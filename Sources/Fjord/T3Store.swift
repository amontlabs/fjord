import Foundation
import Observation

// State for the T3 client: the shell (threads + projects) and one projection per subscribed thread.
// Both reducers are pure value types, so tests drive them without a socket.

/// The shell stream folded into rows. Every `snapshot` merges (S1 #10); `thread.removed` deletes (archive, S1 #12).
struct T3ShellState: Equatable, Sendable {
    var threads: [String: T3ThreadShell] = [:]
    var projects: [String: T3Project] = [:]
    /// Highest sequence seen: pass it as `afterSequence` when resubscribing.
    var sequence: Int?
    var synchronized = false

    mutating func apply(_ item: T3ShellItem) {
        if let s = item.sequence { sequence = max(sequence ?? 0, s) }
        switch item {
        case .synchronized: synchronized = true
        case .snapshot(let s):
            for p in s.projects { projects[p.id] = p }
            for t in s.threads where !t.id.isEmpty { threads[t.id] = t }
            // archivedThreads are not listed; make sure none lingers as active.
            for t in s.archivedThreads { threads[t.id] = nil }
        case .projectUpdated(_, let p): projects[p.id] = p
        case .projectRemoved(_, let id): projects[id] = nil
        case .threadUpdated(_, let location, let t):
            if location == .archive { threads[t.id] = nil } else if !t.id.isEmpty { threads[t.id] = t }
        case .threadRemoved(_, _, let id): threads[id] = nil
        case .unknown: break
        }
    }

    /// Threads a list shows: not a subagent or side chat (`isListedThreadLineage`), not archived or deleted.
    var listedThreads: [T3ThreadShell] {
        threads.values.filter { $0.isListed && $0.archivedAt == nil && $0.deletedAt == nil }
            .sorted { (a: T3ThreadShell, b: T3ThreadShell) -> Bool in
                let (x, y) = (a.updatedAt?.text ?? "", b.updatedAt?.text ?? "")
                return x != y ? x > y : a.id < b.id
            }
    }
    func listedThreads(in projectId: String) -> [T3ThreadShell] { listedThreads.filter { $0.projectId == projectId } }
    /// Listed threads with a blocking pending request or a proposed plan to act on.
    var needingYou: [T3ThreadShell] {
        listedThreads.filter { ($0.pendingRuntimeRequest?.blocking ?? false) || $0.hasActionableProposedPlan }
    }
    /// Counts by status, for the probe (no titles).
    var statusCounts: [String: Int] {
        listedThreads.reduce(into: [:]) { $0[$1.status.rawValue, default: 0] += 1 }
    }
}

extension T3Projection {
    /// Mirrors `applyOrchestrationV2ProjectionEvent` (client-runtime). Events are whole-record upserts.
    /// `visibleTurnItems` isn't kept: `turnItems` is ordered by ordinal and carries what Fjord reads.
    mutating func apply(_ e: T3ThreadEvent) {
        guard e.threadId.isEmpty || e.threadId == thread.id else { return }
        let p = e.payload
        func bump() { updatedAt = e.occurredAt ?? updatedAt }
        switch e.type {
        case "thread.visited", "thread.tags-updated", "thread.marked-unread":
            thread = T3ThreadShell(json: p)  // not activity: no updatedAt bump
        case let t where t.hasPrefix("thread.") && t != "thread.pull-request-link-updated" && p.isObject && p["id"] != nil:
            thread = T3ThreadShell(json: p); bump()
        case "run.created", "run.updated": upsert(&runs, T3Run(json: p)); bump()
        case "message.updated": upsert(&messages, T3Message(json: p)); bump()
        case "runtime-request.updated": upsert(&runtimeRequests, T3RuntimeRequest(json: p)); bump()
        case "plan.updated": upsert(&plans, T3Plan(json: p)); bump()
        case "provider-session.attached", "provider-session.updated": upsert(&providerSessions, T3ProviderSession(json: p)); bump()
        case "provider-session.detached":
            let id = p.str("providerSessionId")
            providerSessions.removeAll { $0.id == id }; bump()
        case "turn-item.updated": applyItem(T3TurnItem(json: p)); bump()
        case "run-attempt.created", "run-attempt.updated": upsertRaw("attempts", p); bump()
        case "node.updated": upsertRaw("nodes", p); bump()
        case "subagent.updated": upsertRaw("subagents", p); bump()
        case "provider-thread.updated": upsertRaw("providerThreads", p); bump()
        case "provider-turn.updated": upsertRaw("providerTurns", p); bump()
        case "checkpoint-scope.created": upsertRaw("checkpointScopes", p); bump()
        case "checkpoint.captured": upsertRaw("checkpoints", p); bump()
        case "context-handoff.updated": upsertRaw("contextHandoffs", p); bump()
        case "context-transfer.created", "context-transfer.updated": upsertRaw("contextTransfers", p); bump()
        default: break  // unknown or irrelevant type: ignored, but the caller still advances its cursor
        }
    }

