import Foundation
import Testing
@testable import Fjord

/// The Router as the store runs it: the switch with its hook, and the forms folder.
@MainActor
@Suite struct RouterStore {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func session(_ id: String, turns: Int, focused: Double = -60, summary: String? = "Done it") -> AgentThread {
        AgentThread(id: id, title: "Session \(id)", folder: "/code/app", completedTurns: turns,
                      lastActivity: now.addingTimeInterval(-60), lastFocused: now.addingTimeInterval(focused * 60),
                      lastUserMessage: now.addingTimeInterval(-120), summary: summary.map { .init(blocked: false, detail: $0) },
                      cliID: "cli-\(id)")
    }

    /// Sessions and Router on, the Router's files in `dir`, every session seen once.
    private func store(_ dir: TempDir, _ sessions: [AgentThread]) -> Store {
        let s = Store()
        s.persists = false
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.routerExecutable = "/Applications/Fjord.app/Contents/MacOS/Fjord"
        s.interceptOpen = { _ in }
        s.agents.enabled = true
        s.agents.enabledAt = now.addingTimeInterval(-3600)
        s.ingest(sessions, appUnread: [], claudeFrontmost: false, now: now)
        s.setRouterEnabled(true, now: now)
        return s
    }

    @Test func switchingItOnInstallsTheHookAndOffRemovesIt() async throws {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1)])
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        let installer = FormHookInstaller(claudeDir: paths.claudeDir)
        #expect(s.routerHookStatus == .installed && s.routerHookError == nil)
        #expect(installer.status(executable: "/Applications/Fjord.app/Contents/MacOS/Fjord") == .installed)
        #expect(FileManager.default.fileExists(atPath: paths.forms.appendingPathComponent(".enabled").path))

        s.setRouterEnabled(false)
        await s.routerHookWork?.value
        #expect(s.routerHookStatus == .notInstalled && s.routerHookError == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.forms.appendingPathComponent(".enabled").path))
        #expect(!FileManager.default.fileExists(atPath: installer.script.path))
    }

    @Test func aHookThatCantBeInstalledSaysWhy() async throws {
        let dir = TempDir()
        try FileManager.default.createDirectory(at: dir.path("claude"), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: dir.path("claude/settings.json"))
        let s = store(dir, [])
        await s.routerHookWork?.value
        #expect(s.routerHookError != nil)
        #expect(s.routerHookStatus == .notInstalled)
        #expect(try Data(contentsOf: dir.path("claude/settings.json")) == Data("{ nope".utf8))
    }

    @Test func atLaunchAnOutdatedHookIsInstalledAgain() async throws {
        let dir = TempDir()
        let s = store(dir, [])
        await s.routerHookWork?.value
        let installer = FormHookInstaller(claudeDir: dir.path("claude"))
        // The app moved.
        let moved = Store()
        moved.persists = false
        moved.routerPaths = s.routerPaths
        moved.routerExecutable = "/Users/me/Applications/Fjord.app/Contents/MacOS/Fjord"
        moved.router.enabled = true
        moved.startRouter()
        await moved.routerHookWork?.value
        #expect(installer.status(executable: "/Users/me/Applications/Fjord.app/Contents/MacOS/Fjord") == .installed)
        #expect(moved.routerHookStatus == .installed)

        // Not installed (you took it out yourself): launch leaves it so.
        try installer.uninstall()
        let again = Store()
        again.persists = false
        again.routerPaths = s.routerPaths
        again.routerExecutable = moved.routerExecutable
        again.router.enabled = true
        again.startRouter()
        await again.routerHookWork?.value
        #expect(again.routerHookStatus == .notInstalled)
    }

    private func asking(_ s: Store, _ id: String, since: Date, call: String = "toolu_1", turns: Int = 1,
                        tool: String = "AskUserQuestion") {
        var running = session(id, turns: turns)
        running.running = true
        running.summary = nil
        s.ingest([running], appUnread: [], claudeFrontmost: false, now: now)
        let text = tool == "ExitPlanMode" ? "Approve the plan: Ship it" : "Which one?"
        s.threadWork = [id: ThreadWork(text: text, since: since, waitsForYou: true, tool: tool, toolUseID: call)]
    }

    /// The hook holds a form for `call` (nil: not found yet): written to the forms folder and read back by the bridge when
    /// the store has one running, else set directly.
    private func form(_ s: Store, call: String?, key: String = "k", plan: Bool = false) async {
        guard s.router.enabled, let forms = s.routerPaths?.forms else {
            s.routerFormsLoaded = true
            s.pendingForms = ["cli-local_a": PendingForm(id: key, cliSessionID: "cli-local_a", transcriptPath: "",
                                                         questions: [.init(question: "Q?", header: "", multiSelect: false, options: [])],
                                                         createdAt: now, pid: 1, toolUseID: call)]
            return
        }
        await release(s)
        var record: [String: Any] = ["key": key, "session_id": "cli-local_a", "tool_input": plan ? planInput : sampleInput,
                                     "created_at": 1, "pid": Int(getpid())]
        record["tool_use_id"] = call
        if plan { record["tool_name"] = "ExitPlanMode" }
        try! JSONSerialization.data(withJSONObject: record).write(to: forms.appendingPathComponent("\(key).json"))
        s.formBridge.refresh()
        await waitUntil { s.pendingForms["cli-local_a"]?.id == key }
    }

    /// The hook lets go of every form.
    private func release(_ s: Store) async {
        guard let forms = s.routerPaths?.forms else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: forms, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "json" { try? FileManager.default.removeItem(at: file) }
        s.formBridge.refresh()
        await waitUntil { s.pendingForms.isEmpty && s.routerFormsLoaded }
    }

}
