import Foundation

// Lenient wire types for the T3 Code v0.1.7 orchestration protocol 2 (docs/design/t3-research/S1-spikes.md).
// Every type decodes from a `T3JSON` tree by hand: a missing or oddly typed field falls back to a default and
// an unknown enum value, item type or event type is kept (as its raw string / raw JSON) instead of failing.

// MARK: - JSON

enum T3JSON: Equatable, Hashable, Sendable, Codable {
    case null, bool(Bool), number(Double), string(String), array([T3JSON]), object([String: T3JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([T3JSON].self) { self = .array(v) }
        else if let v = try? c.decode([String: T3JSON].self) { self = .object(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            if v == v.rounded(), abs(v) < 9e15 { try c.encode(Int64(v)) } else { try c.encode(v) }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    subscript(key: String) -> T3JSON? {
        if case .object(let o) = self, let v = o[key], v != .null { return v }
        return nil
    }
    subscript(index: Int) -> T3JSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var int: Int? { if case .number(let n) = self { return Int(exactly: n.rounded()) } else { return nil } }
    var double: Double? { if case .number(let n) = self { return n } else { return nil } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var array: [T3JSON]? { if case .array(let a) = self { return a } else { return nil } }
    var object: [String: T3JSON]? { if case .object(let o) = self { return o } else { return nil } }
    var isObject: Bool { object != nil }

    /// Encodes to compact JSON with sorted keys (stable for tests).
    func data() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
    /// JSONSerialization, not Codable: the shell snapshot is ~1 MB, and the `try?` chain in `init(from:)` took ~30 s on it in a debug build.
    static func parse(_ data: Data) -> T3JSON? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return T3JSON(foundation: any)
    }

    init(foundation any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map(T3JSON.init(foundation:)))
        case let o as [String: Any]: self = .object(o.mapValues(T3JSON.init(foundation:)))
        default: self = .null
        }
    }
    static func parse(_ text: String) -> T3JSON? { parse(Data(text.utf8)) }
}

extension T3JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral v: String) { self = .string(v) }
    init(integerLiteral v: Int) { self = .number(Double(v)) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(arrayLiteral e: T3JSON...) { self = .array(e) }
    init(dictionaryLiteral e: (String, T3JSON)...) { self = .object(Dictionary(e, uniquingKeysWith: { $1 })) }
    init(nilLiteral: ()) { self = .null }
}

/// A type that builds itself from a JSON object and never throws on shape surprises.
protocol T3Decodable: Decodable { init(json: T3JSON) }
extension T3Decodable {
    init(from decoder: Decoder) throws { self.init(json: try T3JSON(from: decoder)) }
}

// MARK: - Lenient enums and timestamps

/// A string enum that keeps values it doesn't know.
protocol T3StringEnum: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral where RawValue == String {
    init(rawValue: String)
}
extension T3StringEnum {
    init(stringLiteral v: String) { self.init(rawValue: v) }
    init(from decoder: Decoder) throws {
        self.init(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "")
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// `idle` plus the run statuses (OV2:2047). Unknown values are kept.
struct T3Status: T3StringEnum {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let idle: T3Status = "idle", preparing: T3Status = "preparing", queued: T3Status = "queued"
    static let starting: T3Status = "starting", running: T3Status = "running", waiting: T3Status = "waiting"
    static let completed: T3Status = "completed", interrupted: T3Status = "interrupted", failed: T3Status = "failed"
    static let cancelled: T3Status = "cancelled", rolledBack: T3Status = "rolled_back"
    /// Statuses T3 itself counts as live (`LIVE_SHELL_STATUSES`).
    var isLive: Bool { [.queued, .preparing, .starting, .running, .waiting].contains(self) }
}

struct T3RuntimeMode: T3StringEnum {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let approvalRequired: T3RuntimeMode = "approval-required", autoAcceptEdits: T3RuntimeMode = "auto-accept-edits"
    static let auto: T3RuntimeMode = "auto", fullAccess: T3RuntimeMode = "full-access"
}

struct T3InteractionMode: T3StringEnum {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let `default`: T3InteractionMode = "default", plan: T3InteractionMode = "plan"
}

struct T3Decision: T3StringEnum {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let accept: T3Decision = "accept", acceptForSession: T3Decision = "acceptForSession"
    static let acceptAlways: T3Decision = "acceptAlways", decline: T3Decision = "decline", cancel: T3Decision = "cancel"
    /// The fixed list to fall back on when a request carries no `options` (S1 #7).
    static let fallbackList: [T3Decision] = [.accept, .acceptForSession, .acceptAlways, .decline, .cancel]
}

struct T3ItemType: T3StringEnum {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let userMessage: T3ItemType = "user_message", assistantMessage: T3ItemType = "assistant_message"
    static let reasoning: T3ItemType = "reasoning", proposedPlan: T3ItemType = "proposed_plan"
    static let todoList: T3ItemType = "todo_list", userInputRequest: T3ItemType = "user_input_request"
    static let approvalRequest: T3ItemType = "approval_request", commandExecution: T3ItemType = "command_execution"
    static let fileChange: T3ItemType = "file_change", fileSearch: T3ItemType = "file_search"
    static let webSearch: T3ItemType = "web_search", dynamicTool: T3ItemType = "dynamic_tool"
    static let notification: T3ItemType = "notification", checkpoint: T3ItemType = "checkpoint"
}

/// An ISO-8601 timestamp that keeps its text and never fails to decode.
struct T3Timestamp: Hashable, Sendable, Comparable, Codable {
    var text: String
    init(_ text: String) { self.text = text }
    init(date: Date) { self.text = T3Timestamp.format(date) }
    init(from decoder: Decoder) throws { text = (try? decoder.singleValueContainer().decode(String.self)) ?? "" }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(text) }
    static func < (a: T3Timestamp, b: T3Timestamp) -> Bool { a.text < b.text }  // same UTC `Z` format, so text order is time order

    var date: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    static func now() -> T3Timestamp { T3Timestamp(date: Date()) }
}

extension T3JSON {
    func ts(_ k: String) -> T3Timestamp? { self[k]?.string.map(T3Timestamp.init) }
    func str(_ k: String) -> String? { self[k]?.string }
    func flag(_ k: String) -> Bool { self[k]?.bool ?? false }
}

// MARK: - Projects and threads (shell)

struct T3Project: T3Decodable, Hashable, Sendable {
    var id: String
    var title: String
    var workspaceRoot: String
    /// `repositoryIdentity` (owner/name of the GitHub remote) stays raw; read it with `repoSlug`.
    var repositoryIdentity: T3JSON?
    var pinnedAt: T3Timestamp?
    var archivedAt: T3Timestamp?
    var updatedAt: T3Timestamp?
    var raw: T3JSON

