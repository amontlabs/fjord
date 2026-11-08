import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite struct ToolsTests {
    private func store() -> Store {
        let s = Store()
        s.persists = false
        return s
    }

    @Test func noToolIsOnUntilOneIsSwitchedOn() {
        let s = store()
        #expect(s.tools.isEmpty)
        #expect(s.settings.toolsPicked == nil)
        s.setTool(.triage, on: true)
        #expect(s.tools == [.triage])
        #expect(!s.toolsLinked)
    }

    @Test func withTriageOffGitHubIsNotChecked() {
        let s = store()
        s.refreshNow()
        #expect(!s.isSyncing)
        s.setHubOpen(true)
        #expect(!s.isSyncing)
    }

    @Test func withTriageOffNoAvatarIsWarmed() {
        let s = store()
        Demo.populate(s, .busy)
        #expect(!s.avatarsToWarm().isEmpty)
        s.setTool(.triage, on: false)
        #expect(s.avatarsToWarm().isEmpty)
    }

    @Test func switchingTriageOffStopsTheInboxTimerAndChecksNothingMore() async {
        let s = store()
        Demo.populate(s, .busy)
        s.inboxMemo.timer = Task {}
        s.setTool(.triage, on: false)
        #expect(s.inboxMemo.timer == nil)
        let last = s.lastSync
        await s.pollAll()
        #expect(s.lastSync == last)
    }

    @Test func withTriageOffTheWindowOpensOnTheRouter() {
        let s = store()
        Demo.populate(s, .busy)
        #expect(s.firstPlace != .router)
        s.setTool(.triage, on: false)
        #expect(s.firstPlace == .router)
    }


    @Test func anActionThatStartsASessionWaitsForTheRouterAndThenOnlyForWhatComesAfter() async {
        let performer = FakePerformer()
        var category = InboxFixture.category()
        category.actions = ActionList([.make(.askRouter(prompt: "Fix it")), .make(.rerun)])
        let s = InboxFixture.store([InboxFixture.pr(1)], category: category)
        s.actionPerformer = performer
        await s.runActions()
        // Triage alone: a PR that comes in gets no session (a re-run isn't due: its checks pass).
        s.things["pr:a/one#2"] = InboxFixture.pr(2)
        await s.runActions()
        #expect(performer.messages.isEmpty)
        // The Router on: what was already there is old news; what comes after goes to the Router.
        s.setTool(.router, on: true)
        #expect(s.toolsLinked)
        await s.runActions()
        #expect(performer.messages.isEmpty)
        s.things["pr:a/one#3"] = InboxFixture.pr(3)
        await s.runActions()
        #expect(performer.messages.map(\.parts.last) == [.pointer(.notification("pr:a/one#3"))])
    }

    @Test func jevReadsNothingOfTheInboxWithTriageOff() {
        let s = store()
        #expect(!s.jevReadsInbox && !s.jevAllows(.inbox) && !s.jevAllows(.actions))
        s.setTool(.triage, on: true)
        #expect(s.jevReadsInbox && s.jevAllows(.inbox))
    }

    @Test func eachShortcutBelongsToItsTool() {
        #expect(ShortcutAction.togglePanel.tool == nil)
        #expect(ShortcutAction.router.tool == .router)
        for action in [ShortcutAction.openItem, .toggleRead, .discard, .markAllRead, .refresh] { #expect(action.tool == .triage) }
    }
}
