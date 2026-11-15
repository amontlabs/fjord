import SwiftUI

// The Router page in a wide window (docs/design/router-v2/WIDE-OPTIONS.md, option E with D below it). By the page's width:
// - under `ledgerFrom`, the page's own: the 720 column grouped by state, a card under its row (`RouterList`);
// - the ledger: the threads grouped by project, the project in a rail, each name in a margin beside its first row, ages
//   right after the words, a card under its row;
// - from `paneFrom`, the ledger in a narrower column and the selected row's card in a pane beside it.
// None stretches the reading column.

enum RouterWide {
    enum Layout: Equatable {
        case ledger, pane
    }

    /// Where the layout's columns are in a page.
    struct Frame: Equatable {
        /// Where the reading column's words start, from the page's left, and how wide it is.
        var start: CGFloat
        var column: CGFloat
        /// The names' margin left of the column, and the projects' rail left of that.
        var margin: CGFloat
        var rail: CGFloat
        /// The pane, `gap` after the reading column.
        var side: CGFloat = 0
        var gap: CGFloat = 0

        /// Where the last column ends.
        var end: CGFloat { start + column + (side > 0 ? gap + side : 0) }
    }

    static let rail: CGFloat = 92
    /// The ledger alone: its names' margin (it takes what it has between the bounds) and its column.
    static let margin: ClosedRange<CGFloat> = 150...172
    static let ledger: CGFloat = 680
    /// With the pane: the ledger's margin and column, the gap, and the pane's bounds.
    static let paneMargin: CGFloat = 140
    static let paneLedger: CGFloat = 520
    static let paneGap: CGFloat = 40
    static let pane: ClosedRange<CGFloat> = 380...620

    /// The layout of a page `page` wide, and its columns: the pane when it has the room, else the ledger; nil for the
    /// page's own.
    static func frame(page: CGFloat) -> (layout: Layout, frame: Frame)? {
        if paneRoom(page) >= pane.lowerBound { return (.pane, paneFrame(page)) }
        guard ledgerLeft(page) >= margin.lowerBound else { return nil }
        return (.ledger, ledgerFrame(page))
    }

    /// `layout` at a page `page` wide, whether or not it has the room (cut at the page's right edge if it hasn't): the
    /// layout a live resize started in, kept until it ends (`RouterScreen`).
    static func frame(page: CGFloat, holding layout: Layout?) -> (layout: Layout, frame: Frame)? {
        switch layout {
        case nil: nil
        case .pane: (.pane, paneFrame(page))
        case .ledger: (.ledger, ledgerFrame(page))
        }
    }

    private static func paneRoom(_ page: CGFloat) -> CGFloat {
        page - 2 * Router.gutter - rail - paneMargin - Router.Margin.lead - paneLedger - paneGap
    }

    private static func ledgerLeft(_ page: CGFloat) -> CGFloat { page - 2 * Router.gutter - ledger - Router.Margin.lead - rail }

    private static func paneFrame(_ page: CGFloat) -> Frame {
        let side = min(max(paneRoom(page), pane.lowerBound), pane.upperBound)
        let total = rail + paneMargin + Router.Margin.lead + paneLedger + paneGap + side
        return Frame(start: max((page - total) / 2, Router.gutter) + rail + paneMargin + Router.Margin.lead, column: paneLedger,
                     margin: paneMargin, rail: rail, side: side, gap: paneGap)
    }

    private static func ledgerFrame(_ page: CGFloat) -> Frame {
        let m = min(max(ledgerLeft(page), margin.lowerBound), margin.upperBound)
        return Frame(start: max((page - ledger) / 2, Router.gutter + rail + m + Router.Margin.lead), column: ledger, margin: m,
                     rail: rail)
    }

    /// The page width from which the ledger, and the pane, are drawn.
    static var ledgerFrom: CGFloat { 2 * Router.gutter + rail + margin.lowerBound + Router.Margin.lead + ledger }
    static var paneFrom: CGFloat {
        2 * Router.gutter + rail + paneMargin + Router.Margin.lead + paneLedger + paneGap + pane.lowerBound
    }
}

/// The selected row's card beside the ledger, level with its first row (the pane, `RouterList`).
struct RouterWideSide: View {
    let model: RouterModel
    let frame: RouterWide.Frame

