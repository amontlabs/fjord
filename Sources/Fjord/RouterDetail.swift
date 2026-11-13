import Foundation

/// What a Router v2 line and its card read of one thread, made by pure functions from the thread's projection
/// (docs/design/router-v2/IMPLEMENTATION.md 1.7). A value: the store keeps one per watched thread and compares it with the
/// last, so a projection event that moves none of these fields changes nothing on the page.
struct RouterDetail: Equatable {
    /// What a running thread is on right now.
    struct Working: Equatable {
        var text: String
        /// The text is a command (drawn in mono).
        var mono: Bool
        /// When the run began.
        var since: Date
    }

    /// Words queued behind the turn under way, with the run T3 made for them (what Cancel takes back).
    struct Queued: Equatable, Identifiable {
        var id: String
        var words: String
    }

    /// The working line; nil when no run is live.
    var working: Working?
    /// The to-do list's steps, from the live run's list, else the latest run's; empty without one (T3's to-do setting).
    var steps: [RouterThread.Step] = []
    /// The agent's last message, whole.
    var reply = ""
    /// That message is still being written.
    var writing = false
    /// Your last words there (the verdict reads them; the shell carries none).
    var youSaid: String?
    /// The question, permission or plan it waits on.
    var request: ThreadRequest?
    var queued: [Queued] = []
    /// The latest turn's changes: its checkpoints summed. Nil when it changed no file.
    var diff: RouterThread.Diff?
    /// The last thing a run that did not finish was doing (its last tool item); nil for any other run.
    var lastStep: String?
    /// Its agent takes words mid-turn.
    var steers = true
    /// Its subagents, background commands and waits.
    var activity = RouterActivity()
    /// A live run's raw detail: the tool or command running now and the few before it, newest first (the working peek's).
    var workNow: RouterWork.Step?
    var workRecent: [RouterWork.Step] = []
    /// The agent's latest whole words in the live run, and their message: what a working summary reads (one being
    /// written isn't news yet).
    var said: String?
    var saidID: String?
    /// The kind of tool running now ("command", T3's tool name): a summary's fingerprint has it.
    var toolKind: String?
    /// What started each of the latest runs, by run id: the working card's timeline shows it under the run's summaries.
    var starts: [String: RouterWork.Start] = [:]
    /// When each of those runs started (T3's `startedAt`, else `requestedAt`): their history entries' time.
    var startedAt: [String: Date] = [:]

    /// Reads a projection. `now` stands in for a missing run start.
    static func make(_ p: T3Projection, now: Date) -> RouterDetail {
        var d = RouterDetail()
        let active = p.activeRun
        let latest = p.runs.last(where: { !$0.isQueued })
        let current = active ?? latest

        // Steps: the current run's list, the last one it wrote.
        if let current {
            d.steps = steps(of: p.turnItems.lazy.filter { $0.runId == nil || $0.runId == current.id })
        }

        // Working.
        if let active {
            let items = p.turnItems.filter { $0.runId == nil || $0.runId == active.id }
            let since = (active.startedAt ?? active.requestedAt).flatMap(AgentThread.date) ?? now
            d.working = working(items, steps: d.steps, messages: p.messages, since: since)
            work(&d, items, messages: p.messages, now: now)
        } else if p.thread.status.isLive, !(p.thread.status == .queued) {
            d.working = Working(text: Router.Copy.starting, mono: false,
                                since: p.thread.activityRunStartedAt.flatMap(AgentThread.date) ?? now)
        }

        // The reply and whether it is still being written.
        if let message = p.messages.last(where: { $0.role == "assistant" && (!$0.text.isEmpty || $0.streaming) }) {
            d.reply = message.text
            d.writing = message.streaming
        } else if let item = p.turnItems.last(where: { if case .assistantMessage(_, let t, let s) = $0.detail { !t.isEmpty || s } else { false } }),
                  case .assistantMessage(_, let text, let streaming) = item.detail {
            d.reply = text
            d.writing = streaming
        }

        d.request = ThreadRequest(p)
        d.youSaid = p.messages.last(where: { $0.role == "user" && !$0.text.isEmpty })?.text

        // Only your own words: T3's own queued messages (a delegated task's completion) aren't yours to see or cancel.
        d.queued = p.ownQueuedRuns.compactMap { run in
            guard let id = run.userMessageId, let words = p.messages.first(where: { $0.id == id })?.text, !words.isEmpty else { return nil }
            return Queued(id: run.id, words: words)
        }

        // The diff: the latest turn's checkpoints, summed.
        if let latest {
            let mine = p.checkpoints.filter { $0.runId == latest.id }
            let files = mine.reduce(0) { $0 + $1.fileCount }
            if files > 0 {
                d.diff = .init(files: files, added: mine.reduce(0) { $0 + $1.additions }, removed: mine.reduce(0) { $0 + $1.deletions })
            }
        }

        // The failed run's last step: its last tool item.
        if let latest, [.failed, .interrupted, .cancelled].contains(latest.status),
           let item = p.turnItems.last(where: { $0.runId == latest.id && ThreadWork.isTool($0) && !isThinking($0) }) {
            d.lastStep = ThreadWork.describe(item)
        }

        d.steers = ThreadSender.steers(session: p.capabilities, driver: p.thread.providerInstanceId)
        d.activity = RouterActivity.make(p)
        d.starts = starts(p)
        for run in p.runs.filter({ !$0.isQueued }).suffix(startsKept) {
            if let at = (run.startedAt ?? run.requestedAt)?.date { d.startedAt[run.id] = at }
        }
        return d
    }

