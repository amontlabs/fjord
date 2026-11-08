import AppKit
import SwiftUI

// Fjord as a window: everything the bar holds, with the bar's items as a navigation sidebar. The other mode is
// the bar docked on a screen edge; whoever switches between them calls `show` and listens to `onClose`.

/// How the app is present on the system. An accessory app has no Dock icon and no menu bar; while the app window is open
/// Fjord is a regular app (Dock icon, ⌘-Tab, menu bar).
@MainActor
enum AppPolicy {
    /// The policy the app wants now. A test run keeps it to itself: applied, every test that opens the window would put
    /// its test helper in the Dock and take the focus, and with test runs side by side the Dock fills with them.
    private(set) static var current: NSApplication.ActivationPolicy = .accessory

    /// Regular while `windowOpen`, else accessory (the bar only).
    static func update(windowOpen: Bool) {
        current = windowOpen ? .regular : .accessory
        guard !UnderTest.isRunning else { return }
        if NSApp.activationPolicy() != current { NSApp.setActivationPolicy(current) }
    }

    /// Brings Fjord to the front unless this is a test run, which must not take focus from whoever is at the Mac.
    static func activate() {
        guard !UnderTest.isRunning else { return }
        watchActivations()
        request.asked(active: NSApp.isActive, at: ProcessInfo.processInfo.systemUptime)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The app with windows that was in front before Fjord became active: where the keyboard goes back when the window
    /// closes. It is held strongly (a weak reference would let the workspace release it) and dropped once it has quit.
    private static var previous: NSRunningApplication?
    private static var activations: NSObjectProtocol?

    /// Whether the keyboard can go back to an app: a regular one (a menu-bar or launcher app, such as Raycast or a password
    /// manager, has no window to type in) other than Fjord that is still running.
    static func canTakeFocusBack(policy: NSApplication.ActivationPolicy, isSelf: Bool, terminated: Bool) -> Bool {
        policy == .regular && !isSelf && !terminated
    }

    private static func remember(_ app: NSRunningApplication?) {
        if let app = takingFocusBack(app) { previous = app }
    }

    /// `app`, if the keyboard can go back to it as it is now (`canTakeFocusBack`).
    static func takingFocusBack(_ app: NSRunningApplication?) -> NSRunningApplication? {
        guard let app, canTakeFocusBack(policy: app.activationPolicy, isSelf: app == NSRunningApplication.current,
                                        terminated: app.isTerminated) else { return nil }
        return app
    }

    private static func watchActivations() {
        guard activations == nil else { return }
        activations = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                remember(app)
                // Another app came to the front after the request: it was refused, or has been overtaken.
                if let app, app != NSRunningApplication.current { request.overtaken() }
            }
        }
        remember(NSWorkspace.shared.frontmostApplication)
        becameActive = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                              queue: .main) { _ in
            MainActor.assumeIsolated { becameActiveNow() }
        }
        resignedActive = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { request.resigned() }
        }
    }

    private static var becameActive: NSObjectProtocol?
    private static var resignedActive: NSObjectProtocol?
    /// An activation `activate` asked for, until it lands or the app resigns.
    private static var request = ActivationRequest()

    /// Whether an activation requested by Fjord has yet to land.
    static var activationPending: Bool { request.isPending(at: ProcessInfo.processInfo.systemUptime) }

    /// An activation asked for, from the asking until it lands (`didBecomeActive`), the app resigns or another app comes to
    /// the front (refused, or overtaken), and at most `life` seconds of uptime: long enough for a main thread busy bringing
    /// the window in, short enough that a refusal no one reported can't pass a later activation of the user's for ours.
    struct ActivationRequest: Equatable {
        static let life: TimeInterval = 5
        private(set) var askedAt: TimeInterval?

        /// Asked (`now`: system uptime); none comes when the app is active already.
        mutating func asked(active: Bool, at now: TimeInterval) { if !active { askedAt = now } }

        func isPending(at now: TimeInterval) -> Bool { askedAt.map { now - $0 < Self.life } ?? false }

        /// The app became active: whether that was the activation asked for.
        mutating func landed(at now: TimeInterval) -> Bool {
            defer { askedAt = nil }
            return isPending(at: now)
        }

        mutating func resigned() { askedAt = nil }
        mutating func overtaken() { askedAt = nil }
    }

    /// The close's tidying, as a safety net: still active with no window, while an activation asked for is pending (its
    /// notice still to come), the keyboard goes back.
    static func yieldsAtTidy(active: Bool, windowShown: Bool, pending: Bool) -> Bool { active && !windowShown && pending }
    /// The user made Fjord active (⌘-Tab, the Dock) while its window was closing: the app delegate opens it again.
    static var reopen: (() -> Void)?

    private static func becameActiveNow() {
        let ours = request.landed(at: ProcessInfo.processInfo.systemUptime)
        switch onActivation(ours: ours, windowShown: AppWindowController.anyShown, closing: AppWindowController.anyClosing) {
        case .yield: yieldFocus()
        case .reopen: reopen?()
        case .stay: break
        }
    }

    enum Activation: Equatable { case stay, yield, reopen }

    /// What Fjord does as it becomes active. An activation it asked for (`ours`, an opening's) that lands with no
    /// window open or on its way in (the close was quick: under Reduce Motion, or with no morph) gives the keyboard back
    /// again. One it didn't ask for (⌘-Tab, the Dock) while the window closes is the user asking for it: the window opens
    /// again. Anything else stays (the user's, or a banner's click, which opens what it opens).
    static func onActivation(ours: Bool, windowShown: Bool, closing: Bool) -> Activation {
        if ours { return windowShown ? .stay : .yield }
        return closing ? .reopen : .stay
    }

    /// The keyboard back to the app that had it before, as the window starts closing: what you type next goes there at
    /// once rather than after the close's motion (the Dock icon still goes at its end, `update`). Fjord yields its
    /// activation to that app, which is then asked to the front; with no such app, or one that won't come, Fjord
    /// just stops being active. Nothing when it is not active, or under a test.
    static func yieldFocus() {
        guard !UnderTest.isRunning, NSApp.isActive else { return }
        // Asked again now: it may have quit, or turned into an app without windows, since it was remembered.
        previous = takingFocusBack(previous)
        guard let previous else {
            NSApp.deactivate()
            return
        }
        let asked: Bool
        if #available(macOS 14, *) {
            NSApp.yieldActivation(to: previous)
            asked = previous.activate(from: .current, options: [])
        } else {
            asked = previous.activate(options: [])
        }
        if !asked { NSApp.deactivate() }
    }
}

@MainActor
final class AppWindowController: NSObject, NSWindowDelegate {
    /// The window the Go menu acts on: the last one made.
    static weak var active: AppWindowController?
    /// The controllers whose window has been brought in: whether another is still open when one's close is tidied.
    private static let broughtIn = NSHashTable<AppWindowController>.weakObjects()
    /// Whether a window is open or on its way in (`isOpen`), of those brought in or the last one made.
    static var anyShown: Bool { active?.isOpen == true || broughtIn.allObjects.contains { $0.isOpen } }
    /// Whether a window is on its way out (its close's motion playing).
    static var anyClosing: Bool { active?.phase == .closing || broughtIn.allObjects.contains { $0.phase == .closing } }
    static let autosave = "FjordApp"
    static let minSize = NSSize(width: 1000, height: 600)

    let store: Store
    let navigator: AppNavigator
    let routerModel: RouterModel
    /// Called once the window has closed (by the user or `close()`): the place to put the bar back on its edge.
    var onClose: (() -> Void)?
    /// The screen the bar is docked on: the window opens there. Nil (or no answer) is the main screen.
    var barScreen: () -> NSScreen? = { nil }
    /// Where the bar is, to morph out of when the window opens and into when it closes. Nil: no morph.
    var bar: () -> BarMorph? = { nil }
    /// The window starts closing (its morph is under way): the bar may fade back in now. `onClose` follows.
    var onClosing: (() -> Void)?
    /// The window came to the front, or went out of sight (another app in front, minimized, covered): the bar is away
    /// while the window is in front, and back on its edge otherwise.
    var onFront: ((Bool) -> Void)?
    private var lastFront: Bool?
    private var observers: [NSObjectProtocol] = []
    /// What a morph in progress is, so a new `show` or `close` can take it over.
    private(set) var run: AppTransition.Run?
    private var generation = 0

