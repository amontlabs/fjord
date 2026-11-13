import Foundation

// One structured model call through Claude Code on your subscription (`claude -p`): a system prompt, the user text on stdin
// and a JSON schema, answered as the typed JSON. No tools, no settings, no MCP, no session kept, thinking off. The router's
// decider (Sonnet), its thread cards and project purposes (Haiku) use it, and Router v2's verdicts stream with the same flags (`ClaudeStream`). Every call's usage (`--output-format json`: its tokens
// and `total_cost_usd`) goes to the model-usage log (`ModelUsageLog`).

/// What a call cost, in tokens, and Claude Code's own cost for it (at API prices).
struct ModelUsage: Equatable, Sendable, Codable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    /// `total_cost_usd`; nil when the answer didn't say (Jev's comes from his price).
    var costUSD: Double?
}

enum ClaudePrint {
    /// Runs the program: Claude Code's binary, its arguments, stdin, the deadline. Tests stand in for it.
    typealias Runner = @Sendable (_ binary: String, _ arguments: [String], _ input: Data, _ timeout: TimeInterval) async throws -> OneShot.Output

    struct Reply: Sendable {
        /// The typed answer, as JSON.
        var json: Data
        var usage: ModelUsage
        var latency: TimeInterval
    }

    struct Failure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    /// Thinking off for a single answer: the setting Claude Code reads (no other settings load).
    static let noThinking = #"{"alwaysThinkingEnabled":false}"#

    /// The arguments of one call, in a fixed order. `streaming`: the answer as it is written (`ClaudeStream`), one JSON
    /// line per event, the typed answer's pieces included.
    static func arguments(model: String, system: String, schema: String, effort: String?, streaming: Bool = false) -> [String] {
        var out = ["-p", "--model", model, "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence"]
        out += streaming ? ["--output-format", "stream-json", "--verbose", "--include-partial-messages"] : ["--output-format", "json"]
        out += ["--settings", noThinking]
        if let effort { out += ["--effort", effort] }
        out += ["--json-schema", schema, "--system-prompt", system]
        return out
    }

    /// The typed answer and its usage, from what `claude -p --output-format json` printed.
    static func parse(_ output: OneShot.Output) throws -> (json: Data, usage: ModelUsage) {
        guard let obj = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any] else {
            let why = String(decoding: output.stderr.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: why.isEmpty ? "Claude Code's answer wasn't JSON (exit \(output.status))" : "Claude Code: \(why)")
        }
        let usage = usage(obj)
        if obj["is_error"] as? Bool == true {
            throw Failure(message: "Claude Code: " + String((obj["result"] as? String ?? "the call failed").prefix(200)))
        }
        guard let typed = obj["structured_output"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: typed) else {
            throw Failure(message: "Claude Code's answer had no structured output")
        }
        return (data, usage)
    }

    /// A result object's tokens and cost.
    static func usage(_ obj: [String: Any]) -> ModelUsage {
        let u = obj["usage"] as? [String: Any] ?? [:]
        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        return ModelUsage(inputTokens: n("input_tokens"), outputTokens: n("output_tokens"),
                          cacheReadTokens: n("cache_read_input_tokens"), cacheCreationTokens: n("cache_creation_input_tokens"),
                          costUSD: (obj["total_cost_usd"] as? NSNumber)?.doubleValue)
    }

    static let liveRunner: Runner = { binary, arguments, input, timeout in
        let home = FileManager.default.temporaryDirectory
        return try await OneShot.run(binary, arguments, cwd: home, input: input, timeout: timeout)
    }

    /// One call. `role` names it in the usage log (`ModelUsageLog.Role`).
    static func call(binary: String, model: String, system: String, user: String, schema: String, effort: String? = nil,
                     timeout: TimeInterval, role: ModelUsageLog.Role, log: ModelUsageLog?, runner: Runner = liveRunner) async throws -> Reply {
        let start = Date()
        let output = try await runner(binary, arguments(model: model, system: system, schema: schema, effort: effort), Data(user.utf8), timeout)
        let (json, usage) = try parse(output)
        log?.record(role: role, model: model, usage)
        return Reply(json: json, usage: usage, latency: Date().timeIntervalSince(start))
    }
}

// MARK: - The usage log

