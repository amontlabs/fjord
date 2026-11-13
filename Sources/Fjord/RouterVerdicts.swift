import Foundation
import OSLog

// The verdict engine (docs/design/router-v2/IMPLEMENTATION.md 1.4): one streamed Haiku call per thread per fingerprint,
// started in the turn the store asks, at most four at once, queued by need (asks, then finished turns newest first, then
// names, then working threads' summaries, then project purposes), cancelled with its process when the thread moves on. What it reads comes back to the
// store as events: the state first, then the line's words as they grow, then the whole verdict; or `failed`, once, after
// its retries. A call that fails is asked again after a backoff (2^n s, capped), one wake scheduled for the earliest; a rate
// limit holds the queue for the time it named (else the backoff) and puts its call back. A cancelled call says nothing,
// and an answer is only told while its call is still the current one.

/// What the store asks for one thread.
struct RouterVerdictRequest: Equatable, Sendable {
    /// In the queue's order.
    enum Kind: Int, Codable, Comparable, Sendable {
        /// T3 asks (question, form, plan, permission): the line that says it.
        case ask
        /// A turn ended: does it need you, is it worth a look, and its line.
        case finished
        /// A thread with no name yet.
        case name
        /// A working thread: a short line of what it is doing now (`RouterSummaryPrompt`), told through `onSummary`.
        case summary

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    var thread: String
    /// The shell row's fingerprint the verdict is for (`RouterRecords`); a late answer is checked against it.
    var fingerprint: String
    var kind: Kind
    var input: RouterVerdictInput
    /// A summary's facts (`kind == .summary` only).
    var summary: RouterSummaryInput?
    /// When it happened (the turn's end, the ask's time): finished turns go newest first.
    var at = Date()
}

/// What the model said of a thread. An ask's verdict has a name and a line; a name's, the name alone.
struct RouterVerdict: Equatable, Sendable, Codable {
    var kind: RouterVerdictRequest.Kind
    var needsYou = false
    var worth: RouterThread.Worth = .quiet
    /// The page's short name (28 characters at most).
    var name = ""
    var line = ""
    /// A step's ask, in a sentence or two (needs you only).
    var ask = ""
    /// A step's options: the words each sends.
    var options: [String] = []
    /// The line it would have if it didn't need you ("Doesn't need me" swaps to it).
    var result = ""

    private enum CodingKeys: String, CodingKey { case kind, needsYou, look, name, line, ask, options, result }

    init(kind: RouterVerdictRequest.Kind, needsYou: Bool = false, worth: RouterThread.Worth = .quiet, name: String = "",
         line: String = "", ask: String = "", options: [String] = [], result: String = "") {
        self.kind = kind; self.needsYou = needsYou; self.worth = worth; self.name = name; self.line = line
        self.ask = ask; self.options = options; self.result = result
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decode(RouterVerdictRequest.Kind.self, forKey: .kind)
        needsYou = try c.decodeIfPresent(Bool.self, forKey: .needsYou) ?? false
        worth = try c.decodeIfPresent(Bool.self, forKey: .look) == true ? .look : .quiet
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        ask = try c.decodeIfPresent(String.self, forKey: .ask) ?? ""
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        result = try c.decodeIfPresent(String.self, forKey: .result) ?? ""
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(needsYou, forKey: .needsYou)
        try c.encode(worth == .look, forKey: .look)
        try c.encode(name, forKey: .name)
        try c.encode(line, forKey: .line)
        try c.encode(ask, forKey: .ask)
        try c.encode(options, forKey: .options)
        try c.encode(result, forKey: .result)
    }
}

/// What the engine tells the store of one call, in this order: `state` (a finished turn's only), `words` as the line
/// grows (`done` once it is whole), `done` with the whole verdict. Or `failed`, once, at any point. A cancelled call
/// tells nothing.
enum RouterVerdictEvent: Equatable, Sendable {
    case state(needsYou: Bool, worth: RouterThread.Worth)
    case words(String, done: Bool)
    case done(RouterVerdict)
    case failed
}

// MARK: - Reading one answer

/// One call's answer read as it comes (pure): the pieces of `PartialJSON` into events, and the whole answer checked.
struct RouterVerdictReading {
    let kind: RouterVerdictRequest.Kind
    private var needsYou: Bool?
    private var worth: RouterThread.Worth?
    private(set) var stateTold = false
    private(set) var lineDone = false
    private var shown = ""

