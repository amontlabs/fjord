import AppKit
import SwiftUI

// A card's quote (docs/design/router-v2/DESIGN.md R10, 2026-11-14): the agent's own words behind what the card says are a
// small quote mark right after the words they back (the detail; with none, the sentence the card is about, on its line), not a block of their
// own. The pointer on the mark shows the quote whole in the page's hover shell (14 lines tall, scrolled past that);
// a click opens the thread in T3. An item's quote is its own lines, else its thread's last message; a thread's is its
// last message.

/// The quote mark: `quote.bubble` in outline (its words, not punctuation), 11 pt, quiet, primary under the pointer.
struct RouterQuoteMark {
    static let symbol = "quote.bubble"
    static let size: CGFloat = 11
    /// The glyph's ink over and under its baseline at `size` (`quote.bubble`, measured at 2x).
    static let inkAbove: CGFloat = 10.5
    static let inkBelow: CGFloat = 0

    /// The mark as it is drawn in the words.
    static var glyph: Text { Text(Image(systemName: symbol)).font(.system(size: size, weight: .regular)) }

    /// Quieter than the muted words at rest (it backs them, it isn't one of them); primary under the pointer.
    static func ink(_ hot: Bool) -> Color { hot ? CDS.Text.primary : CDS.Text.muted.opacity(0.7) }

    /// The mark after the sentence the card is about, where the sentence is drawn (the line, the pane's head, a ledger
    /// row): its card has no detail for the mark to follow, and quotes. Nil while the card isn't open.
    @MainActor static func onSentence(_ model: RouterModel, _ box: RouterLineBox, item: RouterItem?) -> RouterQuoteMarkSpec? {
        let thread = box.head
        // As the card reads it: the line's box has the last lines (`RouterSummaryCard`).
        let layers = RouterLayers(thread, item, lastLines: box.talking ? "…" : "")
        guard layers.detail == nil, layers.quote != nil else { return nil }
        return RouterQuoteMarkSpec(model: model, thread: thread.id, item: item?.id)
    }

    /// The hit of a card's mark: its thread and its item (none for the thread's last message).
    static func hit(_ thread: String, _ item: String?) -> RouterHit { .quote(thread, item) }

    /// The quote behind a mark's hit: an item's own lines, else its thread's last message.
    @MainActor static func words(_ model: RouterModel, _ hit: RouterHit) -> String? {
        guard case .quote(let id, let itemID) = hit, let t = model.thread(id) else { return nil }
        let item = itemID.flatMap { i in t.ledger.items.first { $0.id == i } }
        return RouterLayers(t, item).quote
    }

    /// A click on the mark: the thread in T3.
    @MainActor static func open(_ model: RouterModel, _ thread: String) {
        // TODO: T3 can't open a thread at a message yet. Store the quoted message's id with the quote (`RouterItem.quote`,
        // the last lines) and open there once it can.
        model.open(thread)
    }
}

/// Words with the quote mark after their last word, flowing with them (joined by a no-break space: it never wraps onto a
/// line of its own). The mark is drawn in the text; the pointer's target is laid over where the text drew it. Words cut
/// at their line limit would cut the mark with their last word: then (and before macOS 15, which can't tell where the
/// text drew it) the mark is a button of its own after the words, which leave it room.
struct RouterQuoteTrail<Drawn: View>: View {
    let model: RouterModel
    let hit: RouterHit
    let thread: String
    /// The words as they are laid out.
    let words: Text
    /// What follows the mark on its line (a row's age).
    let after: Text?
    /// The words as drawn with `trail` after them (the mark and `after`); nil: the mark is drawn apart, after them.
    let drawn: (_ trail: Text?) -> Drawn

    @State private var slot: CGRect?
    /// The words didn't leave the mark room on their last line: it is drawn apart.
    @State private var cut = false
    @State private var box = RouterQuoteSlotBox()

    init(model: RouterModel, hit: RouterHit, thread: String, words: Text, after: Text? = nil,
         drawn: @escaping (_ trail: Text?) -> Drawn) {
        self.model = model
        self.hit = hit
        self.thread = thread
        self.words = words
        self.after = after
        self.drawn = drawn
    }

