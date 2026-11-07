import Foundation
import SwiftUI

// MARK: - Persisted state

/// What Fjord remembers about a Claude session it has shown.
struct ThreadEntry: Codable, Hashable, Identifiable {
    var id: String
    /// Two letters or an emoji chosen by you; nil uses letters from the title.
    var label: String?
    /// Fjord's own read flag. It follows the app (new turns, opening the session, the sidebar dot) but can be changed
    /// here without touching the app.
    var unread = false
    /// Activity last seen (see `AgentThread.activity`).
    var seen = ""
    /// Not listed at this activity (an entry made only to hold a label or an icon): hidden until there is newer activity.
    var hiddenAt: String?
    var focusedAt: Date?
    /// SF Symbol picked by Jev (shown unless you set a label yourself).
    var icon: String?
    /// Icons you asked to replace: never offered again for this session.
    var rejectedIcons: [String]?
}

struct ThreadsState: Codable {
    /// Whether Claude's sessions are read: they follow the Router's switch (see `Store.switchRouter`).
    var enabled = false
    var enabledAt: Date?
    var entries: [ThreadEntry] = []
    /// Folders whose sessions never show up as pending ("" = scratch chats).
    var mutedFolders: [String] = []
    /// Sidebar dots at the last read, to notice when one appears or disappears.
    var appUnread: [String]?
    /// Sessions active recently are offered as pending the first time the extension sees them.
    var seeded = false
    /// Colour of each project (folder path → index into `Theme.projectColors`), picked once and then kept.
    var folderColors: [String: Int] = [:]
    /// Icons picked by Jev (TypeSafe) for each session; needs a TypeSafe API key (kept in the Keychain).
    var iconsEnabled = false
    /// Bumped when the palette changes, so colours picked from an older one are picked again.
    var paletteVersion = ThreadsState.palette
    static let palette = 2
    /// Bumped when the icon list changes, so icons picked from an older one are picked again.
    var iconsVersion = ThreadsState.icons
    static let icons = 2

    init() {}

    /// A project gets a colour the first time one of its sessions is listed: the least used one.
    mutating func assignColor(_ folder: String) {
        guard !folder.isEmpty, folderColors[folder] == nil else { return }
        let used = folderColors.values.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
        folderColors[folder] = Theme.projectColors.indices.min { used[$0, default: 0] < used[$1, default: 0] } ?? 0
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        enabledAt = try c.decodeIfPresent(Date.self, forKey: .enabledAt)
        entries = try c.decodeIfPresent([ThreadEntry].self, forKey: .entries) ?? []
        mutedFolders = try c.decodeIfPresent([String].self, forKey: .mutedFolders) ?? []
        appUnread = try c.decodeIfPresent([String].self, forKey: .appUnread)
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        iconsEnabled = try c.decodeIfPresent(Bool.self, forKey: .iconsEnabled) ?? false
        let version = try c.decodeIfPresent(Int.self, forKey: .paletteVersion) ?? 1
        folderColors = version == Self.palette ? try c.decodeIfPresent([String: Int].self, forKey: .folderColors) ?? [:] : [:]
        if try c.decodeIfPresent(Int.self, forKey: .iconsVersion) ?? 1 != Self.icons {
            for i in entries.indices {
                entries[i].icon = nil
                entries[i].rejectedIcons = nil
            }
        }
    }
}

enum ClaudeLink: Equatable {
    case off, ok, missing, unreadable
}

// MARK: - Rows

/// What a session is doing for the Router: needs you, finished, working, or quiet (listed for `Store.recentWindow` after its
/// last activity).
enum ThreadGroup: Int, CaseIterable {
    case needsYou, done, working, idle
}

struct ThreadRow: Identifiable, Hashable {
    var session: AgentThread
    var entry: ThreadEntry
    var label: String
    /// The project's colour (nil for scratch chats).
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
    var unread: Bool { entry.unread }

    /// Mid-turn but stopped on you (a question, a plan): counts as waiting, not as working.
    var waitsForYou: Bool { session.running && activity?.waitsForYou == true }