    init(json j: T3JSON) {
        id = j.str("id") ?? ""
        title = j.str("title") ?? ""
        workspaceRoot = j.str("workspaceRoot") ?? ""
        repositoryIdentity = j["repositoryIdentity"]
        pinnedAt = j.ts("pinnedAt"); archivedAt = j.ts("archivedAt"); updatedAt = j.ts("updatedAt")
        raw = j
    }
    /// `owner/name` when the identity carries one (keys differ by T3 version, so look at a few).
    var repoSlug: String? {
        guard let r = repositoryIdentity else { return nil }
        if let s = r.str("nameWithOwner") ?? r.str("fullName") { return s }
        if let o = r.str("owner"), let n = r.str("name") { return "\(o)/\(n)" }
        return nil
    }
}

struct T3Lineage: Hashable, Sendable {
    var parentThreadId: String?
    /// `fork`, `subagent` or nil; unknown values are kept.
    var relationshipToParent: String?
    var rootThreadId: String?
    var sideChat: Bool
    init(json j: T3JSON?) {
        parentThreadId = j?.str("parentThreadId"); relationshipToParent = j?.str("relationshipToParent")
        rootThreadId = j?.str("rootThreadId"); sideChat = j?.flag("sideChat") ?? false
    }
    /// `isListedThreadLineage` (OV2:163-164): subagents and side chats live inside their parent.
    var isListed: Bool { relationshipToParent != "subagent" && !sideChat }
}

struct T3PendingRequest: Hashable, Sendable {
    var id: String
    /// `command`, `file-change`, `user_input`, … unknown values are kept.
    var kind: String
    var createdAt: T3Timestamp?
    var blocking: Bool
    init?(json j: T3JSON?) {
        guard let j, let id = j.str("id") else { return nil }
        self.id = id; kind = j.str("kind") ?? ""; createdAt = j.ts("createdAt"); blocking = j["blocking"]?.bool ?? true
    }
    var isUserInput: Bool { kind == "user_input" }
}

struct T3VisibleMessage: Hashable, Sendable {
    var id: String
    var role: String
    var text: String
    var updatedAt: T3Timestamp?
    init?(json j: T3JSON?) {
        guard let j, let id = j.str("id") else { return nil }
        self.id = id; role = j.str("role") ?? ""; text = j.str("text") ?? ""; updatedAt = j.ts("updatedAt")
    }
}

struct T3PullRequest: Hashable, Sendable {
    var url: String
    var number: Int?
    var repository: String?
    var state: String?
    var title: String?
    var raw: T3JSON
    init(json j: T3JSON) {
        url = j.str("url") ?? ""
        number = j.num("number") ?? j["snapshot"]?.num("number")
        repository = j.str("repository") ?? j.str("repo")
        state = j["snapshot"]?.str("state") ?? j.str("state")
        title = j["snapshot"]?.str("title")
        raw = j
    }
}

extension T3JSON {
    func num(_ k: String) -> Int? { self[k]?.int }
    func str(_ k: String, _ alt: String) -> String? { self[k]?.string ?? self[alt]?.string }
}

/// A thread row from the shell stream. The projection's `thread` decodes into the same type
/// (fields it lacks keep defaults: `status` idle, no pending request).
struct T3ThreadShell: T3Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var projectId: String
    var title: String
    var providerInstanceId: String
    var model: String?
    var runtimeMode: T3RuntimeMode
    var interactionMode: T3InteractionMode
    var branch: String?
    var worktreePath: String?
    var pullRequests: [T3PullRequest]
    var lineage: T3Lineage
    var historyOrigin: String?
    var latestRunId: String?
    var activeRunId: String?
    var latestRunCompletedAt: T3Timestamp?
    /// When the run now live began (`activityRunStartedAt`; null between runs).
    var activityRunStartedAt: T3Timestamp?
    /// You asked the latest run to stop (`latestRunStopRequested`): an interrupt that is yours, not a failure.
    var latestRunStopRequested: Bool
    var activityRunStatus: T3Status?
    var status: T3Status
    var lastError: String?
    var pendingRuntimeRequest: T3PendingRequest?
    var latestVisibleMessage: T3VisibleMessage?
    var latestUserMessageAt: T3Timestamp?
    /// Your own words only: wakes and agent messages that go through the user role do not move it.
    var latestUserAuthoredMessageAt: T3Timestamp?
    var hasActionableProposedPlan: Bool
    /// Work the agent left running (`pendingBackgroundTasks`): subagents, background commands, monitors, background tasks.
    var pendingBackgroundTasks: [T3PendingTask]
    /// The run holds until another thread's work ends (`blockedOnThreadWait`).
    var blockedOnThreadWait: Bool
    var createdAt: T3Timestamp?
    var updatedAt: T3Timestamp?
    var archivedAt: T3Timestamp?
    var settledAt: T3Timestamp?
    var snoozedUntil: T3Timestamp?
    var pinnedAt: T3Timestamp?
    var lastVisitedAt: T3Timestamp?
    var tags: [String]
    var deletedAt: T3Timestamp?
    var raw: T3JSON

