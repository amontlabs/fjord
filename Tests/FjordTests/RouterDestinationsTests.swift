import Foundation
import Testing
@testable import Fjord

/// Which sessions Jev routes among (`RouterTools.destinations`), and how the board's recency weighs them
/// (`RouteFusion.features`).
@MainActor
struct RouterDestinationsTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    /// 20 sessions finished in the last hour, and two older ones beyond the limit: one whose card waits on you, one whose
    /// finished turn's card was never archived.
    private func store() -> Store {
        let s = InboxFixture.store([])
        s.router.enabled = true
        for n in 0..<20 {
            s.claudeSessions["recent\(n)"] = ClaudeSession(id: "recent\(n)", title: "Recent \(n)", folder: "/code/app",
                                                           lastActivity: t0.addingTimeInterval(-60 - Double(n)))
        }
        s.claudeSessions["asks"] = ClaudeSession(id: "asks", title: "Asks", folder: "/code/app", lastActivity: t0.addingTimeInterval(-3 * 86400))
        s.claudeSessions["done"] = ClaudeSession(id: "done", title: "Done", folder: "/code/app", lastActivity: t0.addingTimeInterval(-3 * 86400))
        s.router.cards = [
            RouterCard(id: "asks#t1", sessionID: "asks", kind: .question, title: "Asks", folder: "/code/app", text: "Which one?",
                       createdAt: t0.addingTimeInterval(-3 * 86400)),
            RouterCard(id: "done#t1", sessionID: "done", kind: .done, title: "Done", folder: "/code/app", text: "Shipped it.",
                       createdAt: t0.addingTimeInterval(-3 * 86400)),
        ]
        return s
    }

    @Test func anOldSessionBeyondTheLimitIsOfferedOnlyWhileItsCardWaitsOnYou() {
        let s = store()
        let targets = RouterTools(store: s).destinations(s, now: t0).map(\.target)
        #expect(targets.contains("answer:asks#t1"))
        #expect(!targets.contains("answer:done#t1") && !targets.contains("session:done"))
        #expect(targets.filter { $0.hasPrefix("session:recent") }.count == 20)
    }

    /// The latest finished session, the one you last told and the one whose conversation the message continues: recency
    /// features, unless it finished `RouteFusion.oldHours` ago or more and isn't waiting on you.
    @Test func anOldSessionHasNoneOfTheLatestSessionsPull() throws {
        func features(idle: Double, waiting: Bool = false) -> [String: Double] {
            var facts = RouterTools.Facts()
            facts.latest = ["a"]
            facts.idleMinutes = ["a": idle]
            facts.lastTold = "a"
            facts.targetOf = ["a": "session:a"]
            if waiting { facts.waiting = ["a"] }
            let signals = RouteFusion.Signals(route: ["session:a": 0.6, "new:/code/app": 0.4, "unclear": 0.1], next: ["a": 0.9])
            return RouteFusion.features(signals, facts: facts) { $0.hasPrefix("session:") ? String($0.dropFirst(8)) : nil }["session:a"] ?? [:]
        }
        let recent = features(idle: 60)
        #expect(recent["fin0"] == 1 && recent["told0"] == 1 && recent["nxt"] == 0.9 && (recent["fin0u"] ?? 0) > 0)
        let old = features(idle: RouteFusion.oldHours * 60)
        #expect(old["fin0"] == nil && old["told0"] == nil && old["nxt"] == 0 && old["fin0u"] == 0)
        #expect(old["lp"] == recent["lp"] && old["session"] == 1)
        let waits = features(idle: 3 * 24 * 60, waiting: true)
        #expect(waits["fin0"] == 1 && waits["told0"] == 1 && waits["nxt"] == 0.9)
    }

    /// Jev sure of a new session, the latest session (finished minutes ago, last told) unsure: the new session leads. At
    /// `new` 0.66 the session did.
    @Test func jevsNewSessionHoldsAgainstTheLatestSession() throws {
        var facts = RouterTools.Facts()
        facts.latest = ["a"]
        facts.idleMinutes = ["a": 6]
        facts.lastTold = "a"
        facts.targetOf = ["a": "session:a"]
        facts.message = "New session in app: the history rows can't be selected"
        let signals = RouteFusion.Signals(route: ["new:/code/app": 0.75, "session:a": 0.17, "unclear": 0.03], next: ["a": 0.3])
        let v = RouteFusion.decide(signals, facts: facts, answers: []) { $0.hasPrefix("session:") ? String($0.dropFirst(8)) : nil }
        #expect(v.ranked.first?.target == "new:/code/app")
    }

    @Test func aSessionYouTagIsOfferedWhateverItsCard() {
        let s = store()
        let targets = RouterTools(store: s).destinations(s, including: ["session:done"], now: t0).map(\.target)
        #expect(targets.contains("answer:done#t1"))
    }
}
