import AppKit
import Foundation
import Testing
@testable import Fjord

@MainActor final class RecordingBriefEvents: BriefEvents {
    var calls: [String] = []
    func itemsChanged(_ project: String) { calls.append("items " + project) }
    func boardChanged(_ project: String) { calls.append("board " + project) }
}

private func facts(_ threads: [CourierBriefFacts.Thread], cardItems: [String: CourierBriefFacts.Card] = [:], watch: CourierWatch = .live,
                   turning: Bool = false) -> CourierBriefFacts {
    CourierBriefFacts(project: "chan_p", name: "p", threads: threads, watch: watch, turning: turning, cardItems: cardItems)
}

private func th(_ id: String, _ status: String?, state: String = "idle", session: String? = nil, at: Double = 10, needs: String? = nil) -> CourierBriefFacts.Thread {
    .init(id: id, title: "T " + id, state: state, touched: 5, session: session, status: status, statusAt: at, needs: needs)
}

@MainActor @Suite struct BriefAdapter {
    @Test func newItemsCallTheModelPathABoardChangeOnlyRebuildsAndATurnEndCallsToo() {
        let events = RecordingBriefEvents()
        RouterBriefLink.deliver(CourierBriefChange(items: ["a"], board: ["a", "b"], turnEnded: ["c"]), to: events)
        #expect(events.calls == ["items a", "items c", "board b"])
    }

    @Test func theHostsChangesDriveTheEngineAsTheyArrive() async {
        let events = RecordingBriefEvents()
        var sink: AsyncStream<CourierBriefChange>.Continuation!
        let stream = AsyncStream<CourierBriefChange> { sink = $0 }
        let link = RouterBriefLink()
        var names: [String: String] = [:]
        link.onChange = { names = $0.names }
        link.follow(stream, events: events)
        sink.yield(CourierBriefChange(items: ["chan_p"], names: ["chan_p": "p"]))
        sink.yield(CourierBriefChange(board: ["chan_q"]))
        sink.finish()
        for _ in 0..<50 where events.calls.count < 2 { await Task.yield() }
        #expect(events.calls == ["items chan_p", "board chan_q"])
        #expect(names.isEmpty || names == ["chan_p": "p"])
    }

    @Test func logItemsMapToTheBriefsKinds() {
        func ci(_ kind: String, thread: String?, _ content: JSON) -> CourierItem {
            CourierItem(seq: 7, at: 1, project: "chan_p", thread: thread, kind: kind, id: "k", content: content)
        }
        #expect(CourierBriefSource.item(ci("row", thread: nil, ["from": "claude", "text": "done"]))?.kind == .coordinator)
        #expect(CourierBriefSource.item(ci("row", thread: "t", ["from": "claude", "text": "hi"]))?.kind == .message)
        let answered = CourierBriefSource.item(ci("answer", thread: "t", ["card": "c", "option": 2, "text": "Blue — replies Blue"]))
        #expect(answered?.kind == .message && answered?.text == "you answered: Blue — replies Blue" && answered?.thread == "t")
        let card = CourierBriefSource.item(ci("card", thread: "t", ["kind": "plan", "options": ["Yes", "No"], "answered": false]))
        #expect(card?.kind == .card && card?.options == ["Yes", "No"] && card?.urgent == true)
        let status = CourierBriefSource.item(ci("status", thread: "t", ["status": "needs you"]))
        #expect(status?.status == .needsYou && status?.seq == 7)
        #expect(CourierBriefSource.item(ci("session", thread: "t", ["state": "stranded"]))?.kind == .stranded)
    }

    @Test func turningOfAStaleProjectReadsFalse() {
        let b = CourierBriefSource.board(facts([th("t", "working")], watch: .stale(since: 3), turning: true))
        #expect(!b.coordinatorTurning)
        #expect(b.watch == "stale:3.0" && b.threads.first?.asOf == 3)
    }
}

@MainActor @Suite struct BriefEntryBuilding {
    @Test func aPendingCardIsAnEntryWithItsRowKeyAndOptionsAsData() {
        let b = CourierBriefSource.board(facts([th("t1", "needs you"), th("t2", "working")],
                                               cardItems: ["t1": .init(key: "row_9", kind: "question", options: ["A", "B"], text: "Which?")]))
        #expect(b.entries.count == 1)
        let e = b.entries[0]
        #expect(e.kind == .question && e.card == "row_9" && e.options == ["A", "B"] && e.question == "Which?" && e.since == 10)
    }

