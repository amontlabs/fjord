import Foundation
import Testing
@testable import Fjord

/// The decision log: what each writer records, how a revert settles it, what is kept, the context it renders and the history
/// built on it.
@MainActor
@Suite(.serialized) struct RouterDecisions {
    private func store() -> Store {
        let s = InboxFixture.store([])
        s.router.enabled = true
        s.agents.enabled = true
        s.claudeSessions = [
            "local_a": ClaudeSession(id: "local_a", title: "Fix the login bug", folder: "/code/lookout", lastActivity: Date(), running: true),
        ]
        return s
    }

    // MARK: Writers

    @Test func aChangeJoinsItsRunOrStandsAlone() async throws {
        let s = store()
        let alone = FjordChange(title: "Changed snooze", patch: .setting(key: "k", before: .on(false), after: .on(true)))
        s.logChange(alone)
        #expect(s.router.decisions.count == 1 && s.router.decisions[0].trigger == .system)
        #expect(s.router.decisions[0].done == [.changed(alone.id)] && s.router.decisions[0].links.changes == [alone.id])

        let run = s.logDecision(RouterDecision(trigger: .you("snooze")))
        let joined = FjordChange(title: "Changed other", patch: .setting(key: "k", before: .on(false), after: .on(true)))
        s.logChange(joined, into: run)
        #expect(s.router.decisions.count == 2)
        #expect(s.router.decisions[1].done == [.changed(joined.id)])
    }

    @Test func revertingAChangeSettlesItsDecision() async throws {
        let s = store()
        s.categories = [InboxStore.ci]
        let t = RouterTools(store: s)
        t.beginTurn("make one")
        let out = await t.call("create_category", ["category": ["name": "Mine", "symbol": "eye", "color": "amber", "rules": [[String: Any]]()]])
        #expect(out?.isError == false)
        let change = try #require(s.router.changes.last)
        #expect(s.router.decisions.count == 1 && s.router.decisions[0].links.changes == [change.id])
        #expect(s.router.decisions[0].outcome == .done)
        s.revertFjordChange(change.id)
        #expect(s.router.decisions[0].outcome == .reverted)
        #expect(s.router.decisions[0].summary == "reverted")
    }

    @Test func answersFromThePageAreLogged() {
        let s = store()
        s.router.cards = [RouterCard(id: "local_a#w1", sessionID: "local_a", kind: .question, title: "Fix the login bug",
                                     folder: nil, text: "Which?", createdAt: Date())]
        s.logCardAction("Archived", card: "local_a#w1")
        let d = s.router.decisions[0]
        #expect(d.trigger == .you("Archived") && d.outcome == .done)
        #expect(d.done == [.answered(card: "Fix the login bug")] && d.links.cards == ["local_a#w1"] && d.links.sessions == ["local_a"])
    }

    // MARK: Persistence


    @Test func theOldestAreDroppedPastTheCap() {
        var state = RouterState()
        for i in 0..<(RouterDecision.maxKept + 5) { state.log(RouterDecision(trigger: .you("m\(i)"))) }
        #expect(state.decisions.count == RouterDecision.maxKept)
        #expect(state.decisions.first?.trigger == .you("m5"))
    }

    @Test func anEntryWhoseAskBackCardIsStillUpOutlivesTheCap() {
        var state = RouterState()
        let asking = RouterDecision(trigger: .you("which one?"))
        state.log(asking, inUse: [asking.id])
        for i in 0..<(RouterDecision.maxKept + 5) { state.log(RouterDecision(trigger: .you("m\(i)")), inUse: [asking.id]) }
        #expect(state.decisions.count == RouterDecision.maxKept)
        #expect(state.decisions.first?.id == asking.id)
    }

    @Test func theEntryOfAChangeWaitingForYourApplyOutlivesTheCap() {
        var state = RouterState()
        var change = FjordChange(title: "waiting", patch: .setting(key: "snooze", before: .date(nil), after: .date(nil)))
        change.pending = "asks first"
        state.changes = [change]
        state.log(RouterDecision(trigger: .you("change it"), done: [.changed(change.id)], links: .init(changes: [change.id])))
        for i in 0..<(RouterDecision.maxKept + 5) { state.log(RouterDecision(trigger: .you("m\(i)"))) }
        #expect(state.decisions.count == RouterDecision.maxKept)
        #expect(state.decisions.first?.trigger == .you("change it") && state.decisions[1].trigger == .you("m6"))
        // Applied (or discarded), it goes with the rest.
        state.changes[0].pending = nil
        state.log(RouterDecision(trigger: .you("more")))
        #expect(state.decisions.first?.trigger == .you("m6"))
    }

