import Foundation

// One `claude -p` call whose typed answer is read as it is written (docs/design/router-v2/IMPLEMENTATION.md 1.4): the
// process's stdout as whole lines (`ClaudeStream.run`), each line of `--output-format stream-json --verbose
// --include-partial-messages` read for the `StructuredOutput` call's growing input and the closing `result`
// (`ClaudeStream.Reader`), and that input read field by field as it closes, a string field as it grows (`PartialJSON`).
// The flags are `ClaudePrint`'s, with the streaming format.

enum ClaudeStream {
    /// Runs the program and yields its stdout line by line as the lines come, without their newline. Ending the stream
    /// early (the consumer's task cancelled, or it stops iterating) terminates the process. Tests stand in for it.
    typealias Runner = @Sendable (_ binary: String, _ arguments: [String], _ input: Data, _ timeout: TimeInterval) -> AsyncThrowingStream<Data, Error>

    static let liveRunner: Runner = { binary, arguments, input, timeout in
        run(binary: binary, arguments: arguments, input: input, timeout: timeout)
    }

    /// The live runner: `OneShot` with its output read as it comes. One deadline covers the run; a non-zero exit ends the
    /// stream with `ClaudePrint.Failure` (after the lines it printed, so a `result` line saying why is read first).
    static func run(binary: String, arguments: [String], input: Data, timeout: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let lines = Lines()
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let out = try await OneShot.run(binary, arguments, cwd: FileManager.default.temporaryDirectory, input: input,
                                                    timeout: timeout,
                                                    onOutput: { chunk in for line in lines.feed(chunk) { continuation.yield(line) } })
                    if let last = lines.finish() { continuation.yield(last) }
                    if out.status != 0 {
                        let why = String(decoding: out.stderr.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.finish(throwing: ClaudePrint.Failure(message: why.isEmpty ? "Claude Code exited \(out.status)" : "Claude Code: \(why)"))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Bytes into whole lines, kept between chunks; one thread feeds it at a time, the lock is for the hand-over.
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var splitter = LineSplitter()
        func feed(_ chunk: Data) -> [Data] { lock.withLock { splitter.feed(chunk) } }
        func finish() -> Data? { lock.withLock { splitter.finish() } }
    }
}

// MARK: - Lines

/// Splits bytes into lines at `\n`, a line cut across chunks waited for. A line longer than `maxLine` is dropped whole
/// (no stream-json line is near it), so a runaway program can't grow the buffer.
struct LineSplitter {
    static let maxLine = 1 << 20

    private var line = Data()
    private var skipping = false

    mutating func feed(_ data: Data) -> [Data] {
        var out: [Data] = []
        var rest = data[...]
        while let end = rest.firstIndex(of: 0x0A) {
            let piece = rest[rest.startIndex..<end]
            if skipping {
                skipping = false
            } else if line.count + piece.count <= Self.maxLine {
                line.append(contentsOf: piece)
                if !line.isEmpty { out.append(line) }
            }
            line = Data()
            rest = rest[rest.index(after: end)...]
        }
        if !skipping {
            if line.count + rest.count > Self.maxLine {
                line = Data()
                skipping = true
            } else {
                line.append(contentsOf: rest)
            }
        }
        return out
    }

    /// What was left without a newline at the end.
    mutating func finish() -> Data? {
        defer { line = Data(); skipping = false }
        return skipping || line.isEmpty ? nil : line
    }
}

// MARK: - The typed answer as it is written

/// Reads a JSON object as its text grows (the `StructuredOutput` call's `input_json_delta` pieces), top-level fields only:
/// each field once its value is whole (`.field`, its raw JSON), and a string field while it is written (`.growing`, its
/// decoded text cut after the last whole word, given again only when that grows). Pure, incremental: each character is
/// scanned once, a string decoded once.
struct PartialJSON {
    enum Piece: Equatable, Sendable {
        /// A top-level field whose value is whole: the key and the value's raw JSON.
        case field(String, raw: String)
        /// A top-level string being written: the key and its words so far, cut after the last whole word.
        case growing(String, String)
    }

    private enum Phase { case start, beforeKey, key, colon, beforeValue, string, nested, primitive, end }

    private var text: [Unicode.Scalar] = []
    private var at = 0
    private var phase = Phase.start
    private var escaped = false
    /// Where the key or value being read started (its first scalar: the quote, bracket or digit).
    private var mark = 0
    private var key = ""
    /// Inside a nested value: its depth and whether a string in it is open.
    private var depth = 0
    private var nestedString = false
    /// A string value's decoded text so far, how far it is decoded, and the words last given.
    private var decoded = String.UnicodeScalarView()
    private var decodedTo = 0
    private var shown = ""

    init() {}

    /// Takes the next piece of the object's text; the fields it closed or grew, in order.
    mutating func feed(_ more: String) -> [Piece] {
        text.append(contentsOf: more.unicodeScalars)
        var out: [Piece] = []
        while at < text.count, phase != .end {
            let c = text[at]
            switch phase {
            case .start:
                if c == "{" { phase = .beforeKey }
            case .beforeKey:
                if c == "\"" { phase = .key; mark = at; escaped = false } else if c == "}" { phase = .end }
            case .key:
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" {
                    key = Self.decodeWhole(text[mark...at]) ?? ""
                    phase = .colon
                }
            case .colon:
                if c == ":" { phase = .beforeValue }
            case .beforeValue:
                if c.properties.isWhitespace { break }
                mark = at
                switch c {
                case "\"":
                    phase = .string
                    escaped = false
                    decoded = String.UnicodeScalarView()
                    decodedTo = at + 1
                    shown = ""
                case "{", "[":
                    phase = .nested
                    depth = 1
                    nestedString = false
                    escaped = false
                default:
                    phase = .primitive
                }
            case .string:
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" {
                    out.append(.field(key, raw: String(String.UnicodeScalarView(text[mark...at]))))
                    phase = .beforeKey
                }
            case .nested:
                if nestedString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { nestedString = false }
                } else if c == "\"" {
                    nestedString = true
                } else if c == "{" || c == "[" {
                    depth += 1
                } else if c == "}" || c == "]" {
                    depth -= 1
                    if depth == 0 {
                        out.append(.field(key, raw: String(String.UnicodeScalarView(text[mark...at]))))
                        phase = .beforeKey
                    }
                }
            case .primitive:
                if c == "," || c == "}" || c.properties.isWhitespace {
                    out.append(.field(key, raw: String(String.UnicodeScalarView(text[mark..<at]))))
                    phase = c == "}" ? .end : .beforeKey
                }
            case .end:
                break
            }
            at += 1
        }
        if phase == .string, let words = growWords() { out.append(.growing(key, words)) }
        return out
    }

    /// The open string's words so far, when they grew past a word's end.
    private mutating func growWords() -> String? {
        decodeOpen()
        guard let lastSpace = decoded.lastIndex(where: { $0.properties.isWhitespace }) else { return nil }
        let words = String(String.UnicodeScalarView(decoded[..<lastSpace])).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words != shown else { return nil }
        shown = words
        return words
    }

    /// Decodes the open string from where it was left to the end of the text, stopping before an escape cut off.
    private mutating func decodeOpen() {
        var i = decodedTo
        while i < text.count {
            let c = text[i]
            guard c == "\\" else { decoded.append(c); i += 1; continue }
            guard i + 1 < text.count else { break }
            let e = text[i + 1]
            switch e {
            case "n": decoded.append("\n")
            case "t": decoded.append("\t")
            case "r": decoded.append("\r")
            case "b": decoded.append("\u{8}")
            case "f": decoded.append("\u{C}")
            case "u":
                guard let unit = Self.hex4(text, i + 2) else { decodedTo = i; return }
                guard (0xD800..<0xDC00).contains(unit) else {
                    decoded.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                    i += 6
                    continue
                }
                // A high surrogate waits for its low one; without one it is a replacement character.
                guard i + 12 <= text.count else { decodedTo = i; return }
                if text[i + 6] == "\\", text[i + 7] == "u", let low = Self.hex4(text, i + 8), (0xDC00..<0xE000).contains(low),
                   let pair = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) {
                    decoded.append(pair)
                    i += 12
                } else {
                    decoded.append("\u{FFFD}")
                    i += 6
                }
                continue
            default: decoded.append(e)
            }
            i += 2
        }
        decodedTo = i
    }

    private static func hex4(_ s: [Unicode.Scalar], _ at: Int) -> UInt32? {
        guard at + 4 <= s.count else { return nil }
        return UInt32(String(String.UnicodeScalarView(s[at..<at + 4])), radix: 16)
    }

    private static func decodeWhole(_ quoted: ArraySlice<Unicode.Scalar>) -> String? {
        string(String(String.UnicodeScalarView(quoted)))
    }

    // MARK: Reading a field's raw value

    static func value(_ raw: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) }
    static func string(_ raw: String) -> String? { value(raw) as? String }
    static func strings(_ raw: String) -> [String]? { (value(raw) as? [Any])?.compactMap { $0 as? String } }
}

