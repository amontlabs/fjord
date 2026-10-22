import Foundation

// The Router's decision log (docs/design/spec/router.md): one entry per run: what set it off, what was decided, what was
// done, and how it ended. It is the Router's history on the page, and its last entries are context for later runs.

struct RouterDecision: Identifiable, Equatable {
    enum Trigger: Codable, Equatable {
        /// Your message, or something you did on a card (what it was, in words).
        case you(String)
        /// An inbox action that started a session itself, as it did before its message went through the Router: its category
        /// and thing (names), the action, and its run. Only in entries from before; an action's message now is `.you`, with
        /// `fromAction`.
        case action(category: String, thing: String, actionID: String, runID: String?)
        /// A session did something the Router acted on.
        case session(sessionID: String, event: String)
        /// Fjord itself (a change with no message behind it).
        case system
    }

    /// What was decided: the target, the intent or label, and how sure when it was classified.
    struct Decided: Codable, Equatable {
        var target: String?
        var intent: String?
        var label: String?
        var confidence: Double?
        /// You went with the target: Jev's pick shown while you typed (sent as it was, or clicked), his suggestion picked on
        /// an ask, or a target you pinned. An example for the next routings, as corrections are.
        var confirmed: Bool?
        /// The target itself (`session:<id>`, `answer:<card>`, `new:<folder>`, an intent), and on a correction the one Jev
        /// suggested: what examples name it by, as titles can be shared or change. Nil in entries from before.
        var targetID: String?
        var fromID: String?
        init(target: String? = nil, intent: String? = nil, label: String? = nil, confidence: Double? = nil) {
            self.target = target
            self.intent = intent
            self.label = label
            self.confidence = confidence
        }
    }

    enum Done: Codable, Equatable {
        /// Your words went to a session (or started one): what `lastTold` reads.
        var sendsWords: Bool {
            switch self {
            case .sent, .started, .interrupted: true
            default: false
            }
        }

        /// A message sent to a session, with what you wrote when it was rephrased.
        case sent(to: String, text: String, original: String?)
        case started(session: String?, project: String, model: String?, effort: String?)
        /// A prefilled guest session handed off to Claude Desktop, without a local peer or first delivery.
        case preparedGuest(project: String, location: String, pendingStart: String)
        case changed(UUID)
        /// A card answered or marked handled (its id).
        case answered(card: String)
        /// The Router asked you which of these.
        case asked([String])
        /// A card your message resolved, by Jev's judgement (its title, and what you wrote).
        case resolved(card: String, message: String)
        case failed(String)
        /// A message sent here taken back (`RouterDispatcher.cancel`): how far it had gone.
        case cancelled(Cancelled)
        /// A card archived at once on the words (`RouterActionChecks`), its change (with Revert) and the card's title.
        case archived(title: String, change: UUID)
        /// A session's running turn stopped on the words: the session's title and project, and when the turn began.
        case stopped(title: String, project: String, since: Date?)
        /// A running turn stopped and the words sent as the session's next message (`stopped`: one was running).
        case interrupted(title: String, text: String, stopped: Bool)
    }

    /// How a cancel went, as the session's plugin answered it.
    enum Cancelled: String, Codable, Equatable {
        /// Claude hadn't started on it: it never will.
        case beforeStart = "before-start"
        /// Claude was working on it: the turn was stopped.
        case aborted
        /// Its turn was already over.
        case tooLate = "too-late"
        /// Claude read it together with words you typed in that session yourself: not stopped, so neither are they.
        case together
        /// The session's plugin was reloaded since it took it: it can't tell.
        case unknown

        /// The plugin's ack ("ok aborted"); nil for anything else.
        init?(ack: String) {
            guard ack.hasPrefix("ok "), let how = Self(rawValue: String(ack.dropFirst(3))) else { return nil }
            self = how
        }

        /// Whether the message was stopped.
        var stopped: Bool { self == .beforeStart || self == .aborted }

        var words: String {
            switch self {
            case .beforeStart: "cancelled before Claude started on it"
            case .aborted: "cancelled: Claude stopped working on it; what it already did stays done, and a command it was running finishes unseen"
            case .tooLate: "too late to cancel: Claude had finished with it"
            case .together: "not cancelled: Claude read it together with words you typed there, which a cancel would stop too"
            case .unknown: "couldn't tell whether it was cancelled: Fjord's plugin in the session was reloaded since"
            }
        }
    }