/// Every model call the Router makes, one JSON line each in Application Support/Fjord/model-usage.jsonl (yours alone): when,
/// which role and model, its tokens and its cost at API prices. Settings › T3 Code sums it for today, 7 days and all time.
final class ModelUsageLog: @unchecked Sendable {
    enum Role: String, Codable, CaseIterable, Sendable {
        case decider, cards, brief, jev, verdict, purpose, summary, items
        var title: String {
            switch self {
            case .decider: "Sonnet decider"
            case .cards: "Haiku thread cards"
            // The old brief page's calls, still in the log's history.
            case .brief: "Haiku briefs"
            case .jev: "Jev"
            case .verdict: "Haiku verdicts"
            case .purpose: "Haiku project purposes"
            case .summary: "Haiku working summaries"
            case .items: "Sonnet open items"
            }
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        var at: Date
        var role: Role
        var model: String
        var usage: ModelUsage
    }

    /// API price estimate per million tokens (input, cache read, cache write, output), for a call whose answer gave no cost.
    static let prices: [String: (input: Double, read: Double, write: Double, output: Double)] = [
        "claude-sonnet-5-5": (2.0, 0.2, 2.5, 10.0),
        "claude-haiku-5-5": (0.1, 0.01, 0.125, 0.5),
        // Jev: input only (J3: $0.042 per million, output free).
        "jev": (0.042, 0.042, 0.042, 0),
    ]

    static func estimate(model: String, _ u: ModelUsage) -> Double {
        guard let p = prices[model] ?? prices[model.hasPrefix("jev") ? "jev" : ""] else { return 0 }
        return (Double(u.inputTokens) * p.input + Double(u.cacheReadTokens) * p.read + Double(u.cacheCreationTokens) * p.write
                + Double(u.outputTokens) * p.output) / 1e6
    }

    let url: URL
    private let queue = DispatchQueue(label: "fjord.model-usage")
    let clock: @Sendable () -> Date

    init(url: URL, clock: @escaping @Sendable () -> Date = { Date() }) { self.url = url; self.clock = clock }

    /// The live log; nil in a test run or a demo (no paths). Set once by the store at launch.
    nonisolated(unsafe) static var shared: ModelUsageLog?

    static func live(_ paths: RouterPaths?) -> ModelUsageLog? {
        paths.map { ModelUsageLog(url: $0.support.appendingPathComponent("model-usage.jsonl")) }
    }

    func record(role: Role, model: String, _ usage: ModelUsage) {
        var u = usage
        if u.costUSD == nil { u.costUSD = Self.estimate(model: model, usage) }
        let entry = Entry(at: clock(), role: role, model: model, usage: u)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard var data = try? enc.encode(entry) else { return }
        data.append(0x0A)
        queue.async { [url] in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    func flush() { queue.sync {} }

    func entries() -> [Entry] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return data.split(separator: 0x0A).compactMap { try? dec.decode(Entry.self, from: Data($0)) }
        }
    }

    // MARK: Totals

    struct Totals: Equatable, Sendable {
        var calls = 0
        var input = 0
        var cacheRead = 0
        var cacheWrite = 0
        var output = 0
        var cost = 0.0

        mutating func add(_ u: ModelUsage) {
            calls += 1; input += u.inputTokens; cacheRead += u.cacheReadTokens; cacheWrite += u.cacheCreationTokens
            output += u.outputTokens; cost += u.costUSD ?? 0
        }
    }

    enum Span: String, CaseIterable, Sendable { case today = "Today", week = "Last 7 days", all = "All time" }

    /// Each role's totals for each span: today from local midnight, the last 7 days, all time.
    static func totals(_ entries: [Entry], now: Date, calendar: Calendar = .current) -> [Span: [Role: Totals]] {
        let midnight = calendar.startOfDay(for: now)
        let week = now.addingTimeInterval(-7 * 86400)
        var out: [Span: [Role: Totals]] = [:]
        for span in Span.allCases { out[span] = [:] }
        for e in entries {
            out[.all]![e.role, default: Totals()].add(e.usage)
            if e.at >= week { out[.week]![e.role, default: Totals()].add(e.usage) }
            if e.at >= midnight { out[.today]![e.role, default: Totals()].add(e.usage) }
        }
        return out
    }
}
