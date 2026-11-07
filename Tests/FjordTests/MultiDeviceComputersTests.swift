import Foundation
import Testing
@testable import Fjord

/// The Computers tool as a controller: This Mac and every connected device are listed, and every action, job and event is
/// scoped by the device that owns the computer. The demo remote device reuses the ids of This Mac's `dev` and `linux-1`.
@MainActor
@Suite(.serialized) struct MultiDeviceComputersTests {
    private let device = MockEngineClient.demoRemoteDevice
    private var remoteMac: GuestReference { GuestReference(deviceId: device.id, computerId: MockEngineClient.devID) }
    private var localMac: GuestReference { .thisMac(MockEngineClient.devID) }
    private var remoteLinux: GuestReference { GuestReference(deviceId: device.id, computerId: MockEngineClient.linuxID) }
    private var localLinux: GuestReference { .thisMac(MockEngineClient.linuxID) }

    private func rig() async throws -> (model: ComputersModel, local: MockEngineClient, remote: MockEngineClient) {
        let local = MockEngineClient()
        let remote = local.connectDemoRemoteDevice()
        let model = ComputersModel(client: local, initialInventory: local.inventory)
        try await model.connect()
        return (model, local, remote)
    }

    @Test func listsThisMacAndEachConnectedDeviceAsGroupsWithSameIdComputersApart() async throws {
        let (model, _, _) = try await rig()
        #expect(model.ownerGroups.map(\.name) == ["This Mac", "Studio Mac"])
        #expect(model.row(localMac)?.name == "dev")
        #expect(model.row(remoteMac)?.name == "studio-dev")
        #expect(model.row(localLinux)?.name == "linux-1")
        #expect(model.row(remoteLinux)?.name == "ci-linux")
    }

    @Test func subscribesToTheConnectedDevicesEvents() async throws {
        let (model, local, _) = try await rig()
        #expect(local.subscribedDeviceIds.last == [device.id])
        await model.deactivate()
    }

    @Test func startingTheRemoteComputerLeavesTheSameIdLocalOneAlone() async throws {
        let (model, local, remote) = try await rig()
        #expect(model.row(remoteMac)?.displayState == .stopped)
        await model.start(remoteMac)
        #expect(model.actionError == nil)
        #expect(remote.inventory.computer(MockEngineClient.devID)?.displayState == .running)
        #expect(model.row(remoteMac)?.displayState == .running)
        #expect(local.stopRequests.isEmpty)
        #expect(model.row(localMac)?.displayState == .running)
    }

    @Test func stoppingTheLocalComputerDoesNotTouchTheRemoteSameIdOne() async throws {
        let (model, _, remote) = try await rig()
        await model.start(remoteMac)
        await model.stop(localMac)
        #expect(remote.stopRequests.isEmpty)
        #expect(model.row(remoteMac)?.displayState == .running)
    }

    @Test func jobsAreTrackedByDeviceAndJobIdWhenBothDevicesIssueTheSameId() async throws {
        let (model, _, _) = try await rig()
        await model.start(localMac)  // refused: running, so no job
        await model.start(remoteMac)
        await model.createCheckpoint(for: localLinux)
        // Both engines count job ids from the same start, so one id exists on two devices.
        let remoteKey = ComputerJobKey.make(deviceId: device.id, jobId: "job:1")
        #expect(model.finishedJobs[remoteKey] != nil)
        #expect(model.finishedJobs["job:1"] != nil)
        #expect(remoteKey != "job:1")
        #expect(ComputerJobKey.parts(remoteKey) == (device.id, "job:1"))
        #expect(ComputerJobKey.parts("job:1") == (nil, "job:1"))
    }

    @Test func acknowledgingARemoteJobNamesItsOwner() async throws {
        let (model, local, remote) = try await rig()
        await model.start(remoteMac)
        let key = ComputerJobKey.make(deviceId: device.id, jobId: "job:1")
        #expect(model.jobAwaitingAcknowledgement == key)
        await model.acknowledgePresentedJob(key)
        #expect(remote.acknowledgedJobs == ["job:1"])
        #expect(local.acknowledgedJobs.isEmpty)
        #expect(model.finishedJobs[key] == nil)
    }