    /// Where the window is in its morph. The bar's presence is not told of the window's comings and goings meanwhile (the
    /// window is out of sight on purpose), and is told what they came to once it is over.
    enum Phase { case idle, opening, closing }
    private(set) var phase = Phase.idle
    private(set) var window: NSWindow?
    private let checksClaudeCode: Bool
    /// The rows' picked state, Settings' scroll requests and the category editor's step back, shared by the destinations.
    let hub = HubState()
    private lazy var keys: RouterKeys = {
        let keys = RouterKeys(store: store, model: routerModel)
        keys.openPalette = { [weak self] in self?.palette.open() }
        return keys
    }()
    /// The inbox's search, and the keys of the inbox destinations (see `AppWindowKeys`).
    let search = InboxSearch()
    private(set) lazy var inboxKeys: AppWindowKeys = {
        let keys = AppWindowKeys(store: store, navigator: navigator, hub: hub, search: search)
        keys.openPalette = { [weak self] event in self?.palette.open(replaying: event) }
        keys.openInRouter = { [weak self] thing in
            guard let self else { return }
            routerModel.open(thing: thing, in: navigator)
        }
        return keys
    }()
    /// The ⌘K palette over the window (see `PaletteModel`).
    private let remembers: Bool
    private(set) lazy var palette = PaletteModel(store: store, navigator: navigator, routerModel: routerModel, hub: hub,
                                                 usage: remembers ? PaletteUsage(defaults: .standard) : nil)
    private var monitor: Any?
    /// The window's corner radius, for the root's shapes.
    let corner = WindowCorner()
    /// The window's capture flag: its glass pieces draw their stand-ins while the morph takes its picture (`GlassCapture`).
    let capture = GlassCapture()

    /// `routerModel`: the Router's chat state, shared with whatever else shows the Router. `remembers`: open on the place left
    /// last (off for shots and tests).
    init(store: Store, routerModel: RouterModel? = nil, remembers: Bool = true, checksClaudeCode: Bool = true) {
        self.store = store
        self.routerModel = routerModel ?? RouterModel()
        self.checksClaudeCode = checksClaudeCode
        self.remembers = remembers
        navigator = AppNavigator(fallback: store.firstPlace, defaults: remembers ? .standard : nil)
        super.init()
        // The place changed by whatever changes it (the Go menu, back and forward, a chip) while the window is on its way
        // in: the overlay shows the new one.
        navigator.onChange = { [weak self] in self?.contentChanged() }
        Self.active = self
        settle()
        Self.watchMemory()
    }

    /// The system short of memory: the window made last lets go of what it keeps only to open faster (see `releaseKept`),
    /// and keeps nothing more until memory is back (see `memoryShort`).
    private static var memoryWatch: DispatchSourceMemoryPressure?

    private static func watchMemory() {
        guard memoryWatch == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler {
            let event = source.data
            MainActor.assumeIsolated { active?.memoryPressure(elevated: !event.contains(.normal)) }
        }
        source.resume()
        memoryWatch = source
    }

    /// Whether the system is short of memory (a warning or a critical pressure, until it says normal again): the window
    /// prepares nothing, keeps no picture at a close, and lets go of its content once a close has taken it out.
    private(set) var memoryShort = false

    /// The system's memory pressure went up (`elevated`) or back to normal.
    func memoryPressure(elevated: Bool) {
        memoryShort = elevated
        if elevated { releaseKept() }
    }

    /// Lets go of the picture kept from the last close and, while the window is closed, of its content (a window's worth
    /// of views, and the picture some 15 MB): the next opening makes them again, as a first one does. Content still in the
    /// window stays (a close under way takes it out a turn later, and lets go of it then while memory is short).
    func releaseKept() {
        closedPicture = nil
        guard phase == .idle, pending == nil, window?.isVisible != true, window?.contentViewController == nil else { return }
        content = nil
    }

    /// Whether a picture from the last close is kept for the next opening.
    var keepsPicture: Bool { closedPicture != nil }

    /// Open, or on its way in (its morph plays before the window itself is in); one on its way out is closed already (a
    /// toggle opens it again).
    var isOpen: Bool { phase == .opening || (phase != .closing && window?.isVisible == true) }
    /// Whether the palette is over the window: the menus' window actions wait for it to close.
    var paletteIsOpen: Bool { palette.isOpen }
    /// What the window shortcut does: close the window you are looking at (or one on its way in), else bring it in front.
    /// A window open behind another app or minimized comes forward: closing it would leave nothing to see.
    var shortcutCloses: Bool { Self.shortcutCloses(phase: phase, front: isFront) }

    static func shortcutCloses(phase: Phase, front: Bool) -> Bool { phase == .opening || (phase == .idle && front) }
    /// The window's content, kept while the window is closed: out of the window it stands still (no body runs, no clock,
    /// timeline or animation ticks, its tasks are cancelled), and back in it picks up where it was, its scroll positions and
    /// the rest of its state kept, its appearing (`onAppear`, `.task`, `onChange(initial:)`) run again as on a first open.
    private(set) var content: NSViewController?
    /// The window's picture as it was last seen: kept the window as drawn while it is open and still (`keepPicture`), so a
    /// close starts on it with nothing captured, then kept from the close for the next opening to start on (see
    /// `startOpening`), until the window has stayed closed `keptPictureLife`.
    private var closedPicture: AppTransition.Picture?
    /// Input to the window and what was asked of it, counted (see `AppTransition.Marks`).
    private var changes = 0
    private var inputWatch: Any?
    /// Keeps `closedPicture` fresh while the window is open (see `keepPicture`): its next look, and whether it keeps.
    private var pictureKeeper: Timer?
    private var keeping = false
    /// The keeper's last look at a window that had moved on from its picture, and the marks then: a picture is taken only
    /// once the next look finds it alike (the window at rest).
    private var restGlance: (glance: AppTransition.Glance, marks: AppTransition.Marks)?
    /// Lets go of `closedPicture` once the window has stayed closed `keptPictureLife`.
    private var pictureExpiry: DispatchWorkItem?
    /// How long a closed window keeps its picture (some 15 to 30 MB): by then what it shows has likely moved on (its times,
    /// its counts), so an opening would not hand over on it anyway.
    static let keptPictureLife: TimeInterval = 300
    /// An opening whose window is still to be brought in: its generation.
    private var pending: Int?
    /// The morph under way, from its request to its overlay gone: its signpost interval, and the motion gate it holds.
    private var span = MorphSpan()
    /// Whether the window has the keyboard, or is about to.
    var isKey: Bool { window?.isKeyWindow == true || pending != nil }

    /// Shows the window in front, on `destination` when one is given (else where it was left). `entry`: a brief entry to focus
    /// (it opens on the Router).
    func show(_ destination: AppDestination? = nil, entry: BriefTarget? = nil) {
        // Until the opening's first frame is flushed (see `startOpening`), or at once when there is no morph.
        let asked = MorphSignposts.signposter.beginInterval("Open to first flush")
        defer { MorphSignposts.signposter.endInterval("Open to first flush", asked) }
        LatencySignposts.windowAsked()
        // Taken somewhere else (a shortcut, a notification): the palette would cover the new place.
        palette.close(restoringFocus: false)
        Self.active = self
        settle()
        var destination = destination
        if entry != nil { destination = .router }
        if let entry {
            store.routerBriefs.focus(entry)
            changes &+= 1
        }
        // Another place, while on its way in: the navigator says so (see `init`).
        if let destination { navigator.go(destination.resolved(shown: shownIDs, tools: store.tools)) }
        let window = self.window ?? makeWindow()
        self.window = window
        // Opened again: the kept picture is wanted after all.
        pictureExpiry?.cancel()
        pictureExpiry = nil
        // A window on its way out comes back from where it is (minimized on its way in included: its close's end would close
        // it otherwise); one on its way in just goes on.
        let reversing = phase == .closing && run != nil
        let arriving = phase == .opening
        let opening = !arriving && (reversing || (!window.isVisible && !AppTransition.isMiniaturized(window)))
            && AppTransition.enabled
        if !window.isVisible && !reversing && !arriving {
            if UnderTest.isRunning { window.setFrameOrigin(UnderTest.away) } else { moveToBarScreen(window) }
        }
        // The bar as it is now, before whoever called us hides it.
        let morph = opening && !reversing && !AppTransition.reduceMotion ? bar() : nil
        if opening {
            // A live close fade reverses from what is on screen, without a transparent frame in between.
            if !reversing || !window.isVisible { window.alphaValue = 0 }
            window.ignoresMouseEvents = true
            startOpening(window, bar: morph, reversing: reversing)
        } else {
            // One on its way in with its window still to come gets it then.
            if pending == nil { bringIn(window) }
        }
        // The app regular and asked to the front in this turn, after the opening's first frame is submitted: the activation
        // (the window's keyboard, and so the opening's fresh picture, wait for it) goes on while the window is brought in,
        // rather than being asked only once it is.
        AppPolicy.update(windowOpen: true)
        AppPolicy.activate()
        // An entry picked on the way in: the place may be the same, what it shows is not.
        if entry != nil, arriving { contentChanged() }
        watchKeys()
        watchInput()
        watchFront()
        reportFront()
    }

