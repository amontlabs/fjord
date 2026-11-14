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
        let g = Router.gutter
        let lead = Router.Margin.lead
        let room = page - 2 * g - rail - paneMargin - lead - paneLedger - paneGap
        if room >= pane.lowerBound {
            let side = min(room, pane.upperBound)
            let total = rail + paneMargin + lead + paneLedger + paneGap + side
            return (.pane, Frame(start: max((page - total) / 2, g) + rail + paneMargin + lead, column: paneLedger,
                                 margin: paneMargin, rail: rail, side: side, gap: paneGap))
        }
        let left = page - 2 * g - ledger - lead - rail
        guard left >= margin.lowerBound else { return nil }
        let m = min(left, margin.upperBound)
        return (.ledger, Frame(start: max((page - ledger) / 2, g + rail + m + lead), column: ledger, margin: m, rail: rail))
    }

    /// The page width from which the ledger, and the pane, are drawn.
    static var ledgerFrom: CGFloat { 2 * Router.gutter + rail + margin.lowerBound + Router.Margin.lead + ledger }
    static var paneFrom: CGFloat {
        2 * Router.gutter + rail + paneMargin + Router.Margin.lead + paneLedger + paneGap + pane.lowerBound
    }
}

/// The page under the title line, in one of the wide layouts.
struct RouterWidePage: View {
    let model: RouterModel
    let layout: RouterWide.Layout
    let frame: RouterWide.Frame
    let page: CGFloat

    private typealias L = Router.Line
    private typealias M = Router.Margin

    var body: some View {
        if layout == .pane {
            // The ledger and its composer on the left; the selected row's card beside them, level with the first row.
            let split = frame.start + frame.column + frame.gap / 2
            HStack(alignment: .top, spacing: 0) {
                scroll(width: split) { ledger(cards: false) }
                    .frame(width: split)
                ZStack(alignment: .topLeading) {
                    if case .line(let id)? = model.selection, model.thread(id) != nil {
                        RouterWidePane(model: model, box: model.box(id)).id(id)
                    }
                }
                .frame(width: frame.side, alignment: .topLeading)
                .padding(.leading, frame.gap / 2)
                .padding(.top, Router.Bar.control + 2 * Router.Bar.padY + Router.Header.firstTop)
                .padding(.bottom, Router.Dock.bottom)
                Spacer(minLength: 0)
            }
        } else {
            scroll(width: page) { ledger(cards: true) }
        }
    }

    // MARK: The page's shell: the bar over the rows, the dock under them

