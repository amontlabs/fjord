import Foundation

/// What a thread has going besides the step it is on: its subagents, the commands it left running in the background, and
/// what it waits on (another thread, a monitor, a command it said it resumes after). T3's own watch of a pull request is
/// not the agent's work and isn't listed (the shell drops it, `T3ThreadShell`). The line shows it as
/// a few muted glyphs, the peek and the card list it (docs/design/router-v2/DESIGN.md 1.4, 1.5, 1.6).
///
/// Read from the thread's projection, which carries all of it (T3 v0.1.7, `OV2` = `packages/contracts/src/orchestrationV2.ts`):
/// - `subagents[]` (`OV2:884`): `title`, `prompt`, `model`, `status`, `startedAt`. The model is the provider's id
///   (`claude-opus-5-5`), or the agent type's name when the subagent was started as a named agent (`judge`).
/// - `providerThreads[].pendingBackgroundTasks` (`OV2:1094`): the agent's live roster, during the turn and after it:
///   `{taskId, kind: subagent|command|monitor|background_task, description?, awaited?}`. No start time. The shell's own
///   list (`thread.pendingBackgroundTasks`) is the same roster, but empty while a run is active.
/// - Turn items: a `command_execution` started in the background answers with its task id in its output (Claude's Bash:
///   "…in background with ID: bkfz9x4ct"), which gives the command and its `startedAt`; live `dynamic_tool` items give
///   the waits (`t3_thread_wait`, `t3_background_wait`, Claude's `Monitor`).
struct RouterV2Activity: Equatable {
    struct Agent: Equatable, Identifiable {
        var id: String
        var name: String
        /// The provider's model id as T3 has it; nil when T3 has none.
        var model: String?
        var since: Date?
    }

    struct Process: Equatable, Identifiable {
        var id: String
        /// The command's first line, or T3's description when the command isn't in the projection.
        var command: String
        /// `command` is the command itself (drawn in mono).
        var mono: Bool
        var since: Date?
    }

    struct Wait: Equatable, Identifiable {
        enum Kind: Equatable { case thread, monitor, command, task }
        var id: String
        var kind: Kind
        var what: String
        /// `what` is a command (drawn in mono).
        var mono = false
        /// The thread waited on (a `t3_thread_wait`), for its name.
        var thread: String?
        var since: Date?
    }

    var agents: [Agent] = []
    var processes: [Process] = []
    var waits: [Wait] = []

    var isEmpty: Bool { agents.isEmpty && processes.isEmpty && waits.isEmpty }

    /// The line's one sentence for it, for the accessibility label: "2 subagents, 1 background command, waiting on 1".
    var summary: String {
        var parts: [String] = []
        if !agents.isEmpty { parts.append(agents.count == 1 ? "1 subagent" : "\(agents.count) subagents") }
        if !processes.isEmpty { parts.append(processes.count == 1 ? "1 background command" : "\(processes.count) background commands") }
        if !waits.isEmpty { parts.append("waiting on \(waits.count)") }
        return parts.joined(separator: ", ")
    }
}

