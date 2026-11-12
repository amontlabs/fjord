import Foundation

// The Router v2 page's record store (docs/design/router-v2/IMPLEMENTATION.md 1.3): one record per T3 thread, composed from
// its code state (`RouterCodeState`), its verdict when the verdict's fingerprint is the current one, and this app's own
// acts T3 hasn't confirmed yet. It hands the page only what changed (`RouterV2Change`), one record at a time; while the
// window's morph plays it keeps the changes and lets them go as one batch when still. Not observed by views: the page
// model is, and it takes these changes through `apply`.

@MainActor
final class RouterRecords {
    // MARK: Wiring

    /// Every change for the page (the model's `apply`).
    var emit: (RouterV2Change) -> Void = { _ in }
    /// A verdict to ask for (`RouterVerdicts.ask`).
    var ask: (RouterVerdictRequest) -> Void = { _ in }
    /// The engine's calls for this thread are no longer wanted: a run started, another fingerprint, the thread left.
    var cancel: (String) -> Void = { _ in }
    /// The Needs-you count changed (the sidebar badge, the bar).
    var onNeedsYou: ((Int) -> Void)?
    /// The shell as T3's store holds it now (`shell(_:)` reads its rows and projects from it).
    var rows: () -> T3ShellState = { T3ShellState() }
    /// A thread's project as the page names it; nil for no project.
    var projectName: (AgentThread) -> String? = { $0.folder == nil ? nil : $0.folderName } {
        didSet { projectNames = [:] }
    }
    /// A thread's pull requests with their states; `reply` is its last reply, where the unlinked ones are named.
    var pullRequests: (AgentThread, String?) -> [RouterV2Thread.PR] = { t, _ in RouterRecords.linked(t) }
    var notifier: RouterNotifier?
    var now: () -> Date = Date.init

    private let gate: MotionGate.Gate
    private let file: RouterVerdictFile?

    // MARK: State

    private var entries: [String: Entry] = [:]
    /// What the page holds: the last record handed to it per thread (the diff's other side).
    private var shown: [String: RouterV2Thread] = [:]
    private var older: [String: RouterV2Older] = [:]
    /// Project names by folder, and fallback names by title: worked out once each (a whole shell reads hundreds of rows).
    private var projectNames: [String: String?] = [:]
    private var titleNames: [String: String] = [:]
    /// The earliest clock boundary the operation under way met: one timer is set at its end.
    private var nextBoundary: Date?
    private var olderChanged = false
    /// The verdict file's contents: verdict, name, not-for-me mark and told banners per thread.
    private(set) var saved: [String: Saved]
    private var savedChanged = false
    /// Changes made in the operation under way, handed on as one at its end.
    private var out: [RouterV2Change] = []
    private var depth = 0
    /// Changes kept while the window's morph plays.
    private var held: [RouterV2Change] = []
    private var holding = false
    private var lost = false
    private var boundaryTimer: Timer?
    private var boundaryAt: Date?

    /// How many lines are in Needs you (asks, steps and stopped).
    private(set) var needsYou = 0

    /// `saved`: the verdict file's contents (`RouterVerdictFile.load`, read off the main thread before the first frame).
    init(saved: [String: Saved] = [:], file: RouterVerdictFile? = nil, gate: MotionGate.Gate? = nil) {
        self.saved = saved
        self.file = file
        self.gate = gate ?? MotionGate.shared
    }

    // MARK: Reads

    func record(_ id: String) -> RouterV2Thread? { shown[id] }

    /// A section's lines, longest there first.
    func lines(in section: RouterV2Section) -> [RouterV2Thread] {
        shown.values.filter { $0.section == section }.sorted { ($0.since, $0.id) < ($1.since, $1.id) }
    }

    /// The housekeeping line's threads, newest first.
    var olderLines: [RouterV2Older] { older.values.sorted { ($0.since, $0.id) > ($1.since, $1.id) } }

    /// Everything the page should hold now, as one batch (a page model made after the store).
    func snapshot() -> RouterV2Change {
        var all: [RouterV2Change] = shown.values.sorted { $0.id < $1.id }.map { .upsert($0) }
        all.append(.older(olderLines))
        if lost { all.append(.connection(lost: true)) }
        return .batch(all)
    }

    // MARK: T3's events

