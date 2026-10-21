import AppKit
import CoreServices
import Foundation

/// A Claude Code session of the Claude desktop app, as read from the app's own files. Nothing here is a public API:
/// every field is optional on disk, and anything unexpected is skipped rather than trusted.
struct ClaudeSession: Identifiable, Hashable {
    var id: String
    var title: String
    /// Repository root (worktrees collapse onto it); nil for scratch chats, which have no folder of their own.
    var folder: String?
    var isArchived = false
    var completedTurns = 0
    var lastActivity: Date
    var lastFocused: Date?
    var lastUserMessage: Date?
    /// The app's own one-line summary of the latest finished turn.
    var summary: Summary?
    var running = false
    /// Claude Code's own session id: names the transcript (`~/.claude/projects/*/<id>.jsonl`).
    var cliID: String?
    /// Desktop's own SSH connection metadata. Local mirrors expose the configured host alias here.
    var sshHost: String? = nil

    struct Summary: Hashable {
        var blocked: Bool
        var detail: String
    }

    var folderName: String { folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Scratch" }
    /// Mute key: the folder path, or "" for scratch chats.
    var folderKey: String { folder ?? "" }
    /// Changes whenever a turn finishes or a new message is sent.
    var activity: String { "\(completedTurns)|\(Int((lastUserMessage ?? .distantPast).timeIntervalSince1970))" }
}

/// What a working agent is on right now, and since when.
struct ClaudeActivity: Hashable {
    var text: String
    var since: Date
    /// Stopped mid-turn on you: a question, or a plan to approve.
    var waitsForYou = false
    /// The tool it waits on you with (`AskUserQuestion`, `ExitPlanMode`): tells a question from a plan.
    var tool: String? = nil
    /// That call's id in the transcript: what ties a card to the form Fjord's hook holds for the same call.
    var toolUseID: String? = nil
    /// The session's task list as its last TodoWrite left it.
    var todo: Todo? = nil
    /// The agent's latest words between tool calls in this turn (the last assistant text block, trimmed); at a turn's end,
    /// its final message.
    var narration: String? = nil

    struct Todo: Hashable {
        var done: Int
        var total: Int
        /// The in-progress item, in the present tense (its `activeForm`).
        var active: String?
    }
}

/// A subagent or shell command a session started in the background, still running.
struct ClaudeTask: Hashable, Identifiable {
    enum Kind: Hashable { case agent, command }
    var id: String
    var kind: Kind
    var title: String
    var since: Date
    /// What a subagent is on (from its own transcript); commands don't say.
    var activity: ClaudeActivity? = nil
}

enum Claude {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Claude", isDirectory: true)
    static let sessionsDir = root.appendingPathComponent("claude-code-sessions", isDirectory: true)
    static let localStorageDir = root.appendingPathComponent("Local Storage/leveldb", isDirectory: true)
    /// A turn older than this with no summary is a session that died mid-turn, not one still working.
    static let runningTimeout: TimeInterval = 2 * 3600

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            || FileManager.default.fileExists(atPath: sessionsDir.path)
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// Opens the conversation in the app (its own link format, the one it hands out for sessions).
    static func open(_ id: String) {
        guard let url = URL(string: "claude://claude.ai/epitaxy/\(id)") else { return }
        Link.open(url)
    }

    // MARK: Sessions

    private struct Raw: Decodable {
        var sessionId: String?
        var cliSessionId: String?
        var title: String?
        var cwd: String?
        var originCwd: String?
        var gitAnchorsFolderRealpath: String?
        var isArchived: Bool?
        var completedTurns: Int?
        var createdAt: Double?
        var lastActivityAt: Double?
        var lastFocusedAt: Double?
        var latestUserFrameAt: Double?
        var postTurnSummary: Summary?
        var postTurnSummaryFor: String?
        var lastAssistantUuid: String?
        var sshConfig: SSHConfig?

        struct SSHConfig: Decodable {
            var sshHost: String?
        }

        struct Summary: Decodable {
            var status_category: String?
            var status_detail: String?
        }
    }