    private func scroll<Rows: View>(width: CGFloat, @ViewBuilder rows: () -> Rows) -> some View {
        // The bar runs over the reading column, not the pane; so does the composer.
        let barEnd = frame.start + frame.column
        return ScrollView {
            rows()
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlayScrollers()
        }
        .trackUnderBar(model)
        .safeAreaInset(edge: .top, spacing: 0) {
            ZStack {
                if model.hasThreads {
                    RouterHostedBar(model: model)
                        .padding(.leading, frame.start - CDS.Tabs.pad).padding(.trailing, width - barEnd - CDS.Tabs.pad)
                        .transition(.opacity)
                }
            }
            .frame(height: Router.Bar.control + 2 * Router.Bar.padY)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Color.clear.frame(height: Router.Bar.fade).allowsHitTesting(false)
                RouterDock(model: model)
                    .padding(.leading, frame.start).padding(.trailing, width - frame.start - frame.column)
                    .padding(.bottom, Router.Dock.bottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [CDS.Surface.s1.opacity(0), CDS.Surface.s1], startPoint: .top, endPoint: .bottom)
                                .frame(height: Router.Bar.fade)
                            CDS.Surface.s1
                        }
                        .padding(.top, -Router.Bar.fade)
                        .allowsHitTesting(false)
                    }
            }
        }
    }

    /// A row that isn't a thread: a section's header, the sentence in its place, the housekeeping line.
    @ViewBuilder private func other(_ slot: RouterSlot, first: Bool) -> some View {
        switch slot.kind {
        case .header(let section, let count): RouterHeaderRow(model: model, section: section, count: count, first: first)
        case .sentence(let words, let clear): RouterSentenceRow(model: model, words: words, clear: clear)
        case .reading(let count): RouterReadingRow(count: count, first: first)
        case .housekeeping(let count): RouterHousekeepingRow(model: model, count: count)
        case .line, .ghost: EmptyView()
        }
    }

    private func isLine(_ slot: RouterSlot?) -> Bool {
        if case .line? = slot?.kind { true } else { false }
    }

    // MARK: The ledger by project


    private struct Group: Identifiable {
        var id: String
        var lines: [String] = []
        var tally: [RouterSection: Int] = [:]
    }

    /// The page's threads by project, in the page's order: the project of the most pressing thread first, a thread with
    /// no project last.
    private var groups: [Group] {
        var groups: [Group] = []
        for slot in model.layout {
            guard case .line(let id) = slot.kind, let thread = model.thread(id) else { continue }
            let project = thread.project ?? ""
            let at = groups.firstIndex { $0.id == project } ?? {
                groups.append(Group(id: project))
                return groups.count - 1
            }()
            groups[at].lines.append(id)
            groups[at].tally[thread.section, default: 0] += 1
        }
        return groups.filter { !$0.id.isEmpty } + groups.filter { $0.id.isEmpty }
    }

    private func ledger(cards: Bool) -> some View {
        let slots = model.layout.filter { !isLine($0) }
        return VStack(alignment: .leading, spacing: 0) {
            // With no thread: the sentence that says so.
            ForEach(slots) { slot in
                if case .sentence = slot.kind { other(slot, first: true).padding(.leading, lead) }
                if case .reading = slot.kind { other(slot, first: true).padding(.leading, lead) }
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                HStack(alignment: .top, spacing: 0) {
                    rail(group).frame(width: frame.rail, alignment: .leading)
                    VStack(alignment: .leading, spacing: M.threadGap) {
                        ForEach(group.lines, id: \.self) { id in
                            RouterWideMarginThread(model: model, box: model.box(id), margin: frame.margin, project: false, cards: cards)
                        }
                    }
                }
                .padding(.top, index == 0 ? Router.Header.firstTop : 18)
            }
            ForEach(slots) { slot in
                if case .housekeeping = slot.kind { other(slot, first: false).padding(.leading, lead) }
            }
        }
        .frame(width: frame.rail + frame.margin + M.lead + frame.column + L.reach, alignment: .leading)
        .padding(.leading, frame.start - M.lead - frame.margin - frame.rail)
    }

    /// A page row's own leading in the ledger: its words on the marks' column.
    private var lead: CGFloat { frame.rail + frame.margin + M.lead - L.nameLeading }

    /// The project, once, beside its first thread: its name (a click filters to it) and, with more than one thread, what
    /// it has in each state.
    private func rail(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if group.id.isEmpty {
                Text("no project").font(CDS.sans(12)).foregroundStyle(CDS.Text.disabled)
                    .frame(height: Router.Items.rowHeight)
            } else {
                RouterButton(model: model, hit: .pill("rail:" + group.id), action: { model.toggle(project: group.id) }) { hot, _ in
                    Text(group.id).font(CDS.sans(12, .semibold)).foregroundStyle(hot ? CDS.Text.primary : CDS.Text.secondary)
                        .lineLimit(1)
                        .frame(height: Router.Items.rowHeight)
                }
                .routerLink()
                .accessibilityLabel("Project \(group.id)")
            }
            if group.lines.count > 1 {
                HStack(spacing: 8) {
                    ForEach(RouterSection.allCases, id: \.self) { section in
                        if let n = group.tally[section] {
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

extension EnvironmentValues {
    /// The history's height on a card that shares the room (nil: `Router.Work.timelineHeight`).
    @Entry var routerTimelineCap: CGFloat? = nil
    /// The thread's own acts (Snooze, Settle, Stop) on its card; off over an open item, where Open in T3 alone stays.
    @Entry var routerThreadActs = true
}

/// The selected row and its card, beside the list. A thread (or a block's header): the line as the list has it (name,
/// project, age), the thread's own words, then the card, on the selected ground. A block's item: the thread's card the
/// same way but with no ground, its history shorter and no footer (Open in T3 an icon in its name row), then the item (its mark and
/// sentence, then its card) on the selected ground under it. As tall as what it says; past the page's height it scrolls.
struct RouterWidePane: View {
    let model: RouterModel
    let box: RouterLineBox

    private typealias L = Router.Line
    private typealias I = Router.Items

    /// The thread card's history over an open item: about four rows (19 tall, 3 apart).
    static let itemTimelineCap: CGFloat = 4 * 19 + 3 * 3
    /// Between the thread's card and the item's ground.
    static let itemGap: CGFloat = 12

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
                            .environment(\.routerTimelineCap, Self.itemTimelineCap)
                            .environment(\.routerThreadActs, false)
                    }
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
                    .padding(.top, Self.itemGap)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        head(thread)
                        RouterWideCard(model: model, box: box)
                    }
                    .background(RoundedRectangle(cornerRadius: L.selectedRadius, style: .continuous).fill(Router.Surface.quiet))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(thread.name), open")
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
