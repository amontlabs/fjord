import AppKit
import SwiftUI

// A thread's line in a hosting view of its own (docs/design/router-v2/IMPLEMENTATION.md 2.2, "one record changes: one
// line redrawn"). In the page's one SwiftUI tree, a record, a streamed word or a growing reply laid out, hit-tested and
// drew the whole sixty-row page, every frame (`--router-v2-load`: event to commit p95 ~150 ms). Here each line's views
// live in their own `NSHostingView`: a change inside a line lays out, hit-tests and draws that line alone, and the list
// sees a leaf whose height changes only when the card opens or shuts, the queued row comes or goes, or the card's
// content grows. The list keeps what moves lines (their places, the glide between sections, the fold in and out, the
// moving line drawn on top), so the motion is the same.

extension RouterV2 {
    /// A hosted line's own coordinate space: its targets' frames are in it, placed on the page by the line's origin.
    static let rowSpace = "router-v2-row"
    /// The list's own space: a row's place in it doesn't change as the page scrolls.
    static let listSpace = "router-v2-list"
}

/// The list's slot for a line: its hosting view, as tall as the line's content.
struct RouterV2HostedLine: View {
    let model: RouterV2Model
    let box: RouterV2LineBox
    /// Its row's id in the list.
    let slot: String
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.windowArrival) private var arrival
    @Environment(\.routerV2Still) private var still
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // The line's height from what the model sets, at once: the rows under it glide on the change's own curve
        // (`RouterV2Glides`) while the card opens, shuts or grows inside on the same curve. The line's height as measured
        // until it has been laid out once.
        let open = box.selected && !box.moving
        let card = box.cardHeight
        let rest = box.rowHeight + box.queuedHeight
        let height: CGFloat? = box.rowHeight > 0 ? rest + (open ? card : 0) : nil
        RouterV2LineHost(model: model, box: box, slot: slot, setup: .init(reduce: reduce, still: still, scheme: scheme, arrival: arrival))
            .frame(height: height, alignment: .top)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(RouterV2.space)).origin } action: { [model, id = box.id] in
                model.targets.origins[id] = $0
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(RouterV2.listSpace)).minY } action: { [glides = model.glides, slot] in
                glides.placed(slot, at: $0)
            }
            // A line in flight passes over the rows between: it is drawn last.
            .zIndex(box.moving ? 1 : 0)
            .routerV2Glides()
    }
}

extension View {
    /// A row of the list placed and sized where it goes at once: its slot view glides there on Core Animation, on the
    /// change's own curve (`RouterV2Glides`), so a move costs the page one layout, not one a frame.
    func routerV2Glides() -> some View { transaction { $0.animation = nil } }
}

/// The curve of the change being made now, for the list's rows: SwiftUI places a row where it goes at once, and its
/// slot view (`RouterV2GlideView`), seeing its place change in the layout that change brought, runs the same curve on
/// Core Animation (an additive offset on its layer, from where it was to nothing). SwiftUI's springs and Core
/// Animation's share their model (`perceptualDuration`, `bounce`), so the rows glide as they did when SwiftUI moved
/// them, and nothing in SwiftUI runs per frame. A curve holds for the turn it is set in and the layouts that turn's
/// change brings (a line's own hosting view measures its card first, then the list takes its height).
@MainActor
final class RouterV2Glides {
    struct Glide {
        let curve: Motion.Curve
        let generation: Int
    }

    private(set) var current: Glide?
    private var generation = 0
    /// Lines changing section, and what runs once each has landed (`RouterV2Model.move`).
    private var landings: [String: () -> Void] = [:]
    private var observer: CFRunLoopObserver?
    /// Commits left before the curve goes.
    private var commits = 0

    /// The rows' slot views, by row id.
    private var views: [String: Weak] = [:]
    private struct Weak { weak var view: RouterV2GlideView? }

    func register(_ id: String, _ view: RouterV2GlideView) {
        view.glides = self
        views[id] = Weak(view: view)
    }

    /// The list placed row `id` with its top at `y` in the list's space.
    func placed(_ id: String, at y: CGFloat) {
        guard let view = views[id]?.view else { return }
        if let was = view.place, was != y { view.glide(by: y - was) }
        view.place = y
    }

    /// A change on `curve` is being made: the rows it moves glide on it.
    func began(_ curve: Motion.Curve) {
        guard curve != .none else { return }
        generation &+= 1
        current = Glide(curve: curve, generation: generation)
        commits = 2
        schedule()
    }

    /// `id` is changing section: `land` runs once its row has glided there (or at once if it has nowhere to go).
    func landing(_ id: String, _ land: @escaping () -> Void) {
        landings[id] = land
        schedule()
    }

