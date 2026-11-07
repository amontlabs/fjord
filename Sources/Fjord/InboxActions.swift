import Foundation
import os

// Actions: what a category does by itself when a thing comes in. Pure planning here (which runs are due, which are old
// news), the Store's runner and the real performer below. The user-facing contract is in docs/design/spec/inbox.md.

// MARK: - Model

/// When an action runs for a thing in the category.
enum ActionTrigger: String, Codable, Hashable {
    /// Once, when the thing comes into the category (and again if it left and came back after a while).
    case enter
    /// Once for each new fact the thing gains.
    case eachFact
}

enum ActionKind: Codable, Hashable {
    /// "Send to the Router": the prompt goes through the Router as yours, from the category, with the thing tagged; the Router
    /// sends it to a session working in the thing's repo or starts one in a local clone (`ActionPrompt`).
    case askRouter(prompt: ActionPrompt)
    case comment(String)
    /// Re-run the failed jobs of the failing workflow runs.
    case rerun

    /// It sends to Claude sessions through the Router: it runs and shows only while Triage and the Router are both on.
    var sendsToRouter: Bool { if case .askRouter = self { true } else { false } }

    // Written as the synthesized form was, so what is saved reads back. A `session(folder, prompt:)` saved before the Router
    // was the only way in is read as `askRouter` with the same prompt (the Router picks the folder now). A prompt saved before
    // prompts had pills is read with its placeholders made pills (`ActionPrompt.migrated`).
    private enum Key: String, CodingKey { case askRouter, session, comment, rerun }
    private enum Field: String, CodingKey { case _0 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if c.contains(.askRouter) || c.contains(.session) {
            let inner = try c.nestedContainer(keyedBy: ActionPrompt.CodingKeys.self, forKey: c.contains(.askRouter) ? .askRouter : .session)
            self = .askRouter(prompt: ActionPrompt(from: inner))
        } else if c.contains(.comment) {
            self = .comment(try c.nestedContainer(keyedBy: Field.self, forKey: .comment).decode(String.self, forKey: ._0))
        } else if c.contains(.rerun) {
            self = .rerun
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown action"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .askRouter(let prompt):
            var inner = c.nestedContainer(keyedBy: ActionPrompt.CodingKeys.self, forKey: .askRouter)
            try prompt.encode(to: &inner)
        case .comment(let text):
            var inner = c.nestedContainer(keyedBy: Field.self, forKey: .comment)
            try inner.encode(text, forKey: ._0)
        case .rerun:
            _ = c.nestedContainer(keyedBy: Field.self, forKey: .rerun)
        }
    }
}

struct CategoryAction: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: ActionKind
    var trigger: ActionTrigger = .enter

    var title: String {
        switch kind {
        case .askRouter: "Send to the Router"
        case .comment: "Comment on GitHub"
        case .rerun: "Re-run failed checks"
        }
    }

    var symbol: String {
        switch kind {
        case .askRouter: "sparkles"
        case .comment: "text.bubble"
        case .rerun: "arrow.clockwise"
        }
    }

    func applies(to kind: ThingKind) -> Bool {
        switch self.kind {
        case .askRouter: true
        case .comment: kind != .workflow
        case .rerun: kind != .issue
        }
    }

    static func make(_ kind: ActionKind) -> CategoryAction { CategoryAction(kind: kind) }
}

/// A category's actions. Written as a plain array.
struct ActionList: Codable, Hashable {
    var items: [CategoryAction] = []
    var isEmpty: Bool { items.isEmpty }

    init(_ items: [CategoryAction] = []) { self.items = items }
    /// Read one by one: an action of a kind this build no longer has (the headless "Run in a computer") is dropped, and the
    /// rest of the category stays.
    init(from decoder: Decoder) throws {
        items = try decoder.singleValueContainer().decode([Lossy<CategoryAction>].self).compactMap(\.value)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(items)
    }
}

// MARK: - What happened

/// One run of an action for a thing and a trigger key.
struct ActionRun: Codable, Hashable {
    enum State: String, Codable, Hashable {
        /// Already in the category when the action was made: old, never run.
        case baselined
        case running, done, failed
    }

    var category: UUID
    var thing: String
    var action: UUID
    /// `enter`, or a fact key.
    var trigger: String
    var state: State
    var at: Date
    /// done: "commented", "re-ran 2 jobs", "sent to <session>", "session started"; running: "waiting on you in the Router"
    /// while the Router asks you where its message goes; failed: why.
    var detail = ""
    /// The comment's page.
    var url: URL?
    /// The Claude app's id of the session the Router sent its message to, or started for it.
    var sessionID: String?
    /// The entry in the Router's history (its decision log id) the run left: what the Router made of its message follows
    /// it (`Store.followActionRun`).
    var message: UUID?
    /// For `enter`: when the thing was first seen out of the category since (nil while it is in).
    var left: Date?
}

/// Everything actions remember: what was already there when each category (or action) began, and each run.
struct ActionLedger: Codable, Equatable {
    struct Baseline: Codable, Equatable {
        /// A fingerprint of the category's rules (see `InboxActions.fingerprint`).
        var rules: String
        var actions: Set<UUID>
        /// The fingerprint is this build's (its sets sorted). Nil in a ledger saved before: one an earlier build wrote.
        var sorted: Bool?
    }

    var baselines: [UUID: Baseline] = [:]
    var runs: [String: ActionRun] = [:]
    /// PRs read again with every latest review (`InboxSync.reviewsShape`) since the last plan: the reviews they had all
    /// along, back now, are taken as old, once. Kept by an earlier build, every review of the PR; this one keeps
    /// `restoredReviewIDs` instead.
    var restoredReviews: Set<String>?
    /// The same, by PR: the ids of the reviews it had all along (made by the time it was last read), back now. One made
    /// since, while Fjord was closed, isn't among them, and is new.
    var restoredReviewIDs: [String: Set<String>]?
    /// Each such PR as it was last read, with the reviews it had all along back: the categories it was in then, and its
    /// facts there. Only those were there before; what it has besides (a commit pushed while Fjord was closed)
    /// is new.
    var restoredBefore: [String: [UUID: Set<String>]]?
    /// By category, then thing: a review request or assignment of yours that was there, not yet rated by Jev, when the
    /// category (or an action of it) was taken in. Its rating arriving later doesn't make the thing new (`AwaitedRating`).
    var awaitedRatings: [UUID: [String: AwaitedRating]]?

    /// A request or assignment (`InboxEngine.importanceStamp`) there when actions were taken in, its rating still to come:
    /// once rated, what the rating alone brings into the category is old for those actions, as it would have been had Jev
    /// rated it before.
    struct AwaitedRating: Codable, Equatable {
        var stamp: String
        /// The actions taken in then.
        var actions: Set<UUID>
        /// It was in the category then: only its importance facts for that request are old; else its entering and its
        /// facts there are.
        var wasIn: Bool
        /// By action, what it had in the category when that action was taken in, or would have had there rated (its
        /// importance aside): only those facts are old once it is rated. One made since (a comment) is new, and so is its
        /// entering when that brings it in. Nil from a build that didn't note them: all its facts there are old.
        var facts: [UUID: [String]]? = nil
    }

    static func key(_ category: UUID, _ thing: String, _ action: UUID, _ trigger: String) -> String {
        "\(category.uuidString)\u{1F}\(thing)\u{1F}\(action.uuidString)\u{1F}\(trigger)"
    }

    func run(_ category: UUID, _ thing: String, _ action: UUID, _ trigger: String) -> ActionRun? {
        runs[Self.key(category, thing, action, trigger)]
    }

    mutating func set(_ run: ActionRun) { runs[Self.key(run.category, run.thing, run.action, run.trigger)] = run }
}

// MARK: - Planning

enum InboxActions {
    /// Runs per sync; the rest wait for the next.
    static let perSync = 10
    /// How long a thing must have been out of a category, without a break, before coming back counts as entering again (a
    /// workflow that is re-run and fails again would otherwise be re-run for ever).
    static let reentryCooldown: TimeInterval = 3600
    /// Runs remembered, beyond those for what is still present (never forgotten while their trigger is there).
    static let maxRuns = 2000

    /// A thing's review request or assignment of yours (`InboxEngine.importanceStamp`), and whether Jev has rated it.
    struct Rating: Equatable {
        var stamp: String
        var rated: Bool
        /// Not rated yet: by category (one with an importance rule), the facts it would have there once rated, its
        /// importance aside.
        var facts: [UUID: [String]] = [:]
    }

    /// One action due for one thing.
    struct Job: Equatable {
        var category: InboxCategory
        var action: CategoryAction
        var entry: InboxEntry
        /// The trigger keys it answers: `enter`, or the new facts' keys.
        var keys: [String]
        var facts: [Fact]
    }