    /// The message a send put in a session, so it can be taken back (`RouterDispatcher.cancel`): the session (Fjord's
    /// id, and Claude Code's, which its inbox goes by), the delivery's nonce, when, how many turns the session had
    /// finished then and whether one was running, whether its plugin takes aborts, and how a cancel went. Nil for
    /// anything else and in entries from before.
    struct Delivered: Codable, Equatable {
        var session: String
        var cli: String
        var nonce: String
        var at: Date
        var turns: Int
        var busy: Bool
        var abortable: Bool
        var cancelled: Cancelled?

        /// How long a Cancel is offered after a send: past it, the turn has nearly always finished.
        static let window: TimeInterval = 10 * 60

        /// Whether a Cancel can still stop it, as Fjord sees the session (`now`, and its turns finished now): not
        /// cancelled yet, its plugin takes aborts, sent within `window`, the session not archived, and its turn not
        /// seen to finish (the one it waited behind, then its own). A session Fjord hasn't read yet (one just started)
        /// is given the window. The plugin has the last word: a turn over meanwhile is told as too late.
        func cancellable(session: ClaudeSession?, now: Date) -> Bool {
            guard cancelled == nil, abortable, now.timeIntervalSince(at) < Self.window else { return false }
            guard let session else { return true }
            return !session.isArchived && session.completedTurns < turns + (busy ? 2 : 1)
        }
    }

    enum Outcome: Codable, Equatable {
        case done
        case reverted
        /// You chose something other than what was suggested.
        case corrected(from: String, to: String)
        case pending
    }

    struct Links: Codable, Equatable {
        var sessions: [String] = []
        var cards: [String] = []
        var changes: [UUID] = []
    }

    /// The entry's id. A one-part entry's only part has the same id (every entry from before, and every one-place message);
    /// the parts of a divided one have ids of their own (`divide(into:)`).
    var id = UUID() { didSet { if parts.count == 1 { parts[0].id = id } } }
    var at: Date
    var trigger: Trigger
    /// The places the message went to, in order; never empty. Most messages are one part, which the accessors below read
    /// and write as the entry's own (`decision`, `done`, `outcome`, `links`, `reply`, `note`, `delivered`).
    var parts: [Part]

    /// The pills of your message (`.you`), drawn where their "@name" is; nil for anything else and in entries from before.
    var mentions: [RouterMention]?
    /// A message a category's "Then" sent for a thing (your prompt, `.you`): the category, the thing, the action and its run.
    /// Nil for anything else.
    var fromAction: SessionOrigin?
    /// The same message's session settings: what a session the Router starts for it is called and runs on. Nil for anything
    /// else, and in entries from before (the thing's line is the title then, on your defaults).
    var actionStart: ActionStart?
    /// No longer set. Kept so entries from before still decode (entries from the compound run also carry keys the decoder
    /// ignores).
    var generated: Bool?

    /// One place a message went to: the words for it, and everything that happened there. A message that goes to one place has
    /// one part, which is the entry itself (same id); a divided one (docs/design/spec/router.md, Several places) has one per
    /// place, each with an id of its own so the runs, the asks and the history act on a part as they do on a message.
    struct Part: Codable, Equatable, Identifiable {
        var id: UUID
        /// The words for this place; nil: the whole message.
        var text: String?
        /// The pills inside `text`, ranged in it (not in the whole message).
        var mentions: [RouterMention]?
        /// Where it was fixed to go (a target, or `project:<folder>`); nil for a message routed whole.
        var place: String?
        /// The target whose answer it was held for; nil when it didn't wait for one.
        var waitsFor: String?
        var decision = Decided()
        var done: [Done] = []
        var outcome: Outcome = .pending
        var links = Links()
        var reply: String?
        var note: String?
        var delivered: Delivered?

