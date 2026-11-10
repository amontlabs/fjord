import Foundation
import Testing
@testable import Fjord

actor FakeGitHub {
    var states: [String: PRState] = [:]
    var asked: [String] = []
    func set(_ url: String, _ s: PRState) { states[url] = s }
    func state(_ ref: PullRequestRef) -> PRState { asked.append(ref.url.absoluteString); return states[ref.url.absoluteString] ?? .open }
}

@MainActor @Suite struct BriefPullRequests {
    private func thread(_ id: String, said: String?) -> AgentThread {
        var t = AgentThread(id: id, title: "Thread " + id, folder: "/code/p", lastActivity: Date(), latestMessage: said,
                            lastRunEndedAt: Date())
        t.projectID = "p"
        return t
    }

    @Test func aPullRequestNamedInAReplyIsOnTheBoardWithItsState() {
        let t = thread("a", said: "Opened https://github.com/o/r/pull/12 for review.")
        let ref = PullRequestRef(owner: "o", repo: "r", number: 12)
        let open = T3BriefSource.boards(threads: [t], requests: [:], textPRs: ["a": [ref]])["p"]!
        #expect(open.threads[0].prs == [BriefPR(url: "https://github.com/o/r/pull/12", number: 12, state: .unknown)])
        let merged = T3BriefSource.boards(threads: [t], requests: [:], prStates: ["https://github.com/o/r/pull/12": .merged],
                                          textPRs: ["a": [ref]])["p"]!
        #expect(merged.threads[0].prs.map(\.state) == [.merged])
    }

    @Test func aStateChangeRebuildsTheBoardWithoutTheNetwork() async throws {
        let github = FakeGitHub()
        let dir = TempDir()
        let log = try BriefLog(path: dir.path("briefs.db").path)
        let store = Store()
        store.persists = false
        store.threads["a"] = thread("a", said: "PR: https://github.com/o/r/pull/12")
        let briefs = store.routerBriefs
        briefs.store = store
        let model = FakeBriefModel()
        let engine = RouterBriefEngine(source: T3BriefSource(log: log, boards: { [weak briefs] in briefs?.currentBoards() ?? [:] }),
                                       store: MemoryBriefStore(), model: model.runner, clock: { 100 })
        briefs.use(engine, log: log)
        briefs.usePullRequestStates(minInterval: 0) { await github.state($0) }
        briefs.threadsChanged(store: store)
        func state() -> PRState? { briefs.currentBoards()["p"]?.threads.first?.prs.first?.state }
        for _ in 0..<100 where state() != .open { try await Task.sleep(for: .milliseconds(20)) }
        #expect(state() == .open)
        // GitHub says it merged: the refresh brings the new state onto the board.
        await github.set("https://github.com/o/r/pull/12", .merged)
        await briefs.pullRequests?.refresh([PullRequestRef(owner: "o", repo: "r", number: 12)])
        for _ in 0..<100 where state() != .merged { try await Task.sleep(for: .milliseconds(20)) }
        #expect(state() == .merged)
        #expect(await github.asked.allSatisfy { $0 == "https://github.com/o/r/pull/12" })
    }
}