    /// The window and its content made ahead of a first open, at idle, so that open only brings them in (see `bringIn`): the
    /// window is not ordered in, the app's policy and the bar are not told, and the content is built and laid out at the
    /// window's size, then taken out of it again, where it stands still as after a close. A content that was never in a
    /// window would not: laid out, it runs its body and appearing and redraws on every change of the store behind it. No-op
    /// once the content exists or while the window is open or on its way. No close is involved, so nothing a close leaves
    /// for later (see `windowWillClose`) is either.
    func prepare() {
        guard content == nil, phase == .idle, pending == nil, window?.isVisible != true, !memoryShort else { return }
        settle()
        let window = self.window ?? makeWindow()
        self.window = window
        let content = makeContent(size: window.contentRect(forFrameRect: window.frame).size)
        self.content = content
        seedCorner(window)
        window.contentViewController = content
        content.view.layoutSubtreeIfNeeded()
        window.contentViewController = nil
    }

    /// What shows the window: its content (built once, kept across closes), the window in front with the keyboard (once the
    /// app is active: `show` asks for that). The heavy part of an opening, which waits until its morph's first frame has
    /// been submitted.
    private func bringIn(_ window: NSWindow) {
        let signpost = MorphSignposts.signposter.beginInterval("Bring in")
        defer { MorphSignposts.signposter.endInterval("Bring in", signpost) }
        if window.contentViewController == nil {
            // The window takes its content's size: kept content is given the window's as it is now (it may have been fitted
            // to a smaller screen since), new content is made at it.
            let size = window.contentRect(forFrameRect: window.frame).size
            let content = self.content ?? makeContent(size: size)
            if content.view.frame.size != size { content.view.setFrameSize(size) }
            self.content = content
            seedCorner(window)
            // What changed while it was out is drawn as it is now, not played as it goes back in: from before the window takes
            // it until it has been laid out and drawn, and a turn after.
            WindowArrival.appWindow.arrive(laying: content.view)
            window.contentViewController = content
        }
        Self.broughtIn.add(self)
        window.makeKeyAndOrderFront(nil)
    }

    /// The window opens: the overlay grows out of the bar's cell (or picks up from where a close had got to) while the real
    /// window waits at its frame, invisible; then the real window takes over under the overlay. The motion comes first: the
    /// overlay starts on the picture kept from the last close (or the window's bare surface) and its first frame is flushed
    /// to the render server (submitted: drawn as soon as the server can) before the window is built and brought in, a turn
    /// later, which gives it a fresh picture.
    private func startOpening(_ window: NSWindow, bar: BarMorph?, reversing: Bool) {
        phase = .opening
        // A live close fade turned round stays above the bare overlay until that overlay is gone.
        let reversingLive = reversing && window.isVisible
        if !reversingLive { restoreLevel() }
        // Work that can wait holds until the window has handed over (`handedOver`), or a close that takes over ends.
        span.begin("Open")
        generation += 1
        let mine = generation
        if reversingLive { AppTransition.fadeWindow(window, 1, {}) }
        stopKeepingPicture()
        let current: AppTransition.Run?
        let chrome = glassWindow(window)
        let glass = AppTransition.usesGlass
        // Taken in another appearance, at another size or scale, with the sidebar folded otherwise: not even for a moment.
        let kept = closedPicture.flatMap { $0.fits(window, glass: glass, sidebar: chrome.sidebar) ? $0 : nil }
        if reversing, let run {
            // Keep the overlay's bounds and coordinate origin for the whole trip, including this reversal.
            current = run
        } else {
            run?.end()
            current = AppTransition.makeRun(for: window, picture: kept, bar: bar, glassWindow: chrome, glass: glass)
        }
        run = current
        guard let current else {
            bringIn(window)
            reveal(window)
            finishOpening(mine)
            return
        }
        // Whatever the overlay starts on is checked against the window at the handoff, and nothing is captured on the way:
        // a picture still the window's is cut to the real window on, any other (none, another place's, one the window has
        // moved on from since) fades into it.
        pending = mine
        // The real window takes clicks only once it shows, at the handoff (`reveal`): before, the overlay may show another
        // page than the one a click would land on, or the glass still be some 15 to 23 pt off its frame.
        current.open(reduced: AppTransition.reduceMotion || current.bar == nil) { [weak self, weak window] in
            guard let self, let window, self.generation == mine else { return }
            // The real window must be in before it takes over. No picture is taken now: it would hold the handoff up. The
            // overlay cuts to the real window when its picture is the window as drawn now, and fades into it otherwise.
            self.bringInPending(mine)
            // Looked at again whatever was checked before (a few ms, within the handoff's two-refresh lead): what the
            // window's appearing changed a turn after the last look must not pop as the overlay cuts away.
            let exact = current.picture?.exact == true && current.glance != nil
                && AppTransition.glance(of: window)?.same(as: current.glance) == true
            // Work that can wait goes once the real window shows (the overlay's shadow fades on the render server).
            let checked = self.marks
            current.handoff(fading: !exact, stillExact: { [weak self] in self?.marks == checked },
                            reveal: { self.reveal(window) }, handedOver: { self.handedOver(mine) },
                            finished: { self.finishOpening(mine) })
        }
        // The motion submitted to the render server, nothing captured or built yet: the rest waits a turn.
        AppTransition.flushInitial()
        AppTransition.nextTurn { [weak self] in self?.bringInPending(mine) }
    }

    /// The window of the opening `mine` brought in, if it is not yet.
    private func bringInPending(_ mine: Int) {
        guard pending == mine, generation == mine, phase == .opening, let window else { return }
        pending = nil
        bringIn(window)
        // Laid out and drawn now, while the overlay moves on the render server (still invisible, its layers committed with
        // this turn): the window's first drawing after a close (some 20 to 30 ms, far more on a first opening) is then
        // done by the handoff, which otherwise waited on it before the real window could show.
        let warming = MorphSignposts.signposter.beginInterval("Warm window")
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        MorphSignposts.signposter.endInterval("Warm window", warming)
    }

    /// What may have changed the window since a picture was taken, besides its pixels (see `AppTransition.Marks`).
    var marks: AppTransition.Marks {
        AppTransition.Marks(changes: changes, inbox: store.inboxRevision, inboxDisplay: store.inboxDisplayRevision,
                            router: store.routerRevision, shown: store.shownRevision)
    }

