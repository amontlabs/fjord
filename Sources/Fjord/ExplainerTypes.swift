import Foundation

// The seam between Show me's engine (P3: the queue, the launch, the final; ExplainerEngine.swift) and its renderer (P2: the
// offscreen WebKit render and the `preview` MCP server; ExplainerRenderer.swift, ExplainerMCP.swift). The engine owns
// requests and runs; the renderer owns versions. docs/design/router-visuals/SHOWME.md §2, §3, §13.
//
// Files under `runs/<run>/`: the renderer writes `v<n>.js`, `v<n>/…` and `meta.json` (versions); the engine writes
// `input.md` and `run.json` (source, ask, final, watched). Neither writes the other's.

/// One saved version of an explainer: what a `preview` call (or the engine's final render) produced.
struct ExplainerVersion: Equatable, Sendable {
    /// The explainer's run: its T3 thread id.
    var run: String
    /// 1, 2, …: `runs/<run>/v<number>.js`.
    var number: Int
    /// The code as rendered.
    var code: String
    /// The kit marked the page broken (`body.broken`, or it never got ready).
    var broken: Bool
    /// The first error or layout note the render reported, if any: what the next draft is fixing.
    var note: String?
    /// From the kit's `window.__spec` (nil when the page never ran).
    var title: String?
    var answer: String?
    var captions: [String] = []
    /// The film's length in seconds, from `window.__timing`.
    var length: Double?
    /// `runs/<run>/v<number>/index.html`, and its held last frame in each appearance.
    var page: URL?
    var posterLight: URL?
    var posterDark: URL?
}

/// What a `preview` call's `ticket` stands for: the run it saves into, and the question the page shows.
struct ExplainerTicket: Equatable, Sendable {
    var run: String
    var ask: String
}

/// The engine, as the renderer sees it.
@MainActor
protocol ExplainerRenderHost: AnyObject {
    /// The live run a `preview` ticket belongs to; nil for a missing or unknown ticket (the tool answers an error that names
    /// the fix and saves nothing).
    func ticket(_ ticket: String) -> ExplainerTicket?
    /// A version was saved (by `preview`): the dock shows it at once.
    func versionSaved(_ version: ExplainerVersion)
}

/// The renderer, as the engine sees it. P2 conforms; the engine's tests use a stub.
@MainActor
protocol ExplainerRendering: AnyObject {
    /// Starts the persistent preview server for the project (binding the port `.mcp.json` names when it can, rewriting
    /// `.mcp.json` otherwise). Called once per app run, after `ExplainerProject.sync()`.
    func start(project: ExplainerProject, host: ExplainerRenderHost) async throws
    /// The versions saved for a run, oldest first (read back from disk: survives a relaunch).
    func versions(of run: String) -> [ExplainerVersion]
    /// Renders code with no MCP call and saves it as the run's next version: the final, when the last message's code block
    /// differs from the last preview (§2.4).
    func render(_ code: String, ticket: ExplainerTicket) async throws -> ExplainerVersion
}
