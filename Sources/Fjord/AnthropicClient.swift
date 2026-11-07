import Foundation
import Security

// A small client for the Anthropic Messages API: one call with a system prompt, a user text and a JSON schema, answered as a
// typed value. Used by the routing decider instead of spawning `claude -p`. Structured output goes through
// `output_config.format` (Sonnet 5.5 rejects a forced `tool_choice`); the system block carries the cache breakpoint, so the
// stable role + schema prefix is reused while the board, which changes on every call, goes in the user message after it.
// Prompts under the model's minimum cacheable prefix (about 1-4k tokens) simply aren't cached; nothing breaks.

/// What a call cost, in tokens (the API's `usage`).
struct AnthropicUsage: Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
}

enum AnthropicError: Error, Equatable, Sendable, LocalizedError {
    /// No key in the Keychain (service `fjord-anthropic-key`).
    case noKey
    /// 401 or 403: the key is wrong, revoked or not allowed.
    case auth(String)
    /// 429 after the retry, with the server's `retry-after` when it sent one.
    case rateLimited(retryAfter: TimeInterval?)
    /// 529 or an `overloaded_error` after the retry.
    case overloaded
    /// The reply came but isn't the typed answer: a refusal, a cut-off, no text, or JSON that doesn't decode.
    case badOutput(String)
    /// Any other HTTP error (400 and the like, 5xx).
    case http(status: Int, message: String)
    case timeout
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .noKey: "No Anthropic key in the Keychain"
        case .auth(let m): "Anthropic refused the key: \(m)"
        case .rateLimited: "Anthropic rate limit reached"
        case .overloaded: "Anthropic is overloaded"
        case .badOutput(let m): "Anthropic's answer wasn't usable: \(m)"
        case .http(let s, let m): "Anthropic error \(s): \(m)"
        case .timeout: "Anthropic took too long"
        case .transport(let m): "Couldn't reach Anthropic: \(m)"
        }
    }
}

