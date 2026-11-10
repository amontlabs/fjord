import Foundation
import Testing
@testable import Fjord

@MainActor @Suite struct BriefDocChecks {
    @Test func aRepeatOfAFinishAddsNoEntryOrVersion() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .done)])
        model.answer = { _ in #"{"now":["t1 finished."],"needs_you":[],"purpose":""}"# }
        let store = MemoryBriefStore()
        let engine = makeEngine(src, model, store: store)
        engine.boardChanged("p"); await engine.idle()
        let version = engine.docs["p"]?.version
        // A new run end moves the key; the same words come back: a call, no new version.
        src.setThreads("p", [ran(briefThread("t1", .done), at: 9)])
        engine.boardChanged("p"); await engine.idle()
        #expect(model.contexts.count == 2)
        #expect(engine.docs["p"]?.needsYou.isEmpty == true)
        #expect(engine.docs["p"]?.version == version)
        #expect(store.versions("p").count == 1)
    }

    @Test func theAnswerIsCheckedIdsOptionsAndCaps() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        var t1 = briefThread("t1", .needsYou)
        t1.askOptions = ["red", "blue"]
        src.setThreads("p", [t1, briefThread("t2", .done)])
        model.answer = { _ in
            #"{"now":["1","2","3","4"],"needs_you":[{"thread":"t1","kind":"question","question":"Which?","options":["wrong"]},{"thread":"ghost","kind":"plan","question":"?","options":[]},{"thread":"t2","kind":"question","question":"done already","options":[]}],"purpose":"Docs"}"#
        }
        let engine = makeEngine(src, model)
        engine.boardChanged("p"); await engine.idle()
        let doc = engine.docs["p"]!
        #expect(doc.now == ["1", "2", "3"] && doc.purpose == "Docs")
        // A done thread whose reply asks waits on you too; a thread the board doesn't have never does.
        #expect(doc.needsYou.map(\.thread).sorted() == ["t1", "t2"])
        #expect(doc.needsYou.first { $0.thread == "t1" }?.options == ["red", "blue"])  // the request's, as data
    }

    @Test func theAnswerDecoderToleratesAnOldShapeAndAMissingPurpose() throws {
        let old = try BriefDoc.parse(#"{"now":"a\nb","needs_you":[],"decisions":[{"thread":"send","text":"ok"}],"loose_ends":["x"]}"#)
        #expect(old.now == ["a", "b"] && old.purpose == nil)
    }

    @Test func aFailureKeepsTheOldProseStaleAndTheDeterministicPartStillRebuilds() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        model.answer = { _ in #"{"now":["Old prose."],"needs_you":[],"purpose":""}"# }
        src.setThreads("p", [briefThread("t1", .working)])
        let engine = makeEngine(src, model)
        engine.boardChanged("p"); await engine.idle()
        model.failing = true
        src.setThreads("p", [ran(briefThread("t1", .working), at: 3)])
        engine.boardChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.now == ["Old prose."] && engine.docs["p"]?.proseStale == true)
        // The deterministic part still rebuilds from the Board.
        var t = briefThread("t1", .working); t.runEnded = 3; t.ends = "words only"
        src.setThreads("p", [t])
        engine.boardChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.threads.first?.ends == "words only")
    }

    @Test func versionsStoreAProseDiff() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        model.answer = { _ in #"{"now":["New line."],"needs_you":[],"purpose":""}"# }
        src.setThreads("p", [briefThread("t1", .done)])
        let store = MemoryBriefStore()
        let engine = makeEngine(src, model, store: store)
        engine.boardChanged("p"); await engine.idle()
        let v = store.versions("p")
        #expect(v.count == 1 && v[0].diff.contains("+ now: New line."))
    }

    @Test func theSQLiteStoreKeepsVersionsAndKey() throws {
        let path = NSTemporaryDirectory() + "briefs-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let a = try SQLiteBriefStore(path: path)
        a.append(BriefVersion(project: "p", version: 1, at: 5, prose: BriefDoc.Prose(now: ["x"]), diff: "+ x"))
        a.setKey("p", "k1")
        let b = try SQLiteBriefStore(path: path)
        #expect(b.latest("p")?.prose.now == ["x"] && b.key("p") == "k1" && b.key("q") == nil)
    }
}

enum FakeBriefModelRead {
    static func last(_ m: FakeBriefModel) -> String { m.contexts.last ?? "" }
}

@MainActor @Suite struct GeneralBriefLead {
    @Test func theLeadRunsAfterTheBatchAndNotWhenNothingChanged() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("a", [briefThread("t1", .needsYou)])
        src.setThreads("b", [briefThread("t2", .working)])
        model.answer = { c in c.contains("t1") ? askAnswer : #"{"now":["Busy."],"needs_you":[],"purpose":""}"# }
        let engine = makeEngine(src, model)
        engine.boardChanged("a"); engine.boardChanged("b"); await engine.idle()
        #expect(model.leadContexts.count == 1)
        #expect(model.leadContexts[0].contains("Which one?") && model.leadContexts[0].contains("Busy."))
        #expect(engine.general.forYou == "Two things need you.")
        // A change that moves neither what needs you nor what finished: no lead.
        src.setThreads("b", [ran(briefThread("t2", .working), at: 5)])
        engine.boardChanged("b"); await engine.idle()
        #expect(model.leadContexts.count == 1)
        // The Board changing alone (mark read, a view) never runs it either.
        engine.boardChanged("a"); await engine.idle()
        #expect(model.leadContexts.count == 1)
    }
}
