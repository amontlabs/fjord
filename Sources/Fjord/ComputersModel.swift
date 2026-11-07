import Foundation
import Observation

struct RunningComputer: Equatable, Identifiable {
    var computerId: String
    var name: String
    var kind: ComputerKind
    var id: String { computerId }
}

struct ComputerQuitPrompt: Equatable {
    var runningComputers: [RunningComputer]
    var inspectionError: String? = nil

    var message: String {
        if let inspectionError {
            return "Fjord couldn't check whether any computers are running. \(inspectionError)"
        }
        let names = runningComputers.map(\.name).joined(separator: ", ")
        return "Quit Fjord? \(runningComputers.count) computers are running: \(names)."
    }

    static func make(inventory: ComputerInventory) -> ComputerQuitPrompt? {
        let running = inventory.runningComputers
        guard !running.isEmpty else { return nil }
        return ComputerQuitPrompt(runningComputers: running)
    }

    static func checkFailed(_ error: String) -> ComputerQuitPrompt {
        ComputerQuitPrompt(runningComputers: [], inspectionError: error)
    }
}

enum ComputerQuitChoice: Equatable { case cancel, keepRunning, stopAndQuit }

/// A job as the model tracks it: job ids are owner-local, so a job on another device is `(deviceId, jobId)`. The key is the bare
/// job id for This Mac and `<jobId>@<deviceId>` for another device, and it is what `ComputerJobReceipt.jobId`,
/// `ComputerUploadConflict.jobId` and `ComputersModel.finishedJobs` carry.
enum ComputerJobKey {
    static func make(deviceId: String?, jobId: String) -> String {
        deviceId.map { "\(jobId)@\($0)" } ?? jobId
    }

    static func parts(_ key: String) -> (deviceId: String?, jobId: String) {
        guard let separator = key.lastIndex(of: "@") else { return (nil, key) }
        return (String(key[key.index(after: separator)...]), String(key[..<separator]))
    }
}

struct ComputerUploadContext: Equatable {
    var computerId: String
    var directory: String
    var paths: [String]
    var deviceId: String? = nil
}

struct ComputerUploadConflict: Equatable, Identifiable {
    var jobId: String
    var computerId: String
    var directory: String
    var paths: [String]
    var names: [String]
    var deviceId: String? = nil
    var id: String { jobId }
    var target: GuestReference { GuestReference(deviceId: deviceId, computerId: computerId) }
}

struct ComputerUploadNotice: Equatable, Identifiable {
    var jobId: String
    var computerId: String
    var message: String
    var deviceId: String? = nil
    var id: String { jobId }
    var target: GuestReference { GuestReference(deviceId: deviceId, computerId: computerId) }
}

/// Where a computer's action cannot reach when another device owns the computer, so Fjord says so instead of calling.
/// `display.show` is the owner's own VM window (Silo answers `unsupported_remote_operation`). The other two are answers
/// that name the owner's machine: a published port's URL and the SSH-access command are the owner's loopback address and
/// key path (remote-all.md, remote-guest-ssh.md). Files, terminals, editors and SSH aliases do work remotely.
enum ComputerRemoteLimit {
    case display, openPort, terminal

    var reason: String {
        switch self {
        case .display: "A macOS computer's window opens on the Mac that owns it."
        case .openPort: "This port is published on the Mac that owns the computer, so it can't be opened from here."
        case .terminal: "The SSH command is for the Mac that owns the computer, so it can't be opened from here."
        }
    }

    /// The reason this action is unavailable for `target`, `nil` when it is available.
    func unavailableReason(for target: GuestReference) -> String? { target.deviceId == nil ? nil : reason }
}

struct ComputerJobReceipt: Equatable, Identifiable {
    enum Tone: Equatable { case success, warning, danger }

    var jobId: String
    var action: String
    var message: String
    var tone: Tone
    var id: String { jobId }
}

struct ComputerViewerScriptCommand: Equatable, Identifiable {
    var connectionId: String
    var id: UUID
    var script: String
}

