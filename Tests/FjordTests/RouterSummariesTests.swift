import Foundation
import Testing
@testable import Fjord

/// A working thread's summaries (DESIGN.md 1.4 "Working, summed up", R6): asked when the agent writes something new or its
/// to-do step moves, at most one a minute per thread, never twice for the same facts, cancelled when it stops working; kept
/// as a timeline in the verdict file until the thread leaves the page.
@MainActor @Suite struct RouterSummariesTests {
    typealias F = RecordFixture

    @MainActor final class Harness {
        let records: RouterRecords
        var changes: [RouterChange] = []
        var asks: [RouterVerdictRequest] = []
        var cancels: [String] = []
        var summaryCancels: [String] = []
        var clock = RecordFixture.now

        init(saved: [String: RouterRecords.Saved] = [:]) {
            records = RouterRecords(saved: saved, gate: MotionGate.Gate(longest: 600))
            records.now = { [unowned self] in self.clock }
            records.emit = { [unowned self] in self.changes.append($0) }
            records.ask = { [unowned self] in self.asks.append($0) }
            records.cancel = { [unowned self] in self.cancels.append($0) }
            records.cancelSummary = { [unowned self] in self.summaryCancels.append($0) }
        }

        var summaries: [RouterVerdictRequest] { asks.filter { $0.kind == .summary } }

        func take() -> [RouterChange] {
            defer { changes = [] }
            return changes
        }

        /// Answers the latest summary call with this line.
        func answer(_ line: String, thread: String = "t1") {
            guard let r = summaries.last(where: { $0.thread == thread }) else { Issue.record("no summary asked"); return }
            records.summary(thread, fingerprint: r.fingerprint, .words(line, done: true))
            records.summary(thread, fingerprint: r.fingerprint, .done(RouterVerdict(kind: .summary, line: line)))
        }

        /// The clock moves on, and the records' one wake fires.
        func wait(_ seconds: TimeInterval) {
            clock = clock.addingTimeInterval(seconds)
            records.tick()
        }
    }

    /// A thread in its run `r1`, started a few minutes ago.
    static func running(_ id: String = "t1") -> AgentThread {
        var t = F.thread(id, status: .running)
        t.runStartedAt = F.ago(3)
        return t
    }

    /// The run's live detail: the agent's latest whole words (by message id), the running step, the tool running now.
    static func detail(said: String? = "Found the gap; moving the copy.", id: String = "m1", step: String? = nil,
                       tool: String? = "command", now: String = "swift test --filter Tab") -> RouterDetail {
        var d = F.working("Editing Foo.swift")
        d.said = said
        d.saidID = said == nil ? nil : id
        if let step { d.steps = [.init(id: 0, text: "Sort", state: .done), .init(id: 1, text: step, state: .running)] }
        d.toolKind = tool
        d.workNow = RouterWork.Step(id: 9, text: now, mono: true, at: F.ago(0.2))
        d.workRecent = [RouterWork.Step(id: 8, text: "Read TabHandover.swift", at: F.ago(1))]
        return d
    }

    private func start(_ h: Harness, _ d: RouterDetail? = nil) {
        h.records.put(Self.running())
        h.records.detail("t1", d ?? Self.detail())
    }

    // MARK: Trigger

    @Test func newWordsAskForASummaryAndTheLineSheensUntilItsWordsStream() throws {
        let h = Harness()
        h.records.put(Self.running())
        h.records.detail("t1", { var d = Self.detail(said: nil); d.saidID = nil; return d }())
        // No words and no to-do step yet: nothing to sum up, the code's line.
        #expect(h.summaries.isEmpty)
        #expect(h.records.record("t1")?.sentence.text == "Editing Foo.swift")
        h.records.detail("t1", Self.detail())
        let ask = try #require(h.summaries.first)
        #expect(ask.thread == "t1")
        let facts = try #require(ask.summary)
        #expect(facts.said == "Found the gap; moving the copy.")
        #expect(facts.now == "swift test --filter Tab")
        #expect(facts.recent == ["Read TabHandover.swift"])
        #expect(facts.last == nil)
        // The code's line, sheening while the first summary is written.
        #expect(h.records.record("t1")?.sentence.text == "Editing Foo.swift")
        #expect(h.records.record("t1")?.sentence.phase == .reassessing)
        _ = h.take()
        h.records.summary("t1", fingerprint: ask.fingerprint, .words("Moving the draft", done: false))
        let stream = try #require(h.records.record("t1")?.sentence.stream)
        #expect(h.take() == [.words("t1", stream: stream, text: "Moving the draft", done: false)])
        h.records.summary("t1", fingerprint: ask.fingerprint, .words("Moving the draft copy earlier", done: true))
        h.records.summary("t1", fingerprint: ask.fingerprint, .done(RouterVerdict(kind: .summary, line: "Moving the draft copy earlier")))
        let r = try #require(h.records.record("t1"))
        #expect(r.sentence.text == "Moving the draft copy earlier")
        #expect(r.sentence.phase != .reassessing)
        #expect(r.work.summaries.map(\.text) == ["Moving the draft copy earlier"])
        #expect(r.work.summaries.first?.at == h.clock)
        #expect(r.work.now?.text == "swift test --filter Tab")
        #expect(r.work.recent.map(\.text) == ["Read TabHandover.swift"])
    }

