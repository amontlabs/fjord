import Foundation
import Testing
@testable import Fjord

/// A thread's summary in the one layout (sentence, detail, facts, source) and its history (summaries, run starts, items
/// raised and closed, turns ended), through the records with fakes.
@MainActor @Suite struct RouterSummaryHistoryTests {
    typealias F = RecordFixture
    typealias H = RouterItemLedgersTests.Harness

    private static func ended(_ run: String = "r1", minutes: Double = 1) -> AgentThread {
        var t = F.thread(minutes: minutes)
        t.latestRunID = run
        t.latestMessage = "The skill is Markdown only: SKILL.md and 8 reference files. No scripts."
        t.pullRequests = [T3PullRequest(json: .object(["url": .string("https://github.com/o/r/pull/59"), "number": .number(59),
                                                       "state": .string("open")]))]
        return t
    }

    private static func turn(_ reply: String, ended: Date? = nil) -> RouterItemFacts.Turn {
        .init(reply: reply, yourWords: "is it just instructions?", woke: nil, status: "completed", live: false, ended: ended)
    }

    @Test func aFinishedTurnsSummaryIsItsOutcomeWithCodesFactsAndTheAgentsWords() throws {
        let h = H()
        h.records.put(Self.ended())
        h.facts(RouterItemFacts(turns: ["r1": Self.turn("The skill is Markdown only…")]))
        h.answer(RouterItemsAnswer(line: "skill is Markdown only: SKILL.md + 8 reference files, no scripts",
                                   detail: "Nothing runs on your machine.",
                                   facts: [.init(kind: .tests, text: "tests pass", tone: .good)]))
        let r = try #require(h.record)
        #expect(r.sentence.text == "skill is Markdown only: SKILL.md + 8 reference files, no scripts")
        let s = try #require(r.summary)
        #expect(s.sentence == r.sentence.text)
        #expect(s.detail == "Nothing runs on your machine.")
        // Code's facts first (the PR with its page), then the model's.
        #expect(s.facts.map(\.text) == ["PR #59 open", "tests pass"])
        #expect(s.facts.first?.link == URL(string: "https://github.com/o/r/pull/59"))
        #expect(s.source == "The skill is Markdown only: SKILL.md and 8 reference files. No scripts.")
        // Kept in the file with the line.
        #expect(h.saved?.lineDetail == "Nothing runs on your machine." && h.saved?.lineFacts?.count == 1)
    }

    @Test func theOutcomesDetailAndFactsAreReadFromTheAnswer() throws {
        let json = #"{"open":[],"found":[],"line":"v0.8.13 released","detail":"v0.8.13 released","facts":["#
            + #"{"kind":"tests","text":"412 tests pass","tone":"good"},{"kind":"note","text":"412 tests pass","tone":"good"},"#
            + #"{"kind":"note","text":"installed app still 0.8.11","tone":"neutral"}]}"#
        let a = try #require(RouterItemsReading.answer(Data(json.utf8), turn: true, ids: []))
        // A detail that is the line again says nothing more; a chip given twice is one.
        #expect(a.detail == nil)
        #expect(a.facts == [.init(kind: .tests, text: "412 tests pass", tone: .good), .init(kind: .note, text: "installed app still 0.8.11")])
        // Your words' read has none.
        let mine = try #require(RouterItemsReading.answer(Data(#"{"open":[]}"#.utf8), turn: false, ids: []))
        #expect(mine.facts.isEmpty && mine.detail == nil)
    }

    @Test func aTurnEndedWithNoReplyYetWaitsForItInsteadOfPassingSilently() throws {
        let h = H()
        h.records.items.missAfter = { _ in 0 }
        h.records.put(Self.ended())
        // T3's projection hasn't the reply yet: nothing is read, and the input stays pending.
        h.facts(RouterItemFacts(turns: ["r1": Self.turn("")], order: ["r1"]))
        #expect(h.reads.isEmpty)
        #expect(h.saved?.pending.map(\.key) == ["turn:r1"])
        // The next projection read has it: read, with its line.
        h.records.itemFacts("t1", key: "turn:r1", RouterItemFacts(turns: ["r1": Self.turn("Done.")], order: ["r1"]))
        #expect(h.reads.count == 1)
    }

