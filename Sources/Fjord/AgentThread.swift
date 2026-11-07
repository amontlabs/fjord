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
    var lastError: String?
    /// The run stopped on a usage limit and won't pick up again by itself.
    var limitStopped = false
    var limitResetAt: Date?
    var branch: String?
    var pullRequests: [T3PullRequest] = []
    var tags: [String] = []

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
            lastError: t.lastError,
            limitStopped: t.status == .failed && raw.str("lastErrorClass") == "usage_limit" && recovery?["autoResume"]?.bool != true,
            limitResetAt: (raw.ts("usageLimitResetAt") ?? recovery?.ts("resetAt")).flatMap(Self.date),
            branch: t.branch, pullRequests: t.pullRequests, tags: t.tags)
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

/// What a working thread is on right now, and since when (filled from the thread's projection in a later step).
struct ThreadWork: Hashable {
    var text: String
    var since: Date
    /// The thread's task list.
    var todo: Todo? = nil
    /// The agent's latest words between tool calls in this turn; at a turn's end, its final message.
    var narration: String? = nil

    struct Todo: Hashable {
        var done: Int
        var total: Int
        /// The in-progress item, in the present tense.
        var active: String?
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