    init(kind: RouterVerdictRequest.Kind) { self.kind = kind }

    mutating func take(_ piece: PartialJSON.Piece) -> [RouterVerdictEvent] {
        switch piece {
        case .field("state", let raw) where kind == .finished:
            needsYou = PartialJSON.string(raw).flatMap(Self.needsYou)
            return stateEvent()
        case .field("worth", let raw) where kind == .finished:
            worth = PartialJSON.string(raw).flatMap(Self.worth)
            return stateEvent()
        case .growing("line", let words) where kind != .name && !lineDone:
            guard kind != .finished || stateTold, words != shown else { return [] }
            shown = words
            return [.words(words, done: false)]
        case .field("line", let raw) where kind != .name && !lineDone:
            let clean: (String) -> String = kind == .summary ? RouterSummaryPrompt.line : Self.flat
            guard kind != .finished || stateTold, let line = PartialJSON.string(raw).map(clean), !line.isEmpty else { return [] }
            lineDone = true
            shown = line
            return [.words(line, done: true)]
        default:
            return []
        }
    }

    private mutating func stateEvent() -> [RouterVerdictEvent] {
        guard !stateTold, let needsYou, let worth else { return [] }
        stateTold = true
        return [.state(needsYou: needsYou, worth: needsYou ? .look : worth)]
    }

    /// The call's end: what wasn't told yet, then the verdict; `failed` when the answer doesn't read.
    mutating func end(_ json: Data?) -> [RouterVerdictEvent] {
        guard let json, let verdict = Self.verdict(json, kind: kind) else { return [.failed] }
        var out: [RouterVerdictEvent] = []
        if kind == .finished, !stateTold {
            stateTold = true
            out.append(.state(needsYou: verdict.needsYou, worth: verdict.worth))
        }
        if kind != .name, !lineDone {
            lineDone = true
            out.append(.words(verdict.line, done: true))
        }
        out.append(.done(verdict))
        return out
    }

    /// The whole answer, checked: a known state and worth, a line (but for a name), a name of 28 characters at most.
    static func verdict(_ json: Data, kind: RouterVerdictRequest.Kind) -> RouterVerdict? {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        func text(_ k: String) -> String { flat(o[k] as? String ?? "") }
        var v = RouterVerdict(kind: kind, name: clipName(text("name")), line: text("line"))
        switch kind {
        case .name:
            guard !v.name.isEmpty else { return nil }
        case .summary:
            v.name = ""
            v.line = RouterSummaryPrompt.line(text("line"))
            guard !v.line.isEmpty else { return nil }
        case .ask:
            guard !v.line.isEmpty else { return nil }
            v.needsYou = true
            v.worth = .look
        case .finished:
            guard let needsYou = (o["state"] as? String).flatMap(Self.needsYou), let worth = (o["worth"] as? String).flatMap(Self.worth),
                  !v.line.isEmpty else { return nil }
            v.needsYou = needsYou
            v.worth = needsYou ? .look : worth
            if needsYou {
                v.ask = text("ask").isEmpty ? v.line : text("ask")
                v.options = Array(((o["options"] as? [Any]) ?? []).compactMap { ($0 as? String).map(flat) }.filter { !$0.isEmpty }.prefix(4))
                v.result = text("result")
            }
        }
        return v
    }

    private static func needsYou(_ s: String) -> Bool? { s == "needs_you" ? true : s == "done" ? false : nil }
    private static func worth(_ s: String) -> RouterThread.Worth? { s == "look" ? .look : s == "quiet" ? .quiet : nil }

    /// One line, spaces collapsed.
    static func flat(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    static func clipName(_ s: String) -> String { s.isEmpty ? s : Router.firstWords(s) }
}

// MARK: - The engine

@MainActor final class RouterVerdicts {
    nonisolated static let cap = 4
    /// Each call's own deadline.
    nonisolated static let timeout: TimeInterval = 60

