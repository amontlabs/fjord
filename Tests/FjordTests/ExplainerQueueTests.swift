import Foundation
import Testing
@testable import Fjord

/// Show me's queue and engine (SHOWME.md §3, §13): a request waits for its thread's turn, then one Opus explainer thread
/// starts per request, in parallel, into the hidden project; restarts read the queue back; old requests expire.
@MainActor
@Suite struct ExplainerQueueTests {
    static let sent = Date(timeIntervalSince1970: 1_800_000_000)

    static func row(_ id: String, status: String = "completed", active: String? = nil, completed: Date?,
                    project: String = "p1", archived: Bool = false) -> T3JSON {
        var extra: [String: T3JSON] = ["activeRunId": active.map(T3JSON.string) ?? nil,
                                       "latestRunCompletedAt": completed.map { .string(T3Timestamp.format($0)) } ?? nil]
        if archived { extra["archivedAt"] = .string(T3Timestamp.format(sent)) }
        return T3Fixture.thread(id, title: "Thread \(id)", status: status, project: project, extra: extra)
    }

    // MARK: The queue

    @Test func aTurnThatEndsAfterTheSendMakesTheRequestReady() {
        var q = ExplainerQueue()
        q.afterTurn(id: "x1", source: "t1", ask: "m1", sentAt: Self.sent)
        // Still running: waits.
        #expect(q.advance(shell: T3Fixture.state([Self.row("t1", status: "running", active: "r2", completed: Self.sent - 60)]),
                          now: Self.sent + 5).isEmpty)
        #expect(q.requests[0].state == .waitingForTurn)
        // Idle, but the turn that ended is an older one (the new run hasn't shown yet): waits.
        _ = q.advance(shell: T3Fixture.state([Self.row("t1", completed: Self.sent - 60)]), now: Self.sent + 5)
        #expect(q.ready.isEmpty)
        _ = q.advance(shell: T3Fixture.state([Self.row("t1", completed: Self.sent + 30)]), now: Self.sent + 31)
        #expect(q.ready.map(\.id) == ["x1"])
    }

    @Test func aStoppedTurnOrAGoneThreadDropsTheRequest() {
        var q = ExplainerQueue()
        q.afterTurn(id: "a", source: "t1", ask: nil, sentAt: Self.sent)
        q.afterTurn(id: "b", source: "t2", ask: nil, sentAt: Self.sent)
        q.afterTurn(id: "c", source: "gone", ask: nil, sentAt: Self.sent)
        q.afterTurn(id: "d", source: "t3", ask: nil, sentAt: Self.sent)
        // "gone" was there (running) before it left the shell.
        _ = q.advance(shell: T3Fixture.state([Self.row("gone", status: "running", active: "r1", completed: Self.sent - 60)]),
                      now: Self.sent + 1)
        let shell = T3Fixture.state([Self.row("t1", status: "interrupted", completed: Self.sent + 9),
                                     Self.row("t2", status: "failed", completed: Self.sent + 9),
                                     Self.row("t3", completed: Self.sent + 9, archived: true)])
        let dropped = q.advance(shell: shell, now: Self.sent + 10)
        #expect(dropped.map(\.0.id) == ["a", "b", "c", "d"])
        #expect(dropped.map(\.1) == [.turnStopped, .turnStopped, .threadGone, .threadGone])
        #expect(q.requests.isEmpty)
    }

    @Test func aNewThreadNotInTheShellYetIsWaitedFor() {
        var q = ExplainerQueue()
        q.afterTurn(id: "n", source: "new", ask: "m1", sentAt: Self.sent)
        #expect(q.advance(shell: T3ShellState(), now: Self.sent + 1).isEmpty)
        #expect(q.requests.map(\.id) == ["n"])
        _ = q.advance(shell: T3Fixture.state([Self.row("new", completed: Self.sent + 20)]), now: Self.sent + 21)
        #expect(q.ready.map(\.id) == ["n"])
    }

    @Test func aRequestOlderThanADayExpires() {
        var q = ExplainerQueue()
        q.now(id: "old", source: "t1", at: Self.sent)
        q.now(id: "new", source: "t1", at: Self.sent + 3600)
        let dropped = q.advance(shell: T3ShellState(), now: Self.sent + ExplainerQueue.expiry + 60)
        #expect(dropped.map(\.0.id) == ["old"] && dropped[0].1 == .expired)
        #expect(q.ready.map(\.id) == ["new"])
    }

    @Test func theQueueReadsBackFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("explainer-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var q = ExplainerQueue()
        q.afterTurn(id: "x1", source: "t1", ask: "m1", sentAt: Self.sent + 0.123)
        q.now(id: "x2", source: "t2", at: Self.sent)
        let url = dir.appendingPathComponent("queue.json")
        try q.save(url)
        #expect(ExplainerQueue.load(url) == q)
        #expect(ExplainerQueue.load(dir.appendingPathComponent("none.json")) == ExplainerQueue())
    }

    // MARK: The engine

    @Test func startHidesTheProjectAndTheRequestLaunchesAnOpusThreadWhenItsTurnEnds() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let engine = rig.engine
        engine.start()
        #expect(rig.hidden == [rig.project.root.path])
        await settle()
        #expect(rig.synced == 1 && rig.renderer.started == 1)

        // T3's first shell: the project is made (archived), then a send with Show me waits for its turn.
        rig.whole = T3Fixture.state([Self.row("t1", status: "running", active: "r1", completed: nil)], projects: rig.projects)
        engine.shell(.synchronized)
        await settle()
        #expect(rig.mutations.map { $0.str("type") } == ["project.create", "project.update"])
        engine.requested(source: "t1", ask: "u1", sentAt: Self.sent)
        await settle()
        #expect(rig.launches.isEmpty)
        #expect(engine.items.map(\.stage) == [.queued])

        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent + 40)], projects: rig.projects)
        engine.shell(nil)
        await settle()
        let launch = try #require(rig.launches.first)
        #expect(rig.launches.count == 1)
        #expect(launch.projectId == rig.projectID)
        #expect(launch.model == "claude-opus-5-5" && launch.instanceId == "claudeAgent" && launch.options.isEmpty)
        #expect(launch.runtimeMode == .fullAccess && launch.interactionMode == .default)
        #expect(launch.workspaceStrategy == ["type": "root"] && !launch.generateTitle)
        #expect(launch.title == "Explainer: Why is it slow?")
        let run = try #require(engine.runs[launch.threadId])
        #expect(launch.text.hasPrefix("<ticket>\(run.ticket)</ticket>\n<ask>Why is it slow?</ask>\n<thread name=\"Fix the login bug\" project=\"Garden\">"))
        #expect(rig.modelAsked == ["claude-opus-5-5"])
        #expect(engine.queue.requests.isEmpty)
        // The input is kept with the run, and the run reads back.
        let saved = try String(contentsOf: rig.project.runs.appendingPathComponent("\(run.id)/input.md"), encoding: .utf8)
        #expect(saved == launch.text)
        #expect(ExplainerEngine.loadRuns(rig.project.runs)[run.id] == run)
        // The ticket names the run to the renderer; another doesn't.
        #expect(engine.ticket(run.ticket) == ExplainerTicket(run: run.id, ask: "Why is it slow?"))
        #expect(engine.ticket("nope") == nil)
        #expect(engine.items.first?.stage == .making(draft: 0, fixing: ""))
    }

    @Test func creatorsRunInParallel() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let engine = rig.engine
        engine.start()
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent - 60)], projects: rig.projects)
        engine.shell(.synchronized)
        await settle()
        engine.requested(reply: "t1")
        engine.requested(reply: "t1")
        await settle()
        #expect(rig.launches.count == 2)
        #expect(Set(rig.launches.map(\.threadId)).count == 2)
        #expect(Set(engine.runs.values.map(\.ticket)).count == 2)
    }

    @Test func aRelaunchReadsTheQueueBackAndDropsWhatWasAlreadyLaunched() async throws {
        let rig = Rig()
        defer { rig.clean() }
        var q = ExplainerQueue()
        q.afterTurn(id: "waiting", source: "t1", ask: "u1", sentAt: Self.sent)
        q.now(id: "launched", source: "t1", at: Self.sent)
        try q.save(rig.project.queue)
        // T3 already has the launched one's thread, and the source's turn ended while Fjord was closed.
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent + 40),
                                     Self.row("launched", status: "running", active: "r1", completed: nil, project: "px")],
                                    projects: rig.projects + [T3Fixture.project("px", title: "Fjord explainers", root: rig.project.root.path)])
        let engine = rig.engine
        engine.start()
        await settle()
        #expect(rig.launches.map(\.threadId) == ["waiting"])
        #expect(rig.mutations.isEmpty == false)
        #expect(ExplainerQueue.load(rig.project.queue).requests.isEmpty)
    }

    @Test func aRequestWithNothingToExplainFailsInTheDock() async throws {
        let rig = Rig()
        defer { rig.clean() }
        rig.source = ExplainerInputTests.projection([ExplainerInputTests.message("u1", "user", "Hi", at: ExplainerInputTests.at("10:00"))])
        let engine = rig.engine
        engine.start()
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent - 60)], projects: rig.projects)
        engine.shell(.synchronized)
        engine.requested(reply: "t1")
        await settle()
        #expect(rig.launches.isEmpty)
        #expect(engine.items.map(\.stage) == [.failed("There's no answer to explain yet")])
    }

    @Test func followUpsGoAsTheOwnersWordsIntoTheExplainersThread() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let engine = rig.engine
        engine.start()
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent - 60)], projects: rig.projects)
        engine.shell(.synchronized)
        engine.requested(reply: "t1")
        await settle()
        let id = try #require(rig.launches.first?.threadId)
        try await engine.followUp(id, words: "Slower, please")
        guard case .messageDispatch(let thread, _, let text, let dispatch, _, _, _, _)? = rig.commands.last else {
            Issue.record("no message"); return
        }
        #expect(thread == id && text == "Slower, please" && dispatch == .startImmediately(intent: .steer))
        await #expect(throws: (any Error).self) { try await engine.followUp("unknown", words: "x") }
    }
}

