import Foundation

// Your message stays in sight where it went: in the Brief, under the session it was sent to, one muted line with your words
// and how it is going: sending, delivered, working, and gone once that session's turn finishes (it replied). A message that
// didn't go says why in a word and stays until you dismiss it or a later message to that session replaces it. Nothing is kept
// for it: it is read from the delivery operations and the session's state.

struct RouterSentLine: Equatable, Identifiable {
    enum Status: Equatable {
        case sending, delivered, working
        /// It didn't go, or may not have: the word.
        case failed(String)

        var label: String {
            switch self {
            case .sending: "sending…"
            case .delivered: "delivered"
            case .working: "working"
            case .failed(let word): word
            }
        }

        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    /// The operation's nonce: what a dismissal is kept by.
    let nonce: String
    let session: String
    let text: String
    let status: Status
    var id: String { session }

    /// A delivered message nobody turned into a turn is not kept for ever.
    static let deliveredLife: TimeInterval = 15 * 60

    /// Where a delivery stands now, from its operation and its session; nil when there is nothing to show (the session
    /// replied, or it is gone).
    static func status(_ operation: DeliveryOperation, session: ClaudeSession?, now: Date = Date()) -> Status? {
        switch operation.state {
        case .waiting: return .sending
        case .unsure: return .failed("unsure")
        case .refused: return .failed("refused")
        case .needsYou: return .failed("needs you")
        case .sent:
            guard let session, now.timeIntervalSince(operation.updatedAt) < deliveredLife else { return nil }
            if session.running { return .working }
            // Its turn ran and finished after the delivery: it replied.
            return session.lastActivity > operation.updatedAt ? nil : .delivered
        }
    }
}

extension Store {
    /// The latest message you sent to each session, as a line, by session, less what was dismissed.
    func routerSentLines(dismissed: Set<String> = [], now: Date = Date()) -> [String: RouterSentLine] {
        var latest: [String: DeliveryOperation] = [:]
        for operation in router.operations {
            guard let session = operation.session, operation.decisionID != nil else { continue }
            if let had = latest[session], had.createdAt > operation.createdAt { continue }
            latest[session] = operation
        }
        var lines: [String: RouterSentLine] = [:]
        for (session, operation) in latest where !dismissed.contains(operation.nonce) {
            guard let id = operation.decisionID, case .you(let said)? = router.record(id)?.trigger,
                  let status = RouterSentLine.status(operation, session: claudeSessions[session], now: now) else { continue }
            lines[session] = RouterSentLine(nonce: operation.nonce, session: session, text: said, status: status)
        }
        return lines
    }
}
