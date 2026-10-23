import AppKit
import Observation
import SwiftUI

/// Where the hub sits in its window, and what the controller needs to know about it.
@Observable
@MainActor
final class HubLayout {
    /// Docked: the window spans the edge and the hub is placed along it. Floating: the window is exactly the bar
    /// (while it's dragged to another edge).
    var floating = false
    /// The bar's length along its edge: the bar keeps its start where it was whatever its peek takes.
    var restLength: CGFloat = 0
    /// The bar's size, to carry exactly that when it's dragged.
    @ObservationIgnored var restSize: CGSize = .zero
    /// The hub's frame in the window (top-left origin).
    @ObservationIgnored var frame: CGRect = .zero {
        didSet { if frame != oldValue { onFrame?() } }
    }
    @ObservationIgnored var onFrame: (() -> Void)?
    /// The bar's scale while it is carried on glass (`BarStretch`); read only while floating, so never at rest.
    var stretch: CGSize = BarStretch.rest
}

/// A transparent window over the bar at rest. The real window lets the mouse through everywhere until the pointer
/// is on the hub; this one's tracking area is how that's noticed without a system-wide mouse monitor.
private final class HoverTrigger: FloatingPanel {
    private final class TriggerView: NSView {
        var onHover: (() -> Void)?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                           owner: self))
        }
        override func mouseEntered(with event: NSEvent) { onHover?() }
        override func mouseMoved(with event: NSEvent) { onHover?() }
    }

    private let trigger = TriggerView()
    var onHover: (() -> Void)? {
        get { trigger.onHover }
        set { trigger.onHover = newValue }
    }

    override init(size: NSSize) {
        super.init(size: size)
        contentView = trigger
        // It takes the mouse (a window that ignores it gets no tracking events); it only covers the hub's own frame,
        // and goes away the moment the pointer is on it.
        acceptsMouseMovedEvents = true
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Places the hub against its edge: flush with the screen, at its position along the edge, and kept on screen
/// as it grows (from the bar's top on the sides, from its left end along the top and bottom).
private struct EdgeLayout: Layout {
    let edge: DockEdge
    let position: Double
    let restLength: CGFloat
    private let inset = Theme.Metrics.inset

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let hub = subviews.first else { return }
        let size = hub.sizeThatFits(.unspecified)
        func along(_ length: CGFloat, _ own: CGFloat) -> CGFloat {
            // From where the bar starts, so the bar never moves as a peek opens.
            let start = length * position - restLength / 2
            return min(max(start, inset), length - own - inset)
        }
        let origin = switch edge {
        case .right: CGPoint(x: bounds.maxX - size.width, y: bounds.minY + along(bounds.height, size.height))
        case .left: CGPoint(x: bounds.minX, y: bounds.minY + along(bounds.height, size.height))
        case .top: CGPoint(x: bounds.minX + along(bounds.width, size.width), y: bounds.minY)
        case .bottom: CGPoint(x: bounds.minX + along(bounds.width, size.width), y: bounds.maxY - size.height)
        }
        hub.place(at: origin, proposal: .unspecified)
    }
}

struct HubRoot: View {
    let store: Store
    let ui: UIState
    let hub: HubState
    let layout: HubLayout
    var openApp: (AppDestination) -> Void = { _ in }
    var reopenApp: () -> Void = {}
    var openUpdates: () -> Void = {}
    var openRouter: (String?) -> Void = { _ in }
    var openRouterMessage: (UUID) -> Void = { _ in }
    var pickRouterCard: (String) -> Void = { _ in }
    /// A row's "Open in Router" (given while the Router is on).
    var openInRouter: ((String) -> Void)? = nil
    /// How the bar and its panels draw: the app's, or a fixed one in tests.
    var chrome: Chrome = .shared

