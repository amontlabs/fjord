import AppKit
import SwiftUI

// Ticks on Core Animation (docs/design/router-v2/WAVE2-NOTES.md, "Layout performance, part 2"): a line's age, a count, a
// state's mark. With SwiftUI's `numericText` and symbol replace, each tick redrew its text on the CPU every frame of its
// half-second spring, inside the line's or the header's hosting view (~17 % of the main thread under the load's moves).
// Here what ticks is drawn by SwiftUI in a small hosting view of its own, once per change; the roll itself is Core
// Animation moving two pictures of it (before and after): the characters that changed go out and come in, sliced by
// their places in the text, the rest stays. At rest the hosting view draws as before. The picture before is the one
// kept from the last tick (or, for a mark, taken once the page is still), so the change's own turn rarely draws one.

/// How a tick changes.
enum RouterV2TickStyle: Equatable {
    /// `numericText`: the characters that changed roll (out up and in from below as the value grows or isn't a number,
    /// the other way as it shrinks), the others stay. `font` places the characters.
    case numeric(font: NSFont)
    /// A state's mark: the old one goes small and out as the new one grows in (`symbolEffect(.replace.downUp)`); a
    /// crossfade when either side is no symbol (a key starting with `~`).
    case replace
}

/// `content` drawn in a hosting view of its own; when `key` changes, it ticks on Core Animation.
struct RouterV2Tick<Content: View>: NSViewRepresentable {
    let key: String
    let style: RouterV2TickStyle
    /// Numeric ticks animate on every change (`.animation(counts, value:)`); a mark only when the change is animated.
    var always = true
    /// What its content shows besides `key` (a tint, a paused mark): with the key, what its kept picture is of.
    var look = ""
    @ViewBuilder let content: () -> Content

    final class Coordinator {
        var controller: NSHostingController<AnyView>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RouterV2TickView {
        let controller = NSHostingController(rootView: root(context))
        controller.sizingOptions = []
        context.coordinator.controller = controller
        let host = controller.view as! NSHostingView<AnyView>
        host.sizingOptions = []
        host.safeAreaRegions = []
        return RouterV2TickView(host: host, key: key)
    }

    func updateNSView(_ view: RouterV2TickView, context: Context) {
        let environment = context.environment
        let transaction = context.transaction
        // A numeric tick is dropped under Reduce Motion (as `.motion(_:value:)` drops it); a mark crossfades.
        let numeric = if case .numeric = style { true } else { false }
        let animated = !(numeric && environment.accessibilityReduceMotion) && environment.windowArrival?.active != true
            && !transaction.disablesAnimations && (always || transaction.animation != nil)
        view.take(key: key, look: "\(look)|\(environment.colorScheme)", style: style, animated: animated,
                  reduce: environment.accessibilityReduceMotion) {
            view.host.rootView = root(context)
        }
    }

    static func dismantleNSView(_ view: RouterV2TickView, coordinator: Coordinator) { view.settle() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: RouterV2TickView, context: Context) -> CGSize? {
        // Its content's own size: what ticks is never wrapped or stretched. Its column or box is inside its content, so
        // its frame stays as it ticks (a frame that changes makes AppKit walk the window's views for their tracking areas).
        context.coordinator.controller?.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: .infinity))
    }

    private func root(_ context: Context) -> AnyView {
        AnyView(content()
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.routerV2Still, context.environment.routerV2Still)
            .transformEnvironment(\._accessibilityReduceMotion) { if context.environment.accessibilityReduceMotion { $0 = true } })
    }
}

/// The tick's view: its hosting view, and while a tick rolls, the pictures that roll over it.
final class RouterV2TickView: NSView {
    let host: NSHostingView<AnyView>
    private(set) var key: String
    private var pending: Pending?
    private var rolling: [CALayer] = []
    private var generation = 0
    private static let hideKey = "fjord.tick.hide"
    private static let inKey = "fjord.tick.in"

    private struct Pending {
        let old: CGImage
        let oldSize: CGSize
        let oldKey: String
        let style: RouterV2TickStyle
        let reduce: Bool
    }

