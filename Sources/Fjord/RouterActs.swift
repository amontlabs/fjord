import Foundation

// The Router v2 page's acts on T3 (docs/design/router-v2/IMPLEMENTATION.md 1.6): the real `RouterSource`.
//
// The page has already changed its own copy when it calls these. Each act first tells the records what it did (a pending
// send, a hidden thread, a mark), in the same main-loop turn, and only then starts the work: nothing awaits before the
// pending act is recorded. A pending send ends on T3's word, never a timer; T3's refusal ends it at once (`.refused`).
// Everything outside Fjord's own state goes through `Environment`, so tests need no `Store`.

/// What the records learn of the page's acts (Router v2 track 3's store implements it).
@MainActor protocol RouterActsRecords: AnyObject {
    /// A send left the page: the line is Sent until T3 shows its run.
    func began(send: RouterActs.Send)
    /// The send is over without a run to show: T3 refused it, or it could not be made.
    func ended(send: RouterActs.Send)
    /// T3 took the send (its `{sequence}` came back). The pending send still ends on T3's word.
    func took(send: RouterActs.Send)
    /// A settled or snoozed thread has no line until `on` is false again (the Revert, or T3 refusing).
    func hide(_ thread: String, on: Bool)
    /// Fjord's own mark: the verdict's ask doesn't need you.
    func notForMe(_ thread: String, on: Bool)
    /// The card was opened here: the new dot is gone before T3 says so.
    func seen(_ thread: String)
    /// Cancel on a queued row: its run hidden (`on`) until T3 drops it, or shown again when T3 kept it.
    func cancelledQueue(_ thread: String, run: String?, on: Bool)
}

extension RouterActsRecords {
    func took(send: RouterActs.Send) {}
    func cancelledQueue(_ thread: String, run: String?, on: Bool) {}
}

@MainActor final class RouterActs: RouterSource {
    /// A send in flight, as the records hold it.
    struct Send: Equatable {
        enum Kind: Equatable {
            /// Words to an idle thread (or to a request, as its answer).
            case words
            /// Words into the run under way.
            case steer
            /// Words behind the run under way.
            case queue
            /// Options picked on a T3 request.
            case answer
            /// Continue on a Stopped card.
            case continuing
            /// A new thread, started with these settings; `name`: the read's first name for it, when it had one.
            case start(project: String, launch: RouterLaunch, name: String?)
        }

        var thread: String
        var words: String
        var kind: Kind
        var at: Date
    }

    /// Everything an act does outside Fjord's own state. `live(store:)` has the real ones.
    struct Environment {
        /// A message through the dispatcher (the decision log, a waiting request's rules): its entry, nil when the Router is off.
        var submit: (_ text: String, _ context: RouterContext) -> UUID?
        /// The request the thread holds now.
        var request: (_ thread: String) -> ThreadRequest?
        /// An answer on a request, against the snapshot taken when it was read.
        var perform: (_ answer: ThreadAnswers.Answer, _ request: ThreadRequest, _ snapshot: RequestSnapshot) async -> Result<Void, Error>
        /// Continue: T3's words, naming the run when it allows.
        var continueThread: (_ thread: String) async throws -> Void
        /// A command to T3, in order.
        var dispatch: (_ command: T3Command) async throws -> Void
        /// The queued run that carries these words (its user message's text), when T3 lists it.
        var queuedRun: (_ thread: String, _ words: String) -> String?
        /// Stops the run the thread is on.
        var stop: (_ thread: String) async -> Bool
        /// An act with a Revert, logged for History: hidden through `hold` at once, `refused` hears T3's refusal after the line
        /// is back. Returns the change it logged.
        var act: (_ act: ThreadAct, _ thread: String, _ detail: String, _ title: String,
                  _ hold: @escaping @MainActor (Bool) -> Void, _ refused: @escaping @MainActor (String) -> Void) -> UUID?
        /// History's Revert of a change: its opposite command, and the change marked reverted.
        var revert: (_ change: UUID) -> Void
        var open: (_ thread: String) -> Bool
        /// The T3 project id for the name the page shows (or an id).
        var projectID: (_ project: String) -> String?
        /// T3 can't be reached now.
        var away: () -> Bool
        var title: (_ thread: String) -> String
        var now: () -> Date
    }

