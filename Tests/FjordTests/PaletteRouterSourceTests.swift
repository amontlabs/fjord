import Foundation
import Testing
@testable import Fjord

/// The palette's Router source: what it lists, in what order, and what each row does.
@MainActor
@Suite struct PaletteRouterSourceTests {
    /// The places the palette's actions went to.
    private final class Went {
        var places: [AppDestination] = []
    }

    @MainActor private struct Fixture {
        let store: Store
        let model: RouterModel
        let hub: HubState
        let went = Went()

        var context: PaletteContext {
            let went = went
            return PaletteContext(store: store, navigator: AppNavigator(start: .router, defaults: nil), routerModel: model, hub: hub,
                                  go: { went.places.append($0) })
        }
    }

    private func fixture() -> Fixture {
        let store = Store()
        Demo.populate(store, .router)
        store.interceptOpen = { _ in }
        return Fixture(store: store, model: RouterModel(), hub: HubState())
    }

    private func action(_ id: String, of item: PaletteItem) throws -> PaletteAction {
        try #require(item.actions.first { $0.id == id })
    }

    @Test func theRouterOffListsNothing() {
        let f = fixture()
        f.store.setRouterEnabled(false)
        #expect(!f.store.routerOn)
        let output = PaletteRouterSource.make(f.context)
        #expect(output.needsYou.isEmpty && output.items.isEmpty)
    }

    @Test func needsYouIsTheBriefsEntriesInItsOrderWithAttentionDots() throws {
        let f = fixture()
        let output = PaletteRouterSource.make(f.context)
        let entries = f.store.routerBriefs.page().entries
        #expect(!entries.isEmpty)
        #expect(output.needsYou.map(\.id) == entries.map { "thread:" + $0.target.key })
        #expect(output.needsYou.allSatisfy { $0.kind == .thread && $0.dot == .attention && $0.weight == 1.3 })
        // The threads touched today follow them, once each.
        let recent = output.items.filter { $0.kind == .thread }.dropFirst(entries.count)
        #expect(!recent.isEmpty && recent.allSatisfy { !output.needsYou.map(\.id).contains($0.id) })
    }

    @Test func anEntrysFirstActionFocusesItAndGoesToTheRouter() throws {
        let f = fixture()
        let item = try #require(PaletteRouterSource.make(f.context).needsYou.first)
        let entry = try #require(f.store.routerBriefs.page().entries.first)
        try action("show", of: item).run()
        #expect(f.store.routerBriefs.focused == entry.target && f.went.places == [.router])
        // Archive takes it off the brief, with a change Revert sets back.
        try action("archive", of: item).run()
        #expect(!f.store.routerBriefs.page().entries.contains { $0.target == entry.target })
        let change = try #require(f.store.router.changes.last)
        #expect(change.isBriefAction)
        f.store.revertFjordChange(change.id)
        #expect(f.store.routerBriefs.page().entries.contains { $0.target == entry.target })
    }

    @Test func everySessionIsListedWithItsOwnWeight() throws {
        let f = fixture()
        let output = PaletteRouterSource.make(f.context)
        let sessions = output.items.filter { $0.kind == .session }
        #expect(sessions.count == f.store.threads.count)
        for session in f.store.threads.values {
            let item = try #require(sessions.first { $0.id == "session:" + session.id })
            let age = Date().timeIntervalSince(session.lastActivity)
            #expect(item.weight == (age < 86_400 ? 1.1 : age < 7 * 86_400 ? 1.0 : 0.8))
            #expect(item.date == session.lastActivity)
            #expect(item.title == session.title)
            if session.running {
                #expect(item.dot != nil)
                #expect(item.subtitle?.contains("Working") == true)
            }
        }
    }

