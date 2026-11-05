import Foundation
import SwiftUI

// The inbox as categories of things (PRs, issues, workflows) and the facts that put them there.
// A category is rules; a rule is a scope (which things) and conditions (when they need you). Every condition is a
// literal fact one could check on GitHub. A thing is in the first category, top to bottom, that one of its rules
// matches; unmatched things are dropped. Done is not a category: it is the things whose current facts you acknowledged.

// MARK: - Values

enum ThingKind: String, Codable, CaseIterable, Hashable {
    case pr, issue, workflow

    var label: String {
        switch self {
        case .pr: "PRs"
        case .issue: "Issues"
        case .workflow: "Workflows"
        }
    }
}

extension Set where Element == ThingKind {
    /// In the kinds' order: "PRs", "PRs and issues".
    var label: String {
        let words = ThingKind.allCases.filter(contains).enumerated().map { $0 == 0 ? $1.label : $1.label.lowercased() }
        guard let last = words.last else { return "Nothing" }
        return words.count == 1 ? last : words.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Someone a slot names.
enum PersonRef: Codable, Hashable {
    case me
    case user(String)
    case group(UUID)
    /// GitHub's role on the thing's repo: owner, member or collaborator.
    case maintainers
    /// Accounts GitHub marks as bots.
    case bots
    /// A team asked to review: `org/team` (shown `@org/team`). Only means something in `to`.
    case team(String)
    /// Every team you're in (resolved daily). Only means something in `to`.
    case myTeams
}

/// Somewhere a slot names.
enum RepoRef: Codable, Hashable {
    case repo(String)
    /// Every repo of an owner: `owner/*`.
    case owner(String)
    case group(UUID)
    case owned
    /// Repos with a merged or open PR of yours.
    case contributed
    /// PRs and issues only: you're the author, assignee or requested reviewer, were mentioned, or commented.
    case involved
}

/// A slot's values. Empty `include` means anyone/anywhere (only meaningful with `except`).
struct Pick<Value: Codable & Hashable>: Codable, Hashable {
    var include: [Value] = []
    var except: [Value] = []
}

/// What "to" covers; the word itself is a menu narrowing it.
enum ToRole: String, Codable, CaseIterable, Hashable {
    case assigned, reviewRequested, mentioned
}

/// Which things a rule is about. A nil slot was not added: it means any and isn't shown.
struct Scope: Hashable {
    /// At least one. PRs and issues share a rule; workflows are a rule of their own: they have no author and no `to`, need
    /// repos, and have branches and names nothing else has, so a rule mixing them would have no slots that fit it all.
    var kinds: Set<ThingKind>
    var by: Pick<PersonRef>?
    var to: Pick<PersonRef>?
    var toRoles: Set<ToRole> = Set(ToRole.allCases)
    /// Required for workflows.
    var `in`: Pick<RepoRef>?
    /// Workflows: branches; nil is the repo's default branch.
    var on: [String]?
    /// Workflows: names; nil is every workflow.
    var named: [String]?

    init(kinds: Set<ThingKind>, by: Pick<PersonRef>? = nil, to: Pick<PersonRef>? = nil, toRoles: Set<ToRole> = Set(ToRole.allCases),
         in repos: Pick<RepoRef>? = nil, on: [String]? = nil, named: [String]? = nil) {
        self.kinds = kinds
        self.by = by
        self.to = to
        self.toRoles = toRoles
        self.in = repos
        self.on = on
        self.named = named
    }

    /// A workflow rule: repos, branches and names rather than people.
    var isWorkflow: Bool { kinds.contains(.workflow) }
}

extension Scope: Codable {
    private enum CodingKeys: String, CodingKey { case kinds, kind, by, to, toRoles, `in`, on, named }
    /// Set (to anything) in an encoder's userInfo: the legacy `kind` is written too (the saved state; not the rules'
    /// fingerprint, which must not change for it, nor what the Router reads and writes).
    static let withLegacyKind = CodingUserInfoKey(rawValue: "fjord.scope.withLegacyKind")!

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Rules saved before a rule could be about more than one kind have `kind`, one value.
        kinds = try c.decodeIfPresent(Set<ThingKind>.self, forKey: .kinds) ?? [c.decode(ThingKind.self, forKey: .kind)]
        by = try c.decodeIfPresent(Pick<PersonRef>.self, forKey: .by)
        to = try c.decodeIfPresent(Pick<PersonRef>.self, forKey: .to)
        toRoles = try c.decodeIfPresent(Set<ToRole>.self, forKey: .toRoles) ?? Set(ToRole.allCases)
        self.in = try c.decodeIfPresent(Pick<RepoRef>.self, forKey: .in)
        on = try c.decodeIfPresent([String].self, forKey: .on)
        named = try c.decodeIfPresent([String].self, forKey: .named)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // In the kinds' order, so the same rule is always the same JSON.
        let ordered = ThingKind.allCases.filter(kinds.contains)
        try c.encode(ordered, forKey: .kinds)
        // In the saved state, the first of them as `kind` too, as builds from before `kinds` read it: going back to one keeps
        // the categories (it reads one kind of each rule) rather than losing every one for a rule it can't read.
        if encoder.userInfo[Self.withLegacyKind] != nil { try c.encodeIfPresent(ordered.first, forKey: .kind) }
        try c.encodeIfPresent(by, forKey: .by)
        try c.encodeIfPresent(to, forKey: .to)
        try c.encode(ToRole.allCases.filter(toRoles.contains), forKey: .toRoles)
        try c.encodeIfPresent(self.in, forKey: .in)
        try c.encodeIfPresent(on, forKey: .on)
        try c.encodeIfPresent(named, forKey: .named)
    }
}

enum CheckState: String, Codable, CaseIterable, Hashable {
    case failing, pending, passing
}

enum ThingStatus: String, Codable, CaseIterable, Hashable {
    case open, draft, merged, closed
}

/// What an activity condition counts events after.
enum Since: String, Codable, CaseIterable, Hashable {
    /// Since you last marked the thing done (or the rule was made): the default.
    case done
    /// After your latest review on the thing; with none, nothing matches.
    case myLastReview
    /// After your latest comment on the thing (a conversation comment, a review with text, a thread reply); with none,
    /// since the thing was created.
    case myLastComment
}

/// A fact a rule asks for. Activity conditions are events since a point (`Since`, by default you last marked the thing
/// done); the others are true or not right now.
enum Condition: Codable, Hashable {
    // Activity
    case newComment(by: Pick<PersonRef>, since: Since = .done)
    case newReview(by: Pick<PersonRef>, since: Since = .done)
    case newCommits(by: Pick<PersonRef>, since: Since = .done)
    case mentions(Pick<PersonRef>, since: Since = .done)
    // Conversation
    /// The latest Conversation-tab comment (reviews with text count, inline threads don't).
    case lastComment(by: Pick<PersonRef>)
    /// Open threads: unresolved and, when given, started by / last replied to by.
    case unresolvedThreads(startedBy: Pick<PersonRef>?, lastReplyBy: Pick<PersonRef>?)
    // Review, from each reviewer's latest review
    case approved(by: Pick<PersonRef>)
    case changesRequested(by: Pick<PersonRef>)
    // Checks
    case checks(Set<CheckState>)
    case hasConflicts
    /// The base branch has moved on (GitHub's mergeStateStatus BEHIND; only reported when the base branch's protection
    /// requires branches to be up to date).
    case behindBase
    // Status
    /// PRs/issues: draft, ready (= open and not draft), merged, closed. `.open` here means ready for review.
    case status(Set<ThingStatus>)
    case labeled(Pick<String>)
    case noActivity(days: Int)
    // Signals
    case greptileBelow(Int)
    /// A new comment, review or thread reply (not yours) that Jev labels any of these (InboxJev.swift). Asks and to do count
    /// only after your latest word there (answering ends them); fyi and noise since Done. Saved as `asksMe` before labels,
    /// it reads as asks or to do.
    case commentLabel(Set<CommentLabel>)
    /// A new comment (not yours) is noise (`true`: bots, and what Jev reads as automated) or from a person (`false`).
    case noise(Bool)
    /// Jev rates the review request or assignment at least this important.
    case importance(Importance)
    // Workflows
    case workflow(Set<CheckState>)
}

/// Jev's one label for a message (InboxJev.swift): what it asks of you, if anything. It changes how a row stands out, never
/// whether it is there or notifies; only a rule of yours that asks for a label does that.
enum CommentLabel: String, Codable, CaseIterable, Hashable {
    /// A question to you, or a decision only you can make.
    case asks
    /// A change or an action from you: rebase, fix, address a review, resolve a conflict.
    case todo
    /// Informative: nothing to do.
    case fyi
    /// Thanks, +1, an acknowledgement, bot chatter.
    case noise