/// Lets the engine's tasks run: they only await the stubs, which answer at once.
@MainActor
func settle() async {
    for _ in 0..<40 { await Task.yield() }
}

/// The engine on stubs: a temp project folder, a shell the test sets, a source thread, recorded launches and mutations.
@MainActor
final class Rig {
    let project: ExplainerProject
    let renderer = StubRenderer()
    var whole = T3ShellState()
    var hidden: [String] = []
    var hiddenRoot: String?
    var synced = 0
    var mutations: [T3JSON] = []
    var commands: [T3Command] = []
    var modelAsked: [String] = []
    var projectID: String?
    var source = ExplainerInputTests.projection([
        ExplainerInputTests.message("u1", "user", "Why is it slow?", at: ExplainerInputTests.at("10:00")),
        ExplainerInputTests.message("a1", "assistant", "The cache misses.", at: ExplainerInputTests.at("10:01")),
    ])
    var replies: [String: String] = [:]
    var projects: [T3JSON] { [T3Fixture.project("p1", root: "/code/app")] }
    var launches: [T3LaunchRequest] {
        commands.compactMap { if case .launchThread(let r) = $0 { r } else { nil } }
    }

    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explainers-\(UUID().uuidString)", isDirectory: true)
        project = ExplainerProject(root: root)
    }

    func clean() { try? FileManager.default.removeItem(at: project.root) }

    lazy var engine: ExplainerEngine = {
        let env = ExplainerEngine.Env(
            hidden: { [unowned self] in whole },
            shell: { [unowned self] in whole.without(projectRoot: hiddenRoot) },
            hide: { [unowned self] root in hidden.append(root); hiddenRoot = root },
            snapshot: { [unowned self] id in
                if let reply = replies[id] {
                    return ExplainerInputTests.projection([ExplainerInputTests.message("r", "assistant", reply, at: ExplainerInputTests.at("11:00"))])
                }
                return id.hasPrefix("t") ? source : nil
            },
            model: { [unowned self] slug, _ in modelAsked.append(slug); return ThreadLaunchModel(instanceId: "claudeAgent", model: slug) },
            dispatch: { [unowned self] command in commands.append(command) },
            mutate: { [unowned self] body in
                mutations.append(body)
                if body.str("type") == "project.create" { projectID = body.str("projectId") }
                return [:]
            },
            sync: { _ in await MainActor.run { [unowned self] in synced += 1 } },
            zone: ExplainerInputTests.utc, user: "nobody")
        return ExplainerEngine(project: project, renderer: renderer, env: env)
    }()
}

/// The renderer, standing in for P2's: versions the test sets, renders it records.
@MainActor
final class StubRenderer: ExplainerRendering {
    var started = 0
    var saved: [String: [ExplainerVersion]] = [:]
    var rendered: [String] = []
    var fails = false

    func start(project: ExplainerProject, host: ExplainerRenderHost) async throws { started += 1 }
    func versions(of run: String) -> [ExplainerVersion] { saved[run] ?? [] }
    func render(_ code: String, ticket: ExplainerTicket) async throws -> ExplainerVersion {
        if fails { throw ThreadLaunchFailure("render failed") }
        rendered.append(code)
        let v = ExplainerVersion(run: ticket.run, number: (saved[ticket.run]?.last?.number ?? 0) + 1, code: code, broken: false,
                                 title: "Final", answer: "It's the cache.", length: 12)
        saved[ticket.run, default: []].append(v)
        return v
    }
}
