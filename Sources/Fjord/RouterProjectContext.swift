import Foundation

// What the project decider (`RouterProjectDecider`) reads: the claude.ai projects on the engine's Board, each with its
// threads and what each one is doing, did and was last told, and your last routings. Measured on 182 real moments
// (docs/design/router-redesign.md, "Routing on real moments", C to F): the lines and cuts are manager_eval.py's `render`
// (rich) and pcmp/rund.py's (variant D), ported as they were. Local sessions count only as a thread's context: a thread
// the Board ties to a local session gets that session's activity, summary and last-told words.

struct RouterProjectContext: Equatable, Sendable {
    struct Told: Equatable, Sendable {
        var text: String
        var minutesAgo: Int
    }

    /// Something a thread waits on you for: its kind ("question", "plan", "asks", "approval", "permission", "needs") and words.
    struct Waiting: Equatable, Sendable {
        var kind: String
        var text: String
    }

    struct Thread: Equatable, Sendable {
        var id: String
        var title: String
        var running: Bool
        var minutesIdle: Int
        /// What it is on right now (running only).
        var doing = ""
        var summary = ""
        var lastAnswer = ""
        var told: Told? = nil
        var waiting: [Waiting] = []
    }

    struct Project: Equatable, Sendable {
        /// The Board's id (`chan_…`); `name` is what targets name it by (`RouterCourier.Target`).
        var id: String
        var name: String
        var purpose = ""
        /// Most recent first.
        var threads: [Thread] = []

        var minutesIdle: Int? { threads.map(\.minutesIdle).min() }
    }

    /// One of your earlier messages and where it went; `correctedTo` when you sent it somewhere else than suggested.
    struct Routing: Equatable, Sendable {
        var text: String
        var to: String
        var correctedTo: String? = nil
    }

    /// How many of your last routings the board shows (the recipe's E: the last 8).
    static let routingCount = 8

    /// Most recently active first (a project by its latest thread; those with none last, by name).
    private(set) var projects: [Project]
    /// Oldest first, the last `routingCount`.
    private(set) var routings: [Routing]

    init(projects: [Project], routings: [Routing] = []) {
        self.projects = projects.map { p in
            var p = p
            p.threads = p.threads.enumerated().sorted { ($0.element.minutesIdle, $0.offset) < ($1.element.minutesIdle, $1.offset) }.map(\.element)
            return p
        }.enumerated().sorted { a, b in
            switch (a.element.minutesIdle, b.element.minutesIdle) {
            case let (x?, y?): (x, a.offset) < (y, b.offset)
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): (a.element.name, a.offset) < (b.element.name, b.offset)
            }
        }.map(\.element)
        self.routings = Array(routings.suffix(Self.routingCount))
    }

    /// Every thread, most recent first, with its project.
    var threads: [(project: Project, thread: Thread)] {
        projects.flatMap { p in p.threads.map { (p, $0) } }.enumerated()
            .sorted { ($0.element.1.minutesIdle, $0.offset) < ($1.element.1.minutesIdle, $1.offset) }.map(\.element)
    }

    func project(named name: String) -> Project? { projects.first { $0.name == name } ?? projects.first { $0.id == name } }
    func thread(_ id: String) -> (project: Project, thread: Thread)? { threads.first { $0.thread.id == id } }
}

// MARK: - Text as the measured runs cut it

extension RouterProjectContext {
    /// manager_eval.py's `SAID_CHARS`: the end of a thread's last answer.
    static let saidChars = 600

    /// `age()`: 5m, 3h, 2d.
    static func age(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }

    /// `redact(text)[:n]`: keys, tokens and account numbers out first (boards.py's patterns, `RouterTools.redacted`).
    @MainActor static func head(_ text: String, _ n: Int) -> String { String(RouterTools.redacted(text).prefix(n)) }
    /// `redact(text)[-n:]`.
    @MainActor static func tail(_ text: String, _ n: Int) -> String { String(RouterTools.redacted(text).suffix(n)) }

    /// The lines under a thread, as `render(rich)` writes them, each without its indent: the flags line, then doing, summary,
    /// what you last told it, its last answer and what it waits on you for. rund.py puts the same lines in Jev's options.
    @MainActor static func lines(_ t: Thread) -> [String] {
        var out = ["\(t.running ? "running" : "idle"), \(age(t.minutesIdle)) ago"]
        if !t.doing.isEmpty { out.append("doing: \(head(t.doing, 240))") }
        if !t.summary.isEmpty { out.append("summary: \(head(t.summary, 300))") }
        if let told = t.told { out.append("you last told it (\(age(told.minutesAgo)) ago): \(head(told.text, 200))") }
        if !t.lastAnswer.isEmpty { out.append("its last answer: \(tail(t.lastAnswer, saidChars))") }
        for w in t.waiting { out.append("waiting (\(w.kind)): \(head(w.text, 300))") }
        return out
    }

    /// The recipe's routing line: “words” → where (the correction when you made one).
    @MainActor static func line(_ r: Routing) -> String {
        let words = UntrustedText.clean(RouterTools.redacted(r.text), limit: 101).prefix(100)
        let to = r.correctedTo.map { "\(UntrustedText.clean($0, limit: 80)) (you corrected it from \(UntrustedText.clean(r.to, limit: 80)))" }
            ?? UntrustedText.clean(r.to, limit: 80)
        return "“\(words)” → \(to)"
    }

