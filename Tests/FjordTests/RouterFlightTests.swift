import Foundation
import Testing
@testable import Fjord

/// The send-flight (`RouterFlights`): a message sent from the composer is a pill over it while the Router works, flies to
/// the place it went once it went (a session that wasn't working coming into Working for it), unfolds into the ask in place
/// when the Router isn't sure, and stays with why when it fails.
@MainActor
@Suite(.serialized) struct RouterFlightTests {
    @MainActor final class Fakes {
        var ranked: [RouterDispatcher.Scored] = []
        var failSend: String?
        /// Prepares held until the test lets them go.
        var held: CheckedContinuation<Void, Never>?
        var hold = false
        var finished: [UUID] = []

        func install(_ d: RouterDispatcher) {
            d.onFinish = { [self] in finished.append($0) }
            d.effects = RouterDispatcher.Effects(
                rank: { [self] _, _, _ in RouterDispatcher.Ranking(scored: ranked) },
                prepare: { [self] _, session in
                    if hold { await withCheckedContinuation { held = $0 } }
                    return RouterDispatcher.Delivery(to: "peer-\(session)", text: "body", body: "body", original: "body",
                                                     rephrased: false, session: session, newSessionIn: nil)
                },
                start: { _, _, _, _ in throw RouterTools.Failure("no starts here") },
                send: { [self] _, _ in
                    if let failSend { throw RouterTools.Failure(failSend) }
                    return nil
                },
                answer: { _, _, _, _ in "" },
                run: { _, _, _ in RouterRun.Answer(reply: "", done: "") })
        }
    }

    private func setup() -> (Store, RouterFlights, Fakes) {
        let s = InboxFixture.store([])
        s.router.enabled = true
        s.agents.enabled = true
        s.claudeSessions = [
            "local_a": ClaudeSession(id: "local_a", title: "Fix the login bug", folder: "/code/lookout", lastActivity: Date(), running: true),
            "local_b": ClaudeSession(id: "local_b", title: "Update the docs", folder: "/code/docs",
                                     lastActivity: Date().addingTimeInterval(-60), running: false),
        ]
        s.agents.entries = [AgentEntry(id: "local_a"), AgentEntry(id: "local_b")]
        let fakes = Fakes()
        fakes.install(s.routerDispatcher)
        let flights = RouterFlights()
        // Now's view, and the docs session's row and the Working chip in it.
        flights.frames = ["now": CGRect(x: 0, y: 0, width: 800, height: 600), "nowTop": CGRect(x: 0, y: 0, width: 800, height: 40),
                          "composer": CGRect(x: 40, y: 560, width: 700, height: 44),
                          "session:local_b": CGRect(x: 20, y: 200, width: 700, height: 40),
                          "chip:working": CGRect(x: 100, y: 10, width: 80, height: 20)]
        return (s, flights, fakes)
    }

    private func send(_ text: String, _ s: Store) -> UUID? {
        var context = RouterContext()
        context.flies = true
        return s.routerDispatcher.submit(text, context: context)
    }

    @Test func aCanvasComposerSendCreatesTheSameTrackedPill() async throws {
        let (s, _, f) = setup()
        let model = RouterModel()
        model.pickCanvas()
        f.hold = true
        f.ranked = [.init(target: "session:local_b", p: 0.9)]
        // Use the real submit seam without saving any state or reaching a real session.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/flight-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        s.stateFile = dir.appendingPathComponent("state.json")
        s.persists = true
        model.draft = "add a changelog entry to the docs"
        model.send(store: s)
        s.persists = false
        let id = try #require(s.router.decisions.last?.id)
        model.flights.sync(store: s)
        #expect(model.flights.pills.map(\.id) == [id])
        #expect(model.flights.tracking)
        #expect(model.pane == .now)
        await waitUntil { f.held != nil }
        f.held?.resume()
        await waitUntil { f.finished.contains(id) }
    }

