import Foundation

// Your messages in a Claude Code transcript: what you typed (or Fjord delivered as yours), read from its lines. What the
// Router reads of a session's turns (its finished turns, a guest session's evidence) starts from these.

enum YourMessages {
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

    /// Your messages in a transcript, oldest first: what you typed (or Fjord delivered as yours), never a tool's
    /// result, a slash command's lines, a subagent's or one Claude Code adds itself. Only these lines are decoded;
    /// nothing is kept but what `Message` holds.
    nonisolated static func messages(in data: Data) -> [Message] {
        data.split(separator: UInt8(ascii: "\n")).compactMap(message)
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
}