final class AnthropicClient: Sendable {
    static let keychainService = "fjord-anthropic-key"
    static let apiVersion = "2026-10-21"
    static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    /// The one session every call shares: HTTP/2 is negotiated on the first connection and kept alive, so later calls skip
    /// DNS, TCP and TLS. No cookies or disk cache; the system waits for no connectivity, a call fails fast instead.
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 2
        c.waitsForConnectivity = false
        c.httpShouldUsePipelining = true
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 60
        if let protocolClasses { c.protocolClasses = protocolClasses }
        return URLSession(configuration: c)
    }
    static let sharedSession = makeSession()

    /// Reads the key from the Keychain once and remembers it (a missing key is looked up again next time).
    static let keychainKey: @Sendable () -> String? = {
        let cache = KeyCache()
        return { cache.value() }
    }()

    private final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        func value() -> String? {
            lock.lock(); defer { lock.unlock() }
            if let key { return key }
            key = AnthropicClient.readKeychain()
            return key
        }
    }

    static func readKeychain(service: String = keychainService) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    let session: URLSession
    let baseURL: URL
    let apiKey: @Sendable () -> String?
    /// Seconds before a call gives up (per attempt).
    let timeout: TimeInterval
    /// `low` keeps Sonnet's thinking short; nil leaves the model's default.
    let effort: String?
    /// Waits before the retry; tests replace it.
    let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Multiplies the backoff (1...1.5 in production).
    let jitter: @Sendable () -> Double

    init(session: URLSession = AnthropicClient.sharedSession, baseURL: URL = AnthropicClient.defaultBaseURL,
         apiKey: @escaping @Sendable () -> String? = AnthropicClient.keychainKey, timeout: TimeInterval = 20, effort: String? = "low",
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
         jitter: @escaping @Sendable () -> Double = { Double.random(in: 1...1.5) }) {
        self.session = session; self.baseURL = baseURL; self.apiKey = apiKey; self.timeout = timeout; self.effort = effort
        self.sleep = sleep; self.jitter = jitter
    }

    /// Opens the connection (DNS, TCP, TLS, HTTP/2) ahead of the first call. Never throws.
    func warm() async {
        var r = URLRequest(url: baseURL)
        r.httpMethod = "HEAD"
        r.timeoutInterval = timeout
        _ = try? await session.data(for: r)
    }

    /// One structured call. `schema` is JSON Schema text; the answer decodes into `T`.
    func complete<T: Decodable>(system: String, user: String, schema: String, model: String, maxTokens: Int = 1024) async throws
        -> (value: T, usage: AnthropicUsage, latency: TimeInterval) {
        guard let data = schema.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicError.badOutput("the schema isn't a JSON object")
        }
        return try await complete(system: system, user: user, schema: object, model: model, maxTokens: maxTokens)
    }

    func complete<T: Decodable>(system: String, user: String, schema: [String: Any], model: String, maxTokens: Int = 1024) async throws
        -> (value: T, usage: AnthropicUsage, latency: TimeInterval) {
        guard let key = apiKey() else { throw AnthropicError.noKey }
        let body = try requestBody(system: system, user: user, schema: schema, model: model, maxTokens: maxTokens)
        let start = ContinuousClock.now
        var attempt = 0
        while true {
            do {
                let reply = try await send(body, key: key)
                let (value, usage): (T, AnthropicUsage) = try Self.parse(reply)
                let d = ContinuousClock.now - start
                return (value, usage, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            } catch let error as AnthropicError where attempt == 0 && Self.retryable(error) {
                attempt += 1
                try await sleep(Self.backoff(error, jitter: jitter()))
            }
        }
    }

    // MARK: Request

    /// The JSON body, keys sorted so the cached prefix is byte-identical between calls.
    func requestBody(system: String, user: String, schema: [String: Any], model: String, maxTokens: Int) throws -> Data {
        var output: [String: Any] = ["format": ["type": "json_schema", "schema": Self.strict(schema)]]
        if let effort { output["effort"] = effort }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
            "output_config": output,
            // Sonnet 5.5 can't disable thinking; between-tools keeps it off for a single answer.
            "thinking": ["type": "between_tools"],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Structured outputs want `additionalProperties: false` on every object.
    static func strict(_ schema: Any) -> Any {
        if var o = schema as? [String: Any] {
            for (k, v) in o { o[k] = strict(v) }
            if o["type"] as? String == "object", o["additionalProperties"] == nil { o["additionalProperties"] = false }
            return o
        }
        if let a = schema as? [Any] { return a.map(strict) }
        return schema
    }

    private func send(_ body: Data, key: String) async throws -> (status: Int, headers: [AnyHashable: Any], data: Data) {
        var r = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        r.httpMethod = "POST"
        r.httpBody = body
        r.timeoutInterval = timeout
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            let (data, response) = try await session.data(for: r)
            guard let http = response as? HTTPURLResponse else { throw AnthropicError.transport("no HTTP response") }
            return (http.statusCode, http.allHeaderFields, data)
        } catch let e as AnthropicError {
            throw e
        } catch let e as URLError where e.code == .timedOut {
            throw AnthropicError.timeout
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError {
            throw AnthropicError.transport(e.localizedDescription)
        }
    }

    // MARK: Reply

    static func parse<T: Decodable>(_ reply: (status: Int, headers: [AnyHashable: Any], data: Data)) throws -> (T, AnthropicUsage) {
        let json = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any]
        guard (200..<300).contains(reply.status) else { throw error(status: reply.status, headers: reply.headers, json: json) }
        guard let json else { throw AnthropicError.badOutput("the reply isn't JSON") }
        switch json["stop_reason"] as? String {
        case "refusal": throw AnthropicError.badOutput("the model declined")
        case "max_tokens": throw AnthropicError.badOutput("the answer was cut off at max_tokens")
        default: break
        }
        let text = (json["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
        guard let text, let data = text.data(using: .utf8) else { throw AnthropicError.badOutput("no text in the reply") }
        let value: T
        do { value = try JSONDecoder().decode(T.self, from: data) } catch {
            throw AnthropicError.badOutput("the answer doesn't decode: \(error.localizedDescription)")
        }
        let u = json["usage"] as? [String: Any] ?? [:]
        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        return (value, AnthropicUsage(inputTokens: n("input_tokens"), outputTokens: n("output_tokens"),
                                      cacheReadTokens: n("cache_read_input_tokens"), cacheCreationTokens: n("cache_creation_input_tokens")))
    }

    static func error(status: Int, headers: [AnyHashable: Any], json: [String: Any]?) -> AnthropicError {
        let err = json?["error"] as? [String: Any]
        let type = err?["type"] as? String
        let message = err?["message"] as? String ?? ""
        if status == 401 || status == 403 { return .auth(message) }
        if status == 529 || type == "overloaded_error" { return .overloaded }
        if status == 429 { return .rateLimited(retryAfter: retryAfter(headers)) }
        return .http(status: status, message: message)
    }

    static func retryAfter(_ headers: [AnyHashable: Any]) -> TimeInterval? {
        for (k, v) in headers where (k as? String)?.lowercased() == "retry-after" {
            return Double("\(v)".trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func retryable(_ e: AnthropicError) -> Bool {
        switch e {
        case .rateLimited, .overloaded: true
        default: false
        }
    }

    /// The server's `retry-after` (at most 10 s: the decider would rather ask than wait longer), else about a second; jittered.
    static func backoff(_ e: AnthropicError, jitter: Double) -> TimeInterval {
        if case .rateLimited(let after?) = e { return min(after, 10) * jitter }
        return 1 * jitter
    }
}
