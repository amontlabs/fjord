import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite struct Agents {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func session(_ id: String, turns: Int = 3, minutesAgo: Double = 5, messageMinutesAgo: Double? = nil,
                         focusedMinutesAgo: Double? = 60, folder: String? = "/code/app", blocked: Bool = false,
                         running: Bool = false, archived: Bool = false) -> AgentThread {
        AgentThread(id: id, title: "Session \(id)", folder: folder, isArchived: archived, completedTurns: turns,
                      lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                      lastFocused: focusedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
                      lastUserMessage: now.addingTimeInterval(-(messageMinutesAgo ?? minutesAgo + 1) * 60),
                      summary: running ? nil : .init(blocked: blocked, detail: "Detail \(id)"), running: running)
    }

    /// A store that has already seen `sessions` once (seeded), so later reads are "new activity".
    private func store(_ sessions: [AgentThread], dots: Set<String> = []) -> Store {
        let s = Store()
        s.persists = false
        s.agents.enabled = true
        s.agents.enabledAt = now.addingTimeInterval(-3600)
        s.ingest(sessions, appUnread: dots, claudeFrontmost: false, now: now)
        return s
    }

    /// Unlisted until its next activity, as an entry made only to hold an icon picked for it is (see `Store.ensureEntry`).
    private func holdOnlyForAnIcon(_ s: Store, _ id: String) {
        guard let i = s.agents.entries.firstIndex(where: { $0.id == id }) else { return }
        s.agents.entries[i].hiddenAt = s.agents.entries[i].seen
    }

    private func entry(_ s: Store, _ id: String) -> ThreadEntry? { s.agents.entries.first { $0.id == id } }

    /// Icons on and a key saved, so an icon can be asked for; the store has not read the key, so none is.
    private func keySaved(_ s: Store) {
        s.agents.iconsEnabled = true
        s.hasTypesafeKey = true
    }

    @Test func askingForAnIconOfAHiddenSessionPicksIt() {
        let s = store([session("a"), session("b")])
        holdOnlyForAnIcon(s, "a")
        #expect(s.allAgentRows.map(\.id) == ["b"])
        keySaved(s)
        s.repickIcon("a")  // the key is not read yet, so nothing is asked for yet
        #expect(s.iconTarget()?.id == "a")
        s.agents.entries[s.agents.entries.firstIndex { $0.id == "a" }!].icon = "star"
        #expect(s.iconTarget()?.id == "b")
    }

    @Test func askingForAnIconOfAnOldSessionFoundThroughSearchPicksIt() {
        let s = store([session("a"), session("old", minutesAgo: 3 * 24 * 60)])
        #expect(entry(s, "old") == nil)
        keySaved(s)
        s.repickIcon("old")  // the key is not read yet, so nothing is asked for yet
        #expect(s.iconTarget()?.id == "old")
        #expect(s.allAgentRows.map(\.id) == ["a"])  // still unlisted
        #expect(entry(s, "old")?.hiddenAt != nil)
    }

    /// A store that asks for icons, with the transcript and Jev stood in for: every question gets its first option.
    private func iconStore(_ sessions: [AgentThread], firstMessage: String? = "Fix the login form") -> Store {
        let s = store(sessions)
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

    @Test func anIconPickedForWhatASessionWasIsPickedAgainAndOneSetMeanwhileWins() async {
        final class Latch: @unchecked Sendable { var open = false }
        let latch = Latch()
        let s = iconStore([session("a")])
        var titles: [String] = []
        s.iconChooser = { options, _, state, _ in
            titles.append(state["session title"] ?? "")
            while !latch.open { try? await Task.sleep(for: .milliseconds(2)) }
            return .init(choice: options[0], confidence: 1, probabilities: [options[0]: 1])
        }
        s.pickIcons()
        for _ in 0..<2000 where titles.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        // Renamed while Jev answers: the pick for the old name isn't taken; one is made for the new.
        var renamed = session("a")
        renamed.title = "Fix the login form"
        s.ingest([renamed], appUnread: [], claudeFrontmost: false, now: now)
        latch.open = true
        await finishIcons(s)
        #expect(titles.first == "Session a" && titles.last == "Fix the login form" && entry(s, "a")?.icon != nil)

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

    @Test func theIconPickedForAHiddenSessionIsKept() async {
        var hidden = session("a")
        hidden.cliID = "cli-a"
        let s = iconStore([hidden, session("b")])
        holdOnlyForAnIcon(s, "a")
        s.repickIcon("a")
        await finishIcons(s)
        #expect(entry(s, "a")?.icon != nil)
        #expect(s.allAgentRows.map(\.id) == ["b"])
    }

    @Test func theIconPickedForAnOldSessionSurvivesTheNextRefresh() async {
        var old = session("old", minutesAgo: 45 * 24 * 60)
        old.cliID = "cli-old"
        let s = iconStore([session("a"), old])
        s.repickIcon("old")
        s.ingest([session("a"), old], appUnread: [], claudeFrontmost: false, now: now)  // before the icon is picked
        await finishIcons(s)
        s.ingest([session("a"), old], appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "old")?.icon != nil)
    }

    @Test func theIconPickedForAnOldSessionFoundThroughSearchIsKept() async {
        var old = session("old", minutesAgo: 3 * 24 * 60)
        old.cliID = "cli-old"
        let s = iconStore([session("a"), old])
        s.repickIcon("old")
        await finishIcons(s)
        #expect(entry(s, "old")?.icon != nil)
        #expect(s.allAgentRows.map(\.id) == ["a"])
    }

    @Test func aSessionWithNothingToGoOnDoesNotBlockTheOthers() async {
        final class Reads: @unchecked Sendable { var ids: [String] = [] }
        let reads = Reads()
        var untitled = session("u")
        untitled.title = "Untitled session"
        untitled.cliID = "cli-u"
        let s = iconStore([untitled, session("b")])
        s.iconFirstMessage = { reads.ids.append($0); return nil }
        holdOnlyForAnIcon(s, "u")
        s.repickIcon("u")
        await finishIcons(s)
        #expect(entry(s, "b")?.icon != nil)
        #expect(entry(s, "u")?.icon == nil)
        #expect(s.iconTarget() == nil)
        // Later reads don't look at its transcript again, until it has something new.
        s.pickIcons()
        await finishIcons(s)
        #expect(reads.ids == ["cli-u"])
        var renamed = untitled
        renamed.title = "Fix the login form"
        s.ingest([renamed, session("b")], appUnread: [], claudeFrontmost: false, now: now)
        #expect(s.iconTarget()?.id == "u")
    }

    @Test func firstReadOffersRecentSessionsOnly() {
        let s = store([session("a", minutesAgo: 30), session("old", minutesAgo: 3 * 24 * 60)], dots: ["a"])
        #expect(s.agents.entries.map(\.id) == ["a"])
        #expect(entry(s, "a")?.unread == true)  // the sidebar dot decides on first sight
        #expect(s.allAgentRows.map(\.id) == ["a"])
    }

    @Test func finishedTurnMarksUnread() {
        let s = store([session("a")])
        #expect(entry(s, "a")?.unread == false)
        s.ingest([session("a", turns: 4, minutesAgo: 0)], appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == true)
        // Opened from Fjord, then another turn finishes: unread again.
        s.interceptOpen = { _ in }
        s.openThread("a")
        #expect(entry(s, "a")?.unread == false)
        s.ingest([session("a", turns: 5, minutesAgo: 0)], appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == true)
    }

    @Test func finishedWhileYouWatchItStaysRead() {
        let s = store([session("a", focusedMinutesAgo: 10), session("b", focusedMinutesAgo: 50)])
        s.ingest([session("a", turns: 4, minutesAgo: 0, focusedMinutesAgo: 10), session("b", focusedMinutesAgo: 50)],
                 appUnread: [], claudeFrontmost: true, now: now)
        #expect(entry(s, "a")?.unread == false)
    }

    @Test func sendingAMessageOrOpeningItMarksRead() {
        let s = store([session("a"), session("b")], dots: ["a", "b"])
        // A new message (running, no new finished turn).
        s.ingest([session("a", messageMinutesAgo: 0, running: true), session("b")], appUnread: ["a", "b"], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == false)
        // Focused in the app.
        s.ingest([session("a", messageMinutesAgo: 0, running: true), session("b", focusedMinutesAgo: 1)],
                 appUnread: ["a", "b"], claudeFrontmost: true, now: now)
        #expect(entry(s, "b")?.unread == false)
    }

    @Test func sidebarDotChangesWinButYourChoiceStandsOtherwise() {
        let s = store([session("a")], dots: [])
        s.ingest([session("a")], appUnread: ["a"], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == true)
        // Opened from Fjord: the app still shows the dot, unchanged, so Fjord keeps your choice.
        s.interceptOpen = { _ in }
        s.openThread("a")
        s.ingest([session("a")], appUnread: ["a"], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == false)
        // Unreadable dots (nil) change nothing.
        s.ingest([session("a")], appUnread: nil, claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == false)
        // The app clears its dot: read, as it was.
        s.ingest([session("a")], appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == false)
        // A dot appears again: unread.
        s.ingest([session("a")], appUnread: ["a"], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == true)
        // Then the dots can't be read: it stays unread.
        s.ingest([session("a")], appUnread: nil, claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == true)
    }

    @Test func aSessionHeldOnlyForAnIconIsListedAgainOnNewActivity() {
        let s = store([session("a")])
        holdOnlyForAnIcon(s, "a")
        #expect(s.allAgentRows.isEmpty)
        s.ingest([session("a")], appUnread: [], claudeFrontmost: false, now: now)
        #expect(s.allAgentRows.isEmpty)
        s.ingest([session("a", turns: 4, minutesAgo: 0)], appUnread: [], claudeFrontmost: false, now: now)
        #expect(s.allAgentRows.map(\.id) == ["a"])
    }

    @Test func archivedSessionsLeave() {
        let s = store([session("a")])
        s.ingest([session("a", archived: true)], appUnread: [], claudeFrontmost: false, now: now)
        #expect(s.agents.entries.isEmpty)
    }

    @Test func newSessionsAfterSeedingArePendingUnlessMuted() {
        let s = store([session("a")])
        s.setFolderMuted("", true)  // scratch chats
        s.ingest([session("a"), session("new", minutesAgo: 0), session("chat", minutesAgo: 0, folder: nil)],
                 appUnread: [], claudeFrontmost: false, now: now)
        #expect(Set(s.allAgentRows.map(\.id)) == ["a", "new"])
        #expect(entry(s, "new")?.unread == true)
        #expect(entry(s, "chat") == nil)
        // Old sessions with nothing new stay out.
        s.ingest([session("a"), session("new", minutesAgo: 0), session("stale", minutesAgo: 600)],
                 appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "stale") == nil)
    }

    @Test func anUnreadSessionWithWorkStillRunningIsWorkingUntilItEnds() throws {
        let s = store([session("f", minutesAgo: 4)], dots: ["f"])
        s.backgroundWork = ["f": [BackgroundWork(id: "a", kind: .agent, title: "Review the changes", since: now)]]
        let row = try #require(s.allAgentRows.first { $0.id == "f" })
        #expect(row.unread && row.group == .working)
        // The work ends: still unread, so it is done again.
        s.backgroundWork = [:]
        let done = try #require(s.allAgentRows.first { $0.id == "f" })
        #expect(done.unread && done.group == .done)
    }

    @Test func aBlockedSessionWithWorkStillRunningStillNeedsYou() throws {
        let s = store([session("b", minutesAgo: 4, blocked: true)], dots: ["b"])
        s.backgroundWork = ["b": [BackgroundWork(id: "c", kind: .command, title: "Run the full test suite", since: now)]]
        let row = try #require(s.allAgentRows.first { $0.id == "b" })
        #expect(row.group == .needsYou)
    }

    @Test func sessionsOfSameNamedProjectsSayWhichProjectTheyAreIn() throws {
        let s = store([session("a", folder: "/customer-a/app"), session("b", folder: "/customer-b/app")])
        let rows = s.allAgentRows
        let a = try #require(rows.first { $0.id == "a" }), b = try #require(rows.first { $0.id == "b" })
        #expect(a.projectName == "customer-a/app" && b.projectName == "customer-b/app")
        // The name follows the folders: with the other project gone, the folder's own name is enough again.
        s.threads["a"] = nil
        #expect(s.folderName("/customer-b/app") == "app")
        #expect(try #require(s.allAgentRows.first).projectName == "app")
        // A muted project still tells a session's project from another of its name.
        s.setFolderMuted("/customer-a/app", true)
        #expect(s.folderName("/customer-b/app") == "customer-b/app")
    }

    @Test func aPickedIconStaysWhenNoneCanBePickedToReplaceIt() {
        let s = store([session("a")])
        s.agents.entries[0].icon = "hammer"
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
        let s = store([session("a")])
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

@Suite struct ClaudeFiles {
    private func json(_ fields: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }

    @Test func decodesFinishedSessionWithItsSummary() {
        let s = Claude.decodeSession(json([
            "sessionId": "local_1", "title": "Fix CI", "cwd": "/code/app/.claude/worktrees/x", "gitAnchorsFolderRealpath": "/code/app",
            "completedTurns": 3, "lastActivityAt": 1_700_000_000_000.0, "latestUserFrameAt": 1_699_999_000_000.0,
            "postTurnSummary": ["status_category": "blocked", "status_detail": " Which one? "],
            "postTurnSummaryFor": "u1", "lastAssistantUuid": "u1", "someNewField": ["x": 1],
        ]))
        #expect(s?.folder == "/code/app")
        #expect(s?.folderName == "app")
        #expect(s?.summary == .init(blocked: true, detail: "Which one?"))
        #expect(s?.running == false)
    }

    @Test func runningWhileTheSummaryLagsBehind() {
        let now = Date()
        let s = Claude.decodeSession(json([
            "sessionId": "local_2", "latestUserFrameAt": now.addingTimeInterval(-60).timeIntervalSince1970 * 1000,
            "postTurnSummary": ["status_category": "review_ready"], "postTurnSummaryFor": "old", "lastAssistantUuid": "new",
            "cwd": "/Users/me/Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1",
        ]), now: now)
        #expect(s?.running == true)
        #expect(s?.summary == nil)
        #expect(s?.folder == nil)
        #expect(s?.title == "Untitled session")
        // A turn that started hours ago with no summary died with the app.
        let stale = Claude.decodeSession(json([
            "sessionId": "local_3", "latestUserFrameAt": now.addingTimeInterval(-3 * 3600).timeIntervalSince1970 * 1000,
        ]), now: now)
        #expect(stale?.running == false)
    }

    @Test func activityIsTheLastStep() {
        func line(_ obj: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! }
        let tool = line(["type": "assistant", "timestamp": "2026-10-05T08:33:04.292Z",
                         "message": ["content": [["type": "thinking"], ["type": "tool_use", "name": "Bash",
                                                                         "input": ["command": "swift test", "description": "Run the tests"]]]]])
        let result = line(["type": "user", "timestamp": "2026-10-05T08:33:09.000Z", "message": ["content": [["type": "tool_result"]]]])
        let other = line(["type": "attachment"])
        let running = Claude.activity(tail: Data(("partial line\n" + tool + "\n" + other + "\n").utf8))
        #expect(running?.text == "Run the tests")
        #expect(Claude.activity(tail: Data((tool + "\n" + result + "\n").utf8))?.text == "Thinking")
        let question = line(["type": "assistant", "timestamp": "2026-10-05T08:40:00.000Z",
                             "message": ["content": [["type": "tool_use", "name": "AskUserQuestion", "input": [:]]]]])
        #expect(Claude.activity(tail: Data((question + "\n").utf8))?.waitsForYou == true)
        #expect(running?.waitsForYou == false)
        // What it asks is what the row says.
        #expect(Claude.describe(tool: "AskUserQuestion", input: ["questions": [["question": "Which tone should the notes take?"], ["question": "Second"]]])
                == "Which tone should the notes take?")
        #expect(Claude.describe(tool: "ExitPlanMode", input: ["plan": "\n## Ship the redesign\n\n1. Build it"]).contains("Ship the redesign"))
    }

    @Test func endNoticesCutAtAScanBoundaryAreStillFound() {
        let full = Data("xx<task-id>a2</task-id>yy".utf8)
        var ended = Set<String>()
        for cut in 1..<full.count {
            ended = []
            let first = full.prefix(cut)
            let next = Claude.scanEnds(Data(first), base: 0, into: &ended)
            Claude.scanEnds(Data(full[next...]), base: next, into: &ended)
            #expect(ended == ["a2"], "cut at \(cut)")
        }
    }

    @Test func backgroundTasks() throws {
        // Like Claude Code writes them: slashes as they are.
        func line(_ obj: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: obj, options: .withoutEscapingSlashes), encoding: .utf8)!
        }
        let fm = FileManager.default
        // Resolved, as the system reports open files (/var is a link to /private/var).
        let temp = URL(fileURLWithPath: realpath(fm.temporaryDirectory.path, nil).map { String(cString: $0) } ?? NSTemporaryDirectory())
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let tasks = root.appendingPathComponent("tasks", isDirectory: true)
        let subagents = root.appendingPathComponent("subagents", isDirectory: true)
        try fm.createDirectory(at: tasks, withIntermediateDirectories: true)
        try fm.createDirectory(at: subagents, withIntermediateDirectories: true)

        // Two subagents (one announced as finished) and two commands (one still has its output open).
        for id in ["a1", "a2"] {
            let transcript = subagents.appendingPathComponent("agent-\(id).jsonl")
            try Data((line(["type": "assistant", "timestamp": "2026-10-05T08:33:04.292Z", "message": ["content": [
                ["type": "tool_use", "name": "Read", "input": ["file_path": "/x/Agents.swift"]]]]]) + "\n").utf8).write(to: transcript)
            try Data(#"{"description":"Review \#(id)","requestShape":"background"}"#.utf8)
                .write(to: subagents.appendingPathComponent("agent-\(id).meta.json"))
            try fm.createSymbolicLink(at: tasks.appendingPathComponent("\(id).output"), withDestinationURL: transcript)
        }
        for id in ["b1", "b2"] { try Data().write(to: tasks.appendingPathComponent("\(id).output")) }
        let parent = root.appendingPathComponent("session.jsonl")
        try Data([
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "toolu_1", "name": "Bash",
                                                                 "input": ["command": "swift build", "description": "Build the app"]]]]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_1",
                                                            "content": "Command running in background with ID: b1. Output is being written to: …"]]]]),
            line(["type": "queue-operation", "content": "<task-notification>\n<task-id>a2</task-id>\n<status>completed</status>"]),
        ].joined(separator: "\n").utf8).write(to: parent)

        let reader = Claude.TaskReader()
        let open: Set<String> = [tasks.appendingPathComponent("b1.output").path]
        let later = Date().addingTimeInterval(60)
        let found = reader.tasks(in: tasks, transcript: parent, openOutputs: open, now: later)
        #expect(found.map(\.id).sorted() == ["a1", "b1"])
        #expect(found.first { $0.id == "a1" }?.kind == .agent)
        #expect(found.first { $0.id == "a1" }?.title == "Review a1")
        #expect(found.first { $0.id == "a1" }?.activity?.text == "Reading Agents.swift")
        #expect(found.first { $0.id == "b1" }?.kind == .command)
        #expect(found.first { $0.id == "b1" }?.title == "Build the app")
        // The command ends: its output is closed, and it stays finished.
        #expect(reader.tasks(in: tasks, transcript: parent, openOutputs: [], now: later).map(\.id) == ["a1"])
        #expect(reader.tasks(in: tasks, transcript: parent, openOutputs: open, now: later).map(\.id) == ["a1"])
        // A subagent whose transcript went quiet long ago died with its session.
        #expect(reader.tasks(in: tasks, transcript: parent, openOutputs: [], now: later.addingTimeInterval(Claude.agentTimeout)).isEmpty)
    }

    @Test func runningCommandsHoldTheirOutputOpen() throws {
        let fm = FileManager.default
        // A folder of its own, not Claude's.
        let made = fm.temporaryDirectory.appendingPathComponent("fjord-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: made.appendingPathComponent("p/s/tasks", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: made) }
        // The system names a file by its real path (/private/var, not /var).
        let root = URL(fileURLWithPath: made.path.withCString { realpath($0, nil).map { String(cString: $0) } } ?? made.path)
        let folder = root.appendingPathComponent("p/s/tasks", isDirectory: true)
        let output = folder.appendingPathComponent("b1.output")
        fm.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.standardOutput = try FileHandle(forWritingTo: output)
        try process.run()
        #expect(Claude.openTaskOutputs(under: root).contains(output.path))
        process.terminate()
        process.waitUntilExit()
        #expect(!Claude.openTaskOutputs(under: root).contains(output.path))
    }

    @Test func rejectsOtherFiles() {
        #expect(Claude.decodeSession(json(["scheduledTasks": []])) == nil)
        #expect(Claude.decodeSession(Data("not json".utf8)) == nil)
    }

    @Test func parsesTheSidebarDots() {
        let value = [UInt8(1)] + Array(#"{"state":{"unreadIds":["local_a","local_b"],"explicitUnreadIds":[]},"version":0}"#.utf8)
        #expect(Claude.parseUnread(value) == ["local_a", "local_b"])
        let utf16 = [UInt8(0)] + Array(#"{"state":{"unreadIds":["local_c"]}}"#.data(using: .utf16LittleEndian)!)
        #expect(Claude.parseUnread(utf16) == ["local_c"])
        #expect(Claude.parseUnread([1, 0x7b]) == nil)
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

/// Which sessions' background work is known: only from a scan of open files made after the session's turn ended, and never
/// from a cached scan older than a command it hasn't seen.
@Suite struct TaskInventory {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    private func session(_ id: String, ended: Date, running: Bool = false) -> AgentThread {
        AgentThread(id: id, title: id, folder: "/code/app", completedTurns: 1, lastActivity: ended, running: running, cliID: "cli-\(id)")
    }

    /// A command output in `folder`, made at `at`.
    private func command(_ id: String, in folder: URL, at: Date) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(id).output")
        try Data().write(to: url)
        try FileManager.default.setAttributes([.creationDate: at, .modificationDate: at], ofItemAtPath: url.path)
        // The path as the folder lists it (the temporary folder's /private prefix included), as a scan of open files says it.
        let listed = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return try #require(listed.first { $0.lastPathComponent == "\(id).output" }).path
    }

    @Test func aCommandStartedAfterTheCachedScanIsLookedForAgain() throws {
        let dir = TempDir()
        let a = dir.path("a"), b = dir.path("b")
        let aOut = try command("ca", in: a, at: t0.addingTimeInterval(-10))
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        var clock = t0, open: Set<String> = [aOut]
        let outputs = OpenOutputs()
        outputs.now = { clock }
        outputs.scan = { open }
        let reader = Claude.TaskReader()
        let folders = ["cli-a": a, "cli-b": b]
        // A's read walks the processes; B is working.
        var read = ClaudeFeed.readTasks(sessions: [session("a", ended: t0.addingTimeInterval(-20)),
                                                   session("b", ended: t0, running: true)],
                                        folders: folders, reader: reader, outputs: outputs, transcript: { _ in nil })
        #expect(read.tasks["a"]?.count == 1 && read.inventory == ["a"])
        // Within the cached walk's two seconds, B starts a command and its turn ends.
        let bOut = try command("cb", in: b, at: t0.addingTimeInterval(0.5))
        open.insert(bOut)
        clock = t0.addingTimeInterval(1.5)
        read = ClaudeFeed.readTasks(sessions: [session("a", ended: t0.addingTimeInterval(-20)), session("b", ended: t0.addingTimeInterval(1))],
                                    folders: folders, reader: reader, outputs: outputs, transcript: { _ in nil })
        // The walk is made again (the cached one hadn't seen it): B's command is found, and B is known to be busy.
        #expect(read.tasks["b"]?.map(\.id) == ["cb"] && read.inventory.contains("b"))
    }

    @Test func aTurnThatEndedAfterTheCachedScanIsUnknownUntilANewOne() throws {
        let dir = TempDir()
        let b = dir.path("b")
        let bOut = try command("cb", in: b, at: t0.addingTimeInterval(-3))
        var clock = t0
        let outputs = OpenOutputs()
        outputs.now = { clock }
        outputs.scan = { [bOut] }
        let reader = Claude.TaskReader()
        // A walk at t0 (B still working: its command already running).
        _ = ClaudeFeed.readTasks(sessions: [session("b", ended: t0.addingTimeInterval(-1))], folders: ["cli-b": b], reader: reader,
                                 outputs: outputs, transcript: { _ in nil })
        // B's turn ends at t0 + 1; the cached walk (from before) is used: what it left running isn't known yet.
        clock = t0.addingTimeInterval(1.5)
        var read = ClaudeFeed.readTasks(sessions: [session("b", ended: t0.addingTimeInterval(1))], folders: ["cli-b": b],
                                        reader: reader, outputs: outputs, transcript: { _ in nil })
        #expect(!read.inventory.contains("b"))
        // A walk after it: known.
        clock = t0.addingTimeInterval(2.5)
        read = ClaudeFeed.readTasks(sessions: [session("b", ended: t0.addingTimeInterval(1))], folders: ["cli-b": b], reader: reader,
                                    outputs: outputs, transcript: { _ in nil })
        #expect(read.inventory.contains("b") && read.tasks["b"]?.map(\.id) == ["cb"])
    }

    @Test func aCommandListedButNotOpenYetLeavesTheSessionUnknown() throws {
        let dir = TempDir()
        let b = dir.path("b")
        _ = try command("cb", in: b, at: t0.addingTimeInterval(-1))
        let outputs = OpenOutputs()
        outputs.now = { self.t0 }
        outputs.scan = { [] }
        let read = ClaudeFeed.readTasks(sessions: [session("b", ended: t0.addingTimeInterval(-2))], folders: ["cli-b": b],
                                        reader: Claude.TaskReader(), outputs: outputs, transcript: { _ in nil })
        #expect(read.tasks.isEmpty && !read.inventory.contains("b"))
    }

    @Test func aCommandStillInItsGraceIsKnownOnceTheReadAfterItComes() throws {
        // Listed a second ago and not open: unknown now; the re-read the store schedules (past the grace) knows.
        let dir = TempDir()
        let b = dir.path("b")
        _ = try command("cb", in: b, at: t0.addingTimeInterval(-1))
        var clock = t0
        let outputs = OpenOutputs()
        outputs.now = { clock }
        outputs.scan = { [] }
        let reader = Claude.TaskReader()
        let ended = session("b", ended: t0.addingTimeInterval(-2))
        var read = ClaudeFeed.readTasks(sessions: [ended], folders: ["cli-b": b], reader: reader, outputs: outputs, transcript: { _ in nil })
        #expect(!read.inventory.contains("b"))
        clock = t0.addingTimeInterval(6)
        read = ClaudeFeed.readTasks(sessions: [ended], folders: ["cli-b": b], reader: reader, outputs: outputs, transcript: { _ in nil })
        #expect(read.inventory.contains("b") && read.tasks.isEmpty)
    }

    @Test func aFolderThatCantBeReadIsUnknownNotEmptyUntilItCanBe() throws {
        let dir = TempDir()
        let b = dir.path("b")
        _ = try command("cb", in: b, at: t0.addingTimeInterval(-60))
        let outputs = OpenOutputs()
        outputs.now = { self.t0 }
        outputs.scan = { [] }
        let ended = session("b", ended: t0.addingTimeInterval(-30))
        // The task folders couldn't be listed: nothing is known.
        var read = ClaudeFeed.readTasks(sessions: [ended], folders: nil, reader: Claude.TaskReader(), outputs: outputs, transcript: { _ in nil })
        #expect(read.inventory.isEmpty)
        // The session's own folder can't be read: unknown too.
        chmod(b.path, 0)
        defer { chmod(b.path, 0o755) }
        read = ClaudeFeed.readTasks(sessions: [ended], folders: ["cli-b": b], reader: Claude.TaskReader(), outputs: outputs, transcript: { _ in nil })
        #expect(read.inventory.isEmpty)
        // Readable again: known.
        chmod(b.path, 0o755)
        read = ClaudeFeed.readTasks(sessions: [ended], folders: ["cli-b": b], reader: Claude.TaskReader(), outputs: outputs, transcript: { _ in nil })
        #expect(read.inventory == ["b"])
    }

    @Test func taskFoldersThatCantBeListedAreNotNone() throws {
        let dir = TempDir()
        #expect(Claude.readTaskFolders(root: dir.path("missing")) == [:])
        let project = dir.path("root/project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("cli-a/tasks"), withIntermediateDirectories: true)
        #expect(Claude.readTaskFolders(root: dir.path("root"))?.keys.sorted() == ["cli-a"])
        chmod(project.path, 0)
        defer { chmod(project.path, 0o755) }
        #expect(Claude.readTaskFolders(root: dir.path("root")) == nil)
        chmod(project.path, 0o755)
        #expect(Claude.readTaskFolders(root: dir.path("root"))?.keys.sorted() == ["cli-a"])
    }

    @Test func aSessionFolderThatCantBeLookedIntoIsNotNone() throws {
        let dir = TempDir()
        let session = dir.path("root/project/cli-a")
        try FileManager.default.createDirectory(at: session.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.path("root/project/cli-b"), withIntermediateDirectories: true)
        #expect(Claude.readTaskFolders(root: dir.path("root"))?.keys.sorted() == ["cli-a"])
        // No execute permission on the session's folder: its tasks folder can't be looked for.
        chmod(session.path, 0o600)
        defer { chmod(session.path, 0o755) }
        #expect(Claude.readTaskFolders(root: dir.path("root")) == nil)
        chmod(session.path, 0o755)
        #expect(Claude.readTaskFolders(root: dir.path("root"))?.keys.sorted() == ["cli-a"])
    }

    @Test func aReaderThatKeepsItsListingsSeesWhatChangesAsAFreshReadDoes() throws {
        let dir = TempDir(), fm = FileManager.default, reader = Claude.TaskFolderReader()
        let root = dir.path("root")
        #expect(reader.read(root: root) == [:])
        try fm.createDirectory(at: root.appendingPathComponent("project/cli-a/tasks"), withIntermediateDirectories: true)
        // Claude Code's own files beside the projects aren't folders of sessions.
        try Data().write(to: root.appendingPathComponent("cache-break-state-1.json"))
        #expect(reader.read(root: root)?.keys.sorted() == ["cli-a"])
        // A session's tasks folder made in a project already listed, and a project made since.
        try fm.createDirectory(at: root.appendingPathComponent("project/cli-b/tasks"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("other/cli-c/tasks"), withIntermediateDirectories: true)
        #expect(reader.read(root: root)?.keys.sorted() == ["cli-a", "cli-b", "cli-c"])
        try fm.removeItem(at: root.appendingPathComponent("project/cli-a/tasks"))
        try fm.removeItem(at: root.appendingPathComponent("other"))
        #expect(reader.read(root: root)?.keys.sorted() == ["cli-b"])
        let project = root.appendingPathComponent("project")
        chmod(project.path, 0)
        defer { chmod(project.path, 0o755) }
        #expect(reader.read(root: root) == nil)
        chmod(project.path, 0o755)
        #expect(reader.read(root: root)?.keys.sorted() == ["cli-b"])
        // Only the sessions asked about are looked for: one that can't be looked into, not asked about, says nothing.
        try fm.createDirectory(at: root.appendingPathComponent("project/cli-d/tasks"), withIntermediateDirectories: true)
        #expect(reader.read(root: root, only: ["cli-d", "cli-x"])?.keys.sorted() == ["cli-d"])
        let other = root.appendingPathComponent("project/cli-b")
        chmod(other.path, 0o600)
        defer { chmod(other.path, 0o755) }
        #expect(reader.read(root: root, only: ["cli-d"])?.keys.sorted() == ["cli-d"])
        #expect(reader.read(root: root, only: ["cli-b", "cli-d"]) == nil)
    }

    @Test func aTaskReaderListsAgainOnlyAFolderThatChangedAndSeesWhatChanged() throws {
        let dir = TempDir()
        let folder = dir.path("tasks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reader = Claude.TaskReader()
        let now = Date()
        #expect(!reader.needsOpenOutputs(in: folder))
        #expect(reader.newestCommand(in: folder) == nil)
        let output = folder.appendingPathComponent("b1.output")
        try Data().write(to: output)
        #expect(reader.needsOpenOutputs(in: folder))
        #expect(reader.newestCommand(in: folder) != nil)
        // As the listing names it (the system may give /private/var for /var).
        let open = Set(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map(\.path))
        #expect(reader.read(folder, transcript: nil, openOutputs: open, now: now).tasks.map(\.id) == ["b1"])
        try FileManager.default.removeItem(at: output)
        #expect(reader.read(folder, transcript: nil, openOutputs: open, now: now).tasks.isEmpty)
        #expect(!reader.needsOpenOutputs(in: folder))
    }
}
