import Foundation

// The Router's decision log (docs/design/spec/router.md): one entry per run: what set it off, what was decided, what was
// done, and how it ended. It is the Router's history on the page, and its last entries are context for later runs.

struct RouterDecision: Identifiable, Equatable {
    enum Trigger: Codable, Equatable {
        /// Your message, or something you did on the brief (what it was, in words).
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
        /// an ask, or a place you tagged. An example for the next routings, as corrections are.
        var confirmed: Bool?
        /// The target itself (`session:<id>`, `answer:<project>/<thread>`, `new:<folder>`, an intent), and on a correction the one Jev
        /// suggested: what examples name it by, as titles can be shared or change. Nil in entries from before.
        var targetID: String?
        var fromID: String?
        /// Who decided where it goes (`RouterProjectDecision.Decider`: jev, sonnet), for measuring the decider against your
        /// corrections; nil when no model did (a tag, a reply).
        var decider: String?
        init(target: String? = nil, intent: String? = nil, label: String? = nil, confidence: Double? = nil) {
            self.target = target
            self.intent = intent
            self.label = label
            self.confidence = confidence
        }
    }

    enum Done: Codable, Equatable {
        /// Your words went somewhere: what `lastTold` reads.
        var sendsWords: Bool {
            if case .sent = self { true } else { false }
        }

        /// A message sent to a claude.ai place or a thread's session, with what you wrote when it was rephrased.
        case sent(to: String, text: String, original: String?)
        case changed(UUID)
        /// A thread answered (its title).
        case answered(thread: String)
        /// The Router asked you which of these.
        case asked([String])
        case failed(String)
        /// A message taken back while it waited, or its run stopped (`Store.cancelQueued`, `Store.stopRun`).
        case cancelled(Cancelled)
        /// A queued message's words changed in place (`Store.editQueued`).
        case edited(String)
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
        /// The threads it touched (`BriefTarget.key`).
        var threads: [String] = []
        var changes: [UUID] = []
        init(sessions: [String] = [], threads: [String] = [], changes: [UUID] = []) {
            self.sessions = sessions
            self.threads = threads
            self.changes = changes
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try c.decodeIfPresent([String].self, forKey: .sessions) ?? []
            threads = try c.decodeIfPresent([String].self, forKey: .threads) ?? []
            changes = try c.decodeIfPresent([UUID].self, forKey: .changes) ?? []
        }
    }

    var id = UUID()
    var at: Date
    var trigger: Trigger
    var decision = Decided()
    var done: [Done] = []
    var outcome: Outcome = .pending
    var links = Links()
    var reply: String?
    var note: String?
    /// The last message it sent to a thread, for changing your mind (`Store.changeOfMind`).
    var delivered: Delivered?

    /// The pills of your message (`.you`), drawn where their "@name" is; nil for anything else and in entries from before.
    var mentions: [RouterMention]?
    /// A message a category's "Then" sent for a thing (your prompt, `.you`): the category, the thing, the action and its run.
    /// Nil for anything else.
    var fromAction: SessionOrigin?

    /// Where an action's message came from (`RouterContext.action`): what sending it elsewhere goes with again.
    var actionSource: RouterActionSource? { fromAction.map { RouterActionSource(origin: $0) } }
    /// Its message was stopped where it was sent (a Cancel that wasn't too late).
    var isCancelled: Bool { delivered?.stopped == true }

    init(id: UUID = UUID(), at: Date = Date(), trigger: Trigger, decision: Decided = Decided(), done: [Done] = [],
         outcome: Outcome = .pending, links: Links = Links()) {
        self.id = id
        self.at = at
        self.trigger = trigger
        self.decision = decision
        self.done = done
        self.outcome = outcome
        self.links = links
    }

    static let maxKept = 1000

    /// Adds `done` and the links it implies.
    mutating func add(_ item: Done, session: String? = nil, thread: BriefTarget? = nil) {
        done.append(item)
        if case .changed(let id) = item, !links.changes.contains(id) { links.changes.append(id) }
        if let session, !links.sessions.contains(session) { links.sessions.append(session) }
        if let key = thread?.key, !links.threads.contains(key) { links.threads.append(key) }
    }

