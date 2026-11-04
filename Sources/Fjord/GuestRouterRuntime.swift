import CryptoKit
import Foundation

/// App-lifetime guest observers. A tool invocation can finish while a Desktop SSH session is still waiting for the person
/// to send; this object keeps file watches alive and reconciles them with the controller's Desktop metadata.
@MainActor final class GuestRouterRuntime {
    /// The app's runtime, which every caller reaches as `shared`.
    static let app = GuestRouterRuntime()
    /// A runtime a test scopes to its own task (and the tasks that one starts): `stopAll` and `disableAll` from other
    /// suites running side by side never reach the watchers and hooks of a test that has its own.
    @TaskLocal nonisolated(unsafe) static var scoped: GuestRouterRuntime?
    static var shared: GuestRouterRuntime { scoped ?? app }

    private weak var store: Store?
    private var clients: [String: any GuestClient] = [:]
    private var computers: [String: GuestReference] = [:]
    private var generatedClient: SiloGuestClient?
    /// Test seam: builds the guest client for an engine client that isn't a socket one.
    var clientFactory: ((any EngineClient) -> (any GuestClient)?)?
    private var watchers: [String: Task<Void, Never>] = [:]
    private var leaseChecks: [String: Task<Void, Never>] = [:]
    private weak var reconciliationStore: Store?
    private var reconciliationClient: (any EngineClient)?
    private var reconciliationSubscription: String?
    private var reconciliationSettings = ClaudeSSHSettings()
    private var evidence: [String: [GuestSessionEvidence]] = [:]
    private var operationTails: [String: Task<Void, Never>] = [:]
    private var disableTask: Task<Void, Never>?
    /// Completion hooks let tests await watch and reconnect work without polling.
    var didRefresh: (@MainActor (GuestReference) -> Void)?
    var didReconcileGuestRemovals: (@MainActor () -> Void)?

    init() {}

    /// Makes the target visible to Router-off before any guest file or command can be changed.
    func registerInstallationTarget(store: Store, client: any GuestClient, computer: GuestReference) {
        self.store = store
        clients[computer.key] = client
        computers[computer.key] = computer
    }

    func startWatching(store: Store, client: any GuestClient, computer: GuestReference) async throws {
        registerInstallationTarget(store: store, client: client, computer: computer)
        guard watchers[computer.key] == nil else { return }
        let account = try await client.account(for: computer)
        let paths = try GuestRouterPaths(home: account.home)
        var watchedPaths = [paths.forms, paths.presence, paths.registry]
        if (try? await client.filesList(computer: computer, path: paths.projects)) != nil {
            watchedPaths.append(paths.projects)
        }
        let watch = try await client.filesWatch(computer: computer, paths: watchedPaths)
        try await refresh(computer: computer, client: client, paths: paths)
        watchers[computer.key] = Task { [weak self, weak store] in
            for await _ in watch.events {
                guard !Task.isCancelled, let self, let store else { return }
                do { try await self.refresh(computer: computer, client: client, paths: paths) }
                catch {
                    self.markGuestExecutionInaccessible(computer)
                    store.routerHookError = "Guest Router refresh failed on \(computer.computerId): \(error.localizedDescription)"
                }
                self.didRefresh?(computer)
            }
        }
        leaseChecks[computer.key] = Task { [weak self, weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, let store else { return }
                do { try await self.refresh(computer: computer, client: client, paths: paths) }
                catch {
                    self.markGuestExecutionInaccessible(computer)
                    store.routerHookError = "Guest Router lease check failed on \(computer.computerId): \(error.localizedDescription)"
                }
            }
        }
    }

    func stopAll() {
        for task in watchers.values { task.cancel() }
        for task in leaseChecks.values { task.cancel() }
        watchers.removeAll()
        leaseChecks.removeAll()
        clients.removeAll()
        computers.removeAll()
        evidence.removeAll()
        didRefresh = nil
        didReconcileGuestRemovals = nil
        guard let store else { return }
        store.routerFormsLoaded = false
        var state = store.router
        state.guestPendingForms = []
        store.router = state
    }

