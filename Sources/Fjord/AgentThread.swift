import Foundation

/// A T3 Code thread as Fjord lists it: one row of T3's shell and its project, read with no timer, lease or guess (the
/// shell says exactly what runs, what waits on you and what you haven't seen).
struct AgentThread: Identifiable, Hashable {
    /// T3's thread id (one environment for now: this Mac's T3).
    var id: String
    var projectID: String
    var title: String
    /// The project's folder (`workspaceRoot`); nil for T3's "No project" scratch threads.
    var folder: String?
    /// `owner/name` of the project's GitHub repository, when T3 resolved one.
    var repo: String?
    /// What the thread is doing: the live run's status when one runs, else the thread's.
    var status: T3Status
    /// A question or permission it waits on (`blocking`: the run can't go on without you).
    var pendingRequest: T3PendingRequest?
    /// A proposed plan to approve or send back.
    var hasPlan = false
    /// A reply finished that you haven't opened since (`lastVisitedAt` null or before `latestRunCompletedAt`), the read state
    /// T3's sidebar and phone share.
    var unseen = false
    /// T3 settled it (every imported thread is): only work still live or waiting on you lists it.
    var settled = false
    var snoozedUntil: Date?
    /// `updatedAt`: T3 moves it on pin, settle, snooze and unarchive too, so it says when the row changed, not when the work did.
    var lastActivity: Date
    /// When the thread last had a message or a run end (see `realActivity`): what the decider's ages and order use.
    var activityAt: Date
    var lastUserMessage: Date?
    var lastRunEndedAt: Date?
    /// When T3 made it, settled it, and when you last opened it (`lastVisitedAt`, shared by T3's sidebar and phone).
    var createdAt: Date?
    var settledAt: Date?
    var lastVisitedAt: Date?
    /// Your own last words there (`latestUserAuthoredMessageAt`: wakes and agent sends don't move it).
    var lastAuthoredAt: Date?
    /// The latest words the thread shows (the agent's last message), as T3's shell carries them (nil on T3 0.1.7: read the end).
    var latestMessage: String?
    /// The latest words you sent it, when that is its latest message.
    var lastUserText: String?
    /// Its latest visible message (either role), else `endStamp`: a change of it is what makes a cached read stale.
    var latestMessageID: String?
    var lastError: String?
    /// The run stopped on a usage limit and won't pick up again by itself.
    var limitStopped = false
    var limitResetAt: Date?
    /// The thread failed on a usage limit (whether or not T3 resumes it by itself): thread information, never an account window.
    var usageLimit = false
    var branch: String?
    var pullRequests: [T3PullRequest] = []
    var tags: [String] = []
    /// The agent's provider instance (`claudeAgent`, `codex`…): what tells whether it can be steered before a session says.
    var provider = ""
    /// Work the shell says still runs (`pendingBackgroundTasks`): subagents, commands, monitors, background tasks.
    var pendingTasks: [T3PendingTask] = []
    /// The run holds until another thread's work ends (`blockedOnThreadWait`).
    var blockedOnThreadWait = false
    /// T3's latest run id (`latestRunId`): what a pending send, a verdict's fingerprint and a Continue name.
    var latestRunID: String?
    /// When the run now live began (`activityRunStartedAt`): a working line's `since`, and how a send knows its run started.
    var runStartedAt: Date?
    /// You asked the latest run to stop (`latestRunStopRequested`): an interrupt that is yours, not a failure.
    var stopRequested = false

    var folderName: String { folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Scratch" }
    /// Mute and colour key: the folder path, or "" for scratch threads.
    var folderKey: String { folder ?? "" }

    /// The turn itself is under way (or about to start): the status is live.
    var turnRunning: Bool { status.isLive }
    /// Working: the turn is under way, or work it left running still is (`pendingBackgroundTasks`, by T3's own rule that a
    /// shell with pending background tasks is live), or the run holds on another thread. A turn can end while its subagents,
    /// background commands, monitors or background tasks go on: it isn't done until they are.
    var running: Bool { turnRunning || !pendingTasks.isEmpty || blockedOnThreadWait }
    /// Stopped on you: a blocking question or permission (the shell keeps `running` meanwhile, S1 e), or a plan.
    var waitsForYou: Bool { pendingRequest?.blocking == true || hasPlan }
    /// Waits on you, or stopped short (failed, or on a usage limit it won't resume from) and not seen since.
    var needsYou: Bool { waitsForYou || (status == .failed || limitStopped) && unseen }
    /// Still the owner's concern: not snoozed, and either not settled or live or waiting on them. A settled thread that failed
    /// unseen is out (T3 unsettles on a real new failure).
    func inPlay(now: Date) -> Bool {
        if let until = snoozedUntil, until > now { return false }
        return !settled || running || waitsForYou
    }
    /// Its latest run is over, and nothing it started is still going.
    var finished: Bool { [.completed, .interrupted, .cancelled].contains(status) && !running }
    /// What it is on when the turn is over but its work isn't: "background: Review the changes" for one task, how many run
    /// for more. Nothing while the turn itself runs.
    var backgroundStep: String? {
        guard !turnRunning, !pendingTasks.isEmpty else { return nil }
        return pendingTasks.count == 1 ? "background: \(pendingTasks[0].label)" : "background: \(pendingTasks.count) running"
    }
}

extension AgentThread {
    /// T3's scratch project ("No project") keeps its threads under this folder: they have no project of their own.
    static let scratchRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/scratch").path

