import Foundation
import SwiftUI

// MARK: - Persisted state

/// What Fjord keeps of a thread itself: the glyph it shows for it. Read state, archive and snooze are T3's.
struct ThreadEntry: Codable, Hashable, Identifiable {
    var id: String
    /// Two letters or an emoji chosen by you; nil uses letters from the title.
    var label: String?
    /// SF Symbol picked by Jev (shown unless you set a label yourself).
    var icon: String?
    /// Icons you asked to replace: never offered again for this thread.
    var rejectedIcons: [String]?
}

struct ThreadsState: Codable {
    /// Whether threads are read: they follow the Router's switch (see `Store.switchRouter`).
    var enabled = false
    /// Only threads with a label or an icon have one.
    var entries: [ThreadEntry] = []
    /// Folders whose threads never show up as pending ("" = scratch threads).
    var mutedFolders: [String] = []
    /// Colour of each project (folder path → index into `Theme.projectColors`), picked once and then kept.
    var folderColors: [String: Int] = [:]
    /// Icons picked by Jev (TypeSafe) for each thread; needs a TypeSafe API key (kept in the Keychain).
    var iconsEnabled = false
    /// Bumped when the palette changes, so colours picked from an older one are picked again.
    var paletteVersion = ThreadsState.palette
    static let palette = 2
    /// Bumped when the icon list changes, so icons picked from an older one are picked again.
    var iconsVersion = ThreadsState.icons
    static let icons = 2

    init() {}

    /// A project gets a colour the first time one of its threads is read: the least used one.
    mutating func assignColor(_ folder: String) {
        guard !folder.isEmpty, folderColors[folder] == nil else { return }
        let used = folderColors.values.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
        folderColors[folder] = Theme.projectColors.indices.min { used[$0, default: 0] < used[$1, default: 0] } ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, entries, mutedFolders, folderColors, iconsEnabled, paletteVersion, iconsVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        entries = try c.decodeIfPresent([ThreadEntry].self, forKey: .entries) ?? []
        mutedFolders = try c.decodeIfPresent([String].self, forKey: .mutedFolders) ?? []
        iconsEnabled = try c.decodeIfPresent(Bool.self, forKey: .iconsEnabled) ?? false
        let version = try c.decodeIfPresent(Int.self, forKey: .paletteVersion) ?? 1
        folderColors = version == Self.palette ? try c.decodeIfPresent([String: Int].self, forKey: .folderColors) ?? [:] : [:]
        if try c.decodeIfPresent(Int.self, forKey: .iconsVersion) ?? 1 != Self.icons {
            for i in entries.indices {
                entries[i].icon = nil
                entries[i].rejectedIcons = nil
            }
        }
        entries.removeAll { $0.icon == nil && $0.label == nil && $0.rejectedIcons == nil }
    }

    /// The state saved under `agents` before threads came from T3, carried over once: the switch, colours and muted folders
    /// as they were (they are keyed by folder), and the icons and labels of the Claude sessions T3 imported, under the id T3
    /// gave each (`import:claudeAgent:<Claude Code session id>`). `cliIDs` maps the desktop app's session ids to Claude
    /// Code's; the rest of the entries go.
    func carriedOver(cliIDs: [String: String]) -> ThreadsState {
        var out = self
        out.entries = entries.compactMap { e in
            guard e.icon != nil || e.label != nil, let cli = cliIDs[e.id] else { return nil }
            var moved = e
            moved.id = "import:claudeAgent:\(cli)"
            return moved
        }
        return out
    }

    /// The desktop app's session ids and the Claude Code session each ran (its session files), for `carriedOver`.
    static var desktopCLIIDs: () -> [String: String] = {
        guard !UnderTest.refuses("the Claude app's session files") else { return [:] }
        let dir = Claude.root.appendingPathComponent("claude-code-sessions", isDirectory: true)
        var ids: [String: String] = [:]
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [:] }
        for case let url as URL in files where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            guard let data = try? Data(contentsOf: url),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = d["sessionId"] as? String, let cli = d["cliSessionId"] as? String, !cli.isEmpty else { continue }
            ids[id] = cli
        }
        return ids
    }
}

