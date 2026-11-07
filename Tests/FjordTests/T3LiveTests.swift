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

    /// The real shell through Fjord's mapping: how many threads, rows by group, and what is carried in from T3. Counts only.
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["FJORD_T3_LIVE"] == "1"))
    func theRealShellMapsToThreadsAndRows() async throws {
        let client = T3Client.local()
        var state = T3ShellState()
        for await item in await client.subscribeShell() {
            state.apply(item)
            if case .snapshot = item { break }
        }
        await client.shutdown()
        let s = Store()
        s.persists = false
        s.agents.enabled = true
        let started = ContinuousClock.now
        s.t3.store.seed(state)
        let rows = s.allAgentRows
        let took = ContinuousClock.now - started
        let groups = Dictionary(grouping: rows, by: \.group).mapValues(\.count).sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let threads = Array(s.threads.values)
        print("T3 LIVE MAP: threads=\(threads.count) rows=\(rows.count) [\(groups)] mapped+listed in \(took)")
        print("T3 LIVE MAP: settled=\(threads.filter(\.settled).count) unseen=\(threads.filter(\.unseen).count) running=\(threads.filter(\.running).count) waiting=\(threads.filter(\.waitsForYou).count) scratch=\(threads.filter { $0.folder == nil }.count) withRepo=\(threads.filter { $0.repo != nil }.count) backgroundWork=\(s.backgroundWork.values.map(\.count).reduce(0, +)) folders=\(Set(threads.map(\.folderKey)).count) imported=\(threads.filter { $0.id.hasPrefix("import:claudeAgent:") }.count)")
        #expect(threads.count > 0)
    }
}