    init(json j: T3JSON) {
        id = j.str("id") ?? ""
        projectId = j.str("projectId") ?? ""
        title = j.str("title") ?? ""
        providerInstanceId = j.str("providerInstanceId") ?? ""
        model = j["modelSelection"]?.str("model")
        runtimeMode = T3RuntimeMode(rawValue: j.str("runtimeMode") ?? "")
        interactionMode = T3InteractionMode(rawValue: j.str("interactionMode") ?? "")
        branch = j.str("branch"); worktreePath = j.str("worktreePath")
        pullRequests = (j["pullRequests"]?.array ?? []).map(T3PullRequest.init)
        lineage = T3Lineage(json: j["lineage"])
        historyOrigin = j.str("historyOrigin")
        latestRunId = j.str("latestRunId"); activeRunId = j.str("activeRunId")
        latestRunCompletedAt = j.ts("latestRunCompletedAt")
        activityRunStartedAt = j.ts("activityRunStartedAt")
        latestRunStopRequested = j.flag("latestRunStopRequested")
        activityRunStatus = j.str("activityRunStatus").map { T3Status(rawValue: $0) }
        status = T3Status(rawValue: j.str("status") ?? "idle")
        lastError = j.str("lastError")
        pendingRuntimeRequest = T3PendingRequest(json: j["pendingRuntimeRequest"])
        latestVisibleMessage = T3VisibleMessage(json: j["latestVisibleMessage"])
        latestUserMessageAt = j.ts("latestUserMessageAt")
        latestUserAuthoredMessageAt = j.ts("latestUserAuthoredMessageAt")
        hasActionableProposedPlan = j.flag("hasActionableProposedPlan")
        // T3 lists its own watch of a thread's open pull request here too (`pull-request-watch:…`, derivePendingBackgroundWork):
        // that is T3 waiting on a review or a merge, not work the agent left running.
        pendingBackgroundTasks = (j["pendingBackgroundTasks"]?.array ?? []).map(T3PendingTask.init).filter { !$0.id.hasPrefix("pull-request-watch:") }
        blockedOnThreadWait = j.flag("blockedOnThreadWait")
        createdAt = j.ts("createdAt"); updatedAt = j.ts("updatedAt"); archivedAt = j.ts("archivedAt")
        settledAt = j.ts("settledAt"); snoozedUntil = j.ts("snoozedUntil"); pinnedAt = j.ts("pinnedAt")
        lastVisitedAt = j.ts("lastVisitedAt")
        tags = (j["tags"]?.array ?? []).compactMap(\.string)
        deletedAt = j.ts("deletedAt")
        raw = j
    }

    /// Unread: a run finished after you last opened the thread, or you never did (T3's own rule: "mark unread" sets
    /// `lastVisitedAt` just before `latestRunCompletedAt`). Not `updatedAt`, which pin, settle and snooze move too (N4b §2.1).
    var isUnseen: Bool {
        guard let run = latestRunCompletedAt else { return false }
        guard let lastVisitedAt else { return true }
        return lastVisitedAt < run
    }
    var isListed: Bool { lineage.isListed }
    var isLive: Bool { status.isLive }
}

/// One entry of the shell's `pendingBackgroundTasks`: `{taskId, kind, description?}` — a `subagent` (also
/// `childThreadId`, `providerInstanceId`), a `command`, a `monitor` or a `background_task`.
struct T3PendingTask: T3Decodable, Hashable, Sendable {
    var id: String
    var kind: String?
    var description: String?

    init(json j: T3JSON) {
        id = j.str("taskId") ?? ""
        kind = j.str("kind")
        description = j.str("description")
    }

