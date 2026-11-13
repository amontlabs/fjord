import SwiftUI

// The wide layouts' rows (RouterLab.swift, docs/design/router-v2/WIDE-OPTIONS.md), demo only. Two grammars:
// - Margin (options A and D): a thread's name hangs in a margin left of the reading column, right-aligned so it ends
//   beside its words; every row of the column is a mark, its words and the age right after them. A thread costs no row
//   of its own: its name stands beside its first row.
// - Classic (options B and C): the page's own line and block (the name's row, the items under it), the card under its row
//   or left to a pane.
// Neither draws a rail by a thread's own words. The rows are placed at once (no glides): these are looks to choose from.

extension Router {
    /// The margin grammar's measures. The content cell's left edge is where an open card's ground starts; the marks'
    /// column and the words' column are where a line's mark and name words are from its ground's edge, so a card's
    /// column, radios and grounds fall as on the page.
    enum Margin {
        /// From the cell's edge to the marks' column, and to the words'.
        static let mark: CGFloat = Line.nameLeading + Line.namePadX
        static let words: CGFloat = Card.leading
        /// The name's ground ends this far before the cell.
        static let nameGap: CGFloat = 3
        /// From the name's ground to the marks' column.
        static let lead: CGFloat = nameGap + mark
        /// A row's ground under the pointer starts this far before its mark.
        static let reach: CGFloat = 8
        /// Between two threads.
        static let threadGap: CGFloat = 6
        /// Between the project and the name, and the new dot and what follows it.
        static let metaGap: CGFloat = 7
    }
}

// MARK: - Margin grammar

/// A thread in the margin grammar: its name in the margin beside its first row; its own words (a run's summary, Done's
/// outcome, a line's sentence) as the first row when it has some, then a row per item. The selected row and its card
/// share the selected ground, in the column.
struct RouterLabMarginThread: View {
    let model: RouterModel
    let box: RouterLineBox
    let margin: CGFloat
    /// The project beside the name (the ledger's rail says it instead).
    var project = true

    private typealias M = Router.Margin
    private typealias I = Router.Items

    private enum Row: Identifiable {
        case own, item(RouterItem), sent(String), reading
        var id: String {
            switch self {
            case .own: "own"
            case .item(let item): item.id
            case .sent: "sent"
            case .reading: "reading"
            }
        }
    }

    var body: some View {
        let thread = box.head
        let open = box.selected
        let rows = rows(thread, open: open)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: M.nameGap) {
                    ZStack(alignment: .topTrailing) {
                        if index == 0 { RouterLabMarginName(model: model, thread: thread, project: project) }
                    }
                    .frame(width: margin, alignment: .trailing)
                    .frame(minHeight: I.rowHeight, alignment: .top)
                    cell(row, thread: thread, open: open)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(thread.name), \(thread.look.label)")
    }

    private func rows(_ thread: RouterThread, open: Bool) -> [Row] {
        guard thread.ledger.block else { return [.own] }
        var rows: [Row] = []
        if RouterBlockLayout.headerShown(thread, sentence: box.sentence, card: open && box.item == nil) { rows.append(.own) }
        rows += thread.ledger.items.map { .item($0) }
        switch thread.ledger.read {
        case .message(let words)?: rows.append(.sent(words))
        case .turn?: rows.append(.reading)
        case nil: break
        }
        return rows
    }

    /// A row in the column and, when it is the open one, its card under it on the selected ground.
    @ViewBuilder private func cell(_ row: Row, thread: RouterThread, open: Bool) -> some View {
        let id = thread.id
        switch row {
        case .own:
            let flags = model.flags(.row(id))
            let focused = open && (box.item == nil || !thread.ledger.block)
            VStack(alignment: .leading, spacing: 0) {
                RouterButton(model: model, hit: .row(id), action: { model.click(row: id) }) { _, _ in
                    own(thread)
                }
                .background { ground(focused: focused, hot: flags.hot, pressed: flags.pressed) }
                if focused { RouterLabCard(model: model, box: box) }
            }
            .background { selected(focused) }
        case .item(let item):
            let key = RouterModel.itemKey(id, item.id)
            let flags = model.flags(.row(key))
            let focused = open && box.item == item.id
            VStack(alignment: .leading, spacing: 0) {
                RouterButton(model: model, hit: .row(key), action: { model.click(item: item.id, of: id) }) { _, _ in
                    RouterLabItemWords(model: model, thread: id, item: item, hot: flags.hot && !focused)
                }
                .disabled(!item.live)
                .background { ground(focused: focused, hot: flags.hot, pressed: flags.pressed) }
                if focused { RouterLabCard(model: model, box: box) }
            }
            .background { selected(focused) }
        case .sent(let words):
            RouterItemSentRow(words: words).padding(.leading, M.mark - I.markLeading)
        case .reading:
            RouterItemPlaceholder().padding(.leading, M.mark - I.markLeading)
        }
    }

