import Foundation
import Observation

// What you type (docs/design/router-redesign.md, "How a message flows"). Each message is a run of its own (several can be in
// flight), one entry of the decision log, its stage shown on its pill over the composer. Where it goes is decided once, among
// T3's threads: a reply armed on a thread goes to that thread; a thread you tagged goes there with no model; anything else is
// for the decider (`RouterProjectDecider`: Sonnet on the board, Jev without a key), whose decision is acted on as it is: a
// thread gets the words (a waiting request is answered by its own rules first), a new thread starts with them, the Router
// answers here, or you're asked where it goes. Nothing is sent when it isn't sure.

/// What a message of yours comes with besides its text: the thread you're replying to (it is the target), the T3
/// place a Retry goes to again or one waved off, and its pills.
struct RouterContext: Equatable {
    /// The thread it replies to.
    var replyTo: BriefTarget?
    /// The local projects the message tags (their folders): context for an answer, and the folder a new project may use.
    var projects: [String]
    /// A T3 target (`RouteTarget`) it goes to: the place you confirmed.
    var target: String?
    /// A target you dismissed (or a wrong send's, on Send elsewhere): the message never goes there without asking you.
    var notTo: String?
    /// Where the address pills are in the message (character offsets of each "@name"): only these are ever taken out of your
    /// words, never words that happen to match a project's name.
    var pills: [Range<Int>]
    /// Every pill of the message, what it points to and where (`RouterPointer`; `tag` sets this, `pills` and `projects`
    /// together): a T3 thread tagged is where it goes, a notification or a category goes with it as a fenced block
    /// (`RouterPointers.context`).
    var mentions: [RouterMention] = []
    /// A category's "Then" sends it for a thing (`ActionMessage`): unattended, it goes only to a T3 thread or project
    /// (never the Router's own runs: an incoming PR must never change settings), and when where isn't clear it waits for your
    /// pick, with no fallback.
    var action: RouterActionSource?
    /// Your words wait for the turn under way instead of steering it (⌥Return). An action's message never steers.
    var queue = false

    init(replyTo: BriefTarget? = nil, projects: [String] = [], target: String? = nil, notTo: String? = nil, pills: [Range<Int>] = []) {
        self.replyTo = replyTo
        self.projects = projects
        self.target = target
        self.notTo = notTo
        self.pills = pills
    }
}

// MARK: - The ask-back

/// "Where should this go?": a message waiting for you to say where. Nothing is sent until you pick.
struct RouterAskBack: Identifiable, Equatable {
    /// "New thread in <project>": a thread is started in a T3 project (`target` is this prefix and the project's id), and
    /// "New thread in <folder>": the folder has no T3 project yet, so one is made first (the prefix and the folder's path).
    static let newThread = "new_thread:"
    static let newFolder = "new_folder:"

    /// A target you can pick: a T3 thread or a new thread in a project (`RouteTarget`), a folder, or `change_fjord` (the
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
}

// MARK: - Dispatcher

@Observable @MainActor final class RouterDispatcher {
    /// Where a message goes without asking a model, or that it needs the decider.
    enum Plan: Equatable {
        /// A thread of this Mac (or a remote computer's Desktop session) you replied to: its session id.
        case reply(project: String, thread: String, session: String)
        /// A T3 thread you tagged, or a Retry's confirmed place.
        case send(String)
        /// Wholly for the Router ("@router what needs me?").
        case answer
        /// A reply to a thread that can't be reached now: refused, never guessed elsewhere.
        case unreachable(String)
        case decide
    }

    /// A message ready to go to a thread: the T3 thread, what T3 gets (`ThreadMessage`) and what the entry shows of it.
    struct Delivery: Equatable {
        /// T3's thread id.
        var thread: String
        var message: ThreadMessage
        /// Your words as the thread reads them (addressing taken out), and as you wrote them.
        var body: String
        var original: String
        var rephrased: Bool
        var mode: ThreadSendMode
        /// An action's message: it queues behind a turn under way, never steering it.
        var unattended: Bool
    }