    var env: Environment
    weak var records: RouterActsRecords?
    /// What the page hears back: `.refused` for a send that didn't go.
    var emit: (RouterChange) -> Void
    /// T3's models, for the efforts a model takes (set from `RouterChange.launch`); a model not in it is sent as chosen.
    var models: [RouterLaunchModel] = []
    /// Reads where a draft goes (the reader, track 5), and the decision it came to for those words, for the decision log.
    var reader: ((_ draft: String, _ selected: String?, _ mentions: [RouterMention]) -> Void)?
    var decision: (_ draft: String) -> RouterProjectDecision? = { _ in nil }

    /// The dispatcher's entries that are sends of the page, by entry.
    private var entries: [UUID: Send] = [:]
    /// Words queued from the page, per thread: what a Cancel takes back.
    private var queuedWords: [String: String] = [:]
    /// Cancels waiting for T3 to list the run they take back (`threadChanged`).
    private var cancelling: [String: String] = [:]
    /// The changes logged for History, per thread and act, newest last: what a Revert marks reverted.
    private var changes: [String: [ThreadAct: [UUID]]] = [:]

    init(env: Environment, records: RouterActsRecords? = nil, emit: @escaping (RouterChange) -> Void = { _ in }) {
        self.env = env
        self.records = records
        self.emit = emit
    }

    // MARK: Reading a draft

    func read(_ draft: String, selected: String?, mentions: [RouterMention]) {
        reader?(draft, selected, mentions)
    }

    // MARK: Sending

    func send(_ out: RouterOutgoing) {
        let kind: Send.Kind
        switch out.kind {
        case .continuing: kind = .continuing
        case .answer: kind = .answer
        case .words: kind = out.queue ? .queue : out.steering ? .steer : .words
        }
        let send = Send(thread: out.thread, words: out.words, kind: kind, at: env.now())
        if kind == .queue { queuedWords[out.thread] = out.words }
        records?.began(send: send)
        switch out.kind {
        case .words: words(out, send)
        case .answer(let picks, let typed): answer(out, send, picks: picks, typed: typed)
        case .continuing: continuing(send)
        }
    }

    private func words(_ out: RouterOutgoing, _ send: Send) {
        var context = RouterContext(target: RouteTarget.thread(out.thread).targetID)
        context.queue = out.queue
        context.decided = out.read.flatMap { decision($0.draft) }
        guard let entry = env.submit(out.words, context) else {
            return refuse(send, "The Router is off: nothing was sent")
        }
        entries[entry] = send
    }

    private func answer(_ out: RouterOutgoing, _ send: Send, picks: [Int: Int], typed: [Int: String]) {
        // What the thread holds now is what the picks are read against, in this turn.
        guard let request = env.request(out.thread) else { return refuse(send, "That isn't waiting anymore") }
        let resolved: ThreadAnswers.Answer
        do { resolved = try ThreadAnswers.resolve(request, picks: picks, typed: typed) } catch {
            return refuse(send, Self.words(error))
        }
        let snapshot = RequestSnapshot(target: ThreadTarget(project: "", thread: out.thread), request: request)
        Task { @MainActor [env] in
            switch await env.perform(resolved, request, snapshot) {
            case .success: self.took(send)
            case .failure(let error): self.refuse(send, Self.words(error))
            }
        }
    }

    private func continuing(_ send: Send) {
        Task { @MainActor [env] in
            do {
                try await env.continueThread(send.thread)
                self.took(send)
            } catch {
                self.refuse(send, Self.words(error))
            }
        }
    }

