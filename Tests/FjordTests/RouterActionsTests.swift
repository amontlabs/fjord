import Foundation
import Testing
@testable import Fjord

/// What the Router does besides sending (`RouterActionChecks`): the checks call's request, when it is asked, the actions it
/// chooses (archive with Revert, stop, stop and send), the ask cards with typed options, and the trace of each.
@MainActor
extension RouterDispatcherTests {
    /// The standard board plus a session finished with a card (Update the docs: a report to read) and one working with no
    /// card (Run the CI), so there is something to archive and something to stop.
    func actionBoard() -> (Store, RouterDispatcher, Fakes) {
        let (s, d, f) = setup()
        s.claudeSessions["local_c"] = ClaudeSession(id: "local_c", title: "Run the CI", folder: "/code/ci", lastActivity: Date(), running: true)
        s.router.cards.append(RouterCard(id: "local_b#t1", sessionID: "local_b", kind: .done, title: "Update the docs",
                                         folder: "/code/docs", text: "Changelog entry added.", createdAt: Date()))
        return (s, d, f)
    }

    private func reading(_ checks: [RouterActionCheck], urgent: Double = 0.05, instead: Double = 0.05,
                         stoppable: [String] = ["local_c"]) -> RouterActionReading {
        RouterActionReading(checks: checks, urgent: urgent, instead: instead, stoppable: stoppable)
    }

