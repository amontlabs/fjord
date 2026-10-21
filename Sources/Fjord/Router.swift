import AppKit
import Foundation

// MARK: - Persisted state

/// The Router: the cards for what needs you in the Claude sessions, and the log of what it did.
struct RouterState: Codable, Equatable {
    /// Off by default; only offered while the Claude sessions extension is on.
    var enabled = false
    var enabledAt: Date?
    /// Oldest first.
    var cards: [RouterCard] = []
    /// What the Router changed in Fjord itself, oldest first: the records behind the decision log's change cards (see
    /// FjordChange.swift).
    var changes: [FjordChange] = []
    /// The decision log, oldest first (see RouterDecisions.swift).
    var decisions: [RouterDecision] = []
    /// The sessions' summaries you asked for, oldest first (see RouterSummary.swift); kept under the key of the overviews of
    /// every session that came before them, which read as summaries of none.
    var summaries: [RouterSummary] = []
    /// What the feed last saw of each session (see `RouterFeed.Stamp`): a change is an event, the same is not.
    var seen: [String: String] = [:]
    /// The question or plan each session is stopped on, by when it began (ms since 1970, exactly as the transcript says):
    /// a card is made once per wait.
    var waits: [String: Int64] = [:]
    /// The call (`tool_use` id) each of those waits is on, when the transcript said.
    var waitTools: [String: String] = [:]
    /// Waits whose form Fjord's hook was seen holding (session → the wait's ms): that form going away ends the wait.
    var formSeen: [String: Int64] = [:]
    /// Turns that ended while the session still had subagents or commands running (see `RouterFeed.update`): carded once
    /// those are done, by session.
    var pendingTurns: [String: PendingTurn] = [:]
    /// What started a session the Router made for an inbox action, by session (its cards say so).
    var origins: [String: SessionOrigin] = [:]
    /// Sessions Fjord started (the Router, or an inbox action), by session → when. The app imports and shows such a
    /// session on its own, so "viewed" and "read" mean nothing for it: its cards come at once, until you write in it
    /// yourself from the app (a message no run of Fjord's sent: see `RouterFeed.update`), after which the usual rules
    /// apply.
    var fjordStarted: [String: Date] = [:]
    /// By session, the latest turn whose card was handled and then pruned away (`RouterFeed.prune`): the launch's look back
    /// never makes such a turn a card again, though its card is gone.
    var handledTurns: [String: Int] = [:]
    /// By session, a message of yours (ms) its open turn cards are still to be judged against: Jev decides which it settled
    /// (see RouterReplies.swift); none is addressed just for being written after.
    var replies: [String: Int64] = [:]
    /// How the Router writes to you (Settings), in your words: what the cards' briefs and the sessions' summaries follow.
    /// Nil for the default (`RouterStyle.defaultText`).
    var style: String?

    /// Projects whose future sessions have an explicit execution location. `sourceFolder` is a local discovery alias used
    /// only to find the existing project row; `id` is the project identity and is retained when placement changes.
    var runsOnProjects: [RunsOnProject] = []
    /// Desktop SSH starts Fjord prepared but cannot observe a session until guest presence and transcript evidence arrive.
    var pendingDesktopStarts: [PendingDesktopStart] = []
    /// Signed guest inbox deliveries and their confirmed/uncertain state; a timeout never licenses a new nonce.
    var guestRelayDeliveries: [GuestRelayRecord] = []
    /// Current guest forms, watched through the owning computer. Their location accompanies the CLI id on persistence.
    var guestPendingForms: [GuestPendingForm] = []
    /// A Router-off removal that could not reach its guest yet; retried on the next guest connection.
    var pendingGuestDisables: [SessionLocation] = []
    /// A deleted computer's Desktop SSH entry or engine alias could not be removed yet; retried after reconnect.
    var pendingGuestRemovals: [SessionLocation] = []
    /// The Brief: Now written as prose, kept up to date by its writer, with every rewrite (RouterDigest.swift).
    var digest: RouterDigest?

    /// Questions and plans asked while you looked at the session in the app, by session: no card while you do; one is made
    /// when you leave it, if the wait is still on.
    var heldWaits: [String: HeldWait] = [:]

    struct HeldWait: Codable, Equatable {
        var ms: Int64
        var toolUseID: String?
        var kind: RouterCard.Kind
        var text: String
    }

    struct PendingTurn: Codable, Equatable {
        /// The turn's number (`completedTurns`).
        var turns: Int
        /// Your last message when it ended (ms): a newer one means you've moved on, and no card is made for it.
        var message: Int64?
        /// Set once the turn ended (or was ready) while you were looking at the session in the app: no card while you are.
        /// When you leave, the card is made if the app still has the session unread (see `RouterFeed.update`).
        var held: Bool = false
        /// When (ms) you were first seen to have left a held session: the app's unread dots lag, so a missing dot only
        /// means "read" once `RouterFeed.unreadGraceMs` has passed.
        var leftMs: Int64?

        init(turns: Int, message: Int64?, held: Bool = false, leftMs: Int64? = nil) {
            self.turns = turns
            self.message = message
            self.held = held
            self.leftMs = leftMs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            turns = try c.decode(Int.self, forKey: .turns)
            message = try c.decodeIfPresent(Int64.self, forKey: .message)
            held = (try? c.decodeIfPresent(Bool.self, forKey: .held)) ?? false
            leftMs = try? c.decodeIfPresent(Int64.self, forKey: .leftMs)
        }
    }

    init() {}

    /// A line of the chat an older file kept: only the change it may hold is read (one there that can't be read fails the
    /// line, and is counted as lost).
    private struct LegacyLine: Decodable {
        var change: FjordChange?
        enum CodingKeys: String, CodingKey { case change }
        init(from decoder: Decoder) throws {
            change = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(FjordChange.self, forKey: .change)
        }
    }

