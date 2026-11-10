import AppKit
import Foundation
import Observation

// The briefs in the app (docs/design/router-watch-and-briefs.md 3.5, 4 and 5): the engine's documents (or a demo's), the
// page they make (`BriefPage`, ordered as in 4), what you focus and pick, and the acts: an option answered by Return, your
// words sent to the thread, Open, mark read, archive. A waiting request is answered through T3. The facts are T3's threads
// (T3BriefSource.swift) and Fjord's own log of what happened (BriefLog.swift). Mark read, archive, snooze, settle, rename and tags are T3's (ThreadActs.swift), each a change with a Revert
// (`FjordChange.briefAction`); briefs.db keeps only which finished threads were told and which banners were posted.

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

    /// A project T3 has no name for here: its id.
    static func fallbackName(_ id: String) -> String { id }

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
    @ObservationIgnored private var departing: Task<Void, Never>?

    /// The pointer on a highlight or its panel, or off it: it shows at once, and goes a moment after the pointer leaves
    /// both, so crossing from one to the other keeps it.
    func hover(_ key: String, _ t: BriefTarget, inside: Bool) {
        departing?.cancel()
        pointerIn = inside
        if inside {
            if hovered != key { hovered = key; hoveredTarget = t }
            return
        }
        guard !holding, hovered == key else { return }
        departing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.hoverGrace))
            guard let self, !Task.isCancelled, !self.pointerIn, !self.holding, self.hovered == key else { return }
            self.unhover()
        }
    }

    static let hoverGrace = 220

    func unhover() {
        departing?.cancel()
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
    /// Finished threads told (their section was shown and then left) and entries a banner was posted for, as briefs.db keeps
    /// them. Read state, archive, snooze and settle are T3's.
    private(set) var marks = BriefMarks()
    var told: Set<String> { marks.told }
    /// Threads whose entry was marked read here, with the activity they had then: hidden until T3's own `unseen` says so (or
    /// the thread moves on). A thread id the shell doesn't hold (a demo) stays hidden.
    private(set) var visited: [String: Date] = [:]
    /// Threads archived, snoozed or settled here: hidden until the board no longer lists them, or until Revert.
    private(set) var awayThreads: Set<String> = []
    /// The entries (`BriefPage.entryKey`) that are read: T3's `thread.visit` (this app's, T3's or the phone's), or marked here.
    var read: Set<String> {
        var out = Set<String>()
        for doc in docs.values {
            for e in doc.needsYou where isRead(e) { out.insert(BriefPage.entryKey(e)) }
        }
        return out
    }
    /// The brief targets (`BriefTarget.key`) acted away.
    var archived: Set<String> {
        var out = Set<String>()
        for (project, doc) in docs {
            let ids = Set(doc.threads.map(\.id)).union(doc.needsYou.map(\.thread))
            for id in awayThreads where ids.contains(id) { out.insert(BriefTarget(project: project, thread: id).key) }
        }
        return out
    }

    private func isRead(_ e: BriefEntry) -> Bool {
        let thread = store?.threads[e.thread]
        if let seen = visited[e.thread], seen == (thread?.lastActivity ?? seen) { return true }
        guard engine != nil, let thread else { return false }
        return !thread.unseen
    }

    /// An act applied (or taken back) here, shown at once before T3 has said so.
    func holdAct(_ act: BriefAction, _ t: BriefTarget, detail: String, on: Bool, store: Store) {
        switch act {
        case .read: visited[t.thread] = on ? (store.threads[t.thread]?.lastActivity ?? Date()) : nil
        case .archive, .snooze, .settle: if on { awayThreads.insert(t.thread) } else { awayThreads.remove(t.thread) }
        case .rename, .tag: break
        }
        recount()
    }
    @ObservationIgnored var shownFinishes: Set<String> = []
    private(set) var answers: [BriefAnswer] = []
    /// Entries not marked read, every project (the bar's mark): counted when the documents or the marks change.
    private(set) var untoldNeedsYou = 0
    /// The page's clock (a shot pins it).
    @ObservationIgnored var clock: () -> Date = Date.init

    /// Fjord's log of what happened, what it last saw of each thread, and the boards the engine was last told of.
    @ObservationIgnored private var log: BriefLog?
    @ObservationIgnored private var seen: [String: BriefThreadFacts] = [:]
    @ObservationIgnored private var lastBoards: [String: BriefBoard] = [:]
    @ObservationIgnored private var engineStarted = false
    /// T3 stopped answering at this time (`watch: "stale:"`).
    @ObservationIgnored private var downSince: Double?
    /// When each thread was last seen working (the banners' freshness for a finish its background work made late).
    @ObservationIgnored private var sawRunning: [String: Date] = [:]

    /// The engine's documents of the projects T3 lists now (briefs.db may hold others from before; they are purged, and
    /// never shown). A demo's documents are shown as they are.
    var docs: [String: BriefDoc] {
        guard let engine else { return demoDocs }
        guard let listing = t3Listing() else { return [:] }
        return engine.docs.filter { listing.projects.contains($0.key) }
    }

    /// The lead, unless it speaks of a project T3 doesn't list (it is rewritten once the purge has run).
    var general: GeneralBrief {
        guard let engine else { return demoGeneral }
        guard let listing = t3Listing() else { return GeneralBrief() }
        let lead = engine.general
        return lead.tagged.allSatisfy({ id in BriefTarget(key: id).map { listing.projects.contains($0.project) } ?? false }) ? lead : GeneralBrief()
    }

    /// T3's projects and threads now, once it has answered (its snapshot or its `synchronized`, whichever order they and the
    /// engine arrive in) with something in it (nil before: an empty T3 is not a reason to drop anything).
    func t3Listing() -> (projects: Set<String>, threads: Set<String>)? {
        guard let store, store.t3.store.shell.answered else { return nil }
        let projects = Set(store.t3.store.shell.projects.keys).union(store.threads.values.map(\.projectID))
        return projects.isEmpty ? nil : (projects, Set(store.threads.keys))
    }

    /// The listing, for what changes briefs.db: also only while the link is up (what a dropped link last said is shown, not
    /// acted on). A store with no link behind it (demo, shots, tests) has only its shell to go by.
    private func liveListing() -> (projects: Set<String>, threads: Set<String>)? {
        guard let store, !store.t3.store.hasClient || store.t3.store.connection == .connected else { return nil }
        return t3Listing()
    }

    /// Rewrites every current project's brief and the lead now (⌘R on the Router page, the menu, the palette).
    /// Every brief written again, once the end of each thread that stopped in the last day is read (so the boards carry
    /// their last replies).
    func rewriteAll() {
        guard let engine, let listing = liveListing(), let store else { return }
        let cutoff = clock().addingTimeInterval(-BriefLog.recentWindow)
        let recent = store.threads.values.filter { !$0.running && ($0.lastRunEndedAt ?? $0.activityAt) >= cutoff }.map(\.id)
        Task { [weak self, weak store] in
            guard let store else { return }
            await withTaskGroup(of: Void.self) { group in
                for id in recent { group.addTask { @MainActor in _ = await store.readEnd(id) } }
            }
            guard let self else { return }
            self.threadsChanged(store: store)
            engine.rewrite(projects: listing.projects)
        }
    }
    var rewriting: Bool { engine?.rewriting ?? false }
    var rewriteProgress: (done: Int, total: Int)? { engine?.rewriteProgress }
    /// When the facts were last checked (a call landed, or the trigger key showed nothing changed).
    var lastChecked: Double? { engine?.lastChecked }

    /// What briefs.db holds of projects and threads T3 doesn't list goes, once the listing is known and when it changes.
    @ObservationIgnored private var purged: (projects: Set<String>, threads: Set<String>)?
    private func purgeUnlisted() {
        guard let engine, let listing = liveListing(), purged?.projects != listing.projects || purged?.threads != listing.threads else { return }
        purged = listing
        log?.purge(keepingProjects: listing.projects, threads: listing.threads)
        seen = seen.filter { listing.threads.contains($0.key) }
        engine.purge(projects: listing.projects, threads: listing.threads)
        marks = engine.marks()
    }

    func page() -> BriefPage {
        BriefPage.make(docs: docs, names: names, lead: general, read: read, told: told, archived: archived,
                       now: clock().timeIntervalSince1970)
    }

    // MARK: Start

    /// Creates the engine with the Router on: `briefs.db` in Fjord's Application Support. It starts with the first word from T3
    /// (`threadsChanged`, or `connectionChanged` when T3 gives none), when the threads it reads exist.
    func start(store: Store) {
        guard engine == nil, store.routerOn, !Store.isDemo, let paths = store.routerFiles else { return }
        try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        let path = paths.support.appendingPathComponent("briefs.db").path
        guard let db = try? SQLiteBriefStore(path: path), let log = try? BriefLog(path: path) else { return }
        self.log = log
        seen = log.seen()
        let source = T3BriefSource(log: log, boards: { [weak self] in self?.currentBoards() ?? [:] })
        let engine = RouterBriefEngine(source: source, store: db, model: RouterBriefer.haiku(store: store),
                                       style: { [weak store] in store?.routerStyle ?? RouterStyle.defaultText })
        use(engine)
        if !store.threads.isEmpty { threadsChanged(store: store) }
    }

    /// Runs on `engine` (and tests run on one of their own).
    func use(_ engine: RouterBriefEngine, log: BriefLog? = nil) {
        self.engine = engine
        if let log { self.log = log; seen = log.seen() }
        marks = engine.marks()
        engine.onDocs = { [weak self] in self?.docsChanged() }
    }

    /// The Router switched on or off: the engine runs only while it is on (no model call with it off).
    func switched(store: Store) {
        if store.routerOn {
            if let engine { engine.start(); engineStarted = true } else { start(store: store) }
        } else {
            engine?.stop()
        }
    }

    // MARK: Feeding from T3

    /// The boards from the threads and requests now.
    private func currentBoards() -> [String: BriefBoard] {
        guard let store else { return [:] }
        return T3BriefSource.boards(threads: Array(store.threads.values), requests: store.requests, unreachableSince: downSince,
                                    ends: Self.ends(store), now: clock())
    }

    /// The agent's last reply in each thread whose end is known now (T3's shell doesn't carry it).
    private static func ends(_ store: Store) -> [String: String] {
        store.threads.keys.reduce(into: [:]) { out, id in
            if let reply = store.knownEnd(id)?.reply, !reply.isEmpty { out[id] = reply }
        }
    }

    /// A project's name: T3's title, else its folder's.
    private static func name(_ project: String, store: Store, folder: String) -> String {
        if let title = store.t3.store.shell.projects[project]?.title, !title.isEmpty { return title }
        return store.folderName(folder)
    }

    /// The shell changed: what happened to each thread since the log last saw it is logged, project names follow, and the
    /// engine hears of the projects with new items (a call) or another board (the deterministic part only).
    func threadsChanged(store: Store) {
        guard let engine, let log else { return }
        purgeUnlisted()
        let now = clock()
        let boards = T3BriefSource.boards(threads: Array(store.threads.values), requests: store.requests, unreachableSince: downSince,
                                          ends: Self.ends(store), now: now)
        var named = names
        for t in store.threads.values where boards[t.projectID] != nil { named[t.projectID] = Self.name(t.projectID, store: store, folder: t.folderKey) }
        // Projects with no thread on a board keep a brief too: T3's title, never their id.
        for p in store.t3.store.shell.projects.values where !p.title.isEmpty { named[p.id] = p.title }
        if named != names { names = named }
        var itemProjects = Set<String>()
        for t in store.threads.values {
            let facts = BriefThreadFacts(t)
            let old = seen[t.id]
            guard facts != old else { continue }
            seen[t.id] = facts
            log.setSeen(t.id, facts)
            // T3's shell carries no message text: a finish or a send is logged once the thread's end is read, with its words.
            if BriefLog.needsRead(old: old, thread: t), store.knownEnd(t.id) == nil, store.t3.store.hasClient {
                Task { [weak self, weak store] in
                    guard let store else { return }
                    let reads = await store.readEnd(t.id)
                    guard let self, let log = self.log else { return }
                    var appended = false
                    for item in BriefLog.events(old: old, thread: t, now: now.timeIntervalSince1970, reads: reads)
                    where log.append(item, project: t.projectID) { appended = true }
                    if appended { self.engine?.boardChanged(t.projectID) }
                }
                continue
            }
            for item in BriefLog.events(old: old, thread: t, now: now.timeIntervalSince1970, reads: store.knownEnd(t.id))
            where log.append(item, project: t.projectID) {
                itemProjects.insert(t.projectID)
            }
        }
        // What T3 has confirmed is no longer held here.
        let listed = Set(boards.values.flatMap { $0.threads.map(\.id) })
        let stillLeaving = awayThreads.filter { listed.contains($0) }
        if stillLeaving != awayThreads { awayThreads = stillLeaving }
        let stillVisited = visited.filter { id, at in store.threads[id].map { $0.lastActivity == at && $0.unseen } ?? false }
        if stillVisited != visited { visited = stillVisited }
        let before = lastBoards
        lastBoards = boards
        defer { recount(); announce(store: store) }
        guard engineStarted else { engineStarted = true; engine.start(); return }
        let moved = Set(boards.keys).union(before.keys).filter { boards[$0] != before[$0] }
        for p in itemProjects.union(moved).sorted() { engine.boardChanged(p) }
    }

    /// A thread's projection showed a request or plan that waits on you: logged once (by its id), with its words and options.
    func requestAppeared(_ request: ThreadRequest, store: Store) {
        guard let log, let thread = store.threads[request.threadID] else { return }
        if log.append(BriefLog.request(request, title: thread.title, at: clock().timeIntervalSince1970), project: thread.projectID) {
            engine?.boardChanged(thread.projectID)
        }
        announce(store: store)
    }

    /// T3 answered, or stopped answering: the boards say since when, and the briefs start at the first word either way.
    func connectionChanged(_ state: T3ConnectionState, store: Store) {
        switch state {
        case .connected: downSince = nil
        case .connecting: return
        default: if downSince == nil { downSince = clock().timeIntervalSince1970 }
        }
        if engine != nil, !engineStarted, state != .connected { engineStarted = true; engine?.start() }
        threadsChanged(store: store)
    }

    // MARK: Count and banners

    /// The documents changed: the count again.
    private func docsChanged() {
        recount()
    }

    private func recount() {
        let count = page().needsYou
        if untoldNeedsYou != count { untoldNeedsYou = count }
    }

    /// What the threads show now that no banner has told yet (needs you, finished, failed, usage limit), each told once by the
    /// request, plan or run it is about; more than `notifyEach` at once, one banner says how many. It runs on the shell's own
    /// change, with no model between.
    func announce(store: Store) {
        let now = clock()
        // When each thread was last seen working: the finish of one whose background work ran past its run is fresh by this,
        // though the run's end stamp has gone past the window. Gone threads drop out; a thread neither working nor finished
        // (idle, waiting on you) keeps no claim.
        sawRunning = sawRunning.filter { store.threads[$0.key] != nil }
        for t in store.threads.values {
            if t.running { sawRunning[t.id] = now } else if !t.finished { sawRunning[t.id] = nil }
        }
        var fresh: [ThreadNotice] = []
        for t in store.threads.values.sorted(by: { ($0.lastActivity, $0.id) < ($1.lastActivity, $1.id) }) where t.unseen {
            for n in ThreadNotices.notices(t, request: store.requests[t.id], now: now, sawRunning: sawRunning[t.id])
            where !marks.notified.contains(n.key) {
                fresh.append(n)
            }
        }
        guard !fresh.isEmpty else { return }
        for n in fresh { set(.notified, n.key, on: true) }
        func name(_ n: ThreadNotice) -> String { names[n.project].flatMap { $0.isEmpty ? nil : $0 } ?? BriefPage.fallbackName(n.project) }
        if fresh.count > Self.notifyEach {
            store.notifyRouter(id: Self.notificationPrefix + BriefTarget(project: fresh[0].project, thread: fresh[0].thread).key,
                               title: "\(fresh.count) threads have news", subtitle: Set(fresh.map(name)).sorted().joined(separator: ", "), body: "")
            return
        }
        for n in fresh {
            store.notifyRouter(id: Self.notificationPrefix + BriefTarget(project: n.project, thread: n.thread).key,
                               title: "\(name(n)) · \(n.heading)", subtitle: n.title, body: n.body)
        }
    }

    // MARK: Entries

    /// The T3 thread id a brief target stands for.
    func threadID(_ t: BriefTarget) -> String { t.thread }

    /// The T3 thread a brief entry is about, when Fjord lists it.
    func desktopSession(_ t: BriefTarget, store: Store) -> String? {
        store.threads[threadID(t)] != nil ? threadID(t) : nil
    }

    /// What T3 says an entry's thread waits on you for.
    func request(_ e: BriefEntry, store: Store) -> ThreadRequest? { store.heldRequest(e.target) }

    /// An entry as acted on: with its request, T3's question and options, a permission's buttons, a plan's two
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

    /// The words the project's brief highlights the thread with ("the bar's needs-you count"), when its prose names it.
    func highlightName(_ t: BriefTarget) -> String? {
        for line in docs[t.project]?.now ?? [] {
            for case .thread(let id, let text) in BriefMarkup.parse(line) where id == t.thread {
                let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !words.isEmpty { return words }
            }
        }
        return nil
    }

    func title(_ t: BriefTarget) -> String {
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
        // A question asked in words: the option's words are your reply.
        picked[t] = nil
        return send(label, to: t, store: store)
    }

    /// Your words to the thread: explicit target. A thread whose request T3 can take an answer for gets them as its answer
    /// (see `answerRequest`); a thread with none gets them as a reply through the Router's dispatcher, as the composer's
    /// reply did.
    @discardableResult
    func send(_ words: String, to t: BriefTarget, store: Store, queue: Bool = false) -> Bool {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !answering.contains(t) else { return false }
        if let e = entry(t, store: store), let request = request(e, store: store), request.live {
            answerRequest(request, entry: e, option: nil, words: text, store: store)
            return true
        }
        var context = RouterContext(replyTo: t)
            context.queue = queue
            guard store.sendToRouter(text, context: context) else {
            trouble[t] = "This thread can't be reached from here: answer it in T3."
            return false
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

    /// Opens the thread in T3 Code. Whether there was one to open.
    @discardableResult
    func open(_ t: BriefTarget, store: Store) -> Bool {
        guard let session = desktopSession(t, store: store) else { return false }
        return store.openThread(session)
    }

    /// Marks the thread read (`thread.visit`, which T3's sidebar and phone share): a change with its Revert in the drawer.
    func markRead(_ t: BriefTarget, store: Store) {
        guard docs[t.project]?.needsYou.contains(where: { $0.target == t }) == true else { return }
        store.threadAct(.read, on: t, title: title(t))
        leave(t)
    }

    /// Archives the thread in T3 (`thread.archive`): only ever on an explicit press. It leaves the brief until Revert.
    func archive(_ t: BriefTarget, store: Store) {
        store.threadAct(.archive, on: t, title: title(t))
        leave(t)
    }

    /// Snoozes the thread until then: T3 wakes it on a new request or a failure.
    func snooze(_ t: BriefTarget, until: Date, store: Store) {
        store.snoozeThread(t, until: until)
        leave(t)
    }

    /// Settles the thread (T3's "done with it"): it leaves the brief unless it needs you again.
    func settle(_ t: BriefTarget, store: Store) {
        store.settleThread(t)
        leave(t)
    }

    private func set(_ kind: BriefMarks.Kind, _ key: String, on: Bool) {
        guard marks[kind].contains(key) != on else { return }
        if on { marks[kind].insert(key) } else { marks[kind].remove(key) }
        engine?.setMark(kind, key, on: on)
    }

    /// The entry your words went to left the brief: they go nowhere now (never on to another entry unasked).
    private func leave(_ t: BriefTarget) {
        picked[t] = nil
        unmention(t)
    }

    func record(_ t: BriefTarget, _ words: String) {
        if let log {
            let item = BriefItem(seq: 0, id: "answer:\(UUID().uuidString)", at: clock().timeIntervalSince1970, kind: .message, thread: t.thread,
                                 text: "you answered: " + words)
            if log.append(item, project: t.project) { engine?.boardChanged(t.project) }
        }
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