    /// How it reads in a rule, a tag and the Router's tools.
    var title: String {
        switch self {
        case .asks: "asks me"
        case .todo: "to do"
        case .fyi: "FYI"
        case .noise: "noise"
        }
    }

    /// The row's tag.
    var tag: String {
        switch self {
        case .asks: "Asks you"
        case .todo: "To do"
        case .fyi: "FYI"
        case .noise: "Noise"
        }
    }

    /// Something for you to do: answering there ends it.
    var asksOfYou: Bool { self == .asks || self == .todo }

    /// Most attention first: a row with several shows the first.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// How much a review request or an assignment matters, as Jev rates it (InboxJev.swift).
enum Importance: String, Codable, CaseIterable, Comparable, Hashable {
    case low, normal, high, urgent

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (a: Importance, b: Importance) -> Bool { a.rank < b.rank }
}

// Rules saved before `since` have no such key: the activity cases are read by hand, the rest as they always were.
extension Condition {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum ActivityKey: String, CodingKey { case by, _0, since }

    private enum Activity: String { case newComment, newReview, newCommits, mentions }

    /// Every case but the activity ones, encoded the way the synthesized coding always did.
    private enum Other: Codable {
        case lastComment(by: Pick<PersonRef>)
        case unresolvedThreads(startedBy: Pick<PersonRef>?, lastReplyBy: Pick<PersonRef>?)
        case approved(by: Pick<PersonRef>)
        case changesRequested(by: Pick<PersonRef>)
        case checks(Set<CheckState>)
        case hasConflicts
        case behindBase
        case status(Set<ThingStatus>)
        case labeled(Pick<String>)
        case noActivity(days: Int)
        case greptileBelow(Int)
        /// Saved before labels: read as asks or to do, never written.
        case asksMe
        case commentLabel(Set<CommentLabel>)
        case noise(Bool)
        case importance(Importance)
        case workflow(Set<CheckState>)

