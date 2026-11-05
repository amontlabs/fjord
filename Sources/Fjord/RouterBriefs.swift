import AppKit
import Foundation
import Observation

// The briefs in the app (docs/design/router-watch-and-briefs.md 3.5, 4 and 5): the engine's documents (or a demo's), the
// page they make (`BriefPage`, ordered as in 4), what you focus and pick, and the acts: an option answered by Return, your
// words sent to the thread, Open, mark read, archive. A local thread's form is answered through the hook (on this Mac or a
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

    var lead: [String] = []
    var sections: [Section] = []
    /// The names of the sections past the cap.
    var folded: [String] = []
    /// Entries not marked read, every project: the bar's mark.
    var needsYou = 0

    static func entryKey(_ e: BriefEntry) -> String { "\(e.project)/\(e.thread)/\(Int(e.since))" }
    static func finishKey(_ t: BriefThread) -> String { "\(t.id)@\(Int(t.age))" }

    static func staleSince(_ watch: String?) -> Double? {
        guard let w = watch, w.hasPrefix("stale:") else { return nil }
        return Double(w.dropFirst(6))
    }

    static func make(docs: [String: BriefDoc], names: [String: String], lead: [String], read: Set<String>, told: Set<String>,
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
/// 1 to 9 pick an option by the top row's physical key codes (the same keys on AZERTY, where the unshifted characters differ),
/// O open, A archive, R mark read, Esc back.
enum BriefKeys {
    enum Action: Equatable { case pick(Int), confirm, open, archive, read, back, move(down: Bool) }

    /// `kVK_ANSI_1` … `kVK_ANSI_9`.
    static let digits: [Int] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static func action(code: Int, characters: String?, flags: NSEvent.ModifierFlags, focused: Bool, composerEmpty: Bool) -> Action? {
        guard focused, composerEmpty, flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        if let i = digits.firstIndex(of: code) { return .pick(i + 1) }
        switch code {
        case 36, 76: return flags.contains(.shift) ? nil : .confirm
        case 53: return .back
        case 125: return .move(down: true)
        case 126: return .move(down: false)
        default: break
        }
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
    private(set) var engine: RouterBriefEngine?
    /// A demo's or a shot's documents, when no engine runs.
    var demoDocs: [String: BriefDoc] = [:]
    var demoGeneral = GeneralBrief()
    var demoVersions: [String: [BriefVersion]] = [:]
    var names: [String: String] = [:]
    /// A local thread's session key on the Board, and that key's Claude Code session id.
    var sessions: [String: String] = [:]
    var clis: [String: String] = [:]

    var focused: BriefTarget?
    /// Option N picked on an entry, shown live until Return sends it.
    var picked: [BriefTarget: Int] = [:]
    /// Sections open to the full document.
    var expanded: Set<String> = []
    var drawerOpen = false
    /// Why an answer didn't go (refused, failed), on its entry until it changes.
    var trouble: [BriefTarget: String] = [:]
    /// Answers handed over, until the entry leaves on proof.
    var sending: [BriefTarget: Int] = [:]
    /// Entries marked read (`BriefPage.entryKey`), threads archived (`BriefTarget.key`), and finished threads told (their
    /// section was shown and then left), as briefs.db keeps them.
    private(set) var marks = BriefMarks()
    var read: Set<String> { marks.read }
    var archived: Set<String> { marks.archived }
    var told: Set<String> { marks.told }
    @ObservationIgnored var shownFinishes: Set<String> = []
    private(set) var answers: [BriefAnswer] = []
    /// The page's clock (a shot pins it).
    @ObservationIgnored var clock: () -> Date = Date.init

    @ObservationIgnored let link = RouterBriefLink()

    var docs: [String: BriefDoc] { engine?.docs ?? demoDocs }
    var general: GeneralBrief { engine?.general ?? demoGeneral }

    func page() -> BriefPage {
        BriefPage.make(docs: docs, names: names, lead: general.lead, read: read, told: told, archived: archived,
                       now: clock().timeIntervalSince1970)
    }

    var untoldNeedsYou: Int { page().needsYou }

    // MARK: Start

    /// Starts the engine on the link's host: `briefs.db` next to router.db, the host's changes driving it.
    func start(store: Store) {
        guard engine == nil, let host = store.routerCourierLink.host else { return }
        let path = URL(fileURLWithPath: host.dbPath).deletingLastPathComponent().appendingPathComponent("briefs.db").path
        guard let db = try? SQLiteBriefStore(path: path) else { return }
        let engine = RouterBriefEngine(source: CourierBriefSource(host: host), store: db, model: RouterBriefer.haiku(store: store),
                                       style: { [weak store] in store?.routerStyle ?? RouterStyle.defaultText })
        self.engine = engine
        marks = engine.marks()
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

    // MARK: Entries

    /// A local thread's Claude Code session id (`ClaudeSession.cliID`).
    func cli(_ t: BriefTarget, store: Store) -> String? {
        if let key = sessions[t.thread], let cli = clis[key] { return cli }
        return store.claudeSessions[t.thread]?.cliID
    }

    /// A local thread's session in the Claude app (a remote computer's runs there as a Desktop SSH session).
    func desktopSession(_ t: BriefTarget, store: Store) -> String? {
        if store.claudeSessions[t.thread] != nil { return t.thread }
        guard let cli = cli(t, store: store) else { return nil }
        return store.claudeSessions.first { $0.value.cliID == cli }?.key
    }

    /// The form Fjord's hook holds on this Mac for a local thread's session.
    func localForm(_ t: BriefTarget, store: Store) -> PendingForm? {
        cli(t, store: store).flatMap { store.pendingForms[$0] }
    }

    /// The form held for a local entry's session, on this Mac or on a remote computer.
    func form(_ e: BriefEntry, store: Store) -> PendingForm? {
        guard e.source == .local else { return nil }
        return store.heldForm(e.target)
    }

    /// An entry as acted on: a local one with its form (`FormSnapshot`), the form's question and options.
    func resolved(_ e: BriefEntry, store: Store) -> BriefEntry {
        guard let form = form(e, store: store) else { return e }
        var e = e
        e.form = FormSnapshot(target: e.target, form: form)
        if form.isPlan {
            e.kind = .plan
            e.question = e.question ?? "Approve the plan?"
            e.options = ["Approve", "Keep planning"]
        } else if let q = form.questions.first {
            e.kind = .question
            e.question = form.questions.count == 1 ? q.question : form.questions.map(\.question).joined(separator: "\n")
            e.options = form.questions.count == 1 && !q.multiSelect ? q.options.map(\.label) : []
        }
        return e
    }

    func title(_ t: BriefTarget) -> String {
        docs[t.project]?.thread(t.thread)?.title.nonEmpty ?? "Untitled thread"
    }

    func entry(_ t: BriefTarget, store: Store) -> BriefEntry? {
        docs[t.project]?.needsYou.first { $0.target == t }.map { resolved($0, store: store) }
    }

    func focus(_ t: BriefTarget?) {
        if focused != t { focused = t }
    }

    /// ↑↓ over the entries in page order.
    func move(down: Bool) {
        let all = page().entries.map(\.target)
        guard !all.isEmpty else { return }
        guard let f = focused, let i = all.firstIndex(of: f) else { focus(down ? all.first : all.last); return }
        focus(all[min(max(i + (down ? 1 : -1), 0), all.count - 1)])
    }

    func pick(_ t: BriefTarget, _ option: Int, store: Store) {
        guard let e = entry(t, store: store), option >= 1, option <= e.options.count else { return }
        focus(t)
        trouble[t] = nil
        picked[t] = picked[t] == option ? nil : option
    }

    // MARK: Acts

    /// Return on an entry with an option picked: the answer goes (an answer can't be unsent).
    @discardableResult
    func confirm(_ t: BriefTarget, store: Store) -> Bool {
        guard let n = picked[t], let e = entry(t, store: store), n <= e.options.count else { return false }
        let label = e.options[n - 1]
        picked[t] = nil
        if let form = form(e, store: store) {
            answerForm(form, entry: e, option: n, words: nil, store: store)
        } else if let card = e.card {
            let pills = store.routerCourier
            let shown = names[t.project]
            Task { [weak self] in
                let id = await pills.answer(project: t.project, thread: t.thread, card: card, option: n, label: label, shown: shown)
                self?.follow(id, t, pills: pills)
            }
        } else {
            return false
        }
        record(t, label)
        return true
    }

    /// Your words to the entry's thread: explicit target, no model. A local form takes them through the hook.
    @discardableResult
    func send(_ words: String, to t: BriefTarget, store: Store) -> Bool {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let e = entry(t, store: store), let form = form(e, store: store) {
            answerForm(form, entry: e, option: nil, words: text, store: store)
            record(t, text)
            return true
        }
        guard !t.project.hasPrefix("local:") else {
            trouble[t] = "This session runs only on this Mac: answer it in the Claude app."
            return false
        }
        let pills = store.routerCourier
        let shown = names[t.project]
        Task { await pills.send(text, to: .thread(project: t.project, thread: t.thread), shown: shown) }
        if docs[t.project]?.needsYou.contains(where: { $0.target == t }) == true { record(t, text) }
        return true
    }

    private func follow(_ id: Int, _ t: BriefTarget, pills: RouterCourierPills) {
        guard id > 0 else { trouble[t] = "The answer couldn't be handed over."; return }
        sending[t] = id
        Task { [weak self] in
            let done = await pills.next(id) { [.delivered, .deliveredLate, .failed, .refused].contains($0) }
            guard let self, self.sending[t] == id else { return }
            self.sending[t] = nil
            if let done, done.state == .failed || done.state == .refused { self.trouble[t] = done.cause ?? "The answer didn't go." }
        }
    }

    /// A local form: an option picked (a plan's first approves), or your words read by Jev, written for the hook (on this Mac
    /// or the remote computer that holds it).
    private func answerForm(_ form: PendingForm, entry e: BriefEntry, option: Int?, words: String?, store: Store) {
        let t = e.target
        let snapshot = FormSnapshot(target: t, form: form)
        Task { [weak self, weak store] in
            guard let store else { return }
            let result: Result<Void, Error>
            if form.isPlan {
                var decision: PendingForm.PlanDecision
                if let option { decision = .init(approve: option == 1) } else {
                    guard let read = await RouterDispatcher.planDecision(form, message: words ?? "", ask: store.jevAsker(.routing)) else {
                        self?.trouble[t] = "Couldn't tell whether that approves the plan: pick Approve or Keep planning."
                        return
                    }
                    decision = read
                }
                result = await store.answerPlan(form, decision, target: t, snapshot: snapshot)
            } else {
                var answers: [String: String]
                if let option, let q = form.questions.first, option <= q.options.count {
                    answers = [q.question: q.options[option - 1].label]
                } else if let read = await RouterDispatcher.askFormAnswers(form, message: words ?? "", ask: store.jevAsker(.routing)) {
                    answers = read
                } else {
                    self?.trouble[t] = "Couldn't read an answer to every question: pick an option, or answer in the Claude app."
                    return
                }
                result = await store.answerForm(form, answers, target: t, snapshot: snapshot)
            }
            if case .failure(let error) = result {
                self?.trouble[t] = (error as? LocalizedError)?.errorDescription ?? "The answer wasn't written."
            }
        }
    }

    /// Opens the thread: a cloud thread in a new active tab, a local one in the Claude app.
    func open(_ t: BriefTarget, store: Store) {
        if let session = desktopSession(t, store: store) {
            Claude.open(session)
            return
        }
        guard !t.project.hasPrefix("local:"), !UnderTest.refuses("Chrome"),
              let url = URL(string: "https://claude.ai/code/project/\(t.project)?thread=\(t.thread)") else { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Marks the entry read: a change of Fjord's, with its Revert in the drawer.
    func markRead(_ t: BriefTarget, store: Store) {
        guard let e = docs[t.project]?.needsYou.first(where: { $0.target == t }) else { return }
        store.briefAct(.read, on: t, mark: BriefPage.entryKey(e), title: title(t))
        advanceFocus(from: t)
    }

    /// Archives the thread: it leaves the brief until Revert.
    func archive(_ t: BriefTarget, store: Store) {
        store.briefAct(.archive, on: t, mark: t.key, title: title(t))
        advanceFocus(from: t)
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
    }

    private func advanceFocus(from t: BriefTarget) {
        guard focused == t else { return }
        focus(page().entries.first?.target)
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

    /// A key of the brief's, while an entry is focused and the composer is empty.
    func key(_ action: BriefKeys.Action, model: RouterModel, store: Store) -> Bool {
        switch action {
        case .move(let down):
            move(down: down)
        case .back:
            if picked[focused!] != nil { picked[focused!] = nil } else { focus(nil) }
        case .pick(let n):
            guard let f = focused, let e = entry(f, store: store), n <= e.options.count else { return false }
            pick(f, n, store: store)
        case .confirm:
            guard let f = focused else { return false }
            if picked[f] != nil { confirm(f, store: store) } else { model.reply() }
        case .open:
            open(focused!, store: store)
        case .archive:
            archive(focused!, store: store)
        case .read:
            markRead(focused!, store: store)
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