    /// Its last send was stopped by a cancel: one that sent its words again since (to another place) isn't cancelled.
    var endsCancelled: Bool {
        guard let cancelled = done.lastIndex(where: { if case .cancelled = $0 { true } else { false } }) else { return false }
        return done.lastIndex(where: \.sendsWords).map { $0 < cancelled } ?? true
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
            case .changed(let id): "changed Fjord (\(id.uuidString.prefix(8)))"
            case .answered(let thread): "answered \(thread)"
            case .asked(let options): "asked which: " + options.joined(separator: " / ")
            case .failed(let reason): "failed: \(reason)"
            case .cancelled(let how): how.words
            case .edited(let words): "edited while it waited: " + Self.clip(words, 80)
            }
        }
    }

    /// The short phrase after the trigger on the history line: what happened, or how it ended.
    var summary: String {
        switch outcome {
        case .reverted: return "reverted"
        case .corrected(_, let to): return "corrected to \(to)"
        default: break
        }
        if isCancelled { return "cancelled" }
        guard let first = done.first else { return note.map { Self.clip($0, 80) } ?? (outcome == .pending ? "working" : "replied") }
        let more = done.count > 1 ? " +\(done.count - 1)" : ""
        switch first {
        case .sent(let to, _, _): return "sent to \(to)" + more
        case .changed: return "changed Fjord" + more
        case .answered: return "answered" + more
        case .asked: return "asked you" + more
        case .failed: return "failed" + more
        case .cancelled: return "cancelled" + more
        case .edited: return "edited" + more
        }
    }

    var symbol: String {
        if outcome == .reverted { return "arrow.uturn.backward" }
        if isCancelled, outcome == .done || outcome == .pending { return "xmark.circle" }
        if case .action = trigger { return "bolt" }
        // An action's message, before anything is done with it.
        if fromAction != nil, done.isEmpty { return "bolt" }
        switch done.first {
        case .sent: return "paperplane"
        case .changed: return "slider.horizontal.3"
        case .answered: return "checkmark"
        case .asked: return "questionmark.bubble"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        case .edited: return "pencil"
        case nil: return "text.bubble"
        }
    }

    /// " (opus, high)", or nothing.
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
        case id, at, trigger, decision, done, outcome, links, reply, note, delivered, mentions, fromAction, parts
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encode(at, forKey: .at)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(decision, forKey: .decision)
        try c.encode(done, forKey: .done)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(links, forKey: .links)
        try c.encodeIfPresent(reply, forKey: .reply)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(delivered, forKey: .delivered)
        try c.encodeIfPresent(mentions, forKey: .mentions)
        try c.encodeIfPresent(fromAction, forKey: .fromAction)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(UUID.self, forKey: .id)
        at = try c.decode(Date.self, forKey: .at)
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        // A pill of a kind no longer made (a session's) leaves the entry without its pills, not without the entry.
        mentions = (try? c.decodeIfPresent([RouterMention].self, forKey: .mentions)) ?? nil
        fromAction = try c.decodeIfPresent(SessionOrigin.self, forKey: .fromAction)
        // Entries from before the Router sent to projects only: a message divided between places kept its words per part
        // (`parts`), and the entry itself had no decision, done, outcome or links. The first part's decision and outcome stand for
        // it, the others' sends and links join, so no saved message is lost on upgrade.
        let parts = (try? c.decodeIfPresent([LegacyPart].self, forKey: .parts)) ?? nil
        let first = parts?.first
        var legacyNotes: [String] = []
        func items(_ lossy: [LegacyDone]) -> [Done] {
            lossy.compactMap { item in
                if let done = item.done { return done }
                if let started = item.started { return .sent(to: started.project ?? "a new session", text: "", original: nil) }
                if let name = item.removed { legacyNotes.append("before: \(name)") }
                return nil
            }
        }
        decision = try c.decodeIfPresent(Decided.self, forKey: .decision) ?? first?.decision ?? Decided()
        if let own = try c.decodeIfPresent([LegacyDone].self, forKey: .done) {
            done = items(own)
        } else {
            done = items(parts?.flatMap(\.done) ?? [])
        }
        outcome = try c.decodeIfPresent(Outcome.self, forKey: .outcome) ?? first?.outcome ?? .done
        var merged = try c.decodeIfPresent(Links.self, forKey: .links) ?? Links()
        for part in parts ?? [] {
            merged.sessions += part.links.sessions.filter { !merged.sessions.contains($0) }
            merged.threads += part.links.threads.filter { !merged.threads.contains($0) }
            merged.changes += part.links.changes.filter { !merged.changes.contains($0) }
        }
        links = merged
        // What each part answered or noted stays, labelled by its place when there are several.
        func joined(_ own: String?, _ per: [(place: String, text: String?)]) -> String? {
            let kept = per.compactMap { item in item.text.flatMap { $0.isEmpty ? nil : $0 }.map { (item.place, $0) } }
            let lines = kept.map { per.count > 1 ? "\($0.0): \($0.1)" : $0.1 }
            let all = (own.flatMap { $0.isEmpty ? nil : $0 }.map { [$0] } ?? []) + lines
            return all.isEmpty ? nil : all.joined(separator: "\n")
        }
        reply = joined(try c.decodeIfPresent(String.self, forKey: .reply), (parts ?? []).map { ($0.place, $0.reply) })
        note = joined(try c.decodeIfPresent(String.self, forKey: .note), (parts ?? []).map { ($0.place, $0.note) })
        // An entry from before T3 kept another shape (a Claude session's nonce): it reads without a delivery.
        delivered = (try? c.decodeIfPresent(Delivered.self, forKey: .delivered)) ?? parts?.lazy.compactMap(\.delivered).first
        var old = legacyNotes
        if let parts, parts.count > 1 { old.append("divided between: " + parts.map(\.place).joined(separator: ", ")) }
        if !old.isEmpty { note = ([note].compactMap { $0 } + [old.joined(separator: "; ")]).joined(separator: " · ") }
    }

    /// One place of a divided message, as an older file kept it.
    private struct LegacyPart: Decodable {
        var place = ""
        var decision: Decided?
        var done: [LegacyDone] = []
        var outcome: Outcome?
        var links = Links()
        var delivered: Delivered?
        var reply: String?
        var note: String?
        private enum Key: String, CodingKey { case place, decision, done, outcome, links, delivered, reply, note }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            place = (try? c.decodeIfPresent(String.self, forKey: .place)) ?? ""
            decision = try? c.decodeIfPresent(Decided.self, forKey: .decision)
            done = (try? c.decodeIfPresent([LegacyDone].self, forKey: .done)) ?? []
            outcome = try? c.decodeIfPresent(Outcome.self, forKey: .outcome)
            links = (try? c.decodeIfPresent(Links.self, forKey: .links)) ?? Links()
            delivered = try? c.decodeIfPresent(Delivered.self, forKey: .delivered)
            reply = (try? c.decodeIfPresent(String.self, forKey: .reply)) ?? nil
            note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
        }
    }

    /// A done item of today, a session started (now a send to its project), or one of a kind no longer made (named, for the note).
    private struct LegacyDone: Decodable {
        var done: Done?
        var started: (project: String?, session: String?)?
        var removed: String?
        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        init(from decoder: Decoder) throws {
            if let ok = try? Done(from: decoder) { done = ok; return }
            let c = try decoder.container(keyedBy: AnyKey.self)
            let name = c.allKeys.first?.stringValue ?? "unknown"
            // A card answered, from before the briefs: its title is the thread's.
            if name == "answered", let inner = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(stringValue: name)!),
               let title = try? inner.decode(String.self, forKey: AnyKey(stringValue: "card")!) {
                done = .answered(thread: title)
            } else if name == "started", let inner = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(stringValue: name)!) {
                started = (try? inner.decodeIfPresent(String.self, forKey: AnyKey(stringValue: "project")!),
                           try? inner.decodeIfPresent(String.self, forKey: AnyKey(stringValue: "session")!))
            } else {
                removed = name
            }
        }
    }
}

