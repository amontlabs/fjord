import Foundation
import Testing
@testable import Fjord

/// The brief on T3 (Step 13): Fjord's log of what happened per project, the boards built from T3's threads, and the engine's
/// prompt. Synthetic threads only.
@MainActor @Suite struct BriefLogTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func thread(_ id: String, project: String = "p1", running: Bool = false, ended: Double? = nil, said: String? = nil,
                        user: Double? = nil, active: Double? = nil) -> AgentThread {
        var t = AgentThread(id: id, title: "Thread " + id, folder: "/code/" + project, lastActivity: Date(timeIntervalSince1970: active ?? 999_000),
                            running: running, latestMessage: said, lastRunEndedAt: ended.map { Date(timeIntervalSince1970: $0) })
        t.projectID = project
        t.lastUserMessage = user.map { Date(timeIntervalSince1970: $0) }
        return t
    }

    @Test func anItemIsStoredOnceByIdAndReadPastTheCursor() throws {
        let dir = TempDir()
        let log = try BriefLog(path: dir.path("briefs.db").path)
        let a = BriefItem(seq: 0, id: "x:1", at: 1, kind: .message, thread: "t", text: "finished: done", options: ["A"], status: .done)
        #expect(log.append(a, project: "p"))
        #expect(!log.append(a, project: "p"))
        #expect(log.append(BriefItem(seq: 0, id: "x:2", at: 2, kind: .card, thread: "t", text: "asks"), project: "p"))
        let all = log.items(project: "p", after: 0)
        #expect(all.map(\.id) == ["x:1", "x:2"] && all[0].options == ["A"] && all[0].status == .done)
        #expect(log.items(project: "p", after: all[0].seq).map(\.id) == ["x:2"])
        #expect(log.projects() == ["p"] && log.items(project: "q", after: 0).isEmpty)
        let again = try BriefLog(path: dir.path("briefs.db").path)
        #expect(again.items(project: "p", after: 0).count == 2)
    }

    @Test func aRelaunchLogsWhatChangedMeanwhile() throws {
        let dir = TempDir()
        let log = try BriefLog(path: dir.path("briefs.db").path)
        let before = thread("a", running: true)
        log.setSeen("a", BriefThreadFacts(before))
        let seen = try BriefLog(path: dir.path("briefs.db").path).seen()
        let after = thread("a", ended: 999_500, said: "All green.", user: 999_100)
        let items = BriefLog.events(old: seen["a"], thread: after, now: now.timeIntervalSince1970)
        #expect(items.map(\.kind) == [.message, .message])
        #expect(items[0].text == "finished: All green." && items[0].status == .done && items[0].thread == "a")
        #expect(items[1].text.hasPrefix("you sent:"))
        #expect(BriefLog.events(old: BriefThreadFacts(after), thread: after, now: now.timeIntervalSince1970).isEmpty)
    }

    @Test func theWordsTheShellLacksComeFromTheThreadsEnd() {
        let before = thread("a", running: true)
        let after = thread("a", ended: 999_500, user: 999_100)
        #expect(BriefLog.needsRead(old: BriefThreadFacts(before), thread: after))
        #expect(!BriefLog.needsRead(old: BriefThreadFacts(after), thread: after))
        #expect(!BriefLog.needsRead(old: BriefThreadFacts(before), thread: thread("a", running: true, said: "Working.")))
        let long = "Yes, it helps. " + String(repeating: "Details. ", count: 200) + "Want me to post it?"
        let items = BriefLog.events(old: BriefThreadFacts(before), thread: after, now: now.timeIntervalSince1970,
                                    reads: ThreadReads(youSaid: "Does it help?", reply: long))
        #expect(items[0].text == "finished: " + long)
        let huge = "Start. " + String(repeating: "x", count: BriefLog.textCap) + " Want me to post it?"
        #expect(BriefLog.clip(huge).hasPrefix("Start.") && BriefLog.clip(huge).hasSuffix("Want me to post it?"))
        #expect(items[1].text == "you sent: Does it help?")
    }

    @Test func everyThreadOnTheBoardShowsItsLastReply() {
        let done = thread("d", ended: 999_500)
        let old = thread("o", ended: 1, active: 999_000)
        let board = T3BriefSource.boards(threads: [done, old], requests: [:], ends: ["d": "Want me to post it?", "o": "Old."], now: now)["p1"]!
        #expect(board.threads.first { $0.id == "d" }?.ends == "Want me to post it?")
        #expect(board.threads.first { $0.id == "o" }?.ends == "Old.")  // however old
        var doc = BriefDoc(project: "p1")
        doc.threads = board.threads
        #expect(RouterBriefEngine.context(doc).contains("its latest reply") && RouterBriefEngine.context(doc).contains("<session-content untrusted=\"true\">\nWant me to post it?"))
    }

    @Test func aNewRecentThreadIsNewsAndAnOldOneIsNot() {
        let recent = BriefLog.events(old: nil, thread: thread("a", said: "Started."), now: now.timeIntervalSince1970)
        #expect(recent.count == 1 && recent[0].kind == .thread && recent[0].text.contains("Started."))
        #expect(BriefLog.events(old: nil, thread: thread("b", active: 1), now: now.timeIntervalSince1970).isEmpty)
    }

    @Test func aRequestIsLoggedByItsIdWithItsWordsAndOptions() {
        let q = ThreadRequest(id: "r1", threadID: "a", body: .question([T3Question(demo: "", "Silent?", options: [("Yes", ""), ("No", "")])]))
        let item = BriefLog.request(q, title: "T", at: 5)
        #expect(item.id == "ask:r1" && item.kind == .card && item.options == ["Yes", "No"] && item.status == .needsYou)
        #expect(item.text.contains("Silent?"))
    }

    @Test func inPlayTiersTheBoard() {
        var failed = thread("f", ended: 999_900)
        failed.status = .failed; failed.unseen = true; failed.settled = true
        #expect(!T3BriefSource.listed(failed, now: now))
        #expect(!T3BriefSource.listed(thread("old", ended: 1_000_000 - 8 * 86_400, active: 1_000_000 - 8 * 86_400), now: now))
        #expect(T3BriefSource.listed(thread("ok", ended: 1_000_000 - 3 * 86_400, active: 1_000_000 - 3 * 86_400), now: now))
        var waiting = thread("w", ended: 999_000)
        waiting.settled = true; waiting.hasPlan = true
        #expect(T3BriefSource.listed(waiting, now: now))
        var snoozed = thread("s", running: true)
        snoozed.snoozedUntil = now.addingTimeInterval(3600)
        #expect(!T3BriefSource.listed(snoozed, now: now))
        var fresh = thread("p", active: 1_000_000 - 3600), stale = thread("p2", active: 1_000_000 - 2 * 86_400)
        fresh.status = .idle; stale.status = .idle
        #expect(T3BriefSource.listed(fresh, now: now))
        #expect(!T3BriefSource.listed(stale, now: now))
    }

    @Test func boardsGroupByProjectAndSayWhatWaitsOnYou() {
        var waiting = thread("w", running: true)
        waiting.pendingRequest = T3PendingRequest(json: ["id": "rq", "kind": "user_input", "blocking": true])
        let done = thread("d", ended: 999_500)
        let other = thread("o", project: "p2", running: true)
        let old = thread("old", active: 1)
        let boards = T3BriefSource.boards(threads: [waiting, done, other, old], requests: [:], now: now)
        #expect(Set(boards.keys) == ["p1", "p2"])
        let p1 = boards["p1"]!
        #expect(p1.threads.map(\.id).sorted() == ["d", "w"] && p1.watch == "live")
        #expect(p1.entries.map(\.thread) == ["w"] && p1.entries[0].kind == .question && p1.entries[0].episode == "rq")
        #expect(p1.threads.first { $0.id == "d" }?.status == .done && boards["p2"]?.threads.first?.status == .working)
        let down = T3BriefSource.boards(threads: [done], requests: [:], unreachableSince: 77, now: now)
        #expect(down["p1"]?.watch == "stale:77.0" && down["p1"]?.threads.first?.asOf == 77)
    }

    @Test func aHeldRequestDecidesTheEntrysKind() {
        var t = thread("w", running: true)
        t.hasPlan = true
        let plan = ThreadRequest(id: "p", threadID: "w", body: .plan(markdown: "# Ship"))
        let perm = ThreadRequest(id: "c", threadID: "w", body: .approval(kind: "command", prompt: "ls", decisions: ThreadRequest.fallbackDecisions))
        #expect(T3BriefSource.entry(t, project: "p1", request: plan, since: 1, asOf: nil).kind == .plan)
        #expect(T3BriefSource.entry(t, project: "p1", request: perm, since: 1, asOf: nil).kind == .permission)
        #expect(T3BriefSource.entry(t, project: "p1", request: nil, since: 1, asOf: nil).kind == .plan)
        var stopped = thread("s")
        stopped.status = .failed
        #expect(T3BriefSource.entry(stopped, project: "p1", request: nil, since: 1, asOf: nil).kind == .request)
    }

    @Test func theRulesTellThreadsAreEverythingAndAMergedPullRequestWaitsOnNobody() {
        let rules = RouterBriefEngine.rules
        #expect(rules.contains("Threads is everything that exists") && rules.contains("merged or closed waits on nobody"))
        #expect(rules.contains("agent threads") && !rules.contains("coordinator") && !rules.contains("Claude"))
        #expect(!rules.contains("Current brief") && !rules.contains("loose_ends"))
    }
}
