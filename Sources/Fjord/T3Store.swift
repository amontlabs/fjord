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
    /// T3's authoritative snapshot (its projects and threads) has been applied: T3 has answered, marker or not.
    var snapshotted = false

    /// T3 has told us what it has: by its `synchronized` marker, or by its snapshot (a server that doesn't send the marker).
    var answered: Bool { synchronized || snapshotted }

    mutating func apply(_ item: T3ShellItem) {
        if let s = item.sequence { sequence = max(sequence ?? 0, s) }
        switch item {
        case .synchronized: synchronized = true
        case .snapshot(let s):
            snapshotted = true
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

    /// This shell without the projects whose folder is `root` (paths compared standardized) and every thread in them,
    /// subagents and side chats included: what the Router sees of T3 while Fjord keeps a project of its own there (Show me's
    /// explainers, ExplainerProject.swift).
    func without(projectRoot root: String?) -> T3ShellState {
        guard let root else { return self }
        return without(projects: projectIDs(atRoot: root), threads: [])
    }

    /// This shell without these projects, every thread in them, and these threads.
    func without(projects gone: Set<String>, threads: Set<String>) -> T3ShellState {
        guard !gone.isEmpty || !threads.isEmpty else { return self }
        var out = self
        for id in gone { out.projects[id] = nil }
        out.threads = self.threads.filter { !gone.contains($0.value.projectId) && !threads.contains($0.key) }
        return out
    }

    /// The ids of the projects whose folder is `root`.
    func projectIDs(atRoot root: String) -> Set<String> {
        let wanted = Self.standardized(root)
        return Set(projects.values.filter { Self.standardized($0.workspaceRoot) == wanted }.map(\.id))
    }

    static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
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
    /// The shell every Router surface reads: `hidden` without the project at `hiddenRoot`. Filtering here, at the one place
    /// the shell comes in, keeps that project off every list, board, tally and search built from it with no filter of their own.
    private(set) var shell = T3ShellState()
    /// The whole shell as T3 sent it, the hidden project included (for the code that keeps that project).
    @ObservationIgnored private(set) var hidden = T3ShellState()
    /// The folder of the project Fjord keeps for itself in T3 (Show me's explainers), kept out of `shell`. Setting it filters
    /// the shell again and tells `onShell` (as a whole new shell) when that changed what it holds.
    @ObservationIgnored var hiddenRoot: String? {
        didSet {
            guard hiddenRoot != oldValue else { return }
            hiddenProjects = hiddenRoot.map { hidden.projectIDs(atRoot: $0) } ?? []
            hiddenThreads = Set(hidden.threads.values.filter { hiddenProjects.contains($0.projectId) }.map(\.id))
            refilter(notify: true)
        }
    }
    /// Every project id seen at `hiddenRoot`, and every thread id seen in one of them: kept when T3 archives a thread or
    /// removes the project, so a thread that left the shell is still known as Fjord's (T3's search and reads still find it).
    @ObservationIgnored private var hiddenProjects: Set<String> = []
    @ObservationIgnored private var hiddenThreads: Set<String> = []
    /// Threads Fjord says are its own (the explainers' runs), whether or not the shell ever showed them.
    @ObservationIgnored private var ownThreads: Set<String> = []

    /// Whether `id` is a thread of the hidden project (or one Fjord named): kept out of the Router's shell, its search and reads.
    func isHidden(thread id: String) -> Bool { hiddenThreads.contains(id) || ownThreads.contains(id) }

    /// Fjord's own threads (the explainers'), hidden from the Router whatever project T3 files them in.
    func hide(threads ids: some Sequence<String>) {
        let new = Set(ids).subtracting(ownThreads)
        guard !new.isEmpty else { return }
        ownThreads.formUnion(new)
        refilter(notify: true)
    }

    /// Learns the hidden project's ids and threads from one item; true when it learned a project (the shell is filtered again).
    private func learn(_ item: T3ShellItem) -> Bool {
        guard let hiddenRoot else { return false }
        let root = T3ShellState.standardized(hiddenRoot)
        var newProject = false
        func project(_ p: T3Project) {
            if T3ShellState.standardized(p.workspaceRoot) == root, hiddenProjects.insert(p.id).inserted { newProject = true }
        }
        func thread(_ t: T3ThreadShell) { if hiddenProjects.contains(t.projectId) { hiddenThreads.insert(t.id) } }
        switch item {
        case .snapshot(let s):
            s.projects.forEach(project)
            if newProject { hiddenThreads.formUnion(hidden.threads.values.filter { hiddenProjects.contains($0.projectId) }.map(\.id)) }
            s.threads.forEach(thread); s.archivedThreads.forEach(thread)
        case .projectUpdated(_, let p):
            project(p)
            if newProject { hiddenThreads.formUnion(hidden.threads.values.filter { $0.projectId == p.id }.map(\.id)) }
        case .threadUpdated(_, _, let t): thread(t)
        default: break
        }
        return newProject
    }

    /// Whether an item is only about the hidden project: it changes nothing the Router's shell holds.
    private func onlyHidden(_ item: T3ShellItem) -> Bool {
        switch item {
        case .projectUpdated(_, let p): hiddenProjects.contains(p.id)
        case .projectRemoved(_, let id): hiddenProjects.contains(id)
        case .threadUpdated(_, _, let t): isHidden(thread: t.id)
        case .threadRemoved(_, _, let id): isHidden(thread: id)
        default: false
        }
    }

    /// `shell` made again from the whole shell, in full: on a snapshot or when what's hidden changed.
    private func refilter(notify: Bool = false) {
        let next = hidden.without(projects: hiddenProjects, threads: hiddenThreads.union(ownThreads))
        guard next != shell else { return }
        shell = next
        if notify { onShell?(nil) }
    }
    private(set) var projections: [String: T3Projection] = [:]
    private(set) var connection: T3ConnectionState = .connecting
    /// This T3's environment id (from its descriptor, read once connected): the middle of a thread's deep link.
    private(set) var environmentID: String?

    /// Called on the main actor after every shell item is applied (nil: a whole new shell, `seed`), so what is built from the
    /// shell follows each change as it lands, with no polling.
    @ObservationIgnored var onShell: ((T3ShellItem?) -> Void)?
    /// Called when the connection's state changes.
    @ObservationIgnored var onConnection: ((T3ConnectionState) -> Void)?
    /// Called on the main actor after a subscribed thread's projection changed (a snapshot or an event).
    @ObservationIgnored var onThread: ((String) -> Void)?

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
                self.apply(item)
                self.onShell?(item)
            }
        }
        statusTask = Task { [weak self] in
            for await s in await client.connectionStates() {
                guard let self else { return }
                self.connection = s
                if s == .connected, let env = await client.environmentId { self.environmentID = env }
                self.onConnection?(s)
            }
        }
    }

    /// One shell item into the whole shell, then the Router's shell made from it again. Items about the hidden project's
    /// threads still reach `onShell`: every consumer reads the row from `shell` by id, finds none and drops nothing it had.
    /// Only a snapshot or a newly seen hidden project filters the whole shell; any other item lands in `shell` alone, so an
    /// item costs the same however many threads T3 holds.
    func apply(_ item: T3ShellItem) {
        hidden.apply(item)
        if learn(item) || { if case .snapshot = item { true } else { false } }() { return refilter() }
        if onlyHidden(item) {
            if shell.sequence != hidden.sequence { shell.sequence = hidden.sequence }
        } else {
            shell.apply(item)
        }
    }

    /// A shell with no server behind it: demo data, shots and tests (`notify: false` leaves telling `onShell` to the test).
    func seed(_ shell: T3ShellState, notify: Bool = true) {
        hidden = shell
        hiddenProjects.formUnion(hiddenRoot.map { shell.projectIDs(atRoot: $0) } ?? [])
        hiddenThreads.formUnion(shell.threads.values.filter { hiddenProjects.contains($0.projectId) }.map(\.id))
        self.shell = shell.without(projects: hiddenProjects, threads: hiddenThreads.union(ownThreads))
        if notify { onShell?(nil) }
    }

    /// A projection with no server behind it: shots and tests.
    func seed(_ projection: T3Projection, for id: String) {
        projections[id] = projection
        onThread?(id)
    }

    var hasClient: Bool { client != nil }

    func setEnvironment(_ id: String?) { environmentID = id }

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
                case .unknown: continue
                }
                self.onThread?(id)
            }
            // The stream ended by itself (the link closed): a later `watch` may open it again.
            if !Task.isCancelled { self?.threadTasks[id] = nil }
        }
    }

    /// The first thing you asked, from a projection (capped for a prompt).
    nonisolated static func firstUserMessage(in p: T3Projection) -> String? {
        let text = p.messages.first { $0.role == "user" && !$0.text.isEmpty }?.text
            ?? p.turnItems.lazy.compactMap { i -> String? in if case .userMessage(_, let t) = i.detail, !t.isEmpty { t } else { nil } }.first
        return text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The last message you sent in a thread (what the decider shows as "you last said there").
    nonisolated static func lastUserMessage(in p: T3Projection) -> String? {
        let text = p.messages.last { $0.role == "user" && !$0.text.isEmpty }?.text
            ?? p.turnItems.lazy.reversed().compactMap { i -> String? in if case .userMessage(_, let t) = i.detail, !t.isEmpty { t } else { nil } }.first
        return text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The thread's last assistant reply, from a projection, whole (each prompt trims what it shows).
    nonisolated static func lastAssistantMessage(in p: T3Projection) -> String? {
        let text = p.messages.last { $0.role == "assistant" && !$0.text.isEmpty }?.text
            ?? p.turnItems.lazy.reversed().compactMap { i -> String? in if case .assistantMessage(_, let t, _) = i.detail, !t.isEmpty { t } else { nil } }.first
        return text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The end of a thread, as the decider's board reads it: your last words and the agent's last reply.
    nonisolated static func tail(of p: T3Projection) -> ThreadReads {
        ThreadReads(youSaid: lastUserMessage(in: p), reply: lastAssistantMessage(in: p), first: firstUserMessage(in: p),
                    earlier: lastUserMessages(in: p, 3))
    }

    /// Your last `n` messages in a thread, oldest first (each capped for a prompt).
    nonisolated static func lastUserMessages(in p: T3Projection, _ n: Int) -> [String] {
        var texts = p.messages.filter { $0.role == "user" && !$0.text.isEmpty }.map(\.text)
        if texts.isEmpty {
            texts = p.turnItems.compactMap { i -> String? in if case .userMessage(_, let t) = i.detail, !t.isEmpty { t } else { nil } }
        }
        return texts.suffix(n).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)) }.filter { !$0.isEmpty }
    }

    /// Reads a thread's end through a bounded snapshot (T3 caps it at the last 10 user turns, 75 items and 1 MiB), held only
    /// until it arrives and given up after `timeout` seconds.
    func readTail(_ id: String, timeout: TimeInterval = 5) async -> ThreadReads? {
        guard let client else { return nil }
        return await withTaskGroup(of: ThreadReads?.self) { group in
            group.addTask {
                for await item in await client.subscribeThread(id, bounded: true) {
                    if case .snapshot(_, let p) = item { return Self.tail(of: p) }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Reads a thread's first message through a subscription held only until its snapshot arrives.
    func readFirstUserMessage(_ id: String) async -> String? {
        guard let client else { return nil }
        for await item in await client.subscribeThread(id) {
            if case .snapshot(_, let p) = item { return Self.firstUserMessage(in: p) }
        }
        return nil
    }

    /// `orchestration.searchThreads`: matches by title and message text, best first.
    func search(_ query: String, limit: Int) async throws -> [ThreadMatch] {
        let result = try await call(tag: "orchestration.searchThreads", payload: ["query": .string(query), "limit": .number(Double(limit))])
        return (result["matches"]?.array ?? []).map(ThreadMatch.init).filter { !$0.threadId.isEmpty }
    }

    /// A thread's projection: the one held for the screen, else its snapshot through a subscription held only until it arrives.
    func readProjection(_ id: String) async -> T3Projection? {
        if let held = projections[id] { return held }
        guard let client else { return nil }
        for await item in await client.subscribeThread(id) {
            if case .snapshot(_, let p) = item { return p }
        }
        return nil
    }

    /// A thread's projection as T3 has it now, through a bounded snapshot held only until it arrives (the one held for the
    /// screen may lag a run that just ended); with no link, the one held. Given up after `timeout` seconds.
    func readSnapshot(_ id: String, timeout: TimeInterval = 8) async -> T3Projection? {
        guard let client else { return projections[id] }
        return await withTaskGroup(of: T3Projection?.self) { group in
            group.addTask {
                for await item in await client.subscribeThread(id, bounded: true) {
                    if case .snapshot(_, let p) = item { return p }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func closeThread(_ id: String) {
        threadTasks.removeValue(forKey: id)?.cancel()
        projections[id] = nil
    }

    /// Holds a subscription for exactly these threads: opens the ones not yet open, closes the rest. Subscriptions cost the
    /// server a stream each, so they live only as long as someone needs the thread's detail.
    func watch(_ wanted: Set<String>) {
        for id in wanted.subtracting(threadTasks.keys) { openThread(id) }
        for id in Set(threadTasks.keys).subtracting(wanted) { closeThread(id) }
        for id in Set(projections.keys).subtracting(wanted) where threadTasks[id] == nil { projections[id] = nil }
    }
    var watchedThreads: Set<String> { Set(threadTasks.keys) }

    /// `t3code://threads/<environment>/<thread>`, which T3 maps to the thread's page; nil until the environment is known.
    func deepLink(_ thread: String) -> URL? {
        guard let environmentID, !environmentID.isEmpty else { return nil }
        return URL(string: "t3code://threads/\(environmentID)/\(thread)")
    }

    /// A unary request (for example `server.getConfig`).
    func call(tag: String, payload: T3JSON = [:]) async throws -> T3JSON {
        guard let client else { throw T3Error(kind: .disconnected, message: "Not connected") }
        return try await client.call(tag: tag, payload: payload)
    }

    @discardableResult
    func send(_ command: T3Command, commandId: String = UUID().uuidString.lowercased()) async throws -> T3DispatchResult {
        guard let client else { throw T3Error(kind: .disconnected, message: "Not connected") }
        return try await client.dispatch(command, commandId: commandId)
    }
}

// The decider's thread cards read a thread's turns (DeciderContextSource.swift, ThreadCards.swift).
extension T3Store {
    /// A thread's turns (yours and the agent's, with their times) through a bounded snapshot, given up after `timeout` seconds.
    func readTurns(_ id: String, timeout: TimeInterval = 8) async -> [ThreadTurn]? {
        guard let client else { return nil }
        return await withTaskGroup(of: [ThreadTurn]?.self) { group in
            group.addTask {
                for await item in await client.subscribeThread(id, bounded: true) {
                    if case .snapshot(_, let p) = item { return Self.turns(of: p) }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    nonisolated static func turns(of p: T3Projection) -> [ThreadTurn] {
        p.messages.compactMap { m -> ThreadTurn? in
            guard m.role == "user" || m.role == "assistant", !m.text.isEmpty, !m.streaming,
                  let at = (m.createdAt ?? m.updatedAt).flatMap(AgentThread.date) else { return nil }
            return ThreadTurn(role: m.role, at: at, text: m.text)
        }
    }
}