    /// What it is, in a few words: what T3 named it, else its kind.
    var label: String {
        if let d = description, !d.isEmpty { return d }
        return Self.kindName(kind)
    }

    /// "Subagent", "Monitor", "Command", or "Task" for a kind Fjord doesn't know.
    static func kindName(_ kind: String?) -> String {
        switch kind {
        case "subagent": "Subagent"
        case "monitor": "Monitor"
        case "command": "Command"
        default: "Task"
        }
    }
}

// MARK: - Shell stream

enum T3Location: T3StringEnum, Sendable {
    case active, archive, other(String)
    init(rawValue: String) { self = rawValue == "active" ? .active : rawValue == "archive" ? .archive : .other(rawValue) }
    var rawValue: String {
        switch self { case .active: "active"; case .archive: "archive"; case .other(let s): s }
    }
}

struct T3ShellSnapshot: Sendable, Equatable {
    var snapshotSequence: Int
    var threads: [T3ThreadShell]
    var archivedThreads: [T3ThreadShell]
    var projects: [T3Project]
}

extension T3ThreadShell: Equatable {}
extension T3Project: Equatable {}

/// One value of `orchestration.subscribeShell`. Unknown kinds decode as `.unknown` and never fail the stream.
enum T3ShellItem: T3Decodable, Sendable, Equatable {
    case synchronized
    case snapshot(T3ShellSnapshot)
    case projectUpdated(sequence: Int, project: T3Project)
    case projectRemoved(sequence: Int, projectId: String)
    case threadUpdated(sequence: Int, location: T3Location, thread: T3ThreadShell)
    case threadRemoved(sequence: Int, location: T3Location, threadId: String)
    case unknown(kind: String, raw: T3JSON)

    init(json j: T3JSON) {
        let kind = j.str("kind") ?? ""
        let seq = j.num("sequence") ?? 0
        let loc = T3Location(rawValue: j.str("location") ?? "active")
        switch kind {
        case "synchronized": self = .synchronized
        case "snapshot":
            let s = j["snapshot"] ?? .null
            self = .snapshot(T3ShellSnapshot(
                snapshotSequence: s.num("snapshotSequence") ?? 0,
                threads: (s["threads"]?.array ?? []).map(T3ThreadShell.init),
                archivedThreads: (s["archivedThreads"]?.array ?? []).map(T3ThreadShell.init),
                projects: (s["projects"]?.array ?? []).map(T3Project.init)))
        case "project.updated" where j["project"] != nil: self = .projectUpdated(sequence: seq, project: T3Project(json: j["project"]!))
        case "project.removed": self = .projectRemoved(sequence: seq, projectId: j.str("projectId") ?? "")
        case "thread.updated" where j["thread"] != nil: self = .threadUpdated(sequence: seq, location: loc, thread: T3ThreadShell(json: j["thread"]!))
        case "thread.removed": self = .threadRemoved(sequence: seq, location: loc, threadId: j.str("threadId") ?? "")
        default: self = .unknown(kind: kind, raw: j)
        }
    }

    /// The highest sequence this item carries, for `afterSequence` on reconnect.
    var sequence: Int? {
        switch self {
        case .snapshot(let s): s.snapshotSequence
        case .projectUpdated(let n, _), .projectRemoved(let n, _), .threadUpdated(let n, _, _), .threadRemoved(let n, _, _): n
        case .synchronized, .unknown: nil
        }
    }
}

// MARK: - Thread projection

struct T3Run: T3Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var ordinal: Int
    var status: T3Status
    var queuePosition: Int?
    var userMessageId: String?
    var requestedAt: T3Timestamp?
    var startedAt: T3Timestamp?
    var completedAt: T3Timestamp?
    var raw: T3JSON
    init(json j: T3JSON) {
        id = j.str("id") ?? ""; ordinal = j.num("ordinal") ?? 0
        status = T3Status(rawValue: j.str("status") ?? "")
        queuePosition = j.num("queuePosition"); userMessageId = j.str("userMessageId")
        requestedAt = j.ts("requestedAt"); startedAt = j.ts("startedAt"); completedAt = j.ts("completedAt")
        raw = j
    }
    var isQueued: Bool { status == .queued }
}

struct T3Message: T3Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var runId: String?
    var role: String
    var createdBy: String
    var text: String
    var streaming: Bool
    var createdAt: T3Timestamp?
    var updatedAt: T3Timestamp?
    init(json j: T3JSON) {
        id = j.str("id") ?? ""; runId = j.str("runId"); role = j.str("role") ?? ""
        createdBy = j.str("createdBy") ?? ""; text = j.str("text") ?? ""; streaming = j.flag("streaming")
        createdAt = j.ts("createdAt"); updatedAt = j.ts("updatedAt")
    }
}