    /// Every event, with its thread and the fingerprint it is for, on the main actor.
    var onEvent: (String, String, RouterVerdictEvent) -> Void = { _, _, _ in }
    /// A summary call's events (`words`, `done`, `failed`), the same way.
    var onSummary: (String, String, RouterVerdictEvent) -> Void = { _, _, _ in }
    /// Claude Code's binary (`RouterStatus.latestPath`); nil: none found, and an ask fails at once.
    var binary: () -> String?
    let runner: ClaudeStream.Runner
    let log: ModelUsageLog?
    let cap: Int
    /// How long a call may run.
    var timeout = RouterVerdicts.timeout
    /// How many times a call is made before its failure is told (a rate limit doesn't count).
    var attempts = 6
    /// The wait before attempt `n` (1: the first retry), and after the `n`th rate limit in a row that named no time.
    var backoff: (Int) -> TimeInterval = { min(pow(2, Double($0)), RouterVerdicts.maxBackoff) }
    var now: () -> Date = Date.init
    nonisolated static let maxBackoff: TimeInterval = 600
    nonisolated static let maxHold: TimeInterval = 3600

    init(binary: @escaping () -> String?, runner: @escaping ClaudeStream.Runner = ClaudeStream.liveRunner,
         log: ModelUsageLog? = ModelUsageLog.shared, cap: Int = RouterVerdicts.cap) {
        self.binary = binary
        self.runner = runner
        self.log = log
        self.cap = cap
    }

    /// A project's purpose call (`ProjectPurposes`), through the same queue and cap.
    struct PurposeCall {
        var project: String
        var system: String
        var schema: String
        /// Built when the call starts, on the main actor.
        var input: @MainActor () -> String
        var done: @MainActor (String?) -> Void
    }

    private enum Work {
        case verdict(RouterVerdictRequest)
        case purpose(PurposeCall)

        var need: Int {
            switch self {
            case .verdict(let r): r.kind.rawValue
            case .purpose: RouterVerdictRequest.Kind.summary.rawValue + 1
            }
        }

        var at: Date {
            if case .verdict(let r) = self { r.at } else { .distantPast }
        }

        /// A working thread's summary: the most frequent call, it never takes the last slot, and its rate limit holds
        /// only the summaries.
        var isSummary: Bool { if case .verdict(let r) = self { r.kind == .summary } else { false } }
    }

    private struct Job {
        let key: String
        let work: Work
        let token: Int
        /// Calls made before this one (its retries).
        var attempt = 0
        /// Not started before then (a retry's backoff).
        var notBefore: Date?
        /// "Verdict state" (to the state, or an ask's first words) and "Verdict done", from the ask; nil for a purpose.
        var state: RouterSignposts.Interval?
        let done: RouterSignposts.Interval?
        var task: Task<Void, Never>?

        /// Ends what is still open, marked as a call that didn't answer (dropped, cancelled, failed).
        mutating func close() {
            if let state { RouterSignposts.signposter.endInterval(state.name, state.state, "stopped") }
            if let done { RouterSignposts.signposter.endInterval(done.name, done.state, "stopped") }
            state = nil
        }
    }

    private var queued: [Job] = []
    private var running: [String: Job] = [:]
    private var tokens = 0
    /// A rate limit stopped the queue: until the time the API named, or the backoff.
    private(set) var held = false
    private var heldUntil: Date?
    /// A summary hit a rate limit: the summaries wait until then (asks and the rest don't).
    private(set) var summariesHeld = false
    private var summariesHeldUntil: Date?
    /// Rate limits in a row: each one that names no time waits longer.
    private var limits = 0
    /// The one wake scheduled: the hold's end or the earliest retry.
    private var wake: Task<Void, Never>?
    private var wakeAt: Date?

    // MARK: Asking

    /// Asks for a verdict. The same thread, kind and fingerprint already queued or running: nothing. Another fingerprint: the old call
    /// is cancelled (it tells nothing) and this one takes its place. A rate-limit hold keeps its time.
    func ask(_ r: RouterVerdictRequest) {
        let key = Self.key(r.thread, r.kind)
        if case .verdict(let old)? = (running[key] ?? queued.first { $0.key == key })?.work, old.fingerprint == r.fingerprint { return }
        drop(key)
        enqueue(key, .verdict(r))
    }

    /// Cancels every verdict and name call of this thread (a run started, the thread left): its process is terminated,
    /// nothing is told. Its summary is apart (`cancelSummary`).
    func cancel(_ thread: String) {
        for kind in [RouterVerdictRequest.Kind.ask, .finished, .name] { drop(Self.key(thread, kind)) }
    }

    /// Cancels the thread's summary call (it stopped working, it left): nothing is told.
    func cancelSummary(_ thread: String) { drop(Self.key(thread, .summary)) }

