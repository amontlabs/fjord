import AppKit
import Foundation
import Testing
@testable import Fjord

/// The palette's state: the empty palette's groups, the ranked list and its send row, the selection's rules, the actions
/// page, and running an action. Sources are fixed items, so the matcher is not under test here.
@MainActor
@Suite struct PaletteModelTests {
    /// What an action did, and whether the palette was still open when it did.
    final class Ran {
        var openWhenRun: [Bool] = []
        var titles: [String] = []
    }

    private func item(_ id: String, _ title: String, kind: PaletteItem.Kind = .entry, ran: Ran? = nil,
                      model: @escaping () -> PaletteModel? = { nil }) -> PaletteItem {
        PaletteItem(id: id, kind: kind, title: title, icon: .symbol("circle"), actions: [
            PaletteAction(id: "\(id).open", title: "Open", run: { ran?.openWhenRun.append(model()?.isOpen ?? false); ran?.titles.append("open \(title)") }),
            PaletteAction(id: "\(id).copy", title: "Copy link", run: { ran?.titles.append("copy \(title)") }),
            PaletteAction(id: "\(id).archive", title: "Archive", destructive: true, run: { ran?.titles.append("archive \(title)") }),
        ])
    }

    private func make(_ sources: PaletteSources, usage: PaletteUsage? = nil, store: Store? = nil,
                      navigator: AppNavigator? = nil) -> PaletteModel {
        let store = store ?? InboxFixture.store([])
        let model = PaletteModel(store: store, navigator: navigator ?? AppNavigator(fallback: .done, defaults: nil),
                                 routerModel: RouterModel(), hub: HubState(), usage: usage, sources: sources)
        model.later = { $0() }
        return model
    }

