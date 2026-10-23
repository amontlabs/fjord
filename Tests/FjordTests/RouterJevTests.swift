import Foundation
import Testing
@testable import Fjord

/// Jev's pick while you type: asked once typing pauses, shown when he is sure, fixed with a click, waved off with Esc, and its
/// card marked on the page.
@MainActor
@Suite(.serialized) struct RouterLiveTargetTests {
    private func setup() -> (Store, RouterModel, () -> Int) {
        let s = InboxFixture.store([])
        s.router.enabled = true
        s.agents.enabled = true
        s.claudeSessions = [
            "local_a": ClaudeSession(id: "local_a", title: "Fix the login bug", folder: "/code/lookout", lastActivity: Date(), running: false),
            "local_b": ClaudeSession(id: "local_b", title: "Update the docs", folder: "/code/docs", lastActivity: Date(), running: false),
        ]
        s.router.cards = [RouterCard(id: "local_a#w1", sessionID: "local_a", kind: .question, title: "Fix the login bug",
                                     folder: "/code/lookout", text: "Which database?", createdAt: Date())]
        var calls = 0
        s.routerDispatcher.asker = { questions, state in
            // The routing calls (the addressed gate's own call goes beside each one).
            guard case .structuredChoice(let keys, _, _) = questions["route"] else { return [:] }
            calls += 1
            // Sure of the session asking which database (its option, named by its title), when the message mentions one.
            let card = keys.first { $0 == "Fix the login bug" } ?? keys[0]
            let sure = state["message"]?.contains("database") == true
            var p = Dictionary(uniqueKeysWithValues: keys.map { ($0, sure ? 0.02 / Double(keys.count) : 1 / Double(keys.count)) })
            if sure { p[card] = 0.98 }
            return ["route": .choice(.init(choice: card, confidence: 0.9, probabilities: p))]
        }
        let model = RouterModel()
        model.live.delay = .zero
        return (s, model, { calls })
    }

    private func type(_ text: String, _ model: RouterModel, _ store: Store) {
        model.draft = text
        model.predictTarget(store: store)
    }

    @Test func aSurePickIsShownAndASoftOneOrAShortDraftIsNot() async {
        let (s, model, calls) = setup()
        type("use sqlite", model, s)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(calls() == 0 && model.live.prediction == nil, "too short to ask")
        type("I don't know yet, maybe later", model, s)
        await waitUntil { calls() == 1 }
        await waitUntil { model.live.prediction != nil }
        #expect(model.live.prediction?.unsure == true, "not sure: shown with a ?, nothing marked on the page")
        #expect(model.live.prediction?.mark == nil)
        #expect(model.context(s).shown == nil && model.context(s).jev == nil, "and a send goes as it would without it")
        type("use sqlite for the database", model, s)
        await waitUntil { model.live.prediction != nil }
        #expect(model.live.prediction?.unsure == false)
        #expect(model.live.prediction?.target == "answer:local_a#w1" && model.live.prediction?.title == "Fix the login bug")
        #expect(model.live.prediction?.mark == "local_a#w1")
        #expect(model.context(s).shown == "answer:local_a#w1", "sending these words goes with the pick shown")
        #expect(model.context(s).jev == model.live.prediction?.found, "and with what Jev made of them, as shown")
        model.draft = "use sqlite for the database, or not"
        #expect(model.context(s).shown == nil, "it was shown for other words")
        model.draft = "use sqlite for the database"
        model.markPrediction(from: nil, to: model.live.prediction?.mark)
        #expect(model.highlighted == "local_a#w1")
        model.markPrediction(from: "local_a#w1", to: nil)
        #expect(model.highlighted == nil)
    }

    @Test func withJevNotReadingWhatYouTypeNothingIsAskedUntilYouSend() async {
        let (s, model, calls) = setup()
        s.settings.jevReadsDrafts = false
        type("use sqlite for the database", model, s)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(calls() == 0 && model.live.prediction == nil)
        #expect(await s.routerDispatcher.predict("use sqlite for the database", projects: []) == nil && calls() == 0)
        // Switched off while he is asked: what comes back is dropped.
        s.settings.jevReadsDrafts = true
        let sure = s.routerDispatcher.asker!
        s.routerDispatcher.asker = { questions, state in
            s.settings.jevReadsDrafts = false
            return try await sure(questions, state)
        }
        #expect(await s.routerDispatcher.predict("use sqlite for the database", projects: []) == nil)
        // Sending still routes it.
        s.settings.jevReadsDrafts = false
        s.routerDispatcher.asker = sure
        #expect(s.routerDispatcher.submit("use sqlite for the database") != nil)
        await waitUntil { calls() == 2 }
        #expect(calls() == 2)
    }