    // MARK: Loop guard

    /// Who made a fact, when it is about someone's act (a comment, review, commit, reply); nil for facts about state.
    private static func author(of key: String, in thing: Thing) -> String? {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let id = parts[1]
        switch parts[0] {
        case "comment", "mention", "last":
            return thing.comments.first { $0.id == id }?.author.login
                ?? thing.threads.lazy.compactMap { $0.mentions?.first { $0.id == id }?.author.login }.first
        case "review", "approved", "changes":
            return thing.reviews.first { $0.id == id }?.author.login ?? thing.comments.first { $0.id == id }?.author.login
        case "commit":
            return thing.commits.first { $0.id == id }?.author
        case "thread":
            return thing.threads.first { $0.id == id }?.lastReplyBy.login
        default:
            return nil
        }
    }

    /// Whether the event a fact is about (a comment, review, commit, thread reply) is no longer on the thing, so the fact can
    /// never be had again; false for facts about state, which may come back.
    private static func eventGone(_ key: String, _ thing: Thing) -> Bool {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        let id = parts[1]
        switch parts[0] {
        case "comment", "mention", "last", "person", "noise", "asks", "todo", "fyi":
            return !thing.comments.contains { $0.id == id } && !thing.threads.contains { $0.hasReply(id) }
                && !(parts[0] == "mention" && thing.threads.contains { $0.mentions?.contains { $0.id == id } == true })
        case "review", "approved", "changes":
            return !thing.reviews.contains { $0.id == id } && !thing.comments.contains { $0.id == id }
        case "commit":
            return !thing.commits.contains { $0.id == id }
        case "thread":
            return !thing.threads.contains { $0.id == id && (parts.count < 3 || $0.lastReplyID == parts[2]) }
        default:
            return false
        }
    }

    /// The facts that may trigger an action: not made by you, so an action's own comment (or any act of yours) never
    /// starts another.
    static func triggering(_ entry: InboxEntry, me: String) -> [Fact] {
        let mine = me.lowercased()
        return entry.facts.filter { fact in
            guard let who = author(of: fact.key, in: entry.thing) else { return true }
            return who.lowercased() != mine
        }
    }

    // MARK: Plan

    /// What the rules say, in a number that is the same at every launch: any edit of a rule (not only adding or removing
    /// one) makes what matches it old news. So does an edit of a group a rule names: adding Carol to it brings in what
    /// Carol already had, and that isn't new either. Rules that name no group read as they always did. A set (kinds, roles,
    /// states) is written in an order that changes at every launch: each list of plain values is sorted first.
    static func fingerprint(_ rules: [Rule], groups: [InboxGroup]) -> String {
        let (json, appendix) = fingerprintParts(rules, groups: groups)
        return hash(canonical(json) + appendix)
    }

    /// What a fingerprint saved by an earlier build says of the rules now.
    enum LegacyMatch { case same, different, unknown }

    /// Whether `stored` is the fingerprint of the same rules as written before they were sorted (in any order a launch
    /// may have given the sets), as ledgers saved by earlier builds hold it. Only what was a `Set` then is tried in other
    /// orders: a condition's states or statuses (`checks`, `status`, `workflow`); kinds and roles were already written in
    /// their cases' order, and a list (labels, people, repos) in yours. Bounded: past `limit` orders it is `unknown`.
    static func legacyFingerprint(_ stored: String, of rules: [Rule], groups: [InboxGroup], limit: Int = 5_000) -> LegacyMatch {
        let (json, appendix) = fingerprintParts(rules, groups: groups)
        let arrays = plainArrays(json).filter { array in
            setKeys.contains { key in json[..<array.range.lowerBound].reversed().starts(with: key.reversed()) }
        }
        var budget = limit
        var found = false
        // Every order of every set, the text around them kept.
        func walk(_ index: Int, _ built: [UInt8], _ from: Int) {
            guard !found, budget > 0 else { return }
            guard index < arrays.count else {
                budget -= 1
                if hash(built + json[from...] + appendix) == stored { found = true }
                return
            }
            let array = arrays[index]
            let prefix = built + json[from..<array.range.lowerBound]
            for order in permutations(array.items) {
                guard !found, budget > 0 else { return }
                walk(index + 1, prefix + joined(order), array.range.upperBound)
            }
        }
        walk(0, [], 0)
        return found ? .same : budget > 0 ? .different : .unknown
    }

    /// How a condition holding a set is written (`{"checks":{"_0":[…]}}`): the text right before the set's `[`. Never inside a
    /// string, where a quote is escaped.
    private static let setKeys = ["checks", "status", "workflow"].map { Array("\"\($0)\":{\"_0\":".utf8) }

    private static func fingerprintParts(_ rules: [Rule], groups: [InboxGroup]) -> (json: [UInt8], appendix: [UInt8]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(rules)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        var appendix: [UInt8] = []
        for group in groups.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where text.contains(group.id.uuidString) {
            let members = Set(group.members.map { $0.lowercased() }).sorted().joined(separator: "\u{1F}")
            appendix += Array("\u{1E}\(group.id.uuidString)\u{1F}\(group.kind.rawValue)\u{1F}\(members)".utf8)
        }
        return (Array(data), appendix)
    }

    private static func hash(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// JSON text with each list of plain values sorted, as written otherwise.
    static func canonical(_ json: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var from = 0
        for array in plainArrays(json) {
            out += json[from..<array.range.lowerBound]
            out += joined(array.items.sorted { $0.lexicographicallyPrecedes($1) })
            from = array.range.upperBound
        }
        return out + json[from...]
    }

    private static func joined(_ items: [ArraySlice<UInt8>]) -> [UInt8] {
        var out: [UInt8] = [UInt8(ascii: "[")]
        for (i, item) in items.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            out += item
        }
        out.append(UInt8(ascii: "]"))
        return out
    }

    /// Every order of a list; a long one (a set is a few values, a list of labels is kept in its order) only as it is.
    private static func permutations(_ items: [ArraySlice<UInt8>]) -> [[ArraySlice<UInt8>]] {
        guard items.count > 1, items.count <= 5 else { return [items] }
        var out: [[ArraySlice<UInt8>]] = []
        for i in items.indices {
            var rest = items
            let first = rest.remove(at: i)
            for tail in permutations(rest) { out.append([first] + tail) }
        }
        return out
    }

