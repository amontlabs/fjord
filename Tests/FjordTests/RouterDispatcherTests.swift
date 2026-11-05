import Foundation
import Testing
@testable import Fjord

/// What you type goes to a claude.ai project or thread only: a tag goes there with no model, a reply goes to its card's session,
/// anything else is the project decider's, and its decision is acted on as it is.
@MainActor
@Suite(.serialized) struct RouterDispatcherTests {
    @MainActor final class Fakes {
        /// What the decider answers next (in order; the last one again once they're used up), and the stages it reports.
        var decisions: [RouterProjectDecision] = [RouterProjectDecider.ask([], confidence: 0, decider: .none)]
        var stages: [RouterProjectDecider.Stage] = [.jev, .sonnet]
        var decided: [(message: String, unattended: Bool)] = []
        /// What the decider was handed of the message's tags (`RouterTools.tagged`).
        var decidedTagged: [String?] = []
        /// Holds the decider until the test lets it go.
        var holdDecide = false
        var decideHeld: CheckedContinuation<Void, Never>?
        var prepared: [String] = []
        var sent: [RouterDispatcher.Delivery] = []
        var answered: [(target: BriefTarget, answers: [String: String])] = []
        var runs: [(intent: RouterRun.Intent, input: String)] = []
        var answer = RouterRun.Answer(reply: "Done.", done: "set it")
        var finished: [UUID] = []
        /// What the engine was asked, through the pills.
        var requests: [CourierRequest] = []
        /// The dispatcher holds its store weakly: the test's stand-ins keep it.
        var store: Store?

        func install(_ d: RouterDispatcher) {
            d.onFinish = { [self] in finished.append($0) }
            d.effects = RouterDispatcher.Effects(
                decide: { [self] tools, message, unattended, stage in
                    decided.append((message, unattended))
                    decidedTagged.append(tools.tagged)
                    for s in stages { stage(s) }
                    if holdDecide { await withCheckedContinuation { decideHeld = $0 } }
                    return decisions.count > 1 ? decisions.removeFirst() : decisions[0]
                },
                prepare: { [self] _, session in
                    prepared.append(session)
                    return RouterDispatcher.Delivery(to: "peer-\(session)", text: "⟦signed⟧\nbody-\(session)", body: "body-\(session)",
                                                     original: "orig", rephrased: true, session: session)
                },
                send: { [self] _, delivery in
                    sent.append(delivery)
                    return nil
                },
                answer: { [self] _, target, answers, snapshot in
                    guard snapshot.holds(store!) else { throw RouterTools.Failure(FormSnapshot.changedWords) }
                    answered.append((target, answers))
                    return "answered"
                },
                run: { [self] _, intent, input in
                    runs.append((intent, input))
                    return answer
                },
                reviser: { RouterProjectFakeReviser() })
        }
    }

    static let lookout = CourierPlace(id: "chan_lookout", name: "lookout", purpose: "Fjord, the Mac app",
                                      threads: [.init(id: "t1", title: "Fix the login redirect", state: "working", touched: 20)])
    static let lcu = CourierPlace(id: "chan_lcu", name: "lcu", purpose: "", threads: [])

    func setup() -> (Store, RouterDispatcher, Fakes) {
        let s = InboxFixture.store([])
        s.categories = [InboxStore.ci]
        s.router.enabled = true
        s.agents.enabled = true
        s.claudeSessions = [
            "local_a": ClaudeSession(id: "local_a", title: "Fix the login bug", folder: "/code/lookout", lastActivity: Date(), running: true),
        ]
        s.routerCourierLink.take(CourierSnapshot(health: .init(tabConnected: true, signedIn: true), places: [Self.lookout, Self.lcu]))
        let d = s.routerDispatcher
        let f = Fakes()
        f.install(d)
        f.store = s
        s.routerCourier.settleAfter = nil
        s.routerCourier.attach(RouterCourierSource(submit: { [f] in f.requests.append($0); return f.requests.count },
                                                   updates: AsyncStream { _ in }))
        return (s, d, f)
    }