        init(id: UUID = UUID(), text: String? = nil, mentions: [RouterMention]? = nil, place: String? = nil, waitsFor: String? = nil,
             decision: Decided = Decided(), done: [Done] = [], outcome: Outcome = .pending, links: Links = Links()) {
            self.id = id
            self.text = text
            self.mentions = mentions
            self.place = place
            self.waitsFor = waitsFor
            self.decision = decision
            self.done = done
            self.outcome = outcome
            self.links = links
        }

        /// Its last send was stopped by a cancel: one that sent its words again since (to another place) isn't cancelled.
        var endsCancelled: Bool {
            guard let cancelled = done.lastIndex(where: { if case .cancelled(let how) = $0 { how.stopped } else { false } }) else { return false }
            return done.lastIndex(where: \.sendsWords).map { $0 < cancelled } ?? true
        }

        /// A session was started and its first message has not gone yet: the start is held for the session's process (a held start,
        /// `RouterDispatcher.hold`). Kept with the entry, so it reads the same after Fjord restarts; `settleLostHolds` ends it then.
        var isWaitingToSend: Bool {
            outcome == .pending && done.contains { if case .started = $0 { true } else { false } }
                && !done.contains { switch $0 { case .sent, .failed, .interrupted: true; default: false } }
        }

        /// Adds `done` and the links it implies.
        mutating func add(_ item: Done, session: String? = nil, card: String? = nil) {
            done.append(item)
            switch item {
            case .changed(let id), .archived(_, let id): if !links.changes.contains(id) { links.changes.append(id) }
            default: break
            }
            if let session, !links.sessions.contains(session) { links.sessions.append(session) }
            if let card, !links.cards.contains(card) { links.cards.append(card) }
        }
    }

    struct ActionStart: Codable, Equatable {
        var title: String
        var model: String?
        var effort: String?
    }

    /// Where an action's message came from and what a session started for it is (`RouterContext.action`), as it was sent:
    /// what sending it elsewhere goes with again.
    var actionSource: RouterActionSource? {
        fromAction.map { origin in
            RouterActionSource(origin: origin, title: actionStart?.title ?? origin.thing, model: actionStart?.model,
                               effort: actionStart?.effort)
        }
    }
    /// Its message was stopped where it was sent (a Cancel that wasn't too late).
    var isCancelled: Bool { delivered?.cancelled?.stopped == true }

    init(id: UUID = UUID(), at: Date = Date(), trigger: Trigger, decision: Decided = Decided(), done: [Done] = [],
         outcome: Outcome = .pending, links: Links = Links()) {
        self.id = id
        self.at = at
        self.trigger = trigger
        self.parts = [Part(id: id, decision: decision, done: done, outcome: outcome, links: links)]
    }

    static let maxKept = 1000

    /// Adds `done` and the links it implies (to the only part: a divided message's parts are written one by one, through
    /// `Store.updateDecision` with the part's id).
    mutating func add(_ item: Done, session: String? = nil, card: String? = nil) {
        guard parts.count == 1 else { return }
        parts[0].add(item, session: session, card: card)
    }

    // MARK: Parts

    /// Whether the message went to several places.
    var isDivided: Bool { parts.count > 1 }

    // With one part these read and write the part, as the entry's own fields were. With several they read what the parts
    // add up to, and writing them does nothing: a part is written through its own id.

    /// What was decided: for a divided message, that it was split.
    var decision: Decided {
        get { parts.count == 1 ? parts[0].decision : Decided(intent: "message", label: "split") }
        set { if parts.count == 1 { parts[0].decision = newValue } }
    }

    /// What was done, in the parts' order.
    var done: [Done] {
        get { parts.count == 1 ? parts[0].done : parts.flatMap(\.done) }
        set { if parts.count == 1 { parts[0].done = newValue } }
    }

    /// How it ended: pending while any part is.
    var outcome: Outcome {
        get { parts.count == 1 ? parts[0].outcome : parts.contains { $0.outcome == .pending } ? .pending : .done }
        set { if parts.count == 1 { parts[0].outcome = newValue } }
    }

    /// What it touched: the parts' links together.
    var links: Links {
        get {
            guard parts.count > 1 else { return parts[0].links }
            var all = Links()
            for part in parts {
                all.sessions += part.links.sessions.filter { !all.sessions.contains($0) }
                all.cards += part.links.cards.filter { !all.cards.contains($0) }
                all.changes += part.links.changes.filter { !all.changes.contains($0) }
            }
            return all
        }
        set { if parts.count == 1 { parts[0].links = newValue } }
    }