    /// Counts the user's input to the window (a key, a click, a scroll; not the pointer's moves, whose hovers are noise),
    /// for `marks`.
    private func watchInput() {
        guard inputWatch == nil else { return }
        inputWatch = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                                 .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                self.changes &+= 1
                self.nudgeKeeper()
            }
            return event
        }
    }

    /// While the window is open, in front and has the keyboard (started as it opens or becomes key, stopped as it resigns
    /// it or closes), its picture is kept the window as drawn, so a close starts on it at once with nothing captured:
    /// half a second after it starts then about every second, once nothing was pressed or moved for three times what a
    /// picture would cost (half a second at least), and no text is being composed, a glance says whether the window still
    /// is what `closedPicture` shows, and when it isn't a picture is taken there and then, soft when a sharp one would
    /// cost over `idleCaptureBudget`, at most a twentieth of the main thread's time (`mayCaptureAtIdle`). Not short of
    /// memory.
    func keepPictureFresh() {
        // Only for a window there to close: shown, with the keyboard, in front.
        guard AppTransition.enabled, let window, window.isVisible, AppTransition.isKey(window), AppTransition.isFront(window)
        else { return }
        keeping = true
        keeperPace = Self.keeperPaces.shortest
        scheduleKeeper(after: keeperPace)
    }

    /// The keeper's looks: every half second while the window changes, twice as far apart (up to 4 s) each look that
    /// finds nothing to do; back to half a second on the user's input.
    static let keeperPaces = (shortest: 0.5, longest: 4.0)

    private func scheduleKeeper(after delay: TimeInterval) {
        pictureKeeper?.invalidate()
        // One look at a time: a controller gone takes its keeper with it, as no further look is asked.
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated {
                self.pictureKeeper = nil
                self.keepPicture()
            }
        }
        timer.tolerance = delay / 4
        // The default mode only: not while a scroll, a drag or a menu tracks.
        RunLoop.main.add(timer, forMode: .default)
        pictureKeeper = timer
    }

    private func stopKeepingPicture() {
        keeping = false
        restGlance = nil
        pictureKeeper?.invalidate()
        pictureKeeper = nil
    }

    /// The user did something to the window: the keeper looks again soon.
    private func nudgeKeeper() {
        guard keeping else { return }
        keeperPace = Self.keeperPaces.shortest
        if let fire = pictureKeeper?.fireDate, fire.timeIntervalSinceNow <= keeperPace { return }
        scheduleKeeper(after: keeperPace)
    }

    /// How far apart the keeper's looks are now (see `keeperPaces`).
    private(set) var keeperPace = keeperPaces.shortest

    /// The kept picture let go once the window has stayed closed `after` (an opening calls it off).
    private func expireKeptPicture(after: TimeInterval) {
        pictureExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .idle, self.window?.isVisible != true else { return }
                self.closedPicture = nil
                self.pictureExpiry = nil
            }
        }
        pictureExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: expiry)
    }

    /// Whether the kept picture is a soft one (see `AppTransition.reducedScale`).
    var keptPictureIsSoft: Bool { closedPicture?.exact == false }

    /// Whether the kept picture is to be let go (the window closed, and not opened since).
    var keptPictureExpires: Bool { pictureExpiry != nil }

    /// The idle keeper's timer, while it runs (the tests look).
    var keeperTimer: Timer? { pictureKeeper }

    /// The picture the keeper would keep, taken at once at the window's own scale whatever its pace, phase or budget: for
    /// the tests, which have no idle to wait for.
    func keepPictureNow() {
        guard let window, !memoryShort else { return }
        closedPicture = AppTransition.picture(of: window, glassWindow: glassWindow(window), glass: AppTransition.usesGlass,
                                              destination: navigator.selection, marks: marks)
    }

    /// One look of the idle keeper (see `keepPictureFresh`).
    func keepPicture() {
        defer { if keeping, pictureKeeper == nil { scheduleKeeper(after: keeperPace) } }
        func slower() { keeperPace = min(keeperPace * 2, Self.keeperPaces.longest) }
        guard let window, window.isVisible else { return stopKeepingPicture() }
        guard phase == .idle, !memoryShort, AppTransition.isFront(window), AppTransition.isKey(window), !MotionGate.moving,
              !AppTransition.composing(in: window) else { return }
        let full = window.backingScaleFactor, soft = AppTransition.reducedScale(of: window)
        let page = AppTransition.page(navigator.selection)
        // The sharpest picture sure to be within the budget on this page, if any (`costs`).
        func choice() -> (scale: CGFloat, cost: CFTimeInterval)? {
            for scale in [full, soft] {
                let cost = AppTransition.estimate(window, pixelScale: scale, page: page)
                if cost <= AppTransition.idleCaptureBudget { return (scale, cost) }
            }
            return nil
        }
        // Idle long enough that a key typed after a pause like this one is not likely to wait on what the look draws.
        let planned = choice()
        guard AppTransition.inputIdle(max(0.5, 3 * (planned?.cost ?? AppTransition.idleCaptureBudget))) else {
            keeperPace = Self.keeperPaces.shortest
            return
        }
        let chrome = glassWindow(window)
        let glass = AppTransition.usesGlass
        let marks = self.marks
        let kept = closedPicture.flatMap {
            $0.fits(window, glass: glass, sidebar: chrome.sidebar) && $0.destination == navigator.selection ? $0 : nil
        }
        // As good as the keeper would make it (sharp, or soft when sharp costs too much).
        let good = kept.map { $0.exact || (planned?.scale ?? soft) < full } ?? false
        // Nothing typed, clicked, asked or synced since the kept picture: it still stands, with no glance (what moved
        // since is the window's own noise, a ticking duration or the thinking dots, which a close forgives), but at the
        // slowest pace, when a glance checks it moved no further than noise (what changes on its own, unmarked).
        let now: AppTransition.Glance?
        if let kept, good, kept.marks == marks {
            guard keeperPace >= Self.keeperPaces.longest else { return slower() }
            now = AppTransition.glance(of: window, page: page)
            if now?.within(AppTransition.Glance.closeTolerance, of: kept.glance) == true { return }
            // Moved on unmarked: no longer forgiven, and taken again once at rest.
            closedPicture?.marks = nil
        } else {
            now = AppTransition.glance(of: window, page: page)
        }
        if let kept, good, now?.same(as: kept.glance) == true {
            closedPicture?.marks = marks
            return slower()
        }
        // A picture only of a window at rest: two looks in a row alike (but for noise), nothing happening between.
        guard let rest = restGlance, rest.marks == marks,
              now?.within(AppTransition.Glance.closeTolerance, of: rest.glance) == true else {
            restGlance = now.map { ($0, marks) }
            keeperPace = Self.keeperPaces.shortest
            return
        }
        // Never one that may cost more than the budget, by what this page has cost lately (the glance just drawn included):
        // a close without a fresh picture fades the live window instead.
        guard let (scale, cost) = choice(), AppTransition.mayCaptureAtIdle(cost: cost) else {
            // An expensive canvas still settles: skipping its capture must not redraw a glance every half second.
            slower()
            return
        }
        if let picture = AppTransition.picture(of: window, glassWindow: chrome, glass: glass,
                                               destination: navigator.selection, glance: now, pixelScale: scale,
                                               marks: marks) {
            closedPicture = picture
            restGlance = nil
            slower()
        }
    }

    /// Something else asked of the window (another place, a card, a row or a section), open or on its way in: no picture
    /// taken before stands for it, whatever its pixels (an opening's handoff then fades).
    private func contentChanged() {
        changes &+= 1
    }

    /// What the glass morph needs of `window`: its capture flag, and its inset sidebar's frame (none during the onboarding,
    /// nor before macOS 26).
    private func glassWindow(_ window: NSWindow) -> AppTransition.GlassWindow {
        var sidebar: NSRect?
        if #available(macOS 26, *), store.settings.toolsPicked == true {
            sidebar = GlassMorph.sidebarFrame(windowSize: window.frame.size, collapsed: SidebarState.shared.collapsed)
        }
        return AppTransition.GlassWindow(capture: capture, sidebar: sidebar)
    }

    /// The real window, shown (under the overlay), with the keyboard.
    private func reveal(_ window: NSWindow) {
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.makeKeyAndOrderFront(nil)
    }

    /// The opening `mine` has handed over: its interval ends and the motion gate opens.
    private func handedOver(_ mine: Int) {
        guard generation == mine else { return }
        span.end()
    }

    private func finishOpening(_ mine: Int) {
        guard generation == mine else { return }
        // A reopened live close stays above the opaque bare overlay through the refresh wait and its fade.
        // The run has ordered that overlay out before calling us, so lowering the window cannot hide its content.
        restoreLevel()
        // The picture the overlay handed over on is kept as it was taken (with the glance of what it shows), so a close at
        // once starts on it when the window is still that (near enough); the idle keeper takes another once it has moved on.
        if let run, let picture = run.picture, picture.key, picture.glance != nil, !memoryShort {
            closedPicture = picture.handedOver(fading: run.fadesOut)
        } else {
            closedPicture = nil
        }
        run = nil
        phase = .idle
        span.end()
        keepPictureFresh()
        reportFront()
    }

    func close() {
        // The overlay can reverse before its window is brought in: cancel that turn without building or warming content.
        if pending != nil, phase == .opening, let window {
            if windowShouldClose(window) { window.close() }
            return
        }
        window?.performClose(nil)
    }

    /// Closing morphs the window into the bar: an overlay takes the window's place first, then the real window goes and the
    /// overlay shrinks into the bar's cell, then it really closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        palette.close(restoringFocus: false)
        guard AppTransition.enabled, phase != .closing, phase == .opening || isFront else { return phase != .closing }
        // Until the close's first frame is flushed: the time to the first moving frame.
        let asked = MorphSignposts.signposter.beginInterval("Close to first flush")
        // An opening whose overlay has let go of its picture shows the real window already: it closes as an open one does.
        let interrupting = phase == .opening && run?.handedOver != true
        let unshown = phase == .opening && pending != nil && !sender.isVisible
        // One that has let go but whose overlay is still fading out over the real window (its picture, or its shadow):
        // the close takes that overlay over, rather than dropping it half faded.
        let fading = phase == .opening && !interrupting && run?.ended == false ? run : nil
        phase = .closing
        // Held until the overlay is gone (`finishClosing`), or an opening that turns it round has handed over.
        span.begin("Close")
        generation += 1
        let mine = generation
        pending = nil
        sender.ignoresMouseEvents = true
        stopKeepingPicture()
        let existing = interrupting ? run : nil
        let current: AppTransition.Run?
        var liveFade = false
        var blended = false
        let chrome = glassWindow(sender)
        if let existing {
            current = existing
        } else {
            if fading == nil { run?.end() }
            let glass = AppTransition.usesGlass
            let barMorph = AppTransition.reduceMotion ? nil : bar()
            // The picture kept at idle, when the window is still (near enough, `Glance.closeTolerance`, nothing having
            // happened to it since) as it was drawn then: the close starts on it at once. Nothing is ever captured here
            // (what a capture costs depends on what the window shows: up to 520 ms); without such a picture the live
            // window fades out in place over the overlay shrinking beneath it.
            // The picture an opening still fading out just handed over on is newer than the kept one: looked at first.
            let eligible = [fading?.picture, closedPicture].compactMap { $0 }.filter {
                $0.fits(sender, glass: glass, sidebar: chrome.sidebar) && AppTransition.isKey(sender)
                    && $0.destination == navigator.selection && $0.glance != nil
            }
            // A glance is work only a candidate can justify: a bare close starts moving without drawing the window.
            let now = eligible.isEmpty ? nil : AppTransition.glance(of: sender)
            let picture = eligible.first {
                AppTransition.freshness(of: $0, glance: now, marks: marks, destination: navigator.selection,
                                        tolerance: AppTransition.Glance.closeTolerance) != .stale
            }
            // The overlay still fading out is taken over only when it stands where this close would put one.
            let compatible = fading.map {
                $0.isGlass == glass && $0.windowFrame == sender.frame && $0.sidebar == chrome.sidebar
                    && $0.windowRadius == AppTransition.cornerRadius(of: sender)
            } ?? false
            if let fading, compatible, fading.fadingContent {
                // Its picture half faded into the real window: the close goes on from that blend, the live window fading
                // out under it, rather than jumping back to a picture whole.
                fading.resume()
                current = fading
                blended = true
            } else if let fading, compatible {
                // Only its shadow still fading: back on the window's picture whole (or its bare surface).
                fading.takeBack(picture)
                current = fading
                liveFade = picture == nil
            } else {
                fading?.end()
                current = AppTransition.makeRun(for: sender, picture: picture, bar: barMorph, glassWindow: chrome,
                                                glass: glass)
                liveFade = picture == nil
            }
        }
        guard let current else {
            MorphSignposts.signposter.endInterval("Close to first flush", asked)
            finishClosing(sender, mine, unshown: unshown)
            return false
        }
        run = current
        // Kept for the next opening to start on, when it was taken with the window key, as it was taken (an opening cut
        // short may still show the place, the sidebar or the size it started on), unless memory is short.
        if !memoryShort, let picture = current.picture, picture.key {
            // One half faded into the real window was not the window: no small difference is forgiven it.
            closedPicture = picture.handedOver(fading: blended)
        }
        if liveFade {
            // Above the overlay for its fade: the overlay's bare surface and glass shrink beneath the window going.
            liftedLevel = liftedLevel ?? sender.level
            sender.level = NSWindow.Level(rawValue: current.overlay.level.rawValue + 1)
        }
        if !interrupting, !blended {
            // The overlay shows the window before the real one goes, in this turn: its frame is submitted to the render
            // server ahead of the window going, which reaches the server after it, so no frame shows neither.
            current.present()
            CATransaction.flush()
        }
        // Out of sight at once (a window's alpha is cheap); ordered out only once the motion is submitted, as ordering a
        // key window out takes some 11 ms (its key and main status handed on). After the overlay's flush, not inside its
        // transaction: if AppKit sends the alpha with the next commit, it lands with or after the overlay either way; if it
        // sends it at once, only this order has the overlay's frame reach the server first.
        if liveFade || blended {
            AppTransition.fadeWindow(sender, 0) { [weak self, weak sender] in
                guard let self, let sender, self.generation == mine else { return }
                sender.orderOut(nil)
                self.restoreLevel()
            }
        } else {
            sender.alphaValue = 0
        }
        current.close(reduced: AppTransition.reduceMotion || current.bar == nil) { [weak self, weak sender] in
            guard let self, let sender, self.generation == mine else { return }
            self.finishClosing(sender, mine, unshown: unshown)
        }
        MorphSignposts.signposter.endInterval("Close to first flush", asked)
        if generation == mine, !liveFade, !blended { sender.orderOut(nil) }
        if generation == mine { onClosing?() }
        return false
    }

    /// The window's own level, while a close's live fade has it above the overlay.
    private var liftedLevel: NSWindow.Level?

    private func restoreLevel() {
        guard let liftedLevel else { return }
        window?.level = liftedLevel
        self.liftedLevel = nil
    }

    private func finishClosing(_ window: NSWindow, _ mine: Int, unshown: Bool) {
        guard generation == mine else { return }
        run?.end()
        run = nil
        phase = .idle
        span.end()
        restoreLevel()
        window.orderOut(nil)
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        if unshown {
            // A cancelled bring-in can reuse an already closed NSWindow, which sends no second willClose notification.
            windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        } else {
            window.close()
        }
    }

    /// Whether the window is in front of the user: the app is active and the window is on screen and not covered.
    var isFront: Bool { isFront(active: NSApp.isActive) }

    func isFront(active: Bool) -> Bool {
        guard active, let window, window.isVisible, !window.isMiniaturized else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// Tells `onFront` when that changes. `active` is passed by the notifications that know it before `NSApp` does.
    func reportFront(active: Bool = NSApp.isActive) {
        guard phase == .idle else { return }
        let front = isFront(active: active)
        guard front != lastFront else { return }
        lastFront = front
        onFront?(front)
    }

    private func watchFront() {
        guard observers.isEmpty, let window else { return }
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, object: AnyObject?, active: Bool? = nil) {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let active { self?.reportFront(active: active) } else { self?.reportFront() }
                }
            })
        }
        watch(NSApplication.didResignActiveNotification, object: nil, active: false)
        watch(NSApplication.didBecomeActiveNotification, object: nil, active: true)
        watch(NSWindow.didChangeOcclusionStateNotification, object: window)
        watch(NSWindow.didMiniaturizeNotification, object: window)
        watch(NSWindow.didDeminiaturizeNotification, object: window)
        // Fjord made active (⌘-Tab) while the window is open behind another app or minimized: the window comes
        // in front, as any app's does. The bar never makes the app active, so this is the user asking for
        // Fjord.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.raise() }
        })
    }

    private func raise() {
        guard phase == .idle, pending == nil, let window, window.isVisible || window.isMiniaturized,
              !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// Opening puts the window on the bar's screen, where it was left if that is the one, else at the same place relative
    /// to the screen it was on.
    private func moveToBarScreen(_ window: NSWindow) {
        guard let target = barScreen() ?? NSScreen.main else { return }
        let screens = NSScreen.screens
        let previous = screens.max { overlap(window.frame, $0.visibleFrame) < overlap(window.frame, $1.visibleFrame) }
        let from = previous.flatMap { overlap(window.frame, $0.visibleFrame) > 0 ? $0.visibleFrame : nil }
        let frame = AppWindowPlacement.frame(window.frame, from: from, in: target.visibleFrame)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    private func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// Settings, scrolled to Updates: where Check for Updates shows what it found. The request is the window's own, so it
    /// reaches the Settings page shown here whether it opens now or was open already.
    func showUpdates() {
        show(.settings)
        hub.showUpdates()
        contentChanged()
    }

    /// An inbox entry picked and scrolled to, on its category (the archive if it was archived since): where a banner's click lands.
    func show(entry: InboxEntry) {
        show(entry.isDone ? .done : .category(entry.categoryID))
        hub.selection = "i:" + entry.id
        hub.requestScroll("i:" + entry.id)
        contentChanged()
    }

    /// A brief entry picked from the bar (the window opens on the Router next).
    func pick(entry: BriefTarget) {
        store.routerBriefs.focus(entry)
        contentChanged()
    }

    /// A message asked for from the bar: the Router's history drawer opens (the window opens on the Router next).
    func pick(message: UUID) {
        store.routerBriefs.drawerOpen = true
        contentChanged()
    }

    /// A thing's "Open in Router" from the bar: its pill in the Router's composer (the window opens on the Router next).
    func prefillRouter(thing: String) {
        routerModel.prefill([.notification(thing)])
        contentChanged()
    }

    /// The Go menu's destinations with their titles, in the sidebar's order (none during the onboarding).
    var goItems: [GoMenuModel.Item] {
        guard store.settings.toolsPicked == true else { return [] }
        return GoMenuModel.items(AppDestination.all(shown: shownIDs, tools: store.tools)) { title(for: $0) }
    }

    func title(for destination: AppDestination) -> String {
        switch destination {
        case .category(let id): store.categories.first { $0.id == id }?.title ?? "Inbox"
        case .done: "Archive"
        case .router: "Router"
        case .settings: "Settings"
        case .categories: "Inbox categories"
        case .snippets: "Snippets"
        }
    }

    private var shownIDs: [UUID] { store.shownCategories.map(\.id) }

    /// Keeps the selection on a place that exists.
    private func settle() { navigator.settle(shown: shownIDs, tools: store.tools) }

    /// `size`: the window's content size, so that setting the content keeps the window as it is (left alone, the content
    /// would size it to its own minimum, too small to see).
    private func makeContent(size: NSSize) -> NSViewController {
        let root = AppRootView(store: store, navigator: navigator, routerModel: routerModel, hub: hub, search: search,
                               palette: palette, checksClaudeCode: checksClaudeCode, corner: corner, capture: capture)
        let controller = NSHostingController(rootView: root)
        // The window sizes the content, not the other way round.
        controller.sizingOptions = []
        controller.view.frame = NSRect(origin: .zero, size: size)
        return controller
    }

    private func makeWindow() -> NSWindow {
        let window = AwayWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 1180, height: 760)),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: true)
        Self.style(window)
        window.delegate = self
        if !window.setFrameUsingName(Self.autosave) { window.center() }
        window.setFrameAutosaveName(Self.autosave)
        return window
    }

    /// The window's look: dark like the bar's panels, the content running up under a transparent unified title bar.
    static func style(_ window: NSWindow) {
        window.title = "Fjord"
        window.isReleasedWhenClosed = false
        window.minSize = minSize
        window.appearance = Brand.appearance
        window.backgroundColor = NSColor(CDS.Surface.s1)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.allowsToolTipsWhenApplicationIsInactive = true
        TrafficLights.place(window)
    }

    /// The Router's keys (see `RouterKeys`) while the window is key and shows the Router; Esc dismisses a tooltip first.
    private func watchKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated {
                // The onboarding has no page's keys: only its own fields and button.
                guard let window = self.window, window.isKeyWindow, event.window === window,
                      !self.store.isRecordingShortcut, self.store.settings.toolsPicked == true else { return false }
                if TipCenter.dismissVisible(for: event) { return true }
                // The palette: ⌘K opens and closes it, and while it is open every other key is its own field's.
                if Shortcut(event) == Palette.shortcut {
                    self.palette.toggle()
                    return true
                }
                if self.palette.isOpen { return self.palette.takes(event) }
                return self.navigator.selection == .router ? self.keys.key(event) : self.inboxKeys.key(event)
            }
            return consumed ? nil : event
        }
    }

    // AppKit lays the window's three buttons out again on these: they go back on the header's line each time.
    func windowDidResize(_ notification: Notification) { window.map(TrafficLights.place) }
    func windowDidBecomeKey(_ notification: Notification) {
        window.map(TrafficLights.place)
        readCorner()
        // Back in front with the keyboard (after a minimize, a hide, another app): the keeper looks again.
        if phase == .idle { keepPictureFresh() }
    }
    /// Out of the keyboard: nothing to close from, so no picture to keep fresh, and no wakeups.
    func windowDidResignKey(_ notification: Notification) {
        stopKeepingPicture()
    }
    func windowDidEnterFullScreen(_ notification: Notification) { readCorner() }
    func windowDidExitFullScreen(_ notification: Notification) {
        window.map(TrafficLights.place)
        readCorner()
    }

    /// The window's corner radius as it is now, for the root's `containerShape` (none in full screen).
    private func readCorner() {
        guard let window else { return }
        let radius = AppTransition.cornerRadius(of: window)
        if window.isVisible, !window.styleMask.contains(.fullScreen) { Self.knownRadius = radius }
        if corner.radius != radius { corner.radius = radius }
    }

    /// The radius a window shown last reported, out of full screen: the next content starts with it.
    private static var knownRadius: CGFloat?

    /// The radius the content will have, given before it goes in (or is made), so that reading it again as the window
    /// becomes key changes nothing: a change then would redraw the root's shapes in the middle of the opening.
    private func seedCorner(_ window: NSWindow) {
        let radius = window.styleMask.contains(.fullScreen) ? 0 : Self.knownRadius ?? AppTransition.cornerRadius(of: window)
        if corner.radius != radius { corner.radius = radius }
    }

    func windowWillClose(_ notification: Notification) {
        // Every close, a morph's or not (a window closed out of sight): the keeper stops, the picture is let go in a while.
        stopKeepingPicture()
        expireKeptPicture(after: Self.keptPictureLife)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let inputWatch { NSEvent.removeMonitor(inputWatch) }
        inputWatch = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        lastFront = nil
        routerModel.composerFocused = false
        // The bar returns before taking the content out and changing the policy, so its fade starts before that work.
        // Not if the window was opened again meanwhile (on its way in, it is not visible yet), or from the callback.
        let closed = generation
        AppTransition.nextTurn { [weak self] in
            guard let self, self.generation == closed, self.phase == .idle, self.pending == nil,
                  self.window?.isVisible != true else { return }
            self.onClose?()
            guard self.generation == closed, self.phase == .idle, self.pending == nil,
                  self.window?.isVisible != true else { return }
            AppTransition.nextTurn { [weak self] in
                guard let self, self.generation == closed, self.phase == .idle, self.pending == nil,
                      self.window?.isVisible != true else { return }
                // The content leaves the window, which stops it; kept for the next open, it no longer ticks while closed.
                self.window?.contentViewController = nil
                // Short of memory: not kept either (it was still in the window as the pressure came).
                if self.memoryShort { self.releaseKept() }
                // Only the last window's close puts the app back to the bar only: one closing late (its work is deferred)
                // must not take the policy from another that has opened since. Asked of the windows themselves, so a close
                // whose tidying never came (or a controller gone) leaves nothing behind that reads as open.
                Self.broughtIn.remove(self)
                // An opening's activation landing after the close gave the keyboard back gives it back again as it lands
                // (`AppPolicy.onActivation`); active already with that notice still to come, it goes back here.
                if AppPolicy.yieldsAtTidy(active: NSApp.isActive, windowShown: Self.anyShown,
                                          pending: AppPolicy.activationPending) { AppPolicy.yieldFocus() }
                AppPolicy.update(windowOpen: Self.broughtIn.allObjects.contains { $0.isOpen })
            }
        }
    }
}