    /// A shell change as T3's store just applied it (nil: a whole new shell): one row for a row's change, its project's
    /// rows for a project's, every row for anything else.
    func shell(_ item: T3ShellItem?) {
        let shell = rows()
        func listed(_ t: T3ThreadShell) -> Bool { t.isListed && t.archivedAt == nil && t.deletedAt == nil && !t.id.isEmpty }
        func thread(_ t: T3ThreadShell) -> AgentThread { AgentThread(t, project: shell.projects[t.projectId]) }
        func projects(_ ids: Set<String>) {
            for t in shell.threads.values where ids.contains(t.projectId) && listed(t) { put(thread(t)) }
        }
        operation {
            switch item {
            case .threadUpdated(_, _, let t)?:
                if let row = shell.threads[t.id], listed(row) { put(thread(row)) } else { drop(t.id) }
            case .threadRemoved(_, _, let id)?:
                drop(id)
            case .projectUpdated(_, let p)?:
                projects([p.id])
            case .projectRemoved(_, let id)?:
                projects([id])
            case .snapshot(let s)? where s.threads.isEmpty && s.archivedThreads.isEmpty:
                projects(Set(s.projects.map(\.id)))
            case .synchronized?:
                purge()
            case .unknown?:
                break
            case .snapshot?, nil:
                replace(shell.threads.values.filter(listed).map(thread))
            }
        }
    }

    /// One thread as T3's shell shows it now.
    func put(_ t: AgentThread) {
        operation {
            let e = entry(t.id)
            e.thread = t
            refresh(t.id)
        }
    }

    /// A thread T3 no longer lists (archived, deleted).
    func drop(_ id: String) {
        operation {
            guard let e = entries[id], e.thread != nil else { return }
            e.thread = nil
            e.send = nil
            refresh(id)
            entries[id] = nil
        }
    }

    /// Every thread T3 lists, at once (its snapshot, a new shell): one batch.
    func replace(_ all: [AgentThread]) {
        operation {
            let ids = Set(all.map(\.id))
            for id in entries.keys where !ids.contains(id) { drop(id) }
            for t in all { put(t) }
        }
    }

    /// What the thread's projection says (its working line, its reply, its request…), while one is held; nil once closed.
    func detail(_ id: String, _ d: RouterDetail?) {
        operation {
            guard let e = entries[id] else { return }
            // Work T3 gives no start keeps the time Fjord first saw it.
            var d = d
            if let a = d?.activity { d?.activity = a.stamped(after: e.detail?.activity, now: now()) }
            guard e.detail != d else { return }
            e.detail = d
            refresh(id)
        }
    }

    func connection(_ state: T3ConnectionState) {
        let gone: Bool
        switch state {
        case .connected, .connecting, .idle: gone = false
        default: gone = true
        }
        guard gone != lost else { return }
        lost = gone
        operation { out.append(.connection(lost: gone)) }
    }

    // MARK: The verdict engine's events

    /// What the engine says of a call (`RouterVerdicts.onEvent`). Anything for a fingerprint that is no longer the
    /// thread's is late and dropped; a name call's key is T3's title.
    func verdict(_ id: String, fingerprint: String, _ event: RouterVerdictEvent) {
        operation {
            guard let e = entries[id], let t = e.thread else { return }
            if fingerprint != e.fingerprint {
                // A name call's answer, keyed on the title it was asked for: kept only while that is still T3's title; the
                // call is over either way, and a new title is asked for again.
                guard e.naming, fingerprint == e.namingFor else { return }
                switch event {
                case .done(let v):
                    e.naming = false
                    e.namingFor = nil
                    if !v.name.isEmpty, fingerprint == t.title { save(id) { $0.name = v.name; $0.nameKey = t.title } }
                    refresh(id)
                case .failed:
                    e.naming = false
                    e.namingFor = nil
                    e.nameFailed = fingerprint
                    refresh(id)
                case .state, .words: break
                }
                return
            }
            guard e.asked else { return }
            switch event {
            case .state(let needsYou, let worth):
                e.landed = Landed(needsYou: needsYou, worth: worth)
                refresh(id)
            case .words(let text, let done):
                guard !text.isEmpty else { return }
                if e.words == nil { e.stream += 1 }
                e.words = text
                stream(id, text: text, done: done)
            case .done(let v):
                e.asked = false
                e.landed = nil
                let streamed = e.words
                e.words = nil
                save(id) {
                    $0.fingerprint = fingerprint
                    $0.verdict = v
                    if !v.name.isEmpty, $0.nameKey != t.title { $0.name = v.name; $0.nameKey = t.title }
                }
                // The last words are drawn whole: a line that never streamed, or streamed short of its end, streams now.
                if let shownText = shown[id]?.sentence.text, shownText != v.line, !v.line.isEmpty, !needsResult(id, v) {
                    if streamed == nil { entries[id]?.stream += 1 }
                    stream(id, text: v.line, done: true)
                }
                refresh(id)
                if v.needsYou, entries[id]?.code?.wants == .finished, saved[id]?.notForMe != fingerprint, let notifier {
                    let key = notifier.step(t, project: project(t), fingerprint: fingerprint,
                                            ask: v.ask.isEmpty ? v.line : v.ask, told: saved[id]?.told ?? [])
                    if let key { tell(id, key) }
                }
            case .failed:
                e.asked = false
                e.failed = true
                e.landed = nil
                e.words = nil
                refresh(id)
            }
        }
    }

