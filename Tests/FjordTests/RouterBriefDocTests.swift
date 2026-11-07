import Foundation
import Testing
@testable import Fjord

@MainActor @Suite struct BriefDocChecks {
    @Test func seeingTheSameItemAgainThroughTheSourceAddsNothing() {
        let src = FakeBriefSource()
        src.post("p", id: "m1", kind: .message, text: "hi")
        src.post("p", id: "m1", kind: .message, text: "hi")  // a reload, a second frame
        #expect(src.count("p") == 1)
        src.post("p", id: "m1", kind: .message, text: "hi, edited")  // changed content of an id: stored once
        src.post("p", id: "m1", kind: .message, text: "hi, edited")
        #expect(src.count("p") == 2)
    }

    @Test func aRepeatOfAFinishAddsNoEntry() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .done)])
        // The brief already covers the finish: the canned answer leaves it as it was.
        model.answer = { _ in #"{"now":["t1 finished."],"needs_you":[],"decisions":[],"loose_ends":[]}"# }
        let store = MemoryBriefStore()
        let engine = makeEngine(src, model, store: store)
        src.post("p", id: "s1", kind: .status, thread: "t1", status: .done)
        engine.itemsChanged("p"); await engine.idle()
        let version = engine.docs["p"]?.version
        src.post("p", id: "c1", kind: .message, text: "t1 is done!")
        engine.itemsChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.needsYou.isEmpty == true)
        #expect(engine.docs["p"]?.version == version)  // no new version
        #expect(store.versions("p").count == 1 && store.cursor("p") == 2)
        // The call was given the brief that already covers it.
        #expect(FakeBriefModelRead.last(model).contains("now: t1 finished."))
    }

    @Test func theAnswerIsCheckedIdsOptionsAndCaps() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .needsYou), briefThread("t2", .done)])
        model.answer = { _ in
            #"{"now":["1","2","3","4"],"needs_you":[{"thread":"t1","kind":"question","question":"Which?","options":["wrong"]},{"thread":"ghost","kind":"plan","question":"?","options":[]},{"thread":"t2","kind":"question","question":"done already","options":[]}],"decisions":[{"thread":"send","text":"ok"},{"thread":"ghost","text":"no"}],"loose_ends":[]}"#
        }
        let engine = makeEngine(src, model)
        src.post("p", id: "card", kind: .card, thread: "t1", text: "Which?", options: ["red", "blue"])
        engine.itemsChanged("p"); await engine.idle()
        let doc = engine.docs["p"]!
        #expect(doc.now == ["1", "2", "3"])
        #expect(doc.needsYou.map(\.thread) == ["t1"])
        #expect(doc.needsYou[0].options == ["red", "blue"])  // the card item's, as data
        #expect(doc.decisions.map(\.thread) == ["send"])
    }

    @Test func aFailureKeepsTheOldProseStaleAndTheDeterministicPartStillRebuilds() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        model.answer = { _ in #"{"now":["Old prose."],"needs_you":[],"decisions":[],"loose_ends":[]}"# }
        let engine = makeEngine(src, model)
        src.post("p", id: "m1", kind: .message, text: "a")
        engine.itemsChanged("p"); await engine.idle()
        model.failing = true
        src.post("p", id: "m2", kind: .message, text: "b")
        engine.itemsChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.now == ["Old prose."] && engine.docs["p"]?.proseStale == true)
        // A Board change: instantly, with no model call.
        let calls = model.contexts.count
        src.setThreads("p", [briefThread("t9", .working)])
        engine.boardChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.threads.map(\.id) == ["t9"] && model.contexts.count == calls)
    }

    @Test func versionsStoreTheirItemsAndAProseDiff() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        model.answer = { _ in #"{"now":["New line."],"needs_you":[],"decisions":[],"loose_ends":[]}"# }
        let store = MemoryBriefStore()
        let engine = makeEngine(src, model, store: store)
        src.post("p", id: "m1", kind: .message, text: "a")
        engine.itemsChanged("p"); await engine.idle()
        let v = store.versions("p")
        #expect(v.count == 1 && v[0].items == [1] && v[0].diff.contains("+ now: New line."))
    }

    @Test func theSQLiteStoreKeepsVersionsAndCursor() throws {
        let path = NSTemporaryDirectory() + "briefs-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let a = try SQLiteBriefStore(path: path)
        a.append(BriefVersion(project: "p", version: 1, at: 5, prose: BriefDoc.Prose(now: ["x"]), diff: "+ x", items: [1, 2], cursor: 2))
        a.setCursor("p", 2)
        let b = try SQLiteBriefStore(path: path)
        #expect(b.latest("p")?.prose.now == ["x"] && b.latest("p")?.items == [1, 2] && b.cursor("p") == 2 && b.cursor("q") == 0)
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
        model.answer = { c in c.contains("thread t1") ? askAnswer : #"{"now":["Busy."],"needs_you":[],"decisions":[],"loose_ends":[]}"# }
        let engine = makeEngine(src, model)
        src.post("a", id: "c", kind: .card, thread: "t1", text: "Which one?", options: ["x"])
        src.post("b", id: "m", kind: .message, thread: "t2", text: "go")
        engine.itemsChanged("a"); engine.itemsChanged("b"); await engine.idle()
        #expect(model.leadContexts.count == 1)
        #expect(model.leadContexts[0].contains("Which one?") && model.leadContexts[0].contains("Busy."))
        #expect(engine.general.forYou == "Two things need you.")
        // A change that moves neither what needs you nor what finished: no lead.
        src.post("b", id: "m2", kind: .message, thread: "t2", text: "more")
        engine.itemsChanged("b"); await engine.idle()
        #expect(model.leadContexts.count == 1)
        // The Board changing alone (mark read, a view) never runs it either.
        engine.boardChanged("a"); await engine.idle()
        #expect(model.leadContexts.count == 1)
    }
}
