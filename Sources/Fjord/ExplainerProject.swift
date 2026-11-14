import CryptoKit
import Foundation

// The T3 project Fjord keeps for Show me's explainers (docs/design/router-visuals/SHOWME.md §1, §5): one folder,
// `Application Support/Fjord/Explainers`, holding the creator's instructions (`CLAUDE.md`), a tool lock (`.claude/settings.json`,
// `.fjord/guard.sh`), the kit the films run on (`kit/`) and the address of Fjord's preview server (`.mcp.json`). T3 knows it
// as an archived project titled "Fjord explainers", so its sidebar hides it, and `T3Store.hiddenRoot` keeps it off every
// Router surface.
//
// Why these files: a T3 launch can't set a thread's system prompt, tools or MCP servers, but T3's Claude threads load the
// project's CLAUDE.md, settings and `.mcp.json` (spike B1, SHOWME §12). Fjord writes nothing into any agent's own config.

struct ExplainerProject: Sendable {
    static let title = "Fjord explainers"
    static let folderName = "Explainers"
    /// The MCP server's name in `.mcp.json`, so the preview tool is `mcp__fjord__preview` (the name the prompt and guard use).
    static let serverName = "fjord"
    static let previewTool = "mcp__\(serverName)__preview"

    /// The project's folder.
    let root: URL
    /// What the app ships for it: `Resources/Explainer` (CLAUDE.md, settings.json, guard.sh, kit/).
    let resources: URL
    /// The fonts the kit draws with: `Resources/Fonts`, the app's own copy, so the kit has no second one.
    let fonts: URL

    init(root: URL, resources: URL = ExplainerProject.bundledResources, fonts: URL = ExplainerProject.bundledFonts) {
        self.root = root; self.resources = resources; self.fonts = fonts
    }

    /// The project inside Fjord's support folder (`Store.routerFiles?.support`); nil in a test or a demo, so nothing is made.
    static func at(support: URL?) -> ExplainerProject? {
        support.map { ExplainerProject(root: $0.appendingPathComponent(folderName, isDirectory: true)) }
    }

