import Foundation

// Cancel: a message the Router delivered to a session, taken back from its history line. The session's plugin (`abort-v1`)
// gets a signed abort in its inbox naming the delivery, and answers how far it had gone (`RouterDecision.Cancelled`): not
// started (it never will), working (the turn is stopped and doesn't carry on; a command it was running finishes on its
// own, its result unseen), or over. Nothing the agent did is undone,
// and the words stay in the session's history: Claude Code can't take a submitted prompt back out.

extension Store {
    /// An abort of the delivery `cancels` for the session `target` (its CLI id), signed with the key as last read; nil when
    /// there's none (the Router is off), as for `signRelay`.
    func signAbort(target: String, cancels: String) -> String? {
        guard let paths = routerFiles else { return nil }
        if let cached = relayKeyCache, cached.matches(paths.relayKey) {
            return RelaySigner.signAbort(target: target, cancels: cancels, key: cached.key)
        }
        relayKeyCache = nil
        Task { await reloadRelayKey() }
        return nil
    }

    /// Takes a delivery back through its session's inbox, and reads how far it had gone from the plugin's answer. `gate` is
    /// asked on the main actor right before the abort is written (local and guest alike): a reason refuses it, unwritten. `preflight` is the check made before the guest path's awaited reads: it only checks, so a
    /// refusal there or later leaves nothing committed.
    func cancelDelivery(_ sent: RouterDecision.Delivered, gate: (@MainActor @Sendable () -> String?)? = nil,
                        preflight: (@MainActor @Sendable () -> String?)? = nil) async throws -> RouterDecision.Cancelled {
        guard let paths = routerFiles else { throw RouterTools.Failure("The Router is off") }
        if let computer = GuestRouterRuntime.shared.guestReference(for: sent.session) {
            let connected: (any GuestClient)? = if let location = GuestRouterRuntime.shared.location(for: sent.session) {
                await GuestRouterRuntime.shared.connectedGuestClient(for: location)
            } else { nil }
            guard let client = connected,
                  GuestRouterRuntime.shared.guestSessionID(for: sent.session) == sent.cli else {
                throw RouterTools.Failure("Fjord's guest file client isn't connected for this session")
            }
            let account = try await client.account(for: computer)
            let guestPaths = try GuestRouterPaths(home: account.home)
            let guestNowMs = try await GuestClock.sampleMilliseconds(client: client, computer: computer, account: account)
            let live = try await GuestSessionObserver(client: client).read(computer: computer, paths: guestPaths,
                                                                              guestNowMs: guestNowMs)
            guard live.contains(where: { $0.cliSessionID == sent.cli && $0.capabilities.contains(ClaudePlugin.abortCapability) }) else {
                throw RouterTools.Failure("Fjord's guest plugin can't cancel this delivery, or the session is gone")
            }
            let keyFile = try await client.filesRead(computer: computer, path: guestPaths.key, offset: nil, length: nil)
            guard let key = String(data: keyFile.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  key.count == 64, key.allSatisfy(\.isHexDigit) else {
                throw RouterTools.Failure("Fjord's guest relay key is unavailable")
            }
            let text = RelaySigner.signAbort(target: sent.cli, cancels: sent.nonce, key: key,
                                             now: GuestClock.date(milliseconds: guestNowMs))
            let ack = try await GuestRouterRuntime.shared.deliver(text, to: sent.cli, computer: computer, gate: gate, preflight: preflight)
            guard let how = RouterDecision.Cancelled(ack: ack) else {
                throw RouterTools.Failure("The guest session's plugin answered “\(RouterDecision.clip(ack, 60))”")
            }
            return how
        }
        guard await supportsAbort(sent.cli) else {
            throw RouterTools.Failure("Fjord's plugin in the session can't cancel, or the session is gone")
        }
        var text = signAbort(target: sent.cli, cancels: sent.nonce)
        if text == nil, await reloadRelayKey() { text = signAbort(target: sent.cli, cancels: sent.nonce) }
        guard let text else { throw RouterTools.Failure("The Router is off") }
        let ack = try await RelayInbox(root: paths.relay).deliver(text, to: sent.cli, gate: gate)
        guard let how = RouterDecision.Cancelled(ack: ack) else { throw RouterTools.Failure("The session's plugin answered “\(RouterDecision.clip(ack, 60))”") }
        return how
    }

    /// Whether a history entry's message can still be cancelled, as Fjord sees its session now.
    func canCancel(_ decision: RouterDecision, now: Date = Date()) -> Bool {
        guard let sent = decision.delivered else { return false }
        return sent.cancellable(session: threads[sent.session], now: now)
    }
}
