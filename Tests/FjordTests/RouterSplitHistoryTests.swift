import Foundation
import Testing
@testable import Fjord

/// A message that went to several places in the history and the flights (docs/design/spec/router.md, Several places): one
/// line for the message, a line for each part with its own outcome, actions and flight.
@MainActor
@Suite(.serialized) struct RouterSplitHistory {
    private func setup() -> Store {
        let s = InboxFixture.store([])
        s.router.enabled = true
        s.agents.enabled = true
        s.claudeSessions = [
            "local_a": ClaudeSession(id: "local_a", title: "Fix the login bug", folder: "/code/lookout", lastActivity: Date(), running: true),
            "local_b": ClaudeSession(id: "local_b", title: "Update the docs", folder: "/code/docs", lastActivity: Date(), running: true),
        ]
        s.agents.entries = [AgentEntry(id: "local_a"), AgentEntry(id: "local_b")]
        return s
    }

    /// Logs a message divided into three parts and returns its id and its parts' ids.
    private func divided(in s: Store) -> (id: UUID, parts: [UUID]) {
        var entry = RouterDecision(at: Date(), trigger: .you("rerun the build, then tell docs to use its version, and mute banners"))
        let ids = entry.divide(into: [
            .init(text: "rerun the build", place: "session:local_a", decision: .init(target: "Fix the login bug", intent: "message")),
            .init(text: "use its version", place: "session:local_b", waitsFor: "session:local_a",
                  decision: .init(target: "Release notes", intent: "message")),
            .init(text: "mute banners", place: "change_fjord", decision: .init(target: "Fjord", intent: "message")),
        ])
        s.router.decisions.append(entry)
        return (entry.id, ids)
    }

    // MARK: The lines

    @Test func theMessageSaysHowManyPlacesAndEachPartHasItsOwnStatusWords() throws {
        let s = setup()
        let (id, ids) = divided(in: s)
        let entry = try #require(s.router.decisions.first { $0.id == id })
        #expect(entry.placesWords == "to 3 places")
        #expect(entry.places.map(\.id) == ids && entry.places.map(\.triggerText) == ["rerun the build", "use its version", "mute banners"])
        s.updateDecision(ids[0]) { part in
            part.add(.sent(to: "Fix the login bug", text: "rerun the build", original: nil), session: "local_a")
            part.outcome = .done
        }
        s.updateDecision(ids[2]) { part in
            part.add(.failed("not delivered"))
            part.outcome = .done
        }
        let places = try #require(s.router.decisions.first { $0.id == id }).places
        #expect(places[0].summary == "sent to Fix the login bug" && places[0].summary(without: "Fix the login bug") == "sent")
        #expect(places[1].summary == "working" && RouterFlights.holds(places[1]), "a part that waits is held until you send it")
        #expect(places[2].summary == "failed" && !RouterFlights.holds(places[2]))
        s.updateDecision(ids[0]) { part in
            part.add(.cancelled(.aborted))
            part.delivered = .init(session: "local_a", cli: "c", nonce: "n", at: Date(), turns: 0, busy: false, abortable: true, cancelled: .aborted)
        }
        #expect(try #require(s.router.record(ids[0])).summary == "cancelled", "a part cancelled where it was sent says so on its own line")
        #expect(s.router.decisions[0].summary == "split in 3: 1 cancelled, 1 held, 1 failed")
        let one = RouterDecision(trigger: .you("hi"))
        #expect(one.placesWords == nil && !RouterFlights.holds(one))
    }

    @Test func aPartIsHeldOnlyUntilItWent() throws {
        let s = setup()
        let (_, ids) = divided(in: s)
        #expect(RouterFlights.holds(try #require(s.router.record(ids[1]))))
        s.updateDecision(ids[1]) { $0.add(.sent(to: "Update the docs", text: "use its version", original: nil), session: "local_b") }
        #expect(!RouterFlights.holds(try #require(s.router.record(ids[1]))), "once it went it is no longer held")
    }