        init?(_ c: Condition) {
            switch c {
            case .newComment, .newReview, .newCommits, .mentions: return nil
            case .lastComment(let by): self = .lastComment(by: by)
            case .unresolvedThreads(let a, let b): self = .unresolvedThreads(startedBy: a, lastReplyBy: b)
            case .approved(let by): self = .approved(by: by)
            case .changesRequested(let by): self = .changesRequested(by: by)
            case .checks(let s): self = .checks(s)
            case .hasConflicts: self = .hasConflicts
            case .behindBase: self = .behindBase
            case .status(let s): self = .status(s)
            case .labeled(let p): self = .labeled(p)
            case .noActivity(let d): self = .noActivity(days: d)
            case .greptileBelow(let n): self = .greptileBelow(n)
            case .commentLabel(let s): self = .commentLabel(s)
            case .noise(let b): self = .noise(b)
            case .importance(let i): self = .importance(i)
            case .workflow(let s): self = .workflow(s)
            }
        }

        var condition: Condition {
            switch self {
            case .lastComment(let by): .lastComment(by: by)
            case .unresolvedThreads(let a, let b): .unresolvedThreads(startedBy: a, lastReplyBy: b)
            case .approved(let by): .approved(by: by)
            case .changesRequested(let by): .changesRequested(by: by)
            case .checks(let s): .checks(s)
            case .hasConflicts: .hasConflicts
            case .behindBase: .behindBase
            case .status(let s): .status(s)
            case .labeled(let p): .labeled(p)
            case .noActivity(let d): .noActivity(days: d)
            case .greptileBelow(let n): .greptileBelow(n)
            case .asksMe: .commentLabel([.asks, .todo])
            case .commentLabel(let s): .commentLabel(s)
            case .noise(let b): .noise(b)
            case .importance(let i): .importance(i)
            case .workflow(let s): .workflow(s)
            }
        }
    }