    /// Restores guest clients and watches from saved placements and matched starts after the local Router starts.
    func rehydrate(store: Store, client override: (any GuestClient)? = nil,
                   sshSettings: ClaudeSSHSettings = ClaudeSSHSettings()) async {
        self.store = store
        reconciliationSettings = sshSettings
        let router = store.router
        let hasGuestState = !(router.pendingGuestDisables + router.pendingGuestRemovals).isEmpty
            || (store.routerOn && (!router.runsOnProjects.isEmpty || !router.pendingDesktopStarts.isEmpty
                || !router.guestRelayDeliveries.isEmpty || !router.guestPendingForms.isEmpty))
        if override == nil, hasGuestState { await store.ensureEngineConnected() }
        await startRemovalReconciliation(store: store)
        var locations = router.pendingGuestDisables + router.pendingGuestRemovals
        if store.routerOn {
            locations += router.runsOnProjects.map { $0.placement.location }
            locations += router.pendingDesktopStarts.map(\.location)
            locations += router.guestRelayDeliveries.map(\.location)
            locations += router.guestPendingForms.map(\.location)
        }
        for location in Set(locations).sorted(by: { $0.key < $1.key }) {
            guard case .computer(let deviceId, let computerId) = location else { continue }
            let computer = GuestReference(deviceId: deviceId, computerId: computerId)
            guard let client = override ?? guestClient(for: location) else { continue }
            registerInstallationTarget(store: store, client: client, computer: computer)
            if store.router.pendingGuestRemovals.contains(location) {
                do {
                    try await serialized(computer) { [self] in
                        try await reconcileGuestRemoval(computer: computer, client: client, settings: sshSettings)
                    }
                } catch {
                    store.routerHookError = "Guest SSH cleanup is pending for \(computer.computerId): \(error.localizedDescription)"
                }
            }
            if store.routerOn {
                do { try await startWatching(store: store, client: client, computer: computer) }
                catch {
                    markGuestExecutionInaccessible(computer)
                    store.routerHookError = "Guest Router reconnect is pending for \(computer.computerId): \(error.localizedDescription)"
                }
            } else if store.router.pendingGuestDisables.contains(location) {
                do { try await applyPendingDisable(computer: computer, client: client) }
                catch { store.routerHookError = "Guest Router disable is pending for \(computer.computerId): \(error.localizedDescription)" }
            }
        }
    }

    /// Records cleanup before changing either side, so a failed engine call is retried after the next reconnect.
    func prepareComputerRemoval(store: Store, computer: GuestReference,
                               sshSettings: ClaudeSSHSettings = ClaudeSSHSettings()) async throws {
        self.store = store
        reconciliationSettings = sshSettings
        let location = SessionLocation.computer(deviceId: computer.deviceId, computerId: computer.computerId)
        if !store.router.pendingGuestRemovals.contains(location) {
            var state = store.router
            state.pendingGuestRemovals.append(location)
            store.router = state
        }
        guard let client = guestClient(for: location) else {
            try sshSettings.remove(deviceId: computer.deviceId, computerId: computer.computerId)
            clearPendingGuestRemoval(location)
            return
        }
        registerInstallationTarget(store: store, client: client, computer: computer)
        await startRemovalReconciliation(store: store)
        try await serialized(computer) { [self] in
            try await reconcileGuestRemoval(computer: computer, client: client, settings: sshSettings)
        }
    }