// MARK: - Rows

/// What a thread is doing for the Router: needs you, finished and unseen, working, or quiet (listed for `Store.recentWindow`
/// after its last activity).
enum ThreadGroup: Int, CaseIterable {
    case needsYou, done, working, idle
}

struct ThreadRow: Identifiable, Hashable {
    var session: AgentThread
    var entry: ThreadEntry
    var label: String
    /// The project's colour (nil for scratch threads).
    var color: Color?
    /// The project's name as the lists say it, with enough of its path to tell it from another of the same name.
    var project: String?
    /// What it's doing, while it works.
    var activity: ThreadWork?
    /// Turn over, but subagents or commands it started are still running.
    var tasks: [BackgroundWork] = []

    /// The picked icon, unless you chose letters or an emoji yourself.
    var icon: String? { entry.label == nil ? entry.icon : nil }

    /// No icon yet, and no label of your own to show instead.
    var needsIcon: Bool { entry.icon == nil && entry.label == nil }

    var projectName: String { project ?? session.folderName }

    var id: String { session.id }
    /// Not seen since its last update, as T3 keeps it.
    var unread: Bool { session.unseen }

    /// Stopped on you (a question, a permission, a plan): counts as waiting, not as working.
    var waitsForYou: Bool { session.waitsForYou }

    var group: ThreadGroup { Self.group(session, tasks: tasks) }

    static func group(_ s: AgentThread, tasks: [BackgroundWork]) -> ThreadGroup {
        if s.needsYou { return .needsYou }
        // Turn over but subagents or commands it started still run: it isn't done, it picks up again when they finish.
        if s.running || !tasks.isEmpty { return .working }
        if s.unseen && s.finished { return .done }
        return .idle
    }

    /// When the running turn began, if known.
    var workingSince: Date? { session.lastUserMessage ?? activity?.since }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    /// "3 running": what's left in the background, after the status.
    var tasksText: String? { tasks.isEmpty ? nil : "\(tasks.count) running" }
}

// MARK: - Labels

enum AgentLabel {
    private static let skipped: Set<String> = ["a", "an", "the", "of", "for", "and", "to", "in", "on", "with", "my", "is"]

    /// Letter pairs to try, best first: initials of the first two words, then other pairs, then the first letters.
    /// Words naming the project are left out (its colour already says it): "LCU update notifications" in lcu → UN.
    static func candidates(_ title: String, folder: String? = nil) -> [String] {
        let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let folderWords = Set(([folder ?? ""] + (folder ?? "").split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .map { $0.lowercased() }.filter { $0.count >= 2 })
        let meaningful = words.filter { !skipped.contains($0.lowercased()) && !folderWords.contains($0.lowercased()) }
        let use = meaningful.isEmpty ? words : meaningful
        var out: [String] = []
        func add(_ s: String) {
            let u = s.uppercased()
            if u.count == 2, !out.contains(u) { out.append(u) }
        }
        if use.count >= 2 {
            add("\(use[0].prefix(1))\(use[1].prefix(1))")
            for j in 2..<min(use.count, 5) { add("\(use[0].prefix(1))\(use[j].prefix(1))") }
            for i in 1..<min(use.count, 4) { for j in (i + 1)..<min(use.count, 5) { add("\(use[i].prefix(1))\(use[j].prefix(1))") } }
        }
        if let first = use.first {
            add(String(first.prefix(2)))
            let chars = Array(first)
            for c in chars.dropFirst(2) { add("\(chars[0])\(c)") }
        }
        return out
    }

    /// Custom labels win; generated ones avoid every label already taken, falling back to a digit.
    static func assign(_ items: [(id: String, title: String, custom: String?)], folders: [String: String] = [:]) -> [String: String] {
        var taken = Set(items.compactMap { $0.custom?.uppercased() })
        var result: [String: String] = [:]
        for item in items {
            if let custom = item.custom, !custom.isEmpty {
                result[item.id] = custom
                continue
            }
            let options = candidates(item.title, folder: folders[item.id])
            var label = options.first { !taken.contains($0) }
            if label == nil {
                let base = String((options.first ?? "S").prefix(1))
                label = (1...99).lazy.map { "\(base)\($0)" }.first { !taken.contains($0) }
            }
            taken.insert(label!)
            result[item.id] = label!
        }
        return result
    }
}

// MARK: - Store

/// What the views derive from the threads and Fjord's entries, computed once per change.
struct ThreadCache {
    var all: [ThreadRow]
    var entries: [String: ThreadEntry]
    var labels: [String: String]
}

extension Store {
    /// Derived rows, memoized: views read these dozens of times per render. The getters still read the observed
    /// properties, so SwiftUI keeps tracking them; `agentCache` is dropped whenever one of them changes.
    private var cache: ThreadCache {
        let state = agents, sessions = threads, activity = threadWork, tasks = backgroundWork
        // Read for what observes the rows: each names its thread's project.
        _ = (recentTick, folderNames)
        if let agentCache { return agentCache }
        let built = buildAgentCache(state, sessions, activity, tasks)
        agentCache = built
        return built
    }