    @Test func nothingIsAskedWhileAReplyFixesTheTarget() async {
        let (s, model, calls) = setup()
        model.replyTo = "local_a#w1"
        type("use sqlite for the database", model, s)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(calls() == 0 && model.live.prediction == nil)
    }

    @Test func clickingACardsPickMakesItTheReplyAndEscWavesItOff() async {
        let (s, model, _) = setup()
        type("use sqlite for the database", model, s)
        await waitUntil { model.live.prediction != nil }
        model.pinPrediction(store: s)
        #expect(model.replyTo == "local_a#w1" && model.live.prediction == nil)
        #expect(model.context(s).predicted == "answer:local_a#w1", "the reply goes as Jev's pick")

        model.replyTo = nil
        type("use sqlite for the database please", model, s)
        await waitUntil { model.live.prediction != nil }
        model.dismissPrediction()
        #expect(model.live.prediction == nil)
        #expect(model.context(s).notTo == "answer:local_a#w1", "the send won't go there unasked")
        type("use sqlite for the database, thanks", model, s)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.live.prediction == nil, "a waved-off target stays away for this draft")
    }

    @Test func theDraftIsSentAsWrittenWithItsFirstLinesIndentation() {
        let (s, model, _) = setup()
        model.draft = "\n  \n    let x = 1\n    let y = 2\n  "
        #expect(model.plainDraft(s) == "    let x = 1\n    let y = 2")
        model.draft = " \n "
        #expect(model.plainDraft(s).isEmpty)
    }

    @Test func theSendSaysWhereItsPillsAre() {
        let (s, model, _) = setup()
        model.draft = "\n  \n\(MentionText.mark) fix it, not @lookout typed"
        model.pointers = [.project("/code/lookout")]
        #expect(model.plainDraft(s) == "@lookout fix it, not @lookout typed")
        #expect(model.context(s).pills == [0..<8], "only the pill, where it stands in what is sent")
    }

    @Test func aSessionsPickIsPinnedAndSentWithTheMessage() async {
        let (s, model, _) = setup()
        model.live.preview(.init(target: "session:local_b", title: "Update the docs", detail: "session “Update the docs” in docs",
                                 text: "x", mark: nil))
        model.draft = "x"
        model.pinPrediction(store: s)
        #expect(model.live.pinned == "session:local_b" && model.live.pinnedTitle == "Update the docs")
        #expect(model.context(s).target == "session:local_b" && model.context(s).predicted == "session:local_b")
        #expect(model.removeLastChip() && model.live.pinned == nil, "Backspace at the start takes the pin off")
    }

    @Test func aPinnedDraftEditedSinceKeepsItsTarget() {
        let (s, model, _) = setup()
        let read = RouterDispatcher.Classification(ranked: [.init(target: "session:local_b", p: 0.9)], sure: true, assisted: true)
        model.live.preview(.init(target: "session:local_b", title: "Update the docs", detail: "session “Update the docs” in docs",
                                 text: "fix the typo", mark: nil, found: read))
        model.draft = "fix the typo"
        model.pinPrediction(store: s)
        model.draft = "fix the typo, then rewrite the whole docs site in another framework"
        #expect(model.context(s).target == "session:local_b" && model.context(s).predicted == "session:local_b")
        // The pin fixes where it goes: nothing of what Jev read is carried.
        #expect(model.context(s).jev == nil)
    }

    @Test func aPickForOtherWordsGoesAtOnceAndALateAnswerForThemIsNeverShownOrPinned() async {
        let (s, model, _) = setup()
        let sure = s.routerDispatcher.asker!
        var gate: CheckedContinuation<Void, Never>?
        var held = false
        s.routerDispatcher.asker = { questions, state in
            guard state["message"]?.contains("docs") == true else { return try await sure(questions, state) }
            held = true
            await withCheckedContinuation { gate = $0 }
            guard case .structuredChoice(let keys, _, _) = questions["route"] else { return [:] }
            let docs = keys.first { $0 == "Update the docs" } ?? keys[0]
            var p = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0.0) })
            p[docs] = 1
            return ["route": .choice(.init(choice: docs, confidence: 1, probabilities: p))]
        }
        let a = "use sqlite for the database"
        type(a, model, s)
        await waitUntil { model.live.prediction != nil }
        type("update the docs page for sqlite", model, s)
        #expect(model.live.prediction == nil, "the chip goes as soon as the words change")
        await waitUntil { held }
        type(a, model, s)
        await waitUntil { model.live.prediction != nil }
        gate?.resume()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.live.prediction?.target == "answer:local_a#w1", "the late answer for other words isn't shown")

        // Words changed under the chip (before the composer passed them on): a click pins nothing.
        model.draft = "use sqlite for the database, but not in tests"
        model.pinPrediction(store: s)
        #expect(model.replyTo == nil && model.live.pinned == nil && model.live.prediction == nil)
    }

    @Test func nothingIsAskedOnceTheComposerIsGoneAndItsDraftIsAskedAboutWhenBack() async {
        let (s, model, calls) = setup()
        model.live.delay = .milliseconds(100)
        type("use sqlite for the database", model, s)
        model.live.suspend()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(calls() == 0 && model.live.prediction == nil, "the draft wasn't sent to Jev")
        model.predictTarget(store: s)
        await waitUntil { model.live.prediction != nil }
        #expect(calls() == 1 && model.live.prediction?.target == "answer:local_a#w1")
        // Gone and back with the same words: the pick is still theirs, and nothing is asked again.
        model.live.suspend()
        model.predictTarget(store: s)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(calls() == 1 && model.live.prediction?.target == "answer:local_a#w1")
        // Back with other words: they are asked about.
        model.live.suspend()
        type("use postgres for the database instead", model, s)
        #expect(model.live.prediction == nil)
        await waitUntil { calls() == 2 }
    }

    @Test func aPickWhoseCardIsAddressedGoesWithItsMark() async {
        let (s, model, _) = setup()
        type("use sqlite for the database", model, s)
        await waitUntil { model.live.prediction != nil }
        let before = RouterModel.targets(s)
        s.setCardAddressed("local_a#w1", true)
        #expect(RouterModel.targets(s) != before, "the composer watches what can be routed to")
        model.revalidateTarget(store: s)
        #expect(model.live.prediction == nil)
    }

    @Test func aPickStillGoodMarksWhereItsSessionNowIs() {
        let (s, model, _) = setup()
        model.live.preview(.init(target: "session:local_a", title: "Fix the login bug", detail: "", text: "x",
                                 mark: RouterModel.workingID("local_a")))
        // No longer working: its open card is where the page shows it.
        model.revalidateTarget(store: s)
        #expect(model.live.prediction?.mark == "local_a#w1")
    }

    @Test func aKeptPickTakesItsSessionsNewTitleWithoutAskingJevAgain() {
        let (s, model, calls) = setup()
        model.live.preview(.init(target: "session:local_b", title: "Update the docs", detail: "", text: "x", mark: nil))
        s.claudeSessions["local_b"]?.title = "Rewrite the docs"
        model.revalidateTarget(store: s)
        #expect(model.live.prediction?.title == "Rewrite the docs" && calls() == 0)
        // The composer's watch sees a rename of the pick's target as a change, though no target came or went.
        let before = RouterModel.targets(s, predicted: "session:local_b")
        s.claudeSessions["local_b"]?.title = "Rewrite the docs again"
        #expect(RouterModel.targets(s, predicted: "session:local_b") != before)
    }

    @Test func aPinnedSessionThatIsGoneIsUnpinned() {
        let (s, model, _) = setup()
        model.live.preview(.init(target: "session:local_b", title: "Update the docs", detail: "", text: "x", mark: nil))
        model.draft = "x"
        model.pinPrediction(store: s)
        #expect(model.live.pinned == "session:local_b")
        model.revalidateTarget(store: s)
        #expect(model.live.pinned == "session:local_b", "still there: kept")
        s.claudeSessions["local_b"] = nil
        model.revalidateTarget(store: s)
        #expect(model.live.pinned == nil && model.live.pinnedTitle == nil && model.context(s).target == nil)
    }
}
