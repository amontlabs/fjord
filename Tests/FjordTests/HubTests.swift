import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fjord

@MainActor
@Suite struct HubHover {
    enum Block: CaseIterable {
        case hidden, quiet, dragging

        @MainActor func set(_ value: Bool, on hub: HubState) {
            switch self {
            case .hidden: hub.barHidden = value
            case .quiet: hub.quiet = value
            case .dragging: hub.dragging = value
            }
        }
    }

    @Test(arguments: Block.allCases) func aBlockedBarDoesNotSwitchItsPeek(_ block: Block) {
        let hub = HubState()
        hub.section = .inbox
        block.set(true, on: hub)
        hub.enter(.router)
        #expect(hub.section == .inbox)
    }

    @Test(arguments: Block.allCases) func aBlockedBarDoesNotStartADwell(_ block: Block) async {
        let hub = HubState()
        block.set(true, on: hub)
        hub.enter(.inbox)
        block.set(false, on: hub)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(hub.section == nil)
        hub.cancelDwell()
    }

    @Test(arguments: Block.allCases) func aDwellDoesNotOpenAPeekAfterTheBarBecomesBlocked(_ block: Block) async {
        let hub = HubState()
        hub.enter(.inbox)
        block.set(true, on: hub)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(hub.section == nil)
        hub.cancelDwell()
    }

    @Test func aDwellSaysWhichSectionItWaitsOnOnlyWhileItWaits() async {
        let hub = HubState()
        hub.enter(.inbox)
        #expect(hub.arriving == .inbox && hub.section == nil)
        // The dwell (70 ms), however long a loaded machine takes to run it.
        await waitUntil { hub.section != nil }
        #expect(hub.arriving == nil && hub.section == .inbox)
        // Switching while open is at once: no dwell to wait on.
        hub.enter(.router)
        #expect(hub.arriving == nil && hub.section == .router)
    }

    @Test func aCancelledDwellWaitsOnNothing() {
        let hub = HubState()
        hub.enter(.inbox)
        hub.enter(.router)
        #expect(hub.arriving == .router)
        hub.cancelDwell()
        #expect(hub.arriving == nil && hub.section == nil)
    }

    @Test(arguments: Block.allCases) func aBlockedBarWaitsOnNothing(_ block: Block) {
        let hub = HubState()
        hub.enter(.inbox)
        block.set(true, on: hub)
        hub.enter(.router)
        #expect(hub.arriving == nil)
        hub.cancelDwell()
    }

    @Test(arguments: Block.allCases) func aDwellEndingOnABlockedBarWaitsOnNothing(_ block: Block) async {
        let hub = HubState()
        hub.enter(.inbox)
        block.set(true, on: hub)
        // The dwell wakes after 70 ms (later on a loaded machine) and finds the bar blocked.
        await waitUntil { hub.arriving == nil }
        #expect(hub.arriving == nil && hub.section == nil)
    }

    @Test func hoveringTheCurrentTabKeepsItsPickedRowAndScrollRequest() {
        let store = InboxFixture.store([])
        let hub = HubState()
        let view = FjordHub(store: store, ui: UIState(persists: false, edge: .right), hub: hub)
        let tab = store.hubTab(hub)
        // With no explicit tab, the first category is already shown.
        hub.selection = "i:a"
        hub.requestScroll("i:a")
        let scroll = hub.keyboardSelection
        view.hoverTab(tab)
        #expect(hub.selection == "i:a" && hub.keyboardSelection == scroll && hub.tab == nil)
        hub.tab = tab
        hub.selection = "i:b"
        hub.requestScroll("i:b")
        let explicitScroll = hub.keyboardSelection
        view.hoverTab(tab)
        #expect(hub.selection == "i:b" && hub.keyboardSelection == explicitScroll)
        view.hoverTab(.done)
        #expect(hub.tab == .done && hub.selection == nil && hub.keyboardSelection == nil)
    }

    @Test(arguments: Block.allCases) func aBlockedBarDoesNotChangeItsTab(_ block: Block) {
        let store = InboxFixture.store([])
        let hub = HubState()
        let view = FjordHub(store: store, ui: UIState(persists: false, edge: .right), hub: hub)
        hub.selection = "i:a"
        hub.requestScroll("i:a")
        let scroll = hub.keyboardSelection
        block.set(true, on: hub)
        view.hoverTab(.done)
        #expect(hub.tab == nil && hub.selection == "i:a" && hub.keyboardSelection == scroll)
    }
}

