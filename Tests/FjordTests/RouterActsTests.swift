import Foundation
import Testing
@testable import Fjord

/// The Router v2 page's acts on T3 (`RouterActs`): what each kind of send becomes, what the records hear and when, a refusal,
/// and the acts with a Revert. Recording fakes for the first half; a `Store` with a stub sender for the real environment.
/// Nothing reaches a T3.
@MainActor
@Suite(.serialized) struct RouterActsTests {
    typealias F = T3Fixture

    /// Records and environment in one: what the acts did, in order.
    @MainActor final class Fake: RouterActsRecords {
        var log: [String] = []
        var began: [RouterActs.Send] = [], ended: [RouterActs.Send] = [], took: [RouterActs.Send] = []
        var hidden: [(String, Bool)] = [], marked: [(String, Bool)] = [], seen: [String] = []
        var submitted: [(text: String, context: RouterContext)] = []
        var entry: UUID? = UUID()
        var request: ThreadRequest?
        var performed: [ThreadAnswers.Answer] = []
        var performResult: Result<Void, Error> = .success(())
        var continued: [String] = []
        var continueFails: Error?
        var commands: [T3Command] = []
        var queuedRun: String? = "run-q"
        /// Queued runs by the words they carry.
        var queuedRuns: [String: String] = [:]
        var cancelled: [(String, String?, Bool)] = []
        var stopped: [String] = []
        var acted: [(act: BriefAction, thread: String, detail: String, title: String)] = []
        var holds: [@MainActor (Bool) -> Void] = []
        var refusals: [@MainActor (String) -> Void] = []
        var changeID: UUID? = UUID()
        var reverted: [UUID] = []
        var opened: [String] = []
        var emitted: [RouterChange] = []
        var away = false

        func began(send: RouterActs.Send) { log.append("began"); began.append(send) }
        func ended(send: RouterActs.Send) { log.append("ended"); ended.append(send) }
        func took(send: RouterActs.Send) { took.append(send) }
        func hide(_ thread: String, on: Bool) { hidden.append((thread, on)) }
        func notForMe(_ thread: String, on: Bool) { marked.append((thread, on)) }
        func seen(_ thread: String) { seen.append(thread) }
        func cancelledQueue(_ thread: String, run: String?, on: Bool) { cancelled.append((thread, run, on)) }

        func acts() -> RouterActs {
            let env = RouterActs.Environment(
                submit: { [self] text, context in
                    log.append("submit")
                    submitted.append((text, context))
                    return entry
                },
                request: { [self] _ in request },
                perform: { [self] answer, _, _ in
                    performed.append(answer)
                    return performResult
                },
                continueThread: { [self] id in
                    continued.append(id)
                    if let continueFails { throw continueFails }
                },
                dispatch: { [self] command in commands.append(command) },
                queuedRun: { [self] _, words in queuedRuns[words] ?? (words.isEmpty ? queuedRun : nil) },
                stop: { [self] id in stopped.append(id); return true },
                act: { [self] act, thread, detail, title, hold, refused in
                    acted.append((act, thread, detail, title))
                    hold(true)
                    holds.append(hold)
                    refusals.append(refused)
                    return changeID
                },
                revert: { [self] id in reverted.append(id) },
                open: { [self] id in opened.append(id); return true },
                projectID: { name in ["Garden": "p1", "p1": "p1"][name] },
                away: { [self] in away },
                title: { $0 == "t1" ? "Fix the fence" : "thread" },
                now: { Date(timeIntervalSince1970: 1_800_000_000) })
            let acts = RouterActs(env: env, records: self, emit: { [self] in emitted.append($0) })
            return acts
        }
    }

    private func out(_ thread: String = "t1", _ words: String = "use postgres", kind: RouterOutgoing.Kind = .words,
                     steering: Bool = false, queue: Bool = false, read: RouterRead? = nil) -> RouterOutgoing {
        RouterOutgoing(thread: thread, words: words, kind: kind, steering: steering, queue: queue, read: read)
    }

    private func question(_ options: [String], id: String = "q1", custom: Bool = false, multi: Bool = false) -> T3Question {
        T3Question(demo: "Header", "Which one?", id: id, multiSelect: multi, allowCustomAnswer: custom, options: options.map { ($0, "") })
    }

