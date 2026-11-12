import Foundation
import Testing
@testable import Fjord

/// The decider on T3's board: Jev's sure send first, then Sonnet on the full context by N4's rule at its 1% bars, and without
/// Sonnet Jev only orders the ask. A stub stands in for Sonnet; the transport (`claude -p`) is stubbed too. Invented boards only.
@MainActor
@Suite struct RouterProjectDecideTests {
    static let secret = "sk-abcdefghijklmnopqrstuvwxyz0123"

    static func board() -> DeciderBoard {
        var b = DeciderBoard(projects: ["fjord", "silo", "empty"], purposes: ["fjord": "Fjord, the Mac app"], threads: [
            .init(id: "s1", key: "t3-silo-1", project: "silo", title: "Disk quota", flag: .finished, minutesIdle: 300, said: "quota is in"),
            .init(id: "f2", key: "t3-fjord-2", project: "fjord", title: "Old login fix", flag: .finished, minutesIdle: 600, said: "fixed the redirect"),
            .init(id: "f1", key: "t3-fjord-1", project: "fjord", title: "Router redesign", flag: .running, minutesIdle: 3,
                  step: "writing the decider", said: "on it", youSaid: "build the decider"),
        ])
        b.projectIDs = ["fjord": "P-fjord", "silo": "P-silo", "empty": "P-empty"]
        return b
    }

    /// The context's names for the board's threads.
    static let ctx = DeciderContext.Built(system: "role", blocks: ["B", "D", "E"],
                                          ids: ["t-s1": "t3-silo-1", "t-f2": "t3-fjord-2", "t-f1": "t3-fjord-1", "t-old": "t3-archived"],
                                          live: [], archive: [], key: "key", sizes: ["A": 4])

    final class Calls { var jev = 0; var sonnet = 0; var user = ""; var system = "" }

    static func jev(_ pick: String, _ p: Double, calls: Calls) -> JevAsker {
        { _, _ in
            calls.jev += 1
            return ["route": .choice(JevClient.Choice(choice: pick, confidence: p, probabilities: [pick: p]))]
        }
    }

    static func sonnet(_ answer: RouterContextAnswer, calls: Calls) -> RouterProjectDecider.Sonnet {
        { built in
            await MainActor.run { calls.sonnet += 1; calls.user = built.user; calls.system = built.system }
            return answer
        }
    }

    func decision(_ a: RouterContextAnswer, _ board: DeciderBoard? = nil) -> RouterProjectDecision {
        RouterProjectDecider(jev: nil, sonnet: nil).contextDecision(a, context: Self.ctx, board: board ?? Self.board())
    }

    /// A follow-up its thread owns, alone in `fits`.
    static func follow(_ session: String, _ p: Double, owned: String? = nil, unique: Bool = true, pNew: Double = 0) -> RouterContextAnswer {
        .init(action: "follow_up", project: "fjord", session: session, confidence: p, pNew: pNew,
              fits: [.init(thread: session, how: "reacts_to_its_result", stateOK: true)], ownedBy: owned ?? session, referentUnique: unique)
    }

    // MARK: N4's rule at its 1% bars

    @Test func aFollowUpItsThreadOwnsAloneIsSentAtNinetyIdleOrRunning() {
        #expect(decision(Self.follow("t-f2", 0.90)).kind == .thread("t3-fjord-2"))
        #expect(decision(Self.follow("t-f2", 0.89)).kind == .ask([.thread("t3-fjord-2"), .newThread(project: "P-fjord")]))
        #expect(decision(Self.follow("t-f1", 0.90)).kind == .thread("t3-fjord-1"))
        // An archive thread (named in the context, not on the board) can be sent to as well.
        #expect(decision(Self.follow("t-old", 0.95)).kind == .thread("t3-archived"))
    }