    init(from decoder: Decoder) throws {
        let top = try decoder.container(keyedBy: AnyKey.self)
        guard let key = top.allKeys.first, let kind = Activity(rawValue: key.stringValue) else {
            self = try Other(from: decoder).condition
            return
        }
        let c = try top.nestedContainer(keyedBy: ActivityKey.self, forKey: key)
        // `by` for the labeled cases, `_0` for mentions.
        let pick = try c.decodeIfPresent(Pick<PersonRef>.self, forKey: .by) ?? c.decode(Pick<PersonRef>.self, forKey: ._0)
        let since = try c.decodeIfPresent(Since.self, forKey: .since) ?? .done
        switch kind {
        case .newComment: self = .newComment(by: pick, since: since)
        case .newReview: self = .newReview(by: pick, since: since)
        case .newCommits: self = .newCommits(by: pick, since: since)
        case .mentions: self = .mentions(pick, since: since)
        }
    }

    func encode(to encoder: Encoder) throws {
        let name: String, pick: Pick<PersonRef>, since: Since
        let labeled: Bool
        switch self {
        case .newComment(let p, let s): (name, pick, since, labeled) = ("newComment", p, s, true)
        case .newReview(let p, let s): (name, pick, since, labeled) = ("newReview", p, s, true)
        case .newCommits(let p, let s): (name, pick, since, labeled) = ("newCommits", p, s, true)
        case .mentions(let p, let s): (name, pick, since, labeled) = ("mentions", p, s, false)
        default:
            try Other(self)?.encode(to: encoder)
            return
        }
        var top = encoder.container(keyedBy: AnyKey.self)
        var c = top.nestedContainer(keyedBy: ActivityKey.self, forKey: AnyKey(stringValue: name)!)
        try c.encode(pick, forKey: labeled ? .by : ._0)
        if since != .done { try c.encode(since, forKey: .since) }
    }
}

enum MatchMode: String, Codable, Hashable {
    case any, all
}

struct Rule: Codable, Hashable, Identifiable {
    var id = UUID()
    var scope: Scope
    var match: MatchMode = .any
    /// Empty: every open thing in scope.
    var conditions: [Condition] = []
    /// Activity before this counts as old (a new rule doesn't flood you with history).
    var createdAt = Date()
}

/// A category's tint: Claude's palette, by name so it survives design changes.
enum CategoryColor: String, Codable, CaseIterable, Hashable {
    case clay, amber, green, aqua, blue, violet, magenta, red, gray
}

struct InboxCategory: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// SF Symbol.
    var symbol: String
    var color: CategoryColor
    var rules: [Rule] = []
    /// Native notifications.
    var notifies = true
    /// Hidden from the bar and muted; still collects.
    var hidden = false
    /// CI: the default category, whose rules only take repos.
    var isCI = false
    /// What it does by itself when a thing comes in (InboxActions.swift).
    var actions = ActionList()
    /// The bar's section it is in (CategorySections.swift); nil, or one deleted since, is the first.
    var section: UUID? = nil

    /// What the bar and the lists call it; a category still being named is "Untitled".
    var title: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name }
}

extension InboxCategory {
    /// Tolerant of a file from an older build: a field added since it was written (`actions`, `section`) takes its
    /// default, where the synthesized decoding lost every category for it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decode(String.self, forKey: .symbol)
        color = try c.decode(CategoryColor.self, forKey: .color)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        notifies = try c.decodeIfPresent(Bool.self, forKey: .notifies) ?? true
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        isCI = try c.decodeIfPresent(Bool.self, forKey: .isCI) ?? false
        actions = try c.decodeIfPresent(ActionList.self, forKey: .actions) ?? ActionList()
        section = try c.decodeIfPresent(UUID.self, forKey: .section)
    }
}