    @Test func aComposerMessageIsAPillUntilItWentThenFliesIntoItsSessionsRow() async {
        let (s, flights, f) = setup()
        f.ranked = [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.hold = true
        let id = send("add a changelog entry to the docs", s)
        flights.sync(store: s)
        #expect(flights.pills.map(\.id) == [id].compactMap { $0 })
        await waitUntil { f.held != nil }
        flights.sync(store: s)
        #expect(flights.status(id!, store: s) == "→ Update the docs", "once Jev chose, the pill names where it goes")
        #expect(flights.flights.isEmpty, "nothing flies before it went")
        f.held?.resume()
        await waitUntil { f.finished.contains(id!) }
        flights.sync(store: s)
        await waitUntil { !flights.flights.isEmpty }
        #expect(flights.pills.isEmpty, "the flying copy takes the pill's place")
        #expect(flights.flights.first?.target == "session:local_b")
        #expect(s.claudeSessions["local_b"]?.running == true, "the finished session comes into Working to land on")
        flights.land(id!, store: s)
        #expect(flights.landed["session:local_b"] != nil && flights.flights.isEmpty)
        #expect(s.routerDispatcher.flying.isEmpty)
    }

    @Test func aCanvasFlightWaitsForItsNewWorkingRowAndLandsOnlyOnce() async throws {
        let (store, flights, fake) = setup()
        let model = RouterModel()
        model.pickCanvas()
        model.canvas.free = CGRect(x: 16, y: 56, width: 800, height: 450)
        model.canvas.viewportFrame = CGRect(x: 0, y: 40, width: 832, height: 600)
        model.canvas.camera.transform.scale = 0.5
        flights.resolvePlace = { key, fallback in
            model.canvasFlightPlace(key, frames: flights.frames, fallback: fallback, store: store)
        }
        defer { flights.resolvePlace = nil }
        flights.didLand = { model.canvas.flightLanded($0) }
        fake.ranked = [.init(target: "session:local_b", p: 0.9)]
        let id = try #require(send("add a changelog entry to the docs", store))
        let from = CGRect(x: 40, y: 520, width: 700, height: 34)
        flights.frames["pill:\(id)"] = from
        await waitUntil { fake.finished.contains(id) }
        flights.sync(store: store)
        await Task.yield()
        #expect(flights.pills.map(\.id) == [id] && flights.flights.isEmpty)
        #expect(store.claudeSessions["local_b"]?.running == true)
        // A later layout publishes the node after the finished session becomes Working.
        let node = RouterModel.workingID("local_b")
        let rect = CGRect(x: 120, y: 240, width: 210, height: 50)
        flights.frames["canvas:\(node)"] = rect
        await waitUntil { flights.flights.count == 1 }
        let flight = try #require(flights.flights.first)
        #expect(flight.from == from && flight.to == CGRect(x: 120, y: 240, width: 210, height: 26))
        #expect(flight.target == "canvas:\(node)" && flights.pills.isEmpty)
        flights.land(id, store: store)
        let landed = model.canvas.landed[node]
        #expect(flights.landed[flight.target] != nil && landed?.text == flight.text)
        flights.sync(store: store)
        flights.land(id, store: store)
        #expect(flights.flights.isEmpty && !flights.tracking && store.routerDispatcher.flying.isEmpty)
        #expect(model.canvas.landed[node] == landed)
        model.canvas.stopFlights()
    }

    @Test func aRowOutOfSightIsLandedOnByItsSectionsChip() async {
        let (s, flights, f) = setup()
        // The row is under the composer: not enough of it shows.
        flights.frames["session:local_b"] = CGRect(x: 20, y: 580, width: 700, height: 40)
        f.ranked = [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)]
        let id = send("add a changelog entry to the docs", s)
        await waitUntil { f.finished.contains(id!) }
        flights.sync(store: s)
        await waitUntil { !flights.flights.isEmpty }
        #expect(flights.flights.first?.target == "chip:working")
    }

    @Test func anAskUnfoldsInPlaceAndIsNotInNeedsYou() async {
        let (s, flights, f) = setup()
        f.ranked = [.init(target: "session:local_b", p: 0.4), .init(target: "session:local_a", p: 0.35), .init(target: "unclear", p: 0.25)]
        let id = send("ship it tomorrow", s)
        await waitUntil { f.finished.contains(id!) }
        flights.sync(store: s)
        #expect(s.routerDispatcher.askBacks.map(\.id) == [id].compactMap { $0 })
        #expect(flights.pills.first?.phase == .pending, "the pill waits as the ask, over the composer")
        #expect(s.routerPage.asks.isEmpty, "Needs you shows only the asks of messages not sent from the composer")
        // A message sent elsewhere (a notification's "Send to the Router") still asks in Needs you.
        let other = s.routerDispatcher.submit("ship it tomorrow too")
        await waitUntil { f.finished.contains(other!) }
        #expect(s.routerPage.asks.map(\.id) == [other].compactMap { $0 })
    }

