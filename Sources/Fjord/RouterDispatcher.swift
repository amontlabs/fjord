import Foundation
import Observation

// What you type (docs/design/router-redesign.md, "How a message flows"). Each message is a run of its own (several can be in
// flight), one entry of the decision log, its stage shown on its pill over the composer. Where it goes is decided once, among
// your claude.ai projects only: a reply armed on a card goes to the card's session; a claude.ai project or thread you tagged
// or pinned goes there with no model; anything else is for the project decider (`RouterProjectDecider`: Jev, then Sonnet),
// whose decision is acted on as it is: a thread gets the words, a project's coordinator picks the thread, a new project is
// proposed under the composer, the Router answers here, or you're asked where it goes. Nothing is sent when it isn't sure.

/// What a message of yours comes with besides its text: the card you're replying to (its session is the target), the claude.ai
/// place you pinned or waved off, and its pills.
struct RouterContext: Equatable {
    /// A card id.
    var replyTo: String?
    /// The local projects the message tags (their folders): context for an answer, and the folder a new project may use.
    var projects: [String]
    /// A claude.ai target (`RouterCourier.Target`) you pinned.
    var target: String?
    /// A target you dismissed (or a wrong send's, on Send elsewhere): the message never goes there without asking you.
    var notTo: String?
    /// Where the address pills are in the message (character offsets of each "@name"): only these are ever taken out of your
    /// words, never words that happen to match a project's name.
    var pills: [Range<Int>]
    /// Every pill of the message, what it points to and where (`RouterPointer`; `tag` sets this, `pills` and `projects`
    /// together): a claude.ai place tagged is where it goes, a notification or a category goes with it as a fenced block
    /// (`RouterPointers.context`).
    var mentions: [RouterMention] = []
    /// A category's "Then" sends it for a thing (`ActionMessage`): unattended, it goes only to a claude.ai project or thread
    /// (never the Router's own runs: an incoming PR must never change settings), and when where isn't clear it waits for your
    /// pick, with no fallback.
    var action: RouterActionSource?
    /// Sent from the Router page's composer: its run shows as a pill over the composer, flying to where it went
    /// (`RouterFlights`), and an ask about it unfolds there rather than in Needs you.
    var flies = false

    init(replyTo: String? = nil, projects: [String] = [], target: String? = nil, notTo: String? = nil, pills: [Range<Int>] = []) {
        self.replyTo = replyTo
        self.projects = projects
        self.target = target
        self.notTo = notTo
        self.pills = pills
    }
}

// MARK: - The ask-back card

/// "Where should this go?": a message waiting for you to say where. Nothing is sent until you pick.
struct RouterAskBack: Identifiable, Equatable {
    /// "New project…": the proposal flow starts for the message (`RouterProjectProposal`).
    static let newProject = "new_project"

    /// A target you can pick: a claude.ai project or thread (`RouterCourier.Target`), `newProject`, or `change_fjord` (the
    /// Router answers here).
    struct Option: Identifiable, Equatable, Hashable {
        var target: String
        var title: String
        var detail: String
        var id: String { target }
    }

    /// The entry of the run in the decision log.
    var id: UUID
    var message: String
    var context: RouterContext
    /// The likeliest places first.
    var options: [Option]
    /// The decider's best guess (what a different pick corrects).
    var suggestion: String?
    var at: Date
    /// Why it asks, when it isn't the decider's doubt ("Not delivered there").
    var note: String? = nil
    /// The name the decider gave a new project, for "New project…".
    var projectName: String? = nil
}

// MARK: - Dispatcher

@Observable @MainActor final class RouterDispatcher {
    /// Where a message goes without asking a model, or that it needs the decider.
    enum Plan: Equatable {
        case reply(session: String, card: String?)
        /// A claude.ai project or thread you tagged or pinned.
        case send(String)
        /// Wholly for the Router ("@router what needs me?").
        case answer
        case decide
    }

    /// A message ready to go, as the session will get it.
    struct Delivery: Equatable {
        var to: String
        /// What is sent (signed for the session's plugin).
        var text: String
        /// Your words as the session reads them, and as you wrote them.
        var body: String
        var original: String
        var rephrased: Bool
        var session: String?
    }

    /// Everything a run does outside Fjord's own state, so a test stands in for each. The defaults are the real ones.
    struct Effects {
        /// Where a message goes among the claude.ai projects (`RouterProjectDecider`), its stage told as it goes. `unattended`:
        /// an action's message, read by Jev only as an inbox action may be.
        var decide: @MainActor (RouterTools, _ message: String, _ unattended: Bool,
                                _ stage: @escaping @MainActor (RouterProjectDecider.Stage) -> Void) async throws -> RouterProjectDecision
        /// The message for a card's session with its addressing taken out (`Addressing`), and its signature.
        var prepare: @MainActor (RouterTools, _ session: String) async throws -> Delivery
        /// The signed send, through the gate: the plugin's ack when it went through the inbox.
        var send: @MainActor (RouterTools, Delivery) async throws -> String?
        /// A form answered for a card: what was answered.
        /// Only while the card still holds the form it was judged on (`FormSnapshot`).
        var answer: @MainActor (RouterTools, _ card: String, _ answers: [String: String], FormSnapshot) async throws -> String
        /// A Haiku run for an intent, given the context it starts from.
        var run: @MainActor (RouterTools, RouterRun.Intent, _ input: String) async throws -> RouterRun.Answer
        /// What revises a proposed project from your words (the app's asks Sonnet).
        var reviser: @MainActor () -> RouterProjectReviser = { RouterProjectFakeReviser() }
        /// Whether the plugin of the session (by Claude Code's id) takes back a delivery (`abort-v1`).
        var abortable: @MainActor (_ cli: String) async -> Bool = { _ in false }
        /// Takes a delivery back through the session's inbox: how far it had gone, as its plugin answered.
        var cancel: @MainActor (RouterDecision.Delivered) async throws -> RouterDecision.Cancelled = { _ in
            throw RouterTools.Failure("The Router isn't ready")
        }
        /// A plan decided for a card (approved, or sent back with the message): what was done.
        /// Only while the card still holds the plan it was judged on (`FormSnapshot`).
        var answerPlan: @MainActor (RouterTools, _ card: String, PendingForm.PlanDecision, FormSnapshot) async throws -> String = { _, _, _, _ in
            throw RouterTools.Failure("The Router isn't ready")
        }
    }

