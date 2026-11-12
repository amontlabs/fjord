import Foundation
import Testing
@testable import Fjord

/// Shell rows and projection reads as values, for the Router v2 records' tests (no socket, no store).
enum RecordFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    /// A thread whose run `r1` finished `minutes` ago, seen then.
    static func thread(_ id: String = "t1", title: String = "Tidy the garden notes", status: T3Status = .completed,
                       minutes: Double = 5, folder: String? = "/code/app") -> AgentThread {
        let ended = ago(minutes)
        var t = AgentThread(id: id, projectID: "p1", title: title, folder: folder, status: status, lastActivity: ended, activityAt: ended)
        t.lastRunEndedAt = ended
        t.latestRunID = "r1"
        t.lastVisitedAt = ended
        return t
    }

    static func pending(_ id: String = "q1", kind: String = "user_input", minutes: Double = 2, blocking: Bool = true) -> T3PendingRequest {
        T3PendingRequest(json: ["id": .string(id), "kind": .string(kind), "createdAt": .string(T3Timestamp.format(ago(minutes))),
                                "blocking": .bool(blocking)])!
    }

    static func question(_ text: String, options: [String] = ["Yes", "No"], id: String = "q1") -> ThreadRequest {
        ThreadRequest(id: id, threadID: "t1", body: .question([T3Question(demo: "Q", text, options: options.map { ($0, "") })]))
    }

    static func working(_ text: String, mono: Bool = false, minutes: Double = 3) -> RouterDetail {
        var d = RouterDetail()
        d.working = .init(text: text, mono: mono, since: ago(minutes))
        return d
    }
}

/// A thread's code state, scope and fingerprint, from T3's row (IMPLEMENTATION.md 1.3).
@Suite struct RouterCodeStateTests {
    typealias F = RecordFixture
    private let now = RecordFixture.now

    private func make(_ t: AgentThread, _ d: RouterDetail? = nil) -> RouterCodeState { RouterCodeState.make(thread: t, detail: d, now: now) }

    // MARK: The table, row by row

    @Test func aBlockingQuestionBeforeItsProjectionIsAnAskWithItsSkeleton() {
        var t = F.thread(status: .waiting)
        t.pendingRequest = F.pending(minutes: 2)
        let s = make(t)
        #expect(s.state == .needsYou(.question))
        #expect(s.loading)
        #expect(s.wants == .ask)
        #expect(s.since == F.ago(2))
        t.pendingRequest = F.pending(kind: "command")
        #expect(make(t).state == .needsYou(.permission))
    }

    @Test func aHeldRequestSaysItsOwnWords() {
        var t = F.thread(status: .waiting)
        t.pendingRequest = F.pending()
        var d = RouterDetail()
        d.request = F.question("Sidebar, one page, or tabs?\nMore detail here.")
        let one = make(t, d)
        #expect(one.state == .needsYou(.question))
        #expect(one.line == "Sidebar, one page, or tabs?")
        #expect(!one.loading)

        d.request = ThreadRequest(id: "q1", threadID: "t1", body: .question([
            T3Question(demo: "A", "How should updates install?", options: [("Silently", "")]),
            T3Question(demo: "B", "Which channel?", options: [("Stable", "")]),
        ]))
        let form = make(t, d)
        #expect(form.state == .needsYou(.form))
        #expect(form.line == "2 questions: How should updates install?")

        d.request = ThreadRequest(id: "q1", threadID: "t1", body: .approval(kind: "command", prompt: "git worktree remove --force ../x",
                                                                          decisions: [.accept, .decline]))
        let permission = make(t, d)
        #expect(permission.state == .needsYou(.permission))
        #expect(permission.line == "git worktree remove --force ../x")
        #expect(permission.mono)
    }

    @Test func aRequestWinsOverARunningTurn() {
        var t = F.thread(status: .running)
        t.pendingRequest = F.pending()
        #expect(make(t, F.working("Editing Foo.swift")).state == .needsYou(.question))
    }