    /// Each array of JSON text holding only plain values (strings, numbers, literals): its range, `[` to `]` included,
    /// and its items as written. They never nest.
    private static func plainArrays(_ json: [UInt8]) -> [(range: Range<Int>, items: [ArraySlice<UInt8>])] {
        var out: [(range: Range<Int>, items: [ArraySlice<UInt8>])] = []
        // Open containers: whether each is an array, where it starts, whether it holds only plain values, its commas.
        var stack: [(array: Bool, start: Int, plain: Bool, commas: [Int])] = []
        var inString = false, escaped = false
        for (i, byte) in json.enumerated() {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                if !stack.isEmpty { stack[stack.count - 1].plain = false }
                stack.append((byte == UInt8(ascii: "["), i, true, []))
            case UInt8(ascii: ","):
                if !stack.isEmpty { stack[stack.count - 1].commas.append(i) }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                guard let open = stack.popLast() else { continue }
                guard open.array, open.plain, i > open.start + 1 else { continue }
                var items: [ArraySlice<UInt8>] = []
                var start = open.start + 1
                for comma in open.commas + [i] {
                    items.append(json[start..<comma])
                    start = comma + 1
                }
                out.append((open.start..<(i + 1), items))
            default:
                break
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Brings the ledger up to date with the categories (a category, rule set or action seen for the first time takes what
    /// is there as old; runs of what is gone are forgotten) and returns the runs that are due, in the order of the
    /// categories, newest things first.
    /// `known`: the ids of every thing still fetched, in a category now or not.
    /// `held`: actions held back (one that sends to the Router while Triage and the Router aren't both on): neither taken in
    /// nor due, their runs kept; no longer held, they are taken in as just added, so only what comes after runs them.
    static func plan(entries: [InboxEntry], categories: [InboxCategory], groups: [InboxGroup], ledger: inout ActionLedger,
                     me: String, known things: Set<String> = [], ratings: [String: Rating] = [:], now: Date = Date(),
                     held: (CategoryAction) -> Bool = { _ in false }) -> [Job] {
        let byCategory = Dictionary(grouping: entries, by: \.categoryID)
        let known = Set(categories.map(\.id))
        // Reviews a PR had all along, back since this build reads every latest one: old, as if they had been there.
        // Only those it had by the time it was last read: one made since is new. A review's opinion counts with it.
        if ledger.restoredReviews != nil || ledger.restoredReviewIDs != nil || ledger.restoredBefore != nil {
            let whole = ledger.restoredReviews ?? []
            let byID = ledger.restoredReviewIDs ?? [:]
            let before = ledger.restoredBefore ?? [:]
            func restored(_ key: String, of thing: String) -> Bool {
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, ["review", "approved", "changes"].contains(parts[0]) else { return false }
                return whole.contains(thing) || byID[thing]?.contains(parts[1]) == true
            }
            for category in categories {
                for entry in byCategory[category.id] ?? [] where whole.contains(entry.id) || byID[entry.id] != nil {
                    // In the category as last read, those reviews back (a "New review" one it is in only by them): it was
                    // there all along, its entering and the facts it had there then are old. Nothing else is.
                    let had = before[entry.id]?[category.id]
                    for action in category.actions.items where action.applies(to: entry.thing.kind) {
                        var keys = had.map { had in ["enter"] + entry.facts.map(\.key).filter(had.contains) } ?? []
                        if action.trigger == .eachFact { keys += entry.facts.map(\.key).filter { restored($0, of: entry.id) } }
                        for key in keys where ledger.run(category.id, entry.id, action.id, key) == nil {
                            ledger.set(ActionRun(category: category.id, thing: entry.id, action: action.id, trigger: key,
                                                 state: .baselined, at: now))
                        }
                    }
                }
            }
            ledger.restoredReviews = nil
            ledger.restoredReviewIDs = nil
            ledger.restoredBefore = nil
        }
        // Ratings awaited since a baseline that have come: what they alone bring is old for the actions taken in then. One
        // whose request or assignment is gone, or another now, is no longer awaited.
        if var awaited = ledger.awaitedRatings {
            for category in categories {
                guard var records = awaited[category.id] else { continue }
                for (thing, record) in records {
                    guard let rating = ratings[thing], rating.stamp == record.stamp else { records[thing] = nil; continue }
                    guard rating.rated else { continue }
                    records[thing] = nil
                    guard let entry = byCategory[category.id]?.first(where: { $0.id == thing }) else { continue }
                    let rated = entry.facts.map(\.key).filter { $0.hasPrefix("importance:") && $0.hasSuffix(":" + record.stamp) }
                    let others = entry.facts.map(\.key).filter { !rated.contains($0) }
                    for action in category.actions.items where record.actions.contains(action.id) && action.applies(to: entry.thing.kind) {
                        var keys = record.wasIn ? rated : ["enter"] + entry.facts.map(\.key)
                        // What it had then is old, and its entering if nothing else brings it in; what came since is new.
                        if let had = record.facts?[action.id].map(Set.init) {
                            keys = rated + others.filter(had.contains)
                            if !record.wasIn, others.allSatisfy(had.contains) { keys.insert("enter", at: 0) }
                        }
                        for key in keys where ledger.run(category.id, entry.id, action.id, key) == nil {
                            ledger.set(ActionRun(category: category.id, thing: entry.id, action: action.id, trigger: key,
                                                 state: .baselined, at: now))
                        }
                    }
                }
                awaited[category.id] = records.isEmpty ? nil : records
            }
            for id in awaited.keys where !known.contains(id) { awaited[id] = nil }
            ledger.awaitedRatings = awaited.isEmpty ? nil : awaited
        }
        // Baselines: what is there when a category's rules change, or an action is added, is old.
        for category in categories {
            let ruleIDs = fingerprint(category.rules, groups: groups)
            let taken = category.actions.items.filter { !held($0) }
            let actionIDs = Set(taken.map(\.id))
            var before = ledger.baselines[category.id]
            // Saved by a build that didn't sort the sets: the same rules, taken in once under their sorted number.
            // Too many orders to tell (several conditions of states): taken as the same rules too, the safer side. Such a
            // number is almost always the last one the earlier build saved for the rules as they still are; taking it as
            // changed would make old, silently, everything that came in since, and no action would ever run for it. What
            // was already run (or taken as old) keeps its record and isn't run again; only what has none is due.
            // A number this build wrote that isn't the rules' is an edit, whatever it is (and it may be too many orders to tell).
            if let stored = before?.rules, stored != ruleIDs, before?.sorted != true,
               legacyFingerprint(stored, of: category.rules, groups: groups) != .different {
                before?.rules = ruleIDs
            }
            let all = before == nil || before!.rules != ruleIDs
            let fresh = all ? taken : taken.filter { !(before?.actions.contains($0.id) ?? false) }
            for action in fresh {
                for entry in byCategory[category.id] ?? [] where action.applies(to: entry.thing.kind) {
                    for key in ["enter"] + entry.facts.map(\.key) {
                        let existing = ledger.run(category.id, entry.id, action.id, key)
                        if existing == nil {
                            ledger.set(ActionRun(category: category.id, thing: entry.id, action: action.id, trigger: key,
                                                 state: .baselined, at: now))
                        }
                    }
                }
            }
            // A request or assignment there now that Jev hasn't rated yet: its rating, when it comes, is old news too.
            let rates = category.rules.contains { $0.conditions.contains { if case .importance = $0 { true } else { false } } }
            if !fresh.isEmpty {
                var records = !rates || all ? [:] : ledger.awaitedRatings?[category.id] ?? [:]
                let inside = Dictionary((byCategory[category.id] ?? []).map { ($0.id, $0.facts.map(\.key)) }, uniquingKeysWith: { a, _ in a })
                for (thing, rating) in ratings where rates && !rating.rated {
                    var record = records[thing].flatMap { $0.stamp == rating.stamp ? $0 : nil }
                        ?? ActionLedger.AwaitedRating(stamp: rating.stamp, actions: [], wasIn: inside[thing] != nil, facts: [:])
                    record.actions.formUnion(fresh.map(\.id))
                    // What it has there now, or would have rated: its importance aside, what a rating then finds old.
                    var had: [String] = []
                    for key in (inside[thing] ?? []) + (rating.facts[category.id] ?? [])
                    where !key.hasPrefix("importance:") && !had.contains(key) { had.append(key) }
                    if record.facts != nil { for action in fresh { record.facts?[action.id] = had } }
                    records[thing] = record
                }
                var awaited = ledger.awaitedRatings ?? [:]
                awaited[category.id] = records.isEmpty ? nil : records
                ledger.awaitedRatings = awaited.isEmpty ? nil : awaited
            }
            let baseline = ActionLedger.Baseline(rules: ruleIDs, actions: actionIDs, sorted: true)
            if ledger.baselines[category.id] != baseline { ledger.baselines[category.id] = baseline }
        }
        for id in ledger.baselines.keys where !known.contains(id) { ledger.baselines[id] = nil }

        // Forget: runs of a category or action that is gone; entering records of a thing that has been out for a while.
        let actionIDs = Set(categories.flatMap { $0.actions.items.map(\.id) })
        // In the category is in it, whoever's facts hold it there: your own comment (the action's) leaving it in is no exit,
        // which would let another person's reply after the cooldown run the action again within one visit. Whose facts
        // they are counts only for what triggers a run.
        let inside = Set(entries.map { "\($0.categoryID.uuidString)\u{1F}\($0.id)" })
        for (key, run) in ledger.runs {
            if !known.contains(run.category) || !actionIDs.contains(run.action) {
                ledger.runs[key] = nil
            } else if run.trigger == "enter", run.state != .running {
                // Out for the cooldown on end, counted from when it left (not from the run): back sooner is the same visit.
                let isIn = inside.contains("\(run.category.uuidString)\u{1F}\(run.thing)")
                if isIn, let left = run.left {
                    // Seen back only now: out for the whole cooldown is a new visit, without a refresh in between to say so.
                    if now.timeIntervalSince(left) > reentryCooldown { ledger.runs[key] = nil } else { ledger.runs[key]?.left = nil }
                } else if !isIn, let left = run.left {
                    if now.timeIntervalSince(left) > reentryCooldown { ledger.runs[key] = nil }
                } else if !isIn {
                    ledger.runs[key]?.left = now
                }
            }
        }
        // Over the cap, only what nothing present can ask about again goes, oldest first: a run for a fact a thing still has
        // is what keeps it from running again, so it stays however many there are, and so do the runs of a thing still
        // fetched but out of the category for now (it may come back with the same facts). A fact not shown now (Jev's
        // reading off hides importance) may be shown again: in the category, only a run whose event (a comment, review,
        // commit, thread reply) is gone from the thing goes. Entering is forgotten only by the cooldown above.
        if ledger.runs.count > maxRuns {
            var present: Set<String> = []
            var inCategory: [String: Thing] = [:]
            for entry in entries {
                let prefix = "\(entry.categoryID.uuidString)\u{1F}\(entry.id)\u{1F}"
                for fact in entry.facts { present.insert(prefix + fact.key) }
                inCategory["\(entry.categoryID.uuidString)\u{1F}\(entry.id)"] = entry.thing
            }
            let drop = ledger.runs.filter { _, run in
                guard run.state != .running, run.trigger != "enter" else { return false }
                let key = "\(run.category.uuidString)\u{1F}\(run.thing)"
                if let thing = inCategory[key] { return !present.contains(key + "\u{1F}" + run.trigger) && eventGone(run.trigger, thing) }
                return !things.contains(run.thing)
            }
                .sorted { $0.value.at < $1.value.at }
                .prefix(ledger.runs.count - maxRuns)
            for (key, _) in drop { ledger.runs[key] = nil }
        }
        return due(entries: entries, categories: categories, groups: groups, ledger: ledger, me: me)
    }

    /// The runs due now, without changing anything.
    static func due(entries: [InboxEntry], categories: [InboxCategory], groups: [InboxGroup], ledger: ActionLedger,
                    me: String) -> [Job] {
        var jobs: [Job] = []
        for category in categories where !category.actions.isEmpty {
            // Not yet taken in: nothing is due (the baseline comes first).
            guard let baseline = ledger.baselines[category.id], baseline.rules == fingerprint(category.rules, groups: groups)
            else { continue }
            let mine = entries.filter { $0.categoryID == category.id && !$0.isDone }
                .sorted { ($0.thing.updatedAt, $0.id) > ($1.thing.updatedAt, $1.id) }
            for entry in mine {
                let facts = triggering(entry, me: me)
                guard !facts.isEmpty else { continue }
                // An action is run once per thing and fact however often its id is listed: its runs are kept by that id.
                var listed = Set<UUID>()
                for action in category.actions.items where action.applies(to: entry.thing.kind) {
                    guard baseline.actions.contains(action.id), listed.insert(action.id).inserted else { continue }
                    switch action.trigger {
                    case .enter:
                        if ledger.run(category.id, entry.id, action.id, "enter") == nil {
                            jobs.append(Job(category: category, action: action, entry: entry, keys: ["enter"], facts: facts))
                        }
                    case .eachFact:
                        let new = facts.filter { ledger.run(category.id, entry.id, action.id, $0.key) == nil }
                        if !new.isEmpty {
                            jobs.append(Job(category: category, action: action, entry: entry, keys: new.map(\.key), facts: new))
                        }
                    }
                }
            }
        }
        return jobs
    }

    /// A job planned before others ran, as it stands now: nil when it is no longer due (its action deleted or edited, its
    /// category's rules or groups changed, the thing out of the category or Done, its run recorded meanwhile), else for the
    /// facts it still has.
    static func stillDue(_ job: Job, entries: [InboxEntry], categories: [InboxCategory], groups: [InboxGroup],
                         ledger: ActionLedger, me: String) -> Job? {
        guard let category = categories.first(where: { $0.id == job.category.id }),
              category.actions.items.contains(job.action),
              let baseline = ledger.baselines[category.id], baseline.actions.contains(job.action.id),
              baseline.rules == fingerprint(category.rules, groups: groups),
              let entry = entries.first(where: { $0.id == job.entry.id && $0.categoryID == category.id && !$0.isDone })
        else { return nil }
        let facts = triggering(entry, me: me)
        guard !facts.isEmpty else { return nil }
        func unrecorded(_ key: String) -> Bool { ledger.run(category.id, entry.id, job.action.id, key) == nil }
        if job.keys == ["enter"], !unrecorded("enter") { return nil }
        var now = job
        now.category = category
        now.entry = entry
        if job.keys != ["enter"] {
            now.facts = facts.filter { job.keys.contains($0.key) && unrecorded($0.key) }
            now.keys = now.facts.map(\.key)
            if now.keys.isEmpty { return nil }
        } else {
            now.facts = facts
        }
        return now
    }

    // MARK: Words

    /// `{title} {url} {number} {repo} {author}` filled in, for a comment posted on GitHub. What others write goes in on one
    /// line, at most 120 characters.
    static func substitute(_ text: String, thing: Thing) -> String {
        let values: [(String, String)] = [
            ("{title}", inline(thing.title)), ("{url}", thing.url.absoluteString), ("{number}", thing.number.map(String.init) ?? ""),
            ("{repo}", thing.repo), ("{author}", inline(thing.author.map { "@" + $0.login } ?? "")),
        ]
        return values.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// `owner/repo` when it has GitHub's form (letters, digits, `-` for the owner; also `.` and `_` for the name), else nil.
    static func trustedRepo(_ repo: String) -> String? {
        repo.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil ? repo : nil
    }

    /// The thing's link when it is exactly GitHub's link to it (its repo, its kind, its number or run), else nil.
    static func trustedURL(_ thing: Thing) -> String? {
        let url = thing.url.absoluteString
        guard let repo = trustedRepo(thing.repo),
              url.range(of: #"^https://github\.com/[A-Za-z0-9._/-]+/(pull|issues|actions/runs)/[0-9]{1,12}(/job/[0-9]{1,15})?$"#,
                        options: .regularExpression) != nil,
              url.lowercased().hasPrefix("https://github.com/" + repo.lowercased() + "/") else { return nil }
        if thing.kind != .workflow, let n = thing.number, !url.hasSuffix("/\(n)") { return nil }
        return url
    }

    /// The reference said outside the GitHub block: `owner/repo#12`, or "a workflow run in owner/repo", only from values of
    /// GitHub's strict form; nil when they aren't.
    static func trustedReference(_ thing: Thing) -> String? {
        guard let repo = trustedRepo(thing.repo) else { return nil }
        if thing.kind == .workflow { return "a workflow run in \(repo)" }
        return thing.number.map { "\(repo)#\($0)" }
    }

    /// Text from GitHub as one short line: whitespace (newlines too) collapsed, cut at 120 characters.
    static func inline(_ text: String) -> String {
        neutralized(UntrustedText.clean(text, limit: 120))
    }

    static var fenceOpen: String { UntrustedFence.github.open }
    static var fenceClose: String { UntrustedFence.github.close }
    static var fenceWarning: String { UntrustedFence.github.warning }

    /// Content from GitHub made unable to close (or reopen) the fence it sits in.
    static func neutralized(_ text: String) -> String { UntrustedFence.github.neutralized(text) }

    /// Whether the rules can match things others write: any rule not strictly by you, or a comment, review, commit or thread
    /// condition not strictly by you. Conservative: unsure counts as yes.
    static func rulesMatchOthers(_ rules: [Rule]) -> Bool {
        let me = Pick<PersonRef>(include: [.me], except: [])
        func onlyMe(_ pick: Pick<PersonRef>?) -> Bool { pick == me }
        return rules.contains { rule in
            if !onlyMe(rule.scope.by) { return true }
            return rule.conditions.contains { condition in
                switch condition {
                case .newComment(let by, _), .newReview(let by, _), .newCommits(let by, _), .mentions(let by, _),
                     .lastComment(let by), .approved(let by), .changesRequested(let by):
                    return !onlyMe(by)
                case .unresolvedThreads(let started, let last):
                    return !onlyMe(started) || !onlyMe(last)
                default:
                    return false
                }
            }
        }
    }

    /// A category's name as untrusted metadata: cleaned, on one line, bounded, its fence tags broken up. Only ever placed
    /// inside a fenced block.
    static func categoryLabel(_ name: String) -> String { neutralized(UntrustedText.clean(name, limit: 80)) }

    /// The title of an action's message for its thing: the thing's reference and what it is about, in one short line.
    static func sessionTitle(_ thing: Thing) -> String {
        String((reference(thing) + " " + inline(thing.title)).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
    }

    static func reference(_ thing: Thing) -> String {
        switch thing.kind {
        case .workflow: "\(thing.repo) · \(thing.workflowName ?? "workflow") on \(thing.currentBranch ?? "its branch")"
        default: "\(thing.repo)#\(thing.number ?? 0)"
        }
    }

    // MARK: Chips

    /// What a row says about an action: the state of its latest run, or that it is waiting.
    struct Chip: Equatable, Identifiable {
        enum Target: Equatable { case session(String), url(URL), router }
        var id: UUID
        var label: String
        var tint: FactTint
        var target: Target?
        var help: String
        /// For `.router`: the entry in the Router's history the chip opens on.
        var message: UUID? = nil
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    static func chips(for entry: InboxEntry, category: InboxCategory, groups: [InboxGroup], ledger: ActionLedger, me: String,
                      now: Date = Date()) -> [Chip] {
        guard !category.actions.isEmpty else { return [] }
        let actions = category.actions.items.filter { $0.applies(to: entry.thing.kind) }
        var latest: [UUID: ActionRun] = [:]
        for run in ledger.runs.values where run.category == category.id && run.thing == entry.id && run.state != .baselined {
            // The first run at an equal date wins, as it did with max.
            if let before = latest[run.action], before.at >= run.at { continue }
            latest[run.action] = run
        }
        let queued: Set<UUID> = !entry.isDone && actions.contains(where: { latest[$0.id] == nil })
            ? Set(due(entries: [entry], categories: [category], groups: groups, ledger: ledger, me: me).map(\.action.id)) : []
        var out: [Chip] = []
        for action in actions {
            if let run = latest[action.id] {
                out.append(chip(run, action: action, ledger: ledger, now: now))
            } else if queued.contains(action.id) {
                out.append(Chip(id: action.id, label: "queued", tint: .neutral, target: nil, help: "\(action.title) runs on the next refresh"))
            }
        }
        return out
    }

    private static func chip(_ run: ActionRun, action: CategoryAction, ledger: ActionLedger, now: Date) -> Chip {
        switch run.state {
        case .running where run.detail == waitingWords:
            return Chip(id: action.id, label: waitingWords, tint: .attention, target: .router,
                        help: "The Router isn't sure where it goes. Open the Router to pick", message: run.message)
        case .running where run.sessionID != nil:
            return Chip(id: action.id, label: "session started", tint: .neutral, target: run.sessionID.map { .session($0) },
                        help: "Open the thread in T3 Code")
        case .running, .baselined:
            return Chip(id: action.id, label: "running…", tint: .neutral, target: nil, help: action.title)
        case .failed:
            let reason = run.detail.count > 48 ? String(run.detail.prefix(47)) + "…" : run.detail
            return Chip(id: action.id, label: "failed: \(reason)", tint: .danger, target: nil,
                        help: "\(action.title) failed: \(run.detail)")
        case .done:
            switch action.kind {
            case .askRouter:
                if let session = run.sessionID, run.detail.hasPrefix("sent to ") {
                    let label = run.detail.count > 48 ? String(run.detail.prefix(47)) + "…" : run.detail
                    return Chip(id: action.id, label: label, tint: .neutral, target: .session(session),
                                help: "Sent \(ago(run.at, now: now)). Open the thread in T3 Code")
                }
                if let session = run.sessionID {
                    return Chip(id: action.id, label: "session started \(ago(run.at, now: now))", tint: .neutral,
                                target: .session(session), help: "Open the thread in T3 Code")
                }
                return Chip(id: action.id, label: "sent to the Router", tint: .neutral, target: .router,
                            help: "Sent to the Router \(ago(run.at, now: now)). Open the Router", message: run.message)
            case .comment:
                return Chip(id: action.id, label: "commented", tint: .neutral, target: run.url.map { .url($0) },
                            help: "Open the comment on GitHub")
            case .rerun:
                return Chip(id: action.id, label: run.detail.isEmpty ? "re-ran" : run.detail, tint: .neutral, target: nil,
                            help: "Failed checks were re-run \(ago(run.at, now: now))")
            }
        }
    }
}

// MARK: - Doing

/// A workflow run that failed, and what re-running it takes.
struct FailedRun: Equatable {
    var id: Int
    var name: String
    var url: URL?
}

/// What actions do in the world. The Store has the real one; tests and the playground have their own (or none).
@MainActor
protocol ActionPerformer: AnyObject {
    /// Sends a "Send to the Router" action's message through the Router, as yours from its category: its entry in the
    /// Router's history, where what the Router makes of it goes on (`Store.followActionRun`). Throws why it couldn't.
    func sendToRouter(_ message: ActionMessage) async throws -> UUID
    /// Posts a comment; its page when GitHub says.
    func comment(repo: String, number: Int, body: String) async throws -> URL?
    /// The failed runs that re-running would take, for a PR's head commit or a workflow thing.
    func failedRuns(for thing: Thing) async throws -> [FailedRun]
    /// Re-runs one run's failed jobs; how many jobs.
    func rerun(repo: String, run: FailedRun) async throws -> Int
}

struct ActionFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension InboxActions {
    /// Does one job; the run that records it.
    @MainActor
    static func perform(_ job: Job, with performer: ActionPerformer, now: Date = Date()) async -> ActionRun {
        let thing = job.entry.thing
        var run = ActionRun(category: job.category.id, thing: thing.id, action: job.action.id, trigger: job.keys.first ?? "enter",
                            state: .done, at: now)
        do {
            switch job.action.kind {
            case .askRouter(let prompt):
                // Your words and pills, the thing's pill among them: what GitHub wrote goes only in the thing's fenced block.
                let origin = SessionOrigin(category: job.category.name, thing: sessionTitle(thing), actionID: job.action.id.uuidString,
                                           runID: UUID().uuidString)
                let source = RouterActionSource(origin: origin)
                // Sent: where it goes is the Router's to say, and the run follows it there.
                run.message = try await performer.sendToRouter(ActionMessage(parts: prompt.parts(thing: thing.id), source: source))
                run.state = .running
            case .comment(let text):
                guard let number = thing.number, thing.kind != .workflow else { throw ActionFailure("only PRs and issues take comments") }
                let body = substitute(text, thing: thing).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { throw ActionFailure("the comment is empty") }
                run.url = try await performer.comment(repo: thing.repo, number: number, body: body)
                run.detail = "commented"
            case .rerun:
                let failed = try await performer.failedRuns(for: thing)
                guard !failed.isEmpty else { throw ActionFailure("no failed run to re-run") }
                var jobs = 0
                for failure in failed { jobs += try await performer.rerun(repo: thing.repo, run: failure) }
                run.detail = jobs == 0 ? "re-ran" : "re-ran \(jobs) job\(jobs == 1 ? "" : "s")"
            }
        } catch {
            run.state = .failed
            run.detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        run.at = now
        return run
    }

    /// What "Try on latest match" shows: nothing is done, and no model is asked. `name`: a pill's name (the store's).
    @MainActor
    static func preview(_ action: CategoryAction, category: String, thing: Thing, facts: [Fact],
                        performer: ActionPerformer?, name: (RouterPointer) -> String = ActionPrompt.plainName) async -> [String] {
        guard action.applies(to: thing.kind) else { return ["Doesn't apply to \(thing.kind.label.lowercased()): skipped."] }
        var lines = ["On \(reference(thing)): \(thing.title)"]
        switch action.kind {
        case .askRouter(let prompt):
            let reference = RouterPointers.reference(thing)
            let words = ActionPrompt(prompt.parts(thing: thing.id)).words { pointer in
                if case .notification(let id) = pointer, id == thing.id { return reference }
                return name(pointer)
            }
            lines.append("Sends to the Router, as yours from \(category): \(words)")
            let addressed = prompt.pointers.contains { $0.addresses }
            lines.append(addressed ? "It goes to the claude.ai project or thread its pill names."
                         : "The Router sends it to the claude.ai project or thread it is for; if unsure, it asks you.")
            lines.append("With what Fjord knows of \(reference), marked as written by others:")
            lines.append(RouterPointers.notification(name: reference, thing: thing, category: category, facts: facts, done: false))
        case .comment(let text):
            let body = substitute(text, thing: thing)
            lines.append("Comments on \(reference(thing)):")
            lines.append(body.isEmpty ? "(empty: this would fail)" : body)
        case .rerun:
            if let performer, let failed = try? await performer.failedRuns(for: thing) {
                lines.append(failed.isEmpty ? "No failed run: nothing would be re-run."
                             : "Would re-run the failed jobs of: " + failed.map(\.name).joined(separator: ", ") + ".")
            } else {
                lines.append("Would re-run the failed jobs of its failing workflow runs.")
            }
        }
        return lines
    }
}

// MARK: - Local clones

enum LocalClones {
    /// The hosts a remote on GitHub has (`ssh.github.com` is its SSH over port 443).
    static let githubHosts: Set<String> = ["github.com", "www.github.com", "ssh.github.com"]
    static let remoteSchemes: Set<String> = ["https", "http", "ssh", "git", "git+ssh", "ssh+git"]

    /// `owner/repo` (lowercased) from a remote URL on GitHub: `scheme://[user@]github.com[:port]/owner/repo[.git]` or
    /// `[user@]github.com:owner/repo[.git]`. GitHub must be the URL's host, not a word in its path or query
    /// (`https://example.com/github.com/owner/repo` is not GitHub's); a query or fragment is dropped.
    static func repo(fromRemote url: String) -> String? {
        let url = url.trimmingCharacters(in: .whitespaces)
        var rest: Substring
        var host: Substring
        if let scheme = url.range(of: "://") {
            guard remoteSchemes.contains(url[..<scheme.lowerBound].lowercased()) else { return nil }
            let afterScheme = url[scheme.upperBound...]
            let authorityEnd = afterScheme.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? afterScheme.endIndex
            host = afterScheme[..<authorityEnd]
            rest = afterScheme[authorityEnd...]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            if let colon = host.lastIndex(of: ":") {
                guard host[host.index(after: colon)...].allSatisfy(\.isNumber) else { return nil }
                host = host[..<colon]
            }
        } else {
            // scp-like: what comes before the first ":" is the host (with its user), and has no "/" (else it is a path).
            guard let colon = url.firstIndex(of: ":") else { return nil }
            host = url[..<colon]
            guard !host.contains("/") else { return nil }
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            rest = url[url.index(after: colon)...]
        }
        guard githubHosts.contains(host.lowercased()) else { return nil }
        if let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
        var parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        parts = Array(parts.prefix(2))
        if parts[1].lowercased().hasSuffix(".git") { parts[1] = String(parts[1].dropLast(4)) }
        // GitHub's own names: letters, digits, `-`, `_` and `.`, and never `.` or `..` alone.
        let allowed = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber || "-_.".contains(c)) }
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy(allowed) }) else { return nil }
        return parts.joined(separator: "/").lowercased()
    }

    /// The GitHub repos a folder's git config names as remotes (a worktree's are its repo's: see `CodeFolders.configDir`).
    static func remotes(of folder: String) -> [String] { CodeFolders.remotes(of: folder) }

    /// The folders (shortest path first, so a checkout comes before its worktrees) whose remotes name `repo`.
    static func findAll(_ repo: String, in folders: [String], remotes: (String) -> [String] = remotes(of:)) -> [String] {
        let wanted = repo.lowercased()
        return folders.filter { !$0.isEmpty }.sorted { ($0.count, $0) < ($1.count, $1) }
            .filter { remotes($0).contains(wanted) }
    }
}

// MARK: - The Store's side

extension Store {
    /// Called after every inbox refresh: runs the actions that are due, off the refresh. None with Triage off (a refresh
    /// that was under way when it was switched off ends without them).
    func scheduleActions() {
        guard triageOn else { return }
        guard categories.contains(where: { !$0.actions.isEmpty }) || !actionLedger.runs.isEmpty || !actionLedger.baselines.isEmpty
        else { return }
        Task { @MainActor in await runActions() }
    }

    private var resolvedPerformer: ActionPerformer? {
        if let actionPerformer { return actionPerformer }
        guard persists, !Store.isDemo else { return nil }
        let real = StoreActionPerformer(store: self)
        actionPerformer = real
        return real
    }

    /// Takes in what changed (baselines) and runs what is due, at most `InboxActions.perSync` per call.
    func runActions(now: Date = Date()) async {
        guard triageOn, let performer = resolvedPerformer, let me = me?.login, !me.isEmpty else { return }
        // On the defaults (the state couldn't be read): taken in against them, the ledger would forget every run of your
        // categories, and take as new what they hold. Nothing runs, and nothing is taken in, until your categories are back.
        guard !onDefaults else { return }
        // An edit is waiting to be taken in: what it now matches is old news, and must not fire first.
        guard !baselinePending else { return }
        guard !actionsBusy else { actionsAgain = true; return }
        actionsBusy = true
        defer { actionsBusy = false }
        repeat {
            actionsAgain = false
            var ledger = actionLedger
            let jobs = InboxActions.plan(entries: entries, categories: categories, groups: groups, ledger: &ledger, me: me,
                                         known: Set(things.keys), ratings: actionRatings(), now: now, held: heldActions)
            if ledger != actionLedger { actionLedger = ledger }
            for queued in jobs.prefix(InboxActions.perSync) {
                // What ran before it may have taken long: it runs only if it is still due now, for what is still there.
                // Triage switched off while they run: nothing more reaches GitHub or a session.
                guard !baselinePending, triageOn, runnable(queued),
                      let job = InboxActions.stillDue(queued, entries: entries, categories: categories, groups: groups,
                                                      ledger: actionLedger, me: me) else { continue }
                // Each job is recorded as running just before it reaches outside, and nothing reaches outside before that
                // record is on disk: a quit during one leaves only that one interrupted, not those still waiting. A failed
                // write is tried again now, and if that fails too the run isn't made, and its record goes back to what it
                // was (due again at a later refresh).
                let before = actionLedger
                // The rules it was due under: an edit taken in meanwhile (a new baseline) makes it old, as what else they
                // match then.
                let rules = before.baselines[job.category.id]?.rules
                var running = before
                for key in job.keys {
                    var run = ActionRun(category: job.category.id, thing: job.entry.id, action: job.action.id,
                                        trigger: key, state: .running, at: now)
                    running.set(run)
                }
                actionLedger = running
                // The ledger as it is now, with `keys` of this job's records back to what they were before it; or, the rules
                // edited and taken in meanwhile, taken as old (with no record, it would be due again under the new ones).
                func undone(_ keys: [String]) -> ActionLedger {
                    var back = actionLedger
                    let superseded = back.baselines[job.category.id].map { $0.rules != rules } ?? false
                    for key in keys {
                        let id = ActionLedger.key(job.category.id, job.entry.id, job.action.id, key)
                        back.runs[id] = superseded
                            ? ActionRun(category: job.category.id, thing: job.entry.id, action: job.action.id, trigger: key,
                                        state: .baselined, at: now)
                            : before.runs[id]
                    }
                    return back
                }
                if await !actionsWritten() {
                    saveActions()
                    if await !actionsWritten() {
                        Self.actionsLog.error("An action wasn't run: its record couldn't be saved")
                        actionLedger = undone(job.keys)
                        return
                    }
                }
                // The write took a while: deleted, Done, no longer matching, its rules edited or Triage switched off meanwhile,
                // it isn't run (its record goes back, and that is written in turn).
                guard !baselinePending, triageOn, runnable(job), actionLedger.baselines[job.category.id]?.rules == rules,
                      let checked = InboxActions.stillDue(job, entries: entries, categories: categories, groups: groups,
                                                          ledger: undone(job.keys), me: me)
                else {
                    actionLedger = undone(job.keys)
                    continue
                }
                let dropped = job.keys.filter { !checked.keys.contains($0) }
                if !dropped.isEmpty { actionLedger = undone(dropped) }
                let result = await InboxActions.perform(checked, with: performer, now: now)
                var next = actionLedger
                for key in checked.keys {
                    var run = result
                    run.trigger = key
                    next.set(run)
                }
                actionLedger = next
                // A message the Router may have placed already: its runs say where it went.
                if let message = result.message { followActionRun(message) }
            }
        } while actionsAgain
    }

    /// The categories were edited: what they match now is taken as old once the edits pause (so typing doesn't thrash), and
    /// no action runs in between.
    /// What the categories newly ask GitHub for isn't taken in before it has been fetched: a category made for a repo not
    /// yet read would take in nothing, and the refresh after would bring its open PRs as new arrivals and act on them. It
    /// waits for refreshes that have answered each of its searches and workflow targets (`baselineIfFetched`).
    func categoriesEdited(delay: Duration = .seconds(1)) {
        baselinePending = true
        baselineAwaitsFetch = false
        baselineTask?.cancel()
        baselineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if unfetchedScope().isEmpty {
                baselineActions()
                baselinePending = false
                scheduleActions()
            } else {
                baselineAwaitsFetch = true
            }
        }
    }

    /// After a refresh: an edit that waited for what it asks for to be fetched is taken in once it has been.
    func baselineIfFetched() {
        guard baselinePending, baselineAwaitsFetch, unfetchedScope().isEmpty else { return }
        baselineActions()
        baselineAwaitsFetch = false
        baselinePending = false
    }

    /// The searches and workflow targets of the categories with actions that the things weren't fetched for. Nothing when
    /// it isn't known what they were fetched for (never loaded nor refreshed), or who you are.
    func unfetchedScope() -> Set<String> {
        guard let fetched = fetchedScopeKeys(), let me = me?.login, !me.isEmpty else { return [] }
        return InboxSync.scopeKeys(categories: categories.filter { !$0.actions.isEmpty }, groups: groups, me: me,
                                   owned: ownedRepos, contributed: contributedRepos, myTeams: myTeams,
                                   ownerRepos: inboxSyncState.ownerRepos).subtracting(fetched)
    }

    /// What an edit's actions wait to have read before anything runs (`baselineIfFetched`), as the inbox's status says it
    /// ("Actions paused until … can be read"): the repos and owners its searches name, else the searches, and the repos
    /// whose workflows it asks for. Nil when nothing waits.
    func actionsPausedFor() -> String? {
        guard baselinePending, baselineAwaitsFetch else { return nil }
        var seen = Set<String>()
        let names = unfetchedScope().sorted().map(Self.scopeName).filter { seen.insert($0.lowercased()).inserted }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? shown + " and \(names.count - 3) more" : shown
    }

    /// A scope key (`InboxSync.scopeKeys`) as said to you.
    nonisolated static func scopeName(_ key: String) -> String {
        if key.hasPrefix("workflow:") { return "\(key.dropFirst(9).prefix { $0 != "@" })'s workflows" }
        let query = key.hasPrefix("search:") ? String(key.dropFirst(7)) : key
        let tokens = query.split(separator: " ").map(String.init)
        let places = tokens.compactMap { token -> String? in
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, ["repo", "user", "org"].contains(parts[0].lowercased()) else { return nil }
            return parts[1]
        }
        if !places.isEmpty { return places.joined(separator: " or ") }
        let said = tokens.filter { !$0.hasPrefix("archived:") && !$0.hasPrefix("sort:") }.joined(separator: " ")
        return "“\(said)”"
    }

    /// The scope the things were fetched for, as keys (`InboxSync.scopeKeys`).
    func fetchedScopeKeys() -> Set<String>? {
        switch fetchedFor {
        case nil: return nil
        case .keys(let keys): return keys
        case .categories(let categories, let groups):
            guard let me = me?.login, !me.isEmpty else { return [] }
            return InboxSync.scopeKeys(categories: categories, groups: groups, me: me, owned: ownedRepos,
                                       contributed: contributedRepos, myTeams: myTeams, ownerRepos: inboxSyncState.ownerRepos)
        }
    }

    /// Takes what is in the categories now as old, for the actions they have.
    func baselineActions(now: Date = Date()) {
        guard let me = me?.login, !me.isEmpty, !onDefaults else { return }
        var ledger = actionLedger
        _ = InboxActions.plan(entries: entries, categories: categories, groups: groups, ledger: &ledger, me: me,
                              known: Set(things.keys), ratings: actionRatings(), now: now, held: heldActions)
        if ledger != actionLedger { actionLedger = ledger }
    }

    /// The actions held back now (`InboxActions.plan`): those that send to the Router while Triage and the Router aren't both on.
    var heldActions: (CategoryAction) -> Bool {
        let linked = toolsLinked
        return { !linked && $0.kind.sendsToRouter }
    }

    /// Each thing's review request or assignment of yours, and whether Jev has rated it (`InboxActions.plan`).
    func actionRatings() -> [String: InboxActions.Rating] {
        let context = inboxContext
        var out: [String: InboxActions.Rating] = [:]
        // Categories that rate: what a thing not yet rated would have in each once rated (at the most, any importance rule
        // takes it) is what it has there now, for the actions taken in before its rating.
        let rates = categories.filter { $0.rules.contains { $0.conditions.contains { if case .importance = $0 { true } else { false } } } }
        for (id, thing) in things {
            guard let stamp = InboxEngine.importanceStamp(thing, context: context) else { continue }
            let rated = InboxEngine.signals(thing, context.me)?.importance?.stamp == stamp
            var one = InboxActions.Rating(stamp: stamp, rated: rated)
            if !rated, context.jevSignals, !rates.isEmpty {
                let urgent = InboxEngine.rated(thing, .urgent, stamp: stamp, me: context.me)
                for category in rates {
                    let entry = InboxEngine.evaluate(things: [urgent], categories: [category], marks: marks, context: context).first
                    one.facts[category.id] = entry?.facts.map(\.key).filter { !$0.hasPrefix("importance:") } ?? []
                }
            }
            out[id] = one
        }
        return out
    }

    /// A row's chips: none of an action that sends to the Router while Triage and the Router aren't both on.
    func actionChips(for entry: InboxEntry) -> [InboxActions.Chip] {
        guard let category = categories.first(where: { $0.id == entry.categoryID }), !category.actions.isEmpty else { return [] }
        var shown = category
        // The Router's switch is read only for a category that has such an action (rows redraw with what they read).
        if shown.actions.items.contains(where: \.kind.sendsToRouter), !toolsLinked {
            shown.actions.items.removeAll { $0.kind.sendsToRouter }
        }
        return InboxActions.chips(for: entry, category: shown, groups: groups, ledger: actionLedger, me: me?.login ?? "")
    }

    /// Whether a job may still run: one that sends to the Router only while Triage and the Router are both on (switched off
    /// since it was planned, it isn't run; it is held back from the next plan on), and once routing is ready
    /// (`routingReady`): until then it stays due, and runs once it is.
    private func runnable(_ job: InboxActions.Job) -> Bool {
        guard job.action.kind.sendsToRouter else { return true }
        guard toolsLinked else { return false }
        if !routingReady { actionsAwaitRouting = true }
        return routingReady
    }

    /// Whether the Router knows enough to route an action's message: your threads heard from T3 (once asked for),
    /// and your code folders scanned with their remotes read, so a repo's clones are known. At launch the first refresh can
    /// come before them, and would find "No clone of …" where there are clones.
    var routingReady: Bool { (!threadsReadAsked || threadsReadOnce) && codeFolders.readyForRouting }

    /// Routing may have become ready: the actions left for it run now.
    func routingMayBeReady() {
        guard actionsAwaitRouting, routingReady else { return }
        actionsAwaitRouting = false
        scheduleActions()
    }

    /// The most recently updated thing the rules match, with its facts: what "Try on latest match" tries on.
    func latestMatch(of rules: [Rule]) -> (thing: Thing, facts: [Fact])? {
        let context = inboxContext
        var best: (Thing, [Fact])?
        for thing in things.values {
            for rule in rules {
                guard let facts = InboxEngine.facts(rule, thing, marks: nil, context: context) else { continue }
                if best == nil || thing.updatedAt > best!.0.updatedAt { best = (thing, facts) }
                break
            }
        }
        return best.map { (thing: $0.0, facts: $0.1) }
    }

    func openActionTarget(_ target: InboxActions.Chip.Target) {
        switch target {
        case .session(let id): openThread(id)
        case .router: break  // the chip opens the window on the Router (it has the environment for it)
        case .url(let url):
            if let interceptOpen { interceptOpen("Open on GitHub · comment") } else { Link.open(url) }
        }
    }

    // MARK: Persistence (its own small file next to the state)

    var actionsFile: URL? { stateFileURL?.deletingLastPathComponent().appendingPathComponent("actions.json") }

    /// `keepingAside`: the state wasn't read, so the categories are the defaults: the file is copied aside before it is
    /// first written over, as one read only in part is.
    func loadActions(keepingAside: Bool = false) {
        guard persists, let url = actionsFile else { return }
        let data: Data
        do {
            guard let read = try Store.readExisting(url) else { return }
            data = read
        } catch {
            // There but unreadable: not written over until it can be read and kept aside (see `saveActions`).
            Self.actionsLog.error("actions.json can't be read (it isn't written over until it can be): \(error.localizedDescription, privacy: .public)")
            actionsDisk.unreadable = true
            actionsSaveProblem = "actions.json can't be read: \(error.localizedDescription)"
            return
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // Record by record: one this build can't read is lost alone. With anything lost, the file is kept aside before it
        // is first written over (see `saveActions`), and what is there now is taken as old, as for a new action: a thing
        // whose record was lost is not acted on again for what it already had.
        let read = try? dec.decode(LossyLedger.self, from: data)
        var ledger = read?.ledger ?? ActionLedger()
        let lost = read?.lost ?? ["everything"]
        if !lost.isEmpty {
            Self.actionsLog.error("actions.json was read only in part (\(lost.joined(separator: ", "), privacy: .public) lost)")
            ledger.baselines = [:]
        }
        if keepingAside || !lost.isEmpty { actionsDisk.keepAside(data) }
        // Ordinary running actions are not retried after quit.
        for (key, run) in ledger.runs where run.state == .running {
            var r = run
            r.state = .failed
            r.detail = "interrupted"
            ledger.runs[key] = r
        }
        actionLedger = ledger
    }


    nonisolated private static let actionsLog = Logger(subsystem: InboxLog.subsystem, category: "actions")

    /// Each write is the whole ledger as of a revision: one that is written has every change before it on disk. One that
    /// fails is said in the log and tried again (2, 4, 8… seconds, a minute at most) unless a later one is written first.
    func saveActions() {
        guard persists, let url = actionsFile else { return }
        let ledger = ActionsBox(ledger: actionLedger)
        let disk = actionsDisk
        let revision = disk.ask()
        actionsWriter.async {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            do {
                // A file read only in part is copied aside first: until that works, it isn't written over.
                if disk.unreadable {
                    if let original = try Store.readExisting(url) { disk.keepAside(original) }
                    disk.unreadable = false
                }
                if let original = disk.unkept {
                    let backup = try Store.keepAside(original, of: url)
                    disk.keptAside()
                    Self.actionsLog.error("actions.json, read only in part, is kept as \(backup, privacy: .public)")
                }
                try enc.encode(ledger.ledger).write(to: url, options: .atomic)
                disk.wrote(revision)
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.actionsSaveProblem = nil } }
            } catch {
                let failures = disk.failed()
                let problem = "Saving actions.json failed: \(error.localizedDescription)"
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.actionsSaveProblem = problem } }
                Self.actionsLog.error("saving actions.json failed (\(failures, privacy: .public) in a row): \(error.localizedDescription, privacy: .public)")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(min(60, 1 << min(failures, 6))))
                    guard let self, disk.isBehind, disk.asked == revision else { return }
                    saveActions()
                }
            }
        }
    }

    /// Whether every change of the ledger made so far is on disk, once the writes asked are done: a run is recorded as
    /// running before what it does reaches outside (a relaunch then says it was interrupted rather than doing it again).
    @discardableResult
    func actionsWritten() async -> Bool {
        guard persists, actionsFile != nil else { return true }
        let wanted = actionsDisk.asked
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in actionsWriter.async { done.resume() } }
        return actionsDisk.written >= wanted
    }

    /// The same, waiting here (quitting): one that failed is tried once more.
    func flushActions() {
        actionsWriter.sync {}
        guard actionsDisk.isBehind else { return }
        saveActions()
        actionsWriter.sync {}
    }
}

