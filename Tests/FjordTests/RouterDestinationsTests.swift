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

    @Test func aSessionYouTagIsOfferedWhateverItsCard() {
        let s = store()
        let targets = RouterTools(store: s).destinations(s, including: ["session:done"], now: t0).map(\.target)
        #expect(targets.contains("answer:done#t1"))
    }
}