struct T3RuntimeRequest: T3Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var kind: String
    /// `pending`, `resolved`, `expired`, `cancelled`; unknown values kept.
    var status: String
    /// `live`, `message`, `not_resumable` (a decision can only be sent when `live`).
    var responseCapability: String
    var supportsFeedback: Bool
    var decision: T3Decision?
    var feedback: String?
    var createdAt: T3Timestamp?
    var resolvedAt: T3Timestamp?
    var raw: T3JSON
    init(json j: T3JSON) {
        id = j.str("id") ?? ""; kind = j.str("kind") ?? ""; status = j.str("status") ?? ""
        responseCapability = j["responseCapability"]?.str("type") ?? ""
        supportsFeedback = j["responseCapability"]?.flag("supportsFeedback") ?? false
        decision = j.str("decision").map { T3Decision(rawValue: $0) }; feedback = j.str("feedback")
        createdAt = j.ts("createdAt"); resolvedAt = j.ts("resolvedAt")
        raw = j
    }
    var isPending: Bool { status == "pending" }
    var isLive: Bool { responseCapability == "live" }
}

struct T3Plan: T3Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var runId: String?
    var status: String
    var kind: String
    var markdown: String
    init(json j: T3JSON) {
        id = j.str("id") ?? ""; runId = j.str("runId"); status = j.str("status") ?? ""
        kind = j.str("kind") ?? ""; markdown = j.str("markdown") ?? ""
    }
}

struct T3Question: Hashable, Sendable {
    var id: String
    var header: String
    var question: String
    var options: [Option]
    var multiSelect: Bool
    var allowCustomAnswer: Bool
    var required: Bool
    struct Option: Hashable, Sendable {
        var label: String
        var description: String
        /// The answer value: `value` when present, else the label (S1 #9).
        var value: String
        init(json j: T3JSON) {
            label = j.str("label") ?? ""; description = j.str("description") ?? ""
            value = j.str("value") ?? label
        }
    }
    init(json j: T3JSON) {
        id = j.str("id") ?? ""; header = j.str("header") ?? ""; question = j.str("question") ?? ""
        options = (j["options"]?.array ?? []).map(Option.init)
        multiSelect = j.flag("multiSelect"); allowCustomAnswer = j["allowCustomAnswer"]?.bool ?? false
        required = j["required"]?.bool ?? true
    }
}

struct T3ApprovalOption: Hashable, Sendable {
    var decision: T3Decision
    var label: String
    var warning: String?
    init(json j: T3JSON) {
        decision = T3Decision(rawValue: j.str("decision") ?? ""); label = j.str("label") ?? ""; warning = j.str("warning")
    }
}

struct T3TodoStep: Hashable, Sendable {
    var id: String
    var text: String
    /// `pending`, `running`, `completed`; unknown kept.
    var status: String
    init(json j: T3JSON) { id = j.str("id") ?? ""; text = j.str("text") ?? ""; status = j.str("status") ?? "" }
}

/// Typed content of the item kinds Fjord reads; everything else is `.other` (the raw payload is on the item).
enum T3ItemDetail: Hashable, Sendable {
    case userMessage(messageId: String, text: String)
    case assistantMessage(messageId: String, text: String, streaming: Bool)
    case reasoning(text: String, streaming: Bool)
    case proposedPlan(planId: String, markdown: String)
    case todoList(planId: String, steps: [T3TodoStep])
    case userInputRequest(requestId: String, questions: [T3Question])
    case approvalRequest(requestId: String, requestKind: String, prompt: String?, reason: String?, options: [T3ApprovalOption])
    case commandExecution(input: String, output: String?, exitCode: Int?)
    case fileChange(fileName: String, additions: Int?, deletions: Int?)
    case dynamicTool(toolName: String)
    case other
}

struct T3TurnItem: T3Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var runId: String?
    var ordinal: Int
    /// `running`, `waiting`, `completed`, `failed`, `cancelled`, `interrupted`…; unknown kept.
    var status: String
    var title: String?
    var type: T3ItemType
    var updatedAt: T3Timestamp?
    var detail: T3ItemDetail
    var raw: T3JSON

    init(json j: T3JSON) {
        id = j.str("id") ?? ""; runId = j.str("runId"); ordinal = j.num("ordinal") ?? 0
        status = j.str("status") ?? ""; title = j.str("title"); updatedAt = j.ts("updatedAt")
        type = T3ItemType(rawValue: j.str("type") ?? "")
        raw = j
        switch type {
        case .userMessage: detail = .userMessage(messageId: j.str("messageId") ?? "", text: j.str("text") ?? "")
        case .assistantMessage: detail = .assistantMessage(messageId: j.str("messageId") ?? "", text: j.str("text") ?? "", streaming: j.flag("streaming"))
        case .reasoning: detail = .reasoning(text: j.str("text") ?? "", streaming: j.flag("streaming"))
        case .proposedPlan: detail = .proposedPlan(planId: j.str("planId") ?? "", markdown: j.str("markdown") ?? "")
        case .todoList: detail = .todoList(planId: j.str("planId") ?? "", steps: (j["steps"]?.array ?? []).map(T3TodoStep.init))
        case .userInputRequest:
            detail = .userInputRequest(requestId: j.str("requestId") ?? "", questions: (j["questions"]?.array ?? []).map(T3Question.init))
        case .approvalRequest:
            detail = .approvalRequest(requestId: j.str("requestId") ?? "", requestKind: j.str("requestKind") ?? "",
                                      prompt: j.str("prompt"), reason: j.str("reason"),
                                      options: (j["options"]?.array ?? []).map(T3ApprovalOption.init))
        case .commandExecution: detail = .commandExecution(input: j.str("input") ?? "", output: j.str("output"), exitCode: j.num("exitCode"))
        case .fileChange: detail = .fileChange(fileName: j.str("fileName") ?? "", additions: j.num("additions"), deletions: j.num("deletions"))
        case .dynamicTool: detail = .dynamicTool(toolName: j.str("toolName") ?? "")
        default: detail = .other
        }
    }
    /// The server blanks a body its record already carries and sets `textOmitted`; the reducer restores it.
    var textOmitted: Bool { raw.flag("textOmitted") }
}