    var reply: String? {
        get { parts.count == 1 ? parts[0].reply : nil }
        set { if parts.count == 1 { parts[0].reply = newValue } }
    }

    var note: String? {
        get { parts.count == 1 ? parts[0].note : nil }
        set { if parts.count == 1 { parts[0].note = newValue } }
    }

    /// The last message it sent to a session, for a Cancel; a divided message has none of its own (its parts do).
    var delivered: Delivered? {
        get { parts.count == 1 ? parts[0].delivered : nil }
        set { if parts.count == 1 { parts[0].delivered = newValue } }
    }

    /// Every id the entry answers to: its own, and its parts'.
    var ids: [UUID] { parts.count == 1 ? [id] : [id] + parts.map(\.id) }

    /// The places as entries of their own, which is what every run, ask and line works on: the entry itself for one part;
    /// for several, one per part, with the part's id and words (the whole message's when it has none) and pills.
    var places: [RouterDecision] { parts.count == 1 ? [self] : parts.map(projection) }

    /// A part as an entry of its own (`self` when it is the only one). Writing a change made to it back is the store's
    /// (`Store.updateDecision`).
    func projection(_ part: Part) -> RouterDecision {
        guard parts.count > 1 else { return self }
        var entry = RouterDecision(id: part.id, at: at, trigger: part.text.map(Trigger.you) ?? trigger)
        entry.parts = [part]
        entry.mentions = part.text == nil ? mentions : part.mentions
        entry.fromAction = fromAction
        entry.actionStart = actionStart
        return entry
    }

    /// Divides the message among `pieces` (two or more; nothing if it is divided already): each gets a fresh id, so the
    /// maps of the run that read the message whole (its progress and tasks) never meet a part's. Returns the new ids.
    @discardableResult
    mutating func divide(into pieces: [Part]) -> [UUID] {
        guard parts.count == 1, pieces.count >= 2 else { return [] }
        parts = pieces.map { piece in
            var part = piece
            part.id = UUID()
            return part
        }
        return parts.map(\.id)
    }

    // MARK: Words

    /// What set it off, in a line.
    var triggerText: String {
        switch trigger {
        case .you(let text): fromAction.map { "\($0.category) · " + text } ?? text
        case .action(let category, let thing, _, _): "From \(category) · \(thing)"
        case .session(_, let event): event
        case .system: "Fjord"
        }
    }

    /// What was done, one phrase per item.
    var doneLines: [String] { lines(forModel: false) }

    /// `doneLines`, worded for a model (the user, not "you") when `forModel`.
    func lines(forModel: Bool) -> [String] {
        done.map { item in
            switch item {
            case .sent(let to, let text, _): "sent to \(to): \(Self.clip(text, 80))"
            case .started(_, let project, let model, let effort): "started a session in \(project)" + settingsWords(model, effort)
            case .preparedGuest(let project, let location, _): "ready in Claude · \(project) on \(location)"
            case .changed(let id): "changed Fjord (\(id.uuidString.prefix(8)))"
            case .answered(let card): "answered \(card)"
            case .asked(let options): "asked which: " + options.joined(separator: " / ")
            case .resolved(let card, let message): "closed \(card) by \(forModel ? "the user\'s" : "your") message: \(Self.clip(message, 80))"
            case .failed(let reason): "failed: \(reason)"
            case .cancelled(let how): how.words
            case .archived(let title, _): "archived “\(Self.clip(title, 60))”"
            case .stopped(let title, let project, let since):
                "stopped “\(Self.clip(title, 60))” (\(project)" + (since.map { ", since \(Self.clock($0))" } ?? "") + ")"
            case .interrupted(let title, let text, let stopped):
                (stopped ? "interrupted" : "sent to") + " “\(Self.clip(title, 60))”" + (stopped ? " and sent: " : ": ") + Self.clip(text, 80)
            }
        }
    }

    /// The short phrase after the trigger on the history line: what happened, or how it ended.
    var summary: String { summary(waiting: true) }

