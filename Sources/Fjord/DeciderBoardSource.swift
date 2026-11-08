import Foundation

// The decider's board from what Fjord holds of T3 (docs/design/t3-research/decider-board-spec.md, "Inputs per thread"): the
// listed threads (not settled, snoozed, archived or unlisted), what each is doing from T3's shell, the request it waits on,
// the project purposes the brief wrote, and the end of each candidate (your last words and the agent's last reply), read ahead
// of the decision from a bounded snapshot and kept by thread@latest message.

/// The end of a thread, as the board shows it.
struct ThreadReads: Equatable, Sendable {
    /// Your last message there.
    var youSaid: String?
    /// The agent's last reply.
    var reply: String?
    /// The thread's first ask, as far as the read reaches (a bounded snapshot holds the last 10 user turns).
    var first: String? = nil
    /// Your last few messages there, oldest first.
    var earlier: [String] = []
}

/// What was read of each thread's end, kept until its latest message changes (`stamp`), and the reads under way.
@MainActor final class ThreadReadCache {
    private var kept: [String: (stamp: String, reads: ThreadReads)] = [:]
    private var inflight: [String: (stamp: String, task: Task<Void, Never>)] = [:]

    func cached(_ id: String, stamp: String) -> ThreadReads? {
        guard let hit = kept[id], hit.stamp == stamp else { return nil }
        return hit.reads
    }

    func keep(_ id: String, stamp: String, _ reads: ThreadReads) { kept[id] = (stamp, reads) }

    /// Starts `read` for the thread unless one for this stamp is under way. The result is kept when it finishes.
    @discardableResult
    func fetch(_ id: String, stamp: String, read: @escaping @Sendable () async -> ThreadReads?) -> Task<Void, Never> {
        if let running = inflight[id], running.stamp == stamp { return running.task }
        let task = Task { [weak self] in
            let reads = await read()
            guard let self else { return }
            if let reads { self.keep(id, stamp: stamp, reads) }
            if self.inflight[id]?.stamp == stamp { self.inflight[id] = nil }
        }
        inflight[id] = (stamp, task)
        return task
    }

    /// Forgets threads that left.
    func prune(keeping ids: Set<String>) {
        for id in Set(kept.keys).subtracting(ids) { kept[id] = nil }
    }
}

extension Store {
    /// The thread's request as the board says it: the question with its options, the permission's prompt, the plan's start.
    static func requestText(_ r: ThreadRequest) -> String {
        switch r.body {
        case .question(let questions):
            return questions.map { q in
                let options = q.options.map(\.label).filter { !$0.isEmpty }
                return q.question + (options.isEmpty ? "" : " Options: " + options.joined(separator: " / "))
            }.joined(separator: " | ")
        case .approval(let kind, let prompt, _):
            return "permission (\(kind)): \(prompt)"
        case .plan(let markdown):
            return "plan: \(markdown)"
        }
    }

    /// What the shell alone says a thread waits on you for, when its projection isn't held.
    static func requestWords(_ t: AgentThread) -> String? {
        if t.hasPlan { return "a plan to approve" }
        guard let r = t.pendingRequest, r.blocking else { return nil }
        return r.isUserInput ? "a question" : "a permission (\(r.kind))"
    }

