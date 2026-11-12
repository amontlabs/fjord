import AppKit
import SwiftUI

// Router v2's live feedback (docs/design/router-v2/DESIGN.md 2.2 to 2.4): the sheen over words being reassessed,
// Fjord's mark where the Router's model is at work, the working dots and the caret (Core Animation: SwiftUI draws nothing per frame), the model's words fading in one by one
// (a TextRenderer whose progress is the number of words shown), and the fold a line or a card leaves and arrives with.

// MARK: - Sheen

/// A band of `Transcript.shimmerPeak`, 40% of the view wide, sweeping left to right in 1.4 s, forever. Mask it with the
/// words it passes over. Still under Reduce Motion (the view isn't drawn at all then) and in a shot (one pose).
struct RouterV2Sheen: View {
    /// The band's colour: `shimmerPeak` over words; a skeleton passes its own (`skeleton`).
    var color: NSColor?
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.routerV2Still) private var still

    /// Over a skeleton bar: a light band on the bar's faint ink, in both looks (the words' peak is a dark slug there).
    static let skeleton = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 1, alpha: 0.7)
    }

    var body: some View {
        if !reduce {
            SheenRepresentable(color: color ?? NSColor(CDS.Transcript.shimmerPeak), still: still)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct SheenRepresentable: NSViewRepresentable {
    let color: NSColor
    let still: Bool

    func makeNSView(context: Context) -> RouterV2SheenView { RouterV2SheenView() }
    func updateNSView(_ view: RouterV2SheenView, context: Context) {
        view.color = color
        view.still = still
    }
}

final class RouterV2SheenView: NSView {
    var color: NSColor = .white { didSet { if color != oldValue { paint() } } }
    var still = false { didSet { if still != oldValue { animate() } } }
    private let band = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        band.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(band)
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        band.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }
    override func viewDidHide() { super.viewDidHide(); animate() }
    override func viewDidUnhide() { super.viewDidUnhide(); animate() }

    private func paint() {
        var peak = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { peak = color.cgColor }
        band.colors = [peak.copy(alpha: 0) ?? peak, peak, peak.copy(alpha: 0) ?? peak]
    }

    private func locations(_ x: Double) -> [NSNumber] {
        let w = RouterV2.sheenBand
        return [NSNumber(value: x - w), NSNumber(value: x - w / 2), NSNumber(value: x)]
    }

    private func animate() {
        band.removeAllAnimations()
        band.locations = locations(0.7)
        guard !still, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        // The band's middle goes from the words' start to their end: it is on them for the whole pass.
        sweep.fromValue = locations(RouterV2.sheenBand / 2)
        sweep.toValue = locations(1 + RouterV2.sheenBand / 2)
        sweep.duration = RouterV2.sheenPeriod
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.repeatCount = .infinity
        // On the wall clock's phase: every sheen on the page sweeps together.
        sweep.timeOffset = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: RouterV2.sheenPeriod)
        sweep.isRemovedOnCompletion = false
        band.add(sweep, forKey: "sweep")
    }
}

extension EnvironmentValues {
    /// A still picture (a shot): what loops holds one pose.
    @Entry var routerV2Still = false
}

extension View {
    /// Words being reassessed: muted, a sheen passing over them and nothing else.
    func routerV2Sheen<Mask: View>(@ViewBuilder mask: () -> Mask) -> some View {
        overlay { RouterV2Sheen().mask(alignment: .leading) { mask() } }
    }
}

/// A skeleton bar: where text is about to be.
struct RouterV2SkeletonBar: View {
    let share: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        GeometryReader { proxy in
            shape.fill(CDS.alpha(0.06))
                .frame(width: proxy.size.width * share)
                .overlay { RouterV2Sheen(color: RouterV2Sheen.skeleton).mask { shape } }
        }
        .frame(height: 10)
    }
}

// MARK: - The Router's model at work

/// Fjord's mark as its loader (`FjordLoader`: the sun, then each band of water, fades to a trace and comes back, on Core
/// Animation), wherever the Router's model is at work: reading a draft (the destination row's arrow slot) or a thread
/// (after the words it is about to replace). It starts as the whole mark each time it appears, so it reads as Fjord's
/// from its first frame (on the wall clock's phase it often came in as a trace). The whole mark, still, under Reduce
/// Motion and in a shot.
struct RouterV2Thinking: View {
    var tint: Color = CDS.Text.secondary
    var size: CGFloat = RouterV2.Thinking.line
    var label = "Fjord is reading it"
    @Environment(\.routerV2Still) private var still

