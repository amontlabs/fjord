import AppKit
import Foundation
import Testing
@testable import Fjord

@MainActor final class RecordingBriefEvents: BriefEvents {
    var calls: [String] = []
    func itemsChanged(_ project: String) { calls.append("items " + project) }
    func boardChanged(_ project: String) { calls.append("board " + project) }
}

@MainActor @Suite struct BriefEntryBuilding {
    @Test func theModelWritesAPlainWordsQuestionButNeverACardsOptions() {
        var board = BriefBoard(threads: [briefThread("t1", .needsYou), briefThread("t2", .needsYou)])
        board.entries = [
            BriefEntry(project: "p", thread: "t1", kind: .question, state: .needsYou, since: 5, question: "Page words?", options: ["A", "B"]),
            BriefEntry(project: "p", thread: "t2", kind: .request, state: .needsYou, since: 6),
        ]
        let model = [
            BriefEntry(project: "p", thread: "t1", kind: .question, state: .needsYou, since: 1, question: "Model words", options: ["x"]),
            BriefEntry(project: "p", thread: "t2", kind: .request, state: .needsYou, since: 9, question: "Ship today?"),
            BriefEntry(project: "p", thread: "gone", kind: .question, state: .needsYou, since: 1, question: "Old"),
        ]
        let out = RouterBriefEngine.entries(model: model, board: board)
        #expect(out.map(\.thread) == ["t1", "t2"])
        #expect(out[0].options == ["A", "B"] && out[0].question == "Page words?")
        #expect(out[1].question == "Ship today?")
    }

    @Test func anEntryLeavesOnceItsThreadNoLongerNeedsYou() {
        let board = BriefBoard(threads: [briefThread("t1", .working)])
        let model = [BriefEntry(project: "p", thread: "t1", kind: .question, state: .needsYou, since: 1)]
        #expect(RouterBriefEngine.entries(model: model, board: board).isEmpty)
    }

    @Test func aLocalEntryCarriesT3sQuestionAndItsOptions() {
        let store = Store()
        store.persists = false
        let briefs = store.routerBriefs
        store.requests["th_1"] = ThreadRequest(id: "r1", threadID: "th_1", body: .question([
            T3Question(demo: "", "Silent?", options: [("Yes", ""), ("No", "")])]))
        let e = BriefEntry(project: "local:x", thread: "th_1", kind: .request, state: .needsYou, since: 1)
        let r = briefs.resolved(e, store: store)
        #expect(r.request?.id == "r1")
        #expect(r.kind == .question && r.question == "Silent?" && r.options == ["Yes", "No"])
    }

    @Test func aPermissionOffersT3sDecisionsAsButtons() {
        let store = Store()
        store.persists = false
        store.requests["th_1"] = ThreadRequest(id: "r1", threadID: "th_1", body: .approval(
            kind: "command", prompt: "rm -rf build", decisions: ThreadRequest.fallbackDecisions))
        let e = BriefEntry(project: "local:x", thread: "th_1", kind: .question, state: .needsYou, since: 1)
        let r = store.routerBriefs.resolved(e, store: store)
        #expect(r.kind == .permission && r.question == "rm -rf build")
        #expect(r.options == ["Allow", "Allow for this session", "Always allow", "Decline"])
    }

    @Test func aPlanOffersTheTwoYesesAndAnExpiredRequestOffersNoButtons() {
        let store = Store()
        store.persists = false
        store.requests["th_1"] = ThreadRequest(id: "p1", threadID: "th_1", body: .plan(markdown: "# Ship"))
        store.requests["th_2"] = ThreadRequest(id: "r2", threadID: "th_2", body: .question([
            T3Question(demo: "", "Silent?", options: [("Yes", ""), ("No", "")])]), live: false)
        func entry(_ id: String) -> BriefEntry { BriefEntry(project: "local:x", thread: id, kind: .question, state: .needsYou, since: 1) }
        let plan = store.routerBriefs.resolved(entry("th_1"), store: store)
        #expect(plan.kind == .plan && plan.options == ["Yes, auto-accept", "Yes, manually"])
        let gone = store.routerBriefs.resolved(entry("th_2"), store: store)
        #expect(gone.options.isEmpty && gone.question?.contains("T3 restarted") == true)
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
        BriefEntry(project: p, thread: t, kind: kind, state: .needsYou, since: since)
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
