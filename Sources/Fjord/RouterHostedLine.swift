import AppKit
import SwiftUI

// A thread's line in a hosting view of its own (docs/design/router-v2/IMPLEMENTATION.md 2.2, "one record changes: one
// line redrawn"). In the page's one SwiftUI tree, a record, a streamed word or a growing reply laid out, hit-tested and
// drew the whole sixty-row page, every frame (`--router-v2-load`: event to commit p95 ~150 ms). Here each line's views
// live in their own `NSHostingView`: a change inside a line lays out, hit-tests and draws that line alone, and the list
// sees a leaf whose height changes only when the card opens or shuts, the queued row comes or goes, or the card's
// content grows. The list keeps what moves lines (their places, the glide between sections, the fold in and out, the
// moving line drawn on top), so the motion is the same.

extension Router {
    /// A hosted line's own coordinate space: its targets' frames are in it, placed on the page by the line's origin.
    static let rowSpace = "router-v2-row"
    /// The list's own space: a row's place in it doesn't change as the page scrolls.
    static let listSpace = "router-v2-list"
}

/// The list's slot for a line: its hosting view, as tall as the line's content.
struct RouterHostedLine: View {
    let model: RouterModel
    let box: RouterLineBox
    /// Its row's id in the list.
    let slot: String
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.windowArrival) private var arrival
    @Environment(\.routerStill) private var still
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // The line's height from what the model sets, at once: the rows under it glide on the change's own curve
        // (`RouterGlides`) while the card opens, shuts or grows inside on the same curve. The line's height as measured
        // until it has been laid out once.
        let open = box.selected && !box.moving
        let card = box.cardHeight
        let rest = box.rowHeight + box.queuedHeight
        let height: CGFloat? = box.rowHeight > 0 ? rest + (open ? card : 0) : nil
        RouterLineHost(model: model, box: box, slot: slot, setup: .init(reduce: reduce, still: still, scheme: scheme, arrival: arrival))
            .frame(height: height, alignment: .top)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(Router.space)).origin } action: { [model, id = box.id] in
                model.targets.origins[id] = $0
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Router.listSpace)).minY } action: { [glides = model.glides, slot] in
                glides.placed(slot, at: $0)
            }
            // A line in flight passes over the rows between: it is drawn last.
            .zIndex(box.moving ? 1 : 0)
            .routerGlides()
    }
}

extension View {
    /// A row of the list placed and sized where it goes at once: its slot view glides there on Core Animation, on the
    /// change's own curve (`RouterGlides`), so a move costs the page one layout, not one a frame.
    func routerGlides() -> some View { transaction { $0.animation = nil } }
}

/// The curve of the change being made now, for the list's rows: SwiftUI places a row where it goes at once, and its
/// slot view (`RouterGlideView`), seeing its place change in the layout that change brought, runs the same curve on
/// Core Animation (an additive offset on its layer, from where it was to nothing). SwiftUI's springs and Core
/// Animation's share their model (`perceptualDuration`, `bounce`), so the rows glide as they did when SwiftUI moved
/// them, and nothing in SwiftUI runs per frame. A curve holds for the turn it is set in and the layouts that turn's
/// change brings (a line's own hosting view measures its card first, then the list takes its height).
@MainActor
final class RouterGlides {
    struct Glide {
        let curve: Motion.Curve
        let generation: Int
    }

    private(set) var current: Glide?
    private var generation = 0
    /// Lines changing section, and what runs once each has landed (`RouterModel.move`).
    private var landings: [String: () -> Void] = [:]
    private var observer: CFRunLoopObserver?
    /// Commits left before the curve goes.
    private var commits = 0

    /// The rows' slot views, by row id.
    private var views: [String: Weak] = [:]
    private struct Weak { weak var view: RouterGlideView? }

    func register(_ id: String, _ view: RouterGlideView) {
        view.glides = self
        views[id] = Weak(view: view)
    }