    /// Cancel on a queued row: the run that carries the words queued here, never another one T3 queued (a subagent's
    /// completion). Not listed by T3 yet: it is cancelled when it is (`threadChanged`).
    func cancelQueued(_ thread: String) {
        // Words queued before this run of Fjord: the row shows T3's queued run, its newest.
        let words = queuedWords.removeValue(forKey: thread) ?? ""
        guard !words.isEmpty || env.queuedRun(thread, "") != nil else { return }
        records?.cancelledQueue(thread, run: nil, on: true)
        cancelling[thread] = words
        threadChanged(thread)
    }

    /// The thread's projection changed: a cancel waiting for its run sends it now.
    func threadChanged(_ thread: String) {
        guard let words = cancelling[thread], let run = env.queuedRun(thread, words) else { return }
        cancelling[thread] = nil
        records?.cancelledQueue(thread, run: run, on: true)
        Task { @MainActor [env] in
            do {
                try await env.dispatch(.queuedRunCancel(threadId: thread, runId: run))
            } catch {
                // T3 kept it: it still goes at the turn's end, and the page says so.
                self.records?.cancelledQueue(thread, run: run, on: false)
                self.emit(.note(thread, words: Router.Copy.queueKept))
            }
        }
    }

    /// The dispatcher's word on an entry of the page's (wired to `RouterDispatcher.onSend`).
    func sendEvent(_ entry: UUID, _ event: RouterDispatcher.SendEvent) {
        guard let send = entries.removeValue(forKey: entry) else { return }
        switch event {
        case .taken: took(send)
        case .refused(let reason, let offline): refuse(send, reason, offline: offline)
        }
    }

    private func took(_ send: Send) { records?.took(send: send) }

    /// The send didn't go: its pending act ends at once and the page puts the line back with a failure line.
    private func refuse(_ send: Send, _ reason: String, offline: Bool? = nil) {
        records?.ended(send: send)
        emit(.refused(send.thread, reason: reason, offline: offline ?? env.away()))
    }

    private static func words(_ error: Error) -> String {
        let said = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return said.split(separator: "\n").first.map(String.init) ?? "The answer wasn't sent."
    }

    // MARK: A new thread

    func mintThread() -> String { UUID().uuidString.lowercased() }

    func start(_ thread: String, words: String, project: String, launch: RouterLaunch, read: RouterRead?) {
        let send = Send(thread: thread, words: words, kind: .start(project: project, launch: launch, name: read?.name), at: env.now())
        records?.began(send: send)
        guard let id = env.projectID(project) else { return refuse(send, "That project isn't in T3 anymore: nothing was started") }
        var context = RouterContext(target: RouterAskBack.newThread + id)
        // No settings until T3's config is read: the page showed none, and T3 starts it with its own defaults.
        context.launch = RouterLaunchPlan(thread: thread, settings: models.isEmpty ? nil : settings(launch))
        context.decided = read.flatMap { decision($0.draft) }
        guard let entry = env.submit(words, context) else { return refuse(send, "The Router is off: nothing was started") }
        entries[entry] = send
    }

    /// The row's chips as T3's launch settings: its own lists' names, and no effort for a model that takes none.
    func settings(_ launch: RouterLaunch) -> ThreadLaunchSettings {
        let model = models.first { $0.id == launch.model }
        let takesEffort = model.map { !$0.efforts.isEmpty } ?? true
        return ThreadLaunchSettings(model: launch.model, effort: takesEffort ? launch.effort.rawValue : nil,
                                    runtimeMode: T3RuntimeMode(rawValue: launch.access.rawValue),
                                    interactionMode: launch.plan ? .plan : .default)
    }

    // MARK: Stop, visit, open

    func stop(_ thread: String) {
        Task { @MainActor [env] in _ = await env.stop(thread) }
    }

    func visit(_ thread: String) {
        records?.seen(thread)
        Task { @MainActor [env] in try? await env.dispatch(.threadVisit(threadId: thread, visitedAt: T3Timestamp(date: env.now()))) }
    }

    func open(_ thread: String) { _ = env.open(thread) }

    // MARK: Settle, snooze, not for me