    /// A finished turn's verdict that you said doesn't need you shows its result line, not the line.
    private func needsResult(_ id: String, _ v: RouterVerdict) -> Bool {
        v.needsYou && saved[id]?.notForMe == entries[id]?.fingerprint && !v.result.isEmpty
    }

    // MARK: This app's own acts (pending until T3 says)

    /// A send left the page: the line is Sent until T3 shows the run it started (a steer: until the run it went into
    /// ends, or `delivered(_:)`). Queued words wait under the line until T3 lists them. A new thread's line is Sent,
    /// before T3 lists it.
    func began(send s: RouterActs.Send) {
        operation {
            if case .start(let project, let launch, let name) = s.kind {
                let e = entry(s.thread)
                e.send = Send(words: s.words, status: .sending, steering: false, run: nil, runStarted: nil, request: nil,
                              plan: false, at: s.at, start: Start(project: project, launch: launch, name: name ?? RouterV2.firstWords(s.words)))
                e.launch = launch
                refresh(s.thread)
                return
            }
            guard let e = entries[s.thread], let t = e.thread else { return }
            switch s.kind {
            case .queue:
                e.queued = s.words
                e.queuedRun = t.latestRunID
            case .start:
                return
            case .steer, .words, .answer, .continuing:
                let steering = s.kind == .steer
                e.send = Send(words: s.words, status: steering ? .steering : .sending, steering: steering, run: t.latestRunID,
                              runStarted: t.runStartedAt, request: t.pendingRequest?.id, plan: t.hasPlan, at: s.at)
            }
            refresh(s.thread)
        }
    }

    /// T3 took the send (`{sequence}`): its status goes. A steer keeps "steering…" until the run shows it.
    func took(send s: RouterActs.Send) {
        operation {
            guard let e = entries[s.thread], var send = e.send, !send.steering, send.status != .taken else { return }
            send.status = .taken
            e.send = send
            refresh(s.thread)
        }
    }