private struct ActionsBox: @unchecked Sendable { let ledger: ActionLedger }

/// actions.json read record by record, saying what it couldn't read.
private struct LossyLedger: Decodable {
    var ledger = ActionLedger()
    var lost: [String] = []

    private enum CodingKeys: String, CodingKey {
        case baselines, runs, restoredReviews, restoredReviewIDs, restoredBefore, awaitedRatings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do { ledger.baselines = try c.decodeIfPresent([UUID: ActionLedger.Baseline].self, forKey: .baselines) ?? [:] } catch {
            lost.append("baselines")
        }
        do {
            // Required: a file without them (or with null) has lost every record, not had none.
            let all = try c.decode([String: Lossy<ActionRun>].self, forKey: .runs)
            ledger.runs = all.compactMapValues(\.value)
            if ledger.runs.count < all.count { lost.append("\(all.count - ledger.runs.count) of runs") }
        } catch {
            lost.append("runs")
        }
        // What is still to come (reviews back, ratings awaited) is kept across a restart: without it, what was there is new.
        do { ledger.restoredReviews = try c.decodeIfPresent(Set<String>.self, forKey: .restoredReviews) } catch {
            lost.append("restoredReviews")
        }
        do { ledger.restoredReviewIDs = try c.decodeIfPresent([String: Set<String>].self, forKey: .restoredReviewIDs) } catch {
            lost.append("restoredReviewIDs")
        }
        do { ledger.restoredBefore = try c.decodeIfPresent([String: [UUID: Set<String>]].self, forKey: .restoredBefore) } catch {
            lost.append("restoredBefore")
        }
        do {
            ledger.awaitedRatings = try c.decodeIfPresent([UUID: [String: ActionLedger.AwaitedRating]].self, forKey: .awaitedRatings)
        } catch {
            lost.append("awaitedRatings")
        }
    }
}

