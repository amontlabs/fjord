import SwiftUI

// The Router's main page, over the composer: Now (what needs you, what's worth a look, what waits and what works, one
// scroll of sections that fold) and History (the conversation with the Router and the items already addressed, one
// timeline, opening at its newest). Side by side in a wide window, one at a time with a switch in a narrow one.

// MARK: - Model

/// Which items stand in which zone, and in what order. Pure: the views draw it and the tests read it.
struct RouterPage: Equatable {
    /// One line of the history.
    enum Entry: Identifiable, Equatable {
        /// An addressed card, at the time it was addressed.
        case card(RouterCard)
        /// A run of the Router, from the decision log.
        case decision(RouterDecision)
        /// A summary you asked for.
        case summary(RouterSummary)

        var id: String {
            switch self {
            case .summary(let s): "summary-" + s.id.uuidString
            case .decision(let d): d.id.uuidString
            case .card(let c): c.id
            }
        }

        var date: Date {
            switch self {
            case .card(let c): c.addressedAt ?? c.createdAt
            case .decision(let d): d.at
            case .summary(let s): s.at
            }
        }
    }

    /// Open cards whose next move is yours, as the page shows them (the arrow keys walk the same order, see `ranked`): an
    /// OK asked first, then what stops a session on you, stuck turns, then a last step left to you (RouterTiers.swift).
    var needs: [RouterCard] = []
    /// Sessions whose wait is over and that aren't told yet: yours to continue, in Needs you; newest first.
    var ready: [RouterCard] = []
    /// Sessions whose turn ended waiting on something (CI, another session…), under the working ones; newest first.
    var waiting: [RouterCard] = []
    /// Finished turns with nothing to do but something to tell (Worth a look), and those you opened again; most urgent
    /// first.
    var notes: [RouterCard] = []
    /// Messages waiting for you to say where they go (nothing is sent until you do), above the cards.
    var asks: [RouterAskBack] = []
    /// Sessions working on their own, the longest running first.
    var working: [AgentRow] = []
    /// Each working session's newest summary, by session: shown under its row until the next one.
    var summaries: [String: RouterSummary] = [:]
    /// Each working session's questions your last message left (`RouterFeed.unanswered`), by session: under its row.
    var unanswered: [String: [String]] = [:]
    /// Oldest first: the Router's runs, the summaries and the addressed cards by time.
    var history: [Entry] = []

    /// The card of Needs you shown in full: the one asked for while it is still waiting, else the first; none while the one
    /// asked for is one of Worth a look's (it is open there).
    func openNeed(preferred: String?) -> String? {
        if let preferred, needs.contains(where: { $0.id == preferred }) { return preferred }
        if let preferred, notes.contains(where: { $0.id == preferred }) { return nil }
        return needs.first?.id
    }

    static func make(cards: [RouterCard], working: [AgentRow],
                     decisions: [RouterDecision] = [], summaries: [RouterSummary] = [], asks: [RouterAskBack] = []) -> RouterPage {
        make(cards: cards, working: working, asks: asks, history: history(cards: cards, decisions: decisions, summaries: summaries),
             summaries: summaries)
    }

    /// The zones on the cards and sessions, around a history worked out already (`Store.routerHistory`). `tasks`: what
    /// sessions whose turn is over still run (`Store.routerTasks`, the map the keys and the counts go by too, a muted
    /// project's sessions with the rest); without it, the Working rows'.
    static func make(cards: [RouterCard], working: [AgentRow], asks: [RouterAskBack], history: [Entry],
                     summaries: [RouterSummary] = [], tasks: [String: [ClaudeTask]]? = nil) -> RouterPage {
        let open = cards.filter(\.isOpen)
        var page = RouterPage()
        let tasks = tasks ?? Dictionary(working.map { ($0.id, $0.tasks) }, uniquingKeysWith: +)
        let shown = open.filter { $0.kind != .waiting && shows($0, tasks: tasks) }
        page.needs = shown.filter { $0.kind.needsYou }.sorted(by: ranked)
        page.notes = shown.filter { !$0.kind.needsYou }.sorted(by: ranked)
        // A session that is working again shows as working.
        let busy = Set(working.map(\.id))
        let waits = open.filter { $0.kind == .waiting && !busy.contains($0.sessionID) }.sorted(by: newestFirst)
        page.ready = waits.filter { $0.tier == .needsYou }
        page.waiting = waits.filter { $0.tier != .needsYou }
        page.working = working
        page.asks = asks
        page.history = history
        page.summaries = latest(summaries, working: working)
        for row in working {
            if let left = RouterFeed.unanswered(cards, row.id, turns: row.session.completedTurns)?.skipped { page.unanswered[row.id] = left }
        }
        return page
    }

    /// Whether a card is on the page (and so the keys, the pick and the away strip have it): a turn isn't done while its
    /// session still has subagents or commands running (`tasks`, by session, as the Working rows have them), it shows as
    /// working until they end.
    static func shows(_ card: RouterCard, tasks: [String: [ClaudeTask]]) -> Bool {
        !(card.isOpen && card.kind == .done && !(tasks[card.sessionID] ?? []).isEmpty)
    }

    /// Under each working session's row: its newest summary (the last of those at the same time). A session no longer working
    /// has none shown; the history keeps them all.
    static func latest(_ summaries: [RouterSummary], working: [AgentRow]) -> [String: RouterSummary] {
        let ids = Set(working.map(\.id))
        var out: [String: RouterSummary] = [:]
        for summary in summaries {
            guard let id = summary.sessionID, ids.contains(id) else { continue }
            if let kept = out[id], kept.at > summary.at { continue }
            out[id] = summary
        }
        return out
    }

    /// The history, oldest first (ties keep the runs, then the summaries, then the cards, in their order); one line per id.
    static func history(cards: [RouterCard], decisions: [RouterDecision], summaries: [RouterSummary]) -> [Entry] {
        let entries = decisions.map(Entry.decision) + summaries.map(Entry.summary) + cards.filter { !$0.isOpen }.map(Entry.card)
        var seen = Set<String>()
        return entries.enumerated().sorted { a, b in
            a.element.date != b.element.date ? a.element.date < b.element.date : a.offset < b.offset
        }.map(\.element).filter { seen.insert($0.id).inserted }
    }

    private static func newestFirst(_ a: RouterCard, _ b: RouterCard) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id
    }

    /// Needs you's order: by kind (`Kind.rank`), then the most urgent (Jev's score; a session stopped mid-turn on a question
    /// or plan counts as blocking now, a turn he didn't score as today), then the newest.
    static func ranked(_ a: RouterCard, _ b: RouterCard) -> Bool {
        if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
        let ua = urgency(a), ub = urgency(b)
        if ua != ub { return ua > ub }
        return newestFirst(a, b)
    }

    static func urgency(_ card: RouterCard) -> Double {
        card.triage?.urgency ?? (card.kind.isTurn ? 2 : 4)
    }
}

extension Store {
    /// The asks Needs you shows: those of messages sent from the composer unfold over it instead (`RouterFlights`).
    var routerAsksInNeeds: [RouterAskBack] { routerDispatcher.askBacks.filter { !$0.context.flies } }

    /// The Router's page on what is stored and what runs now.
    var routerPage: RouterPage {
        .make(cards: router.cards, working: routerWorkingRows, asks: routerAsksInNeeds, history: routerHistory,
              summaries: router.summaries, tasks: routerTasks)
    }

    /// What sessions whose turn is over still have running, as the Working rows have it (a running session's row has none).
    /// Worked out as the tasks or the sessions change, not on each read: a read allocates nothing and observes only its
    /// revision, which moves when it changed.
    var routerTasks: [String: [ClaudeTask]] {
        _ = routerTasksRevision
        return routerTasksKept
    }

    /// Called by the tasks' and the sessions' didSets: the tasks of sessions not running, kept when they changed.
    func updateRouterTasks() {
        let tasks = claudeTasks
        let now = tasks.isEmpty ? tasks : tasks.filter { claudeSessions[$0.key]?.running != true }
        if now != routerTasksKept { bumpRouterTasks(now) }
    }

    /// The open cards the page shows: a done card whose session still runs subagents or commands is hidden there, so the
    /// Router's runs don't list it either (the zones, and so `mark_seen`, don't have it).
    var shownRouterCards: [RouterCard] { routerShownCards.filter(\.isOpen) }

    /// The Router's cards less those the page doesn't show (`RouterPage.shows`): what the keys and the away strip go by.
    var routerShownCards: [RouterCard] {
        let tasks = routerTasks
        return router.cards.filter { RouterPage.shows($0, tasks: tasks) }
    }

    /// The open cards the page shows, newest first: what Jev offers and a send goes to, and where a superseded card's pick
    /// moves. An addressed card is still replied to from the history.
    var routerShownOpenCards: [RouterCard] {
        let tasks = routerTasks
        return openRouterCards.filter { RouterPage.shows($0, tasks: tasks) }
    }

    /// The open cards as the page has them, Needs you (the waits yours to continue with it), Worth a look, then the
    /// sessions waiting: what the bar's panel lists. Not a finished turn whose session still runs work, nor a wait whose
    /// session is working again.
    var routerPanelCards: [RouterCard] {
        let page = routerZones
        return page.needs + page.ready + page.notes + page.waiting
    }

    /// The page's zones alone: what the live part of the page redraws on, without the history. Read by Now's column, the
    /// keys, the bar's panel and the pick on every redraw and press: worked out again only when what it is made of changed
    /// (`RouterMemo`). Its reads are those of the work, so a view reading it still redraws on any of them.
    var routerZones: RouterPage {
        let inputs = RouterMemo.ZoneInputs(cards: router.cards, rows: allAgentRows, asks: routerDispatcher.askBacks,
                                           summaries: router.summaries, tasks: routerTasks)
        if let memo = RouterMemo.zones, memo.inputs == inputs { return memo.page }
        let page = RouterPage.make(cards: inputs.cards, working: routerWorkingRows, asks: routerAsksInNeeds, history: [],
                                   summaries: inputs.summaries, tasks: inputs.tasks)
        RouterMemo.zones = (inputs, page)
        return page
    }
}

/// The Router's derived lists, kept with what they were worked out from: a read that finds the same inputs (most often the
/// very same arrays, compared by their storage at once) gets the last answer. One slot each, whatever store asks (the
/// answer is a function of the inputs alone), so a test's stores only miss.
@MainActor
enum RouterMemo {
    struct ZoneInputs: Equatable {
        var cards: [RouterCard]
        var rows: [AgentRow]
        var asks: [RouterAskBack]
        var summaries: [RouterSummary]
        /// `Store.routerTasks`: kept by the store, the same dictionary until it changes, so compared by its storage.
        var tasks: [String: [ClaudeTask]]
    }
    static var zones: (inputs: ZoneInputs, page: RouterPage)?

    struct CountInputs: Equatable {
        var cards: [RouterCard]
        var tasks: [String: [ClaudeTask]]
    }
    static var counts: (inputs: CountInputs, counts: (needsYou: Int, notes: Int))?
}

// MARK: - Page

private struct GutterKey: EnvironmentKey { static let defaultValue = CDS.Transcript.gutter }

extension EnvironmentValues {
    /// The history's lines are out of sight (hidden under Now): they draw what they last read, reading nothing live.
    @Entry var historyOutOfSight = false
}

/// A value a view last read live, kept for when it is out of sight. Not view state: written as it is drawn.
private final class LastRead<Value> {
    var value: Value?
}
extension EnvironmentValues {
    /// The page's side margin: 32, 16 in a narrow column.
    var routerGutter: CGFloat {
        get { self[GutterKey.self] }
        set { self[GutterKey.self] = newValue }
    }
}

/// Now and History: side by side in a wide window, one at a time with a switch over them in a narrow one. Each scrolls on
/// its own and nothing inside them does: a section of Now is as tall as it is, folded to its header line when you want it out
/// of the way.
struct RouterPageView: View {
    let store: Store
    @Bindable var model: RouterModel

    /// Whether the history has been shown on this page: in a narrow window it isn't built until it is, then kept, hidden
    /// under Now, so going back to it finds it as it was (its scroll, the lines drawn). Not view state: it turns on as the
    /// history shows, which redraws the page already.
    @State private var historyShown = Flag()
    private final class Flag { var on = false }

    /// Now's share of a wide page.
    static let nowShare: CGFloat = 0.55

    var body: some View {
        // The canvas (RouterCanvas.swift) takes the whole page when it is picked, the history a panel over it.
        Group {
            if model.layout == .canvas {
                CanvasPage(store: store, model: model)
            } else if model.layout == .brief {
                DigestPage(store: store, model: model)
            } else {
                columns
            }
        }
    }

    private var columns: some View {
        // The page's size as it is laid out, not measured after: the columns' widths are right on the first layout. The
        // frame reads nothing of the store: what each side shows is worked out in its own column.
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let wide = RouterZone.sideBySide(width: width)
            let nowWidth = wide ? (width * Self.nowShare).rounded() : width
            let historyWidth = wide ? width - nowWidth - CDS.hairline : width
            let showsNow = wide || model.pane == .now
            let historyHidden = !wide && showsNow
            let buildsHistory = historyShown.on || !historyHidden
            let _ = historyHidden ? () : (historyShown.on = true)
            // Once shown, the history is always the same view in the same place, shown or not, at any width: switching sides
            // or crossing into a wide window keeps where you were in it (its scroll, the lines drawn). A narrow page that
            // opens on Now doesn't build it (its list, its clock, its anchoring) until it is asked for.
            ZStack(alignment: .topLeading) {
                if buildsHistory {
                    HistoryColumn(store: store, model: model, bar: !wide, hidden: historyHidden)
                        .flightTarget(historyHidden ? nil : "history", flashes: false)
                        .column(historyWidth)
                        .frame(width: historyWidth, height: height)
                        .offset(x: wide ? nowWidth + CDS.hairline : 0)
                        .opacity(historyHidden ? 0 : 1)
                        .allowsHitTesting(!historyHidden)
                        .accessibilityHidden(historyHidden)
                }
                if showsNow {
                    NowColumn(store: store, model: model, height: height, bar: !wide)
                        .column(nowWidth)
                        .frame(width: nowWidth, height: height)
                }
                if wide {
                    Rectangle().fill(CDS.border).frame(width: CDS.hairline, height: height).offset(x: nowWidth)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
        }
    }

    static func gutter(_ width: CGFloat) -> CGFloat { width < 560 ? CDS.Transcript.narrowGutter : CDS.Transcript.gutter }

    /// Room over the history's first line. Before macOS 26 the top fade's height, so the first line starts clear of the
    /// strip; on 26 there is no top fade (the history runs under the switch, or the page's top bar in a wide window, the
    /// scroll edge effect softening what passes under them), so a short gap.
    static var historyTop: CGFloat {
        if #available(macOS 26, *) { return 12 }
        return CDS.Transcript.fade
    }
}

/// The history's side: its bar over it, the switch (in a narrow window, else its name) and on the right the Unread filter
/// and Mark all read. On macOS 26 the bar is the column's and the history runs under it, its lines dissolving under the
/// soft scroll edge effect rather than cut off at the bar; the history stays the same view at any width.
struct HistoryColumn: View {
    let store: Store
    let model: RouterModel
    let bar: Bool
    /// Under Now in a narrow window: its clock stops until it shows again.
    let hidden: Bool

