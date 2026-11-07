import Foundation
import Testing
@testable import Fjord

/// Answers the client's requests from a closure instead of the network, and keeps what it was asked.
final class AnthropicStub: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var body: String }
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> Reply)?
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []
    private static let lock = NSLock()

    static func reset(_ h: @escaping (URLRequest, Data) -> Reply) {
        lock.lock(); handler = h; requests = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
        }
        Self.lock.lock()
        Self.requests.append((request, body))
        let h = Self.handler
        Self.lock.unlock()
        let reply = h?(request, body) ?? Reply(status: 500, body: "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/2", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct Answer: Decodable, Equatable { var word: String; var number: Int }

private let schema = #"{"type":"object","properties":{"word":{"type":"string"},"number":{"type":"integer"},"nested":{"type":"object","properties":{"a":{"type":"string"}}}},"required":["word","number"]}"#

private func ok(_ text: String = #"{"word":"hi","number":7}"#, stop: String = "end_turn") -> AnthropicStub.Reply {
    let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
    return .init(body: #"{"id":"m","type":"message","stop_reason":"\#(stop)","content":[{"type":"text","text":\#(escaped)}],"usage":{"input_tokens":12,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":3}}"#)
}

private func client(key: String? = "sk-test", sleeps: SleepLog = SleepLog()) -> AnthropicClient {
    AnthropicClient(session: AnthropicClient.makeSession(protocolClasses: [AnthropicStub.self]),
                    baseURL: URL(string: "https://stub.test")!, apiKey: { key }, timeout: 5,
                    sleep: { sleeps.add($0) }, jitter: { 1.25 })
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func add(_ v: TimeInterval) { lock.lock(); values.append(v); lock.unlock() }
    var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values }
}

private func call(_ c: AnthropicClient) async throws -> (value: Answer, usage: AnthropicUsage, latency: TimeInterval) {
    try await c.complete(system: "SYS", user: "the board", schema: schema, model: "claude-sonnet-5-5", maxTokens: 300)
}

@Suite(.serialized) struct AnthropicClientTests {
    @Test func requestShape() async throws {
        AnthropicStub.reset { _, _ in ok() }
        _ = try await call(client())
        let (request, body) = try #require(AnthropicStub.requests.first)
        #expect(request.url?.absoluteString == "https://stub.test/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == AnthropicClient.apiVersion)
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-sonnet-5-5")
        #expect(json["max_tokens"] as? Int == 300)
        // The cache breakpoint is on the system block; the changing board is in the user message, after it.
        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect(system[0]["text"] as? String == "SYS")
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "the board")
        // No forced tool_choice (Sonnet 5.5 rejects it), no sampling parameters.
        #expect(json["tool_choice"] == nil && json["tools"] == nil && json["temperature"] == nil)
        let output = try #require(json["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "low")
        let format = try #require(output["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let sent = try #require(format["schema"] as? [String: Any])
        #expect(sent["additionalProperties"] as? Bool == false)
        let nested = try #require((sent["properties"] as? [String: Any])?["nested"] as? [String: Any])
        #expect(nested["additionalProperties"] as? Bool == false)
        #expect(sent["required"] as? [String] == ["word", "number"])
    }

    @Test func bodyIsByteStableAcrossCalls() async throws {
        AnthropicStub.reset { _, _ in ok() }
        let c = client()
        _ = try await call(c); _ = try await call(c)
        #expect(AnthropicStub.requests.count == 2)
        #expect(AnthropicStub.requests[0].body == AnthropicStub.requests[1].body)
    }

    @Test func parsesAnswerAndUsage() async throws {
        AnthropicStub.reset { _, _ in ok() }
        let r = try await call(client())
        #expect(r.value == Answer(word: "hi", number: 7))
        #expect(r.usage == AnthropicUsage(inputTokens: 12, outputTokens: 5, cacheReadTokens: 100, cacheCreationTokens: 3))
        #expect(r.latency >= 0)
    }

    @Test func noKey() async {
        AnthropicStub.reset { _, _ in ok() }
        await #expect(throws: AnthropicError.noKey) { _ = try await call(client(key: nil)) }
        #expect(AnthropicStub.requests.isEmpty)
    }

    @Test func authErrors() async {
        AnthropicStub.reset { _, _ in .init(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#) }
        await #expect(throws: AnthropicError.auth("invalid x-api-key")) { _ = try await call(client()) }
        #expect(AnthropicStub.requests.count == 1)
    }

    @Test func retriesOnceOnRateLimitHonouringRetryAfter() async throws {
        let sleeps = SleepLog()
        var n = 0
        AnthropicStub.reset { _, _ in
            n += 1
            return n == 1 ? .init(status: 429, headers: ["Retry-After": "2"], body: #"{"error":{"type":"rate_limit_error","message":"slow"}}"#) : ok()
        }
        let r = try await call(client(sleeps: sleeps))
        #expect(r.value.word == "hi")
        #expect(AnthropicStub.requests.count == 2)
        #expect(sleeps.all == [2 * 1.25])
    }

    @Test func retriesOnceOnOverloaded() async throws {
        let sleeps = SleepLog()
        var n = 0
        AnthropicStub.reset { _, _ in
            n += 1
            return n == 1 ? .init(status: 529, body: #"{"error":{"type":"overloaded_error","message":"Overloaded"}}"#) : ok()
        }
        _ = try await call(client(sleeps: sleeps))
        #expect(AnthropicStub.requests.count == 2)
        #expect(sleeps.all == [1.25])
    }

    @Test func givesUpAfterOneRetry() async {
        AnthropicStub.reset { _, _ in .init(status: 529, body: #"{"error":{"type":"overloaded_error","message":"Overloaded"}}"#) }
        await #expect(throws: AnthropicError.overloaded) { _ = try await call(client()) }
        #expect(AnthropicStub.requests.count == 2)

        AnthropicStub.reset { _, _ in .init(status: 429, headers: ["retry-after": "30"], body: "{}") }
        let sleeps = SleepLog()
        await #expect(throws: AnthropicError.rateLimited(retryAfter: 30)) { _ = try await call(client(sleeps: sleeps)) }
        #expect(AnthropicStub.requests.count == 2)
        #expect(sleeps.all == [10 * 1.25]) // capped
    }

    @Test func otherErrorsAreNotRetried() async {
        AnthropicStub.reset { _, _ in .init(status: 400, body: #"{"error":{"type":"invalid_request_error","message":"bad schema"}}"#) }
        await #expect(throws: AnthropicError.http(status: 400, message: "bad schema")) { _ = try await call(client()) }
        #expect(AnthropicStub.requests.count == 1)
    }

    @Test func badOutput() async {
        AnthropicStub.reset { _, _ in ok("not json") }
        await #expect(throws: (any Error).self) { _ = try await call(client()) }
        for reply in [ok(#"{"word":"x"}"#), ok(stop: "refusal"), ok(stop: "max_tokens"), .init(body: #"{"content":[],"usage":{}}"#), .init(body: "<html>")] {
            AnthropicStub.reset { _, _ in reply }
            do { _ = try await call(client()); Issue.record("should have thrown") } catch let e as AnthropicError {
                guard case .badOutput = e else { Issue.record("wrong error \(e)"); continue }
            } catch { Issue.record("wrong error \(error)") }
        }
    }

    @Test func timeoutIsTyped() async {
        final class Slow: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
            override func stopLoading() {}
        }
        let c = AnthropicClient(session: AnthropicClient.makeSession(protocolClasses: [Slow.self]), baseURL: URL(string: "https://stub.test")!,
                                apiKey: { "k" }, timeout: 1)
        await #expect(throws: AnthropicError.timeout) { _ = try await call(c) }
    }

    @Test func warmNeverThrows() async {
        AnthropicStub.reset { _, _ in .init(status: 404, body: "") }
        await client().warm()
        #expect(AnthropicStub.requests.first?.request.httpMethod == "HEAD")
        #expect(AnthropicStub.requests.first?.request.value(forHTTPHeaderField: "x-api-key") == nil)
    }
}

/// FJORD_ANTHROPIC_LIVE=1: three real calls with a tiny prompt (a fraction of a cent); the first pays for TLS.
@Suite struct AnthropicLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FJORD_ANTHROPIC_LIVE"] == "1"))
    func liveSmoke() async throws {
        let schema = #"{"type":"object","properties":{"word":{"type":"string"},"number":{"type":"integer"}},"required":["word","number"]}"#
        let c = AnthropicClient()
        var latencies: [Double] = []
        for _ in 0..<3 {
            let r: (value: Answer, usage: AnthropicUsage, latency: TimeInterval) = try await c.complete(
                system: "Answer with a one-word colour and the number of letters in it.", user: "Colour of the sky.", schema: schema,
                model: "claude-sonnet-5-5", maxTokens: 100)
            #expect(!r.value.word.isEmpty)
            latencies.append(r.latency)
            print("LIVE latency \(String(format: "%.3f", r.latency))s in=\(r.usage.inputTokens) out=\(r.usage.outputTokens) answer=\(r.value)")
        }
    }
}