    /// The thread a shell row stands for, with its project (nil when the shell hasn't sent it yet).
    init(_ t: T3ThreadShell, project: T3Project?) {
        let root = project.map { ($0.workspaceRoot as NSString).standardizingPath }
        let raw = t.raw
        let recovery = raw["limitRecovery"]
        self.init(
            id: t.id, projectID: t.projectId, title: t.title,
            folder: root.flatMap { $0.isEmpty || $0 == Self.scratchRoot ? nil : $0 },
            repo: project?.repoSlug,
            status: t.activityRunStatus ?? t.status,
            pendingRequest: t.pendingRuntimeRequest, hasPlan: t.hasActionableProposedPlan, unseen: t.isUnseen,
            settled: t.settledAt != nil, snoozedUntil: t.snoozedUntil.flatMap(Self.date),
            lastActivity: t.updatedAt.flatMap(Self.date) ?? t.createdAt.flatMap(Self.date) ?? .distantPast,
            activityAt: Self.realActivity(t),
            lastUserMessage: t.latestUserMessageAt.flatMap(Self.date), lastRunEndedAt: t.latestRunCompletedAt.flatMap(Self.date),
            latestMessage: t.latestVisibleMessage.flatMap { $0.role == "assistant" && !$0.text.isEmpty ? $0.text : nil },
            lastUserText: t.latestVisibleMessage.flatMap { $0.role == "user" && !$0.text.isEmpty ? $0.text : nil },
            latestMessageID: t.latestVisibleMessage?.id ?? Self.endStamp(t),
            lastError: t.lastError,
            limitStopped: t.status == .failed && raw.str("lastErrorClass") == "usage_limit" && recovery?["autoResume"]?.bool != true,
            limitResetAt: (raw.ts("usageLimitResetAt") ?? recovery?.ts("resetAt")).flatMap(Self.date),
            usageLimit: t.status == .failed && raw.str("lastErrorClass") == "usage_limit",
            branch: t.branch, pullRequests: t.pullRequests, tags: t.tags, provider: t.providerInstanceId,
            pendingTasks: t.pendingBackgroundTasks, blockedOnThreadWait: t.blockedOnThreadWait)
        createdAt = t.createdAt.flatMap(Self.date)
        settledAt = t.settledAt.flatMap(Self.date)
        lastVisitedAt = t.lastVisitedAt.flatMap(Self.date)
        lastAuthoredAt = t.latestUserAuthoredMessageAt.flatMap(Self.date)
        latestRunID = t.latestRunId
        runStartedAt = t.activityRunStartedAt.flatMap(Self.date)
        stopRequested = t.latestRunStopRequested
    }

    /// What stands for the latest message when the shell carries none (T3 0.1.7 always sends `latestVisibleMessage: null`): the
    /// last run's end, your last message, the run's status and its pending background work, so a read of the thread's end goes
    /// stale when any of them moves (the work ending after the run did moves no timestamp).
    static func endStamp(_ t: T3ThreadShell) -> String {
        [t.latestRunCompletedAt?.text ?? "-", t.latestUserMessageAt?.text ?? "-", (t.activityRunStatus ?? t.status).rawValue,
         String(t.pendingBackgroundTasks.count + (t.blockedOnThreadWait ? 1 : 0))].joined(separator: "|")
    }

    /// When the thread last had real activity: the latest of its last run's end, the last words you wrote and its latest visible
    /// message, never `updatedAt` (J3, gap 1). An imported thread stamps its messages with the import time, so until it has run on
    /// T3 it counts from its creation (old), and after that from its last run alone.
    static func realActivity(_ t: T3ThreadShell) -> Date {
        let created = t.createdAt.flatMap(date)
        let run = t.latestRunCompletedAt.flatMap(date)
        if t.historyOrigin == "v1_import" { return run ?? created ?? .distantPast }
        let times = [run, (t.latestUserAuthoredMessageAt ?? t.latestUserMessageAt).flatMap(date),
                     t.latestVisibleMessage?.updatedAt.flatMap(date)].compactMap { $0 }
        return times.max() ?? created ?? .distantPast
    }

    /// What it left running after its turn that it picks up again from (`pendingBackgroundTasks`, by T3's own rule
    /// `backgroundWorkHoldsCompletion`): subagents and background tasks, and commands or monitors it said it waits on. A
    /// command it didn't (as often a dev server as a wait) doesn't keep it working.
    static func backgroundWork(_ t: T3ThreadShell, since: Date) -> [BackgroundWork] {
        (t.raw["pendingBackgroundTasks"]?.array ?? []).compactMap { task in
            guard let id = task.str("taskId") else { return nil }
            let holds = task["awaited"]?.bool == true || !["command", "monitor"].contains(task.str("kind") ?? "background_task")
            guard holds else { return nil }
            let kind: BackgroundWork.Kind = task.str("kind") == "subagent" ? .agent : .command
            return BackgroundWork(id: id, kind: kind, title: task.str("description") ?? (kind == .agent ? "Subagent" : "Command"), since: since)
        }
    }

