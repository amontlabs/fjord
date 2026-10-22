import Foundation

// MARK: - Off the main thread

/// Blocking work (reading files, a hook a test holds) on a dispatch queue, never on Swift's small shared pool of threads:
/// a held or slow read there would hold up every other task in the app. `qos`: what you are waiting on (a send, a fork) is
/// `.userInitiated`; what keeps things fresh in the background (a scan of your code folders) is `.utility`, so it never
/// competes with the main thread for a core while the window moves.
enum OffMain {
    static func run<T>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            let box = UncheckedBox(work)
            DispatchQueue.global(qos: qos).async { done.resume(returning: box.value()) }
        }
    }

    private struct UncheckedBox<T>: @unchecked Sendable {
        let value: () -> T
        init(_ value: @escaping () -> T) { self.value = value }
    }
}

// MARK: - Running a CLI once

/// Runs a program to its end, off the main thread: stdin given, stdout and the exit status back. One deadline covers it
/// all (writing stdin, the run, reading the output), and a cancelled caller ends it: SIGTERM, then SIGKILL, and its exit is
/// waited for, so nothing is left running.
enum OneShot {
    struct Output: Sendable {
        var stdout: Data
        var stderr: Data
        var status: Int32
    }

    struct TimedOut: LocalizedError {
        var seconds: TimeInterval
        var errorDescription: String? { "No answer in \(Int(RouterTools.bounded(seconds))) s" }
    }

    /// Ends a run from outside (Stop, a reset, quitting); Swift task cancellation does the same.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        /// Woken by the program's exit or by `cancel`.
        fileprivate let wake = DispatchSemaphore(value: 0)
        private(set) var pid: Int32 = 0
        private var gone = false

        init() {}

        private var done = false

        /// Its program was started and hasn't been seen to exit.
        var isRunning: Bool { lock.withLock { pid > 0 && !gone } }
        /// Not over yet: about to start, running, or being stopped. A run ends only once its program is confirmed gone.
        var isActive: Bool { lock.withLock { !done } }

        fileprivate func finish() { lock.withLock { done = true } }

        private var inputDone = false
        /// The program's input was written whole or given up, and its pipe closed.
        var isInputClosed: Bool { lock.withLock { inputDone } }
        fileprivate func inputClosed() { lock.withLock { inputDone = true } }

        fileprivate func exited() { lock.withLock { gone = true } }

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() {
            lock.withLock { cancelled = true }
            wake.signal()
        }