struct T3ProviderSession: T3Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var driver: String
    var status: String
    var capabilities: Capabilities
    struct Capabilities: Hashable, Sendable {
        var supportsInterrupt = false
        var supportsActiveSteering = false
        var activeSteeringInterruptsTools = false
        var supportsQueuedMessages = false
        var supportsCommandApproval = false
        var supportsFileChangeApproval = false
        var emitsProposedPlan = false
        var emitsTodoList = false
        var supportsStructuredQuestions = false
        var pendingRequestsSurviveRestart = false
        init(json j: T3JSON?) {
            guard let j else { return }
            supportsInterrupt = j["turns"]?.flag("supportsInterrupt") ?? false
            supportsActiveSteering = j["turns"]?.flag("supportsActiveSteering") ?? false
            activeSteeringInterruptsTools = j["turns"]?.flag("activeSteeringInterruptsTools") ?? false
            supportsQueuedMessages = j["turns"]?.flag("supportsQueuedMessages") ?? false
            supportsCommandApproval = j["approvals"]?.flag("supportsCommandApproval") ?? false
            supportsFileChangeApproval = j["approvals"]?.flag("supportsFileChangeApproval") ?? false
            emitsProposedPlan = j["planning"]?.flag("emitsProposedPlan") ?? false
            emitsTodoList = j["planning"]?.flag("emitsTodoList") ?? false
            supportsStructuredQuestions = j["planning"]?.flag("supportsStructuredQuestions") ?? false
            pendingRequestsSurviveRestart = j["sessions"]?.flag("pendingRequestsSurviveRestart") ?? false
        }
    }
    init(json j: T3JSON) {
        id = j.str("id") ?? ""; driver = j.str("driver") ?? ""; status = j.str("status") ?? ""
        capabilities = Capabilities(json: j["capabilities"])
    }
}

/// Collections Fjord doesn't read are kept raw (upserted by `id`) so nothing is lost.
struct T3Projection: T3Decodable, Equatable, Sendable {
    var thread: T3ThreadShell
    var runs: [T3Run]
    var messages: [T3Message]
    var runtimeRequests: [T3RuntimeRequest]
    var plans: [T3Plan]
    var turnItems: [T3TurnItem]
    var providerSessions: [T3ProviderSession]
    var others: [String: [T3JSON]]
    var updatedAt: T3Timestamp?

    static let otherKeys = ["attempts", "nodes", "subagents", "providerThreads", "providerTurns", "checkpointScopes",
                            "checkpoints", "contextHandoffs", "contextTransfers"]

    init(json j: T3JSON) {
        thread = T3ThreadShell(json: j["thread"] ?? .null)
        runs = (j["runs"]?.array ?? []).map(T3Run.init)
        messages = (j["messages"]?.array ?? []).map(T3Message.init)
        runtimeRequests = (j["runtimeRequests"]?.array ?? []).map(T3RuntimeRequest.init)
        plans = (j["plans"]?.array ?? []).map(T3Plan.init)
        turnItems = (j["turnItems"]?.array ?? []).map(T3TurnItem.init)
        providerSessions = (j["providerSessions"]?.array ?? []).map(T3ProviderSession.init)
        others = Dictionary(uniqueKeysWithValues: T3Projection.otherKeys.map { ($0, j[$0]?.array ?? []) })
        updatedAt = j.ts("updatedAt")
    }

    var pullRequests: [T3PullRequest] { thread.pullRequests }
    var pendingRequests: [T3RuntimeRequest] { runtimeRequests.filter(\.isPending) }
    var queuedRuns: [T3Run] { runs.filter(\.isQueued).sorted { ($0.queuePosition ?? 0) < ($1.queuePosition ?? 0) } }
    var activeRun: T3Run? { runs.last(where: { $0.status.isLive && !$0.isQueued }) }
    /// Capabilities of the newest attached session; nil until a first run attaches one (S1 #3).
    var capabilities: T3ProviderSession.Capabilities? { providerSessions.last?.capabilities }
}

/// One value of `orchestration.subscribeThread`.
enum T3ThreadItem: T3Decodable, Sendable, Equatable {
    case snapshot(sequence: Int, projection: T3Projection)
    case event(T3ThreadEvent)
    case unknown(kind: String, raw: T3JSON)