    var body: some View {
        // Show me's panel, open, at the pane's bottom: level with the composer, the card above it.
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if case .line(let id)? = model.selection, model.thread(id) != nil {
                    RouterWidePane(model: model, box: model.box(id)).id(id)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            if let showMe = model.showMe, showMe.open, showMe.size == .panel {
                RouterShowMePanel(model: model, state: showMe, width: frame.side, docked: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(width: frame.side, alignment: .topLeading)
        .padding(.leading, frame.gap / 2)
        .padding(.top, Router.Bar.control + 2 * Router.Bar.padY + Router.Header.firstTop)
        .padding(.bottom, Router.Dock.bottom)
    }
}

/// The project, once, beside its first thread in the ledger: its name (a click filters to it) and, with more than one
/// thread, what it has in each state.
struct RouterRail: View {
    let model: RouterModel
    let project: String
    let lines: Int
    let tally: [RouterSection: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if project.isEmpty {
                Text("no project").font(CDS.sans(12)).foregroundStyle(CDS.Text.disabled)
                    .frame(height: Router.Items.rowHeight)
            } else {
                RouterButton(model: model, hit: .pill("rail:" + project), action: { model.toggle(project: project) }) { hot, _ in
                    Text(project).font(CDS.sans(12, .semibold)).foregroundStyle(hot ? CDS.Text.primary : CDS.Text.secondary)
                        .lineLimit(1)
                        .frame(height: Router.Items.rowHeight)
                }
                .routerLink()
                .accessibilityLabel("Project \(project)")
            }
            if lines > 1 {
                HStack(spacing: 8) {
                    ForEach(RouterSection.allCases, id: \.self) { section in
                        if let n = tally[section] {
                            HStack(spacing: 3) {
                                Image(systemName: section.symbol).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(section.tint)
                                Text(verbatim: "\(n)").font(CDS.sans(11)).monospacedDigit().foregroundStyle(CDS.Text.muted)
                            }
                            .accessibilityLabel("\(section.title), \(n)")
                        }
                    }
                }
                .frame(height: 14)
            }
        }
    }
}

// MARK: - The pane

/// How tall a card's history shows (`RouterTimeline`), for the pane that fits it to the room it has left.
struct RouterTimelineShown: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension EnvironmentValues {
    /// A wide page's pane holds Show me's open panel, so the dock doesn't float it.
    @Entry var routerPaneHoldsShowMe = false
    /// The history's height on a card that shares the room (nil: `Router.Work.timelineHeight`).
    @Entry var routerTimelineCap: CGFloat? = nil
    /// The thread's own acts (Snooze, Settle, Stop) on its card; off over an open item, where Open in T3 alone stays.
    @Entry var routerThreadActs = true
}

/// The selected row and its card, beside the list. A thread (or a block's header): the line as the list has it (name,
/// project, age), the thread's own words, then the card, on the selected ground. A block's item: the thread's card the
/// same way but with no ground and no footer (Open in T3 an icon in its name row), then the item (its mark and sentence,
/// then its card) on the selected ground under it. The thread's history takes the room the pane has left over the whole
/// item, so the item is never pushed off. As tall as what it says; past the page's height it scrolls.
struct RouterWidePane: View {
    let model: RouterModel
    let box: RouterLineBox

    /// The pane's height, the item's part, the thread's part and its history as shown: the room the history has left.
    @State private var paneHeight: CGFloat = 0
    @State private var itemHeight: CGFloat = 0
    @State private var threadHeight: CGFloat = 0
    @State private var historyShown: CGFloat = 0
    /// The history's height as you last dragged it (its grip, under the thread's card), kept across launches.
    @AppStorage("router.wideHistoryHeight") private var historyChosen: Double = Double(Self.historyDefault)
    /// The chosen height when the drag started; nil while not dragging.
    @State private var dragFrom: CGFloat?
    @State private var gripHot = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias L = Router.Line
    private typealias I = Router.Items

    /// The thread card's history over an open item, at its shortest: two rows (19 tall, 3 apart).
    static let historyFloor: CGFloat = 2 * 19 + 3
    /// …and as tall as it starts, until you drag its grip.
    static let historyDefault: CGFloat = 420
    /// Between the thread's card and the item's ground.
    static let itemGap: CGFloat = 12

    /// The room the pane has left for the history over the whole item's card, never under `historyFloor`.
    private var historyRoom: CGFloat? {
        guard paneHeight > 0, itemHeight > 0 else { return nil }
        let room = paneHeight - Self.itemGap - itemHeight - (threadHeight - historyShown)
        return max(Self.historyFloor, room.rounded(.down))
    }

    /// The thread card's history over an open item: the height you chose with its grip, within the room the pane has
    /// left (so the item is never pushed off). Not measured yet: its usual height.
    private var historyCap: CGFloat {
        guard let room = historyRoom else { return Router.Work.timelineHeight }
        return min(room, max(Self.historyFloor, CGFloat(historyChosen)))
    }

    var body: some View {
        let thread = box.head
        let block = thread.ledger.block
        let item = block ? box.item.flatMap { focus in thread.ledger.items.first { $0.id == focus } } : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let item {
                    VStack(alignment: .leading, spacing: 0) {
                        head(thread, opener: true)
                        RouterSummaryView(model: model, thread: thread, item: nil, layer: .card(box))
                            .environment(\.routerCardLeading, Router.Card.leading)
                            .environment(\.routerLive, true)
                            .environment(\.routerTimelineCap, historyCap)
                            .environment(\.routerThreadActs, false)
                    }
                    .onPreferenceChange(RouterTimelineShown.self) { historyShown = $0 }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { threadHeight = $0 }
                    grip
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: L.markGap) {
                            Image(systemName: item.kind.symbol).font(.system(size: I.mark, weight: .semibold))
                                .foregroundStyle(item.kind.tint)
                                .frame(width: L.markBox, height: I.lineHeight)
                            trailed(Text(item.sentence), RouterQuoteMark.onSentence(model, box, item: item))
                                .font(CDS.sans(14)).foregroundStyle(CDS.Text.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, Router.Margin.mark).padding(.trailing, L.reach)
                        .padding(.top, 8).padding(.bottom, 8)
                        RouterWideCard(model: model, box: box)
                    }
                    .background(RoundedRectangle(cornerRadius: L.selectedRadius, style: .continuous).fill(Router.Surface.quiet))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { itemHeight = $0 }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        head(thread)
                        RouterWideCard(model: model, box: box)
                    }
                    .background(RoundedRectangle(cornerRadius: L.selectedRadius, style: .continuous).fill(Router.Surface.quiet))
                }
            }
        }
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(thread.name), open")
    }

    /// The history's grip: the gap between the thread's card and the item, a short bar under the pointer. Dragging it
    /// sets how tall the history shows (kept across launches); a double click puts it back to `historyDefault`.
    private var grip: some View {
        Capsule()
            .fill(CDS.Text.muted)
            .frame(width: 36, height: 4)
            .opacity(gripHot || dragFrom != nil ? 0.6 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: Self.itemGap)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != gripHot else { return }
                gripHot = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .onDisappear { if gripHot { NSCursor.pop(); gripHot = false } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = dragFrom ?? historyCap
                        if dragFrom == nil { dragFrom = from }
                        let top = historyRoom ?? .greatestFiniteMagnitude
                        historyChosen = Double(min(top, max(Self.historyFloor, (from + drag.translation.height).rounded())))
                    }
                    .onEnded { _ in dragFrom = nil }
            )
            .onTapGesture(count: 2) { historyChosen = Double(Self.historyDefault) }
            .animation(Motion.hover(on: gripHot).resolved(reduce: reduceMotion), value: gripHot)
            .accessibilityElement()
            .accessibilityLabel("History height")
            .accessibilityValue("\(Int(historyCap)) points")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 40 : -40
                historyChosen = Double(min(historyRoom ?? .greatestFiniteMagnitude, max(Self.historyFloor, historyCap + step)))
            }
    }

    /// The thread's line as the list has it, then its own words in the primary ink.
    /// `opener`: over an open item, where the thread's card has no footer, Open in T3 as an icon before the project.
    @ViewBuilder private func head(_ thread: RouterThread, opener: Bool = false) -> some View {
        let block = thread.ledger.block
        let s = box.sentence
        let own = block ? RouterBlockHeader.words(thread, sentence: s) : s.text
        HStack(spacing: 0) {
            name(thread)
            Spacer(minLength: 12)
            if opener, thread.live { openIcon(thread).padding(.trailing, 6) }
            if let project = thread.project { RouterProjectBadge(project: project) }
            RouterAge(model: model, since: thread.since).padding(.leading, L.ageGap)
        }
        .padding(.leading, L.nameLeading).padding(.trailing, L.reach)
        .frame(minHeight: L.minHeight)
        if !own.isEmpty {
            let words = block
                ? Text(own)
                : RouterSentenceText.text(RouterWords(s.text, prs: thread.prs, stateWord: s.stateWord),
                                          tint: CDS.Text.primary, mono: s.mono, attributed: false)
            trailed(words, RouterQuoteMark.onSentence(model, box, item: nil))
                .font(CDS.sans(14)).foregroundStyle(CDS.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Router.Card.leading).padding(.trailing, L.reach)
                .padding(.bottom, 8)
        }
    }

    /// Words with the card's quote mark after them, when the card has no detail for it to follow.
    @ViewBuilder private func trailed(_ words: Text, _ quote: RouterQuoteMarkSpec?) -> some View {
        if let quote {
            RouterQuoteTrail(model: quote.model, hit: quote.hit, thread: quote.thread, words: words)
        } else {
            words
        }
    }

    /// Open in T3 as a quiet icon: the footer's act, where the thread's card has no footer.
    private func openIcon(_ thread: RouterThread) -> some View {
        RouterButton(model: model, hit: .footer(thread.id, .open), action: { model.open(thread.id) }) { hot, pressed in
            Image(systemName: "arrow.up.right.square").font(.system(size: 12, weight: .regular))
                .foregroundStyle(hot ? CDS.Text.primary : CDS.Text.muted)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous)
                    .fill(pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear))
        }
        .help("Open in T3 ⌘O")
        .accessibilityLabel("Open in T3")
    }

    /// The name as its line has it: its mark and its colour's ground.
    @ViewBuilder private func name(_ thread: RouterThread) -> some View {
        if thread.ledger.block {
            RouterBlockName(thread: thread, hot: false)
        } else {
            let look = thread.look
            HStack(spacing: L.markGap) {
                RouterMark(look: look, paused: thread.paused)
                Text(thread.name).font(CDS.sans(14, look.ground ? .medium : .regular))
                    .foregroundStyle(look.ground ? look.tint : CDS.Text.primary).lineLimit(1)
            }
            .padding(.horizontal, L.namePadX).padding(.vertical, L.namePadY)
            .background(RoundedRectangle(cornerRadius: L.nameRadius, style: .continuous).fill(look.tint.opacity(look.ground ? L.ground : 0)))
        }
    }
}
