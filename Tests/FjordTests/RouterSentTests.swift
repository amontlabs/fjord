import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite struct RouterSentTests {
    private let now = Date()

    private func operation(_ state: DeliveryOperation.State, ago: TimeInterval = 30) -> DeliveryOperation {
        let at = now.addingTimeInterval(-ago)
        return DeliveryOperation(nonce: UUID().uuidString, target: "t", kind: .message, bodyHash: "", state: state,
                                 decisionID: UUID(), session: "local_a", to: "A", createdAt: at, updatedAt: at)
    }

    private func session(running: Bool, activity: TimeInterval) -> ClaudeSession {
        ClaudeSession(id: "local_a", title: "A", folder: nil, lastActivity: now.addingTimeInterval(-activity), running: running)
    }

    @Test func aMessageGoesFromSendingToDeliveredToWorkingAndIsGoneOnceItsTurnFinished() {
        let idle = session(running: false, activity: 100)
        #expect(RouterSentLine.status(operation(.waiting), session: idle, now: now) == .sending)
        #expect(RouterSentLine.status(operation(.sent), session: idle, now: now) == .delivered)
        #expect(RouterSentLine.status(operation(.sent), session: session(running: true, activity: 1), now: now) == .working)
        #expect(RouterSentLine.status(operation(.sent), session: session(running: false, activity: 1), now: now) == nil)
        #expect(RouterSentLine.status(operation(.sent), session: nil, now: now) == nil)
        #expect(RouterSentLine.status(operation(.sent, ago: 3600), session: idle, now: now) == nil)
    }

    @Test func aFailureShowsItsWordAndStaysWhateverTheSessionDoes() {
        let done = session(running: false, activity: 1)
        #expect(RouterSentLine.status(operation(.unsure, ago: 7200), session: done, now: now) == .failed("unsure"))
        #expect(RouterSentLine.status(operation(.refused), session: nil, now: now) == .failed("refused"))
        #expect(RouterSentLine.status(operation(.needsYou), session: done, now: now) == .failed("needs you"))
    }

    @Test func theBriefKeepsOnlyTheLatestLinePerSessionAndPlacesItUnderTheFirstParagraphNamingIt() {
        let a = RouterSentLine(nonce: "1", session: "local_a", text: "x", status: .sending)
        let b = RouterSentLine(nonce: "2", session: "local_b", text: "y", status: .delivered)
        let placed = DigestPage.placeSent([a.session: a, b.session: b], in: [
            ("one", "no one here"), ("two", "<run s=\"local_a\">a</run> and <need s=\"local_a\">a</need>"),
        ])
        #expect(placed.byKey["two"] == [a])
        #expect(placed.rest == [b])
    }
}
