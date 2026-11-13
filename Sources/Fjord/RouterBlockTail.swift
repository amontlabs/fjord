import AppKit
import SwiftUI

// A block's rows under its open card (DESIGN.md 1.15, "Motion"), in a hosting view of their own beside the line's
// (`RouterLineSlotView.placeTail`). In the line's hosting view they were placed at once while the line's slot and the
// lines under the block glided on Core Animation: a card shutting left an empty band the card's height under the block for
// the glide's length. Rolled by SwiftUI instead, they ran two or three frames behind the slot's mask and the card was drawn
// over them. Here they move on their own layer, on the glides' curve, in step with the mask that cuts the card.

/// A block's rows, in order: the header, each item, then your words or the placeholder, and where the open card cuts them.
enum RouterBlockLayout {
    enum Row: Identifiable {
        case header, item(RouterItem), sent(String), reading
        var id: String {
            switch self {
            case .header: "header"
            case .item(let item): item.id
            case .sent: "sent"
            case .reading: "reading"
            }
        }
    }

    static func rows(_ thread: RouterThread) -> [Row] {
        var rows: [Row] = [.header] + thread.ledger.items.map { .item($0) }
        switch thread.ledger.read {
        case .message(let words)?: rows.append(.sent(words))
        case .turn?: rows.append(.reading)
        case nil: break
        }
        return rows
    }

    /// How many rows are above the card: down to its item (`RouterLineBox.item`), else the header alone.
    static func cut(_ rows: [Row], item: String?) -> Int {
        guard let item, let i = rows.firstIndex(where: { $0.id == item }) else { return 1 }
        return i + 1
    }

    /// The first row under the card, if any: the tail's glide follows it (`RouterLineSlotView.placeTail`).
    @MainActor static func firstUnder(_ box: RouterLineBox) -> String? {
        let rows = rows(box.head)
        let cut = cut(rows, item: box.item)
        return cut < rows.count ? rows[cut].id : nil
    }

    /// What the block's rows are, the card's place aside. A change of it folds rows in and out as lines do (height
    /// from or to nothing, the opacity only in the fold's last part) and the rows after them slide, on `Motion.spatial`,
    /// the curve the block's height and the lines under it glide on (`RouterGlides`). Only then: a row moving between
    /// the line's hosting view and the tail's as the card moves is placed at once, and drawn where it was
    /// (`RouterBlockLeave`). Placed at once and faded on a linear curve of their own, a closed item
    /// went and left its gap under the rows after it, which jumped up into it while the block shrank on the spring.
    static func rowsKey(_ thread: RouterThread) -> [String] { rows(thread).map(\.id) }

    /// Whether the header has something of its own to say besides its name: its own words, Fjord's mark while a read
    /// is under way, or its card open under it (the wide layouts to choose from give it a row only then, `RouterLab`).
    static func headerShown(_ thread: RouterThread, sentence: RouterThread.Sentence? = nil, card: Bool) -> Bool {
        card || thread.ledger.read != nil || !RouterBlockHeader.words(thread, sentence: sentence).isEmpty
    }

    /// The tail's rows' line in the targets (`RouterTargets.frames`): placed by its line's origin and the tail's top.
    static func tailRow(_ line: String) -> String { line + "#tail" }
}

/// One row of a block: its header, an item, your words, the placeholder.
struct RouterBlockRowView: View {
    let model: RouterModel
    let box: RouterLineBox
    let thread: RouterThread
    let row: RouterBlockLayout.Row
    /// The card is open under this row's block (its ground and the focused item's).
    var open = false
    var hot = false
    var pressed = false
    /// The open row's height, for the ground under it and its card (the row the card is under).
    var focusHeight: Binding<CGFloat>?
    @Environment(\.accessibilityReduceMotion) private var reduce

    private typealias M = Router.Line

