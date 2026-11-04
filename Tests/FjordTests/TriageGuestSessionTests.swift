import Foundation
import Testing
@testable import Fjord

/// A Triage action for a project that lives in a computer goes through the Router like a Mac project's: its session is
/// prepared in Claude over SSH (the `claude://code/new` link with the prompt filled in), after an automatic checkpoint of
/// the computer, and starts when the owner presses Send there. A Mac project keeps the local flow.
@MainActor
@Suite(.serialized, .ownGuestRuntime) struct TriageGuestSessionTests {
    private let computerID = "10000000-0000-4000-8000-0000000000d1"
    private var guestRef: GuestReference { GuestReference(deviceId: nil, computerId: computerID) }
    private var account: GuestAccount {
        GuestAccount(home: "/home/guest", uid: 1001, operatingSystem: .linux, architecture: "aarch64",
                     nodeExecutable: "/usr/bin/node", claudeExecutable: "/home/guest/.local/bin/claude")
    }
    private let source = "/local/widget"

    private func engine() -> MockEngineClient {
        var inventory = MockEngineClient.demoInventory
        inventory.linux.computers.append(ApplicationComputer(kind: .linux,
            configuration: ComputerConfiguration(id: computerID, name: "Linux dev", cpus: 2, maxCPUs: 8, memoryGiB: 4,
                maxMemoryGiB: 16, workspaceStorageGiB: 32, runtimeStorageGiB: 16),
            purpose: "Local MicroSandbox", state: .running, stateDetail: "Running", canDismissError: false, freshness: "fresh"))
        return MockEngineClient(inventory: inventory)
    }

    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-triage-guest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }


    private func guest() async -> MockGuestClient {
        let guest = MockGuestClient(accounts: [guestRef: account])
        await guest.setExecResult(GuestExecResult(exitCode: 0, stdout: Data("1800000000000".utf8), stderr: Data()),
                                  argv: [account.nodeExecutable, "-e", "process.stdout.write(String(Date.now()))"])
        return guest
    }

    private func checkpoints(_ engine: MockEngineClient) -> [ComputerCheckpoint] {
        engine.inventory.computer(computerID)?.checkpoints ?? []
    }






    @Test func aCheckpointThatCantBeSavedThrowsWithAReasonSoTheSessionIsNotStarted() async {
        do {
            _ = try await AutomaticCheckpoint.take(engine: UnavailableEngineClient(), computer: guestRef, task: "Fix it")
            Issue.record("a checkpoint was reported with no engine")
        } catch {
            #expect(error.localizedDescription.contains("automatic checkpoint setting"))
        }
    }




    @Test func aSavedHeadlessRunInAComputerActionIsDroppedAndTheCategoryStays() throws {
        let json = Data(#"""
        [{"id":"11111111-1111-4111-8111-111111111111","kind":{"runInComputer":{"_0":{"computerID":"c","computerName":"n","workspaceRoot":"/w","promptTemplate":"x"}}},"trigger":"enter"},
         {"id":"22222222-2222-4222-8222-222222222222","kind":{"rerun":{}},"trigger":"enter"}]
        """#.utf8)
        let list = try JSONDecoder().decode(ActionList.self, from: json)
        #expect(list.items.map(\.title) == ["Re-run failed checks"])
    }
}

private actor Finished {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