    /// Shell timestamps, parsed with one formatter per format (a snapshot holds hundreds of rows).
    static func date(_ t: T3Timestamp) -> Date? {
        dateLock.lock(); defer { dateLock.unlock() }
        return fractional.date(from: t.text) ?? whole.date(from: t.text)
    }
    private static let dateLock = NSLock()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()
}

/// What a working thread is on right now, and since when: read from the thread's projection, which Fjord holds open only
/// while the thread works (see `Store.syncThreadDetail`).
struct ThreadWork: Hashable {
    var text: String
    var since: Date
    /// The thread's task list.
    var todo: Todo? = nil
    /// The agent's latest words between tool calls in this turn; at a turn's end, its final message.
    var narration: String? = nil
    /// How many files this turn has changed.
    var files = 0

    struct Todo: Hashable {
        var done: Int
        var total: Int
        /// The in-progress item, in the present tense.
        var active: String?
    }
}

extension ThreadWork {
    /// What the live turn is doing, from its items by type (never by a tool's name, so it reads the same for any agent):
    /// the item still running (else the last tool-like one), the task list, the last words and the files changed.
    init?(_ p: T3Projection, now: Date = Date()) {
        guard let run = p.activeRun ?? p.runs.last(where: { $0.status.isLive }) else { return nil }
        let items = p.turnItems.filter { $0.runId == nil || $0.runId == run.id }
        func live(_ i: T3TurnItem) -> Bool { i.status == "running" || i.status == "waiting" }
        func tool(_ i: T3TurnItem) -> Bool {
            switch i.detail {
            case .commandExecution, .fileChange, .dynamicTool, .reasoning: true
            default: [T3ItemType.webSearch, .fileSearch].contains(i.type) || i.type.rawValue == "subagent"
            }
        }
        let current = items.last { tool($0) && live($0) } ?? items.last(where: tool)
        text = current.map(Self.describe) ?? "Working"
        since = (run.startedAt ?? run.requestedAt).flatMap(AgentThread.date) ?? now
        if let list = items.last(where: { if case .todoList = $0.detail { true } else { false } }),
           case .todoList(_, let steps) = list.detail, !steps.isEmpty {
            todo = Todo(done: steps.filter { $0.status == "completed" }.count, total: steps.count,
                        active: steps.first { $0.status == "running" }?.text)
        }
        narration = items.reversed().lazy.compactMap { i -> String? in
            if case .assistantMessage(_, let t, _) = i.detail, !t.isEmpty { t } else { nil }
        }.first
        files = Set(items.compactMap { i -> String? in if case .fileChange(let name, _, _) = i.detail { name } else { nil } }).count
    }

    /// An item in a few words: a command is its input, a file change its file, a search its query.
    private static func describe(_ i: T3TurnItem) -> String {
        func line(_ s: String, _ cap: Int = 120) -> String {
            let one = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
            let t = one.trimmingCharacters(in: .whitespaces)
            return t.count > cap ? String(t.prefix(cap)) + "…" : t
        }
        switch i.detail {
        case .commandExecution(let input, _, _): return input.isEmpty ? "Running a command" : line(input)
        case .fileChange(let name, _, _): return name.isEmpty ? "Editing files" : "Editing " + (name as NSString).lastPathComponent
        case .dynamicTool(let name): return name.isEmpty ? "Working" : name
        case .reasoning: return "Thinking"
        default:
            if i.type == .webSearch { return (i.raw.str("query") ?? i.title).map { line($0) } ?? "Searching the web" }
            if i.type == .fileSearch { return (i.raw.str("query") ?? i.title).map { line($0) } ?? "Searching files" }
            return i.title.map { line($0) } ?? "Working on a subagent"
        }
    }

    /// The tooltip on a working row: the task in hand, the files changed and where the work lives.
    func detail(branch: String?, pullRequests: [T3PullRequest]) -> String? {
        var lines: [String] = []
        if let todo { lines.append("\(todo.done) of \(todo.total) done" + (todo.active.map { " · " + $0 } ?? "")) }
        if files > 0 { lines.append(files == 1 ? "1 file changed" : "\(files) files changed") }
        if let branch, !branch.isEmpty { lines.append("Branch " + branch) }
        for pr in pullRequests { lines.append(pr.number.map { "PR #\($0)" } ?? "Pull request") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// A subagent or command a thread left running after its turn.
struct BackgroundWork: Hashable, Identifiable {
    enum Kind: Hashable { case agent, command }
    var id: String
    var kind: Kind
    var title: String
    var since: Date
    /// What a subagent is on; commands don't say.
    var activity: ThreadWork? = nil
}
