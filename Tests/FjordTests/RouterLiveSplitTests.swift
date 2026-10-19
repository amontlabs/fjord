import Foundation
import Testing
@testable import Fjord

/// The draft divided into several places while you type, and the Brief's ⌘-clicked recipients: the parts show under the composer
/// once Jev's read has both compound gates up (once the draft is still, never per keystroke), Return sends exactly what is shown,
/// and the recipients each get the whole message. The model, Jev and the sender are stood in for.
@MainActor
@Suite(.serialized) struct RouterLiveSplitTests {
    typealias World = RouterSplitTests.World

    private let both = "add the page and rerun the build"

    /// The split tests' world, with its dispatcher the one the store (and so the live target) asks.
    private func world() -> World {
        let w = World()
        w.store.routerDispatcher = w.dispatcher
        return w
    }

    private func gatesUp(_ w: World) {
        w.f.ranked = [.init(target: "compound", p: 0.9), .init(target: "session:local_b", p: 0.05), .init(target: "unclear", p: 0.05)]
        w.f.gates = ["gate_compound": 0.9, "gate_compound2": 0.8, "gate_you": 0]
        w.f.ungated = .init(ranked: [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)], sure: true, card: nil)
        w.f.division = .init(parts: [.init(target: "session:local_b", text: "add the page", waitsFor: nil),
                                     .init(target: "session:local_c", text: "rerun the build", waitsFor: "session:local_b")],
                             sure: false, alternatives: [])
    }

    private func model() -> RouterModel {
        let model = RouterModel()
        model.live.delay = .zero
        return model
    }

    private func type(_ text: String, _ model: RouterModel, _ w: World) {
        model.draft = text
        model.predictTarget(store: w.store)
    }

    @Test func theDividerIsAskedOnceAndItsPartsShowInPlaceOfThePick() async {
        let w = world()
        gatesUp(w)
        let model = model()
        type(both, model, w)
        await waitUntil { model.live.division != nil }
        #expect(model.live.division?.parts.count == 2 && model.live.dividing == false && model.live.prediction == nil)
        #expect(model.live.chips.map(\.title) == ["Update the docs", "Ship it"] && model.live.chips.map(\.words) == ["add the page", "rerun the build"])
        #expect(model.live.chips.map(\.waits) == [false, true])
        #expect(w.f.ranks == 1 && w.f.divideRequests.count == 1)
        // The same words again (a pill or the reply changing): nothing more is asked.
        type(both, model, w)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(w.f.ranks == 1 && w.f.divideRequests.count == 1 && model.live.division != nil)
    }

    @Test func aCompoundTopWithOneGateDownIsDividedLiveAsTheSendDivides() async throws {
        let w = world()
        gatesUp(w)
        // Not both gates, but his top pick is compound: the send asks the divider, so what is shown is what it asks.
        w.f.gates = ["gate_compound": 0.9, "gate_compound2": 0.2]
        let model = model()
        type(both, model, w)
        await waitUntil { model.live.division != nil }
        #expect(model.live.chips.map(\.words) == ["add the page", "rerun the build"] && w.f.divideRequests.count == 1)
        var context = model.context(w.store)
        context.flies = false
        let id = try #require(w.dispatcher.submit(both, context: context))
        await w.finishAll(id)
        #expect(w.f.divideRequests.count == 1 && w.entry(id)?.parts.count == 2, "sent as shown: the divider was not asked again")
        // A top that isn't compound, with one gate down, is neither shown nor sent as parts.
        w.f.ranked = [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)]
        let other = self.model()
        type(both + "!", other, w)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(other.live.division == nil && w.f.divideRequests.count == 1)
    }

    @Test func changedWordsTakeTheDivisionAway() async {
        let w = world()
        gatesUp(w)
        let model = model()
        type(both, model, w)
        await waitUntil { model.live.division != nil }
        w.f.ranked = [.init(target: "session:local_b", p: 0.9)]
        w.f.gates = [:]
        type(both + ", then something else", model, w)
        #expect(model.live.division == nil && model.live.chips.isEmpty)
        await waitUntil { w.f.ranks == 2 }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.live.division == nil && model.live.dividing == false)
    }

    @Test func theContextCarriesTheDivisionOnlyForTheExactWordsAndReturnAsksTheDividerNothingAgain() async throws {
        let w = world()
        gatesUp(w)
        let model = model()
        type(both, model, w)
        await waitUntil { model.live.division != nil }
        #expect(model.context(w.store).division == model.live.division)
        model.draft = both + "!"
        #expect(model.context(w.store).division == nil, "it was shown for other words")
        model.draft = both
        // A place gone since: not a division to send.
        w.store.claudeSessions["local_c"]?.isArchived = true
        #expect(model.context(w.store).division == nil)
        w.store.claudeSessions["local_c"]?.isArchived = false
        var context = model.context(w.store)
        #expect(context.division != nil)
        context.flies = false
        let id = try #require(w.dispatcher.submit(both, context: context))
        await w.finishAll(id)
        #expect(w.f.divideRequests.count == 1 && w.entry(id)?.parts.count == 2 && w.dispatcher.askBacks.isEmpty)
        #expect(w.f.ranks == 1, "Jev was not asked again")
    }

    @Test func aChangeOfTheFirstLinesIndentationIsAChangeOfWords() async throws {
        let w = world()
        gatesUp(w)
        let model = model()
        type(both, model, w)
        await waitUntil { model.live.division != nil }
        #expect(model.context(w.store).division != nil)
        // Only blank lines before it and whitespace after it are left out of what is sent; an indent is part of the words.
        model.draft = "\n" + both + "  "
        #expect(model.context(w.store).division != nil)
        model.draft = "    " + both
        #expect(model.context(w.store).division == nil, "the parts were cut from other words")
        // Typed that way, the parts are read again, for the words as they are, and not taken from the answer for the others.
        type("    " + both, model, w)
        #expect(model.live.division == nil && model.live.chips.isEmpty)
        await waitUntil { w.f.divideRequests.count == 2 }
        await waitUntil { model.live.division != nil }
        #expect(w.f.divideRequests.count == 2 && w.f.divideRequests[1].message == "    " + both)
        #expect(model.context(w.store).division?.text == "    " + both)
    }

    @Test func recipientsFixWhereItGoesAndEachGetsTheWholeMessage() async throws {
        let w = world()
        gatesUp(w)
        let model = model()
        model.live.recipients = ["session:local_b", "session:local_c"]
        type(both, model, w)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(w.f.ranks == 0 && model.live.division == nil && model.live.prediction == nil, "nothing is asked: they fix it")
        let context = model.context(w.store)
        #expect(context.recipients == ["session:local_b", "session:local_c"])
        let id = try #require(w.dispatcher.submit(both, context: context))
        await w.finishAll(id)
        #expect(w.entry(id)?.parts.count == 2)
        #expect(w.words(of: "local_b") == [both] && w.words(of: "local_c") == [both])
        #expect(w.f.divideRequests.isEmpty)
        // A send puts them away.
        model.live.reset()
        #expect(model.live.recipients.isEmpty)
    }

    @Test func backspaceTakesTheLastRecipientOffFirst() {
        let model = model()
        model.replyTo = "local_a#w1"
        model.live.recipients = ["session:local_b", "session:local_c"]
        #expect(model.removeLastChip() && model.live.recipients == ["session:local_b"])
        #expect(model.removeLastChip() && model.live.recipients.isEmpty && model.replyTo == "local_a#w1")
        #expect(model.removeLastChip() && model.replyTo == nil)
    }

    @Test func pickingARecipientEndsAnEditSoTheDraftGoesToTheRecipients() {
        let w = world()
        let model = model()
        model.edit(session: "local_a", message: "use postgres")
        #expect(model.editing != nil)
        model.toggleRecipient("session:local_b", store: w.store)
        #expect(model.editing == nil && model.live.recipients == ["session:local_b"], "the two can't both hold")
        // Taking it off again edits nothing; a session that can't be sent to is no recipient and ends nothing.
        model.edit(session: "local_a", message: "use postgres")
        w.store.claudeSessions["local_c"]?.isArchived = true
        model.toggleRecipient("session:local_c", store: w.store)
        #expect(model.editing != nil && model.live.recipients.isEmpty)
    }

    @Test func aProjectGoneFromTheCodeFoldersChangesWhatTheWatcherSeesAndTheDivisionGoes() async throws {
        let w = world()
        gatesUp(w)
        w.f.division = .init(parts: [.init(target: "new:/code/app", text: "add the page", waitsFor: nil),
                                     .init(target: "session:local_c", text: "rerun the build", waitsFor: nil)], sure: false, alternatives: [])
        w.store.codeFolders.scan = { _ in .init(repos: ["/code/app": []]) }
        w.store.addCodeFolders(["/code"])
        await w.store.codeFolders.settled()
        let model = model()
        type(both, model, w)
        await waitUntil { model.live.division != nil }
        #expect(model.live.watchedTargets.contains("new:/code/app"))
        let before = RouterModel.targets(w.store, predicted: nil, watching: model.live.watchedTargets)
        // A scan finds the project gone: no card or session changed, yet what the parts can go to did.
        w.store.removeCodeFolder("/code")
        await w.store.codeFolders.settled()
        #expect(RouterModel.targets(w.store, predicted: nil, watching: model.live.watchedTargets) != before)
        model.revalidateTarget(store: w.store)
        #expect(model.live.division == nil && model.live.chips.isEmpty, "the parts are for a place that is gone: dropped")
        #expect(model.context(w.store).division == nil)
    }

    @Test func aRecipientThatIsGoneIsTakenOff() {
        let w = world()
        let model = model()
        model.live.recipients = ["session:local_b", "session:local_c"]
        w.store.claudeSessions["local_c"]?.isArchived = true
        model.live.revalidate(store: w.store)
        #expect(model.live.recipients == ["session:local_b"])
    }

    @Test func withJevNotReadingWhatYouTypeNoDivisionIsAsked() async {
        let w = world()
        gatesUp(w)
        w.store.settings.jevReadsDrafts = false
        let model = model()
        type(both, model, w)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(w.f.ranks == 0 && w.f.divideRequests.isEmpty && model.live.division == nil && !model.live.dividing)
    }
}