    /// The landing of the line whose row starts its glide now.
    func claim(_ id: String) -> (() -> Void)? { landings.removeValue(forKey: id) }

    /// After Core Animation's commit (order 2000000), at the end of each turn until the curve is spent.
    private func schedule() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.committed() }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func committed() {
        // A line whose row didn't move on the page (not shown, or at the same place) has landed.
        let unclaimed = landings
        landings = [:]
        commits -= 1
        if commits <= 0 {
            current = nil
            if let observer { CFRunLoopObserverInvalidate(observer) }
            observer = nil
        }
        for land in unclaimed.values { land() }
    }

    /// The Core Animation twin of a curve, as an additive offset of `keyPath` from `from` to nothing.
    static func animation(_ curve: Motion.Curve, keyPath: String, from: CGFloat) -> CABasicAnimation? {
        let animation: CABasicAnimation
        switch curve {
        case .none: return nil
        case .easeOut(let duration):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        case .spring(let duration, let bounce):
            let spring = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
            spring.keyPath = keyPath
            spring.duration = spring.settlingDuration
            animation = spring
        }
        animation.fromValue = from
        animation.toValue = 0
        animation.isAdditive = true
        animation.fillMode = .backwards
        return animation
    }

    /// How long a curve takes to land, logically (what SwiftUI's `.logicallyComplete` waits for).
    static func landing(_ curve: Motion.Curve) -> Double {
        switch curve {
        case .none: 0
        case .easeOut(let duration): duration
        case .spring(let duration, _): duration
        }
    }
}

/// A row's slot in the list: when the list places it elsewhere in the layout of an animated change, it glides there from
/// where it was, on the change's curve. The list reports its place (`RouterV2Glides.placed`): SwiftUI places the view's
/// host inside containers of its own, so the view never sees its place change.
class RouterV2GlideView: NSView {
    /// The line whose landing this row's glide carries (`RouterV2Model.move`).
    var line: String?
    weak var glides: RouterV2Glides?
    /// Its top in the list's space, as last placed.
    var place: CGFloat?

    override var isFlipped: Bool { true }

    // A hosting view inside asks for an update (`NSHostingView.setNeedsUpdate` → `setNeedsUpdateConstraints`), and AppKit
    // tells each container up the chain, so the window's next pass reaches it. SwiftUI's host of this view (its
    // `_NSConstraintBasedLayoutHostingView` override of that message) also takes it as "the hosted view's size may have
    // changed" and lays the whole list out again: on every frame of every animation inside every row
    // (`--router-v2-load`: ~260 list layouts a second, the most of the main thread). A row's height is the list's to set
    // (from the model, `RouterV2HostedLine`), so the hosts of the list's own rows pass the message on as any view does
    // (`NSView`'s implementation). Only those host classes change; a failed lookup leaves them as they are.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let host = superview { Self.quiet(type(of: host)) }
    }

    private static var quieted: Set<ObjectIdentifier> = []

    /// `host`'s instances pass an update request on as a plain `NSView` does (see `viewDidMoveToSuperview`).
    static func quiet(_ host: AnyClass) {
        guard quieted.insert(ObjectIdentifier(host)).inserted, host != NSView.self else { return }
        let selector = NSSelectorFromString("_informContainerThatSubviewsNeedUpdateConstraints")
        guard let plain = class_getInstanceMethod(NSView.self, selector), class_getInstanceMethod(host, selector) != nil else { return }
        class_replaceMethod(host, selector, method_getImplementation(plain), method_getTypeEncoding(plain))
    }

    /// Placed `dy` lower than it was (in the list's space, y down).
    func glide(by dy: CGFloat) {
        guard dy != 0, let layer, let glides else { return }
        // From where it was to where it is: an offset that runs to nothing, in the layer's own sense of down.
        guard let glide = glides.current, let animation = RouterV2Glides.animation(glide.curve, keyPath: "transform.translation.y", from: -dy * Self.down(of: self))
        else { return }
        layer.add(animation, forKey: "glide-\(glide.generation)-\(Int(CACurrentMediaTime() * 1000))")
        // Landed when its curve logically ends: an empty additive animation of that length says when.
        if let line, let land = glides.claim(line) {
            let landing = CABasicAnimation(keyPath: "opacity")
            landing.fromValue = 0
            landing.toValue = 0
            landing.isAdditive = true
            landing.duration = RouterV2Glides.landing(glide.curve)
            landing.delegate = Landing(land)
            layer.add(landing, forKey: "landing-\(glide.generation)")
        }
    }

    /// +1 when a positive translation of the view's layer moves it down on screen, -1 when up.
    private static func down(of view: NSView) -> CGFloat {
        guard let superlayer = view.layer?.superlayer else { return 1 }
        return superlayer.contentsAreFlipped() ? 1 : -1
    }

    /// Runs its work when the animation it is the delegate of stops (ended, or taken off with its layer).
    private final class Landing: NSObject, CAAnimationDelegate {
        let land: () -> Void
        init(_ land: @escaping () -> Void) { self.land = land }
        func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
            MainActor.assumeIsolated { land() }
        }
    }
}

