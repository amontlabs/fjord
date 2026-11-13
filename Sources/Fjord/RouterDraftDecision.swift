import Foundation

// Where a draft goes, decided on the board as it is now: the reader's Jev and Sonnet calls (`RouterReader`) and the
// dispatcher's decisions run through these.


extension Store {
    /// Fjord's decision on a draft, on the board as it is now (nothing waited for): Jev first, then Sonnet on the full context.
    /// `open`: the card open on the page, the decider's prior.
    func decideDraft(_ text: String, tagged: String?, notTo: String?, reuse: JevPath.Result?, open: String? = nil,
                     pointed: [DeciderContext.Pointed] = []) async -> RouterProjectDecision? {
        try? await decideDestination(text, tagged: tagged, notTo: notTo, reuse: reuse, jev: jevAsker(.routing, base: routerDispatcher.asker),
                                     open: open, pointed: pointed)
    }

    /// The decider on the board with its reads and the full context, for the composer and the dispatcher alike.
    func decideDestination(_ text: String, tagged: String?, action: RouterActionSource? = nil, notTo: String? = nil,
                           reuse: JevPath.Result? = nil, jev: JevAsker?, open: String? = nil, pointed: [DeciderContext.Pointed] = [],
                           stage: (RouterProjectDecider.Stage) -> Void = { _ in }) async throws -> RouterProjectDecision {
        let board = await deciderBoardWithReads()
        var decider = RouterProjectDecider.app(self)
        decider.jev = jev
        var decision = try await decider.decide(text, in: board, context: { [unowned self] in
            self.deciderContext(text, board: board, tagged: tagged, unattended: action != nil, open: open, pointed: pointed)
        }, tagged: tagged, action: action, notTo: notTo, reuse: reuse, stage: stage)
        decision.board = board
        if decision.boardText.isEmpty { decision.boardText = board.render() }
        return decision
    }

    /// Jev's fused path on a draft, on the board as it is now: nil without Jev.
    func readDraft(_ text: String, tagged: String?) async -> JevPath.Result? {
        guard let jev = jevAsker(.routing, base: routerDispatcher.asker) else { return nil }
        let board = await deciderBoardWithReads()
        return await JevPath.run(JevPath.request(text, board, tagged: tagged), message: text, jev: jev)
    }

    /// T3's own search over every thread for the draft's words (E's second source); nothing when it fails.
    func searchDraft(_ text: String) async -> [DeciderContext.SearchHit] {
        let query = String(RouterTools.redacted(text).prefix(200))
        guard t3.store.hasClient, query.count >= 2, let hits = try? await t3.store.search(query, limit: 10) else { return [] }
        return hits.map { DeciderContext.SearchHit(thread: $0.threadId, snippet: $0.snippet) }
    }

    /// "The same board": the listed threads, what each is doing, its latest message and read state, and the projects.
    func deciderBoardKey() -> String {
        let rows = threads.values.sorted { $0.id < $1.id }.map { t in
            [t.id, t.running ? "r" : "f", t.waitsForYou ? "w" : "", t.latestMessageID ?? "", t.lastVisitedAt.map { "\($0.timeIntervalSince1970)" } ?? "",
             t.settled ? "s" : ""].joined(separator: ",")
        }
        return DeciderLog.hash(rows.joined(separator: "\n") + "\u{1}" + t3.store.shell.projects.keys.sorted().joined(separator: ","))
    }

    /// Whether the composer may read drafts now: the Router on and a real session (a demo reads nothing).
    var previewsDrafts: Bool { routerOn && !routerIsPretend }
}
