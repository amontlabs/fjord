import Foundation

// The per-project brief and what it is made of (docs/design/router-watch-and-briefs.md, 3 and 5.0). Nothing here talks to a
// model or a store: the types, the check of a model's answer, and the prose diff.

/// A thread's status on the Board.
enum ThreadState: String, Codable, Hashable, Sendable {
    case working, needsYou = "needs_you", paused, done
}

/// A thread of a project: the Board ids (a local-only session: its session id).
struct BriefTarget: Codable, Hashable, Sendable {
    var project: String
    var thread: String

    /// "project/thread": how a decision links it, and an MCP call names it.
    var key: String { project + "/" + thread }

    init(project: String, thread: String) {
        self.project = project
        self.thread = thread
    }

    /// From its `key` (the project's id never holds a slash; a thread's may).
    init?(key: String) {
        guard let slash = key.firstIndex(of: "/"), slash != key.startIndex, key.index(after: slash) != key.endIndex else { return nil }
        project = String(key[..<slash])
        thread = String(key[key.index(after: slash)...])
    }
}

struct SentLine: Codable, Hashable, Sendable {
    var intent: String
    var words: String
    var state: String
}

/// What you act on: a thread that waits on you.
struct BriefEntry: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case question, plan, request, permission, stranded }
    enum Source: String, Codable, Hashable, Sendable { case cloud, local }

    var project: String
    var thread: String
    var kind: Kind
    var state: ThreadState
    var since: Double
    var source: Source
    var asOf: Double?
    var question: String?
    var options: [String] = []
    /// The decision row's key (cloud).
    var card: String?
    /// The plugin hook's form (local); live state, never stored.
    var form: FormSnapshot?
    var sent: [SentLine] = []
    /// What a read mark holds to (`BriefPage.entryKey`): the Board's status change or card; nil for the model's own entries,
    /// whose `since` stays as first written.
    var episode: String?

    var target: BriefTarget { BriefTarget(project: project, thread: thread) }

    private enum CodingKeys: String, CodingKey {
        case project, thread, kind, state, since, source, asOf = "as_of", question, options, card, sent, episode
    }

    static func == (a: BriefEntry, b: BriefEntry) -> Bool {
        a.project == b.project && a.thread == b.thread && a.kind == b.kind && a.state == b.state && a.since == b.since
            && a.source == b.source && a.asOf == b.asOf && a.question == b.question && a.options == b.options && a.card == b.card
            && a.form == b.form && a.sent == b.sent && a.episode == b.episode
    }

    func hash(into h: inout Hasher) {
        h.combine(project); h.combine(thread); h.combine(kind); h.combine(question); h.combine(options)
    }
}

/// A thread of the deterministic list.
struct BriefThread: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var status: ThreadState
    /// When it started, or last changed.
    var age: Double
    var source: BriefEntry.Source = .cloud
    /// Set when the project's frame is stale: what it last saw, and when.
    var asOf: Double?

    private enum CodingKeys: String, CodingKey { case id, title, status, age, source, asOf = "as_of" }
}

struct BriefDecision: Codable, Hashable, Sendable {
    /// A thread id, or `BriefDoc.yourSend` for one of your messages.
    var thread: String
    var text: String
}

struct BriefDoc: Codable, Equatable, Sendable {
    static let yourSend = "send"
    /// The thread id of a question the project's coordinator asks in its own replies: you answer it in the project.
    static let coordinator = "coordinator"
    static let maxNow = 3
    static let maxEntries = 20
    static let maxDecisions = 10
    static let maxLooseEnds = 10

    var project: String
    var version = 0
    var at: Double = 0
    var purpose: String?
    var watch: String?
    var threads: [BriefThread] = []
    var now: [String] = []
    var needsYou: [BriefEntry] = []
    var decisions: [BriefDecision] = []
    var looseEnds: [String] = []
    var sent: [SentLine] = []
    /// The last call failed: the prose below is being rewritten.
    var proseStale = false

    private enum CodingKeys: String, CodingKey {
        case project, version, at, purpose, watch, threads, now, needsYou = "needs_you", decisions, looseEnds = "loose_ends"
        case sent, proseStale = "prose_stale"
    }

    /// The model-written fields, as stored in a version row (the deterministic ones are rebuilt, never stored).
    struct Prose: Codable, Equatable, Sendable {
        var purpose: String?
        var now: [String] = []
        var needsYou: [BriefEntry] = []
        var decisions: [BriefDecision] = []
        var looseEnds: [String] = []

        private enum CodingKeys: String, CodingKey {
            case purpose, now, needsYou = "needs_you", decisions, looseEnds = "loose_ends"
        }
    }

    var prose: Prose {
        get { Prose(purpose: purpose, now: now, needsYou: needsYou, decisions: decisions, looseEnds: looseEnds) }
        set { purpose = newValue.purpose; now = newValue.now; needsYou = newValue.needsYou; decisions = newValue.decisions; looseEnds = newValue.looseEnds }
    }

    func thread(_ id: String) -> BriefThread? { threads.first { $0.id == id } }

    // MARK: the model's answer

    /// One needs-you entry as the model wrote it.
    struct RawEntry: Codable {
        var thread: String
        var kind: String
        var question: String?
        var options: [String]?
    }

