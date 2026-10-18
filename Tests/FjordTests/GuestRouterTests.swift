import Foundation
import Testing
@testable import Fjord

private actor GuestRelayStateRecorder {
    private(set) var values: [GuestRelayRecord] = []
    func append(_ value: GuestRelayRecord) { values.append(value) }
}

private actor GuestHookProcessSignals {
    enum Startup { case ready, exited(Int32) }
    private var output = Data()
    private var isReady = false
    private var startupWaiter: CheckedContinuation<Startup, Never>?
    private var exitStatus: Int32?
    private var exitWaiter: CheckedContinuation<Int32, Never>?

    func receiveOutput(_ data: Data) {
        output.append(data)
        if output.range(of: Data("ready\n".utf8)) != nil {
            isReady = true
            startupWaiter?.resume(returning: .ready)
            startupWaiter = nil
        }
    }

    func waitUntilReadyOrExit() async -> Startup {
        if isReady { return .ready }
        if let exitStatus { return .exited(exitStatus) }
        return await withCheckedContinuation { startupWaiter = $0 }
    }

    func recordExit(_ status: Int32) {
        exitStatus = status
        startupWaiter?.resume(returning: .exited(status))
        startupWaiter = nil
        exitWaiter?.resume(returning: status)
        exitWaiter = nil
    }

    func waitForExit() async -> Int32 {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { exitWaiter = $0 }
    }

    func capturedOutput() -> Data { output }
}