    /// Everything a run does outside Fjord's own state, so a test stands in for each. The defaults are the real ones.
    struct Effects {
        /// Where a message goes among T3's threads (`RouterProjectDecider`), its stage told as it goes. `unattended`:
        /// an action's message, read by Jev only as an inbox action may be.
        var decide: @MainActor (RouterTools, _ message: String, _ unattended: Bool,
                                _ stage: @escaping @MainActor (RouterProjectDecider.Stage) -> Void) async throws -> RouterProjectDecision
        /// The `message.dispatch` to the thread, through the gate: what T3 took and what it did with it.
        var send: @MainActor (RouterTools, Delivery) async throws -> RouterDecision.Delivered
        /// A question, permission or plan answered for a thread: what was done.
        /// Only while the thread still holds the request it was judged on (`RequestSnapshot`).
        var answer: @MainActor (RouterTools, BriefTarget, RequestAnswer, RequestSnapshot) async throws -> String
        /// A Haiku run for an intent, given the context it starts from.
        var run: @MainActor (RouterTools, RouterRun.Intent, _ input: String) async throws -> RouterRun.Answer
    }

    /// What a message to a thread's waiting request does: answers to its questions, a plan decided, or a permission declined
    /// with your words.
    enum RequestAnswer: Sendable { case answers([String: T3Answer]), plan(PlanDecision), decline(String) }

    /// Asks waiting for a pick, oldest first.
    private(set) var askBacks: [RouterAskBack] = []
    /// How far each run under way is, by its entry in the log ("finding where it goes", "sending"…).
    private(set) var progress: [UUID: String] = [:]
    /// What each Haiku run under way has shown so far: the reply as far as it is written, what it thought, the tools it
    /// called. Updated at most ten times a second; gone when the run ends.
    private(set) var live: [UUID: RouterRunLive] = [:]
    /// A run of yours is under way: the composer shows Stop. An action's message being placed, or waiting its turn, is the
    /// inbox's, in the background (`actionRuns`): you send meanwhile, and Stop leaves it be.
    var isBusy: Bool { progress.keys.contains { !actionRuns.contains($0) } }
    /// What an action's message waiting its turn says on its line.
    static let waitingTurn = "waiting its turn"
    /// The entries of actions' messages under way or waiting their turn (`submit`, `launch`), until they end.
    @ObservationIgnored private var actionRuns: Set<UUID> = []

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
    /// Every decision and what became of it, for the benchmark (nil in a test or a demo).
    @ObservationIgnored var decisionLog: DeciderLog?
    /// What you last said in each thread, kept by thread@lastActivity.
    @ObservationIgnored let youSaid = YouSaidCache()
    /// Sonnet's client; tests don't reach it (they stand in `Effects.decide`).
    @ObservationIgnored lazy var anthropic = RouterProjectDecider.makeClient()

    init(store: Store) {
        self.store = store
        // A test run only has the folder it stood in (`routerPaths`); the user's own is never reached from here.
        decisionLog = DeciderLog.live(UnderTest.isRunning ? store.routerPaths : store.routerFiles)
        effects = Effects.unavailable
        effects = Effects.live(self)
        // An entry whose ask-back card is still up is not pruned from the history (its pick needs the record).
        store.decisionsInUse = { [weak self] in Set(self?.askBacks.map(\.id) ?? []) }
    }

    struct Job {
        var id: UUID
        var text: String
        var context: RouterContext
        var tools: RouterTools
    }