    private func buildAgentCache(_ state: ThreadsState, _ sessions: [String: AgentThread],
                                 _ activity: [String: ThreadWork], _ tasks: [String: [BackgroundWork]]) -> ThreadCache {
        let byID = Dictionary(state.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let muted = mutedSessionIDs(state.mutedFolders, among: Array(sessions.values))
        let now = Date(), cutoff = now.addingTimeInterval(-Self.recentWindow)
        // The next moment the list changes with no event: a quiet thread ageing out, a snooze running out.
        var next: Date?
        func at(_ d: Date) { next = min(next ?? d, d) }
        let pending = sessions.values
            .compactMap { s -> (AgentThread, ThreadEntry)? in
                guard !muted.contains(s.id) else { return nil }
                if let until = s.snoozedUntil, until > now { at(until); return nil }
                let left = tasks[s.id] ?? []
                // Settled (as every imported thread is): only work still live or waiting on you lists it, as in T3.
                if s.settled, !s.running, !s.waitsForYou, left.isEmpty { return nil }
                // Threads stay while they work, wait on you or wait to be seen, and for an hour after their last activity;
                // then only a search finds them.
                if ThreadRow.group(s, tasks: left) == .idle {
                    guard s.lastActivity > cutoff else { return nil }
                    at(s.lastActivity + Self.recentWindow)
                }
                return (s, byID[s.id] ?? ThreadEntry(id: s.id))
            }
            .sorted { $0.0.lastActivity != $1.0.lastActivity ? $0.0.lastActivity > $1.0.lastActivity : $0.0.id < $1.0.id }
        // The list is read again when the next of them changes by the clock alone.
        scheduleRecentExpiry(next.map { $0.timeIntervalSince(now) })
        let labels = AgentLabel.assign(pending.map { (id: $0.0.id, title: $0.0.title, custom: $0.1.label) },
                                       folders: Dictionary(pending.map { ($0.0.id, $0.0.folderName) }, uniquingKeysWith: { a, _ in a }))
        let allRows = pending.map { makeRow($0.0, $0.1, label: labels[$0.0.id]) }
        return ThreadCache(all: allRows, entries: byID, labels: Dictionary(allRows.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a }))
    }

    /// How long a thread that went quiet stays listed.
    static let recentWindow: TimeInterval = 3600

    private func scheduleRecentExpiry(_ delay: TimeInterval?) {
        recentExpiry?.invalidate()
        recentExpiry = nil
        guard let delay else { return }
        let timer = Timer(timeInterval: max(1, delay + 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.recentTick &+= 1 }
        }
        RunLoop.main.add(timer, forMode: .common)
        recentExpiry = timer
    }

    /// A row for any thread, listed or not (search results show threads Fjord hasn't listed).
    func row(_ session: AgentThread, _ entry: ThreadEntry? = nil, label: String? = nil) -> ThreadRow {
        makeRow(session, entry ?? cache.entries[session.id], label: label)
    }