    var body: some View {
        let hot = model.flags(hit).hot
        let space = Text(verbatim: "\u{00A0}")
        let tail = after ?? Text(verbatim: "")
        if #available(macOS 15, *) {
            // Laid out with the mark, drawing nothing: it finds where the mark falls, or that the words cut it. The words
            // as drawn sit over it, laid out the same (a renderer that drew the words drew them a shade heavier than the
            // words around them).
            (words + space + RouterQuoteMark.glyph.customAttribute(RouterQuoteSlot()) + tail)
                .textRenderer(RouterQuoteSlotRenderer(box: box))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay(alignment: .topLeading) {
                    if cut {
                        apart()
                    } else {
                        spoken(drawn(space + RouterQuoteMark.glyph.foregroundColor(RouterQuoteMark.ink(hot)) + tail), words + tail)
                    }
                }
                .onAppear { box.listen { slot = $0; cut = $0 == nil } }
                .background(alignment: .topLeading) {
                    // A small rounded ground under the pointer, behind the glyph.
                    if !cut, let slot, hot { ground(slot) }
                }
                .overlay(alignment: .topLeading) {
                    if !cut, let slot { target(slot) }
                }
        } else {
            apart()
        }
    }

    /// The words, then the mark as a button of its own on their last line, then what follows it.
    private func apart() -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 1) {
            spoken(drawn(nil), words)
            RouterButton(model: model, hit: hit, action: { RouterQuoteMark.open(model, thread) }) { hot, _ in
                RouterQuoteMark.glyph.foregroundColor(RouterQuoteMark.ink(hot))
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous)
                        .fill(hot ? Router.Surface.hover : .clear))
                    .frame(minWidth: 18, minHeight: 18)
            }
            .routerLink()
            .fixedSize()
            .quoteMarkAccessibility(model, hit)
            if let after { after.lineLimit(1).fixedSize() }
        }
    }

    /// The words as one element, read without the mark's glyph (the mark is its own element).
    private func spoken(_ view: some View, _ label: Text) -> some View {
        view.accessibilityElement(children: .ignore).accessibilityLabel(label)
    }

    /// A small rounded ground under the pointer, centred on the glyph as drawn (`slot` is the glyph's ink, not its
    /// line box: centred on the line box, the glyph sat high in it), 3 pt round it, a token's radius.
    private func ground(_ rect: CGRect) -> some View {
        let w = rect.width + 6, h = rect.height + 6
        return RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous).fill(Router.Surface.hover)
            .frame(width: w, height: h)
            .offset(x: rect.midX - w / 2, y: rect.midY - h / 2)
            .allowsHitTesting(false)
    }

    /// The mark's target: a little larger than the glyph, centred on it.
    private func target(_ rect: CGRect) -> some View {
        let w = max(rect.width + 8, 18), h = max(rect.height + 6, 18)
        return RouterButton(model: model, hit: hit, action: { RouterQuoteMark.open(model, thread) }) { _, _ in
            Color.clear.frame(width: w, height: h)
        }
        .routerLink()
        .quoteMarkAccessibility(model, hit)
        .offset(x: rect.midX - w / 2, y: rect.midY - h / 2)
    }
}

extension RouterQuoteTrail where Drawn == Text {
    /// Plain words: drawn as they are laid out.
    init(model: RouterModel, hit: RouterHit, thread: String, words: Text, after: Text? = nil) {
        self.init(model: model, hit: hit, thread: thread, words: words, after: after) { trail in
            trail.map { words + $0 } ?? words
        }
    }
}

