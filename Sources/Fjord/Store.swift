import AppKit
import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class Store {
    /// Demo and snapshot runs: never touch the Keychain (a new build would stop on an access prompt).
    nonisolated static let isDemo = CommandLine.arguments.contains { ["--demo", "--snapshot", "--playground", "--playground-shots", "--window", "--window-shots"].contains($0) }

    @ObservationIgnored private(set) var engineClient: any EngineClient
    private(set) var hasEngineConnection: Bool
    @ObservationIgnored let engineLauncher: EngineLauncher?
    @ObservationIgnored let computers: ComputersModel
    @ObservationIgnored var routerPlacementShot = false
    @ObservationIgnored private var engineConnectAttempt: Task<Void, Never>?

    init(engineClient: (any EngineClient)? = nil, engineLauncher: EngineLauncher? = nil) {
        let offlineContext = Store.isDemo || UnderTest.isRunning
        let socketPath = SocketEngineClient.defaultSocketPath
        let defaultClient: any EngineClient
        if offlineContext { defaultClient = MockEngineClient() }
        else { defaultClient = UnavailableEngineClient() }
        let selectedClient = engineClient ?? defaultClient
        self.engineClient = selectedClient
        self.hasEngineConnection = selectedClient is MockEngineClient || selectedClient is SocketEngineClient
        self.engineLauncher = engineLauncher ?? (offlineContext ? nil : EngineLauncher(socketPath: socketPath))
        let computers = ComputersModel(client: selectedClient, initialInventory: (selectedClient as? MockEngineClient)?.inventory)
        self.computers = computers
        if selectedClient is SocketEngineClient {
            computers.prepareComputerRemoval = { [weak self] computer in
                guard let self else { return }
                try await GuestRouterRuntime.shared.prepareComputerRemoval(store: self, computer: computer)
            }
            computers.computerRemovalCompleted = { [weak self] computer in
                guard let self else { return }
                GuestRouterRuntime.shared.computerRemoved(store: self, computer: computer)
            }
        }
    }

    var computersEngineReady: Bool { hasEngineConnection }

    /// Probe an engine only when the user opens Computers. This can attach to Silo.app's shared owner but never registers
    /// Fjord's LaunchAgent.
    func inspectComputersEngine() async {
        guard let engineLauncher else { return }
        await engineLauncher.inspect()
        await attachConnectedEngine()
        await runEngineUpdate(automatic: true)
    }

    /// Connects to a running engine without the Computers page (never registers anything): the Router's guest delivery
    /// needs it at launch and on first use. Concurrent callers share one attempt; an engine already attached is left alone.
    func ensureEngineConnected() async {
        if hasEngineConnection { return }
        if let attempt = engineConnectAttempt { await attempt.value; return }
        guard let engineLauncher else { return }
        let attempt = Task { @MainActor [weak self] in
            await engineLauncher.inspect()
            await self?.attachConnectedEngine()
        }
        engineConnectAttempt = attempt
        await attempt.value
        engineConnectAttempt = nil
    }

    /// The Computers page's Update button, and the retry after a blocked update.
    func updateComputersEngine() async {
        await runEngineUpdate(automatic: false)
    }

    /// The engine handoff (see EngineHandoff.swift). The Computers page keeps showing the old engine's computers until the
    /// old engine leaves, then the new engine's.
    private func runEngineUpdate(automatic: Bool) async {
        guard let engineLauncher else { return }
        if automatic { await engineLauncher.continueUpdateIfAutomatic() } else { await engineLauncher.updateEngine() }
        await attachConnectedEngine()
    }

    /// The first launch after a Fjord update that carries a new silod: connect without registering anything and hand off.
    func resumeEngineHandoffIfPending() async {
        guard EngineHandoffMarker.take() else { return }
        await inspectComputersEngine()
    }

    /// The Computers page calls this only from its visible Enable action.
    func enableComputersEngine() async {
        guard let engineLauncher else { return }
        await engineLauncher.enable()
        await attachConnectedEngine()
    }

    func openEngineApprovalSettings() {
        engineLauncher?.openApprovalSettings()
    }

    private func attachConnectedEngine() async {
        guard let client = engineLauncher?.client else {
            hasEngineConnection = false
            return
        }
        engineClient = client
        hasEngineConnection = true
        await computers.replaceClient(client)
        do { try await computers.connect() }
        catch { computers.actionError = error.localizedDescription }
        // Right after an engine update its saved items are typically refused until the user allows them.
        await computers.refreshKeychainStatus()
    }

    // The inbox: categories of things (see InboxModel.swift, InboxStore.swift).
    var categories: [InboxCategory] = InboxStore.defaultCategories {
        didSet {
            // A name, a symbol or a colour (each keystroke in the editor) changes what the inbox is called, not what is
            // in it: it isn't worked out again for that.
            if InboxStore.evaluatesAlike(categories, oldValue) { inboxDisplayRevision &+= 1 } else { inboxRevision &+= 1 }
            persistedRevision &+= 1
            logCategories(from: oldValue)
        }
    }
    var groups: [InboxGroup] = [] {
        didSet { inboxRevision &+= 1; persistedRevision &+= 1; logGroups(from: oldValue) }
    }
    /// The bar's sections, in order (CategorySections.swift); every inbox starts with GitHub's.
    var categorySections: [CategorySection] = [.github] {
        didSet { persistedRevision &+= 1 }
    }
    /// Prompt texts kept for reuse, in the order you put them (Snippets.swift); @ lists them.
    var snippets: [Snippet] = [] {
        didSet { persistedRevision &+= 1; corpusRevision &+= 1 }
    }
    /// The Snippets page's undo history while it is open (⌘Z there is the page's).
    @ObservationIgnored var snippetHistory: SnippetHistory?
    /// A category whose editor the categories page opens when it shows (a rule-off mark's click, from the bar or the window).
    var categoryEditorRequest: UUID?
    /// Set to have the categories page open the editor of a new category when it shows (the palette's New category).
    var newCategoryRequest = false
    /// Who is changing the categories and groups now, for the log (see `InboxLog`); nil is the editor.
    @ObservationIgnored var inboxSource: InboxChangeSource?
    /// Where those log lines go; the tests read them.
    @ObservationIgnored var inboxLog: (String) -> Void = InboxLog.write
    var things: [String: Thing] = [:] {
        didSet {
            inboxRevision &+= 1; persistedRevision &+= 1
            // Only when CI was seen to change was set below: nothing else changed.
            guard !stampingCI else { return }
            if !loading {
                let now = Date()
                let ci = Self.stampingCIChanges(things, before: oldValue, now: now)
                if let stamped = Self.stampingCommitArrivals(ci ?? things, before: oldValue, now: now) ?? ci {
                    stampingCI = true
                    things = stamped
                    stampingCI = false
                }
            }
            resolveWaits(); if !loading { carryAssignmentStamps(seenBefore: oldValue) }
        }
    }
    @ObservationIgnored private var stampingCI = false

    /// The things with when their CI was last seen to change (`Thing.ciChangedAt`): kept from before while it is the same
    /// (a refresh makes the thing anew), `now` once its state, its run or whether it still runs changed; nil when none moved.
    /// One first seen with CI is stamped when that CI finished, as GitHub says (`ciFinishedAt`), else now: CI that finished
    /// before it was found, after a turn that waits on it ended, is still CI that changed since.
    nonisolated static func stampingCIChanges(_ things: [String: Thing], before: [String: Thing], now: Date) -> [String: Thing]? {
        var stamped = things
        var moved = false
        for (id, thing) in things where thing.kind == .pr || thing.kind == .workflow {
            guard let old = before[id] else {
                if thing.ciChangedAt == nil, thing.checks != nil { stamped[id]?.ciChangedAt = thing.ciFinishedAt ?? now; moved = true }
                continue
            }
            let same = thing.checks == old.checks && thing.ciRunning == old.ciRunning && thing.ciCancelled == old.ciCancelled
                && (old.ciRun == nil || thing.ciRun == old.ciRun)
            let at = same ? thing.ciChangedAt ?? old.ciChangedAt
                : thing.ciChangedAt == nil || thing.ciChangedAt == old.ciChangedAt ? now : thing.ciChangedAt
            if at != thing.ciChangedAt { stamped[id]?.ciChangedAt = at; moved = true }
        }
        return moved ? stamped : nil
    }

    /// The things with when each commit came to its PR (`ThingCommit.seenAt`): kept from before for one it had, `now` for
    /// one first seen on a PR read before (pushed since, though committed earlier); nil when none moved. What a PR has when
    /// it is first read (or read again after it was gone) isn't stamped: it was all there before.
    nonisolated static func stampingCommitArrivals(_ things: [String: Thing], before: [String: Thing], now: Date) -> [String: Thing]? {
        var stamped = things
        var moved = false
        for (id, thing) in things where thing.kind == .pr && !thing.commits.isEmpty {
            guard let old = before[id], !old.commits.isEmpty else { continue }
            let seen = Dictionary(old.commits.map { ($0.id, $0.seenAt) }, uniquingKeysWith: { a, _ in a })
            var commits = thing.commits
            for i in commits.indices {
                // One it had keeps what it had (nil when it was there when the PR was first read).
                let at: Date? = if let had = seen[commits[i].id] { had } else { commits[i].seenAt ?? now }
                if at != commits[i].seenAt { commits[i].seenAt = at; moved = true }
            }
            stamped[id]?.commits = commits
        }
        return moved ? stamped : nil
    }
    var marks: [String: EntryMarks] = [:] {
        didSet { inboxRevision &+= 1; persistedRevision &+= 1 }
    }
    /// Per category, the rules (by id) whose matches were already noted: a category's first look, or a changed rule set,
    /// announces nothing.
    var categoryBaselines: [UUID: Set<UUID>] = [:] {
        didSet { persistedRevision &+= 1 }
    }
    /// The repos you own and those you merged a PR in (what `Repos I own` and `Repos I contribute to` mean), kept so the
    /// editor's preview has them at launch.
    var ownedRepos: Set<String> = [] {
        didSet { inboxRevision &+= 1; persistedRevision &+= 1 }
    }
    var contributedRepos: Set<String> = [] {
        didSet { inboxRevision &+= 1; persistedRevision &+= 1 }
    }
    /// The teams you're in, `org/team` (what `My teams` means), resolved with the repos.
    var myTeams: Set<String> = [] {
        didSet { inboxRevision &+= 1; persistedRevision &+= 1 }
    }
    /// What the categories' actions have done and what was already there when they began (InboxActions.swift); kept in its
    /// own file next to the state.
    var actionLedger = ActionLedger() {
        didSet { saveActions(); corpusRevision &+= 1 }
    }
    /// Does what actions do; nil is the real one (and nothing at all in the playground and tests).
    @ObservationIgnored var actionPerformer: ActionPerformer?
    /// The Claude app's sessions were asked for, and the first read of them has come: until then a "Send to the Router"
    /// action waits (`routingReady`), so it isn't routed before your sessions, and the clones among their folders, are known.
    @ObservationIgnored var claudeReadAsked = false
    @ObservationIgnored var claudeReadOnce = false
    /// A "Send to the Router" job was left for when routing is ready (`routingMayBeReady` runs the actions then).
    @ObservationIgnored var actionsAwaitRouting = false
    @ObservationIgnored var actionsBusy = false
    /// The categories page's undo history while it is open (⌘Z there is the editor's, not Done's).
    @ObservationIgnored var categoryHistory: CategoryHistory?
    /// Rules were edited and the actions have not yet taken in what they match: nothing runs until they have.
    /// Saved with the state: a quit before it is taken in leaves it waiting at the next launch.
    @ObservationIgnored var baselinePending = false {
        didSet { if baselinePending != oldValue { persistedRevision &+= 1 } }
    }
    @ObservationIgnored var baselineTask: Task<Void, Never>?
    /// The edit's pause is over, but what it asks GitHub for hasn't been fetched yet: it is taken in after the refresh
    /// that has (`baselineIfFetched`).
    @ObservationIgnored var baselineAwaitsFetch = false
    /// What the things were fetched for: the categories they were saved with, then the searches and workflow targets the
    /// refreshes since have answered. Nil when never loaded nor refreshed (the things are taken as they are).
    /// Saved with the state: after a restart, what the things were fetched for is still what was, not what the categories
    /// ask for now.
    @ObservationIgnored var fetchedFor: FetchedScope? {
        didSet { if fetchedFor != oldValue { persistedRevision &+= 1 } }
    }
    enum FetchedScope: Equatable, Codable {
        case categories([InboxCategory], [InboxGroup])
        case keys(Set<String>)
    }
    @ObservationIgnored var actionsAgain = false
    /// Which of the ledger's changes are on disk (InboxActions.swift): no action runs before its record is.
    @ObservationIgnored let actionsDisk = ActionsDisk()
    /// What the last inbox refresh failed at, if it did (InboxSync.swift); the things it had stay.
    var inboxError: String?
    /// Why Jev couldn't read the inbox's new comments and requests (InboxJev.swift): his labels and ratings stay as they
    /// were until he can.
    var inboxReadError: String?
    /// Why what is changed isn't being saved, if it isn't (the state's file or the actions'): said where the sync status is,
    /// until a save works.
    var saveProblem: String? {
        let problems = [stateSaveProblem, actionsSaveProblem].compactMap { $0 }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }
    var stateSaveProblem: String?
    var actionsSaveProblem: String?
    /// The saved state couldn't be read at launch: what runs is the defaults, until a save works.
    /// No action runs meanwhile: the ledger would be taken in against these categories, not yours (InboxActions.swift).
    @ObservationIgnored private(set) var onDefaults = false
    /// Repos (lowercased) GitHub said don't exist, or can't be seen: their chips are red and block Save.
    var missingRepos: Set<String> = []
    /// What GitHub said of each repo named, this session (lowercased name to its canonical name).
    @ObservationIgnored var repoAnswers: [String: String] = [:]
    /// Saved repo names were checked against GitHub's canonical ones this launch.
    @ObservationIgnored var repoNamesChecked = false
    @ObservationIgnored var repoNamesChecking = false
    /// When ownedRepos and contributedRepos were last resolved (at most daily).
    @ObservationIgnored var reposResolvedAt: Date? {
        didSet { persistedRevision &+= 1 }
    }
    /// When myTeams was last resolved (this session; at most daily).
    @ObservationIgnored var teamsResolvedAt: Date?
    /// What the inbox's refreshes keep between them (InboxSync.swift).
    @ObservationIgnored var inboxSyncState = InboxSyncState()
    /// Default branches found for workflow things, by repo, and when each was looked up (again daily: `defaultBranchRecheck`).
    @ObservationIgnored var defaultBranches: [String: String] = [:]
    @ObservationIgnored var defaultBranchesCheckedAt: [String: Date] = [:]
    /// Bumped on every inbox change: the memo key for entries.
    private(set) var inboxRevision = 0
    /// Bumped when only what the categories are called changed (names, symbols, colours, sections, switches): what is
    /// searched by their names is made again, the entries aren't.
    private(set) var inboxDisplayRevision = 0
    @ObservationIgnored var inboxMemo = InboxStore.Memo()
    /// How many rules of each category are off, as of an `inboxRevision` (`rulesOff`).
    @ObservationIgnored var rulesOffMemo: (revision: Int, counts: [UUID: Int])?
    /// Time alone changed what matches (InboxStore.swift): what reads the inbox reads it again.
    func inboxTimePassed() { inboxRevision &+= 1 }
    /// Done, taken back with ⌘Z or the inbox's undo line.
    let undoStack = UndoStack()
    var settings = AppSettings() {
        didSet {
            if (settings.triage == true) != triageOn { triageOn = settings.triage == true }
            persistedRevision &+= 1
            armSnoozeExpiry()
        }
    }

    /// Triage's switch (`settings.triage`; the Router's is `routerOn`), kept in step by `settings` and written only when it
    /// changes: what reads it (the bar, the window's root) doesn't redraw with every other setting.
    private(set) var triageOn = false
    /// The Router's switch: on only while Fjord reads Claude's sessions too (`router.enabled && agents.enabled`,
    /// which follow each other). Kept in step by `router` and `agents` and written only when it changes, so what reads it
    /// doesn't redraw with every read of Claude's sessions, as reading those two whole would.
    private(set) var routerOn = false
    @ObservationIgnored var routerGeneration: UInt64 = 0
    private func updateRouterOn() {
        if (router.enabled && agents.enabled) != routerOn { routerOn = router.enabled && agents.enabled }
    }

    /// Claude sessions extension (see Agents.swift).
    var agents = AgentsState() {
        didSet {
            updateRouterOn()
            agentCache = nil
            agentEntryIndex = nil
            persistedRevision &+= 1
            shownRevision &+= 1
            corpusRevision &+= 1
            if !ingesting { claudeStamp.revision += 1 }
            refreshFolderNames()
            refreshSessionRows(sessionRowsChanged(from: oldValue))
            routerDigester.markDirty(store: self)
        }
    }
    /// The Router (see Router.swift): its cards, its decision log and the changes it made.
    var router = RouterState() {
        didSet {
            updateRouterOn()
            routerRevision &+= 1
            persistedRevision &+= 1
            if oldValue.cards != router.cards { countCardChanges(from: oldValue.cards) }
            // What it means for the Brief: a card in or handled, a message of yours (RouterDigestWriter.swift).
            if oldValue.cards != router.cards || oldValue.decisions != router.decisions || oldValue.enabled != router.enabled
                || (router.digest == nil && router.enabled) {
                routerDigester.observe(from: oldValue, to: router, store: self)
            } else if oldValue.pendingDesktopStarts != router.pendingDesktopStarts || oldValue.runsOnProjects != router.runsOnProjects
                        || oldValue.lives != router.lives {
                // What decides a session's project, and what each session's lines say.
                routerDigester.markDirty(store: self)
            }
            // Worked out again only if what it is made of changed: a session's stamps or an open card changing leave it (and
            // what draws it) alone.
            if oldValue.decisions != router.decisions || oldValue.summaries != router.summaries || oldValue.cards != router.cards {
                // Held Claude reads taken in together (`batchingClaudeReads`): worked out once, at their end.
                if routerHistoryDeferred { routerHistoryStale = true } else { rebuildRouterHistory() }
            }
        }
    }
    @ObservationIgnored var routerHistoryDeferred = false
    @ObservationIgnored var routerHistoryStale = false

    func rebuildRouterHistory() {
        let next = RouterPage.history(cards: router.cards, decisions: router.decisions, summaries: router.summaries)
        if next != routerHistory { routerHistory = next }
    }
    /// The Router page's history (see `RouterPage.history`), worked out when the router changes and only then: the page
    /// reads it on every redraw.
    private(set) var routerHistory: [RouterPage.Entry] = [] {
        didSet { routerSearchRevision &+= 1 }
    }
    /// Bumped when what the history is searched by changes (its lines, the projects' names): what the Router's search
    /// keeps its work by (RouterSearch.swift). Observed, so a search's memo hit still redraws on the next change.
    private(set) var routerSearchRevision = 0
    /// Each history line's search text, in the history's order, as of the revision it was made for: made on the first
    /// search after a change and kept for the searches after it (`routerHistorySearchKeys`).
    @ObservationIgnored var routerHistoryKeys: (revision: Int, keys: [String])?
    /// Bumped on every change to `router`: a cheap memo/animation key.
    private(set) var routerRevision = 0
    /// How many times each card has changed (see `countCardChanges`).
    @ObservationIgnored var cardRevisions: [String: Int] = [:]
    /// The question forms Fjord's hook holds, by Claude Code session id (`ClaudeSession.cliID`).
    var pendingForms: [String: PendingForm] = [:] {
        didSet { shownRevision &+= 1 }
    }
    /// Why installing or removing the form hook failed, if it did.
    var routerHookError: String?
    /// The form hook as last checked (nil until the Router has been switched on in this run).
    var routerHookStatus: FormHookInstaller.Status?
    /// Fjord's Claude Code plugin as last checked (nil until the Router has been switched on in this run, or
    /// in a test that stands in no CLI), and why installing or removing it failed, if it did.
    var routerPluginStatus: ClaudePluginInstaller.Status?
    var routerPluginError: String?
    /// Every project's name, with as much of its path as tells it from another of the same name (`customer-a/app`): worked
    /// out when the folders change, not by each view that names a project. Only a change in it redraws what reads it.
    var folderNames: [String: String] = [:] {
        // The history is searched by its cards' project names too.
        didSet {
            routerSearchRevision &+= 1
            // The rows name each session's project.
            agentCache = nil
            refreshSessionRows(sessionRowsChanged(names: oldValue))
        }
    }
    /// Names of folders no session is in, worked out among `namedFoldersSeen` (`folderName`); cleared when that changes.
    @ObservationIgnored var folderNameMisses: [String: String] = [:]
    /// Each session's row as `sessionRow` gives it, in a box of its own (see `refreshSessionRows`).
    @ObservationIgnored var sessionRowBoxes: [String: SessionRowBox] = [:]
    /// The rows to make again once a read of Claude is taken in (`batchingSessionRows`); nil outside one.
    @ObservationIgnored var sessionRowsPending: Set<String>?
    /// The agents' entries by session, made when a row is and dropped with every change to `agents`.
    @ObservationIgnored var agentEntryIndex: [String: AgentEntry]?
    /// The folders `folderNames` was worked out for: the work is skipped while they are the same.
    @ObservationIgnored var namedFoldersSeen: Set<String>?
    /// The git repos in your code folders, kept fresh (CodeFolders.swift).
    @ObservationIgnored lazy var codeFolders = CodeFolderScanner(store: self)
    var claudeSessions: [String: ClaudeSession] = [:] {
        didSet {
            claudeSessionsRevision &+= 1
            shownRevision &+= 1
            corpusRevision &+= 1
            agentCache = nil
            refreshFolderNames()
            refreshSessionRows(sessionRowsChanged(oldValue, claudeSessions))
            pruneSessionRows()
            updateRouterTasks()
            routerDigester.markDirty(store: self)
        }
    }
    /// Guest execution observations keyed by the Desktop session that owns the SSH mirror. Local reads can refresh
    /// title, folder, and timestamps, but must not replace this guest-owned execution state.
    @ObservationIgnored var guestExecutionStates: [String: GuestExecutionState] = [:]
    /// Bumped on every change to `claudeSessions`: a cheap memo key for what is worked out from them (unobserved).
    @ObservationIgnored private(set) var claudeSessionsRevision = 0
    /// Bumped when what the open palette lists changes besides the inbox and the Router (`inboxRevision`, `routerRevision`):
    /// the sessions, the agents, the actions' runs, the snippets, the project folders. Observed, so the palette follows it.
    private(set) var corpusRevision = 0
    func corpusChanged() { corpusRevision &+= 1 }
    /// Bumped on every change to what the window shows of Claude besides the inbox and the Router (the sessions, their
    /// activity, task titles, the agents, the forms pending, a recent session ageing out): the window's kept picture is not forgiven
    /// a small difference across one (`AppTransition.Marks`). Unobserved.
    @ObservationIgnored private(set) var shownRevision = 0
    var claudeActivity: [String: ClaudeActivity] = [:] {
        didSet {
            shownRevision &+= 1
            agentCache = nil
            refreshSessionRows(sessionRowsChanged(oldValue, claudeActivity))
            routerDigester.markDirty(store: self)
        }
    }
    /// Bumped when a recent session ages out of the list (see `Store.recentWindow`).
    var recentTick = 0 {
        didSet {
            shownRevision &+= 1
            agentCache = nil
        }
    }
    @ObservationIgnored var recentExpiry: Timer?
    /// Subagents and commands still running in sessions whose turn is over.
    var claudeTasks: [String: [ClaudeTask]] = [:] {
        didSet {
            shownRevision &+= 1
            agentCache = nil
            refreshSessionRows(sessionRowsChanged(oldValue, claudeTasks))
            updateRouterTasks()
            routerDigester.markDirty(store: self)
        }
    }
    /// `routerTasks` as last worked out (`updateRouterTasks`, as the tasks or the sessions change), and a revision bumped
    /// only when it changed: what reads it observes that rather than every session.
    @ObservationIgnored var routerTasksKept: [String: [ClaudeTask]] = [:]
    private(set) var routerTasksRevision = 0
    func bumpRouterTasks(_ tasks: [String: [ClaudeTask]]) {
        routerTasksKept = tasks
        routerTasksRevision &+= 1
    }
    /// Filled in right after launch (see `start`): the Keychain read stays off the main thread.
    var hasTypesafeKey = false
    var iconError: String?
    var claudeLink: ClaudeLink = .off {
        didSet {
            if claudeLink == .ok { claudeSessionsRead = true }
            // Claude missing or unreadable ends the wait for its first listing.
            if oldValue != claudeLink { routerDigester.check(self) }
        }
    }
    /// Claude's sessions have been read since Fjord started reading them: a read failing after that leaves the
    /// last ones known (`claudeSessions`), not nothing known.
    var claudeSessionsRead = false

    var me: GHUser? {
        didSet {
            guard let name = me?.login, name != login else { return }
            // Someone else: what was known of the last account (its repos, its teams) isn't theirs.
            if !login.isEmpty, name.caseInsensitiveCompare(login) != .orderedSame { forgetAccountCaches() }
            login = name
        }
    }
    /// Who `me` was last time, kept so the inbox's "me" rules (by me, to me, Repos I own) match at launch, before GitHub
    /// answers who the token is; a sign-in as someone else replaces it.
    private(set) var login = "" {
        didSet { inboxRevision &+= 1; persistedRevision &+= 1 }
    }
    var tokenSource: TokenSource?
    var authError: String?
    /// The first look at the account got no answer from GitHub (no network yet, a VPN down): nothing is known of the token, so
    /// this is a sync problem, not a sign-in one, and the cached rows stay.
    var unreachable = false
    var isSyncing = false
    var lastSync: Date?
    var rateRemaining: Int?
    /// When the GitHub rate limit resets, as of the last sync.
    @ObservationIgnored var rateResetsAt: Date?
    var suggestions: [String] = []

    @ObservationIgnored let gh = GitHubClient()
    /// What the window's morph holds the store's results back with (`MotionGate`). Under test, a gate of the store's own,
    /// which only a test that holds it holds: the app's, which window tests hold, would hold every store's work in the suites
    /// running beside them.
    @ObservationIgnored var motionGate = UnderTest.isRunning ? MotionGate.Gate() : MotionGate.shared {
        didSet { claudeFeed.gate = motionGate }
    }
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored let updater = Updater()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var hubOpen = false
    /// The hub is open as the app window, not only a peek (`setHubOpen`).
    @ObservationIgnored private var hubWindowOpen = false
    @ObservationIgnored private var systemAsleep = false
    @ObservationIgnored private var pollNow = false
    /// Where the token comes from; replaced in tests (the real one can spawn `gh`).
    @ObservationIgnored var resolveToken: @Sendable () -> (String, TokenSource)? = { TokenProvider.resolve() }
    /// Counts the changes made in Settings; the token held was found under `foundAt`, and is looked for again once they differ.
    @ObservationIgnored private(set) var credentialsChanged = 0
    @ObservationIgnored private var foundAt = 0
    /// A token was just saved or taken away: the sign-in that fails next is its result and is said aloud (a poll's isn't).
    @ObservationIgnored private(set) var awaitingSignIn = false
    @ObservationIgnored private var lastAuthAttempt: Date?
    @ObservationIgnored var authRetry = false
    @ObservationIgnored private var refreshQueued = false
    /// Signed out, polls look for a new token this rarely: each look can spawn `gh auth token`.
    private static let authBackoff: TimeInterval = 300
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    /// When the sleeper is due to wake.
    @ObservationIgnored private(set) var sleeperWakes: Date?
    /// The reset an immediate check was already made for (see `pollAll`): never twice for the same one, so a check that
    /// fails (offline, keeping the spent budget and that reset) can't start another at once, and another.
    @ObservationIgnored private var retriedReset: Date?
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Bumped by every persisted property's didSet, and the one place a change is saved from: a Done, a category edit or a
    /// mark is written shortly after, poll or not.
    @ObservationIgnored private var persistedRevision = 0 {
        didSet { save() }
    }
    /// `persistedRevision` as of the last write (or load): quitting writes only if it moved since.
    @ObservationIgnored private var savedRevision = 0
    /// When the one-shot Claude timer fires (it only ever moves earlier until it does).
    @ObservationIgnored private var claudeDeadline: Date?
    @ObservationIgnored var persists = true
    /// Stops the shortcut recorder that is listening, if any. While one is, the panel's key handler stands down
    /// and the global hotkeys are released, so the recorder sees every combination.
    @ObservationIgnored private var stopRecorder: (() -> Void)?
    var isRecordingShortcut: Bool { stopRecorder != nil }
    @ObservationIgnored var onRecordingShortcutChange: ((Bool) -> Void)?
    /// Shows the inbox: on a category with a thing selected (a banner for it), or on the first category (a summary's).
    @ObservationIgnored var onOpenInbox: ((_ category: UUID?, _ thing: String?) -> Void)?
    /// Registers a global shortcut system-wide; `false` when the system refuses it.
    @ObservationIgnored var onGlobalShortcutChange: ((ShortcutAction, Shortcut) -> Bool)?
    /// The system-wide shortcuts the system last refused to register (another app holds the key), by the key it refused:
    /// one still stored does nothing, and Settings says so.
    var refusedShortcuts: [ShortcutAction: Shortcut] = [:]
    /// Cards the feed just made, or that Jev's triage found need you (for banners).
    @ObservationIgnored var onNewRouterCards: (([RouterCard]) -> Void)?
    /// What finished turns ended on, by Jev (see RouterTriage.swift).
    @ObservationIgnored let routerTriager = RouterTriager()
    /// What each card tells you, in plain words (see RouterBrief.swift).
    @ObservationIgnored let routerBriefer = RouterBriefer()
    /// Each shown session's two lines: its latest turn, and its whole life (see RouterLife.swift).
    @ObservationIgnored let routerLife = RouterLifeWriter()
    /// Keeps the Brief up to date (RouterDigestWriter.swift).
    @ObservationIgnored let routerDigester = RouterDigestWriter()
    /// The Brief, kept with the Router's state.
    var routerDigest: RouterDigest? {
        get { router.digest }
        set { router.digest = newValue }
    }
    /// What decides whether something interrupts you, and what came while you were away (see RouterAttention.swift).
    @ObservationIgnored let routerAttention = RouterAttention()
    /// Whether the Claude app is in front (tests answer for it).
    @ObservationIgnored var claudeIsFrontmost: () -> Bool = { Claude.isFrontmost }
    /// The Router was just switched on: its open cards are settled against how things are now at the next feed.
    @ObservationIgnored var routerReconcilePending = false
    /// The forms folder has been read since the Router was switched on: until then no form is known to be gone.
    @ObservationIgnored var routerFormsLoaded = false
    /// The sessions whose background work the last read looked at (see `ClaudeSnapshot.taskInventory`); nil until a read
    /// has said (a test feeding sessions by hand: every one).
    @ObservationIgnored var claudeTaskInventory: Set<String>?
    /// Every session the last read listed, archived ones too, with when each was active last: what the Router's memory of
    /// handled turns is kept for (`RouterFeed.update`). Nil until a read has said.
    @ObservationIgnored var claudeSessionsListed: [String: Date]?
    @ObservationIgnored let formBridge = FormBridge()
    /// Claude Code's binary, which the Router's runs use.
    @ObservationIgnored lazy var routerStatus = RouterStatus()
    /// Your messages to the Router, as typed runs (each its own).
    @ObservationIgnored lazy var routerDispatcher: RouterDispatcher = {
        let dispatcher = RouterDispatcher(store: self)
        dispatcher.claudePath = { [weak self] in self?.routerStatus.latestPath() }
        return dispatcher
    }()
    /// The entries of the ask-back cards still up: kept when the history is pruned.
    @ObservationIgnored var decisionsInUse: () -> Set<UUID> = { [] }
    /// A Router run's change was taken back with Revert (the run's entry): the dispatcher traces it as the outcome of the action.
    @ObservationIgnored var routerRunReverted: (UUID) -> Void = { _ in }
    /// Where the Router's files go, in a test (see `routerFiles`).
    @ObservationIgnored var routerPaths: RouterPaths?
    /// The executable the hook runs; this one unless a test says otherwise.
    @ObservationIgnored var routerExecutable: String?
    /// The latest install or removal of the hook (each waits for the one before).
    @ObservationIgnored var routerHookWork: Task<Void, Never>?
    /// Runs Claude Code's CLI for the plugin; a test stands one in (without one, a test run leaves the plugin alone).
    @ObservationIgnored var routerPluginRunner: ClaudePluginInstaller.Runner?
    /// Who may make the relay key (see `RelayKeyFence`), and the key as last read (see `signRelay`).
    @ObservationIgnored let relayKeyFence = RelayKeyFence()
    @ObservationIgnored var relayKeyCache: RelayKeyCache?
    @ObservationIgnored var mutedIDsCache: (muted: [String], starts: [PendingDesktopStart], folders: [String: String], result: Set<String>)?
    /// Takes back a delivery through its session's plugin ; tests answer for it. Nil: `cancelDelivery`.
    @ObservationIgnored var deliveryCanceller: ((RouterDecision.Delivered, @escaping @MainActor @Sendable () -> String?) async throws -> RouterDecision.Cancelled)?
    @ObservationIgnored var pluginQuitObserver: NSObjectProtocol?
    /// Where Claude Code's binary is; the newest copy the Claude app bundles unless a test says otherwise.
    @ObservationIgnored var routerClaudeBinary: (@Sendable () -> String?)?
    /// The app's version, which the plugin's is stamped with.
    @ObservationIgnored var routerAppVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
    @ObservationIgnored let activityReader = Claude.ActivityReader()
    @ObservationIgnored lazy var claudeFeed: ClaudeFeed = {
        let feed = ClaudeFeed(activityReader: activityReader)
        feed.batched = { [weak self] body in if let self { self.batchingClaudeReads(body) } else { body() } }
        feed.gate = motionGate
        return feed
    }()
    /// Derived rows, rebuilt after any change to the agents or what was read (see Agents.swift).
    @ObservationIgnored var agentCache: AgentCache?
    /// Tells a read of the app that was asked for before you changed something from one asked for after.
    @ObservationIgnored var claudeStamp = ClaudeStamp()
    @ObservationIgnored var ingesting = false
    @ObservationIgnored var iconTask: Task<Void, Never>?
    /// Sessions you asked an icon for, picked before the rest (they may not be listed).
    @ObservationIgnored var iconRequests: [String] = []
    /// Sessions with nothing to go on yet (see `iconStamp` for when they're looked at again).
    @ObservationIgnored var iconDeferred: [String: String] = [:]
    @ObservationIgnored var iconsPausedUntil = Date.distantPast
    /// Where icons get their input and their answer (a session's first message by transcript id; Jev's choice from
    /// options, hints, state and instructions). Tests swap them for the disk and the network.
    @ObservationIgnored var iconFirstMessage: (@Sendable (String) -> String?)?
    @ObservationIgnored var iconChooser: (([String], [String: String], [String: String], String) async throws -> JevClient.Choice)?
    @ObservationIgnored var typesafeKeyCache: String?
    /// Jev's reading of the inbox (InboxJev.swift): tests answer for TypeSafe.
    @ObservationIgnored var inboxAsker: InboxJev.Asker?
    /// What every call to Jev goes through (JevGate.swift).
    @ObservationIgnored let jevGate = JevGate()
    /// What keeps a key in the Keychain (tests answer for it).
    @ObservationIgnored var keychainWrite: ((String, String) -> Bool)?
    @ObservationIgnored private var transcriptWatcher: FolderWatcher?
    @ObservationIgnored private var sessionsWatcher: FolderWatcher?
    @ObservationIgnored private var dotsWatcher: FolderWatcher?
    @ObservationIgnored var claudeTimer: Timer?
    @ObservationIgnored private var claudeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var screensAsleep = false

    private nonisolated static func isClaude(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Claude.bundleID
    }

    /// Where the state is kept, when not in the user's own file: a test's, in a folder of its own. A test run that reaches the
    /// user's file stops (see `UnderTest`).
    @ObservationIgnored var stateFile: URL?

    /// Where the state file is (its neighbours live beside it).
    var stateFileURL: URL? { file }

    /// The file the state is read from and written to; nil when a test has not said where, and was stopped for it.
    private var file: URL? {
        if let stateFile { return stateFile }
        return UnderTest.refuses("the saved state (Application Support/Fjord/state.json)") ? nil : Self.fileURL
    }

    nonisolated private static let fileURL: URL = {
        let dir = AppIdentity.supportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    // MARK: Lifecycle

    /// `load()`, then `startServices()`: launch can run them a turn apart (the bar shown between them).
    func start() {
        load()
        wireNotifications()
        startServices()
    }

    /// The banners' clicks routed to the store and the notification center's delegate set: at launch, before it finishes
    /// (a click that launched the app is delivered then) and before anything chains its own routing onto `notifier.onOpen`
    /// (`RouterBanners.attach`), which `startServices` leaves alone.
    func wireNotifications() {
        notifier.onOpen = { [weak self] id, url in self?.openNotification(id: id, url: url) }
        notifier.attach()
    }

    /// Everything that runs once the state is loaded (`load()`) and the banners wired (`wireNotifications()`): asking for
    /// banners, updates, the sleep observer, GitHub's polling, Claude's sessions, the Router, the code folders and the
    /// Keychain's read.
    func startServices() {
        if !UnderTest.isRunning {
            ClaudeMark.warm()
            // The icons this Mac can draw (some thousand symbol lookups), worked out before an icon is first picked.
            SessionIcons.warm()
        }
        notifier.requestAuthorization()
        updater.automatic = { [weak self] in self?.settings.checkUpdates ?? true }
        updater.skipped = { [weak self] in self?.settings.skippedVersion }
        updater.onSkip = { [weak self] in self?.settings.skippedVersion = $0 }
        updater.start()
        if !UnderTest.isRunning { Task { await resumeEngineHandoffIfPending() } }
        observeSleep()
        if triageOn { restartPolling() }
        // The Router is the only reader of Claude's sessions, and they have no switch of their own: they follow it.
        if agents.enabled != router.enabled {
            agents.enabled = router.enabled
            if router.enabled { agents.enabledAt = agents.enabledAt ?? Date() }
        }
        watchClaude()
        startRouter()
        if !Store.isDemo { codeFolders.start() }
        Task.detached(priority: .utility) {
            let key = Keychain.read(Keychain.typesafe) ?? ""
            await MainActor.run { [weak self] in
                // A key saved meanwhile (Settings) is newer than this read.
                guard let self, self.typesafeKeyCache == nil else { return }
                self.typesafeKeyCache = key
                self.hasTypesafeKey = !key.isEmpty
                self.pickIcons()
                self.typesafeKeyArrived()
            }
        }
    }

    /// File events give near-instant updates: the sessions folder triggers a read of the sessions, the app's local
    /// storage (where it lazily writes the sidebar dots) only a re-read of the dots. What events can't tell is covered
    /// by the app launching, quitting or coming to the front, and by a one-shot timer (see `scheduleClaudeTick`).
    func watchClaude() {
        sessionsWatcher = nil
        dotsWatcher = nil
        transcriptWatcher = nil
        claudeTimer?.invalidate()
        claudeTimer = nil
        claudeDeadline = nil
        let center = NSWorkspace.shared.notificationCenter
        claudeObservers.forEach { center.removeObserver($0) }
        claudeObservers = []
        guard agents.enabled else { return }
        sessionsWatcher = FolderWatcher([Claude.sessionsDir]) { [weak self] in
            MainActor.assumeIsolated { self?.refreshClaude() }
        }
        // The app writes to its leveldb in bursts: one read of the dots per couple of seconds is plenty.
        dotsWatcher = FolderWatcher([Claude.localStorageDir], latency: 2) { [weak self] in
            MainActor.assumeIsolated { self?.refreshUnread() }
        }
        // Transcripts change with every step an agent takes: only the working sessions' tails are read, and only the
        // transcripts of working sessions (and those with background tasks) are worth waking up for. The filter runs
        // on the watcher's queue; `isRelevant` takes its own lock.
        let feed = claudeFeed
        transcriptWatcher = FolderWatcher([Claude.transcriptsDir], latency: 0.5, relevant: { feed.isRelevant($0) }) { [weak self] in
            MainActor.assumeIsolated { self?.refreshActivity() }
        }
        func watch(_ name: Notification.Name, _ then: @escaping @MainActor (Store) -> Void) {
            claudeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard Self.isClaude(note) else { return }
                MainActor.assumeIsolated { if let self { then(self) } }
            })
        }
        // Whether the app is open decides if a session still "runs"; being in front, which one you're looking at.
        watch(NSWorkspace.didLaunchApplicationNotification) { $0.refreshClaude() }
        watch(NSWorkspace.didTerminateApplicationNotification) { $0.refreshClaude() }
        watch(NSWorkspace.didActivateApplicationNotification) { $0.refreshClaude() }
        claudeObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = true
                self?.claudeTimer?.invalidate()
                self?.claudeTimer = nil
                self?.claudeDeadline = nil
            }
        })
        claudeObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screensAsleep = false
                self.refreshClaude()
            }
        })
        screensAsleep = false
        refreshClaude()
    }

    /// How soon to read again because a session's background work isn't known yet (see `RouterFeed.update`): only while the
    /// Router waits on a finished turn of a session that isn't running, or a waiting card on another session (`resolveWaits`),
    /// and the last read couldn't say. Nil otherwise (no tick for it at rest).
    var inventoryRecheck: TimeInterval? {
        guard router.enabled, let inventory = claudeTaskInventory else { return nil }
        let watched = router.cards.compactMap { card -> String? in
            guard card.isOpen, card.kind == .waiting, card.triage?.ready == nil,
                  case .session(let id, _) = card.triage?.watch?.target else { return nil }
            return id
        }
        let waiting = (Array(router.pendingTurns.keys) + watched).contains { id in
            claudeSessions[id].map { !$0.running && !inventory.contains(id) } ?? false
        }
        return waiting ? Self.inventoryRecheckDelay : nil
    }

    /// Past the five seconds a command just listed has to show up open (see `Claude.TaskReader.read`).
    nonisolated static let inventoryRecheckDelay: TimeInterval = 5

    /// What nothing announces is the clock: a turn with no summary stops counting as running two hours after its last
    /// message, and a background subagent that stopped writing is given up on. One timer, set after each read for the
    /// first moment something can expire (and none while the screens are asleep or nothing is running).
    func scheduleClaudeTick() {
        guard agents.enabled, persists, !screensAsleep else {
            claudeTimer?.invalidate()
            claudeTimer = nil
            claudeDeadline = nil
            return
        }
        var next: TimeInterval?
        let now = Date()
        for session in claudeSessions.values where session.running {
            let left = (session.lastUserMessage ?? .distantPast).addingTimeInterval(Claude.runningTimeout).timeIntervalSince(now)
            next = min(next ?? left, left)
        }
        // Sessions with background work: its end isn't always an event (a command's process just exits).
        if !claudeTasks.isEmpty { next = min(next ?? 60, 60) }
        // A finished turn the Router waits to card while what it left running isn't known yet: read again soon (past the
        // grace a just-listed command gets), until it is.
        if let recheck = inventoryRecheck { next = min(next ?? recheck, recheck) }
        // Icon picking waits out a failure (a rejected key waits for a new one instead).
        if agents.iconsEnabled, iconsPausedUntil > now, iconsPausedUntil < .distantFuture {
            next = min(next ?? .infinity, iconsPausedUntil.timeIntervalSince(now))
        }
        guard let next else { return }
        let deadline = now.addingTimeInterval(max(next, 1) + 1)
        // Frequent reads must not keep pushing it back: it only moves earlier.
        if claudeTimer?.isValid == true, let current = claudeDeadline, current <= deadline { return }
        claudeTimer?.invalidate()
        claudeDeadline = deadline
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.claudeDeadline = nil
                self?.refreshClaude()
            }
        }
        timer.tolerance = max(next, 1) * 0.1 + 2
        RunLoop.main.add(timer, forMode: .common)
        claudeTimer = timer
    }

    /// Polls GitHub on a loop; nothing with Triage off.
    func restartPolling() {
        stopPolling()
        guard triageOn else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.systemAsleep { await self.pollAll() }
                await self.sleepUntilNextPoll()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        sleeper?.cancel()
    }

    /// A check of GitHub now; nothing with Triage off.
    func refreshNow() {
        guard triageOn else { return }
        authRetry = true
        // Asked for during a poll: that one may be on its way out with what it knew before, so one more follows it.
        if isSyncing { refreshQueued = true } else { Task { await pollAll() } }
    }

    /// The hub being open means someone is looking: poll faster meanwhile, and, once the window is open (`window`), sync now
    /// if stale. A peek (the bar hovered, `window` false) syncs nothing at once: its rows would shuffle under the pointer
    /// when the answer came. The sleeper set for the longer interval is set again for the shorter once the window's morph
    /// has played (`MotionGate`), so no poll's work starts under it unless the inbox is stale.
    func setHubOpen(_ open: Bool, window: Bool = true) {
        let windowWas = hubWindowOpen
        hubWindowOpen = open && window
        guard open != hubOpen || hubWindowOpen != windowWas else { return }
        hubOpen = open
        // The window opened (not a peek, which polls nothing at once): once its morph has played, a sleeper due later than
        // the open hub's interval from the last poll is woken, and sleeps again for the shorter one.
        if hubWindowOpen, !windowWas {
            motionGate.whenStill { [weak self] in
                guard let self, self.hubWindowOpen, let wakes = self.sleeperWakes,
                      wakes > (self.lastSync ?? .distantPast).addingTimeInterval(self.effectivePollInterval) else { return }
                self.sleeper?.cancel()
            }
        }
        guard hubWindowOpen, !windowWas, !isSyncing else { return }
        // Signed out for want of a token, `gh auth login` may have been run since: look again, however recent the last poll.
        if awaitsToken || Date().timeIntervalSince(lastSync ?? .distantPast) > 60 { refreshNow() }
    }

    /// Signed out with no token to ask GitHub about: the only case where a look for one (it reads the Keychain and may run
    /// `gh`) is likely to find something new, once the user has signed in elsewhere.
    private var awaitsToken: Bool { me == nil && gh.token == nil && authError != nil }

    /// `gh auth login` was run in Terminal, which the app comes back from: the look the polls hold back (see `authBackoff`)
    /// is made now. Nothing happens for any other reason to be signed out.
    func appBecameActive() {
        if awaitsToken, !isSyncing { refreshNow() }
    }

    /// How often to poll: the setting, at most 30 s while the hub is open, and doubled in Low Power Mode whichever it is.
    private var effectivePollInterval: TimeInterval {
        let base = settings.pollInterval
        return (hubOpen ? min(base, 30) : base) * (ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : 1)
    }

    /// Sleeps in slices so a change (hub opening, wake, new interval) can cut it short.
    private func sleepUntilNextPoll() async {
        while !Task.isCancelled {
            if pollNow, !systemAsleep {
                pollNow = false
                return
            }
            var wait = 3600.0
            if !systemAsleep {
                wait = effectivePollInterval - Date().timeIntervalSince(lastSync ?? .distantPast)
                // Out of calls: nothing is sent before the reset, so that is when to check again, whatever is left of the interval.
                if rateRemaining == 0, let reset = rateResetsAt {
                    if reset <= Date(), (lastSync ?? .distantPast) < reset, !isSyncing { return }
                    if reset > Date() { wait = min(wait, reset.timeIntervalSinceNow) }
                }
                if wait <= 0 {
                    if !isSyncing { return }
                    wait = 1
                }
            }
            let seconds = wait
            let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
            sleeper = task
            sleeperWakes = Date(timeIntervalSinceNow: seconds)
            await task.value
            // Over: nothing is asleep until the next one (unless another sleep has taken its place meanwhile).
            if sleeper == task {
                sleeper = nil
                sleeperWakes = nil
            }
        }
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemAsleep = true }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.systemAsleep = false
                    self.pollNow = true
                    self.sleeper?.cancel()
                }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appBecameActive() }
            },
        ]
    }

    // MARK: Persistence

    func load() {
        loading = true
        defer { loading = false }
        guard let file else { return }
        // Nothing read: nothing was fetched for any category.
        fetchedFor = .categories([], [])
        // Read and decoded off the main thread at launch, when it was (`readSavedStateEarly`).
        let early = Self.early.take(file)
        let data: Data
        do {
            let bytes = try early.map { try $0.data.get() } ?? Self.readExisting(file)
            guard let read = bytes else { loadActions(); return }
            data = read
        } catch {
            // There but unreadable (its mode, say): not fresh state. Nothing is written over it until it can be read and
            // kept aside (see `writeSnapshot`). The actions' file is read (and kept from being written over) all the same.
            unreadable = file
            onDefaults = true
            stateSaveProblem = "state.json can't be read: \(error.localizedDescription)" + Self.onDefaultsNote
            Self.stateLog.error("the saved state can't be read (it isn't written over until it can be): \(error.localizedDescription, privacy: .public)")
            loadActions(keepingAside: true)
            return
        }
        guard let state = early.map({ $0.state }) ?? Self.decodeState(data) else {
            keepAside(file, data, dropped: ["everything"])
            loadActions(keepingAside: true)
            return
        }
        if !state.dropped.isEmpty { keepAside(file, data, dropped: state.dropped) }
        settings = state.settings
        agents = state.agents ?? AgentsState()
        var router = state.router ?? RouterState()
        router.settleInterrupted()
        // What was saved isn't news for the Brief.
        routerDigester.suspended = true
        self.router = router
        routerDigester.suspended = false
        changingInbox(.load) {
            if let c = state.categories { categories = c }
            groups = state.groups ?? []
            categorySections = state.categorySections ?? [.github]
        }
        snippets = state.snippets ?? []
        things = state.things ?? [:]
        // (A file from before it was saved: the categories it was saved with.)
        if state.things != nil { fetchedFor = state.fetchedFor ?? .categories(categories, groups) }
        // An edit not taken in when the app quit still waits for what it asks for to be fetched.
        if state.baselinePending == true {
            baselinePending = true
            baselineAwaitsFetch = true
        }
        marks = state.marks ?? [:]
        categoryBaselines = state.categoryBaselines ?? [:]
        ownedRepos = state.ownedRepos ?? []
        contributedRepos = state.contributedRepos ?? []
        myTeams = state.myTeams ?? []
        reposResolvedAt = state.reposResolvedAt
        login = state.login ?? ""
        savedRevision = persistedRevision
        loadActions()
        // Once the login, marks and actions' records are in: carried during the load, a cached rating or Done was lost.
        loading = false
        carryAssignmentStamps(seenBefore: things)
        // The Brief compares with the state as loaded, not as the Store was before it.
        routerDigester.baseline(store: self)
    }

    /// The saved state as decoded from what the file held; nil when it doesn't decode.
    nonisolated static func decodeState(_ data: Data) -> PersistedState? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PersistedState.self, from: data)
    }

    /// The saved state as read (what `readExisting` gave, or its error) and decoded off the main thread.
    struct SavedRead: @unchecked Sendable {
        let file: URL
        let data: Result<Data?, Error>
        let state: PersistedState?
    }

    /// Starts reading and decoding the user's saved state on a background queue, at launch's first line (beside the fonts):
    /// the first `load()` of that file takes it, waiting for it if it isn't done, rather than decoding half a megabyte of
    /// JSON on the main thread. Nothing writes the file before that load.
    nonisolated static func readSavedStateEarly(at file: URL? = nil) { early.start(file ?? fileURL) }
    nonisolated private static let early = EarlyRead()

    private final class EarlyRead: @unchecked Sendable {
        private let lock = NSLock()
        /// The read under way, as a work item: the main thread waiting on it (`take`) lends it its priority, which a
        /// semaphore wouldn't.
        private var pending: (file: URL, work: DispatchWorkItem)?
        private var result: SavedRead?

        func start(_ file: URL) {
            let work = DispatchWorkItem(qos: .userInteractive, flags: .enforceQoS) { [self] in
                let data = Result { try Store.readExisting(file) }
                let state = (try? data.get()).flatMap { $0 }.flatMap(Store.decodeState)
                lock.withLock { result = SavedRead(file: file, data: data, state: state) }
            }
            guard lock.withLock({ () -> Bool in
                guard pending == nil else { return false }
                pending = (file, work)
                return true
            }) else { return }
            DispatchQueue.global(qos: .userInteractive).async(execute: work)
        }

        /// Once: the early read of `file`, waited for; nil when none was begun for it.
        func take(_ file: URL) -> SavedRead? {
            guard let begun = lock.withLock({ () -> (file: URL, work: DispatchWorkItem)? in
                guard let begun = pending, begun.file == file else { return nil }
                pending = nil
                return begun
            }) else { return nil }
            begun.work.wait()
            return lock.withLock { defer { result = nil }; return result }
        }
    }

    /// A file read only in part is copied aside (`state.json.bak-<date>`) before anything is written over it: what this
    /// build couldn't read (a newer build's, or a damaged part) can still be brought back by hand.
    /// Until that copy is made, nothing is written over the file: each write tries the copy again first, and the changes
    /// wait in memory (see `writeSnapshot`).
    private func keepAside(_ file: URL, _ data: Data, dropped: [String]) {
        guard persists else { return }
        do {
            let backup = try (keepAsideStandIn ?? { try Self.keepAside($0, of: $1) })(data, file)
            unkept = nil
            Self.stateLog.error("the saved state was read only in part (\(dropped.joined(separator: ", "), privacy: .public) lost): kept as \(backup, privacy: .public)")
        } catch {
            unkept = (file, data, dropped)
            stateSaveProblem = "state.json, read only in part, can't be kept aside: \(error.localizedDescription)"
            Self.stateLog.error("the saved state was read only in part, and keeping it aside failed (it isn't written over until it is): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A file read only in part not yet kept aside: what it held, and what was lost of it.
    @ObservationIgnored private var unkept: (file: URL, data: Data, dropped: [String])?
    /// A file that was there but couldn't be read at launch: nothing is written over it until it can be read and kept aside.
    @ObservationIgnored private var unreadable: URL?

    /// What `file` holds; nil only when it isn't there (fresh state). Any other failure to read it throws.
    nonisolated static func readExisting(_ file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch {
            let ns = error as NSError
            let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            if (ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileReadNoSuchFile.rawValue)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
                || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)) {
                return nil
            }
            throw error
        }
    }
    /// Stands in for `Store.keepAside(_:of:)` (tests).
    @ObservationIgnored var keepAsideStandIn: ((Data, URL) throws -> String)?

    /// Distinct copies kept aside of a file, at most: the oldest go first.
    nonisolated static let maxBackups = 5

    /// Copies `data` (what `file` held) beside it as `<name>.bak-<date>`, unless a copy with the same bytes is already
    /// there (the same damaged file, launch after launch, is kept once); past `maxBackups` copies the oldest go. Returns
    /// the copy's name.
    nonisolated static func keepAside(_ data: Data, of file: URL, now: Date = Date()) throws -> String {
        let fm = FileManager.default
        let folder = file.deletingLastPathComponent()
        let prefix = file.lastPathComponent + ".bak-"
        // Oldest first.
        func made(_ name: String) -> Date {
            ((try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.creationDate] as? Date) ?? .distantPast
        }
        let kept = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(prefix) }
            .map { ($0, made($0)) }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.map(\.0)
        if let same = kept.first(where: { (try? Data(contentsOf: folder.appendingPathComponent($0))) == data }) { return same }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        var name = prefix + format.string(from: now)
        var n = 1
        while kept.contains(name) || fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            n += 1
            name = prefix + format.string(from: now) + "-\(n)"
        }
        try data.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
        for old in kept.dropLast(max(0, maxBackups - 1)) { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
        return name
    }

    /// Each Store writes on queues of its own (production has one Store): another cannot hold this one's writes up.
    private let writer = DispatchQueue(label: "fjord.save")
    /// Where actions.json is written: off the main thread, one write at a time, in the order asked.
    let actionsWriter = DispatchQueue(label: "fjord.actions.save", qos: .utility)

    /// Coalesced: the write happens shortly after the last call, off the main thread.
    func save() { scheduleSave(after: .milliseconds(500)) }

    private func scheduleSave(after delay: Duration) {
        // (Asked now, not when the write comes: a test that reaches the user's file is stopped where it did.)
        guard persists, !loading, file != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.writeSnapshot(wait: false)
        }
    }

    /// Writes any pending change now (quitting): one that failed before is tried again, twice if need be.
    func flushSave() {
        flushActions()
        saveTask?.cancel()
        writeSnapshot(wait: true)
        if persistedRevision != savedRevision { writeSnapshot(wait: true) }
    }

    /// Writes that failed in a row: the next is tried after a longer wait (2, 4, 8… seconds, a minute at most).
    @ObservationIgnored private var saveFailures = 0
    private static let stateLog = Logger(subsystem: InboxLog.subsystem, category: "state")

    private func writeSnapshot(wait: Bool) {
        guard persistedRevision != savedRevision, persists, !loading else {
            if wait { writer.sync {} }
            return
        }
        guard let url = file else { return }
        let revision = persistedRevision
        if let unreadable {
            do {
                if let data = try Self.readExisting(unreadable) { keepAside(unreadable, data, dropped: ["everything"]) }
                self.unreadable = nil
            } catch {
                wrote(revision, failure: "the saved state can't be read, so it isn't written over: \(error.localizedDescription)", retry: !wait)
                return
            }
        }
        if let unkept {
            keepAside(unkept.file, unkept.data, dropped: unkept.dropped)
            guard self.unkept == nil else {
                wrote(revision, failure: "the file read only in part isn't kept aside yet, so it isn't written over", retry: !wait)
                return
            }
        }
        let box = SnapshotBox(state: PersistedState(settings: settings, agents: agents, router: router, categories: categories,
                                                       groups: groups, categorySections: categorySections, things: things, marks: marks,
                                                       categoryBaselines: categoryBaselines, ownedRepos: ownedRepos,
                                                       contributedRepos: contributedRepos, reposResolvedAt: reposResolvedAt,
                                                       myTeams: myTeams, login: login.isEmpty ? nil : login,
                                                       fetchedFor: fetchedFor, baselinePending: baselinePending ? true : nil,
                                                       snippets: snippets))
        let write: @Sendable () -> String? = {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.userInfo[Scope.withLegacyKind] = true
            do {
                try enc.encode(box.state).write(to: url, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if wait {
            wrote(revision, failure: writer.sync(execute: write), retry: false)
        } else {
            writer.async {
                let failure = write()
                Task { @MainActor [weak self] in self?.wrote(revision, failure: failure, retry: true) }
            }
        }
    }

    /// Only a write that happened counts as saved: one that failed leaves the change pending, says why in the log, and is
    /// tried again later (and when quitting).
    private func wrote(_ revision: Int, failure: String?, retry: Bool) {
        guard let failure else {
            saveFailures = 0
            savedRevision = revision
            stateSaveProblem = nil
            onDefaults = false
            return
        }
        saveFailures += 1
        stateSaveProblem = "Saving state.json failed: \(failure)" + (onDefaults ? Self.onDefaultsNote : "")
        Self.stateLog.error("saving the state failed (\(self.saveFailures, privacy: .public) in a row): \(failure, privacy: .public)")
        // (A change made since has a write of its own coming, which retries in turn.)
        if retry, persistedRevision == revision {
            scheduleSave(after: .seconds(min(60, 1 << min(saveFailures, 6))))
        }
    }

    private struct SnapshotBox: @unchecked Sendable { let state: PersistedState }

    private static let onDefaultsNote = "\nRunning on defaults until the file can be read"

    // MARK: Derived

    /// Whether notifications are snoozed. The views that read it are redrawn once, when the snooze runs out (`snoozeRevision`):
    /// nothing changes in the settings then, and nothing ticks for it.
    var isSnoozed: Bool {
        _ = snoozeRevision
        return (settings.snoozeUntil ?? .distantPast) > Date()
    }

    /// Bumped when a snooze's deadline passes.
    private var snoozeRevision = 0
    @ObservationIgnored private var snoozeExpiry: (deadline: Date, task: Task<Void, Never>)?

    /// One cancellable one-shot at the snooze's deadline, kept in step with the setting.
    private func armSnoozeExpiry() {
        guard let until = settings.snoozeUntil, until > Date() else {
            snoozeExpiry?.task.cancel()
            snoozeExpiry = nil
            return
        }
        guard snoozeExpiry?.deadline != until else { return }
        snoozeExpiry?.task.cancel()
        snoozeExpiry = (until, Task { [weak self] in
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
            guard !Task.isCancelled, let self else { return }
            snoozeRevision &+= 1
            snoozeExpiry = nil
        })
    }

    // MARK: Notification clicks

    /// A clicked banner: `inbox:<thing id>` opens the thing's category with it selected, a summary opens the inbox, and
    /// anything else the page it was about.
    func openNotification(id: String, url: String?) {
        if id.hasPrefix(Self.inboxNotificationPrefix) {
            let thing = String(id.dropFirst(Self.inboxNotificationPrefix.count))
            if let entry = entries.first(where: { $0.id == thing }) {
                onOpenInbox?(entry.categoryID, thing)
                return
            }
        } else if id.hasPrefix(Notifier.summaryPrefix) {
            onOpenInbox?(nil, nil)
            return
        }
        if let url = [url, id].lazy.compactMap({ $0.flatMap { URL(string: $0) } }).first(where: { $0.scheme == "https" }) {
            // The thing is gone (closed, or no rule holds it): the page it was about still makes sense.
            Link.open(url)
        }
    }

    /// Notification ids of inbox things: `inbox:<thing id>`.
    nonisolated static let inboxNotificationPrefix = "inbox:"

    /// Playground: report what would open instead of opening it.
    @ObservationIgnored var interceptOpen: ((String) -> Void)?
    /// Where this store's own announcements go (VoiceOver, through `Announce`): a test listens to its store alone here,
    /// so what other stores say meanwhile (other tests running beside it) never reaches it.
    @ObservationIgnored var announce: (_ text: String, _ again: Bool) -> Void = { Announce.say($0, again: $1) }

    func shortcut(_ action: ShortcutAction) -> Shortcut {
        settings.shortcuts?[action.rawValue] ?? action.defaultShortcut
    }

    /// A stored system-wide shortcut that another app held when Fjord tried to register it.
    func isShortcutHeldByAnotherApp(_ action: ShortcutAction) -> Bool {
        refusedShortcuts[action].map { $0 == shortcut(action) } ?? false
    }

    /// `nil` resets to the default. A global one the system refuses (another app holds the key) is not kept: the one that
    /// works stays stored and registered, and the refusal is returned.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) -> ShortcutRefusal? {
        var all = settings.shortcuts ?? [:]
        all[action.rawValue] = shortcut == action.defaultShortcut ? nil : shortcut
        let wanted = all[action.rawValue] ?? action.defaultShortcut
        if action.isGlobal, onGlobalShortcutChange?(action, wanted) == false { return .unavailable(wanted) }
        settings.shortcuts = all.isEmpty ? nil : all
        return nil
    }

    /// Asks the system again for the stored system-wide key another app held, which it may have let go of since.
    func retryShortcut(_ action: ShortcutAction) -> Bool {
        !action.isGlobal || onGlobalShortcutChange?(action, shortcut(action)) != false
    }

    /// A recorder starts listening; one that already was is stopped, so only one ever is.
    func beginRecordingShortcut(stop: @escaping () -> Void) {
        stopRecorder?()
        stopRecorder = stop
        onRecordingShortcutChange?(true)
    }

    func endRecordingShortcut() {
        stopRecorder = nil
        onRecordingShortcutChange?(false)
    }

    func snooze(for seconds: TimeInterval?) {
        settings.snoozeUntil = seconds.map { Date().addingTimeInterval($0) }
    }

    func snoozeUntilTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        settings.snoozeUntil = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
    }

    // MARK: Auth

    /// Signs in with the token held, else the one `resolveToken` finds. A token already held is asked about as it is: finding one
    /// reads the Keychain and may run `gh`, which a poll that fails (offline, a VPN down, GitHub's own trouble) would do every
    /// minute. Only no token, one GitHub refused (`dropRejectedToken`), or a change in Settings (`setToken`) looks again.
    func authenticate() async {
        // What Settings changes while this waits (on the token found, or on /user) is about another token: nothing of it is kept.
        let asked = credentialsChanged
        if gh.token == nil || foundAt != credentialsChanged {
            let attemptBefore = lastAuthAttempt
            lastAuthAttempt = Date()
            let find = resolveToken
            let resolved = await Task.detached(operation: find).value
            // What it found is said once the window's morph has played (`MotionGate`).
            await motionGate.still()
            // Its poll cancelled meanwhile: nothing was found as far as the backoff goes, so the next poll looks again.
            if Task.isCancelled { lastAuthAttempt = attemptBefore }
            guard asked == credentialsChanged, !Task.isCancelled else { return }
            guard let (token, source) = resolved else {
                gh.token = nil
                me = nil
                tokenSource = nil
                unreachable = false
                signInFailed("No GitHub token found. Run `gh auth login`, or paste a token in Settings.")
                return
            }
            gh.token = token
            tokenSource = source
            foundAt = asked
        }
        let user: GHUser
        do {
            user = try await gh.get("/user", as: GHUser.self)
        } catch {
            await motionGate.still()
            guard asked == credentialsChanged, !Task.isCancelled else { return }
            if error is URLError {
                // Only a missing or refused token is a sign-in problem: an earlier one is not this attempt's.
                authError = nil
                unreachable = true
                return
            }
            me = nil
            unreachable = false
            signInFailed(error.localizedDescription)
            return
        }
        await motionGate.still()
        guard asked == credentialsChanged, !Task.isCancelled else { return }
        me = user
        authError = nil
        awaitingSignIn = false
        unreachable = false
    }

    /// Sets the sign-in problem. The editor in Settings closes once the Keychain has a token, before GitHub answers, so the
    /// refusal of what was just saved is said too, once; a later poll's is only shown.
    private func signInFailed(_ reason: String) {
        authError = reason
        guard awaitingSignIn else { return }
        awaitingSignIn = false
        announce(reason, true)
    }

    /// Revoked or expired: forget the token and who it was, so the next look resolves one again
    /// (the user may have run `gh auth login` meanwhile).
    private func dropRejectedToken() {
        gh.token = nil
        me = nil
        tokenSource = nil
        lastAuthAttempt = nil
        authError = "GitHub rejected the token. Run `gh auth login` again, then Retry."
    }

    /// Keeps `token` in the Keychain, or removes it with nothing, and signs in again with what is there. False when the
    /// Keychain refused it: nothing changes then, and the token that was saved before still signs in.
    @discardableResult
    func setToken(_ token: String?) -> Bool {
        if let token, !token.isEmpty {
            guard (keychainWrite ?? Keychain.write)(token, Keychain.github) else { return false }
        } else {
            Keychain.delete()
        }
        me = nil
        awaitingSignIn = true
        credentialsChanged += 1
        refreshNow()
        return true
    }

    // MARK: Repos

    func loadSuggestions() async {
        guard suggestions.isEmpty else { return }
        if me == nil { await authenticate() }
        var names: [String] = []
        if let involved: GHSearch<GHIssue> = try? await gh.get("/search/issues", ["q": "involves:@me", "sort": "updated", "per_page": "100"]) {
            names += involved.items.compactMap { $0.repositoryUrl.map { repoName(from: $0) } }
        }
        if let mine: [GHRepo] = try? await gh.get("/user/repos", ["sort": "pushed", "per_page": "100", "affiliation": "owner,collaborator,organization_member"]) {
            names += mine.map(\.fullName)
        }
        var seen = Set(things.values.map { $0.repo.lowercased() })
        suggestions = names.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: Polling

    /// Nothing with Triage off, a refresh asked for meanwhile included.
    /// Started, and its end said (`isSyncing`, `lastSync`, a token GitHub refused), once the window's morph has played
    /// (`MotionGate`): all of it is observed.
    /// A poll whose task was cancelled meanwhile (the loop started again) commits nothing, and lets go of `isSyncing`.
    func pollAll() async {
        await motionGate.still()
        guard !Task.isCancelled, triageOn, !isSyncing else { return }
        isSyncing = true
        let synced = await pollOnce()
        await motionGate.still()
        guard !Task.isCancelled else {
            isSyncing = false
            if refreshQueued {
                refreshQueued = false
                Task { await pollAll() }
            }
            return
        }
        if synced, gh.tokenRejected { dropRejectedToken() }
        finishPoll()
    }

    private func finishPoll() {
        do {
            isSyncing = false
            lastSync = Date()
            if rateRemaining != gh.rateRemaining { rateRemaining = gh.rateRemaining }
            rateResetsAt = gh.rateResetsAt
            // A reset learned now (a refresh by hand) may come before the wake the sleeper was set for: it sets that again. One
            // already passed by the time this poll is over (a slow poll) means the calls are back: the loop checks now, once
            // for that reset.
            if gh.rateRemaining == 0, let reset = rateResetsAt, let wakes = sleeperWakes, reset < wakes {
                if reset > Date() {
                    sleeper?.cancel()
                } else if retriedReset != reset {
                    retriedReset = reset
                    pollNow = true
                    sleeper?.cancel()
                }
            }
            if refreshQueued {
                refreshQueued = false
                Task { await pollAll() }
            }
        }
    }

    /// One poll: the sign-in, then the inbox's refresh; whether it got that far.
    private func pollOnce() async -> Bool {
        // Signed out: look for a token when asked (Retry, a refresh) or once the backoff has passed. One already held is
        // asked about at every poll: that is a request, not a look in the Keychain and `gh`.
        let asked = authRetry
        authRetry = false
        // Cancelled (the loop started again): a Retry asked for is still to be made by the next poll.
        defer { if asked, Task.isCancelled { authRetry = true } }
        // A 401 from outside a poll (adding a repo, suggestions) left the token and who it was cached.
        if gh.tokenRejected { dropRejectedToken() }
        if me == nil, asked || gh.token != nil || Date().timeIntervalSince(lastAuthAttempt ?? .distantPast) >= Self.authBackoff {
            await authenticate()
        }
        // Switched off while it signed in: nothing is fetched.
        guard me != nil, triageOn else { return false }
        await syncInbox(manual: asked)
        return true
    }

    /// How long a repo's default branch is taken as known before it is looked up again (an unchanged answer is a 304).
    nonisolated static let defaultBranchRecheck: TimeInterval = 86400

    /// Asks GitHub for the CI of a repo's default branch, and the commit's headline. The default branch is looked up, then
    /// again daily (another may have been made the default: `main` to `release`), and at once when its head is gone; a
    /// lookup again that fails leaves the one known.
    func fetchCI(_ name: String, now: Date = Date()) async throws -> CIStatus {
        var branch = defaultBranches[name]
        if branch == nil || defaultBranchesCheckedAt[name].map({ now.timeIntervalSince($0) >= Self.defaultBranchRecheck }) ?? true {
            do { branch = try await lookUpDefaultBranch(name, now: now) } catch { if branch == nil { throw error } }
        }
        var status = try await fetchBranchCI(name, branch: branch!, now: now)
        // Gone: the lookup it made says which is the default now, and that one is read.
        if status.sha == nil, let found = defaultBranches[name], found != branch {
            branch = found
            status = try await fetchBranchCI(name, branch: found, now: now)
        }
        // Renamed since it was found: the name it has now is the default branch.
        if status.sha != nil, status.branch != branch { defaultBranches[name] = status.branch }
        return status
    }

    /// A repo's default branch, as GitHub has it now, remembered with when it was looked up.
    @discardableResult
    func lookUpDefaultBranch(_ name: String, now: Date = Date()) async throws -> String {
        let info: GHRepo = try await gh.get("/repos/\(name)")
        defaultBranches[name] = info.defaultBranch
        defaultBranchesCheckedAt[name] = now
        return info.defaultBranch
    }

    /// Asks GitHub for the CI of one branch of a repo, and the commit's headline. A branch renamed since (`master` now
    /// `main`) is read as the branch it is now: its head comes under the new name, and so must its Actions runs, filtered by
    /// it. `CIStatus.branch` is that name; a rule's branch keeps its things as it names them (`@master`), so what it, its
    /// marks and waits know them by stays.
    /// A branch that no longer exists (its head not found, its repo found) has no CI: no workflows, no commit (`sha` nil), so
    /// what was read of it before goes; the repo's default branch is learned again meanwhile.
    func fetchBranchCI(_ name: String, branch: String, now: Date = Date()) async throws -> CIStatus {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let ref = branch.addingPercentEncoding(withAllowedCharacters: allowed) ?? branch
        // The branch's head is the commit read: the latest Actions run may be on an older one (a docs commit its path filters
        // skip, while external CI runs on it). All three sources are asked about that commit.
        let head: GHBranch
        do {
            head = try await gh.get("/repos/\(name)/branches/\(ref)")
        } catch let error as GitHubError where error.status == 404 {
            // The repo not found either: that is the error, and what was read of it stays.
            try await lookUpDefaultBranch(name, now: now)
            return CIStatus(branch: branch, sha: nil, url: nil, checkedAt: Date())
        }
        let sha = head.commit.sha
        let current = head.name.flatMap { $0.isEmpty ? nil : $0 } ?? branch
        let (runs, runsRead) = try await branchRuns(name, branch: current, sha: sha, lineage: branch)
        async let checksReq = branchCheckRuns(name, target: sha, branch: branch)
        async let statusReq = branchStatuses(name, target: sha, branch: branch)
        let ((checks, checksRead), (combined, statusesRead)) = try await (checksReq, statusReq)
        // Runs not all read are like checks not all read: what isn't read may still run.
        // Folded off the main thread.
        let reading = await InboxSync.foldCI(runs: runs, sha: sha, checks: checks, combined: combined,
                                             complete: checksRead && statusesRead && runsRead)
        let title = runs.first { $0.headSha == sha }?.displayTitle ?? head.headline
        return CIStatus(branch: current, sha: sha, url: URL(string: "https://github.com/\(name)/commit/\(sha)"),
                        checkedAt: Date(), title: title, updatedAt: reading.changedAt, workflows: reading.workflows,
                        runsCapped: runsRead ? nil : true)
    }

    /// A commit's push-triggered Actions runs on a branch, page by page (GitHub gives 30 unless asked, 100 at most), and
    /// whether all of them were read. Only push-triggered runs count: issue/comment-triggered workflows also run against the
    /// default branch HEAD and would otherwise make CI look red.
    func branchRuns(_ name: String, branch: String, sha: String, lineage: String) async throws -> ([GHWorkflowRuns.Run], Bool) {
        var runs: [GHWorkflowRuns.Run] = []
        for page in 1...Self.ciPages {
            let answer: GHWorkflowRuns = try await gh.get("/repos/\(name)/actions/runs",
                                                          ["branch": branch, "event": "push", "head_sha": sha, "per_page": "100",
                                                           "page": "\(page)"], lineage: lineage)
            runs += answer.workflowRuns
            if answer.workflowRuns.count < 100 || runs.count >= answer.totalCount ?? .max { return (runs, true) }
        }
        return (runs, false)
    }

    /// The pages of check runs or statuses read at most for one commit (100 each): past them, what isn't read may still run.
    nonisolated static let ciPages = 3

    /// A commit's check runs, page by page (GitHub gives 30 unless asked, 100 at most), and whether all of them were read.
    func branchCheckRuns(_ name: String, target: String, branch: String) async throws -> ([GHCheckRuns.Run], Bool) {
        var runs: [GHCheckRuns.Run] = []
        for page in 1...Self.ciPages {
            let answer: GHCheckRuns = try await gh.get("/repos/\(name)/commits/\(target)/check-runs",
                                                       ["per_page": "100", "page": "\(page)"], lineage: branch)
            runs += answer.checkRuns
            if runs.count >= answer.totalCount || answer.checkRuns.isEmpty { return (runs, runs.count >= answer.totalCount) }
        }
        return (runs, false)
    }

    /// A commit's combined status with all its statuses, page by page, and whether all of them were read.
    func branchStatuses(_ name: String, target: String, branch: String) async throws -> (GHCombinedStatus, Bool) {
        var first: GHCombinedStatus?
        var statuses: [GHCombinedStatus.Status] = []
        for page in 1...Self.ciPages {
            let answer: GHCombinedStatus = try await gh.get("/repos/\(name)/commits/\(target)/status",
                                                            ["per_page": "100", "page": "\(page)"], lineage: branch)
            if first == nil { first = answer }
            statuses += answer.statuses
            if statuses.count >= answer.totalCount || answer.statuses.isEmpty { break }
        }
        let combined = GHCombinedStatus(state: first!.state, totalCount: first!.totalCount, sha: first!.sha, statuses: statuses)
        return (combined, statuses.count >= combined.totalCount)
    }

    /// What CI's three sources say about one commit.
    struct CIReading: Equatable {
        /// The latest change among them: an Actions run, an external check run or a legacy status.
        var changedAt: Date?
        /// Each workflow's state and failed jobs (the external checks and legacy statuses together are one more, `external`).
        var workflows: [CIStatus.Workflow] = []
    }

    /// The id of the one workflow that stands for external check runs and legacy statuses.
    nonisolated static let externalWorkflowID = "external"

    /// Folds Actions runs (the latest of each workflow, on `sha`) and their jobs, external check runs and legacy statuses
    /// into each workflow's state and failed names, and when any of them last changed. Any of the three can be all a repo
    /// has. Checks or statuses not all read (`complete` false) may still run: they are running, never passing.
    nonisolated static func readCI(runs: [GHWorkflowRuns.Run], sha: String?, checks: [GHCheckRuns.Run],
                                   combined: GHCombinedStatus, complete: Bool = true) -> CIReading {
        var latest: [Int: GHWorkflowRuns.Run] = [:]
        for run in runs where run.headSha == sha && latest[run.workflowId] == nil { latest[run.workflowId] = run }
        let external = checks.filter { $0.app?.slug != "github-actions" }

        let bad: Set<String> = ["failure", "timed_out", "action_required", "startup_failure"]
        // A failed workflow is named by the jobs that failed in it (each is a check run in the run's own suite); its own
        // name stands in only when none is found. Jobs of runs not chosen above (another trigger) never count.
        let jobs = checks.filter { $0.app?.slug == "github-actions" && bad.contains($0.conclusion ?? "") }
        var workflows: [CIStatus.Workflow] = []
        for run in latest.values.sorted(by: { ($0.name, $0.workflowId) < ($1.name, $1.workflowId) }) {
            var failing: [String] = []
            if bad.contains(run.conclusion ?? "") {
                let failed = jobs.filter { run.checkSuiteId != nil && $0.checkSuite?.id == run.checkSuiteId }.map(\.name)
                failing = failed.isEmpty ? [run.name] : failed
            }
            let state: CIState = !failing.isEmpty ? .failure : run.status != "completed" ? .pending
                : run.conclusion == "cancelled" ? .cancelled : .success
            workflows.append(CIStatus.Workflow(id: "\(run.workflowId)", name: run.name, state: state, failing: failing,
                                               url: run.htmlUrl, updatedAt: run.updatedAt,
                                               run: run.id.map { "ci:\(run.headSha):\($0)#\(run.runAttempt ?? 1)" }))
        }
        if !external.isEmpty || combined.totalCount > 0 || !complete {
            let failing = external.filter { bad.contains($0.conclusion ?? "") }.map(\.name)
                + combined.statuses.filter { $0.state == "failure" || $0.state == "error" }.map(\.context)
            // GitHub's own state of all the statuses counts too (it is "pending" with none, so only when there are some).
            let pending = !complete || external.contains { $0.status != "completed" }
                || combined.statuses.contains { $0.state == "pending" } || (combined.totalCount > 0 && combined.state == "pending")
            // A check stopped before it finished didn't pass.
            let cancelled = external.contains { $0.status == "completed" && $0.conclusion == "cancelled" }
            let changed = external.compactMap { $0.completedAt ?? $0.startedAt }
                + combined.statuses.compactMap { $0.updatedAt ?? $0.createdAt }
            // Another check finishing moves `changed`, not which execution it is: its checks by id, statuses by when posted.
            let ids = external.map { $0.id.map { "c\($0)" } ?? "n\($0.name)" }
                + combined.statuses.map { "s\($0.context)@\(($0.createdAt ?? .distantPast).timeIntervalSince1970)" }
            workflows.append(CIStatus.Workflow(id: externalWorkflowID, name: "Checks",
                                               state: !failing.isEmpty ? .failure : pending ? .pending : cancelled ? .cancelled : .success,
                                               failing: failing, url: nil, updatedAt: changed.max(),
                                               run: InboxSync.ciRun(sha: sha ?? combined.sha, ids: ids), running: pending))
        }
        return CIReading(changedAt: workflows.compactMap(\.updatedAt).max(), workflows: workflows)
    }

    // MARK: Notifications

    /// The inbox's banners; none with Triage off (a refresh under way when it was switched off).
    func notify(id: String, title: String, subtitle: String, body: String, quiet: Bool, url: URL? = nil) {
        guard triageOn, settings.notifications, !isSnoozed else { return }
        // Away, a thing's banner comes only if Jev rates it high or urgent; the others are counted for when you're back.
        if id.hasPrefix(Self.inboxNotificationPrefix) {
            let thing = things[String(id.dropFirst(Self.inboxNotificationPrefix.count))]
            let importance = thing.flatMap { InboxEngine.importance($0, context: inboxContext) }
            if !routerAttention.admitInbox(importance) { return }
        }
        notifier.post(id: id, title: title, subtitle: subtitle, body: body, quiet: quiet, url: url)
    }

    // MARK: Helpers

    private func repoName(from url: URL) -> String {
        url.pathComponents.suffix(2).joined(separator: "/")
    }
}
