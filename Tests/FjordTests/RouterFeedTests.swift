import Foundation
import Testing
@testable import Fjord

/// The rules that make and address the Router's cards (see `RouterFeed`).
@Suite struct RouterFeedRules {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func session(_ id: String = "local_a", turns: Int = 1, message: Double = -10, focused: Double? = -20,
                         summary: String? = "Did the thing", blocked: Bool = false, running: Bool = false,
                         folder: String? = "/code/app", archived: Bool = false, title: String? = nil) -> ClaudeSession {
        ClaudeSession(id: id, title: title ?? "Session \(id)", folder: folder, isArchived: archived, completedTurns: turns,
                      lastActivity: at(message), lastFocused: focused.map(at), lastUserMessage: at(message),
                      // The app writes a turn's summary once it's over: a running session has none.
                      summary: (running ? nil : summary).map { .init(blocked: blocked, detail: $0) }, running: running, cliID: "cli-\(id)")
    }

    private func question(_ since: Double, _ text: String = "Which one?", call: String? = nil) -> ClaudeActivity {
        ClaudeActivity(text: text, since: at(since), waitsForYou: true, tool: "AskUserQuestion", toolUseID: call ?? "toolu_\(since)")
    }

    /// A state that has seen `sessions` once (the first sight records only).
    private func seen(_ sessions: [ClaudeSession], activity: [String: ClaudeActivity] = [:]) -> RouterState {
        var state = RouterState()
        state.enabled = true
        RouterFeed.update(&state, sessions: sessions, activity: activity, muted: [], viewing: nil, now: at(0))
        return state
    }

    private func update(_ state: inout RouterState, _ sessions: [ClaudeSession], activity: [String: ClaudeActivity] = [:],
                        muted: Set<String> = [], viewing: String? = nil, unread: Set<String>? = nil, forms: [String: Set<String>]? = nil,
                        tasks: [String: [ClaudeTask]] = [:], inventory: Set<String>? = nil, now: Double) {
        RouterFeed.update(&state, sessions: sessions, activity: activity, muted: muted, viewing: viewing, unread: unread, forms: forms, tasks: tasks,
                          inventory: inventory, now: at(now))
    }

    @Test func theFirstSightOfASessionOnlyRecordsIt() {
        let state = seen([session(turns: 5), session("local_b", running: true)], activity: ["local_b": question(-1)])
        #expect(state.cards.isEmpty)
    }