@MainActor
@Suite struct HubCI {
    private func workflow(_ id: Int, _ state: CheckState, repo: String = "a/one") -> Thing {
        var thing = Thing(id: "workflow:\(repo):\(id)@main", kind: .workflow, repo: repo, number: nil, title: "Fix",
                          url: URL(string: "https://github.com/\(repo)/actions")!, createdAt: Date(), updatedAt: Date())
        thing.checks = state
        thing.workflowName = "W\(id)"
        thing.branch = "main"
        return thing
    }

    @Test func aSaveThatCannotBeMadeIsSaidEvenOfflineOrSignedOut() {
        let store = InboxFixture.store([])
        let hub = FjordHub(store: store, ui: UIState(persists: false, edge: .right), hub: HubState())
        store.actionsSaveProblem = "Saving actions.json failed: full"
        store.unreachable = true
        var s = hub.sync(now: Date())
        #expect(s.text == "Not saved" && s.detail?.contains("full") == true && s.detail?.contains("couldn't reach GitHub") == true)
        store.authError = "GitHub rejected the token"
        s = hub.sync(now: Date())
        #expect(s.text == "Not saved" && s.detail?.contains("can't sign in to GitHub") == true)
        // Saved again: GitHub's state is back.
        store.actionsSaveProblem = nil
        #expect(hub.sync(now: Date()).text == "Sign-in problem")
    }

    @Test func actionsWaitingForWhatCantBeReadAreSaidInTheInboxStatus() {
        var made = InboxCategory(name: "New", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.repo("o/new")])))
        ])
        made.actions = ActionList([CategoryAction.make(.comment("Thanks"))])
        let store = InboxFixture.store([], category: made)
        let hub = FjordHub(store: store, ui: UIState(persists: false, edge: .right), hub: HubState())
        store.fetchedFor = .keys([])
        store.inboxError = "Something went wrong"
        #expect(hub.sync(now: Date()).detail?.contains("Actions paused") == false)
        // An edit waits for its repo's search, which keeps failing: it is said.
        store.baselinePending = true
        store.baselineAwaitsFetch = true
        let s = hub.sync(now: Date())
        #expect(s.text == "Inbox didn't sync" && s.detail?.contains("Actions paused until o/new can be read") == true)
    }

    @Test func theCIBadgeCountsFailingWorkflowsNotRepos() {
        var ci = InboxStore.ci
        ci.rules = [Rule(scope: Scope(kinds: [.workflow], in: Pick(include: [.repo("a/one"), .repo("b/two")])),
                         conditions: [.workflow([.failing])], createdAt: .distantPast)]
        // Two failing workflows in one repo, one passing, one running, one failing in another repo.
        let store = InboxFixture.store([workflow(1, .failing), workflow(2, .failing), workflow(3, .passing), workflow(4, .pending),
                                        workflow(5, .failing, repo: "b/two")], category: ci)
        #expect(store.count(ci.id) == 3 && store.badge(ci) == 3)
        #expect(store.entries(in: ci.id).allSatisfy { $0.thing.checks == .failing })
        // The same workflow failing again after it was fine is a new failure: Done holds only while it keeps failing.
        let entry = store.entries(in: ci.id)[0]
        store.markDone(entry)
        #expect(store.count(ci.id) == 2)
    }
}

@Suite struct CappedScrollFit {
    @Test func stopsOnTheLastRowThatFits() {
        #expect(CappedScrollSpace.fit(cap: 100, edges: [36, 72, 108, 144]) == 72)
        #expect(CappedScrollSpace.fit(cap: 108, edges: [36, 72, 108, 144]) == 108)
        // Rows measured only up to the cap: the cut is unmeasured, so the cap stands.
        #expect(CappedScrollSpace.fit(cap: 300, edges: [43, 87]) == 300)
    }

    @Test func fallsBackToTheCap() {
        #expect(CappedScrollSpace.fit(cap: 20, edges: [36, 72]) == 20)
        #expect(CappedScrollSpace.fit(cap: 100, edges: []) == 100)
    }