    var body: some View {
        GeometryReader { _ in content }
            .coordinateSpace(.named(FjordHub.rootSpace))
            .environment(chrome)
            .environment(\.openApp, openApp)
            .environment(\.reopenApp, reopenApp)
            .environment(\.openUpdates, openUpdates)
            .environment(\.openRouter, openRouter)
            .environment(\.openRouterMessage, openRouterMessage)
            .environment(\.pickRouterCard, pickRouterCard)
            .environment(\.openInRouter, store.offers(.openInRouter) ? openInRouter : nil)
            // Tooltips are drawn over the whole window, outside the hub's clipped shape, so they're never cut off.
            .tipSpace()
    }

    @ViewBuilder private var content: some View {
        let view = FjordHub(store: store, ui: ui, hub: hub)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FjordHub.rootSpace)) } action: { frame in
                if HubController.debug { NSLog("Fjord hub frame \(frame)") }
                layout.frame = frame
                layout.restLength = ui.edge.isHorizontal ? frame.width : frame.height
                layout.restSize = frame.size
            }
        if layout.floating {
            // Drawn scaled, laid out as is: the window stays exactly the bar's size.
            view.scaleEffect(layout.stretch)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EdgeLayout(edge: ui.edge, position: store.settings.centerPill == true ? 0.5 : ui.position,
                       restLength: layout.restLength) { view }
        }
    }
}

/// What the bar's views do (see `HubController.rootActions`).
private struct HubActions {
    let openApp: (AppDestination) -> Void
    let reopenApp: () -> Void
    let openUpdates: () -> Void
    let openRouter: (String?) -> Void
    let openRouterMessage: (UUID) -> Void
    let pickRouterCard: (String) -> Void
    let openInRouter: (String) -> Void
}

/// The bar on its screen edge. The window spans the edge (so a peek can open without the window being resized mid-animation)
/// and lets the mouse through everywhere but the bar and its peek. While the app window is open the bar is away.
@MainActor
final class HubController {
    let store: Store
    let ui: UIState
    let hub = HubState()
    private let layout = HubLayout()
    private let window: PillPanel
    private let host: NSHostingView<HubRoot>
    private var screen: NSScreen
    /// The screen the bar is docked on.
    var dockedScreen: NSScreen { screen }
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    /// The hover state a scheduled task is about to apply, so repeated events don't reschedule it.
    private var pendingHover: Bool?
    /// Whether the hub was last reported to the store as visible beyond the bare bar.
    private var reportedOpen = false
    /// Whether that was as the app window, rather than a peek.
    private var reportedWindow = false
    /// The app window is open. The bar is off the edge only while the window is also in front.
    private(set) var windowOpen = false
    /// The open window is in front of the user (else the bar is back on its edge, the window behind it).
    private(set) var windowFront = false
    /// Whether the bar is away from the edge now: the window is open and in front.
    var barAway: Bool { BarPresence(windowOpen: windowOpen, windowFront: windowFront).barAway }
    /// Launch preparation waits for both reported hover and a pointer that has not reached its tracking callback yet.
    var isInteracting: Bool {
        hub.hovering || hub.dragging || (!barAway && layout.frame != .zero && hubScreenFrame.contains(mouseLocation()))
    }
    private var barApplied = false
    /// Which departure or return a fade completion belongs to.
    private(set) var barGeneration = 0
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    /// The carried bar has been drawn out along its motion (`BarStretch`), and settles as it lands.
    private var stretched = false