    var body: some View {
        if #available(macOS 26, *) {
            history
                .safeAreaBar(edge: .top, spacing: 0) {
                    header
                        // The page's ground from the bar's middle up, so no line reads beside it, as under the composer;
                        // below, the lines fade out under the soft edge.
                        .background {
                            LinearGradient(colors: [CDS.Surface.s1, CDS.Surface.s1.opacity(0)], startPoint: .center, endPoint: .bottom)
                                .allowsHitTesting(false)
                        }
                }
                // The page hides its edge effects (its title line has a ground of its own); the history's is shown again.
                .scrollEdgeEffectHidden(false, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            VStack(spacing: 0) {
                header
                history
            }
        }
    }

    /// A history of its own for each side of the filter: turned on or off, it opens at its bottom, as at first.
    private var history: some View {
        RouterHistory(store: store, model: model, hidden: hidden).id(model.unreadOnly)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if bar {
                PaneSwitch(store: store, model: model)
            } else {
                HistoryTitle()
            }
            Spacer(minLength: 0)
            // The unread counted once on the line: on the switch's History when it is there.
            HistoryFilters(store: store, model: model, counted: !bar)
        }
        .measured()
        // As Now's chips row is, so the switch is in the same place on both sides.
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// Now's side: the switch (in a narrow window) and the sections' chips over the sections. Only it works out what's live.
private struct NowColumn: View {
    let store: Store
    let model: RouterModel
    let height: CGFloat
    let bar: Bool
    @Namespace private var ns

    var body: some View {
        let page = model.zones(store)
        // What the chips' solos and mutes leave; the chips count the whole page.
        let shown = page.filtered(model.filter)
        // A session moving between the zones is the same card travelling, unless it has one in both.
        let once = Dictionary(grouping: page.needs.map(\.sessionID), by: { $0 }).filter { $0.value.count == 1 }.keys
        let travelling = Set(once).subtracting(Set(page.working.map(\.id)))
        let travellingWorking = Set(page.working.map(\.id)).subtracting(Set(page.needs.map(\.sessionID)))
        if #available(macOS 26, *) {
            // The chips and the Router's status line are the column's bar: Now runs under it and the page's top bar, with a
            // hard edge, as its sections' headers pin under it (glass-plan §5.3).
            RouterNow(store: store, model: model, page: shown, height: height, ns: ns, travelling: travelling,
                      travellingWorking: travellingWorking)
                .flightFrame("now")
                .safeAreaBar(edge: .top, spacing: 0) { chips(page) }
                .scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            VStack(spacing: 0) {
                chips(page)
                RouterNow(store: store, model: model, page: shown, height: height, ns: ns, travelling: travelling,
                          travellingWorking: travellingWorking)
                    .flightFrame("now")
            }
        }
    }

    private func chips(_ page: RouterPage) -> some View {
        HStack(spacing: 12) {
            if bar { PaneSwitch(store: store, model: model) }
            ZoneChips(model: model, page: page, compact: bar)
            Spacer(minLength: 0)
        }
        .measured()
        .padding(.top, 6)
        .padding(.bottom, 2)
        // Under it is what shows of Now: where a message can land.
        .flightFrame("nowTop")
    }
}

extension View {
    /// A column of the page `width` wide: its margin and its text's measure.
    func column(_ width: CGFloat) -> some View {
        let gutter = RouterPageView.gutter(width)
        return self
            .environment(\.routerGutter, gutter)
            .environment(\.cdsColumnWidth, min(CDS.Transcript.measure, max(0, width - 2 * gutter)))
    }

    /// Centred in the page at the transcript's measure, its margin inside.
    func measured() -> some View {
        frame(maxWidth: CDS.Transcript.measure + 2 * CDS.Transcript.gutter).frame(maxWidth: .infinity)
    }
}

/// Now or History, in a narrow window: what's live with what needs you counted, and the history with its unread. Claude's
/// contained SegmentedControl (forms-buttons.md §5.4) as a pill, as its own app switch is (global-sidebar-titlebar.md
/// §2): the white-5% track with 1 of padding, the side shown on the white-10% thumb with its ring, the names muted until
/// shown or hovered. As tall as the sections' chips beside it, and drawn the same on both sides, so it never moves.
struct PaneSwitch: View {
    let store: Store
    let model: RouterModel
    @Environment(\.routerGutter) private var gutter
    @State private var hovered: RouterPane?

    var body: some View {
        HStack(spacing: 0) {
            // What needs you, as the badge counts it, and the messages waiting for you to say where they go.
            segment(.now, "Now", count: store.routerCounts.needsYou + store.routerAsksInNeeds.count, tint: CDS.Fill.warning)
            segment(.history, "History", count: store.routerUnread.count, tint: CDS.Fill.accent)
        }
        .padding(1)
        .frame(height: ZoneChip.height)
        // The track on the page's ground, so no history line scrolled under the switch shows through its names.
        .background(Capsule(style: .continuous).fill(CDS.Segmented.track).background(Capsule(style: .continuous).fill(CDS.Surface.s1)))
        .fixedSize()
        .padding(.leading, gutter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
    }

    private func segment(_ pane: RouterPane, _ title: String, count: Int, tint: Color) -> some View {
        let picked = model.pane == pane
        let thumb = ZoneChip.height - 2
        return Button { model.show(pane) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).cdsText((12, 16), .regular, picked || hovered == pane ? CDS.Text.primary : CDS.Text.muted)
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)").cdsText((12, 16), .medium, tint).monospacedDigit()
                }
            }
            .padding(.horizontal, CDS.Segmented.padX)
            .frame(maxHeight: .infinity)
            .background {
                if picked {
                    Capsule(style: .continuous).fill(CDS.Segmented.thumb)
                        .overlay(Capsule(style: .continuous).strokeBorder(CDS.border, lineWidth: 1))
                        .bakedShadow(CDS.fieldShadow, .rounded(thumb / 2), radius: 1, y: 1, fill: CDS.Segmented.thumb)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .flightTarget("pane:\(pane == .now ? "now" : "history")", radius: thumb / 2)
        .onHover { hovered = $0 ? pane : (hovered == pane ? nil : hovered) }
        .help(pane == .now ? "What's live: what needs you, what waits and what works" : "The Router's conversation and what was handled")
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The history's name over it in a wide window, where no switch says it, as tall as the switch would be.
private struct HistoryTitle: View {
    @Environment(\.routerGutter) private var gutter

    var body: some View {
        Text("History").cdsText((12, 16), .medium, CDS.Text.muted)
            .frame(height: ZoneChip.height)
            .padding(.leading, gutter + CDS.Transcript.textInset)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Over the history, on the right of its bar: the Unread filter and Mark all read, always there. With nothing unread Mark
/// all read stays, disabled, so the filter beside it doesn't move.
private struct HistoryFilters: View {
    let store: Store
    let model: RouterModel
    /// The unread count shown on the filter (none where the switch beside it counts them).
    let counted: Bool
    @Environment(\.routerGutter) private var gutter

    var body: some View {
        let unread = store.routerUnread.count
        HStack(spacing: 2) {
            UnreadFilter(count: counted ? unread : 0, on: model.unreadOnly) { model.unreadOnly.toggle() }
            MarkAllRead { model.markAllRead(store) }.disabled(unread == 0)
        }
        .fixedSize()
        .padding(.trailing, gutter)
    }
}

/// The Unread filter: a chip as the sections' are, lit in the accent the unread lines are while it is on.
private struct UnreadFilter: View {
    let count: Int
    let on: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(on ? CDS.Fill.accent : CDS.Text.muted)
                Text("Unread").cdsText((12, 16), .regular, on || hovered ? CDS.Text.primary : CDS.Text.secondary)
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)").cdsText((12, 16), .medium, CDS.Fill.accent).monospacedDigit()
                }
            }
            .padding(.horizontal, 7)
            .frame(height: ZoneChip.height)
            .background(Capsule().fill(on ? CDS.Fill.accent.opacity(hovered ? 0.2 : 0.14) : hovered ? CDS.Fill.ghostHover : CDS.alpha(0.04)))
            .overlay { if on { Capsule().strokeBorder(CDS.Fill.accent.opacity(0.5), lineWidth: 1) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(on ? "Show every line of the history" : "Show only the lines you haven't read")
        .accessibilityLabel(count > 0 ? "Unread only, \(count)" : "Unread only")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Mark all read: a ghost button as tall as the chips, its words muted until hovered.
private struct MarkAllRead: View {
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let hot = hovered && enabled
        Button(action: action) {
            Text("Mark all as read").cdsText((12, 16), .regular, hot ? CDS.Text.primary : CDS.Text.muted)
                .padding(.horizontal, 7)
                .frame(height: ZoneChip.height)
                .background(Capsule().fill(hot ? CDS.Fill.ghostHover : .clear))
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(enabled ? "Every finished turn in the history, read" : "Nothing unread")
    }
}

/// A chip for each section of Now with something in it, its count, with Solo and Mute on each and Clear after them: the
/// canvas's chips are the same (RouterFilter.swift).
private struct ZoneChips: View {
    let model: RouterModel
    let page: RouterPage
    /// Beside the switch: the sections' names go first when there's no room for them.
    var compact = false
    @Environment(\.routerGutter) private var gutter

    var body: some View {
        let counts = RouterZone.allCases.map { (CanvasGroup($0), page.count($0)) }.filter { $0.1 > 0 }
        if !counts.isEmpty {
            ViewThatFits(in: .horizontal) {
                RouterFilterRow(model: model, counts: counts, named: true)
                RouterFilterRow(model: model, counts: counts, named: false)
            }
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .padding(.leading, compact ? 0 : gutter)
            .padding(.trailing, gutter)
        }
    }
}

struct ZoneChip {
    /// The chips' height, and the switch's beside them.
    static let height: CGFloat = 20
}

extension RouterZone {
    var tint: Color {
        switch self {
        case .needs: CDS.Fill.warning
        case .notes: CDS.Text.secondary
        case .waiting: RouterTriage.waitingTint
        case .working: CDS.Text.muted
        }
    }
}

extension RouterPage {
    /// What a section of Now holds.
    func count(_ zone: RouterZone) -> Int {
        switch zone {
        case .needs: needs.count + ready.count + asks.count
        case .notes: notes.count
        case .waiting: waiting.count
        case .working: working.count
        }
    }

    /// The section of Now an item is drawn in (a card, an ask, a working or waiting session's row), if any.
    @MainActor func zone(of id: String) -> RouterZone? {
        if needs.contains(where: { $0.id == id }) || ready.contains(where: { $0.id == id })
            || asks.contains(where: { $0.id.uuidString == id }) { return .needs }
        if notes.contains(where: { $0.id == id }) { return .notes }
        if waiting.contains(where: { RouterModel.workingID($0.sessionID) == id }) { return .waiting }
        if working.contains(where: { RouterModel.workingID($0.id) == id }) { return .working }
        return nil
    }
}

/// While the Router itself works: one slim line over Now.
struct RouterBusyLine: View {
    let store: Store
    @Environment(\.routerGutter) private var gutter

    var body: some View {
        if store.routerDispatcher.isBusy {
            WorkingStatus(label: "The Router is working")
                .padding(.horizontal, gutter + CDS.Transcript.textInset)
                .padding(.vertical, 2)
                .measured()
                .transition(.opacity)
        }
    }
}

/// Tells how much of a scroll view's top its bars cover (its top content inset), where the scroll views say it (macOS 15).
private struct TopInsetWatch: ViewModifier {
    let changed: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in changed(inset) }
        } else {
            content
        }
    }
}

// MARK: - History

/// The history: opens at the bottom and follows what arrives while you are there; scrolled up, nothing
/// moves what you read. Only the newest lines are drawn, Show earlier draws more. A line is drawn from its own values (what
/// it shows, whether it is open or picked, the minute), so it redraws only when one of them changes; what it shows of a
/// session is in small views of their own, which redraw as the sessions do.
private struct RouterHistory: View {
    let store: Store
    let model: RouterModel
    /// Out of sight: the ages stop on their minute.
    let hidden: Bool
    @Environment(\.routerGutter) private var gutter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowArrival) private var arrival
    /// The oldest line drawn, once you scroll up or ask for earlier ones (so nothing drops off the top while you read); at the
    /// bottom, the newest `page` lines.
    @State private var oldest: HistoryWindow.Boundary?
    /// At the bottom: what arrives, and the zones growing under it, keep it there. Scrolled up, the top holds.
    @State private var pinned = true
    /// The content has been laid out: a scroll asked for before that waits for it. Not view state: its turning on draws
    /// nothing, it only lets a waiting scroll go (`released`, set only when one waits, redraws for it).
    @State private var laidOut = HistoryAnchoring.LaidOut()
    @State private var released = false
    @State private var pending: HistoryScroll?

    /// Lines drawn at first, and more each time Show earlier is clicked.
    static let page = 100

    /// What the history was last drawn from while it showed: hidden under Now, it is drawn from this and reads nothing
    /// of the store or the model, so a new line, a pick or a card read doesn't redraw it out of sight; shown again, it reads
    /// them afresh. Not view state: written as it is drawn.
    @State private var shown = Shown()
    private final class Shown {
        var taken = false
        var all: [RouterPage.Entry] = []
        var expanded: Set<String> = []
        var picked: String?
        var highlighted: String?
        var cancels: [UUID: HistoryDecisionLine.Cancel] = [:]
    }

    /// The model's history and marks, read only while the history shows (or before it was ever drawn).
    private func read() -> Shown {
        guard !hidden || !shown.taken else { return shown }
        shown.taken = true
        shown.all = model.history(store)
        shown.expanded = model.expanded
        shown.picked = model.selection
        shown.highlighted = model.highlighted
        return shown
    }

    var body: some View {
        let state = read()
        let all = state.all
        let entries = HistoryWindow.drawn(all, from: oldest, page: Self.page)
        let expanded = state.expanded, picked = state.picked, highlighted = state.highlighted
        // One clock for every age in the history, on the minute (stopped while the history is out of sight).
        MinuteTicking(paused: hidden) { now in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if entries.count < all.count {
                            ClaudeButton("Show earlier", variant: .ghost, size: .sm, icon: "arrow.up") {
                                let first = entries.startIndex
                                oldest = .init(all[max(0, first - Self.page)])
                                pending = HistoryScroll(id: all[first].id, anchor: .top, animated: false)
                            }
                            .padding(.bottom, 6)
                        }
                        if all.isEmpty, model.searching {
                            RouterNothingFound().padding(.leading, CDS.Transcript.textInset - 2)
                        } else if all.isEmpty, model.unreadOnly {
                            RouterNothingFound(text: "Nothing unread", symbol: "checkmark.circle")
                                .padding(.leading, CDS.Transcript.textInset - 2)
                        }
                        ForEach(entries) { entry in
                            row(entry, now: now, open: expanded.contains(entry.id), expanded: expanded,
                                marked: entry.id == picked || entry.id == highlighted)
                        }
                        // The bottom's margin: scrolling to it is scrolling to the very bottom.
                        Color.clear.frame(height: 18).id(RouterModel.endID)
                    }
                    // A scroller showing up never moves the column.
                    .overlayScrollers()
                    // Lines arrive, leave and change without moving; only a line opened or closed by its click animates.
                    .transaction { if !$0.historyToggle { $0.animation = nil } }
                    // macOS 14 has no scroll phases to read: the scroll view itself says when you scroll up, so the lines you
                    // read stay drawn as new ones arrive.
                    .background {
                        if #available(macOS 15, *) { EmptyView() } else {
                            HistoryScrollWatch(pinned: pinned) { step in
                                switch step {
                                case .stay: break
                                case .pin(let on): if pinned != on { pinned = on }
                                case .stick: pending = HistoryScroll(id: RouterModel.endID, anchor: .bottom, animated: false)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: CDS.Transcript.measure, alignment: .leading)
                    .padding(.horizontal, gutter)
                    .frame(maxWidth: .infinity)
                    .padding(.top, RouterPageView.historyTop)
                }
                .cdsTopFade()
                .environment(\.historyOutOfSight, hidden)
                .modifier(HistoryAnchoring(pinned: $pinned, laidOut: laidOut, ready: { if pending != nil { released = true } }) {
                    // With no scroll waiting (the history opening, its lazy lines' heights settling under it; a line arriving),
                    // a jump there and then: nothing of the page is redrawn for it, nor waits a turn.
                    if pending == nil {
                        var jump = Transaction(animation: nil)
                        jump.disablesAnimations = true
                        withTransaction(jump) { proxy.scrollTo(RouterModel.endID, anchor: .bottom) }
                    } else if pending?.id != RouterModel.endID {
                        // Once: geometry changing again while it waits asks for nothing more.
                        pending = HistoryScroll(id: RouterModel.endID, anchor: .bottom, animated: false)
                    }
                })
                // A card picked (clicked, or with the keys): as little scrolling as shows it whole; the Router picked: the bottom.
                // Asked for before the page was drawn too (a banner's card far up the history): it goes there once laid out.
                .onChange(of: model.revealRequest, initial: true) { _, request in
                    guard let request = model.takeReveal(request, by: "history") else { return }
                    scroll(to: request.id, anchor: request.id == RouterModel.endID ? .bottom : nil, in: all, drawn: entries)
                }
                // A message asked for (an action's chip), the page opening on it or not: gone to once, not again each time the
                // page is drawn.
                .onChange(of: model.messageRequest, initial: true) { _, request in
                    guard let request = model.takeReveal(request, by: "message") else { return }
                    scroll(to: request.id, anchor: .center, in: all, drawn: entries)
                }
                // Scrolled up, the lines drawn stay; back at the bottom, only the newest are.
                .onChange(of: pinned) { _, pinned in
                    if pinned { oldest = nil } else if oldest == nil { oldest = entries.first.map(HistoryWindow.Boundary.init) }
                }
                // A line opened by its click is on screen: at the bottom it opens upwards and stays whole; scrolled up it opens
                // downwards, and as little scrolling as shows it whole follows.
                .onChange(of: expanded) { old, new in
                    guard !pinned, let id = new.subtracting(old).first, entries.contains(where: { $0.id == id }) else { return }
                    pending = HistoryScroll(id: id, anchor: nil, animated: true)
                }
                .onChange(of: pending) { perform(proxy) }
                .onChange(of: released) { perform(proxy) }
            }
        }
    }

