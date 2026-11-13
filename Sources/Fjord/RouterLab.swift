import SwiftUI

// Four ways to use a wide window, to choose from (docs/design/router-v2/WIDE-OPTIONS.md). Demo only: `FJORD_WIDE=a|b|c|d`
// (or a shot's model) draws the page with one of them when it has the room, on the same records, bar, dock, cards and
// peeks; without the room, and always without the switch, the page is its own (`RouterList`). None stretches the
// reading column, and none draws a rail by a thread's own words.
//
// - a, margin notes: the 720 column, each thread's name in a margin beside its first row, ages right after the words.
// - b, list and pane: the list as it is in a 600 column, the selected row's card in a pane beside it.
// - c, board: Needs you in the column, Done and Working in a slimmer column beside it.
// - d, ledger by project: a's rows grouped by project, the project in a rail, no section headers.

enum RouterLab {
    enum Option: String, CaseIterable {
        case a, b, c, d
    }

    /// `FJORD_WIDE`: the option every page of this run starts with.
    static let pinned: Option? = ProcessInfo.processInfo.environment["FJORD_WIDE"].flatMap { Option(rawValue: $0.lowercased()) }

    /// Where an option's columns are in a page.
    struct Frame: Equatable {
        /// Where the reading column's words start, from the page's left, and how wide it is.
        var start: CGFloat
        var column: CGFloat
        /// The names' margin left of the column (a, d), and the projects' rail left of that (d).
        var margin: CGFloat = 0
        var rail: CGFloat = 0
        /// The pane (b) or the second column (c), `gap` after the reading column.
        var side: CGFloat = 0
        var gap: CGFloat = 0

        /// Where the option's last column ends.
        var end: CGFloat { start + column + (side > 0 ? gap + side : 0) }
    }

    static let margin: ClosedRange<CGFloat> = 150...212
    static let rail: CGFloat = 92
    static let list: CGFloat = 600
    static let pane: ClosedRange<CGFloat> = 440...620
    static let board: ClosedRange<CGFloat> = 600...720
    static let boardSide: CGFloat = 340
    static let ledger: CGFloat = 680
    static let ledgerMargin: CGFloat = 172

    /// The option's columns in a page `page` wide; nil when it hasn't the room (the page is then its own).
    static func frame(_ option: Option, page: CGFloat) -> Frame? {
        let g = Router.gutter
        let lead = Router.Margin.lead
        switch option {
        case .a:
            // The column centred as the page's own is, pushed right only as far as the margin needs.
            let column = Router.column
            let room = page - 2 * g - column - lead
            guard room >= margin.lowerBound else { return nil }
            let m = min(room, margin.upperBound)
            return Frame(start: max((page - column) / 2, g + m + lead), column: column, margin: m)
        case .b:
            let gap: CGFloat = 40
            let room = page - 2 * g - list - gap
            guard room >= pane.lowerBound else { return nil }
            let side = min(room, pane.upperBound)
            return Frame(start: (page - list - gap - side) / 2, column: list, side: side, gap: gap)
        case .c:
            let gap: CGFloat = 48
            let room = page - 2 * g - gap - boardSide
            guard room >= board.lowerBound else { return nil }
            let column = min(room, board.upperBound)
            return Frame(start: (page - column - gap - boardSide) / 2, column: column, side: boardSide, gap: gap)
        case .d:
            let room = page - 2 * g - ledger - lead - rail
            guard room >= margin.lowerBound else { return nil }
            let m = min(room, ledgerMargin)
            return Frame(start: max((page - ledger) / 2, g + rail + m + lead), column: ledger, margin: m, rail: rail)
        }
    }
}

/// The page under the title line, in one of the wide layouts.
struct RouterLabPage: View {
    let model: RouterModel
    let option: RouterLab.Option
    let frame: RouterLab.Frame
    let page: CGFloat

    private typealias L = Router.Line
    private typealias M = Router.Margin

    var body: some View {
        if option == .b {
            // The list and its composer on the left; the selected row's card beside them, not under its row.
            let split = frame.start + frame.column + frame.gap / 2
            HStack(alignment: .top, spacing: 0) {
                scroll(width: split) { classic(cards: false).padding(.leading, frame.start - L.nameLeading) }
                    .frame(width: split)
                ZStack(alignment: .topLeading) {
                    if case .line(let id)? = model.selection, model.thread(id) != nil {
                        RouterLabPane(model: model, box: model.box(id)).id(id)
                    }
                }
                .frame(width: frame.side, alignment: .topLeading)
                .padding(.leading, frame.gap / 2)
                // Its line on the list's first line.
                .padding(.top, Router.Bar.control + 2 * Router.Bar.padY + Router.Header.firstTop + Router.Header.height)
                .padding(.bottom, Router.Dock.bottom)
                Spacer(minLength: 0)
            }
        } else {
            scroll(width: page) {
                switch option {
                case .a: margins
                case .c: board
                case .d: ledger
                case .b: EmptyView()
                }
            }
        }
    }