    @Test func aPlanSaysItsFirstLine() {
        var t = F.thread()
        t.hasPlan = true
        let bare = make(t)
        #expect(bare.state == .needsYou(.plan))
        #expect(bare.line == "plan ready")
        #expect(bare.loading)
        var d = RouterDetail()
        d.request = ThreadRequest(id: "plan1", threadID: "t1", body: .plan(markdown: "# Move briefs into BriefLog\n- copy the rows"))
        #expect(make(t, d).line == "plan ready: Move briefs into BriefLog")
        // A plan the shell no longer offers is past.
        t.hasPlan = false
        #expect(make(t, d).state == .done)
    }

    @Test func aRunningThreadSaysWhatItIsOn() {
        var t = F.thread(status: .running)
        t.runStartedAt = F.ago(3)
        let bare = make(t)
        #expect(bare.state == .working)
        #expect(bare.line == RouterV2.Copy.starting)
        #expect(bare.since == F.ago(3))
        #expect(bare.wants == .nothing)
        let command = make(t, F.working("swift build", mono: true, minutes: 4))
        #expect(command.line == "swift build")
        #expect(command.mono)
        #expect(command.since == F.ago(4))
        // Work it left running after the turn keeps it Working.
        var bg = F.thread(status: .completed)
        bg.pendingTasks = [T3PendingTask(json: ["taskId": "a", "kind": "subagent", "description": "Review the changes"])]
        #expect(make(bg).state == .working)
        #expect(make(bg).line == "background: Review the changes")
    }

    @Test func aUsageLimitThatResumesIsPausedWorkAndOneThatDoesntIsAStop() {
        var t = F.thread(status: .failed)
        t.usageLimit = true
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        t.limitResetAt = c.date(bySettingHour: 15, minute: 5, second: 0, of: now)
        let paused = make(t)
        #expect(paused.state == .working)
        #expect(paused.paused)
        #expect(paused.line == "paused at the usage limit, resumes 15:05")
        t.limitStopped = true
        let stopped = make(t)
        #expect(stopped.state == .stopped)
        #expect(stopped.line == "hit the usage limit")
        #expect(stopped.since == F.ago(5))
    }

    @Test func aFailureOrAnInterruptYouDidntAskForIsAStop() {
        var t = F.thread(status: .failed)
        t.lastError = "The connection to Claude dropped\nstack…"
        #expect(make(t).state == .stopped)
        #expect(make(t).line == "failed: The connection to Claude dropped")
        #expect(make(t).wants == .nothing)
        let interrupted = make(F.thread(status: .interrupted))
        #expect(interrupted.state == .stopped)
        #expect(interrupted.line == RouterV2.Copy.interrupted)
    }

    @Test func aRunYouStoppedIsDoneQuietWithNoVerdict() {
        var t = F.thread(status: .interrupted)
        t.stopRequested = true
        let s = make(t)
        #expect(s.state == .done)
        #expect(s.line == RouterV2.Copy.stoppedByYou)
        #expect(s.wants == .nothing)
    }

    @Test func anyOtherEndIsDoneAndAsksForAVerdict() {
        let s = make(F.thread(minutes: 7))
        #expect(s.state == .done)
        #expect(s.line == RouterV2.Copy.finished)
        #expect(s.since == F.ago(7))
        #expect(s.wants == .finished)
    }

    // MARK: Scope

    @Test func aFinishedThreadHasALineForADayThenTheHousekeepingLineForAWeek() {
        func scope(_ minutes: Double) -> RouterCodeState.Scope {
            let t = F.thread(minutes: minutes)
            return RouterCodeState.scope(t, state: make(t), now: now)
        }
        #expect(scope(23 * 60) == .line)
        #expect(scope(25 * 60) == .older)
        #expect(scope(6 * 24 * 60) == .older)
        #expect(scope(8 * 24 * 60) == .out)
        // Never run: nothing to say.
        var never = F.thread(status: .idle)
        never.lastRunEndedAt = nil
        #expect(RouterCodeState.scope(never, state: make(never), now: now) == .out)
    }

    @Test func settledSnoozedAndSettledFailedUnseenAreOut() {
        var t = F.thread(status: .failed)
        t.unseen = true
        t.settled = true
        #expect(RouterCodeState.scope(t, state: make(t), now: now) == .out)
        var snoozed = F.thread()
        snoozed.snoozedUntil = now.addingTimeInterval(3600)
        #expect(RouterCodeState.scope(snoozed, state: make(snoozed), now: now) == .out)
        #expect(RouterCodeState.boundary(snoozed, state: make(snoozed), now: now) == now.addingTimeInterval(3600))
        // Settled but waiting on you: still yours.
        var waiting = F.thread(status: .waiting)
        waiting.settled = true
        waiting.pendingRequest = F.pending()
        #expect(RouterCodeState.scope(waiting, state: make(waiting), now: now) == .line)
    }