    fileprivate static let debug = ProcessInfo.processInfo.environment["FJORD_DEBUG"] != nil
    private let trigger = HoverTrigger(size: NSSize(width: 10, height: 10))
    private var globalMouse: Any?
    /// Where the pointer is and which buttons are down: the system's, or a test's.
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var mouseButtons: () -> Int = { NSEvent.pressedMouseButtons }
    /// Waits out the grace before a leave closes the hub: the clock, or a test's.
    var leaveGrace: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// What hears the pointer now, for tests: the system-wide monitor, and the arming window's frame while it's up.
    var watchesGlobally: Bool { globalMouse != nil }
    var triggerFrame: NSRect? { trigger.isVisible ? trigger.frame : nil }
    /// The bar's frame on screen.
    var barScreenFrame: NSRect { barOnScreen ?? hubScreenFrame }
    /// Opens the app window on a place (the app's delegate owns it).
    var openApp: (AppDestination) -> Void = { _ in }
    /// Opens the app window where it was left.
    var reopenApp: () -> Void = {}
    /// Opens the app window on Settings, scrolled to Updates: the window's own Settings is the one that scrolls.
    var openUpdates: () -> Void = {}
    /// Picks a card in the Router, before the window opens on it.
    var pickRouterCard: (String) -> Void = { _ in }
    /// Scrolls the Router's conversation to a message, before the window opens on it.
    var pickRouterMessage: (UUID) -> Void = { _ in }
    /// Tags a thing (its id) in the Router's composer, before the window opens on it: a row's "Open in Router".
    var prefillRouter: (String) -> Void = { _ in }
    /// The avatars about to be shown. Replaceable so tests can observe when and in what order they are warmed.
    var prefetchAvatars: ([URL]) -> Void = { ImageCache.shared.prefetch($0) }
    /// The place the app window shows (or opens on).
    var windowPlace: () -> AppDestination? = { nil }

    /// The edge `--edge` names, if it names one.
    nonisolated static func edge(in arguments: [String]) -> DockEdge? {
        arguments.firstIndex(of: "--edge").flatMap { arguments.dropFirst($0 + 1).first }.flatMap(DockEdge.init(rawValue:))
    }