    var body: some View {
        let id = thread.id
        switch row {
        case .header:
            VStack(alignment: .leading, spacing: 0) {
                RouterButton(model: model, hit: .row(id), action: { model.click(row: id) }) { _, _ in
                    RouterBlockHeader(model: model, thread: thread, hot: hot, sentence: box.sentence)
                }
                .background {
                    RoundedRectangle(cornerRadius: M.radius, style: .continuous)
                        .fill(open && box.item == nil ? .clear : pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear)
                        .transaction { $0.animation = nil }
                }
                .overlay(alignment: .topLeading) { arrow(box.pending != nil, top: (M.minHeight - CDS.Dot.size) / 2, leading: M.dotLeading) }
                // A split message: what the thread will receive (SPLIT.md).
                if let pending = box.pending {
                    RouterPendingLine(pending: pending, leading: M.nameLeading + M.namePadX).transition(.opacity)
                }
            }
            .modifier(FocusHeight(height: focusHeight))
        case .item(let item):
            let key = RouterModel.itemKey(id, item.id)
            let flags = model.flags(.row(key))
            let focused = open && box.item == item.id
            let pending = box.pendingItems[item.id]
            VStack(alignment: .leading, spacing: 0) {
                RouterButton(model: model, hit: .row(key), action: { model.click(item: item.id, of: id) }) { _, _ in
                    RouterItemRow(model: model, thread: id, item: item, selected: focused, hot: flags.hot, pressed: flags.pressed)
                }
                .disabled(!item.live)
                // A split message: the item's arrow, and the answer it will receive (SPLIT.md).
                .overlay(alignment: .topLeading) {
                    // In the lines' dot column: the page's targets read down one edge.
                    arrow(pending != nil, top: (Router.Items.rowHeight - CDS.Dot.size) / 2, leading: M.dotLeading)
                }
                if let pending {
                    RouterPendingLine(pending: pending, leading: Router.Items.markLeading).transition(.opacity)
                }
            }
            .modifier(FocusHeight(height: focusHeight))
            .geometryGroup()
            .transition(.routerFold(reduce: reduce))
        case .sent(let words):
            RouterItemSentRow(words: words)
                .transition(.routerFold(reduce: reduce))
        case .reading:
            RouterItemPlaceholder()
                .transition(.routerFold(reduce: reduce))
        }
    }

    /// A split message's target: the arrow in the row's dot slot.
    private func arrow(_ on: Bool, top: CGFloat, leading: CGFloat) -> some View {
        ZStack { if on { RouterTargetArrow().transition(.opacity) } }
            .frame(width: CDS.Dot.size, height: CDS.Dot.size)
            .padding(.top, top).padding(.leading, leading)
            .allowsHitTesting(false)
    }

    /// Always the same view, focused or not: a modifier that came and went with the focus made the row a new view each
    /// time, and the old one, leaving after the new one had taken the row's target, took it away (the row couldn't be
    /// pointed at).
    private struct FocusHeight: ViewModifier {
        let height: Binding<CGFloat>?

        func body(content: Content) -> some View {
            let on = height != nil
            content.onGeometryChange(for: CGFloat?.self) { on ? $0.size.height : nil } action: { value in
                if let value, let height { height.wrappedValue = value }
            }
        }
    }
}

/// The tail's hosting view's root: the rows under the card, with the line's environment.
struct RouterBlockTailRoot: View {
    let model: RouterModel
    let box: RouterLineBox
    let setup: RouterLineSetup

    var body: some View {
        let tail = RouterBlockTail(model: model, box: box)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(.named(Router.rowSpace))
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, setup.scheme)
            .environment(\.routerStill, setup.still)
            .environment(\.routerRow, RouterBlockLayout.tailRow(box.id))
            .transformEnvironment(\._accessibilityReduceMotion) { if setup.reduce { $0 = true } }
        if let arrival = setup.arrival { tail.windowArrival(arrival) } else { tail }
    }
}