    /// Drops in-memory readers after the engine confirms deletion and returns future starts to This Mac.
    func computerRemoved(store: Store, computer: GuestReference) {
        let location = SessionLocation.computer(deviceId: computer.deviceId, computerId: computer.computerId)
        watchers[computer.key]?.cancel()
        leaseChecks[computer.key]?.cancel()
        watchers[computer.key] = nil
        leaseChecks[computer.key] = nil
        clients[computer.key] = nil
        computers[computer.key] = nil
        evidence[computer.key] = nil

        var state = store.router
        state.runsOnProjects = state.runsOnProjects.map { project in
            guard project.placement.location == location else { return project }
            var project = project
            project.placement = .thisMac(path: project.sourceFolder)
            return project
        }
        state.pendingDesktopStarts.removeAll { $0.location == location && $0.state == .readyInClaude }
        state.guestPendingForms.removeAll { $0.location == location }
        state.pendingGuestDisables.removeAll { $0 == location }
        store.router = state

        for pending in state.pendingDesktopStarts where pending.location == location && pending.state == .matched {
            guard let desktopID = pending.desktopSessionID, let cliID = pending.guestSessionID else { continue }
            store.guestExecutionStates[desktopID] = GuestExecutionState(cliSessionID: cliID, availability: .dead,
                isRunning: false, activity: nil)
            if var session = store.claudeSessions[desktopID] {
                session.running = false
                session.cliID = cliID
                store.claudeSessions[desktopID] = session
            }
            store.claudeActivity[desktopID] = nil
            store.claudeTasks[desktopID] = nil
        }
        store.feedRouter()
    }

    func disableAll() {
        let targets = computers.compactMap { key, computer -> (GuestReference, any GuestClient)? in
            clients[key].map { (computer, $0) }
        }
        if let store {
            var state = store.router
            let knownLocations = state.runsOnProjects.map { $0.placement.location }
                + state.pendingDesktopStarts.map(\.location)
                + targets.map { SessionLocation.computer(deviceId: $0.0.deviceId, computerId: $0.0.computerId) }
            for location in Set(knownLocations) where location != .thisMac {
                if !state.pendingGuestDisables.contains(location) { state.pendingGuestDisables.append(location) }
            }
            store.router = state
        }
        stopAll()
        disableTask = Task { @MainActor [weak self, weak store] in
            for (computer, client) in targets {
                do {
                    guard let self else { return }
                    try await self.serialized(computer) { [self] in
                        try await GuestRouterInstaller(client: client).disable(computer: computer)
                        self.clearPendingDisable(computer)
                    }
                } catch {
                    store?.routerHookError = "Guest Router disable is pending for \(computer.computerId): \(error.localizedDescription)"
                }
            }
            self?.disableTask = nil
        }
    }

    /// Lets tests await a Router-off transition before checking guest files and saved state.
    func waitForDisable() async { await disableTask?.value }

    /// Reconciles a previously failed Router-off while the guest is reachable, before a new install can begin.
    func applyPendingDisable(computer: GuestReference, client: any GuestClient) async throws {
        try await serialized(computer) { [self] in
            try await applyPendingDisableNow(computer: computer, client: client)
        }
    }

    private func applyPendingDisableNow(computer: GuestReference, client: any GuestClient) async throws {
        let location = SessionLocation.computer(deviceId: computer.deviceId, computerId: computer.computerId)
        guard store?.router.pendingGuestDisables.contains(location) == true else { return }
        try await GuestRouterInstaller(client: client).disable(computer: computer)
        clearPendingDisable(computer)
    }

    private func reconcileGuestRemoval(computer: GuestReference, client: any GuestClient,
                                       settings: ClaudeSSHSettings) async throws {
        let location = SessionLocation.computer(deviceId: computer.deviceId, computerId: computer.computerId)
        try settings.remove(deviceId: computer.deviceId, computerId: computer.computerId)
        try await client.sshAliasRemove(computer: computer)
        clearPendingGuestRemoval(location)
    }

    private func reconcilePendingGuestRemovals(store: Store) async {
        defer { didReconcileGuestRemovals?() }
        for location in store.router.pendingGuestRemovals {
            guard case .computer(let deviceId, let computerId) = location,
                  let client = guestClient(for: location) else { continue }
            let computer = GuestReference(deviceId: deviceId, computerId: computerId)
            do {
                try await serialized(computer) { [self] in
                    try await reconcileGuestRemoval(computer: computer, client: client, settings: reconciliationSettings)
                }
            } catch {
                store.routerHookError = "Guest SSH cleanup is pending for \(computer.computerId): \(error.localizedDescription)"
            }
        }
    }

