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
        s.threads = [
            "local_a": AgentThread(id: "local_a", title: "Fix the login bug", folder: "/code/lookout", lastActivity: Date(), running: true),
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

    @Test func answersFromTheBriefAreLogged() {
        let s = store()
        var doc = BriefDoc(project: "local:app")
        doc.threads = [BriefThread(id: "local_a", title: "Fix the login bug", status: .needsYou, age: 0, source: .local)]
        s.routerBriefs.demoDocs = ["local:app": doc]
        s.logEntryAction("Answered the form", target: BriefTarget(project: "local:app", thread: "local_a"))
        let d = s.router.decisions[0]
        #expect(d.trigger == .you("Answered the form") && d.outcome == .done)
        #expect(d.done == [.answered(thread: "Fix the login bug")] && d.links.threads == ["local:app/local_a"])
    }

    // MARK: Persistence

    @Test func theOldestAreDroppedPastTheCap() {
        var state = RouterSaved()
        for i in 0..<(RouterDecision.maxKept + 5) { state.log(RouterDecision(trigger: .you("m\(i)"))) }
        #expect(state.decisions.count == RouterDecision.maxKept)
        #expect(state.decisions.first?.trigger == .you("m5"))
    }

    @Test func anEntryWhoseAskBackCardIsStillUpOutlivesTheCap() {
        var state = RouterSaved()
        let asking = RouterDecision(trigger: .you("which one?"))
        state.log(asking, inUse: [asking.id])
        for i in 0..<(RouterDecision.maxKept + 5) { state.log(RouterDecision(trigger: .you("m\(i)")), inUse: [asking.id]) }
        #expect(state.decisions.count == RouterDecision.maxKept)
        #expect(state.decisions.first?.id == asking.id)
    }

    @Test func theEntryOfAChangeWaitingForYourApplyOutlivesTheCap() {
        var state = RouterSaved()
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

    // MARK: History

    @Test func theLogSurvivesEncodingAndOldStateHasNone() throws {
        var state = RouterSaved()
        var d = RouterDecision(trigger: .action(category: "C", thing: "t", actionID: "a", runID: "r"),
                               decision: .init(target: "Docs", intent: "reply", label: "x", confidence: 0.8), outcome: .corrected(from: "A", to: "B"))
        d.add(.sent(to: "p", text: "hi", original: nil), session: "s")
        d.add(.asked(["a", "b"]))
        state.log(d)
        let back = try JSONDecoder().decode(RouterSaved.self, from: JSONEncoder().encode(state))
        #expect(back.decisions == [d])
        let old = try JSONDecoder().decode(RouterSaved.self, from: Data(#"{"enabled":true,"cards":[],"chat":[]}"#.utf8))
        #expect(old.decisions.isEmpty && old.enabled)
    }

    /// Synthetic entries in the shapes older files kept: a divided message (`parts`, nothing of its own) and a removed done case.
    @Test func entriesInOlderShapesStillDecode() throws {
        let part = { (id: String, place: String, session: String) in
            #"{"id":"\#(id)","place":"\#(place)","text":"words","decision":{"target":"\#(place)","intent":"i","confirmed":true},"done":[{"sent":{"to":"\#(place)","text":"words"}}],"outcome":{"done":{}},"links":{"changes":[],"cards":[],"sessions":["\#(session)"]},"reply":"\#(place == "Alpha" ? "the answer" : "another")"\#(place == "Beta" ? #","note":"a note""# : "")}"#
        }
        let split = #"{"id":"00000000-0000-0000-0000-000000000001","at":0,"trigger":{"you":{"_0":"words"}},"parts":["#
            + part("00000000-0000-0000-0000-000000000011", "Alpha", "s1") + "," + part("00000000-0000-0000-0000-000000000012", "Beta", "s2") + "]}"
        let started = #"{"id":"00000000-0000-0000-0000-000000000002","at":1,"trigger":{"system":{}},"decision":{},"outcome":{"done":{}},"links":{},"done":[{"started":{"project":"Alpha","session":"x"}},{"vanished":{"a":1}},{"failed":{"_0":"why"}}]}"#
        let data = Data(#"{"enabled":true,"cards":[],"decisions":["#.utf8) + Data("\(split),\(started)]}".utf8)
        for one in [split, started] {
            do { _ = try JSONDecoder().decode(RouterDecision.self, from: Data(one.utf8)) } catch { Issue.record("\(error)") }
        }
        let state = try JSONDecoder().decode(RouterSaved.self, from: data)
        #expect(state.decisions.count == 2)
        let a = state.decisions[0]
        #expect(a.decision.target == "Alpha" && a.outcome == .done && a.done.count == 2 && a.links.sessions == ["s1", "s2"])
        #expect(a.note?.contains("Alpha, Beta") == true)
        #expect(a.reply == "Alpha: the answer\nBeta: another" && a.note?.contains("Beta: a note") == true)
        let b = state.decisions[1]
        #expect(b.done.count == 2 && b.done.first?.sendsWords == true && b.note?.contains("vanished") == true)
    }
}
