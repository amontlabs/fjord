import Foundation
import Testing
@testable import Fjord

/// What you type goes to a T3 thread: a tag goes there with no model, a reply goes to its card's thread, anything else is the
/// decider's, and its decision is acted on as it is (a thread gets the words, a new thread starts with them, or you're asked).
@MainActor
@Suite(.serialized) struct RouterDispatcherTests {
    @MainActor final class Fakes {
        /// What the decider answers next (in order; the last one again once they're used up), and the stages it reports.
        var decisions: [RouterProjectDecision] = [RouterProjectDecider.ask([], confidence: 0, decider: .none)]
        var stages: [RouterProjectDecider.Stage] = [.sonnet]
        var decided: [(message: String, unattended: Bool)] = []
        /// What the decider was handed of the message's tags (`RouterTools.tagged`).
        var decidedTagged: [String?] = []
        /// Holds the decider until the test lets it go.
        var holdDecide = false
        var decideHeld: CheckedContinuation<Void, Never>?
        var sent: [RouterDispatcher.Delivery] = []
        var answered: [(target: BriefTarget, answer: RouterDispatcher.RequestAnswer)] = []
        var runs: [(intent: RouterRun.Intent, input: String)] = []
        var answer = RouterRun.Answer(reply: "Done.", done: "set it")
        var finished: [UUID] = []
        /// What went to T3 as commands (a launch).
        var commands: [T3Command] = []
        /// The dispatcher holds its store weakly: the test's stand-ins keep it.
        var store: Store?

        func install(_ d: RouterDispatcher) {
            d.onFinish = { [self] in finished.append($0) }
            d.effects = RouterDispatcher.Effects(
                decide: { [self] tools, message, action, stage in
                    decided.append((message, action != nil))
                    decidedTagged.append(tools.tagged)
                    for s in stages { stage(s) }
                    if holdDecide { await withCheckedContinuation { decideHeld = $0 } }
                    return decisions.count > 1 ? decisions.removeFirst() : decisions[0]
                },
                send: { [self] _, delivery in
                    sent.append(delivery)
                    return RouterDecision.Delivered(thread: delivery.thread, messageID: delivery.message.messageID,
                                                    commandID: delivery.message.commandID, outcome: .steered, note: nil, at: Date())
                },
                answer: { [self] _, target, answer, snapshot in
                    guard snapshot.holds(store!) else { throw RouterTools.Failure(RequestSnapshot.changedWords) }
                    answered.append((target, answer))
                    return "answered"
                },
                run: { [self] _, intent, input in
                    runs.append((intent, input))
                    return answer
                })
        }
    }

    static let config: T3JSON = ["settings": ["defaultModelSelection": ["instanceId": "claudeAgent", "model": "claude-opus-5"]]]

    func setup() -> (Store, RouterDispatcher, Fakes) {
        let s = Store.reading([
            T3Fixture.shell("th-login", title: "Fix the login redirect", status: "running", project: "p1", minutes: 1),
            T3Fixture.shell("th-docs", title: "Write the README", project: "p2", minutes: 40),
        ], projects: [T3Fixture.project("p1", title: "lookout", root: "/code/lookout"), T3Fixture.project("p2", title: "api", root: "/code/api"),
                      T3Fixture.project("p3", title: "lcu", root: "/code/lcu")])
        s.categories = [InboxStore.ci]
        s.router.enabled = true
        let d = s.routerDispatcher
        let f = Fakes()
        f.install(d)
        f.store = s
        s.requestSender = { [f] command, _ in f.commands.append(command) }
        s.launchSupport = ThreadLaunchSupport(config: { Self.config }, createProject: { _, _ in throw RouterTools.Failure("no") },
                                              defaultBranch: { _ in "main" })
        return (s, d, f)
    }

    func finish(_ f: Fakes, _ id: UUID?) async {
        await waitUntil { id.map { f.finished.contains($0) } ?? true }
    }

    func decision(_ s: Store, _ id: UUID?) -> RouterDecision? { s.router.decisions.first { $0.id == id } }

    func decided(_ kind: RouterProjectDecision.Kind, _ decider: RouterProjectDecision.Decider = .sonnet, p: Double = 0.9) -> RouterProjectDecision {
        RouterProjectDecision(kind: kind, confidence: p, decider: decider, reason: "it continues that work")
    }