    /// Asks waiting for a pick, oldest first.
    private(set) var askBacks: [RouterAskBack] = []
    /// The runs of messages sent from the composer (`RouterContext.flies`), oldest first: the composer's pills.
    private(set) var flying: [UUID] = []
    /// The context each of `flying` was sent with, until its pill is done with: a Retry sends again as it was sent.
    @ObservationIgnored private var sentWith: [UUID: RouterContext] = [:]
    /// How far each run under way is, by its entry in the log ("finding where it goes", "sending"…).
    private(set) var progress: [UUID: String] = [:]
    /// What each Haiku run under way has shown so far: the reply as far as it is written, what it thought, the tools it
    /// called. Updated at most ten times a second; gone when the run ends.
    private(set) var live: [UUID: RouterRunLive] = [:]
    /// The last of a composer run's, kept for its pill (answered, it still lists what the run did) until the pill is done with.
    private(set) var lastLive: [UUID: RouterRunLive] = [:]
    /// A run of yours is under way: the composer shows Stop. An action's message being placed, or waiting its turn, is the
    /// inbox's, in the background (`actionRuns`): you send meanwhile, and Stop leaves it be.
    var isBusy: Bool { progress.keys.contains { !actionRuns.contains($0) } }
    /// What an action's message waiting its turn says on its line.
    static let waitingTurn = "waiting its turn"
    /// The entries of actions' messages under way or waiting their turn (`submit`, `launch`), until they end.
    @ObservationIgnored private var actionRuns: Set<UUID> = []
    /// Sends being taken back, by their entry in the log.
    private(set) var cancelling: Set<UUID> = []
    /// The entries whose message waits on a project proposal under the composer: not done until it is made or dropped.
    @ObservationIgnored private var proposing: Set<UUID> = []

    @ObservationIgnored weak var store: Store?
    @ObservationIgnored var effects: Effects
    /// Claude Code's binary, as `RouterStatus` found it.
    @ObservationIgnored var claudePath: () -> String? = { nil }
    /// Set up each run's tools before it starts (tests).
    @ObservationIgnored var configure: ((RouterTools) -> Void)?
    /// A run is over (tests wait on it).
    @ObservationIgnored var onFinish: ((UUID) -> Void)?
    @ObservationIgnored var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var runTools: [UUID: RouterTools] = [:]
    /// Jev's questions (tests answer for him); else `RouterTools.chooser`, else TypeSafe with your key.
    @ObservationIgnored var asker: JevAsker?

    init(store: Store) {
        self.store = store
        effects = Effects.unavailable
        effects = Effects.live(self)
        // An entry whose ask-back card is still up is not pruned from the history (its pick needs the record).
        store.decisionsInUse = { [weak self] in Set(self?.askBacks.map(\.id) ?? []).union(self?.proposing ?? []) }
        store.settleLostOperations()
    }

    struct Job {
        var id: UUID
        var text: String
        var context: RouterContext
        var tools: RouterTools
    }

    /// A composer pill is done with (landed, failed or dismissed): its run is no longer one of `flying`.
    func forgetFlying(_ id: UUID) {
        flying.removeAll { $0 == id }
        lastLive[id] = nil
        sentWith[id] = nil
    }

    /// What a composer message is sent again with (a Retry): what it was sent with, so its tags, armed reply and pin are the
    /// same; a place it went to only by being decided is decided again. Nil: it wasn't sent from the composer, or its pill is
    /// gone.
    func resendContext(_ id: UUID) -> RouterContext? {
        guard var context = sentWith[id] else { return nil }
        context.flies = true
        // A place you confirmed (picked or pinned) is where it goes again: no new ask.
        if context.target == nil, context.replyTo == nil, let entry = store?.router.record(id), entry.decision.confirmed == true,
           let target = entry.decision.targetID, RouterCourier.Target(target) != nil {
            context.target = target
        }
        return context
    }

    /// The demo's ask and run under way gone.
    func clearPreview() {
        askBacks = []
        progress = [:]
        flying = []
    }

    /// A demo or a shot: an ask waiting for you and runs shown under way, with nothing behind them.
    func preview(ask: RouterAskBack? = nil, progress runs: [UUID: String] = [:], flying messages: [UUID] = [],
                 live shown: [UUID: RouterRunLive] = [:], kept: [UUID: RouterRunLive] = [:]) {
        askBacks = ask.map { [$0] } ?? []
        progress = runs
        flying = messages
        live = shown
        lastLive = kept
    }

    // MARK: Entry points

    /// Your message. A run of its own: other runs go on meanwhile. Returns its entry in the decision log.
    @discardableResult
    func submit(_ text: String, context: RouterContext = RouterContext()) -> UUID? {
        guard let store, store.routerOn else { return nil }
        // An action's message: only while Triage and the Router are both on.
        if context.action != nil, !store.toolsLinked { return nil }
        // Sent as written (`RouterModel.sendable`): code keeps the indentation of its first line. Trimmed only to see it isn't empty.
        let text = RouterModel.sendable(text)
        guard !text.isEmpty else { return nil }
        var seen = Set<String>()
        var context = context
        context.projects = context.projects.filter { seen.insert($0).inserted }
        // A pill is an "@name" where it was said; anything else given as one isn't.
        let chars = Array(text)
        context.pills = context.pills.filter { $0.lowerBound >= 0 && $0.upperBound <= chars.count && !$0.isEmpty && chars[$0.lowerBound] == "@" }
        context.mentions = Self.mentions(context.mentions, in: text)
        var entry = RouterDecision(trigger: .you(text), decision: .init(intent: "message"),
                                   links: .init(cards: context.replyTo.map { [$0] } ?? []))
        entry.mentions = context.mentions.isEmpty ? nil : context.mentions
        entry.fromAction = context.action?.origin
        entry.actionStart = context.action.map { .init(title: $0.title, model: $0.model, effort: $0.effort) }
        let id = store.logDecision(entry)
        if context.flies, context.action == nil {
            flying.append(id)
            sentWith[id] = context
        }
        let job = Job(id: id, text: text, context: context,
                      tools: makeTools(id, text, pills: context.pills, mentions: context.mentions, action: context.action != nil))
        // Actions' messages one at a time, in order (`nextAction`); yours at once.
        if context.action != nil {
            actionRuns.insert(id)
            actionQueue.append(job)
            progress[id] = Self.waitingTurn
            nextAction()
        } else {
            launch(job, stage: "starting") { [self] job in try await execute(job) }
        }
        return id
    }

    /// Actions' messages waiting their turn, oldest first, and the one being placed: a backlog is placed one by one.
    @ObservationIgnored private var actionQueue: [Job] = []
    @ObservationIgnored private var actionPlacing: UUID?

    private func nextAction() {
        guard actionPlacing == nil else { return }
        while !actionQueue.isEmpty {
            let job = actionQueue.removeFirst()
            guard store?.toolsLinked == true else { drop(job, Self.unlinkedWords); continue }
            actionPlacing = job.id
            launch(job, stage: "starting") { [self] job in try await execute(job) }
            return
        }
    }

