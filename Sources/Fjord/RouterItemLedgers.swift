import Foundation

// The open items engine (docs/design/router-v2/OPEN-ITEMS.md, DESIGN.md 1.15 R7): each thread keeps a ledger of what is
// open with you, changed by one read per input: every turn the agent ends (never cancelled when a run starts again: a
// background task finishing wakes it at once) and every message you write to it. A read sees the open items and the new
// input and says, per item, keep or close (with how), and what is new or restated (merged into an open item: no
// duplicate, its age resets). Inputs of one thread are read one at a time, in order, each once, keyed by its id (a turn by
// its run, a message by its time); history is never read again. The ledger is kept per thread in the verdict file and
// cleared when the thread is settled. A turn's read also writes its line (what it did, where it stands): Done's sentence.

/// What a thread's projection says that its reads need: the last runs' replies and what started them, your last
/// messages and the reply each answers. Read once per turn or message (`T3Store.readSnapshot`), not kept in the detail.
struct RouterItemFacts: Equatable, Sendable {
    struct Turn: Equatable, Sendable {
        var reply: String
        var yourWords: String?
        var woke: String?
        /// T3's id for the message of yours that started it.
        var started: String? = nil
        var status: String
        /// Still running: its reply isn't whole yet.
        var live: Bool
        /// Ended, but its last reply is still streaming in the projection: not whole yet either (`reply` has it so far).
        var streaming = false
    }

    struct Message: Equatable, Sendable {
        /// T3's id for the message: the input's key.
        var id: String = ""
        var at: Date
        var text: String
        var before: String?
    }

    var turns: [String: Turn] = [:]
    var messages: [Message] = []
    /// Every run T3 lists (not queued), oldest first: a turn older than the ones kept is known, not missing.
    var order: [String] = []

    /// How many of the latest runs and messages are read.
    static let kept = 8

    /// Made off the main thread (a long thread's projection has thousands of items): one walk back from the end over the
    /// messages, and over the turn items only for a run with no reply among them.
    static func make(_ p: T3Projection) -> RouterItemFacts {
        var f = RouterItemFacts()
        let runs = p.runs.filter { !$0.isQueued }.sorted { $0.ordinal < $1.ordinal }
        f.order = runs.map(\.id)
        let latest = runs.suffix(kept)
        let wanted = Set(latest.map(\.id))
        let starters = Set(latest.compactMap(\.userMessageId))
        var whole: [String: String] = [:]
        var last: [String: T3Message] = [:]
        var starter: [String: T3Message] = [:]
        // Your messages, newest first, each waiting for the reply before it.
        var mine: [Message] = []
        var waiting: [Int] = []
        let ordered = p.messages.indices.dropFirst().allSatisfy { i in
            (p.messages[i - 1].createdAt?.date ?? .distantPast) <= (p.messages[i].createdAt?.date ?? .distantPast)
        } ? p.messages : p.messages.sorted { ($0.createdAt?.date ?? .distantPast) < ($1.createdAt?.date ?? .distantPast) }
        for m in ordered.reversed() {
            if starters.contains(m.id), starter[m.id] == nil { starter[m.id] = m }
            if m.role == "assistant", !m.text.isEmpty {
                if let r = m.runId, wanted.contains(r) {
                    if last[r] == nil { last[r] = m }
                    if whole[r] == nil, !m.streaming { whole[r] = m.text }
                }
                for i in waiting { mine[i].before = m.text }
                waiting = []
            }
            if m.role == "user", m.createdBy == "user", !m.text.isEmpty, mine.count < kept, let at = m.createdAt?.date {
                mine.append(Message(id: m.id, at: at, text: m.text, before: nil))
                waiting.append(mine.count - 1)
            }
            if mine.count >= kept, waiting.isEmpty, whole.count == wanted.count, starter.count == starters.count { break }
        }
        f.messages = mine.reversed()
        // A run with no whole reply among the messages: its last finished reply in the turn items.
        var missing = wanted.subtracting(whole.keys)
        if !missing.isEmpty {
            for item in p.turnItems.reversed() {
                guard let r = item.runId, missing.contains(r), case .assistantMessage(_, let t, let streaming) = item.detail,
                      !t.isEmpty, !streaming else { continue }
                whole[r] = t
                missing.remove(r)
                if missing.isEmpty { break }
            }
        }
        for run in latest {
            // The run's last reply still streaming: the projection is behind the run's end.
            let streaming = last[run.id]?.streaming == true
            let reply = streaming ? last[run.id]?.text : whole[run.id]
            let own = run.userMessageId.flatMap { starter[$0] }
            f.turns[run.id] = Turn(reply: reply ?? "", yourWords: own?.createdBy == "user" ? own?.text : nil,
                                   woke: own.flatMap { $0.createdBy == "user" ? nil : $0.text },
                                   started: own?.createdBy == "user" ? own?.id : nil, status: run.status.rawValue,
                                   live: run.status.isLive, streaming: streaming && !run.status.isLive)
        }
        return f
    }

    /// Your messages T3 stamped after `after` and up to `upTo` (its `latestUserAuthoredMessageAt`), oldest first.
    func messages(after: Date?, upTo: Date) -> [Message] {
        messages.filter { $0.at > (after ?? .distantPast) && $0.at <= upTo.addingTimeInterval(2) }
    }
}