@MainActor
final class ComputerViewerOperationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
@Observable
final class ComputersModel {
    private(set) var client: any EngineClient
    private(set) var inventory: ComputerInventory?
    /// The computers of each connected device, in name order. Computer ids are owner-local, so these never merge with
    /// `inventory` (This Mac).
    private(set) var remoteOwnerInventories: [ComputerOwnerInventory] = []
    /// Connected devices whose computers could not be read, with the reason.
    private(set) var unreachableOwners: [ComputerOwnerFailure] = []
    private(set) var placementError: String?
    var placementOwners: [ComputerOwnerInventory] {
        (inventory.map { [ComputerOwnerInventory.local($0)] } ?? []) + remoteOwnerInventories
    }
    /// Checkpoint usage by `GuestReference.key`.
    var checkpointUsage: [String: CheckpointUsage] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    var actionError: String?
    /// The engine's Keychain access (see KeychainAccess.swift).
    let keychain = KeychainAccessModel()
    private(set) var activeJob: OperationJobProgress?
    /// The device `activeJob` runs on (`nil`: This Mac).
    private(set) var activeJobDeviceId: String?
    /// Finished jobs by `ComputerJobKey`.
    private(set) var finishedJobs: [String: OperationJobFinished] = [:]
    /// Each owner's operation queue, by owner (`ownerKey`).
    private(set) var operationQueues: [String: OperationsList] = [:]
    var operationQueue: OperationsList { operationQueues[GuestReference.ownerKey(nil)] ?? .empty }
    private(set) var jobAwaitingAcknowledgement: String?
    var uploadConflicts: [ComputerUploadConflict] = []
    var uploadNotices: [ComputerUploadNotice] = []
    private(set) var quitPrompt: ComputerQuitPrompt?
    private(set) var quitError: String?
    private(set) var isQuitWorking = false
    var selectedDetailSection: ComputerDetailSection = .overview
    var createSheetKind: ComputerKind?
    /// The device the computer is created on (`nil`: This Mac).
    var createDeviceId: String?
    var isCreatePresented = false
    var hostFacts: DeviceFacts?
    /// This Mac's settings. Settings are host-level and the controller's own (remote-all.md).
    var engineSettings: SiloWireSettingsSnapshot?
    /// Per-computer state is keyed by `GuestReference.key`; per-device state by `GuestReference.ownerKey`.
    var setupActivityByOwner: [String: [SiloWireComputerConfigurationProgress]] = [:]
    var fileLists: [String: SiloWireFileListResult] = [:]
    var filePaths: [String: String] = [:]
    var networkByComputer: [String: SiloWireNetworkComputer] = [:]
    var sshAccessByComputer: [String: SiloWireSSHAccessComputer] = [:]
    var githubStates: [String: SiloWireGitHubState] = [:]
    var secretsByOwner: [String: [SiloWireSecret]] = [:]
    var computerUseByComputer: [String: SiloWireComputerUseState] = [:]
    /// Agent tools by `GuestReference.key` (so a remote owner's computer never collides with a local one).
    var agentToolsByKey: [String: SiloWireAgentToolsStatus] = [:]
    /// The setup in progress for a computer, by key: what to show beside its status.
    var agentToolsSetupMessage: [String: String] = [:]
    var agentToolsError: [String: String] = [:]
    var logsByComputer: [String: SiloWireLogPage] = [:]
    var storageByComputer: [String: SiloWireStorageState] = [:]
    var exportStates: [String: SiloWireBackupState] = [:]
    var archiveInspection: SiloWireArchiveInspectionResult?
    var connectionsStatus: SiloWireConnectionsStatus?
    var connectionHealth: [String: SiloWireDeviceHealth] = [:]
    var connectionDevices: [SiloWireDevice] = []
    private var unknownDeviceRefresh: Task<Void, Never>?
    var pendingViewer: SiloWireViewerOpenResult?
    var viewerScripts: [String: [ComputerViewerScriptCommand]] = [:]
    @ObservationIgnored var viewerOperationGate = ComputerViewerOperationGate()
    @ObservationIgnored var viewerRequestID: UUID?

    @ObservationIgnored private var subscription: String?
    @ObservationIgnored private var subscribedDeviceIds: Set<String> = []
    @ObservationIgnored private var quitHandler: ((ComputerQuitChoice) -> Void)?
    @ObservationIgnored private var quitResolutionTask: Task<Void, Never>?
    @ObservationIgnored var jobActions: [String: String] = [:]
    @ObservationIgnored var uploadContexts: [String: ComputerUploadContext] = [:]
    @ObservationIgnored private var jobReceiptQueue: [String] = []
    @ObservationIgnored private var acknowledgingJobIDs: Set<String> = []
    @ObservationIgnored private var presentedJobOutcomes: Set<String> = []
    /// Jobs whose outcome was presented before their action was known (the finished event beat the reply that names the
    /// job): presented again, with the right action, once it is known.
    @ObservationIgnored private var presentedWithoutAction: Set<String> = []
    /// The last failed operation per computer (`GuestReference.key`), shown on its row until the next one succeeds.
    private(set) var computerFailures: [String: String] = [:]
    @ObservationIgnored private var connectionTask: Task<Void, Error>?
    @ObservationIgnored private var connectionAttemptID: UUID?
    @ObservationIgnored private var eventStreamID: UUID?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryID: UUID?
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var hasSequence = false
    @ObservationIgnored private var recoveryRevision: UInt64 = 0
    @ObservationIgnored private var stateRevision: UInt64 = 0
    @ObservationIgnored private var bufferedEvents: [(UInt64, EngineEvent)] = []
    @ObservationIgnored var reservedNames: Set<String> = []
    @ObservationIgnored private var isRecovering = false
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var ownerRefreshID: UUID?

    init(client: any EngineClient, initialInventory: ComputerInventory? = nil) {
        self.client = client
        inventory = initialInventory
    }

    func replaceClient(_ client: any EngineClient) async {
        let previousClient = self.client
        wantsConnection = false
        connectionAttemptID = nil
        eventStreamID = nil
        connectionTask?.cancel()
        connectionTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryID = nil
        isRecovering = false
        bufferedEvents.removeAll()
        isLoading = false
        if let subscription {
            self.subscription = nil
            await previousClient.eventsUnsubscribe(subscription: subscription)
        }
        self.client = client
        inventory = nil
        remoteOwnerInventories = []
        unreachableOwners = []
        error = nil
        actionError = nil
        activeJob = nil
        activeJobDeviceId = nil
        finishedJobs = [:]
        operationQueues = [:]
        subscribedDeviceIds = []
        stateRevision = 0
        hasSequence = false
        sequence = 0
    }

