import Foundation
import Testing
@testable import Fjord

/// Your words to a thread (steer by default, queue on ⌥Return and for unattended messages), the context records the pills
/// travel as, and changing your mind about a queued or running message. All on synthetic threads and a stub sender.
@MainActor
@Suite struct ThreadSenderTests {
    typealias F = T3Fixture

    /// What the stub sender was given.
    @MainActor final class Sent {
        var commands: [(command: T3Command, id: String)] = []
        var failing: Error?
    }

    private func store(status: String = "running", provider: String = "claudeAgent", projection: T3Projection? = nil) -> (Store, Sent) {
        let s = Store.reading([F.shell("t1", status: status, extra: ["providerInstanceId": .string(provider)])])
        let sent = Sent()
        s.requestSender = { command, id in
            if let failing = sent.failing { throw failing }
            sent.commands.append((command, id))
        }
        if let projection { s.t3.store.seed(projection, for: "t1") }
        return (s, sent)
    }

    private func projection(runs: [T3JSON] = [], messages: [T3JSON] = [], sessions: [T3JSON] = [], status: String = "running") -> T3Projection {
        T3Projection(json: [
            "thread": F.thread("t1", status: .init(status)), "runs": .array(runs), "messages": .array(messages), "runtimeRequests": [],
            "plans": [], "turnItems": [], "providerSessions": .array(sessions), "updatedAt": "2026-01-02T03:04:05.000Z",
        ])
    }

    private func run(_ id: String, status: String, message: String, position: Int? = nil) -> T3JSON {
        ["id": .string(id), "threadId": "t1", "ordinal": 1, "status": .string(status), "userMessageId": .string(message),
         "queuePosition": position.map { .number(Double($0)) } ?? nil, "requestedAt": "2026-01-02T03:04:05.000Z"]
    }

    private func dispatchObject(_ sent: Sent, _ i: Int = 0) -> [String: T3JSON] {
        guard case .object(let o) = sent.commands[i].command.payload(commandId: sent.commands[i].id) else { return [:] }
        return o
    }

    // MARK: The plan

    @Test func aRunningThreadIsSteeredByDefaultAndQueuedOnRequest() {
        let steer = ThreadSender.plan(running: true, mode: .steer, steers: true, unattended: false)
        #expect(steer.dispatch == .startImmediately(intent: .steer) && steer.outcome == .steered && steer.note == nil)
        let queue = ThreadSender.plan(running: true, mode: .queue, steers: true, unattended: false)
        #expect(queue.dispatch == .queueAfterActive && queue.outcome == .queued && queue.note == nil)
    }

    @Test func anIdleThreadJustStarts() {
        let plan = ThreadSender.plan(running: false, mode: .steer, steers: true, unattended: false)
        #expect(plan.dispatch == .startImmediately(intent: .auto) && plan.outcome == .started)
    }

    @Test func anAgentThatCantSteerQueuesAndSaysSo() {
        let plan = ThreadSender.plan(running: true, mode: .steer, steers: false, unattended: false)
        #expect(plan.dispatch == .queueAfterActive && plan.outcome == .queued && plan.note?.hasPrefix("queued") == true)
    }

    @Test func anUnattendedMessageNeverSteers() {
        for steers in [true, false] {
            let busy = ThreadSender.plan(running: true, mode: .steer, steers: steers, unattended: true)
            #expect(busy.dispatch == .queueAfterActive && busy.outcome == .queued)
            #expect(ThreadSender.plan(running: false, mode: .steer, steers: steers, unattended: true).dispatch == .queueAfterActive)
        }
    }

    @Test func capabilitiesComeFromTheSessionAndByDriverUntilThereIsOne() {
        #expect(ThreadSender.steers(session: nil, driver: "claudeAgent") && ThreadSender.steers(session: nil, driver: "codex"))
        #expect(!ThreadSender.steers(session: nil, driver: "cursor") && !ThreadSender.steers(session: nil, driver: ""))
        var caps = T3ProviderSession.Capabilities(json: nil)
        #expect(!ThreadSender.steers(session: caps, driver: "claudeAgent"))
        caps.supportsActiveSteering = true
        #expect(ThreadSender.steers(session: caps, driver: "cursor"))
    }