@MainActor final class RouterItemLedgers {
    /// What the verdict file keeps per thread.
    struct Saved: Codable, Equatable {
        var items: [RouterItem] = []
        /// The next item's number.
        var next = 1
        /// The inputs read (`turn:<run>`, `msg:<ms>`), the latest few.
        var read: [String] = []
        /// The latest turn's line, and its run.
        var line: String?
        var lineRun: String?
        /// The latest run seen: a new one means the one before it ended (a wake reads it too).
        var run: String?
        /// Your latest message seen (T3's `latestUserAuthoredMessageAt`).
        var message: Date?
        /// The inputs seen and not read yet, in order: kept here in the same write that marks their trigger seen, so a
        /// relaunch, a crash or the thread leaving the page never loses one. The head is the one being read; it leaves
        /// only when its read is applied.
        var pending: [Input] = []
        /// Your latest words sent from here: T3's copy of one of them is the same message, not read again.
        var sent: [Sent] = []
        /// What was open when the thread was settled, kept for the Settle's Revert until a new run starts.
        var settled: Stash?
        /// Items you marked Done, newest last: their Revert puts them back where they were, and a read under way that
        /// restates or closes one doesn't bring it back.
        var done: [Done] = []

        init(items: [RouterItem] = [], next: Int = 1, read: [String] = [], line: String? = nil, lineRun: String? = nil,
             run: String? = nil, message: Date? = nil, pending: [Input] = []) {
            self.items = items
            self.next = next
            self.read = read
            self.line = line
            self.lineRun = lineRun
            self.run = run
            self.message = message
            self.pending = pending
        }