/// The revisions of the ledger asked to be written, and the latest written (the writes go in order, so it has every one
/// before it); read and changed from the writer and the main actor alike.
final class ActionsDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var _asked = 0, _written = 0, failures = 0
    private var _unkept: Data?

    /// What the file held when it was read only in part, until it is copied aside.
    var unkept: Data? { lock.withLock { _unkept } }
    func keepAside(_ data: Data) { lock.withLock { _unkept = data } }
    func keptAside() { lock.withLock { _unkept = nil } }
    private var _unreadable = false
    /// Whether the file was there but couldn't be read: until it can be (and is kept aside), it isn't written over.
    var unreadable: Bool {
        get { lock.withLock { _unreadable } }
        set { lock.withLock { _unreadable = newValue } }
    }

    var asked: Int { lock.withLock { _asked } }
    var written: Int { lock.withLock { _written } }
    var isBehind: Bool { lock.withLock { _written < _asked } }

    func ask() -> Int { lock.withLock { _asked += 1; return _asked } }
    func wrote(_ revision: Int) { lock.withLock { _written = max(_written, revision); failures = 0 } }
    /// Counts a failed write; returns how many in a row.
    func failed() -> Int { lock.withLock { failures += 1; return failures } }
}

// MARK: - The real performer

@MainActor
final class StoreActionPerformer: ActionPerformer {
    private unowned let store: Store
    init(store: Store) { self.store = store }


