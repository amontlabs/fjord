import Foundation
import Testing
@testable import Fjord

/// What keeps the Router's actions on what was judged: the turn a stop names, an interrupt whose delivery is unknown, the scope
/// of the checks, a stop cancelled while it is done, and a message split back into the composer with its pills.
@MainActor
extension RouterDispatcherTests {
    private func read(_ checks: [RouterActionCheck], turns: [String: String] = ["local_c": "turn-A"], urgent: Double = 0.05,
                      instead: Double = 0.05, stoppable: [String] = ["local_c"]) -> RouterActionReading {
        var r = RouterActionReading(checks: checks, urgent: urgent, instead: instead, stoppable: stoppable)
        r.turns = turns
        return r
    }

    private func running(_ f: Fakes) {
        f.ranked = [.init(target: "session:local_c", p: 0.9), .init(target: "unclear", p: 0.1)]
    }

    // MARK: The turn judged

    @Test func aStopFromTheChecksNamesTheTurnTheyJudged() async {
        let (_, d, f) = actionBoard()
        running(f)
        f.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)])
        let a = d.submit("stop the CI run")
        await finish(d, f, a)
        #expect(f.stopped == ["local_c"] && f.stoppedTurns == ["turn-A"])
        f.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)], instead: 0.9)
        let b = d.submit("stop that and run only the unit tests")
        await finish(d, f, b)
        #expect(f.interruptedTurns == ["turn-A"], "an interrupt names it too")
    }

    @Test func aStopPickedLaterFromAnAskStillNamesTheTurnThatWasChecked() async {
        let (_, d, f) = actionBoard()
        running(f)
        f.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.62)], instead: 0.7)
        let a = d.submit("hold on, the CI")
        await finish(d, f, a)
        let ask = d.askBacks.first { $0.id == a }
        #expect(ask?.context.turns == ["local_c": "turn-A"], "the ask carries the turn it was judged on")
        // By the time of the pick the session runs another turn: the stop still names the one checked (the plugin leaves a
        // different one alone), and the interrupt does too.
        f.finished = []
        #expect(d.pick(a!, target: "stop:session:local_c"))
        await finish(d, f, a)
        #expect(f.stoppedTurns == ["turn-A"])
        let (_, d2, f2) = actionBoard()
        running(f2)
        f2.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.62)], instead: 0.7)
        let b = d2.submit("hold on, the CI")
        await finish(d2, f2, b)
        f2.finished = []
        #expect(d2.pick(b!, target: "interrupt:session:local_c"))
        await finish(d2, f2, b)
        #expect(f2.interruptedTurns == ["turn-A"])
    }

    @Test func aStopForATurnThatIsOverSaysSoAndAsksWhereTheWordsGo() async {
        let (s, d, f) = actionBoard()
        running(f)
        f.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)])
        f.stopOutcome = .notRunning
        let a = d.submit("stop the CI run")
        await finish(d, f, a)
        #expect(decision(s, a)?.done.contains { if case .failed(let why) = $0 { why.contains("its turn had ended or another began") } else { false } } == true)
        #expect(d.askBacks.first { $0.id == a }?.options.map(\.target) == ["session:local_c", "open:session:local_c"])
        // An interrupt refused because the turn moved on asks again, too.
        let (_, d2, f2) = actionBoard()
        running(f2)
        f2.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)], instead: 0.9)
        f2.interruptOutcome = .refused("Its turn changed since you asked")
        let b = d2.submit("stop that and run only the unit tests")
        await finish(d2, f2, b)
        #expect(d2.askBacks.first { $0.id == b }?.options.map(\.target) == ["session:local_c", "open:session:local_c"])
    }

    // MARK: An interrupt whose delivery is unknown

    @Test func anInterruptWhoseAnswerWasLostIsNotOfferedAsANewSendButSentAgainWithItsNonce() async {
        let (s, d, f) = actionBoard()
        running(f)
        f.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)], instead: 0.9)
        let signed = "⟦fjord v3 cli-c 2b8f3d2e-0000-4000-8000-000000000001 1 - - 1 mac⟧\nYm9keQ=="
        f.interruptOutcomes = [.unconfirmed("The session's plugin didn't pick the message up", signed: signed),
                               .delivered(ack: "ok interrupted turn-A", interrupted: "turn-A")]
        let a = d.submit("stop that and run only the unit tests")
        await finish(d, f, a)
        let ask = d.askBacks.first { $0.id == a }
        #expect(ask?.options.map(\.target) == ["retry:session:local_c", "open:session:local_c"], "no “Send to”: it may already have gone")
        #expect(ask?.options.map(\.title) == ["Send again to “Run the CI”", "Check the session"])
        #expect(decision(s, a)?.done.contains { if case .failed(let why) = $0 { why.contains("Can't tell whether") } else { false } } == true)
        #expect(f.sent.isEmpty && f.resent == [nil])
        f.finished = []
        #expect(d.pick(a!, target: "retry:session:local_c"))
        await finish(d, f, a)
        #expect(f.resent == [nil, signed], "the very text and nonce, not a new message")
        #expect(f.interruptedTurns == ["turn-A", "turn-A"] && f.prepared == ["local_c"], "prepared once: no second message was made")
        guard case .interrupted? = decision(s, a)?.done.last else { Issue.record("the line says it interrupted"); return }
        // A failure known not to have gone still offers the words to the session.
        let (_, d2, f2) = actionBoard()
        running(f2)
        f2.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)], instead: 0.9)
        f2.interruptOutcome = .failed("The Router is off")
        let b = d2.submit("stop that and run only the unit tests")
        await finish(d2, f2, b)
        #expect(d2.askBacks.first { $0.id == b }?.options.map(\.target) == ["session:local_c", "open:session:local_c"])
    }

    @Test func aRetryThatCouldntReachThePluginKeepsTheUnknownStatusAndNeverOffersAFreshSend() async {
        let (_, d, f) = actionBoard()
        running(f)
        f.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)], instead: 0.9)
        let signed = "⟦fjord v4 cli-c 2b8f3d2e-0000-4000-8000-000000000001 1 - - 1 turn-A mac⟧\nYm9keQ=="
        f.interruptOutcomes = [.unconfirmed("no answer", signed: signed), .unsupported("Fjord's plugin isn't running in this session"),
                               .refused("already delivered"), .delivered(ack: "ok interrupted turn-A", interrupted: "turn-A")]
        let a = d.submit("stop that and run only the unit tests")
        await finish(d, f, a)
        let first = ["retry:session:local_c", "open:session:local_c"]
        #expect(d.askBacks.first { $0.id == a }?.options.map(\.target) == first)
        // The retry fails because the plugin is unavailable: nothing is known yet, so it is still Retry / Check, never "Send to".
        f.finished = []
        #expect(d.pick(a!, target: "retry:session:local_c"))
        await finish(d, f, a)
        #expect(d.askBacks.first { $0.id == a }?.options.map(\.target) == first)
        // A retry told the nonce was taken already proves nothing about the first try either.
        f.finished = []
        #expect(d.pick(a!, target: "retry:session:local_c"))
        await finish(d, f, a)
        #expect(d.askBacks.first { $0.id == a }?.options.map(\.target) == first)
        #expect(f.resent == [nil, signed, signed], "every retry is the very same text")
        // An ack for the nonce resolves it.
        f.finished = []
        #expect(d.pick(a!, target: "retry:session:local_c"))
        await finish(d, f, a)
        #expect(d.askBacks.first { $0.id == a } == nil && !d.resendsOnly(a!))
    }

    @Test func aRetryRefusedBeforeTheNonceWasClaimedIsConclusiveAndOffersTheWordsToTheSession() async {
        let (_, d, f) = actionBoard()
        running(f)
        f.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)], instead: 0.9)
        let signed = "⟦fjord v4 cli-c 2b8f3d2e-0000-4000-8000-000000000001 1 - - 1 turn-A mac⟧\nYm9keQ=="
        f.interruptOutcomes = [.unconfirmed("no answer", signed: signed), .refused("turn changed")]
        let a = d.submit("stop that and run only the unit tests")
        await finish(d, f, a)
        f.finished = []
        #expect(d.pick(a!, target: "retry:session:local_c"))
        await finish(d, f, a)
        #expect(d.askBacks.first { $0.id == a }?.options.map(\.target) == ["session:local_c", "open:session:local_c"])
        #expect(!d.resendsOnly(a!))
    }

    @Test func whileAnInterruptIsUnconfirmedNoPickResendsItsMessageElsewhere() async {
        let (_, d, f) = actionBoard()
        running(f)
        f.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)], instead: 0.9)
        f.interruptOutcomes = [.unconfirmed("no answer", signed: "⟦fjord v4 cli-c 2b8f3d2e-0000-4000-8000-000000000001 1 - - 1 turn-A mac⟧\nYm9keQ==")]
        let a = d.submit("stop that and run only the unit tests")
        await finish(d, f, a)
        #expect(d.resendsOnly(a!))
        // The same session, another session, a new one: none sends a fresh copy.
        #expect(!d.pick(a!, target: "session:local_c"))
        #expect(!d.pick(a!, target: "session:local_b"))
        #expect(!d.pick(a!, target: "new:/code/ci"))
        #expect(!d.pick(a!, folder: "/code/ci"))
        #expect(f.sent.isEmpty)
        // Only Retry and Check the session are left on the card.
        #expect(d.askBacks.first { $0.id == a }?.options.map(\.target) == ["retry:session:local_c", "open:session:local_c"])
    }

    @Test func theChecksTakeTheTurnsBeforeJevIsAskedAndASessionWithoutOneIsNotStoppable() async throws {
        func presence(_ turn: String?) -> ClaudePlugin.Presence {
            let turnJSON = turn.map { "{\"id\":\"\($0)\"}" } ?? "null"
            let json = "{\"state\":\"live\",\"capabilities\":[\"stop-v1\"],\"turn\":" + turnJSON + "}"
            return try! JSONDecoder().decode(ClaudePlugin.Presence.self, from: Data(json.utf8))
        }
        let store = Store()
        store.persists = false
        store.claudeSessions["local_a"] = ClaudeSession(id: "local_a", title: "A", folder: "/code/a", lastActivity: Date(), running: true, cliID: "cli-a")
        store.claudeSessions["local_b"] = ClaudeSession(id: "local_b", title: "B", folder: "/code/b", lastActivity: Date(), running: true, cliID: "cli-b")
        store.claudeFeed.seedPresence(["cli-a": presence("turn-A"), "cli-b": presence(nil)])
        // A ends and another turn begins while Jev is asked: the judgment is about turn-A, and turn-B isn't named.
        let reading = try await RouterActionChecks.read(store, message: "stop the A run", tagged: nil) { questions, _ in
            store.claudeFeed.seedPresence(["cli-a": presence("turn-B"), "cli-b": presence("turn-C")])
            return Dictionary(uniqueKeysWithValues: questions.keys.map { ($0, JevClient.Answer.noul(0.9)) })
        }
        #expect(reading.turns == ["local_a": "turn-A"], "read before the call")
        #expect(reading.stoppable == ["local_a"], "no known turn, not stoppable: a later turn is never authorized")
        #expect(!RouterActionChecks.allows(.stop(session: "local_b"), reading) && !RouterActionChecks.allows(.interrupt(session: "local_b"), reading))
    }

    // MARK: The checks' scope

    @Test func theChecksAreAskedAboutWhatTheRouteMayGoTo() async {
        let (s, d, f) = actionBoard()
        running(f)
        f.reading = read([])
        let a = d.submit("stop the CI run", context: RouterContext(projects: ["/code/ci"]))
        await finish(d, f, a)
        #expect(f.checkScopes.last?.projects == ["/code/ci"])
        // The candidates: only the cards and sessions of the projects, and the sessions tagged.
        s.claudeSessions["local_d"] = ClaudeSession(id: "local_d", title: "Other CI", folder: "/code/ci", lastActivity: Date(), running: true)
        let ci = RouterActionChecks.candidates(s, scope: .init(projects: ["/code/ci"]))
        #expect(ci.sessions.map(\.id).sorted() == ["local_c", "local_d"] && ci.cards.isEmpty)
        let docs = RouterActionChecks.candidates(s, scope: .init(projects: ["/code/docs"]))
        #expect(docs.sessions.isEmpty && docs.cards.map(\.id) == ["local_b#t1"])
        let tagged = RouterActionChecks.candidates(s, scope: .init(sessions: ["local_d"]))
        #expect(tagged.sessions.map(\.id) == ["local_d"] && tagged.cards.isEmpty)
        #expect(RouterActionChecks.candidates(s).sessions.count == 2, "no bound: every session that works")
    }

    @Test func anActionOnWhatTheChecksNeverSawIsNotDone() {
        let reading = RouterActionReading(checks: [.init(kind: .dismiss, card: "c1", session: "s1", p: 0.9)], stoppable: ["s1"])
        #expect(RouterActionChecks.allows(.archive(card: "c1"), reading) && !RouterActionChecks.allows(.archive(card: "c2"), reading))
        #expect(RouterActionChecks.allows(.stop(session: "s1"), reading) && !RouterActionChecks.allows(.stop(session: "s2"), reading))
        #expect(!RouterActionChecks.allows(.interrupt(session: "s2"), reading) && RouterActionChecks.allows(.say(session: "s2"), reading))
    }

    // MARK: Stopped while it is done

    @Test func aStopCancelledWhileItIsDoneAsksNothingAfterward() async {
        let (s, d, f) = actionBoard()
        running(f)
        f.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)])
        f.holdStop = true
        f.stopOutcome = .failed("Stopped; nothing was done")
        let a = d.submit("stop the CI run")
        await waitUntil { f.stopHeld != nil }
        d.stopAll()
        f.stopHeld?.resume()
        await finish(d, f, a)
        #expect(d.askBacks.isEmpty, "no “Send / Open” ask comes back after Stop dismissed the asks")
        #expect(decision(s, a)?.outcome == .done)
        // What was already done stays on the line.
        let (s2, d2, f2) = actionBoard()
        running(f2)
        f2.reading = read([.init(kind: .stop, card: nil, session: "local_c", p: 0.97)])
        f2.holdStop = true
        f2.stopOutcome = .stopped("turn-A")
        let b = d2.submit("stop the CI run")
        await waitUntil { f2.stopHeld != nil }
        d2.stopAll()
        f2.stopHeld?.resume()
        await finish(d2, f2, b)
        guard case .stopped? = decision(s2, b)?.done.first else { Issue.record("the stop that went through is on the line"); return }
        #expect(d2.askBacks.isEmpty)
    }
}
