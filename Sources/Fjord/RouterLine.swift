import AppKit
import SwiftUI

// Router v2's thread line (docs/design/router-v2/DESIGN.md 1.4, 1.6, 1.10): the new dot, the state's mark and the name,
// the sentence (the code's line, sheening with Fjord's mark after it while the model reads the thread, then the model's
// words streaming in), the
// project pill and the age; under it the queued row, and the card when the line is selected. And what points at things:
// `RouterButton`, through which the real pointer and the demo's drawn one hover, press and click alike.

// MARK: - Pointing

/// Registers a thing that can be pointed at: where it is (for the peek and the drawn pointer), what a click does, and
/// the real pointer's hover.
private struct RouterTargetModifier: ViewModifier {
    let model: RouterModel
    let hit: RouterHit
    var removes = false
    let action: (() -> Void)?
    /// Off inside a closed card: what is there can't be pointed at.
    @Environment(\.routerLive) private var live
    /// The line whose own hosting view this is in: its frame is in that line's space.
    @Environment(\.routerRow) private var row
    /// Which view holds the hit now: a view taking another's hit (a line becoming a block's header, a block's row moving
    /// between the line's hosting view and its tail's) can appear before the old one disappears, and SwiftUI can run the
    /// old one's body once more as it goes. Only the holder writes; a view takes the hit when it appears, so the old
    /// one's last body and its leaving can't take the new one's place away.
    @State private var token = UUID()
    /// Its own frame as last laid out, written into the targets when it holds the hit.
    @State private var laid = Laid()
    private final class Laid { var frame: CGRect? }

    func body(content: Content) -> some View {
        let holder = model.targets.owners[hit]
        let _ = (holder == nil || holder == token) ? take() : ()
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(row == nil ? Router.space : Router.rowSpace)) } action: {
                laid.frame = $0
                if model.targets.owners[hit] == token { model.targets.laid[hit] = $0 }
            }
            .onAppear { take() }
            .onChange(of: live) { _, live in
                if !live { model.hover(hit, false) }
            }
            .onHover { if live { model.realHover(hit, $0) } }
            .onContinuousHover { phase in
                // A button that removes a line arms on a pointer move over it.
                if removes, !model.scripted, case .active(let point) = phase { model.pointerMoved(over: hit, at: point) }
            }
            .onDisappear {
                guard model.targets.owners[hit] == token else { return }
                model.targets.owners[hit] = nil
                model.targets.laid[hit] = nil
                model.targets.rows[hit] = nil
                model.targets.off.remove(hit)
                model.targets.actions[hit] = nil
                model.hover(hit, false)
            }
    }

    /// This view holds the hit: its action, whether it is live, its line and its frame.
    private func take() {
        let targets = model.targets
        targets.owners[hit] = token
        targets.actions[hit] = live ? action : nil
        if live { targets.off.remove(hit) } else { targets.off.insert(hit) }
        targets.rows[hit] = row
        if let frame = laid.frame { targets.laid[hit] = frame }
    }
}

extension EnvironmentValues {
    /// Whether the things inside can be pointed at (a closed card's can't).
    @Entry var routerLive = true
    /// Inside a line's own hosting view (`RouterHostedLine`): that line's id.
    @Entry var routerRow: String? = nil
}

extension View {
    func routerTarget(_ model: RouterModel, _ hit: RouterHit, removes: Bool = false, action: (() -> Void)? = nil) -> some View {
        modifier(RouterTargetModifier(model: model, hit: hit, removes: removes, action: action))
    }

    /// The pointing hand over a link or a pill.
    @ViewBuilder func routerLink() -> some View {
        if #available(macOS 15, *) { pointerStyle(.link) } else { self }
    }
}

/// A button of the page: its label is told whether the pointer is on it and whether it is pressed, read from the model, so
/// the drawn pointer lights and presses it as the real one does. `removes`: it takes a line off the page, so it only
/// fires once the pointer has moved over it since the last removal.
struct RouterButton<Label: View>: View {
    let model: RouterModel
    let hit: RouterHit
    var removes = false
    let action: () -> Void
    @ViewBuilder let label: (_ hot: Bool, _ pressed: Bool) -> Label

    var body: some View {
        Button(action: fire) { EmptyView() }
            .buttonStyle(Style(model: model, hit: hit, label: label))
            .routerTarget(model, hit, removes: removes, action: fire)
    }

