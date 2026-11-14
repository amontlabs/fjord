import Foundation
import Testing
@testable import Fjord

/// Show me's project folder: what ships into it and when, the preview server's address, the tool lock, and the T3 project.
@Suite struct ExplainerProjectTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let source = repo.appendingPathComponent("docs/design/router-visuals/explainer")

    /// A copy of the shipped resources the test may change, and a project folder over it.
    private func project(_ dir: TempDir) throws -> ExplainerProject {
        let resources = dir.path("Explainer")
        try FileManager.default.copyItem(at: ExplainerProject.bundledResources, to: resources)
        return ExplainerProject(root: dir.path("Support/Explainers"), resources: resources, fonts: ExplainerProject.bundledFonts)
    }

    @Test func promptIsBuilt() throws {
        // scripts/build-explainer-prompt.sh: the source with its {{EXAMPLE}} line replaced by the example, whole.
        let src = try String(contentsOf: Self.source.appendingPathComponent("system.src.md"), encoding: .utf8)
        var example = try String(contentsOf: Self.source.appendingPathComponent("examples/lastdrop.js"), encoding: .utf8)
        if example.hasSuffix("\n") { example.removeLast() }
        #expect(src.components(separatedBy: "\n{{EXAMPLE}}\n").count == 2)
        let built = src.replacingOccurrences(of: "\n{{EXAMPLE}}\n", with: "\n\(example)\n")
        let shipped = try String(contentsOf: ExplainerProject.bundledResources.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(shipped == built, "Resources/Explainer/CLAUDE.md is stale: run scripts/build-explainer-prompt.sh")
        // What the plan settled: the full tool name, the ticket, follow-ups.
        #expect(shipped.contains(ExplainerProject.previewTool) && shipped.contains("ticket") && shipped.contains("Later messages"))
    }

    @Test func syncCopiesWhatShipsOnceAndAgainOnlyWhenItChanges() throws {
        let dir = TempDir()
        let p = try project(dir)
        #expect(try p.sync())
        let fm = FileManager.default
        let stamp = ExplainerProject.folder(try p.stamp())
        #expect(p.kit == p.kits.appendingPathComponent(stamp, isDirectory: true))
        for path in ["CLAUDE.md", ".claude/settings.json", ".fjord/guard.sh", ".fjord/stamp", "kit/\(stamp)/kit.js",
                     "kit/\(stamp)/player.html", "kit/\(stamp)/player.css", "kit/\(stamp)/vendor/gsap.min.js",
                     "kit/\(stamp)/fonts/geist-regular.otf", "kit/\(stamp)/fonts/geist-mono.ttf"] {
            #expect(fm.fileExists(atPath: p.root.appendingPathComponent(path).path), "\(path)")
        }
        #expect(mode(p.root.appendingPathComponent(".fjord/guard.sh")) == 0o755)
        #expect(try p.sync() == false)

        // The owner's runs and queue stay; an update rewrites the managed files into a new kit, and the old kit stays.
        try fm.createDirectory(at: p.runs.appendingPathComponent("t1"), withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: p.runs.appendingPathComponent("t1/v1.js"))
        try Data("[]".utf8).write(to: p.queue)
        let old = p.kit
        try ExplainerProject.Server(port: 4321, token: "tok").write(p)
        try Data("# New instructions\n".utf8).write(to: p.resources.appendingPathComponent("CLAUDE.md"))
        #expect(try p.sync())
        #expect(try String(contentsOf: p.root.appendingPathComponent("CLAUDE.md"), encoding: .utf8) == "# New instructions\n")
        #expect(try String(contentsOf: p.runs.appendingPathComponent("t1/v1.js"), encoding: .utf8) == "v1")
        #expect(fm.fileExists(atPath: p.queue.path) && p.server() == ExplainerProject.Server(port: 4321, token: "tok"))
        #expect(p.kit != old && fm.fileExists(atPath: old.appendingPathComponent("kit.js").path))
        #expect(!fm.fileExists(atPath: p.root.appendingPathComponent(".fjord/kit.new").path))
        #expect(try p.sync() == false)
    }

    @Test func aPageLinksTheKitItWasMadeWith() throws {
        let dir = TempDir()
        let p = try project(dir)
        try p.sync()
        let stamp = p.kit.lastPathComponent
        let player = try String(contentsOf: p.kit.appendingPathComponent("player.html"), encoding: .utf8)
        let page = ExplainerRenderer.page(player: player, ask: "Why?")
        #expect(page.contains("\"../../../kit/\(stamp)/player.css\"") && page.contains("\"../../../kit/\(stamp)/kit.js\""))
        #expect(!page.contains("\"../../../kit/player.css\""))
        // From runs/<run>/v<n>/, that link is this kit's file.
        let version = p.runs.appendingPathComponent("r/v1/index.html")
        let css = URL(fileURLWithPath: "../../../kit/\(stamp)/player.css", relativeTo: version).standardizedFileURL
        #expect(css.path == p.kit.appendingPathComponent("player.css").standardizedFileURL.path)
    }

    @Test func aGuardThatWasDeletedOrLostItsModeIsRestored() throws {
        let dir = TempDir()
        let p = try project(dir)
        try p.sync()
        let fm = FileManager.default
        let guardFile = p.root.appendingPathComponent(".fjord/guard.sh")
        try fm.removeItem(at: guardFile)
        #expect(try p.sync())
        #expect(fm.fileExists(atPath: guardFile.path) && mode(guardFile) == 0o755)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: guardFile.path)
        #expect(try p.sync())
        #expect(mode(guardFile) == 0o755)
        try Data("exit 0\n".utf8).write(to: guardFile)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guardFile.path)
        #expect(try p.sync())
        #expect(try Data(contentsOf: guardFile) == Data(contentsOf: p.resources.appendingPathComponent("guard.sh")))
        // A kit file changed by hand is put back too.
        try Data("broken".utf8).write(to: p.kit.appendingPathComponent("kit.js"))
        #expect(try p.sync())
        #expect(try Data(contentsOf: p.kit.appendingPathComponent("kit.js")) == Data(contentsOf: p.resources.appendingPathComponent("kit/kit.js")))
        #expect(try p.sync() == false)
    }

    @Test func theServerFileIsOwnerOnlyAndNamesThePortAndToken() throws {
        let dir = TempDir()
        let p = try project(dir)
        #expect(p.server() == nil)
        let server = ExplainerProject.Server(port: 51234, token: "secret-token")
        #expect(try p.writeServer(server))
        #expect(mode(p.mcpConfig) == 0o600)
        #expect(p.server() == server)
        #expect(try p.writeServer(server) == false)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: p.mcpConfig)) as? [String: Any])
        let entry = try #require((json["mcpServers"] as? [String: Any])?["fjord"] as? [String: Any])
        #expect(entry["type"] as? String == "http" && entry["url"] as? String == "http://127.0.0.1:51234/mcp")
        #expect((entry["headers"] as? [String: String])?["Authorization"] == "Bearer secret-token")
        #expect(try p.writeServer(ExplainerProject.Server(port: 51235, token: "secret-token")))
        #expect(p.server()?.port == 51235 && mode(p.mcpConfig) == 0o600)
    }

    @Test func theSettingsLockEveryToolButPreview() throws {
        let data = try Data(contentsOf: ExplainerProject.bundledResources.appendingPathComponent("settings.json"))
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(settings["enabledMcpjsonServers"] as? [String] == [ExplainerProject.serverName])
        let deny = Set((settings["permissions"] as? [String: Any])?["deny"] as? [String] ?? [])
        #expect(deny.isSuperset(of: ["Bash", "Read", "Edit", "Write", "NotebookEdit", "Glob", "Grep", "WebFetch", "WebSearch",
                                     "Task", "Agent", "TodoWrite", "mcp__t3-code"]))
        let pre = try #require((settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(pre.first?["matcher"] as? String == "*")
        let command = (pre.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        #expect(command?.contains("$CLAUDE_PROJECT_DIR") == true && command?.hasSuffix("/.fjord/guard.sh") == true)
    }

    /// The guard's answer for a hook input: nil allows, else the deny's reason.
    private func guardAnswer(_ input: String) throws -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [ExplainerProject.bundledResources.appendingPathComponent("guard.sh").path]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8)); try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        guard !out.isEmpty else { return nil }
        let json = try JSONSerialization.jsonObject(with: out) as? [String: Any]
        let hook = json?["hookSpecificOutput"] as? [String: Any]
        #expect(hook?["hookEventName"] as? String == "PreToolUse" && hook?["permissionDecision"] as? String == "deny")
        return hook?["permissionDecisionReason"] as? String
    }

    @Test func theGuardAllowsExactlyPreviewAndToolSearch() throws {
        func call(_ tool: String, _ input: String = "{}") -> String {
            #"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"\#(tool)","tool_input":\#(input)}"#
        }
        #expect(try guardAnswer(call("mcp__fjord__preview", #"{"code":"K.film({})","ticket":"t1"}"#)) == nil)
        #expect(try guardAnswer(call("ToolSearch", #"{"query":"preview"}"#)) == nil)
        for tool in ["Bash", "Write", "mcp__lcu__js", "mcp__t3-code__t3_thread_send", "mcp__fjord__preview2", "toolsearch", ""] {
            #expect(try guardAnswer(call(tool))?.contains(ExplainerProject.previewTool) == true, "\(tool)")
        }
        // A name inside the call's input can't pass for the tool's; what can't be read is denied.
        #expect(try guardAnswer(call("Bash", #"{"tool_name":"ToolSearch"}"#)) != nil)
        #expect(try guardAnswer("not json") != nil)
    }

    @Test func ensureMakesTheProjectOnceAndKeepsItArchived() async throws {
        let p = ExplainerProject(root: URL(fileURLWithPath: "/tmp/fjord-x/Explainers"))
        var sent: [T3JSON] = []
        let mutate: (T3JSON) async throws -> T3JSON = { sent.append($0); return [:] }

        // None yet: made under its title, then archived.
        let made = try await p.ensure(in: T3Fixture.state([], projects: [T3Fixture.project("p1", root: "/code/app")]), mutate: mutate)
        #expect(sent.map { $0.str("type") } == ["project.create", "project.update"])
        #expect(sent[0].str("title") == ExplainerProject.title && sent[0].str("workspaceRoot") == p.root.path)
        #expect(sent[0].str("projectId") == made && sent[1].str("projectId") == made && sent[1]["archived"] == .bool(true))

        // Found by its folder (not an id), unarchived: archived again. Archived: left alone.
        sent = []
        let open = T3Fixture.project("px", root: "/tmp/fjord-x/./Explainers/")
        #expect(try await p.ensure(in: T3Fixture.state([], projects: [open]), mutate: mutate) == "px")
        #expect(sent.map { $0.str("type") } == ["project.update"])
        sent = []
        guard case .object(var archived) = open else { Issue.record("not an object"); return }
        archived["archivedAt"] = "2026-11-14T00:00:00.000Z"
        #expect(try await p.ensure(in: T3Fixture.state([], projects: [.object(archived)]), mutate: mutate) == "px")
        #expect(sent.isEmpty)
    }
}

private extension ExplainerProject.Server {
    func write(_ p: ExplainerProject) throws { try p.writeServer(self) }
}