    @Test func aFinishedTurnMakesADoneCardWithTheAppsSummary() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2, summary: "Fixed the **bug**")], now: 1)
        let card = try! #require(state.cards.first)
        #expect(state.cards.count == 1)
        #expect(card.id == "local_a#t2" && card.kind == .done && card.text == "Fixed the **bug**")
        #expect(card.title == "Session local_a" && card.folder == "/code/app" && card.isOpen && card.createdAt == at(1))
        // The same read again makes nothing new.
        update(&state, [session(turns: 2, summary: "Fixed the **bug**")], now: 2)
        #expect(state.cards.count == 1)
    }

    @Test func aNewerTurnYouWatchedEndPutsTheOlderTurnsCardPast() {
        // A turn asks you something and gets its card; you answer in the app (which clears it) and watch the next turn
        // end: no card for that one.
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2, message: 0)], now: 1)
        #expect(state.cards.map(\.id) == ["local_a#t2"] && state.cards[0].isOpen)
        update(&state, [session(turns: 2, message: 2, running: true)], viewing: "local_a", now: 2)
        update(&state, [session(turns: 3, message: 2)], viewing: "local_a", now: 3)
        #expect(state.cards.count == 1 && state.cards[0].addressedBy == .reply)
        // A question card the session still stops on isn't a turn's: left to its own rules.
        var waiting = seen([session(turns: 1)])
        update(&waiting, [session(turns: 1, running: true)], activity: ["local_a": question(1)], now: 1)
        update(&waiting, [session(turns: 2)], now: 2)
        #expect(waiting.cards.contains { !$0.kind.isTurn })
    }

    @Test func aTurnIsCardedOnceItsSummaryIsWritten() {
        // The count goes up first, the session still counting as running until the app writes the summary: no card yet.
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2, summary: nil, running: true)], now: 1)
        #expect(state.cards.isEmpty)
        update(&state, [session(turns: 2, summary: "Can't reach the server", blocked: true)], now: 2)
        #expect(state.cards.map(\.id) == ["local_a#t2"])
        #expect(state.cards.first?.text == "Can't reach the server" && state.cards.first?.kind == .stuck)
        #expect(state.cards.first?.isOpen == true)
    }

    @Test func theSummaryIsFilledInWhenItComesLater() {
        // A turn over with no summary yet (the app gave up counting it as running): the placeholder, then the summary.
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2, summary: nil, running: false)], now: 1)
        #expect(state.cards.count == 1 && state.cards.first?.kind == .done)
        update(&state, [session(turns: 2, summary: "Can't reach the server", blocked: true)], now: 2)
        #expect(state.cards.count == 1)
        #expect(state.cards.first?.text == "Can't reach the server" && state.cards.first?.kind == .stuck)
    }

    @Test func aQuestionMakesOneCardUntilItIsAnswered() {
        var state = seen([session(running: true)])
        let ask = question(0.5, "Which database?")
        update(&state, [session(running: true)], activity: ["local_a": ask], now: 1)
        #expect(state.cards.count == 1 && state.cards.first?.kind == .question && state.cards.first?.text == "Which database?")
        update(&state, [session(running: true)], activity: ["local_a": ask], now: 2)
        #expect(state.cards.count == 1 && state.cards[0].isOpen)
        // Answered (here or in the app): the session moves on.
        update(&state, [session(running: true)], activity: ["local_a": ClaudeActivity(text: "Thinking", since: at(3))], now: 3)
        #expect(state.cards[0].addressedBy == .answered && state.cards[0].addressedAt == at(3))
    }

    @Test func aPlanCardSaysThePlansTitle() {
        var state = seen([session(running: true)])
        let plan = ClaudeActivity(text: "Approve the plan: Move the cache", since: at(1), waitsForYou: true, tool: "ExitPlanMode")
        update(&state, [session(running: true)], activity: ["local_a": plan], now: 1)
        #expect(state.cards.first?.kind == .plan && state.cards.first?.text == "Move the cache")
    }

    @Test func aNewWaitAnswersTheOldOneAndCardsItself() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1, "First?")], now: 1)
        update(&state, [session(running: true)], activity: ["local_a": question(2, "Second?")], now: 2)
        #expect(state.cards.map(\.text) == ["First?", "Second?"])
        #expect(state.cards[0].addressedBy == .answered && state.cards[1].isOpen)
    }

    @Test func aWaitThatEndsWithTheTurnIsAnswered() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1)], now: 1)
        update(&state, [session(turns: 2)], now: 2)
        #expect(state.cards.map(\.kind) == [.question, .done])
        #expect(state.cards[0].addressedBy == .answered && state.cards[1].isOpen)
    }

    @Test func aNewCardSupersedesTheSessionsOpenOnes() {
        var state = seen([session(turns: 1), session("local_b", turns: 1)])
        update(&state, [session(turns: 2), session("local_b", turns: 2)], now: 1)
        update(&state, [session(turns: 3), session("local_b", turns: 2)], now: 2)
        let a = state.cards.filter { $0.sessionID == "local_a" }
        #expect(a.map(\.id) == ["local_a#t2", "local_a#t3"])
        #expect(a[0].addressedBy == .superseded && a[1].isOpen)
        #expect(state.cards.first { $0.sessionID == "local_b" }?.isOpen == true)
        #expect(state.cards.filter(\.isOpen).count == 2)
    }

    @Test func replyingInTheSessionClearsItsCardAtOnce() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 2, message: 2, running: true)], now: 2)
        #expect(state.cards[0].addressedBy == .reply && state.replies["local_a"] == RouterFeed.Stamp.ms(at(2)))
        // A message after it, with nothing left unanswered: nothing to read it for.
        update(&state, [session(turns: 2, message: 3, running: true)], now: 3)
        #expect(state.replies["local_a"] == RouterFeed.Stamp.ms(at(2)))
    }

    @Test func questionsYourReplyLeftAreYoursUntilTheNextTurnEndsWhichWentOnWithoutThem() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 2, message: 2, running: true)], now: 2)
        state.cards[0].skipped = ["Tag it?"]
        state.replies = [:]
        #expect(RouterFeed.unanswered(state.cards, "local_a", turns: 2)?.id == "local_a#t2")
        // Another message while it works may answer them: read for it.
        update(&state, [session(turns: 2, message: 3, running: true)], now: 3)
        #expect(state.replies["local_a"] == RouterFeed.Stamp.ms(at(3)))
        // The next turn's card went on without them; they are no longer yours to answer on the working line.
        update(&state, [session(turns: 3, message: 3)], now: 4)
        #expect(state.cards.map(\.id) == ["local_a#t2", "local_a#t3"] && state.cards[1].wentAhead == ["Tag it?"])
        #expect(RouterFeed.unanswered(state.cards, "local_a", turns: 3) == nil)
        // A run's message clears a card as the Router's, and isn't read again here.
        var run = RouterDecision(at: at(5), trigger: .system)
        run.delivered = .init(session: "local_a", cli: "cli-local_a", nonce: "n", at: at(5), turns: 3, busy: false, abortable: true)
        state.decisions = [run]
        state.replies = [:]
        update(&state, [session(turns: 3, message: 5, running: true)], now: 5.1)
        #expect(state.cards[1].addressedBy == .router && state.replies.isEmpty)
    }

    @Test func openingTheSessionAddressesNothing() {
        var state = seen([session(turns: 1), session("local_b", running: true)])
        update(&state, [session(turns: 2), session("local_b", running: true)], activity: ["local_b": question(1)], now: 1)
        update(&state, [session(turns: 2, focused: 2), session("local_b", focused: 2, running: true)],
               activity: ["local_b": question(1)], now: 2)
        #expect(state.cards.filter(\.isOpen).count == 2)
    }

    @Test func anArchivedOrDeletedSessionsCardsAreGone() {
        var state = seen([session(turns: 1), session("local_b", turns: 1)])
        update(&state, [session(turns: 2), session("local_b", turns: 2)], now: 1)
        update(&state, [session(turns: 2, archived: true)], now: 2)
        #expect(state.cards.allSatisfy { $0.addressedBy == .gone })
    }

    @Test func noCardForATurnYouWatchedInTheApp() {
        var state = seen([session(turns: 1, running: true)])
        update(&state, [session(turns: 1, running: true)], activity: ["local_a": question(1)], viewing: "local_a", now: 1)
        update(&state, [session(turns: 2)], viewing: "local_a", now: 2)
        #expect(state.cards.isEmpty)
        // Looking away having read it (the app shows no dot, even past its lag) doesn't bring it back.
        update(&state, [session(turns: 2)], unread: [], now: 3)
        update(&state, [session(turns: 2)], unread: [], now: 100)
        #expect(state.cards.isEmpty)
        #expect(state.pendingTurns.isEmpty)
    }

    @Test func aTurnEndedWhileYouWatchedIsCardedIfYouLeaveItUnread() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], viewing: "local_a", now: 1)
        update(&state, [session(turns: 2)], viewing: "local_a", now: 2)
        #expect(state.cards.isEmpty)
        update(&state, [session(turns: 2)], unread: ["local_a"], now: 3)
        #expect(state.cards.map(\.id) == ["local_a#t2"])
    }

    @Test func theAppsDotMayLagAfterYouLeave() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], viewing: "local_a", now: 1)
        update(&state, [session(turns: 2)], unread: [], now: 2)
        #expect(state.cards.isEmpty)
        update(&state, [session(turns: 2)], unread: ["local_a"], now: 10)
        #expect(state.cards.count == 1)
    }

    @Test func aSessionFjordStartedIsCardedAtOnceEvenWhileTheAppShowsIt() {
        var state = seen([session(turns: 0)])
        state.fjordStarted["local_a"] = at(-10)
        update(&state, [session(turns: 1, running: true)], viewing: "local_a", now: 1)
        update(&state, [session(turns: 1)], viewing: "local_a", unread: [], now: 2)
        #expect(state.cards.map(\.id) == ["local_a#t1"])
        #expect(state.pendingTurns.isEmpty)
        #expect(state.fjordStarted["local_a"] != nil)
    }

    @Test func aSessionFjordStartedWhoseTurnEndedBeforeTheFeedSawItIsCarded() {
        var state = RouterState()
        state.fjordStarted["local_a"] = at(-10)
        update(&state, [session(turns: 3, message: -9)], viewing: "local_a", unread: [], now: 1)
        #expect(state.cards.map(\.id) == ["local_a#t3"])
        #expect(state.fjordStarted["local_a"] != nil)
    }

    @Test func aQuestionInASessionFjordStartedIsCardedWhileTheAppShowsIt() {
        var state = seen([session(turns: 0, running: true)])
        state.fjordStarted["local_a"] = at(-10)
        update(&state, [session(turns: 0, running: true)], activity: ["local_a": question(1)], viewing: "local_a", now: 1)
        #expect(state.cards.map(\.kind) == [.question])
        #expect(state.heldWaits.isEmpty)
    }

    @Test func onceYouWriteInASessionFjordStartedTheUsualRulesApply() {
        var state = seen([session(turns: 1)])
        state.fjordStarted["local_a"] = at(-10)
        // A message of yours, well after the start and none of Fjord's runs sent it.
        update(&state, [session(turns: 1, message: 20)], viewing: "local_a", now: 21)
        #expect(state.fjordStarted["local_a"] == nil)
        update(&state, [session(turns: 2, message: 20)], viewing: "local_a", unread: [], now: 22)
        #expect(state.cards.isEmpty)
        update(&state, [session(turns: 2, message: 20)], unread: [], now: 100)
        #expect(state.cards.isEmpty)
    }

    /// A run that started at `started` (minutes) and delivered its message to local_a at `sent`.
    private func delivery(started: Double, sent: Double, turns: Int = 1, busy: Bool = false) -> RouterDecision {
        var run = RouterDecision(at: at(started), trigger: .system)
        run.add(.sent(to: "x", text: "hi", original: nil), session: "local_a")
        run.delivered = .init(session: "local_a", cli: "cli-local_a", nonce: "n", at: at(sent), turns: turns, busy: busy, abortable: true)
        return run
    }

    @Test func aMessageFjordSentIsNotYouWritingInTheSession() {
        var state = seen([session(turns: 1)])
        state.fjordStarted["local_a"] = at(-10)
        // Routing took a while: the message went half a minute after the run began, and shows as it went.
        state.decisions = [delivery(started: 19.5, sent: 20.1)]
        update(&state, [session(turns: 1, message: 20.1)], viewing: "local_a", now: 21)
        #expect(state.fjordStarted["local_a"] != nil)
    }

    @Test func aReplyOfYoursMinutesAfterARunSentOneIsYours() {
        // The run sent its message at 0; its turn ended, and you replied in the session two and a half minutes on.
        var state = seen([session(turns: 1)])
        state.decisions = [delivery(started: -0.2, sent: 0)]
        update(&state, [session(turns: 1, message: 0)], now: 0.1)
        #expect(state.replies.isEmpty)
        update(&state, [session(turns: 2, message: 0)], now: 1)
        #expect(state.cards.map(\.id) == ["local_a#t2"])
        update(&state, [session(turns: 2, message: 2.5, running: true)], now: 2.6)
        #expect(state.replies["local_a"] == RouterFeed.Stamp.ms(at(2.5)))
        // A run linked to the session that delivered nothing (it answered a card, say) sends no message either.
        var other = seen([session(turns: 1)])
        var linked = RouterDecision(at: at(0.5), trigger: .system)
        linked.links.sessions = ["local_a"]
        other.decisions = [linked]
        update(&other, [session(turns: 2, message: -10)], now: 1)
        update(&other, [session(turns: 2, message: 1.5, running: true)], now: 1.6)
        #expect(other.replies["local_a"] != nil)
    }

    @Test func aMessageSentWhileTheSessionWorkedShowsWhenItsTurnIsOver() {
        // Sent at 0 while turn 2 ran: Claude Code takes it once that turn is over, minutes later.
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        state.decisions = [delivery(started: -0.2, sent: 0, turns: 1, busy: true)]
        update(&state, [session(turns: 2, message: 3, running: true)], now: 3.1)
        // The card made meanwhile is cleared by it all the same, as the Router's.
        #expect(state.replies.isEmpty && state.cards[0].addressedBy == .router)
        // Its own turn over, a message is yours again.
        update(&state, [session(turns: 3, message: 3)], now: 4)
        update(&state, [session(turns: 3, message: 5, running: true)], now: 5.1)
        #expect(state.replies["local_a"] == RouterFeed.Stamp.ms(at(5)))
    }

    @Test func whatStartedASessionIsForgottenWithIt() {
        var state = RouterState()
        let origin = SessionOrigin(category: "Mine", thing: "o/r#1 T", actionID: "a", runID: "r")
        state.origins = ["local_a": origin, "local_gone": origin, "local_new": origin]
        // Just made: the app doesn't list it yet.
        state.fjordStarted["local_new"] = at(-10)
        update(&state, [session(turns: 0)], now: 1)
        #expect(state.origins.keys.sorted() == ["local_a", "local_new"])
        // An hour on, it never came.
        update(&state, [session(turns: 0)], now: 61)
        #expect(state.origins.keys.sorted() == ["local_a"])
    }

    @Test func missingFjordStartedDefaultsToEmpty() throws {
        let data = try JSONEncoder().encode(RouterState())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["fjordStarted"] = nil
        let state = try JSONDecoder().decode(RouterState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(state.fjordStarted.isEmpty)
    }

    @Test func aTurnEndedWhileTheAppIsNotInFrontIsCarded() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], viewing: nil, unread: [], now: 1)
        #expect(state.cards.map(\.id) == ["local_a#t2"])
    }

    @Test func aWaitSeenWhileWatchingIsCardedOnceYouLookAwayIfStillOn() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1)], viewing: "local_a", now: 1)
        update(&state, [session(running: true)], activity: ["local_a": question(1)], viewing: "local_a", now: 2)
        #expect(state.cards.isEmpty)
        update(&state, [session(running: true)], activity: ["local_a": question(1)], now: 3)
        #expect(state.cards.map(\.kind) == [.question])
    }

    @Test func aWaitAnsweredWhileWatchingMakesNoCard() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1)], viewing: "local_a", now: 1)
        update(&state, [session(turns: 2, running: true)], activity: [:], viewing: "local_a", now: 2)
        update(&state, [session(turns: 2, running: true)], activity: [:], now: 3)
        #expect(state.cards.isEmpty)
        #expect(state.heldWaits.isEmpty)
    }

    @Test func aWaitWhenNotWatchingIsCardedAtOnce() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1)], now: 1)
        #expect(state.cards.map(\.kind) == [.question])
    }

    @Test func mutedProjectsMakeNoCards() {
        var state = seen([session(turns: 1), session("local_b", turns: 1, folder: nil)])
        update(&state, [session(turns: 2), session("local_b", turns: 2, folder: nil)], muted: ["/code/app", ""], now: 1)
        #expect(state.cards.isEmpty)
        update(&state, [session(turns: 2), session("local_b", turns: 2, folder: nil)], now: 2)
        #expect(state.cards.isEmpty)
    }

    @Test func aCardReopenedByHandStaysOpen() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 2, message: 2)], now: 2)
        // Jev judged the reply settled it; you open it again: the same reply isn't judged again.
        state.cards[0].addressedAt = at(2)
        state.cards[0].addressedBy = .reply
        state.replies = [:]
        state.cards[0].addressedAt = nil
        state.cards[0].addressedBy = nil
        update(&state, [session(turns: 2, message: 2)], now: 3)
        #expect(state.cards[0].isOpen && state.replies.isEmpty)
    }

    @Test func aCardAlreadyMadeIsNotMadeTwice() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        // The session's state goes back (a stale read), then forward again.
        update(&state, [session(turns: 1)], now: 2)
        update(&state, [session(turns: 2)], now: 3)
        #expect(state.cards.map(\.id) == ["local_a#t2"])
    }

    @Test func openCardsFollowARenamedSession() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 2, title: "Renamed")], now: 2)
        #expect(state.cards[0].title == "Renamed")
    }

    @Test func addressingBySessionOnlyTouchesItsOpenCards() {
        var state = seen([session(turns: 1), session("local_b", turns: 1)])
        update(&state, [session(turns: 2), session("local_b", turns: 2)], now: 1)
        RouterFeed.address(&state, "local_a", .router, at(2))
        #expect(state.cards.first { $0.sessionID == "local_a" }?.addressedBy == .router)
        #expect(state.cards.first { $0.sessionID == "local_b" }?.isOpen == true)
    }

    @Test func pruningDropsTheOldestAddressedCardsAndNeverAnOpenOne() {
        var state = RouterState()
        for i in 0..<320 {
            var card = RouterCard(id: "c\(i)", sessionID: "s\(i)", kind: .done, title: "", folder: nil, text: "",
                                  createdAt: at(Double(i)))
            // The 10 oldest are open: older than every addressed one, they still stay.
            if i >= 10 { card.addressedAt = at(Double(i)); card.addressedBy = .you }
            state.cards.append(card)
        }
        RouterFeed.prune(&state)
        #expect(state.cards.filter { !$0.isOpen }.count == RouterFeed.maxCards)
        #expect(state.cards.filter(\.isOpen).count == 10)
        #expect(!state.cards.contains { $0.id == "c19" } && state.cards.contains { $0.id == "c20" })

        // All open, more than the cap: none goes.
        state.cards = (0..<305).map { RouterCard(id: "o\($0)", sessionID: "s\($0)", kind: .done, title: "", folder: nil, text: "",
                                                  createdAt: at(Double($0))) }
        RouterFeed.prune(&state)
        #expect(state.cards.count == 305)
    }

    @Test func anOldCardJustArchivedOutlastsTheCap() {
        var state = RouterState()
        state.cards = [RouterCard(id: "old", sessionID: "s-old", kind: .asks, title: "", folder: nil, text: "", createdAt: at(0))]
            + (1...RouterFeed.maxCards).map { RouterCard(id: "c\($0)", sessionID: "s\($0)", kind: .done, title: "", folder: nil, text: "",
                                                        createdAt: at(Double($0)), addressedAt: at(Double($0)), addressedBy: .you) }
        RouterFeed.address(&state, "s-old", .you, at(1000))
        RouterFeed.prune(&state)
        // The card archived now stays; the one addressed longest ago goes instead.
        #expect(state.cards.contains { $0.id == "old" } && !state.cards.contains { $0.id == "c1" })
    }

    @Test func theChangesKeepTheLatest() {
        var state = RouterState()
        state.changes = (0..<510).map {
            FjordChange(date: at(Double($0)), title: "\($0)", patch: .setting(key: "snooze", before: .date(nil), after: .date(nil)))
        }
        RouterFeed.prune(&state)
        #expect(state.changes.count == RouterFeed.maxChanges && state.changes.first?.title == "10")
    }

    @Test func aChangeWaitingForYourApplyOutlivesTheCap() {
        var state = RouterState()
        var waiting = FjordChange(date: at(0), title: "waiting", patch: .setting(key: "snooze", before: .date(nil), after: .date(nil)))
        waiting.pending = "asks first"
        state.changes = [waiting] + (1...510).map {
            FjordChange(date: at(Double($0)), title: "\($0)", patch: .setting(key: "snooze", before: .date(nil), after: .date(nil)))
        }
        RouterFeed.prune(&state)
        #expect(state.changes.count == RouterFeed.maxChanges)
        #expect(state.changes.first == waiting && state.changes[1].title == "12")
    }

    @Test func anOlderFileWithAChatAndAConversationStillLoads() throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let change = FjordChange(date: at(1), title: "Changed snooze", patch: .setting(key: "snooze", before: .date(nil), after: .date(nil)))
        let line = try JSONSerialization.jsonObject(with: enc.encode(change))
        let old: [String: Any] = [
            "enabled": true, "claudeSessionID": "abc",
            "chat": [["role": "you", "text": "hi", "date": "2026-10-09T10:00:00Z"],
                     ["role": "change", "text": "Changed snooze", "date": "2026-10-09T10:00:00Z", "change": line]],
        ]
        let state = try dec.decode(RouterState.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(state.enabled && state.changes.map(\.id) == [change.id])
        // Saved again, the chat and the conversation are gone and the changes stay.
        let saved = try JSONSerialization.jsonObject(with: enc.encode(state)) as? [String: Any]
        #expect(saved?["chat"] == nil && saved?["claudeSessionID"] == nil && (saved?["changes"] as? [Any])?.count == 1)
    }

    @Test func aSavedWaitIsTheSameWaitAfterARelaunch() throws {
        var state = seen([session(running: true)])
        let ask = ClaudeActivity(text: "Q?", since: at(1).addingTimeInterval(0.734), waitsForYou: true, tool: "AskUserQuestion")
        update(&state, [session(running: true)], activity: ["local_a": ask], now: 1)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var loaded = try dec.decode(RouterState.self, from: enc.encode(state))
        update(&loaded, [session(running: true)], activity: ["local_a": ask], now: 2)
        #expect(loaded.cards.count == 1 && loaded.cards[0].isOpen)
    }

    @Test func theStateDecodesLeniently() throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let empty = try dec.decode(RouterState.self, from: Data("{}".utf8))
        #expect(!empty.enabled && empty.cards.isEmpty && empty.changes.isEmpty)
        let odd = try dec.decode(RouterState.self, from: Data(#"{"enabled":true,"cards":[{"kind":"nope"}],"seen":3}"#.utf8))
        #expect(odd.enabled && odd.cards.isEmpty && odd.seen.isEmpty)
    }

    @Test func waitsAFractionOfASecondApartAreTwoWaits() {
        var state = seen([session(running: true)])
        let first = ClaudeActivity(text: "First?", since: at(1), waitsForYou: true, tool: "AskUserQuestion")
        let second = ClaudeActivity(text: "Second?", since: at(1).addingTimeInterval(0.7), waitsForYou: true, tool: "AskUserQuestion")
        update(&state, [session(running: true)], activity: ["local_a": first], now: 1)
        update(&state, [session(running: true)], activity: ["local_a": second], now: 2)
        #expect(state.cards.map(\.text) == ["First?", "Second?"])
        #expect(state.cards[0].addressedBy == .answered && state.cards[1].isOpen)
        // The same wait read again is the same card.
        update(&state, [session(running: true)], activity: ["local_a": second], now: 3)
        #expect(state.cards.count == 2 && state.cards[1].isOpen)
    }

    @Test func aWaitEndsOnlyOnEvidence() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1, call: "toolu_q")], forms: [:], now: 1)
        // Past the two-hour mark, after a relaunch, with nothing read yet: none of it says the question was answered.
        update(&state, [session(summary: nil, running: false)], now: 130)
        update(&state, [session(summary: nil, running: false)], forms: nil, now: 131)
        update(&state, [session(running: true)], now: 132)
        #expect(state.cards.count == 1 && state.cards[0].isOpen)
        #expect(state.cards[0].toolUseID == "toolu_q")
        // The transcript of the running session moved past the call: answered.
        update(&state, [session(running: true)], activity: ["local_a": ClaudeActivity(text: "Thinking", since: at(133))], now: 133)
        #expect(state.cards[0].addressedBy == .answered)
    }

    @Test func aPlanPastTheRunningTimeoutStaysOpen() {
        var state = seen([session(running: true)])
        let plan = ClaudeActivity(text: "Approve the plan: Move", since: at(1), waitsForYou: true, tool: "ExitPlanMode", toolUseID: "toolu_p")
        update(&state, [session(running: true)], activity: ["local_a": plan], now: 1)
        update(&state, [session(summary: nil, running: false)], now: 121)
        update(&state, [session(summary: nil, running: false)], now: 600)
        #expect(state.cards[0].kind == .plan && state.cards[0].isOpen)
        // The turn finishing (its summary is written) ends it.
        update(&state, [session(turns: 2, running: false)], now: 601)
        #expect(state.cards[0].addressedBy == .answered)
    }

    @Test func aHeldFormGoingAwayEndsItsQuestion() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1, call: "toolu_q")], forms: ["local_a": ["toolu_q"]], now: 1)
        // Forms not read yet (a relaunch): nothing is known to be gone.
        update(&state, [session(summary: nil, running: false)], forms: nil, now: 130)
        #expect(state.cards[0].isOpen)
        // Another call's form doesn't keep it; its own going away ends it.
        update(&state, [session(summary: nil, running: false)], forms: ["local_a": ["toolu_other"]], now: 131)
        #expect(state.cards[0].addressedBy == .answered)

        // A message from you ends a wait too.
        var other = seen([session(running: true)])
        update(&other, [session(running: true)], activity: ["local_a": question(1)], now: 1)
        update(&other, [session(message: 140, summary: nil, running: false)], now: 141)
        #expect(other.cards[0].addressedBy == .reply)
    }

    @Test func turningItOnAgainSettlesTheCardsLeftOpen() {
        var state = seen([session(turns: 1), session("local_b", turns: 1), session("local_c", turns: 1),
                          session("local_d", running: true), session("local_e", running: true), session("local_f", running: true)])
        update(&state, [session(turns: 2), session("local_b", turns: 2), session("local_c", turns: 2),
                        session("local_d", running: true), session("local_e", running: true), session("local_f", running: true)],
               activity: ["local_d": question(1), "local_e": question(1), "local_f": question(1, call: "toolu_f")],
               forms: ["local_f": ["toolu_f"]], now: 1)
        #expect(state.cards.filter(\.isOpen).count == 6)
        // While it was off: you replied in a, opened b (which addresses nothing), c was archived, d's question was answered; e still waits; f went
        // idle (two hours on) but its form is still held.
        let now = [session(turns: 2, message: 5, running: true), session("local_b", turns: 2, focused: 5),
                   session("local_d", running: true), session("local_e", running: true), session("local_f", summary: nil, running: false)]
        let activity = ["local_d": ClaudeActivity(text: "Thinking", since: at(5)), "local_e": question(1)]
        RouterFeed.reconcile(&state, sessions: now, activity: activity, forms: ["local_f": ["toolu_f"]], now: at(200))
        let by = Dictionary(uniqueKeysWithValues: state.cards.map { ($0.sessionID, $0.addressedBy) })
        #expect(by["local_a"] == .reply && state.replies["local_a"] != nil && by["local_b"] == RouterCard.Addressed?.none && by["local_c"] == .gone && by["local_d"] == .answered)
        #expect(by["local_e"] == RouterCard.Addressed?.none && by["local_f"] == RouterCard.Addressed?.none)
        // The next update sees every session afresh and keeps the surviving waits, carding nothing twice.
        update(&state, now, activity: activity, forms: ["local_f": ["toolu_f"]], now: 201)
        #expect(state.cards.filter(\.isOpen).map(\.sessionID).sorted() == ["local_b", "local_e", "local_f"])
        #expect(state.cards.count == 6)
    }

    @Test func reopeningACardSupersedesTheSessionsNewerOne() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 3)], now: 2)
        RouterFeed.reopen(&state, "local_a#t2", now: at(3))
        #expect(state.cards.map(\.isOpen) == [true, false])
        #expect(state.cards[1].addressedBy == .superseded)
    }

    @Test func aHandledTurnOutlastsArchivingAndIsForgottenOnlyWithItsSession() {
        var state = seen([session(turns: 2)])
        state.handledTurns = ["local_a": 2]
        // Archived: kept, so that unarchived it makes no card of that turn again.
        RouterFeed.update(&state, sessions: [session(turns: 2, archived: true)], activity: [:], muted: [], viewing: nil, now: at(1))
        #expect(state.handledTurns == ["local_a": 2])
        // Gone for good: forgotten.
        RouterFeed.update(&state, sessions: [], activity: [:], muted: [], viewing: nil, now: at(2))
        #expect(state.handledTurns.isEmpty)
        // At most `maxHandled`, those active last kept.
        let many = (0...RouterFeed.maxHandled).map { session("local_\($0)", turns: 2, message: Double($0), archived: true) }
        state.handledTurns = Dictionary(uniqueKeysWithValues: many.map { ($0.id, 2) })
        RouterFeed.update(&state, sessions: many, activity: [:], muted: [], viewing: nil, now: at(3))
        #expect(state.handledTurns.count == RouterFeed.maxHandled && state.handledTurns["local_0"] == nil && state.handledTurns["local_1"] == 2)
    }

    @Test func aReplyInTheSameSecondAsTheCardIsToldApartAfterARelaunch() throws {
        var state = seen([session(turns: 1), session("local_b", turns: 1)])
        let made = at(1).addingTimeInterval(0.2)
        RouterFeed.update(&state, sessions: [session(turns: 2), session("local_b", turns: 2)], activity: [:], muted: [], viewing: nil,
                          now: made)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        state = try dec.decode(RouterState.self, from: enc.encode(state))
        #expect(state.cards[0].createdMs == RouterFeed.Stamp.ms(made))
        // 0.5 s later, in the same second: a reply in a (which clears its card), an open of b (which addresses nothing).
        var a = session(turns: 2)
        a.lastUserMessage = made.addingTimeInterval(0.5)
        var b = session("local_b", turns: 2)
        b.lastFocused = made.addingTimeInterval(0.5)
        RouterFeed.update(&state, sessions: [a, b], activity: [:], muted: [], viewing: nil, now: made.addingTimeInterval(0.6))
        #expect(state.cards.map(\.isOpen) == [false, true] && Set(state.replies.keys) == ["local_a"])

        // A message just before a card (one with nothing else to go by), in the same second, is not a reply to it.
        let question = RouterCard(id: "local_a#w1", sessionID: "local_a", kind: .question, title: "", folder: nil, text: "",
                                  createdAt: made)
        #expect(!(RouterFeed.Stamp.ms(made.addingTimeInterval(-0.1)) > question.replyAfter))
        #expect(RouterFeed.Stamp.ms(made.addingTimeInterval(0.5)) > question.replyAfter)
    }

    @Test func oldStateFilesWithDatesStillDecode() throws {
        let json = #"{"cards":[{"id":"s#t1","sessionID":"s","kind":"done","title":"T","text":"x","createdAt":"2033-05-18T03:33:20Z"}]}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let state = try dec.decode(RouterState.self, from: Data(json.utf8))
        #expect(state.cards.first?.createdAt == Date(timeIntervalSince1970: 2_000_000_000))
    }

    /// Off, the plan (or question) is approved and the turn finishes; back on, the session says one more turn, not running,
    /// and no summary yet. The saved stamps show the turn moved: the wait is over.
    @Test(arguments: ["ExitPlanMode", "AskUserQuestion"]) func aTurnThatFinishedWhileOffEndsItsWait(tool: String) {
        var state = seen([session(turns: 3, running: true)])
        let wait = ClaudeActivity(text: "Approve the plan: Move", since: at(1), waitsForYou: true, tool: tool, toolUseID: "toolu_w")
        update(&state, [session(turns: 3, running: true)], activity: ["local_a": wait], now: 1)
        #expect(state.cards.count == 1 && state.cards[0].isOpen)
        let after = session(turns: 4, summary: nil, running: false)
        RouterFeed.reconcile(&state, sessions: [after], activity: [:], now: at(30))
        #expect(state.cards[0].addressedBy == .answered)
        update(&state, [after], now: 31)
        #expect(state.cards.filter(\.isOpen).isEmpty)
    }

    @Test func aMessageSentWhileOffEndsTheWait() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1)], now: 1)
        // The message is older than the card's second would suggest only through the stamp: it moved since the last look.
        var after = session(summary: nil, running: false)
        after.lastUserMessage = at(0.5)
        RouterFeed.reconcile(&state, sessions: [after], activity: [:], now: at(30))
        #expect(state.cards[0].addressedBy == .reply)
    }

    @Test func datesAtTheEndsOfTimeAreClampedNotATrap() throws {
        #expect(RouterFeed.Stamp.ms(Date(timeIntervalSince1970: 1e300)) == Int64(9e18))
        #expect(RouterFeed.Stamp.ms(Date(timeIntervalSince1970: -1e300)) == Int64(-9e18))
        #expect(RouterFeed.Stamp.ms(Date(timeIntervalSince1970: .nan)) == 0)
        // A session whose file says absurd times, and saved cards at either end of Int64, go through the feed.
        var state = seen([session(turns: 1)])
        var odd = session(turns: 2)
        odd.lastUserMessage = Date(timeIntervalSince1970: 1e300)
        odd.lastFocused = Date(timeIntervalSince1970: -1e300)
        let json = #"{"cards":[{"id":"x#t1","sessionID":"local_a","kind":"done","title":"","text":"","createdMs":-9223372036854775808},{"id":"y#w9223372036854775807","sessionID":"local_a","kind":"question","title":"","text":"","createdMs":9223372036854775807}],"seen":{},"waits":{"local_a":9223372036854775807}}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var loaded = try dec.decode(RouterState.self, from: Data(json.utf8))
        RouterFeed.update(&state, sessions: [odd], activity: [:], muted: [], viewing: nil, now: at(1))
        RouterFeed.update(&loaded, sessions: [odd], activity: [:], muted: [], viewing: nil, now: at(1))
        RouterFeed.reconcile(&loaded, sessions: [odd], activity: [:], now: at(2))
        _ = loaded.cards.map(\.createdAt)
        #expect(loaded.cards.count == 2)
    }

    // MARK: Turns that leave work running

    private var subagent: [String: [ClaudeTask]] {
        ["local_a": [ClaudeTask(id: "t1", kind: .agent, title: "Explore", since: at(0))]]
    }

    @Test func aTurnThatLeftWorkRunningIsCardedWhenTheWorkIsDone() {
        var state = seen([session(turns: 1)])
        // The turn is over, a subagent still runs: still working, no card.
        update(&state, [session(turns: 2, summary: nil)], tasks: subagent, now: 1)
        update(&state, [session(turns: 2, summary: "First summary")], tasks: subagent, now: 2)
        #expect(state.cards.isEmpty)
        // It's done: the card, with the summary as it is then.
        update(&state, [session(turns: 2, summary: "Merged the fix", blocked: true)], now: 3)
        #expect(state.cards.map(\.id) == ["local_a#t2"] && state.cards[0].kind == .stuck && state.cards[0].text == "Merged the fix")
        #expect(state.cards[0].createdAt == at(3))
        // Once: not again on the next read.
        update(&state, [session(turns: 2, summary: "Merged the fix", blocked: true)], now: 4)
        #expect(state.cards.count == 1)
    }

    @Test func aReplyWhileTheWorkRunsMeansNoCard() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], tasks: subagent, now: 1)
        // You wrote to it meanwhile (a new turn under way, then over before the subagent is done).
        update(&state, [session(turns: 2, message: 2, running: true)], now: 2)
        update(&state, [session(turns: 2, message: 2)], tasks: subagent, now: 3)
        update(&state, [session(turns: 2, message: 2)], now: 4)
        #expect(state.cards.isEmpty)
    }

    @Test func aNewerTurnMeanwhileGivesOneCardForTheLatest() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], tasks: subagent, now: 1)
        // Another turn ended (still with work running), then everything is done.
        update(&state, [session(turns: 3, message: 2)], tasks: subagent, now: 3)
        update(&state, [session(turns: 3, message: 2, summary: "All done")], now: 4)
        #expect(state.cards.map(\.id) == ["local_a#t3"] && state.cards[0].text == "All done")
    }

    @Test func aCardAlreadyMadeIsLeftAloneByWorkStartedLater() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 2)], tasks: subagent, now: 2)
        #expect(state.cards.count == 1 && state.cards[0].isOpen)
        update(&state, [session(turns: 2)], now: 3)
        #expect(state.cards.count == 1)
    }

    @Test func aPendingTurnSurvivesARelaunchAndTurningTheRouterOnAgain() throws {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], tasks: subagent, now: 1)
        let enc = JSONEncoder(), dec = JSONDecoder()
        enc.dateEncodingStrategy = .iso8601
        dec.dateDecodingStrategy = .iso8601
        var loaded = try dec.decode(RouterState.self, from: enc.encode(state))
        // Switched off and on: the open cards are settled and every session seen afresh; the pending turn still waits.
        RouterFeed.reconcile(&loaded, sessions: [session(turns: 2)], activity: [:], now: at(2))
        update(&loaded, [session(turns: 2)], tasks: subagent, now: 3)
        #expect(loaded.cards.isEmpty)
        update(&loaded, [session(turns: 2)], now: 4)
        #expect(loaded.cards.map(\.id) == ["local_a#t2"])
    }

    // MARK: Knowing whether a turn left work running

    @Test func aLateSummaryThenLiveTasksThenNoneGivesOneCardAfterTheTasks() {
        var state = seen([session(turns: 1)])
        // The count goes up while the session still counts as running: what it leaves running isn't known yet.
        update(&state, [session(turns: 2, summary: nil, running: true)], tasks: [:], inventory: [], now: 1)
        #expect(state.cards.isEmpty)
        // The summary is written; the read that sees it hasn't looked at its tasks yet.
        update(&state, [session(turns: 2, summary: "Done it")], tasks: [:], inventory: [], now: 2)
        #expect(state.cards.isEmpty)
        // It has: a subagent still runs.
        update(&state, [session(turns: 2, summary: "Done it")], tasks: subagent, inventory: ["local_a"], now: 3)
        #expect(state.cards.isEmpty)
        // Done: one card.
        update(&state, [session(turns: 2, summary: "Done it")], tasks: [:], inventory: ["local_a"], now: 4)
        update(&state, [session(turns: 2, summary: "Done it")], tasks: [:], inventory: ["local_a"], now: 5)
        #expect(state.cards.map(\.id) == ["local_a#t2"] && state.cards[0].createdAt == at(4))
    }

    @Test func aLateSummaryAndNoTasksGivesTheCardOnceTheReadSaysNone() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2, summary: nil, running: true)], inventory: [], now: 1)
        update(&state, [session(turns: 2, summary: "Done it")], inventory: [], now: 2)
        #expect(state.cards.isEmpty)
        update(&state, [session(turns: 2, summary: "Done it")], inventory: ["local_a"], now: 3)
        #expect(state.cards.map(\.id) == ["local_a#t2"] && state.cards[0].createdAt == at(3))
    }

    @Test func aReplyTheStoreHadntReadWhenTheTasksEndedStillAddressesTheCard() {
        // The turn ends with a command running. You reply; before the store reads the sessions again, a read of the tasks
        // alone says the command is over, with the sessions as last read (no reply yet): the card is made then.
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], tasks: subagent, inventory: ["local_a"], now: 1)
        update(&state, [session(turns: 2)], tasks: [:], inventory: ["local_a"], now: 3)
        #expect(state.cards.map(\.id) == ["local_a#t2"] && state.cards[0].isOpen)
        // The next full read has your reply, sent before the card was made: it is a reply to that turn all the same.
        update(&state, [session(turns: 2, message: 2.5, running: true)], now: 4)
        #expect(state.cards[0].addressedBy == .reply && state.replies["local_a"] == RouterFeed.Stamp.ms(at(2.5)))
    }
}
