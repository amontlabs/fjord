import Foundation
import Testing
@testable import Fjord

/// Starting new work in T3: the launch's encoding, a worktree only for unattended work, the model T3 would use, the project
/// made for a folder, and Revert archiving the thread. Synthetic fixtures and stubs: nothing reaches a T3.
@MainActor
@Suite struct ThreadLauncherTests {
    typealias F = T3Fixture

    @MainActor final class Sent {
        var commands: [(command: T3Command, id: String)] = []
        var created: [(title: String, root: String)] = []
        var failing: Error?
    }

    private let config: T3JSON = [
        "settings": ["defaultModelSelection": ["instanceId": "claudeAgent", "model": "claude-opus-5"], "defaultRuntimeMode": "approval-required"],
        "providers": [["instanceId": "codex", "status": "ready", "enabled": true, "models": [["slug": "gpt-6"]]]],
    ]

    private func store(config: T3JSON? = nil, projects: [T3JSON] = [F.project("p1", title: "Garden", root: "/code/app")],
                       threads: [T3JSON] = []) -> (Store, Sent) {
        let s = Store.reading(threads, projects: projects)
        let sent = Sent()
        let config = config ?? self.config
        s.requestSender = { command, id in
            if let failing = sent.failing { throw failing }
            sent.commands.append((command, id))
        }
        s.launchSupport = ThreadLaunchSupport(
            config: { config },
            createProject: { title, root in
                sent.created.append((title, root))
                return T3Project(json: F.project("made", title: title, root: root))
            },
            defaultBranch: { _ in "trunk" })
        return (s, sent)
    }

    private func payload(_ sent: Sent, _ i: Int = 0) -> [String: T3JSON] {
        guard case .object(let o) = sent.commands[i].command.payload(commandId: sent.commands[i].id) else { return [:] }
        return o
    }

    // MARK: Encoding

    @Test func aLaunchAsksT3ForATitleAndTheDefaultInteractionMode() {
        let r = ThreadLauncher.request(thread: "t9", project: "p1", message: ThreadMessage(text: "Plant the beans\nand water them"),
                                       model: .init(instanceId: "claudeAgent", model: "m"), runtimeMode: .autoAcceptEdits, workspace: .root)
        #expect(r.generateTitle && r.title == "Plant the beans" && r.interactionMode == .default && r.runtimeMode == .autoAcceptEdits)
        let body = T3Command.launchThread(r).payload(commandId: "c")
        #expect(body["workspaceStrategy"]?.str("type") == "root" && body["workspaceStrategy"]?["branch"] == nil)
        #expect(body["initialMessage"]?.str("text") == "Plant the beans\nand water them")
        #expect(T3Command.launchThread(r).rpcTag == "orchestration.launchThread")
    }

    @Test func aLongOrEmptyFirstLineGetsAShortProvisionalTitle() {
        #expect(ThreadLauncher.provisionalTitle(String(repeating: "a", count: 200)).count == 60)
        #expect(ThreadLauncher.provisionalTitle("  \n ") == "New thread")
    }

    @Test func contextRecordsTravelWithTheFirstMessage() {
        let message = ThreadMessage(text: "see [x](t3-context://a)", records: [["id": "a", "kind": "thread"]])
        let r = ThreadLauncher.request(thread: "t", project: "p", message: message, model: .init(instanceId: "i", model: "m"),
                                       runtimeMode: .fullAccess, workspace: .root)
        #expect(T3Command.launchThread(r).payload(commandId: "c")["initialMessage"]?["context"]?["records"]?.array?.count == 1)
    }

    // MARK: The model

