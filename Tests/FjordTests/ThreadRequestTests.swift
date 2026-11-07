import Foundation
import Testing
@testable import Fjord

/// What a thread waits on you for, read from T3's projection, and how an answer is checked and encoded.
@MainActor
@Suite struct ThreadRequestTests {
    typealias F = T3Fixture

    private func projection(requests: [T3JSON] = [], items: [T3JSON] = [], plans: [T3JSON] = [], hasPlan: Bool = false) -> T3Projection {
        guard case .object(var top) = F.projection(), case .object(var body)? = top["projection"] else { fatalError() }
        body["runtimeRequests"] = .array(requests)
        body["turnItems"] = .array(items)
        body["plans"] = .array(plans)
        body["thread"] = F.thread("t1", status: "running", extra: ["hasActionableProposedPlan": .bool(hasPlan)])
        top["projection"] = .object(body)
        guard case .snapshot(_, let p) = T3ThreadItem(json: .object(top)) else { fatalError() }
        return p
    }

    private func request(_ id: String, kind: String = "user_input", status: String = "pending", capability: String = "live",
                         created: String = "2026-01-02T03:04:05.000Z") -> T3JSON {
        ["id": .string(id), "threadId": "t1", "kind": .string(kind), "status": .string(status), "createdAt": .string(created),
         "responseCapability": ["type": .string(capability), "supportsFeedback": true]]
    }

    private func question(_ id: String, multi: Bool = false, custom: Bool = false) -> T3JSON {
        F.item("q-\(id)", type: "user_input_request", ordinal: 2, status: "waiting", ["requestId": .string(id), "questions": [[
            "id": "Which colors?", "header": "Color", "question": "Which colors?", "multiSelect": .bool(multi), "allowCustomAnswer": .bool(custom),
            "options": [["label": "Red", "description": ""], ["label": "Green", "description": ""], ["label": "Blue", "description": ""]],
        ]]])
    }

    @Test func aPendingQuestionIsReadWithItsQuestionsAndOptions() throws {
        let r = try #require(ThreadRequest(projection(requests: [request("r1")], items: [question("r1")])))
        #expect(r.id == "r1" && r.live)
        #expect(r.questions.map(\.question) == ["Which colors?"] && r.questions[0].options.map(\.label) == ["Red", "Green", "Blue"])
    }

    @Test func aPermissionWithNoOptionsOffersT3sFixedDecisionsMinusCancel() throws {
        let item = F.item("a1", type: "approval_request", ordinal: 2, status: "waiting",
                          ["requestId": "r2", "requestKind": "command", "prompt": "echo hi > spike.txt"])
        let r = try #require(ThreadRequest(projection(requests: [request("r2", kind: "command")], items: [item])))
        guard case .approval(let kind, let prompt, let decisions) = r.body else { Issue.record("not a permission"); return }
        #expect(kind == "command" && prompt == "echo hi > spike.txt")
        #expect(decisions == [.accept, .acceptForSession, .acceptAlways, .decline])
    }

    @Test func aRetriedPermissionFollowsTheNewestPendingRequest() throws {
        func approval(_ id: String) -> T3JSON {
            F.item("a-\(id)", type: "approval_request", ordinal: 2, status: "waiting", ["requestId": .string(id), "requestKind": "command", "prompt": "make"])
        }
        let p = projection(requests: [request("old", kind: "command", status: "cancelled"), request("new", kind: "command", created: "2026-01-02T03:05:00.000Z")],
                           items: [approval("old"), approval("new")])
        #expect(ThreadRequest(p)?.id == "new")
    }

    @Test func aPlanComesFromTheProjectionWhenTheShellSaysItIsActionable() throws {
        let plan: T3JSON = ["id": "pl1", "threadId": "t1", "runId": "r1", "nodeId": "n1", "status": "proposed", "kind": "plan", "markdown": "# Ship it"]
        let r = try #require(ThreadRequest(projection(plans: [plan], hasPlan: true)))
        #expect(r.id == "pl1" && r.planMarkdown == "# Ship it")
        #expect(ThreadRequest(projection(plans: [plan], hasPlan: false)) == nil)
    }

    @Test func aRequestT3CantTakeAnAnswerForIsNotLive() throws {
        let r = try #require(ThreadRequest(projection(requests: [request("r1", capability: "not_resumable")], items: [question("r1")])))
        #expect(!r.live)
        #expect(ThreadRequest(projection()) == nil)
    }

    @Test func answersAreCheckedAgainstTheQuestions() throws {
        let q = T3Question(demo: "", "Which colors?", multiSelect: true, options: [("Red", ""), ("Green", "")])
        let r = ThreadRequest(id: "r", threadID: "t1", body: .question([q]))
        #expect(try r.validate([q.id: .many(["Red", "Green"])]) == [q.id: .many(["Red", "Green"])])
        #expect(throws: RequestFailure.incomplete) { try r.validate([:]) }
        #expect(throws: RequestFailure.unknownOption("Pink")) { try r.validate([q.id: .many(["Pink"])]) }
        let custom = T3Question(demo: "", "Name?", allowCustomAnswer: true, options: [("A", "")])
        #expect(try ThreadRequest(id: "r", threadID: "t1", body: .question([custom])).validate([custom.id: .one("Zed")]).count == 1)
    }

    @Test func aMultiSelectAnswerIsEncodedAsAnArrayOfValues() {
        let c = T3Command.respondAnswers(threadId: "t1", requestId: "r1", answers: ["Which colors?": .many(["Red", "Green"])])
        let p = c.payload(commandId: "c")
        #expect(p["type"]?.string == "runtime-request.respond" && p["requestId"]?.string == "r1")
        #expect(p["answers"]?["Which colors?"]?.array?.compactMap(\.string) == ["Red", "Green"])
        let d = T3Command.respondDecision(threadId: "t1", requestId: "r2", decision: .decline, feedback: "no").payload(commandId: "c")
        #expect(d["decision"]?.string == "decline" && d["feedback"]?.string == "no")
    }

    @Test func theBriefOffersRequestsFromT3ForEveryProviderTheSameWay() {
        let store = Store()
        store.persists = false
        // Fed the way a projection event feeds it: the request is read from the projection and kept by thread.
        let p = projection(requests: [request("r1")], items: [question("r1")])
        store.t3.store.seed(p, for: "t1")
        store.agents.enabled = true
        store.threadDetailChanged("t1")
        #expect(store.requests["t1"]?.id == "r1")
    }
}
