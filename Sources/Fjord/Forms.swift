import Darwin
import Foundation

// MARK: - Paths

/// Where the Router keeps its files, and the Claude Code folder the hook goes in. Tests give their own (see `live`).
struct RouterPaths: Equatable, Sendable {
    /// `~/Library/Application Support/Fjord`.
    var support: URL
    /// `~/.claude`.
    var claudeDir: URL

    /// Forms the hook holds open, one file each, and the answers Fjord writes for them.
    var forms: URL { support.appendingPathComponent("forms", isDirectory: true) }
    /// A note for each permission prompt an ordinary tool opens (see `FormHook.observe`), read by `Claude.PermissionNote`.
    var permissions: URL { support.appendingPathComponent("permissions", isDirectory: true) }
    /// The Router process's working folder.
    var routerHome: URL { support.appendingPathComponent("router", isDirectory: true) }
    /// Fjord's Claude Code plugin, a folder marketplace Claude Code reads in place (see `ClaudePlugin`).
    var plugin: URL { support.appendingPathComponent("claude-plugin", isDirectory: true) }
    /// One file per session the plugin runs in, written by the plugin itself.
    var pluginSessions: URL { support.appendingPathComponent("plugin-sessions", isDirectory: true) }
    /// The key Fjord signs relayed messages with. Not in the plugin's folder: Claude Code copies that into its
    /// cache.
    var relayKey: URL { support.appendingPathComponent("relay.key") }

    /// The user's own folders; nil in a test run, which is stopped for reaching them (see `UnderTest`).
    static func live() -> RouterPaths? {
        guard !UnderTest.refuses("the Router's files (Application Support/Fjord and ~/.claude)") else { return nil }
        return unguarded
    }

    /// For the hook process, which is never a test run.
    static var unguarded: RouterPaths {
        RouterPaths(support: AppIdentity.supportDirectory(),
                    claudeDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true))
    }
}

/// Small private files: written whole or not at all, readable by you alone.
enum PrivateFile {
    /// A folder for you alone (0700), with its parents, made off the main thread: where the Router's runs of Claude Code
    /// start, made as a message is prepared and delivered.
    static func makeFolder(_ url: URL) async {
        await OffMain.run {
            _ = try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        try commit(prepare(data, for: url, mode: mode), to: url)
    }

    /// Writes `data` to a temporary file next to `url`, created with its mode, so it is never readable by others, even for a
    /// moment. `commit` puts it in place.
    static func prepare(_ data: Data, for url: URL, mode: mode_t = 0o600) throws -> URL {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temp.path]) }
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var done = 0
            while done < buffer.count {
                let n = Darwin.write(fd, base + done, buffer.count - done)
                if n <= 0 { break }
                done += n
            }
            return done
        }
        fchmod(fd, mode)
        close(fd)
        guard written == data.count else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return temp
    }

    static func commit(_ temp: URL, to url: URL) throws {
        guard rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

// MARK: - Pending forms

/// A question form, or a plan to approve, that a session has open, held by Fjord's hook until it is answered
/// here or in the app.
struct PendingForm: Codable, Hashable, Identifiable, Sendable {
    struct Option: Codable, Hashable, Sendable {
        var label: String
        var description: String
    }

    struct Question: Codable, Hashable, Sendable {
        var question: String
        var header: String
        var multiSelect: Bool
        var options: [Option]
    }

    /// The file's key: `<session>-<ms>-<pid>`.
    var id: String
    /// Claude Code's session id (`ClaudeSession.cliID`).
    var cliSessionID: String
    var transcriptPath: String
    var questions: [Question]
    var createdAt: Date
    /// The hook's process: a form whose hook is gone can't be answered.
    var pid: Int32
    /// The call (`tool_use` id) the form answers, once the hook has found it in the transcript: what ties it to its card.
    var toolUseID: String? = nil
    /// For a plan to approve (ExitPlanMode): the plan, in Markdown. Nil for a question form.
    var plan: String? = nil

    var isPlan: Bool { plan != nil }

    /// What you decide about a plan: approved, or sent back to keep planning with an optional note.
    struct PlanDecision: Codable, Hashable, Sendable {
        var approve: Bool
        var feedback: String = ""
    }

    /// What the hook writes. Unknown fields are left alone.
    static func decode(_ data: Data) -> PendingForm? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["key"] as? String, let session = obj["session_id"] as? String,
              let input = obj["tool_input"] as? [String: Any] else { return nil }
        let ms = (obj["created_at"] as? NSNumber)?.doubleValue ?? 0
        var form = PendingForm(id: key, cliSessionID: session, transcriptPath: obj["transcript_path"] as? String ?? "",
                               questions: [], createdAt: Date(timeIntervalSince1970: ms / 1000),
                               pid: (obj["pid"] as? NSNumber)?.int32Value ?? 0, toolUseID: obj["tool_use_id"] as? String)
        if obj["tool_name"] as? String == FormHook.planTool {
            form.plan = input["plan"] as? String ?? ""
            return form
        }
        guard let raw = input["questions"] as? [[String: Any]] else { return nil }
        form.questions = raw.compactMap { q -> Question? in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Option? in
                (o["label"] as? String).map { Option(label: $0, description: o["description"] as? String ?? "") }
            }
            return Question(question: text, header: q["header"] as? String ?? "", multiSelect: q["multiSelect"] as? Bool ?? false,
                            options: options)
        }
        return form.questions.isEmpty ? nil : form
    }
}