    /// An action's message that never ran (Stop, Triage or the Router switched off while it waited its turn): why, as its
    /// entry's last line.
    private func drop(_ job: Job, _ reason: String) {
        job.tools.endTurn()
        actionRuns.remove(job.id)
        progress[job.id] = nil
        store?.updateDecision(job.id) {
            $0.add(.failed(reason))
            $0.outcome = .done
        }
        follow(job.id)
        onFinish?(job.id)
    }

    /// You picked where an ask-back goes. The entry says it was a correction when the pick isn't the decider's guess.
    @discardableResult
    func pick(_ id: UUID, target: String) -> Bool {
        guard let store, store.routerOn, let ask = askBacks.first(where: { $0.id == id }) else { return false }
        guard live(ask, store: store) else { return false }
        // An action's message goes only to a claude.ai place, and only while Triage and the Router are both on.
        if ask.context.action != nil, RouterCourier.Target(target) == nil || !store.toolsLinked { return false }
        // Offered when it was asked: a place the Board no longer has isn't sent to.
        guard eligible(target, store: store) else { return false }
        answer(ask, target: target, store: store)
        return true
    }

    /// Whether the ask's decision still exists; a card whose entry is gone is removed, and nothing is sent without a record.
    private func live(_ ask: RouterAskBack, store: Store) -> Bool {
        if store.router.record(ask.id) != nil { return true }
        askBacks.removeAll { $0.id == ask.id }
        return false
    }

    /// Sends an ask's message where you picked, logged as your pick (or your correction of the decider's guess, with who
    /// guessed: the measurement reads it).
    private func answer(_ ask: RouterAskBack, target: String, store: Store) {
        let id = ask.id
        askBacks.removeAll { $0.id == id }
        let chosen = describe(target, store: store)
        let corrected = target != ask.suggestion
        store.updateDecision(id) {
            $0.decision.target = chosen
            $0.decision.targetID = target
            if corrected {
                $0.outcome = .corrected(from: ask.suggestion.map { describe($0, store: store) } ?? "no clear target", to: chosen)
                $0.decision.fromID = ask.suggestion
            } else {
                $0.decision.confirmed = true
            }
        }
        let tools = makeTools(id, ask.message, pills: ask.context.pills, mentions: ask.context.mentions,
                              action: ask.context.action != nil)
        let job = Job(id: id, text: ask.message, context: ask.context, tools: tools)
        launch(job, stage: "starting") { [self] job in
            // The send this one corrects (Send elsewhere): the engine keeps the correction on it.
            if corrected, let wrong = ask.suggestion.flatMap(RouterCourier.Target.init), let target = RouterCourier.Target(target),
               let old = store.router.record(id)?.decision.courierIntent, wrong.project != target.project {
                store.routerCourier.correct(old, project: target.project)
            }
            try await route(job, to: target, projectName: ask.projectName)
        }
        follow(id)
    }

    /// You dismissed an ask-back: nothing is sent.
    /// `reason`: why it goes when you didn't dismiss it (Stop, a switch turned off): an action's entry says it as its last
    /// line, so its run fails with why.
    func dismiss(_ id: UUID, reason: String? = nil) {
        guard let store, let i = askBacks.firstIndex(where: { $0.id == id }) else { return }
        let ask = askBacks.remove(at: i)
        store.updateDecision(id) {
            if let reason, ask.context.action != nil {
                $0.add(.failed(reason))
            } else {
                $0.reply = $0.done.contains(where: \.sendsWords) ? "Dismissed: sent nowhere else." : "Dismissed: nothing was sent."
            }
            $0.outcome = .done
        }
        follow(id)
    }

    /// Triage switched off: an action's message no longer goes anywhere. Its asks go, saying why, and those waiting their
    /// turn with them; one under way is stopped at its next step (`linked`).
    func unlinked() {
        for ask in askBacks where ask.context.action != nil { dismiss(ask.id, reason: Self.unlinkedWords) }
        let queued = actionQueue
        actionQueue = []
        for job in queued { drop(job, Self.unlinkedWords) }
    }

    /// An action's message moved on: its run says so (`Store.followActionRun`).
    func follow(_ id: UUID) { store?.followActionRun(id, dispatcher: self) }

    /// Stops every run under way (nothing more is sent by them) and drops the asks waiting for you.
    /// `reason`: what an action's entry says of it (its run fails with why). `actions`: the inbox's actions' messages too,
    /// their runs and their asks (the Router switched off); Stop is for yours, and leaves those be.
    func stopAll(reason: String = "Stopped; nothing was sent", actions: Bool = false) {
        let stopped = { [actionRuns] (id: UUID) in actions || !actionRuns.contains(id) }
        for (id, task) in tasks where stopped(id) { task.cancel() }
        // Their turns end now, not once each run sees it was stopped: a send on its way is refused at its last gate.
        for (id, tools) in runTools where stopped(id) { tools.endTurn() }
        for ask in askBacks where actions || ask.context.action == nil { dismiss(ask.id, reason: reason) }
    }

    // MARK: Runs

    /// `action`: an action's message, whose every send is refused once Triage or the Router is off (`linked`).
    func makeTools(_ id: UUID, _ text: String, pills: [Range<Int>], mentions: [RouterMention] = [],
                   action: Bool = false) -> RouterTools {
        let tools = RouterTools(store: store!)
        tools.claudePath = { [weak self] in self?.claudePath() }
        tools.decision = id
        tools.stage = { [weak self] in self?.progress[id] = $0 }
        let feed = LiveFeed { [weak self] in self?.show($0, for: id) }
        tools.watch = { feed.push($0) }
        tools.beginTurn(text, pills: pills)
        tools.tagged = RouterPointers.context(mentions, store: store!)
        if action { tools.deliveryCheck = { [weak store = self.store] in store?.toolsLinked == true ? nil : Self.unlinkedWords } }
        configure?(tools)
        return tools
    }

    /// Why an action's message no longer goes: Triage or the Router switched off since it was sent to the Router.
    static let unlinkedWords = "Triage or the Router is off; nothing was sent"

    /// An action's message goes on only while Triage and the Router are both on, checked again before each step that sends.
    private func linked(_ context: RouterContext) throws {
        guard context.action != nil, store?.toolsLinked != true else { return }
        throw RouterTools.Failure(Self.unlinkedWords)
    }