    /// Draws enough lines for the one asked for, then scrolls to it once it is drawn and laid out.
    private func scroll(to id: String, anchor: UnitPoint?, in all: [RouterPage.Entry], drawn: ArraySlice<RouterPage.Entry>) {
        if id != RouterModel.endID {
            guard let i = all.firstIndex(where: { $0.id == id }) else { return }
            // Off the bottom before the lines above are drawn: else their arrival reads as the pinned history falling short
            // of its bottom, and it is stuck back there instead of going to the line.
            pinned = false
            if i < drawn.startIndex { oldest = .init(all[i]) }
        }
        pending = HistoryScroll(id: id, anchor: anchor, animated: true)
    }

    private func perform(_ proxy: ScrollViewProxy) {
        guard laidOut.on, let scroll = pending else { return }
        pending = nil
        // A request made while this update performs the scroll (the geometry it moves asking to stick) changes `pending`
        // where its `onChange` doesn't see it: it is looked at once the update is over.
        DispatchQueue.main.async { perform(proxy) }
        // Going to a line leaves the bottom (until the scroll, once done, finds it there after all); going to the bottom pins.
        pinned = scroll.id == RouterModel.endID
        // While the window's content arrives, a jump (`WindowArrival`).
        if scroll.animated, arrival?.active != true, let motion = Motion.scroll.resolved(reduce: reduceMotion) {
            withAnimation(motion) { proxy.scrollTo(scroll.id, anchor: scroll.anchor) }
        } else {
            // A jump, even when what asked for it was animated (a line opening): it doesn't ride that animation.
            var jump = Transaction(animation: nil)
            jump.disablesAnimations = true
            withTransaction(jump) { proxy.scrollTo(scroll.id, anchor: scroll.anchor) }
        }
    }

    /// Whether a run's message can be cancelled now, and whether it is being.
    private func cancelState(_ decision: RouterDecision, now: Date) -> HistoryDecisionLine.Cancel {
        // Hidden: as last drawn (the dispatcher and the sessions aren't read out of sight).
        if hidden, shown.taken { return shown.cancels[decision.id] ?? .none }
        let state = liveCancelState(decision, now: now)
        if state == .none { shown.cancels[decision.id] = nil } else { shown.cancels[decision.id] = state }
        return state
    }

    private func liveCancelState(_ decision: RouterDecision, now: Date) -> HistoryDecisionLine.Cancel {
        guard let sent = decision.delivered else { return .none }
        if store.routerDispatcher.cancelling.contains(decision.id) { return .cancelling }
        // Only a message still within its window looks at its session: the history reads Claude's sessions (which change
        // with every read of them) only while there is one, not for every message it ever sent.
        guard sent.cancellable(session: nil, now: now) else { return .none }
        return store.canCancel(decision, now: now) ? .offered : .none
    }

    @ViewBuilder private func row(_ entry: RouterPage.Entry, now: Date, open: Bool, expanded: Set<String>, marked: Bool) -> some View {
        switch entry {
        case .card(let card):
            HistoryCardLine(card: card, now: now, open: open, marked: marked, store: store, model: model).equatable()
        case .decision(let decision) where decision.isDivided:
            // A message that went to several places: its line, and under it a line for each part, opening on its own.
            let places = decision.places.map { HistorySplitLine.Place(decision: $0, open: expanded.contains($0.id.uuidString),
                                                                       cancel: cancelState($0, now: now)) }
            HistorySplitLine(decision: decision, places: places, now: now, open: open, store: store, model: model).equatable()
        case .decision(let decision):
            HistoryDecisionLine(decision: decision, now: now, open: open, cancel: cancelState(decision, now: now),
                                store: store, model: model).equatable()
        case .summary(let summary):
            HistorySummaryLine(summary: summary, now: now, open: open, model: model).equatable()
        }
    }
}

/// A scroll the history was asked for; each one is new, even to the same line.
private struct HistoryScroll: Equatable {
    var id: String
    var anchor: UnitPoint?
    var animated: Bool
    private let token = UUID()

    init(id: String, anchor: UnitPoint?, animated: Bool) {
        self.id = id
        self.anchor = anchor
        self.animated = animated
    }
}

/// Opens the history at its bottom and keeps it there while you are (new lines, a line opening, the zones or the composer
/// under it growing); scrolled up, the top holds, so nothing moves what you read. Only a scroll takes it off the bottom: yours,
/// or one to a line asked for.
private struct HistoryAnchoring: ViewModifier {
    final class LaidOut { var on = false }

    @Binding var pinned: Bool
    let laidOut: LaidOut
    /// The content is laid out: a scroll asked for before goes now.
    let ready: () -> Void
    /// Back to the bottom, after something other than a scroll left it short of it.
    let stick: () -> Void
    /// Whether a scroll is under way (yours, or an animated one asked for); kept out of the view's state, as it changes
    /// mid-scroll and draws nothing.
    @State private var scrolling = HistoryPin.Scrolling()

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                // Every role at the bottom (opening there, the alignment), but changes of size only while pinned.
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(pinned ? .bottom : .top, for: .sizeChanges)
                .onScrollPhaseChange { _, phase, context in
                    scrolling.on = phase != .idle
                    if phase == .idle {
                        let geometry = HistoryPin.geometry(context.geometry.contentSize.height,
                                                           visibleMaxY: context.geometry.visibleRect.maxY,
                                                           bottomInset: context.geometry.contentInsets.bottom)
                        apply(.pin(HistoryPin.atBottom(geometry.content, visibleBottom: geometry.visibleBottom)))
                    }
                }
                .onScrollGeometryChange(for: HistoryPin.Reading.self) {
                    HistoryPin.Reading(
                        geometry: HistoryPin.geometry($0.contentSize.height, visibleMaxY: $0.visibleRect.maxY,
                                                      bottomInset: $0.contentInsets.bottom),
                        frame: .init(content: $0.contentSize, container: $0.containerSize, insets: $0.contentInsets))
                } action: { old, new in
                    if !laidOut.on, new.geometry.content > 0 {
                        laidOut.on = true
                        ready()
                    }
                    let scrolled = scrolling.on || HistoryPin.scrolled(from: old, to: new)
                    apply(HistoryPin.next(pinned: pinned, scrolling: scrolled, new.geometry))
                }
        } else {
            content
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    DispatchQueue.main.async {
                        laidOut.on = true
                        ready()
                    }
                }
        }
    }

    private func apply(_ step: HistoryPin.Step) {
        switch step {
        case .stay: break
        case .pin(let on): if pinned != on { pinned = on }
        case .stick: stick()
        }
    }
}

/// When the history counts as at its bottom, and what keeps it there.
enum HistoryPin {
    /// How far above the bottom still counts as there.
    static let slack: CGFloat = 24

    struct Geometry: Equatable {
        var content: CGFloat
        var visibleBottom: CGFloat
    }

    /// The geometry, and what lays out what shows: the content's size, the view's and what covers its edges.
    struct Reading: Equatable {
        var geometry: Geometry
        var frame: Frame

        struct Frame: Equatable {
            var content: CGSize
            var container: CGSize
            var insets: EdgeInsets
        }
    }

    /// What shows moved and nothing else: a scroll (yours, or one asked for), whatever the scroll phase says. A scroll asked
    /// for during yours (the Router picking the bottom, the history sticking back there) leaves SwiftUI's phase idle for the
    /// rest of your gesture, and each step of it read as layout stuck the history back to its bottom.
    static func scrolled(from old: Reading, to new: Reading) -> Bool {
        old.frame == new.frame && old.geometry != new.geometry
    }

    final class Scrolling { var on = false }

    enum Step: Equatable {
        case stay
        /// At the bottom or not, as the scroll left it.
        case pin(Bool)
        /// Something other than a scroll (a line arriving or opening, the space under it changing) left a pinned history
        /// short of its bottom: back there.
        case stick
    }

    /// The content's height and the bottom of what shows of it: the visible rect's, less what covers its bottom (on macOS
    /// 26 the composer floats over the history, its height a bottom inset), so a line under the composer is not shown.
    static func geometry(_ contentHeight: CGFloat, visibleMaxY: CGFloat, bottomInset: CGFloat) -> Geometry {
        Geometry(content: contentHeight, visibleBottom: visibleMaxY - bottomInset)
    }

    static func atBottom(_ contentHeight: CGFloat, visibleBottom: CGFloat) -> Bool {
        contentHeight - visibleBottom <= slack
    }

    static func next(pinned: Bool, scrolling: Bool, _ geometry: Geometry) -> Step {
        let bottom = atBottom(geometry.content, visibleBottom: geometry.visibleBottom)
        if scrolling { return .pin(bottom) }
        // Pinned means right at the bottom, not merely near it.
        return pinned && geometry.content - geometry.visibleBottom > 0.5 ? .stick : .stay
    }
}

/// Which lines of the history are drawn.
enum HistoryWindow {
    /// The oldest line drawn, and its time: the line may go (the oldest go past what is kept) while you read.
    struct Boundary: Equatable {
        var id: String
        var date: Date

        init(_ entry: RouterPage.Entry) {
            id = entry.id
            date = entry.date
        }
    }

    /// From the oldest line drawn on; gone, from the first line left at or after its time (what followed it), so the lines
    /// being read stay; none set (at the bottom): the newest `page`.
    static func drawn(_ all: [RouterPage.Entry], from oldest: Boundary?, page: Int) -> ArraySlice<RouterPage.Entry> {
        guard let oldest else { return all.suffix(page) }
        if let i = all.firstIndex(where: { $0.id == oldest.id }) { return all[i...] }
        guard let next = all.firstIndex(where: { $0.date >= oldest.date }) else { return all.suffix(page) }
        return all[next...]
    }
}

private struct HistoryToggleKey: TransactionKey { static let defaultValue = false }

private extension Transaction {
    /// A history line opening or closing by its click: the one change the history animates.
    var historyToggle: Bool {
        get { self[HistoryToggleKey.self] }
        set { self[HistoryToggleKey.self] = newValue }
    }
}

/// Runs `change` as a history line opening or closing: animated (unless Reduce Motion is on), and only that animates.
@MainActor private func toggleHistoryLine(reduceMotion: Bool, _ change: () -> Void) {
    var transaction = Transaction(animation: Motion.spatial.resolved(reduce: reduceMotion))
    transaction.historyToggle = true
    withTransaction(transaction, change)
}

