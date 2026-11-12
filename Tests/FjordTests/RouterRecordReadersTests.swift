import Foundation
import Testing
@testable import Fjord

/// What reads the Router's records besides the page: the decider's threads, the Router run's board, the bar's count.
@MainActor @Suite struct RouterRecordReadersTests {
    typealias F = RecordFixture

    private func store() -> Store {
        let s = Store()
        s.persists = false
        s.routerRecords.now = { F.now }
        var ask = F.thread("ta", title: "Pick the database", status: .waiting)
        ask.pendingRequest = F.pending(minutes: 4)
        s.routerRecords.replace([ask, F.thread("tb", title: "Tidy the notes", minutes: 40)])
        return s
    }

    @Test func theDecidersMentionedThreadsAreTheOnesThePageShows() {
        #expect(store().mentionedThreads() == ["ta", "tb"])
    }

    @Test func theRouterRunsBoardListsTheNeedsYouLinesByThreadID() {
        let c = store().routerRunContext(message: "go on")
        #expect(c.entries.map(\.thread) == ["ta"] && c.entries.first?.kind == "question")
    }

    @Test func theBarsCountIsTheRecordsNeedsYou() {
        #expect(store().routerRecords.needsYou == 1)
    }
}
