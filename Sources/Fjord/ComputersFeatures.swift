import AppKit
import Foundation

enum ComputerDetailSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case files = "Files"
    case network = "Network"
    case access = "Access"
    case activity = "Activity"
    case storage = "Storage"

    var id: String { rawValue }
}

enum ComputerFilesPath {
    static func root(for kind: ComputerKind) -> String? {
        kind == .linux ? "/workspace" : nil
    }

    static func parent(of path: String, kind: ComputerKind) -> String? {
        guard let root = root(for: kind) else { return nil }
        let normalized = (path as NSString).standardizingPath
        guard normalized != root else { return root }
        guard normalized.hasPrefix(root + "/") else { return root }
        let parent = (normalized as NSString).deletingLastPathComponent
        return parent == root || parent.hasPrefix(root + "/") ? parent : root
    }
}

enum ComputerNetworkPolicy {
    static let hiddenDesktopPort = 6901
}

enum ComputerSecretValidation {
    static func name(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count), let first = bytes.first,
              (first == 95 || (65...90).contains(first) || (97...122).contains(first)) else { return false }
        return bytes.dropFirst().allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }
    }

    static func domains(_ values: [String], allowAnyDestination: Bool) -> Bool {
        guard !values.isEmpty, values.count <= 100 else { return false }
        if values.contains("*") { return allowAnyDestination && values.count == 1 }
        return values.allSatisfy { value in
            let host = value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
            guard !host.isEmpty, host.utf8.count <= 253 else { return false }
            return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                guard (1...63).contains(label.utf8.count), let first = label.utf8.first,
                      let last = label.utf8.last, first != 45, last != 45 else { return false }
                return label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
            }
        }
    }
}

struct ComputerResourceLimits: Equatable {
    var minCPUs: Int
    var maxCPUs: Int
    var minMemoryGiB: Int
    var maxMemoryGiB: Int
    var minDiskGiB: Int?
    var maxDiskGiB: Int?
    var defaultCPUs: Int
    var defaultMemoryGiB: Int
    var defaultDiskGiB: Int?

    static func linux(from facts: DeviceFacts, owner: String = "This Mac") throws -> Self {
        guard let capacity = facts.deviceCapacity else {
            throw EngineClientError.invalidAction("\(owner)'s CPU and memory capacity are unavailable.")
        }
        let cpus = capacity.logicalCpus
        let memory = min(capacity.maxMemoryGib, Int(capacity.physicalMemoryBytes / 1_073_741_824))
        guard cpus >= 1, memory >= 1 else {
            throw EngineClientError.invalidAction("\(owner) does not have enough capacity for a Linux computer.")
        }
        return Self(minCPUs: 1, maxCPUs: cpus, minMemoryGiB: 1, maxMemoryGiB: memory,
                    minDiskGiB: nil, maxDiskGiB: nil,
                    defaultCPUs: min(2, cpus), defaultMemoryGiB: min(4, memory), defaultDiskGiB: nil)
    }

    static func macos(from facts: DeviceFacts, minimumDiskGiB: Int, owner: String = "This Mac") throws -> Self {
        guard let limits = facts.macosHostLimits, limits.cpus >= 2, limits.memory_gib >= 8 else {
            throw EngineClientError.invalidAction("\(owner) needs at least 2 CPUs and 8 GiB of memory to host a macOS computer.")
        }
        let minimumDisk = max(32, minimumDiskGiB)
        guard minimumDisk <= 1024 else {
            throw EngineClientError.invalidAction("The macOS template requires more disk space than \(owner) can create.")
        }
        let maxMemory = limits.memory_gib - 4
        return Self(minCPUs: 2, maxCPUs: limits.cpus, minMemoryGiB: 4, maxMemoryGiB: maxMemory,
                    minDiskGiB: minimumDisk, maxDiskGiB: 1024,
                    defaultCPUs: max(2, limits.cpus / 2), defaultMemoryGiB: max(4, min(maxMemory, limits.memory_gib / 2)),
                    defaultDiskGiB: minimumDisk)
    }
}

extension SiloWireBackupOperation {
    var operationClass: SiloWireOperationClass {
        SiloWireOperationClass(archive: archive, canCancel: canCancel, indeterminate: indeterminate,
                               kind: kind, operation: operation, phases: phases, progress: progress,
                               runningNames: runningNames, targetName: targetName, detail: detail,
                               message: message, outcome: outcome, title: title)
    }
}

extension SiloWireOperationClass {
    var backupOperation: SiloWireBackupOperation {
        SiloWireBackupOperation(archive: archive, canCancel: canCancel, indeterminate: indeterminate,
                                kind: kind, operation: operation, phases: phases, progress: progress,
                                runningNames: runningNames, targetName: targetName, detail: detail,
                                message: message, outcome: outcome, title: title)
    }
}

extension ComputersModel {
    /// The limits of the device that will host the computer (`nil`: This Mac).
    func resourceLimits(for kind: ComputerKind, deviceId: String? = nil) async throws -> ComputerResourceLimits {
        let facts = try await client.deviceFactsRead(deviceId: deviceId)
        if deviceId == nil { hostFacts = facts }
        let owner = ownerName(deviceId)
        switch kind {
        case .linux: return try .linux(from: facts, owner: owner)
        case .macos:
            let owned = inventory(for: deviceId)
            if let state = owned?.macos, !state.supported {
                throw EngineClientError.unsupported(state.unsupportedReason ?? "\(owner) cannot host a macOS computer.")
            }
            return try .macos(from: facts, minimumDiskGiB: Int(clamping: owned?.macos.minDiskGiB ?? 32), owner: owner)
        }
    }