    private func fire() {
        if removes, !model.isArmed(hit) { return }
        action()
    }

    private struct Style: ButtonStyle {
        let model: RouterModel
        let hit: RouterHit
        let label: (Bool, Bool) -> Label

        func makeBody(configuration: Configuration) -> some View {
            Styled(model: model, hit: hit, down: configuration.isPressed, label: label)
        }
    }

    private struct Styled: View {
        let model: RouterModel
        let hit: RouterHit
        let down: Bool
        let label: (Bool, Bool) -> Label

        var body: some View {
            // Its own flags: the pointer moving between two things redraws those two.
            let flags = model.flags(hit)
            label(flags.hot, flags.pressed)
                .contentShape(Rectangle())
                .onChange(of: down) { _, down in
                    if down { model.pressed = hit } else if model.pressed == hit { model.pressed = nil }
                }
        }
    }
}

// MARK: - Line

/// Where a block's card place is in its line: its top (the rows above it) and its bottom (the rows under it start there).
struct RouterCardPlace: Equatable {
    var head: CGFloat
    var top: CGFloat
    /// Reported again when the line becomes a block, where nothing else may move (a header is a line's height).
    var block = false
}

/// The card's place's clip: its own rect, reaching `below` further down (a block's card rolling shut is drawn past its
/// place, and the line's mask cuts it).
struct RouterPlaceClip: Shape {
    var below: CGFloat
    func path(in rect: CGRect) -> Path { Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + below)) }
}

struct RouterLineView: View {
    let model: RouterModel
    /// Its own box: the line redraws when its record or its flags change, and for nothing else.
    let box: RouterLineBox
    /// The card's own height, as laid out: its place opens to it and follows it (a reply growing, a plan opening).
    @State private var cardHeight: CGFloat = 0
    /// How much of the card and its ground shows. A card that opens as a line takes off (you answered: that line goes
    /// to Working and the next card opens) lets the line pass first: its place opens at once, on the move's curve, and
    /// what is in it comes a moment later, so the line in flight never crosses it.
    @State private var shown: Double = 1
    /// The row's width: a name takes up to its share of it (`M.nameShare`).
    @State private var rowWidth: CGFloat = 0
    /// The name's width, as laid out: the line leaves it blank at its sentence's start.
    @State private var nameWidth: CGFloat = 0
    /// In a block: the height of the row whose card is open (its ground starts at that row's top).
    @State private var focusRowHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    private typealias M = Router.Line