/// A summary in the history: one line (icon, its session, the text, when), opening to show the whole text.
private struct HistorySummaryLine: View, Equatable {
    let summary: RouterSummary
    let now: Date
    let open: Bool
    let model: RouterModel
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.model === b.model && a.summary == b.summary && a.now == b.now && a.open == b.open
    }

    var body: some View {
        let lit = hovered || open
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleHistoryLine(reduceMotion: reduceMotion) { model.toggleExpanded(RouterPage.Entry.summary(summary).id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CDS.Text.muted).frame(width: 16, height: 16)
                    if let title = summary.title {
                        Text(title).cdsText(CDS.Transcript.text, .regular, lit ? CDS.Text.secondary : CDS.Text.muted)
                            .lineLimit(1).truncationMode(.tail).layoutPriority(2)
                        Text("· \(summary.text)").cdsText((12, 16), .regular, CDS.Text.muted)
                            .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    } else {
                        Text(summary.text).cdsText(CDS.Transcript.text, .regular, lit ? CDS.Text.secondary : CDS.Text.muted)
                            .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    }
                    StatusCaret(hot: hovered, open: open)
                    Spacer(minLength: 8)
                    Text(shortAgo(summary.at, now: now)).cdsText((12, 16), .regular, CDS.Text.muted).monospacedDigit()
                        .help(exactTime(summary.at))
                }
                .padding(.horizontal, CDS.Transcript.statusPad)
                .frame(height: CDS.Transcript.statusRow)
                .background(RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
                    .fill(hovered ? CDS.Fill.ghostHover : .clear))
                .contentShape(Rectangle())
                .overlay {
                    RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
                        .strokeBorder(CDS.Fill.accent, lineWidth: 1).opacity(focused ? 1 : 0)
                }
            }
            .buttonStyle(.plain)
            .focused($focused)
            .onHover { hovered = $0 }
            .accessibilityLabel(summary.title.map { "Summary of \($0)" } ?? "Overview")
            .accessibilityValue("\(summary.text), \(AgentRow.spokenAge(now.timeIntervalSince(summary.at))) ago, at \(exactTime(summary.at)), \(open ? "expanded" : "collapsed")")

            if open {
                CDSProse(text: summary.text, color: CDS.Text.primary, inset: false).historyDetails()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension RouterDecision {
    /// What a message that went to several places says on its line ("to 3 places"): its parts say how each stands. Nil for
    /// a message that went to one.
    var placesWords: String? { isDivided ? "to \(parts.count) places" : nil }

    /// How a part ended, for a line that names its place before the words: "sent", not "sent to" the place again.
    func summary(without place: String) -> String {
        let text = summary, sent = "sent to \(place)"
        return text.hasPrefix(sent) ? "sent" + text.dropFirst(sent.count) : text
    }

    /// While a typed run is under way, how far it is (classifying, sending…); else how it ended. Only a run under way reads
    /// the dispatcher (a held start too: what its first message waits for). The history's line and the canvas's pending
    /// line say it.
    @MainActor func status(_ store: Store) -> String {
        guard outcome == .pending else { return summary }
        if let progress = store.routerDispatcher.progress[id] { return progress + "…" }
        // A start whose first message waits for the Claude app to run the session: started, and what it waits for.
        if let held = store.routerDispatcher.held[id] { return summary + " · " + held }
        return summary
    }
}

/// A run in the history: one line (icon, what set it off, what was done, when), opening to show the trigger, what was done and
/// its links (the session, the change with its Revert). A message it sent that can still be stopped has Cancel on the line.
private struct HistoryDecisionLine: View, Equatable {
    enum Cancel: Equatable { case none, offered, cancelling }

    let decision: RouterDecision
    let now: Date
    let open: Bool
    let cancel: Cancel
    let store: Store
    let model: RouterModel
    /// One part of a divided message, under the line of the message: "→ place", then its words, with no age of its own.
    var nested = false
    @Environment(\.historyOutOfSight) private var outOfSight
    @State private var lastStatus = LastRead<(text: String, held: Bool)>()
    @State private var lastTrigger = LastRead<Text>()
    @State private var lastPlace = LastRead<String>()
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.model === b.model && a.decision == b.decision && a.now == b.now && a.open == b.open
            && a.cancel == b.cancel && a.nested == b.nested
    }

    /// What Cancel does and doesn't, as its tooltip and beside it when the line is open.
    static let cancelHelp = "Stops this message in its session: if Claude hasn't started on it, it never will; if it's working on it, "
        + "it stops, and doesn't carry on. Anything it already did (edits, commands) stays done, a command it was running finishes on "
        + "its own unseen, and your message stays in the session's history."

    static let cancelWidth: CGFloat = 64

    private var key: String { decision.id.uuidString }
    /// While a typed run is under way, how far it is (classifying, sending…); else how it ended. Only a run under way reads
    /// the dispatcher (a held start too: what its first message waits for).
    private var status: (text: String, held: Bool) {
        // The message that went to several places: its parts say how each stands.
        if let places = decision.placesWords { return (places, false) }
        // A part names its place before its words: "sent", not "sent to" it again.
        guard decision.outcome == .pending else { return (nested ? decision.summary(without: place) : decision.summary, false) }
        // Out of sight, as last read: the dispatcher isn't read for a history hidden under Now.
        if outOfSight, let kept = lastStatus.value { return kept }
        let held = store.routerDispatcher.held[decision.id]
        let read: (String, Bool)
        if let progress = store.routerDispatcher.progress[decision.id] {
            read = (progress + "…", held != nil)
        } else if let held {
            // A start whose first message waits for the Claude app to run the session: started, and what it waits for. A part
            // held for another place's answer: held, and what it waits for.
            // The line names just the place it waits for; the rest is in its details.
            let holding = RouterFlights.holds(decision)
            let waitsFor = holding ? RouterFlights.destination(decision.parts.first?.waitsFor, store: store) : nil
            read = (holding ? "held" + (waitsFor.map { " · waits for \($0)" } ?? " · " + held) : decision.summary + " · " + held, true)
        } else {
            read = (decision.summary, false)
        }
        lastStatus.value = read
        return read
    }

    var body: some View {
        let (status, held) = status
        VStack(alignment: .leading, spacing: 0) {
            Button { toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: decision.symbol).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CDS.Text.muted).frame(width: 16, height: 16)
                    trigger
                        .cdsText(CDS.Transcript.text, .regular, hovered || open ? CDS.Text.secondary : CDS.Text.muted)
                        .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    // A held part's line gives its words up before what it waits for.
                    Text("· \(status)").cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).layoutPriority(held ? 2 : 0)
                    // A part held for another place's answer: sent when you say so.
                    if held, RouterFlights.holds(decision) {
                        Button("Send now") { store.routerDispatcher.sendNow(decision.id) }
                            .buttonStyle(.link).font(CDS.sans(12)).fixedSize()
                            .help("Sends it now, without waiting for the answer it needs")
                    }
                    // A held start's first message: yours to drop (Stop leaves it be).
                    if held {
                        Button("Don't send") { store.routerDispatcher.dropHeld(decision.id) }
                            .buttonStyle(.link).font(CDS.sans(12)).fixedSize()
                            .help(RouterFlights.holds(decision) ? "It isn't sent" : "Its first message isn't sent; the session stays in the Claude app")
                    }
                    StatusCaret(hot: hovered, open: open)
                    Spacer(minLength: 8)
                    // A part is as old as its message: the line above says.
                    if !nested {
                        Text(shortAgo(decision.at, now: now)).cdsText((12, 16), .regular, CDS.Text.muted).monospacedDigit()
                            .help(exactTime(decision.at))
                    }
                    // Room for Cancel, laid over it: the line stays one button, and Cancel one of its own.
                    if cancel != .none { Color.clear.frame(width: Self.cancelWidth, height: 1) }
                }
                .padding(.horizontal, CDS.Transcript.statusPad)
                .frame(height: CDS.Transcript.statusRow)
                .background(RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
                    .fill(hovered ? CDS.Fill.ghostHover : .clear))
                .contentShape(Rectangle())
                .overlay {
                    RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
                        .strokeBorder(CDS.Fill.accent, lineWidth: 1).opacity(focused ? 1 : 0)
                }
            }
            .buttonStyle(.plain)
            .focused($focused)
            .onHover { hovered = $0 }
            .accessibilityLabel(nested ? "To \(place): \(decision.triggerText)" : decision.triggerText)
            .accessibilityValue("\(status), \(AgentRow.spokenAge(now.timeIntervalSince(decision.at))) ago, at \(exactTime(decision.at)), \(open ? "expanded" : "collapsed")")
            .overlay(alignment: .trailing) {
                if cancel != .none {
                    ClaudeButton("Cancel", variant: .ghost, size: .sm, busy: cancel == .cancelling) {
                        let id = decision.id
                        Task { await store.routerDispatcher.cancel(id) }
                    }
                    .help(Self.cancelHelp)
                    .accessibilityHint(Self.cancelHelp)
                    .frame(width: Self.cancelWidth, alignment: .trailing)
                    .padding(.trailing, CDS.Transcript.statusPad - 6)
                }
            }

            if open { DecisionDetails(decision: decision, cancel: cancel, store: store, model: model) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle() {
        toggleHistoryLine(reduceMotion: reduceMotion) { model.toggleExpanded(key) }
    }

    /// What set it off; for a part, the place it went to and then its words.
    private var trigger: Text {
        guard nested else { return words }
        return Text("\(Text(verbatim: "→ \(place)  ").fontWeight(.medium))\(words)")
    }

    /// Where a part went, as the pill names it: the session's title, "New session in lcu", Fjord; as last read while out of sight.
    private var place: String {
        if outOfSight, let kept = lastPlace.value { return kept }
        let part = decision.parts[0]
        let target = part.decision.targetID ?? part.place
        var name = target.flatMap { RouterFlights.destination($0, store: store) }
        if name == nil, let target {
            // Not placed yet (a project's tag), or a session that is gone.
            name = target.hasPrefix("project:") ? store.folderName(String(target.dropFirst(8))) : "a session"
        }
        let made = name ?? "…"
        lastPlace.value = made
        return made
    }

    /// Your message with its pills drawn where they were, after its category when a "Then" sent it.
    private var words: Text {
        guard case .you(let text) = decision.trigger, let mentions = decision.mentions, !mentions.isEmpty else {
            return Text(RouterDecision.clip(decision.triggerText, 90))
        }
        // Its pills name sessions and projects as they are now (all of Claude's sessions read): out of sight, as last read.
        if outOfSight, let kept = lastTrigger.value { return kept }
        let made = styledTrigger(text, mentions)
        lastTrigger.value = made
        return made
    }

    private func styledTrigger(_ text: String, _ mentions: [RouterMention]) -> Text {
        let message = MentionText.styled(text, mentions: mentions, store: store, role: CDS.Transcript.text)
        guard let from = decision.fromAction else { return message }
        return Text("\(Text(verbatim: "\(from.category) · ").fontWeight(.medium))\(message)")
    }
}

/// A message that went to several places in the history: its line ("to 3 places", opening to the whole message), and under it a
/// line for each part, indented ("→ place", its words, how it stands), each opening, cancelling and acting on its own.
private struct HistorySplitLine: View, Equatable {
    /// A part as an entry of its own, whether it is open and whether its send can be cancelled.
    struct Place: Equatable {
        let decision: RouterDecision
        let open: Bool
        let cancel: HistoryDecisionLine.Cancel
    }

