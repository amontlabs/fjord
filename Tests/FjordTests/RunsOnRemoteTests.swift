import Foundation
import Testing
@testable import Fjord

/// Router "Runs on" for a computer owned by another device: every step addresses the owner by deviceId, and a computer
/// with the same id on This Mac is never touched.
@MainActor
@Suite(.serialized, .ownGuestRuntime) struct RunsOnRemoteTests {
    private let deviceID = "device-2"
    private let computerID = "10000000-0000-4000-8000-0000000000b7"
    private var remote: GuestReference { GuestReference(deviceId: deviceID, computerId: computerID) }
    private var local: GuestReference { GuestReference(deviceId: nil, computerId: computerID) }
    private var account: GuestAccount {
        GuestAccount(home: "/home/guest", uid: 1001, operatingSystem: .linux, architecture: "aarch64",
                     nodeExecutable: "/usr/bin/node", claudeExecutable: "/home/guest/.local/bin/claude")
    }

    private func row(_ name: String, state: LinuxComputerState) -> ApplicationComputer {
        ApplicationComputer(kind: .linux,
            configuration: ComputerConfiguration(id: computerID, name: name, cpus: 2, maxCPUs: 8, memoryGiB: 4,
                maxMemoryGiB: 16, workspaceStorageGiB: 32, runtimeStorageGiB: 16),
            purpose: "Always-on", state: state, stateDetail: state.rawValue.capitalized, canDismissError: false, freshness: "fresh")
    }

    /// This Mac has a stopped computer under `computerID`; the second device has its own, also stopped, under the same id.
    private func engine(remoteState: LinuxComputerState = .stopped) -> MockEngineClient {
        var localInventory = MockEngineClient.demoInventory
        localInventory.linux.computers.append(row("local-twin", state: .stopped))
        let engine = MockEngineClient(inventory: localInventory)
        var owned = MockEngineClient.demoInventory
        owned.linux.computers = [row("always-on", state: remoteState)]
        engine.connectedDevices = [SiloWireDevice(address: "me@host-2", id: deviceID, name: "Host 2")]
        engine.ownerInventories[deviceID] = owned
        return engine
    }

    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-runson-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }



    @Test func aRunningRemoteComputerIsNotStartedAgain() async throws {
        let engine = engine(remoteState: .running)
        let model = ComputersModel(client: engine, initialInventory: engine.inventory)
        let row = try await model.ensureRemoteRunning(deviceId: deviceID, computerId: computerID)
        #expect(row.name == "always-on")
        #expect(engine.remoteStartRequests.isEmpty)
    }

    @Test func aComputerGoneFromItsOwnerFailsInsteadOfFallingBackToTheLocalOne() async throws {
        let engine = engine()
        engine.ownerInventories[deviceID]?.linux.computers = []
        let model = ComputersModel(client: engine, initialInventory: engine.inventory)
        await #expect(throws: (any Error).self) {
            _ = try await model.ensureRemoteRunning(deviceId: deviceID, computerId: computerID)
        }
        #expect(engine.remoteStartRequests.isEmpty)
        #expect(engine.inventory.computer(computerID)?.displayState == .stopped)
    }

    @Test func remoteAgentToolsStatusAndSetupCarryTheDeviceId() async throws {
        let engine = engine(remoteState: .running)
        engine.mockAgentTools["\(deviceID)/\(computerID)"] = MockEngineClient.agentTools(.missing)
        let model = ComputersModel(client: engine, initialInventory: engine.inventory)
        try await model.ensureAgentTools(remote, kind: .linux, computerName: "always-on")
        #expect(engine.agentToolsSetupKeys == ["\(deviceID)/\(computerID)"])
        #expect(model.agentTools(for: remote)?.state == .ready)
        #expect(model.agentTools(for: local) == nil)
    }
}
