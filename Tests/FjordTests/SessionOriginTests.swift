import Foundation
import Testing
@testable import Fjord

/// Where a session's cards came from: the action whose message started it.
@MainActor
@Suite(.serialized) struct SessionOriginTests {
    @Test func aCardNeverSeenBeforeIsMadeWithTheOriginAndItSurvivesSaving() throws {
        var card = RouterCard(id: "s#t1", sessionID: "s", kind: .done, title: "t", folder: nil, text: "x", createdAt: Date())
        card.origin = SessionOrigin(category: "Mine", thing: "o/r#1 T", actionID: "a", runID: "r")
        let back = try JSONDecoder().decode(RouterCard.self, from: JSONEncoder().encode(card))
        #expect(back.origin?.label == "⚡ from Mine · o/r#1 T")
        // A card saved before origins existed reads back without one.
        var plain = RouterCard(id: "s#t2", sessionID: "s", kind: .done, title: "t", folder: nil, text: "x", createdAt: Date())
        plain.origin = nil
        #expect(try JSONDecoder().decode(RouterCard.self, from: JSONEncoder().encode(plain)).origin == nil)
        var state = RouterState()
        state.origins["s"] = card.origin
        #expect(try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state)).origins["s"] == card.origin)
        #expect(try JSONDecoder().decode(RouterState.self, from: Data("{}".utf8)).origins.isEmpty)
    }
}