    private func startRemovalReconciliation(store: Store) async {
        guard !store.router.pendingGuestRemovals.isEmpty else { return }
        if reconciliationStore === store, reconciliationSubscription != nil { return }
        if let previous = reconciliationClient, let reconciliationSubscription {
            await previous.eventsUnsubscribe(subscription: reconciliationSubscription)
        }
        reconciliationStore = store
        reconciliationClient = store.engineClient
        do {
            let subscription = try await store.engineClient.eventsSubscribe(events: ["connections.devices.changed"]) {
                [weak self, weak store] delivery in
                let shouldRetry: Bool
                switch delivery {
                case .reconnected, .event(_, .connectionsDevicesChanged): shouldRetry = true
                default: shouldRetry = false
                }
                guard shouldRetry else { return }
                Task { @MainActor [weak self, weak store] in
                    guard let self, let store else { return }
                    await self.reconcilePendingGuestRemovals(store: store)
                }
            }
            reconciliationSubscription = subscription
        } catch {
            store.routerHookError = "Guest SSH cleanup will retry on the next engine connection: \(error.localizedDescription)"
        }
    }

    private func clearPendingGuestRemoval(_ location: SessionLocation) {
        guard let store else { return }
        var state = store.router
        state.pendingGuestRemovals.removeAll { $0 == location }
        store.router = state
        guard state.pendingGuestRemovals.isEmpty, reconciliationStore === store,
              let reconciliationClient, let reconciliationSubscription else { return }
        self.reconciliationSubscription = nil
        self.reconciliationClient = nil
        self.reconciliationStore = nil
        Task { @MainActor in await reconciliationClient.eventsUnsubscribe(subscription: reconciliationSubscription) }
    }

    private func serialized<T: Sendable>(_ computer: GuestReference,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        let key = computer.key
        let previous = operationTails[key]
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        operationTails[key] = Task { @MainActor in _ = try? await task.value }
        return try await task.value
    }

    func reconcileDesktopMetadata() {
        guard let store else { return }
        for pending in store.router.pendingDesktopStarts where pending.state == .readyInClaude {
            let candidates = store.claudeSessions.values.compactMap { session -> DesktopSSHSession? in
                guard !session.isArchived, let alias = session.sshHost, let folder = session.folder, folder == pending.folder,
                      session.lastActivity >= pending.openedAt else { return nil }
                return DesktopSSHSession(id: session.id, alias: alias, folder: folder)
            }
            _ = store.reconcileDesktopStart(pending.id, desktop: candidates, evidence: evidence[pending.location.key] ?? [])
        }
    }

    func selectableDesktopSessions(for pendingID: UUID) -> [ClaudeSession] {
        guard let store, let pending = store.router.pendingDesktopStarts.first(where: {
            $0.id == pendingID && $0.state == .readyInClaude
        }) else { return [] }
        let claimed = Set(store.router.pendingDesktopStarts.compactMap { start in
            start.state == .matched ? start.desktopSessionID : nil
        })
        return store.claudeSessions.values.filter { session in
            !session.isArchived && !claimed.contains(session.id) && session.sshHost == pending.alias
                && session.folder == pending.folder && session.lastActivity >= pending.openedAt
        }.sorted { $0.lastActivity > $1.lastActivity }
    }

    @discardableResult
    func selectDesktopSession(_ desktopSessionID: String, for pendingID: UUID) -> Bool {
        guard let store, let pending = store.router.pendingDesktopStarts.first(where: {
            $0.id == pendingID && $0.state == .readyInClaude
        }), let session = selectableDesktopSessions(for: pendingID).first(where: { $0.id == desktopSessionID }),
              let alias = session.sshHost, let folder = session.folder else { return false }
        let desktop = DesktopSSHSession(id: session.id, alias: alias, folder: folder)
        return store.reconcileDesktopStart(pending.id, desktop: [desktop],
            evidence: evidence[pending.location.key] ?? [], allowEditedPrompt: true)
    }

    func answer(_ guestForm: GuestPendingForm, answers: [String: String], cardID: String, snapshot: FormSnapshot? = nil) async throws {
        guard let store, let client = clients[guestForm.computer.key] else { throw FormWriter.Cancelled() }
        let generation = store.routerGeneration
        try await GuestForms(client: client).answer(guestForm, answers: answers) { [weak store] in
            guard let store, store.routerOn, store.routerGeneration == generation,
                  let card = store.router.cards.first(where: { $0.id == cardID }), card.isOpen,
                  let current = store.guestPendingForm(for: card) else { return false }
            return current.form.id == guestForm.form.id && current.form.toolUseID == guestForm.form.toolUseID
                && snapshot.map { $0.holds(store) } != false
        }
    }

