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
        s.threads = [
            "ci": AgentThread(id: "ci", title: "CI watcher", folder: "/code/lookout", lastActivity: t0, running: true),
            "docs": AgentThread(id: "docs", title: "Docs writer", folder: "/code/lookout", lastActivity: t0, running: true),
        ]
        return s
    }




}
