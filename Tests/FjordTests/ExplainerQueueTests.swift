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

    @Test func aRequestWaitsUntilItsMessageIsAnswered() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let engine = rig.engine
        engine.start()
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent - 60)], projects: rig.projects)
        engine.shell(.synchronized)
        await settle()
        // A turn ends right after the send, before the message landed: the clock says ready, the thread says not yet.
        engine.requested(source: "t1", ask: "u2", sentAt: Self.sent)
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent + 1)], projects: rig.projects)
        engine.shell(nil)
        await settle()
        #expect(rig.launches.isEmpty)
        #expect(engine.queue.requests.first?.state == .waitingForTurn && engine.items.map(\.stage) == [.queued])
        // The same completion read again still waits; the turn that answers it launches.
        engine.shell(nil)
        await settle()
        #expect(rig.launches.isEmpty)
        rig.source = ExplainerInputTests.projection([
            ExplainerInputTests.message("u1", "user", "Why is it slow?", at: ExplainerInputTests.at("10:00")),
            ExplainerInputTests.message("a1", "assistant", "The cache misses.", at: ExplainerInputTests.at("10:01")),
            ExplainerInputTests.message("u2", "user", "And the fix?", at: ExplainerInputTests.at("10:02")),
            ExplainerInputTests.message("a2", "assistant", "Warm it.", at: ExplainerInputTests.at("10:03")),
        ])
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent + 30)], projects: rig.projects)
        engine.shell(nil)
        await settle()
        #expect(rig.launches.count == 1 && rig.launches.first?.text.contains("<ask>And the fix?</ask>") == true)
    }

    @Test func aMessageInAQueuedRunIsNotAnswered() {
        let p = T3Projection(json: [
            "thread": T3Fixture.thread("t1"),
            "messages": [ExplainerInputTests.message("u1", "user", "Go", at: ExplainerInputTests.at("10:00"), extra: ["runId": "r2"]),
                         ExplainerInputTests.message("a0", "assistant", "Earlier", at: ExplainerInputTests.at("10:01"), extra: ["runId": "r1"])],
            "runs": [["id": "r1", "status": "completed", "completedAt": "2026-11-14T10:01:00.000Z"],
                     ["id": "r2", "status": "queued", "userMessageId": "u1"]],
        ])
        #expect(!ExplainerQueue.answered(p, ask: "u1"))
        #expect(!ExplainerQueue.answered(p, ask: "missing"))
    }

    /// ⌥Return: the message is queued (stamped 10:02) behind a turn that keeps talking until 10:04. It waits through that
    /// turn's end and its own run's start, and the explainer explains its own run's reply, not the turn it waited behind.
    @Test func aQueuedSendWaitsForItsDeliveryAndItsReply() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let engine = rig.engine
        engine.start()
        rig.whole = T3Fixture.state([Self.row("t1", status: "running", active: "r1", completed: Self.sent - 60)], projects: rig.projects)
        engine.shell(.synchronized)
        await settle()
        let at = ExplainerInputTests.at
        func source(_ r2: [String: T3JSON], answered: Bool) -> T3Projection {
            var messages = [
                ExplainerInputTests.message("u1", "user", "Why is it slow?", at: at("10:00", 0), extra: ["runId": "r1"]),
                ExplainerInputTests.message("a1", "assistant", "Looking.", at: at("10:01", 0), extra: ["runId": "r1"]),
                ExplainerInputTests.message("u2", "user", "And the fix?", at: at("10:02", 0), extra: ["runId": "r2"]),
                ExplainerInputTests.message("a1b", "assistant", "The cache misses.", at: at("10:03", 0), extra: ["runId": "r1"]),
            ]
            if answered { messages.append(ExplainerInputTests.message("a2", "assistant", "Warm it.", at: at("10:05", 0), extra: ["runId": "r2"])) }
            var run2: [String: T3JSON] = ["id": "r2", "ordinal": 2, "userMessageId": "u2"]
            for (k, v) in r2 { run2[k] = v }
            return T3Projection(json: ["thread": T3Fixture.thread("t1"), "messages": .array(messages),
                                       "runs": [["id": "r1", "ordinal": 1, "status": "completed", "userMessageId": "u1",
                                                 "startedAt": .string(at("10:00", 0)), "completedAt": .string(at("10:04", 0))],
                                                .object(run2)]])
        }
        engine.requested(source: "t1", ask: "u2", sentAt: Self.sent)
        // The turn it waits behind ends; T3 hasn't delivered it yet (its run is still queued): no launch.
        rig.source = source(["status": "queued", "queuePosition": 1], answered: false)
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent + 10)], projects: rig.projects)
        engine.shell(nil)
        await settle()
        #expect(rig.launches.isEmpty && engine.items.map(\.stage) == [.queued])
        // Delivered, its run working: still no launch.
        rig.source = source(["status": "running", "startedAt": .string(at("10:04", 1))], answered: false)
        rig.whole = T3Fixture.state([Self.row("t1", status: "running", active: "r2", completed: Self.sent + 10)], projects: rig.projects)
        engine.shell(nil)
        await settle()
        #expect(rig.launches.isEmpty)
        // Its run ends with its reply: one launch, on its own answer.
        rig.source = source(["status": "completed", "startedAt": .string(at("10:04", 1)), "completedAt": .string(at("10:05", 1))],
                            answered: true)
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent + 60)], projects: rig.projects)
        engine.shell(nil)
        await settle()
        let text = try #require(rig.launches.first?.text)
        #expect(rig.launches.count == 1)
        #expect(text.contains("<ask>And the fix?</ask>"))
        #expect(text.contains("focus=\"true\">Warm it.</turn>"))
        #expect(!text.contains("The cache misses.\n\nWarm it."))
    }

    @Test func nothingLaunchesBeforeThePreviewServerIsUp() async throws {
        let rig = Rig()
        defer { rig.clean() }
        rig.renderer.startFails = true
        let engine = rig.engine
        engine.start()
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent - 60)], projects: rig.projects)
        engine.shell(.synchronized)
        engine.requested(reply: "t1")
        await settle()
        #expect(rig.renderer.started == 1 && rig.projectID != nil)
        #expect(rig.launches.isEmpty && !engine.ready && engine.items.map(\.stage) == [.queued])
    }

    @Test func aLaunchingRequestIsListedOnceAndItsThreadIsHidden() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let engine = rig.engine
        var during: [String] = []
        rig.onDispatch = { _ in during = engine.list().map(\.id) }
        engine.start()
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent - 60)], projects: rig.projects)
        engine.shell(.synchronized)
        engine.requested(reply: "t1")
        await settle()
        let id = try #require(rig.launches.first?.threadId)
        #expect(during == [id])
        #expect(rig.hiddenThreads.contains(id))
    }

    @Test func aFollowUpKeepsAFinalThatLandedWhileItWasSent() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let engine = rig.engine
        engine.start()
        rig.whole = T3Fixture.state([Self.row("t1", completed: Self.sent - 60)], projects: rig.projects)
        engine.shell(.synchronized)
        engine.requested(reply: "t1")
        await settle()
        let id = try #require(rig.launches.first?.threadId)
        rig.renderer.saved[id] = [ExplainerVersion(run: id, number: 1, code: "a()", broken: false)]
        engine.versionSaved(rig.renderer.saved[id]![0])
        rig.replies[id] = "```js\na()\n```"
        rig.onDispatch = { _ in await engine.finish(id) }
        try await engine.followUp(id, words: "Slower")
        #expect(engine.runs[id]?.final == 1)
    }

    @Test func theProjectIsMadeAgainWhenT3LosesIt() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let engine = rig.engine
        engine.start()
        rig.whole = T3Fixture.state([], projects: rig.projects)
        engine.shell(.synchronized)
        await settle()
        let first = try #require(rig.projectID)
        rig.whole = T3Fixture.state([], projects: rig.projects + [T3Fixture.project(first, root: rig.project.root.path)])
        engine.shell(nil)
        rig.whole = T3Fixture.state([], projects: rig.projects)
        engine.shell(nil)
        await settle()
        #expect(rig.mutations.filter { $0.str("type") == "project.create" }.count == 2 && rig.projectID != first)
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
    var hiddenThreads: Set<String> = []
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
    /// Runs while a dispatch is awaited: what else happens meanwhile.
    var onDispatch: ((T3Command) async -> Void)?
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
            dispatch: { [unowned self] command in
                commands.append(command)
                await onDispatch?(command)
            },
            mutate: { [unowned self] body in
                mutations.append(body)
                if body.str("type") == "project.create" { projectID = body.str("projectId") }
                return [:]
            },
            sync: { _ in await MainActor.run { [unowned self] in synced += 1 } },
            zone: ExplainerInputTests.utc, user: "nobody",
            hideThreads: { [unowned self] ids in hiddenThreads.formUnion(ids) })
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
    var startFails = false

    func start(project: ExplainerProject, host: ExplainerRenderHost) async throws {
        started += 1
        if startFails { throw ThreadLaunchFailure("the port is taken") }
    }
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