    func answer(_ guestForm: GuestPendingForm, plan decision: PendingForm.PlanDecision, cardID: String,
                snapshot: FormSnapshot? = nil) async throws {
        guard let store, let client = clients[guestForm.computer.key] else { throw FormWriter.Cancelled() }
        let generation = store.routerGeneration
        try await GuestForms(client: client).answer(guestForm, plan: decision) { [weak store] in
            guard let store, store.routerOn, store.routerGeneration == generation,
                  let card = store.router.cards.first(where: { $0.id == cardID }), card.isOpen,
                  let current = store.guestPendingForm(for: card) else { return false }
            return current.form.id == guestForm.form.id && current.form.toolUseID == guestForm.form.toolUseID
                && snapshot.map { $0.holds(store) } != false
        }
    }

    func deliver(_ signedText: String, to cliSessionID: String, computer: GuestReference,
                 decisionID: UUID? = nil, hostSessionID: String? = nil, body: String? = nil,
                 gate: (@MainActor @Sendable () -> String?)? = nil,
                 preflight: (@MainActor @Sendable () -> String?)? = nil) async throws -> String {
        guard let store, let client = clients[computer.key] else { throw GuestClientFailure.notRunning(computer.key) }
        let callback: @MainActor @Sendable (GuestRelayRecord) async -> Void = { [weak store] record in
            store?.saveGuestRelayState(record)
        }
        return try await GuestRelayInbox(client: client, onState: callback)
            .deliver(signedText, to: cliSessionID, computer: computer, decisionID: decisionID,
                     hostSessionID: hostSessionID, body: body, gate: gate, preflight: preflight)
    }

    /// Reconciles the exact signed payload saved before its first guest inbox write.
    func retry(_ record: GuestRelayRecord) async throws -> String {
        guard record.state == .inFlight || record.state == .unconfirmed,
              let signedPayload = record.signedPayload,
              case .computer(let deviceId, let computerId) = record.location,
              let store, let client = clients[GuestReference(deviceId: deviceId, computerId: computerId).key] else {
            throw GuestClientFailure.unavailable("This guest delivery has no retryable payload or connected client")
        }
        let computer = GuestReference(deviceId: deviceId, computerId: computerId)
        let callback: @MainActor @Sendable (GuestRelayRecord) async -> Void = { [weak store] updated in
            store?.saveGuestRelayState(updated)
        }
        let gate: @MainActor @Sendable () -> String? = { [weak store] in
            store?.routerOn == true ? nil : "The Router is off"
        }
        return try await GuestRelayInbox(client: client, onState: callback)
            .deliver(signedPayload, to: record.sessionID, computer: computer, now: record.createdAt,
                     decisionID: record.decisionID, hostSessionID: record.hostSessionID, body: record.body, gate: gate)
    }

    func location(for desktopSessionID: String) -> SessionLocation? {
        store?.router.pendingDesktopStarts.first { $0.desktopSessionID == desktopSessionID && $0.state == .matched }?.location
    }

    func guestSessionID(for desktopSessionID: String) -> String? {
        store?.router.pendingDesktopStarts.first { $0.desktopSessionID == desktopSessionID && $0.state == .matched }?.guestSessionID
    }

    func location(forGuestSessionID cliSessionID: String) -> SessionLocation? {
        store?.router.pendingDesktopStarts.first { $0.guestSessionID == cliSessionID && $0.state == .matched }?.location
    }

    func supportsAbort(forGuestSessionID cliSessionID: String) -> Bool {
        guard let pending = store?.router.pendingDesktopStarts.first(where: {
            $0.guestSessionID == cliSessionID && $0.state == .matched
        }), let desktopID = pending.desktopSessionID else { return false }
        return evidence[pending.location.key]?.contains {
            $0.hostSessionID == desktopID && $0.cliSessionID == cliSessionID
                && $0.capabilities.contains(ClaudePlugin.abortCapability)
        } == true
    }

