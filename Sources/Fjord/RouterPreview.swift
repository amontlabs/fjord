import Foundation
import Observation

// Where the draft will go, shown in the composer before it is sent (N4 §5, E5 "E"). After a 600 ms pause in typing (and at
// least 12 characters) Jev's fused path (`JevPath`) reads the draft; when it is sure (P >= 0.90 on an idle thread) the composer
// shows "→ <thread>" and Return sends there. When he isn't, Sonnet decides on the full context after a longer pause (1.2 s
// from the last keystroke, once per stable draft, cancelled by the next keystroke). Sure, it shows "→ <thread>" or "→ new thread
// in <project>"; not sure, its best guess highlighted and up to 2 alternatives, Return sending to the highlighted one and a
// click picking another. Return before any answer keeps the words in the composer and waits for the decision: a sure one sends
// at once, an unsure one shows its places and waits for a second Return or a click. Nothing asks after a send. Sending the
// same words on the same board reuses the answer. The menu always offers a new thread. Typing never waits on any of it.

@Observable @MainActor
final class RouterPreview {
    /// A decision for a draft: its words, the board it read (`Store.deciderBoardKey`), and the places it offers.
    struct Destination: Equatable {
        var text: String
        var key: String
        var decision: RouterProjectDecision
        /// The targets to offer, best first: the place itself when sure; the guess and up to 2 alternatives when not.
        var options: [String]
        var sure: Bool
        /// Fjord answers here (sure, no target).
        var answer: Bool { if case .answer = decision.kind { true } else { false } }
    }

    /// What a send carries of what the composer showed, for the decision log.
    struct Shown: Equatable, Sendable {
        var text: String
        var target: String
        var p: Double
        var decider: String
        var sure: Bool
    }

    /// The decision shown for the draft (its words may be a few keystrokes old until the next one lands).
    private(set) var destination: Destination?
    /// A decision is under way for the draft (shown once you pressed Return).
    private(set) var deciding = false
    /// Return was pressed before an answer: the words wait in the composer for the decision.
    private(set) var waiting: String?
    /// The chip's menu is open.
    var menuOpen = false
    /// A place picked (an alternative clicked, or from the menu): where Return sends.
    private(set) var pinned: String?
    private(set) var pinnedTitle: String?
    /// The place waved off for this draft: not offered again, and the message doesn't go there unasked.
    private(set) var dismissed: String?

    /// How long typing pauses before Jev reads the draft, and before Sonnet decides; the fewest characters worth reading.
    @ObservationIgnored var jevDelay: Duration = .milliseconds(600)
    @ObservationIgnored var sonnetDelay: Duration = .milliseconds(1200)
    static let minLength = 12
    /// Jev's fused path on the draft (tests stand in). Nil when there is no Jev.
    @ObservationIgnored var read: (@MainActor (_ text: String, _ tagged: String?) async -> JevPath.Result?)?
    /// The whole decision (Jev first, then Sonnet on the full context), reusing Jev's answer; nil when it couldn't decide.
    @ObservationIgnored var decide: (@MainActor (_ text: String, _ tagged: String?, _ notTo: String?, _ reuse: JevPath.Result?) async -> RouterProjectDecision?)?
    /// T3's `searchThreads` for the draft (E's second source), fired at the pause.
    @ObservationIgnored var search: (@MainActor (_ text: String) async -> [DeciderContext.SearchHit])?
    /// The board as it stands, for "the same board" (tests stand in).
    @ObservationIgnored var boardKey: @MainActor () -> String = { "" }
    /// Whether a place can still be sent to, and its option (the dispatcher's; tests stand in).
    @ObservationIgnored var eligible: @MainActor (String) -> Bool = { _ in true }
    /// Whether a draft may be read now (the Router on, not a demo); tests stand in.
    @ObservationIgnored var allowed: () -> Bool = { true }
    /// Jev's last answer, for its words: what the Sonnet stage and a send reuse.
    @ObservationIgnored private(set) var lastJev: (text: String, result: JevPath.Result)?
    @ObservationIgnored private var searched: (text: String, hits: [DeciderContext.SearchHit])?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The words a decision is waiting or under way for.
    @ObservationIgnored private(set) var asking: String?
    /// Decisions started (tests): Jev reads and Sonnet decisions.
    @ObservationIgnored private(set) var reads = 0
    @ObservationIgnored private(set) var decisions = 0
    /// What a Return that waited does once a sure answer lands (the model's send).
    @ObservationIgnored private var onReady: (() -> Void)?
    /// A Return waited and the answer wasn't sure: a click on a place sends these words there.
    @ObservationIgnored private(set) var clickSends: String?
    /// A shot put what is shown: nothing reads the draft, so it stays.
    @ObservationIgnored private var previewing = false

    /// The target Return sends to: the place picked, else the guess.
    var highlighted: String? { pinned ?? destination?.options.first }