    /// `chat` is read, never written (an older file's changes); `claudeSessionID`, and an older file's `autoContinue` and
    /// `autoContinueSessions`, are ignored.
    private enum CodingKeys: String, CodingKey {
        case enabled, enabledAt, cards, changes, chat, decisions, summaries = "overviews", seen, waits, waitTools, formSeen, pendingTurns, origins, heldWaits, fjordStarted, handledTurns, replies, style, runsOnProjects, pendingDesktopStarts, guestRelayDeliveries, guestPendingForms, pendingGuestDisables, pendingGuestRemovals, digest
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(enabledAt, forKey: .enabledAt)
        try c.encode(cards, forKey: .cards)
        try c.encode(changes, forKey: .changes)
        try c.encode(decisions, forKey: .decisions)
        try c.encode(summaries, forKey: .summaries)
        try c.encode(seen, forKey: .seen)
        try c.encode(waits, forKey: .waits)
        try c.encode(waitTools, forKey: .waitTools)
        try c.encode(formSeen, forKey: .formSeen)
        try c.encode(pendingTurns, forKey: .pendingTurns)
        try c.encode(origins, forKey: .origins)
        try c.encode(heldWaits, forKey: .heldWaits)
        try c.encode(fjordStarted, forKey: .fjordStarted)
        try c.encode(handledTurns, forKey: .handledTurns)
        try c.encode(replies, forKey: .replies)
        try c.encodeIfPresent(style, forKey: .style)
        try c.encode(runsOnProjects, forKey: .runsOnProjects)
        try c.encode(pendingDesktopStarts, forKey: .pendingDesktopStarts)
        try c.encode(guestRelayDeliveries, forKey: .guestRelayDeliveries)
        try c.encode(guestPendingForms, forKey: .guestPendingForms)
        try c.encode(pendingGuestDisables, forKey: .pendingGuestDisables)
        try c.encode(pendingGuestRemovals, forKey: .pendingGuestRemovals)
        try c.encodeIfPresent(digest, forKey: .digest)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each part, and each element of a list or map, on its own: one this version can't read is left out, not the rest,
        // and is named in `dropped` (the file is then kept aside before it is written over: see `PersistedState`).
        var lost: [String] = []
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            do { return try c.decodeIfPresent(T.self, forKey: key) } catch {
                lost.append(key.stringValue)
                return nil
            }
        }
        func list<T: Decodable>(_ key: CodingKeys) -> [T] {
            guard let all: [Lossy<T>] = value(key) else { return [] }
            let read = all.compactMap(\.value)
            if read.count < all.count { lost.append("\(all.count - read.count) of \(key.stringValue)") }
            return read
        }
        func map<T: Decodable>(_ key: CodingKeys) -> [String: T] {
            guard let all: [String: Lossy<T>] = value(key) else { return [:] }
            let read = all.compactMapValues(\.value)
            if read.count < all.count { lost.append("\(all.count - read.count) of \(key.stringValue)") }
            return read
        }
        enabled = value(.enabled) ?? false
        enabledAt = value(.enabledAt)
        cards = list(.cards)
        changes = list(.changes)
        // Older files kept the changes among the chat's lines; the rest of the chat is no longer kept.
        var legacy: Set<UUID> = []
        if changes.isEmpty {
            changes = (list(.chat) as [LegacyLine]).compactMap(\.change)
            legacy = Set(changes.map(\.id))
        }
        decisions = list(.decisions)
        summaries = list(.summaries)
        seen = map(.seen)
        waits = map(.waits)
        waitTools = map(.waitTools)
        formSeen = map(.formSeen)
        pendingTurns = map(.pendingTurns)
        origins = map(.origins)
        heldWaits = map(.heldWaits)
        fjordStarted = map(.fjordStarted)
        handledTurns = map(.handledTurns)
        replies = map(.replies)
        style = value(.style)
        runsOnProjects = list(.runsOnProjects)
        pendingDesktopStarts = list(.pendingDesktopStarts)
        guestRelayDeliveries = list(.guestRelayDeliveries)
        guestPendingForms = list(.guestPendingForms)
        pendingGuestDisables = list(.pendingGuestDisables)
        pendingGuestRemovals = list(.pendingGuestRemovals)
        digest = value(.digest)
        linkUnlinkedChanges(legacy: legacy)
        dropped = lost
    }

    /// What the file had that this version couldn't read ("2 of cards", "waits"): never saved, and handed on to
    /// `PersistedState.dropped` (empty once loaded).
    var dropped: [String] = []
}

/// An element of a saved array read on its own: nil when it can't be, so one bad element doesn't take the rest with it.
struct Lossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Where a session came from when an inbox action started it: the category, the thing, the action and its run.
struct SessionOrigin: Codable, Equatable, Hashable {
    var category: String
    /// The thing's reference and title, in a line.
    var thing: String
    var actionID: String
    var runID: String

    /// "⚡ from <category> · <thing>": on the session's cards and rows.
    var label: String { "⚡ from \(category) · \(thing)" }
}

