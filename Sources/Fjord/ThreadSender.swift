import Foundation

// Your words to a T3 thread, and changing your mind about them (docs/design/t3-port-plan.md, steps 9 and 10).
//
// One `message.dispatch` per thread, with a `commandId` of its own made once: a retry reuses it, so T3's receipts keep the
// message from going twice. T3 stamps the message as the user's, so there is nothing to sign or carry. It went when the
// dispatch answers `{sequence}`; whether it started a run, steered the one under way or waits behind it is read from the
// thread's projection (`Store.delivery`), never waited for.

/// What a send asks of a thread that is running.
enum ThreadSendMode: String, Codable, Equatable, Sendable {
    /// Into the turn under way. The default for your own words.
    case steer
    /// After the turn under way (⌥Return). What an unattended message always asks.
    case queue
}

/// What a send did with the thread, as far as Fjord can tell before T3 answers.
enum ThreadSendOutcome: String, Codable, Equatable, Sendable {
    /// The thread was idle: the message starts a run.
    case started
    /// Into the run under way.
    case steered
    /// Behind the run under way.
    case queued
}

/// The message as it goes to a thread: its words as typed, with `t3-context://` references where its pills sit and the
/// records they point to (`RouterPointers.threadMessage`), and the ids that make a retry safe.
struct ThreadMessage: Equatable, Sendable {
    var commandID: String = UUID().uuidString.lowercased()
    var messageID: String = UUID().uuidString.lowercased()
    /// What T3 gets as the text.
    var text: String
    var records: [T3JSON] = []
}

/// How a send is dispatched to the thread it finds.
struct ThreadSendPlan: Equatable, Sendable {
    var dispatch: T3Dispatch
    var outcome: ThreadSendOutcome
    /// Said on the entry when the send is not what was asked ("queued: this agent can't take words while it works").
    var note: String?
}

enum ThreadSender {
    /// Drivers that take a message into a running turn, until the thread's provider session reports its own flags
    /// (`supportsActiveSteering`, static per driver in T3's adapters). Any other driver queues.
    static let steeringDrivers: Set<String> = ["claudeAgent", "codex"]

    /// Whether the thread's agent can be steered: its provider session's flags once there is one, else its driver's.
    static func steers(session: T3ProviderSession.Capabilities?, driver: String) -> Bool {
        session?.supportsActiveSteering ?? steeringDrivers.contains(driver)
    }

    /// How a message is dispatched. `running`: a run is under way or about to start. `unattended`: no one is there to see the
    /// agent's tool interrupted, so it only ever queues (Claude's steer stops the tool it is running, S1 c).
    static func plan(running: Bool, mode: ThreadSendMode, steers: Bool, unattended: Bool) -> ThreadSendPlan {
        if unattended { return ThreadSendPlan(dispatch: .queueAfterActive, outcome: running ? .queued : .started) }
        guard running else { return ThreadSendPlan(dispatch: .startImmediately(intent: .auto), outcome: .started) }
        if mode == .queue { return ThreadSendPlan(dispatch: .queueAfterActive, outcome: .queued) }
        guard steers else {
            return ThreadSendPlan(dispatch: .queueAfterActive, outcome: .queued,
                                  note: "queued: this agent can't take words while it works")
        }
        return ThreadSendPlan(dispatch: .startImmediately(intent: .steer), outcome: .steered)
    }

    /// The run a Continue names (`manualContinuationOfRunId`): T3 allows it only after an interrupt or a usage limit. After
    /// a plain failure, or a run that finished, Continue is a message like any other, and there is no run to name.
    static func continuationRun(status: T3Status, usageLimit: Bool, latestRun: String?) -> String? {
        guard status == .interrupted || (status == .failed && usageLimit) else { return nil }
        return latestRun
    }

    /// T3's own words for Continue.
    static let continueWords = "Continue where you left off."

    /// The pick line over the composer: what your words do to the thread.
    static func pickLine(title: String, running: Bool, steers: Bool) -> (text: String, steering: Bool) {
        guard running else { return ("send to \(title)", false) }
        return steers ? ("steer \(title) (running)", true) : ("queue for \(title) (running)", false)
    }
}

/// Where a sent message stands now, read from the thread's projection.
enum ThreadDelivery: Equatable {
    /// Waiting behind the run under way: `position` in the queue, and the run that takes it back or edits it.
    case queued(run: String, position: Int)
    /// In a run under way (it started, or steered into one): that run can be stopped, the message not taken back.
    case working(run: String)
    /// Its run is over.
    case over
    /// Fjord holds no projection of the thread (it isn't one it watches).
    case unknown
}