    @Test func theOwnershipGuardAsksWhenAnotherThreadOwnsItOrSeveralFit() {
        #expect(decision(Self.follow("t-f2", 0.97, owned: "none")).kind == .ask([.thread("t3-fjord-2"), .newThread(project: "P-fjord")]))
        #expect(decision(Self.follow("t-f2", 0.97, unique: false)).kind == .ask([.thread("t3-fjord-2"), .newThread(project: "P-fjord")]))
    }

    @Test func pNewOrNewWorkAtSeventyStartsANewThreadInTheModelsProject() {
        func a(_ action: String, conf: Double, pNew: Double, project: String = "silo") -> RouterContextAnswer {
            .init(action: action, project: project, session: "", confidence: conf, pNew: pNew)
        }
        #expect(decision(a("ask", conf: 0.3, pNew: 0.70)).kind == .newThread(project: "P-silo"))
        #expect(decision(Self.follow("t-s1", 0.99, pNew: 0.75)).kind == .newThread(project: "P-fjord"))
        #expect(decision(a("new_work", conf: 0.70, pNew: 0.1)).kind == .newThread(project: "P-silo"))
        #expect(decision(a("new_work", conf: 0.69, pNew: 0.69)).kind == .ask([.newThread(project: "P-silo")]))
        // Only a known project.
        #expect(decision(a("new_work", conf: 0.99, pNew: 0.99, project: "garden planner")).kind == .ask([]))
    }

    @Test func anAnswerHereGoesAtEighty() {
        #expect(decision(.init(action: "answer_here", project: "", session: "", confidence: 0.8)).kind == .answer)
        #expect(decision(.init(action: "answer_here", project: "", session: "", confidence: 0.7)).kind == .ask([]))
    }

    @Test func anAskListsTheGuessThenTheFitsThenTheAlternativesEachOnce() {
        var a = RouterContextAnswer(action: "ask", project: "fjord", session: "t-f1", confidence: 0.4, alternatives: ["t-s1", "silo", "nowhere", "t-f1"],
                                    fits: [.init(thread: "t-f2", how: "next_step_same_deliverable", stateOK: true),
                                           .init(thread: "t-s1", how: "topic_only", stateOK: true)])
        a.referentUnique = false
        let d = decision(a)
        #expect(d.kind == .ask([.thread("t3-fjord-1"), .thread("t3-fjord-2"), .thread("t3-silo-1"), .newThread(project: "P-silo")]))
        #expect(d.decider == .sonnet)
    }

    @Test func anUnknownThreadIsNeverSent() {
        #expect(decision(Self.follow("ghost", 0.99)).kind == .ask([.newThread(project: "P-fjord")]))
    }

    @Test func theAnswerDecodesN4bsSchemaAndTheDecisionKeepsItForTheLog() throws {
        let json = #"{"message_deliverable":"fix the quota","fits":[{"thread":"t-s1","how":"reacts_to_its_result","state_ok":true}],"owned_by":"t-s1","referent_unique":true,"action":"follow_up","project":"silo","session":"t-s1","reason":"r","alternatives":[],"confidence":0.93,"project_confidence":0.9,"p_new":0.04}"#
        var a = try JSONDecoder().decode(RouterContextAnswer.self, from: Data(json.utf8))
        a.latency = 1.5
        #expect(a.messageDeliverable == "fix the quota" && a.fits == [.init(thread: "t-s1", how: "reacts_to_its_result", stateOK: true)])
        let d = decision(a)
        #expect(d.kind == .thread("t3-silo-1") && d.pNew == 0.04 && d.deliverable == "fix the quota" && d.ownedBy == "t-s1")
        #expect(d.referentUnique == true && d.fits.count == 1 && d.latency == 1.5 && d.projectConfidence == 0.9 && d.action == "follow_up")
    }