    func createLinuxComputer(name: String, cpus: Int, memoryGiB: Int, deviceId: String? = nil) async {
        do {
            guard ComputerName.isValid(name) else {
                throw EngineClientError.invalidAction("Choose a valid computer name.")
            }
            let limits = try await resourceLimits(for: .linux, deviceId: deviceId)
            guard (limits.minCPUs...limits.maxCPUs).contains(cpus),
                  (limits.minMemoryGiB...limits.maxMemoryGiB).contains(memoryGiB) else {
                throw EngineClientError.invalidAction("Choose CPU and memory values within \(ownerName(deviceId))'s available capacity.")
            }
            let current = try await inventoryForCreation(deviceId: deviceId)
            let computerName = reserveName(name, in: current)
            defer { reservedNames.remove(computerName.lowercased()) }
            let id = UUID().uuidString.lowercased()
            let configuration = ComputerConfiguration(id: id, name: computerName, cpus: cpus,
                                                      maxCPUs: limits.maxCPUs, memoryGiB: memoryGiB,
                                                      maxMemoryGiB: limits.maxMemoryGiB,
                                                      workspaceStorageGiB: 64, runtimeStorageGiB: 32)
            await perform("Create Linux computer", on: deviceId) {
                try await self.client.computersCreate(.linux(configuration, requestId: id, deviceId: deviceId))
            }
        } catch { actionError = error.localizedDescription }
    }

    func createMacosComputer(name: String, cpus: Int, memoryGiB: Int, diskGiB: Int, deviceId: String? = nil) async {
        do {
            guard ComputerName.isValid(name) else {
                throw EngineClientError.invalidAction("Choose a valid computer name.")
            }
            let limits = try await resourceLimits(for: .macos, deviceId: deviceId)
            guard (limits.minCPUs...limits.maxCPUs).contains(cpus),
                  (limits.minMemoryGiB...limits.maxMemoryGiB).contains(memoryGiB),
                  let minDisk = limits.minDiskGiB, let maxDisk = limits.maxDiskGiB,
                  (minDisk...maxDisk).contains(diskGiB) else {
                throw EngineClientError.invalidAction("Choose CPU, memory and disk values within \(ownerName(deviceId))'s limits.")
            }
            let current = try await inventoryForCreation(deviceId: deviceId)
            let computerName = reserveName(name, in: current)
            defer { reservedNames.remove(computerName.lowercased()) }
            let request = MacosComputerCreateRequest(name: computerName, cpus: cpus,
                                                     memoryGiB: memoryGiB, diskGiB: diskGiB)
            await perform("Create macOS computer", on: deviceId) {
                try await self.client.computersCreate(.macos(request, deviceId: deviceId))
            }
        } catch { actionError = error.localizedDescription }
    }

    func updateResources(for target: GuestReference, cpus: Int, memoryGiB: Int,
                         expectedConfiguration: ComputerConfiguration? = nil) async {
        let computerId = target.computerId
        guard var row = row(target) else { return }
        let initialLinux: ComputerConfiguration?
        if case .linux(let computer) = row { initialLinux = computer.configuration } else { initialLinux = nil }
        let displayedConfiguration = expectedConfiguration ?? initialLinux
        if initialLinux != nil {
            guard displayedConfiguration?.id == computerId else {
                actionError = "This computer changed while you were editing it. Refresh the values and try again."
                return
            }
        }
        actionError = nil
        do {
            if row.displayState == .running {
                let stopped = await perform("Stop before editing resources", on: target.deviceId) {
                    try await self.client.computersStop(Self.reference(target))
                }
                guard stopped else { return }
                try await waitUntilStopped([computerId], deviceId: target.deviceId)
                let latest = try await inventoryForCreation(deviceId: target.deviceId)
                guard let refreshed = latest.computer(computerId) else {
                    throw EngineClientError.notFound("This computer no longer exists.")
                }
                row = refreshed
            }
            guard row.displayState == .stopped else {
                throw EngineClientError.invalidAction("Stop the computer before changing CPU or memory.")
            }
            switch row {
            case .linux(let computer):
                guard let displayedConfiguration, computer.configuration == displayedConfiguration else {
                    throw EngineClientError.invalidAction(
                        "This computer's resources changed while you were editing. Refresh the values and reapply your changes.")
                }
                guard (1...computer.configuration.maxCPUs).contains(cpus),
                      (1...computer.configuration.maxMemoryGiB).contains(memoryGiB) else {
                    throw EngineClientError.invalidAction("CPU and memory values exceed the configured host limits.")
                }
                var updated = displayedConfiguration
                updated.cpus = cpus
                updated.memoryGiB = memoryGiB
                let change = SiloWireComputerConfigurationChange(configuration: updated,
                                                                  expected: SiloWireConfiguration(displayedConfiguration),
                                                                  kind: .upsert)
                let result = try await client.invoke(SiloGeneratedMethods.computersConfigurationChange(
                    SiloWireComputerConfigurationChangeParams(change: change, deviceId: target.deviceId,
                                                              requestId: UUID().uuidString)))
                await waitForFeatureJob(result.jobId, deviceId: target.deviceId, label: "Update computer resources")
            case .macos(let computer):
                let limits = try await resourceLimits(for: .macos, deviceId: target.deviceId)
                guard (limits.minCPUs...limits.maxCPUs).contains(cpus),
                      (limits.minMemoryGiB...limits.maxMemoryGiB).contains(memoryGiB) else {
                    throw EngineClientError.invalidAction("CPU and memory values exceed \(ownerName(target.deviceId))'s available capacity.")
                }
                let expected = SiloWireConfiguration(cpus: computer.cpus, memoryGiB: computer.memoryGiB,
                                                     diskGiB: computer.diskGiB)
                let change = SiloWireComputerConfigurationChange(
                    expected: expected, kind: .macosResources, computerId: computerId,
                    cpus: UInt64(cpus), memoryGiB: UInt64(memoryGiB), requestId: UUID().uuidString)
                let result = try await client.invoke(SiloGeneratedMethods.computersConfigurationChange(
                    SiloWireComputerConfigurationChangeParams(change: change, deviceId: target.deviceId,
                                                              requestId: UUID().uuidString)))
                await waitForFeatureJob(result.jobId, deviceId: target.deviceId, label: "Update computer resources")
            }
        } catch { actionError = error.localizedDescription }
    }