extension RouterV2Activity {
    /// Reads a projection: one pass over its turn items, the subagents and the roster. Nothing in it moves unless the
    /// work does, so the record stays equal across the projection's other events.
    static func make(_ p: T3Projection) -> RouterV2Activity {
        func live(_ status: String?) -> Bool { status == "pending" || status == "running" || status == "waiting" }
        func date(_ j: T3JSON, _ key: String) -> Date? { j.ts(key).flatMap(AgentThread.date) }

        // The roster, by task id: every provider thread's, then the shell's (PR watches, a roster from before a restart).
        var roster: [T3PendingTask] = []
        var seen = Set<String>()
        let providerTasks = (p.others["providerThreads"] ?? []).flatMap { ($0["pendingBackgroundTasks"]?.array ?? []).map(T3PendingTask.init) }
        for task in providerTasks + p.thread.pendingBackgroundTasks where !task.id.isEmpty && seen.insert(task.id).inserted {
            roster.append(task)
        }

        // Live items, one pass: subagent rows, waits, and what a background wait names as awaited.
        var subagentItems: [T3TurnItem] = []
        var waitItems: [T3TurnItem] = []
        var awaited = Set<String>()
        for item in p.turnItems where live(item.status) {
            switch item.type {
            case "subagent": subagentItems.append(item)
            case .dynamicTool:
                switch toolId(item) {
                case "t3_background_wait":
                    for id in item.raw["input"]?["taskIds"]?.array ?? [] { if let s = id.string { awaited.insert(s) } }
                case "t3_thread_wait", "Monitor": waitItems.append(item)
                default: break
                }
            default: break
            }
        }

        var a = RouterV2Activity()

        // Subagents: T3's records (title, model, start), then a live item or a roster entry no record covers.
        var agentIds = Set<String>()
        var childThreads = Set<String>()
        for s in p.others["subagents"] ?? [] where live(s.str("status")) {
            guard let id = s.str("id") else { continue }
            agentIds.insert(id)
            if let child = s.str("childThreadId") { childThreads.insert(child) }
            a.agents.append(.init(id: id, name: name(s.str("title"), s.str("prompt")) ?? Copy.subagent,
                                  model: s.str("model").flatMap { $0.isEmpty ? nil : $0 },
                                  since: date(s, "startedAt") ?? date(s, "createdAt")))
        }
        for item in subagentItems {
            let id = item.raw.str("subagentId") ?? item.id
            guard agentIds.insert(id).inserted else { continue }
            if let child = item.raw.str("childThreadId") { childThreads.insert(child) }
            a.agents.append(.init(id: id, name: name(item.title, item.raw.str("prompt")) ?? Copy.subagent, model: nil,
                                  since: date(item.raw, "startedAt")))
        }

        for task in roster {
            let held = task.awaited || awaited.contains(task.id)
            switch task.kind {
            case "subagent":
                // T3's records and items name a subagent by node, the roster by the provider's task: the same one is
                // the same child thread, or the same words.
                if let child = task.childThreadId, childThreads.contains(child) { continue }
                if let d = task.description, a.agents.contains(where: { $0.name == RouterDetail.sentence(d) }) { continue }
                guard agentIds.insert(task.id).inserted else { continue }
                a.agents.append(.init(id: task.id, name: task.description ?? Copy.subagent, model: nil, since: nil))
            case "command":
                let started = command(started: task.id, in: p.turnItems)
                let text = started.map { firstLine($0.input) }.flatMap { $0.isEmpty ? nil : $0 }
                let shown = text ?? task.description ?? Copy.command
                if held {
                    a.waits.append(.init(id: task.id, kind: .command, what: shown, mono: text != nil, since: started?.since))
                } else {
                    a.processes.append(.init(id: task.id, command: shown, mono: text != nil, since: started?.since))
                }
            case "monitor":
                a.waits.append(.init(id: task.id, kind: .monitor, what: task.description ?? Copy.monitor))
            default:
                if held {
                    a.waits.append(.init(id: task.id, kind: .task, what: task.description ?? Copy.task))
                } else {
                    a.processes.append(.init(id: task.id, command: task.description ?? Copy.task, mono: false, since: nil))
                }
            }
        }

        // Waits the turn is on: another thread, or a monitor the roster doesn't list yet.
        let monitors = Set(a.waits.filter { $0.kind == .monitor }.map(\.what))
        for item in waitItems {
            let input = item.raw["input"]
            if toolId(item) == "t3_thread_wait" {
                a.waits.append(.init(id: item.id, kind: .thread, what: Copy.anotherThread, thread: input?.str("threadId"),
                                     since: date(item.raw, "startedAt")))
            } else {
                let what = input?.str("description").map { RouterDetail.sentence($0) } ?? firstLine(input?.str("command") ?? "")
                guard !monitors.contains(what) else { continue }
                a.waits.append(.init(id: item.id, kind: .monitor, what: what.isEmpty ? Copy.monitor : what,
                                     since: date(item.raw, "startedAt")))
            }
        }
        return a
    }

    /// What is new gets a start time when T3 gives none: the one it had before, else `now` (the moment Fjord first saw it).
    func stamped(after previous: RouterV2Activity?, now: Date) -> RouterV2Activity {
        guard !isEmpty else { return self }
        var a = self
        let old = previous ?? .init()
        func before<T: Identifiable>(_ list: [T], _ id: T.ID, _ since: (T) -> Date?) -> Date? {
            list.first { $0.id == id }.flatMap(since)
        }
        for i in a.agents.indices where a.agents[i].since == nil {
            a.agents[i].since = before(old.agents, a.agents[i].id, \.since) ?? now
        }
        for i in a.processes.indices where a.processes[i].since == nil {
            a.processes[i].since = before(old.processes, a.processes[i].id, \.since) ?? now
        }
        for i in a.waits.indices where a.waits[i].since == nil {
            a.waits[i].since = before(old.waits, a.waits[i].id, \.since) ?? now
        }
        return a
    }

    /// A model id as a person says it: `claude-opus-5-5` → "Opus 5.5"; anything else as T3 has it.
    static func modelName(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst("claude-".count).split(separator: "-")
        guard let family = parts.first, family.allSatisfy(\.isLetter) else { return id }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }
        return ([family.prefix(1).uppercased() + family.dropFirst()] + (version.isEmpty ? [] : [version.joined(separator: ".")]))
            .joined(separator: " ")
    }

    enum Copy {
        static let subagent = "Subagent"
        static let command = "Background command"
        static let monitor = "Monitor"
        static let task = "Background task"
        static let anotherThread = "another thread"
    }

    // MARK: Pieces

    /// T3's own tool id: a T3 tool's name without its MCP prefix (`mcp__t3-code__t3_thread_wait` → `t3_thread_wait`).
    private static func toolId(_ item: T3TurnItem) -> String {
        guard case .dynamicTool(let name) = item.detail else { return "" }
        guard let r = name.range(of: "__", options: .backwards) else { return name }
        return String(name[r.upperBound...])
    }

    /// The command started in the background as `task`: the newest command item whose output names the task id.
    private static func command(started task: String, in items: [T3TurnItem]) -> (input: String, since: Date?)? {
        var looked = 0
        for item in items.reversed() {
            guard case .commandExecution(let input, let output, _) = item.detail else { continue }
            looked += 1
            if let output, output.utf8.count < 4096, output.contains(task) {
                return (input, item.raw.ts("startedAt").flatMap(AgentThread.date))
            }
            if looked >= 400 { break }
        }
        return nil
    }

    private static func name(_ title: String?, _ prompt: String?) -> String? {
        for c in [title, prompt] {
            if let c, case let t = RouterDetail.sentence(c), !t.isEmpty { return t }
        }
        return nil
    }

    private static func firstLine(_ text: String, cap: Int = 120) -> String {
        guard let line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return "" }
        return line.count > cap ? String(line.prefix(cap - 1)) + "…" : line
    }
}
