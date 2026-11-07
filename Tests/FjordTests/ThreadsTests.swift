import Foundation
import Testing
@testable import Fjord

/// The threads as Fjord lists them, from T3's shell rows: what decides each row's group, what lists it, and what Fjord keeps
/// of its own (icons, labels, colours).
@MainActor
@Suite struct Agents {
    typealias F = T3Fixture

    private func row(_ s: Store, _ id: String) -> ThreadRow? { s.allAgentRows.first { $0.id == id } }
    private func entry(_ s: Store, _ id: String) -> ThreadEntry? { s.agents.entries.first { $0.id == id } }

    @Test func eachRowsGroupComesFromItsShellRow() throws {
        let s = Store.reading([
            F.shell("run", status: "running", extra: ["activityRunStatus": "running"]),
            // The shell keeps `running` while an approval waits (S1 e): the request decides.
            F.shell("ask", status: "running", extra: ["pendingRuntimeRequest": ["id": "rq1", "kind": "command", "blocking": true]]),
            F.shell("plan", extra: ["hasActionableProposedPlan": true]),
            F.shell("new", unseen: true),
            F.shell("seen"),
            F.shell("broke", status: "failed", unseen: true),
            F.shell("brokeSeen", status: "failed"),
            F.shell("queued", status: "queued"),
        ])
        let groups = Dictionary(uniqueKeysWithValues: s.allAgentRows.map { ($0.id, $0.group) })
        #expect(groups == ["run": .working, "ask": .needsYou, "plan": .needsYou, "new": .done, "seen": .idle,
                           "broke": .needsYou, "brokeSeen": .idle, "queued": .working])
        #expect(try #require(row(s, "new")).unread && !(try #require(row(s, "seen")).unread))
        #expect(try #require(row(s, "ask")).waitsForYou)
    }

    @Test func aUsageLimitThatWontResumeNeedsYouAndOneThatWillDoesnt() throws {
        let limit: [String: T3JSON] = ["lastErrorClass": "usage_limit", "usageLimitResetAt": "2030-01-01T15:00:00.000Z"]
        var resumes = limit
        resumes["limitRecovery"] = ["runId": "r1", "resetAt": "2030-01-01T15:00:00.000Z", "autoResume": true]
        let s = Store.reading([F.shell("stuck", status: "failed", extra: limit), F.shell("resumes", status: "failed", extra: resumes)])
        let stuck = try #require(s.threads["stuck"]), resumed = try #require(s.threads["resumes"])
        #expect(stuck.limitStopped && stuck.limitResetAt != nil && !resumed.limitStopped)
        // Seen, the failed one stops asking; the limit that won't resume still does, until it's seen.
        #expect(row(s, "stuck")?.group == .idle && row(s, "resumes")?.group == .idle)
        s.update(F.shell("stuck", status: "failed", unseen: true, extra: limit))
        #expect(row(s, "stuck")?.group == .needsYou)
    }

    @Test func quietThreadsStayAnHourAndOnlyWorkKeepsASettledOneListed() {
        let s = Store.reading([
            F.shell("recent", minutes: 30),
            F.shell("old", minutes: 90),
            F.shell("oldUnseen", minutes: 3 * 24 * 60, unseen: true),
            // Every imported thread is settled: listed only while it works or waits on you.
            F.shell("settled", minutes: 1, unseen: true, extra: ["settledAt": .string(F.ago(1))]),
            F.shell("settledRunning", status: "running", minutes: 1, extra: ["settledAt": .string(F.ago(1))]),
            F.shell("settledAsks", status: "running", minutes: 1, extra: ["settledAt": .string(F.ago(1)),
                    "pendingRuntimeRequest": ["id": "rq", "kind": "user_input", "blocking": true]]),
        ])
        #expect(Set(s.allAgentRows.map(\.id)) == ["recent", "oldUnseen", "settledRunning", "settledAsks"])
        // The rest are still T3's threads: a search finds them.
        #expect(s.threads.count == 6 && s.sessionRow("old") != nil)
    }

    @Test func subagentsArchivedDeletedAndSnoozedThreadsAreNotListed() {
        let s = Store.reading([
            F.shell("a"),
            F.thread("sub", relationship: "subagent"),
            F.shell("archived", extra: ["archivedAt": .string(F.ago(1))]),
            F.shell("deleted", extra: ["deletedAt": .string(F.ago(1))]),
            F.shell("snoozed", unseen: true, extra: ["snoozedUntil": .string(T3Timestamp.format(Date().addingTimeInterval(3600)))]),
            F.shell("woke", unseen: true, extra: ["snoozedUntil": .string(F.ago(1))]),
        ])
        #expect(Set(s.threads.keys) == ["a", "snoozed", "woke"])
        #expect(Set(s.allAgentRows.map(\.id)) == ["a", "woke"])
    }

    @Test func backgroundTasksKeepAFinishedThreadWorkingUntilTheyEnd() throws {
        // A command it didn't say it waits on (a dev server, as often as not) doesn't count, as in T3.
        let tasks: T3JSON = [["taskId": "t1", "kind": "subagent", "description": "Review the changes"],
                             ["taskId": "t2", "kind": "command", "description": "Run the full test suite", "awaited": true],
                             ["taskId": "t3", "kind": "command", "description": "Serve the docs"]]
        let s = Store.reading([F.shell("f", unseen: true, extra: ["pendingBackgroundTasks": tasks])])
        let r = try #require(row(s, "f"))
        #expect(r.group == .working && r.tasksText == "2 running")
        #expect(r.tasks.map(\.kind) == [.agent, .command] && r.tasks.map(\.title) == ["Review the changes", "Run the full test suite"])
        // The work ends: still unseen, so it is done.
        s.update(F.shell("f", unseen: true))
        #expect(row(s, "f")?.group == .done && s.backgroundWork.isEmpty)
    }

    @Test func aThreadsProjectIsItsFolderAndRepoAndTheScratchProjectHasNone() throws {
        let s = Store.reading([F.shell("a"), F.shell("b", project: "scratch")],
                              projects: [F.project("p1", root: "/code/app"), F.project("scratch", title: "No project", root: AgentThread.scratchRoot)])
        let a = try #require(s.threads["a"]), b = try #require(s.threads["b"])
        #expect(a.folder == "/code/app" && a.repo == "acme/garden" && a.projectID == "p1")
        #expect(b.folder == nil && row(s, "b")?.projectName == "Scratch")
        #expect(s.agents.folderColors["/code/app"] != nil && s.agents.folderColors.count == 1)
    }

    @Test func oneThreadsUpdateChangesItsRowAloneAndARemovalTakesItAway() throws {
        let s = Store.reading([F.shell("a", unseen: true), F.shell("b")])
        let before = try #require(s.threads["b"])
        s.update(F.shell("a", status: "running", extra: ["activityRunStatus": "running"]))
        #expect(row(s, "a")?.group == .working && s.threads["b"] == before)
        // Archived in T3: the shell sends the row with the archive's location, or removes it.
        var shell = s.t3.store.shell
        shell.apply(.threadRemoved(sequence: 999, location: .active, threadId: "a"))
        s.t3.store.seed(shell, notify: false)
        s.applyShell(.threadRemoved(sequence: 999, location: .active, threadId: "a"))
        #expect(s.threads["a"] == nil && s.allAgentRows.map(\.id) == ["b"])
    }

    @Test func aProjectsUpdateChangesItsThreadsAlone() throws {
        let s = Store.reading([F.shell("a"), F.shell("b", project: "p2")],
                              projects: [F.project("p1", root: "/code/app"), F.project("p2", root: "/code/web")])
        let b = try #require(s.threads["b"])
        var shell = s.t3.store.shell
        let moved = T3Project(json: F.project("p1", root: "/code/app2"))
        shell.apply(.projectUpdated(sequence: 200, project: moved))
        s.t3.store.seed(shell, notify: false)
        s.applyShell(.projectUpdated(sequence: 200, project: moved))
        #expect(s.threads["a"]?.folder == "/code/app2" && s.threads["b"] == b)
    }

    @Test func theStoreFollowsTheShellStreamWithNoReadOfItsOwn() {
        let s = Store()
        s.persists = false
        s.agents.enabled = true
        // What T3's store does on each item it applies: the threads follow at once.
        s.t3.store.seed(F.state([F.shell("a")]))
        #expect(s.threads.keys.sorted() == ["a"])
        s.t3.store.seed(F.state([F.shell("a"), F.shell("b", status: "running")]))
        #expect(s.threads.keys.sorted() == ["a", "b"] && s.threads["b"]?.running == true)
        // Off: nothing is read, and what was goes.
        s.setAgentsEnabled(false)
        #expect(s.threads.isEmpty)
        s.t3.store.seed(F.state([F.shell("c")]))
        #expect(s.threads.isEmpty)
        s.setAgentsEnabled(true)
        #expect(s.threads.keys.sorted() == ["c"])
    }

    @Test func routingWaitsForT3sFirstWordOnceItWasAskedFor() {
        let s = Store()
        s.persists = false
        s.agents.enabled = true
        s.threadsReadAsked = true
        #expect(!s.threadsReadOnce)
        s.t3.store.seed(F.state([F.shell("a")]))
        #expect(s.threadsReadOnce)
        // No server to hear from counts as word too: the actions don't wait forever.
        let other = Store()
        other.persists = false
        other.threadsReadAsked = true
        other.t3ConnectionChanged(.noServer)
        #expect(other.threadsReadOnce)
    }

    @Test func mutedProjectsAreNotListed() {
        let s = Store.reading([F.shell("a", unseen: true)])
        s.setFolderMuted("/code/app", true)
        #expect(s.allAgentRows.isEmpty)
        s.setFolderMuted("/code/app", false)
        #expect(s.allAgentRows.map(\.id) == ["a"])
    }

    @Test func entriesOfThreadsT3NoLongerHasGo() {
        let s = Store.reading([F.shell("a"), F.shell("b")])
        s.agents.entries = [ThreadEntry(id: "a", icon: "star"), ThreadEntry(id: "gone", icon: "moon")]
        s.t3.store.seed(F.state([F.shell("a"), F.shell("b")]))
        #expect(s.agents.entries.map(\.id) == ["a"])
    }

    // MARK: Icons

    /// Icons on and a key saved, so an icon can be asked for; the store has not read the key, so none is.
    private func keySaved(_ s: Store) {
        s.agents.iconsEnabled = true
        s.hasTypesafeKey = true
    }

    /// A store that asks for icons, with the first message and Jev stood in for: every question gets its first option.
    private func iconStore(_ threads: [T3JSON], firstMessage: String? = "Fix the login form") -> Store {
        let s = Store.reading(threads)
        s.agents.iconsEnabled = true
        s.typesafeKeyCache = "test"
        s.hasTypesafeKey = true
        s.iconFirstMessage = { _ in firstMessage }
        s.iconChooser = { options, _, _, _ in .init(choice: options[0], confidence: 1, probabilities: [options[0]: 1]) }
        return s
    }

    private func finishIcons(_ s: Store) async {
        while let task = s.iconTask { await task.value }
    }

    @Test func askingForAnIconOfAnOldThreadFoundThroughSearchPicksIt() {
        let s = Store.reading([F.shell("a"), F.shell("old", minutes: 3 * 24 * 60)])
        keySaved(s)
        s.repickIcon("old")  // the key is not read yet, so nothing is asked for yet
        #expect(s.iconTarget()?.id == "old")
        #expect(s.allAgentRows.map(\.id) == ["a"])  // still unlisted
        s.agents.entries = [ThreadEntry(id: "old", icon: "star")]
        #expect(s.iconTarget()?.id == "a")
    }

    @Test func theIconPickedForAnOldThreadIsKeptAndSurvivesTheNextChange() async {
        let s = iconStore([F.shell("a"), F.shell("old", minutes: 45 * 24 * 60)])
        s.repickIcon("old")
        await finishIcons(s)
        #expect(entry(s, "old")?.icon != nil && s.allAgentRows.map(\.id) == ["a"])
        s.update(F.shell("old", minutes: 45 * 24 * 60))
        #expect(entry(s, "old")?.icon != nil)
    }

    @Test func anIconPickedForWhatAThreadWasIsPickedAgainAndOneSetMeanwhileWins() async {
        final class Latch: @unchecked Sendable { var open = false }
        let latch = Latch()
        let s = iconStore([F.shell("a")])
        var titles: [String] = []
        s.iconChooser = { options, _, state, _ in
            titles.append(state["session title"] ?? "")
            while !latch.open { try? await Task.sleep(for: .milliseconds(2)) }
            return .init(choice: options[0], confidence: 1, probabilities: [options[0]: 1])
        }
        s.pickIcons()
        for _ in 0..<2000 where titles.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        // Renamed while Jev answers: the pick for the old name isn't taken; one is made for the new.
        s.update(F.shell("a", title: "Fix the login form"))
        latch.open = true
        await finishIcons(s)
        #expect(titles.first == "Thread a" && titles.last == "Fix the login form" && entry(s, "a")?.icon != nil)

        // An icon set by hand while one is picked: yours stays.
        latch.open = false
        titles = []
        s.repickIcon("a")
        for _ in 0..<2000 where titles.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        let i = s.agents.entries.firstIndex { $0.id == "a" }!
        s.agents.entries[i].label = "ZZ"
        latch.open = true
        await finishIcons(s)
        #expect(entry(s, "a")?.icon == nil && entry(s, "a")?.label == "ZZ")
    }

    @Test func aThreadWithNothingToGoOnDoesNotBlockTheOthers() async {
        final class Reads: @unchecked Sendable { var ids: [String] = [] }
        let reads = Reads()
        let s = iconStore([F.shell("u", title: "New thread", minutes: 6), F.shell("b")])
        s.iconFirstMessage = { reads.ids.append($0); return nil }
        await finishIcons(s)
        s.pickIcons()
        await finishIcons(s)
        #expect(entry(s, "b")?.icon != nil && entry(s, "u")?.icon == nil)
        #expect(s.iconTarget() == nil)
        // Later changes don't look at it again, until it has a name.
        s.pickIcons()
        await finishIcons(s)
        #expect(reads.ids.filter { $0 == "u" }.count == 1)
        s.update(F.shell("u", title: "Fix the login form", minutes: 6))
        #expect(s.iconTarget()?.id == "u")
    }

    @Test func aPickedIconStaysWhenNoneCanBePickedToReplaceIt() {
        let s = Store.reading([F.shell("a")])
        s.agents.entries = [ThreadEntry(id: "a", icon: "hammer")]
        // Icons off: the icon is kept (and shown), and cannot be repicked.
        #expect(!s.canPickIcons)
        s.repickIcon("a")
        #expect(s.agents.entries[0].icon == "hammer" && s.agents.entries[0].rejectedIcons == nil)
        s.agents.iconsEnabled = true
        s.repickIcon("a")
        #expect(s.agents.entries[0].icon == "hammer")
        // On, with a key: the old one goes, and is not offered again.
        s.hasTypesafeKey = true
        #expect(s.canPickIcons)
        s.repickIcon("a")
        #expect(s.agents.entries[0].icon == nil && s.agents.entries[0].rejectedIcons == ["hammer"])
    }

    @Test func aRejectedTypesafeKeyIsAnnouncedWhereItHappensAndOnceWhenSettingsShowsIt() async {
        let s = Store.reading([F.shell("a")])
        await Announced.exclusively {
            var said: [String] = []
            Announce.sink = { said.append($0) }
            // Settings is closed: the rejection is still said, and picking waits for a new key.
            s.iconPickFailed(JevClient.Failure.unauthorized)
            #expect(said == ["TypeSafe didn't accept the API key"] && s.iconsPausedUntil == .distantFuture)
            // Settings opened on it says the same line: not twice.
            Announce.say(s.iconError ?? "")
            #expect(said == ["TypeSafe didn't accept the API key"])
            // Another failure is retried later and not announced from here (Settings says it if it is open).
            s.iconPickFailed(JevClient.Failure.transport("TypeSafe is down"))
            #expect(said == ["TypeSafe didn't accept the API key"] && s.iconsPausedUntil < .distantFuture)
            // What Settings shows about a refused save is said by Settings alone, once.
            s.keychainWrite = { _, _ in false }
            #expect(!s.setTypesafeKey("sk-test"))
            Announce.say(s.iconError ?? "")
            #expect(said.count == 2 && said[1] == s.iconError)
        }
    }

    // MARK: Saved state

    @Test func oldStateFilesStillLoad() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"repos":[],"items":[],"ci":{},"settings":{"botHandles":[],"treatAppsAsBots":true,"pollInterval":60,"notifications":true,"reviewRequests":true,"didInitialReviewSync":true}}"#.utf8))
        #expect(state.agents == nil && state.settings.shortcuts == nil)
        let partial = try JSONDecoder().decode(ThreadsState.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(partial.enabled && partial.entries.isEmpty)
    }

    /// Saved when Jev could pick a new session's model and effort: the setting and the history's "picked by" are gone, and
    /// what was saved with them still loads.
    @Test func stateSavedWithJevsSessionModelPickStillLoads() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"settings":{"botHandles":[],"treatAppsAsBots":true,"pollInterval":60,"notifications":true,"centerPill":true,"jevPicksSessionModels":true,"jevReadsDrafts":false}}"#.utf8))
        #expect(state.dropped.isEmpty && state.settings.centerPill == true)
        let decided = try JSONDecoder().decode(RouterDecision.Decided.self, from: Data(#"{"target":"lookout","settingsBy":"Jev"}"#.utf8))
        #expect(decided.target == "lookout")
    }

    /// Saved under `agents` when Fjord read the Claude app: the icons and labels of sessions T3 imported move to T3's ids once,
    /// colours and the switch stay, and the rest (read flags, sessions T3 doesn't have) goes. Saved again under `threads`.
    @Test func theClaudeAppsIconsMoveOnceToTheThreadsT3ImportedThemAs() throws {
        let saved = ThreadsState.desktopCLIIDs
        defer { ThreadsState.desktopCLIIDs = saved }
        var asked = 0
        ThreadsState.desktopCLIIDs = { asked += 1; return ["local_a": "cli-a", "local_b": "cli-b"] }
        let json = #"{"settings":{"botHandles":[],"treatAppsAsBots":true,"pollInterval":60,"notifications":true},"agents":{"enabled":true,"iconsEnabled":true,"paletteVersion":2,"iconsVersion":2,"folderColors":{"/code/app":3},"mutedFolders":["/code/old"],"appUnread":["local_a"],"seeded":true,"entries":[{"id":"local_a","icon":"bell","unread":true,"seen":"3|1"},{"id":"local_b","label":"XY","seen":"1|1"},{"id":"local_c","icon":"star"},{"id":"local_d","seen":"2|2"}]}}"#
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        let threads = try #require(state.agents)
        #expect(threads.entries == [ThreadEntry(id: "import:claudeAgent:cli-a", icon: "bell"), ThreadEntry(id: "import:claudeAgent:cli-b", label: "XY")])
        #expect(threads.enabled && threads.iconsEnabled && threads.folderColors == ["/code/app": 3] && threads.mutedFolders == ["/code/old"])
        #expect(asked == 1)
        // Written back under the new key, and read from it with no second look at the app's files.
        let out = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        #expect(out?["agents"] == nil && out?["threads"] != nil)
        let again = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        #expect(again.agents?.entries == threads.entries && asked == 1)
    }
}