    /// Drops the errors the page shows that were only the Keychain refusal, once access is allowed.
    func clearCredentialRefusal() {
        if EngineErrorText.isCredentialAccessDenied(error) { error = nil }
        if EngineErrorText.isCredentialAccessDenied(actionError) { actionError = nil }
    }

    func connect() async throws {
        wantsConnection = true
        if let connectionTask {
            try await connectionTask.value
            return
        }
        guard subscription == nil else {
            try await refresh()
            return
        }
        let attemptID = UUID()
        connectionAttemptID = attemptID
        isLoading = true
        let task = Task { @MainActor in
            defer {
                if self.connectionAttemptID == attemptID {
                    self.connectionAttemptID = nil
                    self.connectionTask = nil
                    self.isLoading = false
                    if self.subscription == nil { self.eventStreamID = nil }
                }
            }
            let firstRead = try await self.client.computersList(deviceId: nil)
            guard self.wantsConnection, self.connectionAttemptID == attemptID else { return }
            if self.inventory == nil {
                self.inventory = firstRead
                self.stateRevision &+= 1
            }
            self.sequence = 0
            self.hasSequence = true
            self.eventStreamID = attemptID
            let newSubscription = try await self.subscribeEvents(stream: attemptID)
            guard self.wantsConnection, self.connectionAttemptID == attemptID else {
                self.eventStreamID = nil
                await self.client.eventsUnsubscribe(subscription: newSubscription)
                return
            }
            self.subscription = newSubscription
            // Re-read after subscribing, but do not let a response that crossed an event replace newer state.
            let inventoryRevision = self.stateRevision
            let secondRead = try await self.client.computersList(deviceId: nil)
            guard self.wantsConnection, self.connectionAttemptID == attemptID else { return }
            if self.stateRevision == inventoryRevision {
                self.inventory = secondRead
                self.stateRevision &+= 1
                self.error = nil
            }
            let operationsRevision = self.stateRevision
            let operations = try await self.client.operationsList(deviceId: nil)
            guard self.wantsConnection, self.connectionAttemptID == attemptID else { return }
            if self.stateRevision == operationsRevision {
                self.operationQueues[GuestReference.ownerKey(nil)] = operations
                self.stateRevision &+= 1
                await self.recoverOutstandingJobs(operations.unacknowledgedJobIds, deviceId: nil)
            } else {
                self.beginRecovery(invalidated: true)
            }
            await self.refreshRemoteOwnerInventories()
            await self.refreshRemoteOperations()
            guard self.wantsConnection, self.connectionAttemptID == attemptID else { return }
            await self.resubscribeIfDevicesChanged()
        }
        connectionTask = task
        try await task.value
    }

    private static let eventTopics = ["computers.*", "checkpoints.*", "operations.*", "connections.devices.changed",
                                      "settings.changed", "exports.changed", "display.viewer.page"]

    /// Subscribes to this engine's events and to the connected devices' it relays (`deviceIds`).
    private func subscribeEvents(stream: UUID) async throws -> String {
        let ids = remoteOwnerInventories.compactMap(\.deviceId).sorted()
        subscribedDeviceIds = Set(ids)
        return try await client.eventsSubscribe(events: Self.eventTopics, deviceIds: ids) { [weak self] event in
            self?.receive(event, stream: stream)
        }
    }

    /// The devices to relay changed (one connected or removed): subscribe again for the new set, then read every owner again,
    /// because a device's events only start once it is in the subscription.
    private func resubscribeIfDevicesChanged() async {
        let ids = Set(remoteOwnerInventories.compactMap(\.deviceId))
        guard wantsConnection, let previous = subscription, ids != subscribedDeviceIds else { return }
        let stream = UUID()
        eventStreamID = stream
        subscription = nil
        sequence = 0
        hasSequence = true
        await client.eventsUnsubscribe(subscription: previous)
        do {
            let renewed = try await subscribeEvents(stream: stream)
            guard wantsConnection, eventStreamID == stream else {
                await client.eventsUnsubscribe(subscription: renewed)
                return
            }
            subscription = renewed
            await refreshRemoteOwnerInventories()
            await refreshRemoteOperations()
        } catch {
            if wantsConnection { self.error = error.localizedDescription }
        }
    }

    func activate() async {
        do { try await connect() }
        catch { if wantsConnection { self.error = error.localizedDescription } }
    }

    func deactivate() async {
        await closeScreen()
        wantsConnection = false
        connectionAttemptID = nil
        eventStreamID = nil
        connectionTask?.cancel()
        connectionTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryID = nil
        isRecovering = false
        bufferedEvents.removeAll()
        isLoading = false
        guard let subscription else { return }
        self.subscription = nil
        await client.eventsUnsubscribe(subscription: subscription)
    }

    func refresh() async throws {
        let revision = stateRevision
        let latest = try await client.computersList(deviceId: nil)
        if stateRevision == revision {
            inventory = latest
            stateRevision &+= 1
            error = nil
        }
    }

    /// Loads the local picker inventory and each currently connected remote owner's inventory. Results stay scoped by
    /// owner because computer ids are not globally unique.
    func refreshPlacementInventories() async {
        let revision = stateRevision
        do {
            let latest = try await client.computersList(deviceId: nil)
            if stateRevision == revision {
                inventory = latest
                stateRevision &+= 1
            }
            await refreshRemoteOwnerInventories()
        } catch {
            placementError = error.localizedDescription
            remoteOwnerInventories = []
            unreachableOwners = []
        }
    }

