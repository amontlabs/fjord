import Foundation
import Testing
@testable import Fjord

/// `ClaudeStream`: lines from chunks, the typed answer read field by field (`PartialJSON`), and a real `claude -p
/// --output-format stream-json --include-partial-messages` run (Fixtures/ClaudeStream/verdict.jsonl: a Haiku verdict on
/// made-up text, captured 2026-11-12 with Claude Code 2.1.322; signatures and ids blanked).
@Suite struct ClaudeStreamTests {
    static let fixture: Data = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ClaudeStream/verdict.jsonl")
        return (try? Data(contentsOf: url)) ?? Data()
    }()

    static var fixtureLines: [Data] { fixture.split(separator: 0x0A).map { Data($0) } }

    /// The typed answer's text as the fixture's `input_json_delta` pieces wrote it.
    static var answerPieces: [String] {
        fixtureLines.compactMap { line in
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let e = o["event"] as? [String: Any],
                  let d = e["delta"] as? [String: Any], d["type"] as? String == "input_json_delta" else { return nil }
            return d["partial_json"] as? String
        }
    }

    static let order = ["state", "worth", "name", "line", "ask", "options", "result"]

    /// Checks one read of a whole answer: every field once, in order, with its final value; every growing text a prefix of
    /// its field's final words, cut after a whole word, growing only, and before the field closes.
    static func check(_ pieces: [PartialJSON.Piece], against whole: String, keys: [String]) {
        let final = (try? JSONSerialization.jsonObject(with: Data(whole.utf8))) as? [String: Any] ?? [:]
        var fields: [String] = []
        var grown: [String: String] = [:]
        for p in pieces {
            switch p {
            case .field(let k, let raw):
                fields.append(k)
                let value = PartialJSON.value(raw)
                #expect(value != nil, "field \(k) reads as JSON: \(raw)")
                if let s = final[k] as? String { #expect(PartialJSON.string(raw) == s) }
                if let a = final[k] as? [String] { #expect(PartialJSON.strings(raw) == a) }
            case .growing(let k, let text):
                #expect(!fields.contains(k), "\(k) grows before it closes")
                guard let s = final[k] as? String else { Issue.record("\(k) grows but isn't a string"); continue }
                #expect(s.hasPrefix(text), "\(text) is a start of \(s)")
                let next = s.dropFirst(text.count).first
                #expect(next.map { $0.isWhitespace } ?? false, "\(text) ends on a whole word of \(s)")
                if let before = grown[k] { #expect(text.count > before.count && text.hasPrefix(before)) }
                grown[k] = text
            }
        }
        #expect(fields == keys)
    }

    @Test func theRealAnswerReadsFieldByFieldInOrder() {
        var json = PartialJSON()
        var pieces: [PartialJSON.Piece] = []
        for piece in Self.answerPieces { pieces += json.feed(piece) }
        let whole = Self.answerPieces.joined()
        Self.check(pieces, against: whole, keys: Self.order)
        // The line grows word by word as the pieces come.
        let line = pieces.compactMap { if case .growing("line", let t) = $0 { t } else { nil } }
        #expect(line.first == "Snapshot API build still")
        #expect(line.count >= 5)
    }

    @Test func theRealAnswerCutAtEveryCharacter() {
        let whole = Self.answerPieces.joined()
        let scalars = Array(whole.unicodeScalars)
        for cut in 0...scalars.count {
            var json = PartialJSON()
            let a = String(String.UnicodeScalarView(scalars[..<cut])), b = String(String.UnicodeScalarView(scalars[cut...]))
            Self.check(json.feed(a) + json.feed(b), against: whole, keys: Self.order)
        }
    }

    @Test func escapesAreDecodedAndNeverShownHalfWritten() {
        let whole = #"{"line": "it said \"done\"\nthen café 😀 and a back\\slash \/ tab\there end", "n": 12, "o": {"a": [1, "}"]}, "t": true}"#
        let scalars = Array(whole.unicodeScalars)
        // One character at a time: every growing text decodes cleanly.
        var json = PartialJSON()
        var pieces: [PartialJSON.Piece] = []
        for s in scalars { pieces += json.feed(String(s)) }
        Self.check(pieces, against: whole, keys: ["line", "n", "o", "t"])
        let grown = pieces.compactMap { if case .growing(_, let t) = $0 { t } else { nil } }
        #expect(grown.contains("it said \"done\"\nthen café 😀"))
        #expect(!grown.contains { $0.contains("\\") && !$0.contains("back\\slash") })
        // And cut at every place into two.
        for cut in 0...scalars.count {
            var two = PartialJSON()
            let a = String(String.UnicodeScalarView(scalars[..<cut])), b = String(String.UnicodeScalarView(scalars[cut...]))
            Self.check(two.feed(a) + two.feed(b), against: whole, keys: ["line", "n", "o", "t"])
        }
    }

    @Test func aLineSplitAcrossChunksIsWaitedFor() {
        #expect(Self.fixtureLines.count == 60)
        // The stream's head, through its first pieces of the answer: every byte a cut.
        let lines = Array(Self.fixtureLines.prefix(16))
        let data = Data(lines.map { $0 + Data([0x0A]) }.joined())
        for cut in 0...data.count {
            var s = LineSplitter()
            let got = s.feed(data.subdata(in: 0..<cut)) + s.feed(data.subdata(in: cut..<data.count))
            if got != lines { Issue.record("cut at \(cut)"); return }
            #expect(s.finish() == nil)
        }
        var s = LineSplitter()
        #expect(s.feed(Data("a\nb".utf8)) == [Data("a".utf8)])
        #expect(s.finish() == Data("b".utf8))
    }

    @Test func theRealStreamReadsToItsAnswerAndUsage() {
        var splitter = LineSplitter()
        var reader = ClaudeStream.Reader()
        var outputs: [ClaudeStream.Reader.Output] = []
        var at = 0
        let data = Self.fixture
        while at < data.count {
            let chunk = data.subdata(in: at..<min(data.count, at + 7))
            at += 7
            for line in splitter.feed(chunk) { outputs += reader.read(line) }
        }
        let pieces = outputs.compactMap { if case .piece(let p) = $0 { p } else { nil } }
        Self.check(pieces, against: Self.answerPieces.joined(), keys: Self.order)
        guard case .end(let end)? = outputs.last else { Issue.record("no end"); return }
        #expect(end.error == nil)
        #expect(end.status == nil)
        #expect(end.usage.outputTokens == 513)
        #expect(end.usage.cacheCreationTokens == 1424)
        #expect(end.usage.costUSD == 0.0005415)
        let answer = end.json.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        #expect(answer?["state"] as? String == "needs_you")
        #expect(answer?["name"] as? String == "Fix the snapshot build")
        #expect((answer?["options"] as? [String])?.count == 2)
    }

    @Test func retriesAndFailuresAreRead() {
        var reader = ClaudeStream.Reader()
        let retry = #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":30000,"error_status":429,"error":"rate_limit"}"#
        #expect(reader.read(Data(retry.utf8)) == [.retry(status: 429, after: 30)])
        let failed = #"{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":429,"result":"rate limited","usage":{"input_tokens":3,"output_tokens":0}}"#
        guard case .end(let end)? = reader.read(Data(failed.utf8)).first else { Issue.record("no end"); return }
        #expect(end.status == 429)
        #expect(end.error != nil)
        #expect(end.json == nil)
        #expect(reader.read(Data("not json".utf8)).isEmpty)
    }

    @Test func theStreamingArgumentsAreClaudePrintsWithTheStreamFormat() {
        let args = ClaudePrint.arguments(model: "m", system: "s", schema: "{}", effort: "low", streaming: true)
        #expect(args.contains("stream-json") && args.contains("--verbose") && args.contains("--include-partial-messages"))
        #expect(!args.contains("json"))
        #expect(args.contains("--no-session-persistence") && args.contains("--strict-mcp-config"))
        let plain = ClaudePrint.arguments(model: "m", system: "s", schema: "{}", effort: nil)
        #expect(plain.contains("json") && !plain.contains("--verbose"))
    }
}
