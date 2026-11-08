import Foundation

// The board the decider reads (docs/design/t3-research/decider-board-spec.md): what it knows of every thread that could take
// a message, the projects a new thread could start in, and Fjord itself. This is `render_board` and `candidates` of the E3 run
// (`deciders-t3/common.py`) ported one to one: the same lines, cuts, order and redaction, pinned against that Python by
// `DeciderBoardTests` on invented boards. The same text goes to Sonnet and to the live decision log.

struct DeciderBoard: Equatable, Sendable {
    /// What a thread is doing, as the board says it.
    enum Flag: Equatable, Sendable {
        case running
        /// Waits on you: a question, a permission or a plan. `Thread.running` says whether it also runs.
        case waiting
        case finished
    }

    struct Thread: Equatable, Sendable {
        /// The id the model names it by (short); `key` is what it stands for.
        var id: String
        /// T3's thread id.
        var key: String
        /// The project it belongs to, by the name the board shows.
        var project: String
        var title: String
        var flag: Flag
        /// A run is under way (a waiting thread can be running too).
        var running: Bool
        var minutesIdle: Int
        /// The thread's own summary, when it has no last message.
        var summary = ""
        /// What it is on now (a running thread only).
        var step = ""
        /// Its latest visible message.
        var said = ""
        /// Your last message there; nil: none known.
        var youSaid: String?
        /// Your message is the latest one in the thread, so it came after `said`.
        var youSaidLast = false
        /// Its git branch, when it has one.
        var branch = ""
        /// Its pull requests, each as `#12 open`.
        var pullRequests: [String] = []
        /// The request it waits on, as text; nil: none.
        var waiting: String?
        // What only Jev's board reads (E5, `RouterJevPath.swift`); Sonnet's text above doesn't show them.
        /// The thread's first ask, when it is known.
        var first = ""
        /// Your last few messages there, oldest first.
        var earlier: [String] = []
        /// How long ago your last message there was; nil: not known.
        var youSaidMinutes: Int?
        /// Your latest message (across all threads) went to this one.
        var youLatest = false

        init(id: String, key: String? = nil, project: String, title: String, flag: Flag, running: Bool? = nil, minutesIdle: Int,
             summary: String = "", step: String = "", said: String = "", youSaid: String? = nil, youSaidLast: Bool = false,
             branch: String = "", pullRequests: [String] = [], waiting: String? = nil, first: String = "", earlier: [String] = [],
             youSaidMinutes: Int? = nil, youLatest: Bool = false) {
            self.id = id
            self.key = key ?? id
            self.project = project
            self.title = title
            self.flag = flag
            self.running = running ?? (flag == .running)
            self.minutesIdle = minutesIdle
            self.summary = summary
            self.step = step
            self.said = said
            self.youSaid = youSaid
            self.youSaidLast = youSaidLast
            self.branch = branch
            self.pullRequests = pullRequests
            self.waiting = waiting
            self.first = first
            self.earlier = earlier
            self.youSaidMinutes = youSaidMinutes
            self.youLatest = youLatest
        }
    }

    /// Every project a new thread could start in, in a stable order (ties in recency keep it).
    var projects: [String]
    /// A project's purpose sentence; none: "unknown".
    var purposes: [String: String] = [:]
    /// A project's T3 id by the name the board shows it under; a name missing here stands for itself.
    var projectIDs: [String: String] = [:]
    /// A project's GitHub repository (`owner/name`) by the name the board shows it under, for those that have one.
    var projectRepos: [String: String] = [:]
    /// Every thread that may be shown: not archived, settled, snoozed or unlisted.
    var threads: [Thread]

    // MARK: Candidates (spec, rules 1 to 3)

    /// Finished threads count only within the last 12 hours.
    static let finishedWithinMinutes = 720
    /// The latest finished threads kept per project.
    static let finishedPerProject = 3
    /// Threads on the board, running and waiting ones never cut.
    static let cap = 20
    /// Threads a project's "last threads" names, and the cut of each title.
    static let lastThreads = 3

    /// Stable: equal recency keeps the given order.
    private static func byRecency(_ threads: [Thread]) -> [Thread] {
        threads.enumerated().sorted { ($0.element.minutesIdle, $0.offset) < ($1.element.minutesIdle, $1.offset) }.map(\.element)
    }

    /// The threads on the board: all that run or wait, then the latest 3 finished of each project within 12 hours, newest first,
    /// until the board holds 20 threads.
    var candidates: [Thread] {
        let live = threads.filter { $0.flag != .finished }
        var order: [String] = []
        var finished: [String: [Thread]] = [:]
        for t in Self.byRecency(threads) where t.flag == .finished && t.minutesIdle <= Self.finishedWithinMinutes {
            if finished[t.project] == nil { order.append(t.project) }
            finished[t.project, default: []].append(t)
        }
        let pool = Self.byRecency(order.flatMap { Array(finished[$0, default: []].prefix(Self.finishedPerProject)) })
        return live + pool.prefix(max(0, Self.cap - live.count))
    }