    private func refreshRemoteOwnerInventories() async {
        let attempt = UUID()
        ownerRefreshID = attempt
        do {
            let devices = try await client.connectionsDevicesList()
            var groups: [ComputerOwnerInventory] = []
            var failures: [ComputerOwnerFailure] = []
            for device in devices {
                guard ownerRefreshID == attempt else { return }
                do {
                    let latest = try await client.computersList(deviceId: device.id)
                    groups.append(.remote(device, inventory: latest))
                } catch {
                    failures.append(ComputerOwnerFailure(device: device, message: error.localizedDescription))
                }
            }
            guard ownerRefreshID == attempt else { return }
            remoteOwnerInventories = groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            unreachableOwners = failures.sorted { $0.device.name.localizedStandardCompare($1.device.name) == .orderedAscending }
            let live = Set(groups.compactMap(\.deviceId))
            operationQueues = operationQueues.filter { $0.key == GuestReference.ownerKey(nil) || live.contains($0.key) }
            placementError = failures.isEmpty ? nil
                : "Couldn't load computers from: \(failures.map(\.device.name).joined(separator: ", "))."
        } catch {
            guard ownerRefreshID == attempt else { return }
            remoteOwnerInventories = []
            unreachableOwners = []
            placementError = error.localizedDescription
        }
    }

    /// Reads each connected device's operation queue and shows the jobs it finished while Fjord was away.
    private func refreshRemoteOperations() async {
        for owner in remoteOwnerInventories {
            guard let deviceId = owner.deviceId, wantsConnection else { continue }
            guard let queue = try? await client.operationsList(deviceId: deviceId) else { continue }
            operationQueues[deviceId] = queue
            await recoverOutstandingJobs(queue.unacknowledgedJobIds, deviceId: deviceId)
        }
    }

    // MARK: Owners

    /// The inventory of the device that owns a computer (`nil`: This Mac).
    func inventory(for deviceId: String?) -> ComputerInventory? {
        guard let deviceId else { return inventory }
        return remoteOwnerInventories.first { $0.deviceId == deviceId }?.inventory
    }

    func row(_ target: GuestReference) -> ComputerRow? { inventory(for: target.deviceId)?.computer(target.computerId) }

    /// The name of the device that owns computers: "This Mac" or the connected device's name.
    func ownerName(_ deviceId: String?) -> String {
        guard let deviceId else { return "This Mac" }
        return remoteOwnerInventories.first { $0.deviceId == deviceId }?.name
            ?? unreachableOwners.first { $0.device.id == deviceId }?.device.name
            ?? connectionDevices.first { $0.id == deviceId }?.name ?? "Another Mac"
    }

    /// Every computer of every owner, This Mac first: the groups the Computers page lists.
    var ownerGroups: [ComputerOwnerInventory] { placementOwners }

    private static func sourceDevice(of event: EngineEvent) -> String? {
        switch event {
        case .computersChanged(_, let id), .checkpointsChanged(_, let id), .operationsQueueChanged(_, let id),
             .jobProgress(_, let id), .jobFinished(_, let id): id
        case .guestFilesChanged(let id, _): id
        case .connectionsDevicesChanged, .settingsChanged, .exportsChanged, .viewerPage: nil
        }
    }

    private func isKnownDevice(_ deviceId: String) -> Bool {
        remoteOwnerInventories.contains { $0.deviceId == deviceId }
            || unreachableOwners.contains { $0.device.id == deviceId }
            || connectionDevices.contains { $0.id == deviceId }
    }

    private func refreshForUnknownDevice() {
        guard unknownDeviceRefresh == nil else { return }
        unknownDeviceRefresh = Task { @MainActor [weak self] in
            await self?.refreshPlacementInventories()
            await self?.resubscribeIfDevicesChanged()
            self?.unknownDeviceRefresh = nil
        }
    }

    /// The owner an event came from: a connected device, or This Mac (`nil`) for its own events (no `deviceId`).
    private func eventOwner(_ deviceId: String?) -> String? {
        guard let deviceId, remoteOwnerInventories.contains(where: { $0.deviceId == deviceId }) else { return nil }
        return deviceId
    }

    private func setInventory(_ value: ComputerInventory, for deviceId: String?) {
        guard let deviceId else { inventory = value; return }
        guard let index = remoteOwnerInventories.firstIndex(where: { $0.deviceId == deviceId }) else { return }
        remoteOwnerInventories[index].inventory = value
    }

    func loadCheckpoints(for target: GuestReference) async {
        do {
            let checkpoints = try await client.checkpointsList(computerId: target.computerId, deviceId: target.deviceId)
            guard var inventory = inventory(for: target.deviceId) else { return }
            if let index = inventory.linux.computers.firstIndex(where: { $0.id == target.computerId }) {
                inventory.linux.computers[index].checkpoints = checkpoints
            } else if let index = inventory.macos.computers.firstIndex(where: { $0.id == target.computerId }) {
                inventory.macos.computers[index].checkpoints = checkpoints
            }
            setInventory(inventory, for: target.deviceId)
        } catch { actionError = error.localizedDescription }
    }