    @Test func idsAreStableAndUnique() {
        let f = fixture()
        let first = PaletteRouterSource.make(f.context)
        let second = PaletteRouterSource.make(f.context)
        #expect(first.items.map(\.id) == second.items.map(\.id))
        #expect(Set(first.items.map(\.id)).count == first.items.count)
        #expect(first.items.allSatisfy { $0.id.hasPrefix("thread:") || $0.id.hasPrefix("session:") })
        #expect(first.items.allSatisfy { !$0.actions.isEmpty })
    }

    @Test func sendIsNilWhenBlankOrTheRouterCannotSend() throws {
        let f = fixture()
        #expect(PaletteRouterSource.send("", f.context) == nil)
        #expect(PaletteRouterSource.send("  \n ", f.context) == nil)
        let item = try #require(PaletteRouterSource.send("  what is blocked? ", f.context))
        #expect(item.id == "send:router" && item.kind == .send)
        #expect(item.title == "Send to the Router")
        #expect(item.subtitle == "“what is blocked?”")
        f.model.claudeCodeMissing = true
        #expect(PaletteRouterSource.send("what is blocked?", f.context) == nil)
        f.model.claudeCodeMissing = false
        f.store.setRouterEnabled(false)
        #expect(PaletteRouterSource.send("what is blocked?", f.context) == nil)
    }

    @Test func sendTruncatesALongQueryAndSendsItAndGoesToTheRouter() throws {
        let f = fixture()
        let long = String(repeating: "word ", count: 60)
        let item = try #require(PaletteRouterSource.send(long, f.context))
        #expect((item.subtitle ?? "").count < 90)
        let sent = long.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = f.store.router.decisions.count
        item.actions[0].run()
        #expect(f.went.places == [.router])
        #expect(f.store.router.decisions.count == before + 1)
        guard case .you(let text)? = f.store.router.decisions.last?.trigger else {
            Issue.record("the last decision is not yours")
            return
        }
        #expect(text == sent)
    }

    @Test func aLedgerRunLinkingASessionAddsThePRActionAndKeywords() throws {
        let f = fixture()
        let thing = try #require(f.store.entries.first { !$0.isDone && $0.thing.kind == .pr }?.thing)
        let entry = try #require(f.store.entries.first { $0.id == thing.id })
        let session = try #require(f.store.threads.values.first)
        var run = ActionRun(category: entry.categoryID, thing: thing.id, action: UUID(), trigger: "enter", state: .done, at: Date())
        run.sessionID = session.id
        f.store.actionLedger.set(run)
        let item = try #require(PaletteRouterSource.make(f.context).items.first { $0.id == "session:" + session.id })
        let link = try action("thing", of: item)
        #expect(link.title == "Open the PR")
        let number = try #require(thing.number)
        #expect(item.keywords.contains("#\(number)"))
        #expect(item.keywords.contains("\(thing.repo)#\(number)"))
        // Shown in the window on its category.
        link.run()
        #expect(f.hub.selection == "i:" + thing.id)
        let shown = f.store.triageOn && f.store.categories.first { $0.id == entry.categoryID }?.hidden == false
        #expect(f.went.places == (shown ? [.category(entry.categoryID)] : []))
        // A session without a run has no such action.
        let linked = Set(f.store.actionLedger.runs.values.compactMap(\.sessionID))
        let other = try #require(PaletteRouterSource.make(f.context).items.first {
            $0.kind == .session && !linked.contains(String($0.id.dropFirst("session:".count)))
        })
        #expect(!other.actions.contains { $0.id == "thing" })
    }

    @Test func aFewThousandSessionsAreMadeQuickly() {
        let f = fixture()
        for n in 0..<3000 {
            f.store.threads["perf-\(n)"] = AgentThread(id: "perf-\(n)", title: "Session \(n)", folder: "/code/p\(n % 40)",
                                                                lastActivity: Date().addingTimeInterval(-Double(n) * 600))
        }
        let start = ContinuousClock.now
        let output = PaletteRouterSource.make(f.context)
        let took = ContinuousClock.now - start
        #expect(output.items.count >= 3000)
        // Generous: a debug build, on a busy machine.
        #expect(took < .milliseconds(250))
    }
}
