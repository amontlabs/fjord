import Foundation

// Forking a session: a new session that continues from another's conversation, whole or up to before one of your messages
// (docs/design/spec/router.md, C). It is made the way a new session is (`SessionStart`): a CLI run with no model call,
// `claude -p "/rename <title>" --resume <its id> --fork-session --session-id <new> [--resume-session-at <entry>]`, which
// writes the fork's transcript and leaves the original's untouched; then the Claude app imports it, its process registers,
// and the first message, if any, is signed for its plugin and delivered. Only the conversation is forked: files the agent
// changed stay as they are.

enum SessionFork {
    /// Where the fork's conversation ends.
    enum Point: Equatable, Sendable {
        /// All of it.
        case whole
        /// Up to before your last message (its turn and everything after it are left out).
        case beforeLast
        /// Up to before your message with this text, sent at or after `after` (when the run that sent it began): the first
        /// such one. Without a date, only a text sent once is found (the same words twice, "yes", is refused).
        case before(String, after: Date?)
    }

    /// A fork asked for: of which session, from where, with what first message (empty: none, it waits for yours), titled.
    struct Request: Equatable, Sendable {
        var session: String
        var point: Point = .whole
        var message: String = ""
        /// Nil: "Fork of <its title>".
        var title: String? = nil
    }

    /// What the CLI run needs: the folder the original ran in (its transcript is found from there), its Claude Code id, the
    /// entry the fork keeps up to (nil: all of it), and the title.
    struct Plan: Equatable, Sendable {
        var cwd: String
        var cliID: String
        var at: String?
        var title: String
        /// The message cut at was the conversation's first: nothing is left to fork, so it is a new session in `cwd`.
        var fresh = false
    }

    /// One message of yours in a transcript: its entry, the entry before it (nil for a conversation's first), its text,
    /// and the folder it was sent in.
    struct Message: Equatable, Sendable {
        var uuid: String
        var parent: String?
        var text: String
        var cwd: String?
        /// When it was written (the entry's `timestamp`).
        var at: Date? = nil
    }

    /// The CLI run that makes the fork (`SessionStart.bootstrapArguments`, from another session's conversation).
    /// `--session-id` goes with `--resume` only together with `--fork-session`; `--resume-session-at` keeps the
    /// conversation up to and including that entry.
    static func arguments(cliID: String, uuid: String, title: String, at entry: String?) -> [String] {
        ["-p", "/rename \(title)", "--resume", cliID, "--fork-session", "--session-id", uuid]
            + (entry.map { ["--resume-session-at", $0] } ?? [])
            + ["--output-format", "json", "--setting-sources", ""]
    }

