import Foundation

/// The Router page's one-off reads of a turn's projection (FINAL-REVIEW #2): a finished or stopped turn is read once for
/// its reply, diff and last step, at most `cap` at once (a launch reads every Done line on the page), the newest ask
/// for a thread replacing an older one still waiting. No timer: each read that ends starts the next.
@MainActor final class RouterTurnReads {
    nonisolated static let cap = 4

    /// What a read answers with: the projection, or nil (no link, timed out).
    var done: (_ thread: String, _ key: String, _ projection: T3Projection?) -> Void = { _, _, _ in }

    private let reader: (String) async -> T3Projection?
    private let cap: Int
    private var waiting: [(thread: String, key: String)] = []
    private var running: Set<String> = []

    init(read: @escaping (String) async -> T3Projection?, cap: Int = RouterTurnReads.cap) {
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
