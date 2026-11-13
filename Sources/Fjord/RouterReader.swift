import Foundation

// Where a draft goes, read for Router v2's page (docs/design/router-v2/IMPLEMENTATION.md 1.5). The page shows what code
// knows in the frame of the keystroke (the open card as the prior; a new thread's default chips); this reads the rest and
// answers with one `RouterRead` per stable draft:
//   1. At the typing pause, Jev's fused path (`JevPath`) reads the draft; sure (P >= 0.90, an idle thread, still sendable)
//      it is one place and Sonnet is never asked.
//   2. Otherwise Sonnet decides on the full context (`RouterProjectDecider`) after the longer pause, with the open card as
//      a prior in its Now block and T3's models in its schema, so the draft's aside about a new thread ("use opus
//      medium") comes back as settings and the exact words that say them. The decider never writes the message.
// The next keystroke cancels both (the Sonnet process is terminated by its cancellation handler). The same words on the same
// board reuse the last answer. A Return before the read lands skips the pauses and lets a read already under way finish.
// Nothing polls: the only waits are the two pauses, and a Return cuts them short.

@MainActor
final class RouterReader {
    /// How long typing pauses before Jev reads the draft, and before Sonnet decides (`Router.jevPause`,
    /// `Router.sonnetPause`; tests set their own); the fewest characters worth a model call.
    var jevPause: Duration = Router.jevPause
    var sonnetPause: Duration = Router.sonnetPause
    static let minLength = 12
    /// Sonnet starts only when the draft differs by at least this many characters from the draft of his last start (a Return
    /// skips the guard): a typist's every thinking pause is not worth a full-context call.
    static let newCharacters = 10
    /// Each pause, start, cancel and skipped start, with timestamps, for tuning `Router`'s pauses from real typing
    /// (`Store.makeRouterReader` sets it).
    var log: DeciderLog?

    /// Jev's fused path on the draft (`Store.readDraft`); nil without Jev.
    var jev: (@MainActor (_ text: String, _ tagged: String?) async -> JevPath.Result?)?
    /// The whole decision (Sonnet on the full context, reusing Jev's answer; `Store.decideDestination`), with the open
    /// card's thread (T3's id) for the prior. Nil: it couldn't decide.
    var decide: (@MainActor (_ text: String, _ tagged: String?, _ selected: String?, _ reuse: JevPath.Result?) async -> RouterProjectDecision?)?
    /// T3's `searchThreads` for the draft, fired when Jev wasn't sure (`Store.searchDraft`).
    var search: (@MainActor (_ text: String) async -> [DeciderContext.SearchHit])?
    /// The board as it stands, for "the same board" (`Store.deciderBoardKey`).
    var boardKey: @MainActor () -> String = { "" }
    /// Whether a place (`RouteTarget.targetID`) can still be sent to (`RouterDispatcher.eligible`).
    var eligible: @MainActor (String) -> Bool = { _ in true }
    /// Whether a draft may be read at all now (the Router on, a real session).
    var allowed: @MainActor () -> Bool = { true }
    /// What the composer's @ pills tag, as the decider reads it (`RouterPointers.context`).
    var tagged: @MainActor ([RouterMention]) -> String? = { _ in nil }
    /// A draft's destination landed, with the decision behind it for the decision log (nil: none was made).
    var onRead: @MainActor (RouterRead, RouterProjectDecision?) -> Void = { _, _ in }

    /// Calls made (tests, and the signposts): Jev reads and Sonnet decisions.
    private(set) var reads = 0
    private(set) var decisions = 0
    /// The draft a read is waiting or under way for.
    private(set) var asking: String?

    private struct Ask: Equatable {
        var draft: String
        var selected: String?
        var mentions: [RouterMention]
    }

