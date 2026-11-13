import Foundation

// The per-project brief and what it is made of (docs/design/router-watch-and-briefs.md, 3 and 5.0). Nothing here talks to a
// model or a store: the types, the check of a model's answer, and the prose diff.

/// A thread's status on the Board.
enum ThreadState: String, Codable, Hashable, Sendable {
    case working, needsYou = "needs_you", paused, done
}

struct SentLine: Codable, Hashable, Sendable {
    var intent: String
    var words: String
    var state: String
}

/// What you act on: a thread that waits on you.
struct BriefEntry: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case question, plan, request, permission, stranded }

    var project: String
    var thread: String
    var kind: Kind
    var state: ThreadState
    var since: Double
    var asOf: Double?
    var question: String?
    var options: [String] = []
    /// What T3 says the thread waits on; live state, never stored.
    var request: ThreadRequest?
    var sent: [SentLine] = []
    /// What a read mark holds to (`BriefPage.entryKey`): the Board's status change or card; nil for the model's own entries,
    /// whose `since` stays as first written.
    var episode: String?

    var target: BriefTarget { BriefTarget(project: project, thread: thread) }

    private enum CodingKeys: String, CodingKey {
        case project, thread, kind, state, since, asOf = "as_of", question, options, sent, episode
    }

    static func == (a: BriefEntry, b: BriefEntry) -> Bool {
        a.project == b.project && a.thread == b.thread && a.kind == b.kind && a.state == b.state && a.since == b.since
            && a.asOf == b.asOf && a.question == b.question && a.options == b.options
            && a.request == b.request && a.sent == b.sent && a.episode == b.episode
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
    /// Set when T3 was unreachable: what it last saw, and when.
    var asOf: Double?
    /// How it ended, for a thread that stopped in the last day: the agent's last reply (its start and its end), so the brief
    /// sees a question or a request the reply leaves to you.
    var ends: String? = nil
    /// When that reply was last written (the run's end, else the thread's last activity).
    var endsAt: Double? = nil
    /// When its last run ended.
    var runEnded: Double? = nil
    /// The pull requests it links, with where each stands.
    var prs: [BriefPR] = []
    /// What it waits on you for, as T3 holds it: the request's text and the options it gives.
    var ask: String? = nil
    var askOptions: [String] = []
    /// When you last wrote to it.
    var sentAt: Double? = nil

    private enum CodingKeys: String, CodingKey { case id, title, status, age, asOf = "as_of", ends, endsAt, runEnded, prs, ask, askOptions, sentAt }
}

/// A pull request a thread links.
struct BriefPR: Codable, Hashable, Sendable {
    var url: String
    var number: Int?
    var state: PRState
}

struct BriefDoc: Codable, Equatable, Sendable {
    static let maxNow = 3
    static let maxEntries = 20

    var project: String
    var version = 0
    var at: Double = 0
    var purpose: String?
    var watch: String?
    var threads: [BriefThread] = []
    var now: [String] = []
    var needsYou: [BriefEntry] = []
    var sent: [SentLine] = []
    /// The last call failed: the prose below is being rewritten.
    var proseStale = false

    private enum CodingKeys: String, CodingKey {
        case project, version, at, purpose, watch, threads, now, needsYou = "needs_you"
        case sent, proseStale = "prose_stale"
    }

    /// The model-written fields, as stored in a version row (the deterministic ones are rebuilt, never stored).
    struct Prose: Codable, Equatable, Sendable {
        var purpose: String?
        var now: [String] = []
        var needsYou: [BriefEntry] = []

        private enum CodingKeys: String, CodingKey {
            case purpose, now, needsYou = "needs_you"
        }
    }

    var prose: Prose {
        get { Prose(purpose: purpose, now: now, needsYou: needsYou) }
        set { purpose = newValue.purpose; now = newValue.now; needsYou = newValue.needsYou }
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

    /// The model's whole answer. An old one's `decisions` and `loose_ends` are ignored.
    struct Answer: Codable {
        var now: [String]
        var needsYou: [RawEntry]
        var purpose: String?

        private enum CodingKeys: String, CodingKey { case now, needsYou = "needs_you", purpose }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            if let lines = try? c.decode([String].self, forKey: .now) { now = lines } else {
                now = ((try? c.decode(String.self, forKey: .now)) ?? "").split(separator: "\n").map(String.init)
            }
            needsYou = (try? c.decode([RawEntry].self, forKey: .needsYou)) ?? []
            purpose = try? c.decodeIfPresent(String.self, forKey: .purpose)
        }
    }