    @Test func aRowPlainlyOffThePageIsOneScopeSaysIsOut() {
        var rows: [AgentThread] = []
        let statuses: [T3Status] = [.completed, .running, .failed, .interrupted, .idle, .waiting]
        let day: Double = 24 * 60
        let ages: [Double] = [5, day - 60, day + 60, 6 * day, 8 * day, 30 * day]
        for status in statuses {
            for minutes in ages {
                for variant in 0..<6 {
                    var t = F.thread(status: status, minutes: minutes)
                    switch variant {
                    case 1: t.settled = true
                    case 2: t.snoozedUntil = now.addingTimeInterval(60)
                    case 3: t.pendingRequest = F.pending()
                    case 4: t.usageLimit = true
                    case 5: t.lastRunEndedAt = nil
                    default: break
                    }
                    if status == .running { t.runStartedAt = F.ago(1) }
                    rows.append(t)
                }
            }
        }
        for t in rows where RouterCodeState.plainlyOut(t, inPlay: t.inPlay(now: now), now: now) {
            #expect(RouterCodeState.scope(t, state: make(t), now: now) == .out, "\(t.status.rawValue) \(t.lastActivity)")
        }
    }

    @Test func theNextBoundaryIsADayThenAWeekAfterTheFinish() {
        let t = F.thread(minutes: 60)
        #expect(RouterCodeState.boundary(t, state: make(t), now: now) == F.ago(60).addingTimeInterval(86_400))
        let old = F.thread(minutes: 2 * 24 * 60)
        #expect(RouterCodeState.boundary(old, state: make(old), now: now) == F.ago(2 * 24 * 60).addingTimeInterval(7 * 86_400))
        var running = F.thread(status: .running)
        running.runStartedAt = F.ago(1)
        #expect(RouterCodeState.boundary(running, state: make(running), now: now) == nil)
    }

    // MARK: Fingerprint and the new dot

    @Test func theFingerprintMovesWithTheRunTheRequestThePlanThePRsAndYourWords() {
        let t = F.thread()
        let base = RouterCodeState.fingerprint(t)
        #expect(RouterCodeState.fingerprint(t) == base)
        var u = t; u.latestRunID = "r2"
        #expect(RouterCodeState.fingerprint(u) != base)
        u = t; u.pendingRequest = F.pending()
        #expect(RouterCodeState.fingerprint(u) != base)
        u = t; u.hasPlan = true
        #expect(RouterCodeState.fingerprint(u) != base)
        u = t; u.lastAuthoredAt = F.ago(1)
        #expect(RouterCodeState.fingerprint(u) != base)
        // Not what doesn't change the verdict: a title, a visit, the row's update time.
        u = t; u.title = "Renamed"; u.lastVisitedAt = now; u.lastActivity = now
        #expect(RouterCodeState.fingerprint(u) == base)

        let a = T3PullRequest(json: ["url": "https://github.com/a/b/pull/1", "snapshot": ["state": "open"]])
        let b = T3PullRequest(json: ["url": "https://github.com/a/b/pull/2", "snapshot": ["state": "open"]])
        var merged = b
        merged.state = "merged"
        u = t; u.pullRequests = [a, b]
        var v = t; v.pullRequests = [b, a]
        #expect(RouterCodeState.fingerprint(u) == RouterCodeState.fingerprint(v))
        v.pullRequests = [a, merged]
        #expect(RouterCodeState.fingerprint(u) != RouterCodeState.fingerprint(v))
    }

    @Test func theNewDotIsUnseenOrARequestMadeAfterYourLastVisit() {
        var t = F.thread(minutes: 10)
        #expect(!RouterCodeState.isNew(t))
        t.unseen = true
        #expect(RouterCodeState.isNew(t))
        t.unseen = false
        t.pendingRequest = F.pending(minutes: 2)
        #expect(RouterCodeState.isNew(t))
        t.lastVisitedAt = F.ago(1)
        #expect(!RouterCodeState.isNew(t))
    }
}