    /// A session's transcript, by its Claude Code id: `<root>/<project>/<id>.jsonl`.
    nonisolated static func transcript(_ cliID: String, root: URL = Claude.transcriptsDir) -> URL? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.lazy.map { $0.appendingPathComponent("\(cliID).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Your messages in a transcript, oldest first: what you typed (or Fjord delivered as yours), never a tool's
    /// result, a slash command's lines, a subagent's or one Claude Code adds itself. Only these lines are decoded;
    /// nothing is kept but what `Message` holds.
    nonisolated static func messages(in data: Data) -> [Message] {
        data.split(separator: UInt8(ascii: "\n")).compactMap(message)
    }

    /// The same from the file, read a piece at a time (a long session's transcript runs to many megabytes).
    nonisolated static func messages(at url: URL, chunk: Int = 1 << 20) -> [Message]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var out: [Message] = [], rest = Data()
        while let piece = try? handle.read(upToCount: chunk), !piece.isEmpty {
            rest.append(piece)
            guard let end = rest.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            out += rest[..<end].split(separator: UInt8(ascii: "\n")).compactMap(message)
            rest = Data(rest[rest.index(after: end)...])
        }
        if !rest.isEmpty, let last = message(rest) { out.append(last) }
        return out
    }

    private static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// One transcript line as a message of yours, if it is one.
    static func message(_ line: Data) -> Message? {
        // Cheap first: most lines aren't a user's.
        guard line.count > 2, line.range(of: Data(#""type":"user""#.utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "user", let uuid = obj["uuid"] as? String,
              obj["isMeta"] as? Bool != true, obj["isSidechain"] as? Bool != true, obj["isCompactSummary"] as? Bool != true,
              obj["toolUseResult"] == nil, let message = obj["message"] as? [String: Any],
              let text = text(message["content"]) else { return nil }
        return Message(uuid: uuid, parent: obj["parentUuid"] as? String, text: text, cwd: obj["cwd"] as? String,
                       at: (obj["timestamp"] as? String).flatMap { try? stamp.parse($0) })
    }

    /// A user entry's words: a string, or text blocks (an image alongside is fine); nil for a tool's result or what Claude
    /// Code writes for a slash command.
    private static func text(_ content: Any?) -> String? {
        var text: String
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let generated = ["<command-name>", "<command-message>", "<local-command-", "<bash-input>", "<bash-stdout>", "<bash-stderr>",
                         "<task-notification>", "<system-reminder>", "Caveat: The messages below"]
        guard !text.isEmpty, !generated.contains(where: { text.hasPrefix($0) }) else { return nil }
        return text
    }

    /// Two texts the same message: the same words, however the spaces and line ends fell.
    static func same(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [Substring] { s.split(whereSeparator: \.isWhitespace) }
        return words(a) == words(b)
    }

    struct Failure: LocalizedError, Equatable {
        var reason: String
        var errorDescription: String? { reason }
        init(_ reason: String) { self.reason = reason }
    }

    /// Where `point` cuts `messages` (a session's, oldest first): the entry the fork keeps up to (nil: all of it), the
    /// folder the session ran in there, and whether nothing is left to keep (the cut is before its first message).
    static func cut(_ point: Point, messages: [Message]) throws -> (at: String?, cwd: String?, fresh: Bool) {
        let message: Message
        switch point {
        case .whole:
            return (nil, messages.last?.cwd, false)
        case .beforeLast:
            guard let last = messages.last else { throw Failure("There's no message of yours in that session to fork before") }
            message = last
        case .before(let text, let after):
            let found = messages.filter { same($0.text, text) }
            guard !found.isEmpty else {
                throw Failure("That message isn't in the session's conversation any more (compacted, or sent elsewhere)")
            }
            // The first sent at or after the run that sent it (a little early for clocks); a fork's copies of older ones
            // keep their own dates.
            if let after, let first = found.first(where: { $0.at.map { $0 >= after.addingTimeInterval(-sentSlack) } ?? false }) {
                message = first
            } else if found.count == 1, after == nil || found[0].at == nil {
                message = found[0]
            } else {
                throw Failure("The session has those words more than once, and which one this was can't be told; nothing was forked")
            }
        }
        return (message.parent, message.cwd, message.parent == nil)
    }

    /// How much earlier than the run's start a message it sent may be dated (clocks, rounding).
    static let sentSlack: TimeInterval = 5

    /// The title a fork gets: "Fork of <title>", once ("Fork of Fork of …" is the same thing said twice).
    static func title(of session: String) -> String {
        var base = Substring(session)
        while base.lowercased().hasPrefix("fork of ") { base = base.dropFirst("fork of ".count) }
        return SessionStart.cleanTitle("Fork of " + base)
    }

    // MARK: Asked for in words

    /// "fork <session>", "branch <session> from before my last message: <first message>": what the words ask for. `name`:
    /// the session as named; nil when it is "this session" or "the session" (`thisSession`), a pronoun or nothing.
    struct Words: Equatable {
        var name: String?
        /// Said as "this session", "that session", "the session": the one you pinned.
        var thisSession: Bool
        var beforeLast: Bool
        var message: String
    }

    static func words(_ text: String) -> Words? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:please\s+)?(?:fork|branch(?:\s+off)?)\b(?:\s+(?!from\b|before\b|without\b)(?:the\s+)?(.+?))??(\s+session)?(\s*,?\s+(?:from\s+)?(?:before|without)\s+my\s+last\s+(?:message|prompt|turn))?\s*(?::\s*([\s\S]*))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: t).map { String(t[$0]) } }
        var name = group(1)?.trimmingCharacters(in: .whitespaces)
        let sessionWord = group(2) != nil
        var this = false
        if let n = name?.lowercased(), ["it", "this", "that", "this one", "that one", "session", ""].contains(n) {
            // "this session", "that session", "the session" (read as the name "session"): the pinned one, named as such.
            this = n == "session" || (sessionWord && n != "it")
            name = nil
        }
        return Words(name: name, thisSession: this, beforeLast: group(3) != nil,
                     message: (group(4) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A fork your words ask for, of the session they name (its title as the app shows it, or a project with one session),
    /// or of `pinned` when they say "this session" or ask for the cut ("fork it from before my last message"). Never from
    /// a bare word or a pronoun ("fork", "branch", "fork it", "branch: main"): those answer a session ("Should I create a
    /// branch?") or are a task for one. Nil when the words don't clearly ask for a fork, or name no session.
    @MainActor
    static func request(_ text: String, pinned: String?, store: Store) -> Request? {
        guard let words = words(text) else { return nil }
        let session: String
        if let name = words.name?.lowercased() {
            let live = store.claudeSessions.values.filter { !$0.isArchived }
            let titled = live.filter { $0.title.lowercased() == name }
            if titled.count == 1 {
                session = titled[0].id
            } else {
                let inProject = live.filter { !$0.folderKey.isEmpty && store.folderName($0.folderKey).lowercased() == name }
                guard titled.isEmpty, inProject.count == 1 else { return nil }
                session = inProject[0].id
            }
        } else {
            guard let pinned, words.thisSession || words.beforeLast else { return nil }
            session = pinned
        }
        return Request(session: session, point: words.beforeLast ? .beforeLast : .whole, message: words.message)
    }
}

extension RouterDecision {
    /// The message this run sent to a session as yours, the session, and when the run began (the message was sent then
    /// or after): what a fork from before it, or an edit of it, starts from. Only for a run that sent one message to one
    /// session: a sent item doesn't keep its session, so with several neither is offered rather than a wrong pair.
    var sentMessage: (session: String, text: String, at: Date)? {
        guard case .you = trigger, links.sessions.count == 1, let session = links.sessions.first else { return nil }
        let texts = done.compactMap { item -> String? in if case .sent(_, let text, _) = item { text } else { nil } }
        guard texts.count == 1, let text = texts.first, !text.isEmpty else { return nil }
        return (session, text, at)
    }
}

extension Store {
    /// Forks a session from the page (a session's menu, a sent message's line, a message edited and resent): a run of the
    /// Router's, in its history. Its entry, nil when the Router is off. `mentions`: the pills in `message`, whose
    /// blocks (`RouterPointers.context`) the fork gets fenced after your words, as a session a message is delivered to does.
    @discardableResult
    func forkSession(_ session: String, point: SessionFork.Point = .whole, message: String = "", edited: Bool = false,
                     mentions: [RouterMention] = []) -> UUID? {
        let title = claudeSessions[session].map { "“\(RouterDecision.clip($0.title, 60))”" } ?? "a session"
        let asked = switch point {
        case .whole: "Fork \(title)"
        case .beforeLast: "Fork \(title) from before your last message"
        case .before(let text, _): "Fork \(title) from before “\(RouterDecision.clip(text, 60))”"
        }
        let trigger = edited ? "Edited and resent to a fork of \(title): \(message)" : asked
        return routerDispatcher.fork(SessionFork.Request(session: session, point: point, message: message), trigger: trigger,
                                     mentions: mentions)
    }
}