struct InboxGroup: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case people, repos }
    var id = UUID()
    var name: String
    var kind: Kind
    /// Logins (people) or `owner/repo` / `owner/*` (repos).
    var members: [String] = []
}

// MARK: - Things, as fetched

/// GitHub's `authorAssociation`.
enum Association: String, Codable, Hashable {
    case owner, member, collaborator, contributor, firstTimeContributor, firstTimer, mannequin, none

    var isMaintainer: Bool { self == .owner || self == .member || self == .collaborator }
}

struct Person: Codable, Hashable {
    var login: String
    var isBot = false
    var association: Association = .none
    var avatar: URL?
}

struct ThingComment: Codable, Hashable, Identifiable {
    var id: String
    var author: Person
    var at: Date
    var snippet: String
    /// Logins @-mentioned in the body, lowercased.
    var mentions: [String] = []
    /// The comment as Jev reads it (`InboxSync.readLimit` long) when it is longer than its snippet; nil when the snippet is
    /// all of it, or in an older file.
    var text: String? = nil
    /// A review's summary rather than a plain comment.
    var isReview = false
}

enum ReviewState: String, Codable, Hashable {
    case approved, changesRequested, commented, dismissed
}

struct ThingReview: Codable, Hashable, Identifiable {
    var id: String
    var author: Person
    var state: ReviewState
    var at: Date
    /// The commit it was made on (GitHub's `commit.oid`): it and those before it were reviewed, whenever Triage first saw
    /// them. Nil when GitHub didn't say, or in an older file.
    var commitID: String? = nil
}

struct ThingThread: Codable, Hashable, Identifiable {
    var id: String
    var isResolved: Bool
    var startedBy: Person
    var lastReplyBy: Person
    /// Id of the latest comment in the thread: a new reply is a new fact.
    var lastReplyID: String
    var lastReplyAt: Date
    var path: String?
    var snippet: String
    /// The latest reply as Jev reads it when it is longer than its snippet; nil when the snippet is all of it.
    var text: String? = nil
    /// Each author's latest comment in the thread among its last ones fetched (by login, lowercased): your answer in the
    /// middle of a thread is your latest word there though others replied after it. Nil in an older file.
    var latestBy: [String: Date]?
    /// The comments among those fetched (its first and last ones) that @-mention someone: a mention in the middle of a
    /// thread is one, though a later reply's text is the thread's. Nil in an older file.
    var mentions: [ThreadMention]?
    /// The replies among its last ones fetched before its latest, oldest first: a question there still asks you though
    /// someone else replied after it. Nil in an older file.
    var earlier: [ThingComment]?

    /// Whether a reply among those fetched (its latest, or an earlier one) has this id.
    func hasReply(_ id: String) -> Bool { lastReplyID == id || earlier?.contains { $0.id == id } == true }
}

/// A review-thread comment's @-mentions, with what makes it an event: its id, who wrote it and when.
struct ThreadMention: Codable, Hashable, Identifiable {
    var id: String
    var author: Person
    var at: Date
    /// Lowercased, as `ThingComment.mentions`.
    var logins: [String]
}

/// A PR's review threads past the first page, as last read: how many threads it had and when it was last updated then, when
/// they were read, and the logins their latest replies mention.
struct ThreadsTail: Codable, Hashable {
    var total: Int
    var updatedAt: Date
    var readAt: Date
    var mentions: [String] = []
}

struct ThingCommit: Codable, Hashable, Identifiable {
    var id: String
    var author: String
    /// When it was committed, as GitHub says: pushed later, it reaches the PR only then.
    var at: Date
    /// When it was first seen on a PR read before without it (`Store.stampingCommitArrivals`); nil for what a PR had when
    /// it was first read, or in an older file.
    var seenAt: Date? = nil

    /// When it came to the PR, as far as Triage knows: what counts it as new since Done or your review.
    var arrived: Date { max(at, seenAt ?? at) }
}