    /// The thread the brief marks: the one Return would send to.
    var markedThread: String? { highlighted.flatMap(RouteTarget.init)?.threadID }

    /// Something to show over the composer.
    var visible: Bool { destination != nil || pinned != nil || deciding }

    /// T3's search hits for these words, when they landed.
    func searchHits(for text: String) -> [DeciderContext.SearchHit] { searched?.text == text ? searched?.hits ?? [] : [] }

    /// The draft (as it will be sent) or what fixes its target changed. Nothing is read when the draft is short, or when a
    /// reply, a tagged thread or a picked place already says where it goes. A decision for other words is cancelled at once.
    func update(text: String, context: RouterContext, tagged: String? = nil, store: Store) {
        if previewing { return }
        // A place picked holds: what is shown stays, and nothing is read again until it is taken off.
        if pinned != nil { cancel(); return }
        let fixed = RouterDispatcher.plan(text: text, context: context, store: store) != .decide
        if let waiting, waiting != text { self.waiting = nil; onReady = nil; deciding = false }
        if let words = clickSends, words != text { clickSends = nil; onReady = nil }
        guard allowed(), decide != nil || read != nil, !fixed, text.count >= Self.minLength else {
            cancel()
            if text.isEmpty { reset() } else if fixed || text.count < Self.minLength { destination = nil; menuOpen = false }
            return
        }
        if destination?.text == text || asking == text { return }
        start(text, tagged: tagged, delays: true)
    }

    private func start(_ text: String, tagged: String?, delays: Bool) {
        task?.cancel()
        asking = text
        let (jevDelay, sonnetDelay) = (self.jevDelay, self.sonnetDelay)
        let begun = ContinuousClock.now
        task = Task { [weak self] in
            if delays { try? await Task.sleep(for: jevDelay) }
            guard !Task.isCancelled, let self else { return }
            // Jev first: shown at once when he is sure.
            var jev = self.lastJev?.text == text ? self.lastJev?.result : nil
            if jev == nil, let read = self.read {
                self.reads += 1
                jev = await read(text, tagged)
                guard !Task.isCancelled, self.asking == text else { return }
                if let jev { self.lastJev = (text, jev) }
            }
            if let jev, let d = self.jevSure(jev) {
                self.finish(text, d)
                return
            }
            // T3's search for E, in hand by the time Sonnet's pause is over (or not: E is BM25 alone then).
            if let search = self.search, self.searched?.text != text {
                Task { [weak self] in
                    let hits = await search(text)
                    if self?.asking == text || self?.destination?.text == text { self?.searched = (text, hits) }
                }
            }
            if delays {
                let left = sonnetDelay - (ContinuousClock.now - begun)
                if left > .zero { try? await Task.sleep(for: left) }
            }
            guard !Task.isCancelled, self.asking == text, let decide = self.decide else { return }
            self.decisions += 1
            let decision = await decide(text, tagged, self.dismissed, jev)
            guard !Task.isCancelled, self.asking == text else { return }
            self.finish(text, decision)
        }
    }

    /// Jev's sure send as a decision (an idle thread at P >= 0.90 that can still be sent to, not the one waved off).
    private func jevSure(_ r: JevPath.Result) -> RouterProjectDecision? {
        guard let id = r.send(notTo: dismissed), eligible(RouteTarget.thread(id).targetID) else { return nil }
        var d = RouterProjectDecision(kind: .thread(id), confidence: r.p, decider: .jev)
        d.latency = r.latency
        d.action = "fused"
        d.fused = Task { r }
        return d
    }

    private func finish(_ text: String, _ decision: RouterProjectDecision?) {
        asking = nil
        task = nil
        deciding = false
        apply(decision ?? RouterProjectDecider.ask([], confidence: 0, decider: .none), text: text)
        if waiting == text, let d = destination, d.text == text {
            waiting = nil
            // Sure: it goes now. Not sure: the places wait for a second Return or a click, which sends.
            if d.sure, pinned == nil {
                let ready = onReady
                onReady = nil
                ready?()
            } else {
                clickSends = text
            }
        }
    }

    /// The decision as places to show: those that can still be sent to, never the one waved off.
    func apply(_ decision: RouterProjectDecision, text: String) {
        var options: [String] = []
        for k in decision.places {
            guard let t = RouterProjectDecision(kind: k, confidence: 0, decider: .none).target?.targetID,
                  t != dismissed, eligible(t), !options.contains(t) else { continue }
            options.append(t)
        }
        // A sure place that can't be sent to (gone, waved off) is no answer.
        let sure = decision.sure && !(decision.target != nil && options.isEmpty)
        if !sure { options = Array(options.prefix(3)) }
        destination = Destination(text: text, key: boardKey(), decision: decision, options: options, sure: sure)
        menuOpen = false
    }

