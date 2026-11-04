import Foundation
import Testing
@testable import Fjord

/// The Computers page's references and the computer-removal hooks for computers owned by another device:
/// every call names the owner, and a computer with the same id on This Mac is never read, started or cleaned up instead.
@MainActor
@Suite(.serialized, .ownGuestRuntime) struct RemoteOwnersTests {
    private let deviceID = "device-2"
    private let computerID = "10000000-0000-4000-8000-0000000000c9"
    private var local: GuestReference { GuestReference.thisMac(computerID) }

    private func row(_ name: String, state: LinuxComputerState) -> ApplicationComputer {
        ApplicationComputer(kind: .linux,
            configuration: ComputerConfiguration(id: computerID, name: name, cpus: 2, maxCPUs: 8, memoryGiB: 4,
                maxMemoryGiB: 16, workspaceStorageGiB: 32, runtimeStorageGiB: 16),
            purpose: "Always-on", state: state, stateDetail: state.rawValue.capitalized, canDismissError: false, freshness: "fresh")
    }

    private func engine(remoteComputer: Bool = true) -> MockEngineClient {
        var localInventory = MockEngineClient.demoInventory
        localInventory.linux.computers.append(row("local-twin", state: .stopped))
        let engine = MockEngineClient(inventory: localInventory)
        var owned = MockEngineClient.demoInventory
        owned.linux.computers = remoteComputer ? [row("always-on", state: .stopped)] : []
        engine.connectedDevices = [SiloWireDevice(address: "me@host-2", id: deviceID, name: "Host 2")]
        engine.ownerInventories[deviceID] = owned
        return engine
    }

}
