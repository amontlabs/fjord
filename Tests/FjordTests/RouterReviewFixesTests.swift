import Foundation
import Testing
@testable import Fjord

/// The record store's fixes from docs/design/router-v2/FINAL-REVIEW.md, each reproducing its finding.
@MainActor @Suite struct RouterReviewFixesTests {
    typealias F = RecordFixture
    typealias Harness = RouterRecordsTests.Harness

    private func last(_ changes: [RouterChange], _ id: String = "t1") -> RouterThread? {
        func all(_ c: RouterChange) -> [RouterThread] {
            switch c {
            case .upsert(let t): [t]
            case .batch(let list): list.flatMap(all)
            default: []
            }
        }
        return changes.flatMap(all).last { $0.id == id }
    }

    // MARK: #1: picks belong to one ask

    @Test func aRecordNamesTheAskItsCardAnswers() {
        let h = Harness()
        var t = F.thread(status: .waiting)
        t.pendingRequest = F.pending("req-1")
        h.records.put(t)
        #expect(last(h.take())?.askID == "req-1")
        t.pendingRequest = F.pending("req-2")
        h.records.put(t)
        #expect(last(h.take())?.askID == "req-2")
        t.pendingRequest = nil
        t.status = .running
        t.runStartedAt = F.ago(0)
        h.records.put(t)
        #expect(last(h.take())?.askID == nil)
    }

    // MARK: #2: a verdict reads the turn's reply first

    /// A harness whose records read a turn through `fetch`, as the app's do.
    private func reading() -> (Harness, () -> [(String, String)]) {
        let h = Harness()
        var fetched: [(String, String)] = []
        h.records.fetch = { fetched.append(($0, $1)) }
        return (h, { defer { fetched = [] }; return fetched })
    }

    @Test func aFinishedTurnIsReadBeforeItsVerdictIsAsked() throws {
        let (h, fetched) = reading()
        h.records.put(F.thread())
        // No reply in the shell: no verdict yet, the turn is read, and the line is being read meanwhile.
        #expect(h.verdictAsk() == nil)
        let read = try #require(fetched().first)
        #expect(read.0 == "t1")
        #expect(last(h.take())?.judging == true)
        var d = RouterDetail()
        d.reply = "PR #12 is open. Want me to merge it?"
        d.youSaid = "open the PR"
        d.diff = .init(files: 4, added: 96, removed: 212)
        h.records.read("t1", key: read.1, d)
        let ask = try #require(h.verdictAsk())
        #expect(ask.kind == .finished)
        #expect(ask.input.reply == "PR #12 is open. Want me to merge it?")
        #expect(ask.input.yourWords == "open the PR")
        #expect(ask.input.diff?.files == 4)
        // The card shows what was read.
        #expect(last(h.take())?.lastLines == "PR #12 is open. Want me to merge it?")
        // Read once per turn.
        h.records.put(F.thread())
        #expect(fetched().isEmpty)
    }

    @Test func aReadThatFailsAsksNothingAndIsTriedAtTheNextT3Event() throws {
        let (h, fetched) = reading()
        h.records.put(F.thread())
        let read = try #require(fetched().first)
        h.records.read("t1", key: read.1, nil)
        #expect(h.verdictAsk() == nil)
        // Plain Done on the code's words, not being read forever.
        #expect(h.records.record("t1")?.judging == false)
        h.records.put(F.thread())
        #expect(fetched().isEmpty)
        var seen = F.thread()
        seen.lastVisitedAt = F.now
        h.records.put(seen)
        #expect(fetched().count == 1)
    }

    @Test func aReadForAnEarlierTurnIsDropped() throws {
        let (h, fetched) = reading()
        h.records.put(F.thread())
        let old = try #require(fetched().first)
        var next = F.thread(minutes: 1)
        next.latestRunID = "r2"
        h.records.put(next)
        let current = try #require(fetched().first)
        #expect(current.1 != old.1)
        var d = RouterDetail()
        d.reply = "old reply"
        h.records.read("t1", key: old.1, d)
        #expect(h.verdictAsk() == nil)
        d.reply = "new reply"
        h.records.read("t1", key: current.1, d)
        #expect(h.verdictAsk()?.input.reply == "new reply")
    }