    let decision: RouterDecision
    let places: [Place]
    let now: Date
    let open: Bool
    let store: Store
    let model: RouterModel

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.model === b.model && a.decision == b.decision && a.places == b.places && a.now == b.now
            && a.open == b.open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HistoryDecisionLine(decision: decision, now: now, open: open, cancel: .none, store: store, model: model).equatable()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(places, id: \.decision.id) { place in
                    HistoryDecisionLine(decision: place.decision, now: now, open: place.open, cancel: place.cancel, store: store,
                                        model: model, nested: true).equatable()
                }
            }
            .padding(.leading, CDS.Transcript.statusPad + 14)
            .overlay(alignment: .leading) {
                Rectangle().fill(CDS.border).frame(width: 1).padding(.leading, CDS.Transcript.statusPad + 7).padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An open run's details: what set it off, its reply, what was done, its changes and its sessions, and while its message can
/// still be stopped, what Cancel does with Cancel and Send elsewhere.
private struct DecisionDetails: View {
    let decision: RouterDecision
    let cancel: HistoryDecisionLine.Cancel
    let store: Store
    let model: RouterModel
    @Environment(\.historyOutOfSight) private var outOfSight
    @State private var last = LastRead<Live>()

    /// What it shows of the store (the pills' names, its changes, the sessions and their titles, whether Triage, the Router
    /// and the run are on): read live while the history shows, as last read while it is out of sight.
    private struct Live {
        var styled: Text?
        var changes: [FjordChange]
        var toolsLinked: Bool
        var running: Bool
        var sessions: [(id: String, title: String)]
        var canEdit: Bool
        /// What a part held for another place's answer waits for, and what happens to it.
        var waits: String?
    }

    private var live: Live {
        if outOfSight, let kept = last.value { return kept }
        var styled: Text?
        if case .you(let text) = decision.trigger, let mentions = decision.mentions, !mentions.isEmpty {
            styled = MentionText.styled(text, mentions: mentions, store: store, role: CDS.Transcript.text)
        }
        // The message that went to several places shows its words only: each part has its own line, with the rest.
        let whole = !decision.isDivided
        let changes = whole ? decision.links.changes.compactMap { id in store.router.changes.first { $0.id == id } } : []
        let sessions = whole ? decision.links.sessions.compactMap { id in store.claudeSessions[id].map { (id, $0.title) } } : []
        let canEdit = decision.sentMessage.map { sent in
            store.routerOn && store.claudeSessions[sent.session].map { !$0.isArchived } == true
        } ?? false
        let waits = RouterFlights.holds(decision) ? store.routerDispatcher.held[decision.id] : nil
        let read = Live(styled: styled, changes: changes, toolsLinked: store.toolsLinked,
                        running: store.routerDispatcher.progress[decision.id] != nil, sessions: sessions, canEdit: canEdit, waits: waits)
        last.value = read
        return read
    }

    var body: some View {
        let live = live
        VStack(alignment: .leading, spacing: 10) {
            if let from = decision.fromAction {
                Text("⚡ Sent by \(from.category)'s Then for \(from.thing)").cdsText((12, 16), .regular, CDS.Text.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let styled = live.styled {
                styled
                    .cdsText(CDS.Transcript.text, .regular, CDS.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                CDSProse(text: decision.triggerText, color: CDS.Text.secondary, inset: false)
            }
            if let reply = decision.reply { CDSProse(text: reply, color: CDS.Text.primary, inset: false) }
            if let waits = live.waits {
                Text(waits.prefix(1).uppercased() + waits.dropFirst()).cdsText((12, 16), .regular, CDS.Text.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !decision.isDivided {
                ForEach(Array(decision.doneLines.enumerated()), id: \.offset) { _, line in
                    Text(line).cdsText((12, 16), .regular, CDS.Text.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(live.changes) { change in ChangeCard(change: change, store: store) }
            if cancel != .none {
                Text(HistoryDecisionLine.cancelHelp).cdsText((12, 16), .regular, CDS.Text.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ClaudeButton("Cancel", variant: .secondary, size: .sm, busy: cancel == .cancelling) {
                        let id = decision.id
                        Task { await store.routerDispatcher.cancel(id) }
                    }
                    if case .you = decision.trigger {
                        ClaudeButton("Cancel and send elsewhere…", variant: .ghost, size: .sm) {
                            store.routerDispatcher.sendElsewhere(decision.id)
                        }
                        // An action's message goes anywhere only while Triage and the Router are both on.
                        .help(decision.fromAction != nil && !live.toolsLinked
                              ? "Triage is off: an action's message can't be sent elsewhere until it is on again"
                              : "Cancels it here, then asks where it should go instead, this session left out. Your pick teaches the Router.")
                        .disabled(cancel == .cancelling || live.running || (decision.fromAction != nil && !live.toolsLinked))
                    }
                }
            }
            if !live.sessions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(live.sessions, id: \.id) { session in
                        ClaudeButton("Open \(session.title)", variant: .ghost, size: .sm,
                                     icon: ClaudeMark.openSymbol) { store.openAgent(session.id) }
                    }
                    // The message it sent, taken back in a fork: the session as it was before it (this one stays as it is),
                    // and that again with the message edited.
                    if let sent = decision.sentMessage, live.canEdit {
                        ClaudeButton("Edit and resend", variant: .ghost, size: .sm, icon: "pencil") {
                            model.edit(session: sent.session, message: sent.text, sentAt: sent.at)
                        }
                        .help("Opens it in the composer; sending it starts a fork of the session from before this message. Files the agent changed aren't rolled back")
                        ClaudeButton("Fork from before this", variant: .ghost, size: .sm, icon: "arrow.triangle.branch") {
                            store.forkSession(sent.session, point: .before(sent.text, after: sent.at))
                        }
                        .help("A new session with this one's conversation up to before this message; files aren't rolled back")
                    }
                }
            }
        }
        .historyDetails()
    }
}

/// An addressed card in the history: a dim line (its session's glyph, title, how it was addressed, when) opening to its kind,
/// project and text, and Reopen. Clicking it shows it in full with the composer ready to reply to it; hovering it shows
/// Open in Claude in the time's place.
struct HistoryCardLine: View, Equatable {
    let card: RouterCard
    let now: Date
    let open: Bool
    let marked: Bool
    let store: Store
    let model: RouterModel
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.canvasNodeID) private var canvasNode

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.model === b.model && a.card == b.card && a.now == b.now && a.open == b.open
            && a.marked == b.marked
    }

    private var when: Date { card.addressedAt ?? card.createdAt }
    private var how: String {
        if let note = card.addressedNote { return "addressed by your message: \(RouterDecision.clip(note, 60))" }
        // Finished with nothing for you: what it did is the line.
        if card.addressedBy == .settled { return RouterDecision.clip(card.brief ?? card.text, 140) }
        return card.addressedBy?.label ?? "Addressed"
    }
    private var unread: Bool { card.unread == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // Opening an unread line is seeing it.
                // The pick, the reply and the line seen change at once, unanimated; only the line opening or closing animates.
                let opening = !model.expanded.contains(card.id)
                withTransaction(Transaction(animation: nil)) {
                    if unread { store.acknowledgeRouterCard(card.id) }
                    if opening { model.reply(to: card.id, store: store, reveal: false, expand: false) }
                }
                toggleHistoryLine(reduceMotion: reduceMotion) {
                    // On the canvas it is the one node open.
                    if canvasNode != nil {
                        if opening { model.canvasOpen(card.id) }
                        model.canvas.openDone = opening ? card.id : nil
                    }
                    if opening { model.expanded.insert(card.id) } else { model.expanded.remove(card.id) }
                }
            } label: {
                if canvasNode != nil { canvasLine } else { line }
            }
            .buttonStyle(.plain)
            .focused($focused)
            .canvasHeader()
            .help(exactTime(when))
            .accessibilityLabel("\(unread ? "Unread, " : "")\(card.kind.label): \(card.title)")
            .accessibilityValue("\(how), \(AgentRow.spokenAge(now.timeIntervalSince(when))) ago, at \(exactTime(when)), \(open ? "expanded" : "collapsed")")
            .accessibilityAddTraits(open ? .isSelected : [])
            .accessibilityHint("Shows it in full and replies to it")
            .accessibilityAction(named: "Open in Claude") { store.openAgent(card.sessionID) }
            .accessibilityAction(named: "Reopen") { model.reopen(card.id, store: store) }
            .accessibilityAction(named: "Got it") { store.acknowledgeRouterCard(card.id) }

            if open { CardDetails(card: card, store: store, model: model) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovered = $0 }
        .contextMenu { CardSessionMenu(store: store, sessionID: card.sessionID) }
    }

    /// On the canvas: the same line in fixed columns, so every line of a group has its caret, age and Open in Claude in the
    /// same place, and hovering one moves nothing: the unread dot's room is always kept, the words take what is left (Got
    /// it with them), and the caret, the age and Open in Claude's room are always there at the end.
    private var canvasLine: some View {
        HStack(spacing: 8) {
            Circle().fill(CDS.Fill.accent).frame(width: 6, height: 6).opacity(unread ? 1 : 0).accessibilityHidden(true)
            CardGlyph(store: store, sessionID: card.sessionID, symbol: card.kind.symbol)
            HStack(spacing: 6) {
                Text(card.title).cdsText(CDS.Transcript.text, unread ? .medium : .regular,
                                         unread ? CDS.Text.primary : hovered || open ? CDS.Text.secondary : CDS.Text.muted)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Text("· \(how)").cdsText((12, 16), .regular, unread ? CDS.Text.secondary : CDS.Text.muted)
                    .lineLimit(1).truncationMode(.tail).frame(minWidth: 56, alignment: .leading)
                if unread {
                    Button("Got it") { store.acknowledgeRouterCard(card.id) }
                        .buttonStyle(.link).font(CDS.sans(12)).fixedSize()
                        .help("Seen: it reads as any other line")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusCaret(hot: hovered, open: open).fixedSize()
            Text(shortAgo(when, now: now)).cdsText((12, 16), .regular, CDS.Text.muted).monospacedDigit()
                .lineLimit(1).frame(width: 30, alignment: .trailing)
            HoverOpen(title: card.title, shown: hovered) { store.openAgent(card.sessionID) }.frame(width: 22)
        }
        .padding(.horizontal, CDS.Transcript.statusPad)
        .frame(height: CDS.Transcript.statusRow)
        .background(RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
            .fill(marked ? CDS.Fill.ghostSelected : hovered ? CDS.Fill.ghostHover : unread ? CDS.Fill.accent.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
                .strokeBorder(CDS.Fill.accent, lineWidth: 1).opacity(focused ? 1 : 0)
        }
    }

    private var line: some View {
        HStack(spacing: 8) {
            if unread { Circle().fill(CDS.Fill.accent).frame(width: 6, height: 6).accessibilityHidden(true) }
            CardGlyph(store: store, sessionID: card.sessionID, symbol: card.kind.symbol)
            Text(card.title).cdsText(CDS.Transcript.text, unread ? .medium : .regular,
                                     unread ? CDS.Text.primary : hovered || open ? CDS.Text.secondary : CDS.Text.muted)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Text("· \(how)").cdsText((12, 16), .regular, unread ? CDS.Text.secondary : CDS.Text.muted).lineLimit(1)
            if unread {
                Button("Got it") { store.acknowledgeRouterCard(card.id) }
                    .buttonStyle(.link).font(CDS.sans(12)).fixedSize()
                    .help("Seen: it reads as any other line")
            }
            StatusCaret(hot: hovered, open: open)
            Spacer(minLength: 8)
            // Open in Claude takes the time's place on hover, so the line lines up with the runs around it (and the
            // line, not the hidden age, shows the time on hover).
            Text(shortAgo(when, now: now)).cdsText((12, 16), .regular, CDS.Text.muted).monospacedDigit()
                .opacity(hovered ? 0 : 1)
                .overlay(alignment: .trailing) {
                    HoverOpen(title: card.title, shown: hovered) { store.openAgent(card.sessionID) }
                }
        }
        .padding(.horizontal, CDS.Transcript.statusPad)
        .frame(height: CDS.Transcript.statusRow)
        .background(RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
            .fill(marked ? CDS.Fill.ghostSelected : hovered ? CDS.Fill.ghostHover : unread ? CDS.Fill.accent.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
                .strokeBorder(CDS.Fill.accent, lineWidth: 1).opacity(focused ? 1 : 0)
        }
    }
}

/// An open history card's details: its kind, project and origin, its text, and Reopen.
struct CardDetails: View {
    let card: RouterCard
    let store: Store
    let model: RouterModel
    @Environment(\.historyOutOfSight) private var outOfSight
    @State private var last = LastRead<(project: RouterProject, reopens: Bool)>()

    /// Its project and whether it can be reopened (its session's state): live while the history shows, as last read while
    /// it is out of sight.
    private var live: (project: RouterProject, reopens: Bool) {
        if outOfSight, let kept = last.value { return kept }
        let read = (store.routerProject(card), store.routerCanReopen(card))
        last.value = read
        return read
    }

    var body: some View {
        let (project, reopens) = live
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                KindTag(kind: card.kind)
                TriageChips(triage: card.triage)
                ProjectLabel(name: project.name, color: project.color, maxWidth: 240)
                    .cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1)
                if let origin = card.origin { OriginTag(origin: origin) }
            }
            CDSProse(text: card.text, color: CDS.Text.secondary, inset: false)
            if reopens {
                ClaudeButton("Reopen", variant: .secondary, size: .sm, icon: "arrow.uturn.backward") {
                    model.reopen(card.id, store: store)
                }
            }
        }
        .historyDetails()
    }
}

/// A history card's session glyph, dimmed; its kind's symbol once the session is gone. A view of its own: the sessions it
/// reads change all the time, and only it redraws for them.
struct CardGlyph: View {
    let store: Store
    let sessionID: String
    let symbol: String
    @Environment(\.historyOutOfSight) private var outOfSight
    @State private var last = LastRead<AgentRow?>()

    /// The session's row: read live while the history shows, as last read while it is out of sight.
    private var session: AgentRow? {
        if outOfSight, let kept = last.value { return kept }
        let row = store.sessionRow(sessionID)
        last.value = .some(row)
        return row
    }

    var body: some View {
        if let session {
            SessionGlyph(row: session, size: 16, dot: false).opacity(0.7)
        } else {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .foregroundStyle(CDS.Text.muted).frame(width: 16, height: 16)
        }
    }
}

/// An open card's session glyph, or with `room` only the room it takes; nothing once the session is gone. A view of its own
/// for the same reason.
struct CardLead: View {
    let store: Store
    let sessionID: String
    var room = false

    var body: some View {
        if let session = store.sessionRow(sessionID) {
            if room { Color.clear.frame(width: 20, height: 1) } else { SessionGlyph(row: session, size: 20, dot: false) }
        }
    }
}

/// A card's session menu, in a view of its own for the same reason.
struct CardSessionMenu: View {
    let store: Store
    let sessionID: String

    var body: some View {
        if let session = store.sessionRow(sessionID) { SessionMenu(row: session, store: store) }
    }
}

/// Open in Claude on a line. On a history line it shows while the line is hovered, its room kept so nothing moves; `quiet`,
/// on a working or waiting row, it is always there, muted until the pointer is on it, as the sparkles button.
struct HoverOpen: View {
    let title: String
    var shown = true
    var quiet = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            OpenInClaudeGlyph(size: 13)
                .foregroundStyle(quiet && !hovered ? CDS.Text.muted : CDS.Text.secondary)
                .frame(width: 22, height: quiet ? 20 : 22)
                .background(RoundedRectangle(cornerRadius: quiet ? CDS.Density.compact.radius : 5, style: .continuous)
                    .fill(quiet && !hovered ? .clear : CDS.Fill.ghostHover))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .tip("Open in Claude")
        .accessibilityLabel("Open \(title) in Claude")
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .hoverMotion(shown)
        .accessibilityHidden(!shown)
    }
}

private extension View {
    /// An open history line's box under it.
    func historyDetails() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: CDS.Transcript.stepCardRadius, style: .continuous).fill(CDS.Fill.field))
            .overlay { RoundedRectangle(cornerRadius: CDS.Transcript.stepCardRadius, style: .continuous).strokeBorder(CDS.border, lineWidth: 1) }
            .padding(.top, 6).padding(.bottom, 4)
    }
}

// MARK: - Zones

/// What's live, top to bottom by whose move is next: Needs you, Worth a look, Waiting, Working. One scroll: a section is as
/// tall as it is, and its header stays at the top while you are in it. A click on a header folds the section to that line
/// (what it holds said on it) or opens it, the sections under it moving up or down with it; kept as you leave them.
private struct RouterNow: View {
    let store: Store
    @Bindable var model: RouterModel
    let page: RouterPage
    /// The page's height: what an open form may take is worked out from it.
    let height: CGFloat
    let ns: Namespace.ID
    /// Sessions whose card moves between the zones (matched geometry), from the needs side and from the working side.
    let travelling: Set<String>
    let travellingWorking: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowArrival) private var arrival
    @Environment(\.routerGutter) private var gutter
    @Environment(\.cdsColumnWidth) private var columnWidth
    /// Every card of Worth a look shown, not the first few.
    @State private var showAllNotes = false
    /// A scroll asked for, made once the page has laid out what it opened for it.
    @State private var pending: Pending?
    /// Where each section starts, as last laid out (above the top of what shows: you are inside it). Not view state:
    /// nothing is drawn from it, a fold reads it.
    @State private var tops = Tops()
    static let notesShown = 3

    /// `y` from the scroll view's top; `inset` how much of that top its bars cover (the page's top bar and the column's on
    /// macOS 26, where the scroll runs under them), so what shows starts there.
    private final class Tops {
        var y: [RouterZone: CGFloat] = [:]
        var inset: CGFloat = 0
    }

    private struct Pending: Equatable {
        var id: String
        var anchor: UnitPoint
        private let token = UUID()
        init(_ id: String, anchor: UnitPoint) { self.id = id; self.anchor = anchor }
    }

    private var spring: Animation? { Motion.spatial.resolved(reduce: reduceMotion) }

    /// The sections shown: Needs you always (it says when nothing needs you), the others with something in them; while
    /// a search is on, only those with a match.
    private var zones: [RouterZone] {
        RouterZone.allCases.filter { ($0 == .needs && !model.searching && model.filter.shows(zone: $0)) || page.count($0) > 0 }
    }

    var body: some View {
        let folded = model.shownFolds
        let zones = self.zones
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        AwayStripView(store: store, model: model).padding(.bottom, 4)
                        if zones.isEmpty {
                            if model.filter.isClear { RouterNothingFound() }
                            else { RouterNothingFound(text: "Nothing matches · Esc to clear", symbol: "line.3.horizontal.decrease") }
                        }
                        ForEach(zones) { zone in
                            let isFolded = folded.contains(zone) && page.count(zone) > 0
                            Color.clear.frame(height: 0).id(zone.anchorID)
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { tops.y[zone] = $0 }
                            Section {
                                if !isFolded {
                                    content(zone)
                                        .padding(.bottom, 16)
                                        .transition(.asymmetric(
                                            insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : -6)),
                                            removal: .opacity))
                                }
                            } header: {
                                header(zone, folded: isFolded, proxy: proxy)
                            }
                        }
                    }
                    // A scroller showing up never moves the column.
                    .overlayScrollers()
                    .padding(.horizontal, gutter)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                    .measured()
                    .motion(.spatial, value: page.needs.map(\.id) + page.working.map(\.id))
                }
                .scrollBounceBehavior(.basedOnSize)
                .modifier(TopInsetWatch { tops.inset = $0 })
                // A card picked (with the keys, a banner, the away strip): its section opens, and the page goes to it.
                .onChange(of: model.revealRequest, initial: true) { _, request in
                    guard let request, let zone = page.zone(of: request.id),
                          let taken = model.takeReveal(request, by: "now") else { return }
                    open(zone)
                    pending = Pending(taken.id, anchor: .center)
                }
                // A section's chip: opened, its header at the top.
                .onChange(of: model.zoneRequest, initial: true) { _, request in
                    guard let request, model.takeReveal(request, by: "zone") != nil else { return }
                    if let zone = RouterZone(rawValue: request.id) {
                        open(zone)
                        pending = Pending(zone.anchorID, anchor: .top)
                    }
                }
                .onChange(of: pending) { perform(proxy) }
            }
        }
    }

    private func open(_ zone: RouterZone) {
        guard model.shownFolds.contains(zone) else { return }
        withAnimation(spring) { model.setFolded(zone, false) }
    }

    /// The scroll asked for, once what was opened for it is laid out.
    private func perform(_ proxy: ScrollViewProxy) {
        guard let request = pending else { return }
        DispatchQueue.main.async {
            guard pending == request else { return }
            pending = nil
            // While the window's content arrives (a card asked for as it opens), a jump (`WindowArrival`).
            withAnimation(arrival?.active == true ? nil : Motion.scroll.resolved(reduce: reduceMotion)) {
                proxy.scrollTo(request.id, anchor: request.anchor)
            }
        }
    }

    /// Folds a section or opens it. Folding the one whose header is held at the top (you are inside it) takes the page back
    /// to its start, so the header stays where you clicked it and the next section comes up under it.
    private func toggle(_ zone: RouterZone, proxy: ScrollViewProxy) {
        let folding = !model.shownFolds.contains(zone)
        let inside = (tops.y[zone] ?? 0) < tops.inset - 1
        withAnimation(spring) {
            model.setFolded(zone, folding)
            if folding && inside { proxy.scrollTo(zone.anchorID, anchor: .top) }
        }
        Announce.say(folding ? "\(zone.title) folded" : "\(zone.title) open")
    }


    // MARK: Headers

    @ViewBuilder private func header(_ zone: RouterZone, folded: Bool, proxy: ScrollViewProxy) -> some View {
        let count = page.count(zone)
        HStack(spacing: 6) {
            if zone == .needs && count == 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 12, weight: .medium))
                    Text("Nothing needs you").cdsText((13, 18), .regular, CDS.Text.muted)
                }
                .foregroundStyle(CDS.Text.muted)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                ZoneHeaderButton(zone: zone, count: count, folded: folded, preview: { preview(zone) }) {
                    toggle(zone, proxy: proxy)
                }
                accessory(zone, folded: folded)
            }
        }
        .padding(.vertical, 5)
        // Held at the top over what scrolls under it: the page's own ground, out to the column's edges.
        .background(CDS.Surface.s1.padding(.horizontal, -gutter))
    }

    /// What a folded section holds, on its header line.
    @ViewBuilder private func preview(_ zone: RouterZone) -> some View {
        switch zone {
        case .needs: previewText((page.asks.map { _ in "Where to send it" } + (page.needs + page.ready).map(\.title)))
        case .notes: previewText(page.notes.map(\.title))
        case .waiting: previewText(page.waiting.map(\.title))
        case .working:
            // The section's own rows (a search's matches while one is on), as the other sections' lines and the chips count.
            MinuteTicking { now in
                let items = store.overviewItems(page.working, now: now)
                if let line = RouterOverviewLine.text(items) {
                    Text(line).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                        .help(RouterOverviewLine.tooltip(items))
                }
            }
        }
    }

    private func previewText(_ titles: [String]) -> some View {
        Text(titles.joined(separator: " · ")).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).truncationMode(.tail)
    }

    @ViewBuilder private func accessory(_ zone: RouterZone, folded: Bool) -> some View {
        switch zone {
        case .notes where !folded && !model.searching && page.notes.count > Self.notesShown:
            let all = showsAllNotes
            Button(all ? "Show fewer" : "Show all") {
                withAnimation(spring) { showAllNotes = !all }
            }
            .buttonStyle(.link).font(CDS.sans(12))
        case .working:
            let summarizer = model.summarizer
            SparklesButton(busy: !summarizer.batch.isEmpty, done: Set(page.working.map(\.id)).isSubset(of: summarizer.busy),
                           label: "Summarize what's running") { summarizer.requestAll(store: store) }
        default: EmptyView()
        }
    }

    // MARK: Sections

    @ViewBuilder private func content(_ zone: RouterZone) -> some View {
        switch zone {
        case .needs: needs
        case .notes: notes
        case .waiting: waitingList
        case .working: workingList
        }
    }

    private var workingList: some View {
        VStack(spacing: 0) {
            ForEach(Array(page.working.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Rectangle().fill(CDS.border.opacity(0.6)).frame(height: CDS.hairline) }
                WorkingCard(store: store, model: model, row: row, summary: page.summaries[row.id], unanswered: page.unanswered[row.id] ?? [])
                    .equatable()
                    .flightTarget("session:\(row.id)")
                    .id(RouterModel.workingID(row.id))
                    .matched(travellingWorking.contains(row.id) ? row.id : nil, in: ns)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity))
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CDS.alpha(0.03)))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CDS.border.opacity(0.7), lineWidth: 1) }
    }

    /// The sessions whose move is something else's (CI, a deploy, another session): cool and quiet.
    private var waitingList: some View {
        VStack(spacing: 0) {
            ForEach(Array(page.waiting.enumerated()), id: \.element.id) { i, card in
                if i > 0 { Rectangle().fill(CDS.border.opacity(0.6)).frame(height: CDS.hairline) }
                WaitingCard(store: store, card: card)
                    .equatable()
                    .flightTarget("session:\(card.sessionID)")
                    .id(RouterModel.workingID(card.sessionID))
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// One picked past the first few of Worth a look shows them all, so the keys never land on a card that isn't drawn; a
    /// search shows every match.
    private var showsAllNotes: Bool {
        if showAllNotes || model.searching { return true }
        // The pick read only when there are cards past the first few for it to be on: Now's column doesn't redraw for each
        // arrow key otherwise.
        guard page.notes.count > Self.notesShown else { return false }
        let picked = [model.selection, model.highlighted, model.expandedNeed].compactMap { $0 }
        return page.notes.dropFirst(Self.notesShown).contains { picked.contains($0.id) }
    }

    /// Finished turns with nothing to do but something to tell: quieter than Needs you, a line each, the first few shown.
    private var notes: some View {
        let open = model.expandedNeed
        let shown = showsAllNotes ? page.notes : Array(page.notes.prefix(Self.notesShown))
        return VStack(spacing: 6) {
            ForEach(shown) { card in
                CardView(store: store, model: model, card: card, expanded: card.id == open, form: nil,
                         project: store.routerProject(card), quiet: true)
                    .equatable()
                    .flightTarget("card:\(card.id)", radius: 12)
                    .id(card.id)
                    .transition(.asymmetric(insertion: .opacity, removal: .scaleFade(0.97, reduce: reduceMotion)))
            }
        }
        .padding(.vertical, 1)
    }

    private var needs: some View {
        let open = page.openNeed(preferred: model.expandedNeed)
        let wide = columnWidth >= 620
        // What an open form may take: enough of the page that the open card's own lines and its section's header stay in
        // view with it.
        let formCap = max(160, min(400, height - (wide ? 52 : 100) - 120))
        return VStack(spacing: 6) {
            ForEach(page.asks) { ask in
                AskBackCard(store: store, ask: ask)
                    .equatable()
                    .id(ask.id.uuidString)
                    .transition(.asymmetric(insertion: .scaleFade(0.97, reduce: reduceMotion).combined(with: .opacity),
                                            removal: .scaleFade(0.97, reduce: reduceMotion)))
            }
            ForEach(page.needs) { card in
                // Only the open card shows a form.
                CardView(store: store, model: model, card: card, expanded: card.id == open,
                         form: store.pendingForm(for: card), project: store.routerProject(card),
                         formCap: card.id == open ? formCap : CardView.closedFormCap)
                    .equatable()
                    .flightTarget("card:\(card.id)", radius: 12)
                    .id(card.id)
                    .matched(travelling.contains(card.sessionID) ? card.sessionID : nil, in: ns)
                    .transition(.asymmetric(insertion: .scaleFade(0.97, reduce: reduceMotion).combined(with: .opacity),
                                            removal: .scaleFade(0.97, reduce: reduceMotion)))
            }
            // A wait that is over, not told yet: yours to continue.
            ForEach(page.ready) { card in
                WaitingCard(store: store, card: card)
                    .equatable()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .id(card.id)
                    .transition(.opacity)
            }
        }
        // The cards' rings and shadows need a little room.
        .padding(.vertical, 1)
    }
}

/// A section's header line: its caret, its name and count, and folded, what it holds; a click folds or opens it.
private struct ZoneHeaderButton<Preview: View>: View {
    let zone: RouterZone
    let count: Int
    let folded: Bool
    @ViewBuilder let preview: () -> Preview
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovered ? CDS.Text.secondary : CDS.Text.muted)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .frame(width: 12)
                if zone == .needs {
                    Text(zone.title).cdsText((14, 20), .semibold, CDS.Fill.warning)
                    Text("\(count)")
                        .cdsText((12, 16), .semibold, Color.black.opacity(0.8)).monospacedDigit()
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(CDS.Fill.warning))
                } else {
                    Image(systemName: zone.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(zone.tint)
                    Text(zone.title).cdsText((12, 16), .medium, zone == .waiting ? zone.tint : CDS.Text.secondary)
                    Text("· \(count)").cdsText((12, 16), .regular, zone == .waiting ? zone.tint : CDS.Text.muted).monospacedDigit()
                }
                if folded { preview().padding(.leading, 4) }
                Spacer(minLength: 4)
            }
            .frame(minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(folded ? "Show \(zone.title)" : "Fold \(zone.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(zone.title), \(count)")
        .accessibilityValue(folded ? "Folded" : "Open")
        .accessibilityHint(folded ? "Opens it" : "Folds it")
        .accessibilityAddTraits(.isHeader)
    }
}