    var body: some View {
        FjordLoader(color: tint, label: label, fromStart: true)
            .frame(width: size, height: size)
            .transformEnvironment(\._accessibilityReduceMotion) { if still { $0 = true } }
    }
}

// MARK: - Working dots

/// CDS's working mark as three dots (`Transcript.markDots`), each brightening in turn; still (`ellipsis`) under Reduce
/// Motion, and dim and still when paused.
struct RouterV2WorkingDots: View {
    var tint: Color = CDS.Text.muted
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.routerV2Still) private var still

    var body: some View {
        let dots = CDS.Transcript.markDots
        if reduce {
            Image(systemName: "ellipsis").font(.system(size: RouterV2.Line.mark, weight: .semibold)).foregroundStyle(tint)
        } else {
            DotsRepresentable(color: NSColor(tint), still: still || paused, dim: paused)
                .frame(width: dots.pitch * 2 + dots.size, height: dots.size)
                .accessibilityHidden(true)
        }
    }
}

private struct DotsRepresentable: NSViewRepresentable {
    let color: NSColor
    let still: Bool
    let dim: Bool

    func makeNSView(context: Context) -> RouterV2DotsView { RouterV2DotsView() }
    func updateNSView(_ view: RouterV2DotsView, context: Context) {
        view.color = color
        view.dim = dim
        view.still = still
    }
}

final class RouterV2DotsView: NSView {
    static let period: CFTimeInterval = 1.2

    var color: NSColor = .secondaryLabelColor { didSet { if color != oldValue { paint() } } }
    var still = false { didSet { if still != oldValue { animate() } } }
    var dim = false { didSet { if dim != oldValue { animate() } } }
    private let dots = [CALayer(), CALayer(), CALayer()]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for dot in dots {
            dot.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "opacity": NSNull()]
            layer?.addSublayer(dot)
        }
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let m = CDS.Transcript.markDots
        for (i, dot) in dots.enumerated() {
            dot.frame = NSRect(x: CGFloat(i) * m.pitch, y: bounds.midY - m.size / 2, width: m.size, height: m.size)
            dot.cornerRadius = m.size / 2
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }
    override func viewDidHide() { super.viewDidHide(); animate() }
    override func viewDidUnhide() { super.viewDidUnhide(); animate() }

    private func paint() {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        dots.forEach { $0.backgroundColor = cg }
    }

    private func animate() {
        for (i, dot) in dots.enumerated() {
            dot.removeAllAnimations()
            dot.opacity = dim ? 0.45 : still ? [0.45, 1, 0.7][i] : 1
        }
        guard !still, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
        for (i, dot) in dots.enumerated() {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.3, 1, 0.3, 0.3]
            pulse.keyTimes = [0, 0.3, 0.6, 1]
            pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
                                     CAMediaTimingFunction(name: .linear)]
            pulse.duration = Self.period
            pulse.repeatCount = .infinity
            // Each dot a beat after the one before, all on the wall clock's phase.
            pulse.timeOffset = (phase - Double(i) * 0.18 + Self.period).truncatingRemainder(dividingBy: Self.period)
            pulse.isRemovedOnCompletion = false
            dot.add(pulse, forKey: "pulse")
        }
    }
}

// MARK: - Caret

/// A text caret that blinks (Core Animation), for the composer while the demo's script types in it.
struct RouterV2Caret: View {
    var color: Color = CDS.Text.primary
    var height: CGFloat = 17
    @Environment(\.routerV2Still) private var still

    var body: some View {
        CaretRepresentable(color: NSColor(color), still: still).frame(width: 1.5, height: height).accessibilityHidden(true)
    }
}

private struct CaretRepresentable: NSViewRepresentable {
    let color: NSColor
    let still: Bool

    func makeNSView(context: Context) -> RouterV2CaretView { RouterV2CaretView() }
    func updateNSView(_ view: RouterV2CaretView, context: Context) {
        view.color = color
        view.still = still
    }
}