    @Test func aToDoStepMovingAsksToo() {
        let h = Harness()
        start(h, Self.detail(said: nil, step: "Label the packets"))
        #expect(h.summaries.count == 1)
        h.answer("Labelling the seed packets")
        h.wait(61)
        h.records.detail("t1", Self.detail(said: nil, step: "Water the beds"))
        #expect(h.summaries.count == 2)
        #expect(h.summaries.last?.summary?.steps.last == .init(text: "Water the beds", state: "running"))
        #expect(h.summaries.last?.summary?.last == "Labelling the seed packets")
    }

    @Test func aNewToolAloneAsksNothing() {
        let h = Harness()
        start(h)
        h.answer("Moving the draft copy earlier")
        h.wait(120)
        h.records.detail("t1", Self.detail(tool: "Read", now: "Read Composer.swift"))
        h.wait(120)
        #expect(h.summaries.count == 1)
    }

    // MARK: Coalescing

    @Test func atMostOneAMinuteWithOneWakeForTheNext() {
        let h = Harness()
        start(h)
        h.answer("Moving the draft copy earlier")
        // New words 10 s later: they wait for the minute's end, then go, once, with the latest words.
        h.wait(10)
        h.records.detail("t1", Self.detail(said: "Copy moved.", id: "m2"))
        h.wait(20)
        h.records.detail("t1", Self.detail(said: "Copy moved; caret next.", id: "m3"))
        #expect(h.summaries.count == 1)
        h.wait(29)
        #expect(h.summaries.count == 1)
        h.wait(2)
        #expect(h.summaries.count == 2)
        #expect(h.summaries.last?.summary?.said == "Copy moved; caret next.")
        #expect(h.summaries.last?.summary?.last == "Moving the draft copy earlier")
        // Nothing new since: the wakes after it ask nothing.
        h.answer("Copy moved; putting the caret back")
        h.wait(300)
        #expect(h.summaries.count == 2)
    }

    @Test func wordsThatCameDuringACallAreSummedUpAfterIt() {
        let h = Harness()
        start(h)
        h.wait(30)
        h.records.detail("t1", Self.detail(said: "Copy moved.", id: "m2"))
        #expect(h.summaries.count == 1)
        h.answer("Moving the draft copy earlier")
        h.wait(31)
        #expect(h.summaries.count == 2)
        #expect(h.summaries.last?.summary?.said == "Copy moved.")
    }

    @Test func theSameFactsAreNeverSummedUpTwice() {
        let h = Harness()
        start(h)
        h.answer("Moving the draft copy earlier")
        // The same words come back as another detail (its activity, the reply's flags): no call.
        var d = Self.detail()
        d.writing = true
        h.records.detail("t1", d)
        h.wait(120)
        #expect(h.summaries.count == 1)
        #expect(RouterRecords.summaryPrint(trigger: "m1|-", tool: "command", run: "r1") != RouterRecords.summaryPrint(trigger: "m1|-", tool: "Read", run: "r1"))
    }

    // MARK: Cancel