    /// The decision a Return of `text` sends with: one for these very words on the board as it is now. Nil: none yet.
    func ready(for text: String) -> Destination? {
        guard let d = destination, d.text == text, d.key == boardKey() else { return nil }
        return d
    }

    /// Return before an answer: the words wait for the decision, which starts now without its pauses. `send` runs once it is
    /// sure.
    func waitAndSend(_ text: String, tagged: String?, send: @escaping () -> Void) {
        waiting = text
        onReady = send
        deciding = true
        if destination?.text == text { destination = nil }
        start(text, tagged: tagged, delays: false)
    }

    /// What a send of `text` carries of what was shown.
    func carried(for text: String) -> Shown? {
        guard let d = destination, d.text == text, let target = highlighted ?? (d.answer ? RouteLabel.changeFjord.rawValue : nil) else { return nil }
        return Shown(text: text, target: target, p: d.decision.confidence, decider: d.decision.decider.rawValue, sure: d.sure && pinned == nil)
    }

    /// The menu's places: those offered, then a new thread in each of their projects (the menu always offers one).
    func menu(store: Store) -> [RouterAskBack.Option] {
        let dispatcher = store.routerDispatcher
        var targets = destination?.options ?? []
        var projects: [String] = targets.compactMap { t in
            switch RouteTarget(t) {
            case .thread(let id)?: store.threads[id]?.projectID
            case .newThread(let p)?: p
            case nil: nil
            }
        }
        if projects.isEmpty { projects = store.deciderBoard().projects.map { store.deciderBoard().projectID($0) } }
        for p in projects {
            let t = RouteTarget.newThread(project: p).targetID
            if !targets.contains(t), t != dismissed { targets.append(t) }
        }
        return targets.compactMap { dispatcher.option($0, store: store) }
    }

    /// A place picked (an alternative clicked, or from the menu): Return sends there. Picked while the words wait, it sends.
    func pick(_ target: String, store: Store) {
        guard let option = store.routerDispatcher.option(target, store: store) else { return }
        pinned = target
        pinnedTitle = option.title
        menuOpen = false
        if let words = clickSends, let ready = onReady, destination?.text == words {
            clickSends = nil
            onReady = nil
            ready()
        }
    }

    /// The picked place taken off: the guess is highlighted again.
    func unpin() {
        pinned = nil
        pinnedTitle = nil
    }

    /// Esc, or the chip's ×: the place shown goes and stays away for this draft.
    func dismiss() {
        guard let d = destination, let target = highlighted else { return }
        dismissed = target
        pinned = nil
        pinnedTitle = nil
        var rest = d
        rest.options.removeAll { $0 == target }
        rest.sure = false
        destination = rest.options.isEmpty ? nil : rest
        menuOpen = false
    }

    /// Sent or cleared: everything starts over.
    func reset() {
        cancel()
        destination = nil
        menuOpen = false
        pinned = nil
        pinnedTitle = nil
        dismissed = nil
        lastJev = nil
        searched = nil
        waiting = nil
        onReady = nil
        clickSends = nil
        deciding = false
        previewing = false
    }

    private func cancel() {
        task?.cancel()
        task = nil
        asking = nil
        if waiting == nil { deciding = false }
    }

    /// A shot: a decision shown with nothing behind it.
    func show(_ destination: Destination) {
        self.destination = destination
        previewing = true
    }
}

extension Store {
    /// Fjord's decision on a draft, on the board as it is now (nothing waited for): Jev first, then Sonnet on the full context.
    func decideDraft(_ text: String, tagged: String?, notTo: String?, reuse: JevPath.Result?) async -> RouterProjectDecision? {
        try? await decideDestination(text, tagged: tagged, notTo: notTo, reuse: reuse, jev: jevAsker(.routing, base: routerDispatcher.asker))
    }

    /// The decider on the board with its reads and the full context, for the composer and the dispatcher alike.
    func decideDestination(_ text: String, tagged: String?, action: RouterActionSource? = nil, notTo: String? = nil,
                           reuse: JevPath.Result? = nil, jev: JevAsker?,
                           stage: (RouterProjectDecider.Stage) -> Void = { _ in }) async throws -> RouterProjectDecision {
        let board = await deciderBoardWithReads()
        var decider = RouterProjectDecider.app(self)
        decider.jev = jev
        var decision = try await decider.decide(text, in: board, context: { [unowned self] in
            self.deciderContext(text, board: board, tagged: tagged, unattended: action != nil)
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

extension RouterModel {
    /// The draft changed: the preview follows it.
    func previewDraft(store: Store) {
        let sent = sentDraft(store)
        let context = context(store, sent: sent)
        let tagged = RouterPointers.context(sent.mentions, store: store)
        store.routerPreview.update(text: sent.text, context: context, tagged: tagged, store: store)
    }
}