/// Something a session wants from you, open until it is addressed.
struct RouterCard: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// Stopped on a question (AskUserQuestion).
        case question
        /// Stopped on a plan to approve (ExitPlanMode).
        case plan
        /// Finished its turn.
        case done
        /// Finished its turn, and its summary (or Jev's triage) says it is blocked.
        case stuck
        /// Finished its turn asking you something in its final message (Jev's triage, see RouterTriage.swift).
        case asks
        /// Finished its turn asking your OK for something consequential (push, publish, delete, spend…).
        case approval
        /// Finished its turn waiting on something outside it (CI, a deploy, another session…): shown with the working
        /// sessions, not in Needs you.
        case waiting
        /// Finished its turn, but left you a last step before the work is really over (merge, relaunch and try it, run
        /// something, test by hand): Jev's `next` (see RouterTriage.swift).
        case finish

        /// The kind as a model reads it: "finished" for `done` (the enum value stays; it is saved).
        var modelName: String { self == .done ? "finished" : rawValue }
        /// The same as a label (`Done` is `Finished`).
        var modelLabel: String { self == .done ? "Finished" : label }

        /// Made when a turn ends (the others while one waits).
        var isTurn: Bool { self != .question && self != .plan }
        /// The kind a build from before the triage reads instead (it knew only question, plan, done and stuck): saved as
        /// `kind`, with this one beside it as `kindDetail`, so going back to such a build keeps the cards.
        var legacy: Kind {
            switch self {
            case .question, .plan, .done, .stuck: self
            case .asks, .approval: .stuck
            case .waiting, .finish: .done
            }
        }
        /// Counted as needing you (amber); `done` is only news, and a session `waiting` is still on its way.
        var needsYou: Bool { self != .done && self != .waiting }
        /// Needs you's order: an OK asked first, then what stops a session on a question, then a stuck one, then a last
        /// step left to you, then news.
        var rank: Int {
            switch self {
            case .approval: 0
            case .question, .plan, .asks: 1
            case .stuck: 2
            case .finish: 3
            case .done: 4
            case .waiting: 5
            }
        }
    }

    /// How a card stopped being open.
    enum Addressed: String, Codable {
        /// By hand.
        case you
        /// You sent the session a message after the card: a question or plan it was stopped on is over; a turn's card is
        /// addressed only when Jev judged that the message settled it (older builds: any message after it).
        case reply
        /// The Router sent the session a message.
        case router
        /// The question or plan stopped waiting (answered here, in the app, anywhere).
        case answered
        /// You opened the session after a turn card (older builds: opening no longer addresses a card).
        case opened
        /// A newer card for the same session.
        case superseded
        /// The session was archived or deleted.
        case gone
        /// Jev found nothing left to do in it and nothing worth a look: it went straight to the history, unread (`unread`).
        case settled
    }

    /// `<session>#t<completedTurns>` for a turn, `<session>#w<ms of the wait's start>` for a wait.
    var id: String { didSet { if id != oldValue { contents = Contents() } } }
    var sessionID: String { didSet { if sessionID != oldValue { contents = Contents() } } }
    var kind: Kind { didSet { if kind != oldValue { contents = Contents() } } }
    var title: String { didSet { if title != oldValue { contents = Contents() } } }
    var folder: String? { didSet { if folder != oldValue { contents = Contents() } } }
    var text: String { didSet { if text != oldValue { contents = Contents() } } }
    /// When it was made, in ms since 1970: kept exactly (a date in the state file loses its fraction of a second), so a
    /// reply in the same second as the card is still told apart from one before it.
    var createdMs: Int64 { didSet { if createdMs != oldValue { contents = Contents() } } }
    var addressedAt: Date? { didSet { if addressedAt != oldValue { contents = Contents() } } }
    var addressedBy: Addressed? { didSet { if addressedBy != oldValue { contents = Contents() } } }
    /// For a question or plan: the call it waits on (`tool_use` id), which ties it to the form Fjord's hook holds.
    var toolUseID: String? { didSet { if toolUseID != oldValue { contents = Contents() } } }
    /// For a turn card made once the turn could be told done (see `RouterFeed.update`): your last message when the turn
    /// ended (ms). A later one is a reply to it, however late the card was made.
    var turnMessage: Int64? { didSet { if turnMessage != oldValue { contents = Contents() } } }
    /// Set when an inbox action started the session this is about.
    var origin: SessionOrigin? { didSet { if origin != oldValue { contents = Contents() } } }
    /// The questions of a form, or the asks of a turn (by question), still unanswered after your messages (it had `total`),
    /// so the card says "2 of 3 left".
    var left: [String]? { didSet { if left != oldValue { contents = Contents() } } }
    var total: Int? { didSet { if total != oldValue { contents = Contents() } } }
    /// Your message that resolved the card, when Jev judged it did.
    var addressedNote: String? { didSet { if addressedNote != oldValue { contents = Contents() } } }
    /// What Jev made of a finished turn's final message (see RouterTriage.swift); nil until then, or without a key.
    var triage: RouterTriage? { didSet { if triage != oldValue { contents = Contents() } } }
    /// What the card tells you, in your words' style: one Haiku call (see RouterBrief.swift); nil until then, or when it
    /// isn't made (a trivial turn, no Claude Code), and the card's own text stands.
    var brief: String? { didSet { if brief != oldValue { contents = Contents() } } }
    /// What the brief was made from (a hash): it is made again only when that changes.
    var briefSource: String? { didSet { if briefSource != oldValue { contents = Contents() } } }
    /// What a turn's final message asks you, each with its choices, read by its brief's call (RouterBrief.swift): nil until
    /// then, or when that call failed (the card shows its own text); empty when it asks nothing.
    var asks: [RouterAsk]? { didSet { if asks != oldValue { contents = Contents() } } }
    /// A finished turn that went to the history on its own (`settled`) and that you haven't acknowledged yet.
    var unread: Bool? { didSet { if unread != oldValue { contents = Contents() } } }
    /// What the turn asked that your message clearing the card left untouched, as Jev was clearly sure (RouterCardJudge.swift):
    /// said on the session's working line until you answer it or its next turn ends. Nil when none, or not judged.
    var skipped: [String]? { didSet { if skipped != oldValue { contents = Contents() } } }
    /// The previous turn's `skipped`: what the session went on without. The card says so unless its final message asks it
    /// again (`wentAheadWithout`).
    var wentAhead: [String]? { didSet { if wentAhead != oldValue { contents = Contents() } } }

    /// Copies share a contents token until a stored field changes. Most view and memo comparisons therefore finish
    /// by identity; independently created or decoded cards still compare by value. The token is never persisted.
    private final class Contents {}
    private var contents = Contents()

    static func == (a: Self, b: Self) -> Bool {
        if a.contents === b.contents { return true }
        return a.id == b.id
            && a.sessionID == b.sessionID
            && a.kind == b.kind
            && a.title == b.title
            && a.folder == b.folder
            && a.text == b.text
            && a.createdMs == b.createdMs
            && a.addressedAt == b.addressedAt
            && a.addressedBy == b.addressedBy
            && a.toolUseID == b.toolUseID
            && a.turnMessage == b.turnMessage
            && a.origin == b.origin
            && a.left == b.left
            && a.total == b.total
            && a.addressedNote == b.addressedNote
            && a.triage == b.triage
            && a.brief == b.brief
            && a.briefSource == b.briefSource
            && a.asks == b.asks
            && a.unread == b.unread
            && a.skipped == b.skipped
            && a.wentAhead == b.wentAhead
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The card less how it is told to you (its brief and the asks read with it, read or not): what an action on it goes by.
    var acted: RouterCard {
        var card = self
        card.brief = nil
        card.briefSource = nil
        card.asks = nil
        card.unread = nil
        card.skipped = nil
        card.wentAhead = nil
        return card
    }

    /// What a message (ms) must come after to be a reply to this card.
    var replyAfter: Int64 { turnMessage ?? createdMs }

    var createdAt: Date {
        get { Date(timeIntervalSince1970: Double(createdMs) / 1000) }
        set { createdMs = RouterFeed.Stamp.ms(newValue) }
    }

    var isOpen: Bool { addressedAt == nil }

    init(id: String, sessionID: String, kind: Kind, title: String, folder: String?, text: String, createdAt: Date,
         addressedAt: Date? = nil, addressedBy: Addressed? = nil, toolUseID: String? = nil, turnMessage: Int64? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.folder = folder
        self.text = text
        createdMs = RouterFeed.Stamp.ms(createdAt)
        self.addressedAt = addressedAt
        self.addressedBy = addressedBy
        self.toolUseID = toolUseID
        self.turnMessage = turnMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, kind, kindDetail, title, folder, text, createdMs, createdAt, addressedAt, addressedBy, toolUseID, turnMessage, origin, left, total, addressedNote, triage, brief, briefSource, asks, unread, skipped, wentAhead
    }

    /// Files from before `createdMs` have `createdAt` (a date) instead.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        // The precise kind when this version knows it, else the older builds' one.
        kind = try (try? c.decodeIfPresent(Kind.self, forKey: .kindDetail)) ?? c.decode(Kind.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        if let ms = try? c.decode(Int64.self, forKey: .createdMs) {
            createdMs = ms
        } else {
            createdMs = RouterFeed.Stamp.ms(try c.decode(Date.self, forKey: .createdAt))
        }
        addressedAt = try c.decodeIfPresent(Date.self, forKey: .addressedAt)
        addressedBy = try c.decodeIfPresent(Addressed.self, forKey: .addressedBy)
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID)
        turnMessage = try? c.decodeIfPresent(Int64.self, forKey: .turnMessage)
        origin = try? c.decodeIfPresent(SessionOrigin.self, forKey: .origin)
        left = try? c.decodeIfPresent([String].self, forKey: .left)
        total = try? c.decodeIfPresent(Int.self, forKey: .total)
        addressedNote = try? c.decodeIfPresent(String.self, forKey: .addressedNote)
        triage = try? c.decodeIfPresent(RouterTriage.self, forKey: .triage)
        brief = try? c.decodeIfPresent(String.self, forKey: .brief)
        briefSource = try? c.decodeIfPresent(String.self, forKey: .briefSource)
        // Older files have the sentences Jev found asking, on the triage: each an ask with no choices.
        asks = (try? c.decodeIfPresent([RouterAsk].self, forKey: .asks)) ?? triage.flatMap { RouterAsk.legacy($0.legacyQuestions) }
        unread = try? c.decodeIfPresent(Bool.self, forKey: .unread)
        skipped = try? c.decodeIfPresent([String].self, forKey: .skipped)
        wentAhead = try? c.decodeIfPresent([String].self, forKey: .wentAhead)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(kind.legacy, forKey: .kind)
        if kind.legacy != kind { try c.encode(kind, forKey: .kindDetail) }
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encode(text, forKey: .text)
        try c.encode(createdMs, forKey: .createdMs)
        try c.encodeIfPresent(addressedAt, forKey: .addressedAt)
        try c.encodeIfPresent(addressedBy, forKey: .addressedBy)
        try c.encodeIfPresent(toolUseID, forKey: .toolUseID)
        try c.encodeIfPresent(turnMessage, forKey: .turnMessage)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(left, forKey: .left)
        try c.encodeIfPresent(total, forKey: .total)
        try c.encodeIfPresent(addressedNote, forKey: .addressedNote)
        try c.encodeIfPresent(triage, forKey: .triage)
        try c.encodeIfPresent(brief, forKey: .brief)
        try c.encodeIfPresent(briefSource, forKey: .briefSource)
        try c.encodeIfPresent(asks, forKey: .asks)
        try c.encodeIfPresent(unread, forKey: .unread)
        try c.encodeIfPresent(skipped, forKey: .skipped)
        try c.encodeIfPresent(wentAhead, forKey: .wentAhead)
    }

    /// The turn a turn's card was made for (`<session>#t<completedTurns>`), from its id; nil for a question or plan.
    var turn: Int? {
        guard kind.isTurn, let range = id.range(of: "#t", options: .backwards) else { return nil }
        return Int(id[range.upperBound...])
    }

    /// The wait a question or plan card was made for (ms since 1970), from its id.
    var waitMs: Int64? {
        guard !kind.isTurn, let range = id.range(of: "#w", options: .backwards) else { return nil }
        return Int64(id[range.upperBound...])
    }
}

// MARK: - Feed

/// Turns reads of the sessions into cards. Pure: the same reads give the same cards, so the rules are tested here.
enum RouterFeed {
    /// What a turn card says until the app writes the turn's summary.
    static let placeholder = "Finished its turn"
    static let maxCards = 300
    static let maxChanges = 500
    /// Sessions whose handled turn is kept (`RouterState.handledTurns`), archived ones included.
    static let maxHandled = 500
    /// How long the app's sidebar dot may lag behind a turn you left unread (it is written to disk up to ~30 s late).
    static let unreadGraceMs: Int64 = 40_000

    /// What changes in a session that the rules care about: turns finished, your last message, when you last opened it.
    struct Stamp: Equatable {
        var turns: Int
        var message: Int64?
        var focus: Int64?