    var body: some View {
        let _ = RouterBodies.count("line", box.id, of: model)
        let thread = box.head
        let id = box.id
        let selected = box.selected
        let flags = model.flags(.row(id))
        let hot = flags.hot
        let pressed = flags.pressed
        let moving = box.moving
        // A line in flight is its row alone: in the frame it takes off its card's content and the selected surface are
        // gone (nothing half-faded is dragged across the page), while the card's place folds on the move's own curve, so
        // the rows under it close up as the next card opens. It opens again once the line has landed.
        let open = selected && !moving
        // A line's card rolling shut keeps its place whole: the slot's mask rolls it shut on Core Animation, in step
        // with the lines under it. Shut in SwiftUI's own transaction, the place was sometimes at nothing in the first
        // frame and the card's words went with it, its height left bare while the lines under it glided up.
        let shutting = !open && !moving && box.built && !thread.ledger.block
        let block = thread.ledger.block
        let rows = block ? RouterBlockLayout.rows(thread) : []
        let cut = RouterBlockLayout.cut(rows, item: box.item)
        // A block's card moving to another row: the old one shuts under its row as this one opens (`RouterBlockLeave`).
        let leave = block ? RouterBlockLeave.Place(box.leaving, rows: rows, cut: cut) : nil
        VStack(alignment: .leading, spacing: 0) {
          if block {
            // A thread with open items (any): its line, then a row per item; the open card under its row,
            // the rows after it under the card (RouterItems.swift).
            blockHead(thread, open: open, hot: hot, pressed: pressed)
                // Over the open card's ground, which reaches up behind the open row from the card's place.
                .zIndex(1)
                // A line taking its first item (or losing its last): its row swaps for the header in place, at the
                // same height, and only the item's row folds in or out; crossfaded, the two rows' words doubled.
                .transition(.identity)
          } else {
            RouterButton(model: model, hit: .row(id), action: { model.click(row: id) }) { _, _ in
                row(thread, hot: hot)
            }
            .background {
                // The row's own ground under the pointer: on and off at once, so no trail follows the pointer down the list.
                RoundedRectangle(cornerRadius: M.radius, style: .continuous)
                    .fill(open || moving ? .clear : pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear)
                    .transaction { $0.animation = nil }
            }
            // Its height, for the list's slot (`RouterHostedLine`).
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.rowHeight = $0 }
            .transition(.identity)
            // A line changing section glides there as itself: no plate, no edge, no shadow. What it passes fades out
            // under it and back behind it (the veil), there from the frame it takes off and gone once it has landed in
            // the gap the rows opened for it.
            .background {
                RouterVeil()
                    .opacity(moving ? 1 : 0)
                    .animation(moving ? nil : Motion.fade.resolved(reduce: reduce), value: moving)
            }
            // A split message: what this line will receive (SPLIT.md).
            if let pending = box.pending {
                RouterPendingLine(pending: pending, leading: M.nameLeading + M.namePadX)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.pendingHeight = $0 }
                    .onDisappear { box.pendingHeight = 0 }
                    .transition(.opacity)
            }
            if let queued = thread.queued {
                RouterQueuedRow(model: model, thread: id, words: queued)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.queuedHeight = $0 }
                    .onDisappear { box.queuedHeight = 0 }
                    .transition(.routerFold(reduce: reduce))
            }
          }
            // The card is in its line, closed to no height: it rolls open and shut in place, at full opacity, clipped to
            // the line's surface, on the curve the rows around it move on. Only an open card (or one rolling shut) has a
            // body: a closed one costs nothing.
            ZStack(alignment: .top) {
                if box.built || open {
                    RouterCard(model: model, box: box)
                        // Under its row while the card it replaces shuts above it (`RouterBlockLeave`).
                        .modifier(RouterBlockLeave.Shift(leave: leave, index: leave.map { _ in cut } ?? 0))
                        .transition(.identity)
                }
            }
                // As wide as the line while closed too: an empty place had no width, and a card's first open grew its
                // clip from nothing across, cutting its words on the right for the first frames.
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    // Grown or shrunk while open (a reply, a plan): the rows under it glide as it does, on the spatial
                    // curve, unless the change that did it has a curve of its own.
                    if open, cardHeight > 0, $0 != cardHeight, model.glides.current == nil {
                        model.glides.began(Motion.spatial.curve(reduce: reduce))
                    }
                    cardHeight = $0
                    box.cardHeight = $0
                }
                .opacity(moving ? 0 : shown)
                .transaction { if moving { $0.animation = nil } }
                .frame(height: open || shutting ? (cardHeight > 0 ? cardHeight : nil) : 0, alignment: .top)
                // In a block the card's place shuts at once and the card is still drawn below it while it rolls shut:
                // the line's mask cuts it where the rows under it are, both on Core Animation (`placeTail`).
                .clipShape(RouterPlaceClip(below: block ? RouterLineSlotView.roomStep + (leave?.leave.height ?? 0) : 0))
                .background(alignment: .top) {
                    // A block's open card: its ground under the open row and its card only, not the whole block. Held by
                    // the card's place, it moves with it (an item folding above it). It reaches past the card: the line's
                    // mask ends it, with its corners, where the rows under the card are (`placeTail`), so a card shutting
                    // or changing rows keeps its ground down to them.
                    if block {
                        // An item's hugs its row: from its mark's gutter, as a line's ground is from its mark (the
                        // header's is the whole line's).
                        RoundedRectangle(cornerRadius: M.selectedRadius, style: .continuous).fill(Router.Surface.quiet)
                            .padding(.leading, box.item == nil ? 0 : Router.Items.groundLeading)
                            .motion(.spatial, value: box.item == nil)
                            .frame(height: max(0, focusRowHeight + cardHeight + RouterLineSlotView.roomStep))
                            .offset(y: -focusRowHeight)
                            .modifier(RouterBlockLeave.Shift(leave: leave, index: leave.map { _ in cut } ?? 0))
                            .opacity(open ? shown : 0)
                            .modifier(GroundPresence(open: open, moving: moving))
                    }
                }
                .onGeometryChange(for: RouterCardPlace.self) {
                    let f = $0.frame(in: .named(Router.rowSpace))
                    return RouterCardPlace(head: f.minY, top: f.maxY, block: block)
                } action: { [box] place in
                    guard block else { return }
                    box.slot?.placeTail(head: place.head, top: place.top)
                }
                // Its content grew or shrank while open: the card follows, and the rows under it slide.
                .motion(.spatial, value: block ? 0 : cardHeight)
                // In a block, its place changes at once: the rows under it and the mask move on Core Animation. Except
                // as the block's rows change: an item folding away above the card (struck, done) or in, the card and its
                // ground glide with the rows above it, on their spring, as the rows under it and the mask do. Placed at
                // once, the card went up by the row's height in the first frame while the row folded.
                .transaction(value: RouterBlockLayout.rowsKey(thread)) {
                    if block { $0.animation = Motion.spatial.resolved(reduce: reduce) }
                }
                .transaction { if block { $0.animation = nil } }
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
                .environment(\.routerLive, open)
                // Shut, the card's body goes once the slot's mask has rolled it shut (`RouterLineSlotView.clip`; in a
                // block, `placeTail`), unless it opened again meanwhile.
            // A block's rows under the card are in a hosting view of their own (`RouterBlockTail`).
        }
        .background {
            // Selected, the row and its card share one ground (a fill, no outline), which comes and goes with the
            // card's fold.
            RoundedRectangle(cornerRadius: M.selectedRadius, style: .continuous).fill(Router.Surface.quiet)
                .opacity(open && !block ? shown : 0)
                .modifier(GroundPresence(open: open, moving: moving))
                // The card's content grew or shrank while open (a quote or a plan rolling): the ground follows on the
                // place's curve. Sized by the line outside the place's own animation, it took its new height at once,
                // and a quote rolling shut was drawn below it until its roll ended.
                .motion(.spatial, value: cardHeight)
                .transaction { if moving { $0.animation = nil } }
        }
        .onChange(of: open) { _, open in
            // Opening while a line is in flight: after it has passed (it is past the card's place within a third of
            // its flight).
            guard open, !model.moving.isEmpty, !model.still, !reduce else { return }
            var none = Transaction()
            none.disablesAnimations = true
            withTransaction(none) { shown = 0 }
            let after = Router.cardAfterFlight
            let reveal = Animation.easeOut(duration: after.fade).delay(after.delay).resolved(reduce: reduce)
            DispatchQueue.main.async { withAnimation(reveal) { shown = 1 } }
        }
        // The line moves as one: what changes in it on the way (its mark, its sentence) arrives with it, not ahead of it.
        .geometryGroup()
        // A line in flight passes over the rows between: it is drawn last.
        .zIndex(moving ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(thread.name), \(thread.look.label)")
    }

    /// The selected ground coming and going with its card. Opening, it is there whole in the frame the row's own ground
    /// goes, and the line's mask rolls it open with the card: faded in on the spring, the row lost its hover ground for a
    /// frame and the ground came up under a card already drawn (a flash). Shutting, it stays under the card while the
    /// mask rolls them shut together and is gone as the roll lands (an ease-in as long as the roll): faded on the
    /// spring, it was gone in a tenth of a second and the card's words rolled shut on the bare page. A line taking off
    /// loses it in the frame it takes off.
    private struct GroundPresence: ViewModifier {
        let open: Bool
        let moving: Bool
        @Environment(\.accessibilityReduceMotion) private var reduce

        func body(content: Content) -> some View {
            content.transaction(value: open) { $0.animation = open || moving ? nil : M.groundOut.resolved(reduce: reduce) }
        }
    }

    /// The block's rows down to the one whose card is open (the header when none is): its height is the line's row height.
    private func blockHead(_ thread: RouterThread, open: Bool, hot: Bool, pressed: Bool) -> some View {
        let rows = RouterBlockLayout.rows(thread)
        let cut = RouterBlockLayout.cut(rows, item: box.item)
        let leave = RouterBlockLeave.Place(box.leaving, rows: rows, cut: cut)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.prefix(cut).enumerated()), id: \.element.id) { index, row in
                RouterBlockRowView(model: model, box: box, thread: thread, row: row, open: open, hot: hot, pressed: pressed,
                                   focusHeight: row.id == rows[cut - 1].id ? $focusRowHeight : nil)
                    .modifier(RouterBlockLeave.Shift(leave: leave, index: index))
                    .modifier(RouterBlockLeave.Ghost(model: model, box: box, leave: leave, index: index))
            }
        }
        // Inside a block, rows are placed at once: the slot's mask and the lines under the block move on Core Animation,
        // and a SwiftUI glide here drew rows outside the mask, and an item's kind and words apart, for a few frames. They
        // fold in and out only when the block's rows change (`RouterBlockLayout.rowsKey`).
        .transaction(value: RouterBlockLayout.rowsKey(thread)) { $0.animation = Motion.spatial.resolved(reduce: reduce) }
        .transaction { $0.animation = nil }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if box.rowHeight > 0, height != box.rowHeight, model.glides.current == nil {
                model.glides.began(Motion.spatial.curve(reduce: reduce))
            }
            box.rowHeight = height
        }
        .background {
            RouterVeil()
                .opacity(box.moving ? 1 : 0)
                .animation(box.moving ? nil : Motion.fade.resolved(reduce: reduce), value: box.moving)
        }
    }

    private func row(_ thread: RouterThread, hot: Bool) -> some View {
        // The line the draft goes to, when it isn't the selected one: the destination row's arrow, in the dot's slot.
        // A split message's target has it too (SPLIT.md).
        let marked = box.marked || box.pending != nil
        // The sentence is never cut: it flows as text from after the name and wraps under it; the rest keeps to its first
        // line. (A Sent line keeps to one: your words in quotes, then their status.)
        let flows = thread.sent == nil
        return HStack(alignment: .routerFirstLine, spacing: 0) {
            ZStack {
                Circle().fill(CDS.Fill.accent).opacity(thread.isNew && !marked ? 1 : 0)
                    // Its own fade, whatever change takes it away (a key's act carries it: `RouterModel.markSeen`).
                    .motion(.fade, value: thread.isNew)
                if marked {
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.accent)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .frame(width: CDS.Dot.size, height: CDS.Dot.size)
            .padding(.leading, M.dotLeading).padding(.trailing, M.dotGap)
            .motion(.fade, value: marked)
            .accessibilityLabel(marked ? "Your words go here" : thread.isNew ? "New" : "")
            if flows {
                // The sentence flows as text, the name its highlight at the start, and a line it wraps to starts under
                // the name's ground and runs to the pill (its first line leaves the name's width blank, `RouterFlow`).
                ZStack(alignment: .topLeading) {
                    RouterSentenceView(model: model, box: box, lead: nameWidth > 0 ? nameWidth + M.sentenceGap : 0)
                        .routerActivity(model, thread)
                        .padding(.top, M.namePadY)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RouterName(model: model, thread: thread, rowHot: hot)
                        .modifier(RouterWidthCap(cap: rowWidth > 0 ? rowWidth * M.nameShare : .infinity))
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nameWidth = $0 }
                }
                .alignmentGuide(.routerFirstLine) { _ in M.namePadY + Router.Items.lineHeight / 2 }
            } else {
                RouterName(model: model, thread: thread, rowHot: hot)
                    .modifier(RouterWidthCap(cap: rowWidth > 0 ? rowWidth * M.nameShare : .infinity))
                    .layoutPriority(2)
                RouterSentenceView(model: model, box: box)
                    // Its subagents, background commands and waits, at the end of its place, before the pill (RouterActivityViews.swift).
                    .routerActivity(model, thread)
                    .padding(.leading, M.sentenceGap)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let project = thread.project {
                RouterProjectPill(model: model, thread: thread.id, project: project)
                    .padding(.leading, M.pillGap)
                    .opacity(model.project == nil ? 1 : 0)
                    .allowsHitTesting(model.project == nil)
                    .layoutPriority(1)
            }
            RouterAge(model: model, since: thread.since)
                .padding(.leading, M.ageGap).padding(.trailing, M.reach)
                .layoutPriority(1)
        }
        // As much air over and under the name's ground as a one-line row has, when the words wrap.
        .padding(.vertical, flows ? (M.minHeight - Router.Items.lineHeight - 2 * M.namePadY) / 2 : 0)
        .frame(minHeight: M.minHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        // A name being given: the sentence slides to its new start.
        .motion(.spatial, value: thread.name)
    }
}

extension Router.Line {
    /// The selected ground going as its card rolls shut (`RouterLineView.GroundPresence`): as long as the roll.
    static let groundOut = Animation.easeIn(duration: 0.3)
}

/// Its content at its own width, never wider than `cap` (a flexible frame would take the whole cap).
struct RouterWidthCap: ViewModifier {
    let cap: CGFloat

    func body(content: Content) -> some View { Cap(cap: cap) { content } }

    private struct Cap: Layout {
        let cap: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            let ideal = child.sizeThatFits(.unspecified)
            let width = min(ideal.width, cap, proposal.width ?? .infinity)
            return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

/// The state's mark and the thread's name: on a ground of the state's tint when it asks something of you or is worth a
/// look, plain otherwise. The pointer on it shows the peek.
struct RouterName: View {
    let model: RouterModel
    let thread: RouterThread
    var rowHot = false

    private typealias M = Router.Line

    var body: some View {
        let look = thread.look
        let shape = RoundedRectangle(cornerRadius: M.nameRadius, style: .continuous)
        HStack(spacing: M.markGap) {
            RouterMark(look: look, paused: thread.paused)
            name(look)
        }
        .padding(.horizontal, M.namePadX).padding(.vertical, M.namePadY)
        .background { shape.fill(look.tint.opacity(look.ground ? (rowHot ? M.groundHover : M.ground) : 0)).hoverMotion(rowHot) }
        .contentShape(shape)
        .routerTarget(model, .name(thread.id))
    }

    private func name(_ look: RouterThread.Look) -> some View {
        ZStack(alignment: .leading) {
            // The name's width at the medium weight, always: the sentence's start doesn't shift when a state gives the
            // name its ground (medium) or takes it back (regular).
            // It takes the width it needs, up to the row's share for a name (`RouterLine.nameShare`), then truncates:
            // T3's whole title stands in until the model's name comes.
            Text(thread.name).font(CDS.sans(14, .medium)).lineLimit(1).hidden().accessibilityHidden(true)
            if thread.naming {
                // Being named: the words sheen until the model's name takes their place. The line's one Fjord mark is
                // after its sentence, so none here.
                let text = Text(thread.name).font(CDS.sans(14, look.ground ? .medium : .regular))
                text.foregroundStyle(CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                    .routerSheen { text.lineLimit(1).truncationMode(.tail) }
                    .transition(.routerSwap)
            } else {
                Text(thread.name).font(CDS.sans(14, look.ground ? .medium : .regular))
                    .foregroundStyle(look.ground ? look.tint : CDS.Text.primary).lineLimit(1).truncationMode(.tail)
                    .id(thread.name)
                    .transition(.routerSwap)
            }
        }
    }
}

/// A state's mark in its box: an SF Symbol, or the working dots.
struct RouterMark: View {
    let look: RouterThread.Look
    var paused = false
    var size: CGFloat = Router.Line.mark

    var body: some View {
        // On Core Animation (`RouterTick`): the old mark goes as the new one comes, when the change is animated.
        RouterTick(key: look.symbol.map { "\($0)|\(look.label)" } ?? "~\(look.label)", style: .replace, always: false, look: "\(paused)") {
            ZStack {
                if let symbol = look.symbol {
                    Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(look.tint)
                } else {
                    RouterWorkingDots(tint: look.tint, paused: paused)
                }
            }
            // Its box inside: the view keeps its frame as one mark takes another's place (a frame that changes makes
            // AppKit walk the window's views for their tracking areas).
            .frame(width: Router.Line.markBox, height: Router.Line.markBox)
        }
        .accessibilityHidden(true)
    }
}

/// The line's sentence. Sent: your words in quotes and the status, sheening, until T3 has them; for a thread started
/// here, what it starts with after them. Otherwise the code's line or the model's: muted with a sheen and Fjord's mark
/// while the thread is read again, the model's words streaming in when they land.
struct RouterSentenceView: View {
    let model: RouterModel
    /// Its line's box: streamed words redraw this view only.
    let box: RouterLineBox
    /// The blank its sentence starts with, where the name sits over it.
    var lead: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let _ = RouterBodies.count("sentence", box.id, of: model)
        let thread = box.head
        let sentence = box.sentence
        ZStack(alignment: .leading) {
            if let sent = thread.sent, thread.state == .sent {
                HStack(spacing: 6) {
                    Text("“\(sent.words)”").font(CDS.sans(14)).foregroundStyle(CDS.Text.primary).lineLimit(1).truncationMode(.tail)
                    if sent.status != .taken {
                        let status = Text(sent.status == .steering ? Router.Copy.steering : Router.Copy.sending).font(CDS.sans(14))
                        status.foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
                            .routerSheen { status.lineLimit(1).fixedSize() }
                            .transition(.opacity)
                    }
                    // A thread started here: the model and effort it starts with, so the one thing the settings are
                    // about can be checked on the line.
                    if let launch = thread.launch {
                        Text(model.brief(launch)).font(CDS.sans(12)).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
                            .padding(.leading, 2)
                    }
                }
                .transition(.routerSwap)
            } else {
                let s = sentence
                let reassessing = s.phase == .reassessing
                let words = RouterWords(s.text, prs: thread.prs, stateWord: s.stateWord)
                let tint = reassessing ? CDS.Text.muted : thread.sentenceTint
                let stream = s.stream
                let id = thread.id
                let lines = Router.Items.sentenceLines
                HStack(alignment: .top, spacing: Router.Thinking.gap) {
                    RouterStreamedText(words: words, tint: tint, mono: s.mono, arriving: s.phase == .streaming,
                                         complete: box.complete,
                                         prState: words.parts.contains { $0.kind == .link } ? thread.prs.first?.state : nil,
                                         lead: lead) {
                        model.streamed(id, stream: stream)
                    }
                    .lineLimit(lines).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .topLeading) {
                        if reassessing {
                            RouterSheen().mask(alignment: .topLeading) {
                                RouterSentenceText.text(words, tint: .black, mono: s.mono, attributed: false, lead: lead)
                                    .lineLimit(lines).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                            }
                            .transition(.opacity)
                        }
                    }
                    // The Router's model is reading the thread: Fjord's mark after the words it is about to replace.
                    if reassessing { RouterThinking().frame(height: Router.Items.lineHeight).transition(.opacity) }
                }
                // One view per line of words: the old line goes, then the new one is there (the model's words fade
                // in themselves as they stream, from the frame the old line starts to go). Words that grow are the
                // same line: only the ones that arrived fade in.
                .id(box.sentenceID)
                .transition(s.phase == .streaming ? .routerSwapOut : .routerSwap)
            }
        }
        .motion(.fade, value: sentence.phase)
        // A new text taking another's place (`.id` above), not each word that grows: an animation on every streamed
        // word laid the sentence out on every frame while it streamed (the words fade in on their own).
        .motion(.fade, value: box.sentenceID)
    }
}

/// CDS Badge, neutral xs: the thread's project. A click filters the page to it.
struct RouterProjectPill: View {
    let model: RouterModel
    let thread: String
    let project: String

    var body: some View {
        RouterButton(model: model, hit: .pill(thread), action: { model.toggle(project: project) }) { hot, _ in
            RouterProjectBadge(project: project, hot: hot)
        }
        .routerLink()
        .accessibilityLabel("Project \(project)")
        .accessibilityHint("Filters the page to \(project)")
    }
}

struct RouterProjectBadge: View {
    let project: String
    var hot = false

    var body: some View {
        Text(project).font(CDS.sans(CDS.Badge.font, .medium)).foregroundStyle(hot ? CDS.Text.primary : CDS.Badge.ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, CDS.Badge.padX)
            .frame(height: CDS.Badge.height)
            .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous)
                .fill(hot ? Router.Surface.chosen : Router.Surface.quiet))
            .hoverMotion(hot)
    }
}