/// A review someone was asked for, and when: a new request after a review is a new fact.
struct ThingReviewRequest: Codable, Hashable {
    /// A login, or `org/team`.
    var reviewer: String
    var at: Date
}

/// A PR, issue or workflow as last fetched: everything the conditions read.
struct Thing: Codable, Hashable, Identifiable {
    /// `pr:owner/repo#12`, `issue:owner/repo#3`, `workflow:owner/repo:<workflow id>@<branch>`.
    var id: String
    var kind: ThingKind
    var repo: String
    var number: Int?
    var title: String
    var url: URL
    var author: Person?
    var status: ThingStatus = .open
    var labels: [String] = []
    var assignees: [String] = []
    /// When each current assignee (lowercased) was assigned, the latest `AssignedEvent` for them, when GitHub said.
    var assignedAt: [String: Date]?
    /// Logins, and `org/team` for teams.
    var requestedReviewers: [String] = []
    /// Logins @-mentioned in the body or any comment, lowercased.
    var mentioned: [String] = []
    var createdAt: Date
    var updatedAt: Date
    var comments: [ThingComment] = []
    var reviews: [ThingReview] = []
    var threads: [ThingThread] = []
    var commits: [ThingCommit] = []
    var checks: CheckState?
    var hasConflicts = false
    /// GitHub's mergeStateStatus is BEHIND.
    var behindBase = false
    /// The latest commit's id.
    var headSha: String?
    /// PRs: what its review threads past the first page were read for, kept to be read again only once that changes.
    var threadsTail: ThreadsTail?
    /// PRs: how its reviews were read (`InboxSync.reviewsShape`); nil from a build that kept only each reviewer's latest.
    var reviewsShape: Int?
    /// Which execution of its CI it shows (`ci:`…): a PR's checks on its head commit by their ids (a rerun's are new ones),
    /// a workflow's run and attempt. Nil when unknown (an older file).
    var ciRun: String?
    /// A check is still running, though the outcome may already say failing: the CI as a whole isn't done.
    var ciRunning = false
    /// Workflows: the run (or an external check) was cancelled; `checks` then says failing, never passing.
    var ciCancelled = false
    /// When each current review request was made (the latest `ReviewRequestedEvent` per reviewer).
    var reviewRequests: [ThingReviewRequest] = []
    var greptileScore: Int?
    // Workflows
    var workflowName: String?
    var branch: String?
    /// The name its branch has on GitHub now, when it isn't `branch`: a rule that names `master` keeps its things as
    /// `@master` (`branch`), while master renamed main is read, named and re-run as main.
    var ciBranch: String?
    /// The repo's default branch, when known: what a rule that names no branch watches.
    var defaultBranch: String?
    var failingJobs: [String] = []
    /// PRs: the size of the change, when GitHub said.
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    /// GitHub's node id of a PR or issue: what it is looked at again by when no search returned it (`Store.recheck`).
    var nodeID: String?
    /// What Jev made of it (InboxJev.swift), kept across refreshes; nil before it was asked anything.
    var signals: ThingSignals?
    /// Those (lowercased logins) GitHub's `mentions:` search for them returned it for: mentioned there, though the comment
    /// that did may be past those fetched (ten newer ones came since). Kept across refreshes, at most
    /// `InboxSync.maxSearchMentions`; on a thing just fetched, `false` says such a search read whole would have found it and
    /// didn't (`InboxSync.markMentioned`).
    var mentionedBySearch: [String: Bool]?
}

extension Thing {
    /// A workflow's branch by the name it has on GitHub now (`ciBranch`), else as its rule names it.
    var currentBranch: String? { ciBranch ?? branch }