    private mutating func applyItem(_ item: T3TurnItem) {
        var item = item
        if item.textOmitted, let text = messages.last(where: { m in
            switch item.detail {
            case .userMessage(let id, _), .assistantMessage(let id, _, _): m.id == id
            default: false
            }
        })?.text {
            switch item.detail {
            case .userMessage(let id, _): item.detail = .userMessage(messageId: id, text: text)
            case .assistantMessage(let id, _, let s): item.detail = .assistantMessage(messageId: id, text: text, streaming: s)
            default: break
            }
        }
        if let i = turnItems.lastIndex(where: { $0.id == item.id }) {
            turnItems[i] = item
            if i > 0, turnItems[i - 1].ordinal > item.ordinal || (i + 1 < turnItems.count && turnItems[i + 1].ordinal < item.ordinal) { sortItems() }
        } else {
            turnItems.append(item)
            if turnItems.count > 1, turnItems[turnItems.count - 2].ordinal > item.ordinal { sortItems() }
        }
    }
    private mutating func sortItems() {
        turnItems.sort { $0.ordinal != $1.ordinal ? $0.ordinal < $1.ordinal : $0.id < $1.id }
    }
    private mutating func upsertRaw(_ key: String, _ p: T3JSON) {
        guard let id = p.str("id") else { return }
        var list = others[key] ?? []
        if let i = list.firstIndex(where: { $0.str("id") == id }) { list[i] = p } else { list.append(p) }
        others[key] = list
    }
    private func upsert<T: Identifiable>(_ list: inout [T], _ item: T) where T.ID == String {
        if let i = list.firstIndex(where: { $0.id == item.id }) { list[i] = item } else { list.append(item) }
    }
}

/// Live state for views: the shell plus the thread projections someone asked for.
@MainActor @Observable
final class T3Store {
    private(set) var shell = T3ShellState()
    private(set) var projections: [String: T3Projection] = [:]
    private(set) var connection: T3ConnectionState = .connecting

    /// Called on the main actor after every shell item is applied (nil: a whole new shell, `seed`), so what is built from the
    /// shell follows each change as it lands, with no polling.
    @ObservationIgnored var onShell: ((T3ShellItem?) -> Void)?
    /// Called when the connection's state changes.
    @ObservationIgnored var onConnection: ((T3ConnectionState) -> Void)?

    @ObservationIgnored private var client: T3Client?
    @ObservationIgnored private var shellTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var threadTasks: [String: Task<Void, Never>] = [:]

    var listedThreads: [T3ThreadShell] { shell.listedThreads }
    var projects: [T3Project] { shell.projects.values.sorted { $0.title.localizedCompare($1.title) == .orderedAscending } }

    func start(client: T3Client) {
        stop()
        self.client = client
        shellTask = Task { [weak self] in
            for await item in await client.subscribeShell() {
                guard let self else { return }
                self.shell.apply(item)
                self.onShell?(item)
            }
        }
        statusTask = Task { [weak self] in
            for await s in await client.connectionStates() {
                guard let self else { return }
                self.connection = s
                self.onConnection?(s)
            }
        }
    }

    /// A shell with no server behind it: demo data, shots and tests (`notify: false` leaves telling `onShell` to the test).
    func seed(_ shell: T3ShellState, notify: Bool = true) {
        self.shell = shell
        if notify { onShell?(nil) }
    }

    func stop() {
        shellTask?.cancel(); statusTask?.cancel()
        threadTasks.values.forEach { $0.cancel() }
        threadTasks = [:]; shellTask = nil; statusTask = nil
    }

    /// Opens a thread subscription (idempotent). Close it when the thread leaves the screen or settles.
    func openThread(_ id: String) {
        guard threadTasks[id] == nil, let client else { return }
        threadTasks[id] = Task { [weak self] in
            for await item in await client.subscribeThread(id) {
                guard let self else { return }
                switch item {
                case .snapshot(_, let projection): self.projections[id] = projection
                case .event(let e): self.projections[id]?.apply(e)
                case .unknown: break
                }
            }
        }
    }

    func closeThread(_ id: String) {
        threadTasks.removeValue(forKey: id)?.cancel()
        projections[id] = nil
    }

    @discardableResult
    func send(_ command: T3Command) async throws -> T3DispatchResult {
        guard let client else { throw T3Error(kind: .disconnected, message: "Not connected") }
        return try await client.dispatch(command)
    }
}
