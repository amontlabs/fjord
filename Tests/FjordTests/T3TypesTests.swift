import Foundation
import Testing
@testable import Fjord

@Suite("T3 types, framing, store and commands")
struct T3TypesTests {
    typealias F = T3Fixture

    // MARK: Framing

    @Test func framesRoundTrip() throws {
        let frames: [T3Frame] = [
            .request(id: "1", tag: "orchestration.subscribeShell", payload: [:]),
            .ack(requestId: "1"), .interrupt(requestId: "1"), .ping, .pong,
            .chunk(requestId: "1", values: [["kind": "synchronized"]]),
            .exit(requestId: "2", exit: ["_tag": "Success", "value": ["sequence": 9]]),
        ]
        for f in frames { #expect(T3Frame.decode(try f.encoded()) == [f]) }
    }

    @Test func requestFrameShape() throws {
        let text = try T3Frame.request(id: "1", tag: "orchestration.subscribeShell", payload: [:]).encoded()
        #expect(text == #"{"_tag":"Request","headers":[],"id":"1","payload":{},"tag":"orchestration.subscribeShell"}"#)
        #expect(try T3Frame.ack(requestId: "7").encoded() == #"{"_tag":"Ack","requestId":"7"}"#)
        #expect(try T3Frame.ping.encoded() == #"{"_tag":"Ping"}"#)
    }

    @Test func exitFailureIsTyped() {
        let exit = T3JSON.parse(#"{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"OrchestrationV2DispatchCommandError","commandId":"c","commandType":"message.dispatch","message":"Claude cannot redirect an active run.","detail":"d"}}]}"#)!
        guard case .failure(let e) = T3Frame.result(ofExit: exit) else { Issue.record("expected failure"); return }
        #expect(e.kind == .server)
        #expect(e.message == "Claude cannot redirect an active run.")
        #expect(e.detail == "d")
        #expect(e.commandType == "message.dispatch")
        let interrupt = T3JSON.parse(#"{"_tag":"Failure","cause":[{"_tag":"Interrupt","fiberId":3}]}"#)!
        guard case .failure(let i) = T3Frame.result(ofExit: interrupt) else { Issue.record("expected failure"); return }
        #expect(i.kind == .interrupted)
    }

    @Test func unknownFrameDecodes() {
        #expect(T3Frame.decode(#"{"_tag":"Mystery","x":1}"#).count == 1)
        #expect(T3Frame.decode("not json").isEmpty)
        #expect(T3Frame.decode(#"[{"_tag":"Ping"},{"_tag":"Pong"}]"#) == [.ping, .pong])
    }

    // MARK: Shell

    @Test func snapshotsMerge() {
        var s = T3ShellState()
        s.apply(T3ShellItem(json: F.snapshot(threads: [F.thread("a"), F.thread("b")], projects: [F.project("p1")], sequence: 10)))
        // The second chunk of the initial snapshot: projects only, no threads (S1 #10).
        s.apply(T3ShellItem(json: F.snapshot(threads: [], projects: [F.project("p2", title: "Shed")], sequence: 10)))
        #expect(s.threads.count == 2)
        #expect(s.projects.count == 2)
        #expect(s.sequence == 10)
    }

    @Test func updateRemoveAndArchive() {
        var s = T3ShellState()
        s.apply(T3ShellItem(json: F.snapshot(threads: [F.thread("a", status: "idle")])))
        s.apply(T3ShellItem(json: ["kind": "thread.updated", "sequence": 101, "location": "active", "thread": F.thread("a", title: "Renamed", status: "running")]))
        #expect(s.threads["a"]?.title == "Renamed")
        #expect(s.threads["a"]?.status == .running)
        #expect(s.threads["a"]?.isLive == true)
        s.apply(T3ShellItem(json: ["kind": "thread.removed", "sequence": 102, "location": "active", "threadId": "a"]))
        #expect(s.threads["a"] == nil)
        #expect(s.sequence == 102)
        s.apply(T3ShellItem(json: ["kind": "project.removed", "sequence": 103, "projectId": "p1"]))
        #expect(s.sequence == 103)
    }

    @Test func listedThreadsHideSubagentsAndArchived() {
        var s = T3ShellState()
        s.apply(T3ShellItem(json: F.snapshot(threads: [
            F.thread("top", updatedAt: "2026-01-02T00:00:00.000Z"),
            F.thread("sub", relationship: "subagent"),
            F.thread("fork", updatedAt: "2026-01-03T00:00:00.000Z", relationship: "fork"),
            F.thread("side", extra: ["lineage": ["relationshipToParent": nil, "rootThreadId": "side", "sideChat": true]]),
            F.thread("gone", extra: ["archivedAt": "2026-01-02T00:00:00.000Z"]),
        ])))
        #expect(s.listedThreads.map(\.id) == ["fork", "top"])
        #expect(s.threads["sub"]?.isListed == false)
    }

    @Test func needingYouAndUnseen() {
        var s = T3ShellState()
        s.apply(T3ShellItem(json: F.snapshot(threads: [
            F.thread("q", status: "running", pending: ["id": "req1", "kind": "command", "createdAt": "2026-01-02T03:04:05.000Z", "blocking": true]),
            F.thread("p", extra: ["hasActionableProposedPlan": true]),
            F.thread("async", pending: ["id": "req2", "kind": "user_input", "createdAt": "2026-01-02T03:04:05.000Z", "blocking": false]),
            F.thread("seen", lastVisitedAt: "2026-01-02T03:04:05.000Z"),
            F.thread("unseen", lastVisitedAt: "2026-01-02T03:04:04.999Z"),
        ])))
        #expect(Set(s.needingYou.map(\.id)) == ["q", "p"])
        #expect(s.threads["seen"]?.isUnseen == false)
        #expect(s.threads["unseen"]?.isUnseen == true)
        #expect(s.threads["q"]?.pendingRuntimeRequest?.kind == "command")
        #expect(s.statusCounts["running"] == 1)
    }

    @Test func unknownValuesAreKept() {
        let item = T3ShellItem(json: ["kind": "future.thing", "sequence": 5])
        #expect(item == .unknown(kind: "future.thing", raw: ["kind": "future.thing", "sequence": 5]))
        var s = T3ShellState()
        s.apply(item)
        #expect(s.threads.isEmpty)
        // An unknown status and runtime mode survive, and malformed fields fall back instead of failing.
        let t = T3ThreadShell(json: F.thread("x", status: "hibernating", extra: ["runtimeMode": "warp", "itemCount": "many", "pullRequests": 4]))
        #expect(t.status.rawValue == "hibernating")
        #expect(t.status.isLive == false)
        #expect(t.runtimeMode.rawValue == "warp")
        #expect(t.pullRequests.isEmpty)
        // Decodes through Codable from raw bytes too.
        let decoded = try? JSONDecoder().decode(T3ShellItem.self, from: Data(#"{"kind":"snapshot","snapshot":{"snapshotSequence":3,"threads":[{"id":"z","status":7}]}}"#.utf8))
        guard case .snapshot(let snap)? = decoded else { Issue.record("snapshot didn't decode"); return }
        #expect(snap.threads.first?.id == "z")
    }

    // MARK: Thread projection

    @Test func projectionDecodes() {
        guard case .snapshot(let seq, let p) = T3ThreadItem(json: F.projection()) else { Issue.record("not a snapshot"); return }
        #expect(seq == 500)
        #expect(p.thread.id == "t1")
        #expect(p.runs.count == 1)
        #expect(p.messages.first?.text == "Please sort the seed packets.")
        #expect(p.turnItems.first?.detail == .userMessage(messageId: "um1", text: "Please sort the seed packets."))
        #expect(p.others["attempts"]?.count == 1)
        #expect(p.capabilities == nil)
    }

    private func projection() -> T3Projection {
        guard case .snapshot(_, let p) = T3ThreadItem(json: F.projection()) else { fatalError() }
        return p
    }
    private func apply(_ p: inout T3Projection, _ ev: T3JSON) {
        guard case .event(let e) = T3ThreadItem(json: ev) else { Issue.record("not an event"); return }
        p.apply(e)
    }

    @Test func reducerUpsertsRunsMessagesAndItems() {
        var p = projection()
        apply(&p, F.event("run.updated", 501, payload: F.run("r1", status: "waiting")))
        #expect(p.runs.count == 1 && p.runs[0].status == .waiting)
        apply(&p, F.event("run.created", 502, payload: F.run("r2", status: "queued", queuePosition: 1)))
        #expect(p.queuedRuns.map(\.id) == ["r2"])
        apply(&p, F.event("message.updated", 503, payload: F.message("am1", role: "assistant", text: "Sorted into four piles.")))
        #expect(p.messages.count == 2)
        apply(&p, F.event("message.updated", 504, payload: F.message("am1", role: "assistant", text: "Sorted into five piles.")))
        #expect(p.messages.count == 2 && p.messages[1].text == "Sorted into five piles.")
        apply(&p, F.event("turn-item.updated", 505, payload: F.item("i2", type: "command_execution", ordinal: 3, status: "running", ["input": "ls seeds", "output": "a\nb"])))
        apply(&p, F.event("turn-item.updated", 506, payload: F.item("i0", type: "reasoning", ordinal: 2, ["text": "thinking", "streaming": false])))
        #expect(p.turnItems.map(\.id) == ["i1", "i0", "i2"])  // ordered by ordinal
        apply(&p, F.event("turn-item.updated", 507, payload: F.item("i2", type: "command_execution", ordinal: 3, ["input": "ls seeds", "exitCode": 0])))
        #expect(p.turnItems.count == 3)
        #expect(p.turnItems[2].detail == .commandExecution(input: "ls seeds", output: nil, exitCode: 0))
        #expect(p.updatedAt?.text == "2026-01-02T03:04:07.000Z")
    }

    @Test func reducerQuestionApprovalPlanAndRequests() {
        var p = projection()
        apply(&p, F.event("runtime-request.updated", 510, payload: ["id": "rq1", "nodeId": "n1", "kind": "user_input", "status": "pending",
                                                                    "responseCapability": ["type": "live", "providerSessionId": "s1"], "createdAt": "2026-01-02T03:04:05.000Z", "resolvedAt": nil]))
        #expect(p.pendingRequests.map(\.id) == ["rq1"] && p.pendingRequests[0].isLive)
        let q: T3JSON = [["id": "Which two colors?", "header": "Colors", "question": "Which two colors?", "multiSelect": true,
                          "options": [["label": "Red", "description": "red"], ["label": "Blue", "description": "blue"]]]]
        apply(&p, F.event("turn-item.updated", 511, payload: F.item("i3", type: "user_input_request", ordinal: 4, status: "waiting", ["requestId": "rq1", "questions": q])))
        guard case .userInputRequest(let rid, let qs) = p.turnItems.last!.detail else { Issue.record("not a question"); return }
        #expect(rid == "rq1" && qs[0].multiSelect && qs[0].options.map(\.value) == ["Red", "Blue"])
        apply(&p, F.event("turn-item.updated", 512, payload: F.item("i4", type: "approval_request", ordinal: 5, status: "waiting", ["requestId": "rq2", "requestKind": "command", "prompt": "touch notes.txt"])))
        guard case .approvalRequest(_, let kind, let prompt, _, let options) = p.turnItems.last!.detail else { Issue.record("not an approval"); return }
        #expect(kind == "command" && prompt == "touch notes.txt" && options.isEmpty)  // Claude sends no options: use T3Decision.fallbackList
        apply(&p, F.event("turn-item.updated", 513, payload: F.item("i5", type: "proposed_plan", ordinal: 6, ["planId": "pl1", "markdown": "1. Dig", "streaming": false])))
        apply(&p, F.event("plan.updated", 514, payload: ["id": "pl1", "status": "active", "kind": "proposed_plan", "markdown": "1. Dig"]))
        #expect(p.plans.first?.markdown == "1. Dig")
        apply(&p, F.event("turn-item.updated", 515, payload: F.item("i6", type: "todo_list", ordinal: 7, ["planId": "pl2", "steps": [["id": "s1", "text": "Water", "status": "running"]]])))
        #expect(p.turnItems.last!.detail == .todoList(planId: "pl2", steps: [T3TodoStep(json: ["id": "s1", "text": "Water", "status": "running"])]))
        apply(&p, F.event("turn-item.updated", 516, payload: F.item("i7", type: "file_change", ordinal: 8, ["fileName": "beds.md", "additions": 3, "deletions": 1])))
        #expect(p.turnItems.last!.detail == .fileChange(fileName: "beds.md", additions: 3, deletions: 1))
    }

    @Test func reducerThreadEventsCapabilitiesAndUnknowns() {
        var p = projection()
        apply(&p, F.event("provider-session.attached", 520, payload: ["id": "s1", "driver": "claudeAgent", "status": "ready",
            "capabilities": ["turns": ["supportsInterrupt": true, "supportsActiveSteering": true, "activeSteeringInterruptsTools": true, "supportsQueuedMessages": true],
                             "planning": ["supportsStructuredQuestions": true], "sessions": ["pendingRequestsSurviveRestart": false]]]))
        #expect(p.capabilities?.supportsActiveSteering == true && p.capabilities?.supportsStructuredQuestions == true)
        apply(&p, F.event("provider-session.detached", 521, payload: ["providerSessionId": "s1", "reason": "Runtime mode changed."]))
        #expect(p.capabilities == nil)
        p.updatedAt = T3Timestamp("2026-01-01T00:00:00.000Z")
        let before = p.updatedAt
        apply(&p, F.event("thread.visited", 522, payload: F.thread("t1", status: "running", lastVisitedAt: "2026-01-02T04:00:00.000Z")))
        #expect(p.thread.lastVisitedAt?.text == "2026-01-02T04:00:00.000Z" && p.updatedAt == before)  // not activity
        apply(&p, F.event("thread.runtime-mode-updated", 523, payload: F.thread("t1", status: "running", extra: ["runtimeMode": "approval-required"])))
        #expect(p.thread.runtimeMode == .approvalRequired && p.updatedAt != before)
        apply(&p, F.event("node.updated", 524, payload: ["id": "n1", "status": "running"]))
        #expect(p.others["nodes"]?.count == 1)
        let snapshot = p
        apply(&p, F.event("something.from.the.future", 525, payload: ["x": 1]))
        #expect(p == snapshot)
        guard case .event(let e) = T3ThreadItem(json: F.event("something.from.the.future", 525, payload: ["x": 1])) else { Issue.record("dropped"); return }
        #expect(e.sequence == 525 && e.type == "something.from.the.future")  // still advances the cursor
        apply(&p, F.event("message.updated", 526, payload: F.message("zz", text: "other thread"), thread: "other"))
        #expect(p.messages.count == 1)
        guard case .unknown(let k, _) = T3ThreadItem(json: ["kind": "novel"]) else { Issue.record("expected unknown"); return }
        #expect(k == "novel")
    }

    @Test func omittedBodiesAreRestoredFromMessages() {
        var p = projection()
        apply(&p, F.event("message.updated", 530, payload: F.message("am9", role: "assistant", text: "The beds are done.")))
        apply(&p, F.event("turn-item.updated", 531, payload: F.item("i9", type: "assistant_message", ordinal: 9, ["messageId": "am9", "text": "", "textOmitted": true, "streaming": false])))
        #expect(p.turnItems.last!.detail == .assistantMessage(messageId: "am9", text: "The beds are done.", streaming: false))
    }

    // MARK: Commands (exact shapes from S1)

    private func payload(_ c: T3Command) -> T3JSON { c.payload(commandId: "c1") }

    @Test func messageDispatchSteer() {
        #expect(payload(.messageDispatch(threadId: "t1", messageId: "m1", text: "Use the blue pots", dispatch: .startImmediately(intent: .steer))) == [
            "commandId": "c1", "type": "message.dispatch", "threadId": "t1", "messageId": "m1", "text": "Use the blue pots", "attachments": [],
            "createdBy": "user", "creationSource": "mcp", "dispatchMode": ["type": "start_immediately"], "deliveryIntent": "steer"])
    }

    @Test func messageDispatchQueueSteerActiveAndPlan() {
        let q = payload(.messageDispatch(threadId: "t1", messageId: "m1", text: "Later", dispatch: .queueAfterActive))
        #expect(q["dispatchMode"] == ["type": "queue_after_active"])
        #expect(q["deliveryIntent"] == nil)
        let s = payload(.messageDispatch(threadId: "t1", messageId: "m1", text: "Now", dispatch: .steerActive(targetRunId: "r9")))
        #expect(s["dispatchMode"] == ["type": "steer_active", "targetRunId": "r9"])
        let plan = payload(.messageDispatch(threadId: "t1", messageId: "m1", text: "PLEASE IMPLEMENT THIS PLAN:\n1. Dig", dispatch: .startImmediately(intent: .auto), sourcePlan: ("t1", "pl1")))
        #expect(plan["sourcePlanRef"] == ["threadId": "t1", "planId": "pl1"])
        #expect(plan["deliveryIntent"] == "auto")
    }

    @Test func respondShapes() {
        #expect(payload(.respondDecision(threadId: "t1", requestId: "rq", decision: .decline, feedback: "Not now")) == [
            "commandId": "c1", "type": "runtime-request.respond", "threadId": "t1", "requestId": "rq", "decision": "decline", "feedback": "Not now"])
        #expect(payload(.respondDecision(threadId: "t1", requestId: "rq", decision: .accept))["feedback"] == nil)
        #expect(payload(.respondAnswers(threadId: "t1", requestId: "rq", answers: ["Which two colors?": .many(["Red", "Green"]), "Name?": .one("Fern")])) == [
            "commandId": "c1", "type": "runtime-request.respond", "threadId": "t1", "requestId": "rq",
            "answers": ["Which two colors?": ["Red", "Green"], "Name?": "Fern"]])
    }

    @Test func queueAndRunControlShapes() {
        #expect(payload(.runInterrupt(threadId: "t1", runId: "r1", reason: "stop", holdQueue: true)) == [
            "commandId": "c1", "type": "run.interrupt", "threadId": "t1", "runId": "r1", "reason": "stop", "holdQueue": true])
        #expect(payload(.runInterrupt(threadId: "t1", runId: "r1")) == ["commandId": "c1", "type": "run.interrupt", "threadId": "t1", "runId": "r1"])
        #expect(payload(.queuedRunCancel(threadId: "t1", runId: "r2")) == ["commandId": "c1", "type": "queued-run.cancel", "threadId": "t1", "runId": "r2"])
        #expect(payload(.queuedRunEdit(threadId: "t1", runId: "r2", text: "EDITED")) == ["commandId": "c1", "type": "queued-run.edit", "threadId": "t1", "runId": "r2", "text": "EDITED"])
        #expect(payload(.queueResume(threadId: "t1")) == ["commandId": "c1", "type": "queue.resume", "threadId": "t1"])
    }

    @Test func threadCommandShapes() {
        #expect(payload(.threadVisit(threadId: "t1", visitedAt: T3Timestamp("2026-01-02T03:04:05.000Z"))) == [
            "commandId": "c1", "type": "thread.visit", "threadId": "t1", "visitedAt": "2026-01-02T03:04:05.000Z"])
        #expect(payload(.threadVisit(threadId: "t1", visitedAt: T3Timestamp("2026-01-02T03:04:05.000Z"), opened: true))["opened"] == true)
        #expect(payload(.threadArchive(threadId: "t1")) == ["commandId": "c1", "type": "thread.archive", "threadId": "t1"])
        #expect(payload(.threadUnarchive(threadId: "t1"))["type"] == "thread.unarchive")
        #expect(payload(.threadMarkUnread(threadId: "t1"))["type"] == "thread.mark-unread")
        #expect(payload(.runtimeModeSet(threadId: "t1", mode: .autoAcceptEdits)) == ["commandId": "c1", "type": "thread.runtime-mode.set", "threadId": "t1", "runtimeMode": "auto-accept-edits"])
        #expect(payload(.interactionModeSet(threadId: "t1", mode: .default)) == ["commandId": "c1", "type": "thread.interaction-mode.set", "threadId": "t1", "interactionMode": "default"])
        #expect(payload(.tagSet(threadId: "t1", tag: "garden", tagged: true)) == ["commandId": "c1", "type": "thread.tag.set", "threadId": "t1", "tag": "garden", "tagged": true])
        #expect(payload(.snooze(threadId: "t1", until: T3Timestamp("2026-01-03T00:00:00.000Z"))) == ["commandId": "c1", "type": "thread.snooze", "threadId": "t1", "snoozedUntil": "2026-01-03T00:00:00.000Z"])
        #expect(payload(.unsnooze(threadId: "t1")) == ["commandId": "c1", "type": "thread.unsnooze", "threadId": "t1", "reason": "user"])
    }

    @Test func launchThreadShape() {
        let c = T3Command.launchThread(T3LaunchRequest(threadId: "t9", projectId: "p1", title: "Plant the beans", instanceId: "claudeAgent", model: "claude-haiku-5-5",
                                                       messageId: "m9", text: "Plant beans in row two"))
        #expect(c.rpcTag == "orchestration.launchThread")
        #expect(T3Command.threadArchive(threadId: "t1").rpcTag == "orchestration.dispatchCommand")
        #expect(payload(c) == [
            "commandId": "c1", "creationSource": "mcp", "threadId": "t9", "projectId": "p1", "title": "Plant the beans", "generateTitle": false,
            "modelSelection": ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"], "runtimeMode": "full-access", "interactionMode": "default",
            "workspaceStrategy": ["type": "root"],
            "initialMessage": ["messageId": "m9", "text": "Plant beans in row two", "attachments": []]])
    }

    @Test func dispatchPayloadIsTheCommandItself() throws {
        // S1 #1: the request payload is the command, not {command: …}.
        let text = try T3Frame.request(id: "5", tag: "orchestration.dispatchCommand", payload: payload(.threadVisit(threadId: "t1", visitedAt: T3Timestamp("2026-01-02T03:04:05.000Z")))).encoded()
        #expect(text == #"{"_tag":"Request","headers":[],"id":"5","payload":{"commandId":"c1","threadId":"t1","type":"thread.visit","visitedAt":"2026-01-02T03:04:05.000Z"},"tag":"orchestration.dispatchCommand"}"#)
    }

    @Test func timestampsOrderAndParse() {
        #expect(T3Timestamp("2026-01-02T03:04:05.000Z") < T3Timestamp("2026-01-02T03:04:05.001Z"))
        #expect(T3Timestamp("2026-01-02T03:04:05.000Z").date != nil)
        #expect(T3Timestamp("garbage").date == nil)
        #expect(T3Timestamp(date: Date(timeIntervalSince1970: 0)).text == "1970-01-01T00:00:00.000Z")
    }

    @Test func discoveryReadsRuntimeFile() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("t3-runtime-\(UUID().uuidString).json")
        try Data(#"{"origin":"http://127.0.0.1:4999","port":4999,"pid":1}"#.utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(T3Discovery.origin(runtimeFile: f)?.absoluteString == "http://127.0.0.1:4999")
        #expect(T3Discovery.origin(runtimeFile: f.appendingPathExtension("missing")) == nil)
    }
}