    func loadSettings() async {
        do { engineSettings = try await client.invoke(SiloGeneratedMethods.settingsRead(SiloWireEmptyParams())) }
        catch { actionError = error.localizedDescription }
    }

    func updateAutomaticCheckpointRetention(_ count: UInt64) async {
        var patch = SiloWireSettingsValues()
        patch.automaticCheckpointRetentionCount = count
        await updateSettings(patch)
    }

    func updateStartComputersAtLaunch(_ enabled: Bool) async {
        var patch = SiloWireSettingsValues()
        patch.startComputersAtLaunch = enabled
        await updateSettings(patch)
    }

    func updateStartupComputerIds(_ ids: [String]) async {
        var patch = SiloWireSettingsValues()
        patch.startupComputerIds = ids
        await updateSettings(patch)
    }

    private func updateSettings(_ patch: SiloWireSettingsValues) async {
        do {
            engineSettings = try await client.invoke(SiloGeneratedMethods.settingsUpdate(SiloWireSettingsUpdateParams(patch: patch)))
            actionError = engineSettings?.saveError
        } catch { actionError = error.localizedDescription }
    }

    func loadSetupActivity(deviceId: String?) async {
        do {
            setupActivityByOwner[GuestReference.ownerKey(deviceId)] = try await client.invoke(
                SiloGeneratedMethods.activitySetupRead(SiloWireDeviceParams(deviceId: deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func loadCheckpointUsage(_ target: GuestReference) async {
        do {
            checkpointUsage[target.key] = try await client.invoke(
                SiloGeneratedMethods.checkpointsUsage(SiloWireCheckpointUsageParams(
                    computerId: target.computerId, deviceId: target.deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func abandonRestore(_ target: GuestReference) async {
        do {
            let job = try await client.invoke(SiloGeneratedMethods.checkpointsAbandonRestore(Self.reference(target)))
            await waitForFeatureJob(job.jobId, deviceId: target.deviceId, label: "Abandon restore")
        } catch { actionError = error.localizedDescription }
    }

    func loadFiles(_ target: GuestReference, path requestedPath: String? = nil,
                   offset: UInt64 = 0, snapshotId: String? = nil) async {
        guard let kind = row(target)?.kind,
              let root = ComputerFilesPath.root(for: kind) else { return }
        let path = requestedPath ?? root
        do {
            let result = try await client.invoke(SiloGeneratedMethods.filesList(SiloWireFileListParams(
                computerId: target.computerId, deviceId: target.deviceId, offset: offset, path: path, snapshotId: snapshotId)))
            if offset == 0 { fileLists[target.key] = result }
            else if var previous = fileLists[target.key], previous.snapshotId == result.snapshotId {
                previous.entries.append(contentsOf: result.entries)
                previous.nextOffset = result.nextOffset
                fileLists[target.key] = previous
            } else { fileLists[target.key] = result }
            filePaths[target.key] = path
        } catch { actionError = error.localizedDescription }
    }

    func uploadFiles(_ target: GuestReference, directory: String, paths: [String],
                     conflict: SiloWireConflictPolicy = .ask) async {
        guard !paths.isEmpty else { return }
        let transferId = UUID().uuidString
        let key = ComputerJobKey.make(deviceId: target.deviceId, jobId: "transfer:\(transferId)")
        uploadContexts[key] = ComputerUploadContext(computerId: target.computerId, directory: directory, paths: paths,
                                                    deviceId: target.deviceId)
        let params = SiloWireFileUploadParams(computerId: target.computerId, conflict: conflict, deviceId: target.deviceId,
                                               directory: directory, origin: .client, paths: paths, transferId: transferId)
        await perform("Upload files", on: target.deviceId) {
            try await self.client.invoke(SiloGeneratedMethods.filesUpload(params))
        }
        await loadFiles(target, path: directory)
    }

    func resolveUploadConflict(jobId: String, policy: SiloWireConflictPolicy) async {
        guard let index = uploadConflicts.firstIndex(where: { $0.jobId == jobId }) else { return }
        let conflict = uploadConflicts[index]
        do {
            try await acknowledgeConsumedJob(jobId)
        } catch {
            actionError = error.localizedDescription
            return
        }
        uploadConflicts.remove(at: index)
        uploadContexts[jobId] = nil
        await uploadFiles(conflict.target, directory: conflict.directory, paths: conflict.paths, conflict: policy)
    }

    func dismissUploadConflict(jobId: String) async {
        guard let index = uploadConflicts.firstIndex(where: { $0.jobId == jobId }) else { return }
        do {
            try await acknowledgeConsumedJob(jobId)
            uploadConflicts.remove(at: index)
            uploadContexts[jobId] = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    func dismissUploadNotice(jobId: String) async {
        guard let index = uploadNotices.firstIndex(where: { $0.jobId == jobId }) else { return }
        do {
            try await acknowledgeConsumedJob(jobId)
            uploadNotices.remove(at: index)
            uploadContexts[jobId] = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    func downloadFile(_ target: GuestReference, path: String, destination: String) async {
        let params = SiloWireFileDownloadParams(computerId: target.computerId, destination: destination,
                                                deviceId: target.deviceId, path: path, transferId: UUID().uuidString)
        await perform("Download file", on: target.deviceId) { try await self.client.invoke(SiloGeneratedMethods.filesDownload(params)) }
    }

    func loadNetwork(_ target: GuestReference) async {
        do {
            let state = try await client.invoke(SiloGeneratedMethods.networkState(SiloWireDeviceParams(deviceId: target.deviceId)))
            let name = row(target)?.name
            if let entry = state.computers.first(where: { $0.computerId == target.computerId || $0.computer == name }) {
                networkByComputer[target.key] = entry
            } else {
                networkByComputer[target.key] = SiloWireNetworkComputer(computer: name ?? target.computerId,
                                                                         computerId: target.computerId, ports: [])
            }
        } catch { actionError = error.localizedDescription }
    }

    func publishPort(_ target: GuestReference, port: Int, hostPort: Int? = nil,
                     scheme: SiloWireNetworkScheme? = nil) async {
        actionError = nil
        guard let computer = row(target) else {
            actionError = "This computer is no longer available. Refresh the computer list and try again."
            return
        }
        let isLinuxComputer = computer.kind == .linux
        guard (1...65_535).contains(port), !(isLinuxComputer && port == ComputerNetworkPolicy.hiddenDesktopPort),
              hostPort.map({ (1...65_535).contains($0) }) ?? true else {
            actionError = isLinuxComputer && port == ComputerNetworkPolicy.hiddenDesktopPort
                ? "The Linux desktop port stays private behind Open screen."
                : "Enter ports from 1 to 65535."
            return
        }
        do {
            let state = try await client.invoke(SiloGeneratedMethods.networkPublish(
                SiloWireNetworkPublishParams(computerId: target.computerId, deviceId: target.deviceId,
                                             hostPort: hostPort, port: port, scheme: scheme)))
            updateNetworkState(state, target: target)
        } catch { actionError = error.localizedDescription }
    }

    func unpublishPort(_ target: GuestReference, port: Int) async {
        actionError = nil
        do {
            let state = try await client.invoke(SiloGeneratedMethods.networkUnpublish(
                SiloWireNetworkUnpublishParams(computerId: target.computerId, deviceId: target.deviceId, port: port)))
            updateNetworkState(state, target: target)
        } catch { actionError = error.localizedDescription }
    }

    func openPort(_ target: GuestReference, port: Int) async {
        actionError = nil
        if let reason = ComputerRemoteLimit.openPort.unavailableReason(for: target) { actionError = reason; return }
        do {
            let result = try await client.invoke(SiloGeneratedMethods.networkOpen(
                SiloWireNetworkOpenParams(computerId: target.computerId, deviceId: target.deviceId, port: port)))
            if let url = URL(string: result.url) { NSWorkspace.shared.open(url) }
        } catch { actionError = error.localizedDescription }
    }

    private func updateNetworkState(_ state: SiloWireNetworkState, target: GuestReference) {
        let name = row(target)?.name
        if let entry = state.computers.first(where: { $0.computerId == target.computerId || $0.computer == name }) {
            networkByComputer[target.key] = entry
        }
    }

    // MARK: Per-device state (GitHub, secrets, exports)

    /// This Mac's GitHub state.
    var githubState: SiloWireGitHubState? {
        get { githubStates[GuestReference.ownerKey(nil)] }
        set { githubStates[GuestReference.ownerKey(nil)] = newValue }
    }

    func githubState(for deviceId: String?) -> SiloWireGitHubState? { githubStates[GuestReference.ownerKey(deviceId)] }

    /// This Mac's secrets.
    var secrets: [SiloWireSecret] {
        get { secretsByOwner[GuestReference.ownerKey(nil)] ?? [] }
        set { secretsByOwner[GuestReference.ownerKey(nil)] = newValue }
    }

    func secrets(for deviceId: String?) -> [SiloWireSecret] { secretsByOwner[GuestReference.ownerKey(deviceId)] ?? [] }

    /// This Mac's export state.
    var exportState: SiloWireBackupState? {
        get { exportStates[GuestReference.ownerKey(nil)] }
        set { exportStates[GuestReference.ownerKey(nil)] = newValue }
    }

    func exportState(for deviceId: String?) -> SiloWireBackupState? { exportStates[GuestReference.ownerKey(deviceId)] }

    var setupActivity: [SiloWireComputerConfigurationProgress] { setupActivity(for: nil) }

    func setupActivity(for deviceId: String?) -> [SiloWireComputerConfigurationProgress] {
        setupActivityByOwner[GuestReference.ownerKey(deviceId)] ?? []
    }

    func loadGitHubState(deviceId: String?) async {
        do {
            githubStates[GuestReference.ownerKey(deviceId)] = try await client.invoke(
                SiloGeneratedMethods.githubState(SiloWireDeviceParams(deviceId: deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func setGitHubRepositories(_ target: GuestReference, repositories: [String], allowPushes: Bool? = nil) async {
        actionError = nil
        guard let state = githubState(for: target.deviceId) else { return }
        let computerId = target.computerId
        let current = state.computers.first { $0.computerId == computerId }
        let policy = SiloWireGitHubPolicy(
            allRepositoriesAllowChanges: current?.allRepositoriesAllowChanges ?? false,
            authenticationMethod: current?.authenticationMethod ?? .oauth,
            computerId: computerId,
            identity: current?.identity ?? SiloWireGitHubIdentity(apply: false, email: "", name: ""),
            repositories: repositories.map { repository in
                let prior = current?.repositories.first { $0.repository == repository }?.allowPushes ?? false
                return SiloWireGitHubRepositoryPolicy(allowPushes: allowPushes ?? prior, repository: repository)
            },
            repositoryMode: .selected)
        let configuration = SiloWireGitHubConfiguration(baseRevision: state.policyRevision,
                                                           computers: state.computers.filter { $0.computerId != computerId } + [policy])
        do {
            githubStates[target.ownerKey] = try await client.invoke(SiloGeneratedMethods.githubConfigurationSave(
                SiloWireGitHubConfigurationSaveParams(configuration: configuration, deviceId: target.deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func refreshGitHubRepositories(deviceId: String?) async {
        do {
            githubStates[GuestReference.ownerKey(deviceId)] = try await client.invoke(
                SiloGeneratedMethods.githubRepositoriesRefresh(SiloWireDeviceParams(deviceId: deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func setGitHubAccess(_ enabled: Bool, deviceId: String?) async {
        actionError = nil
        do {
            githubStates[GuestReference.ownerKey(deviceId)] = try await client.invoke(SiloGeneratedMethods.githubAccessSet(
                SiloWireGitHubAccessSetParams(deviceId: deviceId, enabled: enabled)))
        } catch { actionError = error.localizedDescription }
    }

    func connectGitHub(deviceId: String?) async {
        actionError = nil
        do {
            let job = try await client.invoke(SiloGeneratedMethods.githubConnect(SiloWireDeviceParams(deviceId: deviceId)))
            await loadGitHubState(deviceId: deviceId)
            if let url = githubState(for: deviceId)?.pendingAuthorizationUrl.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
            await waitForFeatureJob(job.jobId, deviceId: deviceId, label: "Connect GitHub")
            await loadGitHubState(deviceId: deviceId)
        } catch { actionError = error.localizedDescription }
    }

    func reopenGitHubAuthorization(deviceId: String?) async {
        do {
            let result = try await client.invoke(SiloGeneratedMethods.githubConnectReopen(SiloWireDeviceParams(deviceId: deviceId)))
            if let url = URL(string: result.url) { NSWorkspace.shared.open(url) }
        } catch { actionError = error.localizedDescription }
    }

    func manageGitHubRepositories(deviceId: String?) async {
        do {
            let result = try await client.invoke(SiloGeneratedMethods.githubRepositoriesManage(SiloWireDeviceParams(deviceId: deviceId)))
            if let url = URL(string: result.url) { NSWorkspace.shared.open(url) }
        } catch { actionError = error.localizedDescription }
    }

    func disconnectGitHub(deviceId: String?) async {
        actionError = nil
        do {
            githubStates[GuestReference.ownerKey(deviceId)] = try await client.invoke(
                SiloGeneratedMethods.githubDisconnect(SiloWireDeviceParams(deviceId: deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func saveGitHubToken(_ token: String, deviceId: String?) async {
        actionError = nil
        do {
            githubStates[GuestReference.ownerKey(deviceId)] = try await client.invoke(SiloGeneratedMethods.githubPersonalTokenSave(
                SiloWireGitHubPersonalTokenSaveParams(deviceId: deviceId, token: token)))
        } catch { actionError = error.localizedDescription }
    }

    func removeGitHubToken(deviceId: String?) async {
        actionError = nil
        do {
            githubStates[GuestReference.ownerKey(deviceId)] = try await client.invoke(
                SiloGeneratedMethods.githubPersonalTokenRemove(SiloWireDeviceParams(deviceId: deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func retryGitHubConfiguration(_ target: GuestReference) async {
        do {
            githubStates[target.ownerKey] = try await client.invoke(SiloGeneratedMethods.githubConfigurationRetry(
                SiloWireGitHubConfigurationRetryParams(computerId: target.computerId, deviceId: target.deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func loadSSHAccess(_ target: GuestReference) async {
        do {
            let state = try await client.invoke(SiloGeneratedMethods.sshAccessState(SiloWireDeviceParams(deviceId: target.deviceId)))
            sshAccessByComputer[target.key] = state.computers.first { $0.computerId == target.computerId }
        } catch { actionError = error.localizedDescription }
    }

    func saveSSHAccess(_ target: GuestReference, enabled: Bool, port: Int, bindAddress: String, keys: [String]) async {
        actionError = nil
        do {
            let state = try await client.invoke(SiloGeneratedMethods.sshAccessSave(SiloWireSSHAccessSaveParams(
                bindAddress: bindAddress, computerId: target.computerId, deviceId: target.deviceId, enabled: enabled,
                keys: keys, port: port)))
            sshAccessByComputer[target.key] = state.computers.first { $0.computerId == target.computerId }
        } catch { actionError = error.localizedDescription }
    }

    func openSSHAccessConnection(_ target: GuestReference, network: Bool = false) async {
        actionError = nil
        if let reason = ComputerRemoteLimit.terminal.unavailableReason(for: target) { actionError = reason; return }
        do {
            let command = try await client.invoke(SiloGeneratedMethods.sshAccessConnection(
                SiloWireSSHAccessConnectionParams(computerId: target.computerId, deviceId: target.deviceId,
                                                  download: false, network: network)))
            guard let command, !command.isEmpty else {
                throw EngineClientError.invalidAction("The engine did not return an SSH command.")
            }
            try openTerminal(command: command)
        } catch { actionError = error.localizedDescription }
    }

    func loadSecrets(deviceId: String?) async {
        do {
            secretsByOwner[GuestReference.ownerKey(deviceId)] = try await client.invoke(
                SiloGeneratedMethods.secretsList(SiloWireDeviceParams(deviceId: deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    /// Saves a secret on the device that owns the computers it is assigned to (`computerIds` are that device's ids).
    func saveSecret(id: String?, name: String, value: String?, computerIds: [String], allowedDomains: [String],
                    allowAnyDestination: Bool, deviceId: String?) async {
        guard ComputerSecretValidation.name(name) else {
            actionError = "Choose a valid secret name. Use letters, numbers and underscores, starting with a letter or underscore."
            return
        }
        guard ComputerSecretValidation.domains(allowedDomains, allowAnyDestination: allowAnyDestination) else {
            actionError = "Choose one or more valid lowercase destination hosts. Confirm * to allow every HTTPS destination."
            return
        }
        if id == nil, let value {
            guard !value.isEmpty, value.utf8.count <= 65_536, !value.utf8.contains(0) else {
                actionError = "Enter a secret value of 1 to 65536 bytes without null characters."
                return
            }
        } else if id == nil {
            actionError = "Enter a secret value."
            return
        } else if let value, (value.isEmpty || value.utf8.count > 65_536 || value.utf8.contains(0)) {
            actionError = "Use a secret value of 1 to 65536 bytes without null characters, or leave it blank to keep the current value."
            return
        }
        guard (1...100).contains(computerIds.count) else {
            actionError = "Assign a secret to between 1 and 100 computers."
            return
        }
        actionError = nil
        let request = SiloWireSecretSaveRequest(allowAnyDestination: allowAnyDestination,
                                                allowedDomains: allowedDomains, computerIds: computerIds,
                                                id: id, name: name,
                                                operation: id == nil ? .add : .edit, value: value)
        do {
            secretsByOwner[GuestReference.ownerKey(deviceId)] = try await client.invoke(
                SiloGeneratedMethods.secretsSave(SiloWireSecretsSaveParams(deviceId: deviceId, request: request)))
        } catch { actionError = error.localizedDescription }
    }

    func removeSecret(id: String, deviceId: String?) async {
        do {
            secretsByOwner[GuestReference.ownerKey(deviceId)] = try await client.invoke(
                SiloGeneratedMethods.secretsRemove(SiloWireSecretIdParams(deviceId: deviceId, id: id)))
        } catch { actionError = error.localizedDescription }
    }

    func retrySecret(id: String, deviceId: String?) async {
        do {
            secretsByOwner[GuestReference.ownerKey(deviceId)] = try await client.invoke(
                SiloGeneratedMethods.secretsRetry(SiloWireSecretIdParams(deviceId: deviceId, id: id)))
        } catch { actionError = error.localizedDescription }
    }

    func loadComputerUse(_ target: GuestReference) async {
        do {
            computerUseByComputer[target.key] = try await client.invoke(SiloGeneratedMethods.computerUseState(
                SiloWireComputerUseStateParams(computerId: target.computerId, deviceId: target.deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func setComputerUseApproval(_ target: GuestReference, automatic: Bool) async {
        actionError = nil
        do {
            computerUseByComputer[target.key] = try await client.invoke(SiloGeneratedMethods.computerUseApproval(
                SiloWireComputerUseApprovalParams(computerId: target.computerId, deviceId: target.deviceId,
                                                  mode: automatic ? .auto : .ask)))
        } catch { actionError = error.localizedDescription }
    }

    func setupComputerUse(_ target: GuestReference) async {
        do {
            let result = try await client.invoke(SiloGeneratedMethods.computerUseSetup(Self.reference(target)))
            await waitForFeatureJob(result.jobId, deviceId: target.deviceId, label: "Set up computer use")
            await loadComputerUse(target)
        } catch { actionError = error.localizedDescription }
    }

    func agentTools(for target: GuestReference) -> SiloWireAgentToolsStatus? { agentToolsByKey[target.key] }

    func isSettingUpAgentTools(_ target: GuestReference) -> Bool { agentToolsSetupMessage[target.key] != nil }

    func loadAgentTools(_ target: GuestReference) async {
        do {
            if let status = try await AgentToolsSetup(engine: client).status(target) {
                agentToolsByKey[target.key] = status
            } else {
                agentToolsByKey[target.key] = nil
            }
            agentToolsError[target.key] = nil
        } catch { agentToolsError[target.key] = error.localizedDescription }
    }

    /// Sets the tools up (or updates them) as a job, with its progress in `agentToolsSetupMessage`.
    func setUpAgentTools(_ target: GuestReference, computerName: String) async {
        guard !isSettingUpAgentTools(target) else { return }
        agentToolsError[target.key] = nil
        defer { agentToolsSetupMessage[target.key] = nil }
        do {
            let status = try await AgentToolsSetup(engine: client).setUp(target, computerName: computerName) { [weak self] message in
                self?.agentToolsSetupMessage[target.key] = message
            }
            if let status { agentToolsByKey[target.key] = status }
            if let status, AgentToolsAdvice.needsSetup(status) {
                agentToolsError[target.key] = AgentToolsFailure.stillNotReady(computerName).localizedDescription
            }
        } catch { agentToolsError[target.key] = error.localizedDescription }
    }

    func loadLogs(_ target: GuestReference, query: String? = nil, cursor: String? = nil,
                  source: SiloWireLogSource? = nil, since: String? = nil, until: String? = nil,
                  aroundId: String? = nil, follow: String? = nil) async {
        let key = target.key
        do {
            let page = try await client.invoke(SiloGeneratedMethods.logsQuery(
                SiloWireLogsQueryParams(aroundId: aroundId, computerId: target.computerId, cursor: cursor,
                                        deviceId: target.deviceId, follow: follow, limit: 100, query: query, since: since,
                                        source: source, until: until)))
            if let follow, var previous = logsByComputer[key], previous.snapshot == follow {
                let knownIDs = Set(previous.entries.map(\.id))
                previous.entries.append(contentsOf: page.entries.filter { !knownIDs.contains($0.id) })
                previous.newestAvailableTimestamp = page.newestAvailableTimestamp ?? previous.newestAvailableTimestamp
                previous.oldestAvailableTimestamp = page.oldestAvailableTimestamp ?? previous.oldestAvailableTimestamp
                previous.nextCursor = page.nextCursor ?? previous.nextCursor
                previous.snapshot = page.snapshot ?? previous.snapshot
                previous.totalMatches = page.totalMatches
                previous.timestampEstimated = previous.timestampEstimated || page.timestampEstimated
                previous.unreadableRecords = previous.unreadableRecords == true || page.unreadableRecords == true
                previous.unsupported = page.unsupported ?? previous.unsupported
                logsByComputer[key] = previous
            } else if cursor != nil, var previous = logsByComputer[key], previous.snapshot == page.snapshot {
                previous.entries.append(contentsOf: page.entries)
                previous.nextCursor = page.nextCursor
                previous.totalMatches = page.totalMatches
                previous.oldestAvailableTimestamp = page.oldestAvailableTimestamp
                previous.unreadableRecords = page.unreadableRecords
                previous.timestampEstimated = page.timestampEstimated
                logsByComputer[key] = previous
            } else {
                logsByComputer[key] = page
            }
        } catch { actionError = error.localizedDescription }
    }

    /// Exports a computer's logs. The file is written on this Mac; the pages are read from the device that owns the computer.
    func exportLogs(_ target: GuestReference, destination: String, query: String? = nil,
                    source: SiloWireLogSource? = nil, since: String? = nil, until: String? = nil,
                    aroundId: String? = nil) async {
        let request = SiloWireLogsQueryParams(aroundId: aroundId, computerId: target.computerId, deviceId: target.deviceId,
                                              limit: 100, query: query, since: since, source: source, until: until)
        await perform("Export logs", on: nil) {
            try await self.client.invoke(SiloGeneratedMethods.logsExport(SiloWireLogsExportParams(
                destination: destination, requests: [request])))
        }
    }

    func loadStorage(_ target: GuestReference) async {
        do {
            storageByComputer[target.key] = try await client.invoke(SiloGeneratedMethods.storageRead(
                SiloWireStorageParams(computerId: target.computerId, deviceId: target.deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func reclaimStorage(_ target: GuestReference) async {
        let params = SiloWireStorageParams(computerId: target.computerId, deviceId: target.deviceId)
        await perform("Reclaim storage", on: target.deviceId) { try await self.client.invoke(SiloGeneratedMethods.storageReclaim(params)) }
        await loadStorage(target)
    }

    func loadExportState(deviceId: String?) async {
        do {
            exportStates[GuestReference.ownerKey(deviceId)] = try await client.invoke(
                SiloGeneratedMethods.exportsState(SiloWireExportStateParams(deviceId: deviceId)))
        } catch { actionError = error.localizedDescription }
    }

    func acknowledgeExportResult(deviceId: String?) async {
        guard let operationId = exportState(for: deviceId)?.operationId else { return }
        do {
            _ = try await client.invoke(SiloGeneratedMethods.exportsAcknowledge(
                SiloWireExportAcknowledgeParams(deviceId: deviceId, expectedOperationId: operationId)))
            await loadExportState(deviceId: deviceId)
        } catch { actionError = error.localizedDescription }
    }

    func dismissExportOperation(_ operation: SiloWireOperationClass, deviceId: String?) async {
        guard let operationId = exportState(for: deviceId)?.operationId else { return }
        do {
            let dismissed = try await client.invoke(SiloGeneratedMethods.exportsDismiss(
                SiloWireExportDismissParams(deviceId: deviceId, expectedOperation: operation.backupOperation,
                                            expectedOperationId: operationId)))
            if !dismissed { actionError = "The export result changed before Fjord could dismiss it." }
            await loadExportState(deviceId: deviceId)
        } catch { actionError = error.localizedDescription }
    }

    /// Sets the folder exports are written to, a path on the device that owns the computers.
    func setExportDestination(_ path: String, deviceId: String?) async {
        do {
            _ = try await client.invoke(SiloGeneratedMethods.exportsDestinationSet(
                SiloWireExportDestinationSetParams(deviceId: deviceId, path: path)))
            await loadExportState(deviceId: deviceId)
        } catch { actionError = error.localizedDescription }
    }

    func exportComputer(_ target: GuestReference, checkpointId: String? = nil) async {
        guard let destination = exportState(for: target.deviceId)?.destination else {
            actionError = "Choose an export folder first."
            return
        }
        let params = SiloWireExportCreateParams(checkpointId: checkpointId, computerIds: [target.computerId],
                                                destination: destination, deviceId: target.deviceId)
        await perform("Export computer", on: target.deviceId) { try await self.client.invoke(SiloGeneratedMethods.exportsCreate(params)) }
        await loadExportState(deviceId: target.deviceId)
    }

    func inspectExportArchive(path: String, deviceId: String?) async {
        archiveInspection = nil
        do {
            let job = try await client.invoke(SiloGeneratedMethods.exportsInspect(
                SiloWireExportInspectParams(archivePath: path, deviceId: deviceId)))
            let key = ComputerJobKey.make(deviceId: deviceId, jobId: job.jobId)
            jobActions[key] = "Inspect export archive"
            let outcome = try await waitForFinish(job.jobId, deviceId: deviceId)
            presentJobOutcome(outcome, action: "Inspect export archive", deviceId: deviceId)
            guard let result = outcome.result else {
                throw EngineClientError.invalidAction("The engine returned no archive inspection result.")
            }
            let data = try JSONEncoder().encode(result)
            archiveInspection = try JSONDecoder().decode(SiloWireArchiveInspectionResult.self, from: data)
        } catch { actionError = error.localizedDescription }
    }

    func importComputer(archivePath: String, newName: String, sourceName: String? = nil, deviceId: String?) async {
        guard ComputerName.isValid(newName),
              let inspection = archiveInspection, inspection.valid, inspection.archive.archivePath == archivePath else {
            actionError = "Inspect a valid archive and choose a valid computer name first."
            return
        }
        let selectedSource = sourceName ?? (inspection.archive.computers.count == 1 ? inspection.archive.computers.first : nil)
        guard let selectedSource, inspection.archive.computers.contains(selectedSource) else {
            actionError = "Choose which computer to import from this archive."
            return
        }
        let params = SiloWireExportImportParams(archivePath: archivePath, deviceId: deviceId, newName: newName,
                                                sourceName: selectedSource)
        await perform("Import computer", on: deviceId) { try await self.client.invoke(SiloGeneratedMethods.exportsImport(params)) }
        await loadExportState(deviceId: deviceId)
    }

    func loadConnections() async {
        do {
            connectionsStatus = try await client.invoke(SiloGeneratedMethods.connectionsStatus(SiloWireEmptyParams()))
            let devices = try await client.invoke(SiloGeneratedMethods.connectionsDevicesList(SiloWireEmptyParams()))
            connectionDevices = devices
            let health = try await client.invoke(SiloGeneratedMethods.connectionsDevicesHealth(SiloWireEmptyParams()))
            connectionHealth = Dictionary(uniqueKeysWithValues: health.devices.map { ($0.deviceId, $0) })
        } catch { actionError = error.localizedDescription }
    }

    func connectDevice(address: String, replace: Bool = false) async {
        actionError = nil
        do {
            _ = try await client.invoke(SiloGeneratedMethods.connectionsDevicesConnect(
                SiloWireConnectDeviceParams(address: address, replace: replace ? true : nil)))
            await loadConnections()
        } catch { actionError = error.localizedDescription }
    }

    func removeDevice(id: String) async {
        actionError = nil
        do {
            // The canonical remove operation revokes this controller's key on the owner before local cleanup (95 A-36).
            try await client.invoke(SiloGeneratedMethods.connectionsDevicesRemove(SiloWireDeviceIdParams(deviceId: id)))
            await loadConnections()
        } catch { actionError = error.localizedDescription }
    }

    func setConnectionsEnabled(_ enabled: Bool) async {
        actionError = nil
        do {
            connectionsStatus = try await client.invoke(SiloGeneratedMethods.connectionsSetEnabled(
                SiloWireConnectionsSetEnabledParams(enabled: enabled)))
        } catch { actionError = error.localizedDescription }
    }

    func sshAuthorizationCommand(address: String) async {
        actionError = nil
        do {
            let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await client.invoke(SiloGeneratedMethods.connectionsSshAuthorizationCommand(
                SiloWireSSHAddressParams(address: address)))
            try openTerminal(command: result.command)
        } catch { actionError = error.localizedDescription }
    }

    func sshKeySetupCommand(address: String) async {
        actionError = nil
        do {
            let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await client.invoke(SiloGeneratedMethods.connectionsSshKeySetupCommand(
                SiloWireSSHAddressParams(address: address)))
            try openTerminal(command: result.command)
        } catch { actionError = error.localizedDescription }
    }

    func openTerminal(command: String) throws {
        guard !command.isEmpty, command.utf8.count <= 8192,
              !command.contains("\n"), !command.contains("\r") else {
            throw EngineClientError.invalidAction("Fjord received an invalid SSH setup command.")
        }
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "tell application \"Terminal\" to do script \"\(escaped)\"") else {
            throw EngineClientError.invalidAction("Fjord couldn't open Terminal.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if error != nil { throw EngineClientError.invalidAction("Terminal couldn't run the SSH setup command.") }
    }

    func openScreen(for target: GuestReference) async {
        let requestID = UUID()
        viewerRequestID = requestID
        guard let computer = row(target) else { return }
        if computer.kind == .macos {
            await showDisplay(target)
            return
        }

        await viewerOperationGate.acquire()
        defer { viewerOperationGate.release() }
        guard viewerRequestID == requestID else { return }
        do {
            if let existingViewer = pendingViewer {
                try await closeViewerConnection(existingViewer)
                guard viewerRequestID == requestID else { return }
            }
            let viewer = try await client.invoke(SiloGeneratedMethods.displayViewerOpen(Self.reference(target)))
            guard let url = URL(string: viewer.url), url.scheme == "http", url.host == "127.0.0.1",
                  url.port != nil, viewer.cookie.domain == "127.0.0.1", viewer.cookie.path.hasPrefix("/"),
                  viewer.cookie.httpOnly else {
                throw EngineClientError.invalidAction("The engine returned an unsafe Linux viewer connection.")
            }
            guard viewerRequestID == requestID else {
                try await closeViewerConnection(viewer)
                return
            }
            pendingViewer = viewer
        } catch {
            if viewerRequestID == requestID { actionError = error.localizedDescription }
        }
    }

    func closeScreen() async {
        let requestID = UUID()
        viewerRequestID = requestID
        guard pendingViewer != nil else { return }
        await viewerOperationGate.acquire()
        defer { viewerOperationGate.release() }
        guard viewerRequestID == requestID, let viewer = pendingViewer else { return }
        do {
            try await closeViewerConnection(viewer)
        } catch {
            if viewerRequestID == requestID { actionError = error.localizedDescription }
        }
    }

    private func closeViewerConnection(_ viewer: SiloWireViewerOpenResult) async throws {
        try await client.invoke(SiloGeneratedMethods.displayViewerClose(
            SiloWireViewerConnectionParams(connectionId: viewer.connectionId)))
        viewerScripts[viewer.connectionId] = nil
        if pendingViewer?.connectionId == viewer.connectionId { pendingViewer = nil }
    }

    private func waitForFeatureJob(_ jobId: String, deviceId: String?, label: String) async {
        jobActions[ComputerJobKey.make(deviceId: deviceId, jobId: jobId)] = label
        do {
            let outcome = try await waitForFinish(jobId, deviceId: deviceId)
            presentJobOutcome(outcome, action: label, deviceId: deviceId)
        }
        catch { actionError = error.localizedDescription }
    }
}

extension SiloWireConfiguration {
    /// The optimistic-check baseline of a Linux edit: the generated union shares one `expected` type
    /// between Linux (the whole configuration) and macOS (cpus, memory, disk).
    init(_ configuration: ComputerConfiguration) {
        self.init(cpus: UInt64(configuration.cpus), desktop: configuration.desktop, id: configuration.id,
                  maxCPUs: configuration.maxCPUs, maxMemoryGiB: configuration.maxMemoryGiB,
                  memoryGiB: UInt64(configuration.memoryGiB), name: configuration.name,
                  runtimeStorageGiB: configuration.runtimeStorageGiB,
                  workspaceStorageGiB: configuration.workspaceStorageGiB)
    }
}