    private func request(_ body: ThreadRequest.Body, feedback: Bool = true) -> ThreadRequest {
        ThreadRequest(id: "req-1", threadID: "t1", body: body, live: true, supportsFeedback: feedback)
    }

    // MARK: Sends

    @Test func anIdleSendIsRecordedBeforeItIsSubmittedAndGoesToItsThreadByTheDispatcher() {
        let f = Fake()
        let acts = f.acts()
        acts.send(out())
        #expect(f.log == ["began", "submit"])
        #expect(f.began.first == RouterActs.Send(thread: "t1", words: "use postgres", kind: .words, at: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(f.submitted.first?.text == "use postgres")
        #expect(f.submitted.first?.context.target == "t3-thread:t1" && f.submitted.first?.context.queue == false)
    }

    @Test func aSteerAndAQueueAreToldApartForTheRecordsAndTheDispatcher() {
        let f = Fake()
        let acts = f.acts()
        acts.send(out(steering: true))
        acts.send(out(queue: true))
        #expect(f.began.map(\.kind) == [.steer, .queue])
        #expect(f.submitted.map(\.context.queue) == [false, true])
    }

    @Test func theDispatchersWordEndsOrKeepsThePendingSend() {
        let f = Fake()
        let acts = f.acts()
        let first = UUID(), second = UUID()
        f.entry = first
        acts.send(out("t1", "one"))
        f.entry = second
        acts.send(out("t2", "two"))
        acts.sendEvent(first, .taken)
        acts.sendEvent(second, .refused(reason: "T3 is away", offline: true))
        #expect(f.took.map(\.thread) == ["t1"] && f.ended.map(\.thread) == ["t2"])
        #expect(f.emitted == [.refused("t2", reason: "T3 is away", offline: true)])
        // The word of an entry is heard once.
        acts.sendEvent(first, .refused(reason: "late", offline: false))
        #expect(f.ended.count == 1 && f.emitted.count == 1)
    }

    @Test func aRouterThatIsOffRefusesAtOnceAndEndsThePendingSend() {
        let f = Fake()
        f.entry = nil
        f.away = true
        let acts = f.acts()
        acts.send(out())
        #expect(f.log == ["began", "submit", "ended"])
        #expect(f.emitted.count == 1)
        guard case .refused("t1", let reason, let offline)? = f.emitted.first else { Issue.record("no refusal"); return }
        #expect(reason.contains("Router is off") && offline)
    }

    @Test func theRowsDecisionForTheSameWordsTravelsWithTheSend() {
        let f = Fake()
        let acts = f.acts()
        let decision = RouterProjectDecision(kind: .thread("t1"), confidence: 0.95, decider: .jev)
        acts.decision = { $0 == "use postgres" ? decision : nil }
        acts.send(out(read: RouterRead(draft: "use postgres", places: [], sure: true)))
        acts.send(out(read: RouterRead(draft: "other words", places: [], sure: true)))
        #expect(f.submitted.map(\.context.decided) == [decision, nil])
    }

    // MARK: Answers

    @Test func aPickedOptionAnswersTheQuestionWithItsValueAndIsTakenWhenT3Says() async {
        let f = Fake()
        f.request = request(.question([question(["Postgres", "SQLite"])]))
        let acts = f.acts()
        acts.send(out("t1", "SQLite", kind: .answer(picks: [0: 2], typed: [:])))
        #expect(f.log == ["began"] && f.submitted.isEmpty)
        await waitUntil { !f.took.isEmpty }
        #expect(f.performed == [.answers(["q1": .one("SQLite")])])
        #expect(f.began.first?.kind == .answer)
    }

    @Test func aFormTakesEachQuestionsPickAndTypedWordsInPlaceOfAnOption() async {
        let f = Fake()
        f.request = request(.question([question(["a", "b"], id: "q1"), question(["c", "d"], id: "q2", custom: true)]))
        let acts = f.acts()
        // Option numbers run through the card: the second question's options are 3 and 4.
        acts.send(out(kind: .answer(picks: [0: 1, 1: 4], typed: [:])))
        acts.send(out(kind: .answer(picks: [0: 2], typed: [1: "  something else "])))
        await waitUntil { f.took.count == 2 }
        #expect(f.performed == [.answers(["q1": .one("a"), "q2": .one("d")]), .answers(["q1": .one("b"), "q2": .one("something else")])])
    }

