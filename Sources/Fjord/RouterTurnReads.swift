import Foundation

/// The Router page's one-off reads of a turn's projection (FINAL-REVIEW #2): a finished or stopped turn is read once for
/// its reply, diff and last step, at most `cap` at once (a launch reads every Done line on the page), the newest ask
/// for a thread replacing an older one still waiting. No timer: each read that ends starts the next.
@MainActor final class RouterTurnReads<Value: Sendable> {
    /// What a read answers with: the projection (or what was made of it off the main thread), or nil (no link, timed out).
    var done: (_ thread: String, _ key: String, _ projection: Value?) -> Void = { _, _, _ in }

    private let reader: (String) async -> Value?
    private let cap: Int
    private var waiting: [(thread: String, key: String)] = []
    private var running: Set<String> = []

    init(read: @escaping (String) async -> Value?, cap: Int = RouterSnapshots.cap) {
        self.reader = read
        self.cap = cap
    }

    func read(_ thread: String, key: String) {
        waiting.removeAll { $0.thread == thread }
        waiting.append((thread, key))
        pump()
    }

    var runningCount: Int { running.count }
    var waitingCount: Int { waiting.count }

    private func pump() {
        while running.count < cap, let i = waiting.firstIndex(where: { !running.contains($0.thread) }) {
            let next = waiting.remove(at: i)
            running.insert(next.thread)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let projection = await self.reader(next.thread)
                self.running.remove(next.thread)
                self.done(next.thread, next.key, projection)
                self.pump()
            }
        }
    }
}

/// One projection read per thread at a time, shared (REVIEW-items 3.2): the card's read of a turn that just ended and the
/// open items' read of it ask together, and T3 is read once for both. A read that just landed is reused for a moment.
@MainActor final class RouterSnapshots {
    nonisolated static let cap = 4

    private let reader: (String) async -> T3Projection?
    private var inFlight: [String: Task<T3Projection?, Never>] = [:]
    private var recent: [String: (at: Date, projection: T3Projection)] = [:]
    /// How long a read that landed answers the next ask.
    var reuse: TimeInterval = 1
    var now: () -> Date = Date.init
    /// Reads made of T3 (tests).
    private(set) var made = 0

    init(read: @escaping (String) async -> T3Projection?) { self.reader = read }

    func read(_ id: String) async -> T3Projection? {
        let now = now()
        recent = recent.filter { now.timeIntervalSince($0.value.at) <= reuse }
        if let r = recent[id] { return r.projection }
        if let task = inFlight[id] { return await task.value }
        made += 1
        let reader = self.reader
        let task = Task { await reader(id) }
        inFlight[id] = task
        let p = await task.value
        inFlight[id] = nil
        if let p { recent[id] = (self.now(), p) }
        return p
    }
}