    /// `demo`: on the right edge (or the one `--edge` names) and nothing saved, so trying it never moves your real bar.
    init(store: Store, demo: Bool = false, arguments: [String] = CommandLine.arguments) {
        self.store = store
        ui = demo ? UIState(persists: false, edge: Self.edge(in: arguments) ?? .right) : UIState()
        // The screen you're looking at: the one with the mouse.
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        window = PillPanel(size: NSSize(width: 100, height: 100))
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = true
        host = NSHostingView(rootView: HubRoot(store: store, ui: ui, hub: hub, layout: layout))
        host.sizingOptions = []
        window.contentView = host
        trigger.onHover = { [weak self] in self?.mouseMoved() }
        // The bar's own view is placed as the frame is reported, and the arming window goes where it is: a turn later.
        layout.onFrame = { [weak self] in DispatchQueue.main.async { self?.syncTrigger() } }
        window.canDrag = { [weak self] p in self?.isOnBar(p) ?? false }
        window.onDragChanged = { [weak self] in self?.dragChanged(to: $0) }
        window.onDragEnded = { [weak self] in self?.dragEnded(at: $0) }
        dock()
        window.orderFrontRegardless()
        if !UnderTest.isRunning { watchMouse() }
        syncTrigger()
        observe()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !NSScreen.screens.contains(self.screen) { self.screen = NSScreen.main ?? NSScreen.screens[0] }
                self.dock()
            }
        }
    }

    // MARK: Window

    /// The window along the edge, deep enough for the bar's peek and its shadow.
    private func dockFrame() -> NSRect {
        var vf = screen.visibleFrame
        if UnderTest.isRunning { vf.origin = UnderTest.away }
        switch ui.edge {
        case .right, .left:
            let depth = FjordHub.cell + FjordHub.detail + 40
            let x = ui.edge == .right ? vf.maxX - depth : vf.minX
            return NSRect(x: x, y: vf.minY, width: depth, height: vf.height)
        case .top, .bottom:
            let depth = min(vf.height, 780)
            let y = ui.edge == .top ? vf.maxY - depth : vf.minY
            return NSRect(x: vf.minX, y: y, width: vf.width, height: depth)
        }
    }

    private func dock() {
        layout.floating = false
        if layout.stretch != BarStretch.rest {
            var instant = Transaction(animation: nil)
            instant.disablesAnimations = true
            withTransaction(instant) { layout.stretch = BarStretch.rest }
        }
        stretched = false
        let actions = rootActions
        host.rootView = HubRoot(store: store, ui: ui, hub: hub, layout: layout, openApp: actions.openApp,
                                reopenApp: actions.reopenApp, openUpdates: actions.openUpdates,
                                openRouter: actions.openRouter, openRouterMessage: actions.openRouterMessage,
                                pickRouterCard: actions.pickRouterCard, openInRouter: actions.openInRouter)
        window.setFrame(dockFrame(), display: true)
        syncTrigger()
    }

    /// What the bar's views do, made once: the root is given the same closures each time it is made again (docking on
    /// another edge or screen), so the environment that carries them never tells their readers they changed. Each asks
    /// for what this controller is told to do (`openApp`, `pickRouterCard`, ...) when it is called.
    private lazy var rootActions = HubActions(
        openApp: { [weak self] in self?.opened($0) },
        reopenApp: { [weak self] in self?.reopened() },
        openUpdates: { [weak self] in self?.openedUpdates() },
        openRouter: { [weak self] in self?.opened(.router, card: $0) },
        openRouterMessage: { [weak self] in self?.pickRouterMessage($0); self?.opened(.router) },
        pickRouterCard: { [weak self] in self?.pickRouterCard($0) },
        openInRouter: { [weak self] in self?.prefillRouter($0); self?.opened(.router) })

    /// The hub's frame on screen (AppKit coordinates).
    private var hubScreenFrame: NSRect { screenFrame(layout.frame) }

    /// A frame in the window (top-left origin) on screen.
    private func screenFrame(_ f: CGRect) -> NSRect {
        let w = window.frame
        return NSRect(x: w.minX + f.minX, y: w.maxY - f.maxY, width: f.width, height: f.height)
    }

    /// The bar itself (where a drag can start), in window coordinates (bottom-left origin).
    private func isOnBar(_ p: NSPoint) -> Bool {
        let f = layout.frame
        let h = window.frame.height
        let hubRect = NSRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
        return hubRect.contains(p)
    }

    // MARK: Mouse

    /// The window only takes the mouse over the hub; hovering it opens it after a beat, leaving closes it.
    /// At rest nothing watches the mouse system-wide: a tracking area over the bar (`HoverTrigger`) notices the
    /// pointer arriving. The global monitor, to notice it leaving (and coming back), runs only while the hub has the pointer.
    private func watchMouse() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { monitors.append(local) }
    }

    /// Whether the window takes the mouse (the pointer is on the hub). A window-server call, so only on change.
    private func setAcceptsMouse(_ accepts: Bool) {
        if window.ignoresMouseEvents == accepts { window.ignoresMouseEvents = !accepts }
    }

    /// While the hub has the pointer (the window takes the mouse, or the pointer left a moment ago and the panel is still
    /// open for it to come back), the global monitor runs: every move is heard, wherever it goes, until the hub has closed.
    /// The arming window covers the bar whenever the window lets the mouse through. At rest, the arming window alone.
    private func syncTrigger() {
        guard !barAway else { return }
        let held = !window.ignoresMouseEvents || hub.hovering || pendingHover != nil
        if held, globalMouse == nil {
            globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }
        } else if !held, let global = globalMouse {
            NSEvent.removeMonitor(global)
            globalMouse = nil
        }
        guard window.ignoresMouseEvents else {
            if trigger.isVisible { trigger.orderOut(nil) }
            return
        }
        guard let bar = barOnScreen, dragStart == nil else { return }
        let frame = bar.insetBy(dx: -1, dy: -1)
        if trigger.frame != frame { trigger.setFrame(frame, display: false) }
        if !trigger.isVisible { trigger.orderFrontRegardless() }
        // The hub may have grown or moved under a still pointer.
        if !held, frame.contains(mouseLocation()) { mouseMoved() }
    }

    /// Where the bar is drawn on screen: its own view's frame, else (before it is in the window) its measured frame.
    private var barOnScreen: NSRect? {
        if let drawn = hub.barOnScreen { return drawn }
        return layout.frame == .zero ? nil : hubScreenFrame
    }

    /// The one place that says whether the pointer is on the hub: on the bar, or on the panel of the section shown, both
    /// where they are drawn this moment (`HubPiece`). Reaching it takes 1pt of slack; once it has the pointer, 4, so the
    /// seam between bar and panel, a rounded corner or a pixel's rounding never counts as leaving.
    func isOnHub(_ p: NSPoint) -> Bool {
        let slack: CGFloat = hub.hovering ? 4 : 1
        if let bar = barOnScreen, bar.insetBy(dx: -slack, dy: -slack).contains(p) { return true }
        return hub.panelsOnScreen.contains { $0.insetBy(dx: -slack, dy: -slack).contains(p) }
    }

    func mouseMoved() {
        guard dragStart == nil, !barAway else { return }
        let inside = isOnHub(mouseLocation())
        // A window-server call, so only when it changes.
        setAcceptsMouse(inside)
        defer { syncTrigger() }
        if inside == hub.hovering {
            // Closed from the keyboard with the pointer outside: the next entry may show a panel again.
            if !inside, hub.quiet { hub.quiet = false }
            if pendingHover != nil { hoverTask?.cancel(); pendingHover = nil }
            return
        }
        if pendingHover == inside { return }
        hoverTask?.cancel()
        // Passing over the bar on the way somewhere else shouldn't open it; nor should a drag from elsewhere.
        guard !inside || mouseButtons() == 0 else { pendingHover = nil; return }
        pendingHover = inside
        let grace = leaveGrace
        hoverTask = Task { [weak self] in
            if !inside { await grace(.milliseconds(120)) }
            guard let self, !Task.isCancelled else { return }
            self.pendingHover = nil
            self.hub.hovering = inside
            if !inside {
                self.hub.cancelDwell()
                self.hub.section = nil
                self.hub.quiet = false
                self.closedByLeaving()
            }
            // Closed: back to the arming window alone.
            self.syncTrigger()
        }
    }

    /// The pointer left the bar and its peek.
    private func closedByLeaving() {
        hub.selection = nil
        hub.tab = nil
    }

    // MARK: The app window

    /// A click on an item of the bar (or one of its peek's): the app window opens on it.
    private func opened(_ destination: AppDestination, card: String? = nil) {
        hub.cancelDwell()
        if let card { pickRouterCard(card) }
        openApp(destination)
    }

    /// The mark at the end of the bar: the app window, where it was left.
    private func reopened() {
        hub.cancelDwell()
        reopenApp()
    }

    /// Check for Updates, from the bar's menu: the app window opens on Settings, scrolled to Updates.
    private func openedUpdates() {
        hub.cancelDwell()
        openUpdates()
    }

    /// The app window is open (or closed): the bar leaves the edge, and comes back where it was. The pointer may be over it
    /// when it does, which shows no peek until it has left. Opening is also bringing it to the front.
    func setWindowOpen(_ open: Bool) {
        // An opening that found the bar away already has no "Bar away" to time (one that fades it out has ended it).
        defer { if open { LatencySignposts.barStayed() } }
        guard open != windowOpen || (open && !windowFront) else { return }
        windowOpen = open
        windowFront = open
        applyBar()
    }

    /// The open window came to the front or went out of sight (another app, minimized, covered): the bar is away in the first
    /// case and back on its edge in the second, the window staying open.
    func setWindowFront(_ front: Bool) {
        guard windowOpen, front != windowFront else { return }
        windowFront = front
        applyBar()
    }

    /// The bar's picture and place, and the cell it grows out of (the one under the pointer, else the one last used, else the
    /// GitHub mark's), for the window to grow out of or shrink into. The glass morph (M1) takes no picture: its glass is the
    /// bar's, so the opening's first frame doesn't wait for one.
    var morph: BarMorph? { morph(picture: !AppTransition.usesGlass) }

    /// `morph`, with the bar's picture or without (the glass morph needs none, so on glass none is taken).
    func morph(picture: Bool) -> BarMorph? {
        guard layout.frame != .zero else { return nil }
        let frame = hubScreenFrame
        var image: NSImage?
        if picture, window.isVisible, !barApplied, let rep = host.bitmapImageRepForCachingDisplay(in: layout.frame) {
            let signpost = LatencySignposts.signposter.beginInterval("Bar capture")
            host.cacheDisplay(in: layout.frame, to: rep)
            LatencySignposts.signposter.endInterval("Bar capture", signpost)
            image = NSImage(size: layout.frame.size)
            image?.addRepresentation(rep)
        }
        let tile = CDS.Tile.size + 4
        let mouse = NSEvent.mouseLocation
        var along: CGFloat?
        if frame.insetBy(dx: -2, dy: -2).contains(mouse) {
            along = ui.edge.isHorizontal ? mouse.x : mouse.y
        } else if let last = lastCellAlong, (ui.edge.isHorizontal ? frame.minX...frame.maxX : frame.minY...frame.maxY).contains(last) {
            along = last
        }
        lastCellAlong = along
        let cell: NSRect
        if ui.edge.isHorizontal {
            let x = min(max(along ?? frame.minX + FjordHub.inset + 1 + FjordHub.cell / 2, frame.minX + tile / 2), frame.maxX - tile / 2)
            cell = NSRect(x: x - tile / 2, y: frame.midY - tile / 2, width: tile, height: tile)
        } else {
            let y = min(max(along ?? frame.maxY - FjordHub.cell / 2 - 2, frame.minY + tile / 2), frame.maxY - tile / 2)
            cell = NSRect(x: frame.midX - tile / 2, y: y - tile / 2, width: tile, height: tile)
        }
        return BarMorph(frame: frame, snapshot: image, cell: cell)
    }

    /// Where along the bar the window last opened from, for it to close back into.
    private var lastCellAlong: CGFloat?

    /// Puts the bar where `barAway` says: off the edge (faded out) or on it (faded in).
    private func applyBar() {
        let away = barAway
        let leaving = away && away != barApplied
        if away != barApplied {
            barGeneration += 1
            barApplied = away
            hub.barHidden = away
            hoverTask?.cancel()
            pendingHover = nil
            hub.cancelDwell()
            if away {
                setAcceptsMouse(false)
                trigger.orderOut(nil)
                if let global = globalMouse { NSEvent.removeMonitor(global); globalMouse = nil }
                fadeOut()
            } else {
                clearPeek()
                hub.quiet = true
                fadeIn()
                syncTrigger()
            }
        }
        // Leaving for the window: what the store is told waits at least for the turn after the morph started (and then for
        // the morph to have played, as every report does).
        if leaving {
            AppTransition.nextTurn { [weak self] in self?.reportOpen() }
        } else {
            reportOpen()
        }
    }

    /// Clear the peek only out of sight, so opening can capture the bar before its layout changes.
    private func clearPeek() {
        // Already clear (the bar's fade-out cleared it out of sight): nothing written, so nothing in the bar redraws as the
        // window's close starts.
        guard hub.section != nil || hub.hovering || hub.selection != nil else { return }
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) {
            hub.section = nil
            hub.hovering = false
            hub.selection = nil
        }
    }

    private func fadeOut() {
        LatencySignposts.barLeaving()
        let mine = barGeneration
        guard AppTransition.enabled else { finishFadeOut(mine); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.finishFadeOut(mine)
            }
        })
    }

    /// A completion from an older departure cannot hide a bar that returned and has begun leaving again.
    func finishFadeOut(_ mine: Int) {
        guard barApplied, barGeneration == mine else { return }
        window.orderOut(nil)
        clearPeek()
    }

    private func fadeIn() {
        guard AppTransition.enabled else { window.alphaValue = 1; window.orderFrontRegardless(); return }
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AppTransition.reduceMotion ? AppTransition.reducedDuration : AppTransition.duration
            context.timingFunction = AppTransition.curve
            window.animator().alphaValue = 1
        }
    }

    /// Re-evaluates the pointer and what the store is told when the bar's state changes under a still pointer.
    private func observe() {
        withObservationTracking {
            _ = ui.edge
            _ = hub.section
            _ = hub.quiet
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.mouseMoved()
                self.reportOpen()
                self.observe()
            }
        }
    }

    /// Tells the store when the hub is more than the bare bar (a peek or the app window), so it refreshes stale
    /// data and polls faster meanwhile; warms the avatars the inbox is about to show, those of the page opened first (the
    /// window's place, or the peek's tab). Every report, from the bar's own changes (`observe`) as from the window's, waits
    /// for the window's morph to have played (`MotionGate`): the refresh the store may start, and the avatars, put work on
    /// the main thread. A peek, with nothing moving, is told at once.
    private func reportOpen() {
        // One report waiting for the motion at most: it reads the hub as it is when it runs.
        guard !reportQueued else { return }
        reportQueued = true
        MotionGate.whenStill { [weak self] in
            self?.reportQueued = false
            self?.reportOpenNow()
        }
    }
    private var reportQueued = false

    private func reportOpenNow() {
        let open = windowOpen || (hub.section != nil && !hub.quiet)
        // A peek turned into the window (or back) is told too: only the window syncs at once (`Store.setHubOpen`).
        let window = open && windowOpen
        guard open != reportedOpen || window != reportedWindow else { return }
        reportedOpen = open
        reportedWindow = window
        store.setHubOpen(open, window: window)
        if open {
            // A frame later: the opening's own work comes first.
            AppTransition.nextFrame(screen) {
                // A motion started meanwhile (the window closing at once, say): after it.
                MotionGate.whenStill { [weak self] in
                    guard let self, self.reportedOpen else { return }
                    self.prefetchAvatars(self.store.avatarsToWarm(first: self.windowOpen ? self.windowPlace()?.tab : self.hub.tab))
                }
            }
        }
    }

    // MARK: Dragging to another edge

    private func dragChanged(to mouse: NSPoint) {
        if dragStart == nil {
            hoverTask?.cancel()
            pendingHover = nil
            hub.cancelDwell()
            hub.section = nil
            // Back to the bar at once (no closing animation), and carry just the bar, under the cursor where you
            // grabbed it.
            var instant = Transaction(animation: nil)
            instant.disablesAnimations = true
            withTransaction(instant) {
                hub.hovering = false
                layout.floating = true
            }
            let rest = layout.restSize == .zero ? hubScreenFrame.size : layout.restSize
            let resting = restFrame(size: rest, in: screen.visibleFrame)
            let grip = NSPoint(x: min(max(mouse.x - resting.minX, 10), rest.width - 10),
                               y: min(max(mouse.y - resting.minY, 10), rest.height - 10))
            let bar = NSRect(origin: NSPoint(x: mouse.x - grip.x, y: mouse.y - grip.y), size: rest)
            window.setFrame(bar, display: true)
            dragStart = (mouse, bar.origin)
            hub.dragging = true
        }
        guard let start = dragStart else { return }
        window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
        stretch(along: CGVector(dx: mouse.x - start.mouse.x, dy: mouse.y - start.mouse.y))
    }

    /// On glass, once the motion has a direction, the bar is drawn out along it for the rest of the drag. Under Reduce Motion
    /// `BarStretch.scale` stays at rest, so nothing changes or animates.
    private func stretch(along motion: CGVector) {
        guard !stretched, Chrome.shared.mode == .glass else { return }
        let reduce = Motion.systemReduce
        let scale = BarStretch.scale(motion, reduce: reduce)
        guard scale != BarStretch.rest else { return }
        stretched = true
        withAnimation(Motion.spatial.resolved(reduce: reduce)) { layout.stretch = scale }
    }

    /// The bar settles back to its shape as it glides onto its edge.
    private func settle() {
        guard stretched else { return }
        withAnimation(Motion.spatial.resolved(reduce: Motion.systemReduce)) { layout.stretch = BarStretch.rest }
    }

    private func dragEnded(at mouse: NSPoint) {
        screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screen
        let vf = screen.visibleFrame
        (ui.edge, ui.position) = EdgeSnap.snap(window.frame, in: vf)
        settle()
        // Let SwiftUI lay the bar out for its new edge (it may turn), then glide it into place and dock.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            let size = self.host.fittingSize
            let target = self.restFrame(size: size, in: vf)
            let glide = LatencySignposts.signposter.beginInterval("Drag")
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window.animator().setFrame(target, display: true)
            }, completionHandler: {
                MainActor.assumeIsolated {
                    LatencySignposts.signposter.endInterval("Drag", glide)
                    // On its edge, on glass: the trackpad's tick, as an alignment guide's.
                    if Chrome.shared.mode == .glass { BarStretch.landed() }
                    self.dragStart = nil
                    self.hub.dragging = false
                    self.dock()
                    self.mouseMoved()
                }
            })
        }
    }

    /// `--motion-script`'s drag: the bar picked up and dropped by the opposite edge through the pointer's own path, with
    /// points made up instead of a hand's, so the glide is the one a drag ends in. False when the bar can't be carried now.
    func dragToOppositeEdge() -> Bool {
        guard !barAway, dragStart == nil, layout.frame != .zero else { return false }
        let vf = screen.visibleFrame
        let from = NSPoint(x: hubScreenFrame.midX, y: hubScreenFrame.midY)
        let to = switch ui.edge {
        case .right: NSPoint(x: vf.minX + 20, y: from.y)
        case .left: NSPoint(x: vf.maxX - 20, y: from.y)
        case .top: NSPoint(x: from.x, y: vf.minY + 20)
        case .bottom: NSPoint(x: from.x, y: vf.maxY - 20)
        }
        dragChanged(to: from)
        dragChanged(to: to)
        dragEnded(at: to)
        return true
    }

    /// Where the bar rests on its edge: the same place `EdgeLayout` puts it once docked.
    private func restFrame(size: NSSize, in vf: NSRect) -> NSRect {
        let position = store.settings.centerPill == true ? 0.5 : ui.position
        let dock = dockFrame()
        let inset: CGFloat = 6
        switch ui.edge {
        case .right, .left:
            let top = min(max(dock.height * position - size.height / 2, inset), dock.height - size.height - inset)
            let x = ui.edge == .right ? vf.maxX - size.width : vf.minX
            return NSRect(x: x, y: dock.maxY - top - size.height, width: size.width, height: size.height)
        case .top, .bottom:
            let left = min(max(dock.width * position - size.width / 2, inset), dock.width - size.width - inset)
            let y = ui.edge == .top ? vf.maxY - size.height : vf.minY
            return NSRect(x: dock.minX + left, y: y, width: size.width, height: size.height)
        }
    }
}

