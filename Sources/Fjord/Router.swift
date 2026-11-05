import AppKit
import Foundation

// MARK: - Persisted state

/// What the Router keeps across launches: its switch, the log of what it did and changed, where projects run, and the
/// deliveries and remote computers' forms under way. What you act on is the brief's entries (RouterBriefs.swift), never
/// kept here. A file of an older version, cards and all, is read for these keys only: the rest is dropped at the next save.
struct RouterSaved: Codable, Equatable {
    /// Off by default; only offered while the Claude sessions extension is on.
    var enabled = false
    var enabledAt: Date?
    /// What the Router changed in Fjord itself, and your acts on the brief, oldest first (see FjordChange.swift).
    var changes: [FjordChange] = []
    /// The decision log, oldest first (see RouterDecisions.swift).
    var decisions: [RouterDecision] = []
    /// How the Router writes to you (Settings), in your words: what the briefs follow. Nil for the default
    /// (`RouterStyle.defaultText`).
    var style: String?

    /// Projects whose future sessions have an explicit execution location. `sourceFolder` is a local discovery alias used
    /// only to find the existing project row; `id` is the project identity and is retained when placement changes.
    var runsOnProjects: [RunsOnProject] = []
    /// Desktop SSH starts Fjord prepared but cannot observe a session until guest presence and transcript evidence arrive.
    var pendingDesktopStarts: [PendingDesktopStart] = []
    /// Signed guest inbox deliveries and their confirmed/uncertain state; a timeout never licenses a new nonce.
    var guestRelayDeliveries: [GuestRelayRecord] = []
    /// Current guest forms, watched through the owning computer. Their location accompanies the CLI id on persistence.
    var guestPendingForms: [GuestPendingForm] = []
    /// A Router-off removal that could not reach its guest yet; retried on the next guest connection.
    var pendingGuestDisables: [SessionLocation] = []
    /// A deleted computer's Desktop SSH entry or engine alias could not be removed yet; retried after reconnect.
    var pendingGuestRemovals: [SessionLocation] = []
    /// The messages of yours Fjord ordered to sessions, each kept before it was ordered and settled by what the target's plugin
    /// said (RouterCarry.swift).
    var operations: [DeliveryOperation] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, enabledAt, changes, decisions, style, runsOnProjects, pendingDesktopStarts, guestRelayDeliveries
        case guestPendingForms, pendingGuestDisables, pendingGuestRemovals, operations
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(enabledAt, forKey: .enabledAt)
        try c.encode(changes, forKey: .changes)
        try c.encode(decisions, forKey: .decisions)
        try c.encodeIfPresent(style, forKey: .style)
        try c.encode(runsOnProjects, forKey: .runsOnProjects)
        try c.encode(pendingDesktopStarts, forKey: .pendingDesktopStarts)
        try c.encode(guestRelayDeliveries, forKey: .guestRelayDeliveries)
        try c.encode(guestPendingForms, forKey: .guestPendingForms)
        try c.encode(pendingGuestDisables, forKey: .pendingGuestDisables)
        try c.encode(pendingGuestRemovals, forKey: .pendingGuestRemovals)
        try c.encode(operations, forKey: .operations)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each part, and each element of a list, on its own: one this version can't read is left out, not the rest, and is
        // named in `dropped` (the file is then kept aside before it is written over: see `PersistedState`).
        var lost: [String] = []
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            do { return try c.decodeIfPresent(T.self, forKey: key) } catch {
                lost.append(key.stringValue)
                return nil
            }
        }
        func list<T: Decodable>(_ key: CodingKeys) -> [T] {
            guard let all: [Lossy<T>] = value(key) else { return [] }
            let read = all.compactMap(\.value)
            if read.count < all.count { lost.append("\(all.count - read.count) of \(key.stringValue)") }
            return read
        }
        enabled = value(.enabled) ?? false
        enabledAt = value(.enabledAt)
        changes = list(.changes)
        decisions = list(.decisions)
        style = value(.style)
        runsOnProjects = list(.runsOnProjects)
        pendingDesktopStarts = list(.pendingDesktopStarts)
        guestRelayDeliveries = list(.guestRelayDeliveries)
        guestPendingForms = list(.guestPendingForms)
        pendingGuestDisables = list(.pendingGuestDisables)
        pendingGuestRemovals = list(.pendingGuestRemovals)
        operations = list(.operations)
        linkUnlinkedChanges()
        dropped = lost
    }

    static let maxChanges = 500

    /// The oldest changes past `maxChanges` go; one waiting for your Apply stays.
    mutating func pruneChanges() {
        var over = changes.count - Self.maxChanges
        guard over > 0 else { return }
        changes.removeAll { change in
            guard over > 0, change.pending == nil else { return false }
            over -= 1
            return true
        }
    }

    /// What the file had that this version couldn't read ("2 of decisions", "style"): never saved, and handed on to
    /// `PersistedState.dropped` (empty once loaded).
    var dropped: [String] = []
}