        init(_ session: ClaudeSession) {
            turns = session.completedTurns
            message = session.lastUserMessage.map(Self.ms)
            focus = session.lastFocused.map(Self.ms)
        }

        private init(turns: Int) { self.turns = turns }

        /// A session before anything happened in it.
        static let start = Stamp(turns: 0)

        init?(_ text: String) {
            let parts = text.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let turns = Int(parts[0]) else { return nil }
            self.turns = turns
            message = Int64(parts[1])
            focus = Int64(parts[2])
        }

        var text: String { "\(turns)|\(message.map(String.init) ?? "")|\(focus.map(String.init) ?? "")" }

        /// Dates come from files: one too far out (or not a number) is clamped rather than trapping the conversion.
        static func ms(_ date: Date) -> Int64 {
            let value = (date.timeIntervalSince1970 * 1000).rounded()
            guard value.isFinite else { return 0 }
            return Int64(max(-9e18, min(9e18, value)))
        }
    }

    /// A wait as the transcript shows it: when it began, the call, what kind of card it makes, and its text.
    private struct Wait {
        var ms: Int64
        var toolUseID: String?
        var kind: RouterCard.Kind
        var text: String
    }

    private static func wait(_ activity: ClaudeActivity) -> Wait? {
        guard activity.waitsForYou else { return nil }
        let ms = Stamp.ms(activity.since)
        if activity.tool == "ExitPlanMode" {
            // The card says the plan's title; the row's "Approve the plan: " is the kind tag's job.
            let prefix = "Approve the plan: "
            let text = activity.text.hasPrefix(prefix) ? String(activity.text.dropFirst(prefix.count)) : activity.text
            return Wait(ms: ms, toolUseID: activity.toolUseID, kind: .plan, text: text)
        }
        return Wait(ms: ms, toolUseID: activity.toolUseID, kind: .question, text: activity.text)
    }

    /// Whether a known wait is over, on evidence only: the transcript of the running session moved past its call, the
    /// turn finished (a summary is written once it has), or the form Fjord's hook held for it went away. A session that
    /// merely stopped counting as running (two hours on, the app quit, nothing read yet) is still waiting.
    private static func waitEnded(_ state: RouterState, _ session: ClaudeSession, ms: Int64, toolUseID: String?,
                                  activity: ClaudeActivity?, forms: [String: Set<String>]?) -> Bool {
        if session.running, let activity, wait(activity)?.ms != ms { return true }
        if session.summary != nil { return true }
        if let forms, state.formSeen[session.id] == ms, let toolUseID, forms[session.id]?.contains(toolUseID) != true { return true }
        return false
    }