        fileprivate func started(_ pid: Int32) { lock.withLock { self.pid = pid } }
    }

    /// How long a stopped program has after SIGTERM, and how long its output may trail its exit (a child it left behind
    /// may hold the pipes open: they're not waited for past this).
    static let grace: TimeInterval = 1

    static func run(_ path: String, _ arguments: [String], cwd: URL, input: Data = Data(), timeout: TimeInterval,
                    handle: Handle = Handle()) async throws -> Output {
        try await withTaskCancellationHandler {
            // On a plain thread: the waits block it, which Swift's own pool of threads must not be.
            try await withCheckedThrowingContinuation { (finished: CheckedContinuation<Output, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    finished.resume(with: Result { try blocking(path, arguments, cwd: cwd, input: input, timeout: timeout, handle) })
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func blocking(_ path: String, _ arguments: [String], cwd: URL, input: Data, timeout: TimeInterval,
                                 _ handle: Handle) throws -> Output {
        // Bounded: a huge or odd timeout must not trap when it's turned into nanoseconds.
        let deadline = DispatchTime.now() + RouterTools.bounded(timeout)
        defer { handle.finish() }
        guard !handle.isCancelled else { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in handle.wake.signal() }
        // One reader per pipe, each the only one ever to touch its descriptor: checked read(2), never a FileHandle
        // callback (which can't be stopped while one is under way). Stopped and waited for before the pipe is closed.
        let out = PipeReader(stdout.fileHandleForReading), err = PipeReader(stderr.fileHandleForReading)
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        handle.started(process.processIdentifier)
        defer { if !process.isRunning { handle.exited() } }
        out.start()
        err.start()
        defer {
            // Quiesced first (the reader finishes its read and its bounded last drain), then closed.
            for reader in [out, err] { reader.stop() }
            for reader in [out, err] { reader.waitDone() }
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        // Written on its own thread, without blocking, and stopped with the run: a program (or a descendant holding its
        // stdin) that never reads can't keep a thread, the descriptor or the input alive after it.
        let writer = PipeWriter(stdin.fileHandleForWriting, input) { handle.inputClosed() }
        writer.start()
        defer {
            writer.stop()
            writer.waitDone()
        }
        while process.isRunning {
            if handle.isCancelled {
                stop(process)
                throw CancellationError()
            }
            if handle.wake.wait(timeout: deadline) == .timedOut, process.isRunning {
                stop(process)
                throw TimedOut(seconds: timeout)
            }
        }
        // The output may trail the exit a moment; a child holding the pipes isn't waited for beyond the grace.
        let tail = min(deadline, .now() + grace)
        _ = out.waitEOF(until: tail)
        _ = err.waitEOF(until: tail)
        for reader in [out, err] { reader.stop() }
        for reader in [out, err] { reader.waitDone() }
        return Output(stdout: out.data, stderr: err.data, status: process.terminationStatus)
    }

    /// SIGTERM, SIGKILL after the grace, and its exit confirmed.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let until = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < until { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let killed = Date().addingTimeInterval(5)
        while process.isRunning, Date() < killed { usleep(10_000) }
    }

    /// Writes a program's input on a thread of its own: non-blocking writes when the pipe takes them (poll), EINTR and
    /// EAGAIN retried, stopped when asked; the pipe is closed when it's done either way.
    final class PipeWriter: @unchecked Sendable {
        private let file: FileHandle
        private let data: Data
        private let closed: @Sendable () -> Void
        private let lock = NSLock()
        private var stopping = false
        private let done = DispatchSemaphore(value: 0)

        init(_ file: FileHandle, _ data: Data, closed: @escaping @Sendable () -> Void) {
            self.file = file
            self.data = data
            self.closed = closed
        }

        func start() {
            let thread = Thread { [self] in loop() }
            thread.qualityOfService = .utility
            thread.start()
        }

        func stop() { lock.withLock { stopping = true } }

        func waitDone() {
            done.wait()
            done.signal()
        }

        private var isStopping: Bool { lock.withLock { stopping } }

        private func loop() {
            let fd = file.fileDescriptor
            defer {
                try? file.close()
                closed()
                done.signal()
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var offset = 0
            data.withUnsafeBytes { bytes in
                while offset < bytes.count, !isStopping {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&poller, 1, 50)
                    if ready < 0 { if errno == EINTR { continue } else { return } }
                    if ready == 0 { continue }
                    if poller.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
                    let n = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0, errno == EINTR || errno == EAGAIN { continue }
                    return
                }
            }
        }
    }

    /// Reads one pipe on a thread of its own: polls, reads what's there (EINTR and EAGAIN retried), stops at its end or
    /// when asked. Asked to stop, it drains what's already in the pipe, bounded in bytes and time (a descendant still
    /// feeding it can't keep it going), then says it's done.
    final class PipeReader: @unchecked Sendable {
        static let maxBytes = 8 << 20
        static let drainBytes = 1 << 20
        static let drainTime: TimeInterval = 0.2

        private let fd: Int32
        private let lock = NSLock()
        private var buffer = Data()
        private var stopping = false
        private let ended = DispatchSemaphore(value: 0)
        private let done = DispatchSemaphore(value: 0)
        private var reachedEnd = false
        /// Called around each read (tests hold a read in flight to see the stop wait for it).
        var aroundRead: (() -> Void)?

        init(_ file: FileHandle) { fd = file.fileDescriptor }

        var data: Data { lock.withLock { buffer } }

        func start() {
            let thread = Thread { [self] in loop() }
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func stop() { lock.withLock { stopping = true } }

        /// The pipe's end was reached by `until`.
        func waitEOF(until: DispatchTime) -> Bool {
            if lock.withLock({ reachedEnd }) { return true }
            guard ended.wait(timeout: until) == .success else { return false }
            ended.signal()
            return true
        }

        /// Blocks until the reader has finished (its read under way and its last drain included).
        func waitDone() {
            done.wait()
            done.signal()
        }

        private var isStopping: Bool { lock.withLock { stopping } }

        private func append(_ bytes: UnsafeMutableRawBufferPointer, _ n: Int) {
            lock.withLock {
                guard buffer.count < Self.maxBytes else { return }
                buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[0..<min(n, Self.maxBytes - buffer.count)]))
            }
        }

        /// One read: bytes read, 0 at the end, nil when there's nothing now (or an error).
        private func readOnce(_ chunk: UnsafeMutableRawBufferPointer) -> Int? {
            while true {
                aroundRead?()
                let n = read(fd, chunk.baseAddress, chunk.count)
                if n >= 0 { return n }
                if errno == EINTR { continue }
                return nil
            }
        }

        private func loop() {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: 65536, alignment: 1)
            defer {
                chunk.deallocate()
                done.signal()
            }
            while !isStopping {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, 50)
                if ready < 0 { if errno == EINTR { continue } else { break } }
                if ready == 0 { continue }
                guard let n = readOnce(chunk) else { continue }
                if n == 0 {
                    lock.withLock { reachedEnd = true }
                    ended.signal()
                    return
                }
                append(chunk, n)
            }
            // Stopping: what's already there, within the bounds.
            let started = Date()
            var total = 0
            while total < Self.drainBytes, Date().timeIntervalSince(started) < Self.drainTime,
                  let n = readOnce(chunk), n > 0 {
                append(chunk, n)
                total += n
            }
        }
    }

    /// `--output-format json`'s `result` text, or why the run failed.
    static func result(_ output: Output) throws -> String {
        let obj = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any]
        if let obj, obj["is_error"] as? Bool != true, let text = obj["result"] as? String { return text }
        let errors = (obj?["errors"] as? [String])?.joined(separator: "; ")
        let stderr = String(decoding: output.stderr, as: UTF8.self).split(separator: "\n").last.map(String.init)
        throw RouterTools.Failure(errors ?? (obj?["result"] as? String) ?? stderr ?? "Claude Code exited (\(output.status))")
    }
}

// MARK: - Preparing a message

/// What a message to a session becomes before it is sent: the user's words, with what addressed the session or the Router
/// taken out (`Addressing`).
struct Prepared: Equatable, Sendable {
    var text: String
    var original: String
    var rephrased: Bool
    /// The project a new session was started in (`start_session`): its receipt says so.
    var newSessionIn: String? = nil
    /// What the session gets as your words, when `text` is that signed for its plugin (the chat shows this, never the
    /// header).
    var body: String? = nil
    /// A guest-delivered message never falls back to the controller's Claude peer channel.
    var guestLocation: SessionLocation? = nil
}