    /// Tolerant of a file from an older build: a field added since it was written (`behindBase`, `reviewRequests`…) takes
    /// its default, where the synthesized decoding lost the thing (and, with it, every thing).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ThingKind.self, forKey: .kind)
        repo = try c.decode(String.self, forKey: .repo)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(URL.self, forKey: .url)
        author = try c.decodeIfPresent(Person.self, forKey: .author)
        status = try c.decodeIfPresent(ThingStatus.self, forKey: .status) ?? .open
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        assignees = try c.decodeIfPresent([String].self, forKey: .assignees) ?? []
        assignedAt = try c.decodeIfPresent([String: Date].self, forKey: .assignedAt)
        requestedReviewers = try c.decodeIfPresent([String].self, forKey: .requestedReviewers) ?? []
        mentioned = try c.decodeIfPresent([String].self, forKey: .mentioned) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        comments = try c.decodeIfPresent([ThingComment].self, forKey: .comments) ?? []
        reviews = try c.decodeIfPresent([ThingReview].self, forKey: .reviews) ?? []
        threads = try c.decodeIfPresent([ThingThread].self, forKey: .threads) ?? []
        commits = try c.decodeIfPresent([ThingCommit].self, forKey: .commits) ?? []
        checks = try c.decodeIfPresent(CheckState.self, forKey: .checks)
        hasConflicts = try c.decodeIfPresent(Bool.self, forKey: .hasConflicts) ?? false
        behindBase = try c.decodeIfPresent(Bool.self, forKey: .behindBase) ?? false
        headSha = try c.decodeIfPresent(String.self, forKey: .headSha)
        threadsTail = try c.decodeIfPresent(ThreadsTail.self, forKey: .threadsTail)
        reviewsShape = try c.decodeIfPresent(Int.self, forKey: .reviewsShape)
        ciRun = try c.decodeIfPresent(String.self, forKey: .ciRun)
        ciRunning = try c.decodeIfPresent(Bool.self, forKey: .ciRunning) ?? false
        ciCancelled = try c.decodeIfPresent(Bool.self, forKey: .ciCancelled) ?? false
        reviewRequests = try c.decodeIfPresent([ThingReviewRequest].self, forKey: .reviewRequests) ?? []
        greptileScore = try c.decodeIfPresent(Int.self, forKey: .greptileScore)
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        ciBranch = try c.decodeIfPresent(String.self, forKey: .ciBranch)
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        failingJobs = try c.decodeIfPresent([String].self, forKey: .failingJobs) ?? []
        additions = try c.decodeIfPresent(Int.self, forKey: .additions)
        deletions = try c.decodeIfPresent(Int.self, forKey: .deletions)
        changedFiles = try c.decodeIfPresent(Int.self, forKey: .changedFiles)
        signals = try c.decodeIfPresent(ThingSignals.self, forKey: .signals)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID)
        mentionedBySearch = try c.decodeIfPresent([String: Bool].self, forKey: .mentionedBySearch)
    }
}

/// Jev's verdicts on a thing, each asked once for what it was judged on.
struct ThingSignals: Codable, Hashable {
    /// By comment, review or thread reply id: every message Jev read.
    var messages: [String: MessageSignal] = [:]
    var importance: ImportanceSignal?
    /// Whose inbox Jev read it for (a login as `InboxEngine.viewer` writes it): signed in as someone else, it says nothing.
    var viewer: String?
    /// Your latest word there as ever seen: someone's later reply in a thread takes the place of yours in what GitHub
    /// returns, and must not make a question you answered ask again.
    var answeredAt: Date?
    /// GitHub's `involves:` search for this viewer returned it: you're involved, though what you did there (a comment ten
    /// newer ones pushed out of what is fetched) may no longer be among what came with it. Kept, as involvement is.
    var involved: Bool?
    /// The same for your review searches (`review-requested:`, `reviewed-by:`), by qualifier: a request made only of your
    /// team, or a review of yours past the latest fetched. Each is kept, or taken back, by its own search only. On a thing
    /// just fetched, `false` says such a search read whole would have found it and didn't.
    var involvedBy: [String: Bool]?
}

/// What Jev said of one message: its label, nil where he wasn't sure (read all the same).
struct MessageSignal: Codable, Hashable {
    var label: CommentLabel?

    init(label: CommentLabel? = nil) { self.label = label }

    private enum CodingKeys: String, CodingKey { case label, asksMe, noise }

