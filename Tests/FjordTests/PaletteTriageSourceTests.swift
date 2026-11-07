import AppKit
import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite struct PaletteTriageSourceTests {
    /// What the window was asked to go to, with the pick the hub held at that moment.
    private final class Visits {
        var calls: [(destination: AppDestination, selection: String?)] = []
    }

    private let visible = "a/one"
    private let hidden = "h/hid"
    private let ci = "c/ci"

    /// Three categories: "Mine" (PRs of a/one with a low score), "Quiet" (the same of h/hid, hidden) and "CI" (c/ci workflows).
    private func store(_ things: [Thing]) -> Store {
        func category(_ name: String, repo: String, kinds: Set<ThingKind>, hidden: Bool = false, isCI: Bool = false) -> InboxCategory {
            var category = InboxCategory(
                name: name, symbol: "star", color: .blue,
                rules: [Rule(scope: Scope(kinds: kinds, in: Pick(include: [.repo(repo)])),
                             conditions: kinds.contains(.workflow) ? [] : [.greptileBelow(5)], createdAt: .distantPast)])
            category.hidden = hidden
            category.isCI = isCI
            return category
        }
        let store = InboxFixture.store(things, category: category("Mine", repo: visible, kinds: [.pr]))
        store.categories.append(category("Quiet", repo: hidden, kinds: [.pr], hidden: true))
        store.categories.append(category("CI", repo: ci, kinds: [.workflow], isCI: true))
        return store
    }

    private func context(_ store: Store, hub: HubState? = nil, visits: Visits? = nil) -> PaletteContext {
        let hub = hub ?? HubState()
        let visits = visits ?? Visits()
        return PaletteContext(store: store, navigator: AppNavigator(start: .router, defaults: nil), routerModel: RouterModel(), hub: hub,
                       go: { [hub] in visits.calls.append(($0, hub.selection)) })
    }

    private func workflow(_ n: Int, state: CheckState, minutes: Double = 5) -> Thing {
        let at = Date().addingTimeInterval(-minutes * 60)
        return Thing(id: "workflow:\(ci):\(n)@main", kind: .workflow, repo: ci, number: nil, title: "Build \(n)",
                     url: URL(string: "https://github.com/\(ci)/actions")!, createdAt: at, updatedAt: at, checks: state,
                     workflowName: "CI", branch: "main")
    }

    private func item(_ id: String, in output: PaletteSourceOutput) -> PaletteItem? { output.items.first { $0.id == id } }

    private func ago(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }

    @Test func nothingWithTriageOff() {
        let store = store([InboxFixture.pr(1)])
        #expect(!PaletteTriageSource.make(context(store)).items.isEmpty)
        store.setTool(.triage, on: false)
        let output = PaletteTriageSource.make(context(store))
        #expect(output.items.isEmpty)
        #expect(output.needsYou.isEmpty)
    }

    @Test func anInboxItemIsFoundByNumberRepoAndLink() throws {
        var thing = InboxFixture.pr(482, title: "Fix the thing", by: Person(login: "ada"))
        thing.labels = ["bug"]
        thing.status = .draft
        let output = PaletteTriageSource.make(context(store([thing])))
        let entry = try #require(item("entry:pr:a/one#482", in: output))
        #expect(entry.kind == .entry)
        #expect(entry.title == "Fix the thing")
        #expect(entry.subtitle == "a/one#482 · Mine")
        for word in ["#482", "one#482", "a/one#482", "https://github.com/a/one/pull/482", "@ada", "pull request", "PR", "draft", "bug"] {
            #expect(entry.keywords.contains(word), "missing \(word)")
        }
        #expect(entry.dot != nil)
        #expect(entry.weight == 1)
        #expect(entry.date == thing.updatedAt)
    }

    @Test func aWorkflowSaysItsNameAndBranch() throws {
        let output = PaletteTriageSource.make(context(store([workflow(7, state: .failing)])))
        let entry = try #require(output.items.first { $0.kind == .entry })
        #expect(entry.subtitle == "c/ci · CI · main · CI")
        #expect(entry.keywords.contains("workflow"))
        #expect(entry.keywords.contains("failing"))
        #expect(entry.keywords.contains("main"))
    }

    @Test func archivedItemsRankBelowAndSayTheyAreArchived() throws {
        let store = store([InboxFixture.pr(1), InboxFixture.pr(2)])
        let one = try #require(store.entries.first { $0.id == "pr:a/one#1" })
        store.finish(one)
        let output = PaletteTriageSource.make(context(store))
        let archived = try #require(item("entry:pr:a/one#1", in: output))
        let open = try #require(item("entry:pr:a/one#2", in: output))
        #expect(archived.weight == 0.6)
        #expect(archived.subtitle?.hasSuffix("· Archived") == true)
        #expect(archived.dot == nil)
        #expect(open.weight == 1)
        let titles = archived.actions.map(\.title)
        #expect(titles.contains("Back to inbox"))
        #expect(!titles.contains("Archive"))
        #expect(!titles.contains("Mark as read"))
    }

    @Test func anItemInAHiddenCategoryOpensOnGitHubFirst() throws {
        let output = PaletteTriageSource.make(context(store([InboxFixture.pr(3, repo: hidden)])))
        let entry = try #require(item("entry:pr:h/hid#3", in: output))
        #expect(entry.weight == 0.7)
        #expect(entry.actions.first?.title == "Open on GitHub")
        #expect(!entry.actions.contains { $0.title == "Show in Inbox" })
        #expect(output.needsYou.isEmpty)
    }

    @Test func anArchivedItemOfAHiddenCategoryCanStillBeShown() throws {
        let store = store([InboxFixture.pr(12, repo: hidden)])
        store.finish(try #require(store.entries.first))
        let visits = Visits()
        let entry = try #require(item("entry:pr:h/hid#12", in: PaletteTriageSource.make(context(store, visits: visits))))
        #expect(entry.actions.first?.title == "Show in Inbox")
        entry.actions[0].run()
        #expect(visits.calls.last?.destination == .done)
    }

    @Test func showInInboxFallsBackToGitHubWhenItIsNoLongerListed() throws {
        let store = store([InboxFixture.pr(13)])
        var opened: [String] = []
        store.interceptOpen = { opened.append($0) }
        let visits = Visits()
        let entry = try #require(item("entry:pr:a/one#13", in: PaletteTriageSource.make(context(store, visits: visits))))
        // Its category was hidden since the palette opened.
        store.categories[0].hidden = true
        try #require(entry.actions.first).run()
        #expect(visits.calls.isEmpty)
        #expect(opened.count == 1)
        // Triage was switched off: the same.
        store.categories[0].hidden = false
        store.setTool(.triage, on: false)
        try #require(entry.actions.first).run()
        #expect(visits.calls.isEmpty)
        #expect(opened.count == 2)
    }

    @Test func copyLinkReadsTheLinkWhenItRuns() throws {
        let store = store([workflow(60, state: .failing)])
        let entry = try #require(item("entry:workflow:c/ci:60@main", in: PaletteTriageSource.make(context(store))))
        let url = try #require(URL(string: "https://github.com/c/ci/actions/runs/99"))
        store.things["workflow:c/ci:60@main"]?.url = url
        let board = NSPasteboard.general
        let before = board.string(forType: .string)
        try #require(entry.actions.first { $0.title == "Copy link" }).run()
        #expect(board.string(forType: .string) == url.absoluteString)
        board.clearContents()
        if let before { board.setString(before, forType: .string) }
    }

    @Test func showInInboxPicksTheRowBeforeGoingThereAndScrollsToIt() throws {
        let store = store([InboxFixture.pr(4)])
        let hub = HubState()
        let visits = Visits()
        let output = PaletteTriageSource.make(context(store, hub: hub, visits: visits))
        let entry = try #require(item("entry:pr:a/one#4", in: output))
        let show = try #require(entry.actions.first)
        #expect(show.title == "Show in Inbox")
        let category = try #require(store.categories.first { $0.name == "Mine" })
        show.run()
        #expect(visits.calls.count == 1)
        #expect(visits.calls.first?.destination == .category(category.id))
        #expect(visits.calls.first?.selection == "i:pr:a/one#4")
        #expect(hub.keyboardSelection?.id == "i:pr:a/one#4")
    }

    @Test func showInInboxGoesToTheArchiveForAnArchivedItem() throws {
        let store = store([InboxFixture.pr(5)])
        store.finish(try #require(store.entries.first))
        let visits = Visits()
        let output = PaletteTriageSource.make(context(store, visits: visits))
        try #require(item("entry:pr:a/one#5", in: output)?.actions.first).run()
        #expect(visits.calls.first?.destination == .done)
    }

    @Test func theActionsRunWhatTheInboxRuns() throws {
        let store = store([InboxFixture.pr(6)])
        var opened: [String] = []
        store.interceptOpen = { opened.append($0) }
        // Made again after each change, as the palette is on each open.
        func action(_ title: String) throws -> PaletteAction {
            let entry = try #require(item("entry:pr:a/one#6", in: PaletteTriageSource.make(context(store))))
            return try #require(entry.actions.first { $0.title == title })
        }
        try action("Open on GitHub").run()
        #expect(opened.count == 1)
        #expect(store.entries.first?.isUnread == false)
        try action("Mark as unread").run()
        #expect(store.entries.first?.isUnread == true)
        try action("Mark as read").run()
        #expect(store.entries.first?.isUnread == false)
        #expect(try action("Archive").destructive)
        #expect(try action("Open on GitHub").caps == store.shortcut(.openItem).caps)
        try action("Archive").run()
        #expect(store.entries.first?.isDone == true)
        try action("Back to inbox").run()
        #expect(store.entries.first?.isDone == false)
    }

    @Test func openInRouterIsOfferedOnlyWithTheRouterOn() throws {
        let store = store([InboxFixture.pr(8)])
        var entry = try #require(item("entry:pr:a/one#8", in: PaletteTriageSource.make(context(store))))
        #expect(!entry.actions.contains { $0.title == "Open in Router" })
        store.setTool(.router, on: true)
        entry = try #require(item("entry:pr:a/one#8", in: PaletteTriageSource.make(context(store))))
        #expect(entry.actions.contains { $0.title == "Open in Router" })
    }

    @Test func aSessionStartedForAThingIsAnActionOfIt() throws {
        let store = store([InboxFixture.pr(9)])
        store.setTool(.router, on: true)
        store.threads["s1"] = AgentThread(id: "s1", title: "Fix 9", folder: nil, lastActivity: Date())
        store.actionLedger.runs["k"] = ActionRun(category: UUID(), thing: "pr:a/one#9", action: UUID(), trigger: "enter",
                                                 state: .done, at: Date(), sessionID: "s1")

        let visits = Visits()
        let output = PaletteTriageSource.make(context(store, visits: visits))
        let entry = try #require(item("entry:pr:a/one#9", in: output))
        // Idle, with no card: the Router has nothing to show, so it opens in the Claude app.
        var opened: [String] = []
        store.interceptOpen = { opened.append($0) }
        try #require(entry.actions.first { $0.title == "Open its session" }).run()
        #expect(opened == ["Open in T3 · Fix 9"])
        #expect(visits.calls.isEmpty)
    }

    @Test func aSessionUnknownToClaudeIsNotOffered() throws {
        let store = store([InboxFixture.pr(10)])
        store.actionLedger.runs["k"] = ActionRun(category: UUID(), thing: "pr:a/one#10", action: UUID(), trigger: "enter",
                                                 state: .done, at: Date(), sessionID: "gone")
        let entry = try #require(item("entry:pr:a/one#10", in: PaletteTriageSource.make(context(store))))
        #expect(!entry.actions.contains { $0.title == "Open its session" })
    }

    @Test func needsYouIsTheFiveNewestUnreadOpenItemsOfShownCategories() throws {
        var things = (1...7).map { InboxFixture.pr($0, by: Person(login: "other"), updated: ago(Double($0))) }
        things.append(InboxFixture.pr(20, by: InboxFixture.author, updated: ago(300)))
        things.append(InboxFixture.pr(30, repo: hidden, by: Person(login: "other"), updated: ago(0.5)))
        things.append(workflow(40, state: .failing, minutes: 200))
        things.append(workflow(41, state: .passing, minutes: 0.2))
        let store = store(things)
        // Read, archived and hidden ones never need you, nor does a CI item that doesn't fail.
        store.markSeen(try #require(store.entries.first { $0.id == "pr:a/one#1" }))
        store.finish(try #require(store.entries.first { $0.id == "pr:a/one#2" }))

        let output = PaletteTriageSource.make(context(store))
        #expect(output.needsYou.map(\.id) == (3...7).map { "entry:pr:a/one#\($0)" })
        for item in output.needsYou { #expect(self.item(item.id, in: output) != nil) }

        // Fewer than five: the failing workflow and an older PR of yours follow, in order of date.
        for n in 3...6 { store.markSeen(try #require(store.entries.first { $0.id == "pr:a/one#\(n)" })) }
        #expect(PaletteTriageSource.make(context(store)).needsYou.map(\.id)
                == ["entry:pr:a/one#7", "entry:workflow:c/ci:40@main", "entry:pr:a/one#20"])
    }

    @Test func eachCategoryIsAnItemThatShowsAndEdits() throws {
        let store = store([])
        let output = PaletteTriageSource.make(context(store))
        let categories = output.items.filter { $0.kind == .category }
        #expect(categories.count == 3)
        let mine = try #require(store.categories.first { $0.name == "Mine" })
        let quiet = try #require(store.categories.first { $0.name == "Quiet" })
        let shown = try #require(item("category:" + mine.id.uuidString, in: output))
        #expect(shown.title == "Mine")
        #expect(shown.subtitle == "Inbox category")
        #expect(shown.actions.map(\.title) == ["Show", "Edit"])
        let muted = try #require(item("category:" + quiet.id.uuidString, in: output))
        #expect(muted.subtitle == "Inbox category · Hidden")
        #expect(muted.actions.map(\.title) == ["Edit"])

        let visits = Visits()
        let again = PaletteTriageSource.make(context(store, visits: visits))
        try #require(item("category:" + mine.id.uuidString, in: again)?.actions.first).run()
        #expect(visits.calls.last?.destination == .category(mine.id))
        try #require(item("category:" + quiet.id.uuidString, in: again)?.actions.first).run()
        #expect(visits.calls.last?.destination == .categories)
        #expect(store.categoryEditorRequest == quiet.id)
    }

    @Test func idsAreUniqueAndStableAcrossOpens() {
        let store = store((1...20).map { InboxFixture.pr($0) } + [workflow(1, state: .failing)])
        let first = PaletteTriageSource.make(context(store)).items.map(\.id)
        let second = PaletteTriageSource.make(context(store)).items.map(\.id)
        #expect(first == second)
        #expect(Set(first).count == first.count)
        #expect(first.allSatisfy { $0.hasPrefix("entry:") || $0.hasPrefix("category:") || $0.hasPrefix("run:") })
        for item in PaletteTriageSource.make(context(store)).items {
            #expect(Set(item.actions.map(\.id)).count == item.actions.count)
            #expect(!item.actions.isEmpty)
        }
    }

    @Test func theDemoInboxMakesItemsForEveryEntry() {
        let store = Store()
        Demo.populate(store, .router)
        let output = PaletteTriageSource.make(context(store))
        #expect(output.items.filter { $0.kind == .entry }.count == store.entries.count)
        #expect(output.needsYou.count <= 5)
        #expect(!output.needsYou.isEmpty)
    }

    @Test func threeThousandItemsAreMadeQuickly() {
        let store = store((1...3000).map { InboxFixture.pr($0, title: "Change number \($0)", updated: ago(Double($0))) })
        #expect(store.entries.count == 3000)
        let clock = ContinuousClock()
        var count = 0
        let took = clock.measure { count = PaletteTriageSource.make(context(store)).items.count }
        print("PaletteTriageSource: 3000 entries in \(took)")
        #expect(count >= 3000)
        // A debug build, on a busy machine: the release budget is 5 ms.
        #expect(took < .milliseconds(150))
    }
}
