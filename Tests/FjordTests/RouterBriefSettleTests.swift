import Foundation
import Testing
@testable import Fjord

@MainActor @Suite struct BriefSettle {
    @Test func settlingAThreadDropsItsLineAtOnceAndAnUntaggedOneCostsNoCall() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p", [briefThread("t1", .done), briefThread("t2", .done), briefThread("t3", .working)])
        model.answer = { _ in #"{"now":["<t id=\"t1\">The first</t> is done.","<t id=\"t2\">The second</t> is done.","Things move."],"needs_you":[],"decisions":[],"loose_ends":[]}"# }
        let engine = makeEngine(src, model)
        src.post("p", id: "m1", kind: .message, thread: "t1", text: "x")
        engine.itemsChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.now.count == 3)
        let calls = model.contexts.count
        // t3 is untagged: settling it changes no line and calls nothing.
        src.setThreads("p", [briefThread("t1", .done), briefThread("t2", .done)])
        engine.boardChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.now.count == 3 && model.contexts.count == calls)
        // t1 is tagged: its whole line goes, with no call.
        src.setThreads("p", [briefThread("t2", .done)])
        engine.boardChanged("p"); await engine.idle()
        #expect(engine.docs["p"]?.now.count == 2 && !(engine.docs["p"]?.now.joined().contains("t1") ?? true))
        #expect(model.contexts.count == calls)
    }

    @Test func aModelEntryForAThreadOffTheBoardIsDropped() {
        var board = BriefBoard()
        board.threads = [briefThread("t1", .done)]
        let mine = BriefEntry(project: "p", thread: "t1", kind: .question, state: .done, since: 1)
        let gone = BriefEntry(project: "p", thread: "t2", kind: .stranded, state: .needsYou, since: 1)
        #expect(RouterBriefEngine.entries(model: [mine, gone], board: board).map(\.thread) == ["t1"])
    }
}