    /// Saved before labels, as two readings: asks me (asks), noise (noise), and not noise nor asking (FYI); unsure of
    /// noise, unsure.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.label) {
            label = try c.decodeIfPresent(String.self, forKey: .label).flatMap(CommentLabel.init(rawValue:))
            return
        }
        let asks = try c.decodeIfPresent(Bool.self, forKey: .asksMe)
        let noise = try c.decodeIfPresent(Bool.self, forKey: .noise)
        label = asks == true ? .asks : noise == true ? .noise : noise == false ? .fyi : nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(label, forKey: .label)
    }
}

struct ImportanceSignal: Codable, Hashable {
    /// Nil: Jev wasn't sure.
    var level: Importance?
    /// What it was rated on (the request or assignment and the head commit): a new one is rated again.
    var stamp: String
}

// MARK: - What the engine says

/// Why a thing is in a category, as the row shows it. `key` is its identity: the same key never notifies twice,
/// and Done acknowledges keys.
struct Fact: Codable, Hashable {
    var key: String
    /// The chip, in the rule's words: "Greptile 4/5", "2 unresolved", "last comment: @toksdotdev".
    var label: String
    var tint: FactTint = .neutral
}

enum FactTint: String, Codable, Hashable {
    case neutral, attention, danger, success
}

/// A thing in a category now.
struct InboxEntry: Hashable, Identifiable {
    var thing: Thing
    var categoryID: UUID
    var facts: [Fact]
    /// Every current fact acknowledged.
    var isDone: Bool
    /// Some fact not seen yet.
    var isUnread: Bool
    /// Jev's rating of what it asks of you (a review request, an assignment), when it rated it.
    var importance: Importance?
    /// Jev's labels of the messages its facts are about, by fact key: how the row stands out, never whether it is here.
    var labels: [String: CommentLabel] = [:]
    var id: String { thing.id }
    /// The label that stands out most among its facts'.
    var label: CommentLabel? { labels.values.min { $0.rank < $1.rank } }
    /// Every fact is about a message Jev labels noise: the row is dimmed.
    var isNoise: Bool { !facts.isEmpty && facts.allSatisfy { labels[$0.key] == .noise } }
}

/// What the user did with a thing, persisted by thing id.
struct EntryMarks: Codable, Hashable {
    /// Fact keys seen (opened, or shown and read).
    var seen: Set<String> = []
    /// Fact keys acknowledged with Done.
    var acked: Set<String> = []
    /// Fact keys already notified.
    var notified: Set<String> = []
    var doneAt: Date?
    /// The category it was Done in, and its facts then: it stays Done there while it still belongs there, even once what
    /// counts after Done leaves the category's rules nothing new to match (so it doesn't fall into a later category).
    var doneIn: UUID?
    var doneFacts: [Fact]?
    /// When the thing was first missing from a refresh (it is still missing): its marks are forgotten a month after. Kept
    /// with them, so a restart doesn't start the month again.
    var goneSince: Date?
}

extension EntryMarks {
    /// Tolerant of a file from an older build: a set it didn't write yet is empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seen = try c.decodeIfPresent(Set<String>.self, forKey: .seen) ?? []
        acked = try c.decodeIfPresent(Set<String>.self, forKey: .acked) ?? []
        notified = try c.decodeIfPresent(Set<String>.self, forKey: .notified) ?? []
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        doneIn = try c.decodeIfPresent(UUID.self, forKey: .doneIn)
        doneFacts = try c.decodeIfPresent([Fact].self, forKey: .doneFacts)
        goneSince = try c.decodeIfPresent(Date.self, forKey: .goneSince)
    }
}

/// Resolves what slots name that the engine can't know alone.
struct InboxContext {
    var me: String
    var groups: [InboxGroup] = []
    var contributedRepos: Set<String> = []
    /// `org/team` of every team you're in.
    var myTeams: Set<String> = []
    var now = Date()
    /// What Jev said of things counts (Settings' "Let Jev label new comments"); off, it is as if Jev had said nothing.
    var jevSignals = true
}