    // MARK: The page's shell: the bar over the rows, the dock under them

    private func scroll<Rows: View>(width: CGFloat, @ViewBuilder rows: () -> Rows) -> some View {
        // The bar runs over every column of the option but a pane; the composer keeps to the reading column.
        let barEnd = option == .c ? frame.end : frame.start + frame.column
        return ScrollView {
            rows()
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlayScrollers()
        }
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

    // MARK: a, margin notes

    private var margins: some View {
        let slots = model.layout
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                if case .line(let id) = slot.kind {
                    RouterLabMarginThread(model: model, box: model.box(id), margin: frame.margin)
                        .padding(.top, index > 0 && isLine(slots[index - 1]) ? M.threadGap : 0)
                } else {
                    // On the marks' column, as the bar's first word and the composer's edge.
                    other(slot, first: index == 0)
                        .padding(.leading, frame.margin + M.lead - L.nameLeading)
                }
            }
        }
        .frame(width: frame.margin + M.lead + frame.column + L.reach, alignment: .leading)
        .padding(.leading, frame.start - M.lead - frame.margin)
    }

    // MARK: b, the list (its pane is beside it); c's columns

    private func classic(cards: Bool, slots: [RouterSlot]? = nil, width: CGFloat? = nil) -> some View {
        let slots = slots ?? model.layout
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                if case .line(let id) = slot.kind {
                    RouterLabClassicThread(model: model, box: model.box(id), cards: cards)
                } else {
                    other(slot, first: index == 0)
                }
            }
        }
        .frame(width: L.nameLeading + (width ?? frame.column) + L.reach, alignment: .leading)
    }

    private var board: some View {
        // What asks something of you in the reading column; what is done or running in a slimmer one beside it.
        var main: [RouterSlot] = [], side: [RouterSlot] = []
        for slot in model.layout {
            switch slot.kind {
            case .header(let section, _): if section == .needsYou { main.append(slot) } else { side.append(slot) }
            case .line(let id): if model.thread(id)?.section == .needsYou { main.append(slot) } else { side.append(slot) }
            case .housekeeping: side.append(slot)
            case .sentence, .reading, .ghost: main.append(slot)
            }
        }
        return HStack(alignment: .top, spacing: frame.gap - L.reach - L.nameLeading) {
            classic(cards: true, slots: main)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(side.enumerated()), id: \.element.id) { index, slot in
                    if case .line(let id) = slot.kind {
                        RouterLabSideThread(model: model, box: model.box(id))
                    } else {
                        other(slot, first: index == 0)
                    }
                }
            }
            .frame(width: L.nameLeading + frame.side + L.reach, alignment: .leading)
        }
        .padding(.leading, frame.start - L.nameLeading)
    }

    // MARK: d, ledger by project

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

    private var ledger: some View {
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
                            RouterLabMarginThread(model: model, box: model.box(id), margin: frame.margin, project: false)
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

// MARK: - b's pane

/// The selected row and its card, beside the list: the line as the list has it (name, project, age), the thread's own
/// words, the open item's sentence, then the card, on the selected ground. As tall as what it says; past the page's
/// height it scrolls.
struct RouterLabPane: View {
    let model: RouterModel
    let box: RouterLineBox

    private typealias L = Router.Line
    private typealias I = Router.Items

    var body: some View {
        let thread = box.head
        let block = thread.ledger.block
        let item = block ? box.item.flatMap { focus in thread.ledger.items.first { $0.id == focus } } : nil
        let s = box.sentence
        let own = block ? RouterBlockHeader.words(thread, sentence: s) : s.text
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    name(thread)
                    Spacer(minLength: 12)
                    if let project = thread.project { RouterProjectBadge(project: project) }
                    RouterAge(model: model, since: thread.since).padding(.leading, L.ageGap)
                }
                .padding(.leading, L.nameLeading).padding(.trailing, L.reach)
                .frame(minHeight: L.minHeight)
                if !own.isEmpty {
                    let words = block
                        ? Text(own)
                        : RouterSentenceText.text(RouterWords(s.text, prs: thread.prs, stateWord: s.stateWord),
                                                  tint: item == nil ? CDS.Text.primary : CDS.Text.muted, mono: s.mono, attributed: false)
                    words.font(CDS.sans(14, item == nil ? .medium : .regular))
                        .foregroundStyle(item == nil ? CDS.Text.primary : CDS.Text.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Router.Card.leading).padding(.trailing, L.reach)
                        .padding(.bottom, 8)
                }
                if let item {
                    HStack(alignment: .top, spacing: L.markGap) {
                        Image(systemName: item.kind.symbol).font(.system(size: I.mark, weight: .semibold))
                            .foregroundStyle(item.kind.tint)
                            .frame(width: L.markBox, height: I.lineHeight)
                        Text(item.sentence).font(CDS.sans(14, .medium)).foregroundStyle(CDS.Text.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, Router.Margin.mark).padding(.trailing, L.reach)
                    .padding(.bottom, 8)
                }
                RouterLabCard(model: model, box: box)
            }
            .background(RoundedRectangle(cornerRadius: L.selectedRadius, style: .continuous).fill(Router.Surface.quiet))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(thread.name), open")
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

// MARK: - c's second column

/// A thread in the board's slimmer column: its name, project and age on a line, its own words under the name, wrapping;
/// its items one a row; its card under the row it is open on.
struct RouterLabSideThread: View {
    let model: RouterModel
    let box: RouterLineBox

    private typealias L = Router.Line
    private typealias I = Router.Items

    var body: some View {
        let thread = box.head
        let id = thread.id
        let open = box.selected
        let flags = model.flags(.row(id))
        let block = thread.ledger.block
        let onHeader = open && (box.item == nil || !block)
        let s = box.sentence
        let own = block ? RouterBlockHeader.words(thread, sentence: s) : s.text
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                RouterButton(model: model, hit: .row(id), action: { model.click(row: id) }) { _, _ in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Circle().fill(CDS.Fill.accent).opacity(thread.isNew ? 1 : 0)
                                .frame(width: CDS.Dot.size, height: CDS.Dot.size)
                                .padding(.leading, L.dotLeading).padding(.trailing, L.dotGap)
                            if block {
                                RouterBlockName(thread: thread, hot: flags.hot).routerTarget(model, .name(id))
                            } else {
                                RouterName(model: model, thread: thread, rowHot: flags.hot)
                            }
                            Spacer(minLength: 8)
                            if !thread.activity.isEmpty {
                                RouterActivityMark(model: model, thread: id, activity: thread.activity).fixedSize()
                            }
                            if let project = thread.project {
                                RouterProjectPill(model: model, thread: id, project: project)
                                    .padding(.leading, L.pillGap)
                                    .opacity(model.project == nil ? 1 : 0)
                            }
                            RouterAge(model: model, since: thread.since).padding(.leading, L.ageGap).padding(.trailing, L.reach)
                        }
                        .frame(height: I.rowHeight)
                        if !own.isEmpty {
                            let words = block
                                ? Text(own).foregroundColor(thread.sentenceTint)
                                : RouterSentenceText.text(RouterWords(s.text, prs: thread.prs, stateWord: s.stateWord),
                                                          tint: thread.sentenceTint, mono: s.mono, attributed: false)
                            words.font(CDS.sans(14))
                                .lineLimit(I.sentenceLines).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, Router.Card.leading).padding(.trailing, L.reach)
                        }
                    }
                    .padding(.top, 3).padding(.bottom, 7)
                    .contentShape(Rectangle())
                }
                .background {
                    RoundedRectangle(cornerRadius: L.radius, style: .continuous)
                        .fill(onHeader ? .clear : flags.pressed ? Router.Surface.pressed : flags.hot ? Router.Surface.hover : .clear)
                        .transaction { $0.animation = nil }
                }
                if onHeader { RouterLabCard(model: model, box: box) }
            }
            .background {
                RoundedRectangle(cornerRadius: L.selectedRadius, style: .continuous).fill(onHeader ? Router.Surface.quiet : .clear)
            }
            if block {
                ForEach(thread.ledger.items) { item in
                    let key = RouterModel.itemKey(id, item.id)
                    let f = model.flags(.row(key))
                    let focused = open && box.item == item.id
                    VStack(alignment: .leading, spacing: 0) {
                        RouterButton(model: model, hit: .row(key), action: { model.click(item: item.id, of: id) }) { _, _ in
                            RouterItemRow(model: model, thread: id, item: item, selected: focused, hot: f.hot, pressed: f.pressed)
                        }
                        .disabled(!item.live)
                        if focused { RouterLabCard(model: model, box: box).padding(.leading, I.groundLeading) }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: L.selectedRadius, style: .continuous)
                            .fill(focused ? Router.Surface.quiet : .clear)
                            .padding(.leading, I.groundLeading)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(thread.name), \(thread.look.label)")
    }
}
