import Foundation
import Testing
@testable import Fjord

/// The project decider: the context it reads (order, cuts, redaction), Jev first at 0.7, then Sonnet at 0.8, else ask.
@MainActor
@Suite struct RouterProjectDecideTests {
    typealias C = RouterProjectContext
    static let secret = "sk-abcdefghijklmnopqrstuvwxyz0123"

    static func context(routings: [C.Routing] = []) -> C {
        C(projects: [
            .init(id: "chan_silo", name: "silo", threads: [.init(id: "s1", title: "Disk quota", running: false, minutesIdle: 300)]),
            .init(id: "chan_fjord", name: "fjord", purpose: "Fjord, the Mac app", threads: [
                .init(id: "f2", title: "Old login fix", running: false, minutesIdle: 2000, summary: "fixed the redirect"),
                .init(id: "f1", title: "Router redesign", running: true, minutesIdle: 3, doing: "writing the decider",
                      told: .init(text: "build the decider", minutesAgo: 10)),
            ]),
            .init(id: "chan_empty", name: "empty"),
        ], routings: routings)
    }

    final class Calls { var jev = 0; var sonnet = 0; var prompt = "" }

    static func jev(_ pick: String, _ p: Double, calls: Calls) -> JevAsker {
        { _, _ in
            calls.jev += 1
            return ["route": .choice(JevClient.Choice(choice: pick, confidence: p, probabilities: [pick: p]))]
        }
    }

    static func sonnet(_ answer: RouterProjectSonnetAnswer, calls: Calls) -> RouterProjectDecider.Sonnet {
        { _, prompt, _ in
            await MainActor.run { calls.sonnet += 1; calls.prompt = prompt }
            return answer
        }
    }

    // MARK: Context

    @Test func projectsAndThreadsGoMostRecentFirstAndRoutingsKeepTheLastEight() {
        let routings = (1...10).map { C.Routing(text: "m\($0)", to: "fjord") }
        let c = Self.context(routings: routings)
        #expect(c.projects.map(\.name) == ["fjord", "silo", "empty"])
        #expect(c.projects[0].threads.map(\.id) == ["f1", "f2"])
        #expect(c.threads.map(\.thread.id) == ["f1", "s1", "f2"])
        #expect(c.routings.map(\.text) == (3...10).map { "m\($0)" })
    }

    @Test func aThreadsLinesAreCutAsTheMeasuredBoard() {
        let long = String(repeating: "a", count: 1000)
        let t = C.Thread(id: "x", title: "T", running: true, minutesIdle: 90, doing: long, summary: long, lastAnswer: long + "END",
                         told: .init(text: long, minutesAgo: 3000), waiting: [.init(kind: "question", text: long)])
        let lines = C.lines(t)
        #expect(lines[0] == "running, 1h ago")
        #expect(lines[1] == "doing: " + String(repeating: "a", count: 240))
        #expect(lines[2] == "summary: " + String(repeating: "a", count: 300))
        #expect(lines[3] == "you last told it (2d ago): " + String(repeating: "a", count: 200))
        #expect(lines[4] == "its last answer: " + String(repeating: "a", count: 597) + "END")
        #expect(lines[5] == "waiting (question): " + String(repeating: "a", count: 300))
    }

    @Test func sonnetsBoardListsRoutingsThenProjectsWithTheirThreads() {
        let c = Self.context(routings: [.init(text: "fix it", to: "Old login fix", correctedTo: "fjord")])
        let board = c.board()
        #expect(board.hasPrefix("## Your last routings (oldest first)\n“fix it” → fjord (you corrected it from Old login fix)\n\n## fjord\nabout: Fjord, the Mac app\n- f1 | Router redesign | running, 3m ago\n  doing: writing the decider\n  you last told it (10m ago): build the decider\n- f2 | Old login fix | idle, 1d ago\n  summary: fixed the redirect\n## silo"))
        #expect(board.hasSuffix("## empty"))
    }

    @Test func everythingIsRedactedBeforeAnyModel() async throws {
        let c = C(projects: [.init(id: "p", name: "fjord", purpose: "key \(Self.secret)", threads: [
            .init(id: "t", title: "Keys \(Self.secret)", running: false, minutesIdle: 1, summary: "used \(Self.secret)",
                  lastAnswer: "set \(Self.secret)", told: .init(text: "take \(Self.secret)", minutesAgo: 1)),
        ])])
        let request = RouterProjectDecider.jevRequest("my key is \(Self.secret)", c)
        let wire = String(decoding: try JevClient.requestData(["route": request.question], about: request.state), as: UTF8.self)
        #expect(!wire.contains(Self.secret) && wire.contains("[redacted]"))
        let prompt = RouterProjectDecider.sonnetPrompt("my key is \(Self.secret)", c)
        #expect(!prompt.contains(Self.secret) && prompt.contains("<message>my key is [redacted]</message>"))
    }

