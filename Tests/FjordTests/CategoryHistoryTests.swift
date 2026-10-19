import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite(.serialized) struct CategoryHistoryTests {
    private func setup() -> (Store, CategoryHistory) {
        let store = InboxFixture.store([InboxFixture.pr(1)])
        return (store, CategoryHistory(store: store))
    }

    private func rename(_ store: Store, _ history: CategoryHistory, _ name: String, field: AnyObject? = nil, at: Date) {
        store.categories[0].name = name
        history.observe(store, field: field.map { ObjectIdentifier($0) }, now: at)
    }

    @Test func typingInOneFieldIsOneStepUntilItPauses() {
        let (store, history) = setup()
        let field = NSObject(), other = NSObject()
        let t = Date()
        rename(store, history, "R", field: field, at: t)
        rename(store, history, "Re", field: field, at: t.addingTimeInterval(0.4))
        rename(store, history, "Rev", field: field, at: t.addingTimeInterval(0.9))
        #expect(history.undos.count == 1)
        // A pause starts a new step.
        rename(store, history, "Revi", field: field, at: t.addingTimeInterval(2.5))
        #expect(history.undos.count == 2)
        // Another field does too, and a click (no field) is always its own.
        rename(store, history, "Revie", field: other, at: t.addingTimeInterval(2.6))
        store.categories[0].notifies = false
        history.observe(store, now: t.addingTimeInterval(2.7))
        #expect(history.undos.count == 4)

        #expect(history.undo(store) && store.categories[0].notifies)
        #expect(history.undo(store) && store.categories[0].name == "Revi")
        #expect(history.undo(store) && store.categories[0].name == "Rev")
        #expect(history.undo(store) && store.categories[0].name == "Mine")
        #expect(!history.undo(store) && !history.canUndo)
        #expect(history.redo(store) && store.categories[0].name == "Rev")
    }

    @Test func aNewEditClearsRedo() {
        let (store, history) = setup()
        rename(store, history, "A", at: Date())
        _ = history.undo(store)
        #expect(history.canRedo)
        rename(store, history, "B", at: Date())
        #expect(!history.canRedo && store.categories[0].name == "B")
    }

    @Test func historyKeepsOnlyTheLatestSteps() {
        let (store, history) = setup()
        for i in 1...250 { rename(store, history, "n\(i)", at: Date()) }
        var undone = 0
        while history.undo(store) { undone += 1 }
        #expect(undone == CategoryHistory.limit && store.categories[0].name == "n\(250 - CategoryHistory.limit)")
    }

    @Test func deletingACategoryAndAGroupCanBeUndone() {
        let (store, history) = setup()
        let second = InboxCategory(name: "Second", symbol: "star", color: .red, rules: [])
        store.categories.append(second)
        history.observe(store)
        let first = store.categories[0].id
        store.categories.removeAll { $0.id == first }
        history.observe(store)
        #expect(store.categories.map(\.name) == ["Second"])
        #expect(history.undo(store) && store.categories.map(\.name) == ["Mine", "Second"])
        #expect(history.redo(store) && store.categories.map(\.name) == ["Second"])

        store.groups.append(InboxGroup(name: "Friends", kind: .people))
        history.observe(store)
        store.groups.removeAll()
        history.observe(store)
        #expect(history.undo(store) && store.groups.map(\.name) == ["Friends"])
    }

    @Test func anEditNotYetObservedIsKeptByUndo() {
        let (store, history) = setup()
        store.categories[0].name = "Typed"
        #expect(history.undo(store) && store.categories[0].name == "Mine")
        #expect(history.redo(store) && store.categories[0].name == "Typed")
    }

    @Test func newCategoryIsADraftUntilCreateAndCreateNeedsAName() {
        let (store, history) = setup()
        let before = store.categories
        var draft = CategoriesView.newDraft(after: store.categories)
        #expect(draft.name.isEmpty && draft.symbol == CategoryIcon.fallback && draft.rules.count == 1)
        #expect(store.categories == before)

        // Nameless (or only spaces): nothing is made, nothing to undo.
        #expect(!store.createCategory(draft, history: history))
        draft.name = "   "
        #expect(!store.createCategory(draft, history: history))
        #expect(store.categories == before && !history.canUndo)

        // Named: it goes in at the end, trimmed, its rules new from Create, as one step.
        draft.name = "  Reviews "
        let at = Date().addingTimeInterval(60)
        #expect(store.createCategory(draft, history: history, now: at))
        #expect(store.categories.map(\.name) == before.map(\.name) + ["Reviews"])
        #expect(store.categories.last?.id == draft.id && store.categories.last?.rules.first?.createdAt == at)
        #expect(history.undo(store) && store.categories == before && !history.canUndo)
        #expect(history.redo(store) && store.categories.last?.name == "Reviews")
    }

    @Test func theDraftEditorShowsCreateAndLeavesTheStoreAlone() async throws {
        let store = InboxFixture.store([InboxFixture.pr(1)])
        let before = store.categories
        let draft = CategoriesView.newDraft(after: store.categories)
        let tree = try await AccessibilityTree.render(
            CategoriesView(store: store, preview: CategoriesPreview(editing: .new, draft: draft)).tipSpace(),
            ready: { $0.all.contains { $0.role == "AXButton" && $0.label == "Create" } })
        let buttons = tree.all.filter { $0.role == "AXButton" }.map(\.label)
        #expect(buttons.contains("Create") && !buttons.contains("Undo") && !buttons.contains("Delete category"))
        #expect(tree.all.contains { $0.role == "AXTextField" && $0.label == "Category name" })
        #expect(store.categories == before)
    }

    @Test func aGroupEditOnThePageIsTakenAsOldOnceTheEditsPauseAsARuleEditIs() async throws {
        let store = InboxFixture.store([InboxFixture.pr(1)])
        store.gh.session = StubbedGitHub.session { _ in .init(200, "{}") }
        var edited = false, waited = false
        // Once the page is drawn, a group is edited there: the actions wait for it to be taken in. Seen waiting once is
        // enough: the wait is the page's real second, and on a slow machine the tree takes longer than that to settle.
        _ = try await AccessibilityTree.render(CategoriesView(store: store).tipSpace(), ready: { tree in
            if !edited, AccessibilityTree.hasControls(tree) {
                edited = true
                store.groups.append(InboxGroup(name: "Trusted", kind: .people, members: ["carol"]))
            }
            if edited && store.baselinePending { waited = true }
            return waited
        })
        #expect(waited)
    }

    @Test func aRuleOffIsMarkedOnItsCategoryAndTheMarkOpensItsEditor() async throws {
        let trusted = InboxGroup(name: "Trusted", kind: .people, members: ["ann"])
        var category = InboxFixture.category()
        category.rules.append(Rule(scope: Scope(kinds: [.pr], to: Pick(include: [.me], except: [.group(trusted.id)]))))
        let store = InboxFixture.store([], category: category)
        store.gh.session = StubbedGitHub.session { _ in .init(200, "{}") }
        store.groups = [trusted]
        #expect(store.rulesOff(category.id) == 0)
        // The group is deleted: the rule is off, and its category says so where it shows, even with nothing in it.
        store.groups = []
        #expect(store.rulesOff(category.id) == 1)
        let tip = RulesOffMark.tip(1)
        let list = try await AccessibilityTree.render(InboxListView(store: store, tab: .category(category.id)).tipSpace(),
                                                      ready: { $0.all.contains { $0.label == tip } })
        #expect(list.all.contains { $0.label == tip })
        // Its click asks for the editor, which the categories page opens.
        var went: [AppDestination] = []
        store.editCategory(category.id) { went.append($0) }
        #expect(went == [.categories])
        let page = try await AccessibilityTree.render(CategoriesView(store: store).tipSpace(),
                                                      ready: { $0.all.contains { $0.role == "AXButton" && $0.label == "Delete category" } })
        #expect(page.all.contains { $0.role == "AXButton" && $0.label == "Delete category" })
        #expect(store.categoryEditorRequest == nil)
    }

    @Test func aRuleWithAnImpossibleChipIsOffUntilFixed() {
        let store = InboxFixture.store([InboxFixture.pr(1)])
        var rule = store.categories[0].rules[0]
        rule.scope.named = ["build"]
        #expect(!InboxEngine.problems(rule).isEmpty)
        store.categories[0].rules[0] = rule
        #expect(store.entries.isEmpty)
        store.categories[0].rules[0].scope.named = nil
        #expect(store.entries.count == 1)
    }

    @Test func nothingRunsBetweenAnEditAndItsRebaseline() async {
        let session = CategoryAction.make(.askRouter(prompt: "go"))
        var category = InboxFixture.category()
        category.actions = ActionList([session])
        let store = InboxFixture.store([InboxFixture.pr(1)], category: category)
        store.router.enabled = true
        store.agents.enabled = true
        let performer = FakePerformer()
        store.actionPerformer = performer
        await store.runActions()

        // The rules are edited so that PR 2 matches, and it was there before the edit was taken in.
        store.categories[0].rules[0].conditions = [.greptileBelow(6)]
        store.categoriesEdited(delay: .milliseconds(50))
        store.things["pr:a/one#2"] = InboxFixture.pr(2, greptile: 5)
        await store.runActions()
        #expect(performer.asked.isEmpty)

        await store.baselineTask?.value
        await store.runActions()
        #expect(performer.asked.isEmpty)

        // What comes in after is new.
        store.things["pr:a/one#3"] = InboxFixture.pr(3, greptile: 5)
        await store.runActions()
        #expect(performer.asked.count == 1)
    }
}