    init(host: NSHostingView<AnyView>, key: String) {
        self.host = host
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        // The rolling characters blur (`blur`).
        layerUsesCoreImageFilters = true
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // Never pointed at: a click or a hover is the row's, the header's or the token's around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Its hosting view asks for an update pass on each change and each frame of what animates inside it; SwiftUI's host
    // of this view takes that as "its size may have changed" and lays the whole line out again (as the list did for its
    // rows, `RouterV2GlideView`). Its size changes only with what it is given (`sizeThatFits`, after `updateNSView`), so
    // that host passes the message on as a plain view does.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let superview { RouterV2GlideView.quiet(type(of: superview)) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        host.frame = bounds
    }

    /// The new key and content: when the key changed and the change is animated, the picture before it is kept, and the
    /// tick rolls once the view has its new size (`layout`).
    func take(key: String, look: String, style: RouterV2TickStyle, animated: Bool, reduce: Bool, update: () -> Void) {
        let was = shownAs
        self.look = look
        guard key != self.key else {
            update()
            if shownAs != was { keep(style) }
            return
        }
        let oldKey = self.key
        self.key = key
        // A tick over another: the one under way lands at once.
        let shown = pending.map { ($0.old, $0.oldSize) }
        settle()
        // The picture of what it showed: kept since it was drawn, or taken now.
        let keptOld = kept.flatMap { $0.of == was && $0.size == bounds.size ? ($0.image, $0.size) : nil }
        let old = animated && window != nil ? (shown ?? keptOld ?? picture().map { ($0, bounds.size) }) : nil
        update()
        keep(style)
        guard let old, old.1.width > 0 else { return }
        pending = Pending(old: old.0, oldSize: old.1, oldKey: oldKey, style: style, reduce: reduce)
        needsLayout = true
    }

    /// What it shows now: its key and its look.
    private var shownAs: String { "\(key)|\(look)" }
    private var look = ""
    /// A picture of what it showed, for the next tick to roll from: taking it in the tick's own turn costs that turn a
    /// CPU draw of the view (0.5–2 ms).
    private var kept: (of: String, image: CGImage, size: CGSize)?
    private var keeping = false

    /// Takes the picture of what it shows once this turn's change is on screen and nothing moves (`MotionGate`), off the
    /// path of the change. A numeric tick keeps the picture it rolls to instead.
    private func keep(_ style: RouterV2TickStyle) {
        if case .numeric = style { return }
        guard !keeping, window != nil else { return }
        keeping = true
        DispatchQueue.main.async { [weak self] in
            MotionGate.whenStill {
                guard let self else { return }
                self.keeping = false
                let of = self.shownAs
                guard self.window != nil, self.kept?.of != of, let image = self.picture() else { return }
                self.kept = (of, image, self.bounds.size)
            }
        }
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        guard let pending else { return }
        self.pending = nil
        if case .numeric = pending.style {
            host.layoutSubtreeIfNeeded()
            guard let new = picture() else { return }
            kept = (shownAs, new, bounds.size)
            roll(pending, new: new)
        } else {
            roll(pending, new: nil)
        }
    }

    /// Whatever rolls lands now.
    func settle() {
        pending = nil
        guard !rolling.isEmpty || host.layer?.animation(forKey: Self.hideKey) != nil || host.layer?.animation(forKey: Self.inKey) != nil
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rolling.forEach { $0.removeFromSuperlayer() }
        rolling = []
        host.layer?.removeAnimation(forKey: Self.hideKey)
        host.layer?.removeAnimation(forKey: Self.inKey)
        CATransaction.commit()
    }