    private func ground(focused: Bool, hot: Bool, pressed: Bool) -> some View {
        RoundedRectangle(cornerRadius: Router.Line.radius, style: .continuous)
            .fill(focused ? .clear : pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear)
            .padding(.leading, M.mark - M.reach)
            .transaction { $0.animation = nil }
    }

    private func selected(_ focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Router.Line.selectedRadius, style: .continuous)
            .fill(focused ? Router.Surface.quiet : .clear)
    }

    /// The thread's own words: a line's sentence, or a block's (the run's newest summary after the working dots, Done's
    /// outcome after its check), its age right after them, then what it has running.
    private func own(_ thread: RouterThread) -> some View {
        let block = thread.ledger.block
        let s = box.sentence
        let words: Text = if block {
            Text(RouterBlockHeader.words(thread, sentence: s)).foregroundColor(thread.sentenceTint)
        } else if let sent = thread.sent, thread.state == .sent {
            Text("“\(sent.words)”").foregroundColor(CDS.Text.primary)
        } else {
            RouterSentenceText.text(RouterWords(s.text, prs: thread.prs, stateWord: s.stateWord),
                                    tint: s.phase == .reassessing ? CDS.Text.muted : thread.sentenceTint, mono: s.mono, attributed: false)
        }
        let empty = block && RouterBlockHeader.words(thread, sentence: s).isEmpty
        let reading = block ? thread.ledger.read != nil : s.phase == .reassessing
        return RouterLabWords(words: words, age: empty ? nil : RouterLabAge.text(model, thread.since)) {
            if block, thread.ledger.top != nil {
                // Its name has its most urgent item's colour: its own state is the mark by its own words.
                if thread.isRunning {
                    RouterWorkingDots(tint: CDS.Text.muted, paused: thread.paused)
                } else if !empty, let symbol = thread.look.symbol {
                    Image(systemName: symbol).font(.system(size: I.mark, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                }
            } else {
                RouterMark(look: thread.look, paused: thread.paused)
            }
        } trail: {
            if reading { RouterThinking().frame(height: I.lineHeight) }
            if !thread.activity.isEmpty {
                RouterActivityMark(model: model, thread: thread.id, activity: thread.activity)
                    .fixedSize().frame(height: I.lineHeight)
            }
        }
    }
}

/// A thread's name in the margin, right-aligned so it ends beside its words: on its colour's ground when it asks
/// something of you, plain otherwise, with no mark (the marks are the column's); before it its project, and the new dot.
struct RouterLabMarginName: View {
    let model: RouterModel
    let thread: RouterThread
    var project = true

    private typealias L = Router.Line

    var body: some View {
        let hot = model.flags(.row(thread.id)).hot || model.flags(.name(thread.id)).hot
        let tint: Color? = thread.ledger.top?.tint ?? (thread.look.ground ? thread.look.tint : nil)
        let shape = RoundedRectangle(cornerRadius: L.nameRadius, style: .continuous)
        HStack(alignment: .top, spacing: Router.Margin.metaGap) {
            if thread.isNew {
                Circle().fill(CDS.Fill.accent).frame(width: CDS.Dot.size, height: CDS.Dot.size)
                    .frame(height: Router.Items.lineHeight)
                    .accessibilityLabel("New")
            }
            if project, let name = thread.project, model.project == nil {
                RouterProjectPill(model: model, thread: thread.id, project: name)
                    .frame(height: Router.Items.lineHeight)
            }
            Button(action: { model.click(row: thread.id) }) {
                Text(thread.name).font(CDS.sans(14, tint == nil ? .regular : .medium))
                    .foregroundStyle(thread.naming ? CDS.Text.muted : tint ?? CDS.Text.primary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, L.namePadX).padding(.vertical, L.namePadY)
                    .background { shape.fill((tint ?? .clear).opacity(hot ? L.groundHover : L.ground)) }
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .routerTarget(model, .name(thread.id))
        }
        // The name's line on the row's.
        .padding(.top, (Router.Items.rowHeight - Router.Items.lineHeight) / 2 - L.namePadY)
    }
}

/// A row of the column: its mark, its words flowing with the age right after the last of them (they wrap under their
/// own start, the mark hung before them), then what trails them.
struct RouterLabWords<Mark: View, Trail: View>: View {
    let words: Text
    var age: Text?
    @ViewBuilder let mark: () -> Mark
    @ViewBuilder let trail: () -> Trail

    private typealias I = Router.Items

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack { mark() }
                .frame(width: Router.Line.markBox, height: I.lineHeight)
                .padding(.trailing, Router.Line.markGap)
            ((age.map { words + $0 }) ?? words).font(CDS.sans(14))
                .lineLimit(I.sentenceLines).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Router.Thinking.gap) { trail() }.padding(.leading, Router.Thinking.gap)
            Spacer(minLength: 0)
        }
        .padding(.leading, Router.Margin.mark).padding(.trailing, Router.Line.reach)
        .padding(.vertical, (I.rowHeight - I.lineHeight) / 2)
        .frame(minHeight: I.rowHeight)
        .contentShape(Rectangle())
    }
}