    /// The pills of `text` that are where they say: each an "@name" inside it, none overlapping another.
    static func mentions(_ mentions: [RouterMention], in text: String) -> [RouterMention] {
        let chars = Array(text)
        var end = 0
        return mentions.sorted { $0.range.lowerBound < $1.range.lowerBound }.filter { m in
            guard m.range.lowerBound >= end, m.range.upperBound <= chars.count, !m.range.isEmpty,
                  chars[m.range.lowerBound] == "@" else { return false }
            end = m.range.upperBound
            return true
        }
    }

    func launch(_ job: Job, stage first: String, _ body: @escaping (Job) async throws -> Void) {
        if job.context.action != nil { actionRuns.insert(job.id) }
        progress[job.id] = first
        runTools[job.id] = job.tools
        tasks[job.id] = Task { [weak self] in
            do {
                try await body(job)
            } catch is CancellationError {
                self?.fail(job, "Stopped")
            } catch {
                self?.fail(job, error.localizedDescription)
            }
            self?.end(job)
        }
    }

    /// A run's live state, as the reader's thread reports it (coalesced by `LiveFeed`): only while the run is under way.
    func show(_ run: RouterRunLive, for id: UUID) {
        guard progress[id] != nil, live[id] != run else { return }
        live[id] = run
    }

    func end(_ job: Job) {
        job.tools.endTurn()
        actionRuns.remove(job.id)
        progress[job.id] = nil
        if let last = live.removeValue(forKey: job.id), flying.contains(job.id) { lastLive[job.id] = last }
        tasks[job.id] = nil
        runTools[job.id] = nil
        // Waiting for your pick, or on a proposal, is not over; anything else not settled is done.
        if !askBacks.contains(where: { $0.id == job.id }), !proposing.contains(job.id) {
            store?.updateDecision(job.id) { if $0.outcome == .pending { $0.outcome = .done } }
        }
        follow(job.id)
        onFinish?(job.id)
        // Placed: the next action's message goes.
        if actionPlacing == job.id {
            actionPlacing = nil
            nextAction()
        }
    }

    private func fail(_ job: Job, _ reason: String) {
        let first = reason.split(separator: "\n").first.map(String.init) ?? "failed"
        store?.updateDecision(job.id) { $0.add(.failed(RouterDecision.clip(first, 120))) }
    }

    func stage(_ job: Job, _ text: String) { progress[job.id] = text }

    func note(_ job: Job, _ item: RouterDecision.Done, session: String? = nil, card: String? = nil) {
        store?.updateDecision(job.id) { $0.add(item, session: session, card: card) }
    }

    // MARK: Routing

    func execute(_ job: Job) async throws {
        guard let store else { return }
        switch Self.plan(text: job.text, context: job.context, store: store) {
        case .reply(let session, let card):
            chosen(job)
            try await reply(job, session: session, card: card)
        case .send(let target):
            // A place you tagged or pinned: yours, as a pick is.
            confirm(job, target)
            try await route(job, to: target)
        case .answer:
            try await think(job, .question)
        case .decide:
            try await decideAndAct(job)
        }
    }

    /// Where it goes is yours (the card you replied to).
    func chosen(_ job: Job) {
        store?.updateDecision(job.id) { $0.decision.confirmed = true }
    }

    /// A target you fixed yourself.
    func confirm(_ job: Job, _ target: String) {
        guard let store else { return }
        store.updateDecision(job.id) {
            $0.decision.target = describe(target, store: store)
            $0.decision.targetID = target
            $0.decision.label = Self.label(target)
            $0.decision.confirmed = true
        }
    }

    /// Where a message goes without a model: the card a reply is armed on, the claude.ai place pinned, or the one claude.ai
    /// place tagged (and nothing else that says where). Words wholly for the Router are its own. Anything else is decided.
    static func plan(text: String, context: RouterContext, store: Store) -> Plan {
        // An action's message is never the Router's own, nor a reply: it goes to a claude.ai place.
        let unattended = context.action != nil
        if !unattended, forRouter(text, pills: context.pills) { return .answer }
        if !unattended, let id = context.replyTo, let card = store.router.cards.first(where: { $0.id == id }) {
            return .reply(session: card.sessionID, card: id)
        }
        if !unattended, let target = context.target, let courier = RouterCourier.Target(target),
           RouterCourier.eligible(courier, store: store) {
            return .send(courier.targetID)
        }
        if let only = claudeTag(context, store: store) { return .send(only) }
        return .decide
    }

    /// The one claude.ai place the message tags, when it tags no other and no reply or pin fixes it: nil otherwise, or when the
    /// Board hasn't that place.
    static func claudeTag(_ context: RouterContext, store: Store) -> String? {
        let tagged = context.claudeTargets
        guard tagged.count == 1, context.replyTo == nil, context.target == nil,
              let target = RouterCourier.Target(tagged[0]), RouterCourier.eligible(target, store: store) else { return nil }
        return target.targetID
    }

    /// Everything in the message is for the Router (`@router`, its asides): nothing of it would go on.
    static func forRouter(_ text: String, pills: [Range<Int>]) -> Bool {
        guard RouterTools.hasRouterAside(text) else { return false }
        do { _ = try Addressing.edit(text, pills: pills) } catch { return error is Addressing.NothingLeft }
        return false
    }

    /// The decider's decision, acted on: a place gets the words, a new project is proposed, the Router answers, or you're asked.
    func decideAndAct(_ job: Job) async throws {
        guard let store else { return }
        let unattended = job.context.action != nil
        stage(job, RouterProjectDecider.Stage.jev.words)
        let decision = try await effects.decide(job.tools, job.text, unattended) { [weak self] in self?.stage(job, $0.words) }
        try Task.checkCancellation()
        try linked(job.context)
        store.updateDecision(job.id) {
            $0.decision.decider = decision.decider.rawValue
            $0.decision.confidence = decision.confidence
            if !decision.reason.isEmpty { $0.note = RouterDecision.clip(decision.reason, 200) }
        }
        switch decision.kind {
        case .project, .newWork:
            guard let target = decision.target?.targetID, target != job.context.notTo, eligible(target, store: store) else {
                return askBack(job, decision)
            }
            store.updateDecision(job.id) {
                $0.decision.label = Self.label(target)
                $0.decision.target = describe(target, store: store)
                $0.decision.targetID = target
            }
            try await route(job, to: target)
        case .newProject(let name):
            // An action's message never makes a project by itself: you pick.
            guard !unattended else { return askBack(job, decision) }
            store.updateDecision(job.id) {
                $0.decision.label = "new_project"
                $0.decision.target = "new claude.ai project “\(name)”"
                $0.decision.targetID = RouterAskBack.newProject
            }
            propose(job, name: name)
        case .answer:
            guard !unattended else { return askBack(job, decision) }
            store.updateDecision(job.id) { $0.decision.label = RouteLabel.changeFjord.rawValue }
            try await think(job, .changeFjord)
        case .ask:
            askBack(job, decision)
        }
    }