    init(json j: T3JSON) {
        switch j.str("kind") ?? "" {
        case "snapshot" where j["projection"] != nil:
            self = .snapshot(sequence: j.num("snapshotSequence") ?? 0, projection: T3Projection(json: j["projection"]!))
        case "event" where j["event"] != nil:
            self = .event(T3ThreadEvent(json: j["event"]!, sequence: j.num("sequence") ?? 0))
        case let k: self = .unknown(kind: k, raw: j)
        }
    }
    var sequence: Int? {
        switch self { case .snapshot(let s, _): s; case .event(let e): e.sequence; case .unknown: nil }
    }
}

/// A domain event. `type` stays a string and `payload` raw, so unknown types decode and still advance the cursor.
struct T3ThreadEvent: Sendable, Equatable {
    var sequence: Int
    var id: String
    var threadId: String
    var runId: String?
    var occurredAt: T3Timestamp?
    var type: String
    var payload: T3JSON
    init(json j: T3JSON, sequence: Int) {
        self.sequence = sequence
        id = j.str("id") ?? ""; threadId = j.str("threadId") ?? ""; runId = j.str("runId")
        occurredAt = j.ts("occurredAt"); type = j.str("type") ?? ""; payload = j["payload"] ?? .null
    }
}

// MARK: - Commands Fjord sends

/// An answer to a question: multi-select is `many` (option values), single-select and custom answers are `one` (S1 d).
enum T3Answer: Equatable, Sendable { case one(String), many([String]) }

/// Where a message goes while the thread may be running (S1 #4, c).
enum T3Dispatch: Equatable, Sendable {
    /// `start_immediately` with `deliveryIntent`: the server resolves steer vs queue vs start (T3's own composer).
    case startImmediately(intent: T3DeliveryIntent)
    case queueAfterActive
    case steerActive(targetRunId: String)
}
enum T3DeliveryIntent: String, Sendable { case steer, auto, restart }

struct T3Attachment: Equatable, Sendable {
    var type: String  // image | file
    var id: String, name: String, mimeType: String, sizeBytes: Int
    var json: T3JSON { ["type": .string(type), "id": .string(id), "name": .string(name), "mimeType": .string(mimeType), "sizeBytes": .number(Double(sizeBytes))] }
}

struct T3LaunchRequest: Equatable, Sendable {
    var threadId: String
    var projectId: String
    var title: String
    var generateTitle = false
    var instanceId: String
    var model: String
    var runtimeMode: T3RuntimeMode = .fullAccess
    var interactionMode: T3InteractionMode = .default
    /// `root`, or `worktree` with a base ref and branch (see OV2:654-671).
    var workspaceStrategy: T3JSON = ["type": "root"]
    var messageId: String
    var text: String
    var attachments: [T3Attachment] = []
    /// Typed context the text points at with `t3-context://` links (`ThreadMessage.records`).
    var context: [T3JSON] = []

    var initialMessage: T3JSON {
        var m: [String: T3JSON] = ["messageId": .string(messageId), "text": .string(text), "attachments": .array(attachments.map(\.json))]
        if !context.isEmpty { m["context"] = ["version": 1, "records": .array(context)] }
        return .object(m)
    }
}

/// Every command Fjord sends. `payload(commandId:)` is exactly what goes in the `dispatchCommand` request
/// (the payload IS the command, S1 #1); `launchThread` has its own RPC and payload.
enum T3Command: Equatable, Sendable {
    case messageDispatch(threadId: String, messageId: String, text: String, dispatch: T3Dispatch,
                         attachments: [T3Attachment] = [], sourcePlan: (threadId: String, planId: String)? = nil,
                         context: [T3JSON] = [])
    case respondDecision(threadId: String, requestId: String, decision: T3Decision, feedback: String? = nil)
    case respondAnswers(threadId: String, requestId: String, answers: [String: T3Answer])
    case runInterrupt(threadId: String, runId: String, reason: String? = nil, holdQueue: Bool = false)
    case queuedRunCancel(threadId: String, runId: String)
    case queuedRunEdit(threadId: String, runId: String, text: String)
    case threadVisit(threadId: String, visitedAt: T3Timestamp, opened: Bool = false)
    case threadMarkUnread(threadId: String)
    case threadArchive(threadId: String)
    case threadUnarchive(threadId: String)
    case runtimeModeSet(threadId: String, mode: T3RuntimeMode)
    case interactionModeSet(threadId: String, mode: T3InteractionMode)
    case tagSet(threadId: String, tag: String, tagged: Bool)
    case snooze(threadId: String, until: T3Timestamp)
    case unsnooze(threadId: String)
    case threadSettle(threadId: String)
    case threadUnsettle(threadId: String)
    case threadRename(threadId: String, title: String)
    case queueResume(threadId: String)
    case launchThread(T3LaunchRequest)

    static func == (a: T3Command, b: T3Command) -> Bool { a.payload(commandId: "x") == b.payload(commandId: "x") }

    var rpcTag: String {
        if case .launchThread = self { return "orchestration.launchThread" }
        return "orchestration.dispatchCommand"
    }