@Suite struct AgentLabels {
    @Test func initialsThenAlternativesWhenTaken() {
        #expect(AgentLabel.candidates("CI failure diagnosis").first == "CF")
        #expect(AgentLabel.candidates("Fix the CI").first == "FC")  // "the" skipped
        let labels = AgentLabel.assign([(id: "1", title: "Lookout agents", custom: nil),
                                        (id: "2", title: "Lookout auth", custom: nil),
                                        (id: "3", title: "Anything", custom: "LA")])
        #expect(labels["3"] == "LA")
        #expect(Set(labels.values).count == 3)
        #expect(labels["1"] != "LA" && labels["2"] != "LA")
    }

    @Test func lettersSkipTheProjectName() {
        #expect(AgentLabel.candidates("LCU update notifications", folder: "lcu").first == "UN")
        #expect(AgentLabel.candidates("LCU computer use", folder: "lcu-research").first == "CU")
        #expect(AgentLabel.candidates("Lookout", folder: "lookout").first == "LO")  // nothing else to use
    }

    @Test func singleWordAndEmptyTitles() {
        let labels = AgentLabel.assign([(id: "1", title: "Zed", custom: nil), (id: "2", title: "", custom: nil),
                                        (id: "3", title: "", custom: nil)])
        #expect(labels["1"] == "ZE")
        #expect(labels["2"] != labels["3"])
    }

}