/// The window's three buttons on the 48pt header's line, where the sidebar toggle, back, forward and the page's title are:
/// AppKit centres them in its own 28pt title bar, 8pt higher. The title bar's container grows to the header's height and
/// the buttons sit in its middle, as far from the window's edge as from its top.
enum TrafficLights {
    static let spacing: CGFloat = 20

    static func place(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        let height = CDS.TitleBar.header
        container.frame = NSRect(x: container.frame.minX, y: window.frame.height - height,
                                 width: container.frame.width, height: height)
        let inset = ((height - close.frame.height) / 2).rounded()
        for (i, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            window.standardWindowButton(kind)?.setFrameOrigin(NSPoint(x: inset + CGFloat(i) * spacing, y: inset))
        }
    }

    /// Where the three end, from the window's edge.
    static var end: CGFloat { ((CDS.TitleBar.header - 14) / 2).rounded() + 2 * spacing + 14 }
}

/// Where the window goes when it opens on a screen.
enum AppWindowPlacement {
    /// `frame` on the screen whose usable area is `visible`. Kept (inside the screen) when its centre is already there;
    /// else the same relative place as on `from` (the area of the screen it was on), centred when that is unknown. Never
    /// larger than the screen.
    static func frame(_ frame: NSRect, from: NSRect?, in visible: NSRect) -> NSRect {
        let size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        var center = NSPoint(x: frame.midX, y: frame.midY)
        if !visible.contains(center) {
            if let from, from.width > 0, from.height > 0 {
                center = NSPoint(x: visible.minX + (center.x - from.minX) / from.width * visible.width,
                                 y: visible.minY + (center.y - from.minY) / from.height * visible.height)
            } else {
                center = NSPoint(x: visible.midX, y: visible.midY)
            }
        }
        let x = min(max(center.x - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(center.y - size.height / 2, visible.minY), visible.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

private extension InboxTab {
    var categoryID: UUID? {
        if case .category(let id) = self { return id }
        return nil
    }
}

extension RouterModel {
    /// "Open in Router" on an inbox thing: its pill in the composer (after what the draft holds), and `navigator` on the
    /// Router. The composer takes the keyboard, its caret after the pill, also when the page is made only now.
    func open(thing: String, in navigator: AppNavigator) {
        prefill([.notification(thing)])
        navigator.go(.router)
    }
}

/// The window's corner radius as the window reports it (`AppTransition.cornerRadius(of:)`): read when it becomes key and
/// on entering and leaving full screen, where it is 0.
@MainActor @Observable
final class WindowCorner {
    var radius: CGFloat

    init(radius: CGFloat = AppTransition.fallbackRadius) { self.radius = radius }
}

/// The window's root: the sidebar and the destination side by side, as Claude's Code tab lays them out (a split view
/// would draw the system's floating sidebar). The window's buttons sit over the sidebar's top; the sidebar toggle, back and
/// forward over the content's. On macOS 26 the sidebar is an inset panel and the page rides the fold (`InsetWindowLayout`).
struct AppRootView: View {
    let store: Store
    let navigator: AppNavigator
    let routerModel: RouterModel
    let hub: HubState
    let search: InboxSearch
    /// The ⌘K palette drawn over the window.
    let palette: PaletteModel
    let checksClaudeCode: Bool
    let sidebar: SidebarState
    /// How the sidebar and the floating controls draw: the app's, or a fixed one in tests and shots.
    let chrome: Chrome
    /// The window's corner radius, which the shapes inside it are concentric with.
    let corner: WindowCorner
    /// The window's capture flag (`GlassCapture`): none in shots and tests, which draw no glass to capture.
    let capture: GlassCapture?

    static let sidebarWidth: CGFloat = 240

    /// What the window's lists do to it, made once with the root: the same closures on every update, so the environment
    /// that carries them never tells the views that read them (each row) that they changed.
    private let actions: AppRootActions

    @MainActor
    init(store: Store, navigator: AppNavigator, routerModel: RouterModel, hub: HubState, search: InboxSearch? = nil,
         palette: PaletteModel? = nil, checksClaudeCode: Bool = true, sidebar: SidebarState = .shared, chrome: Chrome = .shared,
         corner: WindowCorner? = nil, capture: GlassCapture? = nil) {
        self.store = store
        self.navigator = navigator
        self.routerModel = routerModel
        self.hub = hub
        self.search = search ?? InboxSearch()
        self.palette = palette ?? PaletteModel(store: store, navigator: navigator, routerModel: routerModel, hub: hub)
        self.checksClaudeCode = checksClaudeCode
        self.sidebar = sidebar
        self.chrome = chrome
        self.corner = corner ?? WindowCorner()
        self.capture = capture
        actions = AppRootActions(store: store, navigator: navigator, routerModel: routerModel, hub: hub,
                                 palette: self.palette)
    }

    // Reads nothing that changes: what does is read by the small pieces below (the page, the corner, the follow-ups and the
    // Router's offer), so a settings write, a corner read when the window becomes key or a category's change redraws them
    // alone, not the root and every reader of its environment.
    var body: some View {
        AppRootPage(store: store, navigator: navigator, routerModel: routerModel, hub: hub, search: search,
                    checksClaudeCode: checksClaudeCode, sidebar: sidebar, chrome: chrome)
            .frame(minWidth: 640, minHeight: 600)
            .environment(chrome)
            .environment(\.glassCapture, capture)
            // A shape inside the window can be concentric with its corners (`ConcentricRectangle`, `Theme.Radius.concentric`).
            .modifier(WindowCornerShape(corner: corner))
            .foregroundStyle(Theme.text)
            .modifier(Brand.Scheme())
            .tipSpace()
            .ignoresSafeArea(.container, edges: .top)
            .background(CDS.Surface.s1)
            .modifier(AppRootFollow(store: store, navigator: navigator, routerModel: routerModel, hub: hub, search: search))
            .environment(\.openRouter, actions.openRouter)
            .environment(\.pickBriefEntry, actions.pickBriefEntry)
            // Chips in the window's own lists: a place, or the Router on the message an action left in its conversation.
            .environment(\.openApp, actions.openApp)
            .environment(\.openRouterMessage, actions.openRouterMessage)
            .environment(\.openChange, actions.openChange)
            .environment(\.openPalette, actions.openPalette)
            .modifier(AppRootRouterOffer(store: store, openInRouter: actions.openInRouter))
            // Its content put back in after a close draws what changed meanwhile as it is (`WindowArrival`).
            .windowArrival()
            .overlay { PaletteOverlay(palette: palette, store: store) }
    }
}

/// The window's actions on itself, for its lists' chips, cards and changes (see `AppRootView.actions`).
@MainActor
final class AppRootActions {
    let openRouter: (BriefTarget?) -> Void
    let pickBriefEntry: (BriefTarget) -> Void
    let openInRouter: (String) -> Void
    let openApp: (AppDestination) -> Void
    let openRouterMessage: (UUID) -> Void
    let openChange: (FjordChange) -> Void
    let openPalette: () -> Void

    init(store: Store, navigator: AppNavigator, routerModel: RouterModel, hub: HubState, palette: PaletteModel) {
        openPalette = { palette.open(pointer: true) }
        openRouter = { entry in
            if let entry { store.routerBriefs.focus(entry) }
            navigator.go(.router)
        }
        pickBriefEntry = { entry in store.routerBriefs.focus(entry) }
        openInRouter = { routerModel.open(thing: $0, in: navigator) }
        openApp = { navigator.go($0.resolved(shown: store.shownCategories.map(\.id), tools: store.tools)) }
        openRouterMessage = { _ in
            store.routerBriefs.drawerOpen = true
            navigator.go(.router)
        }
        openChange = { change in
            switch change.target(in: store) {
            case .category(let id): navigator.go(.categories); hub.openCategory(id)
            case .group(let id): navigator.go(.categories); hub.openGroup(id)
            case .categories: navigator.go(.categories)
            case .router: navigator.go(.router)
            case .settings(let section):
                navigator.go(.settings)
                hub.settingsScroll = ScrollRequest(id: section, seq: (hub.settingsScroll?.seq ?? 0) + 1)
            case .entry(let thing, let category, let isDone):
                navigator.go(isDone ? .done : (category.map { .category($0) } ?? .done))
                hub.selection = "i:" + thing
                hub.requestScroll("i:" + thing)
            }
        }
    }
}

/// The window's corners for the shapes inside it, read here alone: a new radius redraws what is concentric with them.
private struct WindowCornerShape: ViewModifier {
    let corner: WindowCorner

    func body(content: Content) -> some View { content.containerShape(.rect(cornerRadius: corner.radius)) }
}

/// A row's "Open in Router", while the Router is on: the one value of the root's environment that follows the store.
private struct AppRootRouterOffer: ViewModifier {
    let store: Store
    let openInRouter: (String) -> Void

    func body(content: Content) -> some View {
        content.environment(\.openInRouter, store.offers(.openInRouter) ? openInRouter : nil)
    }
}

/// What the window keeps in step as the store and the place change: the place settled on one that exists, and another
/// place's own pick and search.
private struct AppRootFollow: ViewModifier {
    let store: Store
    let navigator: AppNavigator
    let routerModel: RouterModel
    let hub: HubState
    let search: InboxSearch

    func body(content: Content) -> some View {
        content
            .onChange(of: store.shownCategories.map(\.id)) { _, shown in navigator.settle(shown: shown, tools: store.tools) }
            // Another place has its own pick and search; a row asked for there (a banner's click) stays.
            .onChange(of: navigator.selection) { _, place in
                search.end()
                if let pick = hub.selection, let tab = place.tab, store.entries(in: tab).contains(where: { "i:" + $0.id == pick }) { return }
                hub.selection = nil
                hub.keyboardSelection = nil
            }
            .onChange(of: store.tools) { _, tools in navigator.settle(shown: store.shownCategories.map(\.id), tools: tools) }
    }
}

/// The window's page: the onboarding until the tools are picked, then the sidebar and the destination.
private struct AppRootPage: View {
    let store: Store
    let navigator: AppNavigator
    let routerModel: RouterModel
    let hub: HubState
    let search: InboxSearch
    let checksClaudeCode: Bool
    let sidebar: SidebarState
    let chrome: Chrome

    var body: some View {
        if store.settings.toolsPicked == true {
            if #available(macOS 26, *) {
                InsetWindowLayout(store: store, navigator: navigator, routerModel: routerModel, hub: hub, search: search,
                                  checksClaudeCode: checksClaudeCode, sidebar: sidebar, chrome: chrome)
            } else {
                flat(collapsed: sidebar.collapsed)
            }
        } else {
            OnboardingView(store: store) {
                store.settings.toolsPicked = true
                navigator.go(store.firstPlace.resolved(shown: store.shownCategories.map(\.id), tools: store.tools))
            }
        }
    }

    /// macOS 14 and 15: the flat sidebar beside the page, the top bar the sidebar's ground the whole width. The sidebar
    /// toggle, back and forward stay put after the window's three buttons: over the sidebar when it is out, at the
    /// content's start when it is a rail, the page's title after them. The room follows the sidebar's width on the same
    /// spring (an implicit animation here would end up fighting the explicit one).
    private func flat(collapsed: Bool) -> some View {
        let headerInset = collapsed ? AppNavButtons.end - AppSidebar.railWidth : 0
        return HStack(spacing: 0) {
            AppSidebar(store: store, navigator: navigator, hub: hub, collapsed: collapsed)
                .padding(.top, CDS.TitleBar.header)
                .frame(width: collapsed ? AppSidebar.railWidth : AppRootView.sidebarWidth, alignment: .leading)
                .frame(maxHeight: .infinity)
                .clipped()
                .background(CDS.Surface.sidebar)
                // Its edge starts under the top bar: the window's three buttons sit above it.
                .overlay(alignment: .trailing) {
                    Rectangle().fill(CDS.border).frame(width: CDS.Sidebar.edge).padding(.top, CDS.TitleBar.header)
                }
            AppContent(store: store, navigator: navigator, routerModel: routerModel, hub: hub, search: search,
                       checksClaudeCode: checksClaudeCode, leadingInset: headerInset)
        }
        // The top bar: the sidebar's ground the whole width (the pages draw theirs under it), a rule beneath.
        .background(alignment: .top) { CDS.Surface.sidebar.frame(height: CDS.TitleBar.header) }
        .overlay(alignment: .top) {
            Rectangle().fill(CDS.border).frame(height: CDS.Sidebar.edge)
                .padding(.top, CDS.TitleBar.header - CDS.Sidebar.edge)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            AppNavButtons(navigator: navigator,
                          sidebarShown: Binding(get: { !sidebar.collapsed }, set: { sidebar.set(collapsed: !$0) }))
                .padding(.leading, AppNavButtons.leading)
                .frame(height: CDS.TitleBar.header)
        }
    }
}

/// Sidebar toggle, back and forward: Claude's 26pt ghost icon buttons, 4 apart.
struct AppNavButtons: View {
    let navigator: AppNavigator
    @Binding var sidebarShown: Bool
    /// Their start, from the window's edge: just after the window's three buttons.
    static var leading: CGFloat { TrafficLights.end + 10 }
    /// What the three buttons take, with the gaps.
    static let width: CGFloat = 3 * CDS.TitleBar.button + 2 * CDS.TitleBar.buttonGap
    /// Their end, from the window's edge.
    static var end: CGFloat { leading + width }
    /// On macOS 26 the room round them on the title line, and their width with it.
    static let capsulePad: CGFloat = 3
    static var capsuleWidth: CGFloat { width + 2 * capsulePad }

    var body: some View {
        HStack(spacing: CDS.TitleBar.buttonGap) {
            AppIconButton(symbol: "sidebar.left", help: sidebarShown ? "Hide sidebar" : "Show sidebar", key: "⌘B", enabled: true) {
                sidebarShown.toggle()
            }
            AppIconButton(symbol: "chevron.left", help: "Back", key: "⌘[", enabled: navigator.canGoBack) { navigator.back() }
            AppIconButton(symbol: "chevron.right", help: "Forward", key: "⌘]", enabled: navigator.canGoForward) { navigator.forward() }
        }
    }
}

struct AppIconButton: View {
    let symbol: String
    let help: String
    /// Its shortcut, shown in its tooltip.
    var key: String? = nil
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false
    /// On glass: label styles and `ChromeFill`'s ink steps rather than Claude's fixed inks and fills.
    @Environment(\.onGlass) private var onGlass
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: CDS.Sidebar.symbol, weight: .medium))
                .foregroundStyle(ink)
                .frame(width: CDS.TitleBar.button, height: CDS.TitleBar.button)
                .background(RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous)
                    .fill(ChromeFill.color(selected: false, hovered: hovered && enabled, glass: onGlass, scheme: scheme))
                    // On glass hover comes on at once and eases off; elsewhere it stays instant both ways.
                    .hoverMotion(hovered && enabled))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .accessibilityLabel(help)
        // The app's tooltip (as every other button's), with its shortcut.
        .tip(help, key)
    }

    private var ink: AnyShapeStyle {
        let level: ChromeInk = !enabled ? .disabled : hovered ? .primary : .secondary
        if onGlass { return level.style(glass: true) }
        return AnyShapeStyle(!enabled ? CDS.Text.disabled : hovered ? Brand.ink : CDS.Text.secondary)
    }
}