/// What a line's hosting view takes from the page's environment.
struct RouterV2LineSetup: Equatable {
    var reduce: Bool
    var still: Bool
    var scheme: ColorScheme
    var arrival: WindowArrival?

    static func == (a: Self, b: Self) -> Bool {
        a.reduce == b.reduce && a.still == b.still && a.scheme == b.scheme && a.arrival === b.arrival
    }
}

/// The line's views as its own hosting view's root.
struct RouterV2LineRoot: View {
    let model: RouterV2Model
    let box: RouterV2LineBox
    let setup: RouterV2LineSetup

    var body: some View {
        // Top first: while the slot is taller than the line (its card rolling shut), the line stays at its top.
        let line = RouterV2LineView(model: model, box: box)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(.named(RouterV2.rowSpace))
            // Room for what a line draws past its edges (the veil of a line in flight).
            .padding(.vertical, RouterV2LineSlotView.overflow)
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, setup.scheme)
            .environment(\.routerV2Still, setup.still)
            .environment(\.routerV2Row, box.id)
            .transformEnvironment(\._accessibilityReduceMotion) { if setup.reduce { $0 = true } }
        if let arrival = setup.arrival { line.windowArrival(arrival) } else { line }
    }
}

/// A line's hosting view, measured by its controller (`sizeThatFits(in:)`).
typealias RouterV2LineHosting = NSHostingView<RouterV2LineRoot>

/// What the list places: the line's hosting view at its top, as tall as the slot, or taller while the line's card rolls
/// shut (the card is still drawn below the slot's new bottom until its roll has ended: `box.built`). Nothing clips it.
final class RouterV2LineSlotView: RouterV2GlideView {
    let hosting: RouterV2LineHosting
    let box: RouterV2LineBox
    /// The slot's height while the card was last open: the hosting view keeps it until the card's body goes.
    private var held: CGFloat = 0
    /// The room the hosting view has above and below the slot: the veil of a line in flight fades out past its row.
    static let overflow = RouterV2.Surface.veilOut

    init(hosting: RouterV2LineHosting, box: RouterV2LineBox) {
        self.hosting = hosting
        self.box = box
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(hosting)
        line = box.id
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Its hosting view follows its size at once: nothing else lays it out (`RouterV2GlideView`).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    override func layout() {
        super.layout()
        fit()
    }

    /// The hosting view's frame: the slot's width, and its height or the held one.
    func fit() {
        let height = bounds.height
        if box.selected, !box.moving { held = height } else if !box.built { held = 0 }
        let o = Self.overflow
        let frame = CGRect(x: 0, y: -o, width: bounds.width, height: max(height, box.built ? held : 0) + 2 * o)
        if hosting.frame != frame {
            hosting.frame = frame
        }
    }

    // The overflow is drawn, never hit: only the slot can be pointed at.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

private struct RouterV2LineHost: NSViewRepresentable {
    let model: RouterV2Model
    let box: RouterV2LineBox
    let slot: String
    let setup: RouterV2LineSetup

    final class Coordinator {
        var controller: NSHostingController<RouterV2LineRoot>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RouterV2LineSlotView {
        let controller = NSHostingController(rootView: RouterV2LineRoot(model: model, box: box, setup: setup))
        // The list sizes it (`sizeThatFits`): no preferred size or constraints to keep up to date on each change, and no
        // safe area of the window's.
        controller.sizingOptions = []
        context.coordinator.controller = controller
        let hosting = controller.view as! RouterV2LineHosting
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        let view = RouterV2LineSlotView(hosting: hosting, box: box)
        model.glides.register(slot, view)
        return view
    }

    func updateNSView(_ view: RouterV2LineSlotView, context: Context) {
        // A new root only when what it takes changed: setting one runs the line's whole body again.
        let root = view.hosting.rootView
        if root.box !== box || root.model !== model || root.setup != setup {
            view.hosting.rootView = RouterV2LineRoot(model: model, box: box, setup: setup)
        }
        view.fit()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: RouterV2LineSlotView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let controller = context.coordinator.controller else { return nil }
        // A zero height: the root's flexible frame comes back at the line's own height.
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 0))
        return CGSize(width: width, height: max(0, size.height - 2 * RouterV2LineSlotView.overflow))
    }
}
