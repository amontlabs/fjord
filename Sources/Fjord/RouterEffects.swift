import AppKit
import SwiftUI

// Router v2's live feedback (docs/design/router-v2/DESIGN.md 2.2 to 2.4): the sheen over words being reassessed,
// Fjord's mark where the Router's model is at work, the working dots and the caret (Core Animation: SwiftUI draws nothing per frame), the model's words fading in one by one
// (a TextRenderer whose progress is the number of words shown), and the fold a line or a card leaves and arrives with.

// MARK: - Sheen

/// A band of `Transcript.shimmerPeak`, 40% of the view wide, sweeping left to right in 1.4 s, forever. Mask it with the
/// words it passes over. Still under Reduce Motion (the view isn't drawn at all then) and in a shot (one pose).
struct RouterSheen: View {
    /// The band's colour: `shimmerPeak` over words; a skeleton passes its own (`skeleton`).
    var color: NSColor?
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.routerStill) private var still

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

    func makeNSView(context: Context) -> RouterSheenView { RouterSheenView() }
    func updateNSView(_ view: RouterSheenView, context: Context) {
        view.color = color
        view.still = still
    }
}

final class RouterSheenView: NSView {
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
        let w = Router.sheenBand
        return [NSNumber(value: x - w), NSNumber(value: x - w / 2), NSNumber(value: x)]
    }

    private func animate() {
        band.removeAllAnimations()
        band.locations = locations(0.7)
        guard !still, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        // The band's middle goes from the words' start to their end: it is on them for the whole pass.
        sweep.fromValue = locations(Router.sheenBand / 2)
        sweep.toValue = locations(1 + Router.sheenBand / 2)
        sweep.duration = Router.sheenPeriod
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.repeatCount = .infinity
        // On the wall clock's phase: every sheen on the page sweeps together.
        sweep.timeOffset = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Router.sheenPeriod)
        sweep.isRemovedOnCompletion = false
        band.add(sweep, forKey: "sweep")
    }
}

extension EnvironmentValues {
    /// A still picture (a shot): what loops holds one pose.
    @Entry var routerStill = false
}

extension View {
    /// Words being reassessed: muted, a sheen passing over them and nothing else.
    func routerSheen<Mask: View>(@ViewBuilder mask: () -> Mask) -> some View {
        overlay { RouterSheen().mask(alignment: .leading) { mask() } }
    }
}