    @Test func aCallIsCancelledWhenTheThreadStopsWorkingAndItsLateAnswerIsDropped() throws {
        let h = Harness()
        start(h)
        let ask = try #require(h.summaries.first)
        h.records.summary("t1", fingerprint: ask.fingerprint, .words("Moving the", done: false))
        var done = F.thread(minutes: 0)
        done.lastRunEndedAt = h.clock
        h.records.put(done)
        #expect(h.summaryCancels == ["t1"])
        // The verdict's calls aren't the summary's: nothing else was cancelled.
        #expect(h.cancels.isEmpty)
        h.records.summary("t1", fingerprint: ask.fingerprint, .done(RouterVerdict(kind: .summary, line: "Moving the draft copy earlier")))
        #expect(h.records.saved["t1"]?.summaries == nil)
        #expect(h.records.record("t1")?.sentence.text != "Moving the draft copy earlier")
        #expect(h.records.record("t1")?.work.summaries.isEmpty == true)
    }

    @Test func withTheRouterOffNothingIsSummedUp() {
        let h = Harness()
        h.records.canAsk = { false }
        start(h)
        #expect(h.summaries.isEmpty)
        #expect(h.records.record("t1")?.sentence.phase == .settled)
    }

    // MARK: Failure

    @Test func aFailureKeepsTheLineItHadAndIsNotAskedAgainForTheSameFacts() throws {
        let h = Harness()
        start(h)
        h.answer("Moving the draft copy earlier")
        h.wait(61)
        h.records.detail("t1", Self.detail(said: "Copy moved.", id: "m2"))
        let second = try #require(h.summaries.last)
        #expect(h.records.record("t1")?.sentence.phase == .reassessing)
        // Sheening, the line still reads the newest: the card leaves it to the line. Streaming, it lists it.
        #expect(h.records.record("t1")?.work.lineReadsNewest == true)
        h.records.summary("t1", fingerprint: second.fingerprint, .words("Copy mo", done: false))
        #expect(h.records.record("t1")?.work.lineReadsNewest == false)
        let listed = h.records.record("t1").map { RouterTimeline.entries($0) }?.first { $0.isSummary }
        #expect(listed.map { if case .summary(let text) = $0.event.kind { text } else { "" } } == "Moving the draft copy earlier")
        h.records.summary("t1", fingerprint: second.fingerprint, .failed)
        #expect(h.records.record("t1")?.work.lineReadsNewest == true)
        let r = try #require(h.records.record("t1"))
        #expect(r.sentence.text == "Moving the draft copy earlier")
        #expect(r.sentence.phase == .settled)
        #expect(r.work.summaries.count == 1)
        h.wait(300)
        #expect(h.summaries.count == 2)
        // New facts: asked again.
        h.records.detail("t1", Self.detail(said: "Caret next.", id: "m3"))
        #expect(h.summaries.count == 3)
    }

    // MARK: History

    @Test func theTimelineIsNewestFirstCappedAndALineThatSaysTheSameIsOne() {
        let h = Harness()
        start(h)
        h.answer("Moving the draft copy earlier")
        for n in 2...25 {
            h.wait(61)
            h.records.detail("t1", Self.detail(said: "Step \(n).", id: "m\(n)"))
            // The 3rd says what the 2nd said, in other case and punctuation: one entry.
            h.answer(n == 3 ? "step two done." : n == 2 ? "Step two done" : "Step \(n) done")
        }
        let all = h.records.saved["t1"]?.summaries ?? []
        #expect(all.count == RouterRecords.summariesKept)
        #expect(all.first?.text == "Step 25 done")
        #expect(all.map(\.id) == all.map(\.id).sorted(by: >))
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(!all.contains { $0.text == "step two done." })
        #expect(h.records.record("t1")?.work.summaries == all)
    }

    @Test func theLineReadsOnlyItsOwnRunsSummary() {
        let h = Harness()
        start(h)
        h.answer("Moving the draft copy earlier")
        // A new run: the old run's summary stays in the timeline, the line is the code's until the new run's comes.
        var next = Self.running()
        next.latestRunID = "r2"
        h.records.put(next)
        let r = h.records.record("t1")
        #expect(r?.work.summaries.map(\.text) == ["Moving the draft copy earlier"])
        #expect(r?.sentence.text != "Moving the draft copy earlier")
        #expect(h.summaries.last?.summary?.last == nil)
    }

