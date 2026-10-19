import Foundation

/// The Router's routing trace: one JSON line per routed message, with what it was decided on (the board as the Router
/// saw it, Jev's answers, the fused ranking and its sureness, the ask card) and how it was decided, then lines for how
/// it ended (a button picked on the ask, a correction, a message sent and then cancelled, and asked again to send it
/// elsewhere). The first `decided` line of a message is what its outcomes join to; a re-ask is a `reasked` line, with
/// what it was decided on. It stays on this Mac, in Application Support/Fjord/router-trace.jsonl, with the message
/// redacted as it is for Jev. evals/router turns it into benchmark episodes of your real traffic, and the corrections
/// into labels: what in-session moments can only approximate.
struct RouterTrace: Codable, Equatable {
    /// What the fusion saw and made of it (RouteFusion): nil when the words alone, a rule or your own pick decided.
    struct Inputs: Codable, Equatable {
        struct Option: Codable, Equatable {
            var target: String
            var name: String
            var session: String?
        }
        struct Scored: Codable, Equatable {
            var target: String
            var p: Double
        }
        var options: [Option] = []
        /// Jev's answers: the route's probabilities by target, the card checks and next-message checks by session, the gates.
        var route: [String: Double] = [:]
        var reply: [String: Double] = [:]
        var next: [String: Double] = [:]
        var gates: [String: Double] = [:]
        /// BM25 per field, by session (normalised to the best, as the fusion reads it).
        var lexical: [String: [String: Double]] = [:]
        /// The board facts: finished sessions latest first, those working, minutes since each was active, last told.
        var latest: [String] = []
        var running: [String] = []
        var idle: [String: Double] = [:]
        var lastTold: String?
        /// The fused ranking (first eight), the pick's sureness, and whether it was sure enough to act.
        var ranked: [Scored] = []
        var sureness: Double?
        var sure = false
        var card: [String]?
        /// The request Jev was sent, as sent (already redacted): evals replay real traffic through another format with it.
        var request: String?
    }

    enum Kind: String, Codable { case decided, picked, corrected, cancelled, reasked, reverted }

    /// What the checks call read and made of it (`RouterActionChecks`), for a message it was asked for.
    struct Checks: Codable, Equatable {
        /// The yes of each check, by `dismiss:<card id>` and `stop:<session id>`.
        var p: [String: Double] = [:]
        var urgent = 0.0
        var instead = 0.0
        /// The sessions that could be stopped when it was asked.
        var stoppable: [String] = []
        /// The decision: `act`, `ask` or `route`, why, and the ask card's actions (their wire forms).
        var decision = ""
        var why = ""
        var options: [String]?
    }

    var kind: Kind
    var id: UUID
    var at = Date()
    /// `decided`: the message (redacted), what decided it, what it did and where.
    var message: String?
    var pills: [String]?
    var pinned: String?
    var shown: String?
    var notTo: String?
    var replyTo: String?
    var path: String?
    var action: String?
    var target: String?
    var inputs: Inputs?
    /// `decided`: the checks and what was decided on them, when they were asked.
    var checks: Checks?
    /// `decided` as `split`: the places the message was divided among (the target of each part), in order.
    var parts: [String]?
    /// `picked`: the button and its place on the card (0 first); `corrected`: also what was suggested.
    var index: Int?
    var from: String?
    /// `cancelled`: how far the message had gone (`RouterDecision.Cancelled`), seconds after it was sent, and whether it is
    /// to be sent elsewhere (a wrong send: `target` is where it went).
    var how: String?
    var after: Double?
    var elsewhere: Bool?
}

/// Appends trace lines off the main thread. Nowhere under a test unless a test gives it a file.
final class RouterTraceLog: @unchecked Sendable {
    static let shared = RouterTraceLog(url: UnderTest.isRunning ? nil : RouterTraceLog.defaultURL)
    /// The file grows to this, then the older half is dropped (a line is about 20 kB with its request: a few thousand routings).
    static let maxBytes = 256 << 20

    private let queue = DispatchQueue(label: "com.amontlabs.fjord.router-trace")
    private let lock = NSLock()
    private var _url: URL?
    var url: URL? {
        get { lock.withLock { _url } }
        set { lock.withLock { _url = newValue } }
    }

    init(url: URL?) { _url = url }

    static var defaultURL: URL {
        let dir = AppIdentity.supportDirectory()
        return dir.appendingPathComponent("router-trace.jsonl")
    }

    func append(_ line: RouterTrace) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            if let size = try? handle.offsetInFile, size > UInt64(Self.maxBytes) { Self.trim(url) }
        }
    }

    /// Waits for the lines written so far (tests).
    func flush() { queue.sync {} }

    private static func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let half = data.count / 2
        guard let cut = data[half...].firstIndex(of: 0x0A) else { return }
        try? Data(data[(cut + 1)...]).write(to: url, options: .atomic)
    }
}

extension RouterTrace.Inputs {
    /// From the rank effect's own values: the same features and sureness `RouteFusion.decide` read.
    @MainActor
    init(signals s: RouteFusion.Signals, facts f: RouterTools.Facts, destinations: [RouterTools.Destination],
         ranked: [RouterDispatcher.Scored], sure: Bool, card: [String], sessionOf: (String) -> String?) {
        options = destinations.map { Option(target: $0.target, name: $0.name, session: $0.sessionID) }
        route = s.route
        reply = s.reply
        next = s.next
        gates = s.gates
        lexical = s.lexical
        latest = f.latest
        running = f.running.sorted()
        idle = f.idleMinutes
        lastTold = f.lastTold
        self.ranked = ranked.prefix(8).map { Scored(target: $0.target, p: $0.p) }
        let x = RouteFusion.features(s, facts: f, sessionOf: sessionOf)
        sureness = RouteFusion.pick(RouteFusion.probabilities(x), features: x, signals: s, facts: f)?.sure
        self.sure = sure
        self.card = card
    }
}

extension RouterTrace.Checks {
    init(_ reading: RouterActionReading, _ decision: RouterActionDecision) {
        for c in reading.checks {
            switch c.kind {
            case .dismiss: p["dismiss:\(c.card ?? "")"] = c.p
            case .stop: p["stop:\(c.session)"] = c.p
            }
        }
        urgent = reading.urgent
        instead = reading.instead
        stoppable = reading.stoppable
        self.decision = decision.kind.rawValue
        why = decision.why
        options = decision.kind == .ask ? decision.options.map(\.wire) : nil
    }
}