    @Test func jevsOptionsAreThreadsThenNewWorkThenProjectsThenIntents() {
        var c = Self.context()
        c = C(projects: c.projects + [.init(id: "chan_dup", name: "dup", threads: [.init(id: "d1", title: "Router redesign", running: false, minutesIdle: 5)])])
        let r = RouterProjectDecider.jevRequest("hi", c)
        #expect(r.options.map(\.name) == ["Router redesign (fjord)", "Router redesign (dup)", "Disk quota", "Old login fix",
                                           "new in fjord", "new in dup", "new in silo", "new in empty",
                                           "claude_ai project fjord", "claude_ai project dup", "claude_ai project silo", "claude_ai project empty",
                                           "change_fjord", "question", "compound", "unclear"])
        guard case .structuredChoice(_, let criteria, _) = r.question else { Issue.record("not a structured choice"); return }
        let thread = criteria["Router redesign (fjord)"] as? [String: Any]
        #expect(thread?["now"] as? String == "running, 3m ago\ndoing: writing the decider\nyou last told it (10m ago): build the decider")
        let project = criteria["claude_ai project fjord"] as? [String: Any]
        #expect(project?["about"] as? String == "Fjord, the Mac app")
        #expect(project?["its threads"] as? [String] == ["Router redesign", "Old login fix"])
        #expect((criteria["claude_ai project empty"] as? [String: Any])?["about"] as? String == "no description")
        #expect(r.state == ["message": "hi"])
    }

    @Test func theBoardsThreadsTakeTheirLocalSessionsFacts() {
        let board: JSON = [
            "projects": ["chan_a": ["id": "chan_a", "name": "a", "purpose": "A app"], "local:b": ["id": "local:b", "name": "b"]],
            "threads": [
                "t1": ["id": "t1", "project": "chan_a", "title": "One", "state": "working", "session": "cse_1", "touched": 940, "detail": "board detail"],
                "t2": ["id": "t2", "project": "chan_a", "title": "Two", "state": "needs_you", "needs": "pick one", "touched": 400, "result": "done it"],
                "local:x": ["id": "local:x", "project": "local:b", "title": "Local", "state": "idle", "touched": 900],
            ],
        ]
        let local: JSON = ["sessions": ["cse_1": ["cli": "c1"]]]
        let c = C.from(board: board, local: local, now: 1000) { cli in
            cli == "c1" ? .init(doing: "typing", summary: "app summary", told: .init(text: "go", minutesAgo: 2)) : nil
        }
        #expect(c.projects.map(\.name) == ["a"])
        let t = c.projects[0].threads
        #expect(t.map(\.id) == ["t1", "t2"])
        #expect(t[0].running && t[0].doing == "typing" && t[0].summary == "app summary" && t[0].told?.text == "go" && t[0].minutesIdle == 1)
        #expect(!t[1].running && t[1].waiting == [.init(kind: "needs", text: "pick one")] && t[1].lastAnswer == "done it" && t[1].minutesIdle == 10)
    }

    // MARK: The cascade

    @Test func jevAtSevenTenthsDecidesAndNamesTheThreadOnlyAtEight() async throws {
        for (p, thread) in [(0.75, nil), (0.85, "f1")] as [(Double, String?)] {
            let calls = Calls()
            let d = RouterProjectDecider(jev: Self.jev("Router redesign", p, calls: calls),
                                         sonnet: Self.sonnet(.init(action: "ask", project: "", session: "", confidence: 0), calls: calls))
            let out = try await d.decide("next", in: Self.context())
            #expect(out == RouterProjectDecision(kind: .project("fjord", thread: thread), confidence: p, decider: .jev))
            #expect(calls.jev == 1 && calls.sonnet == 0)
        }
    }

    @Test func jevsNewWorkAndProjectPicksAreTaken() async throws {
        let calls = Calls()
        let a = try await RouterProjectDecider(jev: Self.jev("new in silo", 0.9, calls: calls), sonnet: nil).decide("x", in: Self.context())
        #expect(a.kind == .newWork(project: "silo") && a.decider == .jev)
        let b = try await RouterProjectDecider(jev: Self.jev("claude_ai project silo", 0.7, calls: calls), sonnet: nil).decide("x", in: Self.context())
        #expect(b.kind == .project("silo", thread: nil) && b.target == .project("silo"))
    }

    @Test func underSevenTenthsAnIntentOrAFailureGoesToSonnet() async throws {
        let sure = RouterProjectSonnetAnswer(action: "follow_up", project: "silo", session: "s1", reason: "quota", confidence: 0.9)
        let failing: JevAsker = { _, _ in throw JevClient.Failure.transport("down") }
        let calls = Calls()
        for jev in [Self.jev("Router redesign", 0.69, calls: calls), Self.jev("question", 0.99, calls: calls), Self.jev("unclear", 0.9, calls: calls), failing] {
            var stages: [RouterProjectDecider.Stage] = []
            let out = try await RouterProjectDecider(jev: jev, sonnet: Self.sonnet(sure, calls: calls)).decide("quota?", in: Self.context()) { stages.append($0) }
            #expect(out == RouterProjectDecision(kind: .project("silo", thread: "s1"), confidence: 0.9, decider: .sonnet, reason: "quota"))
            #expect(stages == [.jev, .sonnet])
        }
        #expect(calls.sonnet == 4)
        #expect(calls.prompt.hasPrefix("Board:\n## fjord") && calls.prompt.hasSuffix("Message:\n<message>quota?</message>"))
    }

    @Test func sonnetsAnswersBecomeEachKind() {
        let d = RouterProjectDecider(jev: nil, sonnet: nil)
        let c = Self.context()
        func kind(_ action: String, _ project: String = "", _ session: String = "", _ p: Double = 0.9, _ alts: [String] = []) -> RouterProjectDecision.Kind {
            d.sonnetDecision(.init(action: action, project: project, session: session, confidence: p, alternatives: alts), context: c).kind
        }
        #expect(kind("follow_up", "fjord", "f2") == .project("fjord", thread: "f2"))
        #expect(kind("new_work", "silo") == .newWork(project: "silo"))
        #expect(kind("new_work", "garden planner") == .newProject(name: "garden planner"))
        #expect(kind("answer_here") == .answer)
        // Under 0.8, or an ask: asked, the best guess first, then the alternatives.
        #expect(kind("follow_up", "fjord", "f2", 0.79) == .ask([.project("fjord", thread: "f2")]))
        #expect(kind("new_work", "silo", "", 0.5) == .ask([.newWork(project: "silo")]))
        #expect(kind("answer_here", "", "", 0.6) == .ask([]))
        #expect(kind("ask", "fjord", "f1", 0.4, ["s1", "silo", "nowhere", "f1"]) == .ask([.project("fjord", thread: "f1"), .project("silo", thread: "s1"), .project("silo", thread: nil)]))
        // A follow-up of a thread that isn't on the board is never sent.
        #expect(kind("follow_up", "fjord", "ghost") == .ask([.project("fjord", thread: nil)]))
    }

    @Test func noSonnetOrAFailedOneAsks() async throws {
        let none = try await RouterProjectDecider(jev: nil, sonnet: nil).decide("x", in: Self.context())
        #expect(none == RouterProjectDecision(kind: .ask([]), confidence: 0, decider: .none))
        let broken: RouterProjectDecider.Sonnet = { _, _, _ in throw RouterTools.Failure("Claude Code wasn't found") }
        let failed = try await RouterProjectDecider(jev: nil, sonnet: broken).decide("x", in: Self.context())
        #expect(failed.kind == .ask([]) && failed.decider == .none && failed.reason == "Claude Code wasn't found")
    }

    @Test func cancellingStopsTheDecision() async {
        let slow: RouterProjectDecider.Sonnet = { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return .init(action: "answer_here", project: "", session: "", confidence: 1)
        }
        let task = Task { try await RouterProjectDecider(jev: nil, sonnet: slow).decide("x", in: Self.context()) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test func sonnetsTypedAnswerIsRead() {
        let a = RouterProjectSonnetAnswer(["action": "new_work", "project": "silo", "session": "", "reason": "r", "confidence": 0.85,
                                           "project_confidence": 0.9, "alternatives": ["fjord"], "need": []])
        #expect(a == .init(action: "new_work", project: "silo", session: "", reason: "r", confidence: 0.85, projectConfidence: 0.9, alternatives: ["fjord"]))
        #expect(RouterProjectSonnetAnswer(["project": "silo"]) == nil)
        #expect((try? JSONSerialization.jsonObject(with: Data(RouterProjectDecider.schema.utf8))) != nil)
    }
}
