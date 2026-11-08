import AppKit
import Observation
import OSLog
import SwiftUI

// The ⌘K palette's state (docs/design/palette/DESIGN.md): whether it is open, what is typed, the rows listed and the one
// selected, the actions page of a row, and running an action. The view (PaletteView.swift) and the query field
// (PaletteField.swift) only draw it and tell it what the keys and the pointer did.

/// The three sources, and the Router's send row: what the palette is made of. Replaceable so tests and one shot can hand it
/// items of their own.
@MainActor
struct PaletteSources {
    var router: (PaletteContext) -> PaletteSourceOutput
    var triage: (PaletteContext) -> PaletteSourceOutput
    var places: (PaletteContext) -> PaletteSourceOutput
    /// The row that sends the query to the Router; nil when it can't (or the query is blank).
    var send: (String, PaletteContext) -> PaletteItem?
    /// Ranks the corpus for a query, the best first and at most `limit`: the matcher's, unless a fixture brings its own.
    var rank: ((String, PaletteIndex, Int) -> [PaletteHit])?

    static let live = PaletteSources(router: PaletteRouterSource.make, triage: PaletteTriageSource.make,
                                     places: PalettePlacesSource.make, send: PaletteRouterSource.send, rank: nil)

    /// Only these items, from nowhere in particular (a fixture).
    static func fixed(_ items: [PaletteItem], needsYou: [PaletteItem] = [], send: PaletteItem? = nil) -> PaletteSources {
        PaletteSources(router: { _ in PaletteSourceOutput(needsYou: needsYou, items: items) },
                       triage: { _ in PaletteSourceOutput() }, places: { _ in PaletteSourceOutput() },
                       send: { query, _ in query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : send }, rank: nil)
    }
}

/// A run of rows under one heading (none for the ranked list while typing).
struct PaletteSection: Identifiable {
    let id: String
    let title: String?
    var hits: [PaletteHit]
}

/// A request to scroll a row (or the top, with no id) into view: a new `seq` is a new request.
struct PaletteScroll: Equatable {
    var id: String?
    var seq: Int
}

@Observable
@MainActor
final class PaletteModel {
    /// What the palette shows: the rows, or the actions of one of them.
    enum Page: Equatable {
        case list
        case actions(String)
    }

    /// The most results listed while typing.
    static let limit = 50
    /// Triage items in "Needs you", and picks in "Recents".
    static let triageNeeds = 5
    static let recents = 5

    private(set) var isOpen = false
    /// What is typed in the field (on the actions page, what filters the actions).
    private(set) var query = ""
    /// The selected row: an item id on the list, an action id on the actions page. Held apart from the rows, so moving it
    /// redraws the two rows it leaves and reaches.
    private(set) var selection: String?
    private(set) var page = Page.list
    /// The rows, in groups: the empty palette's, or the ranked hits and the Router's send row.
    private(set) var sections: [PaletteSection] = []
    /// Whether the Router can send what is typed: the field says so in its placeholder.
    private(set) var canSend = false
    /// Asks the list to scroll to a row, or to the top.
    private(set) var scroll: PaletteScroll?
    /// Opened by a click on the header's trigger rather than a key: it fades in.
    private(set) var openedByPointer = false