    /// The hosting view as drawn now.
    private func picture() -> CGImage? {
        guard host.bounds.width > 0, host.bounds.height > 0, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    private func roll(_ p: Pending, new: CGImage?) {
        guard let layer, let hostLayer = host.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // When this roll's animations have ended, its pictures go (unless another roll has begun since).
        generation &+= 1
        let mine = generation
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }
                self.rolling.forEach { $0.removeFromSuperlayer() }
                self.rolling = []
            }
        }
        let size = bounds.size
        // Which way is down on screen for this layer's sublayers.
        let down: CGFloat = layer.contentsAreFlipped() ? 1 : -1
        var duration: CFTimeInterval
        switch p.style {
        case .numeric(let font):
            guard let new else { return }
            let shrinking = Double(key).flatMap { new in Double(p.oldKey).map { new < $0 } } ?? false
            // The text sits at its picture's trailing edge (a column wider than the text puts it there).
            let oldPlaces = Self.places(p.oldKey, font: font, in: p.oldSize.width), newPlaces = Self.places(key, font: font, in: size.width)
            let oldChars = Array(p.oldKey), newChars = Array(key)
            let h = size.height
            // As the value grows: out upward, in from below; the other way as it shrinks.
            let travel = h * 0.4 * -down * (shrinking ? -1 : 1)
            let spring = Self.spring(perceptualDuration: 0.5, bounce: 0.15)
            duration = spring.settlingDuration
            for j in 0..<max(oldChars.count, newChars.count) {
                let o = j < oldChars.count ? oldChars.count - 1 - j : nil
                let n = j < newChars.count ? newChars.count - 1 - j : nil
                if let o, let n, oldChars[o] == newChars[n],
                   abs((p.oldSize.width - oldPlaces[o].lowerBound) - (size.width - newPlaces[n].lowerBound)) < 0.5 {
                    add(slice(new, newPlaces, n, count: newChars.count, width: size.width, height: h, at: 0), to: layer)
                    continue
                }
                if let o {
                    let s = slice(p.old, oldPlaces, o, count: oldChars.count, width: p.oldSize.width, height: p.oldSize.height,
                                  at: size.width - p.oldSize.width)
                    s.opacity = 0
                    Self.blur(s, from: 0, to: Self.blurRadius, duration: 0.18)
                    s.add(Self.basic("opacity", from: 1, to: 0, duration: 0.16, timing: .easeOut), forKey: "out")
                    s.add(Self.springy(spring, "transform.translation.y", from: 0, to: travel), forKey: "move")
                    s.add(Self.springy(spring, "transform.scale", from: 1, to: 0.7), forKey: "scale")
                    add(s, to: layer)
                }
                if let n {
                    let s = slice(new, newPlaces, n, count: newChars.count, width: size.width, height: h, at: 0)
                    Self.blur(s, from: Self.blurRadius, to: 0, duration: 0.22)
                    s.add(Self.basic("opacity", from: 0, to: 1, duration: 0.2, timing: .easeOut), forKey: "in")
                    s.add(Self.springy(spring, "transform.translation.y", from: -travel, to: 0), forKey: "move")
                    s.add(Self.springy(spring, "transform.scale", from: 0.7, to: 1), forKey: "scale")
                    add(s, to: layer)
                }
            }
            // The hosting view shows again as the pictures go: the same pixels.
            hostLayer.add(Self.basic("opacity", from: 0, to: 0, duration: duration, timing: .linear), forKey: Self.hideKey)
        case .replace:
            let fade = key.hasPrefix("~") || p.oldKey.hasPrefix("~")
            // The old picture over the new hosting view, centred on it.
            let old = CALayer()
            old.contents = p.old
            old.contentsScale = CGFloat(p.old.width) / max(1, p.oldSize.width)
            old.frame = CGRect(x: (size.width - p.oldSize.width) / 2, y: (size.height - p.oldSize.height) / 2,
                               width: p.oldSize.width, height: p.oldSize.height)
            old.opacity = 0
            if fade || p.reduce {
                duration = 0.2
                old.add(Self.basic("opacity", from: 1, to: 0, duration: duration, timing: .easeOut), forKey: "out")
                hostLayer.add(Self.basic("opacity", from: 0, to: 1, duration: duration, timing: .easeOut), forKey: Self.inKey)
            } else {
                // The old one down and out quickly; the new one up from small, on a lively spring.
                let spring = Self.spring(perceptualDuration: 0.28, bounce: 0.3)
                duration = spring.settlingDuration
                old.add(Self.basic("opacity", from: 1, to: 0, duration: 0.12, timing: .easeIn), forKey: "out")
                old.add(Self.basic("transform.scale", from: 1, to: 0.3, duration: 0.12, timing: .easeIn), forKey: "scale")
                let grow = CAAnimationGroup()
                grow.animations = [Self.springy(spring, "transform", from: Self.scaled(0.3, size), to: CATransform3DIdentity),
                                   Self.basic("opacity", from: 0, to: 1, duration: 0.1, timing: .easeOut, delay: 0.06)]
                grow.duration = duration
                hostLayer.add(grow, forKey: Self.inKey)
            }
            add(old, to: layer)
        }
    }

    /// The blur a rolling character has at its farthest (`numericText` blurs what goes and what comes).
    private static let blurRadius: CGFloat = 2.5

    /// A Gaussian blur over the character's picture, from `from` to `to` points (drawn by the render server).
    private static func blur(_ layer: CALayer, from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.name = "blur"
        filter.setValue(to, forKey: kCIInputRadiusKey)
        layer.filters = [filter]
        layer.add(basic("filters.blur.inputRadius", from: from, to: to, duration: duration, timing: .easeOut), forKey: "blur")
    }

    private func add(_ sublayer: CALayer, to layer: CALayer) {
        layer.addSublayer(sublayer)
        rolling.append(sublayer)
    }

    /// Character `i` of a picture `width` wide: from its start to the next one's (the first from the picture's left edge,
    /// the last to its right edge, so nothing a glyph draws past its advance is cut), placed `at` to the right.
    private func slice(_ image: CGImage, _ places: [Range<CGFloat>], _ i: Int, count: Int, width: CGFloat, height: CGFloat, at x: CGFloat) -> CALayer {
        let start = i == 0 ? 0 : min(width, places[i].lowerBound)
        let end = i == count - 1 ? width : min(width, places[i].upperBound)
        let l = CALayer()
        l.contents = image
        l.contentsScale = CGFloat(image.width) / max(1, width)
        l.contentsRect = CGRect(x: start / max(1, width), y: 0, width: max(0, end - start) / max(1, width), height: 1)
        l.frame = CGRect(x: x + start, y: 0, width: max(0, end - start), height: height)
        return l
    }

    /// Each character's place in a picture `width` wide with the text at its trailing edge, from its typesetting in
    /// `font`.
    static func places(_ text: String, font: NSFont, in width: CGFloat) -> [Range<CGFloat>] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let inset = max(0, width - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        var out: [Range<CGFloat>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let a = CTLineGetOffsetForStringIndex(line, index.utf16Offset(in: text), nil)
            let b = CTLineGetOffsetForStringIndex(line, next.utf16Offset(in: text), nil)
            out.append(inset + min(a, b)..<inset + max(a, b))
            index = next
        }
        return out
    }

    private static func spring(perceptualDuration: Double, bounce: Double) -> CASpringAnimation {
        let s = CASpringAnimation(perceptualDuration: perceptualDuration, bounce: bounce)
        s.duration = s.settlingDuration
        return s
    }

    private static func springy(_ model: CASpringAnimation, _ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let s = model.copy() as! CASpringAnimation
        s.keyPath = keyPath
        s.fromValue = from
        s.toValue = to
        s.fillMode = .both
        s.isRemovedOnCompletion = true
        return s
    }

    private static func basic(_ keyPath: String, from: Any, to: Any, duration: CFTimeInterval, timing: CAMediaTimingFunctionName,
                              delay: CFTimeInterval = 0) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.beginTime = delay
        a.timingFunction = CAMediaTimingFunction(name: timing)
        a.fillMode = .both
        return a
    }

    /// A scale about a layer's centre (an AppKit view's layer is anchored at its corner).
    private static func scaled(_ s: CGFloat, _ size: CGSize) -> CATransform3D {
        let c = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0),
                                                       CATransform3DMakeScale(s, s, 1)), c)
    }
}

extension NSFont {
    /// The font with digits of one width (SwiftUI's `monospacedDigit()`).
    var monospacedDigits: NSFont {
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