    @Test func aFormMissingAnAnswerIsRefusedWithNothingSent() {
        let f = Fake()
        f.request = request(.question([question(["a", "b"], id: "q1"), question(["c", "d"], id: "q2")]))
        let acts = f.acts()
        acts.send(out(kind: .answer(picks: [0: 1], typed: [:])))
        #expect(f.performed.isEmpty && f.ended.count == 1)
        #expect(f.emitted == [.refused("t1", reason: RequestFailure.incomplete.errorDescription!, offline: false)])
    }

    @Test func aPermissionsButtonIsItsDecisionAndTypedWordsAreADeclineNeverAYes() async {
        let f = Fake()
        f.request = request(.approval(kind: "command", prompt: "rm -rf build", decisions: [.accept, .decline]))
        let acts = f.acts()
        acts.send(out(kind: .answer(picks: [0: 1], typed: [:])))
        acts.send(out(kind: .answer(picks: [:], typed: [0: "not that, use the cache"])))
        await waitUntil { f.took.count == 2 }
        #expect(f.performed == [.decision(.accept, feedback: nil), .decision(.decline, feedback: "not that, use the cache")])
    }

    @Test func aPermissionThatTakesNoWordsRefusesTypedWords() {
        let f = Fake()
        f.request = request(.approval(kind: "command", prompt: "x", decisions: [.accept, .decline]), feedback: false)
        let acts = f.acts()
        acts.send(out(kind: .answer(picks: [:], typed: [0: "no"])))
        #expect(f.performed.isEmpty && f.emitted == [.refused("t1", reason: RequestFailure.noFeedback.errorDescription!, offline: false)])
    }

    @Test func aPlansTwoOptionsSetTheModeThenImplementAndWordsSendItBack() async {
        let f = Fake()
        f.request = request(.plan(markdown: "1. do it"))
        let acts = f.acts()
        acts.send(out(kind: .answer(picks: [0: 1], typed: [:])))
        acts.send(out(kind: .answer(picks: [0: 2], typed: [:])))
        acts.send(out(kind: .answer(picks: [:], typed: [0: "split step 2"])))
        await waitUntil { f.took.count == 3 }
        #expect(f.performed == [.implement(.autoAcceptEdits), .implement(.approvalRequired), .sendBack("split step 2")])
    }

    @Test func anAnswerOnARequestTheThreadNoLongerHoldsIsRefused() {
        let f = Fake()
        f.request = nil
        let acts = f.acts()
        acts.send(out(kind: .answer(picks: [0: 1], typed: [:])))
        #expect(f.performed.isEmpty && f.ended.count == 1 && f.emitted.count == 1)
    }

    @Test func anAnswerT3RefusesEndsThePendingSendWithItsWords() async {
        let f = Fake()
        f.request = request(.question([question(["a"])]))
        f.performResult = .failure(RequestFailure.moved)
        let acts = f.acts()
        acts.send(out(kind: .answer(picks: [0: 1], typed: [:])))
        await waitUntil { !f.emitted.isEmpty }
        #expect(f.ended.count == 1 && f.took.isEmpty)
        #expect(f.emitted == [.refused("t1", reason: RequestFailure.moved.errorDescription!, offline: false)])
    }

    @Test func resolvingReadsTheMultipleChoiceAsAList() throws {
        let r = request(.question([question(["a", "b"], multi: true)]))
        #expect(try ThreadAnswers.resolve(r, picks: [0: 2], typed: [:]) == .answers(["q1": .many(["b"])]))
        #expect(throws: RequestFailure.self) { try ThreadAnswers.resolve(r, picks: [0: 5], typed: [:]) }
        #expect(throws: RequestFailure.self) { try ThreadAnswers.resolve(r, picks: [:], typed: [0: "free words"]) }
    }

    // MARK: Continue, Stop, the rest

    @Test func continueIsAMessageOfItsOwnAndAFailureEndsIt() async {
        let f = Fake()
        let acts = f.acts()
        acts.send(out("t1", "Continue where you left off.", kind: .continuing))
        await waitUntil { !f.took.isEmpty }
        #expect(f.continued == ["t1"] && f.submitted.isEmpty && f.began.first?.kind == .continuing)
        f.continueFails = ThreadSendFailure("T3 said no")
        acts.send(out("t2", "Continue where you left off.", kind: .continuing))
        await waitUntil { !f.emitted.isEmpty }
        #expect(f.ended.map(\.thread) == ["t2"] && f.emitted == [.refused("t2", reason: "T3 said no", offline: false)])
    }

