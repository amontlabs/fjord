import Foundation
import Testing
@testable import Fjord

/// The record store's fixes from docs/design/router-v2/FINAL-REVIEW.md, each reproducing its finding.
@MainActor @Suite struct RouterReviewFixesTests {
    typealias F = RecordFixture
    typealias Harness = RouterRecordsTests.Harness

    private func last(_ changes: [RouterChange], _ id: String = "t1") -> RouterThread? {
        func all(_ c: RouterChange) -> [RouterThread] {
            switch c {
            case .upsert(let t): [t]
            case .batch(let list): list.flatMap(all)
            default: []
            }
        }
        return changes.flatMap(all).last { $0.id == id }
    }

    // MARK: #1: picks belong to one ask

    @Test func aRecordNamesTheAskItsCardAnswers() {
        let h = Harness()
        var t = F.thread(status: .waiting)
        t.pendingRequest = F.pending("req-1")
        h.records.put(t)
        #expect(last(h.take())?.askID == "req-1")
        t.pendingRequest = F.pending("req-2")
        h.records.put(t)
        #expect(last(h.take())?.askID == "req-2")
        t.pendingRequest = nil
        t.status = .running
        t.runStartedAt = F.ago(0)
        h.records.put(t)
        #expect(last(h.take())?.askID == nil)
    }
}
