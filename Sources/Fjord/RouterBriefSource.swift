import Foundation

// The briefs over the engine (docs/design/router-watch-and-briefs.md 3 and 5.0): `CourierBriefSource` reads the log and the
// Board through `CourierHost`, and `RouterBriefLink` turns the host's `briefChanges` (said after each input it handled) into the
// engine's `itemsChanged` and `boardChanged`. Events decide; nothing here polls.

/// What changed for the briefs after one input of the host.
struct CourierBriefChange: Sendable, Equatable {
    /// Projects with new items in the log.
    var items: Set<String> = []
    /// Projects whose Board part (threads, statuses, watch, the coordinator's turn, your sends) changed.
    var board: Set<String> = []
    /// Projects whose coordinator's turn just ended: items that waited for it may call now.
    var turnEnded: Set<String> = []
    /// Every project's name, and every local thread's session key: the view's, sent with each change.
    var names: [String: String] = [:]
    var sessions: [String: String] = [:]

    var isEmpty: Bool { items.isEmpty && board.isEmpty && turnEnded.isEmpty }
}

/// One project's Board part, as the host has it now.
struct CourierBriefFacts: Sendable, Equatable {
    struct Thread: Sendable, Equatable {
        var id: String
        var title: String
        /// The Board's state (running, idle, needs_you, stranded…).
        var state: String
        var touched: Double
        /// A local thread's session key.
        var session: String?
        /// The latest recorded status (working, needs you, paused, done), when, and its `needs`.
        var status: String?
        var statusAt: Double?
        var needs: String?
    }

    /// A thread's pending card: its decision row's key, plan or question, the options in the page's order and words.
    struct Card: Sendable, Equatable {
        var key: String
        var kind: String
        var options: [String]
        var text: String?
    }

    var project: String
    var name = ""
    var threads: [Thread] = []
    var watch: CourierWatch = .none
    var turning = false
    var cardItems: [String: Card] = [:]
    var sent: [SentLine] = []
    /// The goal and instructions its settings showed when last read (nil before any read).
    var goal: String?
}

extension CourierHost {
    /// Every project on the Board.
    func briefProjects() -> [String] {
        guard let core else { return [] }
        return (core.board()["projects"]?.asObject?.keys).map { Array($0).sorted() } ?? []
    }

    /// One project's facts: only that project's threads and sends are read.
    func briefFacts(project: String) -> CourierBriefFacts {
        allBriefFacts(only: project)[project] ?? CourierBriefFacts(project: project)
    }

    /// Every project's facts (or `only` one's), from one read of the Board, the statuses and the latest sends.
    func allBriefFacts(only: String? = nil) -> [String: CourierBriefFacts] {
        guard let core else { return [:] }
        let board = core.board()
        let watch = self.watch()
        var out: [String: CourierBriefFacts] = [:]
        for (id, p) in board["projects"]?.asObject ?? JSONObject() where only == nil || only == id {
            let w = watch[id] ?? .none
            var stale = false
            if case .stale = w { stale = true }
            out[id] = CourierBriefFacts(project: id, name: p.get("name")?.asString ?? "", watch: w,
                                        turning: !stale && p.get("turning") == .bool(true), goal: Self.goal(p.get("settings")))
        }
        for (id, t) in board["threads"]?.asObject ?? JSONObject() {
            guard let project = t.get("project")?.asString, out[project] != nil else { continue }
            let status = core.log.status[id]
            out[project]!.threads.append(.init(id: id, title: t.get("title")?.asString ?? "", state: t.get("state")?.asString ?? "",
                                               touched: t.get("touched")?.numeric ?? 0,
                                               session: t.get("session")?.asString.flatMap { $0.isEmpty ? nil : $0 },
                                               status: status, statusAt: core.log.statusAt[id], needs: core.log.statusNeeds[id]))
            if status == "needs you", let key = core.watching.pendingCard[id], let card = core.log.latest(kind: "card", id: key),
               card.get("answered") != .bool(true) {
                out[project]!.cardItems[id] = .init(key: key, kind: card.get("kind")?.asString ?? "question",
                                                options: card.get("options")?.asArray?.compactMap(\.asString) ?? [],
                                                text: core.log.latest(kind: "row", id: key)?.get("text")?.asString)
            }
        }
        let intents = (try? core.db.intents(limit: 100, columns: "id, tool, project, words, status, cause, result")) ?? []
        for i in intents.reversed() {
            guard ["send_to_project", "reply_in_thread"].contains(i.get("tool")?.asString ?? ""),
                  let project = i.get("project")?.asString, out[project] != nil, (out[project]!.sent.count) < 5, let id = i.get("id")?.asInt
            else { continue }
            let state = Self.state(i, taken: core.runs[id]?.flag("taken") ?? false)
            out[project]!.sent.append(SentLine(intent: String(id), words: i.get("words")?.asString ?? "", state: CourierBriefSource.word(state)))
        }
        for k in out.keys { out[k]!.threads.sort { ($0.touched, $0.id) > ($1.touched, $1.id) }; out[k]!.sent.reverse() }
        return out
    }