@MainActor
@Suite struct TypesafeKeySaving {
    @Test func aKeyTheKeychainRefusedIsNotSavedAndSaysSo() {
        let s = Store()
        s.persists = false
        var written: [String] = []
        s.keychainWrite = { key, _ in written.append(key); return false }
        #expect(!s.setTypesafeKey("  sk-test \n"))
        #expect(written == ["sk-test"])
        #expect(!s.hasTypesafeKey && s.typesafeKey == nil)
        #expect(s.iconError != nil)
    }

    @Test func aKeyTheKeychainKeptIsSavedTrimmed() {
        let s = Store()
        s.persists = false
        s.keychainWrite = { _, _ in true }
        #expect(s.setTypesafeKey(" sk-test "))
        #expect(s.hasTypesafeKey && s.typesafeKey == "sk-test" && s.iconError == nil)
    }
}

@Suite struct FolderNaming {
    @Test func aNameIsItsOwnUntilAnotherProjectHasTheSame() {
        let all = ["/work/client/app", "/work/client/api", "/home/me/notes"]
        #expect(all.map { FolderNames.name($0, among: all) } == ["app", "api", "notes"])
        #expect(FolderNames.name("", among: all) == "Scratch")
    }

    @Test func identicalNamesTakeTheShortestPathThatTellsThemApart() {
        let all = ["/work/customer-a/app", "/work/customer-b/app", "/play/app", "/play/other/app", "/solo/tool"]
        #expect(all.map { FolderNames.name($0, among: all) } == ["customer-a/app", "customer-b/app", "play/app", "other/app", "tool"])
    }