    static func decodeSession(_ data: Data, appRunning: Bool = true, now: Date = Date()) -> ClaudeSession? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let id = raw.sessionId, id.hasPrefix("local_") else {
            return nil
        }
        func date(_ ms: Double?) -> Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }
        let path = raw.gitAnchorsFolderRealpath ?? raw.originCwd ?? raw.cwd
        let scratch = path.map { $0.contains("/Claude/scratch-workspaces/") } ?? true
        let lastActivity = date(raw.lastActivityAt) ?? date(raw.createdAt) ?? .distantPast
        // The summary is written once a turn is over and names the message it covers; while a turn runs it is
        // missing or still points at an older message.
        let current = raw.postTurnSummaryFor != nil && raw.postTurnSummaryFor == raw.lastAssistantUuid
        let summary = current ? raw.postTurnSummary.map {
            ClaudeSession.Summary(blocked: $0.status_category == "blocked",
                                  detail: ($0.status_detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        } : nil
        let lastMessage = date(raw.latestUserFrameAt)
        let running = appRunning && !current && raw.isArchived != true
            && lastMessage.map { now.timeIntervalSince($0) < runningTimeout } ?? false
        return ClaudeSession(
            id: id, title: raw.title?.isEmpty == false ? raw.title! : "Untitled session",
            folder: scratch ? nil : path, isArchived: raw.isArchived ?? false,
            completedTurns: raw.completedTurns ?? 0, lastActivity: lastActivity,
            lastFocused: date(raw.lastFocusedAt), lastUserMessage: lastMessage,
            summary: summary, running: running, cliID: raw.cliSessionId, sshHost: raw.sshConfig?.sshHost)
    }

    enum ReadError: Error {
        case missing, unreadable
    }

    /// Re-decodes only the files whose modification date changed since the last call.
    final class SessionReader {
        private var cache: [URL: (Date, ClaudeSession?)] = [:]

        func read() -> Result<[ClaudeSession], ReadError> {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: Claude.sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                return .failure(.missing)
            }
            let appRunning = Claude.isRunning
            var sessions: [ClaudeSession] = []
            var seen = Set<URL>()
            var files = 0
            for case let url as URL in enumerator where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
                files += 1
                seen.insert(url)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                var session: ClaudeSession?
                if let cached = cache[url], cached.0 == modified {
                    session = cached.1
                } else {
                    session = (try? Data(contentsOf: url)).flatMap { Claude.decodeSession($0) }
                    cache[url] = (modified, session)
                }
                // Running depends on the clock and on the app being open, so it's recomputed every time.
                if var s = session {
                    if s.running, !appRunning || Date().timeIntervalSince(s.lastUserMessage ?? .distantPast) > Claude.runningTimeout {
                        s.running = false
                    }
                    sessions.append(s)
                }
            }
            cache = cache.filter { seen.contains($0.key) }
            if files > 0 && sessions.isEmpty { return .failure(.unreadable) }
            return .success(sessions)
        }
    }

    // MARK: Activity (what a working agent is doing, from its transcript)

    static let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    /// Finds transcripts and reads only their tail, again only when they changed.
    final class ActivityReader {
        private var paths: [String: URL] = [:]
        private var cache: [URL: Cached] = [:]
        /// Read from the refresh queue and (for icons) from the main thread.
        private let lock = NSLock()
        /// Where Fjord's hook leaves a note when an ordinary tool's permission prompt opens (`RouterPaths.permissions`); nil
        /// reads none.
        private var permissions: URL?
        /// Claude Code's registry of live processes (`~/.claude/sessions`): which process runs which session.
        private var registry: URL?
        private var processes: Claude.ProcessLister = .system
        /// The Bash prompts still pending, by session, for the check below.
        private var watching: [String: [Claude.PermissionNote]] = [:]
        private var watches: [String: Claude.CommandWatch] = [:]

        private struct Cached {
            var modified: Date
            var activity: ClaudeActivity?
            var calls: Claude.TailCalls
            /// The permission notes this was merged with (their file names).
            var notes: [String]
            var merged: ClaudeActivity?
        }

        init(permissions: URL? = nil) { self.permissions = permissions }

        func setPermissions(_ url: URL?, registry: URL? = nil, processes: Claude.ProcessLister = .system) {
            lock.lock()
            permissions = url
            self.registry = registry
            self.processes = processes
            lock.unlock()
        }

        /// The process running a session, by Claude Code's registry.
        private func pid(of cliID: String) -> Int32? {
            guard let registry else { return nil }
            return ClaudePeers.registry(dir: registry)
                .compactMap { pid, entries in entries.first { $0.sessionID == cliID }.map { (pid, $0.startedAt ?? 0) } }
                .max { $0.1 < $1.1 }?.0
        }

        /// Removes the notes of sessions with no live process: a session that ended or was deleted answers no prompt.
        func pruneNotes() {
            lock.lock()
            let permissions = permissions, registry = registry
            lock.unlock()
            guard let permissions, let registry,
                  let files = try? FileManager.default.contentsOfDirectory(at: permissions, includingPropertiesForKeys: nil),
                  files.contains(where: { $0.pathExtension == "json" }),
                  (try? FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) != nil else { return }
            let live = Set(ClaudePeers.registry(dir: registry).values.flatMap { $0.map { FormHook.safe($0.sessionID) } })
            for file in files where file.pathExtension == "json" {
                let name = file.lastPathComponent
                // `<session>-<ms>-<pid>.json`: the session id has no more than the dashes of a UUID, so cut the last two.
                let parts = name.dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count > 2 else { continue }
                if !live.contains(parts.dropLast(2).joined(separator: "-")) { try? FileManager.default.removeItem(at: file) }
            }
        }

        /// Watches a session's Claude Code process while a Bash prompt is pending for it (`Claude.CommandWatch`), and stops
        /// when none is. Claude Code sends no event when a prompt is approved; the approved command starting is the sign,
        /// and the system reports it as the process forking and the child executing. Deleting the note wakes the folder
        /// watcher, which refreshes the activity. Holds `lock`.
        private func watch(_ cliID: String, _ notes: [Claude.PermissionNote]) {
            let bash = notes.filter { $0.tool == "Bash" }
            watching[cliID] = bash.isEmpty ? nil : bash
            if bash.isEmpty {
                watches.removeValue(forKey: cliID)?.cancel()
            } else if watches[cliID] == nil, let pid = pid(of: cliID) {
                watches[cliID] = Claude.CommandWatch(pid: pid) { [weak self] in self?.checkWatched(cliID) }
            }
        }

        private func checkWatched(_ cliID: String) {
            lock.lock()
            let notes = watching[cliID] ?? []
            let processes = processes
            lock.unlock()
            guard !notes.isEmpty else { return }
            let left = Claude.clearingStartedCommands(notes, pid: pid(of: cliID), processes: processes)
            lock.lock()
            if left.count != notes.count { watch(cliID, left) }
            lock.unlock()
        }

        func activity(for cliID: String) -> ClaudeActivity? {
            guard let url = transcript(cliID) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            var entry: Cached
            if let cached = cache[url], cached.modified == modified {
                entry = cached
            } else {
                let tail = Claude.tail(of: url)
                let activity = Claude.activity(tail: tail)
                entry = Cached(modified: modified, activity: activity, calls: Claude.tailCalls(tail: tail), notes: [], merged: activity)
                // Force the notes to be looked at again against this tail.
                entry.notes = ["\u{0}"]
            }
            var notes = permissions.map { Claude.PermissionNote.read(in: $0, session: cliID) } ?? []
            if notes.contains(where: { $0.tool == "Bash" }) {
                notes = Claude.clearingStartedCommands(notes, pid: pid(of: cliID), processes: processes)
            }
            watch(cliID, notes)
            let names = notes.map(\.file.lastPathComponent)
            if entry.notes != names {
                entry.notes = names
                entry.merged = Claude.mergingPermission(entry.activity, calls: entry.calls, notes: notes)
            }
            cache[url] = entry
            return entry.merged
        }

        func transcript(_ cliID: String) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            if let known = paths[cliID], FileManager.default.fileExists(atPath: known.path) { return known }
            let dirs = (try? FileManager.default.contentsOfDirectory(at: Claude.transcriptsDir, includingPropertiesForKeys: nil)) ?? []
            let found = dirs.lazy.map { $0.appendingPathComponent("\(cliID).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
            paths[cliID] = found
            return found
        }
    }

    static func tail(of url: URL, bytes: Int = 96 * 1024) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? handle.readToEnd()) ?? Data()
    }

    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// The last step in a transcript: the tool being run, or thinking between steps; with the session's task list and the
    /// agent's latest narration, found in the same tail (only the lines that can hold them are parsed).
    static func activity(tail: Data) -> ClaudeActivity? {
        let lines = tail.split(separator: UInt8(ascii: "\n")).reversed()
        var result: ClaudeActivity?
        var narration: String?
        var narrating = true
        var todo: ClaudeActivity.Todo?
        let todoMark = Data("TodoWrite".utf8)
        for line in lines {
            let raw = Data(line)
            let hasTodo = todo == nil && raw.range(of: todoMark) != nil
            guard result == nil || narrating || hasTodo else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let type = obj["type"] as? String, type == "assistant" || type == "user" else { continue }
            let content = (obj["message"] as? [String: Any])?["content"]
            let parts = content as? [[String: Any]] ?? []
            if result == nil {
                let since = (obj["timestamp"] as? String).flatMap { try? Date($0, strategy: Self.iso) } ?? Date()
                if type == "assistant" {
                    if let tool = parts.last(where: { $0["type"] as? String == "tool_use" }) {
                        let name = tool["name"] as? String ?? ""
                        let waits = ["AskUserQuestion", "ExitPlanMode"].contains(name)
                        result = ClaudeActivity(text: describe(tool: name, input: tool["input"] as? [String: Any] ?? [:]),
                                                since: since, waitsForYou: waits, tool: waits ? name : nil,
                                                toolUseID: waits ? tool["id"] as? String : nil)
                    } else {
                        result = ClaudeActivity(text: parts.contains { $0["type"] as? String == "text" } ? "Writing" : "Thinking", since: since)
                    }
                } else {
                    // A tool's result, or your message: the model is working out the next step.
                    result = ClaudeActivity(text: "Thinking", since: since)
                }
            }
            if narrating {
                if type == "assistant", let text = parts.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { narration = String(trimmed.prefix(600)); narrating = false }
                } else if type == "user", content is String || parts.contains(where: { $0["type"] as? String == "text" }) {
                    // Your message begins this turn: nothing before it is its narration.
                    narrating = false
                }
            }
            if todo == nil, type == "assistant",
               let tool = parts.last(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "TodoWrite" }),
               let items = (tool["input"] as? [String: Any])?["todos"] as? [[String: Any]] {
                let done = items.filter { $0["status"] as? String == "completed" }.count
                let active = items.first { $0["status"] as? String == "in_progress" }
                    .flatMap { ($0["activeForm"] as? String) ?? ($0["content"] as? String) }
                todo = ClaudeActivity.Todo(done: done, total: items.count, active: active)
            }
            if !narrating, todo != nil { break }
        }
        result?.narration = narration
        result?.todo = todo
        return result
    }

    // MARK: Permission prompts of ordinary tools

    /// A tool call in a transcript's tail that has no result in it yet.
    struct OpenCall: Hashable {
        var id: String
        var name: String
        var input: NSDictionary
        var since: Date
    }

    /// Every call in a transcript's tail, and the ids it has a result for.
    struct TailCalls: Hashable {
        var all: [OpenCall] = []
        var answered: Set<String> = []
    }

    /// Reads a tail forward: every `tool_use` and `tool_result` in it.
    static func tailCalls(tail: Data) -> TailCalls {
        var calls: [OpenCall] = []
        var answered = Set<String>()
        let use = Data("tool_use".utf8), result = Data("tool_result".utf8)
        for line in tail.split(separator: UInt8(ascii: "\n")) {
            let raw = Data(line)
            guard raw.range(of: use) != nil || raw.range(of: result) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let type = obj["type"] as? String, type == "assistant" || type == "user",
                  let parts = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let since = (obj["timestamp"] as? String).flatMap { try? Date($0, strategy: Self.iso) } ?? Date()
            for part in parts {
                switch (type, part["type"] as? String) {
                case ("assistant", "tool_use"?):
                    guard let id = part["id"] as? String, let name = part["name"] as? String else { continue }
                    calls.append(OpenCall(id: id, name: name, input: (part["input"] as? NSDictionary) ?? [:], since: since))
                case ("user", "tool_result"?):
                    if let id = part["tool_use_id"] as? String { answered.insert(id) }
                default: break
                }
            }
        }
        return TailCalls(all: calls, answered: answered)
    }

    /// What Fjord's hook leaves when a permission prompt opens for an ordinary tool: which call it is for. The hook only
    /// observes (it prints no decision); the prompt is over when that call's result reaches the transcript.
    struct PermissionNote: Hashable {
        var file: URL
        var tool: String
        var input: NSDictionary
        /// The call's id when the hook was told it.
        var toolUseID: String?
        var createdMs: Int64

        /// Whether this note is for `call`: the id if the note has one, else the tool and the exact input.
        func matches(_ call: OpenCall) -> Bool {
            if let toolUseID { return toolUseID == call.id }
            return call.name == tool && call.input.isEqual(input)
        }

        static func prefix(for session: String) -> String { FormHook.safe(session) + "-" }

        /// The notes of a session, newest first.
        static func read(in dir: URL, session: String) -> [PermissionNote] {
            let prefix = Self.prefix(for: session)
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(prefix) }
            let notes = files.compactMap { url -> PermissionNote? in
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tool = obj["tool_name"] as? String, let input = obj["tool_input"] as? NSDictionary else { return nil }
                return PermissionNote(file: url, tool: tool, input: input, toolUseID: obj["tool_use_id"] as? String,
                                      createdMs: (obj["created_at"] as? NSNumber)?.int64Value ?? 0)
            }
            return notes.sorted { ($0.createdMs, $0.file.lastPathComponent) > ($1.createdMs, $1.file.lastPathComponent) }
        }
    }

    /// The activity as it is with the permission prompts there are: a note whose call has its result is over and is taken
    /// away; one whose call is still open makes the session wait on you, as a question does. A session already waiting on
    /// a question or a plan is left as it is.
    static func mergingPermission(_ base: ClaudeActivity?, calls: TailCalls, notes: [PermissionNote]) -> ClaudeActivity? {
        var pending: (PermissionNote, OpenCall)?
        for note in notes {
            // The note's call is the latest of those it matches: with its result, the prompt is over.
            guard let call = calls.all.last(where: note.matches) else { continue }
            if calls.answered.contains(call.id) {
                try? FileManager.default.removeItem(at: note.file)
            } else if pending == nil {
                pending = (note, call)
            }
        }
        guard base?.waitsForYou != true, let (note, call) = pending else { return base }
        var merged = ClaudeActivity(text: permissionText(tool: note.tool, input: note.input as? [String: Any] ?? [:]),
                                    since: call.since, waitsForYou: true, tool: call.name, toolUseID: call.id)
        merged.narration = base?.narration
        merged.todo = base?.todo
        return merged
    }

    /// "Asks your OK to …": what the prompt is for, in a few plain words.
    static let permissionPrefix = "Asks your OK to "

    static func permissionText(tool name: String, input: [String: Any]) -> String {
        func code(_ s: String, _ n: Int = 80) -> String {
            let line = s.split(separator: "\n").first.map(String.init) ?? s
            return "`" + (line.count > n ? String(line.prefix(n - 1)) + "…" : line) + "`"
        }
        func file(_ key: String = "file_path") -> String {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a file"
        }
        let what: String
        switch name {
        case "Bash": what = "run " + code(input["command"] as? String ?? "a command")
        case "Edit", "MultiEdit": what = "edit " + file()
        case "NotebookEdit": what = "edit " + file("notebook_path")
        case "Write": what = "write " + file()
        case "Read": what = "read " + file()
        case "WebFetch": what = "read " + ((input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a web page")
        case "WebSearch": what = "search the web"
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.components(separatedBy: "__")
                what = parts.count > 2 ? "use \(parts[2]) from \(parts[1])" : "use \(name)"
            } else {
                what = "use " + (name.isEmpty ? "a tool" : name)
            }
        }
        return permissionPrefix + what
    }

    /// Whether the last assistant entry ends the turn. Presence can stay live while Claude waits for another message,
    /// so process liveness alone cannot determine the Desktop session's running state.
    static func transcriptEndedTurn(tail: Data) -> Bool {
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "user" { return false }
            guard type == "assistant" else { continue }
            guard let message = object["message"] as? [String: Any],
                  let reason = message["stop_reason"] as? String else { return false }
            return reason == "end_turn" || reason == "stop_sequence"
        }
        return false
    }

    static func describe(tool name: String, input: [String: Any]) -> String {
        func file(_ key: String = "file_path") -> String {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a file"
        }
        func short(_ s: String, _ n: Int = 48) -> String {
            let line = s.split(separator: "\n").first.map(String.init) ?? s
            return line.count > n ? String(line.prefix(n - 1)) + "…" : line
        }
        switch name {
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty { return short(d) }
            return "Running " + short(input["command"] as? String ?? "a command", 36)
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing " + file(name == "NotebookEdit" ? "notebook_path" : "file_path")
        case "Write": return "Writing " + file()
        case "Read": return "Reading " + file()
        case "Grep", "Glob": return "Searching" + ((input["pattern"] as? String).map { " for " + short($0, 28) } ?? "")
        case "Agent", "Task": return "Delegating" + ((input["description"] as? String).map { ": " + short($0, 36) } ?? "")
        case "WebSearch": return "Searching the web"
        case "WebFetch": return "Reading " + ((input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a web page")
        case "TodoWrite": return "Planning"
        // Stopped on you: the row's second line is the question itself, or the plan's title, when the input has it.
        case "AskUserQuestion":
            let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            return first.flatMap { $0.isEmpty ? nil : short($0, 120) } ?? "Asking you a question"
        case "ExitPlanMode":
            // A plan is Markdown: its first line is usually a heading.
            let title = (input["plan"] as? String)?.split(separator: "\n").lazy
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*").union(.whitespaces)) }
                .first { !$0.isEmpty }
            return title.map { "Approve the plan: " + short($0, 96) } ?? "Waiting for you to approve a plan"
        case "Skill": return "Using " + ((input["skill"] as? String) ?? "a skill")
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                let server = parts.count > 1 ? String(parts[1]) : "a tool"
                return "Using " + (server.count > 20 ? "a connector" : server)
            }
            return name.isEmpty ? "Working" : "Using " + name
        }
    }

    // MARK: Background (subagents and shell commands still running after a turn)

    /// Claude Code lists each session's background tasks in `<root>/<project>/<cliID>/tasks/<id>.output`: a symlink to
    /// the transcript for a subagent, a file the command writes to for a shell command.
    static let tasksRoot = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
    /// A subagent whose transcript hasn't moved in this long died with its session (or the app).
    static let agentTimeout: TimeInterval = 30 * 60

    /// Every task folder, by the session it belongs to.
    static func taskFolders() -> [String: URL] { readTaskFolders() ?? [:] }

    /// Every task folder, by session; nil when a folder couldn't be read (what's in it isn't known: not the same as none).
    /// No root at all is none.
    static func readTaskFolders(root: URL = tasksRoot) -> [String: URL]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [:] }
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        var folders: [String: URL] = [:]
        for project in projects {
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: project.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            guard let sessions = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil) else { return nil }
            for session in sessions {
                let tasks = session.appendingPathComponent("tasks", isDirectory: true)
                // No folder is none; one that can't be looked into (no permission) isn't known.
                var info = stat()
                if stat(tasks.path, &info) == 0 {
                    folders[session.lastPathComponent] = tasks
                } else if errno != ENOENT && errno != ENOTDIR {
                    return nil
                }
            }
        }
        return folders
    }

    /// `readTaskFolders`, read again only where a folder changed (`FolderStamp`): the root (which holds some thousand files
    /// of Claude Code's besides the project folders) and each project are listed again only once an entry came or went, so
    /// a read while sessions work (every half second) is a stat of each folder rather than a walk of them all. One reader
    /// per queue: it keeps what it listed.
    final class TaskFolderReader {
        private var rootListing: (stamp: FolderStamp, projects: [URL])?
        private var projectListings: [URL: (stamp: FolderStamp, sessions: [URL], names: Set<String>)] = [:]

        /// `only`: the sessions (Claude Code ids) asked about, whose tasks folders alone are looked for; nil: every one.
        func read(root: URL = tasksRoot, only: Set<String>? = nil) -> [String: URL]? {
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else {
                rootListing = nil
                projectListings = [:]
                return [:]
            }
            let projects: [URL]
            let rootStamp = FolderStamp(root.path)
            if let rootStamp, let kept = rootListing, kept.stamp == rootStamp {
                projects = kept.projects
            } else {
                guard let listed = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                    rootListing = nil
                    return nil
                }
                projects = listed.filter { project in
                    var isFolder: ObjCBool = false
                    return fm.fileExists(atPath: project.path, isDirectory: &isFolder) && isFolder.boolValue
                }
                rootListing = rootStamp.map { ($0, projects) }
            }
            var folders: [String: URL] = [:]
            var listings: [URL: (stamp: FolderStamp, sessions: [URL], names: Set<String>)] = [:]
            for project in projects {
                // Gone (or no longer a folder) since the root was listed: as if it hadn't been there.
                guard let stamp = FolderStamp(project.path) else { continue }
                let listing: (stamp: FolderStamp, sessions: [URL], names: Set<String>)
                if let kept = projectListings[project], kept.stamp == stamp {
                    listing = kept
                } else {
                    guard let listed = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil) else {
                        projectListings = listings
                        return nil
                    }
                    listing = (stamp, listed, Set(listed.map(\.lastPathComponent)))
                }
                listings[project] = listing
                // Only the sessions asked about are looked into: a stat each, not one for every session ever run.
                let sessions = only.map { asked in
                    asked.filter(listing.names.contains).map { project.appendingPathComponent($0, isDirectory: true) }
                } ?? listing.sessions
                for session in sessions {
                    let tasks = session.appendingPathComponent("tasks", isDirectory: true)
                    // No folder is none; one that can't be looked into (no permission) isn't known.
                    var info = stat()
                    if stat(tasks.path, &info) == 0 {
                        folders[session.lastPathComponent] = tasks
                    } else if errno != ENOENT && errno != ENOTDIR {
                        projectListings = listings
                        return nil
                    }
                }
            }
            projectListings = listings
            return folders
        }
    }

    /// Files under `root` (`tasksRoot`) that a process of yours has as its output: the shell commands still running. A
    /// command's output stays open exactly as long as it runs, so this is the system's answer, with no timeout to guess.
    static func openTaskOutputs(under root: URL = tasksRoot) -> Set<String> {
        let prefix = root.path + "/"
        let uid = getuid()
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var open = Set<String>()
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var bsd = proc_bsdshortinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, bsdSize) == bsdSize, bsd.pbsi_uid == uid else { continue }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, 1, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if path.hasPrefix(prefix) { open.insert(path) }
        }
        return open
    }

    /// The tasks a session still has running. Finished ones are remembered, so a session's list is only read again when
    /// its folder or transcript changes.
    final class TaskReader {
        private var finished = Set<String>()
        private var titles: [String: String] = [:]
        private var agentActivity: [URL: (Date, ClaudeActivity?)] = [:]
        /// Task ids announced as ended in each session transcript. Transcripts only grow, so only new bytes are searched.
        private var scans: [URL: (offset: Int, ended: Set<String>, inode: UInt64)] = [:]

        /// Reads only what was appended since the last scan; a replaced or shortened file is scanned from the start.
        private func scanTranscript(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return }
            let inode = UInt64(info.st_ino), size = Int(info.st_size)
            var scan = scans[url] ?? (0, [], inode)
            if scan.inode != inode || size < scan.offset { scan = (0, [], inode) }
            guard size > scan.offset, let handle = try? FileHandle(forReadingFrom: url) else { scans[url] = scan; return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(scan.offset))
            if let chunk = try? handle.readToEnd() {
                scan.offset = Claude.scanEnds(chunk, base: scan.offset, into: &scan.ended)
            }
            scans[url] = scan
        }

        /// A task's output in a folder, as listed: a link to a subagent's transcript, or a command's file.
        private struct Output {
            let url: URL
            let id: String
            let isLink: Bool
            let created: Date?
        }
        /// Each folder's outputs as last listed, kept while the folder is unchanged (`FolderStamp`): a read every half second
        /// while sessions work lists again only the folders a task came to or left, not every one, three times.
        private var listings: [URL: (stamp: FolderStamp, outputs: [Output])] = [:]

        /// The outputs in `folder`; nil when it can't be read.
        private func outputs(in folder: URL) -> [Output]? {
            let stamp = FolderStamp(folder.path)
            if let stamp, let kept = listings[folder], kept.stamp == stamp { return kept.outputs }
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .creationDateKey]
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else {
                listings[folder] = nil
                return nil
            }
            let outputs = entries.filter { $0.pathExtension == "output" }.map { entry in
                let values = try? entry.resourceValues(forKeys: Set(keys))
                return Output(url: entry, id: entry.deletingPathExtension().lastPathComponent,
                              isLink: values?.isSymbolicLink == true, created: values?.creationDate)
            }
            listings[folder] = stamp.map { ($0, outputs) }
            return outputs
        }

        /// Forgets the listings of folders other than `folders` (sessions archived, folders gone).
        func keepListings(of folders: Set<URL>) {
            if listings.keys.contains(where: { !folders.contains($0) }) { listings = listings.filter { folders.contains($0.key) } }
        }

        /// Whether some command in the folder is still unaccounted for, i.e. whether the process list is worth reading.
        func needsOpenOutputs(in folder: URL) -> Bool {
            (outputs(in: folder) ?? []).contains { !$0.isLink && !finished.contains($0.id) }
        }

        func tasks(in folder: URL, transcript: URL?, openOutputs: Set<String>, now: Date = Date()) -> [ClaudeTask] {
            read(folder, transcript: transcript, openOutputs: openOutputs, now: now).tasks
        }

        /// The tasks, and whether that is the whole answer: a command listed only a moment ago and not open yet may be
        /// about to start, so its session's background work isn't known yet.
        func read(_ folder: URL, transcript: URL?, openOutputs: Set<String>, now: Date = Date()) -> (tasks: [ClaudeTask], certain: Bool) {
            let fm = FileManager.default
            // A folder that can't be read says nothing: not "no tasks".
            guard let entries = outputs(in: folder) else { return ([], false) }
            var certain = true
            var tasks: [ClaudeTask] = []
            // The transcript is read in full at most once per call, and only for a command's title.
            var whole: Data??
            func transcriptData() -> Data? {
                if whole == nil { whole = .some(transcript.flatMap { try? Data(contentsOf: $0) }) }
                return whole!
            }
            var scanned = false
            func ended(_ id: String) -> Bool {
                guard let transcript else { return false }
                if !scanned {
                    scanned = true
                    scanTranscript(transcript)
                }
                return scans[transcript]?.ended.contains(id) == true
            }
            for output in entries {
                let id = output.id, entry = output.url
                guard !finished.contains(id) else { continue }
                let since = output.created ?? now
                if output.isLink {
                    guard let target = try? fm.destinationOfSymbolicLink(atPath: entry.path) else { continue }
                    let agent = URL(fileURLWithPath: target)
                    let modified = (try? agent.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    // Its end is announced to the session that started it.
                    if now.timeIntervalSince(modified) > Claude.agentTimeout || ended(id) {
                        finished.insert(id)
                        continue
                    }
                    let title = titles[id] ?? Claude.agentTitle(meta: agent.deletingPathExtension().appendingPathExtension("meta.json"))
                    titles[id] = title
                    tasks.append(ClaudeTask(id: id, kind: .agent, title: title, since: since, activity: activity(agent, modified)))
                } else {
                    guard openOutputs.contains(entry.path) else {
                        // (A file only just listed may not be open yet.)
                        if now.timeIntervalSince(since) > 5 { finished.insert(id) } else { certain = false }
                        continue
                    }
                    let title = titles[id] ?? transcriptData().flatMap { Claude.commandTitle(id, in: $0) } ?? "Background command"
                    titles[id] = title
                    tasks.append(ClaudeTask(id: id, kind: .command, title: title, since: since))
                }
            }
            return (tasks.sorted { $0.since < $1.since }, certain)
        }

        /// When the newest command output in `folder` was made (subagents' links aside): a scan of open files older than
        /// that hasn't seen it.
        func newestCommand(in folder: URL) -> Date? {
            (outputs(in: folder) ?? []).compactMap { $0.isLink ? nil : $0.created }.max()
        }

        private func activity(_ url: URL, _ modified: Date) -> ClaudeActivity? {
            if let cached = agentActivity[url], cached.0 == modified { return cached.1 }
            let activity = Claude.activity(tail: Claude.tail(of: url))
            agentActivity[url] = (modified, activity)
            return activity
        }
    }

    /// Collects the ids of every `<task-id>…</task-id>` notice from `base` on, where `chunk` is the file's bytes from
    /// there. Returns where to resume: just short of the end (a tag may be cut), or at an unfinished notice.
    @discardableResult
    static func scanEnds(_ chunk: Data, base: Int, into ended: inout Set<String>) -> Int {
        let open = Data("<task-id>".utf8), close = Data("</task-id>".utf8)
        var resume = max(0, chunk.count - open.count + 1)
        var cursor = chunk.startIndex
        while let found = chunk.range(of: open, in: cursor..<chunk.endIndex) {
            let from = found.upperBound
            guard let end = chunk.range(of: close, in: from..<min(chunk.endIndex, from + 200)) else {
                if chunk.endIndex - found.lowerBound < 300 { resume = min(resume, found.lowerBound - chunk.startIndex) }
                cursor = from
                continue
            }
            ended.insert(String(decoding: chunk[from..<end.lowerBound], as: UTF8.self))
            cursor = end.upperBound
        }
        return base + resume
    }

    /// The session's transcript has the notice Claude Code sends when a task ends.
    static func announcesEnd(of id: String, in transcript: Data) -> Bool {
        transcript.range(of: Data("<task-id>\(id)</task-id>".utf8)) != nil
    }

    static func agentTitle(meta: URL) -> String {
        struct Meta: Decodable { var description: String? }
        let description = (try? Data(contentsOf: meta)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }?.description
        return description?.isEmpty == false ? description! : "Subagent"
    }

    /// What the session called the command: the description (or command) of the call that answered "…with ID: <id>".
    static func commandTitle(_ id: String, in transcript: Data) -> String? {
        func line(around range: Range<Data.Index>) -> [String: Any]? {
            let newline = UInt8(ascii: "\n")
            let start = transcript[..<range.lowerBound].lastIndex(of: newline).map { $0 + 1 } ?? transcript.startIndex
            let end = transcript[range.upperBound...].firstIndex(of: newline) ?? transcript.endIndex
            return try? JSONSerialization.jsonObject(with: transcript[start..<end]) as? [String: Any]
        }
        func content(_ obj: [String: Any]?) -> [[String: Any]] {
            (obj?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        }
        guard let launched = transcript.range(of: Data("with ID: \(id).".utf8)),
              let callID = content(line(around: launched)).lazy.compactMap({ $0["tool_use_id"] as? String }).first,
              let called = transcript.range(of: Data("\"id\":\"\(callID)\"".utf8)),
              let call = content(line(around: called)).first(where: { $0["id"] as? String == callID }),
              let input = call["input"] as? [String: Any] else { return nil }
        let text = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? input["command"] as? String
        return text.map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
    }

    // MARK: Unread (the sidebar's blue dots)

    private static let unreadKey = Array("epitaxy-unread-v1".utf8)

    /// Session ids with a blue dot in the app's sidebar. The app writes this to disk lazily (up to ~30 s late).
    static func unreadIDs() -> Set<String>? {
        guard let raw = LevelDB.latest(in: localStorageDir, keySuffix: unreadKey) else { return nil }
        return parseUnread(raw)
    }

    /// Chromium Local Storage values start with an encoding byte: 1 = Latin-1, 0 = UTF-16LE.
    static func parseUnread(_ raw: [UInt8]) -> Set<String>? {
        guard let first = raw.first else { return nil }
        let body = Data(raw.dropFirst())
        let text = first == 0 ? String(data: body, encoding: .utf16LittleEndian) : String(data: body, encoding: .isoLatin1)
        struct Stored: Decodable {
            struct State: Decodable { var unreadIds: [String]? }
            var state: State?
        }
        guard let data = text?.data(using: .utf8), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let ids = stored.state?.unreadIds else { return nil }
        return Set(ids)
    }
}

