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
        /// Holds the decider until the test lets it go.
        var holdDecide = false
        var decideHeld: CheckedContinuation<Void, Never>?
        var prepared: [String] = []
        var sent: [RouterDispatcher.Delivery] = []
        var answered: [(card: String, answers: [String: String])] = []
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
                decide: { [self] _, message, unattended, stage in
                    decided.append((message, unattended))
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
                answer: { [self] _, card, answers, snapshot in
                    guard snapshot.holds(store!) else { throw RouterTools.Failure(FormSnapshot.changedWords) }
                    answered.append((card, answers))
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
        s.router.cards = [RouterCard(id: "local_a#w1", sessionID: "local_a", kind: .question, title: "Fix the login bug",
                                     folder: "/code/lookout", text: "Which database?", createdAt: Date())]
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
        f.requests.compactMap { if case .send(let w, let p, let t, _) = $0 { (w, p, t) } else { nil } }
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

    @Test func aReplyGoesToItsCardsSessionWithNoModel() async {
        let (s, d, f) = setup()
        let id = d.submit("use postgres and keep the old schema", context: RouterContext(replyTo: "local_a#w1"))
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