    @Test func aSearchFindsAMessageByItsPartsPlaceAndOutcome() {
        let s = setup()
        divided(in: s)
        let entry = RouterPage.Entry.decision(s.router.decisions[0])
        let key = RouterSearch.key(entry, project: { _ in "" })
        #expect(RouterSearch.matches(key, RouterSearch.words("release notes")), "a part's place, which the message's words don't name")
        #expect(RouterSearch.matches(key, RouterSearch.words("use its version")))
        #expect(RouterSearch.matches(key, RouterSearch.words("fjord mute")))
        #expect(!RouterSearch.matches(key, RouterSearch.words("billing")))
    }

    // MARK: The flight

    @Test func aMessageThatDividesFansOutIntoAPillForEachPartInItsPlace() async throws {
        let s = setup()
        let flights = RouterFlights()
        flights.frames = ["now": CGRect(x: 0, y: 0, width: 800, height: 600), "nowTop": CGRect(x: 0, y: 0, width: 800, height: 40),
                          "composer": CGRect(x: 40, y: 560, width: 700, height: 44),
                          "session:local_a": CGRect(x: 20, y: 100, width: 700, height: 40),
                          "history": CGRect(x: 0, y: 40, width: 800, height: 500)]
        var entry = RouterDecision(at: Date(), trigger: .you("rerun the build, then tell docs to use its version"))
        s.router.decisions.append(entry)
        s.routerDispatcher.preview(progress: [entry.id: "classifying"], flying: [entry.id])
        flights.sync(store: s)
        #expect(flights.pills.map(\.id) == [entry.id])
        // It divides: the run's pill is replaced by one for each part, in its place.
        var ids: [UUID] = []
        s.updateDecision(entry.id) { e in
            ids = e.divide(into: [
                .init(text: "rerun the build", place: "session:local_a", decision: .init(intent: "message")),
                .init(text: "use its version", place: "session:local_b", waitsFor: "session:local_a", decision: .init(intent: "message")),
            ])
        }
        entry = try #require(s.router.decisions.first)
        s.routerDispatcher.replaceFlying(entry.id, with: ids)
        flights.sync(store: s)
        #expect(flights.pills.map(\.id) == ids && flights.pills.map(\.text) == ["rerun the build", "use its version"])
        #expect(s.routerDispatcher.flying == ids)
        // The first went to its session; the second is held for the first's answer, so its pill goes to the history.
        s.updateDecision(ids[0]) { part in
            part.add(.sent(to: "Fix the login bug", text: "rerun the build", original: nil), session: "local_a")
            part.outcome = .done
        }
        s.routerDispatcher.held[ids[1]] = "waits for session “Fix the login bug”"
        flights.sync(store: s)
        await waitUntil { flights.flights.count == 2 }
        #expect(Set(flights.flights.map(\.id)) == Set(ids) && flights.pills.isEmpty)
        #expect(flights.flights.first { $0.id == ids[0] }?.target == "session:local_a")
        #expect(flights.flights.first { $0.id == ids[1] }?.target == "history")
        #expect(flights.flights.first { $0.id == ids[1] }?.status == "held until you send it")
        #expect(flights.flights.map(\.text).sorted() == ["rerun the build", "use its version"])
        for id in ids { flights.land(id, store: s) }
        #expect(flights.flights.isEmpty && s.routerDispatcher.flying.isEmpty)
    }

    @Test func aPartsPillNamesItsPlaceAndAFailedPartStaysWithWhy() async throws {
        let s = setup()
        let flights = RouterFlights()
        let (_, ids) = divided(in: s)
        s.routerDispatcher.preview(progress: [ids[0]: "sending"], flying: ids)
        s.updateDecision(ids[0]) { $0.decision.targetID = "session:local_a" }
        flights.sync(store: s)
        #expect(flights.pills.map(\.id) == ids)
        #expect(flights.status(ids[0], store: s) == "→ Fix the login bug")
        #expect(flights.status(ids[2], store: s) == "finding where it goes")
        s.updateDecision(ids[2]) { part in
            part.add(.failed("the session's inbox is closed"))
            part.outcome = .done
        }
        s.routerDispatcher.preview(progress: [ids[0]: "sending"], flying: ids)
        flights.sync(store: s)
        #expect(flights.pills.first { $0.id == ids[2] }?.phase == .failed("the session's inbox is closed", retry: true))
        #expect(flights.pills.first { $0.id == ids[0] }?.phase == .pending)
    }
}
