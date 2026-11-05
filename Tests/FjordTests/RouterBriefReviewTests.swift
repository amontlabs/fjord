import AppKit
import Carbon
import Foundation
import Testing
@testable import Fjord

/// The briefs' review fixes: the keys, answers one at a time and recorded on proof, one reply target, stranded entries,
/// the purpose, the Router's switch, banners, the away gate, the lead, the read mark and the migration.
@MainActor @Suite struct RouterBriefReviewTests {
    private func demo() -> Store {
        let store = Store()
        Demo.populate(store, .router)
        store.interceptOpen = { _ in }
        return store
    }

    private func key(_ code: Int, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    private func settings(_ store: Store) -> BriefTarget {
        store.routerBriefs.page().entries.first { $0.thread == "th_settings" }!.target
    }

    // MARK: Keys (P1-1)

    /// Typing "approve it" in the composer after clicking an entry: every letter is yours, nothing is archived, picked or
    /// opened, and the reply stays on that entry.
    @Test func lettersAndDigitsInTheComposerAreYourWords() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model)
        let briefs = store.routerBriefs
        let t = settings(store)
        briefs.focus(t)
        model.composerFocused = true
        let editor = NSTextView()
        for (code, c) in [(kVK_ANSI_A, "a"), (kVK_ANSI_O, "o"), (kVK_ANSI_R, "r"), (kVK_ANSI_1, "&"), (kVK_ANSI_2, "é")] {
            #expect(!keys.key(key(code, c), responder: editor), "\(c) types")
        }
        #expect(briefs.focused == t && briefs.archived.isEmpty && briefs.read.isEmpty && briefs.picked.isEmpty)
    }

    /// ↓ in the empty composer puts the keyboard on the brief: there, A archives, and the reply target is dropped, never
    /// moved on to the next entry.
    @Test func onTheBriefAKeyActNeverMovesTheReplyTarget() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model)
        let briefs = store.routerBriefs
        model.composerFocused = true
        #expect(keys.key(key(kVK_DownArrow), responder: NSTextView()))
        #expect(!model.composerFocused)
        let first = try! #require(briefs.focused)
        #expect(keys.key(key(kVK_ANSI_A, "a"), responder: nil))
        #expect(briefs.archived.contains(first.key) && briefs.focused == nil)
    }

    // MARK: Answers (P2-1, P2-2, P3 drawer)

    @Test func oneAnswerAtATimeAndItsLineOnlyOnceDelivered() async {
        let store = demo()
        let (updates, feed) = AsyncStream<CourierUpdate>.makeStream()
        store.routerCourier.attach(RouterCourierSource(submit: { _ in 7 }, updates: updates))
        let briefs = store.routerBriefs
        let t = settings(store)
        briefs.pick(t, 1, store: store)
        #expect(briefs.confirm(t, store: store))
        #expect(briefs.answering.contains(t))
        // A second pick and Return while the first is under way: nothing.
        briefs.pick(t, 2, store: store)
        #expect(briefs.picked[t] == nil && !briefs.confirm(t, store: store))
        #expect(!briefs.answer(t, option: 2, store: store))
        #expect(briefs.answers.isEmpty, "no line before it is delivered")
        for _ in 0..<50 where briefs.sending[t] == nil { await Task.yield() }
        feed.yield(CourierUpdate(intentID: 7, state: .delivered, cause: nil, before: nil, at: Date()))
        await briefs.settled()
        #expect(briefs.answers.map(\.words) == ["A sidebar with sections"] && briefs.answering.isEmpty)
    }

    @Test func anAnswerByOptionKeepsItsOptionWhateverWasPicked() async {
        let store = demo()
        store.routerCourier.attach(RouterCourierSource(submit: { _ in 0 }, updates: AsyncStream { _ in }))
        let briefs = store.routerBriefs
        let t = settings(store)
        briefs.pick(t, 2, store: store)
        // Picking 2 again would take it back; answering 2 doesn't.
        #expect(briefs.answer(t, option: 2, store: store))
        await briefs.settled()
        #expect(briefs.trouble[t] != nil && briefs.answers.isEmpty, "not handed over: no line")
    }

    // MARK: One reply target (P3)

    @Test func theReplyTargetIsTheBriefsAndTheContextCarriesIt() {
        let store = demo()
        let model = RouterModel()
        let t = settings(store)
        store.routerBriefs.focus(t)
        #expect(model.context(store).replyTo == t)
        #expect(model.removeLastChip(store: store) && store.routerBriefs.focused == nil)
        #expect(!model.removeLastChip(store: store))
    }

    // MARK: Dispatcher (P2-3)

    @Test func aReplyThatCantBeReachedIsRefusedNotDecided() {
        let store = Store()
        store.persists = false
        let local = RouterDispatcher.plan(text: "yes", context: RouterContext(replyTo: BriefTarget(project: "local:x", thread: "gone")), store: store)
        let cloud = RouterDispatcher.plan(text: "yes", context: RouterContext(replyTo: BriefTarget(project: "chan_x", thread: "th_gone")), store: store)
        for plan in [local, cloud] {
            guard case .unreachable = plan else { Issue.record("\(plan)"); continue }
        }
    }

    // MARK: Stranded (P2-4)

    @Test func aStrandedEntryLeavesOnceItsThreadWorksAgain() {
        let stranded = [BriefEntry(project: "p", thread: "t1", kind: .stranded, state: .needsYou, since: 1, source: .local)]
        #expect(RouterBriefEngine.entries(model: stranded, board: BriefBoard(threads: [briefThread("t1", .working)])).isEmpty)
        #expect(RouterBriefEngine.entries(model: stranded, board: BriefBoard(threads: [briefThread("t1", .done)])).count == 1)
        var doc = BriefDoc(project: "p")
        doc.threads = [briefThread("t1", .working)]
        let answer = try! BriefDoc.parse(#"{"now":[],"needs_you":[{"thread":"t1","kind":"stranded","question":"","options":[]}],"decisions":[],"loose_ends":[]}"#)
        #expect(doc.checked(answer, known: [], cards: [:], at: 1).needsYou.isEmpty)
    }

    // MARK: Purpose (P2-5)

    @Test func aSettingsReadWritesThePurposeAndACallUnderWayKeepsIt() async {
        let src = FakeBriefSource()
        let (release, go) = AsyncStream<Void>.makeStream()
        let runner: RouterBriefEngine.Model = { _, context, _ in
            if context.contains("Goal:") { return #"{"purpose":"Ship the engine"}"# }
            for await _ in release { break }
            return #"{"now":["Building."],"needs_you":[],"decisions":[],"loose_ends":[]}"#
        }
        let engine = RouterBriefEngine(source: src, store: MemoryBriefStore(), model: runner, clock: { 100 })
        src.post("p", id: "m1", kind: .message, text: "working")
        engine.itemsChanged("p")
        for _ in 0..<50 { await Task.yield() }
        src.boards["p", default: BriefBoard()].goal = "Goal: ship the engine"
        engine.boardChanged("p")
        for _ in 0..<200 where engine.docs["p"]?.purpose == nil { await Task.yield() }
        #expect(engine.docs["p"]?.purpose == "Ship the engine")
        go.yield(())
        await engine.idle()
        #expect(engine.docs["p"]?.now == ["Building."] && engine.docs["p"]?.purpose == "Ship the engine")
    }

    // MARK: The Router's switch (P2-6)

    @Test func offWithTheRouterNoModelCallRuns() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        let engine = makeEngine(src, model)
        engine.stop()
        src.post("p", id: "m1", kind: .message, text: "hello")
        engine.itemsChanged("p"); await engine.idle()
        #expect(model.contexts.isEmpty)
        engine.start(); await engine.idle()
        #expect(model.contexts.count == 1)
    }

    // MARK: Banners and the away gate (P2-7)

    @Test func eachNewEntryIsAnnouncedOnceAndItsBannerOpensIt() {
        let store = demo()
        store.router.enabled = true
        store.agents.enabled = true
        store.settings.notifications = true
        var posted: [String] = []
        store.notifier.onPost = { posted.append($0.identifier) }
        store.routerBriefs.announce(store: store)
        #expect(!posted.isEmpty && posted.allSatisfy { $0.hasPrefix(RouterBriefs.notificationPrefix) })
        let first = posted.count
        store.routerBriefs.announce(store: store)
        #expect(posted.count == first, "once per entry")
        var opened: BriefTarget?
        store.onOpenBrief = { opened = $0 }
        store.openNotification(id: RouterBriefs.notificationPrefix + settings(store).key, url: nil)
        #expect(opened == settings(store))
    }

    @Test func awayOnlyWhatCantWaitComesAndTheRestIsSummedUpOnce() {
        let gate = AwayGate()
        #expect(gate.admitInbox(.normal) && gate.back() == 0)
        gate.idleSeconds = { AwayGate.awayAfter }
        #expect(!gate.admitInbox(.normal) && !gate.admitInbox(nil) && gate.admitInbox(.high) && gate.admitInbox(.urgent))
        #expect(gate.back() == 2 && gate.back() == 0)
        gate.idleSeconds = { 0 }
        gate.locked = true
        #expect(!gate.admitInbox(.low))
    }

    // MARK: Lead, read mark, count, migration (P3)

    @Test func theLeadIsKeptAcrossLaunches() async throws {
        let dir = TempDir()
        let db = try SQLiteBriefStore(path: dir.path("briefs.db").path)
        #expect(db.lead() == nil)
        db.setLead(GeneralBrief(lead: ["One needs you."], at: 5))
        let again = try SQLiteBriefStore(path: dir.path("briefs.db").path)
        #expect(again.lead() == GeneralBrief(lead: ["One needs you."], at: 5))
        let engine = RouterBriefEngine(source: FakeBriefSource(), store: again, model: FakeBriefModel().runner)
        engine.start(); await engine.idle()
        #expect(engine.general.lead == ["One needs you."])
    }

    @Test func aReadMarkHoldsWhateverTheThreadIsTouched() {
        func key(touched: Double, statusAt: Double?) -> String {
            let f = CourierBriefFacts(project: "chan_p", threads: [.init(id: "t1", title: "T", state: "needs_you", touched: touched,
                                                                          status: "needs you", statusAt: statusAt)])
            return BriefPage.entryKey(CourierBriefSource.board(f).entries[0])
        }
        #expect(key(touched: 5, statusAt: nil) == key(touched: 9, statusAt: nil))
        #expect(key(touched: 5, statusAt: 3) == key(touched: 9, statusAt: 3) && key(touched: 5, statusAt: 3) != key(touched: 5, statusAt: 4))
    }

    @Test func theCountFollowsTheMarks() {
        let store = demo()
        let briefs = store.routerBriefs
        let before = briefs.untoldNeedsYou
        #expect(before == briefs.page().needsYou && before > 0)
        briefs.markRead(settings(store), store: store)
        #expect(briefs.untoldNeedsYou == before - 1)
    }

    @Test func settingsGoalAndInstructionsAreThePurposesSource() {
        let read = JSON.object(JSONObject([("goal", .string("Ship")), ("instructions", .string("Keep CI green"))]))
        #expect(CourierHost.goal(read) == "Goal: Ship\nInstructions: Keep CI green")
        #expect(CourierHost.goal(nil) == nil)
        let f = CourierBriefFacts(project: "chan_p", goal: "Goal: Ship")
        #expect(CourierBriefSource.board(f).goal == "Goal: Ship")
    }

    @Test func anOldAnsweredCardKeepsItsTitle() throws {
        let raw = #"{"id":"00000000-0000-0000-0000-000000000003","at":1,"trigger":{"system":{}},"decision":{},"outcome":{"done":{}},"links":{},"done":[{"answered":{"card":"Fix the login bug"}}]}"#
        let d = try JSONDecoder().decode(RouterDecision.self, from: Data(raw.utf8))
        #expect(d.done == [.answered(thread: "Fix the login bug")] && d.note == nil)
    }
}