final class RouterV2CaretView: NSView {
    var color: NSColor = .labelColor { didSet { if color != oldValue { paint() } } }
    var still = false { didSet { if still != oldValue { animate() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 0.75
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }

    private func paint() {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        layer?.backgroundColor = cg
    }

    private func animate() {
        layer?.removeAllAnimations()
        guard !still, window != nil else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.5, 1]
        blink.calculationMode = .discrete
        blink.duration = 1.06
        blink.repeatCount = .infinity
        blink.isRemovedOnCompletion = false
        layer?.add(blink, forKey: "blink")
    }
}

/// The 2 × 14 caret after an agent's last word, as a glyph in the text so it wraps with it.
enum RouterV2TextCaret {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 2, height: 14), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Joined to the last word by a no-break space: the caret never wraps onto a line of its own.
    static var text: Text {
        Text("\u{00A0}") + Text(Image(nsImage: image)).foregroundColor(CDS.Text.muted).baselineOffset(-2)
    }
}

// MARK: - Words streaming

/// A line's words and what is drawn among them: a PR's link and, after it, its state word (the code's, from the board).
struct RouterV2Words: Equatable {
    enum Kind: Equatable { case word, link, state(RouterV2Thread.PR.State) }
    struct Part: Equatable {
        var text: String
        var kind: Kind
        /// Its turn as the words arrive (a link and its state word share one).
        var index: Int
    }

    var parts: [Part]
    var count: Int

    /// `text` cut in words (each with the space after it); the first PR of `prs` it names ("PR #41") becomes a link with
    /// its state word after it when `stateWord`.
    init(_ text: String, prs: [RouterV2Thread.PR] = [], stateWord: Bool = true) {
        var parts: [Part] = []
        var index = 0
        func words(_ s: Substring) {
            var current = ""
            for ch in s {
                if ch == " ", !current.isEmpty, current.last != " " {
                    current.append(ch)
                    parts.append(Part(text: current, kind: .word, index: index))
                    index += 1
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            if !current.isEmpty { parts.append(Part(text: current, kind: .word, index: index)); index += 1 }
        }
        if let pr = prs.first(where: { text.contains("PR #\($0.number)") }), let range = text.range(of: "PR #\(pr.number)") {
            words(text[..<range.lowerBound])
            parts.append(Part(text: String(text[range]), kind: .link, index: index))
            if stateWord { parts.append(Part(text: pr.state.rawValue, kind: .state(pr.state), index: index)) }
            index += 1
            words(text[range.upperBound...])
        } else {
            words(text[...])
        }
        self.parts = parts
        count = index
    }
}

enum RouterV2PRTint {
    static func text(_ s: RouterV2Thread.PR.State) -> Color {
        switch s {
        case .open: CDS.BadgeTint.successText
        case .merged: CDS.BadgeTint.violetText
        case .closed: CDS.Text.danger
        }
    }

    static func fill(_ s: RouterV2Thread.PR.State) -> Color {
        switch s {
        case .open: CDS.BadgeTint.successFill
        case .merged: CDS.BadgeTint.violetFill
        case .closed: CDS.BadgeTint.dangerFill
        }
    }
}

/// A word's turn, carried by its run of text to the renderer: when it starts to fade in, in words' time.
@available(macOS 15, *)
struct RouterV2WordTurn: TextAttribute {
    let index: Double
}

/// The run that pops (a PR's state word as it flips).
@available(macOS 15, *)
struct RouterV2PopRun: TextAttribute {}

/// Draws a line's words as far as they have arrived: word `i` fades in over `fade` words' time from `shown == i`, with no
/// movement; the popped run is drawn at `pop` times its size.
@available(macOS 15, *)
struct RouterV2WordRenderer: TextRenderer {
    var shown: Double
    var pop: CGFloat
    /// How many words' time one word's fade lasts.
    static let fade = RouterV2.wordFade / RouterV2.wordEvery

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(shown, pop) }
        set { shown = newValue.first; pop = newValue.second }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                var copy = context
                if let turn = run[RouterV2WordTurn.self] {
                    let t = min(1, max(0, (shown - turn.index) / Self.fade))
                    // Ease-out.
                    copy.opacity = 1 - (1 - t) * (1 - t)
                }
                if pop != 1, run[RouterV2PopRun.self] != nil {
                    let box = run.typographicBounds.rect
                    copy.translateBy(x: box.midX, y: box.midY)
                    copy.scaleBy(x: pop, y: pop)
                    copy.translateBy(x: -box.midX, y: -box.midY)
                }
                copy.draw(run)
            }
        }
    }
}

