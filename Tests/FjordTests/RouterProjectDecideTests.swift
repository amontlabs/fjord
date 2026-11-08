import Foundation
import Testing
@testable import Fjord

/// The decider on T3's board: Sonnet at 0.80 for an idle thread and 0.90 for a running one, Jev alone without Sonnet, else ask.
/// A stub stands in for Sonnet; the one test of its transport answers from a stub URL protocol. Invented boards only.
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

    final class Calls { var jev = 0; var sonnet = 0; var prompt = ""; var role = "" }

    static func jev(_ pick: String, _ p: Double, calls: Calls) -> JevAsker {
        { _, _ in
            calls.jev += 1
            return ["route": .choice(JevClient.Choice(choice: pick, confidence: p, probabilities: [pick: p]))]
        }
    }

    static func sonnet(_ answer: RouterProjectSonnetAnswer, calls: Calls) -> RouterProjectDecider.Sonnet {
        { role, prompt, _ in
            await MainActor.run { calls.sonnet += 1; calls.prompt = prompt; calls.role = role }
            return answer
        }
    }

    func decision(_ a: RouterProjectSonnetAnswer, _ board: DeciderBoard? = nil) -> RouterProjectDecision {
        RouterProjectDecider(jev: nil, sonnet: nil).sonnetDecision(a, board: board ?? Self.board())
    }

    // MARK: Sonnet's bars

    @Test func anIdleThreadIsSentAtEightTenthsAndARunningOneOnlyAtNineTenths() {
        func a(_ session: String, _ p: Double) -> RouterProjectSonnetAnswer { .init(action: "follow_up", project: "x", session: session, confidence: p) }
        #expect(decision(a("f2", 0.80)).kind == .thread("t3-fjord-2"))
        #expect(decision(a("f2", 0.79)).kind == .ask([.thread("t3-fjord-2")]))
        // f1 is running: a message steers it, so 0.85 only asks.
        #expect(decision(a("f1", 0.85)).kind == .ask([.thread("t3-fjord-1")]))
        #expect(decision(a("f1", 0.90)).kind == .thread("t3-fjord-1"))
    }

    // MARK: Unattended actions

    static func actionBoard() -> DeciderBoard {
        var b = Self.board()
        b.projectRepos = ["fjord": "acme/Fjord", "silo": "acme/silo"]
        return b
    }
    static func action(_ repo: String? = "acme/fjord") -> RouterActionSource {
        RouterActionSource(origin: SessionOrigin(category: "PRs", thing: "PR 1", actionID: "a", runID: "r", runtimeMode: nil), repo: repo)
    }
    func acted(_ a: RouterProjectSonnetAnswer, repo: String? = "acme/fjord") -> RouterProjectDecision {
        RouterProjectDecider(jev: nil, sonnet: nil).sonnetDecision(a, board: Self.actionBoard(), action: Self.action(repo))
    }

    @Test func anActionsFollowUpIsTakenOnlyAtNinetyFiveAndOtherwiseStartsANewThreadInTheProject() {
        func a(_ p: Double, project: String = "fjord", pc: Double = 0) -> RouterProjectSonnetAnswer {
            .init(action: "follow_up", project: project, session: "f2", confidence: p, projectConfidence: pc)
        }
        #expect(acted(a(0.9)).kind == .newThread(project: "P-fjord"))
        #expect(acted(a(0.96)).kind == .thread("t3-fjord-2"))
        // The same answer from the owner is a follow-up at the idle bar.
        #expect(decision(a(0.9)).kind == .thread("t3-fjord-2"))
        // Without a repo that maps to a project: the model's project, at the idle bar.
        #expect(acted(a(0.9, pc: 0.85), repo: nil).kind == .newThread(project: "P-fjord"))
        #expect(acted(a(0.9, pc: 0.5), repo: nil).kind == .ask([.thread("t3-fjord-2")]))
    }

    @Test func anActionsNewWorkStartsAThreadAtTheIdleBarInTheItemsRepoProject() {
        func a(_ project: String, _ p: Double) -> RouterProjectSonnetAnswer { .init(action: "new_work", project: project, session: "", confidence: p) }
        #expect(acted(a("fjord", 0.8)).kind == .newThread(project: "P-fjord"))
        #expect(acted(a("fjord", 0.79)).kind == .ask([.newThread(project: "P-fjord")]))
        // The repo's project fills in a missing one, and blocks a different one.
        #expect(acted(a("", 0.85)).kind == .newThread(project: "P-fjord"))
        #expect(acted(a("silo", 0.99)).kind == .ask([.newThread(project: "P-silo")]))
        // A repo that no project has (or two do) decides nothing.
        #expect(acted(a("silo", 0.9), repo: "acme/other").kind == .newThread(project: "P-silo"))
        var twice = Self.actionBoard()
        twice.projectRepos["silo"] = "acme/fjord"
        let d = RouterProjectDecider(jev: nil, sonnet: nil).sonnetDecision(a("silo", 0.9), board: twice, action: Self.action())
        #expect(d.kind == .newThread(project: "P-silo"))
    }

    @Test func anActionsFollowUpInAnotherProjectThanTheItemsIsNotTaken() {
        let a = RouterProjectSonnetAnswer(action: "follow_up", project: "silo", session: "s1", confidence: 0.99)
        #expect(acted(a).kind == .ask([.thread("t3-silo-1")]))
    }

    @Test func anActionIsToldItIsAutomatedInTheSonnetPromptAndJevsState() async throws {
        let calls = Calls()
        let answer = RouterProjectSonnetAnswer(action: "new_work", project: "fjord", session: "", confidence: 0.9)
        let d = RouterProjectDecider(jev: nil, sonnet: Self.sonnet(answer, calls: calls))
        let out = try await d.decide("do it", in: Self.actionBoard(), action: Self.action())
        #expect(out.kind == .newThread(project: "P-fjord"))
        #expect(calls.prompt.contains("<automated>"))
        _ = try await d.decide("do it", in: Self.actionBoard())
        #expect(!calls.prompt.contains("<automated>"))
        #expect(Self.jevRequest(true).state["note"] != nil)
        #expect(Self.jevRequest(false).state["note"] == nil)
    }

    static func jevRequest(_ unattended: Bool) -> RouterProjectDecider.JevRequest {
        RouterProjectDecider.jevRequest("x", actionBoard(), unattended: unattended)
    }

    @Test func jevOnAnActionTakesAThreadOnlyAtNinetyFiveElseTheRepoProject() {
        let req = Self.jevRequest(true)
        let d = RouterProjectDecider(jev: nil, sonnet: nil)
        func pick(_ name: String, _ p: Double) -> RouterProjectDecision? {
            d.jevDecision(JevClient.Choice(choice: name, confidence: p, probabilities: [name: p]), board: Self.actionBoard(),
                          options: req.options, action: Self.action())
        }
        #expect(pick("Old login fix", 0.9)?.kind == .newThread(project: "P-fjord"))
        #expect(pick("Old login fix", 0.96)?.kind == .thread("t3-fjord-2"))
        #expect(pick("Disk quota", 0.99)?.kind == .newThread(project: "P-fjord"))
        #expect(pick("new in silo", 0.99) == nil)
        #expect(pick("new in fjord", 0.8)?.kind == .newThread(project: "P-fjord"))
    }

    @Test func newWorkAndAnAnswerHereGoAtTheIdleBar() {
        func a(_ action: String, _ project: String, _ p: Double) -> RouterProjectSonnetAnswer { .init(action: action, project: project, session: "", confidence: p) }
        #expect(decision(a("new_work", "silo", 0.8)).kind == .newThread(project: "P-silo"))
        #expect(decision(a("new_work", "silo", 0.79)).kind == .ask([.newThread(project: "P-silo")]))
        #expect(decision(a("answer_here", "", 0.8)).kind == .answer)
        #expect(decision(a("answer_here", "", 0.7)).kind == .ask([]))
    }

    @Test func aProjectThatIsSureWithAThreadThatIsNotDoesNotStartANewThread() {
        // E3 rejected that rule: 29 duplicate threads in 182 moments. The thread bar is the thread's alone.
        let d = decision(.init(action: "follow_up", project: "fjord", session: "f2", confidence: 0.6, projectConfidence: 0.97))
        #expect(d.kind == .ask([.thread("t3-fjord-2")]))
    }

    @Test func anUnknownThreadOrProjectIsNeverSent() {
        #expect(decision(.init(action: "follow_up", project: "fjord", session: "ghost", confidence: 0.99)).kind == .ask([]))
        #expect(decision(.init(action: "new_work", project: "garden planner", session: "", confidence: 0.99)).kind == .ask([]))
    }

    @Test func anAskListsTheGuessThenTheAlternativesEachOnce() {
        let d = decision(.init(action: "ask", project: "fjord", session: "f1", confidence: 0.4, alternatives: ["s1", "silo", "nowhere", "f1"]))
        #expect(d.kind == .ask([.thread("t3-fjord-1"), .thread("t3-silo-1"), .newThread(project: "P-silo")]))
    }

    @Test func theDecisionKeepsWhatTheLogNeeds() {
        var a = RouterProjectSonnetAnswer(action: "follow_up", project: "fjord", session: "f2", reason: "same work", confidence: 0.9, projectConfidence: 0.95)
        a.latency = 1.5
        let d = decision(a)
        #expect(d.decider == .sonnet && d.action == "follow_up" && d.projectConfidence == 0.95 && d.latency == 1.5 && d.reason == "same work")
    }

    // MARK: The cascade

    @Test func sonnetIsAskedFirstAndItsPromptIsTheSpecs() async throws {
        let calls = Calls()
        let d = RouterProjectDecider(jev: Self.jev("Disk quota", 0.99, calls: calls),
                                     sonnet: Self.sonnet(.init(action: "follow_up", project: "silo", session: "s1", confidence: 0.9), calls: calls))
        var stages: [RouterProjectDecider.Stage] = []
        let out = try await d.decide("quota?", in: Self.board()) { stages.append($0) }
        #expect(out.kind == .thread("t3-silo-1") && out.decider == .sonnet && calls.jev == 0 && stages == [.sonnet])
        #expect(calls.prompt == "Board:\n\(Self.board().render())\n\nMessage:\n<message>quota?</message>")
        #expect(calls.role.hasPrefix("You route one message from the owner") && !calls.role.contains("new project"))
    }

    @Test func withoutSonnetJevDecidesAtSevenTenthsAndARunningThreadNeedsNineTenths() async throws {
        let calls = Calls()
        let a = try await RouterProjectDecider(jev: Self.jev("Disk quota", 0.7, calls: calls), sonnet: nil).decide("x", in: Self.board())
        #expect(a == RouterProjectDecision(kind: .thread("t3-silo-1"), confidence: 0.7, decider: .jev))
        let low = try await RouterProjectDecider(jev: Self.jev("Disk quota", 0.69, calls: calls), sonnet: nil).decide("x", in: Self.board())
        #expect(low.kind == .ask([]) && low.decider == .none)
        let running = try await RouterProjectDecider(jev: Self.jev("Router redesign", 0.85, calls: calls), sonnet: nil).decide("x", in: Self.board())
        #expect(running.kind == .ask([]))
        let steer = try await RouterProjectDecider(jev: Self.jev("Router redesign", 0.9, calls: calls), sonnet: nil).decide("x", in: Self.board())
        #expect(steer.kind == .thread("t3-fjord-1"))
        let new = try await RouterProjectDecider(jev: Self.jev("new in silo", 0.8, calls: calls), sonnet: nil).decide("x", in: Self.board())
        #expect(new.kind == .newThread(project: "P-silo"))
        // An intent is never taken from him.
        let intent = try await RouterProjectDecider(jev: Self.jev("question", 0.99, calls: calls), sonnet: nil).decide("x", in: Self.board())
        #expect(intent.kind == .ask([]))
    }

    @Test func aFailedSonnetFallsToJevElseAsksWithWhy() async throws {
        let broken: RouterProjectDecider.Sonnet = { _, _, _ in throw AnthropicError.noKey }
        let calls = Calls()
        var stages: [RouterProjectDecider.Stage] = []
        let viaJev = try await RouterProjectDecider(jev: Self.jev("Disk quota", 0.9, calls: calls), sonnet: broken).decide("x", in: Self.board()) { stages.append($0) }
        #expect(viaJev.kind == .thread("t3-silo-1") && viaJev.decider == .jev && stages == [.sonnet, .jev])
        let alone = try await RouterProjectDecider(jev: nil, sonnet: broken).decide("x", in: Self.board())
        #expect(alone.kind == .ask([]) && alone.decider == .none && alone.reason == AnthropicError.noKey.localizedDescription)
        let nothing = try await RouterProjectDecider(jev: nil, sonnet: nil).decide("x", in: Self.board())
        #expect(nothing == RouterProjectDecision(kind: .ask([]), confidence: 0, decider: .none))
    }

    @Test func cancellingStopsTheDecision() async {
        let slow: RouterProjectDecider.Sonnet = { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return .init(action: "answer_here", project: "", session: "", confidence: 1)
        }
        let task = Task { try await RouterProjectDecider(jev: nil, sonnet: slow).decide("x", in: Self.board()) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    // MARK: Jev's options and redaction

    @Test func jevsOptionsAreTheBoardsThreadsThenNewThreadsThenIntents() throws {
        var b = Self.board()
        b.threads.append(.init(id: "d1", key: "t3-dup", project: "silo", title: "Router redesign", flag: .finished, minutesIdle: 5))
        let r = RouterProjectDecider.jevRequest("hi", b)
        #expect(r.options.map(\.name) == ["Router redesign (fjord)", "Router redesign (silo)", "Disk quota", "Old login fix",
                                           "new in fjord", "new in silo", "new in empty", "change_fjord", "question", "compound", "unclear"])
        guard case .structuredChoice(_, let criteria, _) = r.question else { Issue.record("not a structured choice"); return }
        let now = (criteria["Router redesign (fjord)"] as? [String: Any])?["now"] as? String
        #expect(now?.hasPrefix("- f1 | Router redesign | running (a message would interrupt it), 3m ago") == true)
        #expect((criteria["new in fjord"] as? [String: Any])?["about"] as? String == "Fjord, the Mac app")
        #expect((criteria["new in empty"] as? [String: Any])?["about"] as? String == "no description")
        #expect(r.state == ["message": "hi"])
    }

    @Test func everythingIsRedactedBeforeAnyModel() throws {
        var b = Self.board()
        b.threads[0].title = "Keys \(Self.secret)"
        b.threads[0].said = "set \(Self.secret)"
        b.threads[0].youSaid = "take \(Self.secret)"
        let request = RouterProjectDecider.jevRequest("my key is \(Self.secret)", b, tagged: "@CI \(Self.secret)")
        let wire = String(decoding: try JevClient.requestData(["route": request.question], about: request.state), as: UTF8.self)
        #expect(!wire.contains(Self.secret) && wire.contains("[redacted]"))
        let prompt = RouterProjectDecider.sonnetPrompt("my key is \(Self.secret)", b, tagged: "@CI \(Self.secret)")
        #expect(!prompt.contains(Self.secret) && prompt.contains("<message>my key is [redacted]</message>"))
    }

    // MARK: The transport

    @Test func theApiSonnetSendsTheRoleAsTheCachedSystemBlockWithThinkingOffAndReadsTheTypedAnswer() async throws {
        let seen = DecideSeen()
        DecideStub.handler = { body in
            seen.body = body
            let text = #"{"action":"follow_up","project":"silo","session":"s1","reason":"r","confidence":0.91,"project_confidence":0.95,"alternatives":[],"need":[]}"#
            let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
            return #"{"stop_reason":"end_turn","content":[{"type":"text","text":\#(escaped)}],"usage":{"input_tokens":10,"output_tokens":4}}"#
        }
        let client = AnthropicClient(session: AnthropicClient.makeSession(protocolClasses: [DecideStub.self]), baseURL: URL(string: "https://stub.test")!,
                                     apiKey: { "sk-test" }, effort: nil)
        let sonnet = RouterProjectDecider.api(client)
        let answer = try await sonnet(RouterProjectDecider.role, "Board:\nx", RouterProjectDecider.schema)
        #expect(answer.session == "s1" && answer.confidence == 0.91 && answer.projectConfidence == 0.95 && answer.usage?.inputTokens == 10)
        let json = try #require(try JSONSerialization.jsonObject(with: seen.body) as? [String: Any])
        #expect(json["model"] as? String == "claude-sonnet-5-5" && json["max_tokens"] as? Int == 700)
        #expect((json["thinking"] as? [String: Any])?["type"] as? String == "between_tools")
        let output = json["output_config"] as? [String: Any]
        #expect(output?["effort"] == nil && (output?["format"] as? [String: Any])?["type"] as? String == "json_schema")
        let system = (json["system"] as? [[String: Any]])?.first
        #expect(system?["text"] as? String == RouterProjectDecider.role && (system?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    /// FJORD_ANTHROPIC_LIVE=1: one real call on an invented board (a fraction of a cent).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FJORD_ANTHROPIC_LIVE"] == "1"))
    func liveSmokeOnAnInventedBoard() async throws {
        let b = DeciderBoard(projects: ["harbor-notes"], purposes: ["harbor-notes": "A note-taking app for sailors."], threads: [
            .init(id: "7f3a9c21", project: "harbor-notes", title: "Tide table import", flag: .finished, minutesIdle: 120,
                  said: "The importer now reads both CSV layouts. Two stations still fail on a trailing comma.", youSaid: "Add the second layout too"),
        ])
        let d = RouterProjectDecider(jev: nil, sonnet: RouterProjectDecider.api(RouterProjectDecider.makeClient()))
        let out = try await d.decide("fix the trailing comma in the tide importer", in: b)
        print("live decision:", out.kind, out.confidence, out.latency ?? 0)
        #expect(out.decider == .sonnet && out.latency != nil)
    }
}

final class DecideSeen: @unchecked Sendable { var body = Data() }

final class DecideStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((Data) -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        let reply = Self.handler?(body) ?? "{}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: [:])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