/// The only edit a message gets before it goes to a session as your words: what addresses the session or the Router is
/// taken out of your own bytes, by fixed rules; nothing is ever added, reworded or reordered (no model writes what is
/// signed as yours). Taken out: the @project pills the message starts with (by where the composer put them, never by
/// matching words against a project's or a session's name: a session's title is its own words, and could eat a condition
/// of yours), and `@router` asides (in balanced brackets on one line, or a whole line starting with the marker). Anything
/// else, "tell <the session> to …" and a `@router` in the middle of your words included, goes as you wrote it.
enum Addressing {
    /// Everything in the message was for the Router (`@router` asides): nothing to pass on.
    struct NothingLeft: LocalizedError {
        var errorDescription: String? { "Nothing to pass on: everything in the message was for the Router" }
    }

    /// `message` with its addressing taken out. `pills`: where its @project pills are (`RouterContext.pills`). `envelope`:
    /// false for a new session's task, whose request was already taken out (`SessionStart.task`): only the asides go.
    static func edit(_ message: String, pills: [Range<Int>] = [], envelope: Bool = true) throws -> Prepared {
        var text = message
        if envelope, let rest = withoutLeadingPills(message, pills) { text = rest }
        text = withoutAsides(text)
        guard text != message else { return Prepared(text: message, original: message, rephrased: false) }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NothingLeft() }
        return Prepared(text: text, original: message, rephrased: true)
    }

    /// The pills `text` starts with taken out, each with the spaces, or the colon or dash (and one line break), after it; nil
    /// when it starts with none, or when nothing would be left. A pill glued to what follows it is left, and so is one in
    /// code (`outsideCode`): an indented `@cache` is the decorator of the code it starts.
    static func withoutLeadingPills(_ text: String, _ pills: [Range<Int>]) -> String? {
        let chars = Array(text)
        let ends = Dictionary(outsideCode(chars, pills).map { ($0.lowerBound, $0.upperBound) }, uniquingKeysWith: max)
        func blank(_ i: Int) -> Bool { i < chars.count && (chars[i] == " " || chars[i] == "\t") }
        var cut = 0
        while true {
            var i = cut
            while blank(i) { i += 1 }
            guard let end = ends[i], end <= chars.count, chars[i] == "@" else { break }
            var k = end
            guard k == chars.count || chars[k].isWhitespace || ":,—–".contains(chars[k]) else { break }
            while blank(k) { k += 1 }
            if k < chars.count, ":,—–".contains(chars[k]) {
                k += 1
                while blank(k) { k += 1 }
                if k < chars.count, chars[k] == "\r" { k += 1 }
                if k < chars.count, chars[k] == "\n" || chars[k] == "\r\n" { k += 1 }
            }
            cut = k
        }
        guard cut > 0, chars[cut...].contains(where: { !$0.isWhitespace }) else { return nil }
        return String(chars[cut...])
    }

    /// The pills that start in the message's own words: one in code (fenced, indented or inline, `codeMask`) is its text.
    static func outsideCode(_ text: [Character], _ pills: [Range<Int>]) -> [Range<Int>] {
        guard !pills.isEmpty else { return [] }
        let code = codeMask(text)
        return pills.filter { $0.lowerBound >= 0 && $0.lowerBound < code.count && !code[$0.lowerBound] }
    }

    // MARK: @router asides

    /// Whether the marker that addresses the Router starts at `i` of `text`: `@router` (any case), unless it is part of a
    /// word or address (a letter or digit right before it: `user@router.com`) or of a name or path (right after it a
    /// letter, digit or `/`, or `.` `-` `_` `@` followed by a letter or digit: `@router.js`, `@router/core`, `@router-old`).
    static func isMarker(_ text: [Character], at i: Int) -> Bool {
        let marker = "@router"
        func word(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        let end = i + marker.count
        guard i >= 0, end <= text.count, text[i] == "@", String(text[i..<end]).lowercased() == marker else { return false }
        if i > 0, word(text[i - 1]) { return false }
        if end < text.count {
            let after = text[end]
            if word(after) || after == "/" { return false }
            if ".-_@".contains(after), end + 1 < text.count, word(text[end + 1]) { return false }
        }
        return true
    }

    /// Which characters are pasted code rather than the message's own words: fenced code (``` to the closing fence or the
    /// end), indented code lines (four spaces or a tab) and inline code (`…` on a line, matching backtick runs). An aside is
    /// never looked for there.
    static func codeMask(_ text: [Character]) -> [Bool] {
        var mask = [Bool](repeating: false, count: text.count)
        var lineStart = 0
        var fenced = false
        while lineStart <= text.count {
            var lineEnd = lineStart
            while lineEnd < text.count, !text[lineEnd].isNewline { lineEnd += 1 }
            let line = Array(text[lineStart..<lineEnd])
            var fences = 0, f = 0
            while f + 3 <= line.count {
                if line[f] == "`", line[f + 1] == "`", line[f + 2] == "`" { fences += 1; f += 3 } else { f += 1 }
            }
            if fences % 2 == 1 {
                fenced.toggle()
                for k in lineStart..<lineEnd { mask[k] = true }
            } else if fenced || line.starts(with: Array("    ")) || line.first == "\t" {
                for k in lineStart..<lineEnd { mask[k] = true }
            } else {
                var k = 0
                while k < line.count {
                    guard line[k] == "`" else { k += 1; continue }
                    var run = 0
                    while k + run < line.count, line[k + run] == "`" { run += 1 }
                    var j = k + run, close: Int?
                    while j < line.count {
                        if line[j] == "`" {
                            var r = 0
                            while j + r < line.count, line[j + r] == "`" { r += 1 }
                            if r == run { close = j + r; break }
                            j += r
                        } else { j += 1 }
                    }
                    if let close {
                        for m in k..<close { mask[lineStart + m] = true }
                        k = close
                    } else { k += run }
                }
            }
            lineStart = lineEnd + 1
        }
        return mask
    }

    /// Which characters are quoted in the message's own words: a double-quoted span ("…" or “…”) opened and closed on one
    /// line, outside code (`code`), its quotes included. Single quotes are never quotes here: they are apostrophes as often.
    static func quoteMask(_ text: [Character], code: [Bool]) -> [Bool] {
        var mask = [Bool](repeating: false, count: text.count)
        var k = 0
        while k < text.count {
            let open = text[k]
            guard !code[k], open == "\"" || open == "“" else { k += 1; continue }
            let close: Character = open == "\"" ? "\"" : "”"
            var j = k + 1
            while j < text.count, !text[j].isNewline, code[j] || text[j] != close { j += 1 }
            guard j < text.count, !text[j].isNewline else { k += 1; continue }
            for m in k...j { mask[m] = true }
            k = j + 1
        }
        return mask
    }

    /// The `@router` asides of `text`, as the character ranges they take, in order. Only two forms are asides, both in the
    /// message's own words (not in code, nor opened in a double-quoted span: `quoteMask`): a bracket opened right before the
    /// marker and closed, balanced, on the same line ("(@router no rush)", "[@router later]"), with the spaces before it,
    /// code inside it included; or a whole line that starts with the marker
    /// (after up to three spaces), with its line break ("@router what needs me?"). A marker anywhere else ("ask @router",
    /// `print(f'ask @router')`) is text, and goes as written.
    static func asides(_ text: [Character]) -> [Range<Int>] {
        let code = codeMask(text), quoted = quoteMask(text, code: code)
        func blank(_ c: Character) -> Bool { c == " " || c == "\t" }
        var found: [Range<Int>] = []
        var lineStart = 0
        while lineStart < text.count {
            var lineEnd = lineStart
            while lineEnd < text.count, !text[lineEnd].isNewline { lineEnd += 1 }
            defer { lineStart = lineEnd + 1 }
            var first = lineStart
            while first < lineEnd, text[first] == " ", first - lineStart < 3 { first += 1 }
            if first < lineEnd, !code[first], isMarker(text, at: first) {
                // The whole line, with its own break (or the one before it, for the last line).
                if lineEnd < text.count { found.append(lineStart..<(lineEnd + 1)) }
                else if let last = found.last, last.upperBound == lineStart { found[found.count - 1] = last.lowerBound..<lineEnd }
                else { found.append((lineStart > 0 ? lineStart - 1 : lineStart)..<lineEnd) }
                continue
            }
            var k = lineStart
            while k < lineEnd {
                defer { k += 1 }
                guard !code[k], !quoted[k], text[k] == "(" || text[k] == "[" else { continue }
                let open = text[k], close: Character = open == "(" ? ")" : "]"
                var m = k + 1
                while m < lineEnd, blank(text[m]) { m += 1 }
                guard m < lineEnd, !code[m], isMarker(text, at: m) else { continue }
                // Balanced on the brackets outside code: code inside the aside ("don't wait on `CI`") is the aside's own.
                var depth = 0, j = k, end: Int?
                while j < lineEnd {
                    if !code[j], text[j] == open { depth += 1 }
                    else if !code[j], text[j] == close { depth -= 1; if depth == 0 { end = j; break } }
                    j += 1
                }
                guard let end else { continue }
                var start = k
                while start > lineStart, blank(text[start - 1]) { start -= 1 }
                var stop = end + 1
                if start == lineStart { while stop < lineEnd, blank(text[stop]) { stop += 1 } }
                found.append(start..<stop)
                k = stop - 1
            }
        }
        return found
    }

    /// The asides taken out (`asides`); every other character is left as it is.
    static func withoutAsides(_ message: String) -> String {
        var chars = Array(message)
        for range in asides(chars).reversed() { chars.removeSubrange(range) }
        return String(chars)
    }
}

