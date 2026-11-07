import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite struct ComputersTests {
    @Test func quitPromptNamesOnlyRunningComputers() throws {
        let prompt = try #require(ComputerQuitPrompt.make(inventory: MockEngineClient.demoInventory))
        #expect(prompt.runningComputers.map(\.name) == ["dev", "linux-1"])
        #expect(prompt.message == "Quit Fjord? 2 computers are running: dev, linux-1.")
    }

    @Test func noPromptWhenEveryComputerIsStopped() throws {
        var inventory = MockEngineClient.demoInventory
        inventory.linux.computers = inventory.linux.computers.map { row in
            var row = row
            row.state = .stopped
            row.stateDetail = "Stopped"
            return row
        }
        inventory.macos.computers = inventory.macos.computers.map { row in
            var row = row
            row.state = .stopped
            return row
        }
        #expect(ComputerQuitPrompt.make(inventory: inventory) == nil)
    }

    @Test func creationLimitsComeFromHostCapacityAndMacTemplateDiskFloor() throws {
        let facts = DeviceFacts(
            deviceCapacity: DeviceCapacity(logicalCpus: 8, physicalMemoryBytes: 17_179_869_184, maxMemoryGib: 12),
            macosHostLimits: MacosHostLimits(cpus: 8, memory_gib: 32), remoteLogin: .unknown)
        let linux = try ComputerResourceLimits.linux(from: facts)
        #expect(linux.maxCPUs == 8)
        #expect(linux.maxMemoryGiB == 12)
        #expect(linux.defaultCPUs == 2)
        #expect(linux.defaultMemoryGiB == 4)

        let macos = try ComputerResourceLimits.macos(from: facts, minimumDiskGiB: 64)
        #expect(macos.minCPUs == 2)
        #expect(macos.maxCPUs == 8)
        #expect(macos.minMemoryGiB == 4)
        #expect(macos.maxMemoryGiB == 28)
        #expect(macos.minDiskGiB == 64)
        #expect(macos.maxDiskGiB == 1024)
        #expect(macos.defaultCPUs == 4)
        #expect(macos.defaultMemoryGiB == 16)
    }

    @Test func automaticCheckpointRetentionCanBeTurnedOff() async {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        await model.loadSettings()

        await model.updateAutomaticCheckpointRetention(7)
        #expect(client.settingsSnapshot.settings.automaticCheckpointRetentionCount == 7)

        await model.updateAutomaticCheckpointRetention(0)

        #expect(client.settingsSnapshot.settings.automaticCheckpointRetentionCount == 0)
        #expect(client.generatedCalls.contains("settings.update"))
        #expect(model.actionError == nil)
    }

    @Test func settingsChangedEventRefreshesLoadedComputerDefaults() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()
        await model.loadSettings()

        var patch = SiloWireSettingsValues()
        patch.automaticCheckpointRetentionCount = 9
        _ = try await client.invoke(SiloGeneratedMethods.settingsUpdate(SiloWireSettingsUpdateParams(patch: patch)))

        #expect(model.engineSettings?.settings.automaticCheckpointRetentionCount == 9)
    }

    @Test func modelCreationUsesHostDerivedLinuxAndMacLimits() async {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)

        await model.createLinuxComputer(name: "linux-host-limit", cpus: 16, memoryGiB: 64)
        await model.createMacosComputer(name: "mac-host-limit", cpus: 16, memoryGiB: 60, diskGiB: 64)

        #expect(client.createRequests.count == 2)
        #expect(client.createRequests[0].configuration?.maxCPUs == 16)
        #expect(client.createRequests[0].configuration?.maxMemoryGiB == 64)
        #expect(client.createRequests[1].request?.cpus == 16)
        #expect(client.createRequests[1].request?.memoryGiB == 60)
        #expect(client.createRequests[1].request?.diskGiB == 64)
        #expect(model.actionError == nil)
    }

    @Test func resourceEditStopsRunningLinuxComputerBeforeApplyingCpuAndMemory() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()

        await model.updateResources(for: .thisMac(MockEngineClient.linuxID), cpus: 3, memoryGiB: 10)

        #expect(client.stopRequests == [MockEngineClient.linuxID])
        #expect(client.inventory.computer(MockEngineClient.linuxID)?.resources == "3 CPU · 10 GB memory")
        #expect(client.generatedCalls.contains("computers.configuration.change"))
        #expect(model.actionError == nil)
    }

    @Test func resourceEditPreservesACompetingConfigurationChangeDuringStop() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()
        let computerID = MockEngineClient.linuxID
        var competingInventory = client.inventory
        let index = try #require(competingInventory.linux.computers.firstIndex { $0.id == computerID })
        var competingConfiguration = competingInventory.linux.computers[index].configuration
        competingConfiguration.cpus = 6
        competingConfiguration.memoryGiB = 12
        competingInventory.linux.computers[index].configuration = competingConfiguration

        let edit = Task { await model.updateResources(for: .thisMac(computerID), cpus: 3, memoryGiB: 10) }
        await waitUntil { client.stopRequests == [computerID] }
        client.replaceInventory(competingInventory)
        await edit.value

        #expect(client.inventory.computer(computerID)?.resources == "6 CPU · 12 GB memory")
        #expect(model.actionError?.localizedCaseInsensitiveContains("changed") == true)
    }

    @Test func overlappingViewerOpensCloseTheSupersededConnection() async throws {
        let client = MockEngineClient()
        client.nextViewerOpenResults = [viewerResult("viewer-first"), viewerResult("viewer-second")]
        client.suspendNextViewerOpen = true
        let model = ComputersModel(client: client, initialInventory: client.inventory)

        let firstOpen = Task { await model.openScreen(for: .thisMac(MockEngineClient.linuxID)) }
        await client.waitForSuspendedViewerOpen()
        let secondOpen = Task { await model.openScreen(for: .thisMac(MockEngineClient.linuxID)) }
        client.resumeSuspendedViewerOpen()
        await firstOpen.value
        await secondOpen.value

        #expect(client.viewerOpenRequests == [MockEngineClient.linuxID, MockEngineClient.linuxID])
        #expect(model.pendingViewer?.connectionId == "viewer-second")
        #expect(client.viewerCloseRequests == ["viewer-first"])

        await model.closeScreen()

        #expect(client.viewerCloseRequests == ["viewer-first", "viewer-second"])
        #expect(model.pendingViewer == nil)
    }

    @Test func closingWhileViewerOpenIsPendingClosesTheLateConnection() async {
        let client = MockEngineClient()
        client.nextViewerOpenResults = [viewerResult("viewer-late")]
        client.suspendNextViewerOpen = true
        let model = ComputersModel(client: client, initialInventory: client.inventory)

        let opening = Task { await model.openScreen(for: .thisMac(MockEngineClient.linuxID)) }
        await client.waitForSuspendedViewerOpen()
        await model.closeScreen()
        client.resumeSuspendedViewerOpen()
        await opening.value

        #expect(model.pendingViewer == nil)
        #expect(client.viewerCloseRequests == ["viewer-late"])
    }

    private func viewerResult(_ connectionId: String) -> SiloWireViewerOpenResult {
        SiloWireViewerOpenResult(connectionId: connectionId,
            cookie: SiloWireViewerCookie(domain: "127.0.0.1", httpOnly: true,
                                         name: "silo-viewer", path: "/", value: "demo"),
            initScript: "", name: connectionId, url: "http://127.0.0.1:5099/")
    }

    private func stoppedMacosInventory() -> ComputerInventory {
        var inventory = MockEngineClient.demoInventory
        inventory.macos.computers = inventory.macos.computers.map { computer in
            var computer = computer
            computer.state = .stopped
            computer.progress = nil
            computer.detail = nil
            computer.displayOpen = false
            return computer
        }
        return inventory
    }

    @Test func macosResourceEditSendsTheExpectedBaselineAndNewValues() async throws {
        let inventory = stoppedMacosInventory()
        let client = MockEngineClient(inventory: inventory)
        let model = ComputersModel(client: client, initialInventory: inventory)
        let before = try #require(inventory.macos.computers.first { $0.id == MockEngineClient.devID })

        await model.updateResources(for: .thisMac(MockEngineClient.devID), cpus: 6, memoryGiB: 20)

        #expect(model.actionError == nil)
        #expect(client.generatedCalls.contains("computers.configuration.change"))
        let sent = try #require(client.lastConfigurationChange)
        #expect(sent.kind == .macosResources)
        #expect(sent.computerId == MockEngineClient.devID)
        #expect(sent.expected?.cpus == before.cpus)
        #expect(sent.expected?.memoryGiB == before.memoryGiB)
        #expect(sent.expected?.diskGiB == before.diskGiB)
        #expect(sent.cpus == 6)
        #expect(sent.memoryGiB == 20)
        #expect(sent.requestId?.isEmpty == false)
        let after = try #require(client.inventory.macos.computers.first { $0.id == MockEngineClient.devID })
        #expect(after.cpus == 6 && after.memoryGiB == 20 && after.diskGiB == before.diskGiB)
    }

    @Test func staleMacosResourceBaselineIsRejectedByTheMock() async throws {
        let inventory = stoppedMacosInventory()
        let client = MockEngineClient(inventory: inventory)
        let change = SiloWireComputerConfigurationChange(
            expected: SiloWireConfiguration(cpus: 1, memoryGiB: 1, diskGiB: 1), kind: .macosResources,
            computerId: MockEngineClient.devID, cpus: 4, memoryGiB: 8, requestId: "r1")
        await #expect(throws: EngineClientError.self) {
            _ = try await client.invoke(SiloGeneratedMethods.computersConfigurationChange(
                SiloWireComputerConfigurationChangeParams(change: change, requestId: "r1")))
        }
    }

    @Test func newStableErrorCodesHaveClearMessages() {
        let cases: [(String, String)] = [
            ("not_running", "isn't running"), ("needs_personalizing", "personalizing"), ("setup_incomplete", "setup"),
            ("screen_sharing_unavailable", "Screen sharing"), ("running_limit", "Too many computers"),
            ("desktop_update_required", "Update desktop"), ("permission_denied", "permission"),
            ("output_too_large", "too large"),
        ]
        for (code, fragment) in cases {
            let job = OperationJobError(code: code, message: "raw engine text")
            #expect(job.userMessage.contains(fragment), "\(code): \(job.userMessage)")
            #expect(!job.userMessage.contains("raw engine text"))
            #expect(EngineClientError.coded(code: code, message: "raw").errorDescription?.contains(fragment) == true)
        }
        #expect(OperationJobError(code: "timed_out", message: "It timed out.").userMessage == "It timed out.")
    }

    @Test func failedJobsShowTheMappedMessageInTheReceipt() async throws {
        let client = MockEngineClient()
        client.nextJobFailure = OperationJobError(code: "running_limit", message: "limit 2")
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()

        await model.start(.thisMac(MockEngineClient.failedID))

        #expect(model.actionError == "Start failed: Too many computers are running at once. Stop one, then try again.")
        #expect(model.currentJobReceipt?.message.contains("Too many computers") == true)
    }

    @Test func checkpointKindComesFromTheEngineField() throws {
        // A name without the legacy suffix still reads as automatic when the field says so.
        let automatic = ComputerCheckpoint(id: "a", name: "Before run: x", createdAt: "2026-10-14T10:00:00Z",
                                           scope: .disk, reason: .manual, kind: .automatic, sizeBytes: nil)
        let manual = ComputerCheckpoint(id: "m", name: "Before run: x, deleted automatically",
                                        createdAt: "2026-10-14T10:00:00Z", scope: .disk, reason: .manual,
                                        kind: .manual, sizeBytes: nil)
        #expect(automatic.kindLabel == "Automatic")
        #expect(manual.kindLabel == "Manual")
        #expect(manual.displayName == "Before run: x, deleted automatically")
        let decoded = try JSONDecoder().decode(ComputerCheckpoint.self, from: Data(
            #"{"createdAt":"2026-10-14T10:00:00Z","id":"c","kind":"automatic","name":"n","reason":"manual","scope":"full"}"#.utf8))
        #expect(decoded.kind == .automatic)
    }

    @Test func failedConnectedMacRemovalKeepsDeviceUntilKeyRevocationSucceeds() async {
        let client = MockEngineClient()
        let device = SiloWireDevice(address: "alice@studio.local", id: "owner-device", name: "Studio Mac")
        client.connectedDevices = [device]
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        await model.loadConnections()
        client.nextConnectionRemovalError = "The owner Mac is offline."

        await model.removeDevice(id: device.id)

        #expect(model.connectionDevices == [device])
        #expect(client.revokedDeviceIDs.isEmpty)
        #expect(model.actionError == "The owner Mac is offline.")
    }

    @Test func successfulConnectedMacRemovalRecordsKeyRevocation() async {
        let client = MockEngineClient()
        let device = SiloWireDevice(address: "alice@studio.local", id: "owner-device", name: "Studio Mac")
        client.connectedDevices = [device]
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        await model.loadConnections()

        await model.removeDevice(id: device.id)

        #expect(client.revokedDeviceIDs == [device.id])
        #expect(model.connectionDevices.isEmpty)
    }

    @Test func hiddenLinuxDesktopPortCannotBePublishedAndWildcardSecretsRequireAcknowledgment() async {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)

        await model.publishPort(.thisMac(MockEngineClient.linuxID), port: ComputerNetworkPolicy.hiddenDesktopPort)
        #expect(!client.generatedCalls.contains("network.publish"))
        #expect(model.actionError?.contains("stays private") == true)

        await model.publishPort(.thisMac("missing-computer"), port: ComputerNetworkPolicy.hiddenDesktopPort)
        #expect(!client.generatedCalls.contains("network.publish"))
        #expect(model.actionError?.contains("no longer available") == true)

        await model.saveSecret(id: nil, name: "BUILD_TOKEN", value: "secret-value",
                               computerIds: [MockEngineClient.linuxID], allowedDomains: ["*"],
                               allowAnyDestination: false, deviceId: nil)
        #expect(!client.generatedCalls.contains("secrets.save"))
        #expect(model.actionError?.contains("lowercase destination hosts") == true)

        await model.saveSecret(id: nil, name: "BUILD_TOKEN", value: "secret-value",
                               computerIds: [MockEngineClient.linuxID], allowedDomains: ["*"],
                               allowAnyDestination: true, deviceId: nil)
        #expect(client.generatedCalls.contains("secrets.save"))
        #expect(model.actionError == nil)
    }

    @Test func repositoryPolicyAndComputerUseApprovalUseGeneratedMethods() async {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        await model.loadGitHubState(deviceId: nil)

        await model.setGitHubRepositories(.thisMac(MockEngineClient.devID),
                                          repositories: ["fjord/lookout"], allowPushes: true)
        await model.setComputerUseApproval(.thisMac(MockEngineClient.devID), automatic: true)

        #expect(model.githubState?.computers.first { $0.computerId == MockEngineClient.devID }?.repositories
            == [SiloWireGitHubRepositoryPolicy(allowPushes: true, repository: "fjord/lookout")])
        #expect(model.computerUseByComputer[GuestReference.thisMac(MockEngineClient.devID).key]?.approval == .auto)
        #expect(client.generatedCalls.contains("github.configuration.save"))
        #expect(client.generatedCalls.contains("computerUse.approval"))
    }

    @Test func exportInspectionReturnsMockedArchiveValidityToTheModel() async {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)

        await model.inspectExportArchive(path: "/tmp/demo.silo-backup", deviceId: nil)

        #expect(model.archiveInspection?.valid == true)
        #expect(model.archiveInspection?.archive.computers == ["linux-1"])
        #expect(client.generatedCalls.contains("exports.inspect"))
        #expect(model.actionError == nil)
    }

    @Test func exportAndImportUseTheChosenDestinationAndInspectedComputer() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()

        await model.setExportDestination("/tmp/fjord-exports", deviceId: nil)
        await model.exportComputer(.thisMac(MockEngineClient.linuxID))
        let archive = try #require(model.exportState?.archives.first)
        await model.inspectExportArchive(path: archive.archivePath, deviceId: nil)
        await model.importComputer(archivePath: archive.archivePath, newName: "linux-copy", sourceName: "linux-1", deviceId: nil)

        #expect(model.exportState?.destination == "/tmp/fjord-exports")
        #expect(model.inventory?.allComputers.contains { $0.name == "linux-copy" } == true)
        #expect(client.generatedCalls.contains("exports.create"))
        #expect(client.generatedCalls.contains("exports.inspect"))
        #expect(client.generatedCalls.contains("exports.import"))
        #expect(client.acknowledgedJobs.isEmpty)
        #expect(model.currentJobReceipt?.action == "Export computer")
        while let jobId = model.jobAwaitingAcknowledgement {
            await model.acknowledgePresentedJob(jobId)
        }
        #expect(client.acknowledgedJobs.count == 3)
        #expect(model.actionError == nil)
    }

    @Test func exportResultCanBeMarkedSeenAndDismissedAgainstItsSnapshot() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()

        await model.setExportDestination("/tmp/fjord-exports", deviceId: nil)
        await model.exportComputer(.thisMac(MockEngineClient.linuxID))
        let result = try #require(model.exportState?.operation)
        #expect(result.kind == .result)
        #expect(model.exportState?.resultUnseen == true)

        await model.acknowledgeExportResult(deviceId: nil)
        #expect(model.exportState?.resultUnseen == false)
        #expect(client.generatedCalls.contains("exports.acknowledge"))

        await model.dismissExportOperation(result, deviceId: nil)
        #expect(model.exportState?.operation == nil)
        #expect(client.generatedCalls.contains("exports.dismiss"))
        #expect(model.actionError == nil)
    }

    @Test func mockFileTransferShowsUploadsInThePagedBrowseState() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)

        await model.loadFiles(.thisMac(MockEngineClient.linuxID))
        await model.uploadFiles(.thisMac(MockEngineClient.linuxID), directory: "/workspace", paths: ["/tmp/notes.txt"])
        await model.downloadFile(.thisMac(MockEngineClient.linuxID), path: "/workspace/notes.txt", destination: "/tmp/notes-copy.txt")

        #expect(model.fileLists[GuestReference.thisMac(MockEngineClient.linuxID).key]?.entries.contains { $0.name == "notes.txt" } == true)
        #expect(client.generatedCalls.contains("files.list"))
        #expect(client.generatedCalls.contains("files.upload"))
        #expect(client.generatedCalls.contains("files.download"))
        #expect(client.jobGetCallCount > 0)
        #expect(client.acknowledgedJobs.isEmpty)
        #expect(model.currentJobReceipt?.action == "Upload files")
        let firstReceipt = try #require(model.jobAwaitingAcknowledgement)
        await model.acknowledgePresentedJob(firstReceipt)
        #expect(model.currentJobReceipt?.action == "Download file")
        while let jobId = model.jobAwaitingAcknowledgement {
            await model.acknowledgePresentedJob(jobId)
        }
        #expect(client.acknowledgedJobs.count == 2)
        #expect(model.actionError == nil)
    }

    @Test func logsFollowUsesSnapshotAndAppendsOnlyNewEntries() async {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)

        await model.loadLogs(.thisMac(MockEngineClient.linuxID), query: "ready", source: .runtime,
                             since: "2026-10-01T00:00:00Z", until: "2026-10-14T00:00:00Z", aroundId: "anchor")
        await model.loadLogs(.thisMac(MockEngineClient.linuxID), query: "ready", source: .runtime,
                             since: "2026-10-01T00:00:00Z", until: "2026-10-14T00:00:00Z", aroundId: "anchor",
                             follow: "mock-log-snapshot-1")

        #expect(client.logFollowRequests == [nil, "mock-log-snapshot-1"])
        #expect(model.logsByComputer[GuestReference.thisMac(MockEngineClient.linuxID).key]?.entries.map(\.line) == ["Computer ready", "New output"])
        #expect(model.logsByComputer[GuestReference.thisMac(MockEngineClient.linuxID).key]?.snapshot == "mock-log-snapshot-2")
    }

    @Test func normalQuitSkipsComputerInspectionWhenComputersAreOffOrEngineIsAbsent() {
        #expect(!AppTermination.shouldInspectComputers(computersEnabled: false, engineAvailable: true))
        #expect(!AppTermination.shouldInspectComputers(computersEnabled: true, engineAvailable: false))
        #expect(AppTermination.shouldInspectComputers(computersEnabled: true, engineAvailable: true))
    }

    @Test func platformOnlyComputerEventsMergeWithoutReplacingOtherPlatform() throws {
        let original = MockEngineClient.demoInventory
        let linuxJSON = Data("""
        {"linux":{"activities":[],"computers":[],"github":null,"repositoryPushOperations":[],"secrets":[]}}
        """.utf8)
        let linuxChange = try JSONDecoder().decode(ComputersChangedPayload.self, from: linuxJSON)
        let linuxMerged = original.applying(linuxChange)
        #expect(linuxMerged.linux.computers.isEmpty)
        #expect(linuxMerged.macos == original.macos)

        var macosState = original.macos
        macosState.computers = []
        let macosJSON = try JSONEncoder().encode(ComputersChangedPayload(macos: macosState))
        let macosChange = try JSONDecoder().decode(ComputersChangedPayload.self, from: macosJSON)
        let macosMerged = original.applying(macosChange)
        #expect(macosMerged.macos.computers.isEmpty)
        #expect(macosMerged.linux == original.linux)
    }

    @Test func linuxDeleteCarriesAndEnforcesExpectedConfiguration() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        let configuration = try #require(client.inventory.linux.computers.first { $0.id == MockEngineClient.failedID }?.configuration)

        do {
            _ = try await client.computersDelete(ComputerDeleteRequest(computerId: MockEngineClient.failedID))
            Issue.record("The mock must reject a Linux delete without expected configuration.")
        } catch {
            #expect(error.localizedDescription.contains("expected configuration"))
        }

        await model.delete(.thisMac(MockEngineClient.failedID))
        #expect(client.deleteRequests.last?.expected == configuration)
        #expect(model.actionError == nil)
    }

    @Test func acceptedJobFailureIsShownBeforeItIsAcknowledged() async throws {
        let client = MockEngineClient()
        client.nextJobFailure = OperationJobError(code: "internal", message: "disk image could not be opened")
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()

        await model.start(.thisMac(MockEngineClient.failedID))

        #expect(model.actionError == "Start failed: disk image could not be opened")
        let jobId = try #require(model.jobAwaitingAcknowledgement)
        #expect(client.acknowledgedJobs.isEmpty)
        await model.acknowledgePresentedJob(jobId)
        #expect(client.acknowledgedJobs == [jobId])
        #expect(model.jobAwaitingAcknowledgement == nil)
    }

    @Test func staleComputerListResponseCannotReplaceANewerEvent() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()

        var staleLinux = client.inventory.linux
        let computerID = try #require(staleLinux.computers.first?.id)
        staleLinux.computers[0].state = .stopped
        staleLinux.computers[0].stateDetail = "Stopped"
        var staleInventory = client.inventory
        staleInventory.linux = staleLinux
        client.replaceInventory(staleInventory)
        client.suspendNextComputersList = true
        let refresh = Task { try await model.refresh() }
        await client.waitForSuspendedComputersList()

        var newerLinux = staleLinux
        newerLinux.computers[0].state = .running
        newerLinux.computers[0].stateDetail = "Running"
        client.deliver(.event(sequence: 2, event: .computersChanged(ComputersChangedPayload(linux: newerLinux))))
        client.resumeSuspendedComputersList()
        try await refresh.value

        #expect(model.inventory?.linux == newerLinux)
        #expect(model.inventory?.computer(computerID)?.displayState == .running)
    }

    @Test func sequenceGapAndReconnectReReadComputerAndOperationState() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()
        let initialReads = client.computersListCallCount

        var afterGap = client.inventory
        afterGap.linux.computers.removeAll()
        client.replaceInventory(afterGap)
        client.deliver(.event(sequence: 3, event: .operationsQueueChanged(.empty)))
        await model.waitForRecovery()
        #expect(client.computersListCallCount > initialReads)
        #expect(model.inventory?.linux.computers.isEmpty == true)

        var afterReconnect = client.inventory
        afterReconnect.macos.computers.removeAll()
        client.replaceInventory(afterReconnect)
        let readsBeforeReconnect = client.computersListCallCount
        client.deliver(.reconnected)
        await model.waitForRecovery()
        #expect(client.computersListCallCount > readsBeforeReconnect)
        #expect(model.inventory?.macos.computers.isEmpty == true)
    }

    @Test func retainedJobOutcomeIsRecoveredThroughJobGet() async throws {
        let client = MockEngineClient()
        client.retainFinishedJob(OperationJobFinished(jobId: "retained:failed",
                                                       error: OperationJobError(code: "internal", message: "recovered failure")))
        let model = ComputersModel(client: client, initialInventory: client.inventory)

        try await model.connect()

        #expect(client.jobGetCallCount == 1)
        #expect(model.finishedJobs["retained:failed"]?.error?.message == "recovered failure")
        #expect(model.actionError == "Computer operation failed: recovered failure")
        #expect(model.jobAwaitingAcknowledgement == "retained:failed")
    }

    @Test func jobGetRecoversACompletionWhenTheFinishedEventIsLost() async throws {
        let client = MockEngineClient()
        client.nextJobFailure = OperationJobError(code: "internal", message: "completion event was lost")
        client.dropNextFinishedEvent = true
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()

        await model.start(.thisMac(MockEngineClient.failedID))

        #expect(client.jobGetCallCount > 1)
        #expect(model.actionError == "Start failed: completion event was lost")
        #expect(model.jobAwaitingAcknowledgement != nil)
    }

    @Test func waitingQueueEntryRendersWithoutProgressAndCanBeCancelled() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()
        let entry = OperationQueueEntry(id: 42, jobId: "job:queued-macos", label: "Create macOS computer",
                                        kind: "computerConfiguration", computerId: MockEngineClient.devID,
                                        computerName: "dev", sinceMs: 1, cancellable: true, blockedByHidden: false)
        let queue = OperationsList(running: [], waiting: [entry], unacknowledgedJobIds: [])

        client.publishOperationQueueChange(queue)

        #expect(model.operationQueue.waiting == [entry])
        #expect(model.activeJob?.jobId != entry.jobId)
        await model.cancelJob("job:queued-macos", deviceId: nil)

        #expect(client.cancelRequests == ["job:queued-macos"])
        #expect(model.operationQueue.waiting.isEmpty)
        #expect(model.actionError == nil)
        #expect(model.finishedJobs["job:queued-macos"]?.error?.code == "cancelled")
    }

    @Test func creationAndForkUseUniqueValidNamesWithinSmallHostLimits() async throws {
        let smallFacts = DeviceFacts(
            deviceCapacity: DeviceCapacity(logicalCpus: 4, physicalMemoryBytes: 8_589_934_592, maxMemoryGib: 8),
            macosHostLimits: MacosHostLimits(cpus: 4, memory_gib: 8), remoteLogin: .unknown)
        var smallInventory = MockEngineClient.demoInventory
        smallInventory.linux.computers = smallInventory.linux.computers.map { row in
            var row = row
            row.configuration.maxCPUs = 4
            row.configuration.maxMemoryGiB = 8
            return row
        }
        let client = MockEngineClient(inventory: smallInventory, deviceFacts: smallFacts)
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()

        await model.createLinuxComputer(name: "linux-new", cpus: 2, memoryGiB: 4)
        await model.createLinuxComputer(name: "linux-new", cpus: 2, memoryGiB: 4)
        let minimumDisk = max(32, Int(clamping: client.inventory.macos.minDiskGiB))
        await model.createMacosComputer(name: "macos-new", cpus: 2, memoryGiB: 4, diskGiB: minimumDisk)
        await model.createMacosComputer(name: "macos-new", cpus: 2, memoryGiB: 4, diskGiB: minimumDisk)

        let linuxRequests = client.createRequests.compactMap(\.configuration)
        let macosRequests = client.createRequests.compactMap(\.request)
        let names = linuxRequests.map(\.name) + macosRequests.map(\.name)
        #expect(names == ["linux-new", "linux-new-2", "macos-new", "macos-new-2"])
        #expect(names.allSatisfy { ComputerName.isValid($0) })
        #expect(Set(names.map { $0.lowercased() }).count == names.count)
        #expect(linuxRequests.allSatisfy { $0.maxCPUs <= smallFacts.deviceCapacity!.logicalCpus })
        #expect(linuxRequests.allSatisfy { $0.maxMemoryGiB <= smallFacts.deviceCapacity!.maxMemoryGib })
        #expect(linuxRequests.allSatisfy { $0.cpus <= $0.maxCPUs && $0.memoryGiB <= $0.maxMemoryGiB })
        #expect(macosRequests.allSatisfy { $0.cpus <= smallFacts.macosHostLimits!.cpus })
        #expect(macosRequests.allSatisfy { $0.memoryGiB <= smallFacts.macosHostLimits!.memory_gib - 4 })

        var duplicate = try #require(linuxRequests.first)
        duplicate.name = "linux-new"
        do {
            _ = try await client.computersCreate(.linux(duplicate, requestId: UUID().uuidString))
            Issue.record("The mock must reject an existing computer name.")
        } catch {
            #expect(error.localizedDescription.contains("already exists"))
        }

        await model.createCheckpoint(for: .thisMac(MockEngineClient.linuxID))
        let checkpointID = try #require(model.inventory?.computer(MockEngineClient.linuxID)?.checkpoints.first?.id)
        let longName = String(repeating: "x", count: ComputerName.maximumLength)
        await model.forkCheckpoint(checkpointID, on: .thisMac(MockEngineClient.linuxID), computerName: longName)
        await model.forkCheckpoint(checkpointID, on: .thisMac(MockEngineClient.linuxID), computerName: longName)

        let forkNames = client.forkRequests.map(\.newName)
        #expect(forkNames.count == 2)
        #expect(forkNames.allSatisfy { ComputerName.isValid($0) && $0.count == ComputerName.maximumLength })
        #expect(forkNames.contains { $0.hasSuffix("-fork") })
        #expect(forkNames.contains { $0.hasSuffix("-fork-2") })
        #expect(Set(forkNames.map { $0.lowercased() }).count == 2)
    }

    @Test func completedCheckpointJobsApplyDelayedCheckpointEvents() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client, initialInventory: client.inventory)
        try await model.connect()
        let linuxID = MockEngineClient.failedID

        await model.createCheckpoint(for: .thisMac(linuxID))
        var checkpoints = try #require(model.inventory?.computer(linuxID)?.checkpoints)
        #expect(checkpoints.count == 1)
        let checkpointID = try #require(checkpoints.first?.id)
        #expect(model.checkpointUsage[GuestReference.thisMac(linuxID).key]?.checkpoints.map(\.id) == [checkpointID])

        await model.restoreCheckpoint(checkpointID, on: .thisMac(linuxID))
        guard case .linux(let restored)? = model.inventory?.computer(linuxID) else {
            Issue.record("The Linux computer should remain in the inventory after restore.")
            return
        }
        #expect(restored.pendingCheckpointRestore?.checkpointId == checkpointID)

        await model.forkCheckpoint(checkpointID, on: .thisMac(linuxID), computerName: "linux-source")
        #expect(model.inventory?.allComputers.contains(where: { $0.name == "linux-source-fork" }) == true)

        await model.deleteCheckpoint(checkpointID, on: .thisMac(linuxID))
        checkpoints = try #require(model.inventory?.computer(linuxID)?.checkpoints)
        #expect(checkpoints.isEmpty)
        #expect(model.checkpointUsage[GuestReference.thisMac(linuxID).key]?.checkpoints.isEmpty == true)
        #expect(client.checkpointListCallCount == 0)
    }

    @Test func setupProgressDecodesEveryCanonicalFieldAndDrivesPresentation() throws {
        let fixture = Data("""
        {
          "jobId":"setup:linux-setup-1",
          "kind":"computerConfiguration",
          "computerId":"computer-1",
          "source":"setup",
          "data":{
            "schemaVersion":1,"type":"computer-configuration","requestId":"linux-setup-1",
            "phase":"computer-configuration","step":"download-image","computer":"devbox",
            "fraction":0.625,"message":"Downloading the runtime image","safeForDisplay":true,
            "timestamp":"2026-10-14T10:00:00Z","level":"warning","elapsedSeconds":12.5,
            "downloadedBytes":640,"totalBytes":1024,"failureCode":"network","exitCode":7,
            "diagnostic":"connection dropped","partial":true
          }
        }
        """.utf8)
        let progress = try JSONDecoder().decode(OperationJobProgress.self, from: fixture)
        guard case .setup(let setup) = progress.data else {
            Issue.record("Setup source must decode to its own progress type.")
            return
        }

        #expect(setup.schemaVersion == 1)
        #expect(setup.type == "computer-configuration")
        #expect(setup.requestId == "linux-setup-1")
        #expect(setup.phase == "computer-configuration")
        #expect(setup.step == "download-image")
        #expect(setup.computer == "devbox")
        #expect(setup.fraction == 0.625)
        #expect(setup.message == "Downloading the runtime image")
        #expect(setup.safeForDisplay)
        #expect(setup.timestamp == "2026-10-14T10:00:00Z")
        #expect(setup.level == "warning")
        #expect(setup.elapsedSeconds == 12.5)
        #expect(setup.downloadedBytes == 640)
        #expect(setup.totalBytes == 1024)
        #expect(setup.failureCode == "network")
        #expect(setup.exitCode == 7)
        #expect(setup.diagnostic == "connection dropped")
        #expect(setup.partial)
        #expect(progress.data.presentationProgress == 0.625)
        #expect(progress.data.presentationTitle == "Downloading the runtime image")

        let encoded = try JSONEncoder().encode(progress)
        #expect(try JSONDecoder().decode(OperationJobProgress.self, from: encoded) == progress)

        let lifecycle = try JSONDecoder().decode(OperationJobProgress.self, from: Data("""
        {"jobId":"job:lifecycle-1","source":"lifecycle","data":{"computerId":"computer-1","action":"start","step":"network"}}
        """.utf8))
        guard case .lifecycle(let lifecycleData) = lifecycle.data else {
            Issue.record("Lifecycle source must decode to its own progress type.")
            return
        }
        #expect(lifecycleData == LifecycleJobProgressData(computerId: "computer-1", action: "start", step: "network"))

        let macos = try JSONDecoder().decode(OperationJobProgress.self, from: Data("""
        {"jobId":"job:macos-1","source":"macos","data":{"computerId":"computer-2","state":"running","progress":0.75,"detail":"Booting","checkpointOperation":{"kind":"capture","status":"running","stage":"Saving memory"}}}
        """.utf8))
        guard case .macos(let macosData) = macos.data else {
            Issue.record("macOS source must decode to its own progress type.")
            return
        }
        #expect(macosData.computerId == "computer-2")
        #expect(macosData.state == "running")
        #expect(macosData.progress == 0.75)
        #expect(macosData.detail == "Booting")
        #expect(macosData.checkpointOperation?.stage == "Saving memory")
    }

    @Test func cancelLeavesEngineConnectedAndDoesNotStopComputers() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client)
        let prompt = try #require(ComputerQuitPrompt.make(inventory: client.inventory))
        try await model.resolveQuit(.cancel, prompt: prompt)
        #expect(!client.disconnected)
        #expect(client.stopRequests.isEmpty)
    }

    @Test func keepRunningDisconnectsOnlyTheClient() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client)
        let prompt = try #require(ComputerQuitPrompt.make(inventory: client.inventory))
        try await model.resolveQuit(.keepRunning, prompt: prompt)
        #expect(client.disconnected)
        #expect(client.stopRequests.isEmpty)
        #expect(client.generatedCalls.contains("settings.flush"))
        #expect(client.settingsSnapshot.revision == 2)
    }

    @Test func stopAndQuitWaitsForRunningComputersToStop() async throws {
        let client = MockEngineClient()
        let model = ComputersModel(client: client)
        try await model.connect()
        let inventory = try await client.computersList(deviceId: nil)
        let prompt = try #require(ComputerQuitPrompt.make(inventory: inventory))
        try await model.resolveQuit(.stopAndQuit, prompt: prompt)
        #expect(Set(client.stopRequests) == Set(prompt.runningComputers.map(\.computerId)))
        #expect(client.disconnected)
        #expect(client.generatedCalls.contains("settings.flush"))
        #expect(client.settingsSnapshot.revision == 2)
        #expect(prompt.runningComputers.allSatisfy { model.inventory?.computer($0.computerId)?.displayState == .stopped })
    }

    @Test func refusedMacosStopRestoresQuitChoicesAfterJobSuccess() async throws {
        var inventory = MockEngineClient.demoInventory
        inventory.linux.computers = inventory.linux.computers.map { row in
            var row = row
            row.state = .stopped
            row.stateDetail = "Stopped"
            return row
        }
        let client = MockEngineClient(inventory: inventory)
        client.stopRefusalIDs = [MockEngineClient.devID]
        let model = ComputersModel(client: client, initialInventory: inventory)
        let prompt = try #require(ComputerQuitPrompt.make(inventory: inventory))
        try await model.connect()
        model.presentQuitPrompt(prompt)
        model.chooseQuit(.stopAndQuit)
        await model.waitForQuitResolution()
        #expect(model.quitError?.contains("refused") == true)
        #expect(!model.isQuitWorking)
        #expect(model.quitPrompt != nil)
    }

    @Test func quitStopWaitHasABoundedDeadline() async throws {
        var inventory = MockEngineClient.demoInventory
        inventory.linux.computers = []
        inventory.macos.computers[0].state = .stopping
        let client = MockEngineClient(inventory: inventory)
        let model = ComputersModel(client: client, initialInventory: inventory)

        do {
            try await model.waitUntilStopped([MockEngineClient.devID], timeout: .milliseconds(30))
            Issue.record("A computer that remains stopping must time out.")
        } catch {
            #expect(error.localizedDescription.contains("deadline"))
        }
    }

    @Test func overlappingActivationsAndTeardownLeaveNoLateSubscription() async {
        let client = MockEngineClient()
        client.suspendNextSubscription = true
        let model = ComputersModel(client: client)
        let listActivation = Task { await model.activate() }
        await client.waitForSuspendedSubscription()
        let detailActivation = Task { await model.activate() }
        await Task.yield()
        await model.deactivate()
        client.resumeSuspendedSubscription()
        await listActivation.value
        await detailActivation.value

        #expect(client.subscribeCallCount == 1)
        #expect(client.activeSubscriptionCount == 0)
        #expect(client.unsubscribeCallCount == 1)
    }

    @Test func stateMappingCoversLinuxAndMacOSStates() throws {
        let inventory = MockEngineClient.demoInventory
        #expect(try #require(inventory.computer(MockEngineClient.linuxID)).displayState == .running)
        #expect(try #require(inventory.computer(MockEngineClient.failedID)).displayState == .failed)
        #expect(try #require(inventory.computer(MockEngineClient.startingID)).displayState == .starting)

        var linuxStopping = try #require(inventory.linux.computers.first { $0.id == MockEngineClient.linuxID })
        linuxStopping.state = .starting
        linuxStopping.stateDetail = "Stopping"
        #expect(ComputerRow.linux(linuxStopping).displayState == .stopping)
    }
}
