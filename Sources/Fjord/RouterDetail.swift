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

    /// The running to-do step, else the first sentence of the agent's latest words in this run, else the running tool or
    /// command (else the last one it ran). "starting" before the run has an item.
    private static func working(_ items: [T3TurnItem], steps: [RouterV2Thread.Step], messages: [T3Message], since: Date) -> Working {
        if let step = steps.first(where: { $0.state == .running }) {
            return Working(text: sentence(step.text), mono: false, since: since)
        }
        for item in items.reversed() {
            guard case .assistantMessage(let id, var text, _) = item.detail else { continue }
            if text.isEmpty { text = messages.first { $0.id == id }?.text ?? "" }
            let first = sentence(text)
            if !first.isEmpty { return Working(text: first, mono: false, since: since) }
        }
        func live(_ i: T3TurnItem) -> Bool { i.status == "running" || i.status == "waiting" }
        if let tool = items.last(where: { ThreadWork.isTool($0) && live($0) }) ?? items.last(where: ThreadWork.isTool) {
            if case .commandExecution = tool.detail { return Working(text: ThreadWork.describe(tool), mono: true, since: since) }
            return Working(text: ThreadWork.describe(tool), mono: false, since: since)
        }
        return Working(text: RouterV2.Copy.starting, mono: false, since: since)
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
