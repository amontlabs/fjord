import Foundation

// The decider's full context (`DeciderContext`) from what Fjord holds: T3's shell for every listed thread (its times, read
// state, git, what it waits on), the board's reads for the live threads' compact lines, and the thread-card cache for the
// archive, the cards and the BM25 text (`ThreadCardStore`). The cache is kept current from shell events
// (`refreshThreadCards`); a decision reads memory only.

extension Store {
    /// Every listed thread as the context reads it. `board`: the board's threads (with their reads) are the live ones.
    func contextThreads(_ board: DeciderBoard) -> [ContextThread] {
        let onBoard = Dictionary(board.threads.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var names: [String: String] = [:]
        for (name, id) in board.projectIDs { names[id] = name }
        let firsts = threadCards.turns
        return threads.values.compactMap { t -> ContextThread? in
            guard let project = names[t.projectID] else { return nil }
            let b = onBoard[t.id]
            var c = ContextThread(key: t.id, project: project, title: t.title, created: t.createdAt ?? t.activityAt,
                                  lastActive: t.activityAt, settledAt: t.settledAt)
            c.branch = t.branch ?? ""
            c.pullRequests = t.pullRequests.compactMap(Self.pullRequestWords)
            c.running = b?.running ?? t.running
            c.waiting = b?.waiting
            c.step = b?.step ?? ""
            c.lastRunCompletedAt = t.lastRunEndedAt
            c.lastVisitedAt = t.lastVisitedAt
            c.youWroteAt = t.lastAuthoredAt
            c.onBoard = b != nil
            c.first = b?.first.nonEmpty ?? firsts[t.id]?.first(where: { $0.role == "user" })?.text ?? ""
            c.earlier = b?.earlier ?? []
            c.said = b?.said ?? ""
            c.youSaid = b?.youSaid
            c.youSaidLast = b?.youSaidLast ?? false
            return c
        }.sorted { ($0.created, $0.key) < ($1.created, $1.key) }
    }

    /// The threads the Router page shows a line for (what needs you, what is done and what works), as T3 thread ids.
    func mentionedThreads() -> Set<String> {
        Set(routerRecords.lines(in: .needsYou).map(\.id) + routerRecords.lines(in: .done).map(\.id)
            + routerRecords.lines(in: .working).map(\.id))
    }

    /// The context for a decision on `message`: the day's archive frozen, everything else as it is now. No read.
    func deciderContext(_ message: String, board: DeciderBoard, tagged: String? = nil, unattended: Bool = false,
                        now: Date = Date(), zone: TimeZone = .current) -> DeciderContext.Built {
        let threads = contextThreads(board)
        let cards = threadCards
        let ids = DeciderContext.ids(threads)
        let start = DeciderContext.dayStart(now, zone)
        let archive = cards.archive(day: start, zone: zone) {
            DeciderContext.archiveBlock(threads, ids: ids, cards: cards.cards, turns: cards.turns, firsts: [:], dayStart: start, zone: zone)
        }
        let search = routerPreview.searchHits(for: message)
        let x = DeciderContext.Inputs(projects: board.projects, purposes: board.purposes, threads: threads, cards: cards.cards,
                                      turns: cards.turns, archive: archive, index: cards.index, search: search, now: now, zone: zone,
                                      mentioned: mentionedThreads())
        return DeciderContext.build(message, x, tagged: tagged, unattended: unattended)
    }

    /// The shell changed: threads active in the archive window whose latest message moved are read again, and those whose run
    /// completed get a card (off the decision path; see `ThreadCardStore.refresh`).
    func refreshThreadCards(now: Date = Date()) {
        guard t3.store.hasClient else { return }
        if threadCards.reader == nil {
            let t3 = self.t3.store
            threadCards.reader = { id in await t3.readTurns(id) }
            let path = routerClaudeBinary?() ?? routerStatus.latestPath()
            threadCards.haiku = { system, user, schema in
                guard let path else { throw ClaudePrint.Failure(message: "Claude Code wasn't found") }
                return try await ClaudePrint.call(binary: path, model: ThreadCardStore.model, system: system, user: user, schema: schema,
                                                  effort: "low", timeout: 60, role: .cards, log: ModelUsageLog.shared).json
            }
        }
        let lo = now.addingTimeInterval(-Double(DeciderContext.archiveDays + 1) * 86400)
        threadCards.refresh(threads.values.filter { $0.activityAt >= lo }.map { t in
            (key: t.id, title: t.title, textStamp: t.latestMessageID ?? t.lastRunEndedAt.map { "\($0.timeIntervalSince1970)" } ?? "-",
             cardStamp: t.lastRunEndedAt.map { "\($0.timeIntervalSince1970)" }, running: t.running)
        })
    }
}