/// A line's sentence as text: its words in `tint`, a PR's link in the accent, its state word in footnote in the state's
/// colour. `attributed`: each run carries its turn for the renderer (`turn`: a word's own, its index unless it arrived
/// later than its index's time).
enum RouterV2SentenceText {
    static func text(_ words: RouterV2Words, tint: Color, mono: Bool, attributed: Bool, turn: (Int) -> Double = { Double($0) }) -> Text {
        var out = Text("")
        for part in words.parts {
            var piece: Text
            switch part.kind {
            case .word:
                piece = Text(part.text).foregroundColor(tint)
            case .link:
                piece = Text(part.text).font(CDS.sans(14, .medium)).foregroundColor(CDS.Text.accent)
                    .underline(color: CDS.Text.accent.opacity(0.4))
            case .state(let state):
                // A word space at the sentence's size, then the state in footnote.
                out = out + Text(" ").font(CDS.sans(14))
                piece = Text(part.text).font(CDS.sans(12)).foregroundColor(RouterV2PRTint.text(state))
            }
            if attributed, #available(macOS 15, *) {
                piece = piece.customAttribute(RouterV2WordTurn(index: turn(part.index)))
                if case .state = part.kind { piece = piece.customAttribute(RouterV2PopRun()) }
            }
            out = out + piece
        }
        return out.font(mono ? CDS.mono(12) : CDS.sans(14))
    }
}

/// The model's words arriving: on appearing as a line that just landed, they fade in one by one, one every 50 ms; a line
/// already there is drawn whole. Words that keep coming (`.words` of the same stream, growing) are the same view: the
/// ones that arrived fade in from where the stream is, in turn if it is ahead of them, together (0.12 s) if they came
/// after their time. The PR's state word pops when it flips. Under Reduce Motion (and before macOS 15) the whole line
/// is there at once; the row fades it.
struct RouterV2StreamedText: View {
    let words: RouterV2Words
    let tint: Color
    var mono = false
    /// The words just landed: they stream.
    let arriving: Bool
    /// No more words are coming for this line: `done` once they are all drawn.
    var complete = true
    /// The PR's state, to pop its word when it changes.
    var prState: RouterV2Thread.PR.State?
    var done: () -> Void = {}