/// A sparkles icon button that makes summaries, the loader in its place while they are made.
struct SparklesButton: View {
    /// Its summaries are being made: the loader shows.
    let busy: Bool
    /// Nothing more to ask for (each of its summaries is under way): it can't be clicked.
    var done = false
    let label: String
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var help: String { busy ? "Summarizing…" : label }

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    FjordLoader(color: CDS.Text.secondary, label: help).frame(width: 11, height: 11)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hovered ? CDS.Text.secondary : CDS.Text.muted)
                }
            }
            .frame(width: 22, height: 20)
            .background(RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
                .fill(hovered && !done ? CDS.Fill.ghostHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .focused($focused)
        .onHover { hovered = $0 }
        .tip(help, focused: focused)
        .accessibilityLabel(help)
    }
}

/// What your last message to a working session left unanswered (`RouterCard.skipped`), under its row, until you answer it
/// or its turn ends.
struct UnansweredLine: View {
    let questions: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "questionmark.bubble").font(.system(size: 9, weight: .medium)).foregroundStyle(CDS.Fill.warning)
                .frame(width: 18)
            Text(Self.text(questions)).cdsText((12, 16), .regular, CDS.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 30)
        .accessibilityElement(children: .combine)
    }

    static func text(_ questions: [String]) -> String {
        (questions.count == 1 ? "1 question you didn't answer: " : "\(questions.count) questions you didn't answer: ")
            + questions.joined(separator: " · ")
    }
}

/// A session's newest summary, under its row: its whole text, wrapped, and how long ago it was made (its time on hover).
struct WorkingSummary: View {
    let summary: RouterSummary
    @Environment(\.canvasNodeID) private var canvasNode

    var body: some View {
        let at = summary.at
        let time = exactTime(at)
        // On a card of the canvas, the age follows the text: a column of its own reads as stray numbers there. The list's
        // rows keep theirs.
        let inline = canvasNode != nil
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 9, weight: .medium)).foregroundStyle(CDS.Text.muted)
                .frame(width: 18)
            if inline {
                MinuteTicking { now in
                    (Text(summary.text).foregroundStyle(CDS.Text.secondary)
                        + Text(" · " + shortAgo(at, now: now)).foregroundStyle(CDS.Text.muted).monospacedDigit())
                        .cdsText((12, 16), .regular, CDS.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(exactTime(at))
            } else {
                Text(summary.text).cdsText((12, 16), .regular, CDS.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MinuteTicking { now in
                    Text(shortAgo(at, now: now)).cdsText((12, 16), .regular, CDS.Text.muted).monospacedDigit().fixedSize()
                }
                .help(exactTime(at))
            }
        }
        // The age under the row's duration, past its two buttons.
        .padding(.trailing, inline ? 8 : 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Summary \(agoPhrase(at)), at \(time)")
        .accessibilityValue(summary.text)
    }
}

/// The working rows' durations tick on the second, every one on the same whole second: one wake-up a second for all of
/// them, rather than one per row at the moment it appeared.
private enum Seconds {
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)
}

private extension View {
    @ViewBuilder func matched(_ id: String?, in ns: Namespace.ID) -> some View {
        if let id { matchedGeometryEffect(id: id, in: ns, properties: .position) } else { self }
    }
}

// MARK: - Working card

/// A session working on its own: calm and small, one line. Its icon and title, what it is doing now (shimmering), its
/// folder, what it left running, and for how long, then Open in Claude (in its menu too). A click expands it in place: every
/// summary of it, newest first, and its subagents and commands with what each is on. Its sparkles button summarizes it,
/// expanding it to show the summary come in; folded, its newest summary sits under it.
struct WorkingCard: View, Equatable {
    let store: Store
    @Bindable var model: RouterModel
    let row: AgentRow
    let summary: RouterSummary?
    let unanswered: [String]
    /// On the canvas: a card of its own, in its own box, rather than a row of the Working list's.
    var standalone = false
    /// Whether it is expanded, when its place keeps it (the canvas, one node open at a time); else its own.
    var open: Binding<Bool>? = nil
    @State private var hovered = false
    @State private var ownExpanded = false
    @Environment(\.cdsColumnWidth) private var columnWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool {
        get { open?.wrappedValue ?? ownExpanded }
        nonmutating set { if let open { open.wrappedValue = newValue } else { ownExpanded = newValue } }
    }