// MARK: - Store

extension RouterSaved {
    /// Adds an entry, newest last; the oldest go past the cap, but never one linking a change still waiting for your Apply
    /// or Discard (its only place on the page), nor an action's message still under way (its run follows it), nor one whose ask-back card is still up (`inUse`, by the entry's id or a part's).
    mutating func log(_ decision: RouterDecision, inUse: Set<UUID> = []) {
        decisions.append(decision)
        guard decisions.count > RouterDecision.maxKept else { return }
        let waiting = Set(changes.filter(\.isPending).map(\.id))
        var over = decisions.count - RouterDecision.maxKept
        decisions = decisions.filter { entry in
            guard over > 0, !entry.links.changes.contains(where: waiting.contains),
                  entry.fromAction == nil || entry.outcome != .pending, !inUse.contains(entry.id) else { return true }
            over -= 1
            return false
        }
    }
}

extension RouterSaved {
    /// Runs and asks still under way when the app quit (quitting can't wait for them to settle) can't go on in this launch:
    /// they say they were interrupted, rather than "working…" for ever.
    mutating func settleInterrupted() {
        for i in decisions.indices {
            guard decisions[i].outcome == .pending else { continue }
            decisions[i].add(.failed("interrupted"))
            decisions[i].outcome = .done
        }
    }