    @Test func theSchemaIsN4bsInItsOrder() throws {
        let schema = DeciderContext.schema
        let keys = ["message_deliverable", "fits", "owned_by", "referent_unique", "action", "project", "session", "reason", "alternatives",
                    "confidence", "project_confidence", "p_new"]
        let json = try #require(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        #expect(json["required"] as? [String] == keys && json["additionalProperties"] as? Bool == false)
        let at = keys.map { (schema.range(of: "\"\($0)\": {")?.lowerBound).map { schema.distance(from: schema.startIndex, to: $0) } ?? -1 }
        #expect(at == at.sorted() && !at.contains(-1))
        let props = try #require(json["properties"] as? [String: Any])
        let fit = try #require(((props["fits"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])
        #expect(((fit["how"] as? [String: Any])?["enum"] as? [String])?.last == "topic_only")
    }

    // MARK: Unattended actions keep their policy

    static func actionBoard() -> DeciderBoard {
        var b = Self.board()
        b.projectRepos = ["fjord": "acme/Fjord", "silo": "acme/silo"]
        return b
    }
    static func action(_ repo: String? = "acme/fjord") -> RouterActionSource {
        RouterActionSource(origin: SessionOrigin(category: "PRs", thing: "PR 1", actionID: "a", runID: "r", runtimeMode: nil), repo: repo)
    }
    func acted(_ a: RouterContextAnswer, repo: String? = "acme/fjord") -> RouterProjectDecision {
        RouterProjectDecider(jev: nil, sonnet: nil).contextDecision(a, context: Self.ctx, board: Self.actionBoard(), action: Self.action(repo))
    }

    @Test func anActionsFollowUpIsTakenOnlyAtNinetyFiveAndOtherwiseStartsANewThreadInTheProject() {
        func a(_ p: Double, pc: Double = 0) -> RouterContextAnswer { .init(action: "follow_up", project: "fjord", session: "t-f2", confidence: p, projectConfidence: pc) }
        #expect(acted(a(0.9)).kind == .newThread(project: "P-fjord"))
        #expect(acted(a(0.96)).kind == .thread("t3-fjord-2"))
        #expect(acted(a(0.9, pc: 0.85), repo: nil).kind == .newThread(project: "P-fjord"))
        #expect(acted(a(0.9, pc: 0.5), repo: nil).kind == .ask([.thread("t3-fjord-2"), .newThread(project: "P-fjord")]))
        // p_new doesn't change it.
        #expect(acted(.init(action: "follow_up", project: "fjord", session: "t-f1", confidence: 0.99, pNew: 0.95)).kind == .thread("t3-fjord-1"))
    }

    @Test func anActionsNewWorkStartsAThreadAtEightyInTheItemsRepoProject() {
        func a(_ project: String, _ p: Double) -> RouterContextAnswer { .init(action: "new_work", project: project, session: "", confidence: p) }
        #expect(acted(a("fjord", 0.8)).kind == .newThread(project: "P-fjord"))
        #expect(acted(a("fjord", 0.79)).kind == .ask([.newThread(project: "P-fjord")]))
        #expect(acted(a("", 0.85)).kind == .newThread(project: "P-fjord"))
        #expect(acted(a("silo", 0.99)).kind == .ask([.newThread(project: "P-silo")]))
    }

    @Test func anActionIsToldItIsAutomatedInTheContextAndJevsState() {
        #expect(DeciderContextTests.build("do it", threads: [], unattended: true).user.contains("<automated>"))
        #expect(!DeciderContextTests.build("do it", threads: []).user.contains("<automated>"))
        #expect(Self.jevRequest(true).state["note"] != nil && Self.jevRequest(false).state["note"] == nil)
    }

    static func jevRequest(_ unattended: Bool) -> RouterProjectDecider.JevRequest {
        RouterProjectDecider.jevRequest("x", actionBoard(), unattended: unattended)
    }

    @Test func jevOnAnActionAsksWithTheRepoProjectsNewThreadFirst() {
        let req = Self.jevRequest(true)
        let d = RouterProjectDecider(jev: nil, sonnet: nil)
        let probs = ["Disk quota": 0.5, "Old login fix": 0.3, "new in silo": 0.1, "Router redesign": 0.05]
        let out = d.jevAsk(JevClient.Choice(choice: "Disk quota", confidence: 0.5, probabilities: probs), board: Self.actionBoard(),
                           options: req.options, action: Self.action())
        #expect(out?.kind == .ask([.newThread(project: "P-fjord"), .thread("t3-silo-1"), .thread("t3-fjord-2")]))
    }

