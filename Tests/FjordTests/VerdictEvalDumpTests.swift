import Foundation
import Testing
@testable import Fjord

/// Not a test of behaviour: with `FJORD_VERDICT_EVAL_DIR` set to a folder holding `cases.json` (real moments exported by
/// `evals/router/verdict/export.py`), it writes the exact system prompts and schemas a verdict call sends, and each case's
/// input as the app sends it (redacted, fenced) to `inputs/<id>.txt`. With `FJORD_VERDICT_EVAL_RUN=1` it also runs each
/// case through the real engine (four at once, as the app does) and writes `verdicts/<id>.json`: the verdict and when its
/// state, its whole line and its end came. Cases already answered are skipped, so a run can be resumed.
@MainActor @Suite struct VerdictEvalDump {
    private struct Case: Decodable {
        struct Request: Decodable { var kind: String, words: String, options: [String] }
        struct PR: Decodable { var url: String, number: Int?, state: String? }
        struct Diff: Decodable { var files: Int, added: Int, removed: Int }
        var id: String, kind: String, title: String
        var project: String?, firstAsk: String?, yourWords: String?, reply: String?
        var request: Request?
        var prs: [PR]
        var files: [String]
        var diff: Diff?

        var verdictKind: RouterVerdictRequest.Kind { kind == "ask" ? .ask : .finished }

        var input: RouterVerdictInput {
            RouterVerdictInput(title: title, project: project, firstAsk: firstAsk, yourWords: yourWords, reply: reply,
                               request: request.map { .init(kind: $0.kind, words: $0.words, options: $0.options) },
                               pullRequests: prs.map { .init(url: $0.url, number: $0.number, state: $0.state) },
                               diff: diff.map { .init(files: $0.files, added: $0.added, removed: $0.removed) })
        }
    }

    private struct Answer: Encodable {
        var id: String
        var kind: String
        var verdict: RouterVerdict?
        var failed: Bool
        /// Seconds from the call's start: the state (a finished turn's), the line whole, the end.
        var state: Double?
        var line: Double?
        var end: Double?
    }

    @Test func dumpsTheVerdictInputs() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FJORD_VERDICT_EVAL_DIR"] else { return }
        let root = URL(fileURLWithPath: dir)
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        let fm = FileManager.default
        let inputs = root.appendingPathComponent("inputs"), verdicts = root.appendingPathComponent("verdicts")
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        try fm.createDirectory(at: verdicts, withIntermediateDirectories: true)
        func write(_ url: URL, _ s: String) throws { try s.write(to: url, atomically: true, encoding: .utf8) }
        for kind in [RouterVerdictRequest.Kind.finished, .ask, .name] {
            let name = "\(kind)"
            try write(root.appendingPathComponent("system-\(name).txt"), RouterVerdictPrompt.system(kind))
            try write(root.appendingPathComponent("schema-\(name).json"), RouterVerdictPrompt.schema(kind))
        }
        for c in cases { try write(inputs.appendingPathComponent("\(c.id).txt"), RouterVerdictPrompt.text(c.input, kind: c.verdictKind)) }

        guard env["FJORD_VERDICT_EVAL_RUN"] == "1", let path = RouterStatus.findDefault() else { return }
        let todo = cases.filter { !fm.fileExists(atPath: verdicts.appendingPathComponent("\($0.id).json").path) }
        let engine = RouterVerdicts(binary: { path }, log: nil)
        var started: [String: Date] = [:]
        var answers: [String: Answer] = [:]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        engine.onEvent = { id, _, event in
            guard var a = answers[id], let t0 = started[id] else { return }
            let t = Date().timeIntervalSince(t0)
            switch event {
            case .state: a.state = t
            case .words(_, let done): if done { a.line = t }
            case .done(let v): a.verdict = v; a.end = t
            case .failed: a.failed = true; a.end = t
            }
            answers[id] = a
            if a.end != nil, let data = try? enc.encode(a) { try? data.write(to: verdicts.appendingPathComponent("\(id).json")) }
        }
        // Fed four at a time, so each case's clock starts with its call (the engine runs four at once).
        var next = todo[...]
        let deadline = Date().addingTimeInterval(Double(todo.count) * 20 + 60)
        while Date() < deadline {
            while answers.values.filter({ $0.end == nil }).count < RouterVerdicts.cap, let c = next.popFirst() {
                answers[c.id] = Answer(id: c.id, kind: c.kind, verdict: nil, failed: false)
                started[c.id] = Date()
                engine.ask(RouterVerdictRequest(thread: c.id, fingerprint: c.id, kind: c.verdictKind, input: c.input))
            }
            if next.isEmpty, !answers.values.contains(where: { $0.end == nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let done = answers.values.filter { $0.end != nil }
        print("verdicts: \(done.count) of \(todo.count), \(done.filter(\.failed).count) failed")
    }
}
