import Foundation
import Testing
@testable import Fjord

/// Not a test of behaviour: with `FJORD_ITEMS_EVAL_DIR` set to a folder holding `cases.json` (real sequences exported by
/// `evals/router/items/export.py`), it writes the exact system prompts and schemas an open-items read sends, and each
/// case's parts as the app builds them (redacted, fenced): `head` once, then each step's input block. The open items
/// block depends on the answers before it: `evals/router/items/run.py` writes it the way `RouterItemsPrompt.openBlock`
/// does. The judge's facts are these same redacted parts, so no raw text reaches it.
@MainActor @Suite struct ItemsEvalDump {
    private struct Case: Decodable {
        struct Step: Decodable {
            var kind: String
            var reply: String?, started: String?, woke: String?, status: String?
            var text: String?, replyBefore: String?
        }
        var id: String, title: String
        var project: String?, firstAsk: String?
        var steps: [Step]
    }

    @Test func dumpsTheItemsInputs() throws {
        guard let dir = ProcessInfo.processInfo.environment["FJORD_ITEMS_EVAL_DIR"] else { return }
        let root = URL(fileURLWithPath: dir)
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        func write(_ name: String, _ s: String) throws {
            try s.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("system-turn.txt", RouterItemsPrompt.turn)
        try write("system-message.txt", RouterItemsPrompt.message)
        try write("system-said.txt", RouterItemsPrompt.said)
        try write("schema-said.json", RouterItemsPrompt.saidSchema)
        try write("schema-turn.json", RouterItemsPrompt.turnSchema)
        try write("schema-message.json", RouterItemsPrompt.messageSchema)
        try write("open-sample.txt", RouterItemsPrompt.openBlock([
            .init(id: "i1", kind: .decide, sentence: "keep it, or delete it?", options: ["Keep it", "Delete it"], minutes: 12),
            .init(id: "i2", kind: .know, sentence: "the image is smaller", minutes: 200),
        ]))
        var parts: [[String: Any]] = []
        for c in cases {
            let base = RouterItemsInput(title: c.title, project: c.project, firstAsk: c.firstAsk, input: .message(words: "", replyBefore: nil))
            let steps: [String] = c.steps.map { s in
                var x = base
                x.input = switch s.kind {
                case "turn": .turn(reply: s.reply ?? "", yourWords: s.started, woke: s.woke, status: s.status ?? "completed")
                case "said": .said(message: s.text ?? "", yourWords: s.started)
                default: .message(words: s.text ?? "", replyBefore: s.replyBefore)
                }
                return RouterItemsPrompt.inputBlock(x)
            }
            parts.append(["id": c.id, "head": RouterItemsPrompt.head(base), "steps": steps, "kinds": c.steps.map(\.kind)])
        }
        try JSONSerialization.data(withJSONObject: parts, options: [.prettyPrinted]).write(to: root.appendingPathComponent("parts.json"))
    }
}
