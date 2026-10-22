import Foundation

// Reaching a session that has no process. Fjord delivers into a session's own Claude Code process; the Claude app caps
// how many it runs and, above the cap, no longer starts one when a session is opened or imported. What does start a
// sleeping session is a message sent to it from another session the app runs (`SendMessage` to `local_<id>`): its text is the
// cold-started session's first prompt. So Fjord keeps a session of its own in the Claude app, the relay, whose only job is that
// call, and has it send the sleeping session a signed wake (`RelaySigner.signWake`); the session's Fjord plugin drops the wake
// (no turn, the process stays up) and comes up with its presence, after which the message goes as always. Design and spikes:
// docs/design/session-wake.md.

/// Fjord's relay session in the Claude app: the app's id (`local_<uuid>`), and Claude Code's own.
struct RouterRelay: Codable, Equatable, Sendable {
    var sessionID: String
    var cliID: String
}

extension RouterTools {
    /// Why nothing can be woken now; the pill offers to start the relay when it reads this.
    static let relayDown = "Fjord's relay isn't running: start it in Claude"

    /// What the relay is told for one wake: the call and nothing else. The plugin lets only this call through in its session.
    static func relayOrder(to session: String, wake: String) -> String {
        "Fjord order: wake a session. Call SendMessage once, with `to` exactly \(session) and `message` exactly \(wake), no "
            + "other field. Say nothing else."
    }

    /// Whether Fjord's plugin runs in `cli` now (a live process with the plugin's presence); tests answer for it.
    func pluginUp(_ store: Store, _ cli: String) async -> Bool {
        if let pluginReadiness { return await pluginReadiness(cli) }
        return await pluginSessionIDs(store).contains(cli)
    }

    /// Signs with the key, reading it again (bounded) when it isn't cached yet.
    private func signing(_ store: Store, ticket: Ticket, _ sign: @MainActor () -> String?) async throws -> String {
        if let text = sign() { return text }
        let reload = keyReload ?? { [weak store] in await store?.reloadRelayKey() ?? false }
        _ = await reload()
        try live(ticket)
        guard let text = sign() else { throw Failure("Fjord couldn't sign the message (its plugin key is missing); nothing was sent") }
        return text
    }

    /// Starts the process of `session` (`local_<id>`, Claude Code's `cli`) through the relay, and returns once Fjord's plugin
    /// is up in it: a signed order into the relay's inbox, the relay's SendMessage of a signed wake, the app starting the
    /// session with it as its first prompt, the session's plugin dropping it. Throws `relayDown` when the relay isn't there.
    func wake(_ store: Store, session local: String, cli: String, title: String, ticket: Ticket) async throws {
        try live(ticket)
        guard let relay = store.relaySession(), await pluginUp(store, relay.cliID) else { throw Failure(Self.relayDown) }
        stage?("waking \(title)")
        if let paths = store.routerFiles {
            // The plugin lets SendMessage through in the relay's session alone, which it knows from its config.
            try await OffMain.run { Swift.Result { try ClaudePlugin.setRelay(relay.cliID, in: paths.plugin) } }.get()
        }
        let wake = try await signing(store, ticket: ticket) { store.signWake(target: cli) }
        let order = try await signing(store, ticket: ticket) {
            store.signRelay(body: Self.relayOrder(to: local, wake: wake), target: relay.cliID)
        }
        try live(ticket)
        if let relayOrders {
            try await relayOrders(order, relay.cliID)
        } else {
            guard let inbox = await store.relayInbox(for: relay.cliID) else { throw Failure(Self.relayDown) }
            do {
                try await inbox.deliver(order, to: relay.cliID, gate: { [weak self] in
                    guard let self else { return "Stopped; nothing was done" }
                    do { try self.live(ticket) } catch { return error.localizedDescription }
                    return self.deliveryCheck?()
                })
            } catch RelayInbox.Failure.unanswered {
                throw Failure(Self.relayDown)
            } catch let failure as RelayInbox.Failure {
                throw Failure(failure.localizedDescription)
            }
        }
        try await waitForPlugin(store, cli: cli, ticket: ticket,
                                failure: "“\(title)” didn't wake: Fjord's plugin didn't come up in it within \(Int(Self.bounded(pluginWait))) s; nothing was sent")
    }

    /// Wakes the session when Fjord's plugin isn't running in it; the CLI id it runs under afterwards.
    func wakeIfAsleep(_ store: Store, session: ClaudeSession, cli: String, ticket: Ticket) async throws {
        guard !(await pluginUp(store, cli)) else { return }
        try await wake(store, session: session.id, cli: cli, title: session.title, ticket: ticket)
    }
}

extension Store {
    /// The relay's folder, under Fjord's own.
    var relayFolder: URL? { routerFiles?.routerHome.appendingPathComponent("relay", isDirectory: true) }

    /// What the relay's session is told when it is made: its job, and a word back.
    static let relayRole = "You are Fjord's relay. Fjord sends you orders to wake sessions: when you receive one, call SendMessage "
        + "once with exactly the `to` and `message` it gives, and say nothing else. Now reply only: Ready."

    /// The link that opens a new session in the Claude app with the relay's role in the composer: the person presses Send once.
    static func relayLink(folder: URL) -> URL? {
        guard var components = URLComponents(string: "claude://code/new") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: relayRole), URLQueryItem(name: "folder", value: folder.path)]
        return components.url
    }

    /// The relay session, if the person made one: the newest session in the relay's folder, kept in the Router's state.
    /// None before the first Send in Claude.
    func relaySession() -> RouterRelay? {
        if let folder = relayFolder?.path,
           let found = claudeSessions.values.filter({ !$0.isArchived && $0.folderKey == folder && $0.cliID != nil })
            .max(by: { $0.lastActivity < $1.lastActivity }), let cli = found.cliID {
            let relay = RouterRelay(sessionID: found.id, cliID: cli)
            if router.relay != relay {
                router.relay = relay
                // The plugin names the relay's session "Fjord" once it knows it (it can't ask Fjord); wakes write it again.
                if let plugin = routerFiles?.plugin {
                    Task { _ = try? await OffMain.run { Swift.Result { try ClaudePlugin.setRelay(relay.cliID, in: plugin) } }.get() }
                }
            }
            return relay
        }
        return router.relay
    }

    /// Opens the Claude app with a new relay session ready to send (its role prefilled, in the relay's folder).
    func startRelay() async {
        guard let folder = relayFolder else { return }
        await PrivateFile.makeFolder(folder)
        guard let url = Self.relayLink(folder: folder) else { return }
        if let interceptOpen { interceptOpen("Start Fjord's relay: \(url.absoluteString)") } else { Link.open(url) }
    }

    /// A wake for the session whose CLI session id is `target`, signed with the key held now; nil when there is none yet.
    func signWake(target: String) -> String? {
        guard let paths = routerFiles else { return nil }
        if let cached = relayKeyCache, cached.matches(paths.relayKey) {
            return RelaySigner.signWake(target: target, key: cached.key)
        }
        relayKeyCache = nil
        Task { await reloadRelayKey() }
        return nil
    }
}