    func presentQuitPrompt(_ prompt: ComputerQuitPrompt, onResolved: ((ComputerQuitChoice) -> Void)? = nil) {
        quitPrompt = prompt
        quitError = nil
        quitHandler = onResolved
    }

    func chooseQuit(_ choice: ComputerQuitChoice) {
        guard let prompt = quitPrompt, !isQuitWorking else { return }
        if choice == .cancel {
            quitPrompt = nil
            quitError = nil
            let handler = quitHandler
            quitHandler = nil
            handler?(.cancel)
            return
        }
        isQuitWorking = true
        quitError = nil
        quitResolutionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.resolveQuit(choice, prompt: prompt)
                self.isQuitWorking = false
                self.quitPrompt = nil
                let handler = self.quitHandler
                self.quitHandler = nil
                handler?(choice)
            } catch {
                self.isQuitWorking = false
                self.quitError = error.localizedDescription
            }
        }
    }

    func waitForQuitResolution() async {
        await quitResolutionTask?.value
    }

    func resolveQuit(_ choice: ComputerQuitChoice, prompt: ComputerQuitPrompt) async throws {
        switch choice {
        case .cancel:
            return
        case .keepRunning:
            try await flushEngineSettings()
            try await client.engineDisconnect()
        case .stopAndQuit:
            guard prompt.inspectionError == nil else {
                throw EngineClientError.invalidAction("Refresh the computer list before stopping computers.")
            }
            for computer in prompt.runningComputers {
                let job = try await client.computersStop(ComputerReference(computerId: computer.computerId))
                let finished = try await waitForFinish(job.jobId, deviceId: nil)
                if let failure = finished.error { throw EngineClientError.jobFailed(failure.userMessage) }
            }
            try await waitUntilStopped(Set(prompt.runningComputers.map(\.computerId)))
            try await flushEngineSettings()
            try await client.engineDisconnect()
        }
    }

    private func flushEngineSettings() async throws {
        let _: SiloNull = try await client.invoke(SiloGeneratedMethods.settingsFlush(SiloWireEmptyParams()))
    }

    func start(_ target: GuestReference) async {
        await perform("Start", on: target.deviceId, computer: target) { try await self.client.computersStart(Self.reference(target)) }
    }
    func stop(_ target: GuestReference) async {
        await perform("Stop", on: target.deviceId, computer: target) { try await self.client.computersStop(Self.reference(target)) }
    }
    func forceStop(_ target: GuestReference) async {
        actionError = nil
        do { try await client.computersForceStop(Self.reference(target)) }
        catch { actionError = error.localizedDescription }
    }
    func delete(_ target: GuestReference) async {
        guard let row = row(target) else {
            actionError = EngineClientError.notFound("This computer no longer exists.").localizedDescription
            return
        }
        let expected: ComputerConfiguration? = if case .linux(let computer) = row { computer.configuration } else { nil }
        await perform("Delete", on: target.deviceId, computer: target) {
            try await self.client.computersDelete(ComputerDeleteRequest(computerId: target.computerId,
                                                                        deviceId: target.deviceId, expected: expected))
        }
    }
    func showDisplay(_ target: GuestReference) async {
        actionError = nil
        if let reason = ComputerRemoteLimit.display.unavailableReason(for: target) { actionError = reason; return }
        do { try await client.displayShow(Self.reference(target)) }
        catch { actionError = error.localizedDescription }
    }
    func createCheckpoint(for target: GuestReference) async {
        let name = "Manual checkpoint · \(Date.now.formatted(.dateTime.month(.abbreviated).day()))"
        await perform("Create checkpoint", on: target.deviceId) {
            try await self.client.checkpointsCreate(CheckpointCreateRequest(computerId: target.computerId,
                                                                            deviceId: target.deviceId, kind: .manual, name: name))
        }
    }
    func restoreCheckpoint(_ checkpointId: String, on target: GuestReference) async {
        await perform("Restore checkpoint", on: target.deviceId) {
            try await self.client.checkpointsRestore(CheckpointRestoreRequest(
                checkpointId: checkpointId, computerId: target.computerId, deviceId: target.deviceId))
        }
    }
    func forkCheckpoint(_ checkpointId: String, on target: GuestReference, computerName: String) async {
        do {
            let current = try await inventoryForCreation(deviceId: target.deviceId)
            let name = reserveForkName(from: computerName, in: current)
            defer { reservedNames.remove(name.lowercased()) }
            await perform("Fork checkpoint", on: target.deviceId) {
                try await self.client.checkpointsFork(CheckpointForkRequest(
                    checkpointId: checkpointId, computerId: target.computerId, deviceId: target.deviceId, newName: name))
            }
        } catch { actionError = error.localizedDescription }
    }
    func deleteCheckpoint(_ checkpointId: String, on target: GuestReference) async {
        await perform("Delete checkpoint", on: target.deviceId) {
            try await self.client.checkpointsDelete(CheckpointDeleteRequest(
                checkpointId: checkpointId, computerId: target.computerId, deviceId: target.deviceId))
        }
    }

    /// The wire reference to a computer, with its owner.
    static func reference(_ target: GuestReference) -> ComputerReference {
        ComputerReference(computerId: target.computerId, deviceId: target.deviceId)
    }

    /// Runs an action and follows the job it starts, which belongs to the device that owns the computer (`deviceId`).
    @discardableResult
    func perform<T>(_ label: String, on deviceId: String?, computer: GuestReference? = nil, _ action: () async throws -> T) async -> Bool {
        actionError = nil
        do {
            let accepted = try await action()
            let jobId: String? = if let job = accepted as? ComputerJob { job.jobId }
                else if let job = accepted as? ComputerCreateResult { job.jobId }
                else if let job = accepted as? SiloWireJobStartResult { job.jobId }
                else { nil }
            guard let jobId else { return false }
            let key = ComputerJobKey.make(deviceId: deviceId, jobId: jobId)
            jobActions[key] = label
            if presentedWithoutAction.remove(key) != nil { presentedJobOutcomes.remove(key) }
            let outcome = try await waitForFinish(jobId, deviceId: deviceId)
            presentJobOutcome(outcome, action: label, deviceId: deviceId)
            if let computer {
                if let failure = outcome.error, failure.code != "cancelled" {
                    computerFailures[computer.key] = "\(label) failed: \(failure.userMessage)"
                } else {
                    computerFailures[computer.key] = nil
                }
            }
            let hasUnresolvedUploadOutcome = label == "Upload files"
                && (uploadConflicts.contains { $0.jobId == key } || uploadNotices.contains { $0.jobId == key })
            let uploadWasCancelled = label == "Upload files" && uploadNotices.contains { $0.jobId == key }
            return outcome.error == nil && !hasUnresolvedUploadOutcome && !uploadWasCancelled
        }
        catch { actionError = error.localizedDescription; return false }
    }

    func inventoryForCreation(deviceId: String?) async throws -> ComputerInventory {
        let revision = stateRevision
        let latest = try await client.computersList(deviceId: deviceId)
        guard stateRevision == revision else { return inventory(for: deviceId) ?? latest }
        setInventory(latest, for: deviceId)
        stateRevision &+= 1
        error = nil
        return latest
    }

    func reserveName(_ base: String, in inventory: ComputerInventory) -> String {
        let existing = inventory.allComputers.map(\.name) + Array(reservedNames)
        let name = ComputerName.unique(base, among: existing)
        reservedNames.insert(name.lowercased())
        return name
    }

    func reserveForkName(from sourceName: String, in inventory: ComputerInventory) -> String {
        let existing = inventory.allComputers.map(\.name) + Array(reservedNames)
        let name = ComputerName.uniqueFork(from: sourceName, among: existing)
        reservedNames.insert(name.lowercased())
        return name
    }

    func acknowledgePresentedJob(_ jobId: String) async {
        guard jobAwaitingAcknowledgement == jobId, acknowledgingJobIDs.insert(jobId).inserted else { return }
        defer { acknowledgingJobIDs.remove(jobId) }
        let job = ComputerJobKey.parts(jobId)
        do {
            try await client.operationsJobAcknowledge(jobId: job.jobId, deviceId: job.deviceId)
            removeAcknowledgedJobLocally(jobId)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func acknowledgeConsumedJob(_ jobId: String) async throws {
        let job = ComputerJobKey.parts(jobId)
        try await client.operationsJobAcknowledge(jobId: job.jobId, deviceId: job.deviceId)
        removeAcknowledgedJobLocally(jobId)
    }

    private func removeAcknowledgedJobLocally(_ jobId: String) {
        finishedJobs[jobId] = nil
        jobActions[jobId] = nil
        uploadContexts[jobId] = nil
        jobReceiptQueue.removeAll { $0 == jobId }
        jobAwaitingAcknowledgement = jobReceiptQueue.first
    }

    var pendingUploadConflict: ComputerUploadConflict? { uploadConflicts.first }

    func uploadConflict(for target: GuestReference) -> ComputerUploadConflict? {
        uploadConflicts.first { $0.target == target }
    }

    func uploadNotice(for target: GuestReference) -> ComputerUploadNotice? {
        uploadNotices.first { $0.target == target }
    }

    var currentJobReceipt: ComputerJobReceipt? {
        guard let jobId = jobAwaitingAcknowledgement, let result = finishedJobs[jobId] else { return nil }
        let action = jobActions[jobId] ?? "Computer operation"
        if let failure = result.error {
            let wasCancelled = failure.code == "cancelled"
            return ComputerJobReceipt(jobId: jobId, action: action,
                message: wasCancelled ? "\(action) was cancelled." : "\(action) failed: \(failure.userMessage)",
                tone: wasCancelled ? .warning : .danger)
        }
        return ComputerJobReceipt(jobId: jobId, action: action, message: "\(action) completed.", tone: .success)
    }

    func cancelJob(_ jobId: String, deviceId: String?) async {
        actionError = nil
        do {
            try await client.operationsCancel(jobId: jobId, deviceId: deviceId)
            let revision = stateRevision
            let latest = try await client.operationsList(deviceId: deviceId)
            if stateRevision == revision {
                operationQueues[GuestReference.ownerKey(deviceId)] = latest
                stateRevision &+= 1
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func receive(_ delivery: EngineEventDelivery, stream: UUID) {
        guard wantsConnection, eventStreamID == stream else { return }
        switch delivery {
        case .disconnected(let reason):
            error = reason
        case .reconnected:
            hasSequence = false
            beginRecovery(invalidated: true)
        case .sequenceAdvanced(let next):
            if hasSequence {
                guard next > sequence else { return }
                if next != sequence &+ 1 {
                    sequence = next
                    beginRecovery(invalidated: true)
                    return
                }
            } else {
                hasSequence = true
            }
            sequence = next
        case .event(let next, let event):
            if hasSequence {
                guard next > sequence else { return }
                if next != sequence &+ 1 {
                    sequence = next
                    bufferedEvents.append((next, event))
                    beginRecovery(invalidated: true)
                    return
                }
            } else {
                hasSequence = true
            }
            sequence = next
            if isRecovering {
                bufferedEvents.append((next, event))
                return
            }
            apply(event)
        }
    }

    private func apply(_ event: EngineEvent) {
        if let deviceId = Self.sourceDevice(of: event), !isKnownDevice(deviceId) {
            // Another Mac we haven't loaded: never This Mac's state. Read the devices and the lists again instead.
            refreshForUnknownDevice()
            return
        }
        switch event {
        case .computersChanged(let change, let deviceId):
            stateRevision &+= 1
            let owner = eventOwner(deviceId)
            if let current = inventory(for: owner) { setInventory(current.applying(change), for: owner) }
            error = nil
        case .connectionsDevicesChanged:
            Task { @MainActor [weak self] in
                await self?.refreshRemoteOwnerInventories()
                await self?.resubscribeIfDevicesChanged()
            }
        case .checkpointsChanged(let change, let deviceId):
            stateRevision &+= 1
            let owner = eventOwner(deviceId)
            if let current = inventory(for: owner) {
                setInventory(current.applying(ComputersChangedPayload(linux: change.linux, macos: change.macos)), for: owner)
            }
            if let usage = change.usage {
                for (computerId, value) in usage {
                    checkpointUsage[GuestReference(deviceId: owner, computerId: computerId).key] = value
                }
            }
        case .operationsQueueChanged(let queue, let deviceId):
            stateRevision &+= 1
            operationQueues[GuestReference.ownerKey(eventOwner(deviceId))] = queue
        case .jobProgress(let progress, let deviceId):
            activeJob = progress
            activeJobDeviceId = eventOwner(deviceId)
        case .jobFinished(let result, let deviceId):
            let owner = eventOwner(deviceId)
            if result.isChunked && result.error == nil {
                resolveChunkedOutcome(result.jobId, deviceId: owner)
            } else {
                recordFinished(result, deviceId: owner)
            }
        case .guestFilesChanged:
            break
        case .viewerPage(let page):
            viewerScripts[page.connectionId, default: []].append(
                ComputerViewerScriptCommand(connectionId: page.connectionId, id: UUID(), script: page.script))
        case .settingsChanged(let snapshot):
            engineSettings = snapshot
        case .exportsChanged(let snapshot):
            exportState = snapshot
        }
    }

    func acknowledgeViewerScriptCommand(connectionId: String, commandId: UUID) {
        guard var commands = viewerScripts[connectionId] else { return }
        commands.removeAll { $0.id == commandId }
        viewerScripts[connectionId] = commands.isEmpty ? nil : commands
    }

    /// The event said the outcome is too large to send, so it says nothing about success: read it with
    /// `operations.job.get` first. If that cannot be read, the job is shown as failed rather than as done.
    private func resolveChunkedOutcome(_ jobId: String, deviceId: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var finished: OperationJobFinished
            do {
                var snapshot = try await self.client.operationsJobGet(jobId: jobId, deviceId: deviceId)
                while snapshot.state != .finished {
                    try await Task.sleep(for: .milliseconds(250))
                    snapshot = try await self.client.operationsJobGet(jobId: jobId, deviceId: deviceId)
                }
                finished = snapshot.finishedEvent
            } catch {
                finished = OperationJobFinished(jobId: jobId, error: OperationJobError(
                    code: "internal", message: "The result of this operation could not be read: \(error.localizedDescription)"))
            }
            self.recordFinished(finished, deviceId: deviceId)
        }
    }

    private func recordFinished(_ result: OperationJobFinished, deviceId: String?) {
        let key = ComputerJobKey.make(deviceId: deviceId, jobId: result.jobId)
        finishedJobs[key] = result
        if activeJob?.jobId == result.jobId, activeJobDeviceId == deviceId { activeJob = nil }
        if jobActions[key] == nil { presentedWithoutAction.insert(key) }
        presentJobOutcome(result, action: jobActions[key] ?? "Computer operation", deviceId: deviceId)
    }

    func presentJobOutcome(_ result: OperationJobFinished, action: String, deviceId: String?) {
        let key = ComputerJobKey.make(deviceId: deviceId, jobId: result.jobId)
        guard presentedJobOutcomes.insert(key).inserted else { return }
        if action == "Upload files", result.error == nil, let upload = decodeUploadOutcome(result.result) {
            if upload.status != .done {
                switch upload.status {
                case .conflict:
                    if let context = uploadContexts[key] {
                        uploadConflicts.removeAll { $0.jobId == key }
                        uploadConflicts.append(ComputerUploadConflict(jobId: key,
                            computerId: context.computerId, directory: context.directory, paths: context.paths,
                            names: upload.names ?? [], deviceId: deviceId))
                        actionError = nil
                    } else if let names = upload.names, !names.isEmpty {
                        actionError = "Upload paused because these files already exist: \(names.joined(separator: ", "))."
                    } else {
                        actionError = "Upload paused because files with those names already exist."
                    }
                    return
                case .cancelled:
                    if let context = uploadContexts[key] {
                        uploadNotices.removeAll { $0.jobId == key }
                        uploadNotices.append(ComputerUploadNotice(jobId: key,
                            computerId: context.computerId, message: "Upload cancelled.", deviceId: deviceId))
                        actionError = nil
                        return
                    }
                    actionError = "Upload cancelled."
                    if finishedJobs[key] != nil { enqueueJobReceipt(key) }
                    return
                case .done:
                    break
                }
            }
        }
        if let failure = result.error, failure.code != "cancelled" {
            actionError = "\(action) failed: \(failure.userMessage)"
        }
        enqueueJobReceipt(key)
    }

    private func enqueueJobReceipt(_ jobId: String) {
        if !jobReceiptQueue.contains(jobId) { jobReceiptQueue.append(jobId) }
        jobAwaitingAcknowledgement = jobReceiptQueue.first
    }

    private func decodeUploadOutcome(_ value: JSONValue?) -> SiloWireUploadOutcome? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(SiloWireUploadOutcome.self, from: data)
    }

    func waitForFinish(_ jobId: String, deviceId: String?) async throws -> OperationJobFinished {
        let key = ComputerJobKey.make(deviceId: deviceId, jobId: jobId)
        while true {
            if let finished = finishedJobs[key] { return finished }
            let snapshot = try await client.operationsJobGet(jobId: jobId, deviceId: deviceId)
            if snapshot.state == .finished {
                let result = snapshot.finishedEvent
                recordFinished(result, deviceId: deviceId)
                return result
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func beginRecovery(invalidated: Bool) {
        if invalidated { recoveryRevision &+= 1 }
        isRecovering = true
        guard recoveryTask == nil else { return }
        let recoveryID = UUID()
        self.recoveryID = recoveryID
        recoveryTask = Task { @MainActor [weak self] in
            await self?.recoverDomainState(id: recoveryID)
        }
    }

    private func recoverDomainState(id: UUID) async {
        defer {
            if recoveryID == id {
                isRecovering = false
                recoveryTask = nil
                recoveryID = nil
            }
        }
        while recoveryID == id, wantsConnection, subscription != nil, !Task.isCancelled {
            let revision = recoveryRevision
            do {
                let inventorySnapshot = try await client.computersList(deviceId: nil)
                guard recoveryID == id, wantsConnection, subscription != nil, !Task.isCancelled else { return }
                await refreshRemoteOwnerInventories()
                guard recoveryID == id, wantsConnection, subscription != nil, !Task.isCancelled else { return }
                let operationsSnapshot = try await client.operationsList(deviceId: nil)
                guard recoveryID == id, wantsConnection, subscription != nil, !Task.isCancelled else { return }
                let settingsSnapshot: SiloWireSettingsSnapshot?
                if engineSettings == nil { settingsSnapshot = nil }
                else { settingsSnapshot = try? await client.invoke(SiloGeneratedMethods.settingsRead(SiloWireEmptyParams())) }
                guard recoveryID == id, wantsConnection, subscription != nil, !Task.isCancelled else { return }
                guard revision == recoveryRevision else { continue }

                inventory = inventorySnapshot
                operationQueues[GuestReference.ownerKey(nil)] = operationsSnapshot
                if let settingsSnapshot { engineSettings = settingsSnapshot }
                stateRevision &+= 1
                error = nil
                let events = bufferedEvents.sorted { $0.0 < $1.0 }
                bufferedEvents.removeAll()
                events.forEach { apply($0.1) }
                await recoverOutstandingJobs(operationsSnapshot.unacknowledgedJobIds, deviceId: nil)
                await refreshRemoteOperations()
                guard recoveryID == id, wantsConnection, subscription != nil, !Task.isCancelled else { return }
                guard revision == recoveryRevision else { continue }
                let lateEvents = bufferedEvents.sorted { $0.0 < $1.0 }
                bufferedEvents.removeAll()
                lateEvents.forEach { apply($0.1) }
                if revision == recoveryRevision { return }
            } catch {
                self.error = error.localizedDescription
                if revision == recoveryRevision { return }
            }
        }
    }

    private func recoverOutstandingJobs(_ jobIds: [String], deviceId: String?) async {
        for jobId in jobIds {
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await client.operationsJobGet(jobId: jobId, deviceId: deviceId)
                guard snapshot.state == .finished else { continue }
                recordFinished(snapshot.finishedEvent, deviceId: deviceId)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func waitForRecovery() async {
        await recoveryTask?.value
    }

    func waitUntilStopped(_ computerIds: Set<String>, deviceId: String? = nil,
                          timeout: Duration = .seconds(20)) async throws {
        guard !computerIds.isEmpty else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            var allStopped = true
            for id in computerIds {
                guard let row = inventory(for: deviceId)?.computer(id) else { continue }
                switch row.displayState {
                case .stopped:
                    continue
                case .stopping:
                    allStopped = false
                default:
                    let detail = row.detail ?? "The stop request for \(row.name) was refused; it is still \(row.displayState.title.lowercased())."
                    throw EngineClientError.jobFailed(detail)
                }
            }
            if allStopped { return }
            guard clock.now < deadline else {
                throw EngineClientError.jobFailed("The computers did not stop before the deadline. You can keep Fjord open and try again.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