    func record(_ id: UUID) -> RouterDecision? { decisions.first { $0.id == id } }

    /// A change waiting for your Apply or Discard is reached only through an entry linking it: one whose entry was lost
    /// (unreadable) or never made gets an entry of Fjord's own, at its date.
    mutating func linkUnlinkedChanges() {
        let linked = Set(decisions.flatMap(\.links.changes))
        for change in changes where !linked.contains(change.id) && change.isPending {
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

    /// Changes an entry in place (nothing if it has been pruned).
    func updateDecision(_ id: UUID, _ change: (inout RouterDecision) -> Void) {
        guard let i = router.decisions.firstIndex(where: { $0.id == id }) else { return }
        var decision = router.decisions[i]
        change(&decision)
        if decision != router.decisions[i] { router.decisions[i] = decision }
    }

    /// The last `count` decisions, oldest first, one line each: context for a model (or Jev).
    /// `excluding`: the entry of the run asking (it is the newest, and not yet history).
    func recentDecisions(_ count: Int = 10, now: Date = Date(), excluding: UUID? = nil) -> String {
        router.decisions.filter { entry in excluding.map { entry.id != $0 } ?? true }.suffix(count).map { $0.contextLine(now: now) }.joined(separator: "\n")
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
        entry.done.removeAll { $0 == .changed(change) }
        entry.links.changes.removeAll { $0 == change }
        if entry.done.isEmpty, entry.links.changes.isEmpty, entry.trigger == .system { router.decisions.remove(at: i) } else { router.decisions[i] = entry }
    }

    /// A change's record was merged with a later one: an entry made only for it says the new title.
    func retitleChange(_ change: UUID, from old: String, to new: String) {
        guard let i = router.decisions.firstIndex(where: { $0.links.changes == [change] && $0.trigger == .system }),
              router.decisions[i].decision.intent == old else { return }
        router.decisions[i].decision.intent = new
    }

    /// After a revert: an entry whose changes are all taken back is reverted.
    func noteReverted(_ change: UUID) {
        guard let part = router.decisions.first(where: { $0.links.changes.contains(change) }) else { return }
        let all = part.links.changes.allSatisfy { id in
            router.changes.contains { $0.id == id && $0.isReverted }
        }
        if all {
            updateDecision(part.id) { $0.outcome = .reverted }
            routerRunReverted(part.id)
        }
    }

    /// Something you did on a brief entry (answered its form, approved its plan).
    func logEntryAction(_ text: String, target: BriefTarget, now: Date = Date()) {
        let title = routerBriefs.title(target)
        var entry = RouterDecision(at: now, trigger: .you(text), decision: .init(target: title, intent: "answer"), outcome: .done)
        entry.add(.answered(thread: title), thread: target)
        logDecision(entry)
    }
}
