import Foundation
import Testing
@testable import Fjord

@MainActor @Suite struct BriefFacts {
    private func thread(_ id: String, running: Bool = false, said: String? = nil, ended: Double? = nil, prs: [String] = []) -> AgentThread {
        var t = AgentThread(id: id, title: "Thread " + id, folder: "/code/p", lastActivity: Date(timeIntervalSince1970: 999_000),
                            running: running, latestMessage: said, lastRunEndedAt: ended.map { Date(timeIntervalSince1970: $0) })
        t.projectID = "p"
        t.pullRequests = prs.map { T3PullRequest(json: T3JSON.parse($0)!) }
        return t
    }

    @Test func everyThreadOnTheBoardCarriesItsReplyWithATimeAndItsPullRequestsWithState() {
        let old = 1_000_000.0 - 3 * 86_400
        let a = thread("a", running: true, said: "Still going, PR is up.", prs: [#"{"url":"https://github.com/o/r/pull/7","number":7,"state":"open"}"#])
        let b = thread("b", said: "CT5 is merged.", ended: old,
                       prs: [#"{"url":"https://github.com/o/r/pull/8","number":8}"#, #"{"url":"https://github.com/o/r/pull/9","number":9,"state":"open"}"#])
        let board = T3BriefSource.boards(threads: [a, b], requests: [:], prStates: ["https://github.com/o/r/pull/9": .merged],
                                         now: Date(timeIntervalSince1970: 1_000_000))["p"]!
        let ta = board.threads.first { $0.id == "a" }!, tb = board.threads.first { $0.id == "b" }!
        #expect(ta.ends == "Still going, PR is up." && ta.endsAt != nil)
        #expect(ta.prs == [BriefPR(url: "https://github.com/o/r/pull/7", number: 7, state: .open)])
        #expect(tb.ends == "CT5 is merged." && tb.endsAt == old && tb.runEnded == old)
        #expect(tb.prs.map(\.state) == [.unknown, .merged])
    }

    @Test func onlyYourOwnWordsCountAsSent() {
        let at = Date(timeIntervalSince1970: 999_000)
        var mine = thread("m"), agent = thread("g")
        mine.lastUserText = "ship it"; mine.lastUserMessage = at; mine.lastAuthoredAt = at
        // A wake or an agent-sent user message: the latest user-role message, but not your words.
        agent.lastUserText = "Background task completed"; agent.lastUserMessage = at; agent.lastAuthoredAt = at.addingTimeInterval(-3_600)
        let board = T3BriefSource.boards(threads: [mine, agent], requests: [:], now: Date(timeIntervalSince1970: 1_000_000))["p"]!
        #expect(board.sent.map(\.words) == ["ship it"])
        #expect(board.threads.first { $0.id == "g" }?.sentAt == at.addingTimeInterval(-3_600).timeIntervalSince1970)
    }
}