    // MARK: Run starts

    /// The runs whose start is read: as many as summaries are kept, each on its own run at most.
    static let startsKept = 20

    /// What started each of the latest runs, from its message's fields as T3 sets them (who wrote it, the delegated
    /// completion or notification T3 queued it with, the limit recovery's message), never from the words.
    static func starts(_ p: T3Projection) -> [String: RouterWork.Start] {
        let runs = p.runs.filter { !$0.isQueued }.suffix(startsKept)
        let wanted = Set(runs.compactMap(\.userMessageId))
        guard !wanted.isEmpty else { return [:] }
        var messages: [String: T3Message] = [:]
        for m in p.messages where wanted.contains(m.id) { messages[m.id] = m }
        var out: [String: RouterWork.Start] = [:]
        for run in runs {
            if let id = run.userMessageId, let m = messages[id], let start = start(m, p) { out[run.id] = start }
        }
        return out
    }

    /// One run's start from its message. Nil: your message with no words (only attachments), nothing to quote.
    static func start(_ m: T3Message, _ p: T3Projection) -> RouterWork.Start? {
        if let ids = m.delegatedTaskIds { return .subagents(subagentTitles(p, ids: ids, child: nil)) }
        if let n = m.notification {
            switch n.kind {
            case "delegated_task", "subagent": return .subagents(subagentTitles(p, ids: [], child: n.childThreadId))
            case "command": return .command(commandLabel(n.summary))
            default: return .woken
            }
        }
        guard m.createdBy == "user" else { return .woken }
        // T3's own "continue" once a usage limit resets is stamped as yours; its id is the recovery's
        // (`UsageLimitRecoveryWorker`: `limit-resume:<thread>:<run>:<request>`).
        if m.creationSource == "server", m.id.hasPrefix(limitResumePrefix) { return .usageLimit }
        let words = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : .asked(words)
    }

    static let limitResumePrefix = "limit-resume:"