    @Test func allTheNamesAtOnceAreWhatEachOneWouldBeAmongTheOthers() {
        // The same rule as one name at a time, which is the definition: the shortest suffix that no other folder shares.
        func reference(_ folder: String, _ all: [String]) -> String {
            func parts(_ f: String) -> [String] { f.split(separator: "/").map(String.init) }
            let own = parts(folder)
            let others = all.filter { $0 != folder }.map(parts)
            var depth = 1
            while depth < own.count, others.contains(where: { $0.suffix(depth) == own.suffix(depth) }) { depth += 1 }
            return own.suffix(depth).joined(separator: "/")
        }
        var all: [String] = []
        for a in 0..<6 { for b in 0..<4 { for c in ["app", "api", "lib"] where (a + b) % 3 != 0 { all.append("/work/g\(a)/p\(b % 2)/\(c)") } } }
        all += ["/play/app", "/app", "/solo/tool", "/x/y/z/app"]
        let names = FolderNames.names(for: Set(all))
        #expect(names.count == Set(all).count)
        for folder in Set(all) { #expect(names[folder] == reference(folder, all), "\(folder)") }
    }

    @MainActor @Test func theNamesFollowTheFolders() {
        let s = Store()
        s.persists = false
        func session(_ id: String, _ folder: String) -> AgentThread {
            AgentThread(id: id, title: id, folder: folder, lastActivity: Date())
        }
        s.threads = ["a": session("a", "/x/app"), "b": session("b", "/y/app")]
        #expect(s.folderNames == ["/x/app": "x/app", "/y/app": "y/app"])
        // A new folder, or a muted one, is named as it comes.
        s.threads["c"] = session("c", "/z/tool")
        #expect(s.folderNames["/z/tool"] == "tool")
        s.agents.mutedFolders = ["/w/app"]
        #expect(s.folderNames["/w/app"] == "w/app" && s.folderNames["/x/app"] == "x/app")
    }
}

