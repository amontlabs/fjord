import Foundation
import Testing
@testable import Fjord

/// Read-only probe of the owner's real T3 server: `FJORD_T3_LIVE=1 swift test --filter T3Live`.
/// Subscribes to the shell, reduces the snapshot and prints counts by status. No titles, no commands.
@Suite("T3 live (read-only)", .timeLimit(.minutes(1)))
struct T3LiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FJORD_T3_LIVE"] == "1"))
    func shellSnapshotCountsByStatus() async throws {
        let started = ContinuousClock.now
        let client = T3Client.local()
        var state = T3ShellState()
        for await item in await client.subscribeShell() {
            state.apply(item)
            if case .snapshot = item { break }
        }
        let took = ContinuousClock.now - started
        await client.shutdown()
        print("T3 LIVE: snapshot in \(took)")
        let counts = state.statusCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("T3 LIVE: projects=\(state.projects.count) threads=\(state.threads.count) listed=\(state.listedThreads.count) needingYou=\(state.needingYou.count) sequence=\(state.sequence ?? -1) | \(counts)")
        #expect(state.threads.count > 0)
    }
}