    func finish(_ f: Fakes, _ id: UUID?) async {
        await waitUntil { id.map { f.finished.contains($0) } ?? true }
    }

    func decision(_ s: Store, _ id: UUID?) -> RouterDecision? { s.router.decisions.first { $0.id == id } }

    func sentWords(_ f: Fakes) -> [(words: String, project: String, thread: String?)] {
        f.requests.compactMap { if case .send(let w, let p, let t, _, _) = $0 { (w, p, t) } else { nil } }
    }

    func decided(_ kind: RouterProjectDecision.Kind, _ decider: RouterProjectDecision.Decider = .sonnet, p: Double = 0.9) -> RouterProjectDecision {
        RouterProjectDecision(kind: kind, confidence: p, decider: decider, reason: "it continues that work")
    }

    // MARK: No model

    @Test func aTaggedProjectGetsTheWordsWithNoModel() async {
        let (s, d, f) = setup()
        let text = "@lookout run the release checklist"
        var context = RouterContext()
        context.tag([RouterMention(range: 0..<8, pointer: .claude(RouterCourier.Target.project("lookout").targetID), name: "lookout")])
        let id = d.submit(text, context: context)
        await finish(f, id)
        await waitUntil { !f.requests.isEmpty }
        #expect(f.decided.isEmpty)
        #expect(sentWords(f).map(\.words) == ["run the release checklist"] && sentWords(f).first?.project == "lookout")
        #expect(decision(s, id)?.decision.confirmed == true && decision(s, id)?.decision.decider == nil)
    }

    @Test func aReplyGoesToItsThreadsSessionWithNoModel() async {
        let (s, d, f) = setup()
        let id = d.submit("use postgres and keep the old schema", context: RouterContext(replyTo: BriefTarget(project: "local:lookout", thread: "local_a")))
        await finish(f, id)
        #expect(f.decided.isEmpty && f.prepared == ["local_a"] && f.sent.count == 1)
        #expect(decision(s, id)?.done.contains(where: \.sendsWords) == true)
    }

    @Test func wordsWhollyForTheRouterAreAnsweredHere() async {
        let (_, d, f) = setup()
        let id = d.submit("@router what needs me?")
        await finish(f, id)
        #expect(f.decided.isEmpty && f.runs.map(\.intent) == [.question])
    }

    // MARK: The engine not taking it

    @Test func aMessageTheEngineDidntTakeIsAFailureNotASentOne() async {
        let (s, d, f) = setup()
        s.routerCourier.attach(RouterCourierSource(submit: { [f] in f.requests.append($0); return 0 }, updates: AsyncStream { _ in }))
        f.decisions = [decided(.project("lookout", thread: nil))]
        let id = d.submit("bump the version")
        await finish(f, id)
        let entry = decision(s, id)
        #expect(entry?.done.contains(where: \.sendsWords) == false)
        #expect(entry?.done.contains(.failed(RouterDispatcher.notTakenWords)) == true)
        #expect(entry?.decision.courierIntent == nil)
        // Retry: the engine takes it this time, and it goes once.
        s.routerCourier.attach(RouterCourierSource(submit: { [f] in f.requests.append($0); return f.requests.count }, updates: AsyncStream { _ in }))
        let again = d.submit("bump the version")
        await finish(f, again)
        #expect(decision(s, again)?.done.contains(where: \.sendsWords) == true)
        #expect(sentWords(f).count == 2)
    }