    struct Rejected: Error, CustomStringConvertible {
        var description: String
    }

    static let schema = #"{"type":"object","properties":{"now":{"type":"array","items":{"type":"string"}},"needs_you":{"type":"array","items":{"type":"object","properties":{"thread":{"type":"string"},"kind":{"type":"string","enum":["question","plan","request","permission","stranded"]},"question":{"type":"string"},"options":{"type":"array","items":{"type":"string"}}},"required":["thread","kind","question","options"],"additionalProperties":false}},"purpose":{"type":"string"}},"required":["now","needs_you","purpose"],"additionalProperties":false}"#

    static func parse(_ text: String) throws -> Answer {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b { s = String(s[a...b]) }
        do { return try JSONDecoder().decode(Answer.self, from: Data(s.utf8)) } catch { throw Rejected(description: "not the brief's JSON") }
    }

    /// The checked prose: thread ids must be on the Board (`threads`), and so must a `now` line's tagged ones (an unknown tag is
    /// dropped, its words kept), a card's options are the thread's request's, `now` is cut at three lines, an entry whose
    /// thread no longer waits on you is dropped, and every list is capped. A link may use only an address the Board holds.
    func checked(_ answer: Answer, at now: Double) -> Prose {
        let exists = Set(threads.map(\.id))
        var out = prose
        var cards: [String: [String]] = [:]
        for t in threads where !t.askOptions.isEmpty { cards[t.id] = t.askOptions }
        // A thread's tag stays only on a thread of the Board; its words stay either way.
        let tagged: (String) -> Bool = { exists.contains($0) }
        let sources = threads.flatMap { [$0.ends ?? "", $0.ask ?? ""] + $0.prs.map(\.url) }
        let links = (sources + self.now).reduce(into: Set<String>()) { $0.formUnion(BriefMarkup.addresses($1)) }
        let lines = answer.now.map { BriefMarkup.checked($0, known: tagged, links: links) }.filter { !BriefMarkup.plain($0).isEmpty }
        out.now = Array(lines.prefix(Self.maxNow))
        var seen = Set<String>()
        out.needsYou = answer.needsYou.compactMap { raw in
            guard let kind = BriefEntry.Kind(rawValue: raw.kind) else { return nil }
            guard exists.contains(raw.thread) else { return nil }
            let th = thread(raw.thread)
            // A thread working again waits on no one, stranded or not. A done thread waits on you when its reply asks (T3 flags
            // only requests it holds), and a stranded session stays on past its done.
            if let th, th.status == .working { return nil }
            guard seen.insert(raw.thread + "/" + raw.kind).inserted else { return nil }
            let old = needsYou.first { $0.thread == raw.thread && $0.kind == kind }
            // A card's options are the card's; the model's own are choices only when it gives two or more (one is no choice).
            let written = raw.options ?? []
            let options = cards[raw.thread] ?? (written.count > 1 ? written : [])
            return BriefEntry(project: project, thread: raw.thread, kind: kind, state: th?.status ?? .needsYou,
                              since: old?.since ?? now, asOf: th?.asOf,
                              question: raw.question, options: options, request: old?.request, sent: old?.sent ?? [])
        }
        out.needsYou = Array(out.needsYou.prefix(Self.maxEntries))
        if let p = answer.purpose, !p.isEmpty { out.purpose = p }
        return out
    }

    /// The lines that changed between two versions' prose: "+ " added, "- " removed.
    static func diff(_ old: Prose, _ new: Prose) -> String {
        func lines(_ p: Prose) -> [String] {
            p.now.map { "now: " + $0 }
                + p.needsYou.map { "needs you: \($0.thread) \($0.kind.rawValue): \($0.question ?? "")" }
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
}