    // MARK: Context

    @Test func recentDecisionsAreOneLineEachAndCorrectionsAreSaid() {
        let s = store()
        let now = Date()
        var a = RouterDecision(at: now.addingTimeInterval(-300), trigger: .you("tell docs to ship"), decision: .init(target: "Docs"))
        a.add(.sent(to: "Docs", text: "ship", original: nil))
        a.outcome = .done
        var b = RouterDecision(at: now.addingTimeInterval(-30), trigger: .you("fix it"), outcome: .corrected(from: "Docs", to: "Lookout dev"))
        b.add(.sent(to: "Lookout dev", text: "fix it", original: nil))
        var c = RouterDecision(at: now.addingTimeInterval(-10), trigger: .system, outcome: .reverted)
        c.add(.changed(UUID()))
        for d in [a, b, c] { s.logDecision(d) }
        let lines = s.recentDecisions(10, now: now).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "5m ago · the user: “tell docs to ship” → target Docs → sent to Docs: ship")
        #expect(lines[1].hasSuffix("(the user corrected this: not Docs, but Lookout dev)") && lines[1].hasPrefix("just now"))
        #expect(lines[2].contains("the user reverted this"))
        #expect(s.recentDecisions(2, now: now).split(separator: "\n").count == 2)
        #expect(Store().recentDecisions().isEmpty)
    }

    @Test func aDoneTurnWaitsInWorkingWhileItsSessionStillHasWorkRunning() {
        let now = Date()
        let done = RouterCard(id: "s#t1", sessionID: "s", kind: .done, title: "T", folder: nil, text: "x", createdAt: now)
        let question = RouterCard(id: "s#w1", sessionID: "s", kind: .question, title: "T", folder: nil, text: "x", createdAt: now)
        var row = AgentRow(session: ClaudeSession(id: "s", title: "T", lastActivity: now), entry: AgentEntry(id: "s"), label: "T")
        row.tasks = [ClaudeTask(id: "a1", kind: .agent, title: "Explore", since: now)]
        let busy = RouterPage.make(cards: [done, question], working: [row])
        #expect(busy.needs.map(\.id) == ["s#w1"] && busy.notes.isEmpty)
        row.tasks = []
        let idle = RouterPage.make(cards: [done, question], working: [row])
        #expect(idle.needs.map(\.id) == ["s#w1"] && idle.notes.map(\.id) == ["s#t1"])
    }

    // MARK: History

    @Test func theHistoryInterleavesDecisionsAndAddressedCardsByTime() {
        let now = Date()
        var card = RouterCard(id: "s#t1", sessionID: "s", kind: .done, title: "T", folder: nil, text: "x", createdAt: now.addingTimeInterval(-500))
        card.addressedAt = now.addingTimeInterval(-100)
        card.addressedBy = .you
        let open = RouterCard(id: "s#t2", sessionID: "s", kind: .question, title: "Q", folder: nil, text: "x", createdAt: now)
        let late = RouterDecision(at: now.addingTimeInterval(-10), trigger: .you("late"))
        let early = RouterDecision(at: now.addingTimeInterval(-300), trigger: .you("early"))
        let page = RouterPage.make(cards: [open, card], working: [], decisions: [late, early])
        #expect(page.history.map(\.id) == [early.id.uuidString, "s#t1", late.id.uuidString])
        #expect(page.needs.map(\.id) == ["s#t2"])
    }

    @Test func theStoresPageShowsTheLog() {
        let s = store()
        let d = s.logDecision(RouterDecision(trigger: .you("hi")))
        let ids = s.routerPage.history.map(\.id)
        #expect(ids == [d.uuidString])
    }

    @Test func theLogSurvivesEncodingAndOldStateHasNone() throws {
        var state = RouterState()
        var d = RouterDecision(trigger: .action(category: "C", thing: "t", actionID: "a", runID: "r"),
                               decision: .init(target: "Docs", intent: "reply", label: "x", confidence: 0.8), outcome: .corrected(from: "A", to: "B"))
        d.add(.sent(to: "p", text: "hi", original: nil), session: "s")
        d.add(.asked(["a", "b"]))
        state.log(d)
        let back = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))
        #expect(back.decisions == [d])
        let old = try JSONDecoder().decode(RouterState.self, from: Data(#"{"enabled":true,"cards":[],"chat":[]}"#.utf8))
        #expect(old.decisions.isEmpty && old.enabled)
    }
}