/// "now", "4m", "2h", "3d": how long it has waited, run, or been finished. It ticks on the page's one minute clock.
struct RouterAge: View {
    let model: RouterModel
    let since: Date
    private static let font = CDS.nsSans(12).monospacedDigits

    var body: some View {
        let _ = model.clock.minute
        let age = BriefAge.short(model.now.timeIntervalSince(since))
        // It ticks as the counts do, on Core Animation (`RouterTick`): never two ages on top of each other.
        RouterTick(key: age, style: .numeric(font: Self.font)) {
            Text(age)
                .font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted)
                .lineLimit(1).fixedSize()
                // Its column inside: the view keeps its frame as the age ticks.
                .frame(minWidth: Router.Line.ageWidth, alignment: .trailing)
        }
    }
}

/// Words waiting for the turn under way, inside their thread's line: `Cancel` puts them back in the composer.
struct RouterQueuedRow: View {
    let model: RouterModel
    let thread: String
    let words: String

    var body: some View {
        HStack(spacing: Router.Line.markGap) {
            // In the mark's box, so the words start under the name above.
            Image(systemName: "arrow.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                .frame(width: Router.Line.markBox)
            Text("“\(words)”").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.secondary).lineLimit(1)
            Text("· " + Router.Copy.queued).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).lineLimit(1)
                .padding(.leading, 2)
                .layoutPriority(1)
            Spacer(minLength: 8)
            RouterTextButton(model: model, hit: .cancelQueued(thread), title: "Cancel") { model.cancelQueued(thread) }
        }
        .frame(height: Router.Line.queuedHeight)
        .padding(.leading, Router.Line.nameLeading + Router.Line.namePadX)
        .padding(.trailing, Router.Line.reach)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }
}

