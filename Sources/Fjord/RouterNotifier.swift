import Foundation

// Banners from the Router v2 records (docs/design/router-v2/IMPLEMENTATION.md 1.9): on a record's code transition (a new
// ask, a finish, a real stop, a usage limit) and when a verdict finds a step. Each is told once, keyed on the request, plan
// or run it is about (or the fingerprint the verdict judged); the records keep the told keys in their file, so a relaunch
// doesn't tell an old story again. The words are `ThreadNotices`'. It fires as the shell shows the change, no model between
// (a step's waits for its verdict, which is what found it).

@MainActor
final class RouterNotifier {
    /// Posts one banner (`Store.notifyRouter`; its id the thread's, so a later banner for the thread replaces it).
    var post: (ThreadNotice) -> Void = { _ in }
    /// More than `each` at once: one banner says how many (`Store.notifyRouter` with the count and their projects).
    var postMany: ([ThreadNotice]) -> Void = { _ in }

    static let each = 3

    /// The key each thread's state had when last seen: a refresh that keeps it tells nothing.
    private var last: [String: String] = [:]
    /// What the records' operation under way told, posted at its end (`flush`).
    private var pending: [ThreadNotice] = []

    /// A thread's code state moved. Returns the key it told, for the records to keep. A thread seen for the first time
    /// (a launch, a reconnect, a thread just listed) is told only what is fresh (`ThreadNotices.fresh`); a finish or a stop
    /// only while you haven't opened it.
    func changed(_ t: AgentThread, project: String?, from old: RouterCodeState?, to new: RouterCodeState, request: ThreadRequest?,
                 now: Date, told: [String]) -> String? {
        guard let n = ThreadNotices.notice(t, state: new, request: request, project: project ?? "") else {
            last[t.id] = nil
            return nil
        }
        let before = last[t.id]
        last[t.id] = n.key
        guard n.key != before, !told.contains(n.key) else { return nil }
        if old == nil, now.timeIntervalSince(new.since) > ThreadNotices.fresh { return nil }
        if n.kind != .needsYou, !t.unseen { return nil }
        pending.append(n)
        return n.key
    }

    /// A verdict found a step in a finished turn: told once per fingerprint.
    func step(_ t: AgentThread, project: String?, fingerprint: String, ask: String, told: [String]) -> String? {
        let n = ThreadNotices.step(t, fingerprint: fingerprint, ask: ask, project: project ?? "")
        guard !told.contains(n.key) else { return nil }
        pending.append(n)
        return n.key
    }

    /// Posts what was told since the last flush: each, or one banner for them all.
    func flush() {
        guard !pending.isEmpty else { return }
        let all = pending
        pending = []
        if all.count > Self.each { postMany(all) } else { all.forEach(post) }
    }
}