    /// The keys that opened it, for the field to type itself once it has the keyboard (a dead key, a plain letter).
    @ObservationIgnored var pendingKeys: [NSEvent] = []

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let navigator: AppNavigator
    @ObservationIgnored private let routerModel: RouterModel
    @ObservationIgnored private let hub: HubState
    @ObservationIgnored private let usage: PaletteUsage?
    @ObservationIgnored private let sources: PaletteSources
    /// Puts an action off to the next run-loop turn, after the keyboard is back where it was. Tests replace it.
    @ObservationIgnored var later: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
    /// Puts the index's making off until the first frame is out. Tests replace it.
    @ObservationIgnored var afterFirstFrame: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    /// Everything made when it opened: the corpus, what the empty palette lists first, and what ids map to.
    @ObservationIgnored private var context: PaletteContext?
    /// Built after the first frame (or by the first keystroke): the empty palette doesn't need it.
    @ObservationIgnored private var index: PaletteIndex?
    @ObservationIgnored private var items: [PaletteItem] = []
    /// How many indexes this palette has made (a test reads it).
    @ObservationIgnored private(set) var indexBuilds = 0
    @ObservationIgnored private var byID: [String: PaletteItem] = [:]
    @ObservationIgnored private var needsYou: [PaletteItem] = []
    /// The actions page's way back: the list's query and pick.
    @ObservationIgnored private var listQuery = ""
    @ObservationIgnored private var listSelection: String?
    @ObservationIgnored private var scrollSeq = 0
    /// The pointer: where it was when a key or a scroll last moved the rows under it, and whether it has since moved more
    /// than a few points (only then may it select).
    @ObservationIgnored private var pointerAnchor: CGPoint?
    @ObservationIgnored private var pointerMoved = false
    @ObservationIgnored private var lastPointer: CGPoint?
    @ObservationIgnored private var lastOffset: CGFloat?
    @ObservationIgnored private var reloadPending = false
    @ObservationIgnored private weak var previousWindow: NSWindow?
    @ObservationIgnored private weak var previousResponder: NSResponder?
    @ObservationIgnored private var announced = Date.distantPast

    /// How far the pointer must go before it selects a row.
    static let pointerSlop: CGFloat = 3

    /// `usage`: the picks remembered (the window's), nil keeps none (shots and tests).
    init(store: Store, navigator: AppNavigator, routerModel: RouterModel, hub: HubState, usage: PaletteUsage? = nil,
         sources: PaletteSources? = nil) {
        self.store = store
        self.navigator = navigator
        self.routerModel = routerModel
        self.hub = hub
        self.usage = usage
        self.sources = sources ?? .live
    }

    // MARK: What is listed

    /// The rows in the order they are walked.
    var hits: [PaletteHit] { sections.flatMap(\.hits) }

    /// The actions page's item.
    var actionsItem: PaletteItem? {
        guard case .actions(let id) = page else { return nil }
        return item(id)
    }

    /// An item by id: the corpus's, or one the list holds that the corpus doesn't (the Router's send row, made for a query).
    private func item(_ id: String) -> PaletteItem? {
        byID[id] ?? sections.lazy.flatMap(\.hits).first { $0.id == id }?.item
    }

    /// The actions page's rows: the item's actions the query leaves.
    var actionRows: [PaletteAction] {
        guard let item = actionsItem else { return [] }
        let words = PaletteText.fold(query).split(separator: " ")
        guard !words.isEmpty else { return item.actions }
        return item.actions.filter { action in
            let title = PaletteText.fold(action.title)
            return words.allSatisfy { title.contains($0) }
        }
    }

    /// The ids that can be selected now, top to bottom.
    var selectableIDs: [String] {
        switch page {
        case .list: sections.flatMap { $0.hits.map(\.id) }
        case .actions: actionRows.map(\.id)
        }
    }

    var selectedHit: PaletteHit? {
        guard page == .list, let selection else { return nil }
        return sections.lazy.flatMap(\.hits).first { $0.id == selection }
    }

    /// What the field says when it is empty.
    var placeholder: String {
        if let item = actionsItem { return "Actions for \(item.title)" }
        return canSend ? "Search or send" : "Search"
    }

    /// Whether the footer's hints give way to the list (a query is typed: Claude's palette folds them).
    var footerCollapsed: Bool { page == .list && !query.isEmpty }

    // MARK: What the palette follows

    /// Where the window is: a change while the palette is open came from outside it (an action closes it first).
    var navigationSelection: AppDestination { navigator.selection }

    /// What the sources are made of, as numbers that move when it does: the store's revisions (the inbox and its categories,
    /// the brief's entries, Claude's sessions and agents, the actions' runs, the snippets, the project folders), the Router's
    /// and the tools' switches, whether the Router can send. Cheap, so the view can watch it.
    struct Stamp: Equatable {
        var inbox: Int, display: Int, router: Int, corpus: Int
        var routerOn: Bool, canSend: Bool, tools: Set<Tool>
        /// The brief: its threads, what needs you and your marks.
        var brief: Int
    }