/// A ghost text button: footnote, muted, primary under the pointer; its keys after it as keycaps.
struct RouterTextButton: View {
    let model: RouterModel
    let hit: RouterHit
    let title: String
    var keys: [String] = []
    var removes = false
    let action: () -> Void

    var body: some View {
        RouterButton(model: model, hit: hit, removes: removes, action: action) { hot, pressed in
            HStack(spacing: 5) {
                // A title that changes ("Show all" to "Show less") swaps; it is never two titles at once.
                ZStack(alignment: .leading) {
                    Text(title).cdsText(CDS.Density.compact.footnote, .regular, hot ? CDS.Text.primary : CDS.Text.muted)
                        .lineLimit(1).fixedSize()
                        .id(title).transition(.routerSwap)
                }
                if !keys.isEmpty { RouterKeyHint(keys: keys).id(keys).transition(.routerSwap) }
            }
            .frame(height: 22)
            .opacity(pressed ? 0.7 : 1)
            .hoverMotion(hot)
        }
        .accessibilityLabel(title)
    }
}

// MARK: - Peek

/// The housekeeping line's peek: its threads, each with its project and age. Wider: the names are T3's titles, whole.
struct RouterOlderPeek: View {
    let model: RouterModel
    let older: [RouterOlder]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(older) { o in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                    Text(o.name).cdsText(CDS.Density.compact.body, .regular, CDS.Text.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    if let project = o.project { RouterProjectBadge(project: project) }
                    Text(BriefAge.short(model.now.timeIntervalSince(o.since))).font(CDS.sans(12)).monospacedDigit()
                        .foregroundStyle(CDS.Text.muted).frame(minWidth: 20, alignment: .trailing)
                }
            }
        }
        .modifier(RouterPeekShell(width: Router.Peek.olderWidth))
    }
}