    /// `summary`; with `waiting` false a start whose first message waits doesn't say so (a line that says why itself).
    func summary(waiting: Bool) -> String {
        switch outcome {
        case .reverted: return "reverted"
        case .corrected(_, let to): return "corrected to \(to)"
        default: break
        }
        if isCancelled { return "cancelled" }
        if isDivided { return dividedSummary }
        guard let first = done.first else { return note.map { Self.clip($0, 80) } ?? (outcome == .pending ? "working" : "replied") }
        let more = done.count > 1 ? " +\(done.count - 1)" : ""
        switch first {
        case .sent(let to, _, _): return "sent to \(to)" + more
        case .started(_, let project, let model, let effort):
            return "started in \(project)" + settingsWords(model, effort) + more
                + (waiting && parts.count == 1 && parts[0].isWaitingToSend ? " · first message waiting" : "")
        case .preparedGuest(let project, _, _): return "ready in Claude · \(project)" + more
        case .changed: return "changed Fjord" + more
        case .answered: return "answered" + more
        case .asked: return "asked you" + more
        case .resolved: return "addressed a card" + more
        case .failed: return "failed" + more
        case .cancelled: return "cancelled" + more
        case .archived: return "archived" + more
        case .stopped: return "stopped" + more
        case .interrupted(_, _, let stopped): return (stopped ? "interrupted" : "sent") + more
        }
    }

    /// "split in 3: 2 sent, 1 held": how the parts of a divided message stand.
    private var dividedSummary: String {
        var tally: [(String, Int)] = []
        for part in places.map({ $0.parts[0] }) {
            let state: String
            if part.done.contains(where: { if case .failed = $0 { true } else { false } }) { state = "failed" }
            else if part.delivered?.cancelled?.stopped == true || part.endsCancelled { state = "cancelled" }
            else if part.outcome == .pending, part.waitsFor != nil, part.done.isEmpty { state = "held" }
            else if part.isWaitingToSend { state = "waiting" }
            else if part.outcome == .pending { state = "working" }
            else if part.done.contains(where: \.sendsWords) { state = "sent" }
            else { state = "done" }
            if let i = tally.firstIndex(where: { $0.0 == state }) { tally[i].1 += 1 } else { tally.append((state, 1)) }
        }
        return "split in \(parts.count): " + tally.map { "\($0.1) \($0.0)" }.joined(separator: ", ")
    }

    /// "09:41": when a stopped turn began.
    static func clock(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "HH:mm"
        return format.string(from: date)
    }

    var symbol: String {
        if isDivided { return "arrow.triangle.branch" }
        if outcome == .reverted { return "arrow.uturn.backward" }
        if isCancelled, outcome == .done || outcome == .pending { return "xmark.circle" }
        if case .action = trigger { return "bolt" }
        // An action's message, before anything is done with it.
        if fromAction != nil, done.isEmpty { return "bolt" }
        switch done.first {
        case .sent: return "paperplane"
        case .started: return "plus.square"
        case .preparedGuest: return "desktopcomputer"
        case .changed: return "slider.horizontal.3"
        case .answered: return "checkmark"
        case .asked: return "questionmark.bubble"
        case .resolved: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        case .archived: return "archivebox"
        case .stopped: return "stop.circle"
        case .interrupted: return "paperplane"
        case nil: return "text.bubble"
        }
    }

    /// " (opus, high)", or nothing.
    private func settingsWords(_ model: String?, _ effort: String?) -> String {
        let set = [model, effort].compactMap { $0 }
        guard !set.isEmpty else { return "" }
        return " (" + set.joined(separator: ", ") + ")"
    }

    static func clip(_ text: String, _ n: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > n ? String(line.prefix(n - 1)) + "…" : line
    }