    @Test func stopVisitOpenAndCancelGoToT3() async {
        let f = Fake()
        let acts = f.acts()
        acts.stop("t1")
        acts.visit("t1")
        acts.open("t2")
        acts.cancelQueued("t1")
        #expect(f.seen == ["t1"] && f.opened == ["t2"])
        await waitUntil { f.stopped == ["t1"] && f.commands.count == 2 }
        let types = f.commands.map { $0.payload(commandId: "c").str("type") }
        #expect(types == ["thread.visit", "queued-run.cancel"])
        #expect(f.commands[1].payload(commandId: "c").str("runId") == "run-q")
    }

    @Test func cancellingWithNothingQueuedSendsNothing() async {
        let f = Fake()
        f.queuedRun = nil
        let acts = f.acts()
        acts.cancelQueued("t1")
        #expect(f.commands.isEmpty)
    }

    @Test func cancelTakesBackTheRunCarryingTheWordsOnceT3ListsItAndSaysSoWhenT3KeepsIt() async {
        let f = Fake()
        f.queuedRun = "run-subagent"
        let acts = f.acts()
        acts.send(out("t1", "and add tests", queue: true))
        // Cancel before T3 lists the run: nothing cancelled yet, the row hidden, nothing else touched.
        acts.cancelQueued("t1")
        #expect(f.commands.isEmpty)
        #expect(f.cancelled.map(\.1) == [nil])
        // T3 lists it, behind a subagent's completion: the run with these words is the one cancelled.
        f.queuedRuns["and add tests"] = "run-mine"
        acts.threadChanged("t1")
        await waitUntil { f.commands.count == 1 }
        #expect(f.commands[0].payload(commandId: "c").str("runId") == "run-mine")
        #expect(f.cancelled.last.map { $0.1 == "run-mine" && $0.2 } == true)
        // Once only.
        acts.threadChanged("t1")
        #expect(f.commands.count == 1)
    }

    @Test func aCancelT3RefusesShowsTheRowAgainAndSaysSo() async {
        let f = Fake()
        f.queuedRuns["and add tests"] = "run-mine"
        var refuses = true
        let acts = f.acts()
        acts.env.dispatch = { _ in if refuses { throw ThreadSendFailure("Thread 3f2a is gone") } }
        acts.send(out("t1", "and add tests", queue: true))
        acts.cancelQueued("t1")
        await waitUntil { !f.emitted.isEmpty }
        refuses = false
        #expect(f.cancelled.last.map { $0.1 == "run-mine" && !$0.2 } == true)
        #expect(f.emitted == [.note("t1", words: Router.Copy.queueKept)])
    }

    @Test func notForMeIsTheRecordsMarkAndItsRevert() {
        let f = Fake()
        let acts = f.acts()
        acts.notForMe("t1", on: true)
        acts.notForMe("t1", on: false)
        #expect(f.marked.map(\.1) == [true, false] && f.commands.isEmpty)
    }

    // MARK: Settle and snooze

    @Test func settleHidesTheThreadThroughTheRecordsAndItsRevertMarksTheChange() {
        let f = Fake()
        let acts = f.acts()
        acts.settle(["t1"], on: true)
        #expect(f.acted.map(\.act) == [.settle] && f.acted.first?.title == "Fix the fence")
        #expect(f.hidden.map(\.1) == [true])
        acts.settle(["t1"], on: false)
        #expect(f.reverted == [f.changeID!] && f.hidden.map(\.1) == [true, false])
    }

    @Test func settleAllIsOneActPerThreadAndOneRevertForThem() {
        let f = Fake()
        let acts = f.acts()
        acts.settle(["t1", "t2", "t3"], on: true)
        #expect(f.acted.map(\.thread) == ["t1", "t2", "t3"])
        acts.settle(["t1", "t2", "t3"], on: false)
        #expect(f.hidden.filter { !$0.1 }.map(\.0) == ["t1", "t2", "t3"])
    }

    @Test func snoozeCarriesItsEndAndUnsnoozingIsTheRevert() {
        let f = Fake()
        let acts = f.acts()
        let until = Date(timeIntervalSince1970: 1_800_003_600)
        acts.snooze("t1", until: until)
        #expect(f.acted.first?.act == .snooze && f.acted.first?.detail == T3Timestamp(date: until).text)
        acts.snooze("t1", until: nil)
        #expect(f.reverted == [f.changeID!])
    }