    private func key(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    private func send() -> PaletteItem { item("send:router", "Send to the Router", kind: .send) }

    private func ids(_ model: PaletteModel) -> [String] { model.hits.map(\.id) }

    private func usage() -> (PaletteUsage, UserDefaults) {
        let suite = "palette-model-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PaletteUsage(defaults: defaults), defaults)
    }

    // MARK: The empty palette

    @Test func theEmptyPaletteListsWhatNeedsYouThenRecentsWithoutRepeats() {
        let (usage, _) = usage()
        let a = item("thread:p/a", "Which branch?", kind: .thread), b = item("thread:p/b", "Approve the plan", kind: .thread)
        let c = item("entry:c", "Fix flaky test"), d = item("entry:d", "Bump the client")
        let model = make(.fixed([a, b, c, d], needsYou: [a, b]), usage: usage)
        usage.record("entry:c", query: "")
        usage.record("thread:p/a", query: "")
        usage.record("entry:gone", query: "")
        model.open()
        #expect(model.sections.map(\.title) == ["Needs you", "Recents"])
        #expect(model.sections[0].hits.map(\.id) == ["thread:p/a", "thread:p/b"])
        // The last pick that is still known, not repeating what already needs you.
        #expect(model.sections[1].hits.map(\.id) == ["entry:c"])
        #expect(model.selection == "thread:p/a")
    }

    @Test func triageItemsInNeedsYouAreCappedAtFiveAfterTheRoutersEntries() {
        let router = [item("thread:p/1", "Question", kind: .thread)]
        let triage = (1...8).map { item("entry:\($0)", "Item \($0)") }
        var sources = PaletteSources.fixed([])
        sources.router = { _ in PaletteSourceOutput(needsYou: router, items: router) }
        sources.triage = { _ in PaletteSourceOutput(needsYou: triage, items: triage) }
        let model = make(sources)
        model.open()
        #expect(model.sections.count == 1 && model.sections[0].title == "Needs you")
        #expect(model.sections[0].hits.map(\.id) == ["thread:p/1", "entry:1", "entry:2", "entry:3", "entry:4", "entry:5"])
    }

    @Test func withNothingToShowItFallsBackToThePages() {
        let pages = [item("page:router", "Router", kind: .page), item("page:settings", "Settings", kind: .page)]
        let model = make(.fixed(pages + [item("entry:1", "A thing")]))
        model.open()
        #expect(model.sections.map(\.title) == ["Go to"])
        #expect(ids(model) == ["page:router", "page:settings"])
    }

    @Test func anItemTwoSourcesMakeIsListedOnce() {
        let shared = item("entry:1", "Shared title")
        var sources = PaletteSources.fixed([shared, item("entry:2", "Shared other")])
        sources.places = { _ in PaletteSourceOutput(needsYou: [shared], items: [shared]) }
        let model = make(sources)
        model.open()
        model.setQuery("shared")
        #expect(ids(model).filter { $0 == "entry:1" }.count == 1)
        #expect(Set(ids(model)) == ["entry:1", "entry:2"])
    }

    // MARK: Typing

    @Test func theSendRowIsLastAndTheOnlyRowWhenNothingMatches() {
        let model = make(.fixed([item("entry:1", "Fix flaky test"), item("entry:2", "Fix the build")], send: send()))
        model.open()
        #expect(model.canSend && model.placeholder == "Search or send")
        model.setQuery("fix")
        #expect(ids(model).last == "send:router" && ids(model).count == 3)
        #expect(model.selection == ids(model).first)
        model.setQuery("zzzqx")
        #expect(ids(model) == ["send:router"] && model.selection == "send:router")
    }

    @Test func withoutARouterThatCanSendThereIsNoSendRowAndNoResultsIsEmpty() {
        let model = make(.fixed([item("entry:1", "Fix flaky test")]))
        model.open()
        #expect(!model.canSend && model.placeholder == "Search")
        model.setQuery("zzzqx")
        #expect(model.hits.isEmpty && model.selection == nil)
    }

    @Test func resultsAreCappedAtFifty() {
        let items = (1...80).map { item("entry:\($0)", "Same title \($0)") }
        let model = make(.fixed(items, send: send()))
        model.open()
        model.setQuery("same")
        // Fifty hits, then the send row.
        #expect(model.hits.count == PaletteModel.limit + 1 && model.hits.last?.id == "send:router")
    }

    // MARK: Selection

    @Test func aNewQuerySelectsTheFirstRowAndADataChangeKeepsTheItem() {
        var items = [item("entry:1", "Fix one"), item("entry:2", "Fix two"), item("entry:3", "Fix three")]
        var sources = PaletteSources.fixed([])
        sources.router = { _ in PaletteSourceOutput(items: items) }
        let model = make(sources)
        model.open()
        model.setQuery("fix")
        model.move(down: true)
        let picked = model.selection
        #expect(picked == ids(model)[1])
        // A row above arrives: the pick stays on the item it was on.
        items.insert(item("entry:0", "Fix zero"), at: 0)
        model.reload()
        #expect(model.selection == picked)
        // The picked item leaves: the first row is selected.
        items.removeAll { $0.id == picked }
        model.reload()
        #expect(model.selection == ids(model).first)
        // A new query starts at the first row, whatever was selected.
        model.move(down: true)
        model.setQuery("fi")
        #expect(model.selection == ids(model).first)
    }

    @Test func theArrowsStayPutAtTheEnds() {
        let model = make(.fixed((1...3).map { item("entry:\($0)", "Fix \($0)") }))
        model.open()
        model.setQuery("fix")
        let rows = ids(model)
        model.move(down: false)
        #expect(model.selection == rows[0])
        model.move(down: true); model.move(down: true); model.move(down: true); model.move(down: true)
        #expect(model.selection == rows[2])
        model.move(down: false)
        #expect(model.selection == rows[1])
    }

    @Test func keyboardMovesAskTheListToScrollButHoverNever() {
        let model = make(.fixed((1...5).map { item("entry:\($0)", "Fix \($0)") }))
        model.open()
        model.setQuery("fix")
        let seq = model.scroll?.seq
        model.move(down: true)
        #expect(model.scroll?.id == ids(model)[1] && model.scroll?.seq != seq)
        let after = model.scroll
        model.pointer(over: ids(model)[3], at: CGPoint(x: 10, y: 10))
        model.pointer(over: ids(model)[3], at: CGPoint(x: 10, y: 40))
        #expect(model.selection == ids(model)[3] && model.scroll == after)
    }

    @Test func thePointerSelectsOnlyAfterMovingMoreThanThreePointsSinceAKey() {
        let model = make(.fixed((1...4).map { item("entry:\($0)", "Fix \($0)") }))
        model.open()
        model.setQuery("fix")
        let rows = ids(model)
        // The first sight of the pointer only notes where it is; a little movement is not a move.
        model.pointer(over: rows[2], at: CGPoint(x: 50, y: 100))
        #expect(model.selection == rows[0])
        model.pointer(over: rows[2], at: CGPoint(x: 52, y: 101))
        #expect(model.selection == rows[0])
        model.pointer(over: rows[2], at: CGPoint(x: 60, y: 101))
        #expect(model.selection == rows[2])
        // A key takes the selection back, and the pointer has to move again.
        model.move(down: false)
        #expect(model.selection == rows[1])
        model.pointer(over: rows[3], at: CGPoint(x: 61, y: 101))
        #expect(model.selection == rows[1])
        model.pointer(over: rows[3], at: CGPoint(x: 80, y: 101))
        model.pointer(over: rows[3], at: CGPoint(x: 90, y: 101))
        #expect(model.selection == rows[3])
        // Rows scrolling under a still pointer is the same spot again: not the pointer.
        model.move(down: false)
        model.pointer(over: rows[0], at: CGPoint(x: 90, y: 101))
        #expect(model.selection == rows[2])
    }

    // MARK: Actions page

    @Test func tabOpensTheActionsPageAndEscOrBackspaceReturnsToTheListAsItWas() {
        let model = make(.fixed([item("entry:1", "Fix one"), item("entry:2", "Fix two")]))
        model.open()
        model.setQuery("fix")
        model.move(down: true)
        let picked = model.selection
        model.showActions()
        #expect(model.page == .actions(picked!) && model.query.isEmpty)
        #expect(model.actionRows.map(\.title) == ["Open", "Copy link", "Archive"])
        #expect(model.selection == "\(picked!).open")
        // Typing filters the actions.
        model.setQuery("arch")
        #expect(model.actionRows.map(\.title) == ["Archive"] && model.selection == "\(picked!).archive")
        // Backspace in a field that still holds text is the field's.
        #expect(!model.backspaceOnEmpty())
        model.setQuery("")
        #expect(model.backspaceOnEmpty())
        #expect(model.page == .list && model.query == "fix" && model.selection == picked)
        // Esc on the actions page goes back; on the list it closes.
        model.showActions()
        model.escape()
        #expect(model.isOpen && model.page == .list)
        model.escape()
        #expect(!model.isOpen)
    }

    @Test func backspaceOnAnEmptyListDoesNothing() {
        let model = make(.fixed([item("page:1", "Router", kind: .page)]))
        model.open()
        #expect(!model.backspaceOnEmpty() && model.isOpen)
    }

    // MARK: Running

    @Test func runningClosesFirstThenRunsAndRecordsThePick() async {
        let (usage, _) = usage()
        let ran = Ran()
        var held: PaletteModel?
        let a = item("entry:1", "Fix one", ran: ran) { held }
        let model = make(.fixed([a, item("entry:2", "Fix two", ran: ran) { held }]), usage: usage)
        held = model
        // The default turn: the action waits for the next run-loop turn.
        model.later = { work in DispatchQueue.main.async { MainActor.assumeIsolated(work) } }
        model.open()
        model.setQuery("fix")
        model.runSelected()
        #expect(!model.isOpen && ran.titles.isEmpty)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ran.titles == ["open \(a.title)"] && ran.openWhenRun == [false])
        #expect(usage.recent(1) == ["entry:1"])
    }

    @Test func aPickFromTheActionsPageRunsThatAction() {
        let ran = Ran()
        let model = make(.fixed([item("entry:1", "Fix one", ran: ran)]))
        model.open()
        model.setQuery("fix")
        model.showActions()
        model.move(down: true)
        model.runSelected()
        #expect(!model.isOpen && ran.titles == ["copy Fix one"])
    }

    @Test func aClickPicksTheRowAndRunsItsFirstAction() {
        let ran = Ran()
        let model = make(.fixed([item("entry:1", "Fix one", ran: ran), item("entry:2", "Fix two", ran: ran)]))
        model.open()
        model.setQuery("fix")
        model.pick("entry:2")
        #expect(!model.isOpen && ran.titles == ["open Fix two"])
    }

    @Test func closingClearsWhatWasTypedAndOpensAgainEmpty() {
        let model = make(.fixed([item("page:1", "Router", kind: .page)]))
        model.open()
        model.setQuery("rou")
        model.close()
        #expect(!model.isOpen && model.query.isEmpty && model.sections.isEmpty && model.selection == nil)
        model.open()
        #expect(model.query.isEmpty && model.selection == "page:1")
    }

    // MARK: Review fixes

    @Test func whileOpenOnlyFieldEditingChordsReachTheWindowsKeyEquivalents() {
        let model = make(.fixed([item("page:1", "Router", kind: .page)]))
        model.open()
        // ⌘1–9 (Go), ⌘↩ (a plan's Accept), ⌘F and ⌘, are swallowed: no key equivalent behind the palette.
        for (code, chars) in [(18, "1"), (19, "2"), (36, "\r"), (3, "f"), (43, ",")] {
            #expect(model.takes(key(code, chars)), "⌘\(chars)")
        }
        // What edits the field, and the app's own quit, reach it.
        for (code, chars) in [(0, "a"), (8, "c"), (9, "v"), (7, "x"), (6, "z"), (123, "\u{F702}"), (124, "\u{F703}"), (51, "\u{7F}"),
                              (12, "q")] {
            #expect(!model.takes(key(code, chars)), "⌘\(chars)")
        }
        #expect(!model.takes(key(6, "z", [.command, .shift])))
        // Typing is the field's.
        #expect(!model.takes(key(0, "a", [])) && !model.takes(key(36, "\r", [])))
        // ⌘W closes the palette, and not the window (by the character: the Z key on AZERTY).
        #expect(model.takes(key(13, "w")) && !model.isOpen)
    }

    @Test func theSendRowHasItsActionsPageAndAKeptItemSurvivesAReload() {
        let model = make(.fixed([item("entry:1", "Fix one")], send: send()))
        model.open()
        model.setQuery("zzzqx")
        #expect(model.selection == "send:router")
        model.showActions()
        #expect(model.actionRows.map(\.title) == ["Open", "Copy link", "Archive"])
        model.reload()
        #expect(model.page == .actions("send:router") && model.actionRows.count == 3)
    }

    @Test func anActionThatWentLeavesThePickOnTheFirstAfterAReload() {
        var archived = false
        func entry() -> PaletteItem {
            var made = item("entry:1", "Fix one")
            if archived { made.actions = [PaletteAction(id: "restore", title: "Back to inbox", run: {}), made.actions[0]] }
            return made
        }
        var sources = PaletteSources.fixed([])
        sources.router = { _ in PaletteSourceOutput(items: [entry()]) }
        let model = make(sources)
        model.open()
        model.setQuery("fix")
        model.showActions()
        model.move(down: true); model.move(down: true)
        #expect(model.selection == "entry:1.archive")
        archived = true
        model.reload()
        // The action it was on is gone: the first one is.
        #expect(model.selection == "restore")
        // One still there stays.
        model.move(down: true)
        model.reload()
        #expect(model.selection == "entry:1.open")
    }

    @Test func theIndexIsMadeAfterTheFirstFrameOrByTheFirstKeystroke() {
        var pending: [@MainActor () -> Void] = []
        let model = make(.fixed([item("entry:1", "Fix one"), item("page:1", "Router", kind: .page)]))
        model.afterFirstFrame = { pending.append($0) }
        model.open()
        // The empty palette is already listed, with no index made.
        #expect(model.indexBuilds == 0 && model.sections.count == 1 && model.selection != nil)
        // Typing before the first frame is out makes it then, once.
        model.setQuery("fix")
        #expect(model.indexBuilds == 1 && ids(model).contains("entry:1"))
        pending.forEach { $0() }
        model.setQuery("fixe")
        #expect(model.indexBuilds == 1)
        // The turn that comes after a close makes nothing.
        model.close()
        model.open()
        model.close()
        pending.forEach { $0() }
        #expect(model.indexBuilds == 1)
        // A data change makes the next one.
        model.open()
        model.reload()
        pending.forEach { $0() }
        #expect(model.indexBuilds == 2)
    }

    @Test func scrollingAndListChangesTakeTheHoverBackUntilThePointerMovesAgain() {
        let model = make(.fixed((1...6).map { item("entry:\($0)", "Fix \($0)") }))
        model.open()
        model.setQuery("fix")
        let rows = ids(model)
        func hover(_ id: String, _ x: CGFloat) {
            model.pointer(over: id, at: CGPoint(x: x, y: 50))
            model.pointer(over: id, at: CGPoint(x: x + 10, y: 50))
        }
        hover(rows[2], 10)
        #expect(model.selection == rows[2])
        // The list scrolls (the view reports the offset): the next hover only notes where the pointer is.
        model.listScrolled(offset: 0)
        model.listScrolled(offset: -40)
        model.pointer(over: rows[4], at: CGPoint(x: 100, y: 50))
        #expect(model.selection == rows[2])
        model.pointer(over: rows[4], at: CGPoint(x: 120, y: 50))
        #expect(model.selection == rows[4])
        // The same offset again is no scroll.
        model.listScrolled(offset: -40)
        model.pointer(over: rows[1], at: CGPoint(x: 130, y: 50))
        #expect(model.selection == rows[1])
        // A new query changes the rows under the pointer too.
        model.setQuery("fix 3")
        model.pointer(over: ids(model)[0], at: CGPoint(x: 300, y: 50))
        #expect(model.selection == ids(model).first)
    }

    @Test func whatTheSourcesAreMadeOfMovesTheStampThatReloads() {
        let store = InboxFixture.store([])
        store.persists = false
        let model = make(.fixed([]), store: store)
        let before = model.sourceStamp
        #expect(model.sourceStamp == before)
        store.snippets.append(Snippet(name: "A prompt", text: "Do it"))
        let withSnippet = model.sourceStamp
        #expect(withSnippet != before)
        store.categories[0].name = "Renamed"
        let renamed = model.sourceStamp
        #expect(renamed != withSnippet)
        // A brief entry, the same entry of another kind, a session, the action runs, the Router's switch.
        var doc = BriefDoc(project: "p")
        var entry = BriefEntry(project: "p", thread: "t", kind: .question, state: .needsYou, since: 1, question: "?")
        doc.needsYou = [entry]
        store.routerBriefs.demoDocs = ["p": doc]
        let carded = model.sourceStamp
        #expect(carded != renamed)
        entry.kind = .plan
        doc.needsYou = [entry]
        store.routerBriefs.demoDocs = ["p": doc]
        #expect(model.sourceStamp != carded)
        let sessioned = model.sourceStamp
        store.threads["x"] = AgentThread(id: "x", title: "T", folder: "/code/web", lastActivity: Date())
        #expect(model.sourceStamp != sessioned)
        let ledgered = model.sourceStamp
        store.actionLedger = ActionLedger()
        #expect(model.sourceStamp != ledgered)
        let before2 = model.sourceStamp
        store.corpusChanged()
        #expect(model.sourceStamp != before2)
    }

    @Test func recentsWalkTheWholeHistoryPastPicksThatAreGone() {
        let (usage, _) = usage()
        let kept = item("setting:a", "A setting", kind: .setting)
        let model = make(.fixed([kept, item("entry:b", "Other")]), usage: usage)
        usage.record("setting:a", query: "")
        // Thirty picks since, none of them listed any more (threads that were archived).
        for n in 1...30 { usage.record("thread:p/gone\(n)", query: "") }
        model.open()
        #expect(model.sections.map(\.title) == ["Recents"] && ids(model) == ["setting:a"])
    }

    @Test func manyChangesTogetherReloadOnce() async {
        var made = 0
        var sources = PaletteSources.fixed([])
        sources.router = { _ in made += 1; return PaletteSourceOutput(items: []) }
        let model = make(sources)
        model.open()
        let opened = made
        model.reloadSoon(); model.reloadSoon(); model.reloadSoon()
        // Waits for the reload rather than a fixed time (a busy test run can hold the main actor), then a while longer to
        // see that no second one follows.
        let deadline = Date().addingTimeInterval(10)
        while made == opened && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(made == opened + 1)
    }

    @Test func theOwnerOfTheKeyboardIsTheFieldBeingEditedNotTheSharedEditor() {
        final class Owner: NSTextField, NSTextViewDelegate {}
        let field = Owner()
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.delegate = field
        #expect(PaletteModel.owner(of: editor) === field)
        let composer = NSTextView()
        #expect(PaletteModel.owner(of: composer) === composer)
        #expect(PaletteModel.owner(of: nil) == nil)
    }

    @Test func itFollowsTheWindowsPlace() {
        let store = InboxFixture.store([])
        let navigator = AppNavigator(fallback: .done, defaults: nil)
        let model = make(.fixed([item("page:1", "Router", kind: .page)]), store: store, navigator: navigator)
        let place = model.navigationSelection
        navigator.go(.router)
        #expect(model.navigationSelection != place)
    }

    @Test func keycapsAreGlyphsWhereTheKeyHasOne() {
        #expect(["Return", "Enter", "⌫", "Delete", "Esc", "Space", "Tab", "⌘", "K"].map(PaletteCaps.glyph)
            == ["↩", "↩", "⌫", "⌫", "Esc", "Space", "Tab", "⌘", "K"])
    }

