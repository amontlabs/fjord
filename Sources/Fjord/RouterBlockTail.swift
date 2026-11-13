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

    /// How many rows are above the card: down to its item (`RouterLineBox.shown`), else the header alone.
    static func cut(_ rows: [Row], item: String?) -> Int {
        guard let item, let i = rows.firstIndex(where: { $0.id == item }) else { return 1 }
        return i + 1
    }

    /// The first row under the card, if any: the tail's glide follows it (`RouterLineSlotView.placeTail`).
    @MainActor static func firstUnder(_ box: RouterLineBox) -> String? {
        let rows = rows(box.head)
        let cut = cut(rows, item: box.shown)
        return cut < rows.count ? rows[cut].id : nil
    }

    /// What the block's rows are, the card's place aside. A change of it folds rows in and out as lines do (height
    /// from or to nothing, the opacity only in the fold's last part) and the rows after them slide, on `Motion.spatial`,
    /// the curve the block's height and the lines under it glide on (`RouterGlides`). Only then: a row moving between
    /// the line's hosting view and the tail's as the card moves is placed at once (the card is shut then, so it doesn't
    /// move on screen: `RouterLineBox.shown`). Placed at once and faded on a linear curve of their own, a closed item
    /// went and left its gap under the rows after it, which jumped up into it while the block shrank on the spring.
    static func rowsKey(_ thread: RouterThread) -> [String] { rows(thread).map(\.id) }

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
            RouterButton(model: model, hit: .row(id), action: { model.click(row: id) }) { _, _ in
                RouterBlockHeader(model: model, thread: thread, hot: hot)
            }
            .background {
                RoundedRectangle(cornerRadius: M.radius, style: .continuous)
                    .fill(open && box.shown == nil ? .clear : pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear)
                    .transaction { $0.animation = nil }
            }
            .modifier(FocusHeight(height: focusHeight))
        case .item(let item):
            let key = RouterModel.itemKey(id, item.id)
            let flags = model.flags(.row(key))
            let focused = open && box.shown == item.id
            RouterButton(model: model, hit: .row(key), action: { model.click(item: item.id, of: id) }) { _, _ in
                RouterItemRow(model: model, thread: id, item: item, selected: focused, hot: flags.hot, pressed: flags.pressed)
            }
            .disabled(!item.live)
            .modifier(FocusHeight(height: focusHeight))
            .geometryGroup()
            .transition(.routerFold(reduce: reduce))
        case .sent(let words):
            RouterItemSentRow(words: words).transition(.routerFold(reduce: reduce))
        case .reading:
            RouterItemPlaceholder().transition(.routerFold(reduce: reduce))
        }
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
            let cut = RouterBlockLayout.cut(rows, item: box.shown)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.dropFirst(cut))) { row in
                    RouterBlockRowView(model: model, box: box, thread: thread, row: row)
                }
                // A little air under the block, so it reads as one thing.
                Color.clear.frame(height: 4)
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