    @Test func lazyFitSnapsToWholeRows() {
        // Realized rows all end within the cap: the rest repeat the pitch (here 41 with spacing).
        #expect(CappedScrollSpace.fitLazy(cap: 300, edges: [48, 89, 130, 171, 212]) == 294)
        #expect(CappedScrollSpace.fitLazy(cap: 294, edges: [48, 89, 130, 171, 212]) == 294)
        #expect(CappedScrollSpace.fitLazy(cap: 100, edges: [48, 89, 130]) == 89)
        // Rows of different heights can't be extrapolated: the cap stands.
        #expect(CappedScrollSpace.fitLazy(cap: 300, edges: [30, 70, 110, 140, 180]) == 300)
        // Never below the first row; no pitch with one edge.
        #expect(CappedScrollSpace.fitLazy(cap: 30, edges: [48, 89]) == 30)
        #expect(CappedScrollSpace.fitLazy(cap: 300, edges: [48]) == 300)
    }
}

@MainActor
@Suite(.hostsWindows) struct CappedScrollHosted {
    @Observable final class Count { var n: Int; init(_ n: Int) { self.n = n } }

    private struct Changing: View {
        let count: Count
        var body: some View {
            CappedScroll(cap: 300, lazy: AdaptiveStack<EmptyView>.isLazy(count.n)) {
                AdaptiveStack(count: count.n, spacing: 0) {
                    ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 40).frame(maxWidth: .infinity).capEdge() }
                }
            }
        }
    }

    @Test func rowCountChangesResizeTheList() {
        let count = Count(3)
        let hosting = NSHostingView(rootView: Changing(count: count).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        func settle() -> CGFloat { steadyHeight(hosting) }
        #expect(abs(settle() - 120) < 1)
        count.n = 100
        let grown = settle()
        #expect(grown >= 280 && grown <= 300, "grown: \(grown)")
        count.n = 2
        #expect(abs(settle() - 80) < 1)
        window.contentView = nil
        window.orderOut(nil)
    }

    private func height<V: View>(of view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        let h = steadyHeight(hosting)
        window.contentView = nil
        window.orderOut(nil)
        return h
    }

    private func rows(_ n: Int) -> some View {
        ForEach(0..<n, id: \.self) { i in Text("row \(i)").frame(height: 40).frame(maxWidth: .infinity).capEdge() }
    }

    @Test func overflowingListsFillTheCapWhateverTheStack() {
        for n in [8, 61, 200] {
            let eager = height(of: CappedScroll(cap: 300, lazy: AdaptiveStack<EmptyView>.isLazy(n)) { AdaptiveStack(count: n) { rows(n) } })
            #expect(eager >= 280 && eager <= 300, "adaptive \(n): \(eager)")
            let lazy = height(of: CappedScroll(cap: 300, lazy: true) { LazyVStack(spacing: 0) { rows(n) } })
            #expect(lazy >= 280 && lazy <= 300, "lazy \(n): \(lazy)")
        }
    }

    private struct LazyRows: View {
        let count: Count
        var body: some View {
            CappedScroll(cap: 300, lazy: true) {
                AdaptiveStack(count: count.n, spacing: 1) {
                    ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 41).frame(maxWidth: .infinity).capEdge() }
                }.padding(.vertical, 8)
            }
        }
    }

    /// Hosts the list, settles it, and returns its height after each row-count change.
    private func heights(counts: [Int]) -> [CGFloat] {
        let count = Count(counts[0])
        let hosting = NSHostingView(rootView: LazyRows(count: count).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        var out: [CGFloat] = []
        for n in counts {
            count.n = n
            out.append(steadyHeight(hosting))
        }
        window.contentView = nil
        window.orderOut(nil)
        return out
    }

    /// Whole rows: 8 of padding at the top, then rows of 41 with 1 of spacing between them.
    private func onRowBoundary(_ h: CGFloat) -> Bool {
        let rowsHigh = (h - 8 + 1) / 42
        return abs(rowsHigh - rowsHigh.rounded()) < 0.03 && rowsHigh.rounded() >= 1
    }

    @Test func lazyListsResizeAcrossRowCountChanges() {
        let r = heights(counts: [3, 400, 2])
        let short = { (n: Int) in 16 + CGFloat(n) * 42 - 1 }
        #expect(abs(r[0] - short(3)) < 1.5, "3: \(r)")
        #expect(r[1] <= 300.5 && r[1] >= 250 && onRowBoundary(r[1]), "400: \(r)")
        #expect(abs(r[2] - short(2)) < 1.5, "2: \(r)")
    }

    private struct VariableRows: View {
        let count: Count
        var body: some View {
            CappedScroll(cap: 300, lazy: true) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 30 + CGFloat(i % 3) * 10).frame(maxWidth: .infinity).capEdge() }
                }
            }
        }
    }

    @Test func variableRowHeightsStillRegrow() {
        let count = Count(200)
        let hosting = NSHostingView(rootView: VariableRows(count: count).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        var out: [CGFloat] = []
        for n in [200, 3, 200] {
            count.n = n
            out.append(steadyHeight(hosting))
        }
        window.contentView = nil
        window.orderOut(nil)
        #expect(abs(out[1] - 120) < 1.5, "\(out)")
        // Cut at a measured row edge (not through a row), and regrown to the same height.
        #expect(out[0] >= 260 && out[0] <= 300.5 && abs(out[2] - out[0]) < 1.5, "\(out)")
    }
}