    // MARK: Window layout and labels

    @Test func theSurfaceSitsAndSizesAsClaudesDoes() {
        let big = PaletteLayout(window: CGSize(width: 1280, height: 800))
        #expect(big.width == 672 && abs(big.top - 130.55) < 0.01)
        let narrow = PaletteLayout(window: CGSize(width: 700, height: 600))
        #expect(narrow.width == 668 && narrow.top >= 61)
        #expect(big.listHeight(content: 2000, footer: true) == 440 && big.listHeight(content: 2000, footer: false) == 481)
        #expect(big.listHeight(content: 100, footer: true) == 100)
    }

    @Test func aRowsDateIsAShortBucket() {
        let now = Date()
        #expect(PaletteTime.label(nil) == nil)
        #expect(PaletteTime.label(now.addingTimeInterval(-60), now: now) == "Just now")
        #expect(PaletteTime.label(now.addingTimeInterval(-1800), now: now) == "Past hour")
        #expect(PaletteTime.label(now.addingTimeInterval(-3 * 86_400), now: now) == "Past week")
        #expect(PaletteTime.label(now.addingTimeInterval(-20 * 86_400), now: now) == "Past month")
        #expect(PaletteTime.label(now.addingTimeInterval(-200 * 86_400), now: now) == "Past year")
        #expect(PaletteTime.label(now.addingTimeInterval(-800 * 86_400), now: now) == nil)
    }
}