/// An element of a saved array read on its own: nil when it can't be, so one bad element doesn't take the rest with it.
struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Where a session came from when an inbox action started it: the category, the thing, the action and its run.
struct SessionOrigin: Codable, Equatable, Hashable {
    var category: String
    /// The thing's reference and title, in a line.
    var thing: String
    var actionID: String
    var runID: String

    /// "⚡ from <category> · <thing>": on the session's rows.
    var label: String { "⚡ from \(category) · \(thing)" }
}

extension Store {
    // MARK: Switching it

    /// The hook and the forms folder follow the toggle. Installing touches `~/.claude/settings.json`, so it happens off the
    /// main thread; `routerHookError` says why it failed.
    func setRouterEnabled(_ on: Bool, now: Date = Date()) {
        guard on != router.enabled else { return }
        routerGeneration &+= 1
        var state = router
        state.enabled = on
        if on { state.enabledAt = state.enabledAt ?? now }
        router = state
        // Off: your messages' runs stop.
        if !on { routerDispatcher.stopAll(reason: RouterDispatcher.unlinkedWords, actions: true); routerDispatcher.unlinked() }
        applyRouterSwitch(install: true)
    }

    /// At launch: the forms folder and its watcher, and the hook again if the app moved since it was installed.
    func startRouter() {
        if router.enabled { applyRouterSwitch(install: false) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await GuestRouterRuntime.shared.rehydrate(store: self)
        }
    }

    /// Where the Router's files are, when they may be touched at all: never in a demo, and in a test only where the test said.
    var routerFiles: RouterPaths? {
        if let routerPaths { return routerPaths }
        guard persists, !Store.isDemo else { return nil }
        return RouterPaths.live()
    }

    /// `install` true: install or uninstall as the toggle says. False (launch): re-install only an outdated hook, and the
    /// plugin when it's outdated or missing.
    private func applyRouterSwitch(install: Bool) {
        let on = router.enabled
        guard let paths = routerFiles else { return }
        observePluginQuit()
        // The key goes the moment the Router is switched off, whatever the CLI does next; a switch-on still under way is
        // fenced off from making it again.
        let generation: Int
        if on {
            generation = relayKeyFence.advance()
        } else {
            relayKeyFence.revoke(paths.relayKey, presence: paths.pluginSessions)
            generation = relayKeyFence.current
            relayKeyCache = nil
        }
        if on {
            formBridge.start(dir: paths.forms) { [weak self] forms in
                guard let self, self.router.enabled else { return }
                let first = !self.routerFormsLoaded
                self.routerFormsLoaded = true
                guard first || forms != self.pendingForms else { return }
                if forms != self.pendingForms { self.pendingForms = forms }
            }
        } else {
            formBridge.stop()
            routerFormsLoaded = false
            if !pendingForms.isEmpty { pendingForms = [:] }
        }
        let executable = routerExecutable ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
        let runner = routerPluginRunner ?? (UnderTest.isRunning ? nil : ClaudePluginInstaller.processRunner)
        let findBinary = routerClaudeBinary ?? { RouterStatus.findDefault() }
        let version = ClaudePlugin.version(app: routerAppVersion)
        let previous = routerHookWork
        routerHookWork = Task { [weak self] in
            await previous?.value
            let result = await Task.detached(priority: .utility) { () -> (FormHookInstaller.Status, String?) in
                let installer = FormHookInstaller(claudeDir: paths.claudeDir)
                do {
                    try FormBridge.setEnabled(on, dir: paths.forms)
                    if on {
                        if install || installer.status(executable: executable) == .outdated {
                            try installer.install(executable: executable)
                        }
                    } else if install {
                        try installer.uninstall()
                    }
                    return (installer.status(executable: executable), nil)
                } catch {
                    return (installer.status(executable: executable), error.localizedDescription)
                }
            }.value
            guard let self else { return }
            if self.routerHookStatus != result.0 { self.routerHookStatus = result.0 }
            if self.routerHookError != result.1 { self.routerHookError = result.1 }
            guard let runner else { return }
            let fence = self.relayKeyFence
            let plugin = await Self.switchPluginNow(on: on, install: install, paths: paths, version: version, findBinary: findBinary,
                                                    run: runner, fence: fence, generation: generation)
            if self.routerPluginStatus != plugin.status { self.routerPluginStatus = plugin.status }
            if self.routerPluginError != plugin.error { self.routerPluginError = plugin.error }
            if let key = plugin.key, fence.current == generation { self.relayKeyCache = key }
        }
    }