    /// Acts on a target: a claude.ai place gets the message, "New project…" proposes one, an intent is a run.
    func route(_ job: Job, to target: String, projectName: String? = nil) async throws {
        try linked(job.context)
        if target == RouterAskBack.newProject {
            return propose(job, name: projectName ?? RouterProjectProposalSeed.name(from: job.text))
        }
        if courierHandoff(job, to: target) != nil { return }
        if let intent = RouterRun.Intent(rawValue: target) { return try await think(job, intent) }
        throw RouterTools.Failure("Nowhere to send that")
    }

    /// The proposal for a new project, under the composer: the decider's name with the folder and repo the message points to.
    /// The entry waits on it: made, it says where the message went (and what you changed of the proposal, for the measurement);
    /// dropped, that nothing was sent.
    func propose(_ job: Job, name: String) {
        guard let store else { return }
        let first = RouterProjectProposalSeed.fields(name: name, message: job.text, context: job.context, store: store)
        let id = job.id
        proposing.insert(id)
        let proposal = store.proposeProject(for: Self.courierWords(job.text, pills: job.context.pills), first: first,
                                            reviser: effects.reviser())
        var made = false
        proposal.onCreated = { [weak store] fields in
            made = true
            store?.updateDecision(id) {
                let target = RouterCourier.Target.project(fields.name).targetID
                $0.decision.target = "new claude.ai project “\(fields.name)”"
                $0.decision.targetID = target
                $0.add(.sent(to: fields.name, text: proposal.message, original: proposal.message == job.text ? nil : job.text))
                // What you changed of the decider's proposal is a correction of it.
                let changed = fields.changes(from: first)
                if !changed.isEmpty {
                    $0.outcome = .corrected(from: "new claude.ai project “\(first.name)”",
                                            to: "new claude.ai project “\(fields.name)” (\(changed.joined(separator: ", ")) changed)")
                } else {
                    $0.outcome = .done
                }
            }
        }
        let ended = proposal.onEnd
        proposal.onEnd = { [weak self, weak store] in
            ended()
            guard let self, self.proposing.remove(id) != nil else { return }
            if !made {
                store?.updateDecision(id) {
                    $0.reply = "Dropped: nothing was sent."
                    $0.outcome = .done
                }
            }
            self.follow(id)
        }
        progress[id] = nil
        follow(id)
    }

    /// A claude.ai target goes to the engine, its pill over the composer taking over from the message's own. Nil: the target
    /// is not one.
    func courierHandoff(_ job: Job, to target: String) -> RouterCourier.Target? {
        guard let store, let courier = RouterCourier.Target(target) else { return nil }
        // The pills that address it at the start of your words aren't part of them.
        let words = Self.courierWords(job.text, pills: job.context.pills)
        let id = job.id
        Task { [weak store] in
            guard let store else { return }
            let intent = await store.routerCourier.send(words, to: courier)
            if intent > 0 { store.updateDecision(id) { $0.decision.courierIntent = intent } }
        }
        store.updateDecision(job.id) {
            // The target the flights read to leave the message's pill to the engine's (`RouterFlights.handedToCourier`).
            $0.decision.targetID = courier.targetID
            $0.add(.sent(to: RouterCourierPills.place(courier.project, store.routerCourier.threadTitle(courier) ?? courier.thread),
                         text: words, original: words == job.text ? nil : job.text))
            // A correction (a pick that wasn't the decider's) stays one.
            if $0.outcome == .pending { $0.outcome = .done }
        }
        return courier
    }