        private enum CodingKeys: String, CodingKey { case items, next, read, line, lineRun, run, message, pending, sent, settled, done }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            items = try c.decodeIfPresent([RouterItem].self, forKey: .items) ?? []
            next = try c.decodeIfPresent(Int.self, forKey: .next) ?? 1
            read = try c.decodeIfPresent([String].self, forKey: .read) ?? []
            line = try c.decodeIfPresent(String.self, forKey: .line)
            lineRun = try c.decodeIfPresent(String.self, forKey: .lineRun)
            run = try c.decodeIfPresent(String.self, forKey: .run)
            message = try c.decodeIfPresent(Date.self, forKey: .message)
            pending = try c.decodeIfPresent([Input].self, forKey: .pending) ?? []
            sent = try c.decodeIfPresent([Sent].self, forKey: .sent) ?? []
            settled = try c.decodeIfPresent(Stash.self, forKey: .settled)
            done = try c.decodeIfPresent([Done].self, forKey: .done) ?? []
        }
    }

    /// An item you marked Done, and where it was.
    struct Done: Codable, Equatable {
        var item: RouterItem
        var index: Int
    }

    static let doneKept = 20

    /// A settled thread's ledger, as it was.
    struct Stash: Codable, Equatable {
        var items: [RouterItem]
        var line: String?
        var lineRun: String?
        var pending: [Input]
        /// The latest run when it was settled: a newer one means the settle stood.
        var run: String?
    }

    /// Words you sent from here, until T3's copy of them is seen.
    struct Sent: Codable, Equatable {
        var at: Date
        var words: String

        /// T3's message is this one: the same words, stamped from a little before to a minute after.
        func matches(_ m: RouterItemFacts.Message) -> Bool {
            m.at >= at.addingTimeInterval(-5) && m.at <= at.addingTimeInterval(60)
                && RouterVerdictReading.flat(m.text) == RouterVerdictReading.flat(words)
        }
    }

    /// One input, read once.
    enum Input: Equatable, Codable {
        case turn(run: String)
        /// T3 says you wrote to the thread after `after`, up to `upTo`: the projection lists each message, and each is an
        /// input of its own (`message`).
        case messages(after: Date?, upTo: Date)
        /// One message of yours, by T3's id, with its words and the reply it answers.
        case message(id: String, at: Date, words: String, before: String?)
        /// Your words sent from here: they show in the block at once.
        case sent(at: Date, words: String)
        /// A whole message the agent posted while its run `run` goes on, by T3's id: a question asked mid-run (while it
        /// waits on a subagent, say) is read when it is asked. Coalesced: a newer one replaces one still waiting.
        case said(id: String, run: String, words: String)

        var key: String {
            switch self {
            case .turn(let run): "turn:" + run
            case .messages(_, let upTo): "msgs:" + Self.ms(upTo)
            case .message(let id, _, _, _): "msg:" + id
            case .sent(let at, _): "sent:" + Self.ms(at)
            case .said(let id, _, _): "said:" + id
            }
        }

        private static func ms(_ d: Date) -> String { String(Int64(d.timeIntervalSince1970 * 1000)) }

        var isTurn: Bool { if case .turn = self { true } else { false } }
        var isSaid: Bool { if case .said = self { true } else { false } }
        /// Your words: they can close what is open, and add nothing.
        var isYours: Bool { !isTurn && !isSaid }

        /// Your words, when the input is a message whose words are known.
        var words: String? {
            switch self {
            case .message(_, _, let words, _), .sent(_, let words): words
            case .turn, .messages, .said: nil
            }
        }
    }

    /// What a thread's read needs from the records: its title, project, first ask and PRs, as a read's base.
    struct Context {
        var title: String
        var project: String?
        var firstAsk: String?
        var pullRequests: [RouterVerdictInput.PullRequest] = []
        /// The agent's last reply, as the records hold it: what your words sent here answer.
        var lastReply: String?
        /// Your last words to the thread: what a mid-run message is read with.
        var yourWords: String?
    }

    /// The agent's latest whole message in a run that goes on, by T3's id.
    struct Said: Equatable {
        var id: String
        var words: String
    }

    static let readKept = 40
    static let sentKept = 8

    // MARK: Wiring

    var load: (String) -> Saved? = { _ in nil }
    var store: (String, Saved?) -> Void = { _, _ in }
    var ask: (RouterVerdictRequest) -> Void = { _ in }
    var cancel: (String) -> Void = { _ in }
    /// Reads the thread's projection once for an input (`key`), answering with `facts(_:key:_:)`.
    var fetch: ((_ thread: String, _ key: String) -> Void)?
    /// The thread's record should be composed again.
    var changed: (String) -> Void = { _ in }
    /// A turn's line as it streams, with its run.
    var words: (_ thread: String, _ run: String, _ text: String, _ done: Bool) -> Void = { _, _, _, _ in }
    /// Items a read added that need you (banners).
    var added: (_ thread: String, _ items: [RouterItem], _ key: String) -> Void = { _, _, _ in }
    var now: () -> Date = Date.init
    /// The wait before a failed read is made again (`n`: failures in a row): offline, a usage limit, Claude Code missing or
    /// being updated. The input stays pending meanwhile; T3 saying something new of the thread tries it at once.
    var retryAfter: (Int) -> TimeInterval = { n in min(30 * pow(2, Double(max(n, 1) - 1)), RouterVerdicts.maxBackoff) }
    /// How long a closed item strikes, and a new one is lit, before the ledger settles (0 in tests: `settle` by hand).
    var strike: TimeInterval = Router.Items.strike
    /// At most one mid-run message read per thread this often, as summaries (`RouterRecords.summaryGap`): one that comes
    /// sooner waits for the gap's end, and a newer one replaces it meanwhile. Anything queued behind it doesn't wait.
    var saidGap: TimeInterval = 60

    // MARK: State

    private final class Live {
        /// The pending head whose read is under way.
        var reading: Input?
        var facts: RouterItemFacts?
        /// The input the facts were read for: your messages are listed only from facts read after T3 stamped them.
        var factsFor: String?
        var fetching: String?
        var factsFailed: String?
        /// Projection reads that missed, per input: bounded, then the input is read with what is known.
        var misses: [String: Int] = [:]
        var missToken = 0
        /// Items a read (or your Done) closed, striking until the ledger settles, at their place.
        var closing: [(index: Int, item: RouterItem)] = []
        /// What the read under way says so far: what it closes, what it finds.
        var closes: [String: RouterItemsAnswer.How] = [:]
        var found: [RouterItemsAnswer.Found] = []
        /// Items just added, lit until the ledger settles.
        var fresh: Set<String> = []
        var pulse = 0
        /// A turn's line as it streams.
        var words: String?
        var settleToken = 0
        /// Your words sent from here in this run of Fjord, by key, and whether T3 took them: only taken words are read.
        var sending: [String: Bool] = [:]
        /// Reads that failed in a row, and the retry's wait: nothing is read (nor sheens) until it ends.
        var failures = 0
        var held = false
        var retryToken = 0
        /// A message you sent here, until T3 stamps it.
        var sentAt: Date?
        /// The inputs seen in this run of Fjord after it started (not before a launch, not pending from the last one):
        /// only their items are told as banners.
        var heard: Set<String> = []
        /// The last mid-run message read's start, and the wait for the gap's end.
        var saidAt: Date?
        var saidWait = false
        var saidToken = 0
    }

    /// When this run of Fjord first looked at a thread, and the threads it has looked at since: what it finds on a
    /// thread's first look ended before the launch, unless T3's stamps say otherwise.
    private var launchedAt: Date?
    private var looked: Set<String> = []

    private var live: [String: Live] = [:]

    private func entry(_ id: String) -> Live {
        if let l = live[id] { return l }
        let l = Live()
        live[id] = l
        return l
    }

    // MARK: Inputs

    /// The thread as T3 shows it now, on the page (`reads`: the Router may call the model): what ended and what you wrote
    /// since it was last seen become inputs, and the next one is read.
    /// `ended`: the latest run is over (the thread is Done or Stopped).
    /// `said`: the agent's latest whole message while its run goes on (nil when it ended, or wrote nothing whole yet).
    /// A thread first seen (a first launch, a thread listed again) reads its latest input: the turn it ended, or the
    /// message it posted mid-run. Reads are paced by the verdict queue's cap and the projection reads' (4 at a time).
    func observe(_ id: String, _ t: AgentThread, ended over: Bool, said: Said? = nil, reads: Bool, context: @autoclosure () -> Context) {
        guard reads else { return }
        if launchedAt == nil { launchedAt = now() }
        if let stash = load(id)?.settled { unsettled(id, stash, run: t.latestRunID) }
        let had = load(id)
        let ended = t.latestRunID.flatMap { over ? Input.turn(run: $0).key : nil }
        let run = t.latestRunID
        let mid = run.flatMap { r in said.flatMap { over ? nil : Input.said(id: $0.id, run: r, words: $0.words) } }
        // Nothing new since it was last seen (the common case: one T3 event of many): only a waiting input may go on.
        if let had, had.run == t.latestRunID, (t.lastAuthoredAt ?? .distantPast) <= (had.message ?? .distantPast),
           ended.map({ had.read.contains($0) }) ?? true,
           mid.map({ m in had.read.contains(m.key) || had.pending.contains { $0.key == m.key } }) ?? true {
            looked.insert(id)
            if live[id]?.reading == nil, !had.pending.isEmpty { pump(id, context: context) }
            return
        }
        // Its first look in this run of Fjord: what it finds ended before the launch unless its stamp is later.
        let first = looked.insert(id).inserted
        let launch = launchedAt ?? .distantPast
        let l = entry(id)
        var s = had ?? Saved(run: t.latestRunID, message: t.lastAuthoredAt)
        // A run that is no longer the latest ended: read it, even when the next one started at once (a wake).
        if let prev = s.run, prev != run { enqueue(l, &s, .turn(run: prev), heard: !first) }
        s.run = run
        // You wrote since: every message after the last one seen is listed from the projection, one input each, before
        // the turn that ended after them (a steer, a queued message) and after one that ended before.
        let wrote = t.lastAuthoredAt.flatMap { $0 > (s.message ?? .distantPast) ? $0 : nil }
        let endedFirst = wrote.map { at in t.lastRunEndedAt.map { $0 < at } ?? false } ?? true
        let turnHeard = !first || (t.lastRunEndedAt ?? .distantPast) >= launch
        if endedFirst, let run, over { endTurn(l, &s, run, heard: turnHeard, reply: context().lastReply) }
        if let at = wrote {
            let after = s.message
            s.message = at
            if let i = s.pending.indices.last, case .messages(let from, _) = s.pending[i], l.reading?.key != s.pending[i].key {
                s.pending[i] = .messages(after: from, upTo: at)
            } else {
                enqueue(l, &s, .messages(after: after, upTo: at), heard: !first || at >= launch)
            }
        }
        if !endedFirst, let run, over { endTurn(l, &s, run, heard: turnHeard, reply: context().lastReply) }
        if let mid, !s.read.contains(mid.key), !s.pending.contains(where: { $0.key == mid.key }) {
            // Coalesced: a newer message replaces one still waiting (not the one being read).
            s.pending.removeAll { $0.isSaid && $0.key != l.reading?.key }
            enqueue(l, &s, mid, heard: !first)
        }
        // The inputs and their triggers seen, in one write.
        if s != had { store(id, s) }
        pump(id, context: context)
    }

    /// `run`'s turn ended: it is read. A mid-run message of it still waiting is its reply (`reply`, the records' last
    /// one): the turn's read reads it.
    private func endTurn(_ l: Live, _ s: inout Saved, _ run: String, heard: Bool, reply: String?) {
        if let reply = reply.map(RouterVerdictReading.flat), !reply.isEmpty {
            s.pending.removeAll { p in
                guard case .said(_, let r, let words) = p, r == run, p.key != l.reading?.key else { return false }
                return RouterVerdictReading.flat(words) == reply
            }
        }
        enqueue(l, &s, .turn(run: run), heard: heard)
    }

    /// Your words to the thread, sent here: they show in the block at once and its open items sheen; they are read once
    /// T3 takes them (`took`), and not at all if it refuses them (`refused`).
    func sent(_ id: String, words: String, at: Date, context: @autoclosure () -> Context) {
        let l = entry(id)
        var s = load(id) ?? Saved()
        guard !s.items.isEmpty else { return }
        let input = Input.sent(at: at, words: words)
        s.sent = Array((s.sent + [Sent(at: at, words: words)]).suffix(Self.sentKept))
        l.sending[input.key] = false
        enqueue(l, &s, input, heard: true)
        store(id, s)
        changed(id)
        pump(id, context: context)
    }

    /// T3 took your words sent at `at`: they are read.
    func took(_ id: String, at: Date, context: @autoclosure () -> Context) {
        let key = Input.sent(at: at, words: "").key
        guard let l = live[id], l.sending[key] == false else { return }
        l.sending[key] = true
        pump(id, context: context)
    }

    /// T3 refused your words sent at `at` (offline, the thread gone): nothing is read, nothing closes, and T3's later
    /// messages aren't taken for them.
    func refused(_ id: String, at: Date, context: @autoclosure () -> Context) {
        let key = Input.sent(at: at, words: "").key
        guard let l = live[id], l.sending.removeValue(forKey: key) != nil, var s = load(id) else { return }
        if l.reading?.key == key {
            cancel(id)
            l.reading = nil
            l.closes = [:]
            l.found = []
        }
        s.pending.removeAll { $0.key == key }
        s.sent.removeAll { Input.sent(at: $0.at, words: "").key == key }
        store(id, s)
        changed(id)
        pump(id, context: context)
    }

    private func enqueue(_ l: Live, _ s: inout Saved, _ input: Input, heard: Bool) {
        guard !s.read.contains(input.key), !s.pending.contains(where: { $0.key == input.key }) else { return }
        s.pending.append(input)
        if heard { l.heard.insert(input.key) }
        // A new turn: the header pulses once.
        if input.isTurn, !s.items.isEmpty { l.pulse &+= 1 }
    }

    /// T3 says something new of the thread: a projection read that missed is tried again.
    func moved(_ id: String) {
        guard let l = live[id] else { return }
        l.factsFailed = nil
        l.held = false
    }

    /// A failed read's wait is over: it is made again (`pump` on the next `observe`, or here).
    func retry(_ id: String, context: @autoclosure () -> Context) {
        guard let l = live[id], l.held || l.factsFailed != nil || l.saidWait else { return }
        l.held = false
        l.factsFailed = nil
        l.saidWait = false
        changed(id)
        pump(id, context: context)
    }

    /// What to do once a failed read's wait is over (the records wire it to `retry` with the thread's context).
    var retried: (String) -> Void = { _ in }

    /// A projection read for `key` landed (nil: it failed).
    func facts(_ id: String, key: String, _ f: RouterItemFacts?, context: @autoclosure () -> Context) {
        guard let l = live[id] else { return }
        if l.fetching == key { l.fetching = nil }
        if let f {
            l.facts = f
            l.factsFor = key
        }
        if f == nil || load(id)?.pending.first.map({ $0.key == key && !has(l, $0) }) == true { missed(id, l, key) }
        pump(id, context: context)
    }

    /// How many projection reads an input gets before it is read with what is known, and the wait before the next one.
    static let maxMisses = 5
    var missAfter: (Int) -> TimeInterval = { n in min(pow(2, Double(n)), 30) }

    /// A projection read failed, or didn't have the input yet (T3's projection behind its shell): read again after a
    /// wait, a few times; then the input goes on with what is known, so it never holds the ones behind it.
    private func missed(_ id: String, _ l: Live, _ key: String) {
        let n = (l.misses[key] ?? 0) + 1
        l.misses[key] = n
        guard n < Self.maxMisses else { return }
        l.factsFailed = key
        l.missToken &+= 1
        let token = l.missToken, wait = missAfter(n)
        guard wait > 0 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, let l = self.live[id], l.factsFailed == key, l.missToken == token else { return }
            self.retried(id)
        }
    }

    /// The input's projection reads are spent: it is read with what is known.
    private func spent(_ l: Live, _ key: String) -> Bool { (l.misses[key] ?? 0) >= Self.maxMisses }

    private func has(_ l: Live, _ input: Input) -> Bool {
        switch input {
        case .turn(let run):
            // Ended in the facts; or older than the runs they keep (the ones after it are read instead); or spent.
            l.facts?.turns[run].map { !$0.live && !$0.streaming } ?? (l.facts.map { $0.order.contains(run) } ?? false) || spent(l, input.key)
        case .messages(_, let upTo):
            // Facts read for it that list the message T3 stamped (the projection may lag the shell).
            spent(l, input.key) || l.factsFor == input.key && l.facts?.messages.contains { $0.at >= upTo.addingTimeInterval(-2) } == true
        case .message, .said: true
        // Read once T3 took them.
        case .sent: l.sending[input.key] == true
        }
    }

    /// Starts the next input's read when none is under way: its facts first (one projection read), then the call.
    private func pump(_ id: String, context: () -> Context) {
        guard load(id)?.pending.isEmpty == false else { return }
        let l = entry(id)
        guard l.reading == nil, !l.held else { return }
        while var s = load(id), let input = s.pending.first {
            if input.isYours {
                // Nothing open: your words can't close anything. A turn after them that they started reads them too
                // (not a turn that was only queued, steered or under way when you wrote).
                let carried = if case .message(let mid, _, _, _) = input {
                    s.pending.dropFirst().contains { if case .turn(let r) = $0 { l.facts?.turns[r]?.started == mid } else { false } }
                } else { false }
                if s.items.isEmpty || carried {
                    markRead(&s, input.key)
                    store(id, s)
                    changed(id)
                    continue
                }
            }
            if case .sent(let at, _) = input, l.sending[input.key] == nil {
                // Sent before a relaunch, its fate unknown: T3's copy, if it took it, is read as your message.
                s.pending.removeFirst()
                s.sent.removeAll { $0.at == at }
                store(id, s)
                continue
            }
            if case .sent = input, l.sending[input.key] == false { return }
            guard has(l, input) else {
                guard let fetch, l.fetching == nil, l.factsFailed != input.key else { return }
                l.fetching = input.key
                fetch(id, input.key)
                return
            }
            if input.isSaid, s.pending.count == 1, let at = l.saidAt, now() < at.addingTimeInterval(saidGap) {
                // Sooner than the gap after the last one: it waits for the gap's end (a newer one replaces it).
                guard !l.saidWait else { return }
                l.saidWait = true
                l.saidToken &+= 1
                let token = l.saidToken, wait = at.addingTimeInterval(saidGap).timeIntervalSince(now())
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard let self, let l = self.live[id], l.saidWait, l.saidToken == token else { return }
                    self.retried(id)
                }
                return
            }
            l.saidWait = false
            if case .messages(let after, let upTo) = input {
                let f = l.factsFor == input.key ? l.facts ?? RouterItemFacts() : RouterItemFacts()
                // Each message of yours in it, by its id, oldest first; T3's copy of words sent from here is not read again.
                var inputs: [Input] = []
                for m in f.messages(after: after, upTo: upTo) {
                    if let i = s.sent.firstIndex(where: { $0.matches(m) }) {
                        s.sent.remove(at: i)
                        continue
                    }
                    inputs.append(.message(id: m.id, at: m.at, words: m.text, before: m.before))
                }
                if l.heard.contains(input.key) { l.heard.formUnion(inputs.map(\.key)) }
                // T3 never listed it: a note, so an answer of yours isn't silently unread.
                if !f.messages.contains(where: { $0.at >= upTo.addingTimeInterval(-2) }) { note(&s, Router.Items.Copy.unreadMessage) }
                markRead(&s, input.key)
                let fresh = inputs.filter { x in !s.read.contains(x.key) && !s.pending.contains { $0.key == x.key } }
                s.pending.insert(contentsOf: fresh, at: 0)
                store(id, s)
                continue
            }
            let open = s.items.map {
                RouterItemsInput.Open(id: $0.id, kind: $0.kind, sentence: $0.sentence, options: $0.options,
                                      minutes: Int(now().timeIntervalSince($0.since) / 60))
            }
            let context = context()
            var x = RouterItemsInput(title: context.title, project: context.project, firstAsk: context.firstAsk, open: open,
                                     input: .message(words: "", replyBefore: nil), pullRequests: context.pullRequests)
            switch input {
            case .turn(let run):
                if let f = l.facts, let i = f.order.firstIndex(of: run) {
                    func unread(_ r: String) -> Bool {
                        f.turns[r].map { !$0.live } == true && !s.read.contains(Input.turn(run: r).key) && !s.pending.contains(.turn(run: r))
                    }
                    // The turns between the last one read and this one, never seen (they ran while Fjord was closed, or
                    // the thread off the page): read first, in order. Not on a thread's first read: only its latest is.
                    if let last = f.order[..<i].lastIndex(where: { s.read.contains(Input.turn(run: $0).key) }) {
                        let missed = f.order[(last + 1)..<i].filter(unread)
                        if !missed.isEmpty {
                            s.pending.insert(contentsOf: missed.map { Input.turn(run: $0) }, at: 0)
                            if l.heard.contains(input.key) { l.heard.formUnion(missed.map { Input.turn(run: $0).key }) }
                            store(id, s)
                            continue
                        }
                    }
                    // The turns that ended after it and were never seen (the thread was off the page): read after it, in order.
                    let later = f.order[(i + 1)...].filter(unread)
                    s.pending.insert(contentsOf: later.map { Input.turn(run: $0) }, at: 1)
                    if l.heard.contains(input.key) { l.heard.formUnion(later.map { Input.turn(run: $0).key }) }
                }
                guard let turn = l.facts?.turns[run], !turn.reply.isEmpty else {
                    // A turn with no words, or older than the facts keep: nothing to read. One T3 never listed: a note.
                    if l.facts?.order.contains(run) != true { note(&s, Router.Items.Copy.unread) }
                    markRead(&s, input.key)
                    store(id, s)
                    changed(id)
                    continue
                }
                x.input = .turn(reply: turn.reply, yourWords: turn.yourWords, woke: turn.woke, status: turn.status)
            case .message(_, _, let words, let before):
                x.input = .message(words: words, replyBefore: before ?? context.lastReply)
            case .sent(_, let words):
                x.input = .message(words: words, replyBefore: context.lastReply)
            case .said(_, _, let words):
                x.input = .said(message: words, yourWords: context.yourWords)
                l.saidAt = now()
            case .messages:
                return
            }
            l.reading = input
            // What the last read added is no longer just in: it is checked like the rest.
            l.fresh = []
            l.closes = [:]
            l.found = []
            l.words = nil
            var request = RouterVerdictRequest(thread: id, fingerprint: input.key, kind: .items,
                                               input: RouterVerdictInput(title: context.title, project: context.project), at: now())
            request.items = x
            ask(request)
            changed(id)
            return
        }
    }

    // MARK: The read's answer

    /// What the engine says of a read (`RouterVerdicts.onItems`): closes strike as soon as they are known, new items land,
    /// the line streams; the whole answer is kept. A failure keeps the ledger as it was. Anything for another read is late.
    func event(_ id: String, key: String, _ e: RouterItemsEvent, context: @autoclosure () -> Context) {
        guard let l = live[id], let input = l.reading, input.key == key else { return }
        switch e {
        case .closing(let closes):
            l.closes = closes
            changed(id)
        case .found(let found):
            l.found = found
            changed(id)
        case .words(let text, let done):
            guard case .turn(let run) = input, !text.isEmpty else { return }
            l.words = text
            words(id, run, text, done)
        case .done(let answer):
            commit(id, l, input, answer)
            pump(id, context: context)
        case .unreadable:
            // The model's answer doesn't read, twice: the input is passed with a note, and the next one is read.
            l.reading = nil
            l.closes = [:]
            l.found = []
            l.words = nil
            var s = load(id) ?? Saved()
            note(&s, input.isTurn ? Router.Items.Copy.unread : Router.Items.Copy.unreadMessage)
            markRead(&s, key)
            store(id, s)
            changed(id)
            pump(id, context: context)
        case .failed:
            // Offline, a usage limit, Claude Code missing: the input stays pending, at the head, and is read again after
            // a wait. Only a well-formed answer marks it read.
            l.reading = nil
            l.closes = [:]
            l.found = []
            l.words = nil
            l.failures += 1
            l.held = true
            l.retryToken &+= 1
            let token = l.retryToken, wait = retryAfter(l.failures)
            if wait > 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard let self, let l = self.live[id], l.held, l.retryToken == token else { return }
                    self.retried(id)
                }
            }
            changed(id)
        }
    }

    private func commit(_ id: String, _ l: Live, _ input: Input, _ a: RouterItemsAnswer) {
        var s = load(id) ?? Saved()
        let now = now()
        var striking: [(Int, RouterItem)] = []
        for (i, item) in s.items.enumerated() {
            guard let how = a.close[item.id] else { continue }
            var item = item
            item.state = .closing(Self.copy(how))
            striking.append((i, item))
        }
        s.items.removeAll { a.close[$0.id] != nil }
        var added: [RouterItem] = []
        for f in a.found {
            // Restating an item you marked Done while the read was under way: it stays done.
            if let same = f.sameAs, s.done.contains(where: { $0.item.id == same }) { continue }
            if let same = f.sameAs, let i = s.items.firstIndex(where: { $0.id == same }) {
                s.items[i].sentence = f.sentence
                s.items[i].kind = f.kind
                if !f.options.isEmpty { s.items[i].options = f.options }
                // Restated: its newer words, when the read has them.
                if let detail = f.detail { s.items[i].detail = detail }
                if let quote = f.quote { s.items[i].quote = quote }
                s.items[i].since = now
            } else {
                let item = RouterItem(id: "i\(s.next)", kind: f.kind, sentence: f.sentence, since: now, options: f.options,
                                      detail: f.detail, quote: f.quote)
                s.next += 1
                s.items.append(item)
                added.append(item)
            }
        }
        if case .turn(let run) = input, !a.line.isEmpty {
            s.line = a.line
            s.lineRun = run
        }
        markRead(&s, input.key)
        store(id, s)
        l.reading = nil
        l.failures = 0
        l.closes = [:]
        l.found = []
        l.words = nil
        l.closing += striking
        l.fresh.formUnion(added.map(\.id))
        settleLater(id, l)
        // Told only for what this run of Fjord saw happen: not what ended before the launch, nor a read left pending by the last.
        let needs = added.filter { $0.kind != .know }
        if !needs.isEmpty, l.heard.contains(input.key) { self.added(id, needs, input.key) }
        l.heard.remove(input.key)
        changed(id)
    }

    static func copy(_ how: RouterItemsAnswer.How) -> String {
        switch how {
        case .answered: Router.Items.Copy.answered
        case .done: Router.Items.Copy.doneByAgent
        case .obsolete: Router.Items.Copy.obsolete
        }
    }

    /// An input that couldn't be read leaves a Know saying so (once while it is open), so nothing goes silently.
    private func note(_ s: inout Saved, _ sentence: String) {
        guard !s.items.contains(where: { $0.sentence == sentence }) else { return }
        s.items.append(RouterItem(id: "i\(s.next)", kind: .know, sentence: sentence, since: now()))
        s.next += 1
    }

    /// The input's read is applied (or there was nothing to read): it leaves the pending list.
    private func markRead(_ s: inout Saved, _ key: String) {
        s.pending.removeAll { $0.key == key }
        guard !s.read.contains(key) else { return }
        s.read = Array((s.read + [key]).suffix(Self.readKept))
    }

    private func settleLater(_ id: String, _ l: Live) {
        guard !l.closing.isEmpty || !l.fresh.isEmpty else { return }
        l.settleToken &+= 1
        let token = l.settleToken
        guard strike > 0 else { return }
        Task { @MainActor [weak self, strike] in
            try? await Task.sleep(for: .seconds(strike))
            guard let self, self.live[id]?.settleToken == token else { return }
            self.settle(id)
        }
    }

    /// After the strike and the highlight: the closed items are gone, the new ones are at rest.
    func settle(_ id: String) {
        guard let l = live[id], !l.closing.isEmpty || !l.fresh.isEmpty else { return }
        l.closing = []
        l.fresh = []
        changed(id)
    }

    // MARK: Your acts

    /// Done on an item (`on`), or its Revert: it strikes "done by you" and goes; Revert puts it back where it was. The
    /// mark is kept in the file: a reset of the thread (a settle, a relaunch) still reverts, and a read under way that
    /// restates the item doesn't bring it back.
    func done(_ id: String, item: String, on: Bool) {
        let l = entry(id)
        var s = load(id) ?? Saved()
        if on {
            guard let i = s.items.firstIndex(where: { $0.id == item }) else { return }
            var was = s.items.remove(at: i)
            s.done = Array((s.done.filter { $0.item.id != item } + [Done(item: was, index: i)]).suffix(Self.doneKept))
            store(id, s)
            was.state = .closing(Router.Items.Copy.doneByYou)
            l.closing.append((i, was))
            settleLater(id, l)
        } else {
            guard let mark = s.done.last(where: { $0.item.id == item }) else { return }
            s.done.removeAll { $0.item.id == item }
            l.closing.removeAll { $0.item.id == item }
            if !s.items.contains(where: { $0.id == item }) {
                var back = mark.item
                back.state = .open
                s.items.insert(back, at: min(mark.index, s.items.count))
            }
            store(id, s)
        }
        changed(id)
    }

    /// The thread was settled: its ledger goes, and any read of it with it. What was open is kept for the Settle's
    /// Revert (`unsettled`) until a new run starts.
    func settled(_ id: String) {
        if let l = live[id], l.reading != nil { cancel(id) }
        live[id] = nil
        guard var s = load(id), !s.items.isEmpty || s.line != nil || !s.pending.isEmpty else { return }
        let was = s.settled
        s.settled = Stash(items: (was?.items ?? []) + s.items, line: s.line ?? was?.line, lineRun: s.line == nil ? was?.lineRun : s.lineRun,
                          pending: (was?.pending ?? []) + s.pending, run: s.run)
        s.items = []
        s.line = nil
        s.lineRun = nil
        s.pending = []
        store(id, s)
    }

    /// The thread is on the page again after a settle: its Revert (no run since) puts back what was open and the read
    /// that was under way; a new run means the settle stood, and the stash goes.
    private func unsettled(_ id: String, _ stash: Stash, run: String?) {
        guard var s = load(id) else { return }
        s.settled = nil
        if stash.run == run {
            s.items = stash.items + s.items.filter { i in !stash.items.contains { $0.id == i.id } }
            if s.line == nil { s.line = stash.line; s.lineRun = stash.lineRun }
            s.pending = stash.pending + s.pending.filter { p in !stash.pending.contains { $0.key == p.key } }
        }
        store(id, s)
    }

    /// The thread left T3's list: its read stops.
    func dropped(_ id: String) {
        if let l = live[id], l.reading != nil { cancel(id) }
        live[id] = nil
    }

    // MARK: What the page shows

    /// The ledger as the page draws it: open items (sheening while a read may close them), what the read under way
    /// closes (striking) and finds (lit), what was just closed, your words or the new turn's placeholder.
    func ledger(_ id: String) -> RouterLedger {
        guard let s = load(id), !s.items.isEmpty || live[id].map({ !$0.closing.isEmpty || !$0.found.isEmpty }) == true else {
            return RouterLedger()
        }
        let l = live[id]
        // A mid-run message's read is quiet: what it finds lands, nothing sheens meanwhile.
        let busy = l?.held != true && (l?.reading.map { !$0.isSaid } ?? false || s.pending.contains { !$0.isSaid })
        var items = s.items.map { item -> RouterItem in
            var item = item
            if let how = l?.closes[item.id] {
                item.state = .closing(Self.copy(how))
            } else if l?.fresh.contains(item.id) == true {
                item.state = .new
            } else if busy {
                item.state = .checking
            }
            return item
        }
        if let l {
            for (i, item) in l.closing.sorted(by: { $0.index < $1.index }) {
                items.insert(item, at: min(i, items.count))
            }
            // What the read under way found: restated items stay; new ones land lit (their ids as the commit gives them).
            var n = s.next
            for f in l.found where f.sameAs == nil || !s.items.contains(where: { $0.id == f.sameAs }) && !s.done.contains(where: { $0.item.id == f.sameAs }) {
                var item = RouterItem(id: "i\(n)", kind: f.kind, sentence: f.sentence, since: now(), options: f.options,
                                      detail: f.detail, quote: f.quote, state: .new)
                item.preview = true
                items.append(item)
                n += 1
            }
        }
        var ledger = RouterLedger(items: items)
        ledger.pulse = l?.pulse ?? 0
        if busy, !s.items.isEmpty, let l {
            if let input = l.reading.flatMap({ $0.isSaid ? nil : $0 }) ?? s.pending.first(where: { !$0.isSaid }) {
                ledger.read = input.words.map { .message($0) } ?? .turn
            }
        }
        return ledger
    }

    /// The latest turn's line, when it is `run`'s.
    func line(_ id: String, run: String?) -> String? {
        guard let s = load(id), let run, s.lineRun == run else { return nil }
        return s.line
    }

    /// `run`'s turn is being read (or waits to be): Done's line isn't in yet.
    func reading(_ id: String, run: String?) -> Bool {
        guard let run, let s = load(id), !s.pending.isEmpty, live[id]?.held != true else { return false }
        return s.pending.contains(.turn(run: run))
    }

    /// A turn's line streaming now.
    func streaming(_ id: String) -> String? { live[id]?.words }

    var readingCount: Int { live.values.filter { $0.reading != nil }.count }
}

extension RouterItem: Codable {
    private enum CodingKeys: String, CodingKey { case id, kind, sentence, since, options, detail, quote }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), kind: try c.decode(Kind.self, forKey: .kind),
                  sentence: try c.decode(String.self, forKey: .sentence), since: try c.decode(Date.self, forKey: .since),
                  options: try c.decodeIfPresent([String].self, forKey: .options) ?? [],
                  // Items saved before reads kept them have neither: the card quotes the thread's last lines.
                  detail: try c.decodeIfPresent(String.self, forKey: .detail),
                  quote: try c.decodeIfPresent(String.self, forKey: .quote))
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(sentence, forKey: .sentence)
        try c.encode(since, forKey: .since)
        if !options.isEmpty { try c.encode(options, forKey: .options) }
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(quote, forKey: .quote)
    }
}