    @Test func aStoppedTurnIsReadForItsCard() throws {
        let (h, fetched) = reading()
        var t = F.thread(status: .failed)
        t.lastError = "exit 1"
        h.records.put(t)
        let read = try #require(fetched().first)
        var d = RouterDetail()
        d.lastStep = "Running swift build"
        d.reply = "The build failed."
        h.records.read("t1", key: read.1, d)
        let r = try #require(h.records.record("t1"))
        #expect(r.stop?.lastStep == "Running swift build")
        #expect(r.lastLines == "The build failed.")
    }

    @Test func anAskWaitsForTheRequestItsLineIsAbout() throws {
        let h = Harness()
        var t = F.thread(status: .waiting)
        t.pendingRequest = F.pending("q1")
        h.records.put(t)
        #expect(h.verdictAsk() == nil)
        var d = RouterDetail()
        d.request = F.question("Sidebar or tabs?", id: "q1")
        h.records.detail("t1", d)
        let ask = try #require(h.verdictAsk())
        #expect(ask.kind == .ask)
        #expect(ask.input.request?.words == "Sidebar or tabs?")
    }

    @Test func theVerdictsSavedBeforeTheReadAreThrownAway() throws {
        // Version 1 was a bare dictionary: verdicts often asked without the reply.
        let v1 = try JSONEncoder().encode(["t1": RouterRecords.Saved(fingerprint: "f", verdict: RouterVerdict(kind: .finished, line: "finished"))])
        #expect(RouterVerdictFile.decode(v1).isEmpty)
        let saved = ["t1": RouterRecords.Saved(fingerprint: "f", verdict: RouterVerdict(kind: .finished, line: "planted"))]
        let v2 = try #require(RouterVerdictFile.encode(saved))
        #expect(RouterVerdictFile.decode(v2) == saved)
    }

    @Test func turnReadsRunAFewAtOnceAndTheNewestAskForAThreadWins() async {
        var gates: [String: CheckedContinuation<Void, Never>] = [:]
        var answered: [(String, String)] = []
        let reads = RouterTurnReads(read: { id in
            await withCheckedContinuation { gates[id] = $0 }
            return nil
        }, cap: 2)
        reads.done = { id, key, _ in answered.append((id, key)) }
        reads.read("a", key: "1")
        reads.read("b", key: "1")
        reads.read("c", key: "1")
        reads.read("c", key: "2")
        await waitUntil { gates.count == 2 }
        #expect(reads.runningCount == 2)
        #expect(reads.waitingCount == 1)
        gates.removeValue(forKey: "a")?.resume()
        await waitUntil { gates["c"] != nil }
        gates.removeValue(forKey: "b")?.resume()
        gates.removeValue(forKey: "c")?.resume()
        await waitUntil { answered.count == 3 }
        #expect(answered.map(\.0).sorted() == ["a", "b", "c"])
        #expect(answered.first { $0.0 == "c" }?.1 == "2")
    }

    // MARK: #6: a hide ends on T3's word about the act

    @Test func aSettledThreadStillWorkingInTheBackgroundComesBackWhenItAsksAgain() {
        let h = Harness()
        var t = F.thread()
        t.pendingTasks = [T3PendingTask(json: ["taskId": "b1", "description": "Review the changes"])]
        h.records.put(t)
        #expect(h.records.record("t1")?.state == .working)
        h.records.hide("t1", on: true)
        #expect(h.records.record("t1") == nil)
        // T3 takes the settle; Fjord still counts the background work as live.
        t.settled = true
        t.settledAt = F.now
        h.records.put(t)
        // The work ends, T3 wakes the thread and it asks a permission: the line is back.
        t.pendingTasks = []
        t.status = .waiting
        t.latestRunID = "r2"
        t.pendingRequest = F.pending("perm-1", kind: "command")
        h.records.put(t)
        #expect(h.records.record("t1")?.state == .needsYou(.permission))
    }

