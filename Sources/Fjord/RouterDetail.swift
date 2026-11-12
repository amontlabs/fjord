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
    var steps: [RouterV2Thread.Step] = []
    /// The agent's last message, whole.
    var reply = ""
    /// That message is still being written.
    var writing = false
    /// The question, permission or plan it waits on.
    var request: ThreadRequest?
    var queued: [Queued] = []
    /// The latest turn's changes: its checkpoints summed. Nil when it changed no file.
    var diff: RouterV2Thread.Diff?
    /// The last thing a run that did not finish was doing (its last tool item); nil for any other run.
    var lastStep: String?
    /// Its agent takes words mid-turn.
    var steers = true
    /// Its subagents, background commands and waits.
    var activity = RouterV2Activity()

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
        } else if p.thread.status.isLive, !(p.thread.status == .queued) {
            d.working = Working(text: RouterV2.Copy.starting, mono: false,
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

        d.queued = p.queuedRuns.compactMap { run in
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
        d.activity = RouterV2Activity.make(p)
        return d
    }

    // MARK: Pieces

    private static func steps(of items: some Sequence<T3TurnItem>) -> [RouterV2Thread.Step] {
        var last: [T3TodoStep] = []
        for i in items { if case .todoList(_, let s) = i.detail, !s.isEmpty { last = s } }
        return last.enumerated().map { n, s in
            .init(id: n, text: s.text, state: s.status == "completed" ? .done : s.status == "running" ? .running : .pending)
        }
    }

    /// What the line says, first match wins: the running to-do step; the running tool's own description (T3's `title`, or a
    /// `description` the item carries); the first sentence of the agent's latest words in this run; a plain label from the
    /// tool kind and its main object; a command in mono, first line only, as the last resort. "starting" before any item.
    private static func working(_ items: [T3TurnItem], steps: [RouterV2Thread.Step], messages: [T3Message], since: Date) -> Working {
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
        return plain(RouterV2.Copy.starting)
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
