import Foundation

// Show me's `preview` tool (docs/design/router-visuals/SHOWME.md §2.1, §13): one persistent MCP server per app run, on the
// port and token the Explainers project's `.mcp.json` names, so a creator's Claude session (which reads `.mcp.json` once, at
// its start) keeps reaching it across Fjord relaunches. It serves one tool, `preview(code, ticket, at?)`: the ticket names
// the run (the engine hands it to each creator in its input), the code is rendered offscreen (ExplainerRenderer.swift) and
// saved as the run's next version (ExplainerStore.swift), and the engine hears of it at once (`versionSaved`).
//
// The answer is the Python preview server's (EX/preview_server.py), word for word, then a label and a JPEG per frame: the
// format the creator's prompt and the evals were tuned on.

@MainActor
final class ExplainerMCP: ExplainerRendering {
    static let tool = "preview"
    /// Seconds in `at`, at most: a reply holds `ExplainerRenderer.maxFrames` frames, `at`'s first.
    nonisolated static let maxAt = ExplainerRenderer.maxFrames
    /// Eight 1× JPEG frames are about 600 KB, 800 KB in base64; a reply may take this much.
    nonisolated static let maxResponse = 8 * 1024 * 1024
    /// What the answer's images may take: the rest is for its text and JSON, so the reply always fits `maxResponse` (a reply
    /// over it would become "Response too large" after the version is saved, and a retry would save it twice).
    nonisolated static let maxImages = maxResponse - 512 * 1024
    /// The page's errors and notes in the answer, at most.
    nonisolated static let maxErrors = 64 * 1024
    static let maxCode = 512 * 1024

    private(set) var project: ExplainerProject?
    private weak var host: ExplainerRenderHost?
    private var server: RouterMCPServer?
    private var renderer: ExplainerRenderer?
    private var store: ExplainerVersions?
    /// The render running now: renders share one web view, so each waits for the one before.
    private var tail: Task<Void, Never>?

    init() {}