    /// Quitting stops the installer's runs of the CLI (each is ended and its exit confirmed).
    private func observePluginQuit() {
        guard pluginQuitObserver == nil else { return }
        pluginQuitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                    queue: .main) { _ in PluginRuns.shared.shutdown() }
    }

    struct PluginSwitch: Sendable {
        var status: ClaudePluginInstaller.Status?
        var error: String?
        /// The key, read off the main thread, for `signRelay`.
        var key: RelayKeyCache?
    }

    /// On (unless a later switch superseded it): the folder is written at this version, the key made once (fenced: see
    /// `RelayKeyFence`), and Claude Code brought to the folder; at launch only when its plugin is missing or outdated.
    /// Off: the plugin and its marketplace are taken out (the key went already, at the switch).
    /// Runs off the main thread, finding Claude Code there too (`findBinary` walks folders).
    nonisolated static func switchPluginNow(on: Bool, install: Bool, paths: RouterPaths, version: String,
                                            findBinary: @escaping @Sendable () -> String?,
                                            run: @escaping ClaudePluginInstaller.Runner, fence: RelayKeyFence,
                                            generation: Int) async -> PluginSwitch {
        let installer = ClaudePluginInstaller(folder: paths.plugin, binary: findBinary(), run: run)
        do {
            if on {
                guard fence.current == generation else { return PluginSwitch(status: try? await installer.status(version: version)) }
                try ClaudePlugin.write(to: paths.plugin, version: version, presence: paths.pluginSessions, key: paths.relayKey,
                                       registry: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true))
                try fence.ifCurrent(generation) { try ClaudePlugin.ensureKey(at: paths.relayKey) }
                let key = RelayKeyCache.load(paths.relayKey)
                let status = try await installer.status(version: version)
                if install || status == .notInstalled || status == .outdated {
                    try await installer.install(version: version)
                }
                return PluginSwitch(status: try await installer.status(version: version), key: key)
            } else if install {
                try await installer.uninstall()
            }
            return PluginSwitch(status: try await installer.status(version: version))
        } catch {
            return PluginSwitch(status: try? await installer.status(version: version), error: error.localizedDescription)
        }
    }

    /// `switchPluginNow` for a caller that can't wait: blocks its thread until done. Call it off the main thread.
    nonisolated static func switchPlugin(on: Bool, install: Bool, paths: RouterPaths, version: String, binary: String?,
                                         run: @escaping ClaudePluginInstaller.Runner) -> (ClaudePluginInstaller.Status?, String?) {
        final class Box: @unchecked Sendable { var value = PluginSwitch() }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let fence = RelayKeyFence()
        let generation = fence.current
        Task.detached {
            box.value = await switchPluginNow(on: on, install: install, paths: paths, version: version, findBinary: { binary },
                                              run: run, fence: fence, generation: generation)
            done.signal()
        }
        done.wait()
        return (box.value.status, box.value.error)
    }

    // MARK: Relaying as the person

    /// The CLI session ids of the sessions Fjord's plugin runs in now (only those can take a message as the person's
    /// own): its presence files under the current key, each bound to a live process Claude Code still registers for
    /// that session. Reads the registry and the presence folder: call it off the main thread.
    nonisolated func sessionsWithPlugin(paths: RouterPaths, keyID: String?) -> Set<String> {
        ClaudePlugin.sessions(in: paths.pluginSessions,
                              registry: ClaudePeers.registry(dir: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true)),
                              keyID: keyID)
    }

    /// `sessionsWithPlugin(paths:keyID:)` for the Router's own files and the key as last read.
    func sessionsWithPlugin() -> Set<String> {
        guard let paths = routerFiles else { return [] }
        return sessionsWithPlugin(paths: paths, keyID: relayKeyCache?.keyID)
    }

    /// `body` signed for the session whose CLI session id is `target`, ready to send as it is; nil when there's no key (the
    /// Router is off, or not set up yet). The key is read off the main thread (by the switch, or `reloadRelayKey`) and used
    /// while its file is the same; here only a stat is made. A key not read yet, or changed, is read again in the
    /// background, and nil is returned meanwhile.
    func signRelay(body: String, target: String) -> String? {
        guard let paths = routerFiles else { return nil }
        if let cached = relayKeyCache, cached.matches(paths.relayKey) {
            return RelaySigner.sign(body: body, target: target, key: cached.key)
        }
        relayKeyCache = nil
        Task { await reloadRelayKey() }
        return nil
    }

    /// Reads the key off the main thread; kept only if no switch came meanwhile. True when there is one.
    @discardableResult
    func reloadRelayKey() async -> Bool {
        guard let paths = routerFiles else { return false }
        let generation = relayKeyFence.current
        // On a queue of its own, not Swift's pool: a busy pool must not hold a message waiting for its key.
        let loaded = await withCheckedContinuation { (done: CheckedContinuation<RelayKeyCache?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: RelayKeyCache.load(paths.relayKey)) }
        }
        guard relayKeyFence.current == generation else { return false }
        if relayKeyCache != loaded { relayKeyCache = loaded }
        return loaded != nil
    }
}