    /// A thread's row, listed or not: `row(session)`, its entry looked up without the listed rows being made.
    func sessionRow(_ id: String) -> ThreadRow? {
        guard let session = threads[id] else { return nil }
        if agentEntryIndex == nil {
            agentEntryIndex = Dictionary(agents.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return makeRow(session, agentEntryIndex?[id], label: nil)
    }

    private func makeRow(_ session: AgentThread, _ entry: ThreadEntry?, label: String?) -> ThreadRow {
        ThreadRow(session: session, entry: entry ?? ThreadEntry(id: session.id),
                 // Threads outside the cache (found through search) still show their saved label.
                 label: label ?? entry?.label ?? AgentLabel.candidates(session.title, folder: session.folderName).first ?? "··",
                 color: projectColor(session.folderKey), project: folderName(session.folderKey),
                 activity: session.turnRunning ? threadWork[session.id] : nil,
                 // Hidden while the turn itself runs (its work is the activity), shown once it is the turn's leftovers that run.
                 tasks: session.turnRunning ? [] : backgroundWork[session.id] ?? [])
    }

    func projectColor(_ folder: String) -> Color? {
        guard !folder.isEmpty, let i = agents.folderColors[folder] else { return nil }
        return Theme.projectColors[i % Theme.projectColors.count]
    }

    var allAgentRows: [ThreadRow] { cache.all }

    /// Every folder a name can be asked for: the ones threads are in, the ones muted and the clones in your code folders.
    var namedFolders: Set<String> { namedFolders(sessions: Set(threads.values.map(\.folderKey))) }

    private func namedFolders(sessions: Set<String>) -> Set<String> {
        sessions.union(agents.mutedFolders).union(codeFolders.clones.keys).subtracting([""])
    }

    /// A project's name wherever it is named: its own, with as much of the path above it as it takes to tell it from another
    /// project of the same name (`customer-a/app`), the same in every menu, tag and spoken value.
    func folderName(_ folder: String) -> String {
        if folder.isEmpty { return "Scratch" }
        if let name = folderNames[folder] { return name }
        // One no thread is in: named among the folders `folderNames` was worked out for, once per set.
        if let name = folderNameMisses[folder] { return name }
        let name = FolderNames.name(folder, among: Array(namedFoldersSeen ?? namedFolders))
        if namedFoldersSeen != nil { folderNameMisses[folder] = name }
        return name
    }

    /// Called when the threads or the muted folders change: the names are worked out again only when the set of folders is
    /// another, and the dictionary is only written when a name did.
    func refreshFolderNames() {
        let sessions = Set(threads.values.map(\.folderKey))
        // The projects (and their clones) follow the threads' folders too.
        codeFolders.sessionFoldersChanged(macSessionFolders)
        let folders = namedFolders(sessions: sessions)
        guard folders != namedFoldersSeen else { return }
        namedFoldersSeen = folders
        folderNameMisses = [:]
        let names = FolderNames.names(for: folders)
        if names != folderNames { folderNames = names }
    }

    /// The folders threads are in: this Mac's T3 runs every one here.
    var macSessionFolders: Set<String> { Set(threads.values.map(\.folderKey)) }

    var knownFolders: [String] {
        // The names to sort by are taken once each, not on every comparison.
        let keyed = macSessionFolders.map { ($0, FolderNames.components($0).last?.lowercased() ?? "") }
        return keyed.sorted { a, b in
            if a.0.isEmpty != b.0.isEmpty { return !a.0.isEmpty }
            return a.1 != b.1 ? a.1 < b.1 : a.0 < b.0
        }.map(\.0)
    }

    // MARK: Reading T3

    /// The T3 link's store calls back here on every shell change and connection state.
    func wireThreads() {
        t3.store.onShell = { [weak self] item in self?.shellChanged(item) }
        t3.store.onConnection = { [weak self] state in self?.t3ConnectionChanged(state) }
        t3.store.onThread = { [weak self] id in self?.threadDetailChanged(id) }
        iconFirstMessage = { [weak self] id in await self?.firstUserMessage(id) }
    }

    /// What you first asked a thread, for its icon: from its projection when one is open, else read once through a
    /// subscription that closes at its snapshot. Kept per thread (the first message never changes).
    func firstUserMessage(_ id: String) async -> String? {
        if let kept = firstMessages[id] { return kept }
        let text: String?
        if let p = t3.store.projections[id] { text = T3Store.firstUserMessage(in: p) } else { text = await t3.store.readFirstUserMessage(id) }
        if let text { firstMessages[id] = text }
        return text
    }

    /// The threads whose detail Fjord holds open: the listed ones that work, which are the ones the Router shows an activity
    /// line for, and the ones that wait on you, whose question, permission or plan only the projection carries. A thread
    /// that settles drops out, and its subscription closes.
    func syncThreadDetail() {
        let wanted = Set(allAgentRows.lazy.filter { $0.session.running || $0.session.waitsForYou }.map(\.id))
        t3.store.watch(wanted)
        let gone = threadWork.keys.filter { !wanted.contains($0) }
        if !gone.isEmpty {
            var work = threadWork
            for id in gone { work[id] = nil }
            threadWork = work
        }
        let stale = requests.keys.filter { !wanted.contains($0) }
        if !stale.isEmpty {
            var next = requests
            for id in stale { next[id] = nil }
            requests = next
        }
    }

    /// A subscribed thread's projection changed: its activity is read again, and assigned only if it differs.
    func threadDetailChanged(_ id: String) {
        guard agents.enabled, let projection = t3.store.projections[id] else { return }
        let work = ThreadWork(projection)
        if threadWork[id] != work { threadWork[id] = work }
        // Whatever waits on you: the newest pending request, else the proposed plan; nothing once it is answered.
        let request = ThreadRequest(projection)
        if requests[id] != request {
            requests[id] = request
            if let request { routerBriefs.requestAppeared(request, store: self) }
        }
    }

    /// A shell change, taken in at once; while the window's morph plays (`MotionGate`) it waits for the motion to end, and
    /// everything that changed meanwhile is taken in as one.
    func shellChanged(_ item: T3ShellItem?) {
        guard agents.enabled else { return }
        if shellHeld { return }
        guard !motionGate.holding else {
            shellHeld = true
            motionGate.whenStill { [weak self] in
                guard let self else { return }
                self.shellHeld = false
                self.applyShell(nil)
            }
            return
        }
        applyShell(item)
    }

    /// The shell as T3's store holds it now, folded into `threads` and `backgroundWork`: one row for a row's change, every
    /// row for anything else (a snapshot, a project changed, a new shell). Pure apart from `now`, so tests drive it directly.
    func applyShell(_ item: T3ShellItem?, now: Date = Date()) {
        guard agents.enabled else { return }
        let shell = t3.store.shell
        func listed(_ t: T3ThreadShell) -> Bool { t.isListed && t.archivedAt == nil && t.deletedAt == nil && !t.id.isEmpty }
        func since(_ s: AgentThread) -> Date { s.lastRunEndedAt ?? s.lastActivity }
        var next = threads, work = backgroundWork
        func put(_ t: T3ThreadShell) {
            let s = AgentThread(t, project: shell.projects[t.projectId])
            next[t.id] = s
            let tasks = AgentThread.backgroundWork(t, since: since(s))
            work[t.id] = tasks.isEmpty ? nil : tasks
        }
        func project(_ ids: Set<String>) {
            for t in shell.threads.values where ids.contains(t.projectId) && listed(t) { put(t) }
        }
        switch item {
        case .threadUpdated(_, _, let t)?:
            if let row = shell.threads[t.id], listed(row) { put(row) } else { next[t.id] = nil; work[t.id] = nil }
        case .threadRemoved(_, _, let id)?:
            next[id] = nil; work[id] = nil
        case .projectUpdated(_, let p)?:
            project([p.id])
        case .projectRemoved(_, let id)?:
            project([id])
        // The snapshot's later parts carry projects alone (their repository, S1 10): only their threads change.
        case .snapshot(let snap)? where snap.threads.isEmpty && snap.archivedThreads.isEmpty:
            project(Set(snap.projects.map(\.id)))
        // T3 has said everything it has: what briefs.db holds of anything else can go (`RouterBriefs.purgeUnlisted`).
        case .synchronized?:
            routerBriefs.threadsChanged(store: self)
            return
        case .unknown?:
            return
        case .snapshot?, nil:
            next = [:]; work = [:]
            for t in shell.threads.values where listed(t) { put(t) }
        }
        // Only on change: the views observing these redraw on every assignment.
        if next != threads { threads = next }
        prefetchDeciderReads()
        refreshThreadCards()
        if work != backgroundWork { backgroundWork = work }
        var state = agents
        // Entries of threads T3 no longer has (archived, deleted) go, once T3 has said what it has.
        if !shell.threads.isEmpty { state.entries.removeAll { shell.threads[$0.id] == nil } }
        // A project gets its colour the first time one of its threads is read, the most recent first.
        for s in next.values.sorted(by: { $0.lastActivity > $1.lastActivity }) { state.assignColor(s.folderKey) }
        if state.entries != agents.entries || state.folderColors != agents.folderColors { agents = state }
        threadsRead()
        syncThreadDetail()
        pickIcons()
        routerBriefs.threadsChanged(store: self)
    }

    /// The first word from T3 came (its shell, or why there is none): what routing knows of threads is known, and the actions
    /// waiting for it go.
    private func threadsRead() {
        guard !threadsReadOnce else { return }
        threadsReadOnce = true
        routingMayBeReady()
    }

    func t3ConnectionChanged(_ state: T3ConnectionState) {
        routerBriefs.connectionChanged(state, store: self)
        switch state {
        case .noToken, .noServer, .incompatible, .tokenRejected: threadsRead()
        default: break
        }
    }

    // MARK: Actions

    private func mutateAgent(_ id: String, _ f: (inout ThreadEntry) -> Void) {
        if let i = agents.entries.firstIndex(where: { $0.id == id }) {
            f(&agents.entries[i])
        } else {
            var entry = ThreadEntry(id: id)
            f(&entry)
            guard entry != ThreadEntry(id: id) else { return }
            agents.entries.append(entry)
        }
    }

    /// Opens the thread in T3 Code (its deep link): T3 itself records the visit when it shows it; Fjord marks nothing. A test's
    /// intercept sees the open instead. Whether there was a link to open.
    @discardableResult
    func openThread(_ id: String) -> Bool {
        if let interceptOpen {
            interceptOpen("Open in T3 · \(threads[id]?.title ?? id)")
            return true
        }
        guard let url = t3.store.deepLink(id) else { return false }
        Link.open(url)
        return true
    }

    // MARK: Icons (Jev)

    /// The thread to pick an icon for next: one you asked for (it may not be listed, found through search), then the
    /// listed ones that don't have one yet. Threads with nothing to go on are skipped until they change.
    func iconTarget() -> ThreadRow? {
        iconRequests.removeAll { iconRow($0)?.needsIcon != true }
        iconDeferred = iconDeferred.filter { iconRow($0.key).map { iconStamp($0.session) } == $0.value }
        func ready(_ row: ThreadRow) -> Bool { iconDeferred[row.id] == nil }
        return iconRequests.lazy.compactMap { self.iconRow($0) }.first(where: ready)
            ?? allAgentRows.first { $0.needsIcon && ready($0) }
    }

    /// Whether a pick begun for `session` (as it was then) may still be taken: the thread still wants an icon (none set
    /// meanwhile, by hand or otherwise), and what it was picked from (its title, its project) is the same.
    func iconStillWanted(_ session: AgentThread) -> Bool {
        guard let now = threads[session.id], iconRow(session.id)?.needsIcon == true else { return false }
        return now.title == session.title && now.folderName == session.folderName
    }

    /// What a thread looked like when it had nothing to go on: a new title changes it.
    private func iconStamp(_ session: AgentThread) -> String {
        "\(session.title)|\(Int(session.lastActivity.timeIntervalSince1970))"
    }

    /// A row for a thread, listed or not.
    private func iconRow(_ id: String) -> ThreadRow? {
        guard let session = threads[id] else { return nil }
        return row(session, cache.entries[id])
    }

    /// Titles T3 gives a thread before it has one of its own.
    static let placeholderTitles: Set<String> = ["", "New thread", "Untitled thread"]

    /// Picks icons for the threads that want one (see `iconTarget`), one request at a time.
    func pickIcons() {
        guard agents.enabled, agents.iconsEnabled, iconTask == nil, Date() >= iconsPausedUntil,
              typesafeKey?.isEmpty == false, let next = iconTarget(),
              // Taken now, with the key and switch as they are: changed meanwhile, nothing is asked.
              let choose = jevChooser(.icons, base: iconChooser) else { return }
        let session = next.session
        let readFirst = iconFirstMessage
        iconTask = Task { [weak self] in
            let id = session.id
            let first = await readFirst?(id)
            guard let self else { return }
            // Nothing to go on yet (a brand-new thread T3 hasn't named): skip it until it changes, and carry on.
            if first == nil, Self.placeholderTitles.contains(session.title) {
                self.iconDeferred[session.id] = self.iconStamp(session)
                self.iconTask = nil
                self.pickIcons()
                return
            }
            let rows = self.allAgentRows
            guard let current = self.iconRow(session.id), current.needsIcon else {
                self.iconTask = nil
                self.pickIcons()
                return
            }
            let used = Set(rows.compactMap(\.entry.icon)).union(current.entry.rejectedIcons ?? [])
            let open = await SessionIcons.openOffMain(excluding: used)
            // Renamed meanwhile (or given an icon by hand): picked again from what it is now.
            guard self.iconStillWanted(session) else { self.iconTask = nil; return self.pickIcons() }
            guard !open.isEmpty else { self.iconTask = nil; return }
            var state = ["session title": session.title, "project": session.folderName]
            if let first { state["first message"] = first }
            do {
                // Two questions (Jev takes at most 255 options): what kind of icon, then which one.
                let kinds = try await choose(open.map(\.category.key),
                    Dictionary(uniqueKeysWithValues: open.map { ($0.category.key, $0.category.about) }), state,
                    "Which kind of icon would best show what this coding session is about?")
                let options = SessionIcons.shortlist(open, probabilities: kinds.probabilities)
                let pick = try await choose(options, SessionIcons.hints, state,
                    "Pick the icon that best shows what this coding session is about, so its owner can tell it apart from their other sessions at a glance.")
                self.iconError = nil
                self.iconTask = nil
                // What it was picked for changed while Jev answered, an icon was set meanwhile, or another thread took
                // this one: not taken, and picked again (or left as you set it).
                if self.iconStillWanted(session), !self.allAgentRows.contains(where: { $0.id != session.id && $0.entry.icon == pick.choice }) {
                    self.mutateAgent(session.id) { $0.icon = pick.choice }
                }
                self.pickIcons()
            } catch {
                self.iconPickFailed(error)
            }
        }
    }

    /// A rejected key waits for a new one, and says so where it happens: the Settings line that shows it may not be open.
    /// Anything else retries in a while.
    func iconPickFailed(_ error: Error) {
        iconTask = nil
        // Stopped, or the key or switch changed meanwhile: nothing failed.
        if error as? JevClient.Failure == .cancelled { return pickIcons() }
        iconError = error.localizedDescription
        let rejected = error as? JevClient.Failure == .unauthorized
        iconsPausedUntil = rejected ? .distantFuture : Date().addingTimeInterval(600)
        if rejected, let said = iconError { announce(said, false) }
        scheduleIconRetry()
    }

    /// One timer for the end of an icon pause (a rejected key waits for a new one instead).
    private func scheduleIconRetry() {
        iconRetry?.invalidate()
        iconRetry = nil
        guard iconsPausedUntil < .distantFuture else { return }
        let timer = Timer(fire: iconsPausedUntil.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pickIcons() }
        }
        RunLoop.main.add(timer, forMode: .common)
        iconRetry = timer
    }

    /// Whether icons can be picked now: on, with a key. Without that a thread keeps the icon it has, but can't get another.
    var canPickIcons: Bool { agents.enabled && agents.iconsEnabled && hasTypesafeKey }

    /// Replaces a thread's icon (the old one is never offered again for it). Not while nothing could pick the next:
    /// the thread would be left with none.
    func repickIcon(_ id: String) {
        guard canPickIcons, threads[id] != nil else { return }
        mutateAgent(id) {
            if let icon = $0.icon { $0.rejectedIcons = ($0.rejectedIcons ?? []) + [icon] }
            $0.icon = nil
        }
        iconRequests.append(id)
        pickIcons()
    }

    var typesafeKey: String? {
        // Filled in by the read at launch (see `Store.start`), never from the main thread.
        typesafeKeyCache
    }

    /// Keeps `key` in the Keychain, or removes it with nothing. False when the Keychain refused it: the key is then not
    /// saved (`iconError` says so) and what was saved before stays.
    @discardableResult
    func setTypesafeKey(_ key: String?) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            Keychain.delete(Keychain.typesafe)
        } else if !(keychainWrite ?? Keychain.write)(trimmed, Keychain.typesafe) {
            iconError = "Couldn't save the key in the Keychain"
            return false
        }
        typesafeKeyCache = trimmed
        hasTypesafeKey = !trimmed.isEmpty
        jevGate.keyChanged()
        // What is under way with the old key stops (the icon's pick starts again with the new one once it has).
        iconTask?.cancel()
        iconError = nil
        iconsPausedUntil = .distantPast
        pickIcons()
        return true
    }