    /// Sonnet's board: your last routings, then each project with its threads, most recent first, as `render(rich)` writes
    /// sessions (a thread's id is what `follow_up` names). A known purpose is one line under the project.
    @MainActor func board() -> String {
        var out: [String] = []
        if !routings.isEmpty {
            out.append("## Your last routings (oldest first)")
            out += routings.map(Self.line)
            out.append("")
        }
        for p in projects {
            out.append("## \(p.name)")
            if !p.purpose.isEmpty { out.append("about: \(Self.head(p.purpose, 300))") }
            for t in p.threads {
                let lines = Self.lines(t)
                out.append("- \(t.id) | \(RouterTools.redacted(t.title)) | \(lines[0])")
                out += lines.dropFirst().map { "  " + $0 }
            }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - From the app

extension RouterProjectContext {
    /// What the app knows of a thread's local session, when the Board ties one to it.
    struct LocalFacts: Equatable, Sendable {
        var doing = ""
        var summary = ""
        var told: Told? = nil
        var waiting: [Waiting] = []
    }

    /// The local session a Board thread stands for: its subject (`local:<cli>`) or its `session` key (`cli:<cli>`, or a
    /// bridge id that the local read maps to its cli).
    static func cli(ofThread t: JSON, local: JSON?) -> String? {
        let id = t["id"]?.asString ?? ""
        if id.hasPrefix("local:") { return String(id.dropFirst(6)) }
        guard let key = t.get("session")?.asString, !key.isEmpty else { return nil }
        if key.hasPrefix("cli:") { return String(key.dropFirst(4)) }
        return local?["sessions"]?.get(key)?.get("cli")?.asString
    }

    /// From the engine's Board (`CourierHost.board()`): its claude.ai projects (never `local:` ones, as `CourierSnapshot`),
    /// each thread with the Board's state, detail (summary), result (last answer) and needs, and what `facts` adds for its local
    /// session (by cli). `now` in seconds since 1970, as the Board's times.
    static func from(board: JSON, local: JSON? = nil, now: Double, routings: [Routing] = [],
                     facts: (String) -> LocalFacts? = { _ in nil }) -> RouterProjectContext {
        let threads = board["threads"]?.asObject?.values ?? []
        var projects: [Project] = []
        for p in board["projects"]?.asObject?.values ?? [] {
            guard let id = p["id"]?.asString, !id.hasPrefix("local:"), let name = p["name"]?.asString, !name.isEmpty else { continue }
            var project = Project(id: id, name: name, purpose: p.get("purpose")?.asString ?? "")
            for t in threads where t["project"]?.asString == id {
                guard let tid = t["id"]?.asString else { continue }
                let state = t.get("state")?.asString ?? ""
                let touched = t.get("active")?.numeric ?? t.get("touched")?.numeric ?? now
                var thread = Thread(id: tid, title: t.get("title")?.asString ?? "", running: state == "working",
                                    minutesIdle: max(0, Int((now - touched) / 60)),
                                    summary: t.get("detail")?.asString ?? "", lastAnswer: t.get("result")?.asString ?? "")
                if state == "needs_you", let needs = t.get("needs")?.asString, !needs.isEmpty {
                    thread.waiting = [Waiting(kind: "needs", text: needs)]
                }
                if let cli = cli(ofThread: t, local: local), let f = facts(cli) {
                    if thread.running { thread.doing = f.doing }
                    if !f.summary.isEmpty { thread.summary = f.summary }
                    thread.told = f.told
                    if !f.waiting.isEmpty { thread.waiting = f.waiting }
                }
                project.threads.append(thread)
            }
            projects.append(project)
        }
        return RouterProjectContext(projects: projects, routings: routings)
    }

    /// The app's context: the Board as the engine last folded it, the local sessions as the engine's `local` input
    /// (`CourierLocal.read()`, for bridge ids), the app's sessions, activity, cards and what you told them, and your last
    /// routings from the history.
    @MainActor static func gather(board: JSON, local: JSON? = nil, store: Store, now: Date = Date()) -> RouterProjectContext {
        let told = store.lastTold()
        let cards = store.routerShownOpenCards
        let byCLI = Dictionary(store.claudeSessions.values.compactMap { s in s.cliID.map { ($0, s) } }, uniquingKeysWith: { a, b in
            a.lastActivity >= b.lastActivity ? a : b
        })
        return from(board: board, local: local, now: now.timeIntervalSince1970, routings: routings(store)) { cli in
            guard let s = byCLI[cli] else { return nil }
            var f = LocalFacts(summary: s.summary?.detail ?? "")
            if s.running { f.doing = store.claudeActivity[s.id]?.text ?? "" }
            if let t = told[s.id] { f.told = Told(text: t.text, minutesAgo: max(0, Int(now.timeIntervalSince(t.at) / 60))) }
            f.waiting = cards.filter { $0.sessionID == s.id && RouterTools.waitsOnYou.contains($0.kind) }
                .sorted { $0.createdAt < $1.createdAt }
                .map { Waiting(kind: $0.kind.modelName, text: $0.text) }
            return f
        }
    }

    /// Your last messages and where each went, oldest first: the decision log's own messages, a correction with where you sent it instead.
    @MainActor static func routings(_ store: Store) -> [Routing] {
        var out: [Routing] = []
        for entry in store.router.decisions {
            guard case .you(let text) = entry.trigger, let to = entry.decision.target ?? entry.decision.intent, !to.isEmpty else { continue }
            var r = Routing(text: text, to: to)
            if case .corrected(let from, let instead) = entry.outcome { r.to = from; r.correctedTo = instead }
            out.append(r)
        }
        return Array(out.suffix(routingCount))
    }
}