    /// Your words without the address pills they start with; as they are when nothing is left.
    nonisolated static func courierWords(_ text: String, pills: [Range<Int>]) -> String {
        let rest = (Addressing.withoutLeadingPills(text, pills) ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? text : rest
    }

    /// Haiku, fresh, for what needs judgment or tools; its reply is what the history shows.
    private func think(_ job: Job, _ intent: RouterRun.Intent) async throws {
        guard let store else { return }
        stage(job, "working")
        let input = store.routerRunContext(message: job.text, projects: job.context.projects, tagged: job.tools.tagged,
                                           excluding: job.id).text()
        let ticket = job.tools.ticket()
        let answer = try await effects.run(job.tools, intent, input)
        // Stopped while the run's output was drained: no reply is recorded.
        try Task.checkCancellation()
        try job.tools.live(ticket)
        let reply = answer.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = answer.done.trimmingCharacters(in: .whitespacesAndNewlines)
        store.updateDecision(job.id) {
            $0.reply = reply.isEmpty ? nil : reply
            $0.note = done.isEmpty ? nil : done
        }
    }

    // MARK: Replies to cards

    /// The answer a question card's form takes from a message that is exactly an option (or several, for a multiple choice):
    /// anything else is text for the session. Only a single question; a plan is never answered this way.
    static func formAnswers(_ form: PendingForm, message: String) -> [String: String]? {
        guard !form.isPlan, form.questions.count == 1, let q = form.questions.first else { return nil }
        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // The label as said (case aside) wins, its punctuation kept ("C#" vs "C"); only else the words alone ("sqlite."
        // for "SQLite"), and then only when they fit one option: two fitting ("C." for "C#" and "C") is text for the session.
        func option(_ text: String) -> String? {
            let ws = CharacterSet.whitespacesAndNewlines
            let exact = text.trimmingCharacters(in: ws).lowercased()
            let hits = q.options.filter { $0.label.trimmingCharacters(in: ws).lowercased() == exact }
            if hits.count == 1 { return hits[0].label }
            guard hits.isEmpty else { return nil }
            let t = text.trimmingCharacters(in: trim).lowercased()
            let loose = q.options.filter { $0.label.trimmingCharacters(in: trim).lowercased() == t }
            return loose.count == 1 ? loose[0].label : nil
        }
        if let one = option(said) { return [q.question: one] }
        guard q.multiSelect else { return nil }
        let parts = said.replacingOccurrences(of: " and ", with: ",").split(separator: ",").map(String.init)
        let labels = parts.compactMap(option)
        guard parts.count > 1, labels.count == parts.count else { return nil }
        return [q.question: FormBridge.joined(labels)]
    }

    /// Passes your words to a card's session: the form's answer when you gave one, else your words without their addressing,
    /// signed, through the gate.
    private func reply(_ job: Job, session: String, card: String?) async throws {
        guard let store else { return }
        // What the session would get, its addressing taken out ("@router no rush"), is what answers its form.
        let said = (try? Addressing.edit(job.text, pills: job.context.pills).text) ?? job.text
        let held = card.map { id in store.router.cards.filter { $0.id == id } } ?? []
        if held.count == 1, let c = held.first, let form = store.pendingForm(for: c) {
            // An answer is given only while the card still holds that very form (it may have moved on while it was read), and
            // at the write itself once more.
            let snapshot = FormSnapshot(card: c, form: form, store: store)
            if form.isPlan {
                // A plan is approved or sent back, never sent as text it stays pending under.
                stage(job, "reading your decision")
                let read = await Self.planDecision(form, message: said, ask: jev(job.tools))
                try Task.checkCancellation()
                // Jev couldn't be asked: nothing is read into your words, the plan stays waiting for you.
                guard let decision = read else {
                    note(job, .failed("Couldn't read your answer to “\(RouterDecision.clip(c.title, 40))” (Jev didn't answer): its plan is still waiting"),
                         session: session, card: c.id)
                    return
                }
                if snapshot.holds(store) {
                    stage(job, decision.approve ? "approving" : "sending it back")
                    _ = try await effects.answerPlan(job.tools, c.id, decision, snapshot)
                    note(job, .answered(card: c.title), session: session, card: c.id)
                    return
                }
            } else {
                var answers = Self.formAnswers(form, message: said)
                if answers == nil {
                    stage(job, "reading your answer")
                    answers = await Self.askFormAnswers(form, message: said, ask: jev(job.tools))
                    try Task.checkCancellation()
                }
                if let answers, snapshot.holds(store) {
                    stage(job, "answering")
                    _ = try await effects.answer(job.tools, c.id, answers, snapshot)
                    note(job, .answered(card: c.title), session: session, card: c.id)
                    return
                }
            }
            // The form moved on while it was read: nothing is answered on a read of another one, and the words go on as text.
        }
        stage(job, "preparing")
        let delivery = try await effects.prepare(job.tools, session)
        stage(job, "sending")
        // The cards open now, as they are: one that changes while this goes isn't addressed by it.
        let eligible = Dictionary(store.router.cards.filter(\.isOpen).map { ($0.id, store.cardRevisions[$0.id, default: 0]) },
                                  uniquingKeysWith: { a, _ in a })
        let before = store.claudeSessions[session]
        _ = try await effects.send(job.tools, delivery)
        note(job, .sent(to: delivery.to, text: delivery.body, original: delivery.rephrased ? delivery.original : nil),
             session: session, card: card)
        await delivered(job, delivery, session: session, turns: before?.completedTurns ?? 0, busy: before?.running ?? false)
        // Its turn cards are cleared by it; Jev reads it for the questions it left, and judges a question or plan it waits on.
        stage(job, "checking its cards")
        await store.judgeCards(session: session, message: job.text, eligible: eligible,
                               asker: job.tools.chooser.map(JevClient.asker(choosing:)), decision: job.id)
    }

    /// A send went: what it delivered, for a Cancel (`turns` and `busy`: the session as it was just before).
    private func delivered(_ job: Job, _ delivery: Delivery, session: String?, turns: Int, busy: Bool) async {
        guard let session, let header = RelayInbox.header(of: delivery.text) else { return }
        let at = Date()
        let abortable = await effects.abortable(header.target)
        store?.updateDecision(job.id) {
            $0.delivered = .init(session: session, cli: header.target, nonce: header.nonce, at: at, turns: turns, busy: busy,
                                 abortable: abortable)
        }
    }

    // MARK: Cancel

    /// Takes back what a reply sent: if Claude hadn't started on it, it never will; if it was working on it, its turn stops.
    /// Anything it already did stays done, and the message stays in the session's history. The entry says how it went; nil
    /// when there's nothing to take back, or it failed.
    @discardableResult
    func cancel(_ id: UUID) async -> RouterDecision.Cancelled? {
        guard let store, let entry = store.router.record(id), let sent = entry.delivered,
              sent.cancelled == nil, sent.abortable, !cancelling.contains(id) else { return nil }
        cancelling.insert(id)
        defer { cancelling.remove(id) }
        do {
            let how = try await effects.cancel(sent)
            store.updateDecision(id) {
                guard $0.delivered?.nonce == sent.nonce else { return }
                $0.delivered?.cancelled = how
                $0.add(.cancelled(how))
            }
            return how
        } catch {
            let first = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? "failed"
            store.updateDecision(id) { $0.add(.failed("couldn't cancel: " + RouterDecision.clip(first, 100))) }
            return nil
        }
    }

    /// Retries an uncertain guest delivery with its persisted signed payload and original nonce.
    func retryGuestDelivery(_ record: GuestRelayRecord) {
        guard let store, store.routerOn, let id = record.decisionID, let hostSessionID = record.hostSessionID,
              record.signedPayload != nil, progress[id] == nil,
              store.router.guestRelayDeliveries.contains(where: {
                  $0.decisionID == id && $0.nonce == record.nonce && ($0.state == .inFlight || $0.state == .unconfirmed)
              }) else { return }
        progress[id] = "reconciling guest delivery"
        tasks[id] = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer {
                self.progress[id] = nil
                self.tasks[id] = nil
                self.onFinish?(id)
            }
            do {
                _ = try await GuestRouterRuntime.shared.retry(record)
                let previous = store.claudeSessions[hostSessionID]
                store.updateDecision(id) { entry in
                    entry.done.removeAll { if case .failed = $0 { true } else { false } }
                    entry.add(.sent(to: hostSessionID, text: record.body ?? "", original: nil), session: hostSessionID)
                    entry.delivered = .init(session: hostSessionID, cli: record.sessionID, nonce: record.nonce,
                        at: record.createdAt, turns: previous?.completedTurns ?? 0, busy: previous?.running ?? false,
                        abortable: false)
                    entry.outcome = .done
                }
            } catch {
                let reason = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? "failed"
                store.updateDecision(id) { entry in
                    entry.done.removeAll { if case .failed(let text) = $0 { text.hasPrefix("retry: ") } else { false } }
                    entry.add(.failed("retry: " + RouterDecision.clip(reason, 100)))
                    entry.outcome = .done
                }
            }
        }
    }

