import Foundation
import Testing
@testable import Fjord

@MainActor @Suite struct BriefSettle {
    @Test func settlingAThreadDropsItsLineAtOnceAndTheChangedFactsCostOneCall() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .done), briefThread("t2", .done), briefThread("t3", .working)])
        model.answer = { c in
            var lines = ["Things move."]
            for id in ["t1", "t2"] where c.contains("- \(id) ") { lines.append("<t id=\"\(id)\">Thread \(id)</t> is done.") }
            return #"{"now":"# + String(decoding: try! JSONEncoder().encode(lines), as: UTF8.self) + #","needs_you":[],"purpose":""}"#
        }
        let engine = makeEngine(src, model)
        engine.boardChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.now.count == 3)
        // t1 is tagged: its whole line goes the moment the board changes, before any call; the changed facts then cost one.
        src.setThreads("p", [briefThread("t2", .done), briefThread("t3", .working)])
        engine.boardChanged("p")
        await engine.idle()
        #expect(model.contexts.count == 2 && !model.contexts[1].contains("- t1 "))
        #expect(engine.docs["p"]?.now.count == 2 && !(engine.docs["p"]?.now.joined().contains("t1") ?? true))
    }

    @Test func refreshAloneDropsATaggedLineWithNoCall() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        let store = MemoryBriefStore()
        src.setThreads("p", [briefThread("t1", .done)])
        store.append(BriefVersion(project: "p", version: 1, at: 1, prose: BriefDoc.Prose(now: [#"<t id="t1">It</t> is done."#, "Plain."]), diff: ""))
        let engine = makeEngine(src, model, store: store)
        engine.start(); await engine.idle()
        let calls = model.contexts.count
        src.setThreads("p", [briefThread("t1", .done)])
        store.setKey("p", RouterBriefEngine.triggerKey(src.boards["p"]!))
        src.setThreads("p", [])
        src.boards["p"]?.threads = []
        engine.boardChanged("p"); await engine.idle()
        #expect(model.contexts.count == calls && engine.docs["p"]?.now.isEmpty == true)
    }

    @Test func aModelEntryForAThreadOffTheBoardIsDropped() {
        var board = BriefBoard()
        board.threads = [briefThread("t1", .done)]
        let mine = BriefEntry(project: "p", thread: "t1", kind: .question, state: .done, since: 1)
        let gone = BriefEntry(project: "p", thread: "t2", kind: .stranded, state: .needsYou, since: 1)
        #expect(RouterBriefEngine.entries(model: [mine, gone], board: board).map(\.thread) == ["t1"])
    }
}

@MainActor @Suite struct BriefLeadFromFacts {
    @Test func theLeadIsWrittenFromThreadFactsAndEntriesNeverFromNowProse() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        var t1 = briefThread("t1", .done)
        t1.ends = "Merged it."; t1.prs = [BriefPR(url: "https://github.com/o/r/pull/3", number: 3, state: .merged)]
        src.setThreads("a", [t1, briefThread("t2", .needsYou)])
        model.answer = { _ in askAnswer.replacingOccurrences(of: "t1", with: "t2").replacingOccurrences(of: "Waiting on you.", with: "PROSE-NOT-FOR-THE-LEAD") }
        let engine = makeEngine(src, model)
        engine.boardChanged("a"); await engine.idle()
        #expect(model.leadContexts.count == 1)
        let lead = model.leadContexts[0]
        #expect(lead.contains("a/t1") && lead.contains("Merged it.") && lead.contains("pull/3: merged") && lead.contains("needs you: a/t2"))
        #expect(!lead.contains("PROSE-NOT-FOR-THE-LEAD") && !lead.contains("now:"))
    }

    @Test func aSettledThreadsLeadLineGoesAtOnceAndTheLeadIsWrittenAgain() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        let store = MemoryBriefStore()
        src.setThreads("a", [briefThread("t1", .done), briefThread("t2", .done)])
        store.setLead(GeneralBrief(forYouLines: [#"<t id="a/t1">One</t> waits."#], worthALookLines: [#"<t id="a/t2">Two</t> done."#, "Plain."], at: 1))
        store.setKey("a", RouterBriefEngine.triggerKey(src.boards["a"]!))
        let engine = makeEngine(src, model, store: store)
        engine.start(); await engine.idle()
        src.setThreads("a", [briefThread("t2", .done)])
        store.setKey("a", RouterBriefEngine.triggerKey(src.boards["a"]!))
        engine.boardChanged("a"); await engine.idle()
        #expect(model.leadContexts.count >= 1)
        #expect(!(store.lead()?.tagged.contains("a/t1") ?? false))
    }

    @Test func aStoredStringLeadStillDecodesAsLines() throws {
        let old = try JSONDecoder().decode(GeneralBrief.self, from: Data(#"{"for_you":"One.\nTwo.","worth_a_look":""}"#.utf8))
        #expect(old.forYouLines == ["One.", "Two."] && old.worthALookLines.isEmpty)
        let new = try JSONDecoder().decode(GeneralBrief.self, from: Data(#"{"for_you":["A"],"worth_a_look":["B","C"]}"#.utf8))
        #expect(new.worthALookLines == ["B", "C"] && new.forYou == "A")
    }
}

/// The 2026-11-09 Silo case: PRs #95, #97 and #103 merged while the brief kept saying they waited for the user's merge.
@MainActor @Suite struct BriefSiloRegression {
    private func silo(_ state: PRState) -> [BriefThread] {
        func pr(_ n: Int) -> [BriefPR] { [BriefPR(url: "https://github.com/amontlabs/silo/pull/\(n)", number: n, state: state)] }
        var a = briefThread("th_ct5", .done, title: "CT5 sessions")
        a.ends = "CT5 is merged into main. I merged as soon as the required tests passed."
        a.endsAt = 1_000; a.runEnded = 1_000; a.prs = pr(95)
        var b = briefThread("th_b", .done, title: "Silo API spec"); b.runEnded = 900; b.prs = pr(97)
        var c = briefThread("th_c", .done, title: "Launch migration"); c.runEnded = 800; c.prs = pr(103)
        return [a, b, c]
    }

    @Test func mergedPullRequestsAreMarkedMergedAndNoStaleWaitIsCarried() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        // A model that only follows the facts it is given: it says a PR waits for a merge only while the context says open.
        model.answer = { c in
            let line = c.contains("pull/95: open")
                ? #"<t id=\"th_ct5\">PR 95</t> waits for your merge."# : #"<t id=\"th_ct5\">CT5</t> landed on main."#
            return #"{"now":["\#(line)"],"needs_you":[],"purpose":""}"#
        }
        src.setThreads("silo", silo(.open))
        let engine = makeEngine(src, model)
        engine.boardChanged("silo"); await engine.idle()
        #expect(engine.docs["silo"]?.now.first?.contains("waits for your merge") == true)

        // They merge; GitHub's state arrives with the board: no earlier brief reaches the call.
        src.setThreads("silo", silo(.merged))
        engine.boardChanged("silo"); await engine.idle()
        #expect(model.contexts.count == 2)
        let context = model.contexts[1]
        for n in [95, 97, 103] { #expect(context.contains("pull/\(n): merged") && !context.contains("pull/\(n): open")) }
        #expect(context.contains("CT5 is merged into main") && context.contains("last run ended"))
        #expect(!context.contains("waits for your merge") && !context.contains("Current brief") && !context.contains("now:"))
        #expect(engine.docs["silo"]?.now.joined().contains("waits for your merge") == false)
    }

    @Test func oldStoredRowsWithDecisionsAndLooseEndsStillDecode() throws {
        let old = #"{"purpose":"Silo","now":["a"],"needs_you":[],"decisions":[{"thread":"send","text":"ok"}],"loose_ends":["x"]}"#
        let prose = try JSONDecoder().decode(BriefDoc.Prose.self, from: Data(old.utf8))
        #expect(prose.now == ["a"] && prose.purpose == "Silo")
    }
}