    func reply(_ thread: String, _ project: String = "p1") -> RouterContext {
        RouterContext(replyTo: BriefTarget(project: project, thread: thread))
    }

    // MARK: No model

    @Test func aTaggedThreadGetsTheWordsWithNoModel() async {
        let (s, d, f) = setup()
        var context = RouterContext()
        context.tag([RouterMention(range: 0..<7, pointer: .t3(RouteTarget.thread("th-docs").targetID), name: "README")])
        let id = d.submit("@README run the release checklist", context: context)
        await finish(f, id)
        #expect(f.decided.isEmpty && f.sent.map(\.thread) == ["th-docs"] && f.sent.first?.body == "run the release checklist", "\(f.sent.first?.body ?? "-")")
        #expect(decision(s, id)?.decision.confirmed == true && decision(s, id)?.decision.decider == nil)
    }

    @Test func aReplyGoesToItsThreadWithNoModelAndSteersIt() async {
        let (s, d, f) = setup()
        let id = d.submit("use postgres and keep the old schema", context: reply("th-login"))
        await finish(f, id)
        #expect(f.decided.isEmpty && f.sent.map(\.thread) == ["th-login"] && f.sent.first?.mode == .steer)
        #expect(decision(s, id)?.delivered?.thread == "th-login")
        #expect(decision(s, id)?.done.contains(where: \.sendsWords) == true)
    }

    @Test func aReplyWithOptionReturnWaitsForTheTurnUnderWay() async {
        let (_, d, f) = setup()
        var context = reply("th-login")
        context.queue = true
        let id = d.submit("after the tests, please", context: context)
        await finish(f, id)
        #expect(f.sent.map(\.mode) == [.queue] && f.sent.first?.unattended == false)
    }

    @Test func aReplyToAThreadT3NoLongerListsIsRefusedNotSentElsewhere() async {
        let (s, d, f) = setup()
        let id = d.submit("ship it", context: reply("th-gone"))
        await finish(f, id)
        #expect(f.decided.isEmpty && f.sent.isEmpty)
        #expect(decision(s, id)?.done.contains(.failed("Not sent: that thread isn't in T3 anymore")) == true)
    }

    @Test func eachThreadRepliedToGetsItsOwnDispatchAndCommandId() async {
        let (_, d, f) = setup()
        let a = d.submit("ship it", context: reply("th-login"))
        let b = d.submit("ship it", context: reply("th-docs", "p2"))
        await finish(f, a)
        await finish(f, b)
        #expect(Set(f.sent.map(\.thread)) == ["th-login", "th-docs"])
        #expect(Set(f.sent.map(\.message.commandID)).count == 2)
    }

    @Test func wordsWhollyForTheRouterAreAnsweredHere() async {
        let (_, d, f) = setup()
        let id = d.submit("@router what needs me?")
        await finish(f, id)
        #expect(f.decided.isEmpty && f.runs.map(\.intent) == [.question])
    }

    @Test func targetsAreNamedAndEligibleWhileT3HasThem() {
        let (s, d, _) = setup()
        #expect(d.eligible("t3-thread:th-login", store: s) && d.eligible("new_thread:p3", store: s) && d.eligible("new_folder:/code/x", store: s))
        #expect(!d.eligible("t3-thread:gone", store: s) && !d.eligible("new_thread:gone", store: s))
        #expect(d.option("t3-thread:th-login", store: s)?.title == "Fix the login redirect")
        #expect(d.option("new_thread:p3", store: s)?.title == "New thread in lcu")
        #expect(d.describe("t3-thread:th-docs", store: s) == "thread “Write the README” in api")
        #expect(d.describe("new_thread:p3", store: s) == "a new thread in lcu")
        #expect(d.pickerOptions().contains { $0.target == "t3-thread:th-docs" } && d.pickerOptions().contains { $0.target == "new_thread:p1" })
        #expect(RouteTarget("t3-thread:") == nil && RouteTarget("claude-project:lookout") == nil && RouteTarget("session:x") == nil)
        #expect(RouteTarget(RouteTarget.newThread(project: "p9").targetID) == .newThread(project: "p9"))
    }

    // MARK: A waiting request: the pick maps onto it deterministically