/// An age that hugs its words: two spaces that don't break, then "4m", so it wraps with the last word, never alone.
@MainActor enum RouterLabAge {
    static func text(_ model: RouterModel, _ since: Date) -> Text {
        _ = model.clock.minute
        return Text(verbatim: "\u{00A0}\u{00A0}" + BriefAge.short(model.now.timeIntervalSince(since)))
            .font(CDS.sans(12)).monospacedDigit().foregroundColor(CDS.Text.muted)
    }
}

/// An item's row in the margin grammar: its kind's mark, its sentence, its age after it; struck with how it closed.
/// Under the pointer the age gives way to a quiet Done in its place, right after the words (the row's own act: struck
/// "done by you", Revert in the toast; a request's is the thread's Settle, off while T3 holds it).
struct RouterLabItemWords: View {
    let model: RouterModel
    let thread: String
    let item: RouterItem
    let hot: Bool

    var body: some View {
        let hit = RouterHit.itemDone(RouterModel.itemKey(thread, item.id))
        let done = item.live && !item.preview && model.atLit == nil && (hot || model.flags(hit).hot)
        let held = item.request == nil ? nil : model.thread(thread).flatMap(model.holdReason)
        let words: Text = if case .closing(let how) = item.state {
            Text(item.sentence).foregroundColor(CDS.Text.muted).strikethrough(true, color: CDS.Text.muted)
                + Text(verbatim: "  ") + Text(how).font(CDS.sans(12)).foregroundColor(CDS.Text.secondary)
        } else {
            Text(item.sentence).foregroundColor(item.state == .checking ? CDS.Text.muted : CDS.Text.secondary)
        }
        RouterLabWords(words: words, age: item.closing || done ? nil : RouterLabAge.text(model, item.since)) {
            Image(systemName: item.kind.symbol).font(.system(size: Router.Items.mark, weight: .semibold))
                .foregroundStyle(item.kind.tint).opacity(item.closing ? 0.45 : 1)
        } trail: {
            if done, let held {
                Text(Router.Items.Copy.done).font(CDS.sans(12)).foregroundStyle(CDS.Text.muted).opacity(0.45)
                    .lineLimit(1).fixedSize()
                    .frame(height: Router.Items.lineHeight)
                    .help(held)
                    .accessibilityLabel("Done is off: \(held)")
            } else if done {
                RouterButton(model: model, hit: hit, removes: true, action: { model.itemDone(thread, item.id) }) { hot, pressed in
                    Text(Router.Items.Copy.done).font(CDS.sans(12)).foregroundStyle(hot ? CDS.Text.primary : CDS.Text.muted)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 6)
                        .frame(height: Router.Items.lineHeight)
                        .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous)
                            .fill(hot ? Router.Surface.chosen : .clear))
                        .opacity(pressed ? 0.7 : 1)
                }
                // Its word where the age was.
                .padding(.leading, -6)
                .accessibilityLabel("Mark done")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kind.word): \(item.sentence)")
    }
}

/// The open row's card, its words on the row's words' column (`Router.Card.leading` from the selected ground's edge).
struct RouterLabCard: View {
    let model: RouterModel
    let box: RouterLineBox

    var body: some View {
        RouterCard(model: model, box: box)
            .environment(\.routerCardLeading, Router.Card.leading)
            .environment(\.routerLive, true)
    }
}

// MARK: - Classic grammar

/// A thread as the page has it: a line, or a block's header and its items one a row. `cards`: the open card under its
/// row, on the selected ground; without (a pane shows it), the selected row alone has the ground.
struct RouterLabClassicThread: View {
    let model: RouterModel
    let box: RouterLineBox
    var cards = true

    private typealias L = Router.Line