extension View {
    /// The page's peek shell (1.6): padding 12, 360 wide, floating, read-only.
    func routerPeekShell(width: CGFloat = Router.Peek.width) -> some View { modifier(RouterPeekShell(width: width)) }
}

private struct RouterPeekShell: ViewModifier {
    var width: CGFloat = Router.Peek.width

    func body(content: Content) -> some View {
        content
            .padding(Router.Peek.pad)
            .frame(width: width, alignment: .leading)
            // The page's one floating shell, as the menus'.
            .routerFloating(radius: Router.Peek.radius)
            .allowsHitTesting(false)
    }
}

/// CDS Badge, tinted: `#41 open` success, `#41 merged` violet, `#41 closed` danger.
struct RouterPRBadge: View {
    let pr: RouterThread.PR
    @State private var pop: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Text(verbatim: "#\(pr.number) \(pr.state.rawValue)")
            .font(CDS.sans(11, .medium)).foregroundStyle(RouterPRTint.text(pr.state))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous).fill(RouterPRTint.fill(pr.state)))
            .scaleEffect(pop)
            .onChange(of: pr.state) {
                pop = Router.prPopScale
                let spring = Router.prPop.resolved(reduce: reduce)
                DispatchQueue.main.async { withAnimation(spring) { pop = 1 } }
            }
            .accessibilityLabel("Pull request \(pr.number), \(pr.state.rawValue)")
    }
}