/// FSEvents on a few folders (recursive), coalesced. Events arrive on a utility queue, where `relevant` filters
/// them; only a relevant batch hops to the main queue to call `handler`.
final class FolderWatcher {
    /// What the stream's callback holds (retained by the stream itself, so a callback in flight never outlives it).
    private final class Callbacks {
        let relevant: (([String]) -> Bool)?
        let handler: () -> Void
        init(relevant: (([String]) -> Bool)?, handler: @escaping () -> Void) {
            self.relevant = relevant
            self.handler = handler
        }
    }

    private static let queue = DispatchQueue(label: "fjord.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(_ urls: [URL], latency: TimeInterval = 0.2, handler: @escaping () -> Void) {
        start(urls, latency: latency, Callbacks(relevant: nil, handler: handler))
    }

    /// Per-file events: `relevant` gets the paths that changed (off the main thread), so the handler only runs for
    /// the ones that matter.
    init(_ urls: [URL], latency: TimeInterval = 0.2, relevant: @escaping ([String]) -> Bool, handler: @escaping () -> Void) {
        start(urls, latency: latency, Callbacks(relevant: relevant, handler: handler))
    }

    private func start(_ urls: [URL], latency: TimeInterval, _ callbacks: Callbacks) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(callbacks).toOpaque(),
                                           retain: nil, release: { info in
            if let info { Unmanaged<Callbacks>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let callbacks = Unmanaged<Callbacks>.fromOpaque(info).takeUnretainedValue()
            if let relevant = callbacks.relevant,
               !relevant(unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []) { return }
            DispatchQueue.main.async { callbacks.handler() }
        }
        var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        if callbacks.relevant != nil {
            flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, urls.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            Unmanaged.passUnretained(callbacks).release()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// What a folder's own inode says of it: its identity and when it last changed (an entry added, removed or renamed in it,
/// or its mode, gives another). What was listed in a folder holds while its stamp is the same. Nil for what isn't a
/// folder, or can't be looked at.
struct FolderStamp: Equatable {
    let device: Int64, inode: UInt64
    let changed: Int64, changedNanos: Int, modified: Int64, modifiedNanos: Int

    init?(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        changed = Int64(info.st_ctimespec.tv_sec)
        changedNanos = info.st_ctimespec.tv_nsec
        modified = Int64(info.st_mtimespec.tv_sec)
        modifiedNanos = info.st_mtimespec.tv_nsec
    }
}

// MARK: - Background reading

/// Everything one read of the app produced. `sessions` is nil for an activity-only refresh.
struct ClaudeSnapshot {
    var link: ClaudeLink?
    var sessions: [ClaudeSession]?
    var appUnread: Set<String>?
    var frontmost = false
    var activity: [String: ClaudeActivity]?
    var tasks: [String: [ClaudeTask]]?
    /// The sessions `tasks` speaks for: those not running in this read, whose background work was looked at (none found is
    /// an answer too).
    var taskInventory: Set<String>?
    /// What the store looked like when the read was asked for (see `Store.applyClaude`).
    var stamp = ClaudeStamp()
}

/// `generation` changes when the extension is switched; `revision` when you change something about an agent.
struct ClaudeStamp: Equatable {
    var generation = 0
    var revision = 0
}

/// Reads the app's files on its own serial queue (the readers keep caches and aren't thread-safe), so none of it
/// touches the main thread. Requests made while a read is running are folded into one more read afterwards.
final class ClaudeFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fjord.claude", qos: .utility)
    private let sessionReader = Claude.SessionReader()
    private let taskReader = Claude.TaskReader()
    private let taskFolderReader = Claude.TaskFolderReader()
    let activityReader: Claude.ActivityReader
    private let lock = NSLock()
    private var scheduled = false
    private var wantFull = false
    private var wantActivity = false
    private var wantUnread = false
    private var stamp = ClaudeStamp()
    private var deliver: (@MainActor (ClaudeSnapshot) -> Void)?
    private var relevant = Set<String>()
    // Only touched on `queue`.
    private var live: [ClaudeSession]?
    private var allSessions: [ClaudeSession]?

    init(activityReader: Claude.ActivityReader) { self.activityReader = activityReader }

    // MARK: The plugin's word for it (presence files)

    /// Where the plugin's presence files are read from (the Router's files); nil reads none, and sessions keep the guess.
    private var presencePaths: RouterPaths?
    private var presenceWatcher: FolderWatcher?
    private var permissionWatcher: FolderWatcher?
    /// The live presence files as of the last read, by the CLI session id.
    private var presenceRead: [String: ClaudePlugin.Presence] = [:]

    /// Sets where presence is read from, on the next read, and calls `changed` (on the main thread) when what a presence file
    /// says changes in a way that matters (see `PresenceSignature`): a plugin rewrites its own as a turn starts and
    /// completes, so the running state follows the turn. Its 10 s heartbeat only renews the lease, which is noted here and
    /// triggers nothing; and when a lease runs out with no renewal, `changed` is called then.
    func readPresence(from paths: RouterPaths?, changed: @escaping @MainActor () -> Void) {
        lock.lock()
        let same = presencePaths == paths
        presencePaths = paths
        presenceChanged = changed
        lock.unlock()
        guard !same else { return }
        presenceWatcher = paths.map { paths in
            FolderWatcher([paths.pluginSessions], latency: 0.5) { [weak self] in
                self?.presenceQueue.async { self?.scanPresence() }
            }
        }
        // A permission prompt opening is noted by the hook in this folder: the activity is read again then.
        activityReader.setPermissions(paths?.permissions, registry: paths?.claudeDir.appendingPathComponent("sessions", isDirectory: true))
        permissionWatcher = paths.map { paths in
            try? FileManager.default.createDirectory(at: paths.permissions, withIntermediateDirectories: true,
                                                      attributes: [.posixPermissions: 0o700])
            return FolderWatcher([paths.permissions], latency: 0.2) {
                DispatchQueue.main.async { MainActor.assumeIsolated { changed() } }
            }
        }
    }

    /// What of a presence file makes a difference to Fjord besides its lease: whether it speaks for the turn at all, the turn
    /// running, what the plugin can do, and the process it is bound to.
    struct PresenceSignature: Equatable {
        var hasTurnField: Bool
        var turn: String?
        var capabilities: [String]
        var pid: Int32?
        var startedAt: Int64?

        init(_ file: ClaudePlugin.Presence) {
            hasTurnField = file.hasTurnField
            turn = file.turn?.id
            capabilities = file.capabilities ?? []
            pid = file.pid
            startedAt = file.startedAt
        }
    }

    private let presenceQueue = DispatchQueue(label: "fjord.claude.presence", qos: .utility)
    private var presenceChanged: (@MainActor () -> Void)?
    /// Which scheduled lease check is current (an older one does nothing).
    private var expiryToken = 0
    /// The clock the lease is judged by (tests move it).
    var presenceNow: @Sendable () -> Date = { ClaudePlugin.leaseNow }

    /// Reads the presence files alone, cheaply (no session history): notes the lease timestamps, and calls the change handler
    /// on the main thread only when a session appeared, vanished or changed in what `PresenceSignature` holds. Schedules the
    /// next look for the moment the earliest lease runs out unless renewed, so a plugin that stopped renewing (unloaded mid-turn)
    /// stops counting then. Runs on the presence queue.
    func scanPresence() {
        lock.lock()
        let paths = presencePaths, changed = presenceChanged
        lock.unlock()
        guard let paths else { return }
        let now = presenceNow()
        let found = ClaudePlugin.live(in: paths.pluginSessions,
                                      registry: ClaudePeers.registry(dir: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true)),
                                      keyID: ClaudePlugin.currentKeyID(beside: paths.pluginSessions), now: now)
        lock.lock()
        let before = presenceRead.mapValues(PresenceSignature.init)
        presenceRead = found
        expiryToken += 1
        let token = expiryToken
        lock.unlock()
        if before != found.mapValues(PresenceSignature.init), let changed {
            DispatchQueue.main.async { MainActor.assumeIsolated { changed() } }
        }
        let expiries = found.values.compactMap { $0.renewedAt }.map { Double($0) / 1000 + ClaudePlugin.lease }
        guard let first = expiries.min() else { return }
        // A hair after the lease ends (it holds while `|now - renewed| < lease`).
        let wait = max(0.05, first - now.timeIntervalSince1970 + 0.05)
        presenceQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.expiryToken == token
            self.lock.unlock()
            if current { self.scanPresence() }
        }
    }