// MARK: - The stream's lines

extension ClaudeStream {
    /// How a call ended: its `result` line.
    struct End: Equatable, Sendable {
        /// The typed answer (`structured_output`), as JSON; nil when there was none.
        var json: Data?
        var usage: ModelUsage
        /// Why it failed, when it did (`is_error`, or no typed answer).
        var error: String?
        /// The API's HTTP status when the call failed on it (`api_error_status`): 429 is a rate limit.
        var status: Int?
    }

    /// Reads a `stream-json` run's lines: the typed answer's pieces as they come, the API's retries, the end. A line it
    /// doesn't know is passed over. Only the first `StructuredOutput` call is followed; the end's answer is the whole one.
    struct Reader {
        enum Output: Equatable, Sendable {
            case piece(PartialJSON.Piece)
            /// Claude Code is retrying the API (`system`/`api_retry`): its HTTP status and the wait it named.
            case retry(status: Int?, after: TimeInterval?)
            case end(End)
        }

        private var answer: Int?
        private var answered = false
        private var json = PartialJSON()

        init() {}

        mutating func read(_ line: Data) -> [Output] {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = obj["type"] as? String else { return [] }
            switch type {
            case "stream_event":
                guard let event = obj["event"] as? [String: Any], let kind = event["type"] as? String,
                      obj["parent_tool_use_id"] as? String == nil else { return [] }
                let index = event["index"] as? Int ?? -1
                switch kind {
                case "content_block_start":
                    guard !answered, answer == nil, let block = event["content_block"] as? [String: Any],
                          block["type"] as? String == "tool_use", block["name"] as? String == "StructuredOutput" else { return [] }
                    answer = index
                case "content_block_delta":
                    guard index == answer, let delta = event["delta"] as? [String: Any], delta["type"] as? String == "input_json_delta",
                          let piece = delta["partial_json"] as? String, !piece.isEmpty else { return [] }
                    return json.feed(piece).map(Output.piece)
                case "content_block_stop":
                    if index == answer { answer = nil; answered = true }
                default: break
                }
            case "system":
                guard obj["subtype"] as? String == "api_retry" else { return [] }
                let status = (obj["error_status"] as? NSNumber)?.intValue
                let after = (obj["retry_delay_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
                return [.retry(status: status, after: after)]
            case "result":
                return [.end(ClaudeStream.end(obj))]
            default: break
            }
            return []
        }
    }

    /// The end of a call from its `result` object (`--output-format json` prints the same one alone).
    static func end(_ obj: [String: Any]) -> End {
        let usage = ClaudePrint.usage(obj)
        let status = (obj["api_error_status"] as? NSNumber)?.intValue
        if obj["is_error"] as? Bool == true {
            return End(json: nil, usage: usage, error: "Claude Code: " + String((obj["result"] as? String ?? "the call failed").prefix(200)),
                       status: status)
        }
        guard let typed = obj["structured_output"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: typed, options: [.sortedKeys]) else {
            return End(json: nil, usage: usage, error: "Claude Code's answer had no structured output", status: status)
        }
        return End(json: data, usage: usage, error: nil, status: status)
    }
}