    /// The send is over without a run to show (T3 refused it, it couldn't be made): its pending act ends at once. The
    /// acts tell the page why (`.refused`) right after; the record follows in the next turn, so the page has put its line
    /// back by then.
    func ended(send s: RouterActs.Send) {
        guard let e = entries[s.thread] else { return }
        if s.kind == .queue { e.queued = nil; e.queuedRun = nil } else { e.send = nil }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.operation {
                    self.refresh(s.thread)
                    if self.entries[s.thread]?.thread == nil { self.entries[s.thread] = nil }
                }
            }
        }
    }

    /// T3's projection shows the words in a run (`Store.delivery`): a steer ends here. `sentAt`: when the delivered message
    /// was sent; one sent before the pending send is an older message's and ends nothing.
    func delivered(_ thread: String, sentAt: Date? = nil) {
        operation {
            guard let e = entries[thread], let send = e.send else { return }
            if let sentAt, sentAt < send.at { return }
            e.send = nil
            refresh(thread)
        }
    }

    /// Cancel on a queued row: the words came back to the composer; T3's queued run stays hidden until it is gone.
    func cancelledQueue(_ thread: String) {
        operation {
            guard let e = entries[thread] else { return }
            e.queued = nil
            e.queuedRun = nil
            for q in e.detail?.queued ?? [] { e.cancelled.insert(q.id) }
            refresh(thread)
        }
    }

    /// Settle or snooze (`on`), or their Revert: hidden until T3's row is out of play, shown until it is back in it.
    func hide(_ thread: String, on: Bool) {
        operation {
            guard let e = entries[thread] else { return }
            e.hidden = on
            refresh(thread)
        }
    }

    /// Doesn't need me: a mark on the verdict, kept with its fingerprint (a restart keeps it, the next turn drops it).
    func notForMe(_ thread: String, on: Bool) {
        operation {
            guard let e = entries[thread] else { return }
            save(thread) { $0.notForMe = on ? e.fingerprint : nil }
            refresh(thread)
        }
    }

    /// Its card opened here (`thread.visit` sent): no new dot until T3's `lastVisitedAt` moves.
    func seen(_ thread: String) {
        operation {
            guard let e = entries[thread], let t = e.thread else { return }
            e.seen = Seen(visited: t.lastVisitedAt)
            refresh(thread)
        }
    }

    /// The clock reached a boundary (a day since a finish, a week, a snooze's end): those threads again.
    func tick() {
        let now = now()
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        boundaryAt = nil
        operation {
            for (id, e) in entries where (e.boundary ?? .distantFuture) <= now { refresh(id) }
            if let next = entries.values.lazy.compactMap(\.boundary).filter({ $0 > now }).min(), next < nextBoundary ?? .distantFuture {
                nextBoundary = next
            }
        }
    }

    /// Writes what the file still has to write, now (on quit).
    func flush() { file?.flush() }

    // MARK: The record

    /// A thread's state now: its code state, scope and fingerprint again, its pending acts ended where T3 agrees, the
    /// verdict asked for or cancelled, its banner, and its record handed on if it changed.
    private func refresh(_ id: String) {
        guard let e = entries[id] else { return }
        let now = now()
        let was = e.code
        if let t = e.thread {
            let playing = t.inPlay(now: now)
            endPending(e, t, inPlay: playing)
            if e.send == nil, e.hidden == nil, RouterCodeState.plainlyOut(t, inPlay: playing, now: now) {
                // Off the page (settled, snoozed, a week old): nothing to show or ask; a snooze's end is its one boundary.
                e.code = nil
                e.scope = .out
                e.boundary = t.snoozedUntil.flatMap { $0 > now ? $0 : nil }
                stopCalls(e, id)
                if let b = e.boundary, b < nextBoundary ?? .distantFuture { nextBoundary = b }
                publish(id, e)
                housekeeping(id, e)
                return
            }
            let code = RouterCodeState.make(thread: t, detail: e.detail, now: now)
            e.code = code
            e.scope = scope(t, code, hidden: e.hidden, now: now)
            e.boundary = RouterCodeState.boundary(t, state: code, now: now)
            // Off the page nothing is asked: its fingerprint is read when it comes back.
            let print = e.scope == .out ? e.fingerprint : RouterCodeState.fingerprint(t)
            if print != e.fingerprint {
                e.fingerprint = print
                e.failed = false
                stopCalls(e, id)
            }
            // A thread started here keeps its settings through its first run.
            if e.launch != nil, e.send == nil, code.state != .working { e.launch = nil }
            if !e.cancelled.isEmpty { e.cancelled.formIntersection((e.detail?.queued ?? []).map(\.id)) }
            askIfNeeded(id, e, t, code)
            if was != code, e.scope != .out, e.hidden != true, let notifier {
                let key = notifier.changed(t, project: project(t), from: was, to: code, request: e.detail?.request, now: now,
                                           told: saved[id]?.told ?? [])
                if let key { tell(id, key) }
            }
        } else {
            e.code = nil
            e.scope = .out
            e.boundary = nil
            stopCalls(e, id)
        }
        if let b = e.boundary, b < nextBoundary ?? .distantFuture { nextBoundary = b }
        publish(id, e)
        housekeeping(id, e)
    }

    /// The scope, with a Revert that T3 hasn't confirmed yet taken as done: the thread is where it would be in play.
    private func scope(_ t: AgentThread, _ code: RouterCodeState, hidden: Bool?, now: Date) -> RouterCodeState.Scope {
        if hidden == true { return .out }
        let scope = RouterCodeState.scope(t, state: code, now: now)
        guard hidden == false, scope == .out else { return scope }
        var back = t
        back.settled = false
        back.snoozedUntil = nil
        return RouterCodeState.scope(back, state: code, now: now)
    }

    /// Pending acts end on T3's word, never on a timer.
    private func endPending(_ e: Entry, _ t: AgentThread, inPlay: Bool) {
        if let s = e.send {
            let newRun = t.latestRunID != nil && t.latestRunID != s.run
            let started = t.runStartedAt != nil && t.runStartedAt != s.runStarted
            if s.steering {
                // Into the run under way: over when that run is (or when T3 shows it in the run, `delivered`).
                if newRun || !t.running { e.send = nil }
            } else if newRun || started || s.request != nil && t.pendingRequest?.id != s.request || s.plan && !t.hasPlan {
                e.send = nil
            }
        }
        if e.queued != nil, t.latestRunID != e.queuedRun || !(e.detail?.queued.isEmpty ?? true) {
            e.queued = nil
            e.queuedRun = nil
        }
        if let hidden = e.hidden, inPlay != hidden { e.hidden = nil }
        if let seen = e.seen, t.lastVisitedAt != seen.visited { e.seen = nil }
    }

    /// The engine's calls for the thread stop: a run started, another fingerprint, the thread left.
    private func stopCalls(_ e: Entry, _ id: String) {
        e.landed = nil
        e.words = nil
        guard e.asked || e.naming else { return }
        e.asked = false
        e.naming = false
        e.namingFor = nil
        cancel(id)
    }

    /// The verdict this state needs, asked once per fingerprint; a name once per T3 title.
    private func askIfNeeded(_ id: String, _ e: Entry, _ t: AgentThread, _ code: RouterCodeState) {
        let onPage = e.scope == .line && e.hidden != true
        let have = saved[id]?.fingerprint == e.fingerprint && saved[id]?.verdict != nil
        if code.wants == .nothing || !onPage || e.send != nil {
            // A run started, the thread left, or your words are on their way: no verdict now.
            if e.asked { stopCalls(e, id) }
        } else if !have, !e.asked, !e.failed {
            e.asked = true
            let kind: RouterVerdictRequest.Kind = code.wants == .ask ? .ask : .finished
            ask(RouterVerdictRequest(thread: id, fingerprint: e.fingerprint, kind: kind, input: input(t, e), at: code.since))
        }
        if saved[id]?.nameKey != t.title, e.nameFailed != t.title, onPage, !e.asked, !e.naming {
            e.naming = true
            e.namingFor = t.title
            ask(RouterVerdictRequest(thread: id, fingerprint: t.title, kind: .name, input: input(t, e), at: t.lastActivity))
        }
    }

    private func input(_ t: AgentThread, _ e: Entry) -> RouterVerdictInput {
        RouterVerdictInput(thread: t, project: project(t), reply: e.detail.map(\.reply).flatMap { $0.isEmpty ? nil : $0 },
                           request: e.detail?.request.map(RouterVerdictInput.Request.init))
    }

    /// The thread's entry, made if it has none.
    private func entry(_ id: String) -> Entry {
        if let e = entries[id] { return e }
        let e = Entry()
        entries[id] = e
        return e
    }

    /// The record the page should show for a thread now; nil: no line.
    private func compose(_ id: String, _ e: Entry) -> RouterV2Thread? {
        guard e.hidden != true else { return nil }
        guard let code = e.code else {
            // Started here, not listed by T3 yet.
            guard let s = e.send, let start = s.start else { return nil }
            var r = RouterV2Thread(id: id, name: start.name, naming: true, title: s.words, project: start.project, state: .sent,
                                   sentence: .init(text: ""), since: s.at)
            r.sent = .init(words: s.words, status: s.status)
            r.launch = start.launch
            return r
        }
        guard e.scope == .line || e.send != nil, let t = e.thread else { return nil }
        let keep = saved[id]
        let name = keep?.name ?? e.send?.start?.name ?? fallbackName(t.title)
        var r = RouterV2Thread(id: id, name: name, naming: keep?.nameKey != t.title && (e.naming || e.asked), title: t.title,
                               project: project(t), state: code.state,
                               sentence: .init(text: code.line, mono: code.mono, stream: e.stream), since: code.since)
        r.isNew = RouterCodeState.isNew(t) && e.seen == nil
        r.paused = code.paused
        r.loading = code.loading
        let d = e.detail
        r.steers = d?.steers ?? true
        r.lastLines = d?.reply ?? t.latestMessage ?? ""
        r.writing = d?.writing ?? false
        r.steps = d?.steps ?? []
        r.activity = d?.activity ?? .init()
        r.diff = d?.diff
        r.queued = e.queued ?? d?.queued.first { !e.cancelled.contains($0.id) }?.words
        r.prs = pullRequests(t, d?.reply ?? t.latestMessage)
        r.launch = e.launch
        if code.state == .stopped { r.stop = .init(error: t.lastError ?? code.line, lastStep: d?.lastStep ?? "") }
        if case .needsYou = code.state, let request = d?.request { card(&r, request) }

        // The verdict, when it is the current fingerprint's: its state as soon as it lands, its words as they stream.
        if code.wants != .nothing {
            let v = keep?.fingerprint == e.fingerprint ? keep?.verdict : nil
            let notForMe = keep?.notForMe == e.fingerprint
            if let v {
                if !v.line.isEmpty { r.sentence = .init(text: v.line, stream: e.stream) }
                if code.wants == .finished { judged(&r, needsYou: v.needsYou, worth: v.worth, notForMe: notForMe, v: v) }
            } else if e.asked {
                if let l = e.landed, code.wants == .finished {
                    judged(&r, needsYou: l.needsYou, worth: l.worth, notForMe: notForMe, v: nil)
                }
                if let words = e.words {
                    r.sentence = .init(text: words, phase: .streaming, stream: e.stream)
                } else {
                    r.sentence.phase = .reassessing
                }
            }
        }

        // Your send, until T3 shows it: Sent, at the top of Working.
        if let s = e.send {
            r.state = .sent
            r.sent = .init(words: s.words, status: s.status)
            r.since = s.at
            r.isNew = false
            r.paused = false
        }
        return r
    }

    /// What a finished turn's verdict makes of it: it left you a step (Needs you, its ask, its options, the result line it
    /// keeps), unless you said it doesn't need you (Done, worth a look, the result line); or Done, worth a look or quiet.
    private func judged(_ r: inout RouterV2Thread, needsYou: Bool, worth: RouterV2Thread.Worth, notForMe: Bool, v: RouterVerdict?) {
        let result = v.flatMap { $0.result.isEmpty ? nil : $0.result }
        if needsYou, !notForMe {
            r.state = .needsYou(.step)
            r.question = v.flatMap { $0.ask.isEmpty ? nil : $0.ask }
            r.options = v?.options ?? []
            r.result = result
        } else if needsYou {
            r.state = .done
            r.worth = .look
            if let result { r.sentence = .init(text: result, stream: r.sentence.stream) }
        } else {
            r.worth = worth
        }
    }

    /// A T3 request's card: its options are T3's (a plan's are Fjord's two yeses), numbered as `ThreadAnswers` reads them.
    private func card(_ r: inout RouterV2Thread, _ request: ThreadRequest) {
        switch request.body {
        case .question(let questions):
            if questions.count > 1 {
                r.form = questions.map { .init(id: $0.id, title: $0.question, options: $0.options.map(\.label)) }
            } else if let q = questions.first {
                r.options = q.options.map(\.label)
            }
        case .approval(_, let prompt, let decisions):
            r.options = decisions.map(ThreadRequest.label)
            r.permission = .init(command: prompt, warning: "", warned: [])
        case .plan(let markdown):
            r.plan = markdown.split(whereSeparator: \.isNewline).map(String.init)
            r.options = ThreadRequest.planChoices
        }
    }

    /// The record is handed on if it changed: a new line or one that left, the card's last lines alone (the hot path), the
    /// name alone, or the whole record.
    private func publish(_ id: String, _ e: Entry) {
        let old = shown[id]
        guard var new = compose(id, e) else {
            if old != nil {
                shown[id] = nil
                count(old, nil)
                out.append(.remove(id))
            }
            return
        }
        if let old {
            // The model's own: the order, and the count of the model's lines; words still drawing keep drawing.
            new.order = old.order
            new.sentence.stream = max(old.sentence.stream, new.sentence.stream)
            if old.sentence.phase == .streaming, new.sentence.phase == .settled, new.sentence.text == old.sentence.text {
                new.sentence.phase = .streaming
            }
            guard new != old else { return }
            var reply = old
            reply.lastLines = new.lastLines
            reply.writing = new.writing
            var named = old
            named.name = new.name
            named.naming = new.naming
            if reply == new {
                out.append(.reply(id, text: new.lastLines, writing: new.writing))
            } else if named == new, !new.naming {
                out.append(.named(id, new.name))
            } else {
                out.append(.upsert(new))
            }
        } else {
            out.append(.upsert(new))
        }
        shown[id] = new
        count(old, new)
    }

    /// A verdict's line as it streams: one field of one line; what the page holds follows it.
    private func stream(_ id: String, text: String, done: Bool) {
        guard let e = entries[id], var s = shown[id] else { return }
        s.sentence = .init(text: text, mono: false, phase: .streaming, stream: e.stream, stateWord: s.sentence.stateWord)
        shown[id] = s
        out.append(.words(id, stream: e.stream, text: text, done: done))
    }

    private func project(_ t: AgentThread) -> String? {
        let key = t.folder ?? ""
        if let known = projectNames[key] { return known }
        let name = projectName(t)
        projectNames[key] = name
        return name
    }

    /// T3's title cut to a name, until the model gives one.
    private func fallbackName(_ title: String) -> String {
        if let known = titleNames[title] { return known }
        let name = Self.cut(title)
        if titleNames.count > 2_000 { titleNames = [:] }
        titleNames[title] = name
        return name
    }

    /// `RouterV2.firstWords`, read in one pass over the bytes for a title in ASCII (most are): the words on one line,
    /// 28 characters at most, cut at a word.
    static func cut(_ title: String) -> String {
        let limit = RouterV2.Line.nameCharacters
        var words: [Range<Int>] = []
        var start = -1, flat = 0, i = 0
        for b in title.utf8 {
            if b >= 0x80 { return RouterV2.firstWords(title) }
            let space = b == 0x20 || (b >= 0x09 && b <= 0x0D)
            if space {
                if start >= 0 { words.append(start..<i); flat += i - start + (words.count > 1 ? 1 : 0); start = -1 }
            } else if start < 0 {
                start = i
            }
            i += 1
        }
        if start >= 0 { words.append(start..<i); flat += i - start + (words.count > 1 ? 1 : 0) }
        let bytes = Array(title.utf8)
        func text(_ ranges: ArraySlice<Range<Int>>) -> String {
            var out: [UInt8] = []
            out.reserveCapacity(limit + 4)
            for (n, r) in ranges.enumerated() {
                if n > 0 { out.append(0x20) }
                out.append(contentsOf: bytes[r])
            }
            return String(decoding: out, as: UTF8.self)
        }
        if flat <= limit {
            if words.count == 1, words[0] == 0..<bytes.count { return title }
            return text(words[...])
        }
        var taken = 0, length = 0
        for w in words {
            if length + w.count + (taken == 0 ? 0 : 1) > limit - 1 { break }
            length += w.count + (taken == 0 ? 0 : 1)
            taken += 1
        }
        if taken == 0 { return String(text(words[...]).prefix(limit - 1)) + "…" }
        return text(words[..<taken]) + "…"
    }

    private func count(_ old: RouterV2Thread?, _ new: RouterV2Thread?) {
        let was = old?.section == .needsYou, now = new?.section == .needsYou
        guard was != now else { return }
        needsYou += now ? 1 : -1
        onNeedsYou?(needsYou)
    }

    /// The housekeeping line's threads: finished a day to a week ago and not settled.
    private func housekeeping(_ id: String, _ e: Entry) {
        var o: RouterV2Older?
        if e.scope == .older, e.hidden != true, e.send == nil, let code = e.code, let t = e.thread {
            o = RouterV2Older(id: id, name: t.title, project: project(t), since: code.since)
        }
        guard older[id] != o else { return }
        older[id] = o
        olderChanged = true
    }

    // MARK: Operations and the hold

    /// Runs `body` as one operation: what it changed goes to the page at its end, one change or one batch; while the
    /// window's morph plays, it is kept and goes when still, with everything else that came meanwhile.
    private func operation(_ body: () -> Void) {
        depth += 1
        body()
        depth -= 1
        guard depth == 0 else { return }
        if let b = nextBoundary {
            nextBoundary = nil
            schedule(b)
        }
        if olderChanged {
            olderChanged = false
            out.append(.older(olderLines))
        }
        if savedChanged {
            savedChanged = false
            file?.save(saved)
        }
        notifier?.flush()
        guard !out.isEmpty else { return }
        let changes = out
        out = []
        if holding || gate.holding {
            held += changes
            guard !holding else { return }
            holding = true
            gate.whenStill { [weak self] in self?.release() }
            return
        }
        emit(changes.count == 1 ? changes[0] : .batch(changes))
    }

    private func release() {
        holding = false
        let changes = Self.compact(held)
        held = []
        guard !changes.isEmpty else { return }
        emit(.batch(changes))
    }

    /// What was kept, folded: the last record per thread (an upsert or a remove), then the housekeeping line, the names,
    /// the words and the last lines as they ended, the connection, then refusals, reads and launches in their order.
    static func compact(_ changes: [RouterV2Change]) -> [RouterV2Change] {
        var records: [String: RouterV2Change] = [:], recordOrder: [String] = []
        var words: [String: RouterV2Change] = [:], wordOrder: [String] = []
        var replies: [String: RouterV2Change] = [:], replyOrder: [String] = []
        var names: [String: RouterV2Change] = [:], nameOrder: [String] = []
        var olderList: RouterV2Change?, connection: RouterV2Change?
        var rest: [RouterV2Change] = []
        func keep(_ d: inout [String: RouterV2Change], _ o: inout [String], _ id: String, _ c: RouterV2Change) {
            if d[id] == nil, !o.contains(id) { o.append(id) }
            d[id] = c
        }
        func fold(_ c: RouterV2Change) {
            switch c {
            case .upsert(let t):
                keep(&records, &recordOrder, t.id, c)
                // A whole record carries what came before it.
                words[t.id] = nil; replies[t.id] = nil; names[t.id] = nil
            case .remove(let id):
                keep(&records, &recordOrder, id, c)
                words[id] = nil; replies[id] = nil; names[id] = nil
            case .words(let id, _, _, _): keep(&words, &wordOrder, id, c)
            case .reply(let id, _, _): keep(&replies, &replyOrder, id, c)
            case .named(let id, _): keep(&names, &nameOrder, id, c)
            case .older: olderList = c
            case .connection: connection = c
            case .batch(let all): all.forEach(fold)
            case .refused, .actRefused, .read, .launch: rest.append(c)
            }
        }
        changes.forEach(fold)
        var out = recordOrder.compactMap { records[$0] }
        if let olderList { out.append(olderList) }
        out += nameOrder.compactMap { names[$0] }
        out += wordOrder.compactMap { words[$0] }
        out += replyOrder.compactMap { replies[$0] }
        if let connection { out.append(connection) }
        return out + rest
    }

    // MARK: The clock's one-shot

    /// One timer for the next boundary of any thread; nothing ticks between.
    private func schedule(_ at: Date?) {
        guard let at else { return }
        if let current = boundaryAt, current <= at { return }
        boundaryTimer?.invalidate()
        boundaryAt = at
        let timer = Timer(timeInterval: max(1, at.timeIntervalSinceNow + 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        boundaryTimer = timer
    }

    // MARK: The verdict file

    private func save(_ id: String, _ change: (inout Saved) -> Void) {
        var s = saved[id] ?? Saved()
        change(&s)
        guard s != saved[id] else { return }
        saved[id] = s
        savedChanged = true
    }

    /// A banner was told (or seen on first sight, too old to tell): kept, so it is told once.
    private func tell(_ id: String, _ key: String) {
        save(id) { s in
            guard !s.told.contains(key) else { return }
            s.told = Array((s.told + [key]).suffix(Self.toldKept))
        }
    }

    static let toldKept = 8

    /// T3 has said everything it has: what the file keeps of threads it no longer lists goes.
    private func purge() {
        let gone = saved.keys.filter { entries[$0]?.thread == nil }
        guard !gone.isEmpty else { return }
        for id in gone { saved[id] = nil }
        savedChanged = true
    }
}

// MARK: - Types

extension RouterRecords: RouterActsRecords {}

extension RouterRecords {
    /// What the file keeps per thread.
    struct Saved: Codable, Equatable {
        /// The fingerprint `verdict` is for.
        var fingerprint: String?
        var verdict: RouterVerdict?
        /// "Doesn't need me", on this fingerprint.
        var notForMe: String?
        var name: String?
        /// T3's title when the name was given.
        var nameKey: String?
        /// The banners already told (their keys), the latest few.
        var told: [String] = []
    }

    /// A send T3 hasn't confirmed.
    struct Send: Equatable {
        var words: String
        var status: RouterV2Thread.Sent.Status
        var steering: Bool
        /// The run, its start, the request and the plan as they were at the send: a move of any is T3's word.
        var run: String?
        var runStarted: Date?
        var request: String?
        var plan: Bool
        var at: Date
        var start: Start?
    }

    /// A new thread started here.
    struct Start: Equatable {
        var project: String
        var launch: RouterV2Launch
        var name: String
    }

    struct Landed: Equatable {
        var needsYou: Bool
        var worth: RouterV2Thread.Worth
    }

    struct Seen: Equatable {
        /// `lastVisitedAt` when the card opened.
        var visited: Date?
    }

    final class Entry {
        var thread: AgentThread?
        var detail: RouterDetail?
        var code: RouterCodeState?
        var scope: RouterCodeState.Scope = .out
        var fingerprint = ""
        var boundary: Date?
        /// A verdict call for this fingerprint is queued or running.
        var asked = false
        /// The call for this fingerprint failed: the code's words stay, settled, until the next fingerprint.
        var failed = false
        /// A name call is queued or running.
        var naming = false
        /// The title the name call under way was asked for.
        var namingFor: String?
        /// The title a name call failed for: not asked again until the title changes.
        var nameFailed: String?
        /// The verdict's state, landed before its words.
        var landed: Landed?
        /// Its words so far.
        var words: String?
        /// The store's count of the model's lines for this thread.
        var stream = 0
        var send: Send?
        /// Words queued behind the turn, until T3 lists them; the run under way when they were.
        var queued: String?
        var queuedRun: String?
        /// T3's queued runs you cancelled here, hidden until T3 drops them.
        var cancelled: Set<String> = []
        /// Settle or snooze (true), or its Revert (false), until T3's row agrees.
        var hidden: Bool?
        var seen: Seen?
        var launch: RouterV2Launch?
    }

    /// The pull requests T3 links, with T3's state for each.
    static func linked(_ t: AgentThread) -> [RouterV2Thread.PR] {
        t.pullRequests.compactMap { pr in
            guard let n = pr.number else { return nil }
            return .init(number: n, state: RouterV2Thread.PR.State(rawValue: pr.state?.lowercased() ?? "") ?? .open)
        }
    }
}

// MARK: - The verdict file

/// `Application Support/Fjord/router-verdicts.json`: read off the main thread before the first frame; written off it,
/// coalesced (a burst of changes is one write of the latest), and flushed on quit.
final class RouterVerdictFile: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "fjord.router-verdicts", qos: .utility)
    private let lock = NSLock()
    private var next: [String: RouterRecords.Saved]?
    private var scheduled = false

    init(url: URL) { self.url = url }

    /// `router-verdicts.json` in the app's support folder.
    static func live(_ support: URL) -> RouterVerdictFile {
        RouterVerdictFile(url: support.appendingPathComponent("router-verdicts.json"))
    }

    /// The file's contents, read on a background thread; empty when there is none or it doesn't read.
    static func load(_ url: URL) async -> [String: RouterRecords.Saved] {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: RouterRecords.Saved].self, from: data)) ?? [:]
        }.value
    }

    func save(_ contents: [String: RouterRecords.Saved]) {
        lock.lock()
        next = contents
        let go = !scheduled
        scheduled = true
        lock.unlock()
        if go { queue.async { self.drain() } }
    }

    /// What is still to write, written now.
    func flush() { queue.sync { drain() } }

    private func drain() {
        lock.lock()
        let contents = next
        next = nil
        scheduled = false
        lock.unlock()
        guard let contents, let data = try? JSONEncoder().encode(contents) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
