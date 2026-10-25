import Foundation
import Testing
@testable import Fjord

/// The reader of a Router run's stream (`RouterRunStream`): the reply as it is written, the thinking and the tool calls, from
/// `claude -p --output-format stream-json --verbose --include-partial-messages` lines.
@Suite struct RouterRunStreamTests {
    private func event(_ body: [String: Any]) -> String {
        let line = try! JSONSerialization.data(withJSONObject: ["type": "stream_event", "event": body, "session_id": "s"])
        return String(decoding: line, as: UTF8.self) + "\n"
    }

    private func start(_ index: Int, _ block: [String: Any]) -> String {
        event(["type": "content_block_start", "index": index, "content_block": block])
    }

    private func delta(_ index: Int, _ delta: [String: Any]) -> String {
        event(["type": "content_block_delta", "index": index, "delta": delta])
    }

    private func json(_ index: Int, _ piece: String) -> String { delta(index, ["type": "input_json_delta", "partial_json": piece]) }

    private func stop(_ index: Int) -> String { event(["type": "content_block_stop", "index": index]) }

    private func feed(_ stream: inout RouterRunStream, _ text: String) { stream.feed(Data(text.utf8)) }

    private let reply = ["type": "tool_use", "id": "t", "name": "StructuredOutput", "input": [String: String]()] as [String: Any]

    @Test func theReplyGrowsAsItsPartialJsonArrives() {
        var stream = RouterRunStream()
        feed(&stream, start(0, reply))
        #expect(stream.live.reply == "")
        feed(&stream, json(0, ""))
        feed(&stream, json(0, "{\"reply\": \"Sunlight contains all vis"))
        #expect(stream.live.reply == "Sunlight contains all vis")
        feed(&stream, json(0, "ible colors.\", \"done\": \"answered"))
        #expect(stream.live.reply == "Sunlight contains all visible colors.", "the reply ends at its closing quote")
        feed(&stream, json(0, " it\"}"))
        #expect(stream.live.reply == "Sunlight contains all visible colors.")
    }

    @Test func aLineCutAcrossChunksIsWaitedFor() {
        var stream = RouterRunStream()
        let whole = Data((start(0, reply) + json(0, "{\"reply\": \"Hello wor") + json(0, "ld\"}")).utf8)
        var changed = 0
        for byte in whole where stream.feed(Data([byte])) { changed += 1 }
        #expect(stream.live.reply == "Hello world")
        #expect(changed > 0)
        var cut = RouterRunStream()
        let line = json(0, "{\"reply\": \"Hi\"}")
        feed(&cut, start(0, reply))
        feed(&cut, String(line.prefix(40)))
        #expect(cut.live.reply == "")
        feed(&cut, String(line.dropFirst(40)))
        #expect(cut.live.reply == "Hi")
    }

    @Test func escapesAreResolvedAndACutOffOneWaits() {
        #expect(RouterRunStream.partialReply(#"{"reply": "a \"quoted\" word\nnext\ttab \\ \/ end"#) == "a \"quoted\" word\nnext\ttab \\ / end")
        #expect(RouterRunStream.partialReply(#"{"reply": "café "#) == "café ")
        // A cut-off escape is left out until it is whole.
        #expect(RouterRunStream.partialReply(#"{"reply": "one\"#) == "one")
        #expect(RouterRunStream.partialReply(#"{"reply": "one\u00"#) == "one")
        #expect(RouterRunStream.partialReply(#"{"reply": "oneé"#) == "oneé")
        // A pair of surrogates is one character; a lone high one waits for its low one.
        #expect(RouterRunStream.partialReply(#"{"reply": "go 🚀!"#) == "go 🚀!")
        #expect(RouterRunStream.partialReply(#"{"reply": "go \ud83d"#) == "go ")
        #expect(RouterRunStream.partialReply(#"{"reply": "go \ud83d\ude"#) == "go ")
    }

    @Test func onlyTheReplyKeyOfTheTopObjectIsRead() {
        #expect(RouterRunStream.partialReply("") == "")
        #expect(RouterRunStream.partialReply("{\"rep") == "")
        #expect(RouterRunStream.partialReply("{\"reply\"") == "")
        #expect(RouterRunStream.partialReply("{\"reply\":") == "")
        #expect(RouterRunStream.partialReply("{\"reply\": \"") == "")
        // `done` first, quoting the word: its escaped quotes are no key.
        #expect(RouterRunStream.partialReply(#"{"done": "said \"reply\": \"no\"", "reply": "yes"#) == "yes")
        #expect(RouterRunStream.partialReply(#"{"done": "x", "reply":"tight"#) == "tight")
    }

    @Test func thinkingAccumulatesBlockAfterBlock() {
        var stream = RouterRunStream()
        feed(&stream, start(0, ["type": "thinking", "thinking": "", "signature": ""]))
        feed(&stream, delta(0, ["type": "thinking_delta", "thinking": "The user asks "]))
        feed(&stream, delta(0, ["type": "thinking_delta", "thinking": "about CI."]))
        feed(&stream, delta(0, ["type": "signature_delta", "signature": "abc"]))
        feed(&stream, stop(0))
        #expect(stream.live.thinking == "The user asks about CI.")
        feed(&stream, start(2, ["type": "thinking", "thinking": ""]))
        feed(&stream, delta(2, ["type": "thinking_delta", "thinking": "Then the board."]))
        #expect(stream.live.thinking == "The user asks about CI.\n\nThen the board.")
        #expect(stream.live.reply.isEmpty && stream.live.steps.isEmpty)
    }