    @Test func theHistoryKeepsTurnEndsItemsAndTheirClosesAcrossStates() throws {
        let h = H()
        let end = F.ago(2)
        h.records.put(Self.ended())
        h.facts(RouterItemFacts(turns: ["r1": Self.turn("Merge it?", ended: end)]))
        h.answer(RouterItemsAnswer(found: [.init(kind: .decide, sentence: "merge PR #59?")], line: "PR #59 open, review clean"))
        h.records.items.settle("t1")
        var r = try #require(h.record)
        // Newest first; at the turn's end, what it raised after the end itself.
        #expect(r.history.map(\.kind) == [.raised(.decide, "merge PR #59?"), .finished("PR #59 open, review clean")])
        #expect(r.history.allSatisfy { $0.at == end && $0.run == "r1" })
        // Done by you is logged; its Revert takes it back.
        h.records.itemDone("t1", item: "i1", on: true)
        r = try #require(h.record)
        #expect(r.history.first?.kind == .closed(.decide, "merge PR #59?", how: Router.Items.Copy.doneByYou))
        h.records.itemDone("t1", item: "i1", on: false)
        #expect(h.record?.history.count == 2)
        // Saved and read back through the file, and a file written before reads with none.
        let back = RouterVerdictFile.decode(try #require(RouterVerdictFile.encode(h.records.saved)))
        #expect(back["t1"]?.history == h.records.saved["t1"]?.history && back["t1"]?.history?.count == 2)
        let old = #"{"version":3,"threads":{"t1":{"told":[],"ledger":{"items":[],"line":"done","lineRun":"r1"}}}}"#
        let t1 = try #require(RouterVerdictFile.decode(Data(old.utf8))["t1"])
        #expect(t1.history == nil && t1.ledger?.line == "done" && t1.ledger?.lineDetail == nil && t1.ledger?.lineFacts == nil)
    }

    @Test func runStartsAndSummariesStayAfterTheRunEndsAndGoWhenTheThreadLeaves() throws {
        let h = H()
        var t = Self.ended()
        h.records.put(t)
        var d = RouterDetail()
        d.starts = ["r1": .asked("is it just instructions?")]
        d.startedAt = ["r1": F.ago(3)]
        h.records.detail("t1", d)
        #expect(h.record?.history.map(\.id) == ["rr1"])
        #expect(h.record?.work.starts["r1"] == .asked("is it just instructions?"))
        // The projection's detail gone (a relaunch, a closed subscription): the start is still there.
        h.records.detail("t1", nil)
        #expect(h.record?.work.starts["r1"] == .asked("is it just instructions?"))
        // Settled: off the page, its history goes.
        t.settled = true
        t.settledAt = F.now
        h.records.put(t)
        #expect(h.records.saved["t1"]?.history == nil)
    }

    @Test func theHistoryMergesSummariesAndTheLogNewestFirstCapped() {
        let summaries = (0..<30).map { RouterWork.Summary(id: $0, text: "s\($0)", at: F.ago(Double(100 - $0)), run: "r1") }.reversed()
        let log = (0..<20).map { RouterEvent(id: "turn:\($0)", at: F.ago(Double(100 - $0) - 0.5), run: "r1", kind: .finished("t\($0)")) }
        let h = RouterRecords.history(summaries: Array(summaries), log: log)
        #expect(h.count == RouterEvent.kept)
        #expect(h.first?.id == "s29")
        #expect(zip(h, h.dropFirst()).allSatisfy { $0.at >= $1.at })
        #expect(h.contains { $0.id == "turn:19" })
    }

    @Test func anItemTakesTheSameShape() {
        let item = RouterItem(id: "i1", kind: .do, sentence: "install 0.8.13", since: F.now, options: ["ok"], detail: "Not live yet.", quote: "Install it.")
        #expect(item.summary == RouterSummary(sentence: "install 0.8.13", detail: "Not live yet.", source: "Install it."))
    }
}