/// Fjord's side of the form hook: lists the forms the hook holds and writes the answers it waits for.
final class FormBridge: @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case unanswered(String)
        case empty(String)
        case unknown(String)
        /// Answers for a plan, or a decision on a plan for a question form.
        case notAQuestion
        case notAPlan

        var errorDescription: String? {
            switch self {
            case .unanswered(let q): "No answer for “\(q)”"
            case .empty(let q): "The answer for “\(q)” is empty"
            case .unknown(let q): "The form has no question “\(q)”"
            case .notAQuestion: "This is a plan to approve, not a question"
            case .notAPlan: "This is a question, not a plan to approve"
            }
        }
    }

    static let marker = ".enabled"
    private let queue = DispatchQueue(label: "fjord.forms", qos: .utility)
    private var watcher: FolderWatcher?
    private(set) var dir: URL?
    private var deliver: (@MainActor ([String: PendingForm]) -> Void)?

    /// Watches `dir` and hands every change of the forms to `deliver`, on the main thread.
    @MainActor
    func start(dir: URL, deliver: @escaping @MainActor ([String: PendingForm]) -> Void) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.dir = dir
        self.deliver = deliver
        watcher = FolderWatcher([dir], latency: 0.1) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }

    @MainActor
    func stop() {
        watcher = nil
        deliver = nil
        dir = nil
    }

    /// Reads the folder off the main thread.
    @MainActor
    func refresh() {
        guard let dir, let deliver else { return }
        queue.async {
            let forms = Self.read(dir: dir)
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(forms) } }
        }
    }

    /// Reads and delivers the current forms before returning. Callers that need the result now can order it without polling.
    @MainActor
    func refreshAndWait() async {
        guard let dir, let deliver else { return }
        let forms = await withCheckedContinuation { done in
            queue.async {
                let forms = Self.read(dir: dir)
                DispatchQueue.main.async { done.resume(returning: forms) }
            }
        }
        deliver(forms)
    }

    /// The newest form of each session. Forms whose hook died are deleted: nothing would read their answer.
    static func read(dir: URL, alive: (Int32) -> Bool = processAlive) -> [String: PendingForm] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var forms: [String: PendingForm] = [:]
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".answer.json")
            && !url.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: url), let form = PendingForm.decode(data) else { continue }
            guard alive(form.pid) else {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: answerURL(form.id, in: dir))
                continue
            }
            if let other = forms[form.cliSessionID], other.createdAt > form.createdAt { continue }
            forms[form.cliSessionID] = form
        }
        return forms
    }

    static func answerURL(_ key: String, in dir: URL) -> URL { dir.appendingPathComponent("\(key).answer.json") }

    /// Several labels picked in a multi-select question, as the form takes them.
    static func joined(_ labels: [String]) -> String { labels.joined(separator: ", ") }

    /// Writes the answer the hook is waiting for: one per question, by its text. Any text is accepted, not only an option's
    /// label: the form always offers "Other" for your own words.
    func answer(_ form: PendingForm, answers: [String: String]) throws {
        guard let dir else { throw CocoaError(.fileNoSuchFile) }
        try Self.answer(form, answers: answers, in: dir)
    }

    static func validate(_ form: PendingForm, _ answers: [String: String]) throws -> [String: String] {
        guard !form.isPlan else { throw Failure.notAQuestion }
        let questions = Set(form.questions.map(\.question))
        if let extra = answers.keys.sorted().first(where: { !questions.contains($0) }) { throw Failure.unknown(extra) }
        var clean: [String: String] = [:]
        for q in form.questions {
            guard let given = answers[q.question] else { throw Failure.unanswered(q.question) }
            let text = given.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.empty(q.question) }
            clean[q.question] = text
        }
        return clean
    }

    static func answer(_ form: PendingForm, answers: [String: String], in dir: URL) throws {
        try PrivateFile.write(answerData(form, answers), to: answerURL(form.id, in: dir))
    }

    /// The answer file for a question form: `{"answers": {question: answer}}`.
    static func answerData(_ form: PendingForm, _ answers: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["answers": validate(form, answers)], options: [.sortedKeys])
    }

    /// The answer file for a plan: `{"plan": {"approve": Bool, "feedback": String}}`, the note trimmed (only sent back with
    /// "Keep planning").
    static func answerData(_ form: PendingForm, plan decision: PendingForm.PlanDecision) throws -> Data {
        guard form.isPlan else { throw Failure.notAPlan }
        let note = decision.approve ? "" : decision.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        return try JSONSerialization.data(withJSONObject: ["plan": ["approve": decision.approve, "feedback": note] as [String: Any]],
                                          options: [.sortedKeys])
    }

    static func answer(_ form: PendingForm, plan decision: PendingForm.PlanDecision, in dir: URL) throws {
        try PrivateFile.write(answerData(form, plan: decision), to: answerURL(form.id, in: dir))
    }

    /// The marker the hook looks for: without it, the hook steps aside at once.
    static func setEnabled(_ on: Bool, dir: URL) throws {
        let marker = dir.appendingPathComponent(Self.marker)
        if on {
            try PrivateFile.write(Data(), to: marker)
        } else if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - Hook mode

/// `Fjord --form-hook`: what Claude Code runs when a session asks a question or has a plan to approve (a
/// `PermissionRequest` hook on `AskUserQuestion` and `ExitPlanMode`). It leaves the form in the forms folder and waits: an
/// answer written by Fjord is printed as the hook's decision, which answers the form like a click. If it is answered
/// in the app first, or anything else ends the wait, it leaves quietly and the app's own form stands. It prints nothing
/// but that one decision. For any other tool it only observes: it notes the prompt (`observe`) and leaves at once.
///
/// A plan's decision is the one the app's own buttons give (checked against Claude Code 2.1): Approve is `allow` with the
/// input as it came (a bare `allow` is ignored for this tool), and the session leaves plan mode as it would there; Keep
/// planning is `deny` with Claude Code's own words for a rejection, your note after them, and the session stays in plan mode.
enum FormHook {
    static let questionTool = "AskUserQuestion"
    static let planTool = "ExitPlanMode"
    /// What Claude Code tells the model when you turn a tool down, alone or followed by what you said.
    static let rejected = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."
    static let rejectedWithNote = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). To tell you how to proceed, the user said:\n"

    struct Environment {
        var forms: URL
        /// Where notes of ordinary tools' prompts go; beside the forms folder unless given.
        var permissions: URL? = nil
        var input: Data
        var output: (Data) -> Void
        var pid: Int32 = getpid()
        var now: () -> Date = Date.init
        var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        /// The process that ran the hook is still there (it is re-parented to launchd when it goes).
        var parentAlive: () -> Bool = { getppid() != 1 }
        /// A signal asked it to stop.
        var stopped: () -> Bool = { FormHook.signalled != 0 }
        var interval: TimeInterval = 0.25
        var maxWait: TimeInterval = 24 * 3600
    }

    /// How a run ended (the process exits 0 whichever it is).
    enum Outcome: Equatable {
        case ignored, observed, answered, answeredElsewhere, parentGone, disabled, stopped, timedOut, failed
    }

    nonisolated(unsafe) static var signalled: sig_atomic_t = 0

    /// The process's entry point: never returns.
    static func main() -> Never {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { _ in FormHook.signalled = 1 }
        }
        guard let input = readInput(fd: STDIN_FILENO, stopped: { FormHook.signalled != 0 }) else { exit(0) }
        let env = Environment(forms: RouterPaths.unguarded.forms, permissions: RouterPaths.unguarded.permissions, input: input) { data in
            FileHandle.standardOutput.write(data)
        }
        _ = run(env)
        exit(0)
    }

    /// Reads the request: up to `limit` bytes, for at most `timeout`, giving up at once when `stopped`. Nil when it gave up
    /// (stdin held open, too large, a signal).
    static func readInput(fd: Int32, limit: Int = 8 << 20, timeout: TimeInterval = 60, stopped: () -> Bool) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if stopped() || Date() >= deadline { return nil }
            var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fds, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { continue }
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            if n == 0 { return data }
            data.append(contentsOf: buffer[0..<n])
            if data.count > limit { return nil }
        }
    }

    static func run(_ env: Environment) -> Outcome {
        let fm = FileManager.default
        guard let request = try? JSONSerialization.jsonObject(with: env.input) as? [String: Any],
              request["hook_event_name"] as? String == "PermissionRequest",
              let tool = request["tool_name"] as? String,
              let input = request["tool_input"] as? [String: Any] else { return .ignored }
        guard fm.fileExists(atPath: env.forms.appendingPathComponent(FormBridge.marker).path) else { return .disabled }
        let session = request["session_id"] as? String ?? "unknown"
        guard tool == questionTool || tool == planTool else { return observe(env, request: request, tool: tool, input: input) }
        let safe = Self.safe(session)
        let started = env.now()
        let key = "\(safe.isEmpty ? "unknown" : safe)-\(Int64(started.timeIntervalSince1970 * 1000))-\(env.pid)"
        let pending = env.forms.appendingPathComponent("\(key).json")
        let answer = FormBridge.answerURL(key, in: env.forms)
        var record: [String: Any] = [
            "key": key, "session_id": session, "transcript_path": request["transcript_path"] as? String ?? "",
            "cwd": request["cwd"] as? String ?? "", "tool_name": tool, "tool_input": input,
            "created_at": Int64(started.timeIntervalSince1970 * 1000), "pid": Int(env.pid),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              (try? PrivateFile.write(data, to: pending)) != nil else { return .failed }
        func cleanUp() {
            try? fm.removeItem(at: pending)
            try? fm.removeItem(at: answer)
        }

        var transcript = TranscriptWatch(path: request["transcript_path"] as? String, tool: tool, input: input as NSDictionary)
        while true {
            if let data = try? Data(contentsOf: answer),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let verdict = Self.decision(tool: tool, input: input, answer: obj) {
                let decision: [String: Any] = ["hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": verdict,
                ]]
                cleanUp()
                guard let out = try? JSONSerialization.data(withJSONObject: decision, options: [.sortedKeys]) else { return .failed }
                env.output(out + Data("\n".utf8))
                return .answered
            }
            if transcript.answered() { cleanUp(); return .answeredElsewhere }
            // The call is known: the form says which it is, so Fjord puts it on that call's card only.
            if let call = transcript.id, record["tool_use_id"] == nil {
                record["tool_use_id"] = call
                if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                    try? PrivateFile.write(data, to: pending)
                }
            }
            if env.stopped() { cleanUp(); return .stopped }
            if !env.parentAlive() { cleanUp(); return .parentGone }
            if !fm.fileExists(atPath: env.forms.appendingPathComponent(FormBridge.marker).path) { cleanUp(); return .disabled }
            if env.now().timeIntervalSince(started) >= env.maxWait { cleanUp(); return .timedOut }
            env.sleep(env.interval)
        }
    }

    /// A session id as a file name's part.
    static func safe(_ session: String) -> String {
        String(session.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            .map(Character.init))
    }

    /// An ordinary tool's permission prompt is about to show: the hook only notes it, for Fjord to read the session as
    /// waiting on you, and leaves at once. It prints nothing, so Claude Code's own prompt goes on untouched. What ends the
    /// wait is read from the transcript (the call's result, a denial included), not here: this process is gone by then.
    static func observe(_ env: Environment, request: [String: Any], tool: String, input: [String: Any]) -> Outcome {
        let session = request["session_id"] as? String ?? "unknown"
        let safe = Self.safe(session)
        let started = env.now()
        let key = "\(safe.isEmpty ? "unknown" : safe)-\(Int64(started.timeIntervalSince1970 * 1000))-\(env.pid)"
        let dir = env.permissions ?? env.forms.deletingLastPathComponent().appendingPathComponent("permissions", isDirectory: true)
        var note: [String: Any] = [
            "key": key, "session_id": session, "transcript_path": request["transcript_path"] as? String ?? "",
            "tool_name": tool, "tool_input": input, "created_at": Int64(started.timeIntervalSince1970 * 1000),
        ]
        if let id = request["tool_use_id"] as? String, !id.isEmpty { note["tool_use_id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: note, options: [.sortedKeys]),
              (try? PrivateFile.write(data, to: dir.appendingPathComponent("\(key).json"))) != nil else { return .failed }
        return .observed
    }

    /// The decision for Fjord's answer file, or nil while it isn't one for this tool: a question's answers go
    /// in its input; a plan is approved as it came or turned down with Claude Code's words and your note.
    static func decision(tool: String, input: [String: Any], answer: [String: Any]) -> [String: Any]? {
        if tool == planTool {
            guard let plan = answer["plan"] as? [String: Any], let approve = plan["approve"] as? Bool else { return nil }
            if approve { return ["behavior": "allow", "updatedInput": input] }
            let note = (plan["feedback"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ["behavior": "deny", "message": note.isEmpty ? rejected : rejectedWithNote + note]
        }
        guard let answers = answer["answers"] as? [String: String] else { return nil }
        var updated = input
        updated["answers"] = answers
        return ["behavior": "allow", "updatedInput": updated]
    }

    /// Follows the session's transcript to see the question answered in the app. Claude Code writes the call (`tool_use`)
    /// before it runs the hook, so this hook's call is the latest call of its tool whose input is this form's: the first
    /// read looks for it backwards from the end, a chunk at a time. Once it is known only a `tool_result` for its id ends the
    /// wait, and only what was added since is read.
    struct TranscriptWatch {
        let path: String?
        let tool: String
        let input: NSDictionary
        private let marker: Data
        /// The call this hook answers, once found.
        private(set) var id: String?
        private var offset: UInt64?
        /// The end of a line still being written, carried to the next read.
        private var partial = Data()
        private var done = false
        static let chunk: UInt64 = 1 << 20

        init(path: String?, tool: String = FormHook.questionTool, input: NSDictionary) {
            self.path = path
            self.tool = tool
            self.input = input
            marker = Data("\"\(tool)\"".utf8)
        }

        mutating func answered() -> Bool {
            guard !done, let path, !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return done }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            guard let offset else {
                // Only complete lines are judged: a record still being written may be the call itself, so the first look
                // waits until the file ends with a whole line.
                if size > 0 {
                    try? handle.seek(toOffset: size - 1)
                    if (try? handle.read(upToCount: 1)) != Data("\n".utf8) { return false }
                }
                findCall(handle, end: size)
                return done
            }
            // A file that shrank was replaced: nothing in it can be trusted to follow on.
            guard size >= offset else { return done }
            guard size > offset else { return false }
            try? handle.seek(toOffset: offset)
            let chunk = (try? handle.readToEnd()) ?? Data()
            self.offset = offset + UInt64(chunk.count)
            var lines = (partial + chunk).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            partial = Data(lines.removeLast())
            for line in lines {
                let line = Data(line)
                if id == nil, let found = call(in: line) { id = found }
                if let id, results(in: line).contains(id) { done = true; return true }
            }
            return false
        }

        /// The first read: backwards from `end` until the call is found (or the file's start), noting the results seen after
        /// it. A call already answered was answered in the app before the hook looked.
        private mutating func findCall(_ handle: FileHandle, end: UInt64) {
            offset = end
            var pos = end
            var carry = Data()
            var tailFound = false
            var later = Set<String>()
            while pos > 0 {
                let start = pos > Self.chunk ? pos - Self.chunk : 0
                try? handle.seek(toOffset: start)
                var buffer = ((try? handle.read(upToCount: Int(pos - start))) ?? Data()) + carry
                pos = start
                if !tailFound {
                    // What follows the last newline is a line still being written: the incremental reads finish it.
                    if let newline = buffer.lastIndex(of: UInt8(ascii: "\n")) {
                        partial = Data(buffer[(newline + 1)...])
                        buffer = Data(buffer[...newline])
                        tailFound = true
                    } else if start == 0 {
                        partial = buffer
                        return
                    } else {
                        carry = buffer
                        continue
                    }
                }
                var lines = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropLast()
                // The first line may begin in the chunk before.
                if start > 0, let first = lines.first {
                    carry = Data(first) + Data("\n".utf8)
                    lines = lines.dropFirst()
                } else {
                    carry = Data()
                }
                for line in lines.reversed() {
                    let line = Data(line)
                    if let found = call(in: line) {
                        id = found
                        done = later.contains(found)
                        return
                    }
                    later.formUnion(results(in: line))
                }
            }
        }

        private static let resultMarker = Data("tool_result".utf8)

        /// The id of the line's last call of this tool with this form's input.
        private func call(in line: Data) -> String? {
            guard line.range(of: marker) != nil, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let parts = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return nil }
            return parts.last { part in
                part["type"] as? String == "tool_use" && part["name"] as? String == tool
                    && (part["input"] as? NSDictionary)?.isEqual(input) == true
            }?["id"] as? String
        }

        /// The call ids the line answers.
        private func results(in line: Data) -> [String] {
            guard line.range(of: Self.resultMarker) != nil, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "user",
                  let parts = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
            return parts.compactMap { $0["type"] as? String == "tool_result" ? $0["tool_use_id"] as? String : nil }
        }
    }
}

// MARK: - Installer

/// Puts the hook in Claude Code's user settings and takes it out again, leaving everything else in the file as it was.
/// Claude Code writes the file too: a change is made to the file as read, and made again if it changed meanwhile.
struct FormHookInstaller {
    enum Status: Equatable, Sendable {
        case installed, notInstalled
        /// Installed by another copy of Fjord (the app moved), or by a version of Fjord with fewer tools.
        case outdated
    }

    enum Failure: LocalizedError, Equatable {
        case invalidSettings(String)
        case notAnObject(String)
        case unreadable(String, String)
        /// `hooks` or `hooks.PermissionRequest` has a shape Fjord doesn't know how to add to.
        case incompatible(String, String)
        case keptChanging(String)

        var errorDescription: String? {
            switch self {
            case .invalidSettings(let path): "\(path) isn't valid JSON, so Fjord left it alone. Fix it and turn the Router on again."
            case .notAnObject(let path): "\(path) doesn't hold a JSON object, so Fjord left it alone."
            case .unreadable(let path, let reason): "Fjord couldn't read \(path): \(reason)"
            case .incompatible(let path, let key): "In \(path), “\(key)” isn't what Claude Code expects, so Fjord left the file alone."
            case .keptChanging(let path): "\(path) kept changing while Fjord was updating it. Try again."
            }
        }
    }

    var claudeDir: URL
    /// `fjord-form.sh` for the installed app, `fjord-dev-form.sh` for debug and E2E builds (`AppIdentity`).
    static func scriptName(development: Bool) -> String { development ? "fjord-dev-form.sh" : "fjord-form.sh" }
    var script: URL { claudeDir.appendingPathComponent("hooks/" + Self.scriptName(development: AppIdentity.isDevelopment())) }
    var settings: URL { claudeDir.appendingPathComponent("settings.json") }
    var backup: URL { claudeDir.appendingPathComponent("settings.json.fjord-backup") }
    /// What the settings run: the script's path, quoted for the shell if it has to be.
    var command: String { Self.quoted(script.path, onlyIfNeeded: true) }
    static let timeout = 86400
    /// The tools the hook holds: questions, and plans to approve (a guest's hook runs those alone: `formMatcher`).
    static let formMatcher = "\(FormHook.questionTool)|\(FormHook.planTool)"
    /// Every tool: the hook holds the two form tools and only notes the permission prompt of any other.
    static let matcher = "*"
    static let attempts = 3
    /// Runs between computing a change and writing it (tests write to the file there, as Claude Code might).
    var beforeReplace: (() -> Void)?

    init(claudeDir: URL) {
        self.claudeDir = claudeDir
    }

    static func quoted(_ s: String, onlyIfNeeded: Bool = false) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@:")
        if onlyIfNeeded, !s.isEmpty, s.unicodeScalars.allSatisfy(plain.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func scriptText(executable: String) -> String {
        let exe = Self.quoted(executable)
        return """
        #!/bin/sh
        # Fjord's form hook lets you answer a Claude Code session's questions and approve its plans from Fjord's Router.
        # Fjord manages this file (it is removed when you turn the Router off); edits are overwritten.
        [ -x \(exe) ] || exit 0
        exec \(exe) --form-hook

        """
    }

    func status(executable: String) -> Status {
        guard let text = try? String(contentsOf: script, encoding: .utf8), let current = entryIsCurrent() else { return .notInstalled }
        return current && text == scriptText(executable: executable) ? .installed : .outdated
    }

    func install(executable: String) throws {
        let fm = FileManager.default
        let hadScript = fm.fileExists(atPath: script.path)
        try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateFile.write(Data(scriptText(executable: executable).utf8), to: script, mode: 0o755)
        do {
            try modify { root in
                var hooks: [String: Any] = [:]
                if let existing = root["hooks"] {
                    guard let dict = existing as? [String: Any] else { throw Failure.incompatible(settings.path, "hooks") }
                    hooks = dict
                }
                var entries: [Any] = []
                if let existing = hooks["PermissionRequest"] {
                    guard let list = existing as? [Any] else {
                        throw Failure.incompatible(settings.path, "hooks.PermissionRequest")
                    }
                    entries = list
                }
                let ours = entries.filter(runsUs)
                if ours.count == 1, isCurrent(ours[0]) { return false }
                // Ours under another matcher, left by an older Fjord hook, goes; a hook of yours sharing that entry
                // stays as it was.
                entries = removingUs(from: entries)
                entries.append(["matcher": Self.matcher,
                                "hooks": [["type": "command", "command": command, "timeout": Self.timeout]]] as [String: Any])
                hooks["PermissionRequest"] = entries
                root["hooks"] = hooks
                return true
            }
        } catch {
            // A script nothing runs is left only if it was there before.
            if !hadScript { try? fm.removeItem(at: script) }
            throw error
        }
    }

    func uninstall() throws {
        try modify { root in
            guard var hooks = root["hooks"] as? [String: Any], let entries = hooks["PermissionRequest"] as? [Any],
                  entries.contains(where: runsUs) else { return false }
            let kept = removingUs(from: entries)
            if kept.isEmpty { hooks.removeValue(forKey: "PermissionRequest") } else { hooks["PermissionRequest"] = kept }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
            return true
        }
        if FileManager.default.fileExists(atPath: script.path) { try FileManager.default.removeItem(at: script) }
    }

    private func isUs(_ hook: Any) -> Bool {
        guard let dict = hook as? [String: Any], let cmd = dict["command"] as? String else { return false }
        return cmd == command || cmd == script.path
    }

    private func runsUs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["hooks"] as? [Any])?.contains(where: isUs) == true
    }

    private func isCurrent(_ entry: Any) -> Bool { (entry as? [String: Any])?["matcher"] as? String == Self.matcher }

    /// The entries without our hook: an entry left with no hook goes.
    private func removingUs(from entries: [Any]) -> [Any] {
        entries.compactMap { entry -> Any? in
            guard var dict = entry as? [String: Any], let list = dict["hooks"] as? [Any] else { return entry }
            let others = list.filter { !isUs($0) }
            if others.count == list.count { return entry }
            if others.isEmpty { return nil }
            dict["hooks"] = others
            return dict
        }
    }

    /// Whether the settings run the hook for every tool it holds (false: only under an older matcher); nil when they don't
    /// run it at all.
    private func entryIsCurrent() -> Bool? {
        guard let raw = try? readRaw(), let root = try? parse(raw), let hooks = root["hooks"] as? [String: Any],
              let entries = hooks["PermissionRequest"] as? [Any] else { return nil }
        let ours = entries.filter(runsUs)
        if ours.isEmpty { return nil }
        return ours.count == 1 && isCurrent(ours[0])
    }

    /// Through a symlink to the file it points at (settings kept in a dotfiles repo stay there).
    private var target: URL { settings.resolvingSymlinksInPath() }

    /// The file's bytes; nil only when there is no file. Any other failure to read it is an error, never "empty".
    private func readRaw() throws -> Data? {
        let path = target.path
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw Failure.unreadable(settings.path, String(cString: strerror(errno)))
        }
        do {
            return try Data(contentsOf: target)
        } catch {
            throw Failure.unreadable(settings.path, (error as NSError).localizedDescription)
        }
    }

    /// The settings object; nil when there is no file. An existing file that isn't a JSON object (empty included) is refused.
    private func parse(_ raw: Data?) throws -> [String: Any]? {
        guard let raw else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) else {
            throw Failure.invalidSettings(settings.path)
        }
        guard let dict = obj as? [String: Any] else { throw Failure.notAnObject(settings.path) }
        return dict
    }

    /// Applies `change` (false: nothing to do) to the settings as they are, and writes them only if the file is still
    /// what was read; otherwise starts over from what is there now, a few times. A copy of the file as it was before
    /// Fjord first changed it is kept next to it.
    private func modify(_ change: (inout [String: Any]) throws -> Bool) throws {
        do {
            try ClaudeSettingsFile.modify(settings: settings, backup: backup, beforeReplace: beforeReplace, change: change)
        } catch let error as ClaudeSettingsFile.Failure {
            switch error {
            case .invalidJSON(let path): throw Failure.invalidSettings(path)
            case .notAnObject(let path): throw Failure.notAnObject(path)
            case .unreadable(let path, let reason): throw Failure.unreadable(path, reason)
            case .keptChanging(let path): throw Failure.keptChanging(path)
            }
        }
    }
}
