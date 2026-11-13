import Foundation
import Testing
@testable import Fjord

/// Not a test of behaviour: with `FJORD_SUMMARY_EVAL_DIR` set to a folder holding `cases.json` (real mid-run moments
/// exported by `evals/router/summary/export.py`), it writes the exact system prompt and schema a working summary call
/// sends, and each moment's input as the app builds it (redacted, fenced) to `inputs/<id>.txt`, without the previous line:
/// `evals/router/summary/run.py` appends that line the way `RouterSummaryPrompt.text` does, from the earlier moment's answer.
@MainActor @Suite struct SummaryEvalDump {
    private struct Case: Decodable {
        struct Tool: Decodable { var text: String }
        struct Step: Decodable { var text: String, status: String }
        var id: String, title: String
        var project: String?, yourWords: String?, said: String?
        var now: Tool?
        var recent: [Tool]
        var steps: [Step]

        var input: RouterSummaryInput {
            RouterSummaryInput(title: title, project: project, yourWords: yourWords, said: said,
                               steps: steps.map { .init(text: $0.text, state: $0.status == "completed" ? "done" : $0.status == "running" ? "running" : "pending") },
                               now: now?.text, recent: recent.map(\.text))
        }
    }

    @Test func dumpsTheSummaryInputs() throws {
        guard let dir = ProcessInfo.processInfo.environment["FJORD_SUMMARY_EVAL_DIR"] else { return }
        let root = URL(fileURLWithPath: dir)
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        let inputs = root.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        func write(_ url: URL, _ s: String) throws { try s.write(to: url, atomically: true, encoding: .utf8) }
        try write(root.appendingPathComponent("system.txt"), RouterSummaryPrompt.system)
        try write(root.appendingPathComponent("schema.json"), RouterSummaryPrompt.schema)
        for c in cases { try write(inputs.appendingPathComponent("\(c.id).txt"), RouterSummaryPrompt.text(c.input)) }
    }
}
