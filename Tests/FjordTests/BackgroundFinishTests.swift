import Foundation
import Testing
@testable import Fjord

/// A thread whose turn ended while work it started goes on (a subagent, a command, a monitor, a background task, a hold on
/// another thread): it stays working, nothing finishes or is told until the work ends, and the finish is told once, then.
@MainActor @Suite struct BackgroundFinishTests {
    typealias F = T3Fixture
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func task(_ id: String, kind: String, description: String) -> T3PendingTask {
        T3PendingTask(json: ["taskId": .string(id), "kind": .string(kind), "description": .string(description)])
    }

    /// A thread whose run ended at 999_500 (the shell carries no message text, as T3 0.1.7 doesn't), last active at 999_000.
    private func thread(_ id: String, pending: [T3PendingTask] = [], blocked: Bool = false, ended: Double? = 999_500,
                        running: Bool = false, unseen: Bool = false) -> AgentThread {
        var t = AgentThread(id: id, title: "Thread " + id, folder: "/code/p1", lastActivity: Date(timeIntervalSince1970: 999_000),
                            running: running, unseen: unseen, latestMessage: nil,
                            lastRunEndedAt: ended.map { Date(timeIntervalSince1970: $0) })
        t.pendingTasks = pending
        t.blockedOnThreadWait = blocked
        return t
    }

    // MARK: The thread stays working

    @Test func aTurnDoneWithWorkPendingIsStillWorking() {
        let t = thread("a", pending: [task("s1", kind: "subagent", description: "Review the changes")])
        #expect(t.running && !t.finished && !t.needsYou)
        #expect(t.backgroundStep == "background: Review the changes")
        let many = thread("b", pending: [task("s1", kind: "subagent", description: "One"), task("c1", kind: "command", description: "Two")])
        #expect(many.backgroundStep == "background: 2 running")
        let held = thread("c", blocked: true)
        #expect(held.running && !held.finished && held.backgroundStep == nil)
        let live = thread("d", ended: nil, running: true)
        #expect(live.turnRunning && live.running && live.backgroundStep == nil)
        let quiet = thread("e")
        #expect(!quiet.running && quiet.finished)
    }

    @Test func theShellCarriesTheWorkAndTheEndStampMovesWithIt() {
        var shell = T3ThreadShell(json: F.thread("t1", status: "completed", extra: ["latestVisibleMessage": nil]))
        let plain = AgentThread.endStamp(shell)
        shell.pendingBackgroundTasks = [task("s1", kind: "subagent", description: "Review the changes")]
        let t = AgentThread(shell, project: nil)
        #expect(t.pendingTasks.map(\.label) == ["Review the changes"] && t.running && !t.finished)
        #expect(t.latestMessageID == AgentThread.endStamp(shell) && AgentThread.endStamp(shell) != plain)
        shell.pendingBackgroundTasks = []
        shell.blockedOnThreadWait = true
        #expect(AgentThread.endStamp(shell) != plain)
        let held = AgentThread(shell, project: nil)
        #expect(held.blockedOnThreadWait && held.running && !held.finished)
        shell.blockedOnThreadWait = false
        #expect(AgentThread.endStamp(shell) == plain)
        let done = AgentThread(shell, project: nil)
        #expect(!done.running && done.finished)
    }

    // MARK: The banner waits for the work

    @Test func theFinishedBannerWaitsForTheWorkAndKeepsAFreshWorkSeenWorking() {
        let held = thread("a", pending: [task("s1", kind: "subagent", description: "Review the changes")])
        #expect(ThreadNotices.notices(held, request: nil, now: Date(timeIntervalSince1970: 999_600)).isEmpty)
        // The work ended just now, though the run ended long ago: fresh by the last seeing of it working.
        let done = thread("a")
        let late = Date(timeIntervalSince1970: 1_060_000)
        #expect(ThreadNotices.notices(done, request: nil, now: late).isEmpty, "a relaunch saw nothing working")
        #expect(ThreadNotices.notices(done, request: nil, now: late, sawRunning: late.addingTimeInterval(-30)).map(\.key) == ["done:a@999500"])
        // Inside the window it tells as before.
        #expect(ThreadNotices.notices(done, request: nil, now: Date(timeIntervalSince1970: 999_600)).map(\.kind) == [.finished])
    }

    @Test func t3sWatchOfAnOpenPullRequestIsNotWorkStillRunning() {
        let shell = T3ThreadShell(json: F.thread("t1", status: "completed", extra: ["pendingBackgroundTasks": .array([
            ["taskId": "pull-request-watch:github.com/o/r#12", "kind": "monitor", "description": "Watching pull request #12"],
        ])]))
        let t = AgentThread(shell, project: nil)
        #expect(t.pendingTasks.isEmpty && !t.running && t.finished)
    }
}
