import Foundation
import Testing
@testable import Fjord

/// The engine wired into the app: the pause as a code, the Board's places as the dispatcher's targets (Jev's and the explicit
/// ones), the message's own pill leaving to the engine's, and the setup's health.
@MainActor
@Suite(.serialized) struct RouterCourierWiringTests {
    private static let lookout = CourierPlace(id: "chan_lookout", name: "lookout", purpose: "Fjord, the Mac app",
                                              threads: [.init(id: "t1", title: "Fix the login redirect", state: "working", touched: 20),
                                                        .init(id: "t0", title: "", state: "done", touched: 10)])

    /// The engine on for the test, with `lookout` on its Board, and the pills on a fake engine that records what was sent.
    private func setup() -> (Store, RouterDispatcher, RouterDispatcherTests.Fakes, sent: () -> [CourierRequest]) {
        RouterCourier.override = true
        let (s, _, f) = RouterDispatcherTests().setup()
        // The store's own dispatcher, which the flights follow.
        let d = s.routerDispatcher
        f.install(d)
        s.routerCourierLink.take(CourierSnapshot(health: .init(tabConnected: true, signedIn: true), places: [Self.lookout]))
        final class Box { var sent: [CourierRequest] = [] }
        let box = Box()
        s.routerCourier.settleAfter = nil
        s.routerCourier.attach(RouterCourierSource(submit: { box.sent.append($0); return box.sent.count }, updates: AsyncStream { _ in }))
        return (s, d, f, { box.sent })
    }

    // MARK: The pause as a code

    @Test func thePauseCodeComesFromTheSameConditionsAsItsSentence() {
        let running = CourierDo.chromeRunning
        defer { CourierDo.chromeRunning = running }
        let cases: [(JSON, Bool, CourierPause?)] = [
            (["connected": false], false, .chromeClosed), (["connected": false], true, .chromeNotConnected),
            (["connected": true, "signed_in": false], true, .signedOut), (["connected": true, "away": true], true, .away),
            (["connected": true, "page_ok": false], true, .tabUnreadable), (["connected": true, "signed_in": true], true, nil),
        ]
        for (health, chrome, pause) in cases {
            CourierDo.chromeRunning = { chrome }
            #expect(CourierDo.pause(health) == pause)
            #expect(CourierDo.blocked(health) == pause.map(CourierDo.sentence))
        }
        // The reference's sentences, unchanged.
        #expect(CourierDo.sentence(.chromeClosed) == "Chrome isn't running" && CourierDo.sentence(.signedOut) == "signed out of claude.ai")
        #expect(CourierDo.sentence(.appClosed) == CourierDo.appClosed)
    }

    @Test func thePillPicksItsButtonByTheCodeNeverByTheSentence() {
        let pills = RouterCourierPills()
        pills.settleAfter = nil
        pills.track(1, .send(words: "run it", project: "lookout", thread: nil))
        // The sentence alone gives no button: only the code does.
        pills.apply(CourierUpdate(intentID: 1, state: .paused, cause: "signed out of claude.ai", before: nil, at: Date()))
        #expect(pills.items.first.map(RouterCourierPills.face)?.action == nil)
        let expected: [CourierPause: RouterCourierPills.Action] = [.chromeClosed: .openChrome, .chromeNotConnected: .openSetup,
                                                                   .signedOut: .signIn, .away: .openTab, .tabUnreadable: .openTab,
                                                                   .appClosed: .showClaudeApp]
        for pause in CourierPause.allCases {
            pills.apply(CourierUpdate(intentID: 1, state: .paused, cause: "whatever it says", before: nil, at: Date(), pause: pause))
            #expect(pills.items.first.map(RouterCourierPills.face)?.action == expected[pause])
        }
        // Going on again drops the code.
        pills.apply(CourierUpdate(intentID: 1, state: .sending, cause: nil, before: nil, at: Date(), pause: .signedOut))
        #expect(pills.items.first?.pause == nil)
    }

    // MARK: The Board in the app

    @Test func aSnapshotReadsTheHealthAndTheClaudeProjectsOfTheBoard() {
        let board: JSON = [
            "health": ["connected": true, "signed_in": false],
            "projects": ["chan_b": ["id": "chan_b", "name": "beta", "purpose": "the site"], "local:/code/x": ["id": "local:/code/x", "name": "x"]],
            "threads": ["t1": ["id": "t1", "project": "chan_b", "title": "Old", "touched": 1.0],
                        "t2": ["id": "t2", "project": "chan_b", "title": "New", "touched": 2.0, "state": "working"]],
        ]
        let snap = CourierSnapshot.of(board)
        #expect(snap.health == CourierSetupHealth(tabConnected: true, signedIn: false))
        #expect(snap.places.map(\.name) == ["beta"], "a local folder's project has no claude.ai project to send to")
        #expect(snap.places.first?.threads.map(\.title) == ["New", "Old"])
        #expect(CourierSnapshot.of(["health": ["connected": false, "signed_in": true]]).health == CourierSetupHealth(tabConnected: false, signedIn: nil))
    }

    @Test func theSetupHearsTheHealthNowAndAsItChanges() async {
        let link = RouterCourierLink()
        link.take(CourierSnapshot(health: .init(tabConnected: true, signedIn: nil)))
        var updates = link.healthUpdates.makeAsyncIterator()
        #expect(await updates.next() == CourierSetupHealth(tabConnected: true, signedIn: nil))
        link.take(CourierSnapshot(health: .init(tabConnected: true, signedIn: true)))
        #expect(await updates.next() == CourierSetupHealth(tabConnected: true, signedIn: true))
    }