    private var current: Ask?
    private var generation = 0
    private var task: Task<Void, Never>?
    /// The pause being waited out, so a Return can cut it short.
    private var sleeper: Task<Void, Never>?
    private var hurry = false
    /// The draft Sonnet last started on, and what the read under way is doing, for the guard and the log.
    private var sonnetStart: String?
    private var phase = "idle"
    private var begunAt: ContinuousClock.Instant?
    private var jevLast: (text: String, board: String, result: JevPath.Result)?
    private var decided: (key: String, decision: RouterProjectDecision)?
    private var searched: (text: String, hits: [DeciderContext.SearchHit])?

    /// T3's search hits for these words, when they landed (the context's E block reads them).
    func searchHits(for text: String) -> [DeciderContext.SearchHit] { searched?.text == text ? searched?.hits ?? [] : [] }

    // MARK: The page's calls

    /// The draft (or what fixes its destination: the open card, the pills) changed. Typing never waits on this: the work starts
    /// in a task. A read under way for the very same ask is kept.
    func read(_ draft: String, selected: String?, mentions: [RouterMention]) {
        let ask = Ask(draft: draft, selected: selected, mentions: mentions)
        if current == ask, task != nil { return }
        start(ask, pauses: true)
    }

    /// One line of the typing trace: what happened to the read, in which phase, how long after the read began.
    private func trace(_ event: String, _ draft: String, extra: [String: Any] = [:]) {
        guard let log else { return }
        let elapsed = begunAt.map { $0.duration(to: .now) } ?? .zero
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        log.typing(event: event, phase: phase, characters: draft.count, sinceKeyMs: ms, extra: extra)
    }

    /// Nothing is read for this draft any more (it was cleared, or sent).
    func cancel() {
        stop()
        sonnetStart = nil
    }

    private func stop() {
        if task != nil, let current { trace("cancel", current.draft) }
        generation += 1
        task?.cancel()
        sleeper?.cancel()
        task = nil
        sleeper = nil
        current = nil
        asking = nil
        hurry = false
    }

    /// Return before the read landed: the pauses are skipped. A call already made is not started again.
    func now(_ draft: String) {
        guard let ask = current, ask.draft == draft, task != nil else {
            // Nothing under way for these words: read them now, without the pauses.
            if !draft.isEmpty { start(Ask(draft: draft, selected: current?.selected, mentions: current?.mentions ?? []), pauses: false) }
            return
        }
        hurry = true
        sleeper?.cancel()
    }

    // MARK: The read

    private func start(_ ask: Ask, pauses: Bool) {
        stop()
        current = ask
        begunAt = .now
        phase = "start"
        asking = ask.draft
        hurry = !pauses
        generation += 1
        let gen = generation
        let tagged = self.tagged(ask.mentions)
        task = Task { [weak self] in
            await self?.run(ask, tagged: tagged, gen: gen)
        }
    }