    // MARK: Text (common.py's `one`, `tail`, `ageS`)

    /// Whitespace as Python's `str.split()` sees it.
    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || (0x1C...0x1F).contains(s.value)
    }

    @MainActor private static func collapsed(_ text: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var pending = false
        for s in RouterTools.redacted(text).unicodeScalars {
            if isSpace(s) { pending = !out.isEmpty; continue }
            if pending { out.append(" "); pending = false }
            out.append(s)
        }
        return out
    }

    private static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: scalars)
        return String(v)
    }

    /// `redact`, one line, the first `n` characters.
    @MainActor static func one(_ text: String, _ n: Int) -> String { string(collapsed(text).prefix(n)) }
    /// `redact`, one line, the last `n` characters.
    @MainActor static func tail(_ text: String, _ n: Int) -> String { string(collapsed(text).suffix(n)) }

    /// `5m`, `3h`, `2d`.
    static func age(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }

    // MARK: The board (spec, "Board text")

    static let fjordLine = "- here | Fjord itself: a question about the board or all threads, or a bare acknowledgement"

    /// The text the model reads. No trailing newline.
    @MainActor func render() -> String {
        let shown = candidates
        let all = Self.byRecency(threads)
        var by: [String: [Thread]] = [:]
        for t in shown { by[t.project, default: []].append(t) }
        var allBy: [String: [Thread]] = [:]
        for t in all { allBy[t.project, default: []].append(t) }
        let best = allBy.mapValues { $0.map(\.minutesIdle).min() ?? Int.max }
        let order = projects.enumerated().sorted { (best[$0.element] ?? Int.max, $0.offset) < (best[$1.element] ?? Int.max, $1.offset) }
            .map(\.element)
        var lines: [String] = []
        for p in order {
            lines.append("## \(p)")
            let titles = allBy[p, default: []].prefix(Self.lastThreads).map { Self.one($0.title, 60) }
            var head = "- new in \(p) | start a new thread here | purpose: \(purposes[p] ?? "unknown")"
            if !titles.isEmpty { head += " | last threads: \(titles.joined(separator: "; "))" }
            lines.append(head)
            for t in by[p, default: []] { lines += Self.lines(t) }
        }
        lines.append("## Fjord")
        lines.append(Self.fjordLine)
        return lines.joined(separator: "\n")
    }

    /// A thread's line and the lines under it (each indented), as the board writes them.
    @MainActor static func lines(_ t: Thread) -> [String] {
        let status: String
        switch t.flag {
        case .running: status = "running (a message would interrupt it)"
        case .waiting: status = t.running ? "waiting on you, running" : "waiting on you"
        case .finished: status = "finished"
        }
        var out = ["- \(t.id) | \(one(t.title, 80)) | \(status), \(age(t.minutesIdle)) ago"]
        var last = tail(t.said, 600)
        if last.isEmpty { last = one(t.summary, 300) }
        if !last.isEmpty { out.append("  last message: \(last)") }
        if let you = t.youSaid {
            out.append("  \(t.youSaidLast && !last.isEmpty ? "you said after that" : "you last said there"): \(one(you, 200))")
        }
        if !t.branch.isEmpty || !t.pullRequests.isEmpty {
            var line = "  git:"
            if !t.branch.isEmpty { line += " branch \(one(t.branch, 60))" }
            if !t.pullRequests.isEmpty { line += (t.branch.isEmpty ? "" : ",") + " pull requests " + t.pullRequests.prefix(3).map { one($0, 40) }.joined(separator: ", ") }
            out.append(line)
        }
        if t.flag == .running, !t.step.isEmpty { out.append("  current step: \(one(t.step, 200))") }
        if let waiting = t.waiting { out.append("  waiting request: \(one(waiting, 300))") }
        return out
    }

    // MARK: Looking things up

    func projectID(_ name: String) -> String { projectIDs[name] ?? name }
    /// The project whose repository is `repo` (compared without case), when exactly one is; nil: none, or several.
    func project(forRepo repo: String?) -> String? {
        guard let repo = repo?.lowercased(), !repo.isEmpty else { return nil }
        let hits = projects.filter { projectRepos[$0]?.lowercased() == repo }
        return hits.count == 1 ? hits[0] : nil
    }
    func thread(id: String) -> Thread? { threads.first { $0.id == id } }
    /// The project a name the model gave stands for (the board shows names as they are).
    func project(named name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.first { $0 == name }
    }
}