    private func trace(_ d: RouterDispatcher) -> RouterTraceLog {
        let log = RouterTraceLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("router-trace-\(UUID().uuidString).jsonl"))
        d.traceLog = log
        return log
    }

    // MARK: The request

    @Test func theChecksAskEveryOpenCardAndEveryStoppableSessionInOrderThenTheTwoGlobalOnes() {
        let (s, _, _) = actionBoard()
        // A running session that waits on you is not offered a stop (its card is the question); one not running neither.
        s.claudeSessions["local_d"] = ClaudeSession(id: "local_d", title: "Idle one", folder: "/code/x", lastActivity: Date(), running: false)
        s.claudeActivity["local_c"] = ClaudeActivity(text: "running the suite", since: Date())
        let candidates = RouterActionChecks.candidates(s)
        #expect(candidates.cards.map(\.id) == ["local_b#t1", "local_a#w1"], "every open card, any kind, in the order the board lists them")
        #expect(candidates.sessions.map(\.id) == ["local_c"], "running and not waiting on you")
        let call = RouterActionChecks.call(s, candidates: candidates)
        #expect(call.order == ["dismiss0", "dismiss1", "stop0", "urgent", "instead"])
        guard case .structuredNoul(let dismiss1) = call.questions["dismiss1"], let waiting = (dismiss1 as? [String: Any])?["card"] as? [String: String] else {
            Issue.record("dismiss1 is a structured yes/no about a card")
            return
        }
        #expect(waiting == ["session": "Fix the login bug", "report": "Which database?"])
        #expect(Set(call.questions.keys) == Set(call.order))
        guard case .structuredNoul(let dismiss0) = call.questions["dismiss0"], let object = dismiss0 as? [String: Any],
              let card = object["card"] as? [String: String] else { Issue.record("dismiss0 is a structured yes/no about a card"); return }
        #expect(object["question"] as? String == "Does `message` ask to archive or drop this card, because the user will handle it or doesn't need it?")
        #expect(card == ["session": "Update the docs", "report": "Changelog entry added."])
        guard case .structuredNoul(let stop0) = call.questions["stop0"], let stop = stop0 as? [String: Any],
              let session = stop["session"] as? [String: String] else { Issue.record("stop0 is a structured yes/no about a session"); return }
        #expect(stop["question"] as? String == "Does `message` ask to stop or interrupt what this session is doing now?")
        #expect(session == ["title": "Run the CI", "project": "ci", "now": "working: running the suite"])
        guard case .structuredNoul(let urgent) = call.questions["urgent"], case .structuredNoul(let instead) = call.questions["instead"] else {
            Issue.record("urgent and instead are structured yes/no")
            return
        }
        #expect((urgent as? [String: Any])?["question"] as? String == "Does `message` ask a session to stop or change what it is doing right now, not after it finishes?")
        #expect((instead as? [String: Any])?["question"] as? String == "Besides stopping, does `message` say what to do next or instead?")
    }

    @Test func theChecksCallHasTheRoutesStateAndIsWrittenInTheirOrder() async throws {
        let (s, _, _) = actionBoard()
        var asked: (questions: [String: JevClient.Question], state: [String: String], order: [String]?)?
        let ask: JevAsker = { questions, state in
            asked = (questions, state, JevClient.questionOrder)
            return Dictionary(uniqueKeysWithValues: questions.keys.map { ($0, JevClient.Answer.noul(0.2)) })
        }
        let reading = try await RouterActionChecks.read(s, message: "stop it, key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789", tagged: nil, ask: ask)
        #expect(asked?.state["message"]?.contains("sk-ant") == false, "the message is redacted as the route's is")
        #expect(asked?.state.keys.sorted() == ["message"])
        #expect(asked?.order == ["dismiss0", "dismiss1", "stop0", "urgent", "instead"])
        #expect(reading.stoppable.isEmpty && reading.checks.count == 3 && reading.urgent == 0.2, "local_c runs by the feed alone: no turn id to name, so not stoppable")
        // On the wire the questions come in that order (a dictionary has none).
        let data = try JevClient.$questionOrder.withValue(asked?.order) {
            try JevClient.requestData(asked?.questions ?? [:], about: asked?.state ?? [:])
        }
        let text = String(decoding: data, as: UTF8.self)
        let positions = ["\"dismiss0\"", "\"dismiss1\"", "\"stop0\"", "\"urgent\"", "\"instead\""].compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == 5 && positions == positions.sorted())
    }

    // MARK: When they are asked

    @Test func theChecksAreAskedWithTheRouteAtSendAndNeverWhileTyping() async {
        let (_, d, f) = actionBoard()
        f.ranked = [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.reading = reading([])
        _ = await d.predict("add a changelog entry for this", projects: [])
        #expect(f.ranks == 1 && f.checked.isEmpty, "a draft read while typing asks the route alone")
        let a = d.submit("add a changelog entry for this")
        await finish(d, f, a)
        #expect(f.checked == ["add a changelog entry for this"], "the send asks the checks once, even for a route kept from typing")
        #expect(f.ranks == 1)
    }

    @Test func theChecksAreSkippedWhereTheRouteIs() async {
        let (_, d, f) = actionBoard()
        f.ranked = [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.reading = reading([])
        // A pinned target, an armed reply, a pick shown over the composer, an inbox action's message.
        let pinned = d.submit("add a changelog entry", context: RouterContext(target: "session:local_b"))
        await finish(d, f, pinned)
        f.finished = []
        let reply = d.submit("sqlite", context: RouterContext(replyTo: "local_a#w1"))
        await finish(d, f, reply)
        f.finished = []
        let shown = RouterDispatcher.Classification(ranked: [.init(target: "session:local_b", p: 0.9)], sure: true, assisted: true)
        let live = d.submit("add a changelog entry to the docs", context: RouterContext(jev: shown, shown: "session:local_b"))
        await finish(d, f, live)
        f.finished = []
        var context = RouterContext(projects: ["/code/docs"])
        context.action = RouterActionSource(origin: SessionOrigin(category: "Contributions", thing: "o/docs#7 Typo", actionID: "a", runID: "r"),
                                            title: "o/docs#7 Typo", model: nil, effort: nil)
        let action = d.submit("fix the typo", context: context)
        await finish(d, f, action)
        #expect(f.checked.isEmpty, "none of them reads the checks")
    }

    @Test func aChecksCallThatCantBeAnsweredLeavesTheRouteAsItIs() async {
        let (s, d, f) = actionBoard()
        f.ranked = [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.reading = nil
        let a = d.submit("add a changelog entry")
        await finish(d, f, a)
        #expect(f.checked.count == 1 && f.prepared == ["local_b"] && decision(s, a)?.done.isEmpty == false)
    }

    // MARK: Archive

    @Test func aCardTheWordsDropIsArchivedAtOnceWithRevertAndNothingIsSent() async {
        let (s, d, f) = actionBoard()
        let log = trace(d)
        defer { log.url.map { try? FileManager.default.removeItem(at: $0) } }
        f.ranked = [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.reading = reading([.init(kind: .dismiss, card: "local_a#w1", session: "local_a", p: 0.1),
                             .init(kind: .dismiss, card: "local_b#t1", session: "local_b", p: 0.95)])
        let a = d.submit("I'll handle the docs one myself")
        await finish(d, f, a)
        #expect(f.prepared.isEmpty && f.sent.isEmpty, "nothing reaches the session")
        #expect(s.router.cards.first { $0.id == "local_b#t1" }?.isOpen == false)
        let entry = decision(s, a)
        guard case .archived(let title, let change)? = entry?.done.first else { Issue.record("the line says it archived"); return }
        #expect(title == "Update the docs" && entry?.doneLines == ["archived “Update the docs”"] && entry?.links.changes == [change])
        #expect(entry?.outcome == .done && entry?.decision.targetID == "archive:card:local_b#t1" && entry?.decision.label == "archive")
        #expect(s.router.changes.contains { $0.id == change && $0.title.hasPrefix("Archive “Update the docs”") })
        // Revert puts the card back and the line says so; the trace links it to the decision.
        #expect(s.revertFjordChange(change) != nil)
        #expect(s.router.cards.first { $0.id == "local_b#t1" }?.isOpen == true)
        #expect(decision(s, a)?.outcome == .reverted)
        let lines = traceLines(d)
        let decided = lines.first { $0.id == a && $0.kind == .decided }
        #expect(decided?.action == "archive" && decided?.target == "archive:card:local_b#t1" && decided?.path == "checks")
        #expect(decided?.checks?.p["dismiss:local_b#t1"] == 0.95 && decided?.checks?.decision == "act" && decided?.checks?.why == "T")
        #expect(lines.contains { $0.id == a && $0.kind == .reverted && $0.target == "archive:card:local_b#t1" })
    }

    // MARK: Stop and interrupt

    @Test func aRunningSessionTheWordsStopAreStoppedAndNothingIsSent() async {
        let (s, d, f) = actionBoard()
        f.ranked = [.init(target: "session:local_c", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.reading = reading([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)])
        let a = d.submit("stop the CI run")
        await finish(d, f, a)
        #expect(f.stopped == ["local_c"] && f.interrupted.isEmpty && f.prepared.isEmpty && f.sent.isEmpty)
        guard case .stopped(let title, let project, _)? = decision(s, a)?.done.first else { Issue.record("the line says it stopped"); return }
        #expect(title == "Run the CI" && project == "ci" && decision(s, a)?.doneLines.first?.hasPrefix("stopped “Run the CI” (ci") == true)
        #expect(decision(s, a)?.outcome == .done && decision(s, a)?.decision.label == "stop")
    }

    @Test func stoppingWithAnythingToDoNextIsAnInterruptThatSendsTheWords() async {
        let (s, d, f) = actionBoard()
        f.ranked = [.init(target: "session:local_c", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.reading = reading([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)], instead: 0.9)
        let a = d.submit("stop that and run only the unit tests")
        await finish(d, f, a)
        #expect(f.stopped.isEmpty && f.interrupted.map(\.session) == ["local_c"] && f.interrupted.first?.text == "body-local_c")
        #expect(f.sent.isEmpty, "the interrupt is its own delivery")
        guard case .interrupted(let title, _, let stopped)? = decision(s, a)?.done.first else { Issue.record("the line says it interrupted"); return }
        #expect(title == "Run the CI" && stopped && decision(s, a)?.doneLines.first == "interrupted “Run the CI” and sent: body-local_c")
        #expect(s.lastTold()["local_c"]?.text == "stop that and run only the unit tests", "what you sent counts as told")
    }

    @Test func anUrgentWordOfChangeOnARunningTargetInterruptsIt() async {
        let (_, d, f) = actionBoard()
        f.ranked = [.init(target: "session:local_c", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.reading = reading([.init(kind: .stop, card: nil, session: "local_c", p: 0.5)], urgent: 0.9, instead: 0.8)
        let a = d.submit("no wait, use the staging config instead")
        await finish(d, f, a)
        #expect(f.interrupted.map(\.session) == ["local_c"])
    }

    @Test func aStopThatCantBeDoneSaysWhyAndAsksWhereTheWordsGoInstead() async {
        for outcome in [StopOutcome.unsupported("Fjord's plugin in this session is too old to stop a turn"), .notRunning, .idle,
                        .failed("Nobody answered")] {
            let (s, d, f) = actionBoard()
            f.ranked = [.init(target: "session:local_c", p: 0.9), .init(target: "unclear", p: 0.1)]
            f.reading = reading([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)])
            f.stopOutcome = outcome
            let a = d.submit("stop the CI run")
            await finish(d, f, a)
            let entry = decision(s, a)
            #expect(entry?.done.contains { if case .failed(let why) = $0 { why.contains("Couldn't stop") || why.contains("wasn't running") } else { false } } == true,
                    "the line says why: \(outcome)")
            let ask = d.askBacks.first { $0.id == a }
            #expect(ask?.options.map(\.target) == ["session:local_c", "open:session:local_c"])
            #expect(ask?.options.map(\.title) == ["Send to “Run the CI”", "Check the session"])
            #expect(f.sent.isEmpty)
            // "Send to X" queues the words behind its turn.
            f.finished = []
            #expect(d.pick(a!, target: "session:local_c"))
            await finish(d, f, a)
            #expect(f.prepared == ["local_c"] && f.sent.count == 1)
        }
    }

    @Test func openingTheSessionAfterAFailedStopSendsNothing() async {
        let (s, d, f) = actionBoard()
        var opened: [String] = []
        s.interceptOpen = { opened.append($0) }
        f.ranked = [.init(target: "session:local_c", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.reading = reading([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)])
        f.stopOutcome = .unsupported("too old")
        let a = d.submit("stop the CI run")
        await finish(d, f, a)
        f.finished = []
        #expect(d.pick(a!, target: "open:session:local_c"))
        await finish(d, f, a)
        #expect(opened == ["Open in Claude · Run the CI"] && f.sent.isEmpty && f.prepared.isEmpty)
        #expect(decision(s, a)?.reply == "Opened “Run the CI”: nothing was sent.")
    }

    @Test func aStopIsRefusedOnceTheRunIsOver() async {
        // The effect's gate is the run's ticket (`Effects.live`): a run that ended asks nothing of the session.
        let (s, _, _) = actionBoard()
        let tools = RouterTools(store: s)
        tools.beginTurn("stop it")
        let ticket = tools.ticket()
        #expect((try? tools.live(ticket)) != nil)
        tools.endTurn()
        #expect((try? tools.live(ticket)) == nil)
    }

    // MARK: Ask cards

    @Test func aDoubtAboutTheTargetsOwnCheckAsksWithTheActionsAsVerbs() async {
        let (s, d, f) = actionBoard()
        let log = trace(d)
        defer { log.url.map { try? FileManager.default.removeItem(at: $0) } }
        f.ranked = [.init(target: "session:local_c", p: 0.9), .init(target: "session:local_b", p: 0.05)]
        f.reading = reading([.init(kind: .stop, card: nil, session: "local_c", p: 0.62),
                             .init(kind: .dismiss, card: "local_b#t1", session: "local_b", p: 0.55)], instead: 0.7)
        let a = d.submit("hold on, the CI")
        await finish(d, f, a)
        let ask = d.askBacks.first { $0.id == a }
        // The doubt is about the target (a clear one): the other session's archive is not on the card; the route's cards follow.
        #expect(ask?.options.map(\.title) == ["Stop “Run the CI” and send this", "Send to “Run the CI”", "Send to “Update the docs”"])
        #expect(ask?.options.map(\.target) == ["interrupt:session:local_c", "session:local_c", "session:local_b"])
        #expect(f.stopped.isEmpty && f.sent.isEmpty && s.router.cards.first { $0.id == "local_b#t1" }?.isOpen == true, "nothing done until you pick")
        // Picking the first is the decision's own suggestion: through the same execution path as when it acts.
        f.finished = []
        #expect(d.pick(a!, target: "interrupt:session:local_c"))
        await finish(d, f, a)
        #expect(f.interrupted.map(\.session) == ["local_c"])
        let lines = traceLines(d)
        let decided = lines.first { $0.id == a && $0.kind == .decided }
        #expect(decided?.action == "ask" && decided?.checks?.decision == "ask" && decided?.checks?.why == "unsure")
        #expect(decided?.checks?.options?.first == "interrupt:session:local_c")
        let picked = lines.first { $0.id == a && $0.kind == .picked }
        #expect(picked?.target == "interrupt:session:local_c" && picked?.index == 0)
    }

    @Test func aPickOfAnotherActionIsACorrectionAndArchivesThroughTheSamePath() async {
        let (s, d, f) = actionBoard()
        let log = trace(d)
        defer { log.url.map { try? FileManager.default.removeItem(at: $0) } }
        // The route is unsure of the target, so every check in doubt is on the card.
        f.ranked = [.init(target: "session:local_c", p: 0.3), .init(target: "session:local_b", p: 0.25)]
        f.reading = reading([.init(kind: .stop, card: nil, session: "local_c", p: 0.62),
                             .init(kind: .dismiss, card: "local_b#t1", session: "local_b", p: 0.55)])
        let a = d.submit("hold on, the CI")
        await finish(d, f, a)
        f.finished = []
        #expect(d.pick(a!, target: "archive:card:local_b#t1"))
        await finish(d, f, a)
        #expect(s.router.cards.first { $0.id == "local_b#t1" }?.isOpen == false && f.stopped.isEmpty)
        guard case .archived? = decision(s, a)?.done.last else { Issue.record("archived through the pick"); return }
        #expect(traceLines(d).contains { $0.id == a && $0.kind == .corrected && $0.target == "archive:card:local_b#t1" })
    }

    @Test func aRouteThatAsksStillAsksWithTheChecksOverHalfFirst() async {
        let (_, d, f) = actionBoard()
        f.ranked = [.init(target: "session:local_b", p: 0.4), .init(target: "session:local_c", p: 0.35)]
        f.reading = reading([.init(kind: .dismiss, card: "local_b#t1", session: "local_b", p: 0.6)])
        let a = d.submit("and the docs too")
        await finish(d, f, a)
        let ask = d.askBacks.first { $0.id == a }
        #expect(ask?.options.first?.title == "Archive “Update the docs”")
        #expect(ask?.options.dropFirst().first?.title.hasPrefix("Send to ") == true)
    }

    @Test func anAskTheChecksBuildNeverOffersCompound() async {
        let (_, d, f) = actionBoard()
        f.ranked = [.init(target: "compound", p: 0.4), .init(target: "session:local_b", p: 0.35), .init(target: "session:local_c", p: 0.2)]
        f.reading = reading([.init(kind: .dismiss, card: "local_b#t1", session: "local_b", p: 0.6)])
        let a = d.submit("and the docs too")
        await finish(d, f, a)
        let ask = d.askBacks.first { $0.id == a }
        #expect(ask?.options.first?.title == "Archive “Update the docs”" && ask?.options.count ?? 0 >= 2)
        #expect(ask?.options.contains { $0.target == "compound" || $0.title == "Change Fjord" } == false)
    }

    @Test func withNoCheckInDoubtTheRouteGoesAsItDid() async {
        let (s, d, f) = actionBoard()
        f.ranked = [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.reading = reading([.init(kind: .dismiss, card: "local_b#t1", session: "local_b", p: 0.3),
                             .init(kind: .stop, card: nil, session: "local_c", p: 0.2)])
        let a = d.submit("add a changelog entry")
        await finish(d, f, a)
        #expect(f.prepared == ["local_b"] && f.stopped.isEmpty && f.interrupted.isEmpty && decision(s, a)?.decision.label == "reply")
    }
}
