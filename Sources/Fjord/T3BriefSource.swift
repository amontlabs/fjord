import Foundation

// The briefs over the engine, on T3 (docs/design/t3-port-plan.md, Step 13): the facts are T3's threads now (`Store.threads`
// and `Store.requests`, from the shell and the projections Fjord already holds open) and Fjord's own log of what happened
// (`BriefLog`). A project is a T3 project. Events decide; nothing here polls.

/// What the engine is told.
@MainActor protocol BriefEvents: AnyObject {
    func itemsChanged(_ project: String)
    func boardChanged(_ project: String)
}

extension RouterBriefEngine: BriefEvents {}

/// The engine's source: the log's items and the boards `RouterBriefs` builds from the live threads.
struct T3BriefSource: BriefSource {
    let log: BriefLog
    /// Every project's board now, read on the main actor.
    let boards: @MainActor @Sendable () -> [String: BriefBoard]

    func projects() async -> [String] {
        let live = await boards().keys
        return Set(live).union(log.projects()).sorted()
    }

    func items(project: String, after cursor: Int) async -> [BriefItem] { log.items(project: project, after: cursor) }

    func board(project: String) async -> BriefBoard { await boards()[project] ?? BriefBoard() }

    // MARK: Pure mappings

    /// How far back a quiet thread still belongs on a project's board.
    static let window = 7 * 86_400.0
    static let perProject = 30
    static let sentLines = 5

    /// A thread's status on the board, from the shell alone.
    static func state(_ t: AgentThread) -> ThreadState {
        if t.needsYou { return .needsYou }
        if t.running { return .working }
        if t.finished || t.lastRunEndedAt != nil { return .done }
        return .paused
    }

    /// Whether a thread is on the board: live or waiting, else recent and not snoozed or settled away.
    static func listed(_ t: AgentThread, now: Date) -> Bool {
        if t.running || t.waitsForYou { return true }
        if let until = t.snoozedUntil, until > now { return false }
        if t.settled && !t.needsYou { return false }
        return now.timeIntervalSince(t.lastActivity) <= window
    }

    /// Every project's board: its threads, the entries that wait on you (a request T3 holds as data, else a plain-words one the
    /// model writes the question of), and the words you sent. `unreachableSince`: T3 stopped answering (`watch: "stale:"`).
    /// `ends`: the agent's last reply in each thread, where known (T3's shell doesn't carry it): a thread that stopped in the
    /// last day shows it.
    static func boards(threads: [AgentThread], requests: [String: ThreadRequest], unreachableSince: Double? = nil,
                       ends: [String: String] = [:], now: Date = Date()) -> [String: BriefBoard] {
        var byProject: [String: [AgentThread]] = [:]
        for t in threads where listed(t, now: now) { byProject[t.projectID, default: []].append(t) }
        var out: [String: BriefBoard] = [:]
        for (project, all) in byProject {
            let mine = all.sorted { ($0.lastActivity, $0.id) > ($1.lastActivity, $1.id) }.prefix(perProject)
            var board = BriefBoard(watch: unreachableSince.map { "stale:\($0)" } ?? "live")
            for t in mine {
                let state = Self.state(t)
                let since = t.lastActivity.timeIntervalSince1970
                let age = state == .done ? (t.lastRunEndedAt?.timeIntervalSince1970 ?? since) : since
                let reply = state == .working || now.timeIntervalSince1970 - age > BriefLog.recentWindow
                    ? nil : (t.latestMessage ?? ends[t.id]).map(BriefLog.clip)
                board.threads.append(BriefThread(id: t.id, title: t.title, status: state, age: age, asOf: unreachableSince, ends: reply))
                if state == .needsYou { board.entries.append(entry(t, project: project, request: requests[t.id], since: since, asOf: unreachableSince)) }
                if let said = t.lastUserText, let at = t.lastUserMessage, now.timeIntervalSince(at) <= 86_400 {
                    board.sent.append(SentLine(intent: t.id, words: said, state: "delivered"))
                }
            }
            board.entries.sort { ($0.since, $0.thread) < ($1.since, $1.thread) }
            board.sent = Array(board.sent.prefix(sentLines).reversed())
            out[project] = board
        }
        return out
    }

    /// The entry of a thread that waits on you. A held request decides its kind; the shell alone (before the projection
    /// loads) says a plan, a question or a permission; a stopped run is a request in plain words.
    static func entry(_ t: AgentThread, project: String, request: ThreadRequest?, since: Double, asOf: Double?) -> BriefEntry {
        var e = BriefEntry(project: project, thread: t.id, kind: .request, state: .needsYou, since: since, asOf: asOf)
        if let request {
            switch request.body {
            case .plan: e.kind = .plan
            case .approval: e.kind = .permission
            case .question: e.kind = .question
            }
            e.episode = request.id
        } else if t.hasPlan {
            e.kind = .plan
            e.episode = "plan@\(Int(since))"
        } else if let pending = t.pendingRequest {
            e.kind = pending.isUserInput ? .question : .permission
            e.episode = pending.id
        } else {
            e.episode = "stopped@\(Int(since))"
        }
        return e
    }
}