    /// The board now. `reads`: the end of a thread, by its id, for those known.
    func deciderBoard(now: Date = Date(), reads: [String: ThreadReads] = [:]) -> DeciderBoard {
        let live = threads.values.filter { t in
            if let until = t.snoozedUntil, until > now { return false }
            return !(t.settled && !t.running && !t.waitsForYou)
        }
        // A project's name as the board shows it: T3's title, made unique when two share it.
        var names: [String: String] = [:]
        var ids: [String: String] = [:]
        var repos: [String: String] = [:]
        let projects = t3.store.shell.projects.values.filter { $0.archivedAt == nil }
            .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        for p in projects {
            let base = DeciderBoard.one(p.title.isEmpty ? URL(fileURLWithPath: p.workspaceRoot).lastPathComponent : p.title, 60)
            var name = base.isEmpty ? "project" : base
            var n = 2
            while ids[name] != nil { name = "\(base) (\(n))"; n += 1 }
            names[p.id] = name
            ids[name] = p.id
            if let repo = p.repoSlug { repos[name] = repo }
        }
        var short: [String: String] = [:]
        var taken = Set<String>()
        let ordered = live.sorted { $0.activityAt != $1.activityAt ? $0.activityAt > $1.activityAt : $0.id < $1.id }
        for t in ordered {
            let plain = t.id.lowercased().filter { $0.isLetter || $0.isNumber }
            var n = min(8, plain.count)
            while n < plain.count, taken.contains(String(plain.prefix(n))) { n += 1 }
            let id = String(plain.prefix(n))
            taken.insert(id)
            short[t.id] = id
        }
        var board = DeciderBoard(projects: projects.compactMap { names[$0.id] }, threads: [])
        board.projectIDs = ids
        board.projectRepos = repos
        for p in projects {
            if let purpose = routerBriefs.docs[p.id]?.purpose, !purpose.isEmpty {
                board.purposes[names[p.id] ?? ""] = purpose.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
        }
        // The thread your latest message went to: Jev's board says so (E5's "your latest message went to this thread").
        let latestTold = live.filter { $0.lastUserMessage != nil }.max { $0.lastUserMessage! < $1.lastUserMessage! }?.id
        board.threads = ordered.compactMap { t in
            guard let project = names[t.projectID], let id = short[t.id] else { return nil }
            let flag: DeciderBoard.Flag = t.waitsForYou ? .waiting : t.running ? .running : .finished
            let work = threadWork[t.id]
            let read = reads[t.id]
            return DeciderBoard.Thread(
                id: id, key: t.id, project: project, title: t.title, flag: flag, running: t.running,
                minutesIdle: max(0, Int(now.timeIntervalSince(t.activityAt) / 60)),
                step: t.running ? (work?.todo?.active ?? work?.text ?? "") : "",
                said: t.latestMessage ?? read?.reply ?? "", youSaid: t.lastUserText ?? read?.youSaid,
                youSaidLast: t.lastUserText != nil,
                branch: t.branch ?? "", pullRequests: t.pullRequests.compactMap(Self.pullRequestWords),
                waiting: t.waitsForYou ? (requests[t.id].map(Self.requestText) ?? Self.requestWords(t)) : nil,
                first: read?.first ?? "", earlier: read?.earlier ?? t.lastUserText.map { [$0] } ?? [],
                youSaidMinutes: t.lastUserMessage.map { max(0, Int(now.timeIntervalSince($0) / 60)) },
                youLatest: t.id == latestTold)
        }
        return board
    }

    /// `#12 open`, from a pull request's shell snapshot; nil without a number.
    static func pullRequestWords(_ pr: T3PullRequest) -> String? {
        guard let number = pr.number else { return nil }
        return "#\(number)" + (pr.state.map { " " + $0.lowercased() } ?? "")
    }

    /// How a thread's end is known: the held projection, else the cache, else nothing (a read is started for next time).
    private func knownReads(for t: DeciderBoard.Thread) -> (reads: ThreadReads?, stamp: String)? {
        guard let thread = threads[t.key] else { return nil }
        let stamp = thread.latestMessageID ?? "-"
        if let p = t3.store.projections[t.key] { return (T3Store.tail(of: p), stamp) }
        return (deciderReads.cached(t.key, stamp: stamp), stamp)
    }

    /// Starts the reads the board's candidates still need: the end of a thread (the agent's last reply when the latest message
    /// is yours, your last words when it is the agent's) through a bounded snapshot. Off the decision path: called when the shell
    /// changes, and a read already under way for the same latest message is not started again.
    @discardableResult
    func prefetchDeciderReads() -> [Task<Void, Never>] {
        guard t3.store.hasClient else { return [] }
        let board = deciderBoard()
        deciderReads.prune(keeping: Set(threads.keys))
        var tasks: [Task<Void, Never>] = []
        let t3 = self.t3.store
        for t in board.candidates {
            guard let known = knownReads(for: t), known.reads == nil else { continue }
            let id = t.key
            tasks.append(deciderReads.fetch(id, stamp: known.stamp) { await t3.readTail(id) })
        }
        return tasks
    }

    /// The board for a decision: what is known now (cache, held projections) and nothing waited for. A candidate whose read has
    /// not landed goes without it; the reads it needs are started for the next decision.
    func deciderBoardWithReads() async -> DeciderBoard {
        prefetchDeciderReads()
        var reads: [String: ThreadReads] = [:]
        for t in deciderBoard().candidates {
            if let r = knownReads(for: t)?.reads { reads[t.key] = r }
        }
        return deciderBoard(reads: reads)
    }
}