    /// Drawn from its own values: another session's row changing doesn't redraw it (what it reads of the store and the
    /// model, it observes itself).
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.model === b.model && a.row == b.row && a.summary == b.summary && a.unanswered == b.unanswered && a.standalone == b.standalone && (a.open == nil) == (b.open == nil)
    }

    var body: some View {
        let summarizer = model.summarizer
        let busy = summarizer.busy.contains(row.id)
        let start = Store.workingStart(row)
        let current = row.session.running ? row.activity?.text ?? "Working" : (row.tasksText ?? "Working")
        let project = store.routerSessionProject(row.id)
        // The line composed from its task list and narration, when there is one; the raw step otherwise.
        let explained = store.liveExplanation(row)
        let doing = explained ?? current
        let marked = model.isMarked(RouterModel.workingID(row.id))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { withAnimation(Motion.spatial.resolved(reduce: reduceMotion)) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        SessionGlyph(row: row, size: 18, dot: false)
                        Text(row.session.title).cdsText((13, 18), .medium, CDS.Text.secondary).lineLimit(1).layoutPriority(2)
                        ShimmerText(text: doing, role: (12, 16)).truncationMode(.tail).layoutPriority(0)
                            .help(RouterLive.tooltip(title: row.session.title, activity: row.activity, tasks: row.tasks))
                        Spacer(minLength: 4)
                        // Its folder, as the cards that need you name it; narrower, it goes first, then what it left running.
                        if columnWidth >= 560 {
                            ProjectLabel(name: project.name, color: project.color, maxWidth: 240)
                                .cdsText((12, 16), .regular, CDS.Text.secondary).lineLimit(1).layoutPriority(1)
                        }
                        if !row.tasks.isEmpty, columnWidth >= 480 { running.fixedSize().layoutPriority(1) }
                        if let start {
                            TimelineView(.periodic(from: Seconds.epoch, by: 1)) { context in
                                Text(AgentRow.duration(context.date.timeIntervalSince(start)))
                                    .cdsText((12, 16), .regular, CDS.Text.muted).monospacedDigit().fixedSize()
                            }
                            .layoutPriority(1)
                        }
                        // In the row's button, so a click on it opens the session without folding the row.
                        HoverOpen(title: row.session.title, quiet: true) { store.openAgent(row.id) }.layoutPriority(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.session.title)
                .accessibilityValue("working, \(project.name), \(doing)\(row.tasks.isEmpty ? "" : ", \(row.tasksText ?? "")")")
                .accessibilityHint(expanded ? "Folds its details" : "Shows its summaries, subagents and commands")
                .accessibilityAddTraits(expanded ? .isSelected : [])
                .accessibilityAction(named: "Open in Claude") { store.openAgent(row.id) }
                .accessibilityAction(named: "Summarize") { summarize() }
                SparklesButton(busy: busy, done: busy, label: "Summarize this session") { summarize() }
            }
            .canvasHeader()
            if !unanswered.isEmpty { UnansweredLine(questions: unanswered) }
            SessionLinesView(store: store, sessionID: row.id).padding(.trailing, 8)
            if expanded { details } else if let summary { WorkingSummary(summary: summary) }
            if let error = summarizer.errors[row.id] {
                Text(error).cdsText((12, 16), .regular, CDS.Fill.warning).lineLimit(2).padding(.leading, 26)
            }
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if standalone {
                // The Working list's box, around this card alone.
                // Open, as a card in full is: its ground and its ring stronger.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(marked || expanded ? CDS.Fill.ghostSelected : hovered ? CDS.Fill.ghostHover : CDS.alpha(0.03))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(CDS.border.opacity(expanded ? 1 : 0.7), lineWidth: expanded ? 1.5 : 1)
                    }
            } else {
                marked ? CDS.Fill.ghostSelected : hovered ? CDS.Fill.ghostHover : .clear
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { SessionMenu(row: row, store: store) }
    }

    /// Asks for a summary, expanding it if folded so the new one comes in with the others.
    private func summarize() {
        if !expanded { withAnimation(Motion.spatial.resolved(reduce: reduceMotion)) { expanded = true } }
        model.summarizer.request(row.id, store: store)
    }

    /// Expanded: its summaries, newest first, then its subagents and commands.
    @ViewBuilder private var details: some View {
        let summaries = store.router.summaries.filter { $0.sessionID == row.id }.reversed()
        VStack(alignment: .leading, spacing: 8) {
            if summaries.isEmpty {
                Text("No summary yet: the sparkles button makes one.")
                    .cdsText((12, 16), .regular, CDS.Text.muted).padding(.leading, 26)
            } else {
                ForEach(Array(summaries)) { WorkingSummary(summary: $0) }
            }
            if !row.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.tasks) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: task.kind == .agent ? "person.crop.circle" : "terminal")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(CDS.Text.muted).frame(width: 18)
                            Text(task.title).cdsText((12, 16), .medium, CDS.Text.secondary).lineLimit(1).layoutPriority(1)
                            if let activity = task.activity {
                                Text(activity.text).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                            }
                            Spacer(minLength: 4)
                            TimelineView(.periodic(from: Seconds.epoch, by: 1)) { context in
                                Text(AgentRow.duration(context.date.timeIntervalSince(task.since)))
                                    .cdsText((12, 16), .regular, CDS.Text.muted).monospacedDigit().fixedSize()
                            }
                        }
                        .padding(.trailing, 60)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(task.kind == .agent ? "Subagent" : "Command") \(task.title)")
                        .accessibilityValue(task.activity?.text ?? "")
                    }
                }
            }
        }
        .transition(.opacity)
    }

    /// "2 agents · 1 command" with their names on hover.
    private var running: some View {
        let agents = row.tasks.filter { $0.kind == .agent }.count
        let commands = row.tasks.count - agents
        var parts: [String] = []
        if agents > 0 { parts.append(agents == 1 ? "1 agent" : "\(agents) agents") }
        if commands > 0 { parts.append(commands == 1 ? "1 command" : "\(commands) commands") }
        return Text(parts.joined(separator: " · "))
            .cdsText((11, 14), .regular, CDS.Text.muted)
            .padding(.horizontal, 6).frame(height: 16)
            .background(Capsule().fill(CDS.Fill.field))
            .runningTip(row.tasks)
    }
}

// MARK: - Waiting card

/// A session whose turn ended waiting on something (CI, a deploy, another session): with the working ones, in a cool
/// tint and an hourglass, saying what for. Once Fjord sees that done it says the session is ready to continue, and Tell
/// it sends the session so. Opening it, or the Claude button beside it, opens the session in Claude.
struct WaitingCard: View, Equatable {
    let store: Store
    let card: RouterCard
    /// On the canvas: a card of its own, its tint in a rounded box with no bar, rather than a row of a list.
    var standalone = false
    /// On the canvas, opened in place: a click shows its brief and text in full (Open in Claude stays beside it) rather
    /// than opening the session.
    var open: Binding<Bool>? = nil
    /// On the canvas, picked (the keys, a banner, Jev): its ring stronger.
    var marked = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (a: Self, b: Self) -> Bool { a.store === b.store && a.standalone == b.standalone && a.marked == b.marked
        && (a.open == nil) == (b.open == nil) && a.card == b.card }

    private var triage: RouterTriage { card.triage ?? RouterTriage() }
    private var expanded: Bool { open?.wrappedValue == true }

    private var line: String {
        if triage.told != nil { return "told it to continue" }
        if let ready = triage.ready {
            // On the canvas, at 420, what finished goes under it: the line keeps to what it is.
            return standalone ? "ready to continue" : "ready to continue · \(triage.waitingLabel) finished: \(ready.result)"
        }
        return "waiting for \(triage.waitingLabel)"
    }

    /// What finished, under the line on the canvas.
    private var finished: String? {
        guard standalone, triage.told == nil, let ready = triage.ready else { return nil }
        return "\(triage.waitingLabel) finished: \(ready.result)"
    }

    private var spoken: String {
        var text = line
        if let finished { text += ", " + finished }
        if let brief = card.brief { text += ". " + brief }
        return text
    }

    var body: some View {
        let tint = RouterTriage.waitingTint
        let ready = triage.ready != nil
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button {
                    if let open {
                        withAnimation(Motion.spatial.resolved(reduce: reduceMotion)) { open.wrappedValue.toggle() }
                    } else {
                        store.openAgent(card.sessionID)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if let row = store.sessionRow(card.sessionID) { SessionGlyph(row: row, size: 18, dot: false) }
                        Text(card.title).cdsText((13, 18), .medium, CDS.Text.secondary).lineLimit(1).layoutPriority(2)
                        Image(systemName: ready ? "checkmark.circle.fill" : "hourglass").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tint)
                        // On the canvas the line goes first: the title gives way, then the line itself in a narrow frame.
                        Text(line).cdsText((12, 16), ready ? .medium : .regular, tint).lineLimit(1).truncationMode(.tail)
                            .layoutPriority(standalone ? 3 : 0)
                        Spacer(minLength: 4)
                        MinuteTicking { now in
                            Text(shortAgo(card.createdAt, now: now)).cdsText((12, 16), .regular, CDS.Text.muted).monospacedDigit().fixedSize()
                                .help(exactTime(card.createdAt))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "" : card.text)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(card.title)
                .accessibilityValue(spoken)
                .accessibilityHint(open == nil ? "Opens it in Claude" : expanded ? "Folds it" : "Shows it in full")
                .accessibilityAddTraits(expanded ? .isSelected : [])
                .accessibilityAction(named: "Open in Claude") { store.openAgent(card.sessionID) }
                // Beside the line rather than in it, so the card's text isn't its tooltip too.
                HoverOpen(title: card.title, quiet: true) { store.openAgent(card.sessionID) }
                if ready, triage.told == nil, store.triageOn || triage.watch?.onCI != true, let message = RouterWaits.message(triage) {
                    ClaudeButton("Tell it", variant: .secondary, size: .sm, icon: "arrow.turn.down.right") { store.tellWaiting(card.id) }
                        .help("Sends it: \(message)")
                }
            }
            .canvasHeader()
            if let finished {
                Text(finished).cdsText((12, 16), .medium, tint).lineLimit(expanded ? nil : 1).truncationMode(.tail)
                    .padding(.leading, 26).padding(.trailing, 8)
                    .accessibilityHidden(true)
            }
            // What it waits on and what comes after, in your words' style (RouterBrief.swift).
            if let brief = card.brief {
                Text(RouterText.inline(brief)).cdsText((12, 16), .regular, CDS.Text.secondary)
                    .lineLimit(expanded ? nil : 2).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26).padding(.trailing, 8)
                    .accessibilityHidden(true)
            }
            SessionLinesView(store: store, sessionID: card.sessionID).padding(.trailing, 8)
            if expanded {
                CDSProse(text: card.text, color: CDS.Text.secondary, inset: false)
                    .padding(.leading, 26).padding(.trailing, 8).padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if standalone {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(ready ? 0.13 : hovered ? 0.09 : 0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint.opacity(marked || expanded ? 0.9 : ready ? 0.5 : 0.2), lineWidth: marked ? 1.5 : 1)
                    }
            } else {
                tint.opacity(ready ? 0.13 : hovered ? 0.09 : 0.06)
            }
        }
        .overlay(alignment: .leading) { if !standalone { Rectangle().fill(tint.opacity(ready ? 0.9 : 0.5)).frame(width: 2) } }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Archive") {
                store.act(.archive(card: card.id, title: UntrustedText.clean(card.title, limit: 60), project: UntrustedText.clean(store.routerProject(card).name, limit: 40)))
            }
            CardSessionMenu(store: store, sessionID: card.sessionID)
        }
    }
}

/// What Jev's triage says of a turn's work, in tiny chips: it claims a success it didn't check; its changes aren't pushed,
/// or a PR is open.
struct TriageChips: View {
    let triage: RouterTriage?

    var body: some View {
        if let triage {
            if triage.circles {
                chip("Going in circles", Theme.red, help: "Jev sees the same attempt failing again")
            }
            if triage.unverified {
                chip("unverified", CDS.Fill.warning, help: "It says it works without having checked (“should work”, untested)")
            }
            if let work = triage.workLabel {
                chip(work, CDS.Text.muted, help: "Its changes: \(work)")
            }
        }
    }

    private func chip(_ text: String, _ color: Color, help: String) -> some View {
        Text(text).cdsText((11, 14), .medium, color).lineLimit(1)
            .padding(.horizontal, 6).frame(height: 16)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
            .help(help)
    }

    /// What a card's header says to VoiceOver besides its kind and title: how many questions it asks (or are left), its
    /// chips, then whether it is shown in full.
    static func spoken(_ card: RouterCard, expanded: Bool) -> String {
        var parts: [String] = []
        let asked = card.asks?.count ?? 0
        if let left = card.left, let total = card.total {
            parts.append("\(left.count) of \(total) questions left")
        } else if asked > 1 {
            parts.append("\(asked) questions")
        }
        if let triage = card.triage {
            if triage.circles { parts.append("going in circles") }
            if triage.unverified { parts.append("unverified") }
            if let work = triage.workLabel { parts.append("changes \(work)") }
        }
        parts.append(expanded ? "expanded" : "collapsed")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Origin

/// "⚡ from <category> · <thing>": the session was started by an inbox action.
struct OriginTag: View {
    let origin: SessionOrigin

    var body: some View {
        Text(origin.label).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).truncationMode(.tail)
            .accessibilityLabel("Started by an action: \(origin.category), \(origin.thing)")
    }
}

// MARK: - Card

/// A card's project as it shows: its folder's name and colour (`Store.routerProject`).
typealias RouterProject = (name: String, color: Color?)

/// An open card in Needs you, warm and solid: a summary row (icon, title, kind, a line of what it asks, project, time) and,
/// for the one shown in full, its form or plan to answer in place, or its text and Archive. Clicking its header shows it
/// in full with the composer ready to reply to it; hovering it shows Open in Claude. (Addressed, it is a `HistoryCardLine`.)
struct CardView: View, Equatable {
    let store: Store
    @Bindable var model: RouterModel
    let card: RouterCard
    let expanded: Bool
    /// Its form or plan held by the hook, and its project, looked up by the zones: the card reads nothing store-wide
    /// itself (its session's glyph is a `CardLead` of its own), so another session's activity doesn't redraw it.
    let form: PendingForm?
    let project: RouterProject
    /// The tallest an open form or plan gets before it scrolls inside.
    var formCap: CGFloat = closedFormCap
    static let closedFormCap: CGFloat = 400
    /// Worth a look's: neutral instead of warm, no shadow.
    var quiet = false
    /// Its project named in its header; on the canvas the frame it is in names it.
    var showsProject = true
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cdsColumnWidth) private var columnWidth