/// A skeleton bar: where text is about to be.
struct RouterSkeletonBar: View {
    let share: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        GeometryReader { proxy in
            shape.fill(CDS.alpha(0.06))
                .frame(width: proxy.size.width * share)
                .overlay { RouterSheen(color: RouterSheen.skeleton).mask { shape } }
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
struct RouterThinking: View {
    var tint: Color = CDS.Text.secondary
    var size: CGFloat = Router.Thinking.line
    var label = "Fjord is reading it"
    @Environment(\.routerStill) private var still

    var body: some View {
        FjordLoader(color: tint, label: label, fromStart: true)
            .frame(width: size, height: size)
            .transformEnvironment(\._accessibilityReduceMotion) { if still { $0 = true } }
    }
}

// MARK: - Working dots

/// CDS's working mark as three dots (`Transcript.markDots`), each brightening in turn; still (`ellipsis`) under Reduce
/// Motion, and dim and still when paused.
struct RouterWorkingDots: View {
    var tint: Color = CDS.Text.muted
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.routerStill) private var still

    var body: some View {
        let dots = CDS.Transcript.markDots
        if reduce {
            Image(systemName: "ellipsis").font(.system(size: Router.Line.mark, weight: .semibold)).foregroundStyle(tint)
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

    func makeNSView(context: Context) -> RouterDotsView { RouterDotsView() }
    func updateNSView(_ view: RouterDotsView, context: Context) {
        view.color = color
        view.dim = dim
        view.still = still
    }
}

final class RouterDotsView: NSView {
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
struct RouterCaret: View {
    var color: Color = CDS.Text.primary
    var height: CGFloat = 17
    @Environment(\.routerStill) private var still

    var body: some View {
        CaretRepresentable(color: NSColor(color), still: still).frame(width: 1.5, height: height).accessibilityHidden(true)
    }
}

private struct CaretRepresentable: NSViewRepresentable {
    let color: NSColor
    let still: Bool

    func makeNSView(context: Context) -> RouterCaretView { RouterCaretView() }
    func updateNSView(_ view: RouterCaretView, context: Context) {
        view.color = color
        view.still = still
    }
}

final class RouterCaretView: NSView {
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
enum RouterTextCaret {
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
struct RouterWords: Equatable {
    enum Kind: Equatable { case word, link, state(RouterThread.PR.State) }
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
    init(_ text: String, prs: [RouterThread.PR] = [], stateWord: Bool = true) {
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

enum RouterPRTint {
    static func text(_ s: RouterThread.PR.State) -> Color {
        switch s {
        case .open: CDS.BadgeTint.successText
        case .merged: CDS.BadgeTint.violetText
        case .closed: CDS.Text.danger
        }
    }

    static func fill(_ s: RouterThread.PR.State) -> Color {
        switch s {
        case .open: CDS.BadgeTint.successFill
        case .merged: CDS.BadgeTint.violetFill
        case .closed: CDS.BadgeTint.dangerFill
        }
    }
}

/// A word's turn, carried by its run of text to the renderer: when it starts to fade in, in words' time.
@available(macOS 15, *)
struct RouterWordTurn: TextAttribute {
    let index: Double
    /// The word's own index in the line.
    var word = 0
}

/// The run that pops (a PR's state word as it flips).
@available(macOS 15, *)
struct RouterPopRun: TextAttribute {}

/// Draws a line's words as far as they have arrived: word `i` fades in over `fade` words' time from `shown == i`, with no
/// movement; the popped run is drawn at `pop` times its size.
@available(macOS 15, *)
struct RouterWordRenderer: TextRenderer {
    var shown: Double
    var pop: CGFloat
    /// Told where each word is drawn (inside `RouterFadingWords`).
    var places: RouterWordPlaces?
    /// How many words' time one word's fade lasts.
    static let fade = Router.wordFade / Router.wordEvery

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(shown, pop) }
        set { shown = newValue.first; pop = newValue.second }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        if let places {
            var rects: [Int: CGRect] = [:]
            for line in layout {
                for run in line {
                    guard let word = run[RouterWordTurn.self]?.word else { continue }
                    let rect = run.typographicBounds.rect
                    rects[word] = rects[word].map { $0.union(rect) } ?? rect
                }
            }
            places.drew(rects)
        }
        for line in layout {
            for run in line {
                var copy = context
                if let turn = run[RouterWordTurn.self] {
                    let t = min(1, max(0, (shown - turn.index) / Self.fade))
                    // Ease-out.
                    copy.opacity = 1 - (1 - t) * (1 - t)
                }
                if pop != 1, run[RouterPopRun.self] != nil {
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
enum RouterSentenceText {
    static func text(_ words: RouterWords, tint: Color, mono: Bool, attributed: Bool, turn: (Int) -> Double = { Double($0) }) -> Text {
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
                piece = Text(part.text).font(CDS.sans(12)).foregroundColor(RouterPRTint.text(state))
            }
            if attributed, #available(macOS 15, *) {
                piece = piece.customAttribute(RouterWordTurn(index: turn(part.index), word: part.index))
                if case .state = part.kind { piece = piece.customAttribute(RouterPopRun()) }
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
///
/// While they stream, the words are drawn whole in a hosting view of their own and Core Animation fades each one in
/// (`RouterFadingWords`): nothing in SwiftUI runs per frame, only once per word that arrives.
struct RouterStreamedText: View {
    let words: RouterWords
    let tint: Color
    var mono = false
    /// The words just landed: they stream.
    let arriving: Bool
    /// No more words are coming for this line: `done` once they are all drawn.
    var complete = true
    /// The PR's state, to pop its word when it changes.
    var prState: RouterThread.PR.State?
    var done: () -> Void = {}

    /// The stream's clock, in words' time: word `i` starts to fade in at `max(i, the clock when it arrived)`. `shown` is
    /// where the current stretch ends (`all`: every word drawn whole).
    @State private var shown: Double
    /// The clock's current stretch: from `start`, at `began`, to `shown`, one word every `Router.wordEvery`.
    @State private var start: Double = 0
    @State private var began = Date.distantPast
    /// Each later batch of words: its first word's index and the clock when it came.
    @State private var batches: [Batch] = []
    @State private var stretch = 0
    @State private var pop: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.routerStill) private var still
    @Environment(\.colorScheme) private var scheme

    private struct Batch: Equatable {
        var from: Int
        var at: Double
    }

    static let all: Double = 100_000

    init(words: RouterWords, tint: Color, mono: Bool = false, arriving: Bool, complete: Bool = true,
         prState: RouterThread.PR.State? = nil, done: @escaping () -> Void = {}) {
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
            // Laid out from the words alone; the words as drawn sit over that place, so a word that fades in measures
            // nothing.
            RouterSentenceText.text(words, tint: tint, mono: mono, attributed: false)
                .hidden()
                .overlay(alignment: .leading) {
                    if !still, shown < Self.all {
                        RouterFadingWords(text: RouterSentenceText.text(words, tint: tint, mono: mono, attributed: true, turn: turn),
                                            pop: pop, scheme: scheme, plan: plan) { ended($0) }
                    } else {
                        drawn()
                    }
                }
                .onAppear { stream() }
                .onChange(of: words.count) { old, new in if new > old { grow(from: old) } }
                .onChange(of: complete) { _, complete in if complete { finish() } }
                .onChange(of: prState) { _, new in
                    guard new != nil, !still else { return }
                    pop = Router.prPopScale
                    let spring = Router.prPop.resolved(reduce: reduce)
                    DispatchQueue.main.async { withAnimation(spring) { pop = 1 } }
                }
        } else {
            RouterSentenceText.text(words, tint: tint, mono: mono, attributed: false)
                .onAppear { if arriving, complete { done() } }
                .onChange(of: complete) { _, complete in if complete, arriving { done() } }
        }
    }

    /// The words that have arrived, drawn whole.
    @available(macOS 15, *)
    private func drawn() -> some View {
        RouterSentenceText.text(words, tint: tint, mono: mono, attributed: true, turn: turn)
            .textRenderer(RouterWordRenderer(shown: Self.all, pop: pop))
            // The words change in one frame (a PR's state word flips, a line mutes): never two strings at once.
            .contentTransition(.identity)
    }

    /// The fades as they stand: when each word's turn comes on the wall clock, and when the stretch ends.
    private var plan: RouterFadePlan {
        let turns = (0..<words.count).map(turn)
        return .init(turns: turns, start: start, began: began, end: began.addingTimeInterval(max(0, shown - start) * Router.wordEvery),
                     stretch: stretch)
    }

    /// Word `i`'s turn: its index, or the clock when it came if that was later.
    private func turn(_ i: Int) -> Double {
        guard let batch = batches.last(where: { $0.from <= i }) else { return Double(i) }
        return max(Double(i), batch.at)
    }

    /// Where the clock is drawn now.
    private var presented: Double {
        guard shown < Self.all else { return Self.all }
        let ran = Date().timeIntervalSince(began) / Router.wordEvery
        return min(shown, start + max(0, ran))
    }

    /// The clock's end: a word's time after the last word's turn, and its fade.
    private var target: Double {
        guard words.count > 0 else { return Router.wordFade / Router.wordEvery }
        return turn(words.count - 1) + 1 + Router.wordFade / Router.wordEvery
    }

    private func stream() {
        guard arriving, shown < Self.all else { return }
        guard !still else { if complete { done() }; return }
        // As the code line goes, at the rate the words arrive.
        run(to: target, lead: Router.streamLead)
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

    /// Runs the clock from `from` to `to`, one word every `wordEvery`; at its end (`ended`), if no later stretch began
    /// and no more words are coming, every word is drawn whole and the line is done.
    private func run(to: Double, from: Double? = nil, lead: Double) {
        let from = from ?? shown
        stretch += 1
        start = from
        began = Date().addingTimeInterval(lead)
        shown = to
    }

    /// A stretch's end, from its fades.
    private func ended(_ which: Int) {
        guard which == stretch, complete, shown < Self.all else { return }
        shown = Self.all
        done()
    }
}

/// A streaming line's words, drawn whole in a hosting view of their own and faded in one by one by Core Animation: a mask
/// over that view's layer has a tile per word (from its start to the next word's), each tile's opacity rising from 0 at
/// the word's turn over `Router.wordFade` on the renderer's curve (1 - (1 - t)^2). The words' places come from the
/// renderer as it draws them (`RouterWordPlaces`), in the same frame, so a word never shows before its tile is there.
/// The stretch's end is a Core Animation clock too (`ended`), so nothing waits on a timer.
@available(macOS 15, *)
struct RouterFadingWords: NSViewRepresentable {
    typealias Plan = RouterFadePlan

    let text: Text
    let pop: CGFloat
    let scheme: ColorScheme
    let plan: Plan
    let ended: (Int) -> Void

    func makeCoordinator() -> RouterWordFades { RouterWordFades() }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: root(context.coordinator))
        view.sizingOptions = []
        view.safeAreaRegions = []
        view.wantsLayer = true
        context.coordinator.view = view
        context.coordinator.ended = ended
        context.coordinator.take(plan)
        return view
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        context.coordinator.ended = ended
        view.rootView = root(context.coordinator)
        context.coordinator.take(plan)
    }

    static func dismantleNSView(_ view: NSHostingView<AnyView>, coordinator: RouterWordFades) {
        coordinator.stop()
    }

    private func root(_ fades: RouterWordFades) -> AnyView {
        AnyView(text
            .textRenderer(RouterWordRenderer(shown: RouterStreamedText.all, pop: pop, places: fades.places))
            .contentTransition(.identity)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .environment(\.colorScheme, scheme))
    }
}

/// A streaming line's fades as they stand.
struct RouterFadePlan: Equatable {
    /// Each word's turn, in words' time.
    var turns: [Double]
    /// The current stretch: the clock is at `start` at `began` and moves a word every `Router.wordEvery`; it ends at
    /// `end`.
    var start: Double
    var began: Date
    var end: Date
    var stretch: Int
}

/// Where each word was drawn (its runs' union, by word index), told by the renderer as it draws.
final class RouterWordPlaces {
    var changed: (([Int: CGRect]) -> Void)?
    private var last: [Int: CGRect] = [:]

    func drew(_ rects: [Int: CGRect]) {
        guard rects != last else { return }
        last = rects
        changed?(rects)
    }
}

/// The fades' layers: the mask and its tiles, the start of each word's fade, the stretch's clock.
@MainActor
final class RouterWordFades: NSObject, CAAnimationDelegate {
    weak var view: NSView?
    var ended: (Int) -> Void = { _ in }
    let places = RouterWordPlaces()

    private let mask = CALayer()
    private var tiles: [Int: CALayer] = [:]
    /// Each word's fade's start, in media time, once known: a word's start never moves.
    private var starts: [Int: CFTimeInterval] = [:]
    private var rects: [Int: CGRect] = [:]
    private var plan: RouterFadePlan?
    private static let clockKey = "fjord.clock"

    override init() {
        super.init()
        places.changed = { [weak self] rects in
            MainActor.assumeIsolated { self?.laid(rects) }
        }
    }

    /// The renderer's own curve, 1 - (1 - t)^2, as a cubic Bézier (exact: x(t) = t).
    private static let curve = CAMediaTimingFunction(controlPoints: 1.0 / 3, 2.0 / 3, 2.0 / 3, 1)

    func take(_ plan: RouterFadePlan) {
        guard plan != self.plan else { return }
        let stretchChanged = plan.stretch != self.plan?.stretch || plan.end != self.plan?.end
        self.plan = plan
        let now = CACurrentMediaTime(), date = Date()
        // Before the first stretch begins (the line just appeared) no word has a turn on the clock yet: hidden.
        for (i, turn) in plan.turns.enumerated() where starts[i] == nil && plan.stretch > 0 {
            let at = plan.began.addingTimeInterval((turn - plan.start) * Router.wordEvery)
            starts[i] = now + at.timeIntervalSince(date)
        }
        layTiles()
        if stretchChanged { clock(until: now + plan.end.timeIntervalSince(date), stretch: plan.stretch) }
    }

    func stop() {
        mask.removeAllAnimations()
        view?.layer?.mask = nil
    }

    private func laid(_ rects: [Int: CGRect]) {
        self.rects = rects
        layTiles()
    }

    /// One tile per word, from its start to the next word's, the layer's whole height; the first from the layer's start.
    /// Past the last word's end nothing shows: a word drawn before its place is known stays hidden.
    private func layTiles() {
        guard let layer = view?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if layer.mask !== mask {
            mask.frame = layer.bounds
            layer.mask = mask
        }
        mask.frame = layer.bounds
        let order = rects.keys.sorted { rects[$0]!.minX < rects[$1]!.minX }
        let now = CACurrentMediaTime()
        let height = layer.bounds.height
        for (n, i) in order.enumerated() {
            let rect = rects[i]!
            let minX = n == 0 ? -1000 : rect.minX
            let maxX = n + 1 < order.count ? rects[order[n + 1]]!.minX : rect.maxX + 4
            let tile: CALayer
            if let old = tiles[i] {
                tile = old
            } else {
                tile = CALayer()
                tile.backgroundColor = NSColor.black.cgColor
                tile.opacity = 0
                mask.addSublayer(tile)
                tiles[i] = tile
            }
            // Its turn known: it fades in from it (once).
            if tile.opacity == 0, let start = starts[i] {
                tile.opacity = 1
                if start + Router.wordFade > now {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.beginTime = start
                    fade.duration = Router.wordFade
                    fade.timingFunction = Self.curve
                    fade.fillMode = .backwards
                    tile.add(fade, forKey: "fade")
                }
            }
            tile.frame = CGRect(x: minX, y: -height, width: maxX - minX, height: 3 * height)
        }
        for (i, tile) in tiles where rects[i] == nil {
            tile.removeFromSuperlayer()
            tiles[i] = nil
        }
    }

    /// The stretch's end as an animation of the mask's own: its stop says the words are drawn.
    private func clock(until end: CFTimeInterval, stretch: Int) {
        mask.removeAnimation(forKey: Self.clockKey)
        let clock = CABasicAnimation(keyPath: "fjordClock")
        clock.fromValue = 0
        clock.toValue = 1
        clock.beginTime = CACurrentMediaTime()
        clock.duration = max(0.001, end - CACurrentMediaTime())
        clock.delegate = self
        clock.setValue(stretch, forKey: "stretch")
        mask.add(clock, forKey: Self.clockKey)
    }

    nonisolated func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard finished, let stretch = animation.value(forKey: "stretch") as? Int else { return }
        MainActor.assumeIsolated { ended(stretch) }
    }
}

// MARK: - Fold

/// A line or a card arriving or leaving: its height from 0 and a fade (the neighbours slide on the same curve, so the
/// two read as one fold). A plain fade under Reduce Motion.
private struct RouterFold: ViewModifier, Animatable {
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
    static func routerFold(reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .modifier(active: RouterFold(open: 0), identity: RouterFold(open: 1))
    }

    /// One text taking another's place: the old one out in 0.06 s, then the new one in over 0.12 s, so two strings are
    /// never read on top of each other. Fades only: the same under Reduce Motion.
    static var routerSwap: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: Router.swapIn).delay(Router.swapOut)),
                    removal: .opacity.animation(.easeOut(duration: Router.swapOut)))
    }

    /// The old text out as `routerSwap` does; the new one there at once (its own words fade in as they stream).
    static var routerSwapOut: AnyTransition {
        .asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: Router.swapOut)))
    }
}

// MARK: - Shake

/// The failure line's entrance: 6 pt sideways, 2 cycles, 0.3 s.
struct RouterShake: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = Router.shake.distance * sin(progress * .pi * 2 * Router.shake.cycles) * (1 - progress)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}