    /// A purpose call for a project; a newer one for the same project replaces it.
    func purpose(_ call: PurposeCall) {
        let key = "\u{1}purpose:" + call.project
        drop(key)
        enqueue(key, .purpose(call))
    }

    var runningCount: Int { running.count }
    var queuedCount: Int { queued.count }

    private static func key(_ thread: String, _ kind: RouterVerdictRequest.Kind) -> String {
        switch kind {
        case .name: "\u{1}name:" + thread
        case .summary: "\u{1}summary:" + thread
        case .ask, .finished: thread
        }
    }

    private func enqueue(_ key: String, _ work: Work, attempt: Int = 0, notBefore: Date? = nil) {
        tokens += 1
        // The verdict gates' signposts time verdicts only, not summaries.
        let timed = if case .verdict(let r) = work, r.kind != .summary { true } else { false }
        queued.append(Job(key: key, work: work, token: tokens, attempt: attempt, notBefore: notBefore,
                          state: timed ? RouterSignposts.begin("Verdict state") : nil,
                          done: timed ? RouterSignposts.begin("Verdict done") : nil))
        pump()
    }

    private func drop(_ key: String) {
        if let i = queued.firstIndex(where: { $0.key == key }) {
            queued[i].close()
            queued.remove(at: i)
        }
        if var job = running.removeValue(forKey: key) {
            job.task?.cancel()
            job.close()
            pump()
        }
    }

    /// Starts what the cap allows, by need: asks, finished turns newest first, names, purposes; a retry not before its
    /// time, nothing while a rate limit holds. Summaries keep one slot free for the rest, and wait out their own limit.
    /// Then one wake for the earliest of what waits on the clock.
    private func pump() {
        let now = now()
        if held, (heldUntil ?? .distantFuture) <= now { held = false; heldUntil = nil }
        if summariesHeld, (summariesHeldUntil ?? .distantFuture) <= now { summariesHeld = false; summariesHeldUntil = nil }
        while !held, running.count < cap {
            let summaries = running.values.filter(\.work.isSummary).count
            let summaryRoom = !summariesHeld && summaries < max(1, cap - 1)
            var best: Int?
            for i in queued.indices where (queued[i].notBefore ?? .distantPast) <= now && (summaryRoom || !queued[i].work.isSummary) {
                guard let b = best else { best = i; continue }
                let a = queued[i].work, w = queued[b].work
                if a.need < w.need || a.need == w.need && a.at > w.at { best = i }
            }
            guard let best else { break }
            start(queued.remove(at: best))
        }
        var next = held ? heldUntil : queued.lazy.compactMap(\.notBefore).filter { $0 > now }.min()
        if !held, summariesHeld, let until = summariesHeldUntil, queued.contains(where: \.work.isSummary) {
            next = min(next ?? until, until)
        }
        schedule(next)
    }

    /// One one-shot for the next time the queue may move; none when nothing waits on the clock.
    private func schedule(_ at: Date?) {
        guard at != wakeAt else { return }
        wake?.cancel()
        wakeAt = at
        guard let at else { wake = nil; return }
        let delay = max(0, at.timeIntervalSince(now()))
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.wakeAt = nil
            self.wake = nil
            self.pump()
        }
    }

    // MARK: Running

