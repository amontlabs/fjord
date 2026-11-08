import Foundation

/// TypeSafe's Jev (a "System One" model): given some state and a list of options, it picks one, with probabilities.
/// It doesn't write text, and only input is billed. https://docs.typesafe.ai/api
struct JevClient {
    let key: String
    var endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    var session = Network.session
    /// How long a call may take. Jev answers in about 0.25 s (p95 under 0.4 s, evals/router): routing waits far less than
    /// the default.
    var timeout: TimeInterval = 20
    /// What sends a request (tests answer for TypeSafe); the session otherwise.
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    var transport: Transport? = nil

    /// Why a call gave nothing, by what it means for the next one (`JevGate`): a rejected key waits for a new one, a busy
    /// TypeSafe for its Retry-After, a network failure for a while; a refused request or an odd answer is that call's alone.
    enum Failure: LocalizedError, Equatable {
        case unauthorized
        /// 429; `retryAfter` in seconds, when TypeSafe said.
        case rateLimited(retryAfter: TimeInterval?)
        /// 529 (or 503).
        case overloaded(retryAfter: TimeInterval?)
        /// No answer: the network, a timeout, another status.
        case transport(String)
        /// Stopped, or no longer allowed (the key or the switch changed meanwhile).
        case cancelled
        /// 422: TypeSafe refused this request.
        case refused(String)
        case invalidAnswer(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: "TypeSafe didn't accept the API key"
            case .rateLimited, .overloaded: "TypeSafe is busy, will retry later"
            case .transport(let why): why
            case .cancelled: "Stopped"
            case .refused(let body): "TypeSafe refused the request: \(body)"
            case .invalidAnswer(let why): why
            }
        }
    }

    struct Choice {
        let choice: String
        let confidence: Double
        /// Every option's probability (they sum to 1).
        let probabilities: [String: Double]
    }

    /// One typed question. Several go in one call (`ask`), each answered under its own key; only the input is billed.
    enum Question {
        /// One of `options` (a description for those whose name isn't enough).
        case choice([String], hints: [String: String] = [:], instructions: String)
        /// Yes or no: the probability of yes. `yes` and `no` say what each means when the question alone doesn't.
        case noul(instructions: String, yes: String? = nil, no: String? = nil)
        /// A rating on 2 to 10 ordered levels, lowest first.
        case score(levels: [String], instructions: String)
        /// One of `options`, each described by its JSON value in `criteria` (an object of named fields reads best), the
        /// instructions a string or an object (a `question` and the data it names in backticks). Answered as a `choice`.
        case structuredChoice([String], criteria: [String: Any], instructions: Any)
        /// Yes or no, the instructions an object holding the question and the data it is about. Answered as a `noul`.
        case structuredNoul(instructions: Any)
    }

    enum Answer {
        case choice(Choice)
        /// The probability of yes.
        case noul(Double)
        /// The probability-weighted level, 0 for the first level to `levels.count - 1` for the last.
        case score(Double, confidence: Double)

        var choice: Choice? { if case .choice(let c) = self { c } else { nil } }
        var yes: Double? { if case .noul(let p) = self { p } else { nil } }
        var score: Double? { if case .score(let s, _) = self { s } else { nil } }
        /// The score, only when Jev is at least `sure` of it.
        func score(sure: Double) -> Double? { if case .score(let s, let c) = self, c >= sure { s } else { nil } }
    }

    /// The order the questions of the calls made in this task are written in on the wire (the keys not listed follow, sorted).
    /// A dictionary has none: the Router's checks (`RouterActionChecks`) were measured in the order they are asked.
    @TaskLocal static var questionOrder: [String]?

    /// The model the calls made in this task go to. Nil: `jev-latest`. The routing question pins a version (the bars are tuned on it).
    @TaskLocal static var model: String?
    /// The version the routing question is asked of (J3: `jev-latest` moves; E4 and the thresholds are on 1.14).
    static let routingModel = "jev-1.14.0"

    /// Asks every question about `state` in one call.
    func ask(_ questions: [String: Question], about state: Any) async throws -> [String: Answer] {
        let (body, keys, ordered) = try Self.request(questions)
        let (wire, all) = Self.wire(body: body, state: state, ordered: ordered)
        let data = try await post(wire, ordered: all)
        return try Self.answers(data, questions: questions, keys: keys)
    }

    /// The request's bytes as `ask` posts them (the routing trace keeps them, so evals can replay real traffic exactly).
    static func requestData(_ questions: [String: Question], about state: Any) throws -> Data {
        let (body, _, ordered) = try request(questions)
        let (wire, all) = Self.wire(body: body, state: state, ordered: ordered)
        return try encode(wire, ordered: all)
    }

    /// The request body, its questions written in `questionOrder` when one is set.
    private static func wire(body: [String: Any], state: Any, ordered: [String: Data]) -> ([String: Any], [String: Data]) {
        let plain: [String: Any] = ["model": model ?? "jev-latest", "state": state, "questions": body]
        guard let order = questionOrder else { return (plain, ordered) }
        let listed = order.filter { body[$0] != nil }
        let keys = listed + body.keys.filter { !listed.contains($0) }.sorted()
        let placeholder = "\u{1}ordered-questions\u{1}"
        guard let object = try? orderedObject(keys.map { ($0, body[$0] ?? NSNull()) }) else { return (plain, ordered) }
        var all = ordered
        all[placeholder] = object
        return (["model": model ?? "jev-latest", "state": state, "questions": placeholder], all)
    }

    private static func request(_ questions: [String: Question]) throws
        -> (body: [String: Any], keys: [String: [String: String]], ordered: [String: Data]) {
        var body: [String: Any] = [:]
        var keys: [String: [String: String]] = [:]
        // A structured choice's options reach Jev in their own order (he leans toward the first: shuffled, the decision
        // changed on 14% of real messages, evals/router): its criteria object is written in order where a placeholder stood.
        var ordered: [String: Data] = [:]
        for (id, question) in questions {
            switch question {
            case .choice(let options, let hints, let instructions):
                guard let map = Self.keyMap(options) else { throw Failure.refused("Two options share a wire key") }
                keys[id] = map
                body[id] = ["type": "choice", "instructions": instructions,
                            "criteria": map.mapValues { option -> Any in hints[option] ?? NSNull() }]
            case .noul(let instructions, let yes, let no):
                var criteria: [String: Any] = [:]
                if let yes { criteria["true"] = yes }
                if let no { criteria["false"] = no }
                body[id] = ["type": "noul", "instructions": instructions, "criteria": criteria.isEmpty ? NSNull() as Any : criteria as Any]
            case .score(let levels, let instructions):
                body[id] = ["type": "score", "instructions": instructions, "criteria": levels]
            case .structuredChoice(let options, let criteria, let instructions):
                guard let map = Self.keyMap(options) else { throw Failure.refused("Two options share a wire key") }
                keys[id] = map
                let placeholder = "\u{1}ordered-criteria-\(ordered.count)\u{1}"
                ordered[placeholder] = try Self.orderedObject(options.map { (Self.key(for: $0), criteria[$0] ?? NSNull()) })
                body[id] = ["type": "choice", "instructions": instructions, "criteria": placeholder]
            case .structuredNoul(let instructions):
                body[id] = ["type": "noul", "instructions": instructions, "criteria": NSNull()]
            }
        }
        return (body, keys, ordered)
    }

    private static func answers(_ data: Data, questions: [String: Question], keys: [String: [String: String]]) throws
        -> [String: Answer] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = json["answers"] as? [String: Any] else { throw Failure.invalidAnswer("Unexpected answer from TypeSafe") }
        var out: [String: Answer] = [:]
        for (id, question) in questions {
            guard let answer = answers[id] as? [String: Any] else { throw Failure.invalidAnswer("TypeSafe left `\(id)` unanswered") }
            switch question {
            case .choice, .structuredChoice:
                out[id] = .choice(try Self.choice(answer, keys: keys[id] ?? [:]))
            case .noul, .structuredNoul:
                guard let p = Self.unit(answer["noul"]) else { throw Failure.invalidAnswer("TypeSafe's yes/no for `\(id)` is invalid") }
                out[id] = .noul(p)
            case .score(let levels, _):
                guard let value = Self.level(answer, count: levels.count), let confidence = Self.confidence(answer["confidence"]) else {
                    throw Failure.invalidAnswer("TypeSafe's score for `\(id)` is invalid")
                }
                out[id] = .score(value, confidence: confidence)
            }
        }
        return out
    }

    /// The best of `options` for `state`, and how sure Jev is. `hints` describes options whose name isn't enough.
    func choose(_ options: [String], hints: [String: String] = [:], for state: [String: String], instructions: String) async throws -> Choice {
        guard let choice = try await ask(["pick": .choice(options, hints: hints, instructions: instructions)], about: state)["pick"]?.choice else {
            throw Failure.invalidAnswer("Unexpected answer from TypeSafe")
        }
        return choice
    }

    /// A JSON object with its keys in the order given.
    static func orderedObject(_ pairs: [(String, Any)]) throws -> Data {
        var out = Data("{".utf8)
        for (i, (key, value)) in pairs.enumerated() {
            if i > 0 { out.append(contentsOf: Array(",".utf8)) }
            out.append(try JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed))
            out.append(contentsOf: Array(":".utf8))
            out.append(try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
        }
        out.append(contentsOf: Array("}".utf8))
        return out
    }

    /// The body as JSON, each placeholder string of `ordered` replaced by its ordered object.
    static func encode(_ body: [String: Any], ordered: [String: Data] = [:]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: body)
        for (placeholder, object) in ordered {
            let quoted = try JSONSerialization.data(withJSONObject: placeholder, options: .fragmentsAllowed)
            guard let range = data.range(of: quoted) else { continue }
            data.replaceSubrange(range, with: object)
        }
        return data
    }

    private func post(_ body: [String: Any], ordered: [String: Data] = [:]) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encode(body, ordered: ordered)
        let data: Data, response: URLResponse
        do {
            if let transport { (data, response) = try await transport(request) } else { (data, response) = try await session.data(for: request) }
        } catch is CancellationError {
            throw Failure.cancelled
        } catch let error as Failure {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw Failure.cancelled
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: return data
        case 401, 403: throw Failure.unauthorized
        case 422: throw Failure.refused(String(decoding: data.prefix(300), as: UTF8.self))
        case 429: throw Failure.rateLimited(retryAfter: Self.retryAfter(http))
        case 503, 529: throw Failure.overloaded(retryAfter: Self.retryAfter(http))
        case let status: throw Failure.transport("TypeSafe returned \(status)")
        }
    }

    /// Retry-After, in seconds or as an HTTP date.
    static func retryAfter(_ response: HTTPURLResponse?, now: Date = Date()) -> TimeInterval? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return format.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    static func key(for option: String) -> String {
        option.replacingOccurrences(of: ".", with: "_")
    }

    /// Each option by its wire key; nil when two share one ("a.b" and "a_b", or the same option twice): a request that
    /// could not tell them apart is never sent, rather than trapping or answering for the wrong one.
    static func keyMap(_ options: [String]) -> [String: String]? {
        var map: [String: String] = [:]
        for option in options where map.updateValue(option, forKey: key(for: option)) != nil { return nil }
        return map
    }

    /// A score brought to 0…count-1: a number (never a boolean) on the levels its legend numbers (from 0 or from 1, one
    /// key per level), or without a legend one that can only be on one of the two scales. Anything else, or out of range,
    /// is no score: never guessed or clamped.
    static func level(_ answer: [String: Any], count: Int) -> Double? {
        guard count > 1, let n = answer["score"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        let raw = n.doubleValue
        let last = Double(count - 1)
        let first: Double
        if let legend = answer["legend"] {
            guard let keys = (legend as? [String: Any])?.keys else { return nil }
            let numbers = keys.compactMap { Int($0) }.sorted()
            guard numbers.count == keys.count, numbers == Array(0..<count) || numbers == Array(1...count) else { return nil }
            first = Double(numbers[0])
        } else if raw < 1 {
            first = 0
        } else if raw > last {
            first = 1
        } else {
            return nil
        }
        let value = raw - first
        return (0...last).contains(value) ? value : nil
    }

    /// A confidence: none said is 0 (not sure); one said must be a number in 0…1.
    static func confidence(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return 0 }
        return unit(value)
    }

    private static func unit(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              (0...1).contains(n.doubleValue) else { return nil }
        return n.doubleValue
    }

    static func parse(_ data: Data, keys: [String: String]) throws -> Choice {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pick = (json["answers"] as? [String: Any])?["pick"] as? [String: Any] else {
            throw Failure.invalidAnswer("Unexpected answer from TypeSafe")
        }
        return try choice(pick, keys: keys)
    }

    static func choice(_ pick: [String: Any], keys: [String: String]) throws -> Choice {
        guard let key = pick["choice"] as? String, let option = keys[key] else {
            throw Failure.invalidAnswer("Unexpected answer from TypeSafe")
        }
        // The distribution is what callers decide on: one that is missing or doesn't add up is an error, never made up.
        guard let raw = pick["probabilities"] as? [String: Any], !raw.isEmpty else {
            throw Failure.invalidAnswer("TypeSafe's answer has no probabilities")
        }
        var probabilities: [String: Double] = [:]
        for (key, value) in raw {
            guard let option = keys[key], let p = unit(value) else { throw Failure.invalidAnswer("TypeSafe's probabilities are invalid") }
            probabilities[option] = p
        }
        guard (0.98...1.02).contains(probabilities.values.reduce(0, +)) else {
            throw Failure.invalidAnswer("TypeSafe's probabilities don't add up")
        }
        guard let confidence = confidence(pick["confidence"]) else { throw Failure.invalidAnswer("TypeSafe's confidence is invalid") }
        return Choice(choice: option, confidence: confidence, probabilities: probabilities)
    }
}