    /// One line for a model's context: "2m ago · you: "…" → sent to X", with a correction named as yours.
    func contextLine(now: Date) -> String {
        let age = shortAgo(at, now: now)
        let when = age == "now" ? "just now" : age.first?.isNumber == true && age.last?.isLetter == true ? "\(age) ago" : age
        let who: String
        switch trigger {
        case .you(let text):
            who = fromAction.map { "action of the category “\(UntrustedText.clean($0.category, limit: 40))”, the user's prompt: “\(Self.clip(text, 100))”" }
                ?? "the user: “\(Self.clip(text, 100))”"
        case .action(let category, let thing, _, _): who = "action of the category “\(UntrustedText.clean(category, limit: 40))” · \(UntrustedText.clean(thing, limit: 80))"
        case .session(_, let event): who = "session: \(Self.clip(event, 100))"
        case .system: who = "Fjord"
        }
        if isDivided {
            let clauses = places.map { place -> String in
                let part = place.parts[0]
                var clause = (part.decision.target ?? part.place ?? "?") + ": “\(Self.clip(place.triggerText, 60))”"
                if let waits = part.waitsFor { clause += " (waited for \(waits))" }
                let did = place.lines(forModel: true)
                if !did.isEmpty { clause += " → " + did.joined(separator: "; ") }
                switch part.outcome {
                case .reverted: clause += " (the user reverted this)"
                case .corrected(let from, let to): clause += " (the user corrected this: not \(from), but \(to))"
                case .pending, .done: break
                }
                return clause
            }
            return "\(when) · \(who) → split into \(parts.count) places: " + clauses.joined(separator: " | ")
        }
        var parts = [who]
        if let target = decision.target { parts.append("target \(target)") }
        if let intent = decision.intent ?? decision.label { parts.append(intent) }
        let did = lines(forModel: true)
        if !did.isEmpty { parts.append(did.joined(separator: "; ")) }
        var line = "\(when) · " + parts.joined(separator: " → ")
        switch outcome {
        case .reverted: line += " (the user reverted this)"
        case .corrected(let from, let to): line += " (the user corrected this: not \(from), but \(to))"
        case .pending, .done: break
        }
        return line
    }
}

// MARK: - Coding

extension RouterDecision: Codable {
    private enum Key: String, CodingKey {
        case id, at, trigger, decision, done, outcome, links, reply, note, delivered, mentions, fromAction, actionStart
        case generated, parts
    }

    /// A one-part entry is today's flat keys, so its file is as it was and an older build reads it; a divided one has `parts`
    /// instead of the per-place keys.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encode(at, forKey: .at)
        try c.encode(trigger, forKey: .trigger)
        if parts.count == 1 {
            let part = parts[0]
            try c.encode(part.decision, forKey: .decision)
            try c.encode(part.done, forKey: .done)
            try c.encode(part.outcome, forKey: .outcome)
            try c.encode(part.links, forKey: .links)
            try c.encodeIfPresent(part.reply, forKey: .reply)
            try c.encodeIfPresent(part.note, forKey: .note)
            try c.encodeIfPresent(part.delivered, forKey: .delivered)
        } else {
            try c.encode(parts, forKey: .parts)
        }
        try c.encodeIfPresent(mentions, forKey: .mentions)
        try c.encodeIfPresent(fromAction, forKey: .fromAction)
        try c.encodeIfPresent(actionStart, forKey: .actionStart)
        try c.encodeIfPresent(generated, forKey: .generated)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(UUID.self, forKey: .id)
        at = try c.decode(Date.self, forKey: .at)
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        mentions = try c.decodeIfPresent([RouterMention].self, forKey: .mentions)
        fromAction = try c.decodeIfPresent(SessionOrigin.self, forKey: .fromAction)
        actionStart = try c.decodeIfPresent(ActionStart.self, forKey: .actionStart)
        generated = try c.decodeIfPresent(Bool.self, forKey: .generated)
        if let decoded = try c.decodeIfPresent([Part].self, forKey: .parts), !decoded.isEmpty {
            parts = decoded
            if parts.count == 1 { parts[0].id = id }
        } else {
            parts = [Part(id: id, decision: try c.decode(Decided.self, forKey: .decision), done: try c.decode([Done].self, forKey: .done),
                          outcome: try c.decode(Outcome.self, forKey: .outcome), links: try c.decode(Links.self, forKey: .links))]
            parts[0].reply = try c.decodeIfPresent(String.self, forKey: .reply)
            parts[0].note = try c.decodeIfPresent(String.self, forKey: .note)
            parts[0].delivered = try c.decodeIfPresent(Delivered.self, forKey: .delivered)
        }
    }
}

// MARK: - Store