    @Test func thePickLineSaysWhatReturnDoes() {
        #expect(ThreadSender.pickLine(title: "Fix login", running: false, steers: true) == ("send to Fix login", false))
        #expect(ThreadSender.pickLine(title: "Fix login", running: true, steers: true) == ("steer Fix login (running)", true))
        #expect(ThreadSender.pickLine(title: "Fix login", running: true, steers: false) == ("queue for Fix login (running)", false))
    }

    // MARK: Sending

    @Test func yourWordsSteerARunningThreadInOneDispatchWithTheirOwnCommandId() async throws {
        let (s, sent) = store()
        let message = ThreadMessage(text: "use postgres")
        let delivered = try await s.sendToThread("t1", message, mode: .steer)
        // The message, then the thread marked read (your words went there).
        #expect(sent.commands.count == 2 && sent.commands[0].id == message.commandID)
        #expect(dispatchObject(sent, 1)["type"] == "thread.visit" && dispatchObject(sent, 1)["threadId"] == "t1")
        let o = dispatchObject(sent)
        #expect(o["type"] == "message.dispatch" && o["threadId"] == "t1" && o["text"] == "use postgres")
        #expect(o["dispatchMode"] == ["type": "start_immediately"] && o["deliveryIntent"] == "steer")
        #expect(o["messageId"] == .string(message.messageID) && o["context"] == nil)
        #expect(delivered.outcome == .steered && delivered.thread == "t1" && delivered.messageID == message.messageID)
    }

    @Test func optionReturnQueuesAfterTheTurn() async throws {
        let (s, sent) = store()
        let delivered = try await s.sendToThread("t1", ThreadMessage(text: "later"), mode: .queue)
        #expect(dispatchObject(sent)["dispatchMode"] == ["type": "queue_after_active"] && dispatchObject(sent)["deliveryIntent"] == nil)
        #expect(delivered.outcome == .queued)
    }

    @Test func anActionsMessageQueuesEvenWhereYouWouldSteer() async throws {
        let (s, sent) = store()
        let delivered = try await s.sendToThread("t1", ThreadMessage(text: "CI failed"), mode: .steer, unattended: true)
        #expect(dispatchObject(sent)["dispatchMode"] == ["type": "queue_after_active"] && delivered.outcome == .queued)
        // An action's message isn't yours: the thread's read state is left alone.
        #expect(sent.commands.count == 1)
    }

    @Test func aThreadWhoseAgentCantSteerQueuesAndTheEntrySaysWhy() async throws {
        let (s, sent) = store(provider: "cursor")
        let delivered = try await s.sendToThread("t1", ThreadMessage(text: "hi"), mode: .steer)
        #expect(dispatchObject(sent)["dispatchMode"] == ["type": "queue_after_active"])
        #expect(delivered.outcome == .queued && delivered.note?.contains("can't take words") == true)
    }

    @Test func aSessionsOwnFlagsDecideOnceItHasAttached() async throws {
        let session: T3JSON = ["id": "ps1", "driver": "cursor", "status": "ready",
                               "capabilities": ["turns": ["supportsActiveSteering": true]]]
        let (s, sent) = store(provider: "cursor", projection: projection(sessions: [session]))
        _ = try await s.sendToThread("t1", ThreadMessage(text: "hi"), mode: .steer)
        #expect(dispatchObject(sent)["deliveryIntent"] == "steer")
    }

    @Test func aRetryOfTheSameMessageCarriesTheSameCommandId() async throws {
        let (s, sent) = store()
        let message = ThreadMessage(text: "go")
        sent.failing = T3Error(kind: .disconnected, message: "dropped")
        await #expect(throws: T3Error.self) { try await s.sendToThread("t1", message, mode: .steer) }
        sent.failing = nil
        _ = try await s.sendToThread("t1", message, mode: .steer)
        #expect(sent.commands.filter { if case .threadVisit = $0.command { false } else { true } }.map(\.id) == [message.commandID])
        #expect(ThreadMessage(text: "go").commandID != message.commandID)
    }