    @Test func deletingTheRemoteComputerNamesItsOwnerAndKeepsTheLocalOne() async throws {
        let (model, local, remote) = try await rig()
        await model.delete(remoteMac)
        #expect(remote.deleteRequests.map(\.deviceId) == [device.id])
        #expect(local.deleteRequests.isEmpty)
        #expect(model.row(localMac) != nil)
        #expect(model.row(remoteMac) == nil)
    }

    @Test func remoteEventsUpdateOnlyTheirOwnersInventory() async throws {
        let (model, _, remote) = try await rig()
        await model.start(remoteMac)
        // The state came through the relayed computers.changed event, not a re-read.
        #expect(remote.inventory.computer(MockEngineClient.devID)?.displayState == .running)
        #expect(model.remoteOwnerInventories.first?.inventory.computer(MockEngineClient.devID)?.displayState == .running)
        #expect(model.inventory?.computer(MockEngineClient.devID)?.name == "dev")
    }

    @Test func anEventFromAnUnknownDeviceNeverTouchesThisMacAndTriggersARead() async throws {
        let (model, local, _) = try await rig()
        let before = model.inventory
        // A third Mac, not in the loaded list, with a computer that reuses This Mac's `dev` id.
        var stranger = try #require(model.inventory?.macos)
        for index in stranger.computers.indices where stranger.computers[index].id == MockEngineClient.devID {
            stranger.computers[index].name = "stranger-dev"
        }
        local.publishForTests(.computersChanged(ComputersChangedPayload(macos: stranger), deviceId: "unknown-mac"))
        #expect(model.inventory == before)
        #expect(model.row(localMac)?.name == "dev")
        #expect(model.row(remoteMac)?.name == "studio-dev")
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.inventory == before)
        #expect(model.row(localMac)?.name == "dev")
        // An event with no deviceId is still This Mac's.
        var renamed = stranger
        for index in renamed.computers.indices where renamed.computers[index].id == MockEngineClient.devID {
            renamed.computers[index].name = "dev-renamed"
        }
        local.publishForTests(.computersChanged(ComputersChangedPayload(macos: renamed)))
        #expect(model.row(localMac)?.name == "dev-renamed")
    }

    @Test func perComputerStateIsKeyedByOwner() async throws {
        let (model, _, _) = try await rig()
        await model.loadFiles(localLinux)
        await model.loadFiles(remoteLinux)
        #expect(model.fileLists[localLinux.key] != nil)
        #expect(model.fileLists[remoteLinux.key] != nil)
        #expect(localLinux.key != remoteLinux.key)
        await model.loadStorage(remoteLinux)
        #expect(model.storageByComputer[remoteLinux.key] != nil)
        #expect(model.storageByComputer[localLinux.key] == nil)
        await model.loadCheckpointUsage(remoteMac)
        #expect(model.checkpointUsage[remoteMac.key]?.checkpoints.map(\.id) == ["checkpoint-studio-1"])
        #expect(model.checkpointUsage[localMac.key] == nil)
    }

    @Test func secretsAndGitHubStateBelongToTheirDevice() async throws {
        let (model, _, _) = try await rig()
        await model.loadSecrets(deviceId: nil)
        await model.loadSecrets(deviceId: device.id)
        #expect(model.secrets(for: nil).map(\.name) == ["GITHUB_TOKEN"])
        #expect(model.secrets(for: device.id).map(\.name) == ["GITHUB_TOKEN"])
        await model.saveSecret(id: nil, name: "REMOTE_ONLY", value: "x", computerIds: [MockEngineClient.devID],
                               allowedDomains: ["example.com"], allowAnyDestination: false, deviceId: device.id)
        #expect(model.secrets(for: device.id).map(\.name).contains("REMOTE_ONLY"))
        #expect(!model.secrets(for: nil).map(\.name).contains("REMOTE_ONLY"))
    }

    @Test func actionsThatReachOnlyThisMacAreUnavailableForARemoteComputer() async throws {
        let (model, local, _) = try await rig()
        await model.showDisplay(remoteMac)
        #expect(model.actionError == ComputerRemoteLimit.display.reason)
        await model.openPort(remoteLinux, port: 3000)
        #expect(model.actionError == ComputerRemoteLimit.openPort.reason)
        await model.openSSHAccessConnection(remoteLinux)
        #expect(model.actionError == ComputerRemoteLimit.terminal.reason)
        #expect(!local.generatedCalls.contains("network.open"))
        #expect(!local.generatedCalls.contains("sshAccess.connection"))
        #expect(ComputerRemoteLimit.openPort.unavailableReason(for: localLinux) == nil)
    }

    @Test func filesUploadAndDownloadGoToTheOwnerOfARemoteComputer() async throws {
        let (model, local, remote) = try await rig()
        await model.uploadFiles(remoteLinux, directory: "/workspace", paths: ["/tmp/notes.txt"])
        #expect(model.actionError == nil)
        #expect(remote.uploadRequests.map(\.deviceId) == [device.id])
        #expect(local.uploadRequests.isEmpty)
        #expect(model.fileLists[remoteLinux.key]?.entries.contains { $0.name == "notes.txt" } == true)
        #expect(model.fileLists[localLinux.key] == nil)
        // The transfer job is the owner's: its key carries the device.
        #expect(model.jobAwaitingAcknowledgement?.hasSuffix("@\(device.id)") == true)
        await model.downloadFile(remoteLinux, path: "/workspace/notes.txt", destination: "/tmp/notes-copy.txt")
        #expect(model.actionError == nil)
    }

    @Test func theEngineRefusesTheWindowAndClipboardForARemoteComputer() async throws {
        let (_, local, _) = try await rig()
        await #expect(throws: EngineClientError.self) {
            try await local.displayShow(ComputerReference(computerId: MockEngineClient.devID, deviceId: device.id))
        }
    }

    @Test func aRemoteDevicesComputersCanBeCreatedOnItAndNamedAfterItsOwnInventory() async throws {
        let (model, local, remote) = try await rig()
        await model.createLinuxComputer(name: "studio-dev", cpus: 2, memoryGiB: 4, deviceId: device.id)
        #expect(model.actionError == nil)
        #expect(remote.createRequests.count == 1)
        #expect(remote.createRequests.first?.deviceId == device.id)
        #expect(local.createRequests.isEmpty)
        #expect(model.remoteOwnerInventories.first?.inventory.allComputers.map(\.name).contains("studio-dev") == true)
    }

    @Test func aRemoteComputerResourceChangeAndCheckpointsGoToItsOwner() async throws {
        let (model, local, remote) = try await rig()
        await model.createCheckpoint(for: remoteMac)
        #expect(remote.inventory.computer(MockEngineClient.devID)?.checkpoints.count == 2)
        #expect(local.inventory.computer(MockEngineClient.devID)?.checkpoints.count == 2)  // its own two, untouched
        await model.updateResources(for: remoteMac, cpus: 4, memoryGiB: 8)
        #expect(model.actionError == nil)
        #expect(remote.inventory.computer(MockEngineClient.devID).map { row -> Bool in
            if case .macos(let computer) = row { computer.cpus == 4 } else { false }
        } == true)
    }

    @Test func aRemoteComputerRouteSurvivesItsTokenAndKeepsTheOwner() {
        let remote = AppDestination.computerDetail(GuestReference(deviceId: "device-studio", computerId: "c-1"))
        let local = AppDestination.computerDetail(.thisMac("c-1"))
        #expect(remote != local)
        #expect(AppDestination(token: remote.token) == remote)
        #expect(AppDestination(token: local.token) == local)
        #expect(remote.token != local.token)
    }
}