/// The block's rows under the open card (all its items when the header's card is open or none is), and the block's air.
struct RouterBlockTail: View {
    let model: RouterModel
    let box: RouterLineBox
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        if box.block {
            let _ = RouterBodies.count("tail", box.id, of: model)
            let thread = box.head
            let rows = RouterBlockLayout.rows(thread)
            let cut = RouterBlockLayout.cut(rows, item: box.item)
            VStack(alignment: .leading, spacing: 0) {
                // The card left a row of the tail (it moved up): the rows after it are drawn lower while it shuts. Left
                // from a row above, the tail's own glide carries the old card's height (`placeTail`).
                let leave = RouterBlockLeave.Place(box.leaving, rows: rows, cut: cut).flatMap { $0.row >= cut ? $0 : nil }
                ForEach(Array(rows.enumerated().dropFirst(cut)), id: \.element.id) { index, row in
                    RouterBlockRowView(model: model, box: box, thread: thread, row: row)
                        .modifier(RouterBlockLeave.Shift(leave: leave, index: index))
                        .modifier(RouterBlockLeave.Ghost(model: model, box: box, leave: leave, index: index))
                }
                // A little air under the block, so it reads as one thing.
                Color.clear.frame(height: 4).modifier(RouterBlockLeave.Shift(leave: leave, index: rows.count))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Rows are placed at once inside: the tail's layer glides (`RouterLineSlotView.placeTail`). They fold in and
            // out, and the rows after them slide, only when the block's rows change.
            .transaction(value: RouterBlockLayout.rowsKey(thread)) { $0.animation = Motion.spatial.resolved(reduce: reduce) }
            .transaction { $0.animation = nil }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                // Grown or shrunk on its own (a read landing): the lines under the block glide on the spatial curve.
                if box.tailHeight > 0, height != box.tailHeight, model.glides.current == nil {
                    model.glides.began(Motion.spatial.curve(reduce: reduce))
                }
                box.tailHeight = height
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// A block's open card moving to another row (`RouterLineBox.focus`): the rows split at the new row at once, and the
/// old card is drawn shutting under its row while the new one opens under its own, on the change's curve, from the same
/// frame. The card's mask, the rows under the new card and the lines under the block glide on Core Animation
/// (`RouterLineSlotView.placeTail`); what is between the two cards is drawn lower by what is left of the old card
/// (`gap`), the same curve read at the frame's time, so they move as one.
struct RouterBlockLeave: Equatable {
    /// The row the card was open under (nil: the header).
    let item: String?
    let height: CGFloat
    let curve: Motion.Curve
    let start: Date
    /// The old card's own box, for its body while it shuts: the line's as it was, its card on the old row.
    let card: RouterLineBox

    @MainActor init(item: String?, height: CGFloat, curve: Motion.Curve, start: Date, line: RouterLineBox) {
        self.item = item
        self.height = height
        self.curve = curve
        self.start = start
        card = RouterLineBox(line.record)
        card.focus(item, curve: nil)
    }

    static func == (a: Self, b: Self) -> Bool { a.card === b.card }

    /// How long it takes to land.
    var length: TimeInterval {
        switch curve {
        case .none: 0
        case .easeOut(let duration): duration
        case .spring(let duration, let bounce): Spring(duration: duration, bounce: bounce).settlingDuration
        }
    }

    /// What is left of the old card at `date`: its height, down to nothing.
    func gap(at date: Date) -> CGFloat {
        let t = date.timeIntervalSince(start)
        guard t > 0 else { return height }
        guard t < length else { return 0 }
        let progress: Double = switch curve {
        case .none: 1
        case .easeOut(let duration): UnitCurve.easeOut.value(at: t / duration)
        case .spring(let duration, let bounce): Spring(duration: duration, bounce: bounce).value(target: 1.0, time: t)
        }
        return height * CGFloat(1 - progress)
    }

    /// The leave as a view of the block's rows sees it: the old row's index, drawn lower from the row after it.
    struct Place: Equatable {
        let leave: RouterBlockLeave
        let row: Int

        init?(_ leave: RouterBlockLeave?, rows: [RouterBlockLayout.Row], cut: Int) {
            guard let leave, let row = rows.firstIndex(where: { $0.id == (leave.item ?? "header") }), row != cut - 1 else {
                return nil
            }
            self.leave = leave
            self.row = row
        }
    }

    /// A row after the old card's: drawn lower by what is left of it. Drawn, not laid out: the card's place, the rows'
    /// heights and the tail's top stay where the change put them.
    struct Shift: ViewModifier {
        let leave: Place?
        let index: Int

        func body(content: Content) -> some View {
            if let leave, index > leave.row {
                TimelineView(.animation) { context in
                    content.offset(y: leave.leave.gap(at: context.date))
                }
            } else {
                content
            }
        }
    }

    /// The old card's row: the card under it, rolling shut on its ground (what is left of it, its top first).
    struct Ghost: ViewModifier {
        let model: RouterModel
        let box: RouterLineBox
        let leave: Place?
        let index: Int

        private typealias M = Router.Line

        func body(content: Content) -> some View {
            if let leave, index == leave.row {
                content
                    .background(alignment: .top) {
                        TimelineView(.animation) { context in
                            let gap = leave.leave.gap(at: context.date)
                            RoundedRectangle(cornerRadius: M.selectedRadius, style: .continuous).fill(Router.Surface.quiet)
                                .padding(.bottom, -gap)
                                .opacity(Double(gap / max(1, leave.leave.height)))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        TimelineView(.animation) { context in
                            let gap = leave.leave.gap(at: context.date)
                            RouterCard(model: model, box: leave.leave.card)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(height: gap, alignment: .top)
                                .clipped()
                                .offset(y: gap)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .environment(\.routerLive, false)
                    }
                    .zIndex(1)
            } else {
                content
            }
        }
    }
}