    @Test func aThreadThatIsGoneIsNotSentTo() async {
        let (s, sent) = store()
        await #expect(throws: ThreadSendFailure.self) { try await s.sendToThread("nope", ThreadMessage(text: "hi"), mode: .steer) }
        #expect(sent.commands.isEmpty)
    }

    @Test func aGateReasonRefusesTheDispatch() async {
        let (s, sent) = store()
        await #expect(throws: ThreadSendFailure.self) {
            try await s.sendToThread("t1", ThreadMessage(text: "hi"), mode: .steer) { "Stopped; nothing was sent" }
        }
        #expect(sent.commands.isEmpty)
    }

    // MARK: Pills as context records

    @Test func aCategoryPillTravelsAsARecordAndYourWordsStayAsTyped() throws {
        let (s, _) = store()
        s.categories = [InboxStore.ci]
        let id = InboxStore.ci.id
        let mention = RouterMention(range: 8..<11, pointer: .category(id), name: "CI")
        let words = try RouterPointers.threadMessage("look at @CI please", pills: [], mentions: [mention], store: s)
        #expect(words.words == "look at @CI please" && !words.rephrased)
        #expect(words.records.count == 1)
        guard case .object(let record) = words.records[0], case .string(let context)? = record["contextId"] else { Issue.record("no record"); return }
        #expect(words.text == "look at [@CI](t3-context://v1/fjord-category/\(context)) please")
        #expect(record["kind"] == "fjord-category" && record["version"] == 1 && record["label"] == "@CI")
        guard case .object(let payload)? = record["payload"] else { Issue.record("no payload"); return }
        #expect(payload["name"] == "CI")
    }

    @Test func theReferenceStaysWhereThePillIsAfterAddressingIsTakenOut() throws {
        let (s, _) = store()
        s.categories = [InboxStore.ci]
        let mention = RouterMention(range: 16..<19, pointer: .category(InboxStore.ci.id), name: "CI")
        let words = try RouterPointers.threadMessage("@lookout fix it @CI (@router no rush) now", pills: [0..<8], mentions: [mention], store: s)
        #expect(words.words == "fix it @CI now" && words.rephrased)
        #expect(words.text.hasPrefix("fix it [@CI](t3-context://v1/fjord-category/ctx_") && words.text.hasSuffix(") now"))
    }

    @Test func aPillTakenOutWithTheAddressingLeavesNoRecord() throws {
        let (s, _) = store()
        let mention = RouterMention(range: 0..<8, pointer: .category(InboxStore.ci.id), name: "lookout")
        let words = try RouterPointers.threadMessage("@lookout fix it", pills: [0..<8], mentions: [mention], store: s)
        #expect(words.text == "fix it" && words.records.isEmpty)
    }

    @Test func theRecordsRideTheDispatchAsContext() async throws {
        let (s, sent) = store()
        s.categories = [InboxStore.ci]
        let mention = RouterMention(range: 8..<11, pointer: .category(InboxStore.ci.id), name: "CI")
        let words = try RouterPointers.threadMessage("look at @CI please", pills: [], mentions: [mention], store: s)
        _ = try await s.sendToThread("t1", ThreadMessage(text: words.text, records: words.records), mode: .steer)
        guard case .object(let context)? = dispatchObject(sent)["context"] else { Issue.record("no context"); return }
        #expect(context["version"] == 1 && context["records"] == .array(words.records))
    }

    // MARK: Changing your mind

    private func entry(_ s: Store, outcome: ThreadSendOutcome, message: String = "um1") -> UUID {
        var d = RouterDecision(trigger: .you("later"), outcome: .done)
        d.delivered = RouterDecision.Delivered(thread: "t1", messageID: message, commandID: "c1", outcome: outcome, note: nil, at: Date())
        return s.logDecision(d)
    }

    @Test func aQueuedMessageCanBeCancelledAndItsEntryDropsIt() async throws {
        let p = projection(runs: [run("r1", status: "running", message: "other"), run("r2", status: "queued", message: "um1", position: 2)])
        let (s, sent) = store(projection: p)
        let id = entry(s, outcome: .queued)
        #expect(s.delivery(try #require(s.router.record(id)?.delivered)) == .queued(run: "r2", position: 2))
        #expect(s.changeOfMind(try #require(s.router.record(id))) == .cancelAndEdit(run: "r2"))
        let cancelled = await s.cancelQueued(id)
        #expect(cancelled)
        #expect(dispatchObject(sent)["type"] == "queued-run.cancel" && dispatchObject(sent)["runId"] == "r2")
        let after = try #require(s.router.record(id))
        #expect(after.delivered?.cancelled == .beforeStart && after.isCancelled && after.summary == "cancelled")
        #expect(s.changeOfMind(after) == .none)
    }

    @Test func aQueuedMessageCanBeEditedInPlace() async throws {
        let p = projection(runs: [run("r2", status: "queued", message: "um1", position: 1)])
        let (s, sent) = store(projection: p)
        let id = entry(s, outcome: .queued)
        let blank = await s.editQueued(id, to: "   ")
        #expect(!blank)
        let edited = await s.editQueued(id, to: " after the tests, please ")
        #expect(edited)
        #expect(dispatchObject(sent)["type"] == "queued-run.edit" && dispatchObject(sent)["text"] == "after the tests, please")
        #expect(s.router.record(id)?.delivered?.editedTo == "after the tests, please")
    }

    @Test func aSteeredMessageCantBeTakenBackButItsRunCanBeStopped() async throws {
        let p = projection(runs: [run("r1", status: "running", message: "um0")],
                           messages: [["id": "um1", "threadId": "t1", "runId": "r1", "role": "user", "createdBy": "user", "text": "now", "streaming": false]])
        let (s, sent) = store(projection: p)
        let id = entry(s, outcome: .steered)
        #expect(s.changeOfMind(try #require(s.router.record(id))) == .stop(run: "r1"))
        let cancelled = await s.cancelQueued(id), edited = await s.editQueued(id, to: "x")
        #expect(!cancelled && !edited)
        let stopped = await s.stopRun(id)
        #expect(stopped)
        let o = dispatchObject(sent)
        #expect(o["type"] == "run.interrupt" && o["runId"] == "r1" && o["holdQueue"] == true)
        #expect(s.router.record(id)?.delivered?.cancelled == .aborted)
    }

    @Test func aFinishedRunOffersNothing() throws {
        let p = projection(runs: [run("r1", status: "completed", message: "um1")], status: "completed")
        let (s, _) = store(status: "completed", projection: p)
        let id = entry(s, outcome: .started)
        #expect(s.changeOfMind(try #require(s.router.record(id))) == .none)
    }

    @Test func aStoppedThreadWithQueuedMessagesOffersToResume() async throws {
        let p = projection(runs: [run("r1", status: "interrupted", message: "um0"), run("r2", status: "queued", message: "um1", position: 1)],
                           status: "interrupted")
        let (s, sent) = store(status: "interrupted", projection: p)
        #expect(s.queueHeld("t1"))
        let resumed = await s.resumeQueue("t1")
        #expect(resumed)
        #expect(dispatchObject(sent)["type"] == "queue.resume")
    }

    @Test func aFailedCancelIsSaidOnTheEntry() async throws {
        let p = projection(runs: [run("r2", status: "queued", message: "um1", position: 1)])
        let (s, sent) = store(projection: p)
        sent.failing = T3Error(kind: .server, message: "Run is no longer queued")
        let id = entry(s, outcome: .queued)
        let cancelled = await s.cancelQueued(id)
        #expect(!cancelled)
        #expect(s.router.record(id)?.doneLines.last?.contains("couldn't cancel") == true)
    }

    @Test func anOldEntryWithAnotherDeliveryShapeStillReads() throws {
        var d = RouterDecision(trigger: .you("hi"), outcome: .done)
        d.delivered = RouterDecision.Delivered(thread: "t1", messageID: "m", commandID: "c", outcome: .started, note: nil, at: Date())
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as? [String: Any])
        json["delivered"] = ["session": "local_a", "cli": "x", "nonce": "n", "at": 0, "turns": 1, "busy": false, "abortable": true]
        let read = try JSONDecoder().decode(RouterDecision.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.delivered == nil && read.id == d.id)
    }
}