    func settle(_ threads: [String], on: Bool) {
        for thread in threads { on ? doAct(.settle, thread) : undoAct(.settle, thread) }
    }

    func snooze(_ thread: String, until: Date?) {
        if let until { doAct(.snooze, thread, detail: T3Timestamp(date: until).text) } else { undoAct(.snooze, thread) }
    }

    func notForMe(_ thread: String, on: Bool) { records?.notForMe(thread, on: on) }

    private func doAct(_ act: ThreadAct, _ thread: String, detail: String = "") {
        let logged = Logged()
        let id = env.act(act, thread, detail, env.title(thread), { [weak self] on in self?.records?.hide(thread, on: on) },
                         { [weak self] reason in
                             // The line is back: nothing is left to revert, and the page says why.
                             guard let self else { return }
                             if let change = logged.id { self.changes[thread]?[act]?.removeAll { $0 == change } }
                             self.emit(.actRefused(thread, reason: reason))
                         })
        logged.id = id
        if let id { changes[thread, default: [:]][act, default: []].append(id) }
    }

    /// The change an act logged, for its refusal (which may come after `act` returns it).
    @MainActor private final class Logged { var id: UUID? }

    /// The Revert: the thread's line may return at once; the change History logged is marked reverted, which sends the opposite
    /// command. With no change to revert (it was refused, or not logged here) the opposite command goes by itself.
    private func undoAct(_ act: ThreadAct, _ thread: String) {
        records?.hide(thread, on: false)
        if let id = changes[thread]?[act]?.popLast() {
            env.revert(id)
        } else {
            let command = Store.commands(for: act, thread: thread, detail: "", forward: false)
            Task { @MainActor [env] in for c in command { try? await env.dispatch(c) } }
        }
    }
}

// MARK: - The real environment

extension RouterActs {
    /// The real acts on `store`: the dispatcher's sends are reported back here, and the records hear every act.
    static func live(store: Store, records: RouterActsRecords? = nil, emit: @escaping (RouterChange) -> Void = { _ in }) -> RouterActs {
        func target(_ id: String) -> ThreadTarget { ThreadTarget(project: store.threads[id]?.projectID ?? "", thread: id) }
        let env = Environment(
            submit: { [weak store] text, context in store?.routerDispatcher.submit(text, context: context) },
            request: { [weak store] id in store?.heldRequest(target(id)) },
            perform: { [weak store] answer, request, snapshot in
                guard let store else { return .failure(ThreadSendFailure("Fjord isn't ready")) }
                return await store.perform(answer, on: request, snapshot: snapshot)
            },
            continueThread: { [weak store] id in try await store?.continueThread(id) },
            dispatch: { [weak store] command in try await store?.dispatch(command) },
            queuedRun: { [weak store] id, words in store?.queuedRun(id, carrying: words) },
            stop: { [weak store] id in await store?.stopThread(id) ?? false },
            act: { [weak store] act, id, detail, title, hold, refused in
                store?.threadAct(act, on: target(id), detail: detail, title: title, hold: hold, refused: refused)
            },
            revert: { [weak store] change in _ = store?.revertFjordChange(change) },
            open: { [weak store] id in store?.openThread(id) ?? false },
            projectID: { [weak store] name in
                guard let projects = store?.t3.store.shell.projects.values.filter({ $0.archivedAt == nil }) else { return nil }
                return projects.first { $0.id == name }?.id
                    ?? projects.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }?.id
                    // A project with no title is named by its folder on the page.
                    ?? projects.first { $0.title.isEmpty && store?.folderName($0.workspaceRoot) == name }?.id
            },
            away: { [weak store] in store?.t3Away ?? false },
            title: { [weak store] id in store?.threads[id]?.title ?? "thread" },
            now: { Date() })
        let acts = RouterActs(env: env, records: records, emit: emit)
        store.routerDispatcher.onSend = { [weak acts] entry, event in acts?.sendEvent(entry, event) }
        return acts
    }
}
