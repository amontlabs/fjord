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

    /// The Settings question, held by T3 as a live request, with the commands that would go to T3 collected (and, if asked, held).
    private func asked(_ store: Store, hold: Bool = false) -> (sent: Sent, release: () -> Void) {
        store.requests["th_settings"] = ThreadRequest(id: "r1", threadID: "th_settings", body: .question([
            T3Question(demo: "", "Which layout?", options: [("A sidebar with sections", "sidebar"), ("One scrolling page", "page"),
                                                              ("Tabs across the top", "tabs")])]))
        let sent = Sent()
        var held: CheckedContinuation<Void, Never>?
        store.requestSender = { command, _ in
            sent.commands.append(command)
            if hold { await withCheckedContinuation { held = $0 } }
        }
        return (sent, { held?.resume(); held = nil })
    }

    @MainActor final class Sent { var commands: [T3Command] = [] }

    @Test func oneAnswerAtATimeAndItsLineOnlyOnceDelivered() async {
        let store = demo()
        let (sent, release) = asked(store, hold: true)
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
        for _ in 0..<50 where sent.commands.isEmpty { await Task.yield() }
        #expect(sent.commands.count == 1)
        release()
        await briefs.settled()
        #expect(briefs.answers.map(\.words) == ["A sidebar with sections"] && briefs.answering.isEmpty)
    }

    @Test func anAnswerByOptionKeepsItsOptionWhateverWasPicked() async {
        let store = demo()
        let (sent, _) = asked(store)
        let briefs = store.routerBriefs
        let t = settings(store)
        briefs.pick(t, 3, store: store)
        // Answering 2 sends 2, whatever was picked, and doesn't toggle.
        #expect(briefs.answer(t, option: 2, store: store))
        await briefs.settled()
        #expect(sent.commands.count == 1 && briefs.answers.map(\.words) == ["One scrolling page"] && briefs.picked[t] == nil)
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
        let stranded = [BriefEntry(project: "p", thread: "t1", kind: .stranded, state: .needsYou, since: 1)]
        #expect(RouterBriefEngine.entries(model: stranded, board: BriefBoard(threads: [briefThread("t1", .working)])).isEmpty)
        #expect(RouterBriefEngine.entries(model: stranded, board: BriefBoard(threads: [briefThread("t1", .done)])).count == 1)
        var doc = BriefDoc(project: "p")
        doc.threads = [briefThread("t1", .working)]
        let answer = try! BriefDoc.parse(#"{"now":[],"needs_you":[{"thread":"t1","kind":"stranded","question":"","options":[]}],"decisions":[],"loose_ends":[]}"#)
        #expect(doc.checked(answer, known: [], cards: [:], at: 1).needsYou.isEmpty)
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
        let store = Store()
        store.persists = false
        store.router.enabled = true
        store.agents.enabled = true
        store.settings.notifications = true
        let now = Date()
        var asks = AgentThread(id: "t-ask", title: "Pick a layout", lastActivity: now, unseen: true)
        asks.status = .running
        asks.pendingRequest = T3PendingRequest(json: T3JSON.parse(#"{"id":"r1","kind":"user_input","blocking":true}"#))
        store.threads = ["t-ask": asks]
        store.routerBriefs.clock = { now }
        var posted: [String] = []
        store.notifier.onPost = { posted.append($0.identifier) }
        store.routerBriefs.announce(store: store)
        #expect(posted == [RouterBriefs.notificationPrefix + BriefTarget(project: asks.projectID, thread: "t-ask").key])
        store.routerBriefs.announce(store: store)
        #expect(posted.count == 1, "once per request")
        var opened: BriefTarget?
        store.onOpenBrief = { opened = $0 }
        store.openNotification(id: posted[0], url: nil)
        #expect(opened?.thread == "t-ask")
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
        db.setLead(GeneralBrief(forYou: "One needs you.", worthALook: "A look.", at: 5))
        let again = try SQLiteBriefStore(path: dir.path("briefs.db").path)
        #expect(again.lead() == GeneralBrief(forYou: "One needs you.", worthALook: "A look.", at: 5))
        let engine = RouterBriefEngine(source: FakeBriefSource(), store: again, model: FakeBriefModel().runner)
        engine.start(); await engine.idle()
        #expect(engine.general.forYou == "One needs you.")
    }

    @Test func aReadMarkHoldsToTheRequestNotToTheThreadsTouches() {
        func key(request: String?, since: Double) -> String {
            var t = AgentThread(id: "t1", title: "T", lastActivity: Date(timeIntervalSince1970: since), running: true)
            t.pendingRequest = request.flatMap { T3PendingRequest(json: T3JSON.parse(#"{"id":"\#($0)","kind":"user_input","blocking":true}"#)) }
            return BriefPage.entryKey(T3BriefSource.entry(t, project: "p", request: nil, since: since, asOf: nil))
        }
        #expect(key(request: "r1", since: 5) == key(request: "r1", since: 9))
        #expect(key(request: "r1", since: 5) != key(request: "r2", since: 5))
    }

    @Test func theCountFollowsTheMarks() {
        let store = demo()
        let briefs = store.routerBriefs
        let before = briefs.untoldNeedsYou
        #expect(before == briefs.page().needsYou && before > 0)
        briefs.markRead(settings(store), store: store)
        #expect(briefs.untoldNeedsYou == before - 1)
    }

    @Test func anOldAnsweredCardKeepsItsTitle() throws {
        let raw = #"{"id":"00000000-0000-0000-0000-000000000003","at":1,"trigger":{"system":{}},"decision":{},"outcome":{"done":{}},"links":{},"done":[{"answered":{"card":"Fix the login bug"}}]}"#
        let d = try JSONDecoder().decode(RouterDecision.self, from: Data(raw.utf8))
        #expect(d.done == [.answered(thread: "Fix the login bug")] && d.note == nil)
    }
}