    /// A demo or a shot: an ask waiting for you and runs shown under way, with nothing behind them.
    func preview(ask: RouterAskBack? = nil, progress runs: [UUID: String] = [:], live shown: [UUID: RouterRunLive] = [:]) {
        askBacks = ask.map { [$0] } ?? []
        progress = runs
        live = shown
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
                                   links: .init(threads: context.replyTo.map { [$0.key] } ?? []))
        entry.mentions = context.mentions.isEmpty ? nil : context.mentions
        entry.fromAction = context.action?.origin
        let id = store.logDecision(entry)
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
        // An action's message goes only to a T3 place, and only while Triage and the Router are both on.
        if ask.context.action != nil, !store.toolsLinked || (RouteTarget(target) == nil && !target.hasPrefix(RouterAskBack.newFolder)) { return false }
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
            }
            // A place you picked, or corrected to, is yours.
            $0.decision.confirmed = true
        }
        let tools = makeTools(id, ask.message, pills: ask.context.pills, mentions: ask.context.mentions,
                              action: ask.context.action != nil)
        let job = Job(id: id, text: ask.message, context: ask.context, tools: tools)
        decisionLog?.outcome(id: id, "picked", target: target, guess: !corrected)
        launch(job, stage: "starting") { [self] job in try await route(job, to: target) }
        follow(id)
    }

    /// You dismissed an ask-back: nothing is sent.
    /// `reason`: why it goes when you didn't dismiss it (Stop, a switch turned off): an action's entry says it as its last
    /// line, so its run fails with why.
    func dismiss(_ id: UUID, reason: String? = nil) {
        guard let store, let i = askBacks.firstIndex(where: { $0.id == id }) else { return }
        let ask = askBacks.remove(at: i)
        decisionLog?.outcome(id: id, "dismissed")
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
        live[job.id] = nil
        tasks[job.id] = nil
        runTools[job.id] = nil
        // Waiting for your pick is not over; anything else not settled is done.
        if !askBacks.contains(where: { $0.id == job.id }) {
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

    func note(_ job: Job, _ item: RouterDecision.Done, session: String? = nil, thread: BriefTarget? = nil) {
        store?.updateDecision(job.id) { $0.add(item, session: session, thread: thread) }
    }

    // MARK: Routing

    func execute(_ job: Job) async throws {
        guard let store else { return }
        switch Self.plan(text: job.text, context: job.context, store: store) {
        case .reply(let project, let thread, let session):
            chosen(job)
            try await reply(job, to: BriefTarget(project: project, thread: thread), session: session)
        case .send(let target):
            // A place you tagged (or a Retry's): yours, as a pick is.
            confirm(job, target)
            try await route(job, to: target)
        case .answer:
            try await think(job, .question)
        case .unreachable(let why):
            chosen(job)
            throw RouterTools.Failure(why)
        case .decide:
            try await decideAndAct(job)
        }
    }

    /// Where it goes is yours (the thread you replied to).
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

    /// Where a message goes without a model: the thread a reply is armed on (refused when T3 no longer lists it), a Retry's
    /// confirmed place, or the one thread the message tags (and nothing else that says where). Words wholly for the Router are
    /// its own. Anything else is decided.
    static func plan(text: String, context: RouterContext, store: Store) -> Plan {
        // An action's message is never the Router's own, nor a reply: it goes to a T3 place.
        let unattended = context.action != nil
        if !unattended, forRouter(text, pills: context.pills) { return .answer }
        if !unattended, let t = context.replyTo {
            if let session = store.routerBriefs.desktopSession(t, store: store) {
                return .reply(project: t.project, thread: t.thread, session: session)
            }
            // Your reply is for that thread alone: it doesn't go to another place a model would pick.
            return .unreachable("Not sent: that thread isn't in T3 anymore")
        }
        if !unattended, let target = context.target, let place = RouteTarget(target), place.eligible(store: store) {
            return .send(place.targetID)
        }
        if let only = threadTag(context, store: store) { return .send(only) }
        return .decide
    }

    /// The one thread the message tags, when it tags no other and no reply or Retry fixes it: nil otherwise, or when T3 no
    /// longer lists it.
    static func threadTag(_ context: RouterContext, store: Store) -> String? {
        let tagged = context.threadTargets
        guard tagged.count == 1, context.replyTo == nil, context.target == nil,
              let target = RouteTarget(tagged[0]), target.eligible(store: store) else { return nil }
        return target.targetID
    }

    /// Everything in the message is for the Router (`@router`, its asides): nothing of it would go on.
    static func forRouter(_ text: String, pills: [Range<Int>]) -> Bool {
        guard RouterTools.hasRouterAside(text) else { return false }
        do { _ = try Addressing.edit(text, pills: pills) } catch { return error is Addressing.NothingLeft }
        return false
    }

    /// The decider's decision, acted on: a thread gets the words (steering its run when one is under way), a new thread starts
    /// with them, the Router answers, or you're asked. Every decision is logged for the benchmark (`DeciderLog`).
    func decideAndAct(_ job: Job) async throws {
        guard let store else { return }
        let unattended = job.context.action != nil
        stage(job, RouterProjectDecider.Stage.sonnet.words)
        let decision = try await effects.decide(job.tools, job.text, unattended) { [weak self] in self?.stage(job, $0.words) }
        try Task.checkCancellation()
        try linked(job.context)
        store.updateDecision(job.id) {
            $0.decision.decider = decision.decider.rawValue
            $0.decision.confidence = decision.confidence
            if !decision.reason.isEmpty { $0.note = RouterDecision.clip(decision.reason, 200) }
        }
        var sent = "asked"
        defer {
            decisionLog?.decision(id: job.id, message: job.text, decision: decision, board: decision.boardText,
                                  candidates: (decision.board?.candidates ?? []).map { ($0.id, $0.key) }, sent: sent)
        }
        switch decision.kind {
        case .thread, .newThread:
            guard let target = decision.target?.targetID, target != job.context.notTo, eligible(target, store: store) else {
                return askBack(job, decision)
            }
            sent = "sent"
            store.updateDecision(job.id) {
                $0.decision.label = Self.label(target)
                $0.decision.target = describe(target, store: store)
                $0.decision.targetID = target
            }
            try await route(job, to: target)
        case .answer:
            guard !unattended else { return askBack(job, decision) }
            sent = "answered"
            store.updateDecision(job.id) { $0.decision.label = RouteLabel.changeFjord.rawValue }
            try await think(job, .changeFjord)
        case .ask:
            askBack(job, decision)
        }
    }

    /// Acts on a target: a thread gets the words (a waiting request is answered deterministically first, see `reply`), a new
    /// thread starts with them, an intent is a run.
    func route(_ job: Job, to target: String) async throws {
        try linked(job.context)
        if target.hasPrefix(RouterAskBack.newThread) || target.hasPrefix(RouterAskBack.newFolder) {
            return try await launchNewThread(job, target: target)
        }
        if let place = RouteTarget(target) {
            guard let store, let thread = place.briefTarget(store: store) else {
                throw RouterTools.Failure("That thread isn't in T3 anymore: nothing was sent")
            }
            return try await reply(job, to: thread, session: thread.thread)
        }
        if let intent = RouterRun.Intent(rawValue: target) { return try await think(job, intent) }
        throw RouterTools.Failure("Nowhere to send that")
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

    // MARK: Replies to threads

    /// Passes your words to a thread: the form's answer when you gave one, else your words without their addressing, as
    /// one `message.dispatch` (steering the turn under way, or queued behind it).
    private func reply(_ job: Job, to t: BriefTarget, session: String) async throws {
        guard let store else { return }
        // What the session would get, its addressing taken out ("@router no rush"), is what answers its form.
        let said = (try? Addressing.edit(job.text, pills: job.context.pills).text) ?? job.text
        let title = store.routerBriefs.title(t)
        if let request = store.heldRequest(t), request.live {
            // An answer is given only while the thread still holds that very request (it may have moved on while it was
            // read), and at the send itself once more.
            let snapshot = RequestSnapshot(target: t, request: request)
            switch request.body {
            case .plan:
                // A plan is approved or sent back, never sent as text it stays pending under. Never a yes without Jev's.
                stage(job, "reading your decision")
                let read = await Self.planDecision(request, message: said, ask: jev(job.tools))
                try Task.checkCancellation()
                let decision = read ?? PlanDecision(approve: false, feedback: said)
                if snapshot.holds(store) {
                    stage(job, decision.approve ? "approving" : "sending it back")
                    _ = try await effects.answer(job.tools, t, .plan(decision), snapshot)
                    note(job, .answered(thread: title), session: session, thread: t)
                    return
                }
            case .approval:
                // Typed words are never a yes: they decline, and the words go to the agent as the reason.
                if snapshot.holds(store), request.supportsFeedback {
                    stage(job, "declining")
                    _ = try await effects.answer(job.tools, t, .decline(said), snapshot)
                    note(job, .answered(thread: title), session: session, thread: t)
                    return
                }
            case .question(let questions):
                stage(job, "reading your answer")
                var answers = await Self.askFormAnswers(request, message: said, ask: jev(job.tools))
                try Task.checkCancellation()
                // Not one of its options: the words themselves, where the one question takes a custom answer.
                if answers == nil, questions.count == 1, questions[0].allowCustomAnswer, !questions[0].multiSelect, !said.isEmpty {
                    answers = [questions[0].id: .one(said)]
                }
                if let answers, snapshot.holds(store) {
                    stage(job, "answering")
                    _ = try await effects.answer(job.tools, t, .answers(answers), snapshot)
                    note(job, .answered(thread: title), session: session, thread: t)
                    return
                }
            }
            // The request moved on while it was read: nothing is answered on a read of another one, and the words go on as text.
        }
        stage(job, "sending")
        let words = try RouterPointers.threadMessage(job.text, pills: job.context.pills, mentions: job.context.mentions, store: store)
        let delivery = Delivery(thread: session, message: ThreadMessage(text: words.text, records: words.records),
                                body: words.words, original: words.original, rephrased: words.rephrased,
                                mode: job.context.queue ? .queue : .steer, unattended: job.context.action != nil)
        let sent = try await effects.send(job.tools, delivery)
        note(job, .sent(to: title, text: delivery.body, original: delivery.rephrased ? delivery.original : nil),
             session: session, thread: t)
        store.updateDecision(job.id) {
            $0.delivered = sent
            if let why = sent.note { $0.note = why }
        }
    }

    /// A wrong send to a thread: asked again with that place left out. What was sent there stays (take it back from its entry
    /// while it waits, or stop its run); the place you pick gets the words, and the pick is a correction of where it went, with
    /// who decided it.
    func sendElsewhere(_ id: UUID) {
        guard canSendElsewhere(id), let store, let entry = store.router.record(id), case .you(let text) = entry.trigger,
              let wrong = entry.decision.targetID else { return }
        var context = RouterContext(notTo: wrong)
        context.mentions = entry.mentions ?? []
        context.action = entry.actionSource
        if context.action != nil, !store.toolsLinked { return }
        store.updateDecision(id) { $0.outcome = .pending }
        decisionLog?.outcome(id: id, "sent_elsewhere", target: wrong)
        let job = Job(id: id, text: text, context: context,
                      tools: makeTools(id, text, pills: [], mentions: context.mentions, action: context.action != nil))
        let places = Self.places(store, without: wrong)
        let ask = RouterProjectDecider.ask(places, confidence: 0, decider: .none)
        askBack(job, ask, suggestion: wrong, note: "Sent to \(describe(wrong, store: store)); where else should it go?")
    }

    /// Whether the message went to a T3 thread and is settled: it can be asked again elsewhere.
    func canSendElsewhere(_ id: UUID?) -> Bool {
        guard let id, let store, store.routerOn, progress[id] == nil, !askBacks.contains(where: { $0.id == id }),
              let entry = store.router.record(id), case .you = entry.trigger,
              let wrong = entry.decision.targetID else { return false }
        return RouteTarget(wrong) != nil
    }

    /// Every place but `wrong`: the board's threads, most recent first, then a new thread in each project.
    static func places(_ store: Store, without wrong: String) -> [RouterProjectDecision.Kind] {
        let gone = RouteTarget(wrong)
        let board = store.deciderBoard()
        var out: [RouterProjectDecision.Kind] = board.candidates.sorted { $0.minutesIdle < $1.minutesIdle }
            .filter { $0.key != gone?.threadID }.map { .thread($0.key) }
        out += board.projects.map { .newThread(project: board.projectID($0)) }
        return out
    }

    /// Jev's questions: the stand-in, else the routing chooser of a run's tools, else TypeSafe with your key; through the
    /// gate (`JevGate`).
    private func jev(_ tools: RouterTools?) -> JevAsker? {
        store?.jevAsker(.routing, base: asker ?? tools?.chooser.map(JevClient.asker(choosing:)))
    }

    /// Whether a target can still be sent to: a thread or project T3 has, a folder to start a project in, or an intent.
    func eligible(_ target: String, store: Store) -> Bool {
        if let place = RouteTarget(target) { return place.eligible(store: store) }
        if target.hasPrefix(RouterAskBack.newFolder) { return true }
        return RouterRun.Intent(rawValue: target) != nil
    }

    /// The label a target stands for: reply (a thread), a new thread, or the intent.
    static func label(_ target: String) -> String {
        switch RouteTarget(target) {
        case .thread?: return "reply"
        case .newThread?: return "new_thread"
        case nil: return target
        }
    }

    // MARK: Ask back

    /// "Where should this go?" with the decider's places first, then the Router's own answer.
    /// `suggestion`: what a pick corrects, when it isn't the decider's best guess (a wrong send asked again).
    func askBack(_ job: Job, _ decision: RouterProjectDecision, suggestion: String? = nil, note: String? = nil) {
        guard let store else { return }
        let unattended = job.context.action != nil
        var places: [RouterProjectDecision.Kind]
        switch decision.kind {
        case .ask(let kinds): places = kinds
        default: places = [decision.kind]
        }
        // Too few to choose from: the other places follow.
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
        // A new thread in the T3 project of each local folder the message tags, or in the folder itself when T3 has none.
        for path in job.context.projects where options.count < 6 {
            let target = store.t3Project(forFolder: path).map { RouterAskBack.newThread + $0.id } ?? RouterAskBack.newFolder + path
            if let option = option(target, store: store), seen.insert(option.id).inserted { options.append(option) }
        }
        if !unattended {
            if let answer = option(RouteLabel.changeFjord.rawValue, store: store) { options.append(answer) }
        }
        let guess = suggestion ?? options.first.map(\.target)
        let ask = RouterAskBack(id: job.id, message: job.text, context: job.context, options: options, suggestion: guess, at: Date(),
                                note: note)
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
        if let place = RouteTarget(target) { return place.option(store: store) }
        switch target {
        case _ where target.hasPrefix(RouterAskBack.newFolder):
            let path = String(target.dropFirst(RouterAskBack.newFolder.count))
            return .init(target: target, title: "New thread in \(ThreadLauncher.projectTitle(root: path))", detail: "makes a T3 project of the folder")
        case "change_fjord": return .init(target: target, title: "Answer here", detail: "The Router answers, or changes Fjord")
        case "question": return .init(target: target, title: "Answer from what Fjord knows", detail: "A question about now")
        default: return nil
        }
    }

    /// A target in words, for the log ("thread “Fix the login” in fjord").
    func describe(_ target: String, store: Store) -> String {
        if let place = RouteTarget(target) { return place.describe(store: store) }
        guard let option = option(target, store: store) else { return target }
        return option.title.lowercased()
    }

    /// Everything the "Something else…" picker offers: the board's threads and a new thread in each project.
    func pickerOptions() -> [RouterAskBack.Option] {
        guard let store else { return [] }
        return Self.places(store, without: "").prefix(30).compactMap { kind in
            RouterProjectDecision(kind: kind, confidence: 0, decider: .none).target.flatMap { option($0.targetID, store: store) }
        }
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
        return Self(decide: { _, _, _, _ in throw no }, send: { _, _ in throw no },
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
                // The board, then what you last said in each candidate that isn't known, then the board again with it.
                let youSaid = await store.youSaidReads(for: store.deciderBoard(), cache: dispatcher.youSaid)
                let board = store.deciderBoard(youSaid: youSaid)
                var decider = RouterProjectDecider.app(store, client: dispatcher.anthropic)
                // An action's message is read by Jev only as an inbox action may be (`JevUse.actions`): it holds what GitHub wrote.
                decider.jev = unattended ? store.jevAsker(.actions, base: dispatcher.asker) : store.jevAsker(.routing, base: dispatcher.asker)
                var decision = try await decider.decide(message, in: board, tagged: tools.tagged, stage: stage)
                decision.board = board
                decision.boardText = board.render()
                return decision
            },
            send: { [weak dispatcher] tools, delivery in
                guard let dispatcher else { throw RouterTools.Failure("Fjord isn't ready") }
                let store = try store(dispatcher)
                let ticket = tools.ticket()
                return try await store.sendToThread(delivery.thread, delivery.message, mode: delivery.mode,
                                                    unattended: delivery.unattended) {
                    do { try tools.live(ticket) } catch { return error.localizedDescription }
                    return tools.deliveryCheck?()
                }
            },
            answer: { [weak dispatcher] tools, target, answer, snapshot in
                guard let dispatcher else { throw RouterTools.Failure("Fjord isn't ready") }
                let store = try store(dispatcher)
                try tools.live(tools.ticket())
                guard snapshot.holds(store) else { throw RouterTools.Failure(RequestSnapshot.changedWords) }
                guard let request = store.heldRequest(target) else { throw RouterTools.Failure("That isn't waiting anymore") }
                let title = store.routerBriefs.title(target)
                let ticket = tools.ticket()
                let valid: @MainActor () -> Bool = { (try? tools.live(ticket)) != nil }
                switch answer {
                case .answers(let answers):
                    switch await store.answerQuestion(request, answers, target: target, snapshot: snapshot, alsoValid: valid) {
                    case .success:
                        return "Answered “\(title)”: " + request.questions.map { q in
                            "\(q.question) = " + (answers[q.id].map { a in switch a { case .one(let v): v; case .many(let m): m.joined(separator: ", ") } } ?? "")
                        }.joined(separator: "; ")
                    case .failure(let error): throw error
                    }
                case .plan(let decision):
                    let result = decision.approve
                        ? await store.implementPlan(request, mode: .approvalRequired, target: target, snapshot: snapshot)
                        : await store.sendBackPlan(request, words: decision.feedback ?? "", target: target, snapshot: snapshot)
                    switch result {
                    case .success: return decision.approve ? "Approved “\(title)”" : "Sent “\(title)” back"
                    case .failure(let error): throw error
                    }
                case .decline(let words):
                    switch await store.answerPermission(request, .decline, feedback: words, target: target, snapshot: snapshot, alsoValid: valid) {
                    case .success: return "Declined “\(title)”'s permission with your words"
                    case .failure(let error): throw error
                    }
                }
            },
            run: { [weak dispatcher] tools, intent, input in
                guard let dispatcher else { throw RouterTools.Failure("Fjord isn't ready") }
                let store = try store(dispatcher)
                guard let binary = dispatcher.claudePath() else { throw RouterTools.Failure("Claude Code wasn't found") }
                return try await RouterRun.run(intent, input: input, tools: tools, store: store, binary: binary)
            }
        )
    }
}

extension RouterDispatcher {
    fileprivate var storeForEffects: Store? { store }
}