    @Test func aPermissionAStrandedSessionAndPlainWords() {
        let b = CourierBriefSource.board(facts([th("p", "needs you", needs: "permission"),
                                                th("s", "needs you", state: "stranded", session: "cse_1", at: 2),
                                                th("w", "needs you", at: 5)]))
        #expect(b.entries.map(\.kind) == [.stranded, .request, .permission])
        #expect(b.entries[0].source == .local)
    }

    @Test func theModelWritesAPlainWordsQuestionButNeverACardsOptions() {
        var board = BriefBoard(threads: [briefThread("t1", .needsYou), briefThread("t2", .needsYou)])
        board.entries = [
            BriefEntry(project: "p", thread: "t1", kind: .question, state: .needsYou, since: 5, source: .cloud, question: "Page words?", options: ["A", "B"], card: "row_1"),
            BriefEntry(project: "p", thread: "t2", kind: .request, state: .needsYou, since: 6, source: .cloud),
        ]
        let model = [
            BriefEntry(project: "p", thread: "t1", kind: .question, state: .needsYou, since: 1, source: .cloud, question: "Model words", options: ["x"]),
            BriefEntry(project: "p", thread: "t2", kind: .request, state: .needsYou, since: 9, source: .cloud, question: "Ship today?"),
            BriefEntry(project: "p", thread: "gone", kind: .question, state: .needsYou, since: 1, source: .cloud, question: "Old"),
        ]
        let out = RouterBriefEngine.entries(model: model, board: board)
        #expect(out.map(\.thread) == ["t1", "t2"])
        #expect(out[0].options == ["A", "B"] && out[0].card == "row_1" && out[0].question == "Page words?")
        #expect(out[1].question == "Ship today?")
    }

    @Test func anEntryLeavesOnceItsThreadNoLongerNeedsYou() {
        let board = BriefBoard(threads: [briefThread("t1", .working)])
        let model = [BriefEntry(project: "p", thread: "t1", kind: .question, state: .needsYou, since: 1, source: .cloud)]
        #expect(RouterBriefEngine.entries(model: model, board: board).isEmpty)
    }

    @Test func aLocalEntryCarriesTheHooksFormAndItsOptions() {
        let store = Store()
        store.persists = false
        let briefs = store.routerBriefs
        briefs.sessions = ["local:cli": "cse_1"]
        briefs.clis = ["cse_1": "cli"]
        store.pendingForms["cli"] = PendingForm(id: "f1", cliSessionID: "cli", transcriptPath: "",
            questions: [.init(question: "Silent?", header: "", multiSelect: false, options: [.init(label: "Yes", description: ""), .init(label: "No", description: "")])],
            createdAt: Date(), pid: 0, toolUseID: "tu")
        let e = BriefEntry(project: "local:x", thread: "local:cli", kind: .request, state: .needsYou, since: 1, source: .local)
        let r = briefs.resolved(e, store: store)
        #expect(r.form?.formID == "f1" && r.form?.toolUseID == "tu")
        #expect(r.kind == .question && r.question == "Silent?" && r.options == ["Yes", "No"])
    }
}

@Suite struct BriefKeysTests {
    @Test func digitsByPhysicalKeyCodeAsOnAZERTY() {
        // AZERTY's top row types & é " ' ( - è _ ç unshifted: the codes decide, never the characters.
        let azerty = ["&", "é", "\"", "'", "(", "-", "è", "_", "ç"]
        for (i, code) in [18, 19, 20, 21, 23, 22, 26, 28, 25].enumerated() {
            #expect(BriefKeys.action(code: code, characters: azerty[i], flags: [], focused: true, composerEmpty: true) == .pick(i + 1))
        }
    }