    /// What the plugin in the guest session `cliSessionID` says it can do and the turn it runs, as of the last read of its
    /// computer; nil when the session isn't one Fjord started there, or isn't live.
    func presence(forGuestSessionID cliSessionID: String) -> (capabilities: [String], turn: ClaudePlugin.Presence.Turn?, hasTurnField: Bool)? {
        guard let pending = store?.router.pendingDesktopStarts.first(where: {
            $0.guestSessionID == cliSessionID && $0.state == .matched
        }), let desktopID = pending.desktopSessionID,
              let found = evidence[pending.location.key]?.first(where: { $0.hostSessionID == desktopID && $0.cliSessionID == cliSessionID })
        else { return nil }
        return (found.capabilities, found.turn, found.hasTurnField)
    }

    /// Seeds what a read of the guest would have found (tests).
    func seedEvidence(_ found: [GuestSessionEvidence], for computer: GuestReference) { evidence[computer.key] = found }

    func guestReference(for desktopSessionID: String) -> GuestReference? {
        guard case .computer(let deviceId, let computerId)? = location(for: desktopSessionID) else { return nil }
        return GuestReference(deviceId: deviceId, computerId: computerId)
    }

    func guestClient(for desktopSessionID: String) -> (any GuestClient)? {
        guard let reference = guestReference(for: desktopSessionID) else { return nil }
        return clients[reference.key]
    }

    func guestClient(for location: SessionLocation) -> (any GuestClient)? {
        guard case .computer(let deviceId, let computerId) = location else { return nil }
        let computer = GuestReference(deviceId: deviceId, computerId: computerId)
        if let client = clients[computer.key] { return client }
        guard let store else { return nil }
        let client: any GuestClient
        if let made = clientFactory?(store.engineClient) { client = made }
        else if let engine = store.engineClient as? SocketEngineClient {
            let generated = generatedClient ?? SiloGuestClient(engine: engine)
            generatedClient = generated
            client = generated
        } else { return nil }
        registerInstallationTarget(store: store, client: client, computer: computer)
        return client
    }

    /// Like `guestClient(for:)`, but connects the engine first when nothing has yet (the Computers page is no longer the only
    /// thing that does), so a Send or Retry right after launch waits for it instead of failing.
    func connectedGuestClient(for location: SessionLocation) async -> (any GuestClient)? {
        if let client = guestClient(for: location) { return client }
        await store?.ensureEngineConnected()
        return guestClient(for: location)
    }

    func guestFolder(for desktopSessionID: String) -> String? {
        store?.router.pendingDesktopStarts.first {
            $0.desktopSessionID == desktopSessionID && $0.state == .matched
        }?.folder
    }

    func transcript(for desktopSessionID: String) -> GuestTranscriptSnapshot? {
        guard let pending = store?.router.pendingDesktopStarts.first(where: {
            $0.desktopSessionID == desktopSessionID && $0.state == .matched
        }), let cli = pending.guestSessionID else { return nil }
        return evidence[pending.location.key]?.first { $0.hostSessionID == desktopSessionID && $0.cliSessionID == cli }?.transcript
    }

    private func refresh(computer: GuestReference, client: any GuestClient, paths: GuestRouterPaths) async throws {
        guard let store else { return }
        let forms = try await GuestForms(client: client).read(computer: computer, paths: paths)
        let current = forms.values.sorted { $0.form.id < $1.form.id }
        if current != store.router.guestPendingForms {
            var state = store.router
            state.guestPendingForms.removeAll { $0.computer == computer }
            state.guestPendingForms.append(contentsOf: current)
            store.router = state
        }
        store.routerFormsLoaded = true
        let projectFoldersBySession = Dictionary(store.router.pendingDesktopStarts.compactMap { pending -> (String, String)? in
            guard pending.state == .matched, pending.location.key == computer.key, let cli = pending.guestSessionID else { return nil }
            return (cli, pending.folder)
        }, uniquingKeysWith: { _, latest in latest })
        evidence[computer.key] = try await GuestSessionObserver(client: client).read(computer: computer, paths: paths,
            projectFoldersBySession: projectFoldersBySession, formSessionIDs: Set(current.map(\.form.cliSessionID)))
        reconcileDesktopMetadata()
        applyGuestEvidenceToStore()
    }