extension View {
    /// The mark to VoiceOver: "The agent's words", the quote as its value; its action opens the thread in T3.
    @MainActor fileprivate func quoteMarkAccessibility(_ model: RouterModel, _ hit: RouterHit) -> some View {
        accessibilityLabel("The agent's words")
            .accessibilityValue(RouterQuoteMark.words(model, hit)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

/// Where the text drew the mark (nil: it cut it), told after the draw (a draw can't change the view it draws).
final class RouterQuoteSlotBox {
    var changed: ((CGRect?) -> Void)?
    /// What it last told; `.none` before it told anything (nil, the mark cut, is told too).
    private var last: CGRect?? = .none
    private var pending: CGRect?? = .none

    func listen(_ changed: @escaping (CGRect?) -> Void) {
        self.changed = changed
        if case .some(let rect) = pending { pending = .none; drew(rect) }
    }

    func drew(_ rect: CGRect?) {
        // Not told yet (drawn before the view appeared): kept for when it is.
        guard changed != nil else { pending = .some(rect); return }
        guard last != .some(rect) else { return }
        last = .some(rect)
        DispatchQueue.main.async { [changed] in changed?(rect) }
    }
}

@available(macOS 15, *)
struct RouterQuoteSlot: TextAttribute {}

/// Draws nothing: tells the box where the mark is.
@available(macOS 15, *)
struct RouterQuoteSlotRenderer: TextRenderer {
    let box: RouterQuoteSlotBox

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var slot: CGRect?
        for line in layout {
            for run in line {
                guard run[RouterQuoteSlot.self] != nil else { continue }
                // The glyph's ink: from the run's baseline, the symbol's own height above it (its tail sits on it).
                let b = run.typographicBounds
                let baseline = b.origin.y
                slot = CGRect(x: b.rect.minX, y: baseline - RouterQuoteMark.inkAbove, width: b.width,
                              height: RouterQuoteMark.inkAbove + RouterQuoteMark.inkBelow)
            }
        }
        box.drew(slot)
    }
}

/// The mark's hover: the quote whole, 14 lines tall at most, the rest scrolled to (a fade at an end with more past it).
/// The pointer can move from the mark onto it (`RouterQuoteHold`); its links are clickable.
struct RouterQuotePeek: View {
    let model: RouterModel
    let hit: RouterHit
    let text: String
    /// Scrolled this far down as it opens (a shot's).
    var start: CGFloat = 0
    /// A shot's `start` (`v2-quote-hover-scrolled`); zero in the app.
    static var shotStart: CGFloat = 0
    /// A shot of the mark hot with no hover (`v2-quote-mark-hot`); false in the app.
    static var shotNoPeek = false

    @State private var full: CGFloat = 0
    @State private var cap: CGFloat = 0
    /// How far the words are scrolled: read by the fades only, so a scroll redraws them and nothing else.
    @State private var scroll = RouterQuoteScrolled()

    private static let fade: CGFloat = 28

    var body: some View {
        let d = CDS.Density.compact
        let quoted = RouterItem.quoted(text)
        let words = Text(RouterInline.text(quoted, size: d.body.0)).cdsText(d.body, .regular, CDS.Text.secondary)
        let inner = Router.Peek.width - 2 * Router.Peek.pad - Router.Card.railInset
        let shown = min(full, cap)
        HStack(alignment: .top, spacing: Router.Card.railInset - 1) {
            Rectangle().fill(CDS.Settings.railLine).frame(width: 1, height: shown)
            RouterQuoteScroll(words: words, key: quoted, width: inner, height: full, start: start) { [scroll] in
                if scroll.offset != $0 { scroll.offset = $0 }
            }
                .frame(width: inner, height: shown)
                .mask { RouterQuoteFades(scroll: scroll, more: full - shown, fade: Self.fade) }
                .background(alignment: .topLeading) {
                    // Measured, never drawn: the words whole and their first 14 lines, at the hover's width.
                    ZStack(alignment: .topLeading) {
                        words.fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { full = $0 }
                        words.lineLimit(Router.Card.quoteLines).fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { cap = $0 }
                    }
                    .frame(width: inner, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .allowsHitTesting(false)
                }
        }
        .padding(Router.Peek.pad)
        .frame(width: Router.Peek.width, alignment: .leading)
        .routerFloating(radius: Router.Peek.radius)
        .contentShape(Rectangle())
        .onHover { RouterQuoteHold.over(model, hit, .peek, $0) }
        .onDisappear { RouterQuoteHold.gone(model, hit, .peek) }
    }
}

/// Where the hover's words are scrolled to.
@Observable final class RouterQuoteScrolled {
    var offset: CGFloat = 0
}

/// The hover's fades: at an end only while more is past it, the top once scrolled, the bottom while more is below.
private struct RouterQuoteFades: View {
    let scroll: RouterQuoteScrolled
    let more: CGFloat
    let fade: CGFloat

    var body: some View {
        let offset = scroll.offset
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(offset > 0.5 ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(offset < more - 0.5 ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
        }
    }
}

/// Keeps the mark's hover open while the pointer is on the mark or on the hover, and a short grace between the two: the
/// pointer crosses the gap from one to the other without it closing. It closes `grace` after the pointer has left both.
@MainActor
enum RouterQuoteHold {
    enum Part { case mark, peek }

    static let grace: TimeInterval = 0.18
    private static var hit: RouterHit?
    private static var parts: Set<Part> = []
    private static var close: DispatchWorkItem?

    static func over(_ model: RouterModel, _ hit: RouterHit, _ part: Part, _ inside: Bool) {
        if part == .peek, model.scripted { return }
        if self.hit != hit { self.hit = hit; parts = [] }
        close?.cancel()
        close = nil
        if inside {
            parts.insert(part)
            if model.hoverControl != hit { model.hoverControl = hit }
            return
        }
        parts.remove(part)
        guard parts.isEmpty, model.hoverControl == hit else { return }
        let work = DispatchWorkItem { [weak model] in
            guard parts.isEmpty, let model, model.hoverControl == hit else { return }
            model.hoverControl = nil
        }
        close = work
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }

    /// The hover went without the pointer leaving it (an exit SwiftUI never tells). With the mark gone too (its card
    /// shut), the hover is over: nothing is left for the pointer to be on, so it closes now, and no grace close is left
    /// to fire later.
    static func gone(_ model: RouterModel, _ hit: RouterHit, _ part: Part) {
        guard self.hit == hit else { return }
        parts.remove(part)
        guard parts.isEmpty else { return }
        close?.cancel()
        close = nil
        if model.hoverControl == hit { model.hoverControl = nil }
    }
}

/// The hover's words in an AppKit scroll view of its own: no scroll bar, no rubber band, and a wheel or trackpad scroll
/// over it is spent in it, all of it. `scrollWheel` moves the words and never calls `super` or the next responder, so
/// at either end the scroll stops there: it can't chain to the page's scroll view, momentum included.
struct RouterQuoteScroll<Words: View>: NSViewRepresentable {
    let words: Words
    /// What the words say: the document is laid out again only when it or the size changes, never on a scroll.
    let key: String
    let width: CGFloat
    let height: CGFloat
    var start: CGFloat = 0
    let scrolled: (CGFloat) -> Void

    final class Coordinator {
        var key: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func root() -> AnyView {
        AnyView(words.fixedSize(horizontal: false, vertical: true)
            .frame(width: width, height: height, alignment: .topLeading))
    }

    func makeNSView(context: Context) -> RouterQuoteScrollView {
        let view = RouterQuoteScrollView(frame: .zero)
        let document = NSHostingView(rootView: root())
        document.sizingOptions = []
        view.documentView = document
        view.scrolled = scrolled
        context.coordinator.key = key
        return view
    }

    func updateNSView(_ view: RouterQuoteScrollView, context: Context) {
        view.scrolled = scrolled
        guard let document = view.documentView as? NSHostingView<AnyView> else { return }
        let size = NSSize(width: width, height: height)
        if context.coordinator.key != key || document.frame.size != size {
            context.coordinator.key = key
            document.rootView = root()
        }
        if document.frame.size != size {
            document.frame = NSRect(origin: .zero, size: size)
            view.move(to: view.contentView.bounds.origin.y == 0 && start > 0 ? start : view.contentView.bounds.origin.y)
        }
    }
}

final class RouterQuoteScrollView: NSScrollView {
    var scrolled: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        let clip = FlippedClip()
        clip.drawsBackground = false
        contentView = clip
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The furthest the words scroll: their height past what shows.
    private var end: CGFloat { max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height) }

    func move(to y: CGFloat) {
        let y = min(max(0, y), end)
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
        let tell = scrolled
        DispatchQueue.main.async { tell?(y) }
    }

    override func scrollWheel(with event: NSEvent) {
        // Spent here whatever it is (horizontal, at an end, momentum): never `super`, never the next responder.
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        guard dy != 0 else { return }
        move(to: contentView.bounds.origin.y - dy)
    }

    override func layout() {
        super.layout()
        // The words and the shown height settle after the first layout: clamp to the new end.
        if contentView.bounds.origin.y > end { move(to: end) }
    }

    private final class FlippedClip: NSClipView {
        override var isFlipped: Bool { true }
    }
}

extension RouterModel {
    /// The quote mark the pointer is on, with its quote.
    var quotePeeked: (hit: RouterHit, text: String)? {
        guard !RouterQuotePeek.shotNoPeek, let hit = hoverControl, let text = RouterQuoteMark.words(self, hit) else { return nil }
        return (hit, text)
    }
}

/// The quote's hover placed under the mark's target (`bounds`) when it fits in the room below, over it otherwise (on the
/// side with more room when neither fits); `dx` sideways.
struct RouterQuotePlacement: Layout {
    var dx: CGFloat
    var gap: CGFloat
    var roomBelow: CGFloat
    var roomAbove: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let need = size.height + gap
            let below = need <= roomBelow || (need > roomAbove && roomBelow >= roomAbove)
            let y = below ? bounds.maxY + gap : bounds.minY - gap - size.height
            view.place(at: CGPoint(x: bounds.minX + dx, y: y), proposal: ProposedViewSize(size))
        }
    }
}