    @Test func liveOnlyWithAnEntryFocusedAndTheComposerEmpty() {
        #expect(BriefKeys.action(code: 18, characters: "1", flags: [], focused: false, composerEmpty: true) == nil)
        #expect(BriefKeys.action(code: 18, characters: "1", flags: [], focused: true, composerEmpty: false) == nil)
        for c in ["o", "a", "r"] { #expect(BriefKeys.action(code: 0, characters: c, flags: [], focused: true, composerEmpty: false) == nil) }
        #expect(BriefKeys.action(code: 0, characters: "o", flags: [], focused: true, composerEmpty: true) == .open)
        #expect(BriefKeys.action(code: 0, characters: "A", flags: .shift, focused: true, composerEmpty: true) == .archive)
        #expect(BriefKeys.action(code: 0, characters: "r", flags: [], focused: true, composerEmpty: true) == .read)
        #expect(BriefKeys.action(code: 36, characters: "\r", flags: [], focused: true, composerEmpty: true) == .confirm)
        #expect(BriefKeys.action(code: 53, characters: nil, flags: [], focused: true, composerEmpty: true) == .back)
        #expect(BriefKeys.action(code: 18, characters: "1", flags: .command, focused: true, composerEmpty: true) == nil)
    }
}

@Suite struct BriefPageOrder {
    private func doc(_ id: String, threads: [BriefThread] = [], entries: [BriefEntry] = []) -> BriefDoc {
        var d = BriefDoc(project: id); d.threads = threads; d.needsYou = entries; return d
    }
    private func entry(_ p: String, _ t: String, _ kind: BriefEntry.Kind, since: Double) -> BriefEntry {
        BriefEntry(project: p, thread: t, kind: kind, state: .needsYou, since: since, source: .cloud)
    }

    @Test func needsYouOldestFirstThenStrandedFinishedNewestWorkingQuiet() {
        let now = 100_000.0
        let docs = [
            "quiet": doc("quiet"),
            "work": doc("work", threads: [BriefThread(id: "w", title: "", status: .working, age: now - 10)]),
            "finA": doc("finA", threads: [BriefThread(id: "f1", title: "", status: .done, age: now - 500)]),
            "finB": doc("finB", threads: [BriefThread(id: "f2", title: "", status: .done, age: now - 50)]),
            "strand": doc("strand", entries: [entry("strand", "s", .stranded, since: now - 5)]),
            "newNeed": doc("newNeed", entries: [entry("newNeed", "n", .question, since: now - 10)]),
            "oldNeed": doc("oldNeed", entries: [entry("oldNeed", "o", .plan, since: now - 900)]),
        ]
        let page = BriefPage.make(docs: docs, names: [:], lead: GeneralBrief(), read: [], told: [], now: now)
        #expect(page.sections.map(\.id) == ["oldNeed", "newNeed", "strand", "finB", "finA", "work", "quiet"])
        #expect(page.needsYou == 3)
        let told = BriefPage.make(docs: docs, names: [:], lead: GeneralBrief(), read: [BriefPage.entryKey(entry("oldNeed", "o", .plan, since: now - 900))],
                                  told: [BriefPage.finishKey(BriefThread(id: "f2", title: "", status: .done, age: now - 50))], now: now)
        #expect(told.needsYou == 2)
        #expect(told.sections.first?.id == "newNeed")
        #expect(told.sections.first { $0.id == "finB" }?.group == .quiet)
    }

    @Test func twelveSectionsAtMostTheRestFoldedByName() {
        var docs: [String: BriefDoc] = [:]
        for i in 0..<15 { docs["p\(i)"] = doc("p\(i)") }
        let page = BriefPage.make(docs: docs, names: Dictionary(uniqueKeysWithValues: (0..<15).map { ("p\($0)", String(format: "n%02d", $0)) }),
                                  lead: GeneralBrief(), read: [], told: [], now: 0)
        #expect(page.sections.count == 12 && page.folded == ["n12", "n13", "n14"])
    }

    @Test func onlyThreadsTouchedInADayAreListed() {
        let now = 200_000.0
        let d = doc("p", threads: [BriefThread(id: "a", title: "", status: .paused, age: now - 100),
                                   BriefThread(id: "b", title: "", status: .paused, age: now - 90_000)])
        let page = BriefPage.make(docs: ["p": d], names: [:], lead: GeneralBrief(), read: [], told: [], now: now)
        #expect(page.sections[0].recent.map(\.id) == ["a"])
    }
}
