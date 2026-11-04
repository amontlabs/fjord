import Foundation
import Testing
@testable import Fjord

/// Where a session Fjord starts for an action comes from, and the model and effort an action asks for it.
@MainActor
@Suite(.serialized) struct SessionStartTests {
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

    // MARK: The action


    @Test func anOverrideOutsideTheMenuIsNotPassedOn() async {
        let performer = FakePerformer()
        var action = CategoryAction.make(.askRouter(prompt: "go"))
        action.model = "--dangerously-skip-permissions"
        action.effort = "ultra"
        var category = InboxFixture.category()
        category.actions = ActionList([action])
        let store = InboxFixture.store([], category: category)
        store.router.enabled = true
        store.agents.enabled = true
        store.actionPerformer = performer
        performer.store = store
        await store.runActions()
        store.things["pr:a/one#2"] = InboxFixture.pr(2)
        await store.runActions()
        #expect(performer.messages.count == 1)
        #expect(performer.messages.first?.source.model == nil && performer.messages.first?.source.effort == nil)
    }

        @Test func anActionSavedWithoutOverridesReadsBackWithTheDefaults() throws {
        let id = UUID().uuidString
        let old = #"{"id":"\#(id)","kind":{"askRouter":{"prompt":"go"}},"trigger":"enter"}"#
        let action = try JSONDecoder().decode(CategoryAction.self, from: Data(old.utf8))
        #expect(action.model == nil && action.effort == nil && action.kind == .askRouter(prompt: "go"))
        var set = action
        set.model = "haiku"
        set.effort = "max"
        let back = try JSONDecoder().decode(CategoryAction.self, from: JSONEncoder().encode(set))
        #expect(back.model == "haiku" && back.effort == "max")
        // Saved without them when they are the defaults.
        #expect(!String(decoding: try JSONEncoder().encode(action), as: UTF8.self).contains("model"))
    }
}