    /// The presence files the last read found alive (key held now, process registered): what each plugin says it can do and
    /// whether it runs a turn.
    var presence: [String: ClaudePlugin.Presence] {
        lock.lock()
        defer { lock.unlock() }
        return presenceRead
    }

    /// Replaces what the last read found (tests).
    func seedPresence(_ presence: [String: ClaudePlugin.Presence]) {
        lock.lock()
        presenceRead = presence
        lock.unlock()
    }

    /// The sessions with `running` taken from the plugin's presence where it is fresh and says anything about the turn
    /// (`turn` present, even null): a session that runs one is running, and one that doesn't isn't, whatever the app's own
    /// files guess. Where there is no plugin, or its file is old, the guess stands. Runs on `queue`.
    private func applyingPresence(to sessions: [ClaudeSession]) -> [ClaudeSession] {
        lock.lock()
        let paths = presencePaths
        lock.unlock()
        guard let paths else {
            return sessions
        }
        let found = ClaudePlugin.live(in: paths.pluginSessions,
                                      registry: ClaudePeers.registry(dir: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true)),
                                      keyID: ClaudePlugin.currentKeyID(beside: paths.pluginSessions))
        lock.lock()
        presenceRead = found
        lock.unlock()
        // Its lease is watched from here on (see `scanPresence`): this read applies what it found, so nothing differs yet.
        presenceQueue.async { [self] in scanPresence() }
        return Self.applying(presence: found, to: sessions)
    }

    /// `applyingPresence(to:)` on a given set of presence files.
    static func applying(presence: [String: ClaudePlugin.Presence], to sessions: [ClaudeSession]) -> [ClaudeSession] {
        sessions.map { session in
            guard !session.isArchived, let cli = session.cliID, let file = presence[cli], file.hasTurnField else { return session }
            var session = session
            session.running = file.turn != nil
            return session
        }
    }

    /// Reads (everything, or just activity and tasks for the sessions seen last) and calls `apply` on the main thread.
    /// `unreadOnly` re-reads just the sidebar dots (the sessions are those of the last read).
    func request(full: Bool, unreadOnly: Bool = false, stamp: ClaudeStamp, apply: @escaping @MainActor (ClaudeSnapshot) -> Void) {
        lock.lock()
        self.stamp = stamp
        deliver = apply
        if full { wantFull = true } else if unreadOnly { wantUnread = true } else { wantActivity = true }
        let start = !scheduled
        scheduled = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                let full = wantFull || (wantUnread && wantActivity), any = wantFull || wantActivity || wantUnread
                let unread = wantUnread && !wantFull && !wantActivity
                let stamp = stamp, apply = deliver
                wantFull = false
                wantActivity = false
                wantUnread = false
                if !any { scheduled = false }
                lock.unlock()
                guard any else { return }
                var snapshot = unread ? readUnread() : read(full: full)
                snapshot.stamp = stamp
                guard let apply else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver(snapshot, apply, gate: self.gate) } }
            }
        }
    }

    /// Reads that came while the window's morph played (`MotionGate`), on the main thread: taken in once the motion is
    /// over, in the order read (what they make of the sessions, the dots and the Router's cards goes by each step), a slice
    /// of them per turn of the main run loop (`sliceBudget`), each slice inside `batched` (the store makes the work that
    /// follows from them once, at its end), so a backlog never holds the main thread just as the window wants its frames.
    /// Reads that come while some still wait queue behind them. None is folded into another: even an activity-only read
    /// can say a session stopped on a question, which the next may already have moved past.
    private var held: [(read: ClaudeSnapshot, apply: @MainActor (ClaudeSnapshot) -> Void)] = []
    /// A slice is asked for (after the motion) or under way.
    private var draining = false
    /// Runs a slice of held reads as one (the store's `batchingClaudeReads`); nil runs them as they are.
    @MainActor var batched: ((() -> Void) -> Void)?
    /// How long a slice of held reads may take before the rest waits for the next turn (at least one read a slice).
    @MainActor var sliceBudget: TimeInterval = 0.006
    /// The gate reads wait at (the store's `motionGate`).
    @MainActor var gate: MotionGate.Gate = MotionGate.shared

    @MainActor func deliver(_ snapshot: ClaudeSnapshot, _ apply: @escaping @MainActor (ClaudeSnapshot) -> Void,
                            gate: MotionGate.Gate = MotionGate.shared) {
        guard gate.holding || draining || !held.isEmpty else { return apply(snapshot) }
        held.append((snapshot, apply))
        guard !draining else { return }
        draining = true
        gate.whenStill { [self] in drain(gate) }
    }

    @MainActor private func drain(_ gate: MotionGate.Gate) {
        let start = DispatchTime.now().uptimeNanoseconds
        let budget = UInt64(sliceBudget * 1_000_000_000)
        let slice = { [self] in
            repeat {
                let (read, apply) = held.removeFirst()
                apply(read)
            } while !held.isEmpty && DispatchTime.now().uptimeNanoseconds - start < budget
        }
        if let batched { batched(slice) } else { slice() }
        guard !held.isEmpty else { draining = false; return }
        // The rest on the next turn, after any motion begun meanwhile.
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { gate.whenStill { [self] in drain(gate) } } }
    }

    /// Whether a changed transcript path belongs to a session that is working or has background tasks.
    func isRelevant(_ paths: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains { path in relevant.contains { path.contains($0) } }
    }

    /// Only the dots: the sessions are those of the last read, so a full read is needed first.
    private func readUnread() -> ClaudeSnapshot {
        guard let sessions = allSessions else { return read(full: true) }
        var snapshot = ClaudeSnapshot()
        snapshot.link = .ok
        snapshot.sessions = sessions
        snapshot.appUnread = Claude.unreadIDs()
        snapshot.frontmost = Claude.isFrontmost
        return snapshot
    }

    private func read(full: Bool) -> ClaudeSnapshot {
        var snapshot = ClaudeSnapshot()
        if full || live == nil {
            switch sessionReader.read() {
            case .failure(.missing):
                allSessions = nil
                snapshot.link = .missing
                return snapshot
            case .failure:
                allSessions = nil
                snapshot.link = .unreadable
                return snapshot
            case .success(let read):
                let sessions = applyingPresence(to: read)
                snapshot.link = .ok
                snapshot.sessions = sessions
                snapshot.appUnread = Claude.unreadIDs()
                snapshot.frontmost = Claude.isFrontmost
                allSessions = sessions
                live = sessions.filter { !$0.isArchived }
            }
        }
        let sessions = live ?? []
        var activity: [String: ClaudeActivity] = [:]
        var watched = Set<String>()
        activityReader.pruneNotes()
        for session in sessions where session.running {
            guard let cli = session.cliID else { continue }
            watched.insert(cli)
            if let found = activityReader.activity(for: cli) { activity[session.id] = found }
        }
        let folders = Claude.isRunning ? taskFolderReader.read(only: Set(sessions.compactMap(\.cliID))) : [:]
        let reader = activityReader
        let found = Self.readTasks(sessions: sessions, folders: folders, reader: taskReader, outputs: openOutputs,
                                   transcript: { reader.transcript($0) })
        for session in sessions where !session.running {
            if let cli = session.cliID, folders?[cli] != nil { watched.insert(cli) }
        }
        lock.lock()
        relevant = watched
        lock.unlock()
        snapshot.activity = activity
        snapshot.tasks = found.tasks
        snapshot.taskInventory = found.inventory
        return snapshot
    }

    private let openOutputs = OpenOutputs()

    /// The background work of the sessions whose turn is over, and the ones that is the whole answer for: a session
    /// counts only when every command in its folder is accounted for by a scan of open files made after its turn ended
    /// (a scan from before can't have seen what it started last), or none needed one.
    /// `folders` nil: they couldn't be read, and no session's work is known.
    static func readTasks(sessions: [ClaudeSession], folders: [String: URL]?, reader: Claude.TaskReader, outputs: OpenOutputs,
                          transcript: (String) -> URL?) -> (tasks: [String: [ClaudeTask]], inventory: Set<String>) {
        guard let folders else { return ([:], []) }
        let idle = sessions.filter { !$0.running }
        let withFolders = idle.compactMap { s in s.cliID.flatMap { folders[$0] }.map { (s, $0) } }
        reader.keepListings(of: Set(withFolders.map(\.1)))
        // The process list is only worth walking while some command's fate is still unknown; a cached walk is used only if
        // no command was started after it.
        let needed = withFolders.filter { reader.needsOpenOutputs(in: $0.1) }
        var scan: (at: Date, open: Set<String>)?
        if !needed.isEmpty {
            scan = outputs.get(newerThan: needed.compactMap { reader.newestCommand(in: $0.1) }.max())
        }
        var tasks: [String: [ClaudeTask]] = [:]
        var inventory = Set(idle.filter { s in s.cliID.map { folders[$0] == nil } ?? true }.map(\.id))
        let now = outputs.now()
        for (session, folder) in withFolders {
            let mustScan = needed.contains { $0.0.id == session.id }
            let read = reader.read(folder, transcript: session.cliID.flatMap(transcript), openOutputs: scan?.open ?? [], now: now)
            if !read.tasks.isEmpty { tasks[session.id] = read.tasks }
            let seenAfterTurn = !mustScan || (scan.map { $0.at > session.lastActivity } ?? false)
            if read.certain, seenAfterTurn { inventory.insert(session.id) }
        }
        return (tasks, inventory)
    }
}

/// Which command outputs a process has open, from one walk of the process list kept for two seconds, unless a command was
/// started after that walk (it can't have seen it). The walk and the clock are the tests' to give.
final class OpenOutputs: @unchecked Sendable {
    var scan: () -> Set<String> = { Claude.openTaskOutputs() }
    var now: () -> Date = Date.init
    private var cached: (at: Date, open: Set<String>)?

    func get(newerThan newest: Date?) -> (at: Date, open: Set<String>) {
        let now = now()
        if let cached, now.timeIntervalSince(cached.at) < 2, newest.map({ $0 < cached.at }) ?? true { return cached }
        let fresh = (at: now, open: scan())
        cached = fresh
        return fresh
    }
}