    @Test func aRevertWithNoChangeLoggedSendsTheOppositeCommandItself() async {
        let f = Fake()
        f.changeID = nil
        let acts = f.acts()
        acts.settle(["t1"], on: true)
        acts.settle(["t1"], on: false)
        await waitUntil { !f.commands.isEmpty }
        #expect(f.reverted.isEmpty && f.commands.map { $0.payload(commandId: "c").str("type") } == ["thread.unsettle"])
    }

    @Test func aRefusedSettleLetsTheLineBackAndTheChangeIsNotRevertedTwice() {
        let f = Fake()
        let acts = f.acts()
        acts.settle(["t1"], on: true)
        f.holds[0](false)
        f.refusals[0]("T3 said no")
        #expect(f.hidden.map(\.1) == [true, false])
        // The page hears why, and a later Revert has no change of this act's to mark.
        #expect(f.emitted == [.actRefused("t1", reason: "T3 said no")])
        acts.settle(["t1"], on: false)
        #expect(f.reverted.isEmpty)
    }

    // MARK: A new thread

    @Test func aNewThreadIsRecordedThenStartedWithTheMintedIdAndTheRowsSettings() {
        let f = Fake()
        let acts = f.acts()
        acts.models = [RouterLaunchModel(id: "claude-opus-5-5", name: "Opus", provider: "Claude", instance: "claudeAgent",
                                           efforts: RouterLaunch.Effort.claude, defaultEffort: .high, access: RouterLaunch.Access.all)]
        let id = acts.mintThread()
        #expect(id == id.lowercased() && UUID(uuidString: id) != nil && acts.mintThread() != id)
        var launch = RouterLaunch(model: "claude-opus-5-5", effort: .medium, access: .autoEdits)
        launch.plan = true
        acts.start(id, words: "add dark mode", project: "Garden", launch: launch, read: nil)
        #expect(f.log == ["began", "submit"])
        #expect(f.began.first?.kind == .start(project: "Garden", launch: launch, name: nil))
        let context = f.submitted.first?.context
        #expect(context?.target == RouterAskBack.newThread + "p1")
        #expect(context?.launch == RouterLaunchPlan(thread: id, settings: ThreadLaunchSettings(
            model: "claude-opus-5-5", effort: "medium", runtimeMode: .autoAcceptEdits, interactionMode: .plan)))
    }

    @Test func aModelThatTakesNoEffortIsStartedWithoutOne() {
        let f = Fake()
        let acts = f.acts()
        acts.models = [RouterLaunchModel(id: "gpt-6", name: "GPT", provider: "Codex", instance: "codex", efforts: [], defaultEffort: nil,
                                           access: RouterLaunch.Access.all)]
        #expect(acts.settings(RouterLaunch(model: "gpt-6", effort: .high, access: .auto)).effort == nil)
        #expect(acts.settings(RouterLaunch(model: "unknown", effort: .high, access: .auto)).effort == "high")
    }

    @Test func aProjectT3DoesntHaveStartsNothing() {
        let f = Fake()
        let acts = f.acts()
        acts.start("new-1", words: "x", project: "Elsewhere", launch: .t3Default, read: nil)
        #expect(f.submitted.isEmpty && f.ended.count == 1 && f.emitted.count == 1)
    }

    // MARK: On a real store

    private func liveStore(_ threads: [T3JSON] = [F.shell("t1", title: "Fix the fence")]) -> (Store, Fake, RouterActs, Commands) {
        let s = Store.reading(threads, projects: [F.project("p1", title: "Garden", root: "/code/app")])
        s.router.enabled = true
        let sent = Commands()
        s.requestSender = { command, _ in sent.commands.append(command) }
        s.launchSupport = ThreadLaunchSupport(
            config: { ["settings": ["defaultModelSelection": ["instanceId": "claudeAgent", "model": "claude-opus-5-5"]],
                       "providers": [["instanceId": "claudeAgent", "status": "ready", "enabled": true,
                                      "models": [["slug": "claude-opus-5-5"], ["slug": "claude-sonnet-5-5"]]]]] },
            createProject: { _, _ in throw RouterTools.Failure("no") }, defaultBranch: { _ in "main" })
        let f = Fake()
        let acts = RouterActs.live(store: s, records: f, emit: { f.emitted.append($0) })
        return (s, f, acts, sent)
    }

    @MainActor final class Commands { var commands: [T3Command] = [] }

    @Test func settleThenItsRevertSendTheTwoCommandsAndMarkHistorysChangeReverted() async throws {
        let (s, f, acts, sent) = liveStore()
        acts.settle(["t1"], on: true)
        #expect(f.hidden.map(\.1) == [true])
        let change = try #require(s.router.changes.last)
        #expect(change.isBriefAction && change.title == "Settled Fix the fence" && !change.isReverted)
        acts.settle(["t1"], on: false)
        #expect(s.router.changes.first { $0.id == change.id }?.isReverted == true && f.hidden.map(\.1) == [true, false])
        await waitUntil { sent.commands.count == 2 }
        #expect(sent.commands.map { $0.payload(commandId: "c").str("type") } == ["thread.settle", "thread.unsettle"])
    }

    @Test func aSettleT3RefusesPutsTheLineBackAndSaysWhyOnTheChange() async throws {
        let (s, f, acts, _) = liveStore()
        s.requestSender = { _, _ in throw ThreadSendFailure("T3 said no") }
        acts.settle(["t1"], on: true)
        await waitUntil { f.hidden.count == 2 }
        #expect(f.hidden.map(\.1) == [true, false])
        let change = try #require(s.router.changes.last)
        #expect(change.isReverted && change.revertNote == "T3 refused it: T3 said no")
    }

    @Test func snoozeSendsItsEndAndUnsnoozeTheRevert() async {
        let (_, _, acts, sent) = liveStore()
        let until = Date(timeIntervalSince1970: 1_800_003_600)
        acts.snooze("t1", until: until)
        acts.snooze("t1", until: nil)
        await waitUntil { sent.commands.count == 2 }
        #expect(sent.commands.map { $0.payload(commandId: "c").str("type") } == ["thread.snooze", "thread.unsnooze"])
        #expect(sent.commands.first?.payload(commandId: "c").str("snoozedUntil") == T3Timestamp(date: until).text)
    }

    @Test func aNewThreadFromThePageLaunchesWithItsMintedIdAndSettingsAndIsTaken() async {
        let (_, f, acts, sent) = liveStore()
        var launch = RouterLaunch(model: "claude-sonnet-5-5", effort: .low, access: .supervised)
        launch.plan = true
        let id = acts.mintThread()
        acts.start(id, words: "add dark mode", project: "Garden", launch: launch, read: nil)
        await waitUntil { !f.took.isEmpty }
        guard case .launchThread(let r)? = sent.commands.first else { Issue.record("no launch: \(sent.commands)"); return }
        #expect(r.threadId == id && r.projectId == "p1" && r.model == "claude-sonnet-5-5" && r.instanceId == "claudeAgent")
        #expect(r.options == [.effort("low")] && r.runtimeMode == .approvalRequired && r.interactionMode == .plan && r.text == "add dark mode")
        #expect(f.ended.isEmpty && f.emitted.isEmpty && f.took.first?.thread == id)
    }

    @Test func aLaunchT3RefusesEndsThePendingSendWithItsWords() async {
        let (s, f, acts, _) = liveStore()
        s.requestSender = { _, _ in throw ThreadLaunchFailure("Base ref does not resolve") }
        acts.start("n1", words: "x", project: "Garden", launch: .t3Default, read: nil)
        await waitUntil { !f.emitted.isEmpty }
        #expect(f.ended.map(\.thread) == ["n1"] && f.took.isEmpty)
        #expect(f.emitted == [.refused("n1", reason: "Base ref does not resolve", offline: false)])
    }

    @Test func wordsToAnIdleThreadGoThroughTheDispatcherAndAreTaken() async {
        let (s, f, acts, sent) = liveStore()
        let sender = Commands()
        s.requestSender = { command, _ in sender.commands.append(command); sent.commands.append(command) }
        acts.send(out("t1", "use postgres"))
        await waitUntil { !f.took.isEmpty }
        let first = sender.commands.first?.payload(commandId: "c")
        #expect(first?.str("type") == "message.dispatch" && first?.str("text") == "use postgres" && first?["dispatchMode"]?.str("type") == "start_immediately")
        #expect(f.ended.isEmpty && f.emitted.isEmpty)
    }
}