    private func applyGuestEvidenceToStore() {
        guard let store else { return }
        var sessions = store.claudeSessions
        var activities = store.claudeActivity
        var tasks = store.claudeTasks
        var changedSessions = false
        var changedActivities = false
        var changedTasks = false
        for pending in store.router.pendingDesktopStarts where pending.state == .matched {
            guard let desktopID = pending.desktopSessionID, let cli = pending.guestSessionID else { continue }
            guard let evidence = evidence[pending.location.key]?.first(where: {
                      $0.hostSessionID == desktopID && $0.cliSessionID == cli
                  }) else {
                store.guestExecutionStates[desktopID] = GuestExecutionState(cliSessionID: cli,
                    availability: .dead, isRunning: false, activity: nil)
                if var session = sessions[desktopID], session.running || session.cliID != cli {
                    session.running = false
                    session.cliID = cli
                    sessions[desktopID] = session
                    changedSessions = true
                }
                if activities[desktopID] != nil { activities[desktopID] = nil; changedActivities = true }
                if tasks[desktopID] != nil { tasks[desktopID] = nil; changedTasks = true }
                continue
            }
            guard let transcript = evidence.transcript else {
                store.guestExecutionStates[desktopID] = inaccessibleState(for: desktopID, cliID: cli, in: store)
                continue
            }
            let activity = transcript.activity
            // The plugin's own word for it when it gives one; else the transcript's tail.
            let running = evidence.hasTurnField ? evidence.turn != nil : !Claude.transcriptEndedTurn(tail: transcript.tail)
            store.guestExecutionStates[desktopID] = GuestExecutionState(cliSessionID: cli,
                availability: .live, isRunning: running, activity: activity)
            if var session = sessions[desktopID] {
                if session.running != running || session.cliID != cli {
                    session.running = running
                    session.cliID = cli
                    sessions[desktopID] = session
                    changedSessions = true
                }
            }
            if let activity {
                if activities[desktopID] != activity { activities[desktopID] = activity; changedActivities = true }
            } else if activities[desktopID] != nil {
                activities[desktopID] = nil
                changedActivities = true
            }
            if let guestTasks = evidence.tasks {
                let value = guestTasks.isEmpty ? nil : guestTasks
                if tasks[desktopID] != value { tasks[desktopID] = value; changedTasks = true }
            }
        }
        if changedSessions { store.claudeSessions = sessions }
        if changedActivities { store.claudeActivity = activities }
        if changedTasks { store.claudeTasks = tasks }
        if changedSessions || changedActivities || changedTasks { store.feedRouter() }
    }

    private func markGuestExecutionInaccessible(_ computer: GuestReference) {
        guard let store else { return }
        for pending in store.router.pendingDesktopStarts where pending.state == .matched && pending.location.key == computer.key {
            guard let desktopID = pending.desktopSessionID, let cliID = pending.guestSessionID else { continue }
            store.guestExecutionStates[desktopID] = inaccessibleState(for: desktopID, cliID: cliID, in: store)
        }
    }

    private func inaccessibleState(for desktopID: String, cliID: String, in store: Store) -> GuestExecutionState {
        let previous = store.guestExecutionStates[desktopID]
        return GuestExecutionState(cliSessionID: cliID, availability: .inaccessible,
            isRunning: previous?.isRunning ?? store.claudeSessions[desktopID]?.running,
            activity: previous?.activity ?? store.claudeActivity[desktopID])
    }

    private func clearPendingDisable(_ computer: GuestReference) {
        guard let store else { return }
        let location = SessionLocation.computer(deviceId: computer.deviceId, computerId: computer.computerId)
        var state = store.router
        let kept = state.pendingGuestDisables.filter { $0 != location }
        guard kept.count != state.pendingGuestDisables.count else { return }
        state.pendingGuestDisables = kept
        store.router = state
    }
}
