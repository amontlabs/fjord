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

    /// `onOutput`: told of each new chunk of stdout as it is read, on the reader's thread (the stream of a `stream-json` run);
    /// the output returned is still the bounded whole.
    static func run(_ path: String, _ arguments: [String], cwd: URL, input: Data = Data(), timeout: TimeInterval,
                    handle: Handle = Handle(), onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> Output {
        try await withTaskCancellationHandler {
            // On a plain thread: the waits block it, which Swift's own pool of threads must not be.
            try await withCheckedThrowingContinuation { (finished: CheckedContinuation<Output, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    finished.resume(with: Result { try blocking(path, arguments, cwd: cwd, input: input, timeout: timeout, handle, onOutput) })
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func blocking(_ path: String, _ arguments: [String], cwd: URL, input: Data, timeout: TimeInterval,
                                 _ handle: Handle, _ onOutput: (@Sendable (Data) -> Void)?) throws -> Output {
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
        out.onChunk = onOutput
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
        /// Told of each chunk read, outside the lock, the last drain's included.
        var onChunk: (@Sendable (Data) -> Void)?

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
            if let onChunk { onChunk(Data(bytes[0..<n])) }
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
    /// What the session gets as your words, when `text` is that signed for its plugin (the chat shows this, never the
    /// header).
    var body: String? = nil
    /// A guest-delivered message never falls back to the controller's Claude peer channel.
    var guestLocation: SessionLocation? = nil
    /// The Claude app's id for the target (`local_<uuid>`), which the app's send tool takes.
    var local: String? = nil
    /// The target has no process now: the app starts it with the message (its plugin comes up with it), so there is no plugin
    /// presence to check before it goes.
    var asleep = false
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