    /// A settings read's goal and instructions, as one text the purpose is written from; nil before any read.
    nonisolated static func goal(_ settings: JSON?) -> String? {
        guard let settings, case .object = settings else { return nil }
        let goal = settings.get("goal")?.asString ?? "", instructions = settings.get("instructions")?.asString ?? ""
        return [goal.isEmpty ? nil : "Goal: " + goal, instructions.isEmpty ? nil : "Instructions: " + instructions]
            .compactMap { $0 }.joined(separator: "\n")
    }

    /// After each input: the projects with new items, the ones whose Board part changed, and the coordinator turns that ended.
    func shareBrief() {
        guard let core else { return }
        var change = CourierBriefChange()
        let last = core.log.lastSeq
        if let told = briefSeq, last > told {
            for i in (try? core.db.items(project: nil, after: told)) ?? [] { if let p = i.project { change.items.insert(p) } }
        }
        briefSeq = last
        let facts = allBriefFacts()
        var sigs: [String: String] = [:]
        for (p, f) in facts {
            sigs[p] = CourierBriefSource.signature(f)
            if briefSigs[p] != sigs[p] { change.board.insert(p) }
            if briefTurning[p] == true && !f.turning { change.turnEnded.insert(p) }
            briefTurning[p] = f.turning
        }
        for p in briefSigs.keys where sigs[p] == nil { change.board.insert(p) }
        briefSigs = sigs
        guard !change.isEmpty else { return }
        change.names = facts.mapValues(\.name)
        for f in facts.values { for t in f.threads { if let s = t.session { change.sessions[t.id] = s } } }
        briefSink.yield(change)
    }
}

/// The log API the engine reads (`BriefSource`), over the host.
struct CourierBriefSource: BriefSource {
    let host: CourierHost

    func projects() async -> [String] { await host.briefProjects() }

    func items(project: String, after cursor: Int) async -> [BriefItem] {
        await host.items(project: project, after: cursor).compactMap(Self.item)
    }

    func board(project: String) async -> BriefBoard { Self.board(await host.briefFacts(project: project)) }

    // MARK: Pure mappings

    /// A thread's status, as the log records it.
    static func status(_ s: String?) -> ThreadState? {
        switch s {
        case "working": .working
        case "needs you": .needsYou
        case "paused": .paused
        case "done": .done
        default: nil
        }
    }

    /// A Board state, for a thread with no recorded status yet.
    static func status(board s: String) -> ThreadState {
        switch s {
        case "running", "working", "busy": .working
        case "needs_you", "stranded", "waiting_app": .needsYou
        case "idle", "resolved", "done", "finished": .done
        default: .paused
        }
    }

    static func word(_ s: CourierState) -> String {
        switch s {
        case .sending, .taken: "sending"
        case .delivered, .deliveredLate, .toolDone: "delivered"
        case .failed, .toolUnconfirmed: "failed"
        case .refused: "refused"
        case .paused: "paused"
        case .awaiting: "waiting"
        }
    }

    /// One item of the log, as the brief's call reads it.
    static func item(_ i: CourierItem) -> BriefItem? {
        let c = i.content
        let text = c.get("text")?.asString ?? ""
        switch i.kind {
        case "project":
            return BriefItem(seq: i.seq, id: i.id, at: i.at, kind: .project, text: c.get("name")?.asString ?? "")
        case "thread":
            let title = c.get("title")?.asString ?? ""
            return BriefItem(seq: i.seq, id: i.id, at: i.at, kind: .thread, thread: i.id, text: text.isEmpty ? title : title + "\n" + text)
        case "row":
            let from = c.get("from")?.asString ?? "unknown"
            return BriefItem(seq: i.seq, id: i.id, at: i.at, kind: i.thread == nil ? .coordinator : .message, thread: i.thread,
                             text: "\(from): \(text)", options: c.get("options")?.asArray?.compactMap(\.asString) ?? [])
        case "card":
            let answered = c.get("answered") == .bool(true)
            return BriefItem(seq: i.seq, id: i.id, at: i.at, kind: .card, thread: i.thread,
                             text: (c.get("kind")?.asString ?? "question") + (answered ? " (answered)" : ""),
                             options: c.get("options")?.asArray?.compactMap(\.asString) ?? [])
        case "session":
            let state = c.get("state")?.asString ?? ""
            let line = [c.get("title")?.asString, c.get("needs")?.asString, c.get("detail")?.asString].compactMap { $0 }.joined(separator: " · ")
            return BriefItem(seq: i.seq, id: i.id, at: i.at, kind: ["stranded", "waiting_app"].contains(state) ? .stranded : .session,
                             thread: i.thread, text: "\(state): \(line)")
        case "status":
            let s = c.get("status")?.asString
            return BriefItem(seq: i.seq, id: i.id + ":" + (s ?? ""), at: i.at, kind: .status, thread: i.thread,
                             text: c.get("needs")?.asString ?? "", status: status(s))
        default:
            return nil
        }
    }