    // MARK: The cascade

    @Test func sonnetDecidesOnTheContextAndTheDecisionKeepsIt() async throws {
        let calls = Calls()
        let d = RouterProjectDecider(jev: Self.jev("Disk quota", 0.99, calls: calls), sonnet: Self.sonnet(Self.follow("t-s1", 0.95), calls: calls))
        var stages: [RouterProjectDecider.Stage] = []
        let out = try await d.decide("quota?", in: Self.board(), context: { Self.ctx }) { stages.append($0) }
        #expect(out.kind == .thread("t3-silo-1") && out.decider == .sonnet && calls.jev == 0 && stages == [.sonnet])
        #expect(calls.user == Self.ctx.user && calls.system == "role")
        #expect(out.boardText == Self.ctx.user && out.contextKey == "key" && out.contextSizes == ["A": 4])
    }

    @Test func withoutSonnetJevNeverSendsAndOnlyOrdersTheAsk() async throws {
        let calls = Calls()
        let a = try await RouterProjectDecider(jev: Self.jev("Disk quota", 0.99, calls: calls), sonnet: nil).decide("x", in: Self.board(), context: { Self.ctx })
        #expect(a.kind == .ask([.thread("t3-silo-1"), .thread("t3-fjord-1"), .thread("t3-fjord-2")]) && a.decider == .jev)
        #expect(!Self.jevRequest(false).options.contains { ["question", "unclear", "compound", "change_fjord"].contains($0.name) })
    }

    @Test func jevOrdersTheAskByHisProbabilities() {
        let req = Self.jevRequest(false)
        let probs = ["Old login fix": 0.6, "new in silo": 0.25, "question": 0.1, "Disk quota": 0.05]
        let out = RouterProjectDecider(jev: nil, sonnet: nil).jevAsk(JevClient.Choice(choice: "Old login fix", confidence: 0.6, probabilities: probs),
                                                                      board: Self.actionBoard(), options: req.options)
        #expect(out?.kind == .ask([.thread("t3-fjord-2"), .newThread(project: "P-silo"), .thread("t3-silo-1")]))
    }

    @Test func aFailedSonnetFallsToJevsAskElseAsksWithWhy() async throws {
        let broken: RouterProjectDecider.Sonnet = { _ in throw ClaudePrint.Failure(message: "Claude Code wasn't found") }
        let calls = Calls()
        var stages: [RouterProjectDecider.Stage] = []
        let viaJev = try await RouterProjectDecider(jev: Self.jev("Disk quota", 0.9, calls: calls), sonnet: broken)
            .decide("x", in: Self.board(), context: { Self.ctx }) { stages.append($0) }
        #expect(viaJev.decider == .jev && stages == [.sonnet, .jev])
        let alone = try await RouterProjectDecider(jev: nil, sonnet: broken).decide("x", in: Self.board(), context: { Self.ctx })
        #expect(alone.kind == .ask([]) && alone.decider == .none && alone.reason == "Claude Code wasn't found")
    }