    /// `forms`: the calls (`tool_use` ids) whose forms Fjord's hook holds, by desktop session; nil until the forms
    /// folder has been read. `tasks`: the subagents and commands sessions whose turn is over still have running
    /// (`Store.claudeTasks`), and `inventory` the sessions that read looked at (nil: every one). A finished turn is
    /// carded only once its session is no longer running (the app writes the summary after the count goes up) and its
    /// background work has been looked at since: with some still running it is work under way, and the card waits until
    /// that is done.
    static func update(_ state: inout RouterState, sessions: [ClaudeSession], activity: [String: ClaudeActivity],
                       muted: Set<String>, mutedSessions: Set<String> = [], viewing: String?, unread: Set<String>? = nil, forms: [String: Set<String>]? = nil,
                       tasks: [String: [ClaudeTask]] = [:], inventory: Set<String>? = nil, listed: [String: Date]? = nil,
                       now: Date) {
        // Muted by folder, or by session when its project's canonical key is muted (`Store.mutedSessionIDs`).
        func isMuted(_ session: ClaudeSession) -> Bool { mutedSessions.contains(session.id) || muted.contains(session.folderKey) }
        let live = Dictionary(sessions.filter { !$0.isArchived }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Written only where it differs: a part left as it was keeps its storage, so the store's check of what changed
        // (`state != router`, every read while sessions work) is a glance at each part rather than a walk of it.
        func set<Value: Equatable>(_ map: inout [String: Value], _ key: String, _ value: Value?) {
            if map[key] != value { map[key] = value }
        }
        func keep<Value>(_ map: inout [String: Value], where kept: (String, Value) -> Bool) {
            if map.contains(where: { !kept($0.key, $0.value) }) { map = map.filter { kept($0.key, $0.value) } }
        }

        for i in state.cards.indices where state.cards[i].isOpen && live[state.cards[i].sessionID] == nil {
            state.cards[i].addressedAt = now
            state.cards[i].addressedBy = .gone
        }

        for session in live.values.sorted(by: { $0.id < $1.id }) {
            let id = session.id
            let stamp = Stamp(session)
            // A session Fjord started has no backlog: seen for the first time after its first turn ended (a quick reply
            // can end before the next look), that turn is still new.
            let before = state.seen[id].flatMap(Stamp.init) ?? (state.fjordStarted[id] != nil ? Stamp.start : nil)
            let busy = !(tasks[id] ?? []).isEmpty
            let previous = state.waits[id]
            let read = session.running ? activity[id] : nil
            let current = read.flatMap(wait)
            var ongoing = previous
            if let previous {
                let moved = before.map { stamp.message != $0.message || stamp.turns > $0.turns } ?? false
                if moved || waitEnded(state, session, ms: previous, toolUseID: state.waitTools[id], activity: read, forms: forms) {
                    ongoing = nil
                }
            }
            if let current { ongoing = current.ms }

            // A session Fjord started is yours to read only once you've written in it from the app: a message that none
            // of Fjord's runs on it sent. Until then the app showing it (it brings it to the front itself) means
            // nothing.
            if let before, state.fjordStarted[id] != nil, stamp.message != before.message, let message = stamp.message,
               !fjordSent(state, id, turns: stamp.turns, atMs: message) {
                state.fjordStarted[id] = nil
            }
            let watching = id == viewing && state.fjordStarted[id] == nil

            // First sight: only what it is now, so turning the Router on doesn't bring the backlog.
            if let before {
                // What addresses the cards there are, before any new one is made (a new one is newer than all of it).
                if stamp.message != before.message, let message = stamp.message {
                    address(&state, id, .reply, now) { !$0.kind.isTurn && message > $0.replyAfter }
                    queueReply(&state, id, turns: stamp.turns, message, now: now)
                }
                if let previous, ongoing != previous {
                    address(&state, id, .answered, now) { !$0.kind.isTurn }
                }

                // No card for what you watched happen in the app, nor for muted projects.
                let quiet = watching || isMuted(session)
                if session.completedTurns > before.turns {
                    // A newer turn ended: the cards of the turns before it are past, whether or not this one gets a card of
                    // its own (none when you watched it end): the session went on from them.
                    address(&state, id, .superseded, now) { $0.kind.isTurn && ($0.turn ?? Int.max) < session.completedTurns }
                    // A newer turn: one still waiting is past (the usual rules apply to this one). It waits too, until it
                    // can be told whether it left work running (decided below, at once when it can be). One that ended
                    // while you look at the session is held, not dropped: see below.
                    state.pendingTurns[id] = isMuted(session) ? nil
                        : RouterState.PendingTurn(turns: session.completedTurns, message: stamp.message, held: watching)
                }
                if let current, current.ms != previous, watching, !isMuted(session) {
                    state.heldWaits[id] = RouterState.HeldWait(ms: current.ms, toolUseID: current.toolUseID, kind: current.kind, text: current.text)
                }
                if let current, current.ms != previous, !quiet {
                    add(&state, RouterCard(id: "\(id)#w\(current.ms)", sessionID: id, kind: current.kind, title: session.title,
                                           folder: session.folder, text: current.text, createdAt: now, toolUseID: current.toolUseID), now)
                }
            }

            // A wait held while you looked: carded when you leave, if it is still on; dropped once it is over.
            if let held = state.heldWaits[id] {
                if ongoing != held.ms || isMuted(session) {
                    state.heldWaits[id] = nil
                } else if !watching {
                    state.heldWaits[id] = nil
                    add(&state, RouterCard(id: "\(id)#w\(held.ms)", sessionID: id, kind: held.kind, title: session.title,
                                           folder: session.folder, text: held.text, createdAt: now, toolUseID: held.toolUseID), now)
                }
            }

            // A turn waiting: carded once the session is no longer running, its background work looked at since, and none
            // left (with the summary as it is then); forgotten if you've written since or another turn began.
            if let pending = state.pendingTurns[id] {
                if stamp.message != pending.message || session.completedTurns != pending.turns {
                    state.pendingTurns[id] = nil
                } else if !session.running, inventory?.contains(id) ?? true, !busy {
                    if isMuted(session) {
                        state.pendingTurns[id] = nil
                    } else if watching {
                        // Being looked at: no card now. If you leave without having read it, it comes then.
                        if !pending.held || pending.leftMs != nil {
                            state.pendingTurns[id]?.held = true
                            state.pendingTurns[id]?.leftMs = nil
                        }
                    } else if !pending.held {
                        state.pendingTurns[id] = nil
                        addTurn(&state, session, turns: pending.turns, message: pending.message, now: now)
                    } else if unread?.contains(id) == true || unread == nil {
                        state.pendingTurns[id] = nil
                        addTurn(&state, session, turns: pending.turns, message: pending.message, now: now)
                    } else {
                        // Left, and the app shows it read, or hasn't shown the dot yet: wait out its lag, then let it go.
                        let left = pending.leftMs ?? Stamp.ms(now)
                        if pending.leftMs != left { state.pendingTurns[id]?.leftMs = left }
                        if Stamp.ms(now) - left >= unreadGraceMs { state.pendingTurns[id] = nil }
                    }
                }
            }

            set(&state.waits, id, ongoing)
            if ongoing == nil {
                set(&state.waitTools, id, nil)
            } else if ongoing != previous {
                set(&state.waitTools, id, current?.toolUseID)
            } else if let tool = current?.toolUseID {
                set(&state.waitTools, id, tool)
            }
            if let ongoing, let tool = state.waitTools[id], forms?[id]?.contains(tool) == true {
                set(&state.formSeen, id, ongoing)
            } else if state.formSeen[id] != nil, state.formSeen[id] != ongoing {
                state.formSeen[id] = nil
            }

            // The summary is written after the turn ends: the open card of that turn takes it when it comes.
            // (The turn's card id is made once, not once per card it is compared with: every session against every card.)
            if let summary = session.summary, case let turnID = "\(id)#t\(session.completedTurns)",
               let i = state.cards.firstIndex(where: { $0.isOpen && $0.id == turnID }) {
                let kind = RouterTriage.kind(blocked: summary.blocked, triage: state.cards[i].triage)
                let text = summary.detail.isEmpty ? placeholder : summary.detail
                if state.cards[i].kind != kind { state.cards[i].kind = kind }
                if state.cards[i].text != text { state.cards[i].text = text }
            }
            // Open cards follow a renamed session.
            for i in state.cards.indices where state.cards[i].sessionID == id && state.cards[i].isOpen
                && state.cards[i].title != session.title {
                state.cards[i].title = session.title
            }
            set(&state.seen, id, stamp.text)
        }

        // Sessions that are gone are forgotten: one that comes back is seen for the first time again.
        keep(&state.seen) { key, _ in live[key] != nil }
        keep(&state.waits) { key, _ in live[key] != nil }
        keep(&state.waitTools) { key, _ in live[key] != nil }
        keep(&state.formSeen) { key, _ in live[key] != nil }
        keep(&state.pendingTurns) { key, _ in live[key] != nil }
        keep(&state.heldWaits) { key, _ in live[key] != nil }
        keep(&state.replies) { key, _ in live[key] != nil }
        // A handled turn outlasts its session's archiving (unarchived, it is no new card): forgotten once the session is gone
        // for good, and past the `maxHandled` sessions active last. `listed`: every session the read listed, archived ones too
        // (the store's sessions leave the archived out); nil: `sessions`.
        let known = listed ?? Dictionary(sessions.map { ($0.id, $0.lastActivity) }, uniquingKeysWith: { a, b in max(a, b) })
        keep(&state.handledTurns) { key, _ in known[key] != nil }
        if state.handledTurns.count > maxHandled {
            let kept = Set(state.handledTurns.keys.sorted { (known[$0] ?? .distantPast, $0) > (known[$1] ?? .distantPast, $1) }.prefix(maxHandled))
            state.handledTurns = state.handledTurns.filter { kept.contains($0.key) }
        }
        // One the app doesn't list yet is kept for an hour (it is imported a moment after it is made).
        keep(&state.fjordStarted) { key, at in live[key] != nil || now.timeIntervalSince(at) < 3600 }
        // What started a session goes with it, past the same hour (a session is noted as Fjord's before its origin is):
        // its cards keep their own copy.
        let started = state.fjordStarted
        keep(&state.origins) { key, _ in live[key] != nil || started[key] != nil }
        prune(&state)
    }

    /// A message after the session's open turn cards clears them at once: the session has the ball again. Yours is
    /// noted too (`RouterState.replies`), for Jev to read for the questions it left untouched (RouterReplies.swift),
    /// and so is one that may answer those an earlier message left (`unanswered`). One a run of Fjord's sent clears
    /// them as the Router's; the Router reads its own as it sends them. `turns`: the session's finished turns now.
    static func queueReply(_ state: inout RouterState, _ session: String, turns: Int, _ message: Int64, now: Date) {
        let fjord = fjordSent(state, session, turns: turns, atMs: message)
        let older = { (card: RouterCard) in card.kind.isTurn && message > card.replyAfter }
        let cleared = state.cards.contains { $0.sessionID == session && $0.isOpen && older($0) }
        address(&state, session, fjord ? .router : .reply, now, where: older)
        guard !fjord, cleared || unanswered(state.cards, session, turns: turns) != nil else { return }
        state.replies[session] = max(state.replies[session] ?? 0, message)
    }

    /// The card of the session's latest turn when a message of yours cleared it leaving questions untouched (`skipped`):
    /// they are yours to answer while it works, until its next turn ends.
    static func unanswered(_ cards: [RouterCard], _ session: String, turns: Int) -> RouterCard? {
        guard let card = cards.last(where: { $0.sessionID == session && $0.turn == turns }), !card.isOpen,
              card.addressedBy == .reply || card.addressedBy == .router, card.skipped?.isEmpty == false else { return nil }
        return card
    }

    /// What the session went on without when its turn `turns` ended: its previous turn's questions your message left.
    static func wentAhead(_ cards: [RouterCard], _ session: String, turns: Int) -> [String]? {
        cards.last { $0.sessionID == session && $0.turn == turns - 1 && ($0.addressedBy == .reply || $0.addressedBy == .router) }?
            .skipped
    }

    /// Whether Fjord sent the session the user message at `ms` (`turns`: the session's finished turns now): its first
    /// message as it was made, or one a run delivered, by the run's record of it (`RouterDecision.delivered`). The
    /// session's plugin submits a delivery a moment before the run hears it went, so the message is that send's within
    /// `deliveredSlack` of it, never minutes after: a reply of yours a little later is yours. One sent while the
    /// session was busy waits for the turn under way to end, so until that turn has (and the delivery's own turn
    /// hasn't), a message is the delivery's.
    private static func fjordSent(_ state: RouterState, _ session: String, turns: Int, atMs ms: Int64) -> Bool {
        // The session's own first message goes out as soon as it is made, before any run links it.
        if let made = state.fjordStarted[session], Stamp.ms(made) - 5_000 <= ms, ms <= Stamp.ms(made) + 300_000 { return true }
        return state.decisions.contains { entry in
            entry.parts.contains { part in
                guard let sent = part.delivered, sent.session == session else { return false }
                let at = Stamp.ms(sent.at)
                guard at - deliveredSlack <= ms else { return false }
                if ms <= at + deliveredSlack { return true }
                return sent.busy && turns <= sent.turns + 1 && ms <= at + Int64(RouterDecision.Delivered.window * 1000)
            }
        }
    }

    /// How far from a delivery's recorded time (ms) its message may show in the session.
    static let deliveredSlack: Int64 = 15_000

    /// The card of a finished turn, with the app's summary as it is now (or the placeholder until it's written).
    private static func addTurn(_ state: inout RouterState, _ session: ClaudeSession, turns: Int, message: Int64?, now: Date) {
        let blocked = session.summary?.blocked == true
        let detail = session.summary?.detail ?? ""
        var card = RouterCard(id: "\(session.id)#t\(turns)", sessionID: session.id, kind: blocked ? .stuck : .done,
                              title: session.title, folder: session.folder, text: detail.isEmpty ? placeholder : detail,
                              createdAt: now, turnMessage: message)
        card.wentAhead = wentAhead(state.cards, session.id, turns: turns)
        add(&state, card, now)
    }

    /// The card of a finished turn found after the fact (the launch's look back, see `Store.rescanTurns`), with its triage
    /// and as of when the turn ended; nil when the turn had a card already.
    static func addTurn(_ state: inout RouterState, _ session: ClaudeSession, triage: RouterTriage, text: String, at: Date,
                        now: Date = Date()) -> RouterCard? {
        let id = "\(session.id)#t\(session.completedTurns)"
        guard !state.cards.contains(where: { $0.id == id }) else { return nil }
        var card = RouterCard(id: id, sessionID: session.id, kind: RouterTriage.kind(blocked: session.summary?.blocked == true, triage: triage),
                              title: session.title, folder: session.folder, text: text, createdAt: at,
                              turnMessage: session.lastUserMessage.map(Stamp.ms))
        card.triage = triage
        card.wentAhead = wentAhead(state.cards, session.id, turns: session.completedTurns)
        add(&state, card, now)
        return state.cards.last
    }

    /// Turning the Router on again: what happened to the open cards while it was off is judged from how things are now
    /// (there are no edges to go by). The waits that survive are kept; the sessions are then seen for the first time again.
    static func reconcile(_ state: inout RouterState, sessions: [ClaudeSession], activity: [String: ClaudeActivity],
                          forms: [String: Set<String>]? = nil, now: Date) {
        let live = Dictionary(sessions.filter { !$0.isArchived }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // What changed since the feed last looked, from the stamps saved then (cleared below): a turn that finished while it
        // was off ends its wait even before the app writes the summary.
        func moved(_ session: ClaudeSession) -> (turns: Bool, message: Bool) {
            guard let before = state.seen[session.id].flatMap(Stamp.init) else { return (false, false) }
            let now = Stamp(session)
            return (now.turns > before.turns, now.message != before.message)
        }
        for i in state.cards.indices where state.cards[i].isOpen {
            let card = state.cards[i]
            var by: RouterCard.Addressed?
            if let session = live[card.sessionID] {
                let stamp = Stamp(session)
                let change = moved(session)
                if !card.kind.isTurn, let message = stamp.message, message > card.replyAfter || change.message {
                    by = .reply
                } else if card.kind.isTurn, let message = stamp.message, message > card.replyAfter {
                    queueReply(&state, session.id, turns: stamp.turns, message, now: now)
                } else if !card.kind.isTurn, change.turns {
                    by = .answered
                } else if !card.kind.isTurn, let ms = card.waitMs,
                          state.waits[session.id] != ms
                            || waitEnded(state, session, ms: ms, toolUseID: card.toolUseID, activity: activity[session.id], forms: forms) {
                    by = .answered
                }
            } else {
                by = .gone
            }
            if let by {
                state.cards[i].addressedAt = now
                state.cards[i].addressedBy = by
            }
        }
        // A wait whose card was just settled is over.
        for (id, ms) in state.waits where !state.cards.contains(where: { $0.sessionID == id && $0.isOpen && $0.waitMs == ms }) {
            if let session = live[id], !waitEnded(state, session, ms: ms, toolUseID: state.waitTools[id], activity: activity[id], forms: forms),
               session.lastUserMessage.map({ Stamp.ms($0) <= ms }) ?? true, moved(session) == (false, false) {
                continue
            }
            state.waits[id] = nil
            state.waitTools[id] = nil
            state.formSeen[id] = nil
        }
        state.seen = [:]
    }

    /// Addresses the open cards of a session that `matches`.
    static func address(_ state: inout RouterState, _ sessionID: String, _ by: RouterCard.Addressed, _ now: Date,
                        where matches: (RouterCard) -> Bool = { _ in true }) {
        for i in state.cards.indices where state.cards[i].sessionID == sessionID && state.cards[i].isOpen && matches(state.cards[i]) {
            state.cards[i].addressedAt = now
            state.cards[i].addressedBy = by
        }
    }

    /// Opens a card again by hand. One open card per session: the session's others are superseded.
    static func reopen(_ state: inout RouterState, _ id: String, now: Date) {
        guard let i = state.cards.firstIndex(where: { $0.id == id }), !state.cards[i].isOpen else { return }
        address(&state, state.cards[i].sessionID, .superseded, now) { $0.id != id }
        state.cards[i].addressedAt = nil
        state.cards[i].addressedBy = nil
        state.cards[i].unread = nil
    }

    /// One open card per session: a new one supersedes the others. A card made before (and reopened, or addressed) is
    /// not made twice.
    private static func add(_ state: inout RouterState, _ card: RouterCard, _ now: Date) {
        guard !state.cards.contains(where: { $0.id == card.id }) else { return }
        address(&state, card.sessionID, .superseded, now)
        var card = card
        if card.origin == nil { card.origin = state.origins[card.sessionID] }
        state.cards.append(card)
    }

    /// Keeps the file small: past `maxCards` addressed cards, those addressed longest ago go, so a card you just archived
    /// stays however old it is (the Brief checks it off, its Revert can open it again). An open card never does (there is
    /// one per session at most, so they stay few): it still wants you. A handled turn's card that goes leaves its turn
    /// number behind (`handledTurns`); the changes keep the latest.
    static func prune(_ state: inout RouterState) {
        let addressed = state.cards.enumerated().filter { !$0.element.isOpen }
        if addressed.count > maxCards {
            let drop = Set(addressed.sorted { ($0.element.addressedAt ?? $0.element.createdAt) < ($1.element.addressedAt ?? $1.element.createdAt) }.prefix(addressed.count - maxCards).map(\.offset))
            for i in drop where state.cards[i].kind.isTurn {
                let card = state.cards[i]
                guard let range = card.id.range(of: "#t", options: .backwards), let turn = Int(card.id[range.upperBound...]) else { continue }
                state.handledTurns[card.sessionID] = max(state.handledTurns[card.sessionID] ?? 0, turn)
            }
            state.cards = state.cards.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        // Past `maxChanges`, the oldest go, but never one still waiting for your Apply or Discard.
        if state.changes.count > maxChanges {
            var over = state.changes.count - maxChanges
            state.changes = state.changes.filter { change in
                guard over > 0, !change.isPending else { return true }
                over -= 1
                return false
            }
        }
    }
}

// MARK: - Store

extension Store {
    /// Counts each card's changes (made, addressed, reopened, retitled…), so a late action can tell a card that changed and
    /// changed back from one that never moved. How it is told to you (its brief, read or not) is no change to act on.
    func countCardChanges(from old: [RouterCard]) {
        let before = Dictionary(old.map { ($0.id, $0.acted) }, uniquingKeysWith: { a, _ in a })
        for card in router.cards where before[card.id] != card.acted { cardRevisions[card.id, default: 0] &+= 1 }
    }

    /// Open cards first, newest first in each part.
    var routerCards: [RouterCard] {
        router.cards.sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id
        }
    }

    var openRouterCards: [RouterCard] { routerCards.filter(\.isOpen) }

    /// Open cards whose move is yours (questions, plans, asks, stuck turns, last steps, waits over that nothing continues),
    /// and those worth a look (finished turns with something to tell); a session waiting is neither, nor a turn that went
    /// to the history unread (RouterTiers.swift).
    var routerCounts: (needsYou: Int, notes: Int) {
        // As on the page: a turn whose session still has subagents or commands running isn't counted yet.
        // Read by the sidebar, the bar and the page's switch on every redraw: counted again only when the cards or what
        // runs changed (`RouterMemo`).
        let tasks = routerTasks
        let inputs = RouterMemo.CountInputs(cards: router.cards, tasks: tasks)
        if let memo = RouterMemo.counts, memo.inputs == inputs { return memo.counts }
        var needsYou = 0, notes = 0
        for card in router.cards where card.isOpen && RouterPage.shows(card, tasks: tasks) {
            switch routerTier(card) {
            case .needsYou: needsYou += 1
            case .note, .done: notes += 1
            case .waiting: break
            }
        }
        RouterMemo.counts = (inputs, (needsYou, notes))
        return (needsYou, notes)
    }

    /// The form Fjord's hook holds for this card's own question or plan: the one for the very call the card waits on
    /// (an older card never shows a newer question's form, nor a card a form whose call isn't known yet).
    func pendingForm(for card: RouterCard) -> PendingForm? {
        guard card.kind == .question || card.kind == .plan, card.isOpen, let call = card.toolUseID else { return nil }
        if let cli = claudeSessions[card.sessionID]?.cliID, let form = pendingForms[cli], form.toolUseID == call,
           form.isPlan == (card.kind == .plan) { return form }
        guard let start = router.pendingDesktopStarts.first(where: { $0.desktopSessionID == card.sessionID && $0.state == .matched }),
              let form = router.guestPendingForms.first(where: { $0.location == start.location && $0.form.cliSessionID == start.guestSessionID })?.form,
              form.toolUseID == call, form.isPlan == (card.kind == .plan) else { return nil }
        return form
    }

    func guestPendingForm(for card: RouterCard) -> GuestPendingForm? {
        guard card.kind == .question || card.kind == .plan, card.isOpen, let call = card.toolUseID,
              let start = router.pendingDesktopStarts.first(where: { $0.desktopSessionID == card.sessionID && $0.state == .matched }),
              let guest = router.guestPendingForms.first(where: { $0.location == start.location && $0.form.cliSessionID == start.guestSessionID }),
              guest.form.toolUseID == call, guest.form.isPlan == (card.kind == .plan) else { return nil }
        return guest
    }

    /// The calls whose forms Fjord's hook holds, by desktop session; nil until the forms folder has been read.
    private var heldForms: [String: Set<String>]? {
        guard routerFormsLoaded else { return nil }
        var held: [String: Set<String>] = [:]
        for session in claudeSessions.values where !pendingForms.isEmpty {
            if let cli = session.cliID, let call = pendingForms[cli]?.toolUseID { held[session.id, default: []].insert(call) }
        }
        for pending in router.pendingDesktopStarts where pending.state == .matched {
            if let call = router.guestPendingForms.first(where: { $0.location == pending.location && $0.form.cliSessionID == pending.guestSessionID })?.form.toolUseID,
               let desktop = pending.desktopSessionID { held[desktop, default: []].insert(call) }
        }
        return held
    }

    /// The session shown in the app right now: the most recently focused one, if the app is in front. Asked afresh each
    /// time: the app may have gone to the back since the last read.
    var viewingNow: String? {
        guard claudeIsFrontmost() else { return nil }
        return claudeSessions.values.filter { !$0.isArchived }
            .max { ($0.lastFocused ?? .distantPast) < ($1.lastFocused ?? .distantPast) }?.id
    }

    /// Runs the feed on what was read last. Only while both the Router and the sessions extension are on, and once the
    /// app's sessions have been read (before that, every card would look gone).
    func feedRouter(now: Date = Date()) {
        guard router.enabled, agents.enabled, claudeLink == .ok else { return }
        var state = router
        let forms = heldForms
        if routerReconcilePending {
            routerReconcilePending = false
            RouterFeed.reconcile(&state, sessions: Array(claudeSessions.values), activity: claudeActivity, forms: forms, now: now)
        }
        RouterFeed.update(&state, sessions: Array(claudeSessions.values), activity: claudeActivity,
                          muted: [], mutedSessions: mutedSessionIDs(), viewing: viewingNow, unread: agents.appUnread.map(Set.init), forms: forms, tasks: claudeTasks,
                          inventory: claudeTaskInventory, listed: claudeSessionsListed, now: now)
        applyTurnSummaries(&state)
        if state != router {
            let known = Dictionary(router.cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            router = state
            // New cards, and open ones that need you only now (a turn's summary came late, blocked): announced once.
            let fresh = state.cards.filter { card in
                guard card.isOpen, let was = known[card.id] else { return card.isOpen }
                return card.kind.needsYou && was.isOpen && !was.kind.needsYou && !routerAttention.delivered.contains(card.id)
            }
            if !fresh.isEmpty { announceRouterCards(fresh) }
        }
        // What the turns ended on (Jev), and the waits that are over.
        triageTurns()
        judgeReplies()
        resolveWaits(now: now)
    }

    /// By hand: addressed, or open again (which supersedes the session's other open cards).
    func setCardAddressed(_ id: String, _ addressed: Bool, now: Date = Date()) {
        guard let card = router.cards.first(where: { $0.id == id }), card.isOpen == addressed else { return }
        var state = router
        if addressed {
            RouterFeed.address(&state, card.sessionID, .you, now) { $0.id == id }
        } else {
            RouterFeed.reopen(&state, id, now: now)
        }
        router = state
    }

    /// Opens the card's session in Claude. The card stays open: looking at a session addresses nothing, only marking it
    /// by hand or acting on it does.
    func openCard(_ id: String) {
        guard let card = router.cards.first(where: { $0.id == id }) else { return }
        openAgent(card.sessionID)
    }

    /// Every open card of a session (the Router sent it a message, say).
    func addressCards(forSession sessionID: String, by: RouterCard.Addressed, now: Date = Date()) {
        var state = router
        RouterFeed.address(&state, sessionID, by, now)
        if state != router { router = state }
    }

    // MARK: Switching it

    /// The hook, the forms folder and the feed follow the toggle. Installing touches `~/.claude/settings.json`, so it
    /// happens off the main thread; `routerHookError` says why it failed.
    func setRouterEnabled(_ on: Bool, now: Date = Date()) {
        guard on != router.enabled else { return }
        routerGeneration &+= 1
        var state = router
        state.enabled = on
        if on {
            state.enabledAt = state.enabledAt ?? now
            // What happened while it was off settles the open cards first (see `RouterFeed.reconcile`).
            routerReconcilePending = true
        }
        router = state
        // Off: a triage under way comes to nothing, and no banner held for one comes; your messages' runs stop.
        if !on { routerTriager.turnedOff(); routerBriefer.cancelAll(); routerDispatcher.stopAll(reason: RouterDispatcher.unlinkedWords, actions: true); routerDispatcher.unlinked() }
        applyRouterSwitch(install: true)
        if on {
            feedRouter(now: now)
            // What it saved (a turn waiting to know what it left running, say) is decided by the next read: one now.
            requestClaudeRead()
        }
    }

    /// A read of the Claude app now (a store that doesn't persist reads nothing on its own).
    private func requestClaudeRead() {
        guard persists else { return }
        refreshClaude()
    }

    /// At launch: the forms folder and its watcher, and the hook again if the app moved since it was installed.
    func startRouter() {
        if router.enabled { applyRouterSwitch(install: false) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await GuestRouterRuntime.shared.rehydrate(store: self)
        }
    }

    /// Where the Router's files are, when they may be touched at all: never in a demo, and in a test only where the test said.
    var routerFiles: RouterPaths? {
        if let routerPaths { return routerPaths }
        guard persists, !Store.isDemo else { return nil }
        return RouterPaths.live()
    }

    /// `install` true: install or uninstall as the toggle says. False (launch): re-install only an outdated hook, and the
    /// plugin when it's outdated or missing.
    private func applyRouterSwitch(install: Bool) {
        let on = router.enabled
        guard let paths = routerFiles else { return }
        observePluginQuit()
        // The key goes the moment the Router is switched off, whatever the CLI does next; a switch-on still under way is
        // fenced off from making it again.
        let generation: Int
        if on {
            generation = relayKeyFence.advance()
        } else {
            relayKeyFence.revoke(paths.relayKey, presence: paths.pluginSessions)
            generation = relayKeyFence.current
            relayKeyCache = nil
        }
        if on {
            formBridge.start(dir: paths.forms) { [weak self] forms in
                guard let self, self.router.enabled else { return }
                let first = !self.routerFormsLoaded
                self.routerFormsLoaded = true
                guard first || forms != self.pendingForms else { return }
                if forms != self.pendingForms { self.pendingForms = forms }
                // A form going away ends its wait (answered, or its hook gave up).
                self.feedRouter()
                // A form held only now: its question's or plan's brief is made again from it.
                self.briefForms()
            }
        } else {
            formBridge.stop()
            routerFormsLoaded = false
            if !pendingForms.isEmpty { pendingForms = [:] }
        }
        let executable = routerExecutable ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
        let runner = routerPluginRunner ?? (UnderTest.isRunning ? nil : ClaudePluginInstaller.processRunner)
        let findBinary = routerClaudeBinary ?? { RouterStatus.findDefault() }
        let version = ClaudePlugin.version(app: routerAppVersion)
        let previous = routerHookWork
        routerHookWork = Task { [weak self] in
            await previous?.value
            let result = await Task.detached(priority: .utility) { () -> (FormHookInstaller.Status, String?) in
                let installer = FormHookInstaller(claudeDir: paths.claudeDir)
                do {
                    try FormBridge.setEnabled(on, dir: paths.forms)
                    if on {
                        if install || installer.status(executable: executable) == .outdated {
                            try installer.install(executable: executable)
                        }
                    } else if install {
                        try installer.uninstall()
                    }
                    return (installer.status(executable: executable), nil)
                } catch {
                    return (installer.status(executable: executable), error.localizedDescription)
                }
            }.value
            guard let self else { return }
            if self.routerHookStatus != result.0 { self.routerHookStatus = result.0 }
            if self.routerHookError != result.1 { self.routerHookError = result.1 }
            guard let runner else { return }
            let fence = self.relayKeyFence
            let plugin = await Self.switchPluginNow(on: on, install: install, paths: paths, version: version, findBinary: findBinary,
                                                    run: runner, fence: fence, generation: generation)
            if self.routerPluginStatus != plugin.status { self.routerPluginStatus = plugin.status }
            if self.routerPluginError != plugin.error { self.routerPluginError = plugin.error }
            if let key = plugin.key, fence.current == generation { self.relayKeyCache = key }
        }
    }

    /// Quitting stops the installer's runs of the CLI (each is ended and its exit confirmed).
    private func observePluginQuit() {
        guard pluginQuitObserver == nil else { return }
        pluginQuitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                    queue: .main) { _ in PluginRuns.shared.shutdown() }
    }

    struct PluginSwitch: Sendable {
        var status: ClaudePluginInstaller.Status?
        var error: String?
        /// The key, read off the main thread, for `signRelay`.
        var key: RelayKeyCache?
    }

    /// On (unless a later switch superseded it): the folder is written at this version, the key made once (fenced: see
    /// `RelayKeyFence`), and Claude Code brought to the folder; at launch only when its plugin is missing or outdated.
    /// Off: the plugin and its marketplace are taken out (the key went already, at the switch).
    /// Runs off the main thread, finding Claude Code there too (`findBinary` walks folders).
    nonisolated static func switchPluginNow(on: Bool, install: Bool, paths: RouterPaths, version: String,
                                            findBinary: @escaping @Sendable () -> String?,
                                            run: @escaping ClaudePluginInstaller.Runner, fence: RelayKeyFence,
                                            generation: Int) async -> PluginSwitch {
        let installer = ClaudePluginInstaller(folder: paths.plugin, binary: findBinary(), run: run)
        do {
            if on {
                guard fence.current == generation else { return PluginSwitch(status: try? await installer.status(version: version)) }
                try ClaudePlugin.write(to: paths.plugin, version: version, presence: paths.pluginSessions, key: paths.relayKey,
                                       registry: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true))
                try fence.ifCurrent(generation) { try ClaudePlugin.ensureKey(at: paths.relayKey) }
                let key = RelayKeyCache.load(paths.relayKey)
                let status = try await installer.status(version: version)
                if install || status == .notInstalled || status == .outdated {
                    try await installer.install(version: version)
                }
                return PluginSwitch(status: try await installer.status(version: version), key: key)
            } else if install {
                try await installer.uninstall()
            }
            return PluginSwitch(status: try await installer.status(version: version))
        } catch {
            return PluginSwitch(status: try? await installer.status(version: version), error: error.localizedDescription)
        }
    }

    /// `switchPluginNow` for a caller that can't wait: blocks its thread until done. Call it off the main thread.
    nonisolated static func switchPlugin(on: Bool, install: Bool, paths: RouterPaths, version: String, binary: String?,
                                         run: @escaping ClaudePluginInstaller.Runner) -> (ClaudePluginInstaller.Status?, String?) {
        final class Box: @unchecked Sendable { var value = PluginSwitch() }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let fence = RelayKeyFence()
        let generation = fence.current
        Task.detached {
            box.value = await switchPluginNow(on: on, install: install, paths: paths, version: version, findBinary: { binary },
                                              run: run, fence: fence, generation: generation)
            done.signal()
        }
        done.wait()
        return (box.value.status, box.value.error)
    }

    // MARK: Relaying as the person

    /// The CLI session ids of the sessions Fjord's plugin runs in now (only those can take a message as the person's
    /// own): its presence files under the current key, each bound to a live process Claude Code still registers for
    /// that session. Reads the registry and the presence folder: call it off the main thread.
    nonisolated func sessionsWithPlugin(paths: RouterPaths, keyID: String?) -> Set<String> {
        ClaudePlugin.sessions(in: paths.pluginSessions,
                              registry: ClaudePeers.registry(dir: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true)),
                              keyID: keyID)
    }