@Suite struct EdgeFlag {
    @Test func edgeFlagNamesTheDemoBarsEdge() {
        #expect(HubController.edge(in: ["Fjord", "--demo", "agents", "--edge", "top"]) == .top)
        #expect(HubController.edge(in: ["Fjord", "--edge", "left", "--open"]) == .left)
    }

    @Test func noEdgeOrAnUnknownOneLeavesTheDefault() {
        #expect(HubController.edge(in: ["Fjord", "--demo"]) == nil)
        #expect(HubController.edge(in: ["Fjord", "--edge"]) == nil)
        #expect(HubController.edge(in: ["Fjord", "--edge", "middle"]) == nil)
    }
}

/// A hosted view's height once its layout has settled: the run loop turned (a measured list takes a few passes) until the
/// height reads the same over several turns, at least as many turns as before. Counted in turns, not time, so a slow
/// machine only takes longer; the shared watchdog ends a layout that never settles, and fails the test.
@MainActor func steadyHeight(_ hosting: NSView, turns: Int = 6, sourceLocation: SourceLocation = #_sourceLocation) -> CGFloat {
    var watchdog = Watchdog(), last = -1.0, same = 0, passes = 0
    while same < turns || passes < 8 {
        guard !watchdog.expired() else {
            Issue.record("Waited \(Int(watchdog.elapsed)) s for a height that never settled (last \(last))", sourceLocation: sourceLocation)
            break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        hosting.layoutSubtreeIfNeeded()
        let h = hosting.fittingSize.height
        same = h == last ? same + 1 : 0
        last = h
        passes += 1
    }
    return last
}

/// The bar's Router panel: the lines that need you, from the Router's records, each a button named by its line's name.
@MainActor
@Suite struct HubRouterPanel {
    @Test func thePanelListsTheNeedsYouLinesByName() async throws {
        var lines: [RouterThread] = []
        let tree = try await AccessibilityTree.render(scenario: .router, ready: { tree in
            tree.all.contains { $0.label == "Router" } && !lines.isEmpty && tree.all.contains { $0.label == lines[0].name }
        }, configure: { store, hub in
            lines = store.routerRecords.lines(in: .needsYou)
            hub.section = .router
        })
        try #require(!lines.isEmpty, "the router demo has lines that need you")
        for line in lines.prefix(FjordHub.routerEntryLimit) {
            let node = tree.all.first { $0.label == line.name && AXNode.controls.contains($0.role) }
            #expect(node != nil, "\(line.name) is a button in the panel")
        }
        // Only the lines that need you: no Done line is listed (the working list under them names what still runs).
        let demo = store(.router)
        let running = Set(demo.routerWorkingRows.map(\.session.title))
        let elsewhere = demo.routerRecords.lines(in: .done)
        for line in elsewhere where !lines.contains(where: { $0.name == line.name }) && !running.contains(line.name) {
            #expect(!tree.all.contains { $0.label == line.name && AXNode.controls.contains($0.role) }, "\(line.name) isn't listed")
        }
    }

    private func store(_ scenario: Demo.Scenario) -> Store {
        let store = Store()
        Demo.populate(store, scenario)
        return store
    }
}