    @Test func aSendTheEngineFailedIsNotARoutingExample() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.project("lookout", thread: nil))]
        let id = d.submit("bump the version")
        await finish(f, id)
        await waitUntil { decision(s, id)?.decision.courierIntent == 1 }
        #expect(RouterProjectContext.routings(s).count == 1)
        s.routerCourier.lastUpdates[1] = CourierUpdate(intentID: 1, state: .failed, cause: "x", before: nil, at: Date())
        #expect(RouterProjectContext.routings(s).isEmpty)
        s.routerCourier.lastUpdates[1] = CourierUpdate(intentID: 1, state: .delivered, cause: nil, before: nil, at: Date())
        #expect(RouterProjectContext.routings(s).count == 1)
    }

    // Round 3 D: the engine's record (it survives a restart) judges a delivery before the pills' memory does.
    @Test func theEnginesRecordJudgesARoutingExample() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.project("lookout", thread: nil))]
        let id = d.submit("bump the version")
        await finish(f, id)
        await waitUntil { decision(s, id)?.decision.courierIntent == 1 }
        s.routerCourier.lastUpdates[1] = CourierUpdate(intentID: 1, state: .delivered, cause: nil, before: nil, at: Date())
        #expect(RouterProjectContext.routings(s, statuses: [1: CourierIntentStatus(state: .failed)]).isEmpty)
        s.routerCourier.attach(RouterCourierSource(submit: { _ in 0 }, updates: AsyncStream { _ in },
                                                   status: { $0 == 1 ? CourierIntentStatus(state: .refused) : nil }))
        let statuses = await RouterProjectContext.deliveries(s)
        #expect(statuses[1]?.state == .refused)
        #expect(RouterProjectContext.routings(s, statuses: statuses).isEmpty)
    }

    // Round 5, 1: a keyed send answered with an intent the engine already had starts its pill from the engine's record.
    @Test func aRepeatedKeysPillStartsFromTheEnginesRecord() async {
        let (s, _, _) = setup()
        s.routerCourier.attach(RouterCourierSource(submit: { _ in 3 }, updates: AsyncStream { _ in },
                                                   status: { $0 == 3 ? CourierIntentStatus(state: .delivered) : nil }))
        let id = await s.routerCourier.send("once", to: .project("lookout"), key: "p#0")
        #expect(id == 3)
        #expect(s.routerCourier.items.first { $0.id == 3 }?.state == .delivered)
        #expect(s.routerCourier.lastUpdates[3]?.state == .delivered)
    }

    // Round 3 F: a wait on the pills ends when its task is cancelled.
    @Test func aWaitOnAnIntentEndsWhenCancelled() async {
        let (s, _, _) = setup()
        let wait = Task { await s.routerCourier.next(42) { $0 == .toolDone } }
        try? await Task.sleep(for: .milliseconds(20))
        wait.cancel()
        #expect(await wait.value == nil)
        #expect(s.routerCourier.waiters[42]?.isEmpty ?? true)
    }

    // MARK: What the message tags

    @Test func aTaggedCategoryReachesTheDeciderAndGoesAfterYourWords() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.project("lookout", thread: nil))]
        let ci = s.categories[0]
        var context = RouterContext()
        context.tag([RouterMention(range: 8..<11, pointer: .category(ci.id), name: "CI")])
        let id = d.submit("look at @CI please", context: context)
        await finish(f, id)
        await waitUntil { !f.requests.isEmpty }
        #expect(f.decidedTagged.first??.contains("@CI: a category") == true)
        let words = sentWords(f).first?.words ?? ""
        #expect(words.hasPrefix("look at @CI please\n\n") && words.contains("@CI: a category"))
        // What was recorded as yours is only your words.
        if case .send(let shown, _, _)? = s.routerCourier.items.first?.work { #expect(shown == "look at @CI please") } else { Issue.record("no pill") }
        if case .sent(_, let text, _)? = decision(s, id)?.done.first(where: \.sendsWords) { #expect(text == "look at @CI please") }
    }

    // MARK: The routing history

    @Test func onlyDeliveredRoutingsAreTheDecidersHistory() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.project("lookout", thread: nil))]
        let sent = d.submit("bump the version")
        await finish(f, sent)
        f.decisions = [decided(.ask([.project("lcu", thread: nil)]), .sonnet, p: 0.3)]
        let waiting = d.submit("what about this one")
        await finish(f, waiting)
        let current = d.submit("a third")
        #expect(RouterProjectContext.routings(s).map(\.text) == ["bump the version"])
        #expect(RouterProjectContext.routings(s, excluding: sent).isEmpty)
        _ = current
    }

    // MARK: The decider

    @Test func aProjectDecisionGoesToItsCoordinatorAndSaysWhoDecided() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.project("lookout", thread: nil), .jev)]
        let id = d.submit("bump the version")
        await finish(f, id)
        await waitUntil { !f.requests.isEmpty }
        #expect(sentWords(f).first?.project == "lookout" && sentWords(f).first?.thread == nil)
        let entry = decision(s, id)
        #expect(entry?.decision.decider == "jev" && entry?.decision.targetID == "claude-project:lookout")
        await waitUntil { decision(s, id)?.decision.courierIntent == 1 }
    }

    @Test func aThreadDecisionRepliesToThatThread() async {
        let (_, d, f) = setup()
        f.decisions = [decided(.project("lookout", thread: "t1"))]
        let id = d.submit("yes, merge it once CI is green")
        await finish(f, id)
        await waitUntil { !f.requests.isEmpty }
        #expect(sentWords(f).first?.project == "lookout" && sentWords(f).first?.thread == "t1")
    }

    @Test func newWorkGoesToTheProjectsCoordinator() async {
        let (_, d, f) = setup()
        f.decisions = [decided(.newWork(project: "lcu"))]
        let id = d.submit("add a --json flag to the status command")
        await finish(f, id)
        await waitUntil { !f.requests.isEmpty }
        #expect(sentWords(f).first?.project == "lcu" && sentWords(f).first?.thread == nil)
    }

    @Test func theStageShowsOnThePendingRunAsTheDeciderGoes() async {
        let (_, d, f) = setup()
        f.holdDecide = true
        f.decisions = [decided(.project("lookout", thread: nil))]
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
        #expect(f.runs.map(\.intent) == [.changeFjord] && f.requests.isEmpty)
        #expect(decision(s, id)?.reply == "Done.")
    }

    @Test func aNewProjectIsProposedUnderTheComposerAndTheEntryWaits() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.newProject(name: "fjord-ios"))]
        let id = d.submit("start an iOS companion app")
        await finish(f, id)
        let proposal = s.routerProposal
        #expect(proposal?.fields.name == "fjord-ios")
        #expect(proposal?.fields.folder == "~/code/projects/fjord-ios" && proposal?.fields.repo == nil)
        #expect(decision(s, id)?.outcome == .pending && f.requests.isEmpty)
        // Dropped: nothing was sent, and the entry says so.
        _ = proposal?.drop()
        #expect(decision(s, id)?.outcome == .done && decision(s, id)?.reply == "Dropped: nothing was sent.")
    }

    @Test func aNewProjectsProposalCarriesWhatTheMessageTagsAfterYourWords() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.newProject(name: "fjord-ios"))]
        var context = RouterContext()
        context.tag([RouterMention(range: 8..<11, pointer: .category(s.categories[0].id), name: "CI")])
        let id = d.submit("look at @CI please", context: context)
        await finish(f, id)
        let proposal = s.routerProposal
        #expect(proposal?.tagged?.contains("@CI: a category") == true)
        #expect(proposal?.message.contains("@CI: a category") == false)
        // The pills' engine: the tags after your words, the pill showing your words alone.
        let engine = RouterProjectPillsEngine(pills: s.routerCourier)
        let intent = await engine.send("look at it\n\n@CI: a category", display: "look at it", to: "chan_x", named: "x", key: "k")
        #expect(intent > 0)
        #expect(sentWords(f).last?.words == "look at it\n\n@CI: a category")
        #expect(s.routerCourier.items.last.map { if case .send(let w, _, _) = $0.work { w } else { "" } } == "look at it")
    }

    @Test func aRestoredProposalReattachesToItsEntry() async throws {
        let (s, d, _) = setup()
        let entry = s.logDecision(RouterDecision(trigger: .you("start an iOS app"), outcome: .done))
        let engine = RouterProjectFakeEngine()
        s.restoreProposals([.init(message: "start an iOS app", fields: .init(name: "fjord-ios"), made: [.create], project: "chan_i",
                                  stopped: "Fjord quit while making it", decision: entry)],
                           reviser: RouterProjectFakeReviser(), engine: engine)
        let p = try #require(s.routerProposal)
        p.settleAfter = nil
        #expect(!p.restored)
        #expect(decision(s, entry)?.outcome == .pending)
        p.confirm()
        await p.settled()
        #expect(engine.sent.map(\.project) == ["chan_i"])
        #expect(decision(s, entry)?.decision.target == "new claude.ai project “fjord-ios”")
        #expect(decision(s, entry)?.decision.courierIntent == 101)
        #expect(decision(s, entry)?.outcome == .done)
        _ = d
    }

    @Test func aProposalTakesTheFolderTheMessageNames() {
        let (s, _, _) = setup()
        let dir = FileManager.default.temporaryDirectory.path
        let fields = RouterProjectProposalSeed.fields(name: "scratch", message: "set it up in \(dir) please", context: RouterContext(), store: s)
        #expect(fields.folder == dir)
        #expect(RouterProjectProposalSeed.name(from: "Set up the iOS app, please") == "set-up-the")
    }

    // MARK: Asking and correcting

    @Test func anAskListsThePlacesThenNewProjectAndAPickOfAnotherIsACorrection() async {
        let (s, d, f) = setup()
        f.decisions = [RouterProjectDecider.ask([.project("lookout", thread: "t1")], confidence: 0.5, decider: .sonnet)]
        let id = d.submit("ship it tomorrow morning")!
        await finish(f, id)
        let ask = d.askBacks.first
        #expect(ask?.options.first?.target == "claude-thread:lookout/t1")
        #expect(ask?.options.contains { $0.target == "claude-project:lcu" } == true)
        #expect(ask?.options.contains { $0.target == RouterAskBack.newProject } == true)
        #expect(decision(s, id)?.decision.decider == "sonnet")
        #expect(d.pick(id, target: "claude-project:lcu"))
        await waitUntil { !f.requests.isEmpty }
        #expect(sentWords(f).first?.project == "lcu")
        guard case .corrected(_, let to)? = decision(s, id)?.outcome else { Issue.record("not a correction"); return }
        #expect(to.contains("lcu"))
    }

    @Test func newProjectOnAnAskStartsTheProposal() async {
        let (s, d, f) = setup()
        f.decisions = [RouterProjectDecider.ask([], confidence: 0, decider: .none)]
        let id = d.submit("a tiny CLI to rename photos")!
        await finish(f, id)
        #expect(d.pick(id, target: RouterAskBack.newProject))
        await waitUntil { s.routerProposal != nil }
        #expect(s.routerProposal?.fields.name == "a-tiny-cli")
    }

    @Test func sendElsewhereAsksWithoutTheWrongPlaceAndKeepsTheCorrectionOnTheEngine() async {
        let (s, d, f) = setup()
        f.decisions = [decided(.project("lookout", thread: nil))]
        let id = d.submit("bump the version")!
        await finish(f, id)
        await waitUntil { decision(s, id)?.decision.courierIntent == 1 }
        d.sendElsewhere(id)
        let ask = d.askBacks.first
        #expect(ask?.suggestion == "claude-project:lookout")
        #expect(ask?.options.contains { $0.target == "claude-project:lookout" } == false)
        #expect(d.pick(id, target: "claude-project:lcu"))
        await waitUntil { f.requests.count >= 3 }
        #expect(f.requests.contains { if case .correct(1, "lcu") = $0 { true } else { false } })
        #expect(sentWords(f).last?.project == "lcu")
        if case .corrected? = decision(s, id)?.outcome {} else { Issue.record("not logged as a correction") }
        #expect(decision(s, id)?.decision.decider == "sonnet")
    }
}
