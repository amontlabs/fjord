import Foundation
import Testing
@testable import Fjord

/// What a session was told, as the Router reads it (`Store.toldAll`, `Store.lastTold`, Jev's "the user last told it"): a
/// divided message gives each session its own part's words, never the whole message.
@MainActor
@Suite(.serialized) struct RouterTold {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    private func store() -> Store {
        let s = InboxFixture.store([])
        s.router.enabled = true
        s.agents.enabled = true
        s.claudeSessions = [
            "ci": ClaudeSession(id: "ci", title: "CI watcher", folder: "/code/lookout", lastActivity: t0, running: true),
            "docs": ClaudeSession(id: "docs", title: "Docs writer", folder: "/code/lookout", lastActivity: t0, running: true),
        ]
        return s
    }

    /// "tell CI to rerun and docs to add the page", sent to both, then a one-place message to CI.
    private func sent(in s: Store) {
        var entry = RouterDecision(at: t0, trigger: .you("tell CI to rerun, and docs to add the page"))
        let ids = entry.divide(into: [.init(text: "rerun", place: "session:ci"), .init(text: "add the page", place: "session:docs")])
        s.router.decisions.append(entry)
        s.updateDecision(ids[0]) { $0.add(.sent(to: "CI watcher", text: "rerun", original: nil), session: "ci"); $0.outcome = .done }
        s.updateDecision(ids[1]) { $0.add(.sent(to: "Docs writer", text: "add the page", original: nil), session: "docs"); $0.outcome = .done }
    }

    @Test func eachSessionIsToldItsOwnPartsWords() {
        let s = store()
        sent(in: s)
        #expect(s.toldAll() == ["ci": ["rerun"], "docs": ["add the page"]])
        #expect(s.lastTold()["ci"]?.text == "rerun" && s.lastTold()["docs"]?.text == "add the page" && s.lastTold()["ci"]?.at == t0)
    }

    @Test func aPartThatSentNothingToldNothing() {
        let s = store()
        sent(in: s)
        s.router.decisions[0].parts[1].done = [.failed("no")]
        #expect(s.toldAll() == ["ci": ["rerun"]] && s.lastTold()["docs"] == nil)
    }

    @Test func aOnePlaceMessageIsReadAsBefore() {
        let s = store()
        sent(in: s)
        var entry = RouterDecision(at: t0.addingTimeInterval(60), trigger: .you("and again"))
        entry.add(.sent(to: "CI watcher", text: "and again", original: nil), session: "ci")
        s.router.decisions.append(entry)
        var skipped = RouterDecision(at: t0.addingTimeInterval(120), trigger: .you("never sent"))
        skipped.add(.asked(["a"]), session: "ci")
        s.router.decisions.append(skipped)
        #expect(s.toldAll() == ["ci": ["rerun", "and again"], "docs": ["add the page"]])
        #expect(s.lastTold()["ci"]?.text == "and again" && s.lastTold()["ci"]?.at == t0.addingTimeInterval(60))
    }

    @Test func jevSeesWhatTheSessionWasLastToldNotTheWholeMessage() throws {
        let s = store()
        sent(in: s)
        let options = RouterTools(store: s).destinations(s, now: t0.addingTimeInterval(60))
        let told = { (id: String) in (options.first { $0.sessionID == id }?.criteria as? [String: Any])?["the user last told it"] as? String }
        let ci = try #require(told("ci")), docs = try #require(told("docs"))
        #expect(ci.hasPrefix("rerun (") && docs.hasPrefix("add the page ("))
        #expect(!ci.contains("docs") && !docs.contains("CI"))
    }
}