    /// `sessionsWithPlugin(paths:keyID:)` for the Router's own files and the key as last read.
    func sessionsWithPlugin() -> Set<String> {
        guard let paths = routerFiles else { return [] }
        return sessionsWithPlugin(paths: paths, keyID: relayKeyCache?.keyID)
    }

    /// `body` signed for the session whose CLI session id is `target`, ready to send as it is; nil when there's no key (the
    /// Router is off, or not set up yet). The key is read off the main thread (by the switch, or `reloadRelayKey`) and used
    /// while its file is the same; here only a stat is made. A key not read yet, or changed, is read again in the
    /// background, and nil is returned meanwhile.
    func signRelay(body: String, target: String, settings: SessionSettings? = nil) -> String? {
        guard let paths = routerFiles else { return nil }
        if let cached = relayKeyCache, cached.matches(paths.relayKey) {
            return RelaySigner.sign(body: body, target: target, key: cached.key, model: settings?.model, effort: settings?.effort)
        }
        relayKeyCache = nil
        Task { await reloadRelayKey() }
        return nil
    }

    /// Reads the key off the main thread; kept only if no switch came meanwhile. True when there is one.
    @discardableResult
    func reloadRelayKey() async -> Bool {
        guard let paths = routerFiles else { return false }
        let generation = relayKeyFence.current
        // On a queue of its own, not Swift's pool: a busy pool must not hold a message waiting for its key.
        let loaded = await withCheckedContinuation { (done: CheckedContinuation<RelayKeyCache?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: RelayKeyCache.load(paths.relayKey)) }
        }
        guard relayKeyFence.current == generation else { return false }
        if relayKeyCache != loaded { relayKeyCache = loaded }
        return loaded != nil
    }
}