extension RouterState {
    /// Adds an entry, newest last; the oldest go past the cap, but never one linking a change still waiting for your Apply
    /// or Discard (its only place on the page), nor an action's message still under way (its run follows it), nor one whose ask-back card is still up (`inUse`, by the entry's id or a part's).
    mutating func log(_ decision: RouterDecision, inUse: Set<UUID> = []) {
        decisions.append(decision)
        guard decisions.count > RouterDecision.maxKept else { return }
        let waiting = Set(changes.filter(\.isPending).map(\.id))
        var over = decisions.count - RouterDecision.maxKept
        decisions = decisions.filter { entry in
            guard over > 0, !entry.links.changes.contains(where: waiting.contains),
                  entry.fromAction == nil || entry.outcome != .pending, !entry.ids.contains(where: inUse.contains) else { return true }
            over -= 1
            return false
        }
    }
}

extension RouterState {
    /// Runs and asks still under way when the app quit (quitting can't wait for them to settle) can't go on in this launch:
    /// they say they were interrupted, rather than "working…" for ever.
    mutating func settleInterrupted() {
        for i in decisions.indices {
            for j in decisions[i].parts.indices where decisions[i].parts[j].outcome == .pending {
                var part = decisions[i].parts[j]
                // A start whose first message was held for the session to run: the session is there, the message never went.
                let held = part.done.contains { if case .started = $0 { true } else { false } }
                let guestPrepared = part.done.contains { if case .preparedGuest = $0 { true } else { false } }
                if !guestPrepared {
                    // Held, as against a part sent now (it has its delivery or other lines by then, whatever it waited for).
                    if let waits = part.waitsFor, part.done.isEmpty {
                        part.add(.failed("wasn't sent: Fjord quit while it waited for \(placeWords(waits))"))
                    } else {
                        part.add(.failed(held ? "its first message wasn't sent: Fjord quit while it waited for the session to run" : "interrupted"))
                    }
                }
                part.outcome = .done
                decisions[i].parts[j] = part
            }
        }
    }

    /// A target in a few words, as far as the state tells (its card's title for a session; the folder of a project).
    private func placeWords(_ target: String) -> String {
        if target.hasPrefix("session:"), let title = cards.last(where: { $0.sessionID == String(target.dropFirst(8)) })?.title {
            return "“\(RouterDecision.clip(title, 60))”"
        }
        for prefix in ["project:", "new:"] where target.hasPrefix(prefix) {
            return URL(fileURLWithPath: String(target.dropFirst(prefix.count))).lastPathComponent
        }
        return target
    }

    /// An entry, or a part of a divided one as an entry of its own (`RouterDecision.projection`).
    func record(_ id: UUID) -> RouterDecision? {
        for entry in decisions {
            if entry.id == id { return entry }
            if let part = entry.parts.first(where: { $0.id == id }), entry.parts.count > 1 { return entry.projection(part) }
        }
        return nil
    }

    /// The entry a part belongs to; nil for an entry's own id and for anything else.
    func parent(of id: UUID) -> UUID? {
        decisions.first { $0.parts.count > 1 && $0.parts.contains { $0.id == id } }?.id
    }

    /// A change waiting for your Apply or Discard, or one an older file kept in its chat, is reached only through an
    /// entry linking it: one whose entry was lost (unreadable) or never made gets an entry of Fjord's own, at its date.
    mutating func linkUnlinkedChanges(legacy: Set<UUID>) {
        let linked = Set(decisions.flatMap(\.links.changes))
        for change in changes where !linked.contains(change.id) && (change.isPending || legacy.contains(change.id)) {
            var entry = RouterDecision(at: change.date, trigger: .system, outcome: change.isReverted ? .reverted : .done)
            entry.add(.changed(change.id))
            decisions.insert(entry, at: decisions.firstIndex { $0.at > change.date } ?? decisions.endIndex)
        }
    }
}

extension Store {
    /// Records a decision and returns its id.
    @discardableResult
    func logDecision(_ decision: RouterDecision) -> UUID {
        var state = router
        state.log(decision, inUse: decisionsInUse())
        router = state
        return decision.id
    }