extension RouterDecision {
    /// A message a send put in a thread, so its entry can say how it went and offer to change your mind: the thread (T3's
    /// id), the message and command ids, and what the send did.
    struct Delivered: Codable, Equatable {
        var thread: String
        var messageID: String
        var commandID: String
        var outcome: ThreadSendOutcome
        var note: String?
        var at: Date
        /// What taking it back or stopping it did.
        var cancelled: Cancelled?
        /// The words, once edited in place while queued.
        var editedTo: String?

        /// Whether the message can no longer run: cancelled while queued, or its run stopped.
        var stopped: Bool { cancelled != nil }
    }

    /// What changing your mind did.
    enum Cancelled: String, Codable, Equatable {
        /// It was queued and never will run (`queued-run.cancel`).
        case beforeStart = "before-start"
        /// Its run was stopped (`run.interrupt`): what it already did stays done.
        case aborted

        var words: String {
            switch self {
            case .beforeStart: "cancelled before it ran"
            case .aborted: "stopped: what the agent already did stays done"
            }
        }
    }
}

extension Store {
    /// T3 can't be reached now (not connected): a refused send says so, and only while it is true.
    var t3Away: Bool { requestSender == nil && !routerIsPretend && t3.store.connection != .connected }

    /// The driver of a thread's agent, for what its provider session hasn't said yet.
    func threadSteers(_ id: String) -> Bool {
        ThreadSender.steers(session: t3.store.projections[id]?.capabilities, driver: threads[id]?.provider ?? "")
    }

    /// The pick line for a thread you reply to.
    func pickLine(_ id: String, title: String) -> (text: String, steering: Bool) {
        ThreadSender.pickLine(title: title, running: threads[id]?.running ?? false, steers: threadSteers(id))
    }

    /// Sends `message` to the thread: one `message.dispatch`. Throws why it didn't go (T3's own words for a refusal).
    /// `gate` is asked right before the dispatch: a reason refuses it. In a demo or a playground nothing is sent.
    func sendToThread(_ id: String, _ message: ThreadMessage, mode: ThreadSendMode, unattended: Bool = false,
                      gate: (@MainActor () -> String?)? = nil) async throws -> RouterDecision.Delivered {
        guard let thread = threads[id] else { throw ThreadSendFailure("That thread isn't in T3 anymore: nothing was sent") }
        let plan = ThreadSender.plan(running: thread.running, mode: mode, steers: threadSteers(id), unattended: unattended)
        if let refusal = gate?() { throw ThreadSendFailure(refusal) }
        let command = T3Command.messageDispatch(threadId: id, messageId: message.messageID, text: message.text,
                                                dispatch: plan.dispatch, context: message.records)
        try await dispatch(command, commandId: message.commandID)
        // Your words went there: you have read what it said (T3's read state, which its sidebar and phone share). Fjord marks a
        // thread read only then and on Mark read, never for showing it. An action's message isn't yours: nothing is marked.
        if !unattended { try? await dispatch(.threadVisit(threadId: id, visitedAt: T3Timestamp(date: Date()))) }
        return RouterDecision.Delivered(thread: id, messageID: message.messageID, commandID: message.commandID,
                                        outcome: plan.outcome, note: plan.note, at: Date())
    }

    /// Continue on a stopped thread: T3's own words as a message that starts a run, naming the run it continues when T3 allows
    /// it. Marks the thread read, as any send of yours does.
    func continueThread(_ id: String) async throws {
        guard let thread = threads[id] else { throw ThreadSendFailure("That thread isn't in T3 anymore: nothing was sent") }
        let run = ThreadSender.continuationRun(status: thread.status, usageLimit: thread.usageLimit, latestRun: thread.latestRunID)
        let command = T3Command.messageDispatch(threadId: id, messageId: UUID().uuidString.lowercased(), text: ThreadSender.continueWords,
                                                dispatch: .startImmediately(intent: .auto), continuationOf: run)
        try await dispatch(command)
        try? await dispatch(.threadVisit(threadId: id, visitedAt: T3Timestamp(date: Date())))
    }

    /// The newest message queued behind a thread's run (the one a Cancel on its queued row takes back).
    func newestQueuedRun(_ id: String) -> String? { t3.store.projections[id]?.ownQueuedRuns.last?.id }

    /// The queued run of yours whose message is these words (the newest such); "" for any words: your newest queued run.
    /// Never one T3 queued itself (a delegated task's completion).
    func queuedRun(_ id: String, carrying words: String) -> String? {
        guard let p = t3.store.projections[id] else { return nil }
        if words.isEmpty { return p.ownQueuedRuns.last?.id }
        return p.ownQueuedRuns.last { run in run.userMessageId.flatMap { m in p.messages.first { $0.id == m } }?.text == words }?.id
    }