    /// Drawn from its own values: the zones redrawing for another card (or a session's activity) skip it; what it reads of
    /// the model (the pick, the mark) it observes itself.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.model === b.model && a.card == b.card && a.expanded == b.expanded && a.form == b.form
            && a.project.name == b.project.name
            && a.project.color == b.project.color && a.formCap == b.formCap && a.quiet == b.quiet && a.showsProject == b.showsProject
    }

    /// Wide enough for an open card's summary on one line.
    private var wide: Bool { columnWidth >= 620 }
    /// Through the card's own mark: the pick moving elsewhere doesn't redraw it.
    private var marked: Bool { model.isMarked(card.id) }
    private var when: Date { card.createdAt }

    /// What the card asks, on one line: its brief, else the first question still open, else its text (parsed once per text).
    private var excerpt: AttributedString {
        if let brief = card.brief { return Self.inline(brief) }
        if let first = openAsks.first { return Self.inline(first.question) }
        let flat = card.text.split(whereSeparator: \.isNewline).map { $0.drop { "#-* ".contains($0) } }.joined(separator: " ")
        return Self.inline(flat)
    }

    private final class Parsed { let text: AttributedString; init(_ text: AttributedString) { self.text = text } }
    @MainActor private static let parsed: NSCache<NSString, Parsed> = { let c = NSCache<NSString, Parsed>(); c.countLimit = 200; return c }()

    static func inline(_ text: String) -> AttributedString {
        if let hit = parsed.object(forKey: text as NSString) { return hit.text }
        let out = RouterText.inline(text)
        parsed.setObject(Parsed(out), forKey: text as NSString)
        return out
    }

    /// What the turn's final message asks (`RouterCard.asks`) that your messages haven't answered.
    private var openAsks: [RouterAsk] {
        let all = card.asks ?? []
        guard let left = card.left else { return all }
        return all.filter { left.contains($0.question) }
    }

    var body: some View {
        open
            .onHover { hovered = $0 }
            .contextMenu { CardSessionMenu(store: store, sessionID: card.sessionID) }
    }

    /// The header: clicking it shows the card in full and arms the reply.
    private func header<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        Button {
            withAnimation(Motion.spatial.resolved(reduce: reduceMotion)) { model.tap(card.id, store: store) }
        } label: { label() }
            .buttonStyle(.plain)
            .focused($focused)
            .accessibilityLabel("\(card.kind.label): \(card.title)")
            .accessibilityValue(TriageChips.spoken(card, expanded: expanded))
            .accessibilityAddTraits(expanded ? .isSelected : [])
            .accessibilityHint("Shows it in full and replies to it")
            .accessibilityAction(named: "Open in Claude") { openInClaude() }
    }

    /// Always there on a card, beside Archive and alike: what you do with a card isn't hidden until you hover it.
    private var openButton: some View {
        ClaudeButton(icon: ClaudeMark.openSymbol, label: "Open in Claude", variant: .ghost, size: .sm) { openInClaude() }
    }

    private func openInClaude() { model.open(card.id, store: store) }

    /// What the session went on without: questions your last message left that its final message doesn't ask again.
    static func wentAhead(_ questions: [String]) -> String {
        (questions.count == 1 ? "Went ahead without your answer: " : "Went ahead without your answers: ") + questions.joined(separator: " · ")
    }

    // MARK: Open

    private var open: some View {
        let warm = quiet ? CDS.Text.secondary : card.kind == .approval ? RouterTriage.approvalTint : CDS.Fill.warning
        return VStack(alignment: .leading, spacing: 0) {
            header { summary(project: project) }
            if let left = card.left, let total = card.total {
                Text("\(left.count) of \(total) left").cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1)
                    .padding(.horizontal, 14).padding(.bottom, expanded ? 4 : 7).padding(.top, -3)
                    .padding(.leading, wide ? 28 : 0)
            }
            SessionLinesView(store: store, sessionID: card.sessionID)
                .padding(.horizontal, 14).padding(.bottom, expanded ? 4 : 7).padding(.top, -3)
                .padding(.leading, wide ? 28 : 0)
            let without = card.wentAheadWithout
            if !without.isEmpty {
                Text(Self.wentAhead(without)).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(expanded ? nil : 2)
                    .padding(.horizontal, 14).padding(.bottom, expanded ? 4 : 7).padding(.top, -3)
                    .padding(.leading, wide ? 28 : 0)
            }
            if let origin = card.origin, !quiet {
                OriginTag(origin: origin).padding(.horizontal, 14).padding(.bottom, expanded ? 4 : 7).padding(.top, -3)
                    .padding(.leading, wide ? 28 : 0)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    content(form: form)
                }
                .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 2)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.wash(warm, quiet ? (expanded ? 0.08 : hovered ? 0.07 : 0.04) : expanded ? 0.15 : hovered ? 0.13 : 0.09)))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(warm.opacity(quiet ? (marked || expanded || focused ? 0.45 : 0.2) : marked || expanded || focused ? 0.8 : 0.4),
                              lineWidth: marked ? 1.5 : 1)
        }
        // One shadow for the card as a whole: without the group each of its parts (every line of text, every icon) casts its
        // own, and the window's picture for the opening morph blurs every one of them again.
        .compositingGroup()
        .shadow(color: warm.opacity(expanded && !quiet ? 0.10 : 0), radius: 10, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.kind.label): \(card.title)")
        .accessibilityAction(named: "Archive") { model.address(card.id, store: store) }
    }

    /// Who, what kind, what it asks and when: one line when there is room, else two.
    private func summary(project: RouterProject) -> some View {
        let title = Text(card.title).cdsText(quiet ? (13, 18) : (14, 20), quiet ? .medium : .semibold, CDS.Text.primary).lineLimit(1)
        let age = CardAge(date: when).fixedSize()
        let ask = Text(excerpt).cdsText((13, 18), .regular, CDS.Text.secondary).lineLimit(1).truncationMode(.tail)
        // A form has its own buttons: Archive sits in the header beside it.
        return VStack(alignment: .leading, spacing: 1) {
            if wide {
                HStack(spacing: 8) {
                    lead
                    title.layoutPriority(2)
                    KindTag(kind: card.kind)
                    TriageChips(triage: card.triage)
                    if !expanded { ask.padding(.leading, 4).layoutPriority(0) }
                    Spacer(minLength: 4)
                    if showsProject { projectLabel(project) }
                    age
                    archiveButton
                    openButton
                }
                .canvasHeader()
            } else {
                if showsProject {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { lead; title; KindTag(kind: card.kind); TriageChips(triage: card.triage); Spacer(minLength: 4); projectLabel(project); age; archiveButton; openButton }
                        HStack(spacing: 8) { lead; title; KindTag(kind: card.kind); Spacer(minLength: 4); age; archiveButton; openButton }
                        HStack(spacing: 8) { lead; title; Spacer(minLength: 4); age; archiveButton; openButton }
                    }
                } else {
                    // No project to drop: a title too long for the line gives way, its kind, the chips and its age kept.
                    // A narrow canvas card: Jev's chips go first, then the kind's name (its icon kept); nothing draws past
                    // the card.
                    Group {
                        if columnWidth >= Self.chipsRoom {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { lead; title; KindTag(kind: card.kind); TriageChips(triage: card.triage); Spacer(minLength: 4); age; archiveButton; openButton }
                                // Too long for the line: the title gives way, its kind, Jev's chips and its age kept.
                                HStack(spacing: 8) {
                                    lead
                                    title.truncationMode(.tail).layoutPriority(0)
                                    KindTag(kind: card.kind).layoutPriority(1)
                                    TriageChips(triage: card.triage).fixedSize().layoutPriority(1)
                                    Spacer(minLength: 4)
                                    age.layoutPriority(1)
                                    archiveButton.layoutPriority(1)
                                    openButton.layoutPriority(1)
                                }
                            }
                        } else {
                            HStack(spacing: columnWidth >= Self.kindRoom ? 8 : 6) {
                                lead
                                title.truncationMode(.tail).layoutPriority(0)
                                if columnWidth >= Self.kindRoom { KindTag(kind: card.kind).layoutPriority(1) } else { KindGlyph(kind: card.kind).layoutPriority(1) }
                                Spacer(minLength: 2)
                                age.layoutPriority(1)
                                archiveButton.layoutPriority(1)
                                openButton.layoutPriority(1)
                            }
                        }
                    }
                    .clipped()
                    .canvasHeader()
                }
                // Under the title, past the glyph's room when it has one.
                if !expanded { HStack(spacing: 8) { CardLead(store: store, sessionID: card.sessionID, room: true); ask } }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, wide ? 6 : expanded ? 8 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The card widths (the canvas's narrow frames) under which Jev's chips, then the kind's name, give way.
    static let chipsRoom: CGFloat = 380
    static let kindRoom: CGFloat = 280

    /// Archive, on Needs you and Worth a look alike: in the header, always. The only way a card leaves the list from here.
    private var archiveButton: some View {
        ClaudeButton(icon: "archivebox", label: "Archive", variant: .ghost, size: .sm) {
            guard !Self.secondClick(NSApp.currentEvent) else { return }
            model.address(card.id, store: store)
        }
    }

    /// Whether `event` is the second click of a double-click (or a later one): Archive takes only the first. The card leaves
    /// as it is archived and the next one's Archive slides under the pointer, so the second click would archive a card you
    /// never saw. A press with no click (a key, VoiceOver) archives.
    static func secondClick(_ event: NSEvent?) -> Bool {
        guard let event, [.leftMouseDown, .leftMouseUp].contains(event.type) else { return false }
        return event.clickCount > 1
    }

    private var lead: some View { CardLead(store: store, sessionID: card.sessionID) }

    private func projectLabel(_ project: RouterProject) -> some View {
        ProjectLabel(name: project.name, color: project.color, maxWidth: 240)
            .cdsText((12, 16), .regular, CDS.Text.secondary).lineLimit(1).layoutPriority(1)
    }

    /// The card's full content: its brief over its form or plan (capped, scrolling inside), else over what it said.
    @ViewBuilder private func content(form: PendingForm?) -> some View {
        if let brief = card.brief {
            Text(RouterText.inline(brief)).cdsText((13, 18), .medium, CDS.Text.primary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        if let form {
            ScrollView {
                Group {
                    if form.isPlan { CodePlanCard(form: form, card: card.id, store: store, model: model) }
                    else { CodeFormCard(form: form, card: card.id, store: store, model: model) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: formCap)
            .fixedSize(horizontal: false, vertical: true)
        } else if !openAsks.isEmpty {
            // What it asks, each with the choices it offers; what the turn did under it.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(openAsks, id: \.question) { ask in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "questionmark.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(card.kind.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RouterText.inline(ask.question)).cdsText((13, 18), .regular, CDS.Text.primary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            ForEach(ask.options, id: \.self) { option in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "circle").font(.system(size: 6, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                                    Text(RouterText.inline(option)).cdsText((12, 16), .regular, CDS.Text.secondary)
                                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if card.text != RouterFeed.placeholder {
                    CDSProse(text: card.text, color: CDS.Text.secondary, inset: false).padding(.top, 2)
                }
            }
        } else {
            CDSProse(text: card.text, color: card.kind == .stuck ? CDS.Text.danger : CDS.Text.primary, inset: false)
        }
    }
}

/// A card's age, on the minute's clock: the card is drawn from its own values only (Equatable), so its age keeps time here,
/// and its time on hover.
private struct CardAge: View {
    let date: Date

    var body: some View {
        // The time on hover with it: a day old, it says its date rather than only its time.
        MinuteTicking { now in
            Text(shortAgo(date, now: now)).cdsText((12, 16), .regular, CDS.Text.secondary).monospacedDigit()
                .help(exactTime(date))
        }
    }
}

// MARK: - Ask-back card

/// "Where should this go?": a message the Router couldn't place with confidence. The top targets are buttons, "Something else…"
/// lists every session and project. Only a click answers it: whatever is typed in the composer meanwhile is a message of its
/// own, even one that reads like a target's name, so a session titled after what you'd say ("Don't deploy") is never picked
/// for saying it. Nothing is sent until you pick.
struct AskBackCard: View, Equatable {
    let store: Store
    let ask: RouterAskBack

    nonisolated static func == (a: Self, b: Self) -> Bool { a.store === b.store && a.ask == b.ask }

    var body: some View {
        let warm = CDS.Fill.warning
        let pickers = store.routerDispatcher.pickerOptions()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble").font(.system(size: 13, weight: .medium)).foregroundStyle(warm)
                Text(ask.context.part ? "Where should this part go?" : "Where should this go?").cdsText((14, 20), .semibold, CDS.Text.primary)
                Spacer(minLength: 4)
                CardAge(date: ask.at)
            }
            Text((ask.context.action.map { "\($0.origin.category) · " } ?? "") + "“\(RouterDecision.clip(ask.message, 160))”")
                .cdsText((13, 18), .regular, CDS.Text.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let note = ask.note {
                Text(note).cdsText((12, 16), .medium, CDS.Text.warning).fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 6) {
                // What can still be sent to: a card hidden since it was offered (its session's tasks running) has no button.
                let options = ask.options.filter { store.routerDispatcher.eligible($0.target, store: store) }
                let newest = ask.id == store.routerDispatcher.askBacks.last?.id
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    ClaudeButton(option.title + (option.detail.isEmpty ? "" : " · \(option.detail)"), variant: .secondary, size: .sm) {
                        if option.target == RouterAskBack.chooseFolder { chooseFolder() }
                        else { store.routerDispatcher.pick(ask.id, target: option.target) }
                    }
                    // RouterKeys: ⌘1–⌘4 on the newest ask.
                    .help(newest && index < RouterKeys.pickKeys.count ? "⌘\(index + 1)" : "")
                }
                // A message whose delivery is unconfirmed is only sent again as it was, or the session looked at.
                if !store.routerDispatcher.resendsOnly(ask.id) { Menu {
                    if !pickers.sessions.isEmpty {
                        Section("Send to a session") {
                            ForEach(pickers.sessions) { option in
                                Button("\(option.title) · \(option.detail)") { store.routerDispatcher.pick(ask.id, target: option.target) }
                            }
                        }
                    }
                    if !pickers.projects.isEmpty {
                        Section("Start a session in") {
                            ForEach(pickers.projects) { option in
                                Button(option.detail) { store.routerDispatcher.pick(ask.id, target: option.target) }
                            }
                        }
                    }
                } label: {
                    Text("Something else…").cdsText((13, 18), .medium, CDS.Text.secondary)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(CDS.Fill.field))
                        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CDS.border, lineWidth: 1) }
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize() }
                ClaudeButton("Dismiss", variant: .ghost, size: .sm) { store.routerDispatcher.dismiss(ask.id) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.wash(warm, 0.15)))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(warm.opacity(0.8), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where should this go? \(ask.message)")
    }

    /// "Choose folder…": a folder picked in the open panel gets a new session with the message.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start a session here"
        panel.message = ask.note.map { "\($0). Choose the folder a new session should work in." } ?? "Choose the folder a new session should work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.routerDispatcher.pick(ask.id, folder: url.path)
    }
}