    @Test func offNothingOfClaudeAiIsATarget() {
        RouterCourier.override = false
        defer { RouterCourier.override = nil }
        let (s, _, _) = RouterDispatcherTests().setup()
        s.routerCourierLink.take(CourierSnapshot(places: [Self.lookout]))
        #expect(!RouterTools(store: s).destinations(s).contains { $0.target.hasPrefix("claude-") })
        #expect(!s.routerDispatcher.eligible("claude-project:lookout", store: s))
        #expect(!NativeHostManifest.enabled)
    }

    // MARK: Routing

    @Test func jevIsOfferedEachClaudeProjectWithItsThreadsButNoThreadOfItsOwn() throws {
        defer { RouterCourier.override = nil }
        let (s, _, _, _) = setup()
        let destinations = RouterTools(store: s).destinations(s)
        let claude = destinations.filter { $0.target.hasPrefix("claude-") }
        #expect(claude.map(\.target) == ["claude-project:lookout"])
        let criteria = try #require(claude.first?.criteria as? [String: Any])
        #expect(criteria["its threads"] as? [String] == ["Fix the login redirect"])
        #expect(criteria["about"] as? String == "Fjord, the Mac app")
        // Local sessions and new sessions are offered as before.
        #expect(destinations.contains { $0.target == "new:/code/lookout" } && destinations.contains { $0.target.hasPrefix("answer:local_a") })
        // A message tagging local projects is for them only.
        #expect(!RouterTools(store: s).destinations(s, projects: ["/code/lookout"]).contains { $0.target.hasPrefix("claude-") })
        #expect(NativeHostManifest.enabled)
    }

    @Test func claudeTargetsAreNamedAndEligibleWhileTheBoardHasThem() {
        defer { RouterCourier.override = nil }
        let (s, d, _, _) = setup()
        #expect(d.eligible("claude-project:lookout", store: s) && d.eligible("claude-thread:lookout/t1", store: s))
        #expect(!d.eligible("claude-project:gone", store: s) && !d.eligible("claude-thread:lookout/t9", store: s))
        #expect(d.option("claude-thread:lookout/t1", store: s)?.title == "Fix the login redirect")
        #expect(d.describe("claude-project:lookout", store: s) == "claude.ai project “lookout”")
        #expect(d.pickerOptions().projects.contains { $0.target == "claude-project:lookout" })
    }

    @Test func jevsSurePickOfAClaudeProjectGoesToTheEngineAndItsPillIsTheOnlyOne() async {
        defer { RouterCourier.override = nil }
        let (s, d, f, sent) = setup()
        f.ranked = [.init(target: "claude-project:lookout", p: 0.9), .init(target: "unclear", p: 0.1)]
        f.rankSure = true
        let flights = RouterFlights()
        var context = RouterContext()
        context.flies = true
        let id = d.submit("ship the release notes", context: context)
        flights.sync(store: s)
        #expect(flights.pills.count == 1)
        await waitUntil { id.map { f.finished.contains($0) } ?? true }
        #expect(f.ranks == 1, "one routing call, as for a local target")
        await waitUntil { !sent().isEmpty }
        guard case .send(let words, let project, let thread, _)? = sent().first else { Issue.record("nothing sent to the engine"); return }
        #expect(words == "ship the release notes" && project == "lookout" && thread == nil)
        #expect(f.prepared.isEmpty && f.sent.isEmpty, "no local session was sent to")
        flights.sync(store: s)
        #expect(flights.pills.isEmpty && flights.flights.isEmpty, "the message's own pill left: the engine's says it")
        #expect(s.routerCourier.items.count == 1)
    }

    @Test func aLoneClaudeTagOrAPinGoesThereWithNoModel() async {
        defer { RouterCourier.override = nil }
        let (s, d, f, sent) = setup()
        let text = "@lookout run the release checklist"
        var context = RouterContext()
        context.tag([RouterMention(range: 0..<8, pointer: .claude("claude-project:lookout"), name: "lookout")])
        #expect(RouterDispatcher.plan(text: text, context: context, store: s) == .route("claude-project:lookout"))
        let a = d.submit(text, context: context)
        await waitUntil { a.map { f.finished.contains($0) } ?? true }
        let b = d.submit("and the changelog", context: RouterContext(target: "claude-thread:lookout/t1"))
        await waitUntil { b.map { f.finished.contains($0) } ?? true }
        #expect(f.ranks == 0, "an explicit target asks no model")
        await waitUntil { sent().count == 2 }
        guard case .send(let w1, "lookout", nil, _)? = sent().first, case .send(let w2, "lookout", "t1", _)? = sent().last else {
            Issue.record("not sent as tagged"); return
        }
        #expect(w1 == "run the release checklist", "the address pill isn't part of your words")
        #expect(w2 == "and the changelog")
        // A claude tag beside a session tag isn't the lone place: today's path decides.
        var both = RouterContext()
        both.tag([RouterMention(range: 0..<8, pointer: .claude("claude-project:lookout"), name: "lookout"),
                  RouterMention(range: 9..<27, pointer: .session("local_b"), name: "Update the docs")])
        #expect(RouterDispatcher.plan(text: "@lookout @Update the docs hi", context: both, store: s) != .route("claude-project:lookout"))
    }
}
