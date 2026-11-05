import AppKit
import QuartzCore
import SwiftUI

/// Fjord's mark, "sun over water" (docs/design/fjord/mark.html): a circle cut by a level horizon, the sun above it and two
/// bands of water below, the second thinner. Its numbers live here once; `scripts/make-icon.swift` and the Icon Composer
/// document's SVGs (Resources/AppIcon.icon) carry the same ones, as neither can read the app's code.
enum FjordMark {
    /// The construction, from the circle's top, in its diameters: the sun to 0.55, then gap 0.072, band 0.2, gap 0.072,
    /// band 0.11 (which the circle cuts off a little early).
    static let split = 0.55, gap = 0.072, bands = [0.2, 0.11]

    /// The parts' spans from the top, in diameters: the sun, band 1, band 2.
    static var spans: [(top: Double, bottom: Double)] {
        var y = split, out = [(top: 0.0, bottom: split)]
        for b in bands { y += gap; out.append((y, min(1, y + b))); y += b }
        return out
    }

    /// The sun, band 1 and band 2 as paths, for the circle that fits `rect` (centred in it), in a space whose y runs up
    /// (AppKit's and Core Animation's own) unless `yDown`.
    static func parts(in rect: CGRect, yDown: Bool = false) -> [CGPath] {
        let d = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        let circle = CGPath(ellipseIn: box, transform: nil)
        return spans.map { span in
            let y = yDown ? box.minY + span.top * d : box.maxY - span.bottom * d
            return circle.intersection(CGPath(rect: CGRect(x: box.minX, y: y, width: d, height: (span.bottom - span.top) * d), transform: nil))
        }
    }
}

// MARK: - Loader

/// The mark as Fjord's loading indicator, always in one colour: the sun, then each band, fades to a faint trace (0.1) one
/// after another from the top, and they come back in the same order, every 2.6 s (mark.html's `level()`). It fills the
/// square that fits its frame. Core Animation moves it, so SwiftUI draws nothing while it runs (see `BlinkingDotView`); it
/// stops when out of a window or hidden, and with Reduce Motion it is the whole mark, still (as mark.html leaves it).
///
/// The colour is a parameter, not the environment's foreground style (which an AppKit view can't read): pass the colour
/// the text beside it uses. Dynamic colours follow light and dark. Read out as `label`.
///
///     FjordLoader(color: CDS.Text.secondary).frame(width: 16, height: 16)
struct FjordLoader: View {
    var color: Color = .primary
    var label: String = "Loading"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FjordLoaderRepresentable(color: NSColor(color), still: reduceMotion)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityElement()
            .accessibilityLabel(label)
    }
}

private struct FjordLoaderRepresentable: NSViewRepresentable {
    let color: NSColor
    let still: Bool

    func makeNSView(context: Context) -> FjordLoaderView { FjordLoaderView() }
    func updateNSView(_ view: FjordLoaderView, context: Context) {
        view.color = color
        view.still = still
    }
}

final class FjordLoaderView: NSView {
    /// mark.html's `level()`: a cycle, each part's turn coming 0.1 of it after the one above, out at 0.04 and back at 0.52 of
    /// it, each fade 0.11 of it long.
    static let period: CFTimeInterval = 2.6
    static let step = 0.1, out = 0.04, back = 0.52, fade = 0.11, trace: Float = 0.1

    var color: NSColor = .labelColor { didSet { if color != oldValue { paint() } } }
    var still = false { didSet { if still != oldValue { animate() } } }
    private let layers = (0..<3).map { _ in CAShapeLayer() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in layers { l.actions = ["path": NSNull(), "fillColor": NSNull(), "opacity": NSNull()]; layer?.addSublayer(l) }
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, path) in zip(layers, FjordMark.parts(in: bounds)) { l.frame = bounds; l.path = path }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }
    override func viewDidHide() { super.viewDidHide(); animate() }
    override func viewDidUnhide() { super.viewDidUnhide(); animate() }

    /// The colour as it reads in this view's look (a dynamic colour resolved again when the look changes).
    private func paint() {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        for l in layers { l.fillColor = cg }
    }

    /// Each part's fade, on the wall clock's phase so every loader on screen moves together; none when it can't be seen.
    private func animate() {
        for l in layers { l.removeAllAnimations(); l.opacity = 1 }
        guard !still, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        // Smoothstep (3x² − 2x³) is exactly this cubic Bézier: control points evenly spaced in time, flat at both ends.
        let smooth = CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1), linear = CAMediaTimingFunction(name: .linear)
        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
        for (i, l) in layers.enumerated() {
            let a = Self.out + Double(i) * Self.step, b = Self.back + Double(i) * Self.step
            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values = [1, 1, Self.trace, Self.trace, 1, 1].map { NSNumber(value: $0) }
            anim.keyTimes = [0, a, a + Self.fade, b, b + Self.fade, 1].map { NSNumber(value: $0) }
            anim.timingFunctions = [linear, smooth, linear, smooth, linear]
            anim.duration = Self.period
            anim.repeatCount = .infinity
            anim.timeOffset = phase
            anim.isRemovedOnCompletion = false
            l.add(anim, forKey: "level")
        }
    }
}
