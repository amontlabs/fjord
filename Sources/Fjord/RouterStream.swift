import Foundation

/// What a delivery's `claude` process writes on stdout (stream-json), as far as the delivery cares. Pure, so it is tested on sample lines.
enum RouterStream {
    enum Event: Equatable {
        /// `system/init`: the process's Claude Code session.
        case started(sessionID: String)
        case text(String)
        /// A tool call, with its string (and boolean) arguments.
        case toolUse(id: String, name: String, input: [String: String])
        case toolResult(id: String, isError: Bool, text: String)
        /// A session wrote to the Router (`<cross-session-message from-name=…>`).
        case peer(from: String, text: String)
        /// A turn ended.
        case result(isError: Bool, text: String)
        /// Claude Code asks before a tool runs (`control_request` `can_use_tool`): `input`'s string fields, and the names of
        /// any that aren't strings (which no allowed call has).
        case permission(id: String, tool: String, input: [String: String], otherFields: [String])
    }

    static func parse(_ line: Data) -> [Event] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            guard obj["subtype"] as? String == "init", let id = obj["session_id"] as? String else { return [] }
            return [.started(sessionID: id)]
        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : .text(text)
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                    var input: [String: String] = [:]
                    for (key, value) in block["input"] as? [String: Any] ?? [:] {
                        if let s = value as? String { input[key] = s }
                        else if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { input[key] = n.boolValue ? "true" : "false" }
                    }
                    return .toolUse(id: id, name: name, input: input)
                default:
                    return nil
                }
            }
        case "user":
            let content = (obj["message"] as? [String: Any])?["content"]
            if let text = content as? String { return peer(text).map { [$0] } ?? [] }
            var events: [Event] = []
            for block in content as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else { continue }
                    events.append(.toolResult(id: id, isError: block["is_error"] as? Bool ?? false, text: Self.text(block["content"])))
                case "text":
                    if let event = peer(block["text"] as? String ?? "") { events.append(event) }
                default:
                    continue
                }
            }
            return events
        case "control_request":
            guard let id = obj["request_id"] as? String, let request = obj["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool" else { return [] }
            var strings: [String: String] = [:], others: [String] = []
            for (key, value) in request["input"] as? [String: Any] ?? [:] {
                if let s = value as? String { strings[key] = s } else { others.append(key) }
            }
            return [.permission(id: id, tool: request["tool_name"] as? String ?? "", input: strings, otherFields: others.sorted())]
        case "result":
            let isError = obj["is_error"] as? Bool ?? (obj["subtype"] as? String != "success")
            let errors = (obj["errors"] as? [String] ?? []).filter { !$0.hasPrefix("[ede_diagnostic]") }
            let text = (obj["result"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? errors.joined(separator: "\n")
            return [.result(isError: isError, text: text)]
        default:
            return []
        }
    }

    /// A tool result's text, whether a string or text blocks.
    static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// A message another session sent: who from, and its text without the envelope.
    static func peer(_ text: String) -> Event? {
        guard let start = text.range(of: "<cross-session-message"),
              let close = text.range(of: ">", range: start.upperBound..<text.endIndex) else { return nil }
        let attributes = String(text[start.upperBound..<close.lowerBound])
        func attribute(_ name: String) -> String? {
            guard let r = attributes.range(of: "\\b\(name)=\"([^\"]*)\"", options: .regularExpression) else { return nil }
            return String(attributes[r].dropFirst(name.count + 2).dropLast())
        }
        var body = text[close.upperBound...]
        if let end = body.range(of: "</cross-session-message>", options: .backwards) { body = body[..<end.lowerBound] }
        let from = attribute("from-name").flatMap { $0.isEmpty ? nil : $0 } ?? attribute("from") ?? "A session"
        return .peer(from: from, text: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One line of stdin: your message.
    static func userLine(_ text: String) -> Data {
        line(["type": "user", "message": ["role": "user", "content": text]])
    }

    /// One line of stdin: the answer to a permission request. Allowed with exactly the input asked about, or denied.
    static func permissionLine(id: String, allow input: [String: String]?, deny reason: String = "") -> Data {
        let decision: [String: Any] = input.map { ["behavior": "allow", "updatedInput": $0] }
            ?? ["behavior": "deny", "message": reason]
        return line(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": decision]])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Splits off the whole lines of `buffer`, leaving a partial one.
    static func lines(_ buffer: inout Data) -> [Data] {
        var out: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty { out.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return out
    }
}

/// The version the Router's MCP server reports.
enum RouterAgent {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1" }
}

/// Bytes from a pipe, cut into whole lines; touched only by the pipe's handler.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func take(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        return RouterStream.lines(&data)
    }
}