    func payload(commandId: String) -> T3JSON {
        func cmd(_ type: String, _ thread: String, _ extra: [String: T3JSON] = [:]) -> T3JSON {
            .object(extra.merging(["commandId": .string(commandId), "type": .string(type), "threadId": .string(thread)]) { a, _ in a })
        }
        switch self {
        case .messageDispatch(let thread, let messageId, let text, let dispatch, let attachments, let plan, let records):
            var e: [String: T3JSON] = [
                "createdBy": "user", "creationSource": "mcp", "messageId": .string(messageId), "text": .string(text),
                "attachments": .array(attachments.map(\.json)),
            ]
            switch dispatch {
            case .startImmediately(let intent):
                e["dispatchMode"] = ["type": "start_immediately"]; e["deliveryIntent"] = .string(intent.rawValue)
            case .queueAfterActive: e["dispatchMode"] = ["type": "queue_after_active"]
            case .steerActive(let run): e["dispatchMode"] = ["type": "steer_active", "targetRunId": .string(run)]
            }
            if let plan { e["sourcePlanRef"] = ["threadId": .string(plan.threadId), "planId": .string(plan.planId)] }
            // Typed context the text points at with `t3-context://` links (`ThreadMessage`).
            if !records.isEmpty { e["context"] = ["version": 1, "records": .array(records)] }
            return cmd("message.dispatch", thread, e)
        case .respondDecision(let thread, let request, let decision, let feedback):
            var e: [String: T3JSON] = ["requestId": .string(request), "decision": .string(decision.rawValue)]
            if let feedback { e["feedback"] = .string(feedback) }
            return cmd("runtime-request.respond", thread, e)
        case .respondAnswers(let thread, let request, let answers):
            let a = answers.mapValues { v -> T3JSON in
                switch v { case .one(let s): .string(s); case .many(let m): .array(m.map(T3JSON.string)) }
            }
            return cmd("runtime-request.respond", thread, ["requestId": .string(request), "answers": .object(a)])
        case .runInterrupt(let thread, let run, let reason, let hold):
            var e: [String: T3JSON] = ["runId": .string(run)]
            if let reason { e["reason"] = .string(reason) }
            if hold { e["holdQueue"] = true }
            return cmd("run.interrupt", thread, e)
        case .queuedRunCancel(let thread, let run): return cmd("queued-run.cancel", thread, ["runId": .string(run)])
        case .queuedRunEdit(let thread, let run, let text): return cmd("queued-run.edit", thread, ["runId": .string(run), "text": .string(text)])
        case .threadVisit(let thread, let at, let opened):
            var e: [String: T3JSON] = ["visitedAt": .string(at.text)]
            if opened { e["opened"] = true }
            return cmd("thread.visit", thread, e)
        case .threadMarkUnread(let thread): return cmd("thread.mark-unread", thread)
        case .threadArchive(let thread): return cmd("thread.archive", thread)
        case .threadUnarchive(let thread): return cmd("thread.unarchive", thread)
        case .runtimeModeSet(let thread, let mode): return cmd("thread.runtime-mode.set", thread, ["runtimeMode": .string(mode.rawValue)])
        case .interactionModeSet(let thread, let mode): return cmd("thread.interaction-mode.set", thread, ["interactionMode": .string(mode.rawValue)])
        case .tagSet(let thread, let tag, let tagged): return cmd("thread.tag.set", thread, ["tag": .string(tag), "tagged": .bool(tagged)])
        case .snooze(let thread, let until): return cmd("thread.snooze", thread, ["snoozedUntil": .string(until.text)])
        case .unsnooze(let thread): return cmd("thread.unsnooze", thread, ["reason": "user"])
        case .threadSettle(let thread): return cmd("thread.settle", thread)
        case .threadUnsettle(let thread): return cmd("thread.unsettle", thread, ["reason": "user"])
        case .threadRename(let thread, let title): return cmd("thread.metadata.update", thread, ["title": .string(title)])
        case .queueResume(let thread): return cmd("queue.resume", thread)
        case .launchThread(let r):
            return [
                "commandId": .string(commandId), "creationSource": "mcp", "threadId": .string(r.threadId),
                "projectId": .string(r.projectId), "title": .string(r.title), "generateTitle": .bool(r.generateTitle),
                "modelSelection": ["instanceId": .string(r.instanceId), "model": .string(r.model)],
                "runtimeMode": .string(r.runtimeMode.rawValue), "interactionMode": .string(r.interactionMode.rawValue),
                "workspaceStrategy": r.workspaceStrategy,
                "initialMessage": r.initialMessage,
            ]
        }
    }
}

/// `{sequence}` returned by `dispatchCommand`; `launchThread` also returns it (and `threadId`).
struct T3DispatchResult: Equatable, Sendable {
    var sequence: Int?
    var raw: T3JSON
}

/// A failed command: the server's typed error (`OrchestrationV2DispatchCommandError`) or a transport problem.
struct T3Error: Error, Equatable, Sendable, CustomStringConvertible {
    enum Kind: Equatable, Sendable { case server, disconnected, timedOut, incompatible, noToken, noServer, tokenRejected, interrupted, malformed }
    var kind: Kind
    var message: String
    var detail: String? = nil
    var commandType: String? = nil
    var tag: String? = nil
    var description: String { "T3 \(kind)\(tag.map { " (\($0))" } ?? ""): \(message)" }
}