    var sourceStamp: Stamp {
        let briefs = store.routerBriefs
        var brief = Hasher()
        for (project, doc) in briefs.docs.sorted(by: { $0.key < $1.key }) {
            brief.combine(project)
            for t in doc.threads { brief.combine(t.id); brief.combine(t.title); brief.combine(t.status) }
            for e in doc.needsYou { brief.combine(e) }
        }
        brief.combine(briefs.read)
        brief.combine(briefs.archived)
        return Stamp(inbox: store.inboxRevision, display: store.inboxDisplayRevision, router: store.routerRevision,
                     corpus: store.corpusRevision, routerOn: store.routerOn, canSend: routerModel.canSend(store),
                     tools: store.tools, brief: brief.finalize())
    }

    /// Lists the data again soon, once for the changes that come together (Claude's sessions change by the second).
    func reloadSoon() {
        guard isOpen, !reloadPending else { return }
        reloadPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.reloadPending = false
            self?.reload()
        }
    }

    // MARK: Keys

    /// Whether the window's key monitor takes a key while the palette is open (true) or lets it through to the field (false).
    /// Only ⌘K (its own) and ⌘W (closes the palette, not the window) are acted on; the other ⌘ chords are swallowed so no key
    /// equivalent (Go ▸ pages, a plan's Accept on ⌘↩) reaches the window behind, except what edits the field and the app's
    /// own quit, hide and minimize. By the character, so it is the same key on any layout.
    func takes(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        guard flags.contains(.command) else { return false }
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if typed == "w", flags == .command {
            close()
            return true
        }
        if [123, 124, 125, 126, 51, 117].contains(Int(event.keyCode)) { return false }
        if ["a", "c", "v", "x", "q", "h", "m"].contains(typed) { return false }
        if typed == "z" { return false }
        return true
    }

    // MARK: Opening and closing

    /// Opens the palette: the corpus built from the sources (synchronously, a few thousand items at most) so that the first
    /// frame already holds the empty palette's groups. `event`: the key that opened it, typed into the field once it has the
    /// keyboard.
    func open(replaying event: NSEvent? = nil, pointer: Bool = false) {
        if let event { pendingKeys.append(event) }
        guard !isOpen else { return }
        let span = LatencySignposts.signposter.beginInterval("Palette open to first flush")
        previousWindow = NSApp?.keyWindow
        previousResponder = Self.owner(of: previousWindow?.firstResponder)
        build()
        query = ""
        page = .list
        openedByPointer = pointer
        recompute(keeping: nil)
        if pointer {
            withAnimation(Motion.fade.resolved(reduce: AppTransition.reduceMotion)) { isOpen = true }
        } else {
            isOpen = true
        }
        LatencySignposts.endAfterCommit("Palette open to first flush", span)
        afterFirstFrame { [weak self] in self?.makeIndex() }
    }

    /// What has the keyboard, as it is given back: a field being edited is its field (the editor is shared, and is the
    /// palette's own field's by then), anything else itself.
    static func owner(of responder: NSResponder?) -> NSResponder? {
        guard let editor = responder as? NSTextView, editor.isFieldEditor else { return responder }
        return editor.delegate as? NSResponder
    }

    /// The index the ranker needs, made once per corpus.
    @discardableResult
    private func makeIndex() -> PaletteIndex? {
        guard isOpen else { return nil }
        if let index { return index }
        let span = LatencySignposts.signposter.beginInterval("Palette index")
        let made = PaletteIndex(items)
        LatencySignposts.signposter.endInterval("Palette index", span)
        indexBuilds += 1
        index = made
        return made
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// Closes it and gives the keyboard back to what had it.
    func close(restoringFocus: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        if restoringFocus { giveBackKeyboard() }
        previousWindow = nil
        previousResponder = nil
        pendingKeys = []
        page = .list
        query = ""
        listQuery = ""
        selection = nil
        listSelection = nil
        sections = []
        context = nil
        index = nil
        items = []
        lastOffset = nil
        byID = [:]
        needsYou = []
        pointerAnchor = nil
        pointerMoved = false
        lastPointer = nil
    }

    private func giveBackKeyboard() {
        guard let window = previousWindow else { return }
        var target = previousResponder
        if let view = target as? NSView, view.window !== window { target = nil }
        window.makeFirstResponder(target)
    }

    /// The corpus again from the sources, for data that changed under the open palette: the same query, and the same row
    /// selected if it is still listed.
    func reload() {
        guard isOpen else { return }
        build()
        switch page {
        case .list:
            recompute(keeping: selection)
            afterFirstFrame { [weak self] in self?.makeIndex() }
        case .actions(let id):
            sections = rankedSections(for: listQuery)
            // The row it belongs to gone: back to the list.
            guard item(id) != nil else {
                page = .list
                query = listQuery
                recompute(keeping: listSelection)
                return
            }
            if !sections.flatMap(\.hits).contains(where: { $0.id == listSelection }) { listSelection = nil }
            // An action that went (Archive, once archived, is Back to inbox) leaves the pick on the first.
            let ids = actionRows.map(\.id)
            if selection.map(ids.contains) != true { selection = ids.first }
        }
    }

    private func build() {
        let ctx = PaletteContext(store: store, navigator: navigator, routerModel: routerModel, hub: hub) { [navigator, store] in
            navigator.go($0.resolved(shown: store.shownCategories.map(\.id), tools: store.tools))
        }
        context = ctx
        let router = sources.router(ctx), triage = sources.triage(ctx), places = sources.places(ctx)
        var seen = Set<String>()
        let items = (router.items + triage.items + places.items + router.needsYou + triage.needsYou + places.needsYou)
            .filter { seen.insert($0.id).inserted }
        self.items = items
        index = nil
        byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        needsYou = router.needsYou + triage.needsYou.prefix(Self.triageNeeds) + places.needsYou
        canSend = sources.send("a", ctx) != nil
    }

    // MARK: Typing

    /// The field's text changed (never while an input method is composing): the rows are the new query's, the first selected.
    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        switch page {
        case .list:
            recompute(keeping: nil)
            announceCount()
        case .actions:
            selection = actionRows.first?.id
            requestScroll(nil)
        }
    }

    /// The rows for the current query and the one to select: `kept` if it is among them, else the first.
    private func recompute(keeping kept: String?) {
        // Other rows are under the pointer now: it has to move again before it selects.
        scrolled()
        sections = rankedSections(for: query)
        let ids = selectableIDs
        let target = kept.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        selection = target
        // A kept row stays where it is; a new list starts at the top.
        if kept == nil || target != kept { requestScroll(nil) }
    }

    /// The rows `query` lists: the ranked hits with the Router's send row last, or the empty palette's groups.
    private func rankedSections(for query: String) -> [PaletteSection] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return emptySections() }
        guard let index = makeIndex() else { return [] }
        var found = sources.rank?(query, index, Self.limit)
            ?? PaletteRanker.rank(query, in: index, usage: usage, now: Date(), limit: Self.limit)
        if let context, let send = sources.send(query, context), !found.contains(where: { $0.id == send.id }) {
            found.append(PaletteHit(item: send, ranges: []))
        }
        return found.isEmpty ? [] : [PaletteSection(id: "results", title: nil, hits: found)]
    }

    /// The empty palette: what needs you, then the last picks, else the pages.
    private func emptySections() -> [PaletteSection] {
        var seen = Set<String>()
        func hits(_ items: [PaletteItem]) -> [PaletteHit] {
            items.filter { seen.insert($0.id).inserted }.map { PaletteHit(item: $0, ranges: []) }
        }
        var result: [PaletteSection] = []
        let needs = hits(needsYou)
        if !needs.isEmpty { result.append(PaletteSection(id: "needs", title: "Needs you", hits: needs)) }
        // The whole history, newest first: picks that are gone (an answered entry) don't hide older ones that are not.
        let recent = hits((usage?.recent(Int.max) ?? []).lazy.compactMap { self.byID[$0] }.filter { !seen.contains($0.id) }
            .prefix(Self.recents).map { $0 })
        if !recent.isEmpty { result.append(PaletteSection(id: "recents", title: "Recents", hits: Array(recent))) }
        if result.isEmpty {
            let pages = hits(items.filter { $0.kind == .page })
            if !pages.isEmpty { result.append(PaletteSection(id: "pages", title: "Go to", hits: pages)) }
        }
        return result
    }

    /// Tells VoiceOver how many rows the query left, not oftener than it can take it in.
    private func announceCount() {
        guard Date().timeIntervalSince(announced) > 0.8 else { return }
        announced = Date()
        let count = hits.count
        Announce.say(count == 0 ? "No results" : count == 1 ? "1 result" : "\(count) results")
    }

    // MARK: Selection

    /// ↑ or ↓: the next row up or down, staying put at either end; the list scrolls to show it.
    func move(down: Bool) {
        let ids = selectableIDs
        guard !ids.isEmpty else { return }
        pointerMoved = false
        pointerAnchor = nil
        let current = selection.flatMap(ids.firstIndex(of:)) ?? (down ? -1 : ids.count)
        let next = min(max(current + (down ? 1 : -1), 0), ids.count - 1)
        guard ids[next] != selection else { return }
        selection = ids[next]
        requestScroll(ids[next])
    }

    /// The pointer is over a row, at `point` (in the list's space). It selects the row only once it has moved more than a few
    /// points since a key or a scroll last moved the rows under it, and never scrolls.
    func pointer(over id: String, at point: CGPoint) {
        // The same spot again is rows moving under a still pointer (a scroll), not the pointer.
        if let last = lastPointer, abs(last.x - point.x) < 0.5, abs(last.y - point.y) < 0.5 { return }
        lastPointer = point
        if !pointerMoved {
            guard let anchor = pointerAnchor else { pointerAnchor = point; return }
            guard hypot(point.x - anchor.x, point.y - anchor.y) > Self.pointerSlop else { return }
            pointerMoved = true
        }
        if selection != id, selectableIDs.contains(id) { selection = id }
    }

    /// The list scrolled: the pointer has to move again before it selects.
    func scrolled() {
        pointerMoved = false
        pointerAnchor = nil
    }

    /// The list's content is at `offset` (how far it has gone up under the top edge): a different one than last time is a
    /// scroll, by the wheel, the keys or the list changing.
    func listScrolled(offset: CGFloat) {
        defer { lastOffset = offset }
        guard let last = lastOffset, abs(last - offset) >= 0.5 else { return }
        scrolled()
    }

    private func requestScroll(_ id: String?) {
        scrollSeq &+= 1
        scroll = PaletteScroll(id: id, seq: scrollSeq)
    }

    // MARK: Actions page

    /// Tab or ⌥↩: the selected row's actions. Nothing on the actions page already, or with no row selected.
    func showActions() {
        guard page == .list, let hit = selectedHit else { return }
        scrolled()
        listQuery = query
        listSelection = selection
        page = .actions(hit.id)
        query = ""
        selection = hit.item.actions.first?.id
        requestScroll(nil)
    }

    /// Back from the actions page to the list as it was. False when it is not on the actions page.
    @discardableResult
    func back() -> Bool {
        guard page != .list else { return false }
        scrolled()
        page = .list
        query = listQuery
        recompute(keeping: listSelection)
        if let id = selection { requestScroll(id) }
        return true
    }

    /// Esc: back from the actions page, else closes.
    func escape() {
        if !back() { close() }
    }

    /// Backspace in an empty field: back from the actions page. False when there is nowhere to go back to (the key is then
    /// the field's own).
    func backspaceOnEmpty() -> Bool {
        guard query.isEmpty else { return false }
        return back()
    }

    // MARK: Running

    /// ↩: the selected row's first action, or on the actions page the selected action.
    func runSelected() {
        switch page {
        case .list:
            guard let item = selectedHit?.item, let action = item.actions.first else { return }
            run(action, of: item)
        case .actions:
            guard let item = actionsItem, let action = actionRows.first(where: { $0.id == selection }) else { return }
            run(action, of: item)
        }
    }

    /// A click on a row of the list: it is picked and run; on the actions page, the action clicked.
    func pick(_ id: String) {
        guard selectableIDs.contains(id) else { return }
        selection = id
        runSelected()
    }

    /// Closes the palette, gives the keyboard back to what had it, then runs the action on the next run-loop turn (so it
    /// applies to what you were looking at), and remembers the pick.
    func run(_ action: PaletteAction, of item: PaletteItem) {
        usage?.record(item.id, query: page == .list ? query : listQuery)
        close()
        let run = action.run
        later(run)
    }
}