    /// The tool as `tools/list` offers it.
    static let tools: [[String: Any]] = [[
        "name": tool,
        "description": "Render your explainer and look at it. `code` is the full explainer({...}) call. `ticket` is the ticket "
            + "from your input's <ticket> line, on every call. Returns timing, any errors and layout notes, and the held frame "
            + "at the end of every scene; `at` adds frames at those seconds.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "code": ["type": "string", "description": "The full explainer({...}) call."],
                "ticket": ["type": "string", "description": "The ticket from the <ticket> line at the top of your input."],
                "at": ["type": "array", "items": ["type": "number"], "maxItems": maxAt,
                   "description": "Extra frames, at these seconds (at most \(maxAt)). A reply holds at most \(maxAt) frames: "
                       + "these first, then scene ends while there's room."],
            ],
            "required": ["code", "ticket"],
        ] as [String: Any],
    ]]

    // MARK: ExplainerRendering

    func start(project: ExplainerProject, host: ExplainerRenderHost) async throws {
        self.project = project
        self.host = host
        store = ExplainerVersions(runs: project.runs)
        renderer = ExplainerRenderer(root: project.root, kit: project.kit)
        server?.stop()
        let saved = project.server()
        let server = RouterMCPServer(token: saved?.token, preferredPort: saved?.port) { [weak self] body in
            guard let self else { return RouterRPC.Reply(status: 503, body: nil) }
            return await RouterRPC.handle(body, tools: Self.tools, version: "1", maxResponse: Self.maxResponse) { name, args in
                await self.call(name, args)
            }
        }
        self.server = server
        let port: UInt16 = try await withCheckedThrowingContinuation { done in
            server.start { done.resume(with: $0) }
        }
        try project.writeServer(ExplainerProject.Server(port: port, token: server.token))
    }

    func stop() {
        server?.stop()
        server = nil
        renderer?.close()
    }

    func versions(of run: String) -> [ExplainerVersion] {
        store?.versions(of: run) ?? []
    }

    func render(_ code: String, ticket: ExplainerTicket) async throws -> ExplainerVersion {
        try await save(code, ticket: ticket, at: []).version
    }

    // MARK: The tool

    /// One tool call; nil for a name this server doesn't serve.
    func call(_ name: String, _ args: [String: Any]) async -> RouterRPC.ToolResult? {
        guard name == Self.tool else { return nil }
        let given = (args["ticket"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !given.isEmpty else {
            return .error("Missing `ticket`. Call \(ExplainerProject.previewTool) again with `code` and `ticket`: the ticket is "
                + "the text inside the <ticket>…</ticket> line at the top of your input. Nothing was saved.")
        }
        guard let ticket = host?.ticket(given) else {
            return .error("Unknown ticket “\(given.prefix(80))”. Copy the ticket exactly from the <ticket>…</ticket> line at "
                + "the top of your input and call \(ExplainerProject.previewTool) again. Nothing was saved.")
        }
        guard let code = args["code"] as? String, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("Missing `code`: pass the full explainer({...}) call. Nothing was saved.")
        }
        guard code.utf8.count <= Self.maxCode else {
            return .error("`code` is over \(Self.maxCode / 1024) KB. Make the explainer shorter. Nothing was saved.")
        }
        var at: [Double] = []
        if let raw = args["at"], !(raw is NSNull) {
            let list = raw as? [Any]
            let numbers = list?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            guard let list, numbers.count == list.count, numbers.allSatisfy(\.isFinite) else {
                return .error("`at` is a list of seconds, like [3.2, 7]. Nothing was saved.")
            }
            guard numbers.count <= Self.maxAt else {
                return .error("`at` takes at most \(Self.maxAt) seconds; you passed \(numbers.count). Nothing was saved.")
            }
            at = numbers
        }
        do {
            let (version, result) = try await save(code, ticket: ticket, at: at)
            host?.versionSaved(version)
            // Base64 of up to 8 frames: off the main thread.
            return await Task.detached { Self.answer(version: version.number, result) }.value
        } catch {
            return .error("The preview couldn't render: \(error.localizedDescription). Nothing was saved; try again.")
        }
    }

    /// Renders and saves the run's next version, after any render already running.
    private func save(_ code: String, ticket: ExplainerTicket, at: [Double]) async throws
        -> (version: ExplainerVersion, result: ExplainerRenderer.Result) {
        guard let store, let renderer else { throw CocoaError(.featureUnsupported) }
        let before = tail
        let mine = Task<(ExplainerVersion, ExplainerRenderer.Result), Error> { @MainActor in
            await before?.value
            let number = try store.next(ticket.run)
            let dir = try store.page(ticket.run, number)
            try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(code.utf8).write(to: store.code(ticket.run, number), options: .atomic)
            let result = try await renderer.render(code: code, ask: ticket.ask, into: dir, at: at)
            let note = result.errors.split(separator: "\n").first.map(String.init)
            let version = ExplainerVersion(run: ticket.run, number: number, code: code, broken: result.broken || result.timing == nil,
                                           note: note, title: result.spec?.title, answer: result.spec?.answer,
                                           captions: result.spec?.captions ?? [], length: result.timing?.total,
                                           page: dir.appendingPathComponent("index.html"), posterLight: result.posterLight,
                                           posterDark: result.posterDark)
            try store.save(version)
            return (version, result)
        }
        tail = Task { _ = try? await mine.value }
        return try await mine.value
    }

    /// The Python server's answer: "Version N. Total … Scenes start at …", the errors and notes, then a label and an image
    /// per frame. It always fits the reply: images stop at `images` bytes of base64 and errors at `maxErrors`, and each frame
    /// left out (by the frame cap or the size cap) is named with how to see it.
    nonisolated static func answer(version: Int, _ result: ExplainerRenderer.Result, images budget: Int = maxImages)
        -> RouterRPC.ToolResult {
        var text = "Version \(version). "
        if let timing = result.timing {
            text += "Total \(ExplainerRenderer.number(timing.total)) s. Scenes start at "
                + timing.scenes.enumerated().map { "\($0.offset): \(ExplainerRenderer.number($0.element.first ?? 0)) s" }
                .joined(separator: ", ")
        } else {
            text += "No timing: build() failed."
        }
        var errors = result.errors
        if errors.utf8.count > maxErrors {
            errors = String(decoding: errors.utf8.prefix(maxErrors), as: UTF8.self) + "\n… (cut: fix these first)"
        }
        text += errors.isEmpty ? "\nNo errors, no layout notes." : "\nErrors and layout notes to fix:\n" + errors
        var images: [RouterRPC.ToolResult.Image] = [], tooBig: [String] = [], room = budget
        for frame in result.frames {
            let size = (frame.jpeg.count + 2) / 3 * 4
            guard tooBig.isEmpty, size <= room else { tooBig.append(frame.label); continue }
            room -= size
            images.append(.init(label: frame.label, mime: "image/jpeg", base64: frame.jpeg.base64EncodedString()))
        }
        if !result.left.isEmpty {
            text += "\nA reply holds at most \(ExplainerRenderer.maxFrames) frames, so these were left out: "
                + result.left.joined(separator: ", ") + ". To see them, call again with their seconds in `at`."
        }
        if !tooBig.isEmpty {
            text += "\nThe reply's size cap left out these frames: " + tooBig.joined(separator: ", ")
                + ". To see them, call again with fewer seconds in `at`."
        }
        return RouterRPC.ToolResult(text: text, images: images)
    }
}
