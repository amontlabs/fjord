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

    // MARK: Routing

    @Test func claudeTargetsAreNamedAndEligibleWhileTheBoardHasThem() {
        let (s, d, _) = RouterDispatcherTests().setup()
        #expect(d.eligible("claude-project:lookout", store: s) && d.eligible("claude-thread:lookout/t1", store: s))
        #expect(!d.eligible("claude-project:gone", store: s) && !d.eligible("claude-thread:lookout/t9", store: s))
        #expect(d.option("claude-thread:lookout/t1", store: s)?.title == "Fix the login redirect")
        #expect(d.describe("claude-project:lookout", store: s) == "claude.ai project “lookout”")
        #expect(d.pickerOptions().contains { $0.target == "claude-project:lookout" })
        #expect(!d.eligible("session:local_a", store: s), "a local session is no destination")
        #expect(!NativeHostManifest.enabled, "never under a test")
    }

    @Test func aSendToAClaudeProjectLeavesItsPillToTheEngines() async {
        let (s, d, f) = RouterDispatcherTests().setup()
        f.decisions = [RouterProjectDecision(kind: .project("lookout", thread: nil), confidence: 0.9, decider: .jev)]
        let id = d.submit("ship the release notes")
        await waitUntil { id.map { f.finished.contains($0) } ?? true }
        await waitUntil { !f.requests.isEmpty }
        #expect(f.prepared.isEmpty && f.sent.isEmpty, "no local session was sent to")
        #expect(s.routerCourier.items.count == 1)
    }
}
