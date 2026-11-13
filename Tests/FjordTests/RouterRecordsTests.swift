import Foundation
import Testing
@testable import Fjord

/// The Router v2 record store: one record per thread from code, verdict and pending acts, handing on only what changed.
@MainActor @Suite struct RouterRecordsTests {
    typealias F = RecordFixture

    @MainActor final class Harness {
        let gate = MotionGate.Gate(longest: 600)
        let records: RouterRecords
        var changes: [RouterChange] = []
        var asks: [RouterVerdictRequest] = []
        var cancels: [String] = []
        var clock = RecordFixture.now

        init(saved: [String: RouterRecords.Saved] = [:]) {
            records = RouterRecords(saved: saved, gate: gate)
            records.now = { [unowned self] in self.clock }
            records.emit = { [unowned self] in self.changes.append($0) }
            records.ask = { [unowned self] in self.asks.append($0) }
            records.cancel = { [unowned self] in self.cancels.append($0) }
        }

        /// The changes so far, taken.
        func take() -> [RouterChange] {
            defer { changes = [] }
            return changes
        }

        func verdictAsk(_ id: String = "t1") -> RouterVerdictRequest? { asks.last { $0.thread == id && $0.kind != .name } }
    }

    private func send(_ kind: RouterActs.Send.Kind = .words, words: String = "go on", thread: String = "t1") -> RouterActs.Send {
        RouterActs.Send(thread: thread, words: words, kind: kind, at: F.now)
    }