// MARK: - Starting a session

/// A new desktop session made directly, with no draft for the user to send: a CLI session is created in the folder with no
/// model call (its only line renames it), the app imports it (`claude://resume`) and starts its process, which then
/// registers as a peer the Router can message.
enum SessionStart {
    struct Started: Equatable, Sendable {
        /// The desktop app's id, `local_<uuid>`.
        var sessionID: String
        var peer: String
        /// Claude Code's own session id: the bootstrap's uuid.
        var cliID: String { sessionID.hasPrefix("local_") ? String(sessionID.dropFirst(6)) : sessionID }
    }

    static let wait: TimeInterval = 20

    /// A start the Claude app has but doesn't run yet (`NotRunning`): done as a start, its first message held until the
    /// session runs (`RouterTools.finishStart`).
    struct Held: LocalizedError {
        var waiting: NotRunning
        var title: String
        /// The project's name.
        var project: String
        /// The first message, prepared but not signed yet; nil when there is none.
        var ready: Prepared?
        var settings: SessionSettings?
        var errorDescription: String? { waiting.errorDescription }
    }

    // MARK: The task of a start

    private static let models = "opus|sonnet|haiku|fable"
    private static let efforts = "low|medium|high|xhigh|max"
    /// One setting, in the words that ask for it: a model ("with opus", "using the sonnet model", "on haiku", "opus model")
    /// or an effort ("with low effort", "at high effort", "high effort", "effort of max"). Where these words ask for it is
    /// the request's alone (`settings(in:)`): before the task, or the clause the request ends with.
    static let settingItem =
        #"(?:(?:with|using|use|on)\s+(?:the\s+)?(?:\#(models))(?:\s+model)?|(?:the\s+)?(?:\#(models))\s+model|(?:(?:with|at|on)\s+)?(?:\#(efforts))\s+effort|(?:with\s+)?effort\s+(?:of\s+|to\s+|level\s+)?(?:\#(efforts)))\b"#
    private static let settingClause = #"(?:and\s+)?"# + settingItem
    /// What joins one setting to the next in a run of them: "with opus, high effort", "using sonnet and low effort".
    private static let settingJoin = #"[ \t]*(?:[,;][ \t]*)?(?:and[ \t]+)?"#
    /// Where a session starts, as the request names it before the task ("in lookout", "in the <pill> repo"): only so the
    /// settings after it are still the request's, never a model's or an effort's words.
    private static let settingPlace =
        #"(?:in|on|for|inside)\s+(?:the\s+)?(?:[\x{E000}-\x{F8FF}]|(?!(?:\#(models)|\#(efforts))\b)[\w.\-]+)(?:\s+(?:project|repo|repository|folder))?"# + goesOn