private actor GuestRouterGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor GuestAccountBarrier {
    private var shouldPause = true
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pauseOnce() async {
        guard shouldPause else { return }
        shouldPause = false
        entered = true
        entryWaiter?.resume()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct AccountPausingGuestClient: GuestClient {
    var base: MockGuestClient
    var barrier: GuestAccountBarrier

    func account(for computer: GuestReference) async throws -> GuestAccount {
        await barrier.pauseOnce()
        return try await base.account(for: computer)
    }
    func filesRead(computer: GuestReference, path: String, offset: Int64?, length: Int?) async throws -> GuestFileReadResult {
        try await base.filesRead(computer: computer, path: path, offset: offset, length: length)
    }
    func filesList(computer: GuestReference, path: String) async throws -> [GuestFileEntry] {
        try await base.filesList(computer: computer, path: path)
    }
    func filesWrite(_ request: GuestFileWriteRequest) async throws -> GuestFileWriteResult { try await base.filesWrite(request) }
    func filesRemove(computer: GuestReference, paths: [String]) async throws -> [String] {
        try await base.filesRemove(computer: computer, paths: paths)
    }
    func filesWatch(computer: GuestReference, paths: [String]) async throws -> GuestFilesWatch {
        try await base.filesWatch(computer: computer, paths: paths)
    }
    func sshAliasEnsure(computer: GuestReference, installInclude: Bool) async throws -> GuestSSHAlias {
        try await base.sshAliasEnsure(computer: computer, installInclude: installInclude)
    }
    func sshAliasRemove(computer: GuestReference) async throws { try await base.sshAliasRemove(computer: computer) }
    func exec(_ request: GuestExecRequest) async throws -> GuestExecResult { try await base.exec(request) }
    func execStart(_ request: GuestExecStartRequest) async throws -> String { try await base.execStart(request) }
    func execGet(computer: GuestReference, jobId: String, sinceSequence: UInt64) async throws -> GuestExecJobResult {
        try await base.execGet(computer: computer, jobId: jobId, sinceSequence: sinceSequence)
    }
}

@Suite(.serialized, .ownGuestRuntime) struct GuestRouterTests {
    private let computer = GuestReference(deviceId: "owner-1", computerId: "computer-1")
    private var localComputer: GuestReference { GuestReference(deviceId: nil, computerId: computer.computerId) }
    private var account: GuestAccount {
        GuestAccount(home: "/home/guest", uid: 1001, operatingSystem: .linux, architecture: "aarch64",
                     nodeExecutable: "/usr/bin/node", claudeExecutable: "/home/guest/.local/bin/claude")
    }

    private func client() -> MockGuestClient { MockGuestClient(accounts: [computer: account, localComputer: account]) }

    @MainActor private func engineWithComputer(state: LinuxComputerState) -> MockEngineClient {
        var inventory = MockEngineClient.demoInventory
        inventory.linux.computers.append(ApplicationComputer(kind: .linux,
            configuration: ComputerConfiguration(id: computer.computerId, name: "Linux dev", cpus: 2, maxCPUs: 8,
                memoryGiB: 4, maxMemoryGiB: 16, workspaceStorageGiB: 32, runtimeStorageGiB: 16),
            purpose: "Local MicroSandbox", state: state, stateDetail: state.rawValue.capitalized,
            canDismissError: false, freshness: "fresh"))
        return MockEngineClient(inventory: inventory)
    }

    @Test func guestInstallerWritesGuestOnlyPluginHookSettingsAndPrivateKey() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let originalSettings = try JSONSerialization.data(withJSONObject: [
            "theme": "dark", "sshConfigs": [["id": "mine", "name": "Existing", "sshHost": "ssh-existing"]],
            "hooks": ["PermissionRequest": [["matcher": "OtherTool", "hooks": [["type": "command", "command": "custom-hook"]]]]],
        ], options: [.sortedKeys])
        try await guest.filesWrite(.init(computer: computer, path: paths.settings, data: originalSettings, mode: 0o640))
        let installed = try await GuestRouterInstaller(client: guest).install(computer: computer)
        let files = await guest.filesSnapshot(for: computer)
        let hook = String(data: try #require(files[installed.paths.hook]), encoding: .utf8)!
        let plugin = try #require(files[GuestRouterPaths.join(installed.paths.plugin, "hooks/register.ts")])
        let key = try #require(files[installed.paths.key])
        let settings = try #require(files[installed.paths.settings])
        let root = try #require(try JSONSerialization.jsonObject(with: settings) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let permission = try #require(hooks["PermissionRequest"] as? [[String: Any]])
        let backup = try await guest.filesRead(computer: computer, path: paths.settings + ".fjord-backup", offset: nil, length: nil)

        #expect(key.count == 65)
        #expect(await guest.writeRecords().first(where: { $0.path == installed.paths.key })?.mode == 0o600)
        #expect(await guest.writeRecords().first(where: { $0.path == installed.paths.hook })?.mode == 0o755)
        #expect(hook.contains("/usr/bin/node"))
        #expect(hook.contains(installed.paths.formModule))
        #expect(!hook.contains("--form-hook"))
        #expect(!String(decoding: plugin, as: UTF8.self).contains("Fjord --form-hook"))
        #expect(permission.contains { ($0["matcher"] as? String) == "AskUserQuestion|ExitPlanMode" })
        #expect(permission.contains { ($0["matcher"] as? String) == "OtherTool" })
        #expect(root["theme"] as? String == "dark")
        #expect((root["sshConfigs"] as? [[String: String]])?.first?["id"] == "mine")
        #expect(backup.data == originalSettings)
        #expect(backup.mode == 0o600)
        #expect(files[GuestRouterPaths.join(installed.paths.forms, FormBridge.marker)] != nil)
        #expect(await guest.execRecords().map(\.argv).contains([account.claudeExecutable, "plugin", "install", ClaudePlugin.guestID, "--scope", "user"]))
        // The guest plugin has a name of its own, so Desktop's hookless --plugin-dir copy of the Mac's `fjord` cannot shadow it.
        let manifest = String(decoding: try #require(files[GuestRouterPaths.join(installed.paths.plugin, ".claude-plugin/plugin.json")]), as: UTF8.self)
        let market = String(decoding: try #require(files[GuestRouterPaths.join(installed.paths.plugin, ".claude-plugin/marketplace.json")]), as: UTF8.self)
        #expect(manifest.contains("\"name\" : \"\(ClaudePlugin.guestName)\""))
        #expect(market.contains("\"name\": \"\(ClaudePlugin.guestName)\"") && !market.contains("\"name\": \"fjord\""))
        #expect(await guest.execRecords().map(\.argv).contains([account.claudeExecutable, "plugin", "uninstall", "fjord@fjord", "--scope", "user"]))
        #expect(await guest.execRecords().map(\.argv).contains([account.claudeExecutable, "plugin", "marketplace", "remove", "fjord"]))
        #expect(FileManager.default.fileExists(atPath: installed.paths.hook) == false)

        _ = try await GuestRouterInstaller(client: guest).install(computer: computer)
        #expect(await guest.execRecords().contains { $0.argv == [account.claudeExecutable, "plugin", "update", ClaudePlugin.guestID, "--scope", "user"] })
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(installed.paths.presence, "cli-1"),
                                         data: Data("{}".utf8), mode: 0o600))
        try await GuestRouterInstaller(client: guest).disable(computer: computer)
        let afterDisable = try await guest.filesRead(computer: computer, path: paths.settings, offset: nil, length: nil)
        let disabledRoot = try #require(try JSONSerialization.jsonObject(with: afterDisable.data) as? [String: Any])
        let disabledHooks = try #require(disabledRoot["hooks"] as? [String: Any])
        #expect((disabledHooks["PermissionRequest"] as? [[String: Any]])?.contains { ($0["matcher"] as? String) == "OtherTool" } == true)
        #expect(await guest.filesSnapshot(for: computer)[paths.key] == nil)
        #expect(await guest.filesSnapshot(for: computer)[GuestRouterPaths.join(paths.forms, FormBridge.marker)] == nil)
        #expect(await guest.filesSnapshot(for: computer)[GuestRouterPaths.join(paths.presence, "cli-1")] == nil)
    }

    @Test func guestInstallerProvisionsPinnedOfficialNodeWhenNodeIsMissing() async throws {
        let missingNode = GuestAccount(home: account.home, uid: account.uid, operatingSystem: .linux,
            architecture: "aarch64", nodeExecutable: "", claudeExecutable: account.claudeExecutable)
        let guest = MockGuestClient(accounts: [computer: missingNode])

        let installed = try await GuestRouterInstaller(client: guest).install(computer: computer)

        let artifact = try #require(GuestNodeRuntime.artifact(operatingSystem: .linux, architecture: "aarch64"))
        let request = try #require(await guest.execStartRecords().first)
        #expect(request.argv.contains(artifact.url))
        #expect(request.argv.contains(artifact.sha256))
        #expect(request.retainOutputBytes == GuestNodeRuntime.outputLimit)
        let files = await guest.filesSnapshot(for: computer)
        let script = try #require(files[request.argv[1]])
        let source = try #require(String(data: script, encoding: .utf8))
        let hookData = try #require(files[installed.paths.hook])
        let hook = try #require(String(data: hookData, encoding: .utf8))
        #expect(source.contains("sha256sum") && source.contains("shasum -a 256"))
        #expect(source.contains("curl --fail --location"))
        #expect(source.contains("trap 'exit 143' TERM") && source.contains("mv \"$backup\" \"$install\""))
        #expect(hook.contains(GuestNodeRuntime.nodePath(home: account.home)))
    }

    @Test func guestFormHookExitsQuietlyOnTerminationWhileStdinIsHeldOpen() async throws {
        let dir = TempDir()
        let module = dir.path("form-hook.mjs")
        let registration = "for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sig, stop)"
        let source = GuestRouterArtifacts.formModule
        #expect(source.contains(registration))
        let instrumented = source.replacingOccurrences(of: registration,
                                                        with: registration + "\nprocess.stdout.write('ready\\n')")
        try Data(instrumented.utf8).write(to: module)

        let signals = GuestHookProcessSignals()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", module.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = dir.url.path
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { terminated in
            Task { await signals.recordExit(terminated.terminationStatus) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { await signals.receiveOutput(data) }
        }
        try process.run()
        guard case .ready = await signals.waitUntilReadyOrExit() else {
            Issue.record("The hook exited before registering its signal handlers")
            return
        }
        #expect(process.isRunning)
        process.terminate()
        let status = await signals.waitForExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        process.waitUntilExit()
        try? stdin.fileHandleForWriting.close()
        #expect(process.terminationReason == .exit && status == 0)
        #expect(await signals.capturedOutput() == Data("ready\n".utf8))
    }

    @Test func guestFormHookBoundsAnOpenStdinRead() async throws {
        let dir = TempDir()
        let module = dir.path("form-hook.mjs")
        let inputTimeout = "const INPUT_TIMEOUT = 30_000"
        let inputTimer = "const timer = setTimeout(() => { timedOut = true; process.stdin.destroy() }, INPUT_TIMEOUT)"
        var source = GuestRouterArtifacts.formModule
        #expect(source.contains(inputTimeout))
        #expect(source.contains(inputTimer))
        source = source.replacingOccurrences(of: inputTimer,
            with: "const timer = undefined\n  queueMicrotask(() => { timedOut = true; process.stdin.destroy() })")
        try Data(source.utf8).write(to: module)

        let signals = GuestHookProcessSignals()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", module.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = dir.url.path
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { terminated in
            Task { await signals.recordExit(terminated.terminationStatus) }
        }
        try process.run()
        let status = await signals.waitForExit()
        process.waitUntilExit()
        try? stdin.fileHandleForWriting.close()
        #expect(process.terminationReason == .exit && status == 0)
        #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @Test func guestFormHookFindsTheCallInATranscriptWhoseFirstPromptIsAPlainString() async throws {
        let dir = TempDir()
        let module = dir.path("form-hook.mjs")
        try Data(GuestRouterArtifacts.formModule.utf8).write(to: module)
        let forms = dir.url.appendingPathComponent(".local/share/fjord/router/forms", isDirectory: true)
        try FileManager.default.createDirectory(at: forms, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: forms.appendingPathComponent(".enabled").path, contents: Data())
        let input: [String: Any] = ["questions": [["question": "Red or blue?", "header": "Color", "multiSelect": false,
                                                  "options": [["label": "Red", "description": "r"], ["label": "Blue", "description": "b"]]]]]
        // Claude Code writes the first user row with a string as its content, then the assistant's tool_use.
        let rows: [[String: Any]] = [
            ["type": "user", "message": ["role": "user", "content": "ask me which color I prefer"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_guest_1", "name": "AskUserQuestion", "input": input]]]],
        ]
        let transcript = dir.path("session.jsonl")
        try Data(rows.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n").utf8).write(to: transcript)
        let request = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "tool_input": input,
            "session_id": "s1", "transcript_path": transcript.path, "cwd": "/home/silo/e2e-proj",
        ])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", module.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = dir.url.path
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        try stdin.fileHandleForWriting.write(contentsOf: request)
        try stdin.fileHandleForWriting.close()

        var toolUseID: String?
        for _ in 0..<80 where toolUseID == nil {
            try await Task.sleep(for: .milliseconds(100))
            let files = (try? FileManager.default.contentsOfDirectory(at: forms, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasSuffix(".answer.json") {
                let form = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if let id = form?["tool_use_id"] as? String { toolUseID = id }
            }
        }
        #expect(toolUseID == "toolu_guest_1")
    }

    @Test func guestDisablePersistsNestedRemovalFromAMixedHookEntry() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let command = FormHookInstaller.quoted(paths.hook, onlyIfNeeded: true)
        let original = try JSONSerialization.data(withJSONObject: [
            "hooks": ["PermissionRequest": [[
                "matcher": FormHookInstaller.matcher,
                "hooks": [["type": "command", "command": command], ["type": "command", "command": "custom-hook"]],
            ]]],
        ], options: [.sortedKeys])
        _ = try await guest.filesWrite(.init(computer: computer, path: paths.settings, data: original, mode: 0o600))

        try await GuestClaudeSettings.removeHook(client: guest, computer: computer, paths: paths)

        let updated = try await guest.filesRead(computer: computer, path: paths.settings, offset: nil, length: nil)
        let root = try #require(try JSONSerialization.jsonObject(with: updated.data) as? [String: Any])
        let entries = try #require((root["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
        let hooks = try #require(entries.first?["hooks"] as? [[String: Any]])
        #expect(!hooks.contains { $0["command"] as? String == command })
        #expect(hooks.contains { $0["command"] as? String == "custom-hook" })
    }

    @Test func guestFormWatcherAnswersCreateOnlyAndUsesGuestProcessChecks() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.forms, FormBridge.marker),
                                         data: Data(), mode: 0o600))
        let formData = try JSONSerialization.data(withJSONObject: [
            "key": "session-100-42", "session_id": "session", "transcript_path": "/home/guest/.claude/projects/p/session.jsonl",
            "tool_name": FormHook.questionTool, "tool_input": ["questions": [["question": "Ship?", "options": [["label": "Yes"]]]]],
            "created_at": 100, "pid": 42, "tool_use_id": "tool-1",
        ])
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.forms, "session-100-42.json"),
                                         data: formData, mode: 0o600))
        let reader = GuestForms(client: guest)
        let snapshot = try await reader.watch(computer: computer, paths: paths)
        let key = GuestFormKey(location: .computer(deviceId: computer.deviceId, computerId: computer.computerId),
                               cliSessionID: "session")
        let pending = try #require(snapshot.forms[key])
        try await reader.answer(pending, answers: ["Ship?": "Yes"])
        let answerPath = GuestRouterPaths.join(paths.forms, "session-100-42.answer.json")
        let answer = try await guest.filesRead(computer: computer, path: answerPath, offset: nil, length: nil)
        #expect(try JSONSerialization.jsonObject(with: answer.data) as? [String: Any] != nil)
        #expect(await guest.execRecords().contains { $0.argv == ["/bin/kill", "-0", "42"] })
        let log = await guest.callLog()
        let watch = try #require(log.firstIndex(of: "watch:\(paths.forms)"))
        let markerRead = try #require(log.firstIndex(of: "read:\(GuestRouterPaths.join(paths.forms, FormBridge.marker))"))
        #expect(watch < markerRead)
        await #expect(throws: FormWriter.AlreadyAnswered.self) { try await reader.answer(pending, answers: ["Ship?": "Yes"]) }
    }

    @MainActor @Test func routerOffDuringGuestAccountLookupRejectsAStaleFormApproval() async throws {
        defer { GuestRouterRuntime.shared.stopAll() }
        let store = Store(engineClient: MockEngineClient())
        store.persists = false
        store.agents.enabled = true
        store.setRouterEnabled(true)
        let location = SessionLocation.computer(deviceId: computer.deviceId, computerId: computer.computerId)
        let desktopID = "local_guest_stale"
        let form = PendingForm(id: "guest-form-stale", cliSessionID: "cli-guest-stale", transcriptPath: "/guest/transcript.jsonl",
            questions: [.init(question: "Ship?", header: "Ship", multiSelect: false, options: [.init(label: "Yes", description: "")])],
            createdAt: Date(), pid: 42, toolUseID: "tool-stale")
        let guestForm = GuestPendingForm(computer: computer, location: location, form: form)
        var state = store.router
        state.pendingDesktopStarts = [PendingDesktopStart(projectID: UUID(), location: location,
            alias: "ssh-guest-1", folder: "/workspace/repo", prompt: "Start", state: .matched,
            desktopSessionID: desktopID, guestSessionID: form.cliSessionID)]
        state.guestPendingForms = [guestForm]
        state.cards = [RouterCard(id: "\(desktopID)#w1", sessionID: desktopID, kind: .question, title: "Ship?",
            folder: "/workspace/repo", text: "Ship?", createdAt: Date(), toolUseID: form.toolUseID)]
        store.router = state

        let base = client()
        let barrier = GuestAccountBarrier()
        let guest = AccountPausingGuestClient(base: base, barrier: barrier)
        GuestRouterRuntime.shared.registerInstallationTarget(store: store, client: guest, computer: computer)
        let answer = Task {
            try await GuestRouterRuntime.shared.answer(guestForm, answers: ["Ship?": "Yes"], cardID: "\(desktopID)#w1")
        }
        await barrier.waitUntilEntered()
        store.setRouterEnabled(false)
        await barrier.release()
        do {
            try await answer.value
            Issue.record("a guest answer was admitted after Router-off")
        } catch {
            #expect(error is FormWriter.Cancelled)
        }

        let paths = try GuestRouterPaths(home: account.home)
        #expect(await base.filesSnapshot(for: computer)[GuestRouterPaths.join(paths.forms, "\(form.id).answer.json")] == nil)
    }

    @Test func guestRelaySubscribesBeforeWriteAndConsumesAck() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let session = "cli-session-1"
        let nonce = "0123456789abcdef0123456789abcdef"
        let folder = GuestRouterPaths.join(paths.inbox, session)
        let messagePath = GuestRouterPaths.join(folder, "\(nonce).msg")
        let ack = GuestRouterPaths.join(folder, "\(nonce).ack")
        await guest.acknowledgeWhenMessageIsAdmitted(computer: computer, messagePath: messagePath, ackPath: ack,
                                                      data: Data("ok model=opus".utf8), hintPath: folder)
        let signed = "⟦fjord v1 \(session) \(nonce) 2000000000000 \(String(repeating: "a", count: 64))⟧\nYWJj"
        let answer = try await GuestRelayInbox(client: guest, timeout: nil).deliver(signed, to: session, computer: computer)
        let log = await guest.callLog()
        let watch = try #require(log.firstIndex(where: { $0.hasPrefix("watch:") }))
        let write = try #require(log.firstIndex(of: "write:\(GuestRouterPaths.join(folder, "\(nonce).msg"))"))
        #expect(answer == "ok model=opus")
        #expect(watch < write)
        #expect(await guest.filesSnapshot(for: computer)[ack] == nil)
        #expect(await guest.removalRecords().last?.1.count == 2)
    }

    @Test func guestRelayConsumesCoalescedFolderAcknowledgementHintsImmediately() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let cli = "cli-coalesced-ack"
        let nonce = "abcdef0123456789abcdef0123456789"
        let folder = GuestRouterPaths.join(paths.inbox, cli)
        let messagePath = GuestRouterPaths.join(folder, "\(nonce).msg")
        let ackPath = GuestRouterPaths.join(folder, "\(nonce).ack")
        await guest.acknowledgeWhenMessageIsAdmitted(computer: computer, messagePath: messagePath,
                                                      ackPath: ackPath, data: Data("ok".utf8), hintPath: folder)
        await guest.failNextRead(computer: computer, path: ackPath, with: .notFound(ackPath))
        await guest.failNextRead(computer: computer, path: ackPath, with: .notFound(ackPath))
        let signed = "⟦fjord v1 \(cli) \(nonce) 1800000000000 \(String(repeating: "a", count: 64))⟧\nRun checks"
        let ack = try await GuestRelayInbox(client: guest, timeout: nil).deliver(signed, to: cli, computer: computer)

        #expect(ack == "ok")
        #expect(await guest.callLog().filter { $0 == "read:\(ackPath)" }.count == 3)
    }

    @MainActor @Test func launchRehydratesSavedGuestTargetsAndExecutionState() async throws {
        defer { GuestRouterRuntime.shared.stopAll() }
        let guest = client()
        let store = Store()
        store.persists = false
        store.setRouterEnabled(true)
        store.agents.enabled = true
        let projectID = UUID()
        let placement = ProjectPlacement.computer(deviceId: computer.deviceId, computerId: computer.computerId,
                                                  guestPath: "/workspace/project")
        var state = store.router
        state.runsOnProjects = [RunsOnProject(id: projectID, name: "Project", sourceFolder: "/local/project", placement: placement)]
        state.pendingDesktopStarts = [PendingDesktopStart(projectID: projectID,
            location: .computer(deviceId: computer.deviceId, computerId: computer.computerId), alias: "ssh-computer",
            folder: "/workspace/project", prompt: "Ship", openedAt: Date(), state: .matched,
            desktopSessionID: "desktop-1", guestSessionID: "cli-1")]
        store.router = state

        await GuestRouterRuntime.shared.rehydrate(store: store, client: guest)

        let calls = await guest.callLog()
        let guestPaths = try GuestRouterPaths(home: account.home)
        #expect(calls.filter { $0.hasPrefix("watch:") }.count == 1)
        #expect(calls.contains { $0.contains(guestPaths.forms) })
        #expect(store.guestExecutionStates["desktop-1"]?.availability == .dead)
        #expect(store.guestExecutionStates["desktop-1"]?.isRunning == false)
    }

    @Test func guestClockSamplesTheGuestNodeRuntime() async throws {
        let guest = client()
        let milliseconds: Int64 = 1_800_000_000_000
        await guest.setExecResult(GuestExecResult(exitCode: 0, stdout: Data(String(milliseconds).utf8), stderr: Data()),
                                  argv: [account.nodeExecutable, "-e", "process.stdout.write(String(Date.now()))"])

        let sampled = try await GuestClock.sampleMilliseconds(client: guest, computer: computer)

        #expect(sampled >= milliseconds && sampled < milliseconds + 5_000)
        #expect(await guest.execRecords().last?.argv == [account.nodeExecutable, "-e", "process.stdout.write(String(Date.now()))"])
    }

    @Test func guestDeepLinkUsesDocumentedSSHFieldsAndPreservesGuestFolderAndPrompt() async throws {
        let guest = client()
        try await guest.filesWrite(.init(computer: computer, path: "/workspace/repo/.git/config",
            data: Data("[remote \"origin\"]\nurl = https://github.com/acme/widget.git\n".utf8), mode: 0o600))
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-guest-start-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let project = RunsOnProject(name: "widget", sourceFolder: "/local/widget",
                                    placement: .computer(deviceId: computer.deviceId, computerId: computer.computerId,
                                                         guestPath: "/workspace/repo"))
        let prepared = try await GuestDesktopStart.prepare(client: guest, placement: project.placement, project: project,
            prompt: "Fix café & query?", computerName: "Linux dev", settings: ClaudeSSHSettings(home: tempHome))
        let parts = try #require(URLComponents(url: prepared.url, resolvingAgainstBaseURL: false))
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let settingsData = try Data(contentsOf: tempHome.appendingPathComponent(".claude/settings.json"))
        let settingsRoot = try #require(try JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        let ssh = try #require(settingsRoot["sshConfigs"] as? [[String: Any]])

        #expect(parts.scheme == "claude")
        #expect(parts.host == "code")
        #expect(parts.path == "/new")
        #expect(fields["ssh_host"] == prepared.alias.alias)
        #expect(fields["ssh_folder"] == "/workspace/repo")
        #expect(fields["q"] == "Fix café & query?")
        #expect(prepared.pending.state == .readyInClaude)
        #expect(prepared.pending.prompt == "Fix café & query?")
        #expect(ssh.first?["sshHost"] as? String == prepared.alias.alias)
        #expect(ssh.first?["startDirectory"] == nil)
        #expect(FileManager.default.fileExists(atPath: "/workspace/repo/.git/config") == false)
    }

    @Test func guestCodeFolderScannerReadsWorktreeConfigWithoutNormalizingAgainstHost() async throws {
        let guest = client()
        try await guest.filesWrite(.init(computer: computer, path: "/workspace/repo/.git/config",
            data: Data("[remote \"origin\"]\nurl = git@github.com:acme/widget.git\n".utf8), mode: 0o600))
        let scan = try await GuestCodeFolders(client: guest).scan(computer: computer, roots: ["/workspace"])

        #expect(scan.repos["/workspace/repo"] == ["acme/widget"])
        #expect(scan.cutShort == false)
        #expect(GuestCodeFolders.resolveGuest("../common", from: "/home/guest/repo/.git/worktrees/wt") == "/home/guest/repo/.git/worktrees/common")
        #expect(FileManager.default.fileExists(atPath: "/workspace/repo/.git/config") == false)
    }

    @Test func pendingStartMatcherRequiresOwnerHostIdAndSentPromptInGuestTranscript() {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = PendingDesktopStart(projectID: UUID(), location: .computer(deviceId: "owner-1", computerId: "computer-1"),
            alias: "ssh-computer-1", folder: "/workspace/repo", prompt: "Fix the bug", openedAt: opened)
        let message = SessionFork.Message(uuid: "message-1", parent: nil, text: "Fix the bug now", cwd: "/workspace/repo",
                                          at: opened.addingTimeInterval(10))
        let evidence = GuestSessionEvidence(computer: computer, cliSessionID: "cli-1", hostSessionID: "local_desktop-1",
            pid: 42, startedAt: 123, renewedAt: 1_800_000_010_000, capabilities: [ClaudePlugin.inboxCapability],
            transcriptMessages: [message])
        let desktop = [DesktopSSHSession(id: "local_desktop-1", alias: "ssh-computer-1", folder: "/workspace/repo")]

        #expect(PendingDesktopStartMatcher.match(pending, desktop: desktop, evidence: [evidence]) == evidence)
        #expect(PendingDesktopStartMatcher.match(pending, desktop: [desktop[0], desktop[0]], evidence: [evidence]) == nil)
        #expect(PendingDesktopStartMatcher.match(pending, desktop: desktop, evidence: []) == nil)
        let sameFolderElsewhere = DesktopSSHSession(id: "local_other", alias: "ssh-other-computer", folder: pending.folder)
        #expect(PendingDesktopStartMatcher.match(pending, desktop: desktop + [sameFolderElsewhere], evidence: [evidence]) == evidence)
    }

    @Test func pendingStartMatchesAFormBackedSessionWithoutPluginPresence() {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = PendingDesktopStart(projectID: UUID(), location: .computer(deviceId: "owner-1", computerId: "computer-1"),
            alias: "ssh-computer-1", folder: "/workspace/repo", prompt: "Fix the bug", openedAt: opened)
        let message = SessionFork.Message(uuid: "message-1", parent: nil, text: "Fix the bug now", cwd: "/workspace/repo",
                                          at: opened.addingTimeInterval(10))
        var evidence = GuestSessionEvidence(computer: computer, cliSessionID: "cli-1", hostSessionID: "local_desktop-1",
            pid: 42, startedAt: 123, renewedAt: 1_800_000_010_000, capabilities: [], transcriptMessages: [message])
        let desktop = [DesktopSSHSession(id: "local_desktop-1", alias: "ssh-computer-1", folder: "/workspace/repo")]

        #expect(PendingDesktopStartMatcher.match(pending, desktop: desktop, evidence: [evidence]) == nil)
        evidence.formBacked = true
        #expect(PendingDesktopStartMatcher.match(pending, desktop: desktop, evidence: [evidence]) == evidence)
    }

    @MainActor @Test func aFolderInsideAComputerIsNeverOfferedAsAMacProject() {
        let store = InboxFixture.store([])
        store.agents.enabled = true
        store.claudeSessions = [
            "local_mac": ClaudeSession(id: "local_mac", title: "Mac", folder: "/code/app", lastActivity: Date(), running: false),
            "local_guest": ClaudeSession(id: "local_guest", title: "Guest", folder: "/home/silo/e2e-proj",
                lastActivity: Date(), running: false, cliID: "cli-guest", sshHost: "ssh-computer-1"),
        ]
        #expect(store.knownFolders == ["/code/app"])
        // A local session in a folder of the same path keeps it a Mac project.
        store.claudeSessions["local_same"] = ClaudeSession(id: "local_same", title: "Same", folder: "/home/silo/e2e-proj",
            lastActivity: Date(), running: false)
        #expect(store.knownFolders.contains("/home/silo/e2e-proj"))
    }

    @Test func desktopSessionDecodesItsActualSSHHostAlias() throws {
        let raw = Data(#"{"sessionId":"local_ssh","cliSessionId":"cli-ssh","cwd":"/workspace/repo","sshConfig":{"sshHost":"ssh-guest-1"}}"#.utf8)
        let session = try #require(Claude.decodeSession(raw))
        #expect(session.sshHost == "ssh-guest-1")
    }

    @MainActor @Test func emptyPrefillsMatchAndADesktopSessionCanOnlyBeClaimedOnce() {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let location = SessionLocation.computer(deviceId: computer.deviceId, computerId: computer.computerId)
        let message = SessionFork.Message(uuid: "message-1", parent: nil, text: "Fix the bug", cwd: "/workspace/repo",
                                          at: opened.addingTimeInterval(10))
        let evidence = GuestSessionEvidence(computer: computer, cliSessionID: "cli-1", hostSessionID: "local_desktop-1",
            pid: 42, startedAt: 123, renewedAt: 1_800_000_010_000, capabilities: [ClaudePlugin.inboxCapability],
            transcriptMessages: [message])
        let desktop = DesktopSSHSession(id: "local_desktop-1", alias: "ssh-computer-1", folder: "/workspace/repo")
        let empty = PendingDesktopStart(projectID: UUID(), location: location, alias: desktop.alias,
            folder: desktop.folder, prompt: "", openedAt: opened)

        #expect(PendingDesktopStartMatcher.match(empty, desktop: [desktop], evidence: [evidence]) == evidence)

        let first = PendingDesktopStart(projectID: UUID(), location: location, alias: desktop.alias,
            folder: desktop.folder, prompt: "Fix", openedAt: opened)
        let second = PendingDesktopStart(projectID: UUID(), location: location, alias: desktop.alias,
            folder: desktop.folder, prompt: "Fix", openedAt: opened)
        var state = RouterState()
        state.pendingDesktopStarts = [first, second]
        let store = Store(engineClient: MockEngineClient())
        store.persists = false
        store.router = state

        #expect(store.reconcileDesktopStart(first.id, desktop: [desktop], evidence: [evidence]))
        #expect(!store.reconcileDesktopStart(second.id, desktop: [desktop], evidence: [evidence]))
        #expect(store.router.pendingDesktopStarts.filter { $0.state == .matched }.count == 1)

        var edited = first
        edited.prompt = "Original prefill"
        let editedEvidence = GuestSessionEvidence(computer: computer, cliSessionID: evidence.cliSessionID,
            hostSessionID: evidence.hostSessionID, pid: evidence.pid, startedAt: evidence.startedAt,
            renewedAt: evidence.renewedAt, capabilities: evidence.capabilities,
            transcriptMessages: [SessionFork.Message(uuid: "message-edited", parent: nil,
                text: "The person edited the prefilled task", cwd: "/workspace/repo", at: opened.addingTimeInterval(10))])
        #expect(PendingDesktopStartMatcher.match(edited, desktop: [desktop], evidence: [editedEvidence]) == nil)
        #expect(PendingDesktopStartMatcher.match(edited, desktop: [desktop], evidence: [editedEvidence],
                                                 allowEditedPrompt: true) == editedEvidence)
    }

    @MainActor @Test func personCanSelectTheActualDesktopSessionAfterEditingThePrefill() async throws {
        defer { GuestRouterRuntime.shared.stopAll() }
        let store = Store(engineClient: MockEngineClient())
        store.persists = false
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let desktopID = "local_edited_guest"
        let cliID = "guest-cli-edited"
        store.claudeSessions[desktopID] = ClaudeSession(id: desktopID, title: "Edited task", folder: "/workspace/repo",
            lastActivity: opened.addingTimeInterval(10), running: false, cliID: cliID, sshHost: "ssh-computer-1")
        let pending = PendingDesktopStart(projectID: UUID(),
            location: .computer(deviceId: computer.deviceId, computerId: computer.computerId),
            alias: "ssh-computer-1", folder: "/workspace/repo", prompt: "Original prefill", openedAt: opened)
        var state = store.router
        state.pendingDesktopStarts = [pending]
        store.router = state

        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let key = String(repeating: "cd", count: 32)
        let start: Int64 = 1_800_000_000_000
        _ = try await guest.filesWrite(.init(computer: computer, path: paths.key, data: Data(key.utf8), mode: 0o600))
        let presence = try JSONSerialization.data(withJSONObject: [
            "state": "live", "sessionId": cliID, "pid": 42, "startedAt": 123,
            "keyId": ClaudePlugin.keyID(of: key), "renewedAt": start, "capabilities": [ClaudePlugin.inboxCapability],
        ])
        _ = try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.presence, cliID), data: presence, mode: 0o600))
        let registry = try JSONSerialization.data(withJSONObject: [
            "hostSessionId": desktopID, "sessionId": cliID, "pid": 42, "startedAt": 123,
        ])
        _ = try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.registry, "42.json"), data: registry, mode: 0o600))
        let transcript = try JSONSerialization.data(withJSONObject: [
            "type": "user", "uuid": "message-edited", "cwd": "/workspace/repo", "timestamp": "2027-01-15T08:00:10.000Z",
            "message": ["role": "user", "content": "The person edited the prefilled task"],
        ], options: [.sortedKeys]) + Data("\n".utf8)
        _ = try await guest.filesWrite(.init(computer: computer,
            path: GuestRouterPaths.join(GuestRouterPaths.join(paths.projects, "workspace-repo"), "\(cliID).jsonl"),
            data: transcript, mode: 0o600))
        let clockArgv = [account.nodeExecutable, "-e", "process.stdout.write(String(Date.now()))"]
        await guest.setExecResult(GuestExecResult(exitCode: 0, stdout: Data(String(start + 1_000).utf8), stderr: Data()), argv: clockArgv)

        try await GuestRouterRuntime.shared.startWatching(store: store, client: guest, computer: computer)

        #expect(store.router.pendingDesktopStarts.first?.state == .readyInClaude)
        #expect(GuestRouterRuntime.shared.selectableDesktopSessions(for: pending.id).map(\.id) == [desktopID])
        #expect(GuestRouterRuntime.shared.selectDesktopSession(desktopID, for: pending.id))
        #expect(store.router.pendingDesktopStarts.first?.state == .matched)
        #expect(store.router.pendingDesktopStarts.first?.guestSessionID == cliID)
    }

    @MainActor @Test func dispatcherSendsAndChecksAbortForGuestWithoutLocalClaude() async throws {
        defer { GuestRouterRuntime.shared.stopAll() }
        let store = Store(engineClient: MockEngineClient())
        store.persists = false
        store.router.enabled = true
        store.agents.enabled = true
        let desktopID = "local_guest_dispatch"
        let cliID = "guest-cli-dispatch"
        let location = SessionLocation.computer(deviceId: computer.deviceId, computerId: computer.computerId)
        let start: Int64 = 1_800_000_000_000
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let key = String(repeating: "ef", count: 32)
        _ = try await guest.filesWrite(.init(computer: computer, path: paths.key, data: Data(key.utf8), mode: 0o600))
        let presence = try JSONSerialization.data(withJSONObject: [
            "state": "live", "sessionId": cliID, "pid": 42, "startedAt": 123,
            "keyId": ClaudePlugin.keyID(of: key), "renewedAt": start,
            "capabilities": [ClaudePlugin.inboxCapability, ClaudePlugin.abortCapability],
        ])
        _ = try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.presence, cliID), data: presence, mode: 0o600))
        let registry = try JSONSerialization.data(withJSONObject: [
            "hostSessionId": desktopID, "sessionId": cliID, "pid": 42, "startedAt": 123,
        ])
        _ = try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.registry, "42.json"), data: registry, mode: 0o600))
        let transcript = try JSONSerialization.data(withJSONObject: [
            "type": "user", "uuid": "dispatch-user", "cwd": "/workspace/repo", "timestamp": "2027-01-15T08:00:10.000Z",
            "message": ["role": "user", "content": "Run the checks"],
        ], options: [.sortedKeys]) + Data("\n".utf8)
        _ = try await guest.filesWrite(.init(computer: computer,
            path: GuestRouterPaths.join(GuestRouterPaths.join(paths.projects, "workspace-repo"), "\(cliID).jsonl"),
            data: transcript, mode: 0o600))
        let clockArgv = [account.nodeExecutable, "-e", "process.stdout.write(String(Date.now()))"]
        await guest.setExecResult(GuestExecResult(exitCode: 0, stdout: Data(String(start + 1_000).utf8), stderr: Data()), argv: clockArgv)
        let nonce = "0123456789abcdef0123456789abcdef"
        let signed = "⟦fjord v1 \(cliID) \(nonce) \(start + 60_000) \(String(repeating: "a", count: 64))⟧\nRun the checks"
        let ackPath = GuestRouterPaths.join(GuestRouterPaths.join(paths.inbox, cliID), "\(nonce).ack")
        let messagePath = GuestRouterPaths.join(GuestRouterPaths.join(paths.inbox, cliID), "\(nonce).msg")
        await guest.acknowledgeWhenMessageIsAdmitted(computer: computer, messagePath: messagePath,
                                                      ackPath: ackPath, data: Data("ok".utf8))
        store.claudeSessions[desktopID] = ClaudeSession(id: desktopID, title: "Guest task", folder: "/workspace/repo",
            lastActivity: Date(timeIntervalSince1970: Double(start) / 1000), running: true, cliID: cliID, sshHost: "ssh-computer-1")
        store.router.pendingDesktopStarts = [PendingDesktopStart(projectID: UUID(), location: location,
            alias: "ssh-computer-1", folder: "/workspace/repo", prompt: "Run the checks", openedAt: Date(timeIntervalSince1970: Double(start) / 1000),
            state: .matched, desktopSessionID: desktopID, guestSessionID: cliID)]
        try await GuestRouterRuntime.shared.startWatching(store: store, client: guest, computer: computer)

        let tools = RouterTools(store: store)
        tools.beginTurn("Run the checks")
        tools.prepared["peer-guest"] = Prepared(text: signed, original: "Run the checks", rephrased: false,
            body: "Run the checks", guestLocation: location)
        store.routerDispatcher.claudePath = { nil }
        let effects = RouterDispatcher.Effects.live(store.routerDispatcher)
        #expect(await effects.abortable(cliID))
        do {
            let ack = try await effects.send(tools, .init(to: "peer-guest", text: signed, body: "Run the checks",
                original: "Run the checks", rephrased: false, session: desktopID, newSessionIn: nil))
            #expect(ack == "ok")
        } catch {
            Issue.record("guest delivery required local Claude Code: \(error.localizedDescription)")
        }
        #expect(await guest.writeRecords().contains { $0.path == messagePath && $0.data == Data(signed.utf8) })
    }

    @MainActor @Test func matchedSessionKeepsGuestIdentityWhenMappedBackToItsRouterProject() {
        let store = Store(engineClient: MockEngineClient())
        store.persists = false
        let source = "/local/widget"
        let project = RunsOnProject(name: "widget", sourceFolder: source,
            placement: .computer(deviceId: computer.deviceId, computerId: computer.computerId, guestPath: "/workspace/repo"))
        let pending = PendingDesktopStart(projectID: project.id,
            location: .computer(deviceId: computer.deviceId, computerId: computer.computerId),
            alias: "ssh-computer-1", folder: "/workspace/repo", prompt: "Fix it", state: .matched,
            desktopSessionID: "local_desktop-1", guestSessionID: "cli-1")
        var state = RouterState()
        state.runsOnProjects = [project]
        state.pendingDesktopStarts = [pending]
        store.router = state
        store.claudeSessions[pending.desktopSessionID!] = ClaudeSession(id: pending.desktopSessionID!, title: "Fix it",
            folder: "/host/mirror/ssh-computer-1", lastActivity: Date(), running: true)

        #expect(store.routerProjectFolder(sessionID: "local_desktop-1") == source)
        #expect(store.routerSessionProject("local_desktop-1").name.contains("/workspace/repo"))
        #expect(store.routerProjectGroupKey(sessionID: "local_desktop-1", folder: "/host/mirror/ssh-computer-1")
                == "guest-project:\(project.id.uuidString):\(pending.location.key):/workspace/repo")
    }

    @Test func localPeerReadersNeverProbeHostPIDsForMatchedGuestSessions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-peer-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"hostSessionId":"local_guest","sessionId":"cli-1","pid":4242,"name":"Guest"}"#.utf8)
            .write(to: dir.appendingPathComponent("4242.json"))
        try Data(#"{"hostSessionId":"local_host","sessionId":"cli-2","pid":5151,"name":"Local"}"#.utf8)
            .write(to: dir.appendingPathComponent("5151.json"))
        var probed: [Int32] = []
        let alive: (Int32) -> Bool = { probed.append($0); return true }

        let peers = RouterTools.localPeers(dir: dir, excluding: ["local_guest"], alive: alive)
        #expect(peers["local_guest"] == nil)
        #expect(peers["local_host"]?.name == "Local")
        #expect(probed == [5151])
        probed = []
        let cliIDs = RouterTools.cliSessions(dir: dir, excluding: ["local_guest"], alive: alive)
        #expect(cliIDs == ["local_host": ["cli-2"]])
        #expect(probed == [5151])
    }

    @Test func guestTranscriptReaderDropsRangedAndUnfinishedJSONLFragments() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let cli = "cli-transcript-1"
        let directory = GuestRouterPaths.join(paths.projects, "workspace-repo")
        let head = try JSONSerialization.data(withJSONObject: [
            "type": "user", "uuid": "old", "cwd": "/workspace/repo", "message": ["content": String(repeating: "x", count: 500)],
        ], options: [.sortedKeys])
        let current = try JSONSerialization.data(withJSONObject: [
            "type": "user", "uuid": "current", "cwd": "/workspace/repo", "timestamp": "2026-12-15T16:00:10.000Z",
            "message": ["role": "user", "content": "Current guest message"],
        ], options: [.sortedKeys])
        let partial = Data("{\"type\":\"assistant\",\"message\":{\"content\":[".utf8)
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(directory, "\(cli).jsonl"),
            data: head + Data("\n".utf8) + current + Data("\n".utf8) + partial, mode: 0o600))

        let result = try await GuestTranscripts(client: guest, tailLimit: 300)
            .read(computer: computer, projectsRoot: paths.projects, cliSessionID: cli)
        let snapshot = try #require(result)

        #expect(snapshot.path == GuestRouterPaths.join(directory, "\(cli).jsonl"))
        #expect(snapshot.messages.map(\.uuid) == ["current"])
        #expect(snapshot.messages.first?.cwd == "/workspace/repo")
        #expect(snapshot.size > Int64(snapshot.tail.count))
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
    }

    @Test func guestTranscriptCacheReusesStableTailAndInvalidatesOnReplacementAndShrink() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let cli = "cli-cache"
        let directory = GuestRouterPaths.join(paths.projects, "workspace-repo")
        let path = GuestRouterPaths.join(directory, "\(cli).jsonl")
        func line(_ uuid: String, _ content: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "type": "user", "uuid": uuid, "cwd": "/workspace/repo",
                "message": ["role": "user", "content": content],
            ], options: [.sortedKeys]) + Data("\n".utf8)
        }
        try await guest.filesWrite(.init(computer: computer, path: path, data: line("one", "first"), mode: 0o600))
        let reader = GuestTranscripts(client: guest, tailLimit: 4096)

        let first = try #require(try await reader.read(computer: computer, projectsRoot: paths.projects, cliSessionID: cli))
        let afterFirst = await guest.callLog().filter { $0 == "read:\(path)" }.count
        let second = try #require(try await reader.read(computer: computer, projectsRoot: paths.projects, cliSessionID: cli))
        let afterSecond = await guest.callLog().filter { $0 == "read:\(path)" }.count
        #expect(first == second)
        #expect(afterFirst == 2)
        #expect(afterSecond == afterFirst + 1)

        try await guest.filesWrite(.init(computer: computer, path: path, data: line("two", "replacement"), mode: 0o600))
        let replaced = try #require(try await reader.read(computer: computer, projectsRoot: paths.projects, cliSessionID: cli))
        #expect(replaced.inode == first.inode)
        #expect(replaced.mtimeMs != first.mtimeMs)
        #expect(replaced.messages.map(\.uuid) == ["two"])

        try await guest.filesWrite(.init(computer: computer, path: path, data: line("three", "x"), mode: 0o600))
        let shrunk = try #require(try await reader.read(computer: computer, projectsRoot: paths.projects, cliSessionID: cli))
        #expect(shrunk.size < replaced.size)
        #expect(shrunk.messages.map(\.uuid) == ["three"])
    }

    @Test func guestBackgroundCommandTasksUseTheGuestFdTable() async throws {
        let guest = client()
        let root = "/tmp/claude-\(account.uid)"
        let tasks = GuestRouterPaths.join(GuestRouterPaths.join(GuestRouterPaths.join(root, "-workspace-repo"), "cli-parent"), "tasks")
        let output = GuestRouterPaths.join(tasks, "task-1.output")
        try await guest.filesWrite(.init(computer: computer, path: output, data: Data("still running".utf8), mode: 0o600))
        let request = GuestBackgroundTasks.openOutputsRequest(computer: computer, account: account, root: root)
        await guest.setExecResult(GuestExecResult(exitCode: 0, stdout: Data((output + "\n").utf8), stderr: Data()), argv: request.argv)

        let read = await GuestBackgroundTasks(client: guest).read(computer: computer, account: account,
            cliSessionID: "cli-parent", projectFolders: ["/workspace/repo"], parentTranscript: Data(),
            now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(read.certain)
        #expect(read.tasks.map(\.id) == ["task-1"])
        #expect(read.tasks.first?.kind == .command)
        let exec = try #require(await guest.execRecords().first)
        #expect(Array(exec.argv.prefix(2)) == ["/bin/sh", "-c"])
        #expect(Array(exec.argv.suffix(2)) == [String(account.uid), root])
    }

    @MainActor @Test func routerGuestStartPersistsReadyStateBeforeOpenWithoutSendingPrompt() async throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-router-guest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let engine = engineWithComputer(state: .stopped)
        let store = Store(engineClient: engine)
        store.stateFile = tempHome.appendingPathComponent("state.json")
        store.router.enabled = true
        store.agents.enabled = true
        let source = "/local/widget"
        store.claudeSessions["local_existing"] = ClaudeSession(id: "local_existing", title: "Existing", folder: source,
            lastActivity: Date(), running: false)
        store.setRunsOnPlacement(.computer(deviceId: nil, computerId: computer.computerId,
                                           guestPath: "/workspace/repo"), for: source)
        let guest = MockGuestClient(accounts: [localComputer: account])
        let clockArgv = [account.nodeExecutable, "-e", "process.stdout.write(String(Date.now()))"]
        await guest.setExecResult(GuestExecResult(exitCode: 0, stdout: Data("1800000000000".utf8), stderr: Data()), argv: clockArgv)
        var captured: String?
        var openCount = 0
        var sawPersistedPendingStart = false
        store.interceptOpen = { message in
            openCount += 1
            captured = message
            guard let data = try? Data(contentsOf: tempHome.appendingPathComponent("state.json")),
                  let state = Store.decodeState(data) else { return }
            sawPersistedPendingStart = state.router?.pendingDesktopStarts.count == 1
        }
        let tools = RouterTools(store: store)
        tools.guestClient = guest
        tools.guestSSHSettings = ClaudeSSHSettings(home: tempHome)
        tools.beginTurn("Fix the bug in widget")
        defer { GuestRouterRuntime.shared.stopAll() }

        let result = try await tools.startSession(store, project: "widget", title: "Fix it", ticket: tools.ticket())
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let pending = try #require(store.router.pendingDesktopStarts.first)
        let callsBeforeRetry = await guest.execRecords().count
        let retry = try await tools.startSession(store, project: "widget", title: "Fix it", ticket: tools.ticket())
        let retryObject = try #require(try JSONSerialization.jsonObject(with: Data(retry.utf8)) as? [String: Any])
        let guestPaths = try GuestRouterPaths(home: account.home)
        let calls = await guest.callLog()
        let watchLog = calls.filter { $0.hasPrefix("watch:") }

        #expect(sawPersistedPendingStart)
        #expect(engine.inventory.computer(computer.computerId)?.displayState == .running)
        #expect(openCount == 1)
        #expect(captured?.contains("claude://code/new?") == true)
        #expect((retryObject["pendingStart"] as? String) == pending.id.uuidString)
        #expect(store.router.pendingDesktopStarts.count == 1)
        #expect(await guest.execRecords().count == callsBeforeRetry)
        #expect(watchLog.contains { $0.contains(guestPaths.projects) })
        #expect(object["state"] as? String == "ready_in_claude")
        #expect(pending.state == .readyInClaude)
        #expect(pending.guestSessionID == nil)
        #expect(tools.prepared.isEmpty)
        #expect((object["next"] as? String)?.contains("press Send in Claude") == true)
    }

    @MainActor @Test func dispatcherRecordsGuestStartWithoutExpectingLocalPeerPreparation() async throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-router-dispatch-guest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer {
            GuestRouterRuntime.shared.stopAll()
            try? FileManager.default.removeItem(at: tempHome)
        }

        let store = Store(engineClient: engineWithComputer(state: .running))
        store.stateFile = tempHome.appendingPathComponent("state.json")
        store.persists = false
        store.router.enabled = true
        store.agents.enabled = true
        let source = "/local/widget"
        store.claudeSessions["local_existing"] = ClaudeSession(id: "local_existing", title: "Existing", folder: source,
            lastActivity: Date(), running: false)
        store.setRunsOnPlacement(.computer(deviceId: nil, computerId: computer.computerId,
                                           guestPath: "/workspace/repo"), for: source)
        var opens = 0
        store.interceptOpen = { _ in opens += 1 }

        let guest = MockGuestClient(accounts: [localComputer: account])
        await guest.setExecResult(GuestExecResult(exitCode: 0, stdout: Data("1800000000000".utf8), stderr: Data()),
            argv: [account.nodeExecutable, "-e", "process.stdout.write(String(Date.now()))"])
        let dispatcher = store.routerDispatcher
        let finished = GuestRouterGate()
        dispatcher.onFinish = { _ in Task { await finished.open() } }
        dispatcher.configure = { tools in
            tools.guestClient = guest
            tools.guestSSHSettings = ClaudeSSHSettings(home: tempHome)
        }

        let id = try #require(dispatcher.submit("start a new session to fix the bug", context: RouterContext(projects: [source])))
        await finished.wait()
        let entry = try #require(store.router.decisions.first(where: { $0.id == id }))

        let prepared = try #require(entry.done.compactMap { item -> (String, String, String)? in
            if case .preparedGuest(let project, let location, let pendingStart) = item { return (project, location, pendingStart) }
            return nil
        }.first)
        #expect(entry.doneLines.allSatisfy { !$0.contains("Not prepared") && !$0.hasPrefix("failed:") })
        #expect(entry.outcome == .done)
        #expect(opens == 1)
        #expect(store.router.pendingDesktopStarts.count == 1)
        #expect(prepared.0 == "widget")
        #expect(prepared.1 == "local/\(computer.computerId)")
        #expect(prepared.2 == store.router.pendingDesktopStarts[0].id.uuidString)
    }

    @MainActor @Test func disablingRouterDuringGuestInstallWaitsAndRevokesTheInstallation() async throws {
        defer { GuestRouterRuntime.shared.stopAll() }
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-router-disable-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let store = Store(engineClient: engineWithComputer(state: .running))
        store.stateFile = tempHome.appendingPathComponent("state.json")
        store.persists = false
        store.router.enabled = true
        store.agents.enabled = true
        let source = "/local/widget"
        store.claudeSessions["local_existing"] = ClaudeSession(id: "local_existing", title: "Widget", folder: source,
            lastActivity: Date(), running: false)
        store.setRunsOnPlacement(.computer(deviceId: nil, computerId: computer.computerId, guestPath: "/workspace/repo"), for: source)
        let guest = MockGuestClient(accounts: [localComputer: account])
        let paths = try GuestRouterPaths(home: account.home)
        let marketplace = [account.claudeExecutable, "plugin", "marketplace", "add", paths.plugin, "--scope", "user"]
        await guest.pauseNextExec(argv: marketplace)
        let tools = RouterTools(store: store)
        tools.guestClient = guest
        tools.guestSSHSettings = ClaudeSSHSettings(home: tempHome)
        tools.beginTurn("Fix the bug in widget")

        let starting = Task { try await tools.startSession(store, project: "widget", title: "Fix it", ticket: tools.ticket()) }
        await guest.waitForExecPause(argv: marketplace)
        store.switchRouter(false)
        await guest.resumeExec(argv: marketplace)
        do { _ = try await starting.value } catch { }

        let location = SessionLocation.computer(deviceId: nil, computerId: computer.computerId)
        await GuestRouterRuntime.shared.waitForDisable()
        #expect(store.router.pendingDesktopStarts.isEmpty)
        #expect(store.router.pendingGuestDisables.isEmpty)
        #expect(await guest.filesSnapshot(for: localComputer)[paths.key] == nil)
        #expect(await guest.filesSnapshot(for: localComputer)[GuestRouterPaths.join(paths.forms, FormBridge.marker)] == nil)
    }

    @Test func guestPresenceRequiresGuestPIDRegistryAndAuthoritativeTranscript() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let cli = "cli-session-1"
        let pid: Int32 = 42
        let start = Int64(1_800_000_000_000)
        let key = String(repeating: "ab", count: 32)
        try await guest.filesWrite(.init(computer: computer, path: paths.key, data: Data((key + "\n").utf8), mode: 0o600))
        let presence = try JSONSerialization.data(withJSONObject: [
            "state": "live", "sessionId": cli, "pid": pid, "startedAt": 123,
            "keyId": ClaudePlugin.keyID(of: key), "renewedAt": start, "capabilities": [ClaudePlugin.inboxCapability],
        ])
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.presence, cli), data: presence, mode: 0o600))
        let registry = try JSONSerialization.data(withJSONObject: [
            "hostSessionId": "local_desktop-1", "sessionId": cli, "pid": pid, "startedAt": 123,
        ])
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.registry, "42.json"), data: registry, mode: 0o600))
        let transcript = try JSONSerialization.data(withJSONObject: [
            "type": "user", "uuid": "message-1", "cwd": "/workspace/repo", "timestamp": "2026-12-15T16:00:10.000Z",
            "message": ["role": "user", "content": "Fix the bug"],
        ], options: [.sortedKeys]) + Data("\n".utf8)
        try await guest.filesWrite(.init(computer: computer,
            path: GuestRouterPaths.join(GuestRouterPaths.join(paths.projects, "workspace-repo"), "\(cli).jsonl"),
            data: transcript, mode: 0o600))
        let evidence = try await GuestSessionObserver(client: guest).read(computer: computer, paths: paths, guestNowMs: start + 10_000)

        #expect(evidence.count == 1)
        #expect(evidence.first?.cliSessionID == cli)
        #expect(evidence.first?.hostSessionID == "local_desktop-1")
        #expect(evidence.first?.transcriptMessages.first?.text == "Fix the bug")
        await guest.setExecResult(GuestExecResult(exitCode: 1, stdout: Data(), stderr: Data("Operation not permitted".utf8)), argv: ["/bin/kill", "-0", "42"])
        #expect(try await GuestSessionObserver(client: guest).read(computer: computer, paths: paths, guestNowMs: start + 10_000).isEmpty)
    }

    @MainActor @Test func guestTurnCompletionAndIdentitySurviveLocalMirrorRefresh() async throws {
        defer { GuestRouterRuntime.shared.stopAll() }
        let store = Store(engineClient: MockEngineClient())
        store.persists = false
        store.agents.enabled = true
        let desktopID = "local_desktop-guest-state"
        let cliID = "guest-cli-1"
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        store.claudeSessions[desktopID] = ClaudeSession(id: desktopID, title: "Widget", folder: "/workspace/repo",
            lastActivity: opened, running: true, cliID: "mirror-cli")
        store.router.pendingDesktopStarts = [PendingDesktopStart(projectID: UUID(),
            location: .computer(deviceId: computer.deviceId, computerId: computer.computerId),
            alias: "ssh-computer-1", folder: "/workspace/repo", prompt: "Fix it", openedAt: opened,
            state: .matched, desktopSessionID: desktopID, guestSessionID: cliID)]

        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let key = String(repeating: "ab", count: 32)
        let start: Int64 = 1_800_000_000_000
        try await guest.filesWrite(.init(computer: computer, path: paths.key, data: Data(key.utf8), mode: 0o600))
        let presence = try JSONSerialization.data(withJSONObject: [
            "state": "live", "sessionId": cliID, "pid": 42, "startedAt": 123,
            "keyId": ClaudePlugin.keyID(of: key), "renewedAt": start, "capabilities": [ClaudePlugin.inboxCapability],
        ])
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.presence, cliID), data: presence, mode: 0o600))
        let registry = try JSONSerialization.data(withJSONObject: [
            "hostSessionId": desktopID, "sessionId": cliID, "pid": 42, "startedAt": 123,
        ])
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.registry, "42.json"), data: registry, mode: 0o600))
        let final = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "uuid": "final-1", "cwd": "/workspace/repo", "timestamp": "2026-12-15T16:00:10.000Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": "Done" ]], "stop_reason": "end_turn"],
        ], options: [.sortedKeys]) + Data("\n".utf8)
        try await guest.filesWrite(.init(computer: computer,
            path: GuestRouterPaths.join(GuestRouterPaths.join(paths.projects, "workspace-repo"), "\(cliID).jsonl"),
            data: final, mode: 0o600))
        let clockArgv = [account.nodeExecutable, "-e", "process.stdout.write(String(Date.now()))"]
        await guest.setExecResult(GuestExecResult(exitCode: 0, stdout: Data(String(start + 1_000).utf8), stderr: Data()), argv: clockArgv)

        try await GuestRouterRuntime.shared.startWatching(store: store, client: guest, computer: computer)

        #expect(store.claudeSessions[desktopID]?.running == false)
        #expect(store.claudeSessions[desktopID]?.cliID == cliID)
        #expect(store.claudeActivity[desktopID]?.text == "Writing")
        #expect(store.guestExecutionStates[desktopID]?.availability == .live)
        #expect(store.guestExecutionStates[desktopID]?.isRunning == false)
        let matchedSession = try #require(store.claudeSessions[desktopID])
        #expect(await store.finalMessage(matchedSession) == "Done")

        var mirror = ClaudeSession(id: desktopID, title: "Widget", folder: "/workspace/repo", lastActivity: opened,
                                  running: true, cliID: "mirror-cli")
        mirror.completedTurns = 0
        var snapshot = ClaudeSnapshot()
        snapshot.sessions = [mirror]
        snapshot.activity = [desktopID: ClaudeActivity(text: "Reading stale mirror", since: opened)]
        // A read of the app as the feed makes one, stamped when it is taken: one stamped before a change since would be
        // dropped for a real read of this machine (none of these sessions).
        snapshot.stamp = store.claudeStamp
        store.applyClaude(snapshot)

        #expect(store.claudeSessions[desktopID]?.running == false)
        #expect(store.claudeSessions[desktopID]?.cliID == cliID)
        #expect(store.claudeActivity[desktopID]?.text == "Writing")

        await guest.failNextRead(computer: computer, path: paths.key, with: .unavailable("temporary read failure"))
        let inaccessible = GuestRouterGate()
        let dead = GuestRouterGate()
        GuestRouterRuntime.shared.didRefresh = { _ in
            if store.guestExecutionStates[desktopID]?.availability == .inaccessible { Task { await inaccessible.open() } }
            if store.guestExecutionStates[desktopID]?.availability == .dead { Task { await dead.open() } }
        }
        _ = try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.presence, cliID),
                                              data: presence, mode: 0o600))
        await inaccessible.wait()
        snapshot.stamp = store.claudeStamp
        store.applyClaude(snapshot)
        #expect(store.claudeSessions[desktopID]?.running == false)
        #expect(store.claudeActivity[desktopID]?.text == "Writing")

        _ = try await guest.filesRemove(computer: computer, paths: [GuestRouterPaths.join(paths.presence, cliID)])
        await dead.wait()
        #expect(store.claudeSessions[desktopID]?.running == false)
        #expect(store.claudeActivity[desktopID] == nil)
    }

    @Test func signedGuestRelayUsesGuestKeyAndPersistsDeliveryState() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let cli = "cli-session-1"
        let nonce = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
        let nonceText = nonce.uuidString.lowercased()
        let start: Int64 = 1_800_000_000_000
        let key = String(repeating: "cd", count: 32)
        try await guest.filesWrite(.init(computer: computer, path: paths.key, data: Data(key.utf8), mode: 0o600))
        let presence = try JSONSerialization.data(withJSONObject: [
            "state": "live", "sessionId": cli, "pid": 42, "startedAt": 123,
            "keyId": ClaudePlugin.keyID(of: key), "renewedAt": start, "capabilities": [ClaudePlugin.inboxCapability],
        ])
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.presence, cli), data: presence, mode: 0o600))
        let registry = try JSONSerialization.data(withJSONObject: [
            "hostSessionId": "local_desktop-1", "sessionId": cli, "pid": 42, "startedAt": 123,
        ])
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.registry, "42.json"), data: registry, mode: 0o600))
        let folder = GuestRouterPaths.join(paths.inbox, cli)
        let messagePath = GuestRouterPaths.join(folder, "\(nonceText).msg")
        let ack = GuestRouterPaths.join(folder, "\(nonceText).ack")
        await guest.acknowledgeWhenMessageIsAdmitted(computer: computer, messagePath: messagePath, ackPath: ack,
                                                      data: Data("ok".utf8), hintPath: folder)
        let clockArgv = [account.nodeExecutable, "-e", "process.stdout.write(String(Date.now()))"]
        await guest.setExecResult(GuestExecResult(exitCode: 0, stdout: Data(String(start + 1000).utf8), stderr: Data()), argv: clockArgv)
        let states = GuestRelayStateRecorder()
        let send = GuestRelayDelivery(client: guest, onState: { await states.append($0) })
        let result = try await send.send(body: "Run the checks", to: cli, computer: computer, nonce: nonce,
                                         now: Date(timeIntervalSince1970: Double(start) / 1000))
        let saved = await states.values
        let message = try #require(await guest.writeRecords().first(where: { $0.path == messagePath }))

        #expect(result == "ok")
        #expect(String(decoding: message.data, as: UTF8.self).contains("⟦fjord v1 \(cli) \(nonceText)"))
        #expect(saved.first?.state == .inFlight)
        #expect(saved.last?.state == .delivered)
        #expect(saved.allSatisfy { $0.nonce == nonceText })
    }

    /// A guest session whose plugin runs turn `t9` and can stop and interrupt: set up as a read of its computer finds it.
    @MainActor private func controllableGuest(_ store: Store, desktopID: String, cliID: String, guest: MockGuestClient,
                                              capabilities: [String]) async throws -> GuestRouterPaths {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        store.claudeSessions[desktopID] = ClaudeSession(id: desktopID, title: "Widget", folder: "/workspace/repo",
            lastActivity: opened, running: false, cliID: "mirror-cli")
        store.router.pendingDesktopStarts = [PendingDesktopStart(projectID: UUID(),
            location: .computer(deviceId: computer.deviceId, computerId: computer.computerId),
            alias: "ssh-computer-1", folder: "/workspace/repo", prompt: "Fix it", openedAt: opened,
            state: .matched, desktopSessionID: desktopID, guestSessionID: cliID)]
        let paths = try GuestRouterPaths(home: account.home)
        let key = String(repeating: "ab", count: 32)
        let start: Int64 = 1_800_000_000_000
        try await guest.filesWrite(.init(computer: computer, path: paths.key, data: Data(key.utf8), mode: 0o600))
        let presence = try JSONSerialization.data(withJSONObject: [
            "state": "live", "sessionId": cliID, "pid": 42, "startedAt": 123, "keyId": ClaudePlugin.keyID(of: key),
            "renewedAt": start, "capabilities": capabilities, "turn": ["id": "t9", "startedAt": start - 5000],
        ] as [String: Any])
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.presence, cliID), data: presence, mode: 0o600))
        let registry = try JSONSerialization.data(withJSONObject: [
            "hostSessionId": desktopID, "sessionId": cliID, "pid": 42, "startedAt": 123,
        ])
        try await guest.filesWrite(.init(computer: computer, path: GuestRouterPaths.join(paths.registry, "42.json"), data: registry, mode: 0o600))
        // The transcript's tail looks like a finished turn: the plugin's word for it wins.
        let final = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "uuid": "final-1", "cwd": "/workspace/repo", "timestamp": "2026-12-15T16:00:10.000Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": "Done"]], "stop_reason": "end_turn"],
        ], options: [.sortedKeys]) + Data("\n".utf8)
        try await guest.filesWrite(.init(computer: computer,
            path: GuestRouterPaths.join(GuestRouterPaths.join(paths.projects, "workspace-repo"), "\(cliID).jsonl"),
            data: final, mode: 0o600))
        let clockArgv = [account.nodeExecutable, "-e", "process.stdout.write(String(Date.now()))"]
        await guest.setExecResult(GuestExecResult(exitCode: 0, stdout: Data(String(start + 1_000).utf8), stderr: Data()), argv: clockArgv)
        try await GuestRouterRuntime.shared.startWatching(store: store, client: guest, computer: computer)
        return paths
    }

    /// The guest's plugin: acks the first message it sees in the session's inbox with `answer`.
    private func guestPlugin(_ guest: MockGuestClient, inbox: String, answer: String) -> Task<Void, Never> {
        let computer = computer
        return Task.detached {
            var watchdog = Watchdog()
            while !watchdog.expired() {
                let files = await guest.filesSnapshot(for: computer)
                if let message = files.keys.first(where: { $0.hasPrefix(inbox + "/") && $0.hasSuffix(".msg") }) {
                    let ack = String(message.dropLast(4)) + ".ack"
                    _ = try? await guest.filesWrite(.init(computer: computer, path: ack, data: Data(answer.utf8), mode: 0o600))
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    @MainActor @Test func aGuestSessionRunsATurnWhenItsPluginSaysSoAndItCanBeStoppedAndInterrupted() async throws {
        defer { GuestRouterRuntime.shared.stopAll() }
        let store = Store(engineClient: MockEngineClient())
        store.persists = false
        store.agents.enabled = true
        let desktopID = "local_desktop-control", cliID = "guest-cli-ctl"
        let guest = client()
        let paths = try await controllableGuest(store, desktopID: desktopID, cliID: cliID, guest: guest, capabilities: [
            ClaudePlugin.inboxCapability, ClaudePlugin.stopCapability, ClaudePlugin.interruptCapability])
        let inbox = GuestRouterPaths.join(paths.inbox, cliID)

        // The transcript says the turn ended; the plugin's presence says one runs, and that wins.
        #expect(store.claudeSessions[desktopID]?.running == true)
        #expect(store.guestExecutionStates[desktopID]?.isRunning == true)
        #expect(store.canStop(sessionID: desktopID))
        #expect(store.runningTurn(sessionID: desktopID)?.id == "t9")

        // A gate that refuses stops it before the write: nothing reaches the inbox.
        let refused = await store.stopTurn(sessionID: desktopID) { "The card is gone" }
        guard case .failed(let why) = refused, why.contains("The card is gone") else { Issue.record("\(refused)"); return }
        let interrupted = await store.interrupt(sessionID: desktopID, text: "Never mind", gate: { "The card is gone" })
        guard case .refused(let reason) = interrupted, reason == "The card is gone" else { Issue.record("\(interrupted)"); return }
        #expect(await guest.writeRecords().filter { $0.path.hasPrefix(inbox) }.isEmpty)

        // The stop names the turn presence shows, signed with the guest's key.
        var fake = guestPlugin(guest, inbox: inbox, answer: "ok stopped t9")
        #expect(await store.stopTurn(sessionID: desktopID) == .stopped("t9"))
        await fake.value
        let stop = try #require(await guest.writeRecords().first { $0.path.hasPrefix(inbox) && $0.path.hasSuffix(".msg") })
        let stopText = String(decoding: stop.data, as: UTF8.self)
        #expect(stopText.hasPrefix("⟦fjord stop v1 \(cliID) ") && stopText.contains(" t9 "))

        // The interrupt is a v3 message with the flag.
        fake = guestPlugin(guest, inbox: inbox, answer: "ok interrupted t9")
        let done = await store.interrupt(sessionID: desktopID, text: "Do this instead")
        #expect(done == .delivered(ack: "ok interrupted t9", interrupted: "t9"))
        await fake.value
        let sent = await guest.writeRecords().filter { $0.path.hasPrefix(inbox) && $0.path.hasSuffix(".msg") }
        let text = String(decoding: try #require(sent.last).data, as: UTF8.self)
        #expect(text.hasPrefix("⟦fjord v3 \(cliID) ") && text.split(separator: "\n")[0].contains(" - - 1 "))
    }

    @MainActor @Test func aGuestPluginWithoutStopIsUnsupportedAndNothingIsWritten() async throws {
        defer { GuestRouterRuntime.shared.stopAll() }
        let store = Store(engineClient: MockEngineClient())
        store.persists = false
        store.agents.enabled = true
        let desktopID = "local_desktop-old", cliID = "guest-cli-old"
        let guest = client()
        let paths = try await controllableGuest(store, desktopID: desktopID, cliID: cliID, guest: guest,
                                                capabilities: [ClaudePlugin.inboxCapability, ClaudePlugin.abortCapability])
        #expect(!store.canStop(sessionID: desktopID))
        guard case .unsupported = await store.stopTurn(sessionID: desktopID) else { Issue.record("stop"); return }
        guard case .unsupported = await store.interrupt(sessionID: desktopID, text: "hi") else { Issue.record("interrupt"); return }
        #expect(await guest.writeRecords().filter { $0.path.hasPrefix(GuestRouterPaths.join(paths.inbox, cliID)) }.isEmpty)
    }

    @Test func guestRelayRetryReconcilesTheOriginalNonceAfterAdmissionReplyIsLost() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let cli = "cli-retry-1"
        let nonce = UUID(uuidString: "89abcdef-0123-4567-89ab-cdef01234567")!
        let nonceText = nonce.uuidString.lowercased()
        let folder = GuestRouterPaths.join(paths.inbox, cli)
        let messagePath = GuestRouterPaths.join(folder, "\(nonceText).msg")
        let ackPath = GuestRouterPaths.join(folder, "\(nonceText).ack")
        let key = String(repeating: "ef", count: 32)
        let decisionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let signed = RelaySigner.sign(body: "Run the checks", target: cli, key: key, nonce: nonce,
                                     now: createdAt)
        let states = GuestRelayStateRecorder()
        await guest.failNextWriteAfterAdmission(computer: computer, path: messagePath,
                                                with: .unavailable("reply lost after admission"))

        do {
            _ = try await GuestRelayInbox(client: guest, timeout: nil, onState: { await states.append($0) })
                .deliver(signed, to: cli, computer: computer, now: createdAt, decisionID: decisionID,
                         hostSessionID: "local_desktop-1", body: "Run the checks")
            Issue.record("a lost admission reply was reported as a confirmed delivery")
        } catch {
            #expect(error as? GuestRelayInbox.Failure == .deliveryUnconfirmed(nonceText))
        }
        #expect(await guest.filesSnapshot(for: computer)[messagePath] == Data(signed.utf8))
        #expect(await states.values.last?.state == .unconfirmed)
        #expect(await states.values.last?.signedPayload == signed)
        #expect(await states.values.last?.decisionID == decisionID)
        #expect(await states.values.last?.hostSessionID == "local_desktop-1")
        #expect(await states.values.last?.body == "Run the checks")

        try await guest.filesWrite(.init(computer: computer, path: ackPath, data: Data("ok".utf8), mode: 0o600))
        do {
            let acknowledgement = try await GuestRelayInbox(client: guest, timeout: nil, onState: { await states.append($0) })
                .deliver(signed, to: cli, computer: computer, now: createdAt, decisionID: decisionID,
                         hostSessionID: "local_desktop-1", body: "Run the checks")
            #expect(acknowledgement == "ok")
        } catch {
            Issue.record("retry didn't reconcile the original nonce: \(error.localizedDescription)")
        }

        #expect(await guest.writeRecords().filter { $0.path == messagePath }.count == 1)
        #expect(await states.values.last?.nonce == nonceText)
        #expect(await states.values.last?.state == .delivered)
    }

    @Test func guestRelayAckReadFailureRetainsTheAdmittedPayloadForRetry() async throws {
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let cli = "cli-ack-read"
        let nonce = UUID(uuidString: "fedcba98-7654-3210-fedc-ba9876543210")!
        let nonceText = nonce.uuidString.lowercased()
        let folder = GuestRouterPaths.join(paths.inbox, cli)
        let messagePath = GuestRouterPaths.join(folder, "\(nonceText).msg")
        let ackPath = GuestRouterPaths.join(folder, "\(nonceText).ack")
        let signed = RelaySigner.sign(body: "Run once", target: cli, key: String(repeating: "12", count: 32), nonce: nonce,
                                      now: Date(timeIntervalSince1970: 1_800_000_000))
        let states = GuestRelayStateRecorder()
        await guest.failNextRead(computer: computer, path: ackPath, with: .notFound(ackPath))
        await guest.failNextRead(computer: computer, path: ackPath, with: .unavailable("ack read reply lost"))

        do {
            _ = try await GuestRelayInbox(client: guest, timeout: nil, onState: { await states.append($0) })
                .deliver(signed, to: cli, computer: computer)
            Issue.record("an acknowledgement read failure was reported as a confirmed delivery")
        } catch {
            #expect(error as? GuestRelayInbox.Failure == .deliveryUnconfirmed(nonceText))
        }

        #expect(await states.values.last?.state == .unconfirmed)
        #expect(await states.values.last?.signedPayload == signed)
        #expect(await guest.filesSnapshot(for: computer)[messagePath] == Data(signed.utf8))
        try await guest.filesWrite(.init(computer: computer, path: ackPath, data: Data("ok".utf8), mode: 0o600))
        #expect(try await GuestRelayInbox(client: guest, timeout: nil).deliver(signed, to: cli, computer: computer) == "ok")
        #expect(await guest.writeRecords().filter { $0.path == messagePath }.count == 1)
    }

    @Test func guestRelayGateIsAskedAgainRightBeforeTheWrite() async throws {
        final class Asks: @unchecked Sendable { var count = 0 }
        let guest = client()
        let paths = try GuestRouterPaths(home: account.home)
        let cli = "cli-gate"
        let nonce = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
        let folder = GuestRouterPaths.join(paths.inbox, cli)
        let messagePath = GuestRouterPaths.join(folder, "\(nonce.uuidString.lowercased()).msg")
        let signed = RelaySigner.sign(body: "stop", target: cli, key: String(repeating: "34", count: 32), nonce: nonce,
                                      now: Date(timeIntervalSince1970: 1_800_000_000))
        let asks = Asks()
        // Open at the first look, closed by the time the reads are done (Discard, or the Router turned off meanwhile).
        let gate: @MainActor @Sendable () -> String? = { asks.count += 1; return asks.count >= 2 ? "Discarded" : nil }
        do {
            _ = try await GuestRelayInbox(client: guest, timeout: nil).deliver(signed, to: cli, computer: computer, gate: gate)
            Issue.record("a delivery whose gate closed before the write was sent")
        } catch {
            #expect(error as? GuestRelayInbox.Failure == .refused("Discarded"))
        }
        #expect(await guest.filesSnapshot(for: computer)[messagePath] == nil)
        #expect(await guest.writeRecords().filter { $0.path == messagePath }.isEmpty)
    }

    @MainActor @Test func dispatcherGuestRetryCompletesTheOriginalDecisionWithoutASecondWrite() async throws {
        defer { GuestRouterRuntime.shared.stopAll() }
        let store = Store(engineClient: MockEngineClient())
        store.persists = false
        store.router.enabled = true
        store.agents.enabled = true
        let guest = client()
        try await GuestRouterRuntime.shared.startWatching(store: store, client: guest, computer: computer)

        let paths = try GuestRouterPaths(home: account.home)
        let cli = "cli-retry-dispatch"
        let nonce = "0123456789abcdef0123456789abcdef"
        let folder = GuestRouterPaths.join(paths.inbox, cli)
        let messagePath = GuestRouterPaths.join(folder, "\(nonce).msg")
        let ackPath = GuestRouterPaths.join(folder, "\(nonce).ack")
        let signed = "⟦fjord v1 \(cli) \(nonce) 1800000000000 \(String(repeating: "a", count: 64))⟧\nRun the checks"
        try await guest.filesWrite(.init(computer: computer, path: messagePath, data: Data(signed.utf8), mode: 0o600))
        try await guest.filesWrite(.init(computer: computer, path: ackPath, data: Data("ok".utf8), mode: 0o600))

        let decisionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        var entry = RouterDecision(id: decisionID, at: createdAt, trigger: .you("Run the checks"))
        entry.add(.failed("delivery is unconfirmed"))
        entry.outcome = .done
        store.router.decisions = [entry]
        let receipt = GuestRelayRecord(location: .computer(deviceId: computer.deviceId, computerId: computer.computerId),
            sessionID: cli, nonce: nonce, createdAt: createdAt, state: .unconfirmed, signedPayload: signed,
            body: "Run the checks", decisionID: decisionID, hostSessionID: "local_desktop-1")
        store.saveGuestRelayState(receipt)
        let countBeforeRetry = store.router.decisions.count

        let finished = GuestRouterGate()
        store.routerDispatcher.onFinish = { id in if id == decisionID { Task { await finished.open() } } }
        store.routerDispatcher.retryGuestDelivery(receipt)
        await finished.wait()

        let recovered = try #require(store.router.decisions.first(where: { $0.id == decisionID }))
        let savedReceipt = try #require(store.router.guestRelayDeliveries.first)
        #expect(store.router.decisions.count == countBeforeRetry)
        #expect(recovered.doneLines == ["sent to local_desktop-1: Run the checks"])
        #expect(recovered.delivered?.nonce == nonce)
        #expect(savedReceipt.state == .delivered)
        #expect(await guest.writeRecords().filter { $0.path == messagePath }.count == 1)
    }

    @Test func RouterStatePersistsGuestFormsAndRelayReceipts() throws {
        let form = PendingForm(id: "cli-1-100-42", cliSessionID: "cli-1", transcriptPath: "/guest/transcript.jsonl",
            questions: [.init(question: "Deploy?", header: "Ship", multiSelect: false, options: [.init(label: "Yes", description: "")])],
            createdAt: Date(timeIntervalSince1970: 100), pid: 42, toolUseID: "tool-1")
        let pending = GuestPendingForm(computer: computer,
            location: .computer(deviceId: computer.deviceId, computerId: computer.computerId), form: form)
        let receipt = GuestRelayRecord(location: pending.location, sessionID: "cli-1", nonce: "nonce", state: .unconfirmed)
        var state = RouterState()
        state.guestPendingForms = [pending]
        state.pendingGuestDisables = [pending.location]
        state.pendingGuestRemovals = [pending.location]
        GuestRelayLedger.upsert(receipt, into: &state.guestRelayDeliveries)
        let decoded = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))

        #expect(decoded.guestPendingForms == [pending])
        #expect(decoded.guestRelayDeliveries == [receipt])
        #expect(decoded.pendingGuestDisables == [pending.location])
        #expect(decoded.pendingGuestRemovals == [pending.location])
    }

    @MainActor @Test func guestAliasCleanupRetriesAfterEngineReconnectAndCleansDesktopSettings() async throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-guest-removal-\(UUID().uuidString)")
        let claudeDir = tempHome.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer {
            GuestRouterRuntime.shared.stopAll()
            try? FileManager.default.removeItem(at: tempHome)
        }
        let computer = self.computer
        let location = SessionLocation.computer(deviceId: computer.deviceId, computerId: computer.computerId)
        let settingsComputer = ClaudeSSHSettings.Computer(deviceId: computer.deviceId, computerId: computer.computerId,
            computerName: "Linux dev", ownerName: "Owner", alias: "ssh-computer-1")
        let rawSettings = try JSONSerialization.data(withJSONObject: [
            "sshConfigs": [settingsComputer.json, ["id": "mine", "name": "Keep me", "sshHost": "other"]],
        ])
        try rawSettings.write(to: claudeDir.appendingPathComponent("settings.json"))
        let settings = ClaudeSSHSettings(claudeDir: claudeDir)
        let guest = client()
        _ = try await guest.sshAliasEnsure(computer: computer, installInclude: true)
        await guest.failNextAliasRemoval()
        let engine = engineWithComputer(state: .stopped)
        let store = Store(engineClient: engine)
        store.stateFile = tempHome.appendingPathComponent("state.json")
        store.persists = false
        store.router.pendingGuestRemovals = [location]

        await GuestRouterRuntime.shared.rehydrate(store: store, client: guest, sshSettings: settings)

        #expect(store.router.pendingGuestRemovals == [location])
        let firstPass = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings.settings)) as? [String: Any])
        #expect((firstPass["sshConfigs"] as? [[String: String]])?.map { $0["id"] } == ["mine"])
        let reconciled = GuestRouterGate()
        GuestRouterRuntime.shared.didReconcileGuestRemovals = { Task { await reconciled.open() } }
        engine.deliver(.reconnected)
        await reconciled.wait()
        let calls = await guest.callLog()
        #expect(calls.filter { $0 == "ssh-alias:remove:\(computer.key)" }.count == 2)
    }
}