    func setIconsEnabled(_ on: Bool) {
        agents.iconsEnabled = on
        if !on { iconTask?.cancel() }
        iconsPausedUntil = .distantPast
        pickIcons()
    }

    /// The threads of muted projects.
    func mutedSessionIDs(_ muted: [String], among sessions: [AgentThread]) -> Set<String> {
        guard !muted.isEmpty else { return [] }
        let set = Set(muted)
        return Set(sessions.filter { set.contains($0.folderKey) }.map(\.id))
    }

    func setFolderMuted(_ folder: String, _ muted: Bool) {
        agents.mutedFolders.removeAll { $0 == folder }
        if muted { agents.mutedFolders.append(folder) }
    }

    func setAgentsEnabled(_ on: Bool) {
        guard on != agents.enabled else { return }
        agents.enabled = on
        if on {
            applyShell(nil)
        } else {
            threads = [:]
            backgroundWork = [:]
        }
    }
}

/// Names for folders: the last component, and the folders above it only where another project would have the same one.
enum FolderNames {
    /// The names of all of `folders` at once. A folder whose last component no other has is named by it alone; only the ones that
    /// share a last component are compared, each by as many of the components above as it takes to differ.
    static func names(for folders: Set<String>) -> [String: String] {
        var named: [String: [String]] = [:]
        var parts: [String: [String]] = [:]
        for folder in folders {
            let own = components(folder)
            parts[folder] = own
            named[own.last ?? "", default: []].append(folder)
        }
        var names: [String: String] = [:]
        for (_, group) in named {
            for folder in group {
                let own = parts[folder]!
                var depth = 1
                while depth < own.count, group.contains(where: { $0 != folder && parts[$0]!.suffix(depth) == own.suffix(depth) }) { depth += 1 }
                names[folder] = own.suffix(depth).joined(separator: "/")
            }
        }
        return names
    }

    static func name(_ folder: String, among folders: [String]) -> String {
        guard !folder.isEmpty else { return "Scratch" }
        return names(for: Set(folders).union([folder]))[folder] ?? ""
    }

    /// A path's components, without the root and empty ones.
    static func components(_ folder: String) -> [String] {
        folder.split(separator: "/").map(String.init)
    }
}