    /// The settings a request (`envelope`) asks for, in its words, in order: a run of them that leads it, after the request
    /// to start a session and where it starts ("start a session in lookout with opus, high effort: …"), or, with no such
    /// request, one that opens with "with", "using" or "use" ("with opus fix the tests"); and the clause it ends with
    /// (`trailingSettings`). Anywhere else ("add a settings toggle for high effort") they are the task's own words.
    static func settings(in request: String) -> [String] {
        var rest = request, at = 0
        func eat(_ pattern: String) -> String? {
            guard let r = rest.range(of: "^(?:" + pattern + ")", options: [.regularExpression, .caseInsensitive]), !r.isEmpty
            else { return nil }
            let taken = String(rest[r])
            at += taken.count
            rest = String(rest[r.upperBound...])
            return taken
        }
        _ = eat(#"[\s\x{E000}-\x{F8FF},:;\-–—]+"#)
        let started = eat(startPhrase) != nil
        var items: [String] = []
        if started || rest.range(of: #"^(?:with|using|use)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            while true {
                _ = eat(#"[ \t,:;\-–—]+"#)
                if let item = eat(settingClause) { items.append(item); continue }
                if started, eat(settingPlace) != nil { continue }
                break
            }
        }
        let tail = trailingSettings(request).filter { request.distance(from: request.startIndex, to: $0.item.lowerBound) >= at }
        return items + tail.map(\.words)
    }

    /// The settings `text` ends with ("fix the tests with opus, high effort", "…, using sonnet", "…but use haiku"): a clause
    /// that opens with "with" or "using" (not a bare "use", and not after "to": an infinitive belongs to the task), is set
    /// apart from the task by a comma, semicolon, dash or parentheses ("…, with opus", "(using haiku)"; unseparated, "replace
    /// the default model with sonnet" is all task), and holds settings only, with nothing after it but the sentence's closing
    /// mark. Each setting as its words (`item`) and what goes with them when they are taken out (`cut`: the comma or "and"
    /// before it, and, before the first, a "but", "instead" or "rather" leading into the clause). Never one said not to be
    /// wanted (`SessionSettings.negated`).
    static func trailingSettings(_ text: String) -> [(cut: Range<String.Index>, item: Range<String.Index>, words: String)] {
        // Read on its words alone (`wordsOnly`): code and quotes can't be settings, nor can they or an aside end the clause.
        let (seen, at) = wordsOnly(text)
        let chars = Array(text.indices) + [text.endIndex]
        func original(_ r: Range<String.Index>) -> Range<String.Index> {
            let a = seen.distance(from: seen.startIndex, to: r.lowerBound), b = seen.distance(from: seen.startIndex, to: r.upperBound)
            return chars[at[a]]..<(b > a ? text.index(after: chars[at[b - 1]]) : chars[at[a]])
        }
        return trailingSettings(seen: seen).map { (original($0.cut), original($0.item), String(seen[$0.item])) }
    }

    /// `text` as its settings are read: each character of code or of a double-quoted span (`Addressing.codeMask`,
    /// `quoteMask`) made a stand-in that is no word, space or mark, and its `@router` asides taken out; for each character
    /// left, and its end, where it is in `text`.
    static func wordsOnly(_ text: String) -> (String, [Int]) {
        let chars = Array(text)
        let code = Addressing.codeMask(chars), quoted = Addressing.quoteMask(chars, code: code)
        var aside = [Bool](repeating: false, count: chars.count)
        for r in Addressing.asides(chars) { for k in r { aside[k] = true } }
        var seen: [Character] = [], at: [Int] = []
        for k in chars.indices where !aside[k] {
            seen.append(code[k] || quoted[k] ? "\u{FFFC}" : chars[k])
            at.append(k)
        }
        at.append(chars.count)
        return (String(seen), at)
    }

    private static func trailingSettings(seen text: String) -> [(cut: Range<String.Index>, item: Range<String.Index>)] {
        // Only a clause set apart from the task counts: after a comma, semicolon or dash, or in parentheses. Without one,
        // "with <model>" ending a sentence is the task's own words ("replace the default model with sonnet").
        let body = #"(?:(?:but|instead|rather|and)\b[ \t]*)?(?<!\bto[ \t]{0,3})\b(?=(?:with|using)\b)"# + settingItem
            + "(?:" + settingJoin + settingItem + ")*"
        let pattern = #"[ \t]*(?:[,;\x{2014}\x{2013}]|[ \t]-(?=[ \t]))[ \t]*"# + body + #"(?=[ \t]*[.,;:!?]*[ \t]*$)"#
            + #"|[ \t]*\([ \t]*"# + body + #"[ \t]*\)(?=[ \t]*[.,;:!?]*[ \t]*$)"#
        guard let clause = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let one = try? NSRegularExpression(pattern: "(" + settingJoin + ")(" + settingItem + ")", options: [.caseInsensitive])
        else { return [] }
        let length = NSRange(text.startIndex..., in: text).length
        var from = 0
        while from < length, let m = clause.firstMatch(in: text, range: NSRange(location: from, length: length - from)),
              let whole = Range(m.range, in: text) {
            var found: [(cut: Range<String.Index>, item: Range<String.Index>)] = []
            for im in one.matches(in: text, range: m.range) {
                guard let join = Range(im.range(at: 1), in: text), let item = Range(im.range(at: 2), in: text) else { continue }
                guard !SessionSettings.negated(text, before: item.lowerBound, from: whole.lowerBound) else { found = []; break }
                found.append((found.isEmpty ? whole.lowerBound..<item.upperBound : join.lowerBound..<item.upperBound, item))
            }
            // A clause in parentheses goes with its closing one.
            if let last = found.last, text[whole].hasSuffix(")") {
                found[found.count - 1].cut = last.cut.lowerBound..<whole.upperBound
            }
            if !found.isEmpty { return found }
            from = m.range.location + 1
        }
        return []
    }
    /// What follows the noun of a request to start a session: the end, a mark, or a word that takes the request on
    /// ("to", "in", "for", "about", a settings clause), not another noun: "create a chat widget" and "create a session
    /// manager" are features to build. A mark ends it only standing apart: a stop, comma, colon or the like followed by a
    /// space or the end, a dash or an opening parenthesis after a space. Joined to the noun it makes a word: "session-based",
    /// "session.json" and "session:json" are names, not the end of a request.
    static let requestBoundary =
        #"(?=[ \t]*(?:$|\n|[,:;.!?](?=\s|$))|[ \t]+(?:[\-–—](?=[ \t])|\()|[ \t]+(?:(?:to|in|on|inside|for|about|and|then|that|at)\b|(?:with|using|use|on)\s+(?:the\s+)?(?:opus|sonnet|haiku|fable|low|medium|high|xhigh|max|effort)\b))"#
    static let startPhrase =
        #"^(?:(?:please|pls|hey|can\s+you|could\s+you|i\s+want\s+you\s+to|i'd\s+like\s+you\s+to)[,\s]+)?(?:(?:start|open|create|launch|spin\s+up|kick\s+off|begin)\s+(?:up\s+)?(?:an?\s+|the\s+|one\s+)?(?:new\s+|fresh\s+)?(?:claude\s+)?(?:session|chat|conversation)|(?:in\s+)?(?:an?\s+)?(?:new|fresh)\s+(?:claude\s+)?(?:session|chat|conversation))"# + requestBoundary

    /// `joining`: the words either side of what is taken out are tidied where they meet (one space between words, none
    /// before punctuation or a line's end); nothing else in the text is touched (code keeps its indentation and spacing).
    private static func strip(_ pattern: String, from text: inout String, all: Bool = false, joining: Bool = false) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        var changed = false
        repeat {
            guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range, in: text), !r.isEmpty else { return changed }
            let at = text.distance(from: text.startIndex, to: r.lowerBound)
            text.removeSubrange(r)
            if joining { join(&text, at: at) }
            changed = true
        } while all
        return changed
    }

    /// The spaces where a clause was taken out (at `offset`): one between two words, none at a line's start or end or
    /// before punctuation.
    private static func join(_ text: inout String, at offset: Int) {
        let i = text.index(text.startIndex, offsetBy: offset)
        var end = i
        while end < text.endIndex, text[end] == " " || text[end] == "\t" { text.formIndex(after: &end) }
        guard end > i else { return }
        let before = i > text.startIndex ? text[text.index(before: i)] : nil
        let after = end < text.endIndex ? text[end] : nil
        let between = (before.map { !$0.isWhitespace } ?? false) && (after.map { !$0.isWhitespace && !",.;:!?)]}".contains($0) } ?? false)
        text.replaceSubrange(i..<end, with: between ? " " : "")
    }

    /// After a project named in the request to start a session: the request goes on ("to …", ", with opus", ":") or ends.
    static let goesOn = #"(?=[ \t]*(?:$|\n|[,:;.!?\-–—]|(?:to|and|then|with|using|at)\b))"#
    static let negations: Set<String> = [
        "no", "not", "never", "none", "nothing", "nobody", "nowhere", "neither", "nor", "without", "dont", "don't", "cannot",
        "can't", "cant", "won't", "wont", "stop", "avoid",
    ]

    /// What a new session is for, from the words that asked for it: the request to start one ("start a (new) session (in X)",
    /// "new chat:", "open a session to"), its model and effort settings, and a leading @project (already a pill) are taken
    /// out; the rest stays verbatim, not capitalised or reworded. Empty when nothing is left ("start a session in lookout").
    /// `pills`: where the @project pills are in `text` (`RouterContext.pills`): the only tags taken out (any other @word, a
    /// decorator like `@MainActor`, is the task's own). `projects`: names the project goes by, for "in <project>" in the
    /// request to start the session (one word each: a name can't hold words of yours).
    static func task(from text: String, pills: [Range<Int>] = [], projects: [String] = []) -> String {
        // Each pill stands as one character of its own while the request is taken apart, and is put back after.
        let (masked, pilled) = masking(text, pills)
        // The request is taken from the front of the text only, and only within its envelope (worked out once, on the text
        // as written): past it is the task's own, kept exactly (a pasted line's indentation, "// use opus to reproduce").
        let body = pastPillLine(masked)
        var t = String(body.drop(while: { $0 == " " || $0 == "\t" }))
        let whole = t.count
        let request = max(0, envelope(body).count - (body.count - whole))
        var inRequest: Bool { whole - t.count < request }
        func tidy() { if inRequest { _ = strip(#"^[ \t,:;\-–—]*"#, from: &t) } }
        // A name that is a word of negation ("no", "never") is never taken out by its words: only its pill is.
        let names = projects.filter { !$0.isEmpty && !$0.contains(where: \.isWhitespace) && !negations.contains($0.lowercased()) }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let tag = #"[\x{E000}-\x{F8FF}]"#
        while strip("^" + tag, from: &t) { tidy() }
        let started = strip(startPhrase, from: &t)
        // Each of the model and the effort as `SessionSettings.parse` reads it (`settings(in:)`), the first asked for: only
        // that clause goes.
        var asked: Set<String> = []
        func setting(_ clause: Substring) -> String {
            clause.range(of: #"\b(?:\#(models))\b"#, options: [.regularExpression, .caseInsensitive]) != nil ? "model" : "effort"
        }
        func takeSetting() -> Bool {
            guard let r = t.range(of: "^" + settingClause, options: [.regularExpression, .caseInsensitive]), !r.isEmpty,
                  asked.insert(setting(t[r])).inserted else { return false }
            t.removeSubrange(r)
            return true
        }
        // Settings before the task: after the request to start a session (and where), or opening the message ("with opus
        // fix the tests").
        if started || t.range(of: #"^(?:with|using|use)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            // A project by its words only right after "in", and only where the request goes on after it ("in lookout to …",
            // "in lookout, with opus", the end): "in case the build breaks" and "on no account" are the task's.
            let suffix = #"(?:\s+(?:project|repo|repository|folder))?"#
            let named = names.isEmpty ? "" : #"|^in\s+(?:the\s+)?(?:\#(names))(?![\w./-])\#(suffix)\#(goesOn)"#
            var moved = true
            while moved, inRequest {
                tidy()
                moved = (started && strip(#"^(?:in|on|for|inside)\s+(?:the\s+)?\#(tag)\#(suffix)(?![\w])\#(named)"#, from: &t))
                    || takeSetting()
                    || (started && strip("^" + tag, from: &t))
            }
            tidy()
            if inRequest { _ = strip(#"^(?:to|and|then|that)\s+"#, from: &t) }
        }
        // The settings clause the request's sentence ends with ("fix the tests with opus, low effort"): the plugin applies
        // them, the session never reads them. Never one in the task's own words ("a toggle for high effort"), nor in the
        // code, quotes or lines after the request.
        let left = max(0, request - (whole - t.count))
        let end = t.index(t.startIndex, offsetBy: min(left, t.count))
        var head = String(t[..<end])
        let cuts = trailingSettings(head).filter { asked.insert(setting(Substring($0.words))).inserted }.map(\.cut)
        // Only where a settings clause was cut from the very end of the text is a comma or semicolon left there the request's.
        let endsAtCut = !cuts.isEmpty && end == t.endIndex
        for r in cuts.reversed() {
            let at = head.distance(from: head.startIndex, to: r.lowerBound)
            head.removeSubrange(r)
            join(&head, at: at)
        }
        t = head + t[end...]
        if started || !asked.isEmpty { tidy() }
        // What is left starts after the request's line breaks: the first line of code under it keeps its indentation.
        // Commas and semicolons go only at a boundary where the request or a settings clause was taken out; the task's own
        // punctuation (a pasted line's trailing comma) stays as written.
        var task = RouterModel.sendable(String(t.drop(while: { $0 == " " || $0 == "\t" })))
        while let last = task.last, last.isWhitespace || (endsAtCut || task.isEmpty) && (last == "," || last == ";") { task.removeLast() }
        // Nothing taken out: the words as written, the first line's indentation kept (code).
        if task == masked.trimmingCharacters(in: .whitespacesAndNewlines) { task = body }
        return String(task.map { c in c.unicodeScalars.first.flatMap { pilled[$0] } ?? String(c) }.joined())
    }

    /// Where a new session's model and effort may be asked for (`envelope`), past a first line of nothing but the message's
    /// @project pills ("@lookout⏎start a session with opus:⏎fix login"): the one reading of the request, for its task and
    /// its settings alike.
    static func request(_ text: String, pills: [Range<Int>] = []) -> String {
        envelope(pastPillLine(masking(text, pills).0))
    }

    /// `RouterModel.sendable(masked)`, without a first line that holds only pills (`masking`).
    private static func pastPillLine(_ masked: String) -> String {
        let body = RouterModel.sendable(masked)
        guard let r = body.range(of: #"^[ \t]*(?:[\x{E000}-\x{F8FF}][ \t,:;\-–—]*)+\r?\n"#, options: .regularExpression) else { return body }
        return RouterModel.sendable(String(body[r.upperBound...]))
    }

    /// Where a message's model and effort may be asked for: its first line up to the end of its first sentence, past its
    /// inline code, double-quoted spans and `@router` asides (never read for settings: `wordsOnly`), stopping at a quote or
    /// code left open; nothing when it starts as code, a quote or an indented line. What follows is the task's, as written.
    static func envelope(_ text: String) -> String {
        let chars = Array(text)
        let code = Addressing.codeMask(chars), quoted = Addressing.quoteMask(chars, code: code)
        var aside = [Bool](repeating: false, count: chars.count)
        for r in Addressing.asides(chars) { for k in r { aside[k] = true } }
        var i = 0
        while i < chars.count, chars[i].isNewline { i += 1 }
        guard i < chars.count, chars[i] != " ", chars[i] != "\t", chars[i] != ">", !"\"`“‘".contains(chars[i]) else { return "" }
        var end = i
        while end < chars.count {
            let c = chars[end]
            if c.isNewline { break }
            if code[end] || quoted[end] || aside[end] { end += 1; continue }
            if "\"`“‘".contains(c) { break }
            if c == "'", end == 0 || !chars[end - 1].isLetter { break }
            if ".!?".contains(c), end + 1 == chars.count || chars[end + 1].isWhitespace { end += 1; break }
            end += 1
        }
        return String(chars[..<end])
    }

    /// `text` with each pill (an "@name" at its place) made one private character, and what each stands for. A text that
    /// holds private characters of its own is left as it is (its pills aren't tags then: the words go whole), and a pill in
    /// code is the code's text (`Addressing.outsideCode`).
    private static func masking(_ text: String, _ pills: [Range<Int>]) -> (String, [Unicode.Scalar: String]) {
        let isPrivate = { (s: Unicode.Scalar) in (0xE000...0xF8FF).contains(s.value) }
        var chars = Array(text)
        let pills = Addressing.outsideCode(chars, pills)
        guard !pills.isEmpty, !text.unicodeScalars.contains(where: isPrivate) else { return (text, [:]) }
        var pilled: [Unicode.Scalar: String] = [:]
        var last = Int.max
        for (n, r) in pills.sorted(by: { $0.lowerBound > $1.lowerBound }).enumerated()
        where r.lowerBound >= 0 && r.upperBound <= min(chars.count, last) && !r.isEmpty && chars[r.lowerBound] == "@" {
            guard let mark = Unicode.Scalar(0xE000 + UInt32(n)) else { break }
            pilled[mark] = String(chars[r])
            chars.replaceSubrange(r, with: [Character(mark)])
            last = r.lowerBound
        }
        return (String(chars), pilled)
    }

    /// The CLI session: no model call, and the least left in it (the rename, which is also its title). Its permission mode
    /// isn't set here: the app gives an imported session the one in your settings (`permissions.defaultMode`).
    static func bootstrapArguments(uuid: String, title: String) -> [String] {
        ["-p", "/rename \(title)", "--session-id", uuid, "--output-format", "json", "--setting-sources", ""]
    }

    static func importURL(uuid: String) -> URL? {
        var components = URLComponents(string: "claude://resume")
        components?.queryItems = [URLQueryItem(name: "session", value: uuid)]
        return components?.url
    }

    /// One line, a few words: what the app shows as the title.
    static func cleanTitle(_ title: String) -> String {
        let words = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.prefix(80))
    }

    /// How long a new session has to run in the Claude app before it is reported: the import takes a second, its process
    /// a few more.
    static let processWait: TimeInterval = 30
    /// How long a held part of a divided message waits for you to send it (`RouterDispatcher.heldPartWait`).
    static let heldWait: TimeInterval = 30 * 60

    /// The Claude app has the session (it imported it) but doesn't run it: its process isn't there to take a message
    /// yet. Usually the app is at its limit of sessions run at once (its CLI governor: one per 3 GB of memory, at least
    /// 6): an imported session's start is then given up, not retried, and opening it in the app doesn't start it either.
    /// Fjord starts it through its relay (`RouterTools.wake`). Fjord can't count the app's sessions as the app does, so it
    /// never says the app is full.
    struct NotRunning: LocalizedError, Equatable {
        /// `local_<uuid>`.
        var sessionID: String
        var errorDescription: String? {
            "The new session is in the Claude app, but the app hasn't run it yet" + Self.reason
        }
        static let reason = ": Fjord starts it through its relay, nothing needs opening in the app"
    }

    /// Whether the Claude app has `local_<uuid>` (imported): its file under the app's sessions folder (account/org/<id>.json).
    nonisolated static func imported(_ uuid: String, root: URL = Claude.sessionsDir) -> Bool {
        let fm = FileManager.default, name = "local_\(uuid).json"
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? []
            where fm.fileExists(atPath: org.appendingPathComponent(name).path) { return true }
        }
        return false
    }

    /// Waits (polling the registry off the main thread) for the app's process of `local_<uuid>`; its peer name.
    /// `check` is asked between polls (Stop, a reset): it throws to end the wait. `imported` says whether the app has the
    /// session: one it has but doesn't run by `timeout` throws `NotRunning`; one it never got, `RouterTools.Failure`.
    static func waitForPeer(uuid: String, dir: URL, timeout: TimeInterval = processWait,
                            imported: @escaping @Sendable () -> Bool = { false },
                            check: @MainActor () throws -> Void = {}) async throws -> String {
        let host = "local_\(uuid)"
        let deadline = Date().addingTimeInterval(timeout)
        var there = false
        repeat {
            try Task.checkCancellation()
            try await check()
            let (peers, has) = await OffMain.run { (ClaudePeers.read(dir: dir), imported()) }
            if let peer = peers[host] { return peer.name }
            there = has
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        } while true
        if there { throw NotRunning(sessionID: host) }
        throw RouterTools.Failure("The Claude app didn't open the new session in \(Int(RouterTools.bounded(timeout))) s")
    }
}