    /// The model's whole answer.
    struct Answer: Codable {
        var now: [String]
        var needsYou: [RawEntry]
        var decisions: [BriefDecision]
        var looseEnds: [String]
        var purpose: String?

        private enum CodingKeys: String, CodingKey { case now, needsYou = "needs_you", decisions, looseEnds = "loose_ends", purpose }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            if let lines = try? c.decode([String].self, forKey: .now) { now = lines } else {
                now = ((try? c.decode(String.self, forKey: .now)) ?? "").split(separator: "\n").map(String.init)
            }
            needsYou = (try? c.decode([RawEntry].self, forKey: .needsYou)) ?? []
            decisions = (try? c.decode([BriefDecision].self, forKey: .decisions)) ?? []
            looseEnds = (try? c.decode([String].self, forKey: .looseEnds)) ?? []
            purpose = try? c.decodeIfPresent(String.self, forKey: .purpose)
        }
    }

    struct Rejected: Error, CustomStringConvertible {
        var description: String
    }

    static let schema = #"{"type":"object","properties":{"now":{"type":"array","items":{"type":"string"}},"needs_you":{"type":"array","items":{"type":"object","properties":{"thread":{"type":"string"},"kind":{"type":"string","enum":["question","plan","request","permission","stranded"]},"question":{"type":"string"},"options":{"type":"array","items":{"type":"string"}}},"required":["thread","kind","question","options"],"additionalProperties":false}},"decisions":{"type":"array","items":{"type":"object","properties":{"thread":{"type":"string"},"text":{"type":"string"}},"required":["thread","text"],"additionalProperties":false}},"loose_ends":{"type":"array","items":{"type":"string"}}},"required":["now","needs_you","decisions","loose_ends"],"additionalProperties":false}"#

    static func parse(_ text: String) throws -> Answer {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b { s = String(s[a...b]) }
        do { return try JSONDecoder().decode(Answer.self, from: Data(s.utf8)) } catch { throw Rejected(description: "not the brief's JSON") }
    }

    /// The checked prose: thread ids must exist (in the Board's list or in the new items), a card's options are the card
    /// item's, `now` is cut at three lines, a decision names a thread or your send, an entry whose thread no longer waits on
    /// you is dropped, and every list is capped. `cards` maps a thread to the options of its latest card item.
    func checked(_ answer: Answer, known: Set<String>, cards: [String: [String]], at now: Double) -> Prose {
        let exists = known.union(threads.map(\.id))
        var out = prose
        let lines = answer.now.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        out.now = Array(lines.prefix(Self.maxNow))
        var seen = Set<String>()
        out.needsYou = answer.needsYou.compactMap { raw in
            guard let kind = BriefEntry.Kind(rawValue: raw.kind) else { return nil }
            guard exists.contains(raw.thread) || (raw.thread == Self.coordinator && kind == .request && !project.hasPrefix("local:")) else { return nil }
            let th = thread(raw.thread)
            // A thread working again waits on no one, stranded or not; a stranded session stays on past its done.
            if let th, th.status == .working || (kind != .stranded && th.status == .done) { return nil }
            guard seen.insert(raw.thread + "/" + raw.kind).inserted else { return nil }
            let old = needsYou.first { $0.thread == raw.thread && $0.kind == kind }
            let options = cards[raw.thread] ?? raw.options ?? []
            return BriefEntry(project: project, thread: raw.thread, kind: kind, state: th?.status ?? .needsYou,
                              since: old?.since ?? now, source: th?.source ?? .cloud, asOf: th?.asOf,
                              question: raw.question, options: options, card: old?.card, form: old?.form, sent: old?.sent ?? [])
        }
        out.needsYou = Array(out.needsYou.prefix(Self.maxEntries))
        out.decisions = Array(answer.decisions.filter { $0.thread == Self.yourSend || exists.contains($0.thread) }.prefix(Self.maxDecisions))
        out.looseEnds = Array(answer.looseEnds.filter { !$0.isEmpty }.prefix(Self.maxLooseEnds))
        if let p = answer.purpose, !p.isEmpty { out.purpose = p }
        return out
    }

    /// The lines that changed between two versions' prose: "+ " added, "- " removed.
    static func diff(_ old: Prose, _ new: Prose) -> String {
        func lines(_ p: Prose) -> [String] {
            p.now.map { "now: " + $0 }
                + p.needsYou.map { "needs you: \($0.thread) \($0.kind.rawValue): \($0.question ?? "")" }
                + p.decisions.map { "decided: \($0.thread): \($0.text)" }
                + p.looseEnds.map { "loose: " + $0 }
                + (p.purpose.map { ["purpose: " + $0] } ?? [])
        }
        let a = lines(old), b = lines(new)
        return (a.filter { !b.contains($0) }.map { "- " + $0 } + b.filter { !a.contains($0) }.map { "+ " + $0 }).joined(separator: "\n")
    }
}

/// One stored version of a project's brief.
struct BriefVersion: Equatable, Sendable {
    var project: String
    var version: Int
    var at: Double
    var prose: BriefDoc.Prose
    var diff: String
    /// The log positions of the items that made it.
    var items: [Int]
    var cursor: Int
}