    /// The subagents' titles (else their prompt's first line), by their ids or their own thread, in T3's order.
    private static func subagentTitles(_ p: T3Projection, ids: [String], child: String?) -> [String] {
        let agents = p.others["subagents"] ?? []
        let picked: [T3JSON] = child.map { c in agents.filter { $0.str("childThreadId") == c } }
            ?? ids.compactMap { id in agents.first { $0.str("id") == id } }
        return picked.compactMap { a in
            let title = (a.str("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty ? firstLine(a.str("prompt") ?? "") : title
            return name.isEmpty ? nil : name
        }
    }

    /// The command a `command` notification names: T3 writes its summary as `Command "<label>" finished (exit 0)`
    /// (`backgroundWorkNotification`), the label the command's first line; nil when it names none, or several.
    static func commandLabel(_ summary: String) -> String? {
        guard let open = summary.firstIndex(of: "\""), let close = summary.lastIndex(of: "\""), open < close else { return nil }
        let label = summary[summary.index(after: open)..<close]
        return label.isEmpty || label.contains("\"") ? nil : String(label)
    }

    // MARK: Pieces

    /// The peek's steps and a summary's input, from the live run's items read once from their end: the tool running now,
    /// the three before it, the latest whole words.
    static let recentSteps = 3
    /// How far back from the run's end the walk looks: a long tool-only stretch is not walked whole on every T3 event
    /// (no words in it: `said` is nil).
    static let workScan = 200

    private static func work(_ d: inout RouterDetail, _ items: [T3TurnItem], messages: [T3Message], now: Date) {
        var tools: [RouterWork.Step] = []
        var kind: String?
        var running = false
        for item in items.suffix(workScan).reversed() {
            if d.said == nil, case .assistantMessage(let id, var text, let streaming) = item.detail, !streaming {
                if text.isEmpty { text = messages.first { $0.id == id }?.text ?? "" }
                if !text.isEmpty { d.said = text; d.saidID = id.isEmpty ? item.id : id }
            } else if tools.count <= recentSteps, ThreadWork.isTool(item), !isThinking(item) {
                if tools.isEmpty {
                    running = item.status == "running" || item.status == "waiting"
                    kind = toolKind(item)
                }
                tools.append(workStep(item, now: now))
            }
            if d.said != nil, tools.count > recentSteps { break }
        }
        if running, let first = tools.first {
            d.workNow = first
            d.toolKind = kind
            d.workRecent = Array(tools.dropFirst())
        } else {
            d.workRecent = Array(tools.prefix(recentSteps))
        }
    }

    /// One tool call as the peek lists it: its own words, else a command's first line (mono), else the tool's name and
    /// main object. Its id is its place in the run; its time when it started.
    private static func workStep(_ i: T3TurnItem, now: Date) -> RouterWork.Step {
        let at = (i.raw.ts("startedAt") ?? i.updatedAt).flatMap(AgentThread.date) ?? now
        if let own = ownDescription(i) { return .init(id: i.ordinal, text: own, at: at) }
        if case .commandExecution(let input, _, _) = i.detail {
            let line = firstLine(input)
            return line.isEmpty ? .init(id: i.ordinal, text: "Running a command", at: at) : .init(id: i.ordinal, text: line, mono: true, at: at)
        }
        if case .fileChange(let name, _, _) = i.detail, !name.isEmpty {
            return .init(id: i.ordinal, text: "Edited " + (name as NSString).lastPathComponent, at: at)
        }
        return .init(id: i.ordinal, text: plainLabel(i), at: at)
    }

    private static func toolKind(_ i: T3TurnItem) -> String {
        switch i.detail {
        case .commandExecution: "command"
        case .fileChange: "edit"
        case .dynamicTool(let name): name
        default: i.type.rawValue
        }
    }

    private static func steps(of items: some Sequence<T3TurnItem>) -> [RouterThread.Step] {
        var last: [T3TodoStep] = []
        for i in items { if case .todoList(_, let s) = i.detail, !s.isEmpty { last = s } }
        return last.enumerated().map { n, s in
            .init(id: n, text: s.text, state: s.status == "completed" ? .done : s.status == "running" ? .running : .pending)
        }
    }

    /// What the line says, first match wins: the running to-do step; the running tool's own description (T3's `title`, or a
    /// `description` the item carries); the first sentence of the agent's latest words in this run; a plain label from the
    /// tool kind and its main object; a command in mono, first line only, as the last resort. "starting" before any item.
    private static func working(_ items: [T3TurnItem], steps: [RouterThread.Step], messages: [T3Message], since: Date) -> Working {
        func plain(_ t: String) -> Working { Working(text: t, mono: false, since: since) }
        if let step = steps.first(where: { $0.state == .running }) { return plain(sentence(step.text)) }
        func live(_ i: T3TurnItem) -> Bool { i.status == "running" || i.status == "waiting" }
        let tool = items.last(where: { ThreadWork.isTool($0) && !isThinking($0) && live($0) })
        if let tool, let own = ownDescription(tool) { return plain(own) }
        for item in items.reversed() {
            guard case .assistantMessage(let id, var text, _) = item.detail else { continue }
            if text.isEmpty { text = messages.first { $0.id == id }?.text ?? "" }
            let first = sentence(text)
            if !first.isEmpty { return plain(first) }
        }
        if let tool = tool ?? items.last(where: { ThreadWork.isTool($0) && !isThinking($0) }) {
            if let own = ownDescription(tool) { return plain(own) }
            if case .commandExecution(let input, _, _) = tool.detail {
                let line = firstLine(input)
                return line.isEmpty ? plain("Running a command") : Working(text: line, mono: true, since: since)
            }
            return plain(plainLabel(tool))
        }
        if let thinking = items.last(where: isThinking) { return plain(ThreadWork.describe(thinking)) }
        return plain(Router.Copy.starting)
    }

    /// The words a tool call carries about itself: T3's title (a read, a search, a skill), else a `description` on the item
    /// or in its input (Claude's Bash tool). T3's projection keeps neither for a plain Bash call, which has only its command.
    private static func ownDescription(_ i: T3TurnItem) -> String? {
        for c in [i.title, i.raw.str("description"), i.raw["input"]?.str("description")] {
            if let c, case let t = sentence(c), !t.isEmpty { return t }
        }
        return nil
    }

    /// A short label from the tool's kind and its main object, never from the command's text.
    private static func plainLabel(_ i: T3TurnItem) -> String {
        guard case .dynamicTool(let name) = i.detail else { return ThreadWork.describe(i) }
        if name.isEmpty { return "Working" }
        let input = i.raw["input"]
        let object = ["file_path", "pattern", "query", "url", "path"].lazy.compactMap { input?.str($0) }.first
        let target = object.map { ($0 as NSString).lastPathComponent }
        return target.map { $0.isEmpty ? name : "\(name) · \($0)" } ?? name
    }

    private static func firstLine(_ text: String, cap: Int = 120) -> String {
        guard let line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return "" }
        return line.count > cap ? String(line.prefix(cap - 1)) + "…" : line
    }

    private static func isThinking(_ i: T3TurnItem) -> Bool { if case .reasoning = i.detail { true } else { false } }

    /// The text's first sentence: up to its first full stop, question or exclamation mark followed by a space or the end,
    /// on its first non-empty line, cut at 120 characters.
    static func sentence(_ text: String, cap: Int = 120) -> String {
        guard let line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return "" }
        var end = line.endIndex
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            let next = line.index(after: i)
            if (c == "." || c == "!" || c == "?" || c == "…"), next == line.endIndex || line[next].isWhitespace {
                end = next
                break
            }
            i = next
        }
        let one = line[..<end]
        return one.count > cap ? String(one.prefix(cap - 1)) + "…" : String(one)
    }
}