    @Test func theRoutersToolsAreStepsInOrderWithTheirInputSummarised() {
        var stream = RouterRunStream()
        feed(&stream, start(1, ["type": "tool_use", "id": "a", "name": "mcp__fjord__explain_entry", "input": [String: String]()]))
        #expect(stream.live.steps == [.init(tool: "explain_entry", summary: "")])
        feed(&stream, json(1, ""))
        feed(&stream, json(1, "{\"entry\": \"card-"))
        #expect(stream.live.steps.first?.summary == "", "an input not whole yet has no summary")
        feed(&stream, json(1, "12\", \"limit\": 3, \"deep\": true}"))
        #expect(stream.live.steps == [.init(tool: "explain_entry", summary: "deep: true, entry: card-12, limit: 3")])
        feed(&stream, stop(1))
        feed(&stream, start(2, ["type": "tool_use", "id": "b", "name": "mcp__fjord__board", "input": [String: String]()]))
        feed(&stream, json(2, "{}"))
        feed(&stream, stop(2))
        feed(&stream, start(3, reply))
        feed(&stream, json(3, "{\"reply\": \"Done.\"}"))
        #expect(stream.live.steps.map(\.tool) == ["explain_entry", "board"])
        #expect(stream.live.steps.last?.summary == "")
        #expect(stream.live.reply == "Done.")
    }

    @Test func aLongValueIsClippedInTheSummary() {
        let long = String(repeating: "word ", count: 40)
        let summary = RouterRunStream.summary(of: "{\"text\": \"\(long)\", \"other\": \"two\\nlines\"}")
        #expect(summary?.hasPrefix("other: two lines, text: word word") == true && summary?.hasSuffix("…") == true)
        #expect((summary?.count ?? 0) <= 90)
    }

    @Test func whatItDoesNotKnowIsIgnored() {
        var stream = RouterRunStream()
        feed(&stream, "not json at all\n")
        feed(&stream, "{\"type\":\"system\",\"subtype\":\"init\"}\n")
        feed(&stream, "[1,2]\n\n")
        feed(&stream, event(["type": "message_start", "message": [:] as [String: Any]]))
        feed(&stream, delta(7, ["type": "text_delta", "text": "stray"]))
        feed(&stream, start(0, ["type": "text", "text": ""]))
        feed(&stream, delta(0, ["type": "text_delta", "text": "words"]))
        #expect(stream.live.isEmpty)
        // A line without end that never stops is dropped, and the next one is read.
        var long = RouterRunStream()
        long.feed(Data(repeating: 0x61, count: RouterRunStream.maxLine + 10))
        feed(&long, "\n" + start(0, reply) + json(0, "{\"reply\": \"ok\"}"))
        #expect(long.live.reply == "ok")
    }

    @Test func theProbeStreamReadsEndToEnd() throws {
        let lines = [
            start(0, ["type": "thinking", "thinking": "", "signature": ""]), stop(0),
            start(1, ["type": "tool_use", "id": "t", "name": "mcp__fjord__board", "input": [String: String]()]),
            json(1, "{}"), stop(1),
            start(2, reply), json(2, ""), json(2, "{\"reply\": \"Sunlight contains all vis"), json(2, "ible colors.\"}"), stop(2),
            "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"{}\",\"structured_output\":{\"reply\":\"Sunlight contains all visible colors.\",\"done\":\"answered\"}}\n",
        ]
        var stream = RouterRunStream()
        feed(&stream, lines.joined())
        #expect(stream.live.reply == "Sunlight contains all visible colors." && stream.live.steps.map(\.tool) == ["board"])
        let answer = try RouterRun.parse(OneShot.Output(stdout: Data(lines.joined().utf8), stderr: Data(), status: 0))
        #expect(answer == RouterRun.Answer(reply: "Sunlight contains all visible colors.", done: "answered"))
    }

    @Test func theResultIsTheLastResultLineOfAStreamOrASingleObject() throws {
        let stream = "{\"type\":\"system\"}\n" + event(["type": "content_block_stop", "index": 0])
            + "{\"type\":\"result\",\"is_error\":true,\"result\":\"overloaded\"}\n"
        #expect(throws: (any Error).self) { try RouterRun.parse(OneShot.Output(stdout: Data(stream.utf8), stderr: Data(), status: 1)) }
        let text = "{\"type\":\"result\",\"is_error\":false,\"result\":\"All good\"}\n"
        #expect(try RouterRun.parse(OneShot.Output(stdout: Data(text.utf8), stderr: Data(), status: 0)).reply == "All good")
        // No result at all (killed before it): the failure names what Claude Code said.
        #expect(throws: RouterTools.Failure.self) {
            try RouterRun.parse(OneShot.Output(stdout: Data(stream.dropLast(70).utf8), stderr: Data("boom\n".utf8), status: 1))
        }
    }

    @Test func theLiveFeedPassesOnTheNewestAtMostTenTimesASecond() async {
        final class Seen: @unchecked Sendable { var all: [String] = [] }
        let seen = Seen()
        let feed = await MainActor.run { LiveFeed { seen.all.append($0.reply) } }
        for i in 1...50 { feed.push(RouterRunLive(reply: "\(i)")) }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(seen.all.last == "50" && seen.all.count <= 3, "got \(seen.all)")
        feed.push(RouterRunLive(reply: "51"))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(seen.all.last == "51")
    }
}