    @Test func cancellingStopsTheDecision() async {
        let slow: RouterProjectDecider.Sonnet = { _ in
            try await Task.sleep(for: .seconds(30))
            return .init(action: "answer_here", project: "", session: "", confidence: 1)
        }
        let task = Task { try await RouterProjectDecider(jev: nil, sonnet: slow).decide("x", in: Self.board(), context: { Self.ctx }) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    // MARK: Jev's options and redaction

    @Test func jevsOptionsAreTheBoardsThreadsThenNewThreadsAndNoIntents() throws {
        var b = Self.board()
        b.threads.append(.init(id: "d1", key: "t3-dup", project: "silo", title: "Router redesign", flag: .finished, minutesIdle: 5))
        let r = RouterProjectDecider.jevRequest("hi", b)
        #expect(r.options.map(\.name) == ["Router redesign (fjord)", "Router redesign (silo)", "Disk quota", "Old login fix",
                                           "new in fjord", "new in silo", "new in empty"])
        guard case .structuredChoice(_, let criteria, _) = r.question else { Issue.record("not a structured choice"); return }
        let now = (criteria["Router redesign (fjord)"] as? [String: Any])?["now"] as? String
        #expect(now?.hasPrefix("- f1 | Router redesign | running (a message would interrupt it), 3m ago") == true)
        #expect((criteria["new in fjord"] as? [String: Any])?["about"] as? String == "Fjord, the Mac app")
        #expect((criteria["new in empty"] as? [String: Any])?["about"] as? String == "no description")
        #expect(r.state == ["message": "hi"])
    }

