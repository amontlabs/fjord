import AppKit
import Foundation
import Observation

// The briefs in the app (docs/design/router-watch-and-briefs.md 3.5, 4 and 5): the engine's documents (or a demo's), the
// page they make (`BriefPage`, ordered as in 4), what you focus and pick, and the acts: an option answered by Return, your
// words sent to the thread, Open, mark read, archive. A waiting request is answered through T3 (on this Mac or a
// remote computer). Mark read and archive are Fjord changes with a Revert (`FjordChange.briefAction`); the marks, and which
// finished threads were told, are kept in briefs.db.

/// An answer you gave from the brief, one line in the drawer (an answer can't be taken back).
struct BriefAnswer: Identifiable, Equatable {
    let id = UUID()
    var target: BriefTarget
    var title: String
    var words: String
    var at: Date
}

/// The brief as the page shows it: the lead, then up to 12 project sections in the order of 4, the rest folded.
struct BriefPage: Equatable {
    enum Group: Int, Comparable {
        case needsYou, stranded, finished, working, quiet
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    struct Section: Equatable, Identifiable {
        var id: String { doc.project }
        var name: String
        var group: Group
        var doc: BriefDoc
        /// The entries not marked read, oldest first.
        var entries: [BriefEntry]
        /// Threads touched in the last 24 h, newest first, those that wait on you aside.
        var recent: [BriefThread]
        /// Finished threads not yet told.
        var finished: [BriefThread]
        var staleSince: Double?
    }

    static let cap = 12
    static let recent = 86_400.0

    var lead = GeneralBrief()
    var sections: [Section] = []
    /// The names of the sections past the cap.
    var folded: [String] = []
    /// Entries not marked read, every project: the bar's mark.
    var needsYou = 0

    /// What a read mark holds to: the entry's episode on the Board (its status change, or its card), else the model's `since`.
    static func entryKey(_ e: BriefEntry) -> String { "\(e.project)/\(e.thread)/\(e.episode ?? String(Int(e.since)))" }
    static func finishKey(_ t: BriefThread) -> String { "\(t.id)@\(Int(t.age))" }

    static func staleSince(_ watch: String?) -> Double? {
        guard let w = watch, w.hasPrefix("stale:") else { return nil }
        return Double(w.dropFirst(6))
    }

    static func make(docs: [String: BriefDoc], names: [String: String], lead: GeneralBrief, read: Set<String>, told: Set<String>,
                     archived: Set<String> = [], now: Double) -> BriefPage {
        var sections: [(Section, Double)] = []
        var count = 0
        for (id, doc) in docs {
            let entries = doc.needsYou.filter { !read.contains(entryKey($0)) && !archived.contains($0.target.key) }
            count += entries.count
            let waiting = Set(entries.map(\.thread))
            let threads = doc.threads.filter { !archived.contains(BriefTarget(project: id, thread: $0.id).key) }
            let recent = threads.filter { now - $0.age <= Self.recent && !waiting.contains($0.id) }.sorted { ($0.age, $0.id) > ($1.age, $1.id) }
            let finished = recent.filter { $0.status == .done && !told.contains(finishKey($0)) }
            let group: Group, key: Double
            if let first = entries.first(where: { $0.kind != .stranded }) {
                group = .needsYou; key = first.since
            } else if let first = entries.first {
                group = .stranded; key = first.since
            } else if let newest = finished.first {
                group = .finished; key = -newest.age
            } else if let working = threads.filter({ $0.status == .working }).max(by: { $0.age < $1.age }) {
                group = .working; key = -working.age
            } else {
                group = .quiet; key = 0
            }
            let name = names[id].flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackName(id)
            sections.append((Section(name: name, group: group, doc: doc, entries: entries, recent: recent, finished: finished,
                                     staleSince: staleSince(doc.watch)), key))
        }
        sections.sort { a, b in
            if a.0.group != b.0.group { return a.0.group < b.0.group }
            if a.1 != b.1 { return a.1 < b.1 }
            return (a.0.name.lowercased(), a.0.id) < (b.0.name.lowercased(), b.0.id)
        }
        let shown = sections.prefix(cap).map(\.0)
        return BriefPage(lead: lead, sections: Array(shown), folded: sections.dropFirst(cap).map(\.0.name), needsYou: count)
    }