    /// The app bundle's `Resources/Explainer`, or the repository's when run from `swift build`.
    static var bundledResources: URL { resource("Explainer") }
    static var bundledFonts: URL { resource("Fonts") }
    private static func resource(_ name: String) -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/\(name)")
    }

    // MARK: Paths

    var kit: URL { root.appendingPathComponent("kit", isDirectory: true) }
    var runs: URL { root.appendingPathComponent("runs", isDirectory: true) }
    var queue: URL { root.appendingPathComponent("queue.json") }
    var mcpConfig: URL { root.appendingPathComponent(".mcp.json") }
    var stampFile: URL { root.appendingPathComponent(".fjord/stamp") }

    // MARK: Managed files

    /// One file the app ships and the folder keeps a copy of: where it comes from, where it goes, its mode.
    struct Managed: Equatable {
        var source: URL
        var path: String
        var mode: Int16 = 0o644
    }

    /// Every managed file, sorted by path: the top-level ones, then the kit with the app's fonts in `kit/fonts`.
    func managed() throws -> [Managed] {
        var out = [
            Managed(source: resources.appendingPathComponent("CLAUDE.md"), path: "CLAUDE.md"),
            Managed(source: resources.appendingPathComponent("settings.json"), path: ".claude/settings.json"),
            Managed(source: resources.appendingPathComponent("guard.sh"), path: ".fjord/guard.sh", mode: 0o755),
        ]
        out += try Self.files(under: resources.appendingPathComponent("kit")).map { Managed(source: $0.url, path: "kit/" + $0.path) }
        out += try Self.files(under: fonts).map { Managed(source: $0.url, path: "kit/fonts/" + $0.path) }
        return out.sorted { $0.path < $1.path }
    }

    /// The regular files under a folder, by path relative to it (hidden files skipped: `.DS_Store` isn't the kit's).
    private static func files(under folder: URL) throws -> [(url: URL, path: String)] {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        var out: [(URL, String)] = []
        for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            out.append((url, String(full.dropFirst(base.count + 1))))
        }
        return out
    }

    /// SHA256 over the managed files' paths and bytes, in path order: changes whenever an update changes what ships.
    func stamp() throws -> String {
        var hash = SHA256()
        for file in try managed() {
            hash.update(data: Data(file.path.utf8)); hash.update(data: Data([0]))
            hash.update(data: Data(String(file.mode).utf8)); hash.update(data: Data([0]))
            hash.update(data: try Data(contentsOf: file.source)); hash.update(data: Data([0]))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Makes the folder and brings its managed files up to what the app ships, when the stamp says they differ. `runs/`,
    /// `queue.json` and `.mcp.json` are never touched. The kit is built aside and swapped in whole, so a film never loads a
    /// half-copied kit; the stamp is written last, so a sync that stops partway is done again next launch.
    /// Returns whether it wrote anything. Blocking file work: call it off the main actor.
    @discardableResult
    func sync() throws -> Bool {
        let fm = FileManager.default
        let stamp = try stamp()
        if let old = try? String(contentsOf: stampFile, encoding: .utf8), old == stamp,
           fm.fileExists(atPath: kit.path) { return false }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try managed()
        let fresh = root.appendingPathComponent(".fjord/kit.new", isDirectory: true)
        try? fm.removeItem(at: fresh)
        for file in files {
            let kitPath = file.path.hasPrefix("kit/") ? String(file.path.dropFirst(4)) : nil
            let target = kitPath.map { fresh.appendingPathComponent($0) } ?? root.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: file.source).write(to: target, options: .atomic)
            try fm.setAttributes([.posixPermissions: file.mode], ofItemAtPath: target.path)
        }
        if fm.fileExists(atPath: kit.path) {
            _ = try fm.replaceItemAt(kit, withItemAt: fresh)
        } else {
            try fm.moveItem(at: fresh, to: kit)
        }
        try fm.createDirectory(at: stampFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(stamp.utf8).write(to: stampFile, options: .atomic)
        return true
    }

    // MARK: The preview server's address

    /// Where the project's Claude sessions reach Fjord's preview server (P2's `ExplainerMCP`).
    struct Server: Equatable, Sendable {
        var port: UInt16
        var token: String
    }

    /// `.mcp.json`'s server, the same shape as the Router's (`RouterMCPServer.config(port:)`).
    static func mcpConfig(_ server: Server) -> Data {
        let object: [String: Any] = ["mcpServers": [serverName: [
            "type": "http",
            "url": "http://127.0.0.1:\(server.port)/mcp",
            "headers": ["Authorization": "Bearer \(server.token)"],
        ]]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// The server `.mcp.json` names, so a new app run can bind the same port with the same token: Claude Code reads the file
    /// once per session, and a live explainer's session would lose a server that moved.
    func server() -> Server? {
        guard let data = try? Data(contentsOf: mcpConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (json["mcpServers"] as? [String: Any])?[Self.serverName] as? [String: Any],
              let url = (entry["url"] as? String).flatMap(URL.init(string:)), let port = url.port.flatMap(UInt16.init(exactly:)),
              let auth = (entry["headers"] as? [String: Any])?["Authorization"] as? String, auth.hasPrefix("Bearer ")
        else { return nil }
        let token = String(auth.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : Server(port: port, token: token)
    }

    /// Writes `.mcp.json` (owner-only: it holds the token) when it doesn't already name this server. Returns whether it wrote.
    @discardableResult
    func writeServer(_ server: Server) throws -> Bool {
        guard self.server() != server else { return false }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fm = FileManager.default
        let temp = root.appendingPathComponent(".fjord/mcp.json.new")
        try fm.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: temp)
        guard fm.createFile(atPath: temp.path, contents: Self.mcpConfig(server), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        if fm.fileExists(atPath: mcpConfig.path) { _ = try fm.replaceItemAt(mcpConfig, withItemAt: temp) } else {
            try fm.moveItem(at: temp, to: mcpConfig)
        }
        return true
    }

    // MARK: In T3

    /// The project whose folder is this one in T3's whole shell (`T3Store.hidden`), archived or not. Its identity is the folder,
    /// not a saved id: a project the owner deletes in T3 is made again, and nothing can drift.
    func project(in shell: T3ShellState) -> T3Project? {
        let wanted = T3ShellState.standardized(root.path)
        return shell.projects.values.filter { T3ShellState.standardized($0.workspaceRoot) == wanted }
            .min { ($0.archivedAt == nil ? 1 : 0, $0.id) < ($1.archivedAt == nil ? 1 : 0, $1.id) }
    }

    /// Makes sure T3 has the project, archived (S3: launches into an archived project still work, and T3's pickers and
    /// sidebar drop it). Call it only once T3 has said what it has (`hidden.answered`), or a project it holds would be made
    /// twice. `mutate` sends one `ProjectMutation` (`liveMutate` outside tests). Returns the project's id.
    func ensure(in shell: T3ShellState, mutate: (T3JSON) async throws -> T3JSON) async throws -> String {
        if let found = project(in: shell) {
            if found.archivedAt == nil { _ = try await mutate(Self.archive(found.id)) }
            return found.id
        }
        let id = UUID().uuidString.lowercased()
        _ = try await mutate(ThreadLauncher.projectCreate(commandId: UUID().uuidString.lowercased(), projectId: id,
                                                          title: Self.title, root: root.path))
        _ = try await mutate(Self.archive(id))
        return id
    }

    /// `project.update {archived: true}`: a Boolean, as T3 0.1.7 reads it (`archivedAt` is silently ignored).
    static func archive(_ projectID: String) -> T3JSON {
        ["type": "project.update", "commandId": .string(UUID().uuidString.lowercased()), "projectId": .string(projectID),
         "archived": .bool(true)]
    }

    /// One `ProjectMutation` to the running T3: `POST /api/projects/mutate`, as a launch's `createProject` sends it.
    @MainActor
    static func liveMutate(_ body: T3JSON) async throws -> T3JSON {
        if UnderTest.refuses("T3, changing a project") { throw ThreadLaunchFailure("not in a test") }
        guard let origin = T3Discovery.origin(), let token = T3Discovery.keychainToken() else {
            throw ThreadLaunchFailure("T3 isn't reachable: Fjord can't keep its explainers project")
        }
        var request = URLRequest(url: origin.appendingPathComponent("api/projects/mutate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try body.data()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = T3JSON.parse(data) else {
            throw ThreadLaunchFailure("T3 refused a change to the explainers project: \(T3JSON.parse(data)?.str("message") ?? "no reason given")")
        }
        return json
    }
}