    /// Changes an entry in place (nothing if it has been pruned). The id of a part of a divided message changes that part
    /// only: `change` is made to the part as an entry of its own and written back.
    func updateDecision(_ id: UUID, _ change: (inout RouterDecision) -> Void) {
        if let i = router.decisions.firstIndex(where: { $0.id == id }) {
            var decision = router.decisions[i]
            change(&decision)
            if decision != router.decisions[i] { router.decisions[i] = decision }
            return
        }
        guard let i = router.decisions.firstIndex(where: { $0.parts.count > 1 && $0.parts.contains { $0.id == id } }),
              let j = router.decisions[i].parts.firstIndex(where: { $0.id == id }) else { return }
        let entry = router.decisions[i]
        let before = entry.projection(entry.parts[j])
        var after = before
        change(&after)
        guard after != before else { return }
        var part = after.parts[0]
        if after.mentions != before.mentions { part.mentions = after.mentions }
        if after.trigger != before.trigger, case .you(let text) = after.trigger { part.text = text }
        router.decisions[i].parts[j] = part
    }

    /// The last `count` decisions, oldest first, one line each: context for a model (or Jev).
    /// `excluding`: the entry of the run asking (it is the newest, and not yet history).
    func recentDecisions(_ count: Int = 10, now: Date = Date(), excluding: UUID? = nil) -> String {
        router.decisions.filter { entry in excluding.map { !entry.ids.contains($0) } ?? true }.suffix(count).map { $0.contextLine(now: now) }.joined(separator: "\n")
    }

    /// A change made in Fjord: part of the run under way, else an entry of its own.
    func logChange(_ change: FjordChange, into run: UUID? = nil, as done: RouterDecision.Done? = nil) {
        if let id = run, router.record(id) != nil {
            updateDecision(id) { $0.add(done ?? .changed(change.id)) }
        } else {
            logDecision(RouterDecision(at: change.date, trigger: .system, decision: RouterDecision.Decided(intent: change.title),
                                       done: [.changed(change.id)], outcome: .done, links: .init(changes: [change.id])))
        }
    }

    /// A change that no longer exists (it cancelled out with a later one of its run): its entry forgets it, and goes
    /// when it was only that.
    func dropChange(_ change: UUID) {
        guard let i = router.decisions.firstIndex(where: { $0.links.changes.contains(change) }) else { return }
        var entry = router.decisions[i]
        for j in entry.parts.indices where entry.parts[j].links.changes.contains(change) {
            entry.parts[j].done.removeAll { $0 == .changed(change) }
            entry.parts[j].links.changes.removeAll { $0 == change }
        }
        if entry.done.isEmpty, entry.links.changes.isEmpty, entry.trigger == .system { router.decisions.remove(at: i) } else { router.decisions[i] = entry }
    }

    /// A change's record was merged with a later one: an entry made only for it says the new title.
    func retitleChange(_ change: UUID, from old: String, to new: String) {
        guard let i = router.decisions.firstIndex(where: { $0.links.changes == [change] && $0.trigger == .system }),
              router.decisions[i].decision.intent == old else { return }
        router.decisions[i].decision.intent = new
    }

    /// After a revert: an entry (or, in a divided message, the part) whose changes are all taken back is reverted.
    func noteReverted(_ change: UUID) {
        guard let i = router.decisions.firstIndex(where: { $0.links.changes.contains(change) }),
              let part = router.decisions[i].parts.first(where: { $0.links.changes.contains(change) }) else { return }
        let all = part.links.changes.allSatisfy { id in
            router.changes.contains { $0.id == id && $0.isReverted }
        }
        if all {
            updateDecision(part.id) { $0.outcome = .reverted }
            routerRunReverted(part.id)
        }
    }

    /// Something you did on a card from the page (answered its form, approved its plan, marked it handled).
    func logCardAction(_ text: String, card: String, done: RouterDecision.Done? = nil, now: Date = Date()) {
        let session = router.cards.first { $0.id == card }?.sessionID
        var entry = RouterDecision(at: now, trigger: .you(text), decision: .init(target: router.cards.first { $0.id == card }?.title,
                                                                                  intent: "answer"), outcome: .done)
        entry.add(done ?? .answered(card: router.cards.first { $0.id == card }?.title ?? card), session: session, card: card)
        logDecision(entry)
    }
}
