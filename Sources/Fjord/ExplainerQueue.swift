import Foundation

// Show me requests waiting for an explainer (docs/design/router-visuals/SHOWME.md §3), persisted to `Explainers/queue.json`
// so a request survives a relaunch. A composer send with Show me waits for its thread's turn to end; a Done card's Show me
// waits only for the creator. Creators run in parallel (§13, B2): a request leaves the queue once its explainer thread is
// launched, and from then on it is a run (`ExplainerRun`). Pure except `load` and `save`.

struct ExplainerRequest: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        /// The source thread's turn is still under way.
        case waitingForTurn
        /// The answer is there: the explainer can start.
        case waitingForCreator
    }

    /// The explainer thread's id, minted up front (`launchThread` takes it).
    var id: String
    /// The thread whose answer it explains.
    var source: String
    /// Your message it explains; nil for Show me on a card (its latest reply).
    var ask: String?
    var sentAt: Date
    var state: State
    /// The source thread has been in the shell since the request: a new thread's row arrives after T3 took the send, so
    /// only a row that was there and left means the thread is gone.
    var seen: Bool? = nil
    /// The source's completion that turned out not to answer the message (it ended before the send landed, or the message
    /// went to a queued run): the request waits for a later one.
    var after: Date? = nil
}

struct ExplainerQueue: Codable, Equatable, Sendable {
    /// Oldest first.
    var requests: [ExplainerRequest] = []

    /// A request older than this is dropped: whatever it asked about is a day old.
    static let expiry: TimeInterval = 24 * 60 * 60

    /// Why a request left the queue without an explainer.
    enum Dropped: Equatable, Sendable {
        /// The turn ended interrupted, failed or cancelled.
        case turnStopped
        /// The source thread is gone (archived or deleted).
        case threadGone
        case expired
    }

    var ready: [ExplainerRequest] { requests.filter { $0.state == .waitingForCreator } }

    /// A send with Show me that T3 took: wait for the turn it starts (or steers) to end.
    mutating func afterTurn(id: String = UUID().uuidString.lowercased(), source: String, ask: String?, sentAt: Date) {
        requests.append(ExplainerRequest(id: id, source: source, ask: ask, sentAt: sentAt.toMilliseconds, state: .waitingForTurn))
    }

    /// Show me on a Done card: its reply is there already.
    mutating func now(id: String = UUID().uuidString.lowercased(), source: String, at date: Date) {
        requests.append(ExplainerRequest(id: id, source: source, ask: nil, sentAt: date.toMilliseconds, state: .waitingForCreator))
    }

    mutating func remove(_ id: String) { requests.removeAll { $0.id == id } }

    /// The request was ready by the clock, but its message has no answer yet: wait for a completion later than `after`.
    mutating func notYet(_ id: String, after: Date) {
        guard let i = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[i].state = .waitingForTurn
        requests[i].after = after.toMilliseconds
    }

    /// Whether the source thread answered your message `ask`: the run it went into (started or steered) has ended, or, when
    /// T3 names no run for it, the agent replied after it. A message not in the thread yet isn't answered.
    static func answered(_ p: T3Projection, ask: String) -> Bool {
        guard let message = p.messages.first(where: { $0.id == ask }) else { return false }
        if let run = p.runs.first(where: { ($0.id == message.runId && message.runId != nil) || $0.userMessageId == ask }) {
            // A run that stopped may carry no completion time.
            return !run.status.isLive && !run.isQueued
                && (run.completedAt != nil || [.completed, .interrupted, .failed, .cancelled].contains(run.status))
        }
        let at = message.createdAt?.date ?? .distantPast
        return p.messages.contains { $0.role == "assistant" && !$0.streaming && ($0.createdAt?.date ?? .distantPast) >= at }
    }

    /// The requests waiting for a turn, read against the Router's shell: a turn over (no run live, its latest run completed
    /// at or after the send) makes the request ready; a turn that stopped, or a thread that's gone, drops it. Old requests
    /// expire. Returns the dropped ones, with why.
    mutating func advance(shell: T3ShellState, now: Date) -> [(ExplainerRequest, Dropped)] {
        var dropped: [(ExplainerRequest, Dropped)] = []
        requests = requests.compactMap { r in
            if now.timeIntervalSince(r.sentAt) > Self.expiry { dropped.append((r, .expired)); return nil }
            guard r.state == .waitingForTurn else { return r }
            guard let row = shell.threads[r.source] else {
                if r.seen == true { dropped.append((r, .threadGone)); return nil }
                return r
            }
            guard row.archivedAt == nil, row.deletedAt == nil else { dropped.append((r, .threadGone)); return nil }
            var r = r
            r.seen = true
            guard row.activeRunId == nil, !row.status.isLive, let done = row.latestRunCompletedAt?.date,
                  done >= r.sentAt, r.after.map({ done > $0 }) ?? true else { return r }
            if [.interrupted, .failed, .cancelled].contains(row.status) { dropped.append((r, .turnStopped)); return nil }
            var next = r
            next.state = .waitingForCreator
            return next
        }
        return dropped
    }

    // MARK: Disk

    static func load(_ url: URL) -> ExplainerQueue {
        guard let data = try? Data(contentsOf: url), let queue = try? coder.decoder.decode(ExplainerQueue.self, from: data)
        else { return ExplainerQueue() }
        return queue
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.coder.encoder.encode(self).write(to: url, options: .atomic)
    }

    static let coder: (encoder: JSONEncoder, decoder: JSONDecoder) = {
        // ISO 8601 with fractions, as T3 writes times: a send and the turn's end are compared to the millisecond.
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer(); try c.encode(T3Timestamp.format(date))
        }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = T3Timestamp(text).date else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a time: \(text)"))
            }
            return date
        }
        return (e, d)
    }()
}

extension Date {
    /// This time to the millisecond, as the queue and runs keep it on disk (T3's own precision), so a value reads back equal.
    var toMilliseconds: Date {
        let ms = (timeIntervalSince1970 * 1000).rounded()
        return T3Timestamp(date: Date(timeIntervalSince1970: ms / 1000)).date ?? self
    }
}