    @Test func jevAsksWhichPlaceInThreadsWordsOnAPinnedModel() throws {
        let r = RouterProjectDecider.jevRequest("hi", Self.board())
        guard case .structuredChoice(_, let criteria, let instructions) = r.question else { Issue.record("not a structured choice"); return }
        let words = String(decoding: try JSONSerialization.data(withJSONObject: instructions), as: UTF8.self)
        #expect(!words.contains("session") && !words.contains("`question`") && words.contains("thread"))
        #expect((criteria["Disk quota"] as? [String: Any])?["kind"] as? String == "thread")
        let data = try JevClient.$model.withValue(JevClient.routingModel) { try JevClient.requestData(["route": r.question], about: r.state) }
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "jev-1.14.0")
        let other = try JevClient.requestData(["route": r.question], about: r.state)
        #expect((try JSONSerialization.jsonObject(with: other) as? [String: Any])?["model"] as? String == "jev-latest")
    }

    @Test func everythingIsRedactedBeforeAnyModel() throws {
        var b = Self.board()
        b.threads[0].title = "Keys \(Self.secret)"
        b.threads[0].said = "set \(Self.secret)"
        b.threads[0].youSaid = "take \(Self.secret)"
        let request = RouterProjectDecider.jevRequest("my key is \(Self.secret)", b, tagged: "@CI \(Self.secret)")
        let wire = String(decoding: try JevClient.requestData(["route": request.question], about: request.state), as: UTF8.self)
        #expect(!wire.contains(Self.secret) && wire.contains("[redacted]"))
        let ctx = DeciderContextTests.build("my key is \(Self.secret)", threads: [DeciderContextTests.thread("a", title: "Keys \(Self.secret)", said: "set \(Self.secret)")],
                                            tagged: "@CI \(Self.secret)")
        #expect(!ctx.user.contains(Self.secret) && ctx.user.contains("<message>my key is [redacted]</message>"))
    }

    // MARK: The transport: `claude -p`, stubbed

    @Test func sonnetGoesThroughClaudeCodeWithTheSchemaThinkingOffAndItsUsageLogged() async throws {
        let seen = PrintSeen()
        let runner: ClaudePrint.Runner = { binary, args, input, timeout in
            seen.set(binary, args, String(decoding: input, as: UTF8.self), timeout)
            let out = #"{"type":"result","is_error":false,"total_cost_usd":0.021,"usage":{"input_tokens":7400,"output_tokens":300,"cache_read_input_tokens":27800,"cache_creation_input_tokens":0},"structured_output":{"message_deliverable":"m","fits":[],"owned_by":"none","referent_unique":false,"action":"new_work","project":"silo","session":"","reason":"r","alternatives":[],"confidence":0.8,"project_confidence":0.9,"p_new":0.8}}"#
            return OneShot.Output(stdout: Data(out.utf8), stderr: Data(), status: 0)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ModelUsageLog(url: dir.appendingPathComponent("model-usage.jsonl"))
        let sonnet = RouterProjectDecider.claude(binary: { "/bin/claude" }, runner: runner, log: log)
        let a = try await sonnet(Self.ctx)
        #expect(a.action == "new_work" && a.pNew == 0.8 && a.usage?.cacheReadTokens == 27800 && a.usage?.costUSD == 0.021)
        let args = seen.args
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(seen.binary == "/bin/claude" && args.first == "-p" && value("--model") == "claude-sonnet-5-5")
        #expect(value("--json-schema") == DeciderContext.schema && value("--system-prompt") == "role")
        #expect(value("--settings") == #"{"alwaysThinkingEnabled":false}"# && value("--effort") == "high" && value("--tools") == "")
        #expect(args.contains("--no-session-persistence") && args.contains("--strict-mcp-config") && value("--output-format") == "json")
        #expect(seen.input == Self.ctx.user)
        log.flush()
        let entries = log.entries()
        #expect(entries.count == 1 && entries[0].role == .decider && entries[0].usage.inputTokens == 7400 && entries[0].usage.costUSD == 0.021)
    }

    @Test func aClaudeCodeErrorOrNoStructuredOutputFails() {
        let err = OneShot.Output(stdout: Data(#"{"is_error":true,"result":"usage limit reached"}"#.utf8), stderr: Data(), status: 1)
        #expect(throws: ClaudePrint.Failure.self) { _ = try ClaudePrint.parse(err) }
        let none = OneShot.Output(stdout: Data(#"{"is_error":false,"result":"hi"}"#.utf8), stderr: Data(), status: 0)
        #expect(throws: ClaudePrint.Failure.self) { _ = try ClaudePrint.parse(none) }
        let garbage = OneShot.Output(stdout: Data("nope".utf8), stderr: Data("boom".utf8), status: 1)
        #expect(throws: ClaudePrint.Failure(message: "Claude Code: boom")) { _ = try ClaudePrint.parse(garbage) }
    }
}

// MARK: - A new thread's settings in the answer

extension RouterProjectDecideTests {
    static let offer = RouterLaunchCatalog.offer(config: RouterLaunchCatalogTests.config())

    static func ctxWith(_ offer: RouterLaunchOffer?) -> DeciderContext.Built {
        var c = ctx
        c.launch = offer
        c.schema = DeciderContext.schema(launch: offer)
        return c
    }

    @Test func theAnswerDecodesLaunchAndTheWordsAndAnAnswerWithoutThemStillDecodes() throws {
        let json = #"{"message_deliverable":"split","fits":[],"owned_by":"none","referent_unique":false,"action":"new_work","project":"silo","session":"","reason":"r","alternatives":[],"confidence":0.9,"project_confidence":0.9,"p_new":0.9,"launch":{"model":"claude-opus-5-5","effort":"medium","interaction_mode":"plan"},"launch_words":"(use opus medium)"}"#
        let a = try JSONDecoder().decode(RouterContextAnswer.self, from: Data(json.utf8))
        #expect(a.launch == .init(model: "claude-opus-5-5", effort: "medium", runtimeMode: nil, interactionMode: "plan") && a.launchWords == "(use opus medium)")
        let old = #"{"action":"ask","confidence":0.4}"#
        let b = try JSONDecoder().decode(RouterContextAnswer.self, from: Data(old.utf8))
        #expect(b.launch == .init() && b.launchWords.isEmpty)
        // A launch of the wrong shape is no settings, not a failed answer.
        let odd = try JSONDecoder().decode(RouterContextAnswer.self, from: Data(#"{"action":"ask","confidence":0.4,"launch":"opus"}"#.utf8))
        #expect(odd.launch == .init())
    }

    @Test func aDecisionCarriesOnlyWhatT3OffersAndTheWordsOnlyIfSomethingWasNamed() {
        var a = RouterContextAnswer(action: "new_work", project: "silo", session: "", confidence: 0.9, pNew: 0.9)
        a.launch = .init(model: "opus", effort: "medium", runtimeMode: "auto", interactionMode: "plan")
        a.launchWords = "(use opus medium)"
        let d = RouterProjectDecider(jev: nil, sonnet: nil).contextDecision(a, context: Self.ctxWith(Self.offer), board: Self.board())
        #expect(d.launch == RouterV2LaunchAsk(model: "claude-opus-5-5", effort: .medium, access: .auto, plan: true) && d.launchWords == "(use opus medium)")
        // A model T3 doesn't have is dropped with its effort kept to the default model's list; the words go with nothing named.
        a.launch = .init(model: "gpt-9", effort: nil, runtimeMode: nil, interactionMode: nil)
        let dropped = RouterProjectDecider(jev: nil, sonnet: nil).contextDecision(a, context: Self.ctxWith(Self.offer), board: Self.board())
        #expect(dropped.launch == RouterV2LaunchAsk() && dropped.launchWords.isEmpty)
        // No offer (T3's models unknown): nothing is taken from the answer.
        let none = RouterProjectDecider(jev: nil, sonnet: nil).contextDecision(a, context: Self.ctxWith(nil), board: Self.board())
        #expect(none.launch == RouterV2LaunchAsk() && none.launchWords.isEmpty)
    }

    @Test func theCallsSchemaIsTheContextsSoTheEnumsAreT3sAtCallTime() async throws {
        let seen = PrintSeen()
        let runner: ClaudePrint.Runner = { binary, args, input, timeout in
            seen.set(binary, args, String(decoding: input, as: UTF8.self), timeout)
            let out = #"{"type":"result","is_error":false,"usage":{"input_tokens":1,"output_tokens":1},"structured_output":{"action":"new_work","project":"silo","session":"","confidence":0.8,"launch":{"effort":"max"},"launch_words":"max effort"}}"#
            return OneShot.Output(stdout: Data(out.utf8), stderr: Data(), status: 0)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ModelUsageLog(url: dir.appendingPathComponent("model-usage.jsonl"))
        let built = Self.ctxWith(Self.offer)
        let a = try await RouterProjectDecider.claude(binary: { "/bin/claude" }, runner: runner, log: log)(built)
        let args = seen.args
        #expect(args.firstIndex(of: "--json-schema").map { args[$0 + 1] } == built.schema && built.schema != DeciderContext.schema)
        #expect(a.launch.effort == "max" && a.launchWords == "max effort")
    }

    @Test func theLogKeepsWhatTheMessageNamedForScoring() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DeciderLog(url: dir.appendingPathComponent("decider-log.jsonl"))
        var d = RouterProjectDecision(kind: .newThread(project: "p1"), confidence: 0.9, decider: .sonnet)
        d.launch = RouterV2LaunchAsk(model: "claude-opus-5-5", effort: .medium, access: nil, plan: false)
        d.launchWords = "(use opus medium)"
        log.decision(id: UUID(), message: "split it (use opus medium)", decision: d, board: "b", candidates: [], sent: "split it")
        log.flush()
        let line = try #require(String(contentsOf: log.url, encoding: .utf8).split(separator: "\n").first)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let launch = try #require(json["launch"] as? [String: String])
        #expect(launch == ["model": "claude-opus-5-5", "effort": "medium", "interactionMode": "default"] && json["launchWords"] as? String == "(use opus medium)")
        // A decision with no settings logs none.
        let plain = DeciderLog(url: dir.appendingPathComponent("plain.jsonl"))
        plain.decision(id: UUID(), message: "m", decision: RouterProjectDecision(kind: .answer, confidence: 1, decider: .sonnet), board: "b", candidates: [], sent: "")
        plain.flush()
        #expect(!(try String(contentsOf: plain.url, encoding: .utf8)).contains("launchWords"))
    }
}

final class PrintSeen: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var binary = "", args: [String] = [], input = "", timeout: TimeInterval = 0
    func set(_ b: String, _ a: [String], _ i: String, _ t: TimeInterval) { lock.withLock { binary = b; args = a; input = i; timeout = t } }
}