    @Test func aSummaryAskedForARunThatMovedOnIsDroppedAndTheNewRunsIsAsked() {
        let h = Harness()
        start(h)
        let asked = h.summaries.last
        #expect(asked?.fingerprint.hasSuffix("|r1") == true)
        // r1 ends and r2 starts in the same shell update: still working, the call for r1 goes.
        var next = Self.running()
        next.latestRunID = "r2"
        h.records.put(next)
        #expect(h.summaryCancels == ["t1"])
        // Its late answer is about r1: dropped, never r2's line.
        if let asked {
            h.records.summary("t1", fingerprint: asked.fingerprint, .done(RouterVerdict(kind: .summary, line: "Old run's step")))
        }
        #expect(h.records.saved["t1"]?.summaries == nil)
        #expect(h.records.record("t1")?.sentence.text != "Old run's step")
        // The same step and no new words in r2: the run is in the trigger, so r2 gets its own summary after the gap.
        h.wait(61)
        #expect(h.summaries.last?.fingerprint.hasSuffix("|r2") == true)
        h.answer("Running the snapshot suite")
        #expect(h.records.saved["t1"]?.summaries?.first?.run == "r2")
    }

    @Test func theSameWordsInANewRunAreANewEntryWithItsOwnTime() {
        let h = Harness()
        start(h)
        h.answer("Running the snapshot suite")
        let first = h.records.saved["t1"]?.summaries?.first
        h.wait(120)
        var next = Self.running()
        next.latestRunID = "r2"
        h.records.put(next)
        h.records.detail("t1", Self.detail(said: "Again.", id: "m9"))
        h.wait(61)
        h.answer("Running the snapshot suite")
        let all = h.records.saved["t1"]?.summaries ?? []
        #expect(all.count == 2)
        #expect(all.first?.run == "r2" && all.first?.at != first?.at)
        #expect(all.last == first)
    }

    @Test func aRestartedThreadsCardDoesntShowAnEarlierRunsStepAsCurrent() {
        let h = Harness()
        start(h)
        h.answer("Running the snapshot suite")
        var next = Self.running()
        next.latestRunID = "r2"
        h.records.put(next)
        let record = h.records.record("t1")
        let work = record?.work
        #expect(work?.run == "r2")
        #expect(work?.current == false)
        #expect(work?.lineReadsNewest == false)
        // The card lists r1's summary after its quiet break, not as r2's newest.
        #expect(record.map { RouterTimeline.entries($0) }?.filter(\.isSummary).map(\.event.run) == ["r1"])
    }

    @Test func theTimelineGoesWhenTheThreadLeavesThePage() {
        let h = Harness()
        start(h)
        h.answer("Moving the draft copy earlier")
        #expect(h.records.saved["t1"]?.summaries?.count == 1)
        h.records.drop("t1")
        #expect(h.records.saved["t1"]?.summaries == nil)
    }

    // MARK: Persistence

    @Test func summariesAreKeptInTheVerdictFileAndAnOlderFileStillReads() throws {
        let s = RouterWork.Summary(id: 3, text: "Moving the draft copy earlier", at: F.now, run: "r1", print: "m1|-|command|r1")
        var saved = RouterRecords.Saved()
        saved.name = "Tab handover"
        saved.summaries = [s]
        let data = try #require(RouterVerdictFile.encode(["t1": saved]))
        #expect(RouterVerdictFile.decode(data)["t1"] == saved)
        // A file written before summaries: the same version, no key.
        let old = #"{"version":\#(RouterVerdictFile.version),"threads":{"t1":{"name":"Tab handover","told":[]}}}"#
        #expect(RouterVerdictFile.decode(Data(old.utf8))["t1"]?.name == "Tab handover")
        #expect(RouterVerdictFile.decode(Data(old.utf8))["t1"]?.summaries == nil)

        // A restart: the line reads its run's newest summary at once, and the same facts aren't asked again.
        let h = Harness(saved: ["t1": saved])
        start(h)
        #expect(h.records.record("t1")?.sentence.text == "Moving the draft copy earlier")
        #expect(h.records.record("t1")?.work.summaries == [s])
        #expect(h.summaries.isEmpty)
    }
}