    @Test(arguments: [RouterLayout.list, .canvas]) func aFailedSendStaysWithWhyAndRetrySendsItAgain(layout: RouterLayout) async {
        let (s, flights, f) = setup()
        let model = RouterModel()
        model.layout = layout
        if layout == .canvas {
            flights.resolvePlace = { key, fallback in
                model.canvasFlightPlace(key, frames: flights.frames, fallback: fallback, store: s)
            }
        }
        defer { flights.resolvePlace = nil }
        f.ranked = [.init(target: "session:local_b", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.failSend = "the session's inbox is closed"
        let id = send("add a changelog entry to the docs", s)
        await waitUntil { f.finished.contains(id!) }
        flights.sync(store: s)
        #expect(flights.pills.first?.phase == .failed("the session's inbox is closed", retry: true))
        #expect(!flights.tracking, "a failed pill goes nowhere: nothing is measured while it waits for its Retry")
        f.failSend = nil
        flights.retry(id!, store: s)
        flights.sync(store: s)
        #expect(flights.pills.count == 1 && flights.pills.first?.id != id, "sent again as a new message")
        #expect(flights.tracking, "the new message is on its way")
        #expect(!s.routerDispatcher.flying.contains(id!))
        await waitUntil { f.finished.count == 2 }
    }

    @Test func aRetrySendsAsItWasSentWithItsTagsAndTheConfirmedPlace() async {
        let (s, flights, f) = setup()
        f.ranked = [.init(target: "session:local_a", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.failSend = "the session's inbox is closed"
        var context = RouterContext()
        context.flies = true
        context.pills = [0..<6]
        context.mentions = [RouterMention(range: 0..<6, pointer: .notification("pr:o/r#1"), name: "o/r#1")]
        context.jev = .init(ranked: [], sure: true, assisted: true)
        let id = s.routerDispatcher.submit("@o/r#1 fix it", context: context)!
        await waitUntil { f.finished.contains(id) }
        // The place you picked for it (an ask answered) is the entry's confirmed one.
        s.updateDecision(id) {
            $0.decision.targetID = "session:local_b"
            $0.decision.confirmed = true
        }
        flights.sync(store: s)
        let resend = s.routerDispatcher.resendContext(id)
        #expect(resend?.mentions == context.mentions && resend?.pills == [0..<6] && resend?.flies == true)
        #expect(resend?.target == "session:local_b" && resend?.jev == nil)
        flights.retry(id, store: s)
        let new = s.routerDispatcher.flying.last
        #expect(new != nil && new != id)
        #expect(s.router.record(new!)?.mentions == context.mentions)
        await waitUntil { f.finished.contains(new!) }
        flights.sync(store: s)
        #expect(s.router.record(new!)?.decision.targetID == "session:local_b", "it goes where it went, asking nothing")
        if case .failed(let why, _)? = flights.pills.first?.phase { #expect(why.hasSuffix("tried again")) } else { Issue.record("not failed again") }
    }

    @Test func aRetryOfAMessageThatStartedASessionContinuesWithItAndOnceDeliveredDoesNot() async {
        let (s, flights, f) = setup()
        f.ranked = [.init(target: "session:local_a", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.failSend = "the session's inbox is closed"
        var context = RouterContext()
        context.flies = true
        let id = s.routerDispatcher.submit("start a session to add a changelog entry", context: context)!
        await waitUntil { f.finished.contains(id) }
        flights.sync(store: s)
        #expect(s.routerDispatcher.resendContext(id)?.reuseStart == nil)
        s.noteStart(StartReservation(uuid: "made-before", decisionID: id, folder: "/code/api", title: "T", stage: .imported, createdAt: Date()))
        #expect(s.routerDispatcher.resendContext(id)?.reuseStart == "made-before")
        s.moveStart("made-before", to: .delivered)
        #expect(s.routerDispatcher.resendContext(id)?.reuseStart == nil)
    }

    @Test func whereARunLands() {
        func entry(target: String?, done: [RouterDecision.Done], sessions: [String] = [], cards: [String] = []) -> RouterDecision {
            var e = RouterDecision(trigger: .you("x"), decision: .init(intent: "message"))
            e.decision.targetID = target
            e.done = done
            e.links.sessions = sessions
            e.links.cards = cards
            return e
        }
        #expect(RouterFlights.landing(entry(target: "answer:c1", done: [.answered(card: "Which DB?")], cards: ["c1"])) == "card:c1")
        #expect(RouterFlights.landing(entry(target: "new:/code/lcu", done: [.started(session: "local_n", project: "lcu", model: nil, effort: nil)]))
                == "session:local_n")
        #expect(RouterFlights.landing(entry(target: "session:local_b", done: [.sent(to: "p", text: "t", original: nil)], sessions: ["local_b"]))
                == "session:local_b")
        #expect(RouterFlights.landing(entry(target: "question", done: [])) == "history")
        #expect(!RouterFlights.went(entry(target: nil, done: [.asked(["a"])])))
        #expect(RouterFlights.failure(entry(target: nil, done: [.failed("no")])) == "no")
    }
}
