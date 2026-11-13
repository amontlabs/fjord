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
        var status: String
        /// Still running: its reply isn't whole yet.
        var live: Bool
    }

    struct Message: Equatable, Sendable {
        var at: Date
        var text: String
        var before: String?
    }

    var turns: [String: Turn] = [:]
    var messages: [Message] = []

    /// How many of the latest runs and messages are read.
    static let kept = 8

    static func make(_ p: T3Projection) -> RouterItemFacts {
        var f = RouterItemFacts()
        let byID = Dictionary(p.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for run in p.runs.filter({ !$0.isQueued }).suffix(kept) {
            var reply = p.messages.last { $0.runId == run.id && $0.role == "assistant" && !$0.text.isEmpty && !$0.streaming }?.text
            if reply == nil, let item = p.turnItems.last(where: {
                if $0.runId == run.id, case .assistantMessage(_, let t, let s) = $0.detail { !t.isEmpty && !s } else { false }
            }), case .assistantMessage(_, let text, _) = item.detail {
                reply = text
            }
            let own = run.userMessageId.flatMap { byID[$0] }
            f.turns[run.id] = Turn(reply: reply ?? "", yourWords: own?.createdBy == "user" ? own?.text : nil,
                                   woke: own.flatMap { $0.createdBy == "user" ? nil : $0.text }, status: run.status.rawValue,
                                   live: run.status.isLive)
        }
        let ordered = p.messages.filter { $0.createdAt != nil }.sorted { ($0.createdAt?.date ?? .distantPast) < ($1.createdAt?.date ?? .distantPast) }
        var before: String?
        var mine: [Message] = []
        for m in ordered {
            if m.role == "assistant", !m.text.isEmpty { before = m.text }
            if m.role == "user", m.createdBy == "user", !m.text.isEmpty, let at = m.createdAt?.date {
                mine.append(Message(at: at, text: m.text, before: before))
            }
        }
        f.messages = Array(mine.suffix(kept))
        return f
    }

    /// The message of yours T3 stamped at `at`: the one at that time, else the latest before it.
    func message(at: Date) -> Message? {
        messages.first { abs($0.at.timeIntervalSince(at)) < 2 } ?? messages.last { $0.at <= at.addingTimeInterval(2) }
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
    }

    /// One input, read once.
    enum Input: Equatable {
        case turn(run: String)
        /// `words`: known when you wrote them here (they show in the block at once); else read from T3.
        case message(at: Date, words: String?)

        var key: String {
            switch self {
            case .turn(let run): "turn:" + run
            case .message(let at, _): "msg:" + String(Int64(at.timeIntervalSince1970 * 1000))
            }
        }

        var isTurn: Bool { if case .turn = self { true } else { false } }
    }

    /// What a thread's read needs from the records: its title, project, first ask and PRs, as a read's base.
    struct Context {
        var title: String
        var project: String?
        var firstAsk: String?
        var pullRequests: [RouterVerdictInput.PullRequest] = []
        /// The agent's last reply, as the records hold it: what your words sent here answer.
        var lastReply: String?
    }

    static let readKept = 40

    // MARK: Wiring

    var load: (String) -> Saved? = { _ in nil }
    var store: (String, Saved?) -> Void = { _, _ in }
    var ask: (RouterVerdictRequest) -> Void = { _ in }
    var cancel: (String) -> Void = { _ in }
    /// Reads the thread's projection once for an input (`key`), answering with `facts(_:key:_:)`.
    var fetch: ((_ thread: String, _ key: String) -> Void)?
    /// The thread's record should be composed again.
    var changed: (String) -> Void = { _ in }
    /// A turn's line as it streams.
    var words: (_ thread: String, _ text: String, _ done: Bool) -> Void = { _, _, _ in }
    /// Items a read added that need you (banners).
    var added: (_ thread: String, _ items: [RouterItem], _ key: String) -> Void = { _, _, _ in }
    var now: () -> Date = Date.init
    /// How long a closed item strikes, and a new one is lit, before the ledger settles (0 in tests: `settle` by hand).
    var strike: TimeInterval = Router.Items.strike

    // MARK: State

    private final class Live {
        var queue: [Input] = []
        var reading: Input?
        var facts: RouterItemFacts?
        var fetching: String?
        var factsFailed: String?
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
        /// Items you marked Done, for their Revert: the item and where it was.
        var done: [String: (index: Int, item: RouterItem)] = [:]
        var settleToken = 0
        /// A message you sent here, until T3 stamps it.
        var sentAt: Date?
    }

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
    func observe(_ id: String, _ t: AgentThread, ended over: Bool, reads: Bool, context: @autoclosure () -> Context) {
        guard reads else { return }
        let had = load(id)
        let ended = t.latestRunID.flatMap { over ? Input.turn(run: $0).key : nil }
        // Nothing new since it was last seen (the common case: one T3 event of many): only a waiting input may go on.
        if let had, had.run == t.latestRunID, (t.lastAuthoredAt ?? .distantPast) <= (had.message ?? .distantPast),
           ended.map({ had.read.contains($0) }) ?? true {
            if let l = live[id], l.reading == nil, !l.queue.isEmpty { pump(id, context: context) }
            return
        }
        let l = entry(id)
        var s = had ?? Saved(run: t.latestRunID, message: t.lastAuthoredAt)
        let run = t.latestRunID
        // A run that is no longer the latest ended: read it, even when the next one started at once (a wake).
        if let prev = s.run, prev != run { enqueue(l, s, .turn(run: prev)) }
        s.run = run
        if let run, over { enqueue(l, s, .turn(run: run)) }
        if let at = t.lastAuthoredAt, at > (s.message ?? .distantPast) {
            s.message = at
            // Your words sent here are already in (with their words); T3 stamping them is the same message.
            if let sent = l.sentAt, at >= sent.addingTimeInterval(-5) {
                l.sentAt = nil
            } else {
                enqueue(l, s, .message(at: at, words: nil))
            }
        }
        if s != had { store(id, s) }
        pump(id, context: context)
    }

    /// Your words to the thread, sent here: read at once (its open items sheen, your words show in the block).
    func sent(_ id: String, words: String, at: Date, context: @autoclosure () -> Context) {
        let l = entry(id)
        let s = load(id) ?? Saved()
        guard !s.items.isEmpty else { return }
        l.sentAt = at
        enqueue(l, s, .message(at: at, words: words))
        changed(id)
        pump(id, context: context)
    }

    private func enqueue(_ l: Live, _ s: Saved, _ input: Input) {
        guard !s.read.contains(input.key), l.reading?.key != input.key, !l.queue.contains(where: { $0.key == input.key }) else { return }
        l.queue.append(input)
        // A new turn: the header pulses once.
        if input.isTurn, !s.items.isEmpty { l.pulse &+= 1 }
    }

    /// T3 says something new of the thread: a projection read that missed is tried again.
    func moved(_ id: String) { live[id]?.factsFailed = nil }

    /// A projection read for `key` landed (nil: it failed).
    func facts(_ id: String, key: String, _ f: RouterItemFacts?, context: @autoclosure () -> Context) {
        guard let l = live[id] else { return }
        if l.fetching == key { l.fetching = nil }
        if let f { l.facts = f }
        if f == nil || l.queue.first?.key == key && !has(l, l.queue[0]) { l.factsFailed = key }
        pump(id, context: context)
    }

    private func has(_ l: Live, _ input: Input) -> Bool {
        switch input {
        case .turn(let run): l.facts?.turns[run].map { !$0.live } ?? false
        case .message(let at, let words): words != nil || l.facts?.message(at: at) != nil
        }
    }

    /// Starts the next input's read when none is under way: its facts first (one projection read), then the call.
    private func pump(_ id: String, context: () -> Context) {
        guard let l = live[id], l.reading == nil else { return }
        while let input = l.queue.first {
            var s = load(id) ?? Saved()
            if case .message = input {
                // Nothing open: your words can't close anything. A turn after them in the queue reads them too.
                if s.items.isEmpty || l.queue.dropFirst().contains(where: \.isTurn) {
                    l.queue.removeFirst()
                    markRead(&s, input.key)
                    store(id, s)
                    changed(id)
                    continue
                }
            }
            guard has(l, input) else {
                guard let fetch, l.fetching == nil, l.factsFailed != input.key else { return }
                l.fetching = input.key
                fetch(id, input.key)
                return
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
                guard let turn = l.facts?.turns[run], !turn.reply.isEmpty else {
                    // A turn with no words: nothing to read.
                    l.queue.removeFirst()
                    markRead(&s, input.key)
                    store(id, s)
                    changed(id)
                    continue
                }
                x.input = .turn(reply: turn.reply, yourWords: turn.yourWords, woke: turn.woke, status: turn.status)
            case .message(let at, let words):
                let m = l.facts?.message(at: at)
                x.input = .message(words: words ?? m?.text ?? "", replyBefore: m?.before ?? context.lastReply)
            }
            l.queue.removeFirst()
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
            guard input.isTurn, !text.isEmpty else { return }
            l.words = text
            words(id, text, done)
        case .done(let answer):
            commit(id, l, input, answer)
            pump(id, context: context)
        case .failed:
            l.reading = nil
            l.closes = [:]
            l.found = []
            l.words = nil
            var s = load(id) ?? Saved()
            markRead(&s, key)
            store(id, s)
            changed(id)
            pump(id, context: context)
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
            if let same = f.sameAs, let i = s.items.firstIndex(where: { $0.id == same }) {
                s.items[i].sentence = f.sentence
                s.items[i].kind = f.kind
                if !f.options.isEmpty { s.items[i].options = f.options }
                s.items[i].since = now
            } else {
                let item = RouterItem(id: "i\(s.next)", kind: f.kind, sentence: f.sentence, since: now, options: f.options)
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
        l.closes = [:]
        l.found = []
        l.words = nil
        l.closing += striking
        l.fresh.formUnion(added.map(\.id))
        settleLater(id, l)
        let needs = added.filter { $0.kind != .know }
        if !needs.isEmpty { self.added(id, needs, input.key) }
        changed(id)
    }

    static func copy(_ how: RouterItemsAnswer.How) -> String {
        switch how {
        case .answered: Router.Items.Copy.answered
        case .done: Router.Items.Copy.doneByAgent
        case .obsolete: Router.Items.Copy.obsolete
        }
    }

    private func markRead(_ s: inout Saved, _ key: String) {
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

    /// Done on an item (`on`), or its Revert: it strikes "done by you" and goes; Revert puts it back where it was.
    func done(_ id: String, item: String, on: Bool) {
        let l = entry(id)
        var s = load(id) ?? Saved()
        if on {
            guard let i = s.items.firstIndex(where: { $0.id == item }) else { return }
            var was = s.items.remove(at: i)
            l.done[item] = (i, was)
            store(id, s)
            was.state = .closing(Router.Items.Copy.doneByYou)
            l.closing.append((i, was))
            settleLater(id, l)
        } else {
            guard let (i, was) = l.done.removeValue(forKey: item), !s.items.contains(where: { $0.id == item }) else { return }
            l.closing.removeAll { $0.item.id == item }
            var back = was
            back.state = .open
            s.items.insert(back, at: min(i, s.items.count))
            store(id, s)
        }
        changed(id)
    }

    /// The thread was settled: its ledger goes, and any read of it with it.
    func settled(_ id: String) {
        if let l = live[id], l.reading != nil { cancel(id) }
        live[id] = nil
        if let s = load(id), !s.items.isEmpty || s.line != nil {
            var s = s
            s.items = []
            s.line = nil
            s.lineRun = nil
            store(id, s)
        }
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
        let busy = l.map { $0.reading != nil || !$0.queue.isEmpty } ?? false
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
            for f in l.found where f.sameAs == nil || !s.items.contains(where: { $0.id == f.sameAs }) {
                items.append(RouterItem(id: "i\(n)", kind: f.kind, sentence: f.sentence, since: now(), options: f.options, state: .new))
                n += 1
            }
        }
        var ledger = RouterLedger(items: items)
        ledger.pulse = l?.pulse ?? 0
        if busy, !s.items.isEmpty, let l {
            switch l.reading ?? l.queue.first {
            case .message(let at, let words)?:
                if let words = words ?? l.facts?.message(at: at)?.text { ledger.read = .message(words) } else { ledger.read = .turn }
            case .turn?: ledger.read = .turn
            case nil: break
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
        guard let run, let l = live[id], l.reading != nil || !l.queue.isEmpty else { return false }
        let input = Input.turn(run: run)
        return l.reading == input || l.queue.contains(input)
    }

    /// A turn's line streaming now.
    func streaming(_ id: String) -> String? { live[id]?.words }

    var readingCount: Int { live.values.filter { $0.reading != nil }.count }
}

extension RouterItem: Codable {
    private enum CodingKeys: String, CodingKey { case id, kind, sentence, since, options }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), kind: try c.decode(Kind.self, forKey: .kind),
                  sentence: try c.decode(String.self, forKey: .sentence), since: try c.decode(Date.self, forKey: .since),
                  options: try c.decodeIfPresent([String].self, forKey: .options) ?? [])
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(sentence, forKey: .sentence)
        try c.encode(since, forKey: .since)
        if !options.isEmpty { try c.encode(options, forKey: .options) }
    }
}