    private func start(_ job: Job) {
        var job = job
        guard let path = binary() else {
            job.close()
            switch job.work {
            case .verdict(let r): (r.kind == .summary ? onSummary : onEvent)(r.thread, r.fingerprint, .failed)
            case .purpose(let call): call.done(nil)
            }
            return
        }
        let (arguments, kind): ([String], RouterVerdictRequest.Kind?)
        let input: @MainActor () -> Data
        switch job.work {
        case .verdict(let r) where r.kind == .summary:
            (arguments, kind) = (RouterSummaryPrompt.arguments, r.kind)
            let facts = r.summary ?? RouterSummaryInput(title: r.input.title, project: r.input.project)
            input = { Data(RouterSummaryPrompt.text(facts).utf8) }
        case .verdict(let r):
            (arguments, kind) = (RouterVerdictPrompt.arguments(r.kind), r.kind)
            input = { Data(RouterVerdictPrompt.text(r.input, kind: r.kind).utf8) }
        case .purpose(let p):
            (arguments, kind) = (ClaudePrint.arguments(model: RouterVerdictPrompt.model, system: p.system, schema: p.schema,
                                                       effort: "low", streaming: true), nil)
            input = { Data(p.input().utf8) }
        }
        let runner = self.runner, timeout = self.timeout, key = job.key, token = job.token
        // Off the main actor: the process starts at once, its lines are read there; only events hop back. The input (its
        // redaction is about 1.7 ms in a debug build) is built in a turn of its own, not in the one that asked.
        job.task = Task.detached(priority: .userInitiated) { [weak self] in
            let input = await input()
            if Task.isCancelled { return }
            var reader = ClaudeStream.Reader()
            var reading = kind.map(RouterVerdictReading.init)
            var end: ClaudeStream.End?
            var limit: (hit: Bool, after: TimeInterval?) = (false, nil)
            do {
                lines: for try await line in runner(path, arguments, input, timeout) {
                    var events: [RouterVerdictEvent] = []
                    for out in reader.read(line) {
                        switch out {
                        case .piece(let p): if reading != nil { events += reading!.take(p) }
                        case .retry(let status, let after) where status == 429:
                            limit = (true, after)
                            break lines
                        case .retry: break
                        case .end(let e): end = e
                        }
                    }
                    if !events.isEmpty { await self?.tell(key, token, events) }
                    if end != nil { break }
                }
            } catch {}
            if Task.isCancelled { return }
            if let end, end.status == 429 { limit = (true, nil) }
            await self?.ended(key, token, end: end, reading: reading, limit: limit)
        }
        running[key] = job
    }

    /// Events of a call still current.
    private func tell(_ key: String, _ token: Int, _ events: [RouterVerdictEvent]) {
        guard let job = running[key], job.token == token, case .verdict(let r) = job.work else { return }
        for e in events {
            if case .failed = e {
                running[key]?.close()
            } else if let state = running[key]?.state {
                RouterSignposts.end(state, afterCommit: true)
                running[key]?.state = nil
            }
            if case .done = e, let done = job.done { RouterSignposts.end(done, afterCommit: true) }
            (r.kind == .summary ? onSummary : onEvent)(r.thread, r.fingerprint, e)
        }
    }

    private func ended(_ key: String, _ token: Int, end: ClaudeStream.End?, reading: RouterVerdictReading?,
                       limit: (hit: Bool, after: TimeInterval?)) {
        guard let job = running[key], job.token == token else { return }
        if let end {
            let model = reading.map { RouterVerdictPrompt.model($0.kind) } ?? RouterVerdictPrompt.model
            log?.record(role: reading == nil ? .purpose : reading?.kind == .summary ? .summary : .verdict, model: model, end.usage)
        }
        if limit.hit {
            // The call goes back in the queue, and the queue waits for the limit's time.
            limits += 1
            running[key] = nil
            var job = job
            job.close()
            let after = min(max(limit.after ?? backoff(limits), 0), Self.maxHold)
            if job.work.isSummary {
                // A summary's limit holds only the summaries: asks and finished turns go on.
                summariesHeld = true
                summariesHeldUntil = now().addingTimeInterval(after)
            } else {
                hold(after)
            }
            enqueue(key, job.work, attempt: job.attempt)
            return
        }
        switch job.work {
        case .verdict:
            var reading = reading ?? RouterVerdictReading(kind: .finished)
            let events = end.flatMap { $0.error == nil ? $0.json : nil }.map { reading.end($0) } ?? [.failed]
            if events.last == .failed, job.attempt + 1 < attempts {
                // Asked again after its backoff; the line stays being read meanwhile.
                running[key] = nil
                var job = job
                job.close()
                let attempt = job.attempt + 1
                enqueue(key, job.work, attempt: attempt, notBefore: now().addingTimeInterval(backoff(attempt)))
                return
            }
            if events.last != .failed { limits = 0 }
            tell(key, token, events.last == .failed ? [.failed] : events)
        case .purpose(let call):
            let purpose = end?.json.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["purpose"] as? String
            call.done(purpose.map(RouterVerdictReading.flat).flatMap { $0.isEmpty ? nil : $0 })
        }
        if running[key]?.token == token { running[key] = nil }
        pump()
    }

    /// Stops the queue after a rate limit for `after` seconds (capped); `pump` schedules its end.
    private func hold(_ after: TimeInterval) {
        held = true
        heldUntil = now().addingTimeInterval(min(max(after, 0), Self.maxHold))
    }
}
