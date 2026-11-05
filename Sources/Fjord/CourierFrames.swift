import Foundation

// The engine's side of watching every project through frames (docs/design/router-watch-and-briefs.md §1): the frame identity, each
// frame's own document state (never the top frame's `pages`/`loaded`/`instance`/health/notice), the wanted set the engine alone owns,
// the thread frames' kept slots and check slot, the handover grant and the run-less `home` step. Pure state; CourierCoreFrames acts on it.

/// A frame's identity: `fjord:<project>:<thread|->`, read from `window.name` by the worker, never from the address.
struct CourierFrame: Hashable, Comparable {
    var project: String
    var thread: String?

    init(project: String, thread: String?) { self.project = project; self.thread = thread }
    init?(_ j: JSON?) {
        guard let j, let p = j.get("project")?.asString, !p.isEmpty else { return nil }
        project = p
        thread = j.get("thread")?.asString.flatMap { $0.isEmpty ? nil : $0 }
    }

    var name: String { "fjord:\(project):\(thread ?? "-")" }
    var json: JSON { ["project": .string(project), "thread": JSON(thread)] }
    static func < (a: Self, b: Self) -> Bool { (a.project, a.thread ?? "") < (b.project, b.thread ?? "") }
}

/// One frame's document as its own events say (§1.6).
final class CourierFrameState {
    var loaded: JSON?
    var instance: JSON?
    var settled = false  // a settled whole read of this document came
    var notice: (text: String, at: Double)?
    var health = JSONObject()  // signed_in, page_ok, away: this frame's only
    var frameId: JSON?
    var loadDue: Double?  // `frame_loaded` came: a `page` from this frame is due by then (`frame_inject`, then blank)
    var injected = false
    var reloaded = false  // its one reload of this failure period was spent
    var stuck = 0
    var staleSince: Double?
    var staleTries = 0  // reloads at `home` steps since the last event that resets them (three at most)
    var stop = false  // a thread frame's dock shows `code-prompt-stop`
    var streaming = false  // a thread frame's rows (whole read and deltas since, merged by key) hold a streaming row
    var approval = false  // a thread frame's dock shows an approval slot holding something
    var rows: [String: JSON] = [:]  // a thread frame's rows by key: its last whole read, with every delta since merged in
    var live = false  // a settled whole read of this document came, and it is signed in: a project frame's `watch` is live
    var document: JSON?  // the worker's `documentId` of this frame's last `page`: a `frame_loaded` of that document waits for nothing
    var expectGone = false  // the engine reloaded it, or the top document went: its old document's `frame_gone` is no failure
}

/// A kept thread frame (§1.8): a `working` thread's, or one holding a pending card (its answering surface).
struct CourierKept: Equatable {
    var thread: String
    var project: String
    var card: Bool
    var used: Double  // its last card event: the least recently used card frame is evicted first
}

/// An `.answer` run (§3.6): it never takes the top tab, so it lives outside `runs`; it holds its frame's document instead.
final class CourierAnswer {
    let id: Int
    let frame: CourierFrame
    let card: String
    let option: Int
    var command: String?  // the issued `answer` command, until its `done` or `lost`
    var frameInstance: JSON?  // the frame's document it was issued to
    var attempts = 0
    var deadline: Double?
    var clicked = false  // its `done` said ok
    var answered = false  // the frame's rows show the card `answered`
    var lost = false  // the frame went (or a new document came) before its `done`: reissued once after that frame's replay
    var finished: (JSON) -> Void
    init(id: Int, frame: CourierFrame, card: String, option: Int, finished: @escaping (JSON) -> Void) {
        self.id = id; self.frame = frame; self.card = card; self.option = option; self.finished = finished
    }
    var inFlight: Bool { command != nil && !lost }
}

final class CourierFrames {
    static let keptCap = 3
    static let staleTries = 3
    static let recent = 86_400.0  // only threads touched within this are checked unprompted
    static let grantBound = 12  // at this budget the next run end grants a handover even with runs queued
    static let checkTries = 2  // a check that never settles is requeued this many times in a row, then left unchecked

    /// Frames are in use once the top frame says what it has on screen (`frames {have}`): until then no `frames`, no `home`.
    var on = false
    var states: [CourierFrame: CourierFrameState] = [:]
    var kept: [CourierKept] = []
    var check: CourierFrame?  // the check slot: one settled read, then removed
    var checkAnswer = false  // the check slot holds an answer's frame
    var archived = Set<String>()
    var have: [JSON] = []
    var lastWant: JSON?
    var overCap = Set<String>()  // working threads that found no kept slot: owed a check once their row goes paused
    var removeAfterRead = Set<String>()  // a plain-words request: the thread's frame goes after its next settled read
    var pendingCard: [String: String] = [:]  // thread -> the pending card's key a thread-view read showed: outranks every row status
    var expectWork = Set<String>()  // a read showed its card answered: no `paused` or `done` from the row until it shows `working`
    var rowStatus: [String: String] = [:]  // thread -> what its overview row said last
    var rowSig: [String: String] = [:]  // thread -> its overview row's structure and time, as last seen
    var rowTime: [String: Double] = [:]
    var wakes: [(at: Double, frame: CourierFrame)] = []

    // `home` (§1.3): wanted when a run ended; issued once none is left
    var homeWanted = false
    var homeID: String?

    // the handover (§1.7)
    var handoverBudget: Int?  // `handover_wanted` came with this budget, not yet granted
    var handoverDue: Double?  // granted: `handover_done` is due by then, else `handover_abort`
    var finishes = 0  // run ends: a wanted handover is granted at the next one
    var finishesAtWant = 0

    var answers: [Int: CourierAnswer] = [:]
    var checks: [String: CourierCheck]?  // router.db's `checks`, read once
    var checkSince: (frame: CourierFrame, at: Double)?  // the check slot's thread and when it took it: unsettled by `checkWait`, it is missed
    var checkMisses: [String: Int] = [:]  // thread -> checks that never settled in a row: requeued up to `checkTries`, then unchecked
    var topGone = false  // the top document went and no new one came yet: every frame's drop is expected
    var baseInstance: JSON?  // the handover's new top document, whose base set `handover_done` already sent

    func state(_ f: CourierFrame) -> CourierFrameState {
        if let s = states[f] { return s }
        let s = CourierFrameState()
        states[f] = s
        return s
    }

    func keptIndex(_ thread: String) -> Int? { kept.firstIndex { $0.thread == thread } }
    func holds(_ thread: String) -> Bool { keptIndex(thread) != nil || check?.thread == thread }

    /// An answer in flight for the thread pins its frame: never evicted, never dropped by a grant, a new document or a read.
    func pinned(_ thread: String?) -> Bool { thread != nil && answers.values.contains { $0.frame.thread == thread } }

    /// The least recently used card frame, which a working thread or an answer may evict (never one an answer pins).
    func lruCard() -> Int? {
        kept.indices.filter { kept[$0].card && !pinned(kept[$0].thread) }.min { kept[$0].used < kept[$1].used }
    }

    /// The thread frames wanted now: the kept ones and the check slot's.
    func threadFrames() -> [CourierFrame] {
        kept.map { CourierFrame(project: $0.project, thread: $0.thread) } + (check.map { [$0] } ?? [])
    }
}
