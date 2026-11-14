import Foundation
import Testing
@testable import Fjord

/// Show me on the Router page (RouterShowMe.swift, SHOWME.md §7–§8): the toggle and ⌘Return mark a send, Show me on a Done
/// card asks the engine, and with the panel on an explainer Return's words are its follow-up, not the threads'.
@MainActor
@Suite struct RouterShowMeTests {
    typealias ID = RouterDemo.ID

    @MainActor final class Engine: RouterExplainers {
        var replies: [String] = [], followUps: [(String, String)] = [], watched: [String] = [], opened: [String] = []
        var fails: Error?
        func explain(reply thread: String) { replies.append(thread) }
        func followUp(_ explainer: String, words: String) async throws {
            followUps.append((explainer, words))
            if let fails { throw fails }
        }
        func watched(_ explainer: String) { watched.append(explainer) }
        func open(explainer: String) { opened.append(explainer) }
    }

    private func page(_ state: RouterShowMeState = RouterShowMeState()) -> (RouterModel, RouterModelTests.Recorder, Engine) {
        let model = RouterDemo.records()
        let source = RouterModelTests.Recorder()
        source.model = model
        model.source = source
        let engine = Engine()
        model.explainers = engine
        model.showMe = state
        return (model, source, engine)
    }

    private func typed(_ model: RouterModel, _ words: String, to id: String) {
        model.setDraft(words)
        model.apply(.read(RouterRead(draft: words, places: [.thread(id)], sure: true)))
    }

    private static func ready(_ id: String = "e1") -> ExplainerItem {
        ExplainerItem(id: id, title: "Why the token", thread: "", source: ID.settings, answer: "", captions: [], since: Date(),
                      stage: .ready, length: 20, launched: true)
    }

    @Test func commandReturnSendsWithShowMeOnceAndTheToggleEveryTime() {
        let (model, source, _) = page()
        typed(model, "why the token?", to: ID.bar)
        model.showMeReturn()
        typed(model, "and then?", to: ID.bar)
        model.send()
        model.showMe?.armed = true
        typed(model, "one more", to: ID.bar)
        model.send()
        #expect(source.sends.map(\.showMe) == [true, false, true])
    }

    @Test func withoutShowMeNothingIsMarked() {
        let (model, source, _) = page()
        model.showMe = nil
        typed(model, "why the token?", to: ID.bar)
        model.showMeReturn()
        #expect(source.sends.map(\.showMe) == [false])
    }

    @Test func commandReturnOnADoneCardWithNothingTypedExplainsItsReply() {
        let (model, source, engine) = page()
        model.select(.line(ID.guide))
        model.showMeReturn()
        #expect(engine.replies == [ID.guide])
        #expect(source.sends.isEmpty)
        // A card that isn't Done has no reply to explain.
        model.select(.line(ID.settings))
        model.showMeReturn()
        #expect(engine.replies == [ID.guide])
    }

    @Test func withThePanelOnAnExplainerReturnIsAFollowUpAndTheDraftIsntRead() async {
        let (model, source, engine) = page(RouterShowMeState(open: true, selected: "e1", explainers: [Self.ready()]))
        model.setDraft("simpler")
        #expect(!source.calls.contains { if case .read = $0 { true } else { false } })
        model.send()
        #expect(source.sends.isEmpty)
        #expect(model.draft.isEmpty)
        await Task.yield()
        #expect(engine.followUps.map(\.0) == ["e1"] && engine.followUps.map(\.1) == ["simpler"])
    }

    @Test func aFollowUpThatFailsGivesTheWordsBackWithWhy() async {
        let (model, _, engine) = page(RouterShowMeState(open: true, selected: "e1", explainers: [Self.ready()]))
        engine.fails = ThreadSendFailure("That explainer isn't Fjord's anymore")
        model.setDraft("simpler")
        model.send()
        for _ in 0..<5 { await Task.yield() }
        #expect(model.draft == "simpler")
        #expect(model.showMe?.note == "That explainer isn't Fjord's anymore")
    }

    @Test func closingThePanelGivesTheDraftBackToTheThreads() {
        let (model, source, _) = page(RouterShowMeState(open: true, selected: "e1", explainers: [Self.ready()]))
        model.setDraft("simpler")
        model.toggleShowMeDock()
        #expect(source.calls.contains { if case .read("simpler", _, _) = $0 { true } else { false } })
    }

    @Test func whileOnePlaysTheListFoldsAndPickingOneFoldsItAgain() {
        var state = RouterShowMeState(open: true, selected: "e1", explainers: [Self.ready("e1"), Self.ready("e2")])
        #expect(state.playing && state.target?.id == "e1")
        state.explainers[0].stage = .queued
        #expect(!state.playing && state.target == nil)
        let (model, _, _) = page(RouterShowMeState(open: true, selected: "e1", expanded: true,
                                                   explainers: [Self.ready("e1"), Self.ready("e2")]))
        model.selectExplainer("e2")
        #expect(model.showMe?.selected == "e2" && model.showMe?.expanded == false)
    }

    @Test func aSelectionThatLeftTheListGoesToTheNewest() {
        var state = RouterShowMeState(selected: "gone", explainers: [])
        state.update([Self.ready("new"), Self.ready("old")])
        #expect(state.selected == "new")
    }
}