    /// A project with no name on the Board: a local folder's (`local:<name>`), else its id.
    static func fallbackName(_ id: String) -> String { id.hasPrefix("local:") ? String(id.dropFirst(6)) : id }

    /// Every entry in page order: what ↑↓ walk.
    var entries: [BriefEntry] { sections.flatMap(\.entries) }
}

/// The brief's keys, while an entry is focused and the composer is empty (else every key types): Return confirms or replies,
/// Esc steps back, ↑↓ walk the entries. With the keyboard on the brief (not in the composer) also 1 to 9, which pick an
/// option by the top row's physical key codes (the same keys on AZERTY, where the unshifted characters differ), O open,
/// A archive and R mark read: in the composer, letters and digits are always your words.
enum BriefKeys {
    enum Action: Equatable { case pick(Int), confirm, open, archive, read, back, move(down: Bool) }

    /// `kVK_ANSI_1` … `kVK_ANSI_9`.
    static let digits: [Int] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static func action(code: Int, characters: String?, flags: NSEvent.ModifierFlags, focused: Bool, composerEmpty: Bool,
                       inComposer: Bool = false) -> Action? {
        guard focused, composerEmpty, flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch code {
        case 36, 76: return flags.contains(.shift) ? nil : .confirm
        case 53: return .back
        case 125: return .move(down: true)
        case 126: return .move(down: false)
        default: break
        }
        guard !inComposer else { return nil }
        if let i = digits.firstIndex(of: code) { return .pick(i + 1) }
        guard flags.subtracting(.shift).isEmpty else { return nil }
        switch characters?.lowercased() {
        case "o": return .open
        case "a": return .archive
        case "r": return .read
        default: return nil
        }
    }
}

@MainActor @Observable final class RouterBriefs {
    /// Notification ids of brief entries: `brief:<project>/<thread>`.
    nonisolated static let notificationPrefix = "brief:"
    /// More new entries than this at once: one banner says how many.
    static let notifyEach = 3

    private(set) var engine: RouterBriefEngine?
    @ObservationIgnored weak var store: Store?
    /// A demo's or a shot's documents, when no engine runs.
    var demoDocs: [String: BriefDoc] = [:] {
        didSet { docsChanged() }
    }
    var demoGeneral = GeneralBrief()
    var demoVersions: [String: [BriefVersion]] = [:]
    var names: [String: String] = [:]
    /// A local thread's session key on the Board, and that key's Claude Code session id.
    var sessions: [String: String] = [:]
    var clis: [String: String] = [:]

    /// The threads your words go to, in the order picked: a click on the brief (or Reply in the palette) picks one alone,
    /// a ⌘-click adds one or takes it off. The composer's chips show them; Backspace at its start takes the last off, Esc
    /// all of them.
    var mentioned: [BriefTarget] = []
    /// The last one picked: what the keys act on.
    var focused: BriefTarget? {
        get { mentioned.last }
        set { focus(newValue) }
    }
    /// Option N picked on an entry, shown live until Return sends it.
    var picked: [BriefTarget: Int] = [:]
    /// Projects folded or opened against how they start (open with something for you, folded with nothing).
    var toggled: Set<String> = []
    /// The highlight whose panel shows (`BriefSpan.key`: where it is on the page, and its thread): under the pointer, or
    /// held while you type in it.
    var hovered: String?
    /// Its thread: what 1–9, Return, O and R act on while it shows.
    private(set) var hoveredTarget: BriefTarget?
    /// The page's visible area.
    var viewport: CGSize = .zero
    @ObservationIgnored private var pointerIn = false
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var leaving: Task<Void, Never>?