    /// A wrong send to a claude.ai place: asked again with that place left out. What was sent there stays (claude.ai has no
    /// take-back); the place you pick gets the words, and the pick is a correction of where it went, with who decided it (the
    /// engine's intent keeps it too).
    func sendElsewhere(_ id: UUID) {
        guard let store, store.routerOn, progress[id] == nil, !askBacks.contains(where: { $0.id == id }),
              let entry = store.router.record(id), case .you(let text) = entry.trigger,
              let wrong = entry.decision.targetID, RouterCourier.Target(wrong) != nil else { return }
        var context = RouterContext(notTo: wrong)
        context.mentions = entry.mentions ?? []
        context.action = entry.actionSource
        if context.action != nil, !store.toolsLinked { return }
        store.updateDecision(id) { $0.outcome = .pending }
        let job = Job(id: id, text: text, context: context,
                      tools: makeTools(id, text, pills: [], mentions: context.mentions, action: context.action != nil))
        let places = Self.places(store, without: wrong)
        let ask = RouterProjectDecider.ask(places, confidence: 0, decider: .none)
        askBack(job, ask, suggestion: wrong, note: "Sent to \(describe(wrong, store: store)); where else should it go?")
    }

    /// Every claude.ai place but `wrong`: its project's latest threads first, then the projects.
    static func places(_ store: Store, without wrong: String) -> [RouterProjectDecision.Kind] {
        let gone = RouterCourier.Target(wrong)
        var out: [RouterProjectDecision.Kind] = []
        for place in RouterCourier.places(store) {
            if let gone, gone.project == place.name || gone.project == place.id {
                out += place.threads.prefix(2).filter { $0.id != gone.thread }.map { .project(place.name, thread: $0.id) }
            } else {
                out.append(.project(place.name, thread: nil))
            }
        }
        return out
    }

    /// Jev's questions: the stand-in, else the routing chooser of a run's tools, else TypeSafe with your key; through the
    /// gate (`JevGate`).
    private func jev(_ tools: RouterTools?) -> JevAsker? {
        store?.jevAsker(.routing, base: asker ?? tools?.chooser.map(JevClient.asker(choosing:)))
    }

    /// Whether a target can still be sent to: a claude.ai place the Board has, "New project…", or an intent.
    func eligible(_ target: String, store: Store) -> Bool {
        if let courier = RouterCourier.Target(target) { return RouterCourier.eligible(courier, store: store) }
        if target.hasPrefix("answer:") { return store.routerShownOpenCards.contains { $0.id == String(target.dropFirst(7)) } }
        return target == RouterAskBack.newProject || RouterRun.Intent(rawValue: target) != nil
    }

    /// The label a target stands for: reply (a card or a claude.ai place), a new project, or the intent.
    static func label(_ target: String) -> String {
        if target.hasPrefix("answer:") || RouterCourier.Target(target) != nil { return "reply" }
        return target
    }

    // MARK: Ask back

    /// "Where should this go?" with the decider's places first, then "New project…" and the Router's own answer.
    /// `suggestion`: what a pick corrects, when it isn't the decider's best guess (a wrong send asked again).
    func askBack(_ job: Job, _ decision: RouterProjectDecision, suggestion: String? = nil, note: String? = nil) {
        guard let store else { return }
        let unattended = job.context.action != nil
        var places: [RouterProjectDecision.Kind]
        var name: String?
        switch decision.kind {
        case .ask(let kinds): places = kinds
        case .newProject(let n): places = []; name = n
        default: places = [decision.kind]
        }
        // Too few to choose from: the other projects follow.
        if places.count < 3 {
            for p in Self.places(store, without: job.context.notTo ?? "") where !places.contains(p) && places.count < 4 { places.append(p) }
        }
        var options: [RouterAskBack.Option] = []
        var seen = Set<String>()
        for kind in places {
            guard let target = RouterProjectDecision(kind: kind, confidence: 0, decider: .none).target?.targetID,
                  target != job.context.notTo, options.count < 4,
                  let option = option(target, store: store), seen.insert(option.id).inserted else { continue }
            options.append(option)
        }
        if !unattended {
            options.append(.init(target: RouterAskBack.newProject, title: "New project…", detail: name.map { "“\($0)” on claude.ai" } ?? "on claude.ai"))
            if let answer = option(RouteLabel.changeFjord.rawValue, store: store) { options.append(answer) }
        }
        let guess = suggestion ?? options.first.map(\.target)
        let ask = RouterAskBack(id: job.id, message: job.text, context: job.context, options: options, suggestion: guess, at: Date(),
                                note: note, projectName: name)
        askBacks.append(ask)
        store.updateDecision(job.id) {
            $0.add(.asked(options.map(\.title)))
            if $0.decision.label == nil { $0.decision.label = "unclear" }
            if $0.decision.decider == nil, decision.decider != .none { $0.decision.decider = decision.decider.rawValue }
        }
        progress[job.id] = nil
        follow(job.id)
    }

    /// A target as a button.
    func option(_ target: String, store: Store) -> RouterAskBack.Option? {
        if let courier = RouterCourier.Target(target) { return RouterCourier.option(courier, store: store) }
        if target.hasPrefix("answer:") {
            guard let card = store.router.cards.first(where: { $0.id == String(target.dropFirst(7)) }),
                  RouterPage.shows(card, tasks: store.routerTasks) else { return nil }
            return .init(target: target, title: card.title,
                         detail: "\(card.kind.label) · \(store.routerSessionProject(card.sessionID).name)")
        }
        switch target {
        case RouterAskBack.newProject: return .init(target: target, title: "New project…", detail: "on claude.ai")
        case "change_fjord": return .init(target: target, title: "Answer here", detail: "The Router answers, or changes Fjord")
        case "question": return .init(target: target, title: "Answer from what Fjord knows", detail: "A question about now")
        default: return nil
        }
    }

    /// A target in words, for the log ("thread “Fix the login” in claude.ai project lcu").
    func describe(_ target: String, store: Store) -> String {
        if let courier = RouterCourier.Target(target) {
            let title = RouterCourier.option(courier, store: store)?.title ?? courier.thread ?? courier.project
            return courier.thread == nil ? "claude.ai project “\(courier.project)”" : "thread “\(title)” in claude.ai project \(courier.project)"
        }
        guard let option = option(target, store: store) else { return target }
        if target.hasPrefix("answer:") { return "card “\(option.title)” (\(option.detail))" }
        return option.title.lowercased()
    }

    /// Everything the "Something else…" picker offers: the claude.ai projects and their latest threads.
    func pickerOptions() -> [RouterAskBack.Option] {
        guard let store else { return [] }
        var out: [RouterAskBack.Option] = []
        for place in RouterCourier.places(store).prefix(30) {
            if let o = option(RouterCourier.Target.project(place.name).targetID, store: store) { out.append(o) }
            for t in place.threads.prefix(3) {
                if let o = option(RouterCourier.Target.thread(project: place.name, thread: t.id).targetID, store: store) { out.append(o) }
            }
        }
        return out
    }
}

// MARK: - A run's live state, coalesced

