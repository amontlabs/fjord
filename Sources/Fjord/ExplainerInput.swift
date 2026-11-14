import Foundation

// What the explainer's creator reads after its instructions: the question, the answer and the turn's activity, as
// `<ask>` and `<thread>` (docs/design/router-visuals/SHOWME.md §4). A port of `EX/build_case2.py` onto `T3Projection`, the
// projection Fjord already reads, rather than T3's sqlite; its layout is the Python's byte for byte, so the eval moments'
// `user.md` serve as golden files (ExplainerInputTests). Pure: no clock, no files.

enum ExplainerInput {
    struct Input: Equatable, Sendable {
        /// `<ask>…</ask>` and `<thread …>…</thread>`, ending in a newline. The engine puts `<ticket>` before it.
        var text: String
        /// The question, redacted, as the player's page shows it.
        var askText: String
    }

    /// The focus turn's limit, and every other turn's (the Python's values).
    static let focusLimit = 7_000, turnLimit = 1_500
    static let activityWindow: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - ask: the id of your message it explains; nil (Show me on a card) is the last of yours before the latest reply.
    ///   - project: the project's name as T3 titles it.
    ///   - zone: the clock the `at=` times are read in (the Mac's).
    ///   - user: the short name swapped for `user` in every text.
    static func make(_ p: T3Projection, project: String, ask: String?, zone: TimeZone = .current,
                     user: String = NSUserName()) -> Input? {
        // A message queued behind a turn (⌥Return) is stamped when it was sent, mid-turn; it reaches the agent when its run
        // starts. Ordered by that delivery, the turn it waited behind comes before it, and its answer is its own run's.
        var delivered: [String: Date] = [:]
        for run in p.runs {
            if let m = run.userMessageId, let at = run.startedAt?.date { delivered[m] = at }
        }
        let messages = p.messages.filter { $0.role == "user" || $0.role == "assistant" }
            .map { m in (date: max(m.createdAt?.date ?? .distantPast, delivered[m.id] ?? .distantPast), message: m) }
            .enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        // Yours: T3's typed fields say what a message is, with no word rule (the Python's "doesn't start with `<`").
        func yours(_ m: T3Message) -> Bool {
            m.role == "user" && m.createdBy == "user" && m.notification == nil && m.delegatedTaskIds == nil
        }
        let askIndex: Int
        if let ask {
            guard let i = messages.firstIndex(where: { $0.message.id == ask }), yours(messages[i].message) else { return nil }
            askIndex = i
        } else {
            guard let lastReply = messages.lastIndex(where: { $0.message.role == "assistant" }),
                  let i = messages[..<lastReply].lastIndex(where: { yours($0.message) }) else { return nil }
            askIndex = i
        }
        let end = messages[(askIndex + 1)...].firstIndex { yours($0.message) } ?? messages.endIndex
        let shown = messages[..<end]

        // Turns: yours one each; the agent's consecutive messages merged, as one reply (T3's own messages in between skipped).
        struct Turn { var you: Bool; var at: Date; var text: String; var isAsk: Bool }
        var turns: [Turn] = []
        for (i, m) in shown.enumerated() {
            if yours(m.message) {
                turns.append(Turn(you: true, at: m.date, text: m.message.text, isAsk: i == askIndex))
            } else if m.message.role == "assistant" {
                if let last = turns.last, !last.you { turns[turns.count - 1].text += "\n\n" + m.message.text }
                else { turns.append(Turn(you: false, at: m.date, text: m.message.text, isAsk: false)) }
            }
        }
        guard let iask = turns.lastIndex(where: \.isAsk) else { return nil }
        // One exchange before, the ask, the answer.
        turns = Array(turns[max(0, iask - 2)..<min(turns.count, iask + 2)])
        guard let focus = turns.lastIndex(where: { !$0.you }), let first = turns.first,
              let answerEnd = shown.last?.date else { return nil }
        let since = first.at.addingTimeInterval(-activityWindow)

        let clock = minutes(zone)
        let redact = { (s: String) in redacted(s, user: user) }
        var lines = ["<ask>\(escaped(trimmed(redact(messages[askIndex].message.text))))</ask>",
                     "<thread name=\"\(escaped(redact(p.thread.title)))\" project=\"\(escaped(project))\">"]
        for (i, t) in turns.enumerated() {
            var text = trimmed(redact(t.text))
            let limit = i == focus ? focusLimit : turnLimit
            if text.unicodeScalars.count > limit { text = String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit))) + " …" }
            let mark = i == focus ? " focus=\"true\"" : t.isAsk ? " ask=\"true\"" : ""
            lines.append("  <turn by=\"\(t.you ? "you" : "agent")\" at=\"\(clock(t.at))\"\(mark)>\(escaped(text))</turn>")
        }
        let act = activity(p, since: since, until: answerEnd, clock: clock, redact: redact)
        lines.append("  <activity>")
        lines += act.map { "    " + $0 }
        lines += ["  </activity>", "</thread>"]
        return Input(text: lines.joined(separator: "\n") + "\n", askText: trimmed(redact(messages[askIndex].message.text)))
    }

    // MARK: Activity

    /// The turn's tool calls and subagents, one line each with its start time, in order; over 40, the first 12, a count,
    /// the last 20. Tool calls count when T3 last touched them inside the window (to the second, as the Python reads it).
    static func activity(_ p: T3Projection, since: Date, until end: Date, clock: (Date) -> String,
                         redact: (String) -> String) -> [String] {
        let low = since.timeIntervalSince1970.rounded(.down), high = end.timeIntervalSince1970.rounded(.down) + 1
        var act: [(Date, String)] = []
        for item in p.turnItems {
            guard let updated = item.updatedAt?.date?.timeIntervalSince1970, updated >= low, updated < high,
                  let started = item.raw.ts("startedAt")?.date else { continue }
            let line: String
            switch item.type {
            case .commandExecution:
                let input = trimmed(item.raw.str("input") ?? "")
                line = "Bash " + prefix(String(input.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""), 90)
            case .dynamicTool:
                // Python's `if inp`: no input, null, false, 0 and empty ones give no brief.
                let brief: String
                switch item.raw["input"] {
                case nil, .null?, .bool(false)?, .number(0)?, .string("")?, .array([])?, .object([:])?: brief = ""
                case let input?: brief = prefix(pythonJSON(input), 70)
                }
                line = "\(item.raw.str("toolName") ?? "None") \(brief)"
            case .fileChange:
                let name = item.raw.str("fileName").flatMap { $0.isEmpty ? nil : $0 } ?? "?"
                line = "Edit " + URL(fileURLWithPath: name).lastPathComponent
            case .webSearch: line = "Web search"
            default: continue
            }
            act.append((started, redact(line)))
        }
        for s in p.others["subagents"] ?? [] {
            guard let started = s.ts("startedAt")?.date, started >= since, started <= end else { continue }
            let tail = s.ts("completedAt")?.date.map { "→ \(clock($0))" } ?? "(still running)"
            let title = prefix(s.str("title").flatMap { $0.isEmpty ? nil : $0 } ?? "subagent", 60)
            let model = s.str("model").flatMap { $0.isEmpty ? nil : $0 } ?? "?"
            act.append((started, redact("subagent \"\(title)\" · \(model) · \(clock(started)) \(tail)")))
        }
        act.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        var out = act.map { "\(clock($0.0)) \($0.1)" }
        if out.count > 40 { out = Array(out.prefix(12)) + ["… \(out.count - 32) more …"] + Array(out.suffix(20)) }
        return out
    }

    // MARK: Text

    /// The Python's redaction (`build_case2.py`, what the evals ran on): home folders, emails, keys and tokens, `key=value`
    /// secrets, the owner's short name. Not `RouterTools.redacted`: its rule for long mixed strings cuts paths, branch
    /// names and ids the explainer needs, and this text goes to the provider that ran the thread, not to a third party.
    static func redacted(_ s: String, user: String) -> String {
        var out = s
        for (pattern, template) in patterns {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return user.isEmpty ? out : out.replacingOccurrences(of: user, with: "user")
    }

    private static let patterns: [(NSRegularExpression, String)] = [
        (#"/Users/[^/\s"']+"#, "~"),
        (#"[\w.+-]+@[\w-]+\.[\w.-]+"#, "<email>"),
        (#"\b(sk-[\w-]{8,}|gh[pousr]_\w{16,}|xox\w-[\w-]{10,}|AKIA\w{12,}|eyJ[\w-]{20,}\.[\w-]+\.[\w-]+)"#, "<token>"),
        (#"(?i)(token|secret|password|api[_-]?key)=\S+"#, "$1=<redacted>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// `<` and `>` inside text become `‹` `›`, so the input's own tags stay unambiguous.
    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
    }

    /// Python's `strip()`.
    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The first `n` code points (Python's `s[:n]`).
    static func prefix(_ s: String, _ n: Int) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.prefix(n)))
    }

    static func minutes(_ zone: TimeZone) -> (Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "HH:mm"
        return { f.string(from: $0) }
    }

    /// `json.dumps` as Python writes it (`, ` and `: `, non-ASCII as `\uXXXX`), keys sorted: T3's JSON reaches Fjord with
    /// no key order.
    static func pythonJSON(_ v: T3JSON) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n == n.rounded(), abs(n) < 9e15 { return String(Int64(n)) }
            return String(n)
        case .string(let s): return pythonString(s)
        case .array(let a): return "[" + a.map(pythonJSON).joined(separator: ", ") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { pythonString($0) + ": " + pythonJSON(o[$0]!) }.joined(separator: ", ") + "}"
        }
    }

    private static func pythonString(_ s: String) -> String {
        var out = "\""
        for unit in s.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(unit)!)
            default: out += String(format: "\\u%04x", unit)
            }
        }
        return out + "\""
    }
}