    var group: ThreadGroup {
        if waitsForYou { return .needsYou }
        if session.running { return .working }
        if entry.unread && session.summary?.blocked == true { return .needsYou }
        // Turn over but subagents or commands it started still run: it isn't done, it picks up again when they finish.
        if !tasks.isEmpty { return .working }
        if entry.unread { return .done }
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

/// What the views derive from the agents and the read sessions, computed once per change.
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
        // Read for what observes the rows: each names its session's project.
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
        // Sessions stay while they work or wait to be read, and for an hour after their last activity; then only a
        // search finds them.
        let now = Date(), cutoff = now.addingTimeInterval(-Self.recentWindow)
        let pending = sessions.values
            .compactMap { s -> (AgentThread, ThreadEntry)? in
                guard let e = byID[s.id], e.hiddenAt == nil, !muted.contains(s.id) else { return nil }
                guard s.running || e.unread || tasks[s.id]?.isEmpty == false || s.lastActivity > cutoff else { return nil }
                return (s, e)
            }
            .sorted { $0.0.lastActivity > $1.0.lastActivity }
        // The list is read again when the next of them ages out.
        let quiet = pending.filter { !$0.0.running && !$0.1.unread && tasks[$0.0.id]?.isEmpty != false }.map { $0.0.lastActivity + Self.recentWindow }
        scheduleRecentExpiry(quiet.min().map { $0.timeIntervalSince(now) })
        let labels = AgentLabel.assign(pending.map { (id: $0.0.id, title: $0.0.title, custom: $0.1.label) },
                                       folders: Dictionary(pending.map { ($0.0.id, $0.0.folderName) }, uniquingKeysWith: { a, _ in a }))
        let allRows = pending.map { makeRow($0.0, $0.1, label: labels[$0.0.id]) }
        return ThreadCache(all: allRows, entries: byID, labels: Dictionary(allRows.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a }))
    }

    /// How long a session that went quiet stays listed.
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

    /// A row for any session, listed or not (search results show sessions Fjord hasn't listed).
    func row(_ session: AgentThread, _ entry: ThreadEntry? = nil, label: String? = nil) -> ThreadRow {
        makeRow(session, entry ?? cache.entries[session.id], label: label)
    }

    /// A session's row, listed or not: `row(session)`, its entry looked up without the listed rows being made.
    func sessionRow(_ id: String) -> ThreadRow? {
        guard let session = threads[id] else { return nil }
        if agentEntryIndex == nil {
            agentEntryIndex = Dictionary(agents.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return makeRow(session, agentEntryIndex?[id], label: nil)
    }

    private func makeRow(_ session: AgentThread, _ entry: ThreadEntry?, label: String?) -> ThreadRow {
        ThreadRow(session: session, entry: entry ?? ThreadEntry(id: session.id),
                 // Sessions outside the cache (hidden ones found through search) still show their saved label.
                 label: label ?? entry?.label ?? AgentLabel.candidates(session.title, folder: session.folderName).first ?? "··",
                 color: projectColor(session.folderKey), project: folderName(session.folderKey),
                 activity: session.running ? threadWork[session.id] : nil,
                 tasks: session.running ? [] : backgroundWork[session.id] ?? [])
    }

    func projectColor(_ folder: String) -> Color? {
        guard !folder.isEmpty, let i = agents.folderColors[folder] else { return nil }
        return Theme.projectColors[i % Theme.projectColors.count]
    }

    var allAgentRows: [ThreadRow] { cache.all }

    /// Every folder a name can be asked for: the ones sessions are in, the ones muted and the clones in your code folders.
    var namedFolders: Set<String> { namedFolders(sessions: Set(threads.values.map(\.folderKey))) }

    private func namedFolders(sessions: Set<String>) -> Set<String> {
        sessions.union(agents.mutedFolders).union(codeFolders.clones.keys).subtracting([""])
    }

    /// A project's name wherever it is named: its own, with as much of the path above it as it takes to tell it from another
    /// project of the same name (`customer-a/app`), the same in every menu, tag and spoken value.
    func folderName(_ folder: String) -> String {
        if folder.isEmpty { return "Scratch" }
        if let name = folderNames[folder] { return name }
        // One no session is in (an old session's): named among the folders `folderNames` was worked out for, once per set.
        if let name = folderNameMisses[folder] { return name }
        let name = FolderNames.name(folder, among: Array(namedFoldersSeen ?? namedFolders))
        if namedFoldersSeen != nil { folderNameMisses[folder] = name }
        return name
    }

    /// Called when the sessions or the muted folders change : the
    /// names are worked out again only when the set of folders is another, and the dictionary is only written when a name did.
    func refreshFolderNames() {
        let sessions = Set(threads.values.map(\.folderKey))
        // The projects (and their clones) follow the sessions' folders too.
        codeFolders.sessionFoldersChanged(macSessionFolders)
        let folders = namedFolders(sessions: sessions)
        guard folders != namedFoldersSeen else { return }
        namedFoldersSeen = folders
        folderNameMisses = [:]
        let names = FolderNames.names(for: folders)
        if names != folderNames { folderNames = names }
    }

    /// The folders on this Mac that sessions are in. A session Desktop runs over SSH (a computer's guest) has a folder
    /// that exists only there: it is never a Mac project, unless a local session is in a folder of the same path.
    var macSessionFolders: Set<String> {
        let sessions = Array(threads.values)
        let local = Set(sessions.filter { $0.sshHost == nil }.map(\.folderKey))
        return local.union(sessions.filter { $0.folderKey.isEmpty }.map(\.folderKey))
    }

    var knownFolders: [String] {
        // The names to sort by are taken once each, not on every comparison.
        let keyed = macSessionFolders.map { ($0, FolderNames.components($0).last?.lowercased() ?? "") }
        return keyed.sorted { a, b in
            if a.0.isEmpty != b.0.isEmpty { return !a.0.isEmpty }
            return a.1 != b.1 ? a.1 < b.1 : a.0 < b.0
        }.map(\.0)
    }

    // MARK: Reading the app

    /// Re-reads the app's session files and sidebar dots, off the main thread. Called on file changes (and a slow
    /// timer as backup); calls made while a read is running fold into one more read.
    func refreshClaude() {
        guard agents.enabled else { return }
        // The app's own reads (a store that doesn't persist, a test's, routes on what it was given).
        if persists { claudeReadAsked = true }
        claudeFeed.readPresence(from: routerFiles) { [weak self] in self?.refreshClaude() }
        claudeFeed.request(full: true, stamp: claudeStamp) { [weak self] in self?.applyClaude($0) }
    }

    /// Re-reads only the sidebar dots (the app writes them lazily): the sessions are those of the last read.
    func refreshUnread() {
        guard agents.enabled else { return }
        claudeFeed.request(full: false, unreadOnly: true, stamp: claudeStamp) { [weak self] in self?.applyClaude($0) }
    }

    /// What each working session is doing, from the tail of its transcript (only files that changed are read), and
    /// the background work left running by sessions whose turn is over.
    func refreshActivity() {
        guard agents.enabled else { return }
        claudeFeed.request(full: false, stamp: claudeStamp) { [weak self] in self?.applyClaude($0) }
    }

    /// Takes a read of the app back onto the main thread; properties are only set when they changed.
    func applyClaude(_ snapshot: ClaudeSnapshot) {
        guard agents.enabled, snapshot.stamp.generation == claudeStamp.generation else { return }
        // You changed something since this read was asked for: it could undo that, so read again instead.
        if snapshot.sessions != nil, snapshot.stamp.revision != claudeStamp.revision {
            refreshClaude()
            return
        }
        applyClaudeRead(snapshot)
    }

    private func applyClaudeRead(_ snapshot: ClaudeSnapshot) {
        if let link = snapshot.link, claudeLink != link { claudeLink = link }
        if let sessions = snapshot.sessions {
            ingesting = true
            ingest(sessions, appUnread: snapshot.appUnread, claudeFrontmost: snapshot.frontmost)
            ingesting = false
        }
        // A read that found the sessions, or found them missing or unreadable (no Claude app): either way, what routing will
        // know of them is known, and the actions waiting for it go.
        if !claudeReadOnce, snapshot.sessions != nil || snapshot.link == .missing || snapshot.link == .unreadable {
            claudeReadOnce = true
            routingMayBeReady()
        }
        if let next = snapshot.activity {
            var merged = next
            for (id, guest) in guestExecutionStates {
                if guest.availability == .inaccessible {
                    merged[id] = threadWork[id]
                } else {
                    merged[id] = guest.activity
                }
            }
            if merged != threadWork { threadWork = merged }
        }
        if let next = snapshot.tasks {
            var merged = next
            for (id, guest) in guestExecutionStates {
                merged[id] = guest.availability == .dead ? nil : backgroundWork[id]
            }
            if merged != backgroundWork { backgroundWork = merged }
        }
        if snapshot.sessions != nil { pickIcons() }
        scheduleClaudeTick()
    }

    /// Folds a fresh read of the app into what Fjord remembers. Pure apart from `now`, so tests drive it directly.
    func ingest(_ sessions: [AgentThread], appUnread: Set<String>?, claudeFrontmost: Bool, now: Date = Date()) {
        var state = agents
        let live = sessions.filter { !$0.isArchived }
        let byID = Dictionary(live.map { incoming -> (String, AgentThread) in
            var session = incoming
            if let guest = guestExecutionStates[session.id] {
                session.cliID = guest.cliSessionID
                if let isRunning = guest.isRunning { session.running = isRunning }
            }
            return (session.id, session)
        }, uniquingKeysWith: { a, _ in a })
        let muted = mutedSessionIDs(state.mutedFolders, among: live)
        let previousDots = state.appUnread.map(Set.init)
        // The session shown in the app right now: the most recently focused one, if the app is in front.
        let viewing = claudeFrontmost ? live.max { ($0.lastFocused ?? .distantPast) < ($1.lastFocused ?? .distantPast) }?.id : nil
        let since = state.enabledAt ?? now

        // First read: offer only the few most recent sessions, not a whole day's worth.
        let seedIDs = state.seeded ? [] : Set(live.filter { now.timeIntervalSince($0.lastActivity) < 24 * 3600 }
            .sorted { $0.lastActivity > $1.lastActivity }.prefix(8).map(\.id))

        // Archived (or deleted) sessions leave Fjord.
        state.entries.removeAll { byID[$0.id] == nil }
        var index = Dictionary(uniqueKeysWithValues: state.entries.enumerated().map { ($1.id, $0) })

        for session in live {
            guard let i = index[session.id] else {
                // First sight of a session: offered as pending if it moved recently enough to matter.
                let recent = state.seeded ? session.lastActivity > since : seedIDs.contains(session.id)
                guard recent, !muted.contains(session.id) else { continue }
                var entry = ThreadEntry(id: session.id, seen: session.activity, focusedAt: session.lastFocused)
                // The sidebar dot lags; a session that just finished a turn elsewhere is unread already.
                let finished = state.seeded && session.completedTurns > 0 && session.id != viewing && !session.running
                entry.unread = appUnread?.contains(session.id) == true || finished
                state.entries.append(entry)
                index[session.id] = state.entries.count - 1
                continue
            }
            var entry = state.entries[i]
            if entry.seen != session.activity {
                let turnsBefore = Int(entry.seen.split(separator: "|").first ?? "") ?? 0
                if session.completedTurns > turnsBefore {
                    // A turn finished: unread, unless you were looking at it in the app.
                    entry.unread = session.id != viewing
                } else {
                    // You sent a message, so you've seen it.
                    entry.unread = false
                }
                entry.seen = session.activity
                if entry.hiddenAt != nil, entry.hiddenAt != session.activity { entry.hiddenAt = nil }
            }
            if let focused = session.lastFocused, focused > (entry.focusedAt ?? .distantPast) {
                // Opened in the app (or from Fjord).
                if entry.focusedAt != nil { entry.unread = false }
                entry.focusedAt = focused
            }
            // The sidebar dot appearing or disappearing wins; while it doesn't change, your choice here stands.
            if let dots = appUnread, let before = previousDots {
                let was = before.contains(session.id), now = dots.contains(session.id)
                if !was && now { entry.unread = true }
                if was && !now { entry.unread = false }
            }
            state.entries[i] = entry
        }

        // Forget long-gone pending sessions so the state file stays small, except those you gave a label or an icon.
        state.entries.removeAll { e in
            guard e.hiddenAt != nil, e.label == nil, e.icon == nil, !iconRequests.contains(e.id),
                  let s = byID[e.id] else { return false }
            return now.timeIntervalSince(s.lastActivity) > 30 * 86400
        }
        if let appUnread { state.appUnread = appUnread.sorted() }
        state.seeded = true
        for folder in state.entries.compactMap({ byID[$0.id]?.folderKey }) { state.assignColor(folder) }
        if state.entries != agents.entries || state.appUnread != agents.appUnread || state.seeded != agents.seeded
            || state.folderColors != agents.folderColors {
            agents = state
        }
        // Only on change: the views observing these redraw on every assignment.
        if threads != byID { threads = byID }
    }

    // MARK: Actions

    private func mutateAgent(_ id: String, _ f: (inout ThreadEntry) -> Void) {
        guard let i = agents.entries.firstIndex(where: { $0.id == id }) else { return }
        f(&agents.entries[i])
    }

    func openThread(_ id: String) {
        if let interceptOpen { interceptOpen("Open in Claude · \(threads[id]?.title ?? id)") } else { Claude.open(id) }
        mutateAgent(id) { $0.unread = false }
    }

    /// Sessions Fjord holds no entry for (old, muted, past the first read's cap) get one when an icon is picked for
    /// them: hidden, so they stay unlisted until their next activity.
    private func ensureEntry(_ id: String) {
        guard !agents.entries.contains(where: { $0.id == id }), let session = threads[id] else { return }
        agents.entries.append(ThreadEntry(id: id, seen: session.activity, hiddenAt: session.activity, focusedAt: session.lastFocused))
        agents.assignColor(session.folderKey)
    }

    // MARK: Icons (Jev)

    /// The session to pick an icon for next: one you asked for (it may be hidden, found through search), then the
    /// listed ones that don't have one yet. Sessions with nothing to go on are skipped until they change.
    func iconTarget() -> ThreadRow? {
        iconRequests.removeAll { iconRow($0)?.needsIcon != true }
        iconDeferred = iconDeferred.filter { iconRow($0.key).map { iconStamp($0.session) } == $0.value }
        func ready(_ row: ThreadRow) -> Bool { iconDeferred[row.id] == nil }
        return iconRequests.lazy.compactMap { self.iconRow($0) }.first(where: ready)
            ?? allAgentRows.first { $0.needsIcon && ready($0) }
    }

    /// Whether a pick begun for `session` (as it was then) may still be taken: the session still wants an icon (none set
    /// meanwhile, by hand or otherwise), and what it was picked from (its title, its project, its transcript) is the same.
    func iconStillWanted(_ session: AgentThread) -> Bool {
        guard let now = threads[session.id], iconRow(session.id)?.needsIcon == true else { return false }
        return now.title == session.title && now.folderName == session.folderName && now.cliID == session.cliID
    }

    /// What a session looked like when it had nothing to go on: new activity, a title or a transcript changes it.
    private func iconStamp(_ session: AgentThread) -> String {
        "\(session.title)|\(session.activity)|\(session.cliID ?? "")"
    }

    /// A row for a session Fjord keeps an entry for, listed or hidden.
    private func iconRow(_ id: String) -> ThreadRow? {
        guard let session = threads[id], let entry = cache.entries[id] else { return nil }
        return row(session, entry)
    }

    /// Picks icons for the sessions that want one (see `iconTarget`), one request at a time.
    func pickIcons() {
        guard agents.enabled, agents.iconsEnabled, iconTask == nil, Date() >= iconsPausedUntil,
              typesafeKey?.isEmpty == false, let next = iconTarget(),
              // Taken now, with the key and switch as they are: changed while the transcript is read, nothing is asked.
              let choose = jevChooser(.icons, base: iconChooser) else { return }
        let session = next.session
        let cliID = session.cliID
        let reader = activityReader
        let readFirst = iconFirstMessage ?? { id in reader.transcript(id).flatMap { Claude.firstMessage(head: Claude.head(of: $0)) } }
        iconTask = Task { [weak self] in
            // The transcript's head (256 KB, parsed) is read off the main thread, which may also be waiting on the
            // activity reader's lock.
            let first = await Task.detached(priority: .utility) {
                cliID.flatMap(readFirst)
            }.value
            guard let self else { return }
            // Nothing to go on yet (a brand-new session the app hasn't named): skip it until it changes, and carry on.
            if first == nil, session.title == "Untitled session" {
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
                // What it was picked for changed while Jev answered, an icon was set meanwhile, or another session took
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
        scheduleClaudeTick()
    }

    /// Whether icons can be picked now: on, with a key. Without that a session keeps the icon it has, but can't get another.
    var canPickIcons: Bool { agents.enabled && agents.iconsEnabled && hasTypesafeKey }

    /// Replaces a session's icon (the old one is never offered again for it). Not while nothing could pick the next:
    /// the session would be left with none.
    func repickIcon(_ id: String) {
        guard canPickIcons else { return }
        ensureEntry(id)
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

    /// The sessions of muted projects: a guest session goes by its project's key (`routerProjectGroupKey`).
    func mutedSessionIDs(_ muted: [String], among sessions: [AgentThread]) -> Set<String> {
        guard !muted.isEmpty else { return [] }
        let set = Set(muted)
        return Set(sessions.filter { set.contains(routerProjectGroupKey(sessionID: $0.id, folder: $0.folderKey)) }.map(\.id))
    }

    func setFolderMuted(_ folder: String, _ muted: Bool) {
        agents.mutedFolders.removeAll { $0 == folder }
        if muted { agents.mutedFolders.append(folder) }
    }

    func setAgentsEnabled(_ on: Bool) {
        guard on != agents.enabled else { return }
        claudeStamp.generation += 1
        agents.enabled = on
        if on {
            agents.enabledAt = agents.enabledAt ?? Date()
            if persists { watchClaude() } else { refreshClaude() }
        } else {
            if persists { watchClaude() }
            threads = [:]
            claudeLink = .off
            claudeSessionsRead = false
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