    var body: some View {
        let thread = box.head
        let id = thread.id
        let open = box.selected
        let flags = model.flags(.row(id))
        VStack(alignment: .leading, spacing: 0) {
            if thread.ledger.block {
                let onHeader = open && box.item == nil
                VStack(alignment: .leading, spacing: 0) {
                    RouterButton(model: model, hit: .row(id), action: { model.click(row: id) }) { _, _ in
                        RouterBlockHeader(model: model, thread: thread, hot: flags.hot, sentence: box.sentence)
                    }
                    .background { rowGround(selected: onHeader, hot: flags.hot, pressed: flags.pressed) }
                    if cards, onHeader { RouterLabCard(model: model, box: box) }
                }
                .background { cardGround(cards && onHeader) }
                ForEach(thread.ledger.items) { item in
                    let key = RouterModel.itemKey(id, item.id)
                    let f = model.flags(.row(key))
                    let focused = open && box.item == item.id
                    VStack(alignment: .leading, spacing: 0) {
                        RouterButton(model: model, hit: .row(key), action: { model.click(item: item.id, of: id) }) { _, _ in
                            RouterItemRow(model: model, thread: id, item: item, selected: focused, hot: f.hot, pressed: f.pressed)
                        }
                        .disabled(!item.live)
                        if cards, focused {
                            RouterLabCard(model: model, box: box).padding(.leading, Router.Items.groundLeading)
                        }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: cards ? L.selectedRadius : L.radius, style: .continuous)
                            .fill(focused ? Router.Surface.quiet : .clear)
                            .padding(.leading, Router.Items.groundLeading)
                    }
                }
                switch thread.ledger.read {
                case .message(let words)?: RouterItemSentRow(words: words)
                case .turn?: RouterItemPlaceholder()
                case nil: EmptyView()
                }
                // A block's air.
                Color.clear.frame(height: 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    RouterButton(model: model, hit: .row(id), action: { model.click(row: id) }) { _, _ in
                        RouterLabLine(model: model, box: box, hot: flags.hot)
                    }
                    .background { rowGround(selected: open, hot: flags.hot, pressed: flags.pressed) }
                    if cards, open { RouterLabCard(model: model, box: box) }
                }
                .background { cardGround(cards && open) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(thread.name), \(thread.look.label)")
    }

    private func rowGround(selected: Bool, hot: Bool, pressed: Bool) -> some View {
        RoundedRectangle(cornerRadius: L.radius, style: .continuous)
            .fill(selected ? (cards ? .clear : Router.Surface.quiet) : pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear)
            .transaction { $0.animation = nil }
    }

    private func cardGround(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: L.selectedRadius, style: .continuous).fill(on ? Router.Surface.quiet : .clear)
    }
}

/// A line as the page draws it: the new dot, the name, the sentence flowing from after it and wrapping under it, the
/// activity glyphs, the project and the age.
struct RouterLabLine: View {
    let model: RouterModel
    let box: RouterLineBox
    let hot: Bool
    @State private var nameWidth: CGFloat = 0
    @State private var rowWidth: CGFloat = 0

    private typealias L = Router.Line

    var body: some View {
        let thread = box.head
        HStack(alignment: .routerFirstLine, spacing: 0) {
            Circle().fill(CDS.Fill.accent).opacity(thread.isNew ? 1 : 0)
                .frame(width: CDS.Dot.size, height: CDS.Dot.size)
                .padding(.leading, L.dotLeading).padding(.trailing, L.dotGap)
            ZStack(alignment: .topLeading) {
                RouterSentenceView(model: model, box: box, lead: nameWidth > 0 ? nameWidth + L.sentenceGap : 0)
                    .routerActivity(model, thread)
                    .padding(.top, L.namePadY)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RouterName(model: model, thread: thread, rowHot: hot)
                    .modifier(RouterWidthCap(cap: rowWidth > 0 ? rowWidth * L.nameShare : .infinity))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nameWidth = $0 }
            }
            .alignmentGuide(.routerFirstLine) { _ in L.namePadY + Router.Items.lineHeight / 2 }
            if let project = thread.project {
                RouterProjectPill(model: model, thread: thread.id, project: project)
                    .padding(.leading, L.pillGap)
                    .opacity(model.project == nil ? 1 : 0)
                    .layoutPriority(1)
            }
            RouterAge(model: model, since: thread.since)
                .padding(.leading, L.ageGap).padding(.trailing, L.reach)
                .layoutPriority(1)
        }
        .padding(.vertical, (L.minHeight - Router.Items.lineHeight - 2 * L.namePadY) / 2)
        .frame(minHeight: L.minHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }
}