    /// Where each row is drawn now, as the frames see it (`RouterFrames.rows`): its place in the window's content view
    /// (top-left origin), moved by its glide as drawn this frame. Rows outside the list's visible part are left out.
    func drawn() -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for (id, ref) in views {
            guard let view = ref.view, let content = view.window?.contentView, let clip = view.enclosingScrollView?.contentView
            else { continue }
            var rect = view.convert(view.bounds, to: nil)
            let visible = clip.convert(clip.bounds, to: nil)
            let shift = (view.layer?.presentation()?.transform.m42 ?? 0) * RouterGlideView.down(of: view)
            rect.origin.y -= shift
            guard visible.contains(rect) else { continue }
            out[id] = CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        return out
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
/// where it was, on the change's curve. The list reports its place (`RouterGlides.placed`): SwiftUI places the view's
/// host inside containers of its own, so the view never sees its place change.
class RouterGlideView: NSView {
    /// The line whose landing this row's glide carries (`RouterModel.move`).
    var line: String?
    weak var glides: RouterGlides?
    /// Its top in the list's space, as last placed.
    var place: CGFloat?

    override var isFlipped: Bool { true }

    // A hosting view inside asks for an update (`NSHostingView.setNeedsUpdate` → `setNeedsUpdateConstraints`), and AppKit
    // tells each container up the chain, so the window's next pass reaches it. SwiftUI's host of this view (its
    // `_NSConstraintBasedLayoutHostingView` override of that message) also takes it as "the hosted view's size may have
    // changed" and lays the whole list out again: on every frame of every animation inside every row
    // (`--router-v2-load`: ~260 list layouts a second, the most of the main thread). A row's height is the list's to set
    // (from the model, `RouterHostedLine`), so the hosts of the list's own rows pass the message on as any view does
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
        guard let glide = glides.current, let animation = RouterGlides.animation(glide.curve, keyPath: "transform.translation.y", from: -dy * Self.down(of: self))
        else { return }
        layer.add(animation, forKey: "glide-\(glide.generation)-\(Int(CACurrentMediaTime() * 1000))")
        // Landed when its curve logically ends: an empty additive animation of that length says when.
        if let line, let land = glides.claim(line) {
            let landing = CABasicAnimation(keyPath: "opacity")
            landing.fromValue = 0
            landing.toValue = 0
            landing.isAdditive = true
            landing.duration = RouterGlides.landing(glide.curve)
            landing.delegate = Landing(land)
            layer.add(landing, forKey: "landing-\(glide.generation)")
        }
    }

    /// +1 when a positive translation of the view's layer moves it down on screen, -1 when up.
    static func down(of view: NSView) -> CGFloat {
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
struct RouterLineSetup: Equatable {
    var reduce: Bool
    var still: Bool
    var scheme: ColorScheme
    var arrival: WindowArrival?

    static func == (a: Self, b: Self) -> Bool {
        a.reduce == b.reduce && a.still == b.still && a.scheme == b.scheme && a.arrival === b.arrival
    }
}

/// The line's views as its own hosting view's root.
struct RouterLineRoot: View {
    let model: RouterModel
    let box: RouterLineBox
    let setup: RouterLineSetup

    var body: some View {
        // Top first: while the slot is taller than the line (its card rolling shut), the line stays at its top.
        let line = RouterLineView(model: model, box: box)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(.named(Router.rowSpace))
            // Room for what a line draws past its edges (the veil of a line in flight).
            .padding(.vertical, RouterLineSlotView.overflow)
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, setup.scheme)
            .environment(\.routerStill, setup.still)
            .environment(\.routerRow, box.id)
            .transformEnvironment(\._accessibilityReduceMotion) { if setup.reduce { $0 = true } }
        if let arrival = setup.arrival { line.windowArrival(arrival) } else { line }
    }
}

/// A line's hosting view, measured by its controller (`sizeThatFits(in:)`).
typealias RouterLineHosting = NSHostingView<RouterLineRoot>

/// What the list places: the line's hosting view at its top, as tall as the slot, or taller while the line's card rolls
/// shut (the card is still drawn below the slot's new bottom until its roll has ended: `box.built`). Nothing clips it.
final class RouterLineSlotView: RouterGlideView {
    let hosting: RouterLineHosting
    let box: RouterLineBox
    /// The slot's height while the card was last open: the hosting view keeps it until the card's body goes.
    private var held: CGFloat = 0
    /// The hosting view's height: room for the line and any card under it (`fit`).
    private var room = RouterLineSlotView.roomStep
    /// What the hosting view shows: down to the slot's bottom (`clip`).
    private let mask = CALayer()
    /// The mask's height as last set, for the roll from it.
    private var clipped: CGFloat?
    static let roomStep: CGFloat = 2400
    /// The room the hosting view has above and below the slot: the veil of a line in flight fades out past its row.
    static let overflow = Router.Surface.veilOut

    init(hosting: RouterLineHosting, box: RouterLineBox) {
        self.hosting = hosting
        self.box = box
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(hosting)
        line = box.id
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Its hosting view follows its size at once: nothing else lays it out (`RouterGlideView`).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    override func layout() {
        super.layout()
        fit()
    }

    /// The hosting view's frame: the slot's width, and a height that doesn't change as the card opens, shuts or grows.
    /// SwiftUI takes a hosting view's new size in the update that changed it and, in an animated one, animates its
    /// root's size around the root's new centre: the line dropped by half the card's height as its card opened and slid
    /// back up (the same, upwards, as it shut). So the hosting view is as tall as the slot could get (`room`), the line
    /// drawn at its top; only the slot is hit, and what is past it is empty. It grows only for a card taller than that.
    func fit() {
        let height = bounds.height
        if box.selected, !box.moving { held = height } else if !box.built { held = 0 }
        let o = Self.overflow
        let needed = max(height, box.built ? held : 0) + 2 * o
        if needed > room { room = (needed / Self.roomStep).rounded(.up) * Self.roomStep }
        let frame = CGRect(x: 0, y: -o, width: bounds.width, height: room)
        if hosting.frame != frame {
            hosting.frame = frame
        }
        clip()
    }

    /// The hosting view drawn down to the slot's bottom only: a card's roll is SwiftUI's, drawn on the main thread two or
    /// three frames behind the rows' glides on Core Animation, and as a card shut the line rising under it covered its
    /// last lines. The slot's bottom moves on Core Animation instead, on the glides' own curve, so what shows of a card
    /// shutting (or opening, or growing) is always what the rows around it leave. A line in flight isn't masked (its veil
    /// reaches past its row).
    private func clip() {
        guard let host = hosting.layer else { return }
        guard !box.moving else {
            if host.mask != nil { host.mask = nil }
            clipped = nil
            return
        }
        if host.mask !== mask {
            mask.backgroundColor = CGColor(gray: 0, alpha: 1)
            mask.actions = ["bounds": NSNull(), "position": NSNull(), "anchorPoint": NSNull(), "cornerRadius": NSNull()]
            host.mask = mask
            clipped = nil
        }
        // The hosting layer's sense of down: AppKit lays a view's layers out in the view's own coordinates. The room
        // above the slot is the veil's.
        let down = hosting.isFlipped
        let o = Self.overflow
        let height = bounds.height + o
        let width = bounds.width
        mask.anchorPoint = CGPoint(x: 0, y: down ? 0 : 1)
        mask.position = CGPoint(x: 0, y: down ? 0 : host.bounds.height)
        mask.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // Its bottom corners the selected ground's, so the ground keeps its shape through the roll.
        mask.cornerRadius = box.selected || box.built ? Router.Line.selectedRadius : 0
        mask.maskedCorners = down ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        if let was = clipped, was != height, let glide = glides?.current,
           let animation = RouterGlides.animation(glide.curve, keyPath: "bounds.size.height", from: was - height) {
            mask.add(animation, forKey: "roll-\(glide.generation)-\(Int(CACurrentMediaTime() * 1000))")
        }
        clipped = height
    }

    // The overflow is drawn, never hit: only the slot can be pointed at.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

private struct RouterLineHost: NSViewRepresentable {
    let model: RouterModel
    let box: RouterLineBox
    let slot: String
    let setup: RouterLineSetup

    final class Coordinator {
        var controller: NSHostingController<RouterLineRoot>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RouterLineSlotView {
        let controller = NSHostingController(rootView: RouterLineRoot(model: model, box: box, setup: setup))
        // The list sizes it (`sizeThatFits`): no preferred size or constraints to keep up to date on each change, and no
        // safe area of the window's.
        controller.sizingOptions = []
        context.coordinator.controller = controller
        let hosting = controller.view as! RouterLineHosting
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        let view = RouterLineSlotView(hosting: hosting, box: box)
        model.glides.register(slot, view)
        return view
    }

    func updateNSView(_ view: RouterLineSlotView, context: Context) {
        // A new root only when what it takes changed: setting one runs the line's whole body again.
        let root = view.hosting.rootView
        if root.box !== box || root.model !== model || root.setup != setup {
            view.hosting.rootView = RouterLineRoot(model: model, box: box, setup: setup)
        }
        view.fit()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: RouterLineSlotView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let controller = context.coordinator.controller else { return nil }
        // The slot's height is the list's, from the model (`RouterHostedLine`): measured here, a card that had just shut
        // still came back at its open height (the hosting view not updated yet), and the slot stayed that tall under the
        // rows after it, taking their clicks.
        if let height = proposal.height, height.isFinite { return CGSize(width: width, height: height) }
        // A zero height: the root's flexible frame comes back at the line's own height.
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 0))
        return CGSize(width: width, height: max(0, size.height - 2 * RouterLineSlotView.overflow))
    }
}