/// The engine's side: a summary is a Haiku call queued after asks, finished turns and names, before project purposes,
/// told through `onSummary`, cancelled on its own, logged as `summary`.
@MainActor @Suite(.serialized) struct RouterSummaryCallsTests {
    func until(_ what: @autoclosure () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !what(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func request(_ id: String, _ kind: RouterVerdictRequest.Kind, at: Double = 0) -> RouterVerdictRequest {
        var r = RouterVerdictRequest(thread: id, fingerprint: "f-\(id)", kind: kind,
                                     input: RouterVerdictInput(title: id, reply: "Did the thing."), at: Date(timeIntervalSince1970: at))
        if kind == .summary { r.summary = RouterSummaryInput(title: id, said: "Moving the copy.", now: "swift test") }
        return r
    }

    @Test func aSummaryIsAHaikuCallToldApartWithItsLineCleaned() async {
        let fake = FakeClaude()
        let e = RouterVerdicts(binary: { "/bin/claude" }, runner: fake.runner, log: nil)
        var verdicts: [RouterVerdictEvent] = [], summaries: [RouterVerdictEvent] = []
        e.onEvent = { _, _, ev in verdicts.append(ev) }
        e.onSummary = { _, fp, ev in #expect(fp == "f-s"); summaries.append(ev) }
        e.ask(request("s", .summary))
        await waitUntil { fake.calls.count == 1 }
        #expect(fake.calls[0].arguments.contains("claude-haiku-5-5"))
        #expect(fake.calls[0].arguments.contains { $0.contains(#""now""#) && $0.contains(#""line""#) })
        #expect(fake.calls[0].input.contains("Its latest words:\n<session-content"))
        #expect(fake.calls[0].input.contains("Running now:"))
        fake.send(0, FakeClaude.answer(["done": "Found the gap", "now": "moving the copy", "line": "Moving the draft copy earlier."], size: 5))
        fake.close(0)
        await waitUntil { summaries.last.map { if case .done = $0 { true } else { false } } ?? false }
        #expect(verdicts.isEmpty)
        let words = summaries.compactMap { if case .words(let w, false) = $0 { w } else { nil } }
        #expect(!words.isEmpty && words.allSatisfy { "Moving the draft copy earlier.".hasPrefix($0) })
        #expect(summaries.dropLast().last == .words("Moving the draft copy earlier", done: true))
        #expect(summaries.last == .done(RouterVerdict(kind: .summary, line: "Moving the draft copy earlier")))
    }

    @Test func summariesWaitForVerdictsAndGoBeforePurposes() async {
        let fake = FakeClaude()
        let e = RouterVerdicts(binary: { "/bin/claude" }, runner: fake.runner, log: nil, cap: 1)
        e.ask(request("busy", .ask))
        await until(fake.calls.count == 1)
        e.purpose(.init(project: "p", system: "s", schema: "{}", input: { "Thread: purpose" }, done: { _ in }))
        e.ask(request("summed", .summary))
        e.ask(request("named", .name))
        e.ask(request("finished", .ask))
        var order: [String] = []
        for _ in 0..<4 {
            let n = fake.calls.count
            fake.close(n - 1)
            await until(fake.calls.count == n + 1)
            let input = fake.calls[n].input
            order.append(["summed", "named", "finished", "purpose"].first { input.contains("Thread: \($0)") } ?? "?")
        }
        #expect(order == ["finished", "named", "summed", "purpose"])
    }

    @Test func summariesLeaveOneSlotForAsks() async {
        let fake = FakeClaude()
        let e = RouterVerdicts(binary: { "/bin/claude" }, runner: fake.runner, log: nil, cap: 4)
        for n in 0..<5 { e.ask(request("s\(n)", .summary)) }
        await until(fake.calls.count == 3)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fake.calls.count == 3)
        e.ask(request("asks", .ask))
        await until(fake.calls.count == 4)
        #expect(fake.calls[3].input.contains("Thread: asks"))
    }

    @Test func aSummarysRateLimitHoldsOnlyTheSummaries() async {
        let fake = FakeClaude()
        let e = RouterVerdicts(binary: { "/bin/claude" }, runner: fake.runner, log: nil, cap: 4)
        e.ask(request("s", .summary))
        await until(fake.calls.count == 1)
        fake.send(0, [#"{"type":"system","subtype":"api_retry","attempt":1,"error_status":429,"retry_delay_ms":60000,"error":"rate_limit"}"#])
        fake.close(0)
        await until(e.summariesHeld)
        #expect(!e.held)
        e.ask(request("asks", .ask))
        e.ask(request("other", .summary))
        await until(fake.calls.count == 2)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fake.calls.count == 2)
        #expect(fake.calls[1].input.contains("Thread: asks"))
    }

    @Test func aThreadsSummaryIsCancelledOnItsOwn() async {
        let fake = FakeClaude()
        let e = RouterVerdicts(binary: { "/bin/claude" }, runner: fake.runner, log: nil)
        e.ask(request("t", .summary))
        e.ask(request("t", .name))
        await until(fake.calls.count == 2)
        e.cancel("t")
        await until(fake.calls.contains { $0.terminated })
        #expect(fake.calls.filter(\.terminated).count == 1)
        #expect(e.runningCount == 1)
        e.cancelSummary("t")
        await until(fake.calls.allSatisfy(\.terminated))
        #expect(e.runningCount == 0)
    }

    @Test func usageIsLoggedAsSummaries() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("summaries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ModelUsageLog(url: dir.appendingPathComponent("model-usage.jsonl"))
        let fake = FakeClaude()
        let e = RouterVerdicts(binary: { "/bin/claude" }, runner: fake.runner, log: log)
        var ended = false
        e.onSummary = { _, _, ev in if case .done = ev { ended = true } }
        e.ask(request("t", .summary))
        await until(fake.calls.count == 1)
        fake.send(0, FakeClaude.answer(["done": "", "now": "x", "line": "Checking the tab"], usage: (2000, 450)))
        fake.close(0)
        await until(ended)
        log.flush()
        #expect(log.entries().map(\.role) == [.summary])
        #expect(log.entries().first?.model == "claude-haiku-5-5")
        #expect(log.entries().first?.usage.inputTokens == 2000)
    }

    @Test func theInputIsSmallRedactedAndFenced() {
        let long = String(repeating: "word ", count: 2000) + "the end."
        let x = RouterSummaryInput(title: "Tab", project: "fjord", yourWords: long, said: long + " token sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789",
                                   steps: (0..<12).map { .init(text: "step \($0)", state: "pending") }, now: "swift test",
                                   recent: ["Read A.swift"], last: "Checking the tab")
        let text = RouterSummaryPrompt.text(x)
        #expect(text.count < 3_000)
        #expect(!text.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(text.contains("Its latest words (their end):\n<session-content"))
        #expect(text.contains("the end."))
        #expect(text.contains("step 7") && !text.contains("step 8"))
        #expect(text.hasSuffix("Your previous line: Checking the tab"))
        #expect(RouterSummaryPrompt.line("  Moving the copy.  ") == "Moving the copy")
        #expect(RouterSummaryPrompt.line(String(repeating: "word ", count: 40)).count <= RouterSummaryPrompt.lineCharacters + 1)
    }

    @Test func theAppSendsTheEvalsPrompt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v4 = try String(contentsOf: root.appendingPathComponent("evals/router/summary/prompts/system-v4.txt"), encoding: .utf8)
        func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }
        #expect(words(RouterSummaryPrompt.system) == words(v4))
    }

    /// The card's timeline (R6, R10): the thread's history newest first, a run's events then what started it, runs apart;
    /// the newest summary left to the line that reads it; an item still open not repeated; what the timeline doesn't
    /// show yet counts on the new pill (a run's start doesn't).
    @Test func timelineEntries() {
        let at = RecordFixture.now
        func e(_ id: String, _ m: Double, _ run: String, _ kind: RouterEvent.Kind) -> RouterEvent {
            RouterEvent(id: id, at: at.addingTimeInterval(-m * 60), run: run, kind: kind)
        }
        var t = RouterThread(id: "t", name: "T", title: "T", state: .working, sentence: .init(text: "d"), since: at)
        t.work = RouterWork(run: "b")
        t.work.lineReadsNewest = true
        t.ledger.items = [RouterItem(id: "i", kind: .decide, sentence: "keep it?", since: at)]
        t.history = [e("s4", 1, "b", .summary("d")), e("raised:i", 2, "b", .raised(.decide, "keep it?")),
                     e("s3", 3, "b", .summary("c")), e("rb", 4, "b", .started(.command("swift test"))),
                     e("f1", 5, "a", .finished("done a")), e("s2", 6, "a", .summary("b")),
                     e("ra", 7, "a", .started(.asked("fix it")))]
        let entries = RouterTimeline.entries(t)
        #expect(entries.map(\.id) == ["s3", "rb", "f1", "s2", "ra"])
        #expect(entries.map(\.gap) == [0, Router.Work.rowGap, Router.Work.runGap, Router.Work.rowGap, Router.Work.rowGap])
        let held = RouterTimeline.entries(t, dropping: 1)
        #expect(held.map(\.id) == ["rb", "f1", "s2", "ra"])
        #expect(RouterTimeline.newer(entries, since: held) == 1)
        #expect(RouterTimeline.newer(entries, since: entries) == 0)
    }
}