/// Whether the bar is on its edge: it is, unless the app window is open and in front of the user.
struct BarPresence: Equatable {
    var windowOpen = false
    var windowFront = false
    var barAway: Bool { windowOpen && windowFront }

    /// The window opened (and so came to the front), or closed.
    mutating func opened(_ open: Bool) { windowOpen = open; windowFront = open }
    /// The open window came to the front or went out of sight.
    mutating func front(_ front: Bool) { if windowOpen { windowFront = front } }
}

extension Store {
    /// The pictures the rows are about to show, at the URLs they ask for (the latest actor's, at a row's size): `first`'s
    /// (the page opened, else the tab the inbox opens on) first, then the other categories in order, at most `limit`; and
    /// the account's, at Settings' size. Done's only when it is `first`. None with Triage off.
    func avatarsToWarm(first: InboxTab? = nil, limit: Int = 60) -> [URL] {
        guard triageOn else { return [] }
        var seen = Set<URL>()
        var urls: [URL] = []
        let lead = first ?? tabNeedingYou
        let tabs = [lead] + shownCategories.map { InboxTab.category($0.id) }.filter { $0 != lead }
        scan: for tab in tabs {
            for entry in entries(in: tab) where entry.thing.kind != .workflow {
                guard let url = Avatar.sizedURL(entry.thing.latestActor?.avatar, size: EntryRow.avatar),
                      seen.insert(url).inserted else { continue }
                urls.append(url)
                if urls.count >= limit { break scan }
            }
        }
        if let account = Avatar.sizedURL(me?.avatarUrl, size: SettingsView.accountAvatar) { urls.append(account) }
        return urls
    }
}
