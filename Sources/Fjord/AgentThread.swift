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
    /// Not visited since its last update (`lastVisitedAt` null or older), the read state T3's sidebar and phone share.
    var unseen = false
    /// T3 settled it (every imported thread is): only work still live or waiting on you lists it.
    var settled = false
    var snoozedUntil: Date?
    var lastActivity: Date
    var lastUserMessage: Date?
    var lastRunEndedAt: Date?
    /// The latest words the thread shows (the agent's last message), as T3's shell carries them.
    var latestMessage: String?
    /// The latest words you sent it, when that is its latest message.
    var lastUserText: String?
    var lastError: String?
    /// The run stopped on a usage limit and won't pick up again by itself.
    var limitStopped = false
    var limitResetAt: Date?
    var branch: String?
    var pullRequests: [T3PullRequest] = []
    var tags: [String] = []
    /// The agent's provider instance (`claudeAgent`, `codex`…): what tells whether it can be steered before a session says.
    var provider = ""

    var folderName: String { folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Scratch" }
    /// Mute and colour key: the folder path, or "" for scratch threads.
    var folderKey: String { folder ?? "" }

    /// A run is under way (or about to start).
    var running: Bool { [.preparing, .queued, .starting, .running, .waiting].contains(status) }
    /// Stopped on you: a blocking question or permission (the shell keeps `running` meanwhile, S1 e), or a plan.
    var waitsForYou: Bool { pendingRequest?.blocking == true || hasPlan }
    /// Waits on you, or stopped short (failed, or on a usage limit it won't resume from) and not seen since.
    var needsYou: Bool { waitsForYou || (status == .failed || limitStopped) && unseen }
    /// Its latest run is over.
    var finished: Bool { [.completed, .interrupted, .cancelled].contains(status) }
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
            lastUserMessage: t.latestUserMessageAt.flatMap(Self.date), lastRunEndedAt: t.latestRunCompletedAt.flatMap(Self.date),
            latestMessage: t.latestVisibleMessage.flatMap { $0.role == "assistant" && !$0.text.isEmpty ? $0.text : nil },
            lastUserText: t.latestVisibleMessage.flatMap { $0.role == "user" && !$0.text.isEmpty ? $0.text : nil },
            lastError: t.lastError,
            limitStopped: t.status == .failed && raw.str("lastErrorClass") == "usage_limit" && recovery?["autoResume"]?.bool != true,
            limitResetAt: (raw.ts("usageLimitResetAt") ?? recovery?.ts("resetAt")).flatMap(Self.date),
            branch: t.branch, pullRequests: t.pullRequests, tags: t.tags, provider: t.providerInstanceId)
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