    @Test func aSettledPlanStaysSettled() {
        let h = Harness()
        var t = F.thread()
        t.hasPlan = true
        h.records.put(t)
        #expect(h.records.record("t1")?.state == .needsYou(.plan))
        h.records.hide("t1", on: true)
        t.settled = true
        t.settledAt = F.now
        h.records.put(t)
        #expect(h.records.record("t1") == nil)
        // And after a relaunch, with nothing pending here.
        let fresh = Harness()
        fresh.records.put(t)
        #expect(fresh.records.record("t1") == nil)
    }

    // MARK: #7: a cancelled queued message stays cancelled

    @Test func aCancelledQueuedRunStaysHiddenAndOnlyIt() {
        let h = Harness()
        var t = F.thread(status: .running)
        t.runStartedAt = F.ago(1)
        h.records.put(t)
        h.records.began(send: RouterActs.Send(thread: "t1", words: "and add tests", kind: .queue, at: F.now))
        #expect(h.records.record("t1")?.queued == "and add tests")
        h.records.cancelledQueue("t1", run: nil, on: true)
        #expect(h.records.record("t1")?.queued == nil)
        // T3 lists it with a subagent's completion queued before it: the cancelled one stays hidden, the other shows.
        var d = RouterDetail()
        d.queued = [.init(id: "run-mine", words: "and add tests")]
        h.records.cancelledQueue("t1", run: "run-mine", on: true)
        h.records.detail("t1", d)
        #expect(h.records.record("t1")?.queued == nil)
        d.queued = [.init(id: "run-sub", words: "subagent done"), .init(id: "run-mine", words: "and add tests")]
        h.records.detail("t1", d)
        #expect(h.records.record("t1")?.queued == "subagent done")
        // T3 kept it after all: it shows again.
        d.queued = [.init(id: "run-mine", words: "and add tests")]
        h.records.detail("t1", d)
        h.records.cancelledQueue("t1", run: "run-mine", on: false)
        #expect(h.records.record("t1")?.queued == "and add tests")
    }

    // MARK: #10: a send that starts no run ends on the row

    @Test func aSendT3TookThatStartsNoRunEndsWhenTheRowFails() {
        let h = Harness()
        var t = F.thread()
        h.records.put(t)
        h.records.began(send: RouterActs.Send(thread: "t1", words: "go on", kind: .words, at: F.now))
        #expect(h.records.record("t1")?.state == .sent)
        // The provider session fails before T3 makes a run: same run id, the row failed.
        t.status = .failed
        t.lastError = "provider session failed to start"
        h.records.put(t)
        #expect(h.records.record("t1")?.state == .stopped)
    }

    @Test func aSendEndsWhenTheRunsEndMovesPastIt() {
        let h = Harness()
        var t = F.thread()
        h.records.put(t)
        h.records.began(send: RouterActs.Send(thread: "t1", words: "go on", kind: .words, at: F.now))
        t.lastRunEndedAt = F.now.addingTimeInterval(5)
        h.records.put(t)
        #expect(h.records.record("t1")?.state != .sent)
    }

    // MARK: #11: a detail from a closed subscription is read again at the turn's end

    @Test func aSubscriptionsLastDetailGivesWayToTheTurnsRead() throws {
        let (h, fetched) = reading()
        var t = F.thread(status: .running)
        t.runStartedAt = F.ago(1)
        h.records.put(t)
        var live = RouterDetail()
        live.reply = "Moving the beds"
        live.writing = true
        h.records.detail("t1", live)
        // The shell says completed; the subscription closes without a word.
        t.status = .completed
        h.records.put(t)
        let read = try #require(fetched().first)
        var done = RouterDetail()
        done.reply = "Moved the beds."
        done.diff = .init(files: 4, added: 96, removed: 212)
        h.records.read("t1", key: read.1, done)
        let r = try #require(h.records.record("t1"))
        #expect(!r.writing)
        #expect(r.diff == .init(files: 4, added: 96, removed: 212))
        #expect(r.lastLines == "Moved the beds.")
    }
}