    /// Where a delivered message stands now.
    func delivery(_ sent: RouterDecision.Delivered) -> ThreadDelivery {
        guard let p = t3.store.projections[sent.thread] else { return .unknown }
        let run = p.runs.first { $0.userMessageId == sent.messageID }
            ?? p.messages.first { $0.id == sent.messageID }?.runId.flatMap { id in p.runs.first { $0.id == id } }
        guard let run else { return p.activeRun.map { .working(run: $0.id) } ?? .over }
        if run.isQueued { return .queued(run: run.id, position: run.queuePosition ?? 1) }
        return run.status.isLive ? .working(run: run.id) : .over
    }

    /// What a delivered message's entry can offer now: take it back or edit it while it waits, stop its run while it works.
    enum ChangeOfMind: Equatable { case cancelAndEdit(run: String), stop(run: String), none }

    func changeOfMind(_ entry: RouterDecision) -> ChangeOfMind {
        guard let sent = entry.delivered, !sent.stopped else { return .none }
        switch delivery(sent) {
        case .queued(let run, _): return .cancelAndEdit(run: run)
        case .working(let run): return .stop(run: run)
        case .over, .unknown: return .none
        }
    }

    /// The queued message's entry is taken back: `queued-run.cancel`. The words stay in your history.
    @discardableResult
    func cancelQueued(_ entryID: UUID) async -> Bool {
        guard let entry = router.record(entryID), let sent = entry.delivered, case .cancelAndEdit(let run) = changeOfMind(entry) else { return false }
        do {
            try await dispatch(.queuedRunCancel(threadId: sent.thread, runId: run))
            updateDecision(entryID) {
                $0.delivered?.cancelled = .beforeStart
                $0.add(.cancelled(.beforeStart))
            }
            return true
        } catch {
            noteFailure(entryID, "couldn't cancel: ", error)
            return false
        }
    }

    /// The queued message's words changed in place: `queued-run.edit`. The agent gets the edited text when its turn comes.
    @discardableResult
    func editQueued(_ entryID: UUID, to words: String) async -> Bool {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let entry = router.record(entryID), let sent = entry.delivered,
              case .cancelAndEdit(let run) = changeOfMind(entry) else { return false }
        do {
            try await dispatch(.queuedRunEdit(threadId: sent.thread, runId: run, text: words))
            updateDecision(entryID) {
                $0.delivered?.editedTo = words
                $0.add(.edited(words))
            }
            return true
        } catch {
            noteFailure(entryID, "couldn't edit: ", error)
            return false
        }
    }

    /// Stops the run a message is in (`run.interrupt` holding the queue, so what waits behind it doesn't start at once). What
    /// it already did stays done, and a steered message can't be taken back.
    @discardableResult
    func stopRun(_ entryID: UUID) async -> Bool {
        guard let entry = router.record(entryID), let sent = entry.delivered, case .stop(let run) = changeOfMind(entry) else { return false }
        return await interrupt(thread: sent.thread, run: run, entry: entryID)
    }

    /// Stops the run a thread is on (its row's Stop), whoever's message it was.
    @discardableResult
    func stopThread(_ id: String) async -> Bool {
        guard let run = t3.store.projections[id]?.activeRun else { return false }
        return await interrupt(thread: id, run: run.id, entry: nil)
    }

    private func interrupt(thread: String, run: String, entry: UUID?) async -> Bool {
        do {
            try await dispatch(.runInterrupt(threadId: thread, runId: run, reason: "Stopped from Fjord", holdQueue: true))
            if let entry {
                updateDecision(entry) {
                    $0.delivered?.cancelled = .aborted
                    $0.add(.cancelled(.aborted))
                }
            }
            return true
        } catch {
            if let entry { noteFailure(entry, "couldn't stop: ", error) }
            return false
        }
    }

    /// Lets what waited behind a stopped run start (`queue.resume`).
    @discardableResult
    func resumeQueue(_ id: String) async -> Bool {
        do {
            try await dispatch(.queueResume(threadId: id))
            return true
        } catch {
            return false
        }
    }

    /// Whether a thread holds queued messages with nothing running: stopped with the queue held, waiting for Resume.
    func queueHeld(_ id: String) -> Bool {
        guard let p = t3.store.projections[id] else { return false }
        return !p.queuedRuns.isEmpty && p.activeRun == nil
    }

    private func noteFailure(_ entryID: UUID, _ prefix: String, _ error: Error) {
        let first = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? "failed"
        updateDecision(entryID) { $0.add(.failed(prefix + RouterDecision.clip(first, 100))) }
    }

    /// Sends a command to T3 in order. In a demo or a playground nothing is sent, unless a test stands a sender in.
    func dispatch(_ command: T3Command, commandId: String = UUID().uuidString.lowercased()) async throws {
        if requestSender == nil, routerIsPretend { return }
        if let requestSender { try await requestSender(command, commandId) } else { _ = try await t3.store.send(command, commandId: commandId) }
    }
}

/// Why a message did not go to a thread, in words for the entry.
struct ThreadSendFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
