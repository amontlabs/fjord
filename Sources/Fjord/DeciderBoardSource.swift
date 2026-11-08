import Foundation

// The decider's board from what Fjord holds of T3 (docs/design/t3-research/decider-board-spec.md, "Inputs per thread"): the
// listed threads (not settled, snoozed, archived or unlisted), what each is doing from T3's shell, the request it waits on,
// the project purposes the brief wrote, and what you last said in each candidate (read on demand, kept by thread@updatedAt).

/// What you last said in a thread, kept until the thread changes (its last activity is the stamp).
@MainActor final class YouSaidCache {
    private var kept: [String: (stamp: Date, text: String?)] = [:]

    func cached(_ id: String, stamp: Date) -> String?? {
        guard let hit = kept[id], hit.stamp == stamp else { return nil }
        return .some(hit.text)
    }

    func keep(_ id: String, stamp: Date, _ text: String?) { kept[id] = (stamp, text) }
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

    /// The board now. `youSaid`: your last message in a thread, by its id, for those known.
    func deciderBoard(now: Date = Date(), youSaid: [String: String] = [:]) -> DeciderBoard {
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
        let ordered = live.sorted { $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id }
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
        board.threads = ordered.compactMap { t in
            guard let project = names[t.projectID], let id = short[t.id] else { return nil }
            let flag: DeciderBoard.Flag = t.waitsForYou ? .waiting : t.running ? .running : .finished
            let work = threadWork[t.id]
            return DeciderBoard.Thread(
                id: id, key: t.id, project: project, title: t.title, flag: flag, running: t.running,
                minutesIdle: max(0, Int(now.timeIntervalSince(t.lastActivity) / 60)),
                step: t.running ? (work?.todo?.active ?? work?.text ?? "") : "",
                said: t.latestMessage ?? "", youSaid: youSaid[t.id] ?? t.lastUserText,
                waiting: t.waitsForYou ? (requests[t.id].map(Self.requestText) ?? Self.requestWords(t)) : nil)
        }
        return board
    }

    /// Your last message in each candidate of the board, read when it isn't known: from the held projection, else from T3 (a
    /// subscription held until its snapshot arrives). The ones not read within `within` seconds are left out. Kept by
    /// thread@lastActivity in `cache`.
    func youSaidReads(for board: DeciderBoard, cache: YouSaidCache, within: TimeInterval = 1.2) async -> [String: String] {
        var out: [String: String] = [:]
        var missing: [(id: String, stamp: Date)] = []
        for t in board.candidates {
            guard let thread = threads[t.key] else { continue }
            if thread.lastUserText != nil { continue }
            if let hit = cache.cached(t.key, stamp: thread.lastActivity) {
                if let text = hit { out[t.key] = text }
            } else if let p = self.t3.store.projections[t.key] {
                let text = T3Store.lastUserMessage(in: p)
                cache.keep(t.key, stamp: thread.lastActivity, text)
                if let text { out[t.key] = text }
            } else {
                missing.append((t.key, thread.lastActivity))
            }
        }
        guard !missing.isEmpty else { return out }
        let t3 = self.t3.store
        let read = await withTaskGroup(of: (String, String?)?.self) { group -> [(String, String?)] in
            for m in missing { group.addTask { (m.id, await t3.readLastUserMessage(m.id)) } }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(within * 1e9))
                return nil
            }
            var done: [(String, String?)] = []
            var pending = missing.count
            for await item in group {
                guard let item else { group.cancelAll(); break }
                done.append(item)
                pending -= 1
                if pending == 0 { group.cancelAll(); break }
            }
            return done
        }
        for (id, text) in read {
            if let stamp = missing.first(where: { $0.id == id })?.stamp { cache.keep(id, stamp: stamp, text) }
            if let text { out[id] = text }
        }
        return out
    }
}