    private func run(_ ask: Ask, tagged: String?, gen: Int) async {
        let text = ask.draft
        func live() -> Bool { !Task.isCancelled && gen == generation }
        let board = boardKey()
        // Too short, or not allowed: only the prior (the open card), at once.
        guard text.count >= Self.minLength, allowed(), jev != nil || decide != nil else {
            land(ask, nil, gen: gen)
            return
        }
        // The same words on the same board (and the same open card): the last answer, with no pause and no call.
        let key = DeciderLog.hash([text, board, ask.selected ?? "", tagged ?? ""].joined(separator: "\u{1}"))
        if let last = decided, last.key == key {
            land(ask, last.decision, gen: gen)
            return
        }
        let begun = ContinuousClock.now
        phase = "jev-pause"
        await wait(jevPause)
        guard live() else { return }
        trace("pause", text, extra: ["for": "jev"])
        // Jev first: shown at once when he is sure.
        var jevResult = jevLast.flatMap { $0.text == text && $0.board == board ? $0.result : nil }
        if jevResult == nil, let jev {
            reads += 1
            phase = "jev"
            trace("start", text, extra: ["model": "jev"])
            jevResult = await jev(text, tagged)
            guard live() else { return }
            if let jevResult { jevLast = (text, board, jevResult) }
        }
        if let jevResult, let sure = jevSure(jevResult) {
            decided = (key, sure)
            land(ask, sure, gen: gen)
            return
        }
        // T3's search for the context's E block, in hand by the time Sonnet's pause is over (or not: BM25 alone then).
        if let search, searched?.text != text {
            Task { [weak self] in
                let hits = await search(text)
                if let self, self.current?.draft == text { self.searched = (text, hits) }
            }
        }
        let left = sonnetPause - (ContinuousClock.now - begun)
        phase = "sonnet-pause"
        if left > .zero { await wait(left) }
        guard live(), let decide else {
            if live() { land(ask, nil, gen: gen) }
            return
        }
        trace("pause", text, extra: ["for": "sonnet"])
        // Not for every thinking pause: the draft must have grown (or shrunk) by enough since Sonnet's last start. A Return
        // (hurry) always reads.
        // The same words asked again (another open card, another board) are not typing: no guard.
        if !hurry, let last = sonnetStart, last != text, abs(text.count - last.count) < Self.newCharacters {
            trace("skip", text, extra: ["since": abs(text.count - last.count)])
            land(ask, nil, gen: gen)
            return
        }
        sonnetStart = text
        decisions += 1
        phase = "sonnet"
        trace("start", text, extra: ["model": "sonnet", "hurry": hurry])
        let decision = await decide(text, tagged, ask.selected, jevResult)
        guard live() else { return }
        trace("done", text, extra: ["model": "sonnet"])
        if let decision { decided = (key, decision) }
        land(ask, decision, gen: gen)
    }

    /// Waits out a pause, unless a Return has cut it short; a cancellation ends it at once.
    private func wait(_ pause: Duration) async {
        guard !hurry else { return }
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: pause) }
        self.sleeper = sleeper
        await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
        self.sleeper = nil
    }

    /// Jev's sure send as a decision: an idle thread at P >= 0.90 that can still be sent to.
    private func jevSure(_ r: JevPath.Result) -> RouterProjectDecision? {
        guard let id = r.send(notTo: nil), eligible(RouteTarget.thread(id).targetID) else { return nil }
        var d = RouterProjectDecision(kind: .thread(id), confidence: r.p, decider: .jev)
        d.latency = r.latency
        d.action = "fused"
        d.fused = Task { r }
        return d
    }

    private func land(_ ask: Ask, _ decision: RouterProjectDecision?, gen: Int) {
        guard gen == generation, current == ask else { return }
        task = nil
        asking = nil
        let read = Self.read(ask.draft, decision: decision, selected: ask.selected, eligible: eligible)
        onRead(read, decision)
    }

    // MARK: Decision to read

    /// The decision as the page's read: the places that can still be sent to (three at most when unsure), whether it is sure,
    /// and, for a new thread, the settings the draft names with the words that say them (only when those words are found in
    /// the draft). With no decision there is only the prior: the open card, or no guess.
    static func read(_ draft: String, decision: RouterProjectDecision?, selected: String?, eligible: (String) -> Bool) -> RouterRead {
        guard let decision else {
            if let selected { return RouterRead(draft: draft, places: [.thread(selected)], sure: true) }
            return RouterRead(draft: draft, places: [], sure: false)
        }
        if case .answer = decision.kind { return RouterRead(draft: draft, places: [.here], sure: true) }
        var places: [RouterPlace] = []
        for kind in decision.places {
            let place: RouterPlace
            switch kind {
            case .thread(let id): place = .thread(id)
            case .newThread(let project): place = .newThread(project: project)
            default: continue
            }
            let target: RouteTarget = switch place {
            case .thread(let id): .thread(id)
            case .newThread(let project): .newThread(project: project)
            case .here: .thread("")
            }
            if eligible(target.targetID), !places.contains(place) { places.append(place) }
        }
        // A sure place that can't be sent to (gone) is no answer.
        let sure = decision.sure && !places.isEmpty
        if !sure { places = Array(places.prefix(3)) }
        return RouterRead(draft: draft, places: places, sure: sure)
    }
}