    /// The deterministic part of a project's brief, and the entries that wait on you: one per thread whose status is
    /// `needs you`, with its card's key and options as data when a thread view showed one.
    static func board(_ f: CourierBriefFacts) -> BriefBoard {
        var staleSince: Double?
        if case .stale(let since) = f.watch { staleSince = since }
        let watch: String? = switch f.watch {
        case .live: "live"
        case .stale(let since): "stale:\(since)"
        case .none: nil
        }
        var out = BriefBoard(sent: f.sent, watch: watch, coordinatorTurning: f.turning && staleSince == nil, goal: f.goal)
        for t in f.threads {
            let local = t.session != nil
            let state = status(t.status) ?? status(board: t.state)
            let asOf = local ? nil : staleSince
            out.threads.append(BriefThread(id: t.id, title: t.title, status: state, age: t.statusAt ?? t.touched,
                                           source: local ? .local : .cloud, asOf: asOf))
            guard state == .needsYou else { continue }
            var e = BriefEntry(project: f.project, thread: t.id, kind: .request, state: .needsYou, since: t.statusAt ?? t.touched,
                               source: local ? .local : .cloud, asOf: asOf)
            // What a read mark holds to: the status change, else the card; never `touched`, which moves on every touch.
            e.episode = t.statusAt.map { String(Int($0)) } ?? f.cardItems[t.id]?.key ?? "-"
            if t.needs == "permission" {
                e.kind = .permission
            } else if let card = f.cardItems[t.id] {
                e.kind = card.kind == "plan" ? .plan : .question
                e.card = card.key
                e.options = card.options
                e.question = card.text.flatMap { $0.isEmpty ? nil : $0 }
            } else if local, ["stranded", "waiting_app"].contains(t.state) {
                e.kind = .stranded
            }
            out.entries.append(e)
        }
        out.entries.sort { $0.since < $1.since }
        return out
    }

    /// What the Board part of a project is now, to tell a change from a repeat.
    static func signature(_ f: CourierBriefFacts) -> String {
        var parts = [f.name, "\(f.watch)", "\(f.turning)", f.goal ?? ""]
        parts += f.threads.map { "\($0.id)|\($0.title)|\($0.state)|\($0.status ?? "")|\($0.needs ?? "")|\($0.touched)" }
        parts += f.cardItems.keys.sorted().map { "card \($0)=\(f.cardItems[$0]!.key)/\(f.cardItems[$0]!.options.count)" }
        parts += f.sent.map { "sent \($0.intent)=\($0.state)" }
        return parts.joined(separator: "\n")
    }
}

/// What the engine is told.
@MainActor protocol BriefEvents: AnyObject {
    func itemsChanged(_ project: String)
    func boardChanged(_ project: String)
}

extension RouterBriefEngine: BriefEvents {}

/// Feeds the engine from the host's changes, and the view its names and local sessions.
@MainActor final class RouterBriefLink {
    private var following: Task<Void, Never>?
    /// Each change's names and sessions, for the view.
    var onChange: (CourierBriefChange) -> Void = { _ in }

    func follow(_ changes: AsyncStream<CourierBriefChange>, events: BriefEvents) {
        following?.cancel()
        following = Task { [weak self, weak events] in
            for await change in changes {
                guard let self, let events else { return }
                self.onChange(change)
                Self.deliver(change, to: events)
            }
        }
    }

    func stop() { following?.cancel(); following = nil }

    /// New items, or a coordinator turn that ended, may call the model; any other change rebuilds the deterministic part only.
    static func deliver(_ change: CourierBriefChange, to events: BriefEvents) {
        let calls = change.items.union(change.turnEnded)
        for p in calls.sorted() { events.itemsChanged(p) }
        for p in change.board.subtracting(calls).sorted() { events.boardChanged(p) }
    }
}