    func sendToRouter(_ message: ActionMessage) async throws -> UUID {
        // Only while Triage and the Router are both on: the dispatcher checks again before each step that reaches a session
        // (after a start, a session the app runs later), and the send's own gate once more.
        guard store.toolsLinked else { throw ActionFailure("Triage or the Router is off") }
        let (text, mentions) = store.composeForRouter(message.parts)
        var context = RouterContext()
        context.tag(mentions)
        context.action = message.source
        guard let id = store.routerDispatcher.submit(text, context: context) else { throw ActionFailure("the Router is off") }
        return id
    }

    func comment(repo: String, number: Int, body: String) async throws -> URL? {
        let data = try await store.gh.post("/repos/\(repo)/issues/\(number)/comments", ["body": body])
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["html_url"] as? String).flatMap { URL(string: $0) }
    }

    func failedRuns(for thing: Thing) async throws -> [FailedRun] {
        let path: String
        var query = ["per_page": "100"]
        var pages = Store.ciPages
        switch thing.kind {
        case .pr:
            // All the head commit's runs, page by page (bounded): a failing 51st workflow is one to re-run too.
            guard let sha = thing.headSha else { throw ActionFailure("its head commit isn't known yet") }
            path = "/repos/\(thing.repo)/actions/runs"
            query["head_sha"] = sha
        case .workflow:
            // `workflow:owner/repo:<id>@<branch>`: its own runs, newest first, whatever other workflows ran since.
            let id = thing.id.split(separator: ":").last.map { String($0.split(separator: "@").first ?? "") } ?? ""
            guard let number = Int(id) else { throw ActionFailure("checks that aren't GitHub Actions can't be re-run") }
            path = "/repos/\(thing.repo)/actions/workflows/\(number)/runs"
            // Its runs are listed under the name its branch has now (master renamed main lists none as master).
            query["branch"] = thing.currentBranch ?? ""
            query["event"] = "push"
            // On the commit its CI was read at (`ci:<sha>:…`), when known.
            if let run = thing.ciRun, run.hasPrefix("ci:"), case let parts = run.split(separator: ":"), parts.count > 2 {
                query["head_sha"] = String(parts[1])
            }
            query["per_page"] = "1"
            pages = 1
        case .issue:
            return []
        }
        var runs: [GHWorkflowRuns.Run] = []
        for page in 1...pages {
            query["page"] = "\(page)"
            let answer: GHWorkflowRuns = try await store.gh.get(path, query)
            runs += answer.workflowRuns
            if answer.workflowRuns.count < Int(query["per_page"]!)! || runs.count >= answer.totalCount ?? .max { break }
        }
        var seen = Set<Int>()
        var out: [FailedRun] = []
        // Newest first: the first of each workflow is its latest run.
        for run in runs where seen.insert(run.workflowId).inserted {
            guard let id = run.id, run.status == "completed", ["failure", "timed_out"].contains(run.conclusion ?? "") else { continue }
            out.append(FailedRun(id: id, name: run.name, url: run.htmlUrl))
        }
        return out
    }

    private struct Jobs: Decodable {
        struct Job: Decodable { let conclusion: String? }
        let jobs: [Job]
    }

    func rerun(repo: String, run: FailedRun) async throws -> Int {
        let jobs: Jobs? = try? await store.gh.get("/repos/\(repo)/actions/runs/\(run.id)/jobs", ["filter": "latest", "per_page": "100"])
        // Switched off while the jobs were read: CI isn't restarted.
        guard store.triageOn else { throw ActionFailure("Triage was switched off") }
        try await store.gh.post("/repos/\(repo)/actions/runs/\(run.id)/rerun-failed-jobs")
        return jobs?.jobs.filter { ["failure", "timed_out"].contains($0.conclusion ?? "") }.count ?? 0
    }
}