/// Takes a run's live state from the reader's thread and hands it to the main actor at most ten times a second, the newest
/// each time: the reply streams in dozens of small pieces, which the page would otherwise redraw for.
final class LiveFeed: @unchecked Sendable {
    static let interval: TimeInterval = 0.1

    private let lock = NSLock()
    private var latest: RouterRunLive?
    private var scheduled = false
    private var lastShown = Date.distantPast
    private let deliver: @MainActor (RouterRunLive) -> Void

    init(_ deliver: @escaping @MainActor (RouterRunLive) -> Void) { self.deliver = deliver }

    func push(_ live: RouterRunLive) {
        let wait: TimeInterval? = lock.withLock {
            latest = live
            guard !scheduled else { return nil }
            scheduled = true
            return max(0, Self.interval - Date().timeIntervalSince(lastShown))
        }
        guard let wait else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            let next: RouterRunLive? = lock.withLock {
                scheduled = false
                lastShown = Date()
                defer { latest = nil }
                return latest
            }
            if let next { MainActor.assumeIsolated { deliver(next) } }
        }
    }
}

// MARK: - The real effects

extension RouterDispatcher.Effects {
    /// Nothing is available: before the dispatcher has set up its own.
    static var unavailable: Self {
        let no = RouterTools.Failure("The Router isn't ready")
        return Self(decide: { _, _, _, _ in throw no }, prepare: { _, _ in throw no }, send: { _, _ in throw no },
                    answer: { _, _, _, _ in throw no }, run: { _, _, _ in throw no })
    }

    @MainActor
    static func live(_ dispatcher: RouterDispatcher) -> Self {
        func store(_ d: RouterDispatcher) throws -> Store {
            guard let store = d.storeForEffects else { throw RouterTools.Failure("Fjord isn't ready") }
            return store
        }
        func object(_ json: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        }
        return Self(
            decide: { [weak dispatcher] tools, message, unattended, stage in
                guard let dispatcher else { throw RouterTools.Failure("Fjord isn't ready") }
                let store = try store(dispatcher)
                let link = store.routerCourierLink
                let board = await link.board()
                let read = link.readLocal
                let local = await Task.detached { read() }.value
                let context = RouterProjectContext.gather(board: board, local: local, store: store)
                var decider = RouterProjectDecider.app(store)
                // An action's message is read by Jev only as an inbox action may be (`JevUse.actions`): it holds what GitHub wrote.
                decider.jev = unattended ? store.jevAsker(.actions, base: dispatcher.asker) : store.jevAsker(.routing, base: dispatcher.asker)
                return try await decider.decide(message, in: context, stage: stage)
            },
            prepare: { [weak dispatcher] tools, session in
                guard let dispatcher else { throw RouterTools.Failure("Fjord isn't ready") }
                let store = try store(dispatcher)
                let answer = object(try await tools.prepare(store, session: session, ticket: tools.ticket()))
                guard let to = answer["to"] as? String, let ready = tools.prepared[to] else { throw RouterTools.Failure("Not prepared") }
                return .init(to: to, text: ready.text, body: ready.body ?? ready.text, original: ready.original,
                             rephrased: ready.rephrased, session: session)
            },
            send: { [weak dispatcher] tools, delivery in
                guard let dispatcher else { throw RouterTools.Failure("Fjord isn't ready") }
                let store = try store(dispatcher)
                return try await RouterSender.send(store: store, to: delivery.to, text: delivery.text, tools: tools,
                                                   session: delivery.session, kind: .message,
                                                   decisionID: tools.decision, hostSessionID: delivery.session, body: delivery.body)
            },
            answer: { [weak dispatcher] tools, card, answers, snapshot in
                guard let dispatcher else { throw RouterTools.Failure("Fjord isn't ready") }
                let store = try store(dispatcher)
                guard snapshot.holds(store) else { throw RouterTools.Failure(FormSnapshot.changedWords) }
                guard let c = store.router.cards.first(where: { $0.id == card }), c.isOpen,
                      let form = store.guestPendingForm(for: c)?.form ?? store.pendingForm(for: c), !form.isPlan else {
                    throw RouterTools.Failure("That question isn't waiting anymore")
                }
                let ticket = tools.ticket()
                try tools.live(ticket)
                // The write itself checks the snapshot once more, right before it.
                switch await store.answerForm(form, answers, card: card, snapshot: snapshot,
                                              alsoValid: { (try? tools.live(ticket)) != nil }) {
                case .success:
                    return "Answered “\(c.title)”: " + form.questions.map { "\($0.question) = \(answers[$0.question] ?? "")" }.joined(separator: "; ")
                case .failure(let error): throw error
                }
            },
            run: { [weak dispatcher] tools, intent, input in
                guard let dispatcher else { throw RouterTools.Failure("Fjord isn't ready") }
                let store = try store(dispatcher)
                guard let binary = dispatcher.claudePath() else { throw RouterTools.Failure("Claude Code wasn't found") }
                return try await RouterRun.run(intent, input: input, tools: tools, store: store, binary: binary)
            },
            reviser: { [weak dispatcher] in
                guard let store = dispatcher?.storeForEffects else { return RouterProjectFakeReviser(failure: "Fjord isn't ready") }
                return RouterProjectModelReviser.app(store)
            },
            abortable: { [weak dispatcher] cli in
                guard let store = dispatcher?.storeForEffects else { return false }
                if GuestRouterRuntime.shared.location(forGuestSessionID: cli) != nil {
                    return GuestRouterRuntime.shared.supportsAbort(forGuestSessionID: cli)
                }
                return await store.supportsAbort(cli)
            },
            cancel: { [weak dispatcher] sent in
                guard let dispatcher else { throw RouterTools.Failure("Fjord isn't ready") }
                return try await store(dispatcher).cancelDelivery(sent)
            },
            answerPlan: { [weak dispatcher] tools, card, decision, snapshot in
                guard let dispatcher else { throw RouterTools.Failure("Fjord isn't ready") }
                let store = try store(dispatcher)
                try tools.live(tools.ticket())
                guard snapshot.holds(store) else { throw RouterTools.Failure(FormSnapshot.changedWords) }
                guard let c = store.router.cards.first(where: { $0.id == card }), c.isOpen,
                      let form = store.guestPendingForm(for: c)?.form ?? store.pendingForm(for: c), form.isPlan else {
                    throw RouterTools.Failure("That plan isn't waiting anymore")
                }
                switch await store.answerPlan(form, decision, card: card, snapshot: snapshot) {
                case .success: return decision.approve ? "Approved “\(c.title)”" : "Sent “\(c.title)” back"
                case .failure(let error): throw error
                }
            }
        )
    }
}

extension RouterDispatcher {
    fileprivate var storeForEffects: Store? { store }
}