    @Test func theModelIsTheProjectsThenTheServersThenTheThreadsThenTheFirstReadyProvider() {
        let project: T3JSON = ["defaultModelSelection": ["instanceId": "codex", "model": "gpt-6"]]
        #expect(ThreadLauncher.model(project: project, config: config, siblings: [])
            == .init(instanceId: "codex", model: "gpt-6"))
        #expect(ThreadLauncher.model(project: [:], config: config, siblings: [])
            == .init(instanceId: "claudeAgent", model: "claude-opus-5"))
        let bare: T3JSON = ["settings": [:], "providers": config["providers"] ?? .null]
        let sibling = T3ThreadShell(json: F.thread("t", extra: ["providerInstanceId": "claudeAgent", "modelSelection": ["instanceId": "claudeAgent", "model": "haiku"]]))
        #expect(ThreadLauncher.model(project: nil, config: bare, siblings: [sibling]) == .init(instanceId: "claudeAgent", model: "haiku"))
        #expect(ThreadLauncher.model(project: nil, config: bare, siblings: []) == .init(instanceId: "codex", model: "gpt-6"))
        #expect(ThreadLauncher.model(project: nil, config: nil, siblings: []) == nil)
    }

    @Test func anActionsRuntimeModeWinsOverTheServersDefault() {
        #expect(ThreadLauncher.runtimeMode(asked: "auto-accept-edits", config: config) == .autoAcceptEdits)
        #expect(ThreadLauncher.runtimeMode(asked: nil, config: config) == .approvalRequired)
        #expect(ThreadLauncher.runtimeMode(asked: nil, config: nil) == .fullAccess)
    }

    // MARK: The workspace

    @Test func yourWordsWorkInTheCheckoutAndAnActionsInAWorktreeOffTheDefaultBranch() async throws {
        let (s, sent) = store()
        try await s.launchThread(in: "p1", message: ThreadMessage(text: "fix the fence"))
        let origin = SessionOrigin(category: "Contributions", thing: "a/b#1", actionID: "a", runID: "r", runtimeMode: "approval-required")
        try await s.launchThread(in: "p1", message: ThreadMessage(text: "review it"), origin: origin)
        #expect(sent.commands.count == 2)
        #expect(payload(sent, 0)["workspaceStrategy"]?.str("type") == "root")
        let strategy = payload(sent, 1)["workspaceStrategy"]
        #expect(strategy?.str("type") == "worktree" && strategy?.str("baseRef") == "trunk" && strategy?["branch"] == nil)
        #expect(payload(sent, 1)["runtimeMode"]?.string == "approval-required")
        #expect(payload(sent, 0)["runtimeMode"]?.string == "approval-required")  // T3's own default here
        #expect(payload(sent, 0)["projectId"]?.string == "p1")
        #expect(payload(sent, 0)["modelSelection"]?.str("model") == "claude-opus-5")
    }

    @Test func aLaunchCarriesTheMintedIdAndTheSettingsTheRowShowed() async throws {
        let (s, sent) = store()
        let settings = ThreadLaunchSettings(model: "gpt-6", effort: "medium", runtimeMode: .autoAcceptEdits, interactionMode: .plan)
        let launched = try await s.launchThread(in: "p1", message: ThreadMessage(text: "fix the fence"), thread: "minted-1", settings: settings)
        #expect(launched.thread == "minted-1")
        let p = payload(sent, 0)
        #expect(p["threadId"]?.string == "minted-1")
        #expect(p["modelSelection"]?.str("model") == "gpt-6" && p["modelSelection"]?.str("instanceId") == "codex")
        #expect(p["modelSelection"]?["options"]?.array?.first?.str("id") == "effort")
        #expect(p["modelSelection"]?["options"]?.array?.first?.str("value") == "medium")
        #expect(p["runtimeMode"]?.string == "auto-accept-edits" && p["interactionMode"]?.string == "plan")
        #expect(p["workspaceStrategy"]?.str("type") == "root")
    }

    @Test func aLaunchWithNoSettingsKeepsT3sDefaultsAndSendsNoEffort() async throws {
        let (s, sent) = store()
        try await s.launchThread(in: "p1", message: ThreadMessage(text: "fix the fence"))
        #expect(payload(sent, 0)["modelSelection"]?["options"] == nil && payload(sent, 0)["interactionMode"]?.string == "default")
    }

    @Test func aModelT3DoesntOfferStartsNothingAndSaysSo() async {
        let (s, sent) = store()
        let settings = ThreadLaunchSettings(model: "nope-1", effort: nil, runtimeMode: .auto)
        do { try await s.launchThread(in: "p1", message: ThreadMessage(text: "x"), settings: settings); Issue.record("started") }
        catch { #expect(error.localizedDescription.contains("nope-1")) }
        #expect(sent.commands.isEmpty)
    }

    @Test func aModelIsFoundOnTheInstanceThatRunsIt() {
        #expect(ThreadLauncher.model(slug: "claude-opus-5", project: nil, config: config, siblings: []) == .init(instanceId: "claudeAgent", model: "claude-opus-5"))
        #expect(ThreadLauncher.model(slug: "gpt-6", project: nil, config: config, siblings: []) == .init(instanceId: "codex", model: "gpt-6"))
        #expect(ThreadLauncher.model(slug: "x", project: nil, config: config, siblings: []) == nil)
    }

    @Test func aLaunchNeverGoesToAProjectT3DoesntHave() async {
        let (s, sent) = store()
        await #expect(throws: ThreadLaunchFailure.self) { try await s.launchThread(in: "nope", message: ThreadMessage(text: "x")) }
        #expect(sent.commands.isEmpty)
    }

    @Test func noModelMeansNothingIsStartedAndTheReasonIsSaid() async {
        let (s, sent) = store(config: ["settings": [:], "providers": []])
        do { try await s.launchThread(in: "p1", message: ThreadMessage(text: "x")); Issue.record("started") }
        catch { #expect(error.localizedDescription.contains("no model")) }
        #expect(sent.commands.isEmpty)
    }

    @Test func aRefusalIsT3sOwnWordsAndLogsNothing() async {
        let (s, sent) = store()
        sent.failing = ThreadLaunchFailure("Base ref \"trunk\" does not resolve")
        let before = s.router.changes.count
        await #expect(throws: ThreadLaunchFailure.self) { try await s.launchThread(in: "p1", message: ThreadMessage(text: "x")) }
        #expect(s.router.changes.count == before)
    }

    // MARK: A folder with no project

    @Test func aFolderWithNoProjectGetsOneAndAnExistingOneIsReused() async throws {
        let (s, sent) = store()
        let existing = try await s.projectForFolder("/code/app/")
        #expect(existing.id == "p1" && sent.created.isEmpty)
        let made = try await s.projectForFolder("/code/new-tool")
        #expect(made.id == "made" && sent.created.map(\.title) == ["new-tool"] && sent.created.map(\.root) == ["/code/new-tool"])
        #expect(s.t3Project(forFolder: "/code/new-tool")?.id == "made")
        #expect(ThreadLauncher.projectCreate(commandId: "c", projectId: "p", title: "t", root: "/r").str("type") == "project.create")
    }

    // MARK: Revert

    @Test func aLaunchIsAChangeOfFjordsAndRevertArchivesTheThread() async throws {
        let (s, sent) = store()
        let launched = try await s.launchThread(in: "p1", message: ThreadMessage(text: "fix the fence"))
        let id = try #require(launched.change)
        let change = try #require(s.router.changes.first { $0.id == id })
        #expect(change.title == "Started a thread in Garden" && !change.isReverted)
        #expect(s.router.decisions.contains { $0.links.changes.contains(id) })
        _ = s.revertFjordChange(id)
        await waitUntil { sent.commands.count == 2 }
        #expect(payload(sent, 1)["type"]?.string == "thread.archive" && payload(sent, 1)["threadId"]?.string == launched.thread)
        #expect(s.router.changes.first { $0.id == id }?.isReverted == true)
    }

    @Test func aFailedArchiveSaysSoAndLeavesTheChangeActive() async throws {
        let (s, sent) = store()
        let launched = try await s.launchThread(in: "p1", message: ThreadMessage(text: "x"))
        let id = try #require(launched.change)
        sent.failing = ThreadLaunchFailure("T3 is down")
        _ = s.revertFjordChange(id)
        await waitUntil { s.router.changes.first { $0.id == id }?.revertNote?.contains("Couldn't archive") == true }
        #expect(s.router.changes.first { $0.id == id }?.isReverted == false)
    }
}