    /// The main queue's next turn (what the records defer to it has run).
    private func nextTurn() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
    }

    private func upserts(_ changes: [RouterChange]) -> [RouterThread] {
        changes.flatMap { c -> [RouterThread] in
            switch c {
            case .upsert(let t): [t]
            case .batch(let all): upserts(all)
            default: []
            }
        }
    }

    // MARK: Only what changed

    @Test func oneShellRowEmitsAtMostOneChangeAndAnUnchangedRowNone() {
        let h = Harness()
        h.records.put(F.thread())
        let first = h.take()
        #expect(first.count == 1)
        #expect(upserts(first).first?.state == .done)
        h.records.put(F.thread())
        #expect(h.take().isEmpty)
        var running = F.thread(status: .running)
        running.latestRunID = "r2"
        running.runStartedAt = F.ago(0)
        h.records.put(running)
        let next = h.take()
        #expect(next.count == 1)
        #expect(upserts(next).first?.state == .working)
    }

    @Test func theWholeShellIsOneBatch() {
        let h = Harness()
        h.records.replace([F.thread("a"), F.thread("b", status: .running), F.thread("c", minutes: 2 * 24 * 60)])
        let changes = h.take()
        #expect(changes.count == 1)
        guard case .batch(let all)? = changes.first else { Issue.record("one batch"); return }
        #expect(Set(upserts(all).map(\.id)) == ["a", "b"])
        #expect(all.contains(.older([RouterOlder(id: "c", name: "Tidy the garden notes", project: "app", since: F.ago(2 * 24 * 60))])))
    }

    @Test func theCardsLastLinesAloneTakeTheHotPath() {
        let h = Harness()
        var t = F.thread(status: .running)
        t.runStartedAt = F.ago(1)
        h.records.put(t)
        var d = F.working("Editing Foo.swift")
        h.records.detail("t1", d)
        _ = h.take()
        d.reply = "I moved the"
        d.writing = true
        h.records.detail("t1", d)
        #expect(h.take() == [.reply("t1", text: "I moved the", writing: true)])
    }

    // MARK: Verdicts

    @Test func aFinishedTurnAsksOnceAndItsVerdictLandsStateFirstThenWords() {
        let h = Harness()
        h.records.put(F.thread())
        let ask = h.verdictAsk()
        #expect(ask?.kind == .finished)
        #expect(h.records.record("t1")?.sentence.phase == .reassessing)
        // Until the verdict's state is in, it is being read: not a Done line yet.
        #expect(h.records.record("t1")?.judging == true)
        #expect(h.records.record("t1")?.reading == true)
        _ = h.take()
        h.records.put(F.thread())
        #expect(h.asks.filter { $0.kind == .finished }.count == 1)

        let fp = ask!.fingerprint
        h.records.verdict("t1", fingerprint: fp, .state(needsYou: true, worth: .quiet))
        let landed = upserts(h.take()).first
        #expect(landed?.state == .needsYou(.step))
        #expect(landed?.judging == false)
        h.records.verdict("t1", fingerprint: fp, .words("reserve for", done: false))
        h.records.verdict("t1", fingerprint: fp, .words("reserve for five?", done: true))
        #expect(h.take() == [.words("t1", stream: 1, text: "reserve for", done: false),
                             .words("t1", stream: 1, text: "reserve for five?", done: true)])
        let v = RouterVerdict(kind: .finished, needsYou: true, name: "Val Cenis booking", line: "reserve for five?",
                              ask: "Reserve for five, or keep it at four?", options: ["Five", "Four"], result: "found the chalet")
        h.records.verdict("t1", fingerprint: fp, .done(v))
        let r = h.records.record("t1")
        #expect(r?.state == .needsYou(.step))
        #expect(r?.question == "Reserve for five, or keep it at four?")
        #expect(r?.options == ["Five", "Four"])
        #expect(r?.sentence.text == "reserve for five?")
        #expect(r?.sentence.stream == 1)
        #expect(r?.name == "Val Cenis booking")
        #expect(r?.naming == false)
        #expect(h.records.needsYou == 1)
    }

    /// With the Router off no verdict comes: a finished turn is plain Done on the code's words, not "being read"; switched
    /// on, it is asked for and read.
    @Test func withTheRouterOffAFinishedTurnIsPlainDoneAndIsReadOnceItIsOn() {
        let h = Harness()
        var on = false
        h.records.canAsk = { on }
        h.records.put(F.thread())
        let off = h.records.record("t1")
        #expect(h.asks.isEmpty)
        #expect(off?.state == .done && off?.judging == false && off?.reading == false && off?.naming == false)
        #expect(off?.sentence.phase == .settled)
        on = true
        h.records.askingChanged()
        #expect(h.verdictAsk()?.kind == .finished)
        #expect(h.records.record("t1")?.reading == true)
        // Off again before it lands: the call is cancelled and the line is plain Done again.
        on = false
        h.records.askingChanged()
        #expect(h.cancels.contains("t1"))
        #expect(h.records.record("t1")?.reading == false && h.records.record("t1")?.state == .done)
    }

    @Test func aVerdictForAnOldFingerprintIsDropped() {
        let h = Harness()
        h.records.put(F.thread())
        let old = h.verdictAsk()!.fingerprint
        var t = F.thread()
        t.latestRunID = "r2"
        h.records.put(t)
        #expect(h.cancels == ["t1"])
        let current = h.verdictAsk()!.fingerprint
        #expect(current != old)
        _ = h.take()
        h.records.verdict("t1", fingerprint: old, .done(RouterVerdict(kind: .finished, worth: .look, line: "stale")))
        #expect(h.take().isEmpty)
        h.records.verdict("t1", fingerprint: current, .done(RouterVerdict(kind: .finished, worth: .look, line: "merged #41")))
        #expect(h.records.record("t1")?.sentence.text == "merged #41")
        #expect(h.records.record("t1")?.worth == .look)
    }

    @Test func aRunStartingCancelsTheVerdictAndNothingIsWritten() {
        let h = Harness()
        h.records.put(F.thread())
        let fp = h.verdictAsk()!.fingerprint
        var t = F.thread(status: .running)
        t.runStartedAt = F.ago(0)
        h.records.put(t)
        #expect(h.cancels == ["t1"])
        h.records.verdict("t1", fingerprint: fp, .done(RouterVerdict(kind: .finished, line: "late")))
        #expect(h.records.record("t1")?.state == .working)
        #expect(h.records.saved["t1"]?.verdict == nil)
    }

    @Test func aFailedCallSettlesOnTheCodesWords() {
        let h = Harness()
        h.records.put(F.thread())
        h.records.verdict("t1", fingerprint: h.verdictAsk()!.fingerprint, .failed)
        let s = h.records.record("t1")?.sentence
        #expect(s?.text == Router.Copy.finished)
        #expect(s?.phase == .settled)
        h.records.put(F.thread())
        #expect(h.asks.filter { $0.kind == .finished }.count == 1)
    }

    @Test func notForMeSurvivesARestartAndDiesWithTheFingerprint() {
        let h = Harness()
        h.records.put(F.thread())
        let fp = h.verdictAsk()!.fingerprint
        h.records.verdict("t1", fingerprint: fp, .done(RouterVerdict(kind: .finished, needsYou: true, line: "merge #41?",
                                                                     ask: "Merge #41?", result: "opened #41")))
        #expect(h.records.record("t1")?.state == .needsYou(.step))
        h.records.notForMe("t1", on: true)
        #expect(h.records.record("t1")?.state == .done)
        #expect(h.records.record("t1")?.worth == .look)
        #expect(h.records.record("t1")?.sentence.text == "opened #41")

        // A relaunch: the file's contents, the same row. No call: the verdict and the mark are kept.
        let again = Harness(saved: h.records.saved)
        again.records.put(F.thread())
        #expect(again.asks.filter { $0.kind == .finished }.isEmpty)
        #expect(again.records.record("t1")?.state == .done)
        // Known at once: not read again.
        #expect(again.records.record("t1")?.judging == false)
        #expect(again.records.record("t1")?.sentence.text == "opened #41")

        // The next turn: the mark is for the old fingerprint.
        var t = F.thread()
        t.latestRunID = "r2"
        again.records.put(t)
        let next = again.verdictAsk()!.fingerprint
        again.records.verdict("t1", fingerprint: next, .done(RouterVerdict(kind: .finished, needsYou: true, line: "merge #42?",
                                                                          ask: "Merge #42?")))
        #expect(again.records.record("t1")?.state == .needsYou(.step))
    }

    @Test func aThreadWithNoNameIsNamedOnceForItsTitle() {
        let h = Harness()
        var t = F.thread(status: .running)
        t.runStartedAt = F.ago(1)
        h.records.put(t)
        let name = h.asks.first { $0.kind == .name }
        #expect(name?.fingerprint == t.title)
        #expect(h.records.record("t1")?.naming == true)
        _ = h.take()
        h.records.verdict("t1", fingerprint: t.title, .done(RouterVerdict(kind: .name, name: "Garden notes")))
        #expect(h.take() == [.named("t1", "Garden notes")])
        h.records.put(t)
        #expect(h.asks.filter { $0.kind == .name }.count == 1)
    }

    @Test func aNameForATitleT3ChangedMeanwhileIsDroppedAndTheNewTitleAsked() {
        let h = Harness()
        var t = F.thread(status: .running)
        t.runStartedAt = F.ago(1)
        h.records.put(t)
        let first = t.title
        t.title = "Water the tomatoes"
        h.records.put(t)
        h.records.verdict("t1", fingerprint: first, .done(RouterVerdict(kind: .name, name: "Garden notes")))
        #expect(h.records.record("t1")?.name != "Garden notes")
        #expect(h.asks.last?.kind == .name)
        #expect(h.asks.last?.fingerprint == "Water the tomatoes")
        h.records.verdict("t1", fingerprint: "Water the tomatoes", .done(RouterVerdict(kind: .name, name: "Tomatoes")))
        #expect(h.records.record("t1")?.name == "Tomatoes")
    }

    // MARK: Pending acts

    @Test func aPendingSendHoldsSentUntilTheRunShows() {
        let h = Harness()
        h.records.put(F.thread())
        h.records.began(send: send())
        #expect(h.records.record("t1")?.state == .sent)
        #expect(h.records.record("t1")?.sent == .init(words: "go on", status: .sending))
        // The row moves without a run: still Sent.
        var t = F.thread()
        t.lastActivity = F.now
        h.records.put(t)
        #expect(h.records.record("t1")?.state == .sent)
        h.records.took(send: send())
        #expect(h.records.record("t1")?.sent?.status == .taken)
        // The run it started.
        t.status = .running
        t.latestRunID = "r2"
        t.runStartedAt = F.now
        h.records.put(t)
        #expect(h.records.record("t1")?.state == .working)
        #expect(h.records.record("t1")?.sent == nil)
    }

    @Test func aRefusalEndsTheSendAtOnceAndTheRecordFollowsTheRefusal() async {
        let h = Harness()
        h.records.put(F.thread())
        h.records.began(send: send())
        _ = h.take()
        h.records.ended(send: send())
        // The acts emit `.refused` now; the record comes in the next turn, after it.
        #expect(h.take().isEmpty)
        await nextTurn()
        #expect(h.records.record("t1")?.state == .done)
        #expect(upserts(h.take()).first?.state == .done)
    }

    @Test func aSteerSteersUntilTheRunItWentIntoEnds() {
        let h = Harness()
        var t = F.thread(status: .running)
        t.runStartedAt = F.ago(2)
        h.records.put(t)
        h.records.began(send: send(.steer))
        h.records.took(send: send(.steer))
        #expect(h.records.record("t1")?.sent?.status == .steering)
        h.records.put(t)
        #expect(h.records.record("t1")?.state == .sent)
        h.records.delivered("t1")
        #expect(h.records.record("t1")?.state == .working)
    }

    @Test func aNewThreadStartedHereIsSentBeforeT3ListsIt() {
        let h = Harness()
        let launch = RouterLaunch.t3Default
        h.records.began(send: send(.start(project: "app", launch: launch, name: nil), words: "Add a dark mode to the settings page", thread: "n1"))
        let r = h.records.record("n1")
        #expect(r?.state == .sent)
        #expect(r?.naming == true)
        #expect(r?.launch == launch)
        #expect(r?.name == Router.firstWords("Add a dark mode to the settings page"))
        // T3 lists it before its run: still Sent. The run: Working, its settings kept through it.
        var t = F.thread("n1", status: .idle)
        t.lastRunEndedAt = nil
        t.latestRunID = nil
        h.records.put(t)
        #expect(h.records.record("n1")?.state == .sent)
        t.status = .running
        t.latestRunID = "r1"
        t.runStartedAt = F.now
        h.records.put(t)
        #expect(h.records.record("n1")?.state == .working)
        #expect(h.records.record("n1")?.launch == launch)
    }

    @Test func aRefusedNewThreadLeaves() async {
        let h = Harness()
        let s = send(.start(project: "app", launch: .t3Default, name: nil), words: "Start it", thread: "n1")
        h.records.began(send: s)
        _ = h.take()
        h.records.ended(send: s)
        await nextTurn()
        #expect(h.take() == [.remove("n1")])
        #expect(h.records.record("n1") == nil)
    }

    @Test func aSettleHidesTheLineUntilT3SaysAndItsRevertBringsItBack() {
        let h = Harness()
        h.records.put(F.thread())
        h.records.hide("t1", on: true)
        #expect(h.take().last == .remove("t1"))
        var settled = F.thread()
        settled.settled = true
        h.records.put(settled)
        #expect(h.records.record("t1") == nil)
        // The Revert: back at once, though T3 still says settled.
        h.records.hide("t1", on: false)
        #expect(h.records.record("t1") != nil)
        h.records.put(settled)
        #expect(h.records.record("t1") != nil)
        h.records.put(F.thread())
        #expect(h.records.record("t1") != nil)
    }

    @Test func aSnoozeEndsByTheClock() {
        let h = Harness()
        var t = F.thread()
        t.snoozedUntil = F.now.addingTimeInterval(3600)
        h.records.put(t)
        #expect(h.records.record("t1") == nil)
        h.clock = F.now.addingTimeInterval(3601)
        h.records.tick()
        #expect(h.records.record("t1") != nil)
    }

    @Test func theNewDotGoesWhenTheCardOpensAndStaysGoneWhenT3Agrees() {
        let h = Harness()
        var t = F.thread()
        t.unseen = true
        h.records.put(t)
        #expect(h.records.record("t1")?.isNew == true)
        h.records.seen("t1")
        #expect(h.records.record("t1")?.isNew == false)
        h.records.put(t)
        #expect(h.records.record("t1")?.isNew == false)
        t.unseen = false
        t.lastVisitedAt = F.now
        h.records.put(t)
        #expect(h.records.record("t1")?.isNew == false)
    }

    @Test func theHousekeepingLineTakesTheWeeksFinishedThreads() {
        let h = Harness()
        h.records.put(F.thread("old", minutes: 2 * 24 * 60))
        #expect(h.records.olderLines.map(\.id) == ["old"])
        #expect(h.records.record("old") == nil)
        h.records.hide("old", on: true)
        #expect(h.records.olderLines.isEmpty)
        #expect(h.take().last == .older([]))
    }

    @Test func theNeedsYouCountFollowsTheLines() {
        let h = Harness()
        var counts: [Int] = []
        h.records.onNeedsYou = { counts.append($0) }
        var ask = F.thread("a", status: .waiting)
        ask.pendingRequest = F.pending()
        h.records.replace([ask, F.thread("b", status: .failed), F.thread("c")])
        #expect(h.records.needsYou == 2)
        h.records.drop("b")
        #expect(h.records.needsYou == 1)
        #expect(counts.last == 1)
    }

    // MARK: T3's shell and the file

    @Test func aShellItemIsReadThroughT3sOwnRows() {
        let h = Harness()
        var shell = T3Fixture.state([T3Fixture.thread("t1", status: "running", extra: ["activityRunStartedAt": .string(T3Timestamp.format(F.ago(1)))])])
        h.records.rows = { shell }
        h.records.shell(nil)
        #expect(h.records.record("t1")?.state == .working)
        #expect(h.records.record("t1")?.project == "app")
        let gone = T3ShellItem.threadRemoved(sequence: 101, location: .active, threadId: "t1")
        shell.apply(gone)
        h.records.shell(gone)
        #expect(h.records.record("t1") == nil)
    }

    @Test func theVerdictFileKeepsWhatTheStoreSavedAndDropsWhatT3NoLongerLists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-verdicts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = RouterVerdictFile.live(dir)
        let h = Harness()
        let records = RouterRecords(file: file, gate: h.gate)
        records.now = { F.now }
        var asks: [RouterVerdictRequest] = []
        records.ask = { asks.append($0) }
        records.put(F.thread("t1"))
        records.put(F.thread("t2"))
        for a in asks where a.kind == .finished {
            records.verdict(a.thread, fingerprint: a.fingerprint, .done(RouterVerdict(kind: .finished, worth: .look, name: "Garden", line: "planted")))
        }
        records.flush()
        let loaded = await RouterVerdictFile.load(file.url)
        #expect(loaded["t1"]?.verdict?.line == "planted")
        #expect(loaded["t1"]?.name == "Garden")
        // T3 says what it has: t2 is gone, so is what the file kept of it.
        records.rows = { T3Fixture.state([T3Fixture.thread("t1")]) }
        records.drop("t2")
        records.shell(.synchronized)
        records.flush()
        let purged = await RouterVerdictFile.load(file.url)
        #expect(Set(purged.keys) == ["t1"])
    }

    // MARK: Banners, from the records

    private func harness(saved: [String: RouterRecords.Saved] = [:]) -> (Harness, () -> [ThreadNotice]) {
        let h = Harness(saved: saved)
        let notifier = RouterNotifier()
        var posted: [ThreadNotice] = []
        notifier.post = { posted.append($0) }
        notifier.postMany = { posted += $0 }
        h.records.notifier = notifier
        return (h, { defer { posted = [] }; return posted })
    }

    @Test func bannersAskIsToldOnceKeyedOnItsRequest() {
        let (h, posted) = harness()
        var t = F.thread(status: .running)
        t.runStartedAt = F.ago(1)
        h.records.put(t)
        #expect(posted().isEmpty)
        t.status = .waiting
        t.pendingRequest = F.pending("req-9", minutes: 0)
        h.records.put(t)
        let told = posted()
        #expect(told.map(\.key) == ["ask:req-9"])
        #expect(told.first?.kind == .needsYou)
        // The projection arrives: the same ask, nothing again.
        var d = RouterDetail()
        d.request = F.question("Sidebar or tabs?", id: "req-9")
        h.records.detail("t1", d)
        #expect(posted().isEmpty)
        #expect(h.records.saved["t1"]?.told == ["ask:req-9"])
    }

    @Test func aFinishARealStopAndAUsageLimitAreToldWhileUnseen() {
        let (h, posted) = harness()
        var t = F.thread(status: .running, minutes: 0)
        t.runStartedAt = F.ago(3)
        h.records.put(t)
        t.status = .completed
        t.unseen = true
        t.latestMessage = "Moved the beds.\nMore."
        h.records.put(t)
        #expect(posted().map(\.body) == ["Moved the beds."])

        var f = F.thread("f", status: .running, minutes: 0)
        f.runStartedAt = F.ago(3)
        h.records.put(f)
        f.status = .failed
        f.unseen = true
        f.lastError = "The connection to Claude dropped"
        h.records.put(f)
        #expect(posted().map(\.kind) == [.failed])

        var seen = F.thread("s", status: .running, minutes: 0)
        seen.runStartedAt = F.ago(3)
        h.records.put(seen)
        seen.status = .completed
        h.records.put(seen)
        #expect(posted().isEmpty)
    }

    @Test func aRunYouStoppedIsNotNews() {
        let (h, posted) = harness()
        var t = F.thread(status: .running, minutes: 0)
        t.runStartedAt = F.ago(3)
        h.records.put(t)
        t.status = .interrupted
        t.stopRequested = true
        t.unseen = true
        h.records.put(t)
        #expect(posted().isEmpty)
    }

    @Test func aRelaunchTellsOnlyWhatIsFreshAndNotAlreadyTold() {
        let (h, posted) = harness()
        var old = F.thread("old", minutes: 30)
        old.unseen = true
        var fresh = F.thread("fresh", minutes: 2)
        fresh.unseen = true
        h.records.replace([old, fresh])
        #expect(posted().map(\.thread) == ["fresh"])
        // Again, with the file: nothing.
        let (again, posted2) = harness(saved: h.records.saved)
        again.records.replace([old, fresh])
        #expect(posted2().isEmpty)
    }

    @Test func aVerdictThatFindsAStepIsToldOncePerFingerprint() {
        let (h, posted) = harness()
        var t = F.thread(minutes: 0)
        t.unseen = true
        h.records.put(t)
        _ = posted()
        let fp = h.verdictAsk()!.fingerprint
        h.records.verdict("t1", fingerprint: fp, .done(RouterVerdict(kind: .finished, needsYou: true, line: "merge #41?", ask: "Merge #41?")))
        let told = posted()
        #expect(told.map(\.kind) == [.step])
        #expect(told.first?.body == "Merge #41?")
    }

    @Test func manyAtOnceAreOneBanner() {
        let h = Harness()
        let notifier = RouterNotifier()
        var each = 0, many: [[ThreadNotice]] = []
        notifier.post = { _ in each += 1 }
        notifier.postMany = { many.append($0) }
        h.records.notifier = notifier
        h.records.replace((0..<5).map { i in
            var t = F.thread("t\(i)", minutes: 1)
            t.unseen = true
            return t
        })
        #expect(each == 0)
        #expect(many.map(\.count) == [5])
    }

    // MARK: The hold

    @Test func aMorphsChangesArriveAsOneBatch() async {
        let h = Harness()
        h.gate.began()
        h.records.put(F.thread("a"))
        h.records.put(F.thread("b"))
        var t = F.thread("a", status: .running)
        t.runStartedAt = F.ago(0)
        t.latestRunID = "r2"
        h.records.put(t)
        #expect(h.changes.isEmpty)
        h.gate.ended()
        await h.gate.still()
        let changes = h.take()
        #expect(changes.count == 1)
        guard case .batch(let all)? = changes.first else { Issue.record("one batch"); return }
        #expect(upserts(all).map(\.id) == ["a", "b"])
        #expect(upserts(all).first?.state == .working)
    }

    @Test func compactKeepsTheLastRecordPerThreadAndWordsAfterIt() {
        let a = RouterThread(id: "a", name: "A", title: "A", state: .done, sentence: .init(text: "x"), since: F.now)
        var a2 = a
        a2.state = .working
        let folded = RouterRecords.compact([.upsert(a), .words("a", stream: 1, text: "x y", done: false), .upsert(a2),
                                            .words("a", stream: 2, text: "z", done: true), .remove("b"), .connection(lost: true)])
        #expect(folded == [.upsert(a2), .remove("b"), .words("a", stream: 2, text: "z", done: true), .connection(lost: true)])
    }

    // MARK: Speed

    @Test func aLongT3TitleIsTheNameWholeUntilTheModelNamesIt() {
        let title = "Did we lose various colour highlights in the brief after the rewrite?"
        #expect(RouterRecords.cut(title) == title)
        #expect(RouterRecords.cut(title + " " + String(repeating: "word ", count: 40)).count <= Router.Line.titleCharacters)
    }

    @Test func theFastNameCutIsFirstWords() {
        for title in ["Tidy the garden notes", "Thread number 123 with a longer title", "  spaced\tout   words\nhere ",
                      "Averyveryveryverylongsinglewordthatgoesonandon", "exactly twenty-eight chars!!", "", "café au lait with a croissant please",
                      "one two three four five six seven", "a b"] {
            #expect(RouterRecords.cut(title) == Router.firstWords(title, limit: Router.Line.titleCharacters), "\(title)")
        }
    }

    /// A whole shell of 500 threads, as T3 has them: some sixty with a line (working, finished today, asking), forty on the
    /// housekeeping line, the rest settled or older than a week. Each a verdict or a name to ask for, as on a first launch.
    @Test func fiveHundredRowsReduceInUnderFiveMilliseconds() {
        let h = Harness()
        let rows = (0..<500).map { i -> AgentThread in
            switch i {
            case 0..<20:
                var t = F.thread("t\(i)", title: "Working thread number \(i) with a longer title", status: .running)
                t.runStartedAt = F.ago(1)
                return t
            case 20..<50:
                return F.thread("t\(i)", title: "Finished thread number \(i) with a longer title", minutes: Double(i) * 20)
            case 50..<60:
                var t = F.thread("t\(i)", title: "Asking thread \(i)", status: .waiting)
                t.pendingRequest = F.pending("q\(i)")
                return t
            case 60..<100:
                return F.thread("t\(i)", title: "Older thread \(i)", minutes: Double(2 * 24 * 60 + i))
            default:
                var t = F.thread("t\(i)", title: "Settled thread \(i)", minutes: Double(8 * 24 * 60 + i))
                t.settled = i % 2 == 0
                return t
            }
        }
        // Warm once (first use of the types), then time a whole shell.
        h.records.replace(Array(rows.prefix(5)))
        let clock = ContinuousClock()
        let took = clock.measure { h.records.replace(rows) }
        #expect(took < .milliseconds(5), "500 rows took \(took)")
        #expect(h.records.lines(in: .working).count == 20)
        #expect(h.records.olderLines.count == 40)
    }
}
