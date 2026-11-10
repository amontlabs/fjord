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