    @Test func aPermissionIsDeclinedWithYourWordsNeverAYes() async {
        let (s, d, f) = setup()
        s.requests["th-docs"] = ThreadRequest(id: "perm", threadID: "th-docs",
                                              body: .approval(kind: "command", prompt: "rm -rf build", decisions: ThreadRequest.fallbackDecisions))
        f.decisions = [decided(.thread("th-docs"))]
        let id = d.submit("yes, go ahead")
        await finish(f, id)
        #expect(f.sent.isEmpty && f.answered.count == 1)
        if case .decline(let words)? = f.answered.first?.answer { #expect(words == "yes, go ahead") } else { Issue.record("not a decline") }
        #expect(decision(s, id)?.done.contains { if case .answered = $0 { true } else { false } } == true)
    }

    // MARK: What the message tags

    @Test func aTaggedCategoryReachesTheDeciderAndGoesAfterYourWords() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.thread("th-docs"))]
        var context = RouterContext()
        context.tag([RouterMention(range: 8..<11, pointer: .category(s.categories[0].id), name: "CI")])
        let id = d.submit("look at @CI please", context: context)
        await finish(f, id)
        #expect(f.decidedTagged.first??.contains("@CI: a category") == true)
        let text = f.sent.first?.message.text ?? ""
        #expect(text.hasPrefix("look at ") && text.contains("@CI: a category") || text.contains("t3-context://"))
        // What was recorded as yours is only your words.
        if case .sent(_, let shown, _)? = decision(s, id)?.done.first(where: \.sendsWords) { #expect(shown == "look at @CI please") }
    }

    // MARK: The decider

    @Test func aThreadDecisionSendsToThatThreadSteersARunningOneAndSaysWhoDecided() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.thread("th-login"), .sonnet)]
        let id = d.submit("yes, merge it once CI is green")
        await finish(f, id)
        #expect(f.sent.map(\.thread) == ["th-login"] && f.sent.first?.mode == .steer)
        let entry = decision(s, id)
        #expect(entry?.decision.decider == "sonnet" && entry?.decision.targetID == "t3-thread:th-login" && entry?.decision.confidence == 0.9)
        #expect(entry?.decision.label == "reply" && entry?.decision.target?.contains("Fix the login redirect") == true)
        #expect(entry?.delivered?.outcome == .steered)
    }

    @Test func aNewThreadDecisionStartsAThreadInTheProjectWithYourWords() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.newThread(project: "p3"))]
        let id = d.submit("add a --json flag to the status command")
        await finish(f, id)
        #expect(f.sent.isEmpty)
        guard case .launchThread(let request)? = f.commands.first else { Issue.record("no launch: \(f.commands)"); return }
        #expect(request.projectId == "p3" && request.text == "add a --json flag to the status command")
        let entry = decision(s, id)
        #expect(entry?.decision.targetID == "new_thread:p3" && entry?.decision.label == "new_thread" && entry?.delivered != nil)
    }

    @Test func theStageShowsOnThePendingRunAsTheDeciderGoes() async {
        let (_, d, f) = setup()
        f.holdDecide = true
        f.decisions = [decided(.thread("th-docs"))]
        let id = d.submit("bump the version")!
        await waitUntil { f.decideHeld != nil }
        #expect(d.progress[id] == RouterProjectDecider.Stage.sonnet.words)
        f.decideHeld?.resume()
        await finish(f, id)
    }

    @Test func anAnswerIsTheRoutersOwnRun() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.answer)]
        let id = d.submit("what's going on in lookout?")
        await finish(f, id)
        #expect(f.runs.map(\.intent) == [.changeFjord] && f.sent.isEmpty && f.commands.isEmpty)
        #expect(decision(s, id)?.reply == "Done.")
    }

    @Test func aTargetThatIsGoneSinceTheDecisionAsksInsteadOfSending() async {
        let (_, d, f) = setup()
        f.decisions = [decided(.thread("th-gone"))]
        let id = d.submit("ship it")!
        await finish(f, id)
        #expect(f.sent.isEmpty && d.askBacks.first?.id == id)
    }

    // MARK: Asking and correcting

    @Test func anAskListsThePlacesAndAPickOfAnotherIsACorrection() async {
        let (s, d, f) = setup()
        f.decisions = [RouterProjectDecider.ask([.thread("th-login")], confidence: 0.5, decider: .sonnet)]
        let id = d.submit("ship it tomorrow morning")!
        await finish(f, id)
        let ask = d.askBacks.first
        #expect(ask?.options.first?.target == "t3-thread:th-login" && ask?.suggestion == "t3-thread:th-login")
        #expect(ask?.options.contains { $0.target == "t3-thread:th-docs" } == true)
        #expect(ask?.options.contains { $0.target == "change_fjord" } == true)
        #expect(decision(s, id)?.decision.decider == "sonnet")
        #expect(d.pick(id, target: "t3-thread:th-docs"))
        await finish(f, id)
        await waitUntil { !f.sent.isEmpty }
        #expect(f.sent.map(\.thread) == ["th-docs"])
        guard case .corrected(_, let to)? = decision(s, id)?.outcome else { Issue.record("not a correction"); return }
        #expect(to.contains("Write the README"))
    }

    @Test func aPickOfANewThreadStartsOneAndConfirmingTheGuessIsNotACorrection() async {
        let (s, d, f) = setup()
        f.decisions = [RouterProjectDecider.ask([.newThread(project: "p3")], confidence: 0.5, decider: .sonnet)]
        let id = d.submit("a tiny CLI to rename photos")!
        await finish(f, id)
        #expect(d.askBacks.first?.suggestion == "new_thread:p3")
        #expect(d.pick(id, target: "new_thread:p3"))
        await waitUntil { !f.commands.isEmpty }
        if case .launchThread(let r)? = f.commands.first { #expect(r.projectId == "p3") } else { Issue.record("no launch") }
        if case .corrected? = decision(s, id)?.outcome { Issue.record("a confirmed guess was logged as a correction") }
        #expect(decision(s, id)?.decision.confirmed == true)
    }

    @Test func sendElsewhereAsksWithoutTheWrongPlaceAndLogsTheCorrection() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.thread("th-login"))]
        let id = d.submit("bump the version")!
        await finish(f, id)
        #expect(d.canSendElsewhere(id))
        d.sendElsewhere(id)
        let ask = d.askBacks.first
        #expect(ask?.suggestion == "t3-thread:th-login")
        #expect(ask?.options.contains { $0.target == "t3-thread:th-login" } == false)
        #expect(d.pick(id, target: "t3-thread:th-docs"))
        await waitUntil { f.sent.count >= 2 }
        #expect(f.sent.map(\.thread) == ["th-login", "th-docs"])
        if case .corrected? = decision(s, id)?.outcome {} else { Issue.record("not logged as a correction") }
        #expect(decision(s, id)?.decision.decider == "sonnet")
    }

    @Test func dismissingSendsNothing() async {
        let (s, d, f) = setup()
        f.decisions = [RouterProjectDecider.ask([], confidence: 0, decider: .none)]
        let id = d.submit("hmm")!
        await finish(f, id)
        d.dismiss(id)
        #expect(f.sent.isEmpty && f.commands.isEmpty && d.askBacks.isEmpty && decision(s, id)?.reply == "Dismissed: nothing was sent.")
    }

    // MARK: The decision log

    @Test func everyDecisionIsLoggedWithItsBoardAndWhatYouThenDid() async throws {
        let (_, d, f) = setup()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("decider-log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = DeciderLog(url: url)
        d.decisionLog = log
        var board = DeciderBoard(projects: ["lookout"], threads: [.init(id: "aaaa1111", key: "th-login", project: "lookout", title: "Fix", flag: .running, minutesIdle: 1)])
        board.projectIDs = ["lookout": "p1"]
        var first = decided(.ask([.thread("th-login")]), p: 0.5)
        first.board = board
        first.boardText = board.render()
        first.latency = 1.25
        first.action = "follow_up"
        f.decisions = [first]
        let id = d.submit("ship it")!
        await finish(f, id)
        #expect(d.pick(id, target: "t3-thread:th-login"))
        await finish(f, id)
        log.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let record = try #require(lines.first { $0["type"] as? String == "decision" })
        #expect(record["id"] as? String == id.uuidString && record["kind"] as? String == "ask" && record["places"] as? [String] == ["thread:th-login"])
        #expect(record["boardHash"] as? String == DeciderLog.hash(board.render()) && record["latencyMs"] as? Int == 1250)
        #expect(record["confidence"] as? Double == 0.5 && record["message"] as? String == "ship it" && record["sent"] as? String == "asked")
        #expect((record["candidates"] as? [[String: String]])?.first?["thread"] == "th-login")
        let outcome = try #require(lines.first { $0["type"] as? String == "outcome" })
        #expect(outcome["what"] as? String == "picked" && outcome["wasGuess"] as? Bool == true)
    }
}