    /// The stream's clock, in words' time: word `i` starts to fade in at `max(i, the clock when it arrived)`.
    @State private var shown: Double
    /// The clock's current stretch: from `start`, at `began`, to `shown`, one word every `RouterV2.wordEvery`.
    @State private var start: Double = 0
    @State private var began = Date.distantPast
    /// Each later batch of words: its first word's index and the clock when it came.
    @State private var batches: [Batch] = []
    @State private var stretch = 0
    @State private var pop: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.routerV2Still) private var still

    private struct Batch: Equatable {
        var from: Int
        var at: Double
    }

    static let all: Double = 100_000

    init(words: RouterV2Words, tint: Color, mono: Bool = false, arriving: Bool, complete: Bool = true,
         prState: RouterV2Thread.PR.State? = nil, done: @escaping () -> Void = {}) {
        self.words = words
        self.tint = tint
        self.mono = mono
        self.arriving = arriving
        self.complete = complete
        self.prState = prState
        self.done = done
        _shown = State(initialValue: arriving ? 0 : Self.all)
    }

    var body: some View {
        if #available(macOS 15, *), !reduce {
            // Laid out from the words alone; the words as drawn (their renderer animating every frame while they stream)
            // sit over that place, so a frame of the stream measures this text only, not the page around it.
            RouterV2SentenceText.text(words, tint: tint, mono: mono, attributed: false)
                .hidden()
                .overlay(alignment: .leading) {
                    RouterV2SentenceText.text(words, tint: tint, mono: mono, attributed: true, turn: turn)
                        .textRenderer(RouterV2WordRenderer(shown: still ? Self.all : shown, pop: pop))
                        // The words change in one frame (a PR's state word flips, a line mutes): never two strings at once.
                        .contentTransition(.identity)
                }
                .onAppear { stream() }
                .onChange(of: words.count) { old, new in if new > old { grow(from: old) } }
                .onChange(of: complete) { _, complete in if complete { finish() } }
                .onChange(of: prState) { _, new in
                    guard new != nil, !still else { return }
                    pop = RouterV2.prPopScale
                    let spring = RouterV2.prPop.resolved(reduce: reduce)
                    DispatchQueue.main.async { withAnimation(spring) { pop = 1 } }
                }
        } else {
            RouterV2SentenceText.text(words, tint: tint, mono: mono, attributed: false)
                .onAppear { if arriving, complete { done() } }
                .onChange(of: complete) { _, complete in if complete, arriving { done() } }
        }
    }

    /// Word `i`'s turn: its index, or the clock when it came if that was later.
    private func turn(_ i: Int) -> Double {
        guard let batch = batches.last(where: { $0.from <= i }) else { return Double(i) }
        return max(Double(i), batch.at)
    }

    /// Where the clock is drawn now.
    private var presented: Double {
        guard shown < Self.all else { return Self.all }
        let ran = Date().timeIntervalSince(began) / RouterV2.wordEvery
        return min(shown, start + max(0, ran))
    }

    /// The clock's end: a word's time after the last word's turn, and its fade.
    private var target: Double {
        guard words.count > 0 else { return RouterV2.wordFade / RouterV2.wordEvery }
        return turn(words.count - 1) + 1 + RouterV2.wordFade / RouterV2.wordEvery
    }

    private func stream() {
        guard arriving, shown < Self.all else { return }
        guard !still else { if complete { done() }; return }
        // As the code line goes, at the rate the words arrive.
        run(to: target, lead: RouterV2.streamLead)
    }

    /// More words of the same stream: they start where the clock is.
    private func grow(from count: Int) {
        guard arriving, !still, shown < Self.all else { return }
        let now = presented
        batches.append(Batch(from: count, at: now))
        run(to: target, from: now, lead: 0)
    }

    /// The last words are in: once drawn, it is done.
    private func finish() {
        guard arriving, !still else { done(); return }
        guard shown < Self.all else { return }
        let now = presented
        if now >= shown {
            shown = Self.all
            done()
        } else {
            run(to: shown, from: now, lead: 0)
        }
    }

    /// Runs the clock from `from` to `to`, one word every `wordEvery`; at its end, if no later stretch began and no more
    /// words are coming, every word is drawn whole and the line is done.
    private func run(to: Double, from: Double? = nil, lead: Double) {
        let from = from ?? shown
        stretch += 1
        let mine = stretch
        start = from
        began = Date().addingTimeInterval(lead)
        let duration = max(0, to - from) * RouterV2.wordEvery
        withAnimation(Animation.linear(duration: duration).delay(lead).resolved(reduce: reduce), completionCriteria: .logicallyComplete) {
            // A stretch that ends where the last one did still runs to its end, so its completion waits for the words.
            shown = to == shown ? to.nextUp : to
        } completion: {
            guard stretch == mine, complete else { return }
            shown = Self.all
            done()
        }
    }
}

// MARK: - Fold

/// A line or a card arriving or leaving: its height from 0 and a fade (the neighbours slide on the same curve, so the
/// two read as one fold). A plain fade under Reduce Motion.
private struct RouterV2Fold: ViewModifier, Animatable {
    var open: CGFloat

    var animatableData: CGFloat {
        get { open }
        set { open = newValue }
    }

    func body(content: Content) -> some View {
        content
            .mask(alignment: .top) { Rectangle().scaleEffect(x: 1, y: max(0.0001, open), anchor: .top).padding(.horizontal, -40) }
            // Seen only in the last third of the fold: a row never shows over its neighbours' words on the way.
            .opacity(Double(min(1, max(0, (open - 0.65) / 0.35))))
    }
}

extension AnyTransition {
    static func routerV2Fold(reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .modifier(active: RouterV2Fold(open: 0), identity: RouterV2Fold(open: 1))
    }

    /// One text taking another's place: the old one out in 0.06 s, then the new one in over 0.12 s, so two strings are
    /// never read on top of each other. Fades only: the same under Reduce Motion.
    static var routerV2Swap: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: RouterV2.swapIn).delay(RouterV2.swapOut)),
                    removal: .opacity.animation(.easeOut(duration: RouterV2.swapOut)))
    }

    /// The old text out as `routerV2Swap` does; the new one there at once (its own words fade in as they stream).
    static var routerV2SwapOut: AnyTransition {
        .asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: RouterV2.swapOut)))
    }
}

// MARK: - Shake

/// The failure line's entrance: 6 pt sideways, 2 cycles, 0.3 s.
struct RouterV2Shake: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = RouterV2.shake.distance * sin(progress * .pi * 2 * RouterV2.shake.cycles) * (1 - progress)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}
