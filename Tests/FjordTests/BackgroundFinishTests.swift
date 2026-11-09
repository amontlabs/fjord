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

    // MARK: The brief's finish waits for the work

    @Test func theDoneItemWaitsForTheBackgroundWorkAndIsLoggedOnceWhenItEnds() {
        let working = thread("a", ended: nil, running: true)
        let held = thread("a", pending: [task("s1", kind: "subagent", description: "Review the changes")])
        // The run's end arrives while the work runs: nothing is logged, and nothing is read yet either.
        #expect(BriefLog.events(old: BriefThreadFacts(working), thread: held, now: now.timeIntervalSince1970).isEmpty)
        #expect(!BriefLog.needsRead(old: BriefThreadFacts(working), thread: held))
        // The work ends: the finish is logged, stamped with the run's end, with the reply read from the thread's end.
        let done = thread("a")
        #expect(BriefLog.needsRead(old: BriefThreadFacts(held), thread: done))
        let items = BriefLog.events(old: BriefThreadFacts(held), thread: done, now: now.timeIntervalSince1970,
                                    reads: ThreadReads(youSaid: "Ship it", reply: "Shipped."))
        #expect(items.map(\.kind) == [.message] && items[0].id == "done@999500:a")
        #expect(items[0].text == "finished: Shipped." && items[0].status == .done)
        // And once: the same thread again logs nothing.
        #expect(BriefLog.events(old: BriefThreadFacts(done), thread: done, now: now.timeIntervalSince1970).isEmpty)
        // A run over with no work pending tells at once, as before.
        let over = BriefLog.events(old: BriefThreadFacts(thread("b", ended: nil, running: true)), thread: thread("b", ended: 999_400),
                                   now: now.timeIntervalSince1970, reads: ThreadReads(youSaid: nil, reply: "Done."))
        #expect(over.map(\.id) == ["done@999400:b"])
    }

    @Test func aHoldOnAnotherThreadWaitsTheSameWay() {
        let working = thread("a", ended: nil, running: true)
        let held = thread("a", blocked: true)
        #expect(BriefLog.events(old: BriefThreadFacts(working), thread: held, now: now.timeIntervalSince1970).isEmpty)
        #expect(!BriefLog.needsRead(old: BriefThreadFacts(working), thread: held))
        let done = thread("a")
        #expect(BriefLog.needsRead(old: BriefThreadFacts(held), thread: done))
        let items = BriefLog.events(old: BriefThreadFacts(held), thread: done, now: now.timeIntervalSince1970,
                                    reads: ThreadReads(youSaid: nil, reply: "Picked up again and done."))
        #expect(items.map(\.kind) == [.message] && items[0].text == "finished: Picked up again and done.")
        #expect(BriefLog.events(old: BriefThreadFacts(done), thread: done, now: now.timeIntervalSince1970).isEmpty)
    }

    @Test func factsWrittenWithoutThePendingFieldStillRead() throws {
        let old = #"{"project":"p","title":"T","running":true,"stopped":false,"runEnded":null,"userAt":null,"prs":[]}"#
        let decoded = try JSONDecoder().decode(BriefThreadFacts.self, from: Data(old.utf8))
        #expect(decoded.pending == 0 && decoded.running && decoded.prs.isEmpty)
        // And the facts round-trip through the store whole.
        let dir = TempDir()
        let log = try BriefLog(path: dir.path("briefs.db").path)
        let facts = BriefThreadFacts(thread("a"))
        log.setSeen("a", facts)
        #expect(try BriefLog(path: dir.path("briefs.db").path).seen()["a"] == facts)
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

    @Test func theBannerPathHoldsWhileTheWorkRunsAndTellsOnceWhenItEnds() {
        let held = thread("t-bg", pending: [task("s1", kind: "subagent", description: "Review the changes")], unseen: true)
        let s = Store()
        s.persists = false
        s.router.enabled = true
        s.agents.enabled = true
        s.settings.notifications = true
        s.threads = ["t-bg": held]
        var at = Date(timeIntervalSince1970: 999_600)
        s.routerBriefs.clock = { at }
        var posted: [String] = []
        s.notifier.onPost = { posted.append($0.identifier) }
        s.routerBriefs.announce(store: s)
        #expect(posted.isEmpty, "nothing while the work runs")
        // Still working, later: the seeing of it working stays fresh.
        at = Date(timeIntervalSince1970: 1_000_500)
        s.routerBriefs.announce(store: s)
        #expect(posted.isEmpty)
        // The work ends: the finish is told once, though the run's end is past the window.
        s.threads = ["t-bg": thread("t-bg", unseen: true)]
        s.routerBriefs.announce(store: s)
        #expect(posted.count == 1)
        s.routerBriefs.announce(store: s)
        #expect(posted.count == 1, "once")
        // A relaunch (no seeing of it working) tells no old story.
        let again = Store()
        again.persists = false
        again.router.enabled = true
        again.agents.enabled = true
        again.settings.notifications = true
        again.threads = ["t-bg": thread("t-bg", unseen: true)]
        again.routerBriefs.clock = { Date(timeIntervalSince1970: 1_060_000) }
        var old: [String] = []
        again.notifier.onPost = { old.append($0.identifier) }
        again.routerBriefs.announce(store: again)
        #expect(old.isEmpty)
    }
}