    /// The pointer on a highlight or its panel, or off it: it shows at once, and goes a moment after the pointer leaves
    /// both, so crossing from one to the other keeps it.
    func hover(_ key: String, _ t: BriefTarget, inside: Bool) {
        leaving?.cancel()
        pointerIn = inside
        if inside {
            if hovered != key { hovered = key; hoveredTarget = t }
            return
        }
        guard !holding, hovered == key else { return }
        leaving = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.hoverGrace))
            guard let self, !Task.isCancelled, !self.pointerIn, !self.holding, self.hovered == key else { return }
            self.unhover()
        }
    }

    static let hoverGrace = 220

    func unhover() {
        leaving?.cancel()
        hovered = nil
        hoveredTarget = nil
        holding = false
    }

    /// Typing in the panel keeps it, wherever the pointer is; done typing with the pointer away, it goes.
    func hold(_ on: Bool) {
        holding = on
        if !on, !pointerIn { unhover() }
    }
    var drawerOpen = false
    /// Why an answer didn't go (refused, failed), on its entry until it changes.
    var trouble: [BriefTarget: String] = [:]
    /// Answers handed over, until the entry leaves on proof.
    var sending: [BriefTarget: Int] = [:]
    /// Entries with an answer under way: no other pick or answer until it settles.
    private(set) var answering: Set<BriefTarget> = []
    @ObservationIgnored private var work: [BriefTarget: Task<Void, Never>] = [:]
    /// Entries marked read (`BriefPage.entryKey`), threads archived (`BriefTarget.key`), and finished threads told (their
    /// section was shown and then left), as briefs.db keeps them.
    private(set) var marks = BriefMarks()
    var read: Set<String> { marks.read }
    var archived: Set<String> { marks.archived }
    var told: Set<String> { marks.told }
    @ObservationIgnored var shownFinishes: Set<String> = []
    private(set) var answers: [BriefAnswer] = []
    /// Entries not marked read, every project (the bar's mark): counted when the documents or the marks change.
    private(set) var untoldNeedsYou = 0
    /// The page's clock (a shot pins it).
    @ObservationIgnored var clock: () -> Date = Date.init

    @ObservationIgnored let link = RouterBriefLink()

    var docs: [String: BriefDoc] { engine?.docs ?? demoDocs }
    var general: GeneralBrief { engine?.general ?? demoGeneral }

    func page() -> BriefPage {
        BriefPage.make(docs: docs, names: names, lead: general, read: read, told: told, archived: archived,
                       now: clock().timeIntervalSince1970)
    }

    // MARK: Start

    /// Starts the engine on the link's host, with the Router on: `briefs.db` next to router.db, the host's changes driving it.
    func start(store: Store) {
        guard engine == nil, store.routerOn, let host = store.routerCourierLink.host else { return }
        let path = URL(fileURLWithPath: host.dbPath).deletingLastPathComponent().appendingPathComponent("briefs.db").path
        guard let db = try? SQLiteBriefStore(path: path) else { return }
        let engine = RouterBriefEngine(source: CourierBriefSource(host: host), store: db, model: RouterBriefer.haiku(store: store),
                                       style: { [weak store] in store?.routerStyle ?? RouterStyle.defaultText })
        self.engine = engine
        marks = engine.marks()
        engine.onDocs = { [weak self] in self?.docsChanged() }
        link.onChange = { [weak self, weak store] change in
            guard let self else { return }
            if self.names != change.names { self.names = change.names }
            if self.sessions != change.sessions { self.sessions = change.sessions }
            if let clis = store?.routerCourierLink.localCLI, self.clis != clis { self.clis = clis }
        }
        link.follow(host.briefChanges, events: engine)
        Task { [weak self] in
            let facts = await host.allBriefFacts()
            self?.names = facts.mapValues(\.name)
            engine.start()
        }
    }

    /// The Router switched on or off: the engine runs only while it is on (no model call with it off).
    func switched(store: Store) {
        if store.routerOn {
            if let engine { engine.start() } else { start(store: store) }
        } else {
            engine?.stop()
        }
    }

    // MARK: Count and banners

    /// The documents or the marks changed: the count again, and a banner for each entry newly told (once per entry).
    private func docsChanged() {
        recount()
        guard engine != nil, let store else { return }
        announce(store: store)
    }

    private func recount() {
        let count = page().needsYou
        if untoldNeedsYou != count { untoldNeedsYou = count }
    }

    /// The entries no banner has told yet (not read, not archived), each told once, through the app's banners; more than
    /// `notifyEach` at once, one banner says how many.
    func announce(store: Store) {
        var fresh: [(name: String, entry: BriefEntry)] = []
        for (id, doc) in docs.sorted(by: { $0.key < $1.key }) {
            for e in doc.needsYou where !marks.notified.contains(BriefPage.entryKey(e)) && !read.contains(BriefPage.entryKey(e))
                && !archived.contains(e.target.key) {
                fresh.append((names[id].flatMap { $0.isEmpty ? nil : $0 } ?? BriefPage.fallbackName(id), e))
            }
        }
        guard !fresh.isEmpty else { return }
        for f in fresh { set(.notified, BriefPage.entryKey(f.entry), on: true) }
        if fresh.count > Self.notifyEach {
            let first = fresh.min { $0.entry.since < $1.entry.since }!.entry
            store.notifyRouter(id: Self.notificationPrefix + first.target.key, title: "\(fresh.count) threads need you",
                               subtitle: Set(fresh.map(\.name)).sorted().joined(separator: ", "), body: "")
            return
        }
        for f in fresh {
            let e = f.entry
            store.notifyRouter(id: Self.notificationPrefix + e.target.key, title: "\(f.name) · needs you", subtitle: title(e.target),
                               body: e.question ?? BriefEntryText.kindLabel(e))
        }
    }

    // MARK: Entries

    /// A local thread's Claude Code session id, as the Courier's board knows it (T3's threads carry none).
    func cli(_ t: BriefTarget, store: Store) -> String? {
        if let key = sessions[t.thread], let cli = clis[key] { return cli }
        return nil
    }

    /// The T3 thread id a brief target stands for: the Courier's session key of a local thread, else the id itself.
    func threadID(_ t: BriefTarget) -> String { sessions[t.thread] ?? t.thread }

    /// The T3 thread a brief entry is about, when Fjord lists it.
    func desktopSession(_ t: BriefTarget, store: Store) -> String? {
        store.threads[threadID(t)] != nil ? threadID(t) : nil
    }

    /// What T3 says a local entry's thread waits on you for.
    func request(_ e: BriefEntry, store: Store) -> ThreadRequest? {
        guard e.source == .local else { return nil }
        return store.heldRequest(e.target)
    }

    /// An entry as acted on: a local one with its request, T3's question and options, a permission's buttons, a plan's two
    /// yeses. A request T3 can no longer take an answer for says so and offers no buttons.
    func resolved(_ e: BriefEntry, store: Store) -> BriefEntry {
        guard let request = request(e, store: store) else { return e }
        var e = e
        e.request = request
        let gone = request.live ? "" : "T3 restarted since it asked: answer it in T3, or send words instead.\n"
        switch request.body {
        case .plan(let markdown):
            e.kind = .plan
            e.question = gone + (e.question ?? markdown)
            e.options = request.live ? ThreadRequest.planChoices : []
        case .approval(let kind, let prompt, let decisions):
            e.kind = .permission
            let what = prompt.isEmpty ? "It waits for a permission (\(kind))." : prompt
            e.question = gone + what
            e.options = request.live ? decisions.map(ThreadRequest.label) : []
        case .question(let questions):
            e.kind = .question
            e.question = gone + (questions.count == 1 ? questions[0].question : questions.map(\.question).joined(separator: "\n"))
            let q = questions.first
            e.options = request.live && questions.count == 1 && q?.multiSelect == false ? q?.options.map(\.label) ?? [] : []
        }
        return e
    }

    /// Whether what floats over the page (a peek, a popover drawn in the window) belongs to the highlight `prefix` starts:
    /// its paragraph and section are drawn over what comes after them.
    func raised(_ prefix: String) -> Bool {
        hovered?.hasPrefix(prefix) == true
    }

    /// Whether a project shows its paragraph: one with something for you starts open, one with nothing folded.
    func isOpen(_ section: BriefPage.Section) -> Bool { section.entries.isEmpty == toggled.contains(section.id) }

    func toggle(_ section: BriefPage.Section) {
        if toggled.contains(section.id) { toggled.remove(section.id) } else { toggled.insert(section.id) }
    }

    /// What the latest rewrite of a project's brief changed, in plain words (its new lines), read once per version.
    func lastChange(_ project: String) -> String? {
        guard let doc = docs[project], doc.version > 0 else { return nil }
        if let kept = changeCache[project], kept.version == doc.version { return kept.text }
        let diff = versions()[project]?.last(where: { $0.version == doc.version })?.diff ?? ""
        let added = diff.split(separator: "\n").filter { $0.hasPrefix("+ now: ") }.map { BriefMarkup.plain(String($0.dropFirst(7))) }
        let text = added.isEmpty ? nil : added.joined(separator: " ")
        changeCache[project] = (doc.version, text)
        return text
    }
    @ObservationIgnored private var changeCache: [String: (version: Int, text: String?)] = [:]

    /// A project's name as the page shows it.
    func projectName(_ project: String) -> String {
        names[project].flatMap { $0.isEmpty ? nil : $0 } ?? BriefPage.fallbackName(project)
    }

    func title(_ t: BriefTarget) -> String {
        if t.thread == BriefDoc.coordinator { return "The project's coordinator" }
        return docs[t.project]?.thread(t.thread)?.title.nonEmpty ?? "Untitled thread"
    }

    func entry(_ t: BriefTarget, store: Store) -> BriefEntry? {
        docs[t.project]?.needsYou.first { $0.target == t }.map { resolved($0, store: store) }
    }

    /// Picks `t` alone (nil: none).
    func focus(_ t: BriefTarget?) {
        let next = t.map { [$0] } ?? []
        if mentioned != next { mentioned = next }
    }

    /// Adds `t` to the threads your words go to, or takes it off.
    func toggleMention(_ t: BriefTarget) {
        if let i = mentioned.firstIndex(of: t) { mentioned.remove(at: i) } else { mentioned.append(t) }
    }

    func unmention(_ t: BriefTarget) { mentioned.removeAll { $0 == t } }

    /// ↑↓ over the entries in page order.
    func move(down: Bool) {
        let all = page().entries.map(\.target)
        guard !all.isEmpty else { return }
        guard let f = focused, let i = all.firstIndex(of: f) else { focus(down ? all.first : all.last); return }
        focus(all[min(max(i + (down ? 1 : -1), 0), all.count - 1)])
    }

    /// Picks option N, or takes it back when it is the one picked; nothing while an answer is under way.
    func pick(_ t: BriefTarget, _ option: Int, store: Store) {
        guard !answering.contains(t), let e = entry(t, store: store), option >= 1, option <= e.options.count else { return }
        focus(t)
        trouble[t] = nil
        picked[t] = picked[t] == option ? nil : option
    }

    // MARK: Acts

    /// Option N answered at once, whatever you had picked (the MCP's `answer`): your pick isn't toggled.
    @discardableResult
    func answer(_ t: BriefTarget, option: Int, store: Store) -> Bool {
        guard !answering.contains(t), let e = entry(t, store: store), option >= 1, option <= e.options.count else { return false }
        trouble[t] = nil
        picked[t] = option
        return confirm(t, store: store)
    }

    /// Return on an entry with an option picked: the answer goes (an answer can't be unsent). One at a time: a second
    /// Return while the first is under way does nothing.
    @discardableResult
    func confirm(_ t: BriefTarget, store: Store) -> Bool {
        guard !answering.contains(t), let n = picked[t], let e = entry(t, store: store), n <= e.options.count else { return false }
        let label = e.options[n - 1]
        if let request = request(e, store: store), request.live {
            picked[t] = nil
            answerRequest(request, entry: e, option: n, words: nil, store: store)
            return true
        }
        guard let card = e.card else {  // a question asked in words: the option's words are your reply
            picked[t] = nil
            return send(label, to: t, store: store)
        }
        picked[t] = nil
        let pills = store.routerCourier
        let shown = names[t.project]
        begin(t) { [weak self] in
            let id = await pills.answer(project: t.project, thread: t.thread, card: card, option: n, label: label, shown: shown)
            await self?.follow(id, t, pills: pills, words: label)
        }
        return true
    }

    /// Your words to the thread: explicit target. A thread whose request T3 can take an answer for gets them as its answer
    /// (see `answerRequest`); a local thread with none gets them as a reply through the Router's dispatcher, as the
    /// composer's reply did.
    @discardableResult
    func send(_ words: String, to t: BriefTarget, store: Store) -> Bool {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !answering.contains(t) else { return false }
        if let e = entry(t, store: store), let request = request(e, store: store), request.live {
            answerRequest(request, entry: e, option: nil, words: text, store: store)
            return true
        }
        if t.project.hasPrefix("local:") {
            guard store.sendToRouter(text, context: RouterContext(replyTo: t)) else {
                trouble[t] = "This session can't be reached from here: answer it in the Claude app."
                return false
            }
            return true
        }
        let pills = store.routerCourier
        let shown = names[t.project]
        let entry = docs[t.project]?.needsYou.contains(where: { $0.target == t }) == true
        begin(t) { [weak self] in
            let to: RouterCourier.Target = t.thread == BriefDoc.coordinator ? .project(t.project) : .thread(project: t.project, thread: t.thread)
            let id = await pills.send(text, to: to, shown: shown)
            await self?.follow(id, t, pills: pills, words: entry ? text : nil)
        }
        return true
    }

    /// Runs an answer, the entry held (`answering`) from now until it settles.
    private func begin(_ t: BriefTarget, _ run: @escaping @MainActor () async -> Void) {
        answering.insert(t)
        work[t] = Task { [weak self] in
            await run()
            self?.answering.remove(t)
            self?.work[t] = nil
        }
    }

    /// Waits for every answer under way (tests).
    func settled() async {
        while let (_, task) = work.first { await task.value }
    }

    /// Follows an answer handed over until it is delivered or fails: delivered, its line goes in the drawer (`words`).
    private func follow(_ id: Int, _ t: BriefTarget, pills: RouterCourierPills, words: String?) async {
        guard id > 0 else { trouble[t] = "The answer couldn't be handed over."; return }
        sending[t] = id
        let done = await pills.next(id) { [.delivered, .deliveredLate, .failed, .refused].contains($0) }
        guard sending[t] == id else { return }
        sending[t] = nil
        if let done, done.state == .failed || done.state == .refused {
            trouble[t] = done.cause ?? "The answer didn't go."
        } else if done != nil, let words {
            record(t, words)
        }
    }

    /// A request of several questions, one choice each (a multiple choice's several): every answer goes at once, as T3's own
    /// form sends them, never a thread left half-answered. Keyed by question id.
    @discardableResult
    func answerAll(_ t: BriefTarget, _ answers: [String: [String]], store: Store) -> Bool {
        guard !answering.contains(t), let e = entry(t, store: store), let request = request(e, store: store), request.live,
              case .question(let questions) = request.body,
              questions.allSatisfy({ !(answers[$0.id] ?? []).isEmpty }) else { return false }
        trouble[t] = nil
        let snapshot = RequestSnapshot(target: t, request: request)
        var typed: [String: T3Answer] = [:]
        for q in questions {
            let picked = answers[q.id] ?? []
            typed[q.id] = q.multiSelect ? .many(picked) : .one(picked[0])
        }
        let shown = questions.compactMap { answers[$0.id]?.joined(separator: ", ") }.joined(separator: "; ")
        let sent = typed
        begin(t) { [weak self, weak store] in
            guard let store else { return }
            switch await store.answerQuestion(request, sent, target: t, snapshot: snapshot) {
            case .success: self?.record(t, shown)
            case .failure(let error): self?.trouble[t] = (error as? LocalizedError)?.errorDescription ?? "The answer wasn't sent."
            }
        }
        return true
    }

    /// A request T3 holds: an option picked (a question's, a permission's decision, a plan's yes), or your words. Words to a
    /// question go to Jev to pick an option id, else (a question that takes a custom answer) as they are; to a permission,
    /// they decline it with your words as the reason, never a yes; to a plan, Jev's yes or no (a no sends them as a message).
    /// Its line goes in the drawer once sent.
    private func answerRequest(_ request: ThreadRequest, entry e: BriefEntry, option: Int?, words: String?, store: Store) {
        let t = e.target
        let snapshot = RequestSnapshot(target: t, request: request)
        let shown = option.map { e.options.indices.contains($0 - 1) ? e.options[$0 - 1] : "" } ?? words ?? ""
        begin(t) { [weak self, weak store] in
            guard let store else { return }
            let result: Result<Void, Error>
            switch request.body {
            case .plan:
                if let option, ThreadRequest.planModes.indices.contains(option - 1) {
                    result = await store.implementPlan(request, mode: ThreadRequest.planModes[option - 1], target: t, snapshot: snapshot)
                } else {
                    let text = words ?? ""
                    // Never a yes unless Jev finds one; otherwise your words go back as they are.
                    let read = await RouterDispatcher.planDecision(request, message: text, ask: store.jevAsker(.routing))
                    if read?.approve == true {
                        result = await store.implementPlan(request, mode: .approvalRequired, target: t, snapshot: snapshot)
                    } else {
                        result = await store.sendBackPlan(request, words: text, target: t, snapshot: snapshot)
                    }
                }
            case .approval(_, _, let decisions):
                if let option, decisions.indices.contains(option - 1) {
                    result = await store.answerPermission(request, decisions[option - 1], target: t, snapshot: snapshot)
                } else {
                    result = await store.answerPermission(request, .decline, feedback: words ?? "", target: t, snapshot: snapshot)
                }
            case .question(let questions):
                var answers: [String: T3Answer]
                if let option, questions.count == 1, let q = questions.first, option <= q.options.count {
                    answers = [q.id: .one(q.options[option - 1].value)]
                } else if let read = await RouterDispatcher.askFormAnswers(request, message: words ?? "", ask: store.jevAsker(.routing)) {
                    answers = read
                } else if let text = words, questions.count == 1, questions[0].allowCustomAnswer, !questions[0].multiSelect {
                    answers = [questions[0].id: .one(text)]
                } else {
                    self?.trouble[t] = "Couldn't read an answer to every question: pick an option, or answer in T3."
                    return
                }
                result = await store.answerQuestion(request, answers, target: t, snapshot: snapshot)
            }
            switch result {
            case .success: self?.record(t, shown)
            case .failure(let error): self?.trouble[t] = (error as? LocalizedError)?.errorDescription ?? "The answer wasn't sent."
            }
        }
    }

    /// Opens the thread: a cloud thread in a new active tab, a local one in T3 Code. Whether there was one to open.
    @discardableResult
    func open(_ t: BriefTarget, store: Store) -> Bool {
        if let session = desktopSession(t, store: store) { return store.openThread(session) }
        let page = "https://claude.ai/code/project/\(t.project)" + (t.thread == BriefDoc.coordinator ? "" : "?thread=\(t.thread)")
        guard !t.project.hasPrefix("local:"), let url = URL(string: page)
        else { return false }
        guard !UnderTest.refuses("Chrome") else { return true }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    /// Marks the entry read: a change of Fjord's, with its Revert in the drawer.
    func markRead(_ t: BriefTarget, store: Store) {
        guard let e = docs[t.project]?.needsYou.first(where: { $0.target == t }) else { return }
        store.briefAct(.read, on: t, mark: BriefPage.entryKey(e), title: title(t))
        leave(t)
    }

    /// Archives the thread: it leaves the brief until Revert.
    func archive(_ t: BriefTarget, store: Store) {
        store.briefAct(.archive, on: t, mark: t.key, title: title(t))
        leave(t)
    }

    /// Sets or clears a mark, and keeps it in briefs.db.
    func setMark(_ act: BriefAction, _ key: String, on: Bool) {
        let kind: BriefMarks.Kind = act == .read ? .read : .archived
        set(kind, key, on: on)
    }

    private func set(_ kind: BriefMarks.Kind, _ key: String, on: Bool) {
        guard marks[kind].contains(key) != on else { return }
        if on { marks[kind].insert(key) } else { marks[kind].remove(key) }
        engine?.setMark(kind, key, on: on)
        if kind == .read || kind == .archived { recount() }
    }

    /// The entry your words went to left the brief: they go nowhere now (never on to another entry unasked).
    private func leave(_ t: BriefTarget) {
        picked[t] = nil
        unmention(t)
    }

    func record(_ t: BriefTarget, _ words: String) {
        answers.insert(BriefAnswer(target: t, title: title(t), words: words, at: clock()), at: 0)
        if answers.count > 100 { answers.removeLast(answers.count - 100) }
    }

    /// The page was shown: what it told of finished threads is told once it is left.
    func shown(_ page: BriefPage) {
        for s in page.sections { for t in s.finished { shownFinishes.insert(BriefPage.finishKey(t)) } }
    }

    func left() {
        guard !shownFinishes.isSubset(of: told) else { return }
        for key in shownFinishes { set(.told, key, on: true) }
        shownFinishes = []
    }

    // MARK: Keys

    /// A key of the brief's, while an entry is focused and the composer is empty. Whether it did something: a key that
    /// does nothing here is left to what comes next.
    func key(_ action: BriefKeys.Action, model: RouterModel, store: Store) -> Bool {
        if case .move(let down) = action {
            move(down: down)
            return true
        }
        guard let f = hoveredTarget ?? focused else { return false }
        switch action {
        case .move:
            return true
        case .back:
            if picked[f] != nil { picked[f] = nil } else if hoveredTarget != nil { unhover() } else { focus(nil) }
        case .pick(let n):
            guard !answering.contains(f), let e = entry(f, store: store), n <= e.options.count else { return false }
            pick(f, n, store: store)
        case .confirm:
            if picked[f] != nil {
                if !confirm(f, store: store), !answering.contains(f) { trouble[f] = "That answer can't go from here: answer it in the thread." }
            } else {
                model.reply()
            }
        case .open:
            return open(f, store: store)
        case .archive:
            archive(f, store: store)
        case .read:
            guard docs[f.project]?.needsYou.contains(where: { $0.target == f }) == true else { return false }
            markRead(f, store: store)
        }
        return true
    }
}

extension Store {
    /// An act on a brief entry, done at once and logged as a change of Fjord's that Revert sets back.
    func briefAct(_ act: BriefAction, on t: BriefTarget, mark: String, title: String, now: Date = Date()) {
        guard !routerBriefs.marks[act == .read ? .read : .archived].contains(mark) else { return }
        routerBriefs.setMark(act, mark, on: true)
        let change = FjordChange(date: now, title: "\(act.label) \(title)",
                                 patch: .briefAction(project: t.project, thread: t.thread, act: act, mark: mark))
        var state = router
        state.changes.append(change)
        state.pruneChanges()
        router = state
        logChange(change)
    }
}
