import AppKit
import Carbon
import SwiftUI

// `--playground`: a window with a fake desktop to try the bar and the app window with the demo data.

// MARK: - Playground window

/// A fake desktop: the bar on the edge you pick and an app behind it. A click on the bar opens the app window (a real one) and
/// takes the bar away until it closes.
struct PlaygroundView: View {
    let store: Store
    @Bindable var ui: UIState
    @Bindable var hub: HubState
    /// The "Fjord playground" card: hidden in shots, where it is no part of what is looked at.
    var showsExplainer = true
    var minSize = CGSize(width: 1280, height: 820)
    /// Opens the app window on a place; a toast says so when there is none (in shots).
    var openApp: ((AppDestination) -> Void)? = nil
    var reopenApp: (() -> Void)? = nil
    var pickBriefEntry: ((BriefTarget) -> Void)? = nil
    /// How the bar and its panels draw: the app's, or a fixed one in shots.
    var chrome: Chrome = .shared
    @State private var behindClicks = 0
    @State private var leaveTask: Task<Void, Never>?

    private let menuBar: CGFloat = 26
    private static let space = "playground"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.20, green: 0.27, blue: 0.42), Color(red: 0.47, green: 0.38, blue: 0.52),
                                        Color(red: 0.70, green: 0.52, blue: 0.50)], startPoint: .topLeading, endPoint: .bottomTrailing)
                behindApp.position(x: geo.size.width - 330, y: 260)
                if showsExplainer {
                    controls.position(x: geo.size.width / 2 - (ui.edge == .right ? 140 : ui.edge == .left ? -140 : 0),
                                      y: geo.size.height / 2 + (ui.edge == .top ? 120 : ui.edge == .bottom ? -120 : 0))
                }
                fakeMenuBar.frame(maxHeight: .infinity, alignment: .top)
                if !hub.barHidden { docked(geo.size) }
                if let toast = hub.toast {
                    Text(toast).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 70)
                        .transition(.opacity)
                }
            }
        }
        .coordinateSpace(.named(Self.space))
        .frame(minWidth: minSize.width, minHeight: minSize.height)
        .environment(chrome)
        .environment(\.pickBriefEntry) { entry in pickBriefEntry?(entry) }
        .environment(\.openApp) { [hub] destination in
            if let openApp { openApp(destination) } else { hub.toast = "Open the window on \(destination.token)" }
        }
        .environment(\.reopenApp) { [hub] in
            if let reopenApp { reopenApp() } else { hub.toast = "Open the window where it was" }
        }
        // As in the app: tooltips over the whole window, outside the hub's clipped shape.
        .tipSpace()
        .animation(.easeOut(duration: 0.2), value: hub.toast)
        .onChange(of: hub.toast) { _, toast in
            guard toast != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if hub.toast == toast { hub.toast = nil } }
        }
    }

    @ViewBuilder private func docked(_ screen: CGSize) -> some View {
        // The room on the screen around the bar, as the app's `HubRoot` measures it, so a panel is kept on it here too.
        let hubView = FjordHub(store: store, ui: ui, hub: hub).environment(\.hubPointer, hover)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { [hub, ui] frame in
                let inset = Theme.Metrics.inset
                let room = ui.edge.isHorizontal ? HubRoom(before: frame.minX - inset, after: screen.width - frame.minX - inset)
                                                : HubRoom(before: frame.minY - inset, after: screen.height - frame.minY - inset)
                if hub.room != room { hub.room = room }
            }
        switch ui.edge {
        case .right: hubView.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, menuBar + 40)
        case .left: hubView.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, menuBar + 40)
        case .top: hubView.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, menuBar)
        case .bottom: hubView.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// Opens at once; closes a moment after the mouse leaves the bar and its panel, so crossing a gap doesn't flicker it shut.
    /// (In the app, `HubController` decides this from where the hub is drawn.)
    private func hover(_ inside: Bool) {
        leaveTask?.cancel()
        if inside {
            hub.hovering = true
        } else {
            leaveTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                hub.hovering = false
                hub.cancelDwell()
                hub.section = nil
                hub.selection = nil
                hub.quiet = false
            }
        }
    }

    private var fakeMenuBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.bold)
            ForEach(["Fichier", "Édition", "Présentation", "Aller", "Fenêtre", "Aide"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "wifi")
            Text("lun. 5 oct.  12:04")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: menuBar)
        .background(Color.black.opacity(0.22))
    }

    /// Something under the open view.
    private var behindApp: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 11, height: 11) }
                Spacer()
                Text("Some app behind").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
                Spacer()
            }
            Text("An app under Fjord: clicks around the bar reach it.")
                .font(.system(size: 12.5)).foregroundStyle(.black.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Button("Clicked \(behindClicks) times") { behindClicks += 1 }
                .controlSize(.large)
            Spacer()
        }
        .padding(14)
        .frame(width: 520, height: 330)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.94)))
        .environment(\.colorScheme, .light)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fjord playground").font(.system(size: 15, weight: .semibold))
            Picker("Edge", selection: Binding(get: { ui.edge }, set: { ui.edge = $0 })) {
                Text("Left").tag(DockEdge.left)
                Text("Top").tag(DockEdge.top)
                Text("Right").tag(DockEdge.right)
                Text("Bottom").tag(DockEdge.bottom)
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                Text("Hover an item of the bar to peek at it").foregroundStyle(.secondary)
                Text("Click one to open the window · right ⌘ toggles it").foregroundStyle(.secondary)
                Text("Closing the window (red button, ⌘W) puts the bar back").foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
        }
        .padding(16)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .environment(\.colorScheme, .dark)
    }
}

/// `--playground`: the fake desktop, the demo data, and the app window a click on the bar opens.
@MainActor
final class Playground: NSObject, NSWindowDelegate {
    private let store = Store()
    private let ui = UIState(persists: false, edge: .right)
    private let hub = HubState()
    private var window: NSWindow!
    private var monitor: Any?
    private var tap = ModifierTap()
    private lazy var app = AppWindowController(store: store, remembers: false, checksClaudeCode: false)

    func run() {
        Demo.populate(store, .router)
        store.interceptOpen = { [hub] text in hub.toast = text }
        app.onClose = { [hub] in
            hub.barHidden = false
            // The playground's own window keeps the app regular.
            NSApp.setActivationPolicy(.regular)
        }
        let view = PlaygroundView(store: store, ui: ui, hub: hub, openApp: { [weak self] in self?.openApp($0) },
                                  reopenApp: { [weak self] in
                                      guard let self else { return }
                                      self.openApp(self.app.navigator.selection)
                                  },
                                  pickBriefEntry: { [weak self] entry in self?.store.routerFocus(entry.thread) })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Fjord playground"
        // As in the app's panel: the hub's native menus and popovers are dark.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func windowWillClose(_ notification: Notification) {
        // The app window closing is not the playground's.
        if (notification.object as? NSWindow) === window { NSApp.terminate(nil) }
    }

    /// A click on the bar: the app window opens on it and the bar is away until the window closes.
    private func openApp(_ destination: AppDestination) {
        hub.section = nil
        hub.hovering = false
        hub.barHidden = true
        app.show(destination)
    }

    /// Right ⌘ alone toggles the window, as the app's shortcut does.
    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            if tap.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) == 54 {
                if app.isOpen { app.close() } else { openApp(app.navigator.selection) }
            }
        default:
            tap.interrupt()
        }
    }
}

// MARK: - Shots

/// What the system's accessibility settings read in a shot: the ones set override the system's, the others keep what it says.
/// Only what reads them from the SwiftUI environment follows (Reduce Motion, in the hub); a read straight from `NSWorkspace`
/// always shows the system's setting.
struct ShotEnvironment: Equatable {
    var increaseContrast = false
    var reduceMotion = false
    var differentiateWithoutColor = false

    static let contrast = ShotEnvironment(increaseContrast: true)
    static let motion = ShotEnvironment(reduceMotion: true)
    static let differentiate = ShotEnvironment(differentiateWithoutColor: true)
}

private extension View {
    /// SwiftUI declares these environment values get-only; the underscored keys are the settable ones behind them.
    func shotEnvironment(_ shot: ShotEnvironment) -> some View {
        transformEnvironment(\._colorSchemeContrast) { if shot.increaseContrast { $0 = .increased } }
            .transformEnvironment(\._accessibilityReduceMotion) { if shot.reduceMotion { $0 = true } }
            .transformEnvironment(\._accessibilityDifferentiateWithoutColor) { if shot.differentiateWithoutColor { $0 = true } }
    }
}

extension [DockEdge] {
    static let all: [DockEdge] = [.right, .top, .left, .bottom]
    /// The side bar and the strip: where a state differs between them.
    static let rightAndTop: [DockEdge] = [.right, .top]
}

/// The Router in a shot (it fills the app window's content): the page, and the first Needs-you line's card open.
struct RouterWindowShot {
    /// The first Needs-you line selected, its card open.
    var opensCard = false
    static let size = CGSize(width: 1100, height: 720)
}

/// What a shot has picked, for the row actions to show.
enum ShotSelection {
    /// The newest entry of the first category with something unread.
    case firstNeedsYou
}

/// One screenshot: the playground in a given state, rendered offscreen to `<name>.png`. Add one by adding a line to
/// `PlaygroundShots.catalog`; everything but `name` has a default.
struct Shot {
    static let standard = CGSize(width: 1280, height: 820)
    /// A 1280x720 screen: the bar and its peek must fit the edge without overflowing.
    static let hd = CGSize(width: 1280, height: 720)

    var name: String
    var edge = DockEdge.right
    /// The data (see `Demo.Scenario`).
    var scenario = Demo.Scenario.agents
    /// Just this section open beside the bar, as when it is hovered.
    var section: HubSection?
    /// The inbox peek's tab, by category name (or "Done").
    var tab: String?
    var selection: ShotSelection?
    /// A tooltip shown at once, by title (see `Tip`).
    var tip: String?
    var size = Shot.standard
    var environment = ShotEnvironment()
    /// The Router instead of the playground (the edge only names the shot).
    var routerWindow: RouterWindowShot?
    /// The category editor's page instead of the playground (see `CategoriesDemo`).
    var categories: CategoriesShot?

    /// The same shot on each of these edges, named `<edge>-<state>`.
    static func edges(_ state: String, on edges: [DockEdge] = .all, _ configure: (inout Shot) -> Void = { _ in }) -> [Shot] {
        edges.map { edge in
            var shot = Shot(name: "\(edge.rawValue)-\(state)", edge: edge)
            configure(&shot)
            return shot
        }
    }
}

/// `--playground-shots <dir> [substring...]`: the real views, on the demo data, rendered offscreen as PNGs. Shots whose
/// name contains one of the substrings are rendered (all of them without any), so a change is checked in a few seconds:
/// `.build/debug/Fjord --playground-shots /tmp/shots right-peek`.
///
/// Names are `<edge>-<state>`, the edge being right, top, left or bottom. Every shot is one line of `catalog`, under a
/// comment saying what the group shows. Most states are on the right edge and along the top, which stand for the sides and
/// the strip; the baseline and the bar at rest are on all four. The app window has its own shots (`--window-shots`).
@MainActor
enum PlaygroundShots {
    /// States of the data, as `(name, scenario)`; each is shown at rest and with the inbox's peek.
    private static let causes: [(String, Demo.Scenario)] = [
        ("signed-out", .signedOut), ("inbox-failed", .inboxFailed), ("rate-limited", .rateLimited), ("snoozed", .snoozed),
        ("error", .error), ("contributions-empty", .contributionsEmpty), ("first-sync", .firstSync), ("sync-fault", .syncFault),
        ("inbox-empty", .empty),
    ]
    private static let ci: [(String, Demo.Scenario)] = [
        ("no-ci", .noCI), ("all-passing", .allPassing), ("many-ci", .manyCI), ("ci-running", .ciRunning),
    ]
    private static let updates: [(String, Demo.Scenario)] = [
        ("update-available", .updateAvailable), ("update-downloading", .updateDownloading), ("update-ready", .updateReady),
    ]

    /// The baseline and the peeks: one line each.
    private static let baseline: [Shot] = [
        Shot.edges("rest"),
        Shot.edges("peek-inbox") { $0.section = .inbox },
        Shot.edges("peek-ci") { $0.section = .inbox; $0.tab = "CI" },
        Shot.edges("peek-controls") { $0.section = .controls },
        Shot.edges("peek-tip", on: .rightAndTop) { $0.scenario = .router; $0.section = .router; $0.tip = "Open Router" },
        // An inbox item picked, its actions showing.
        Shot.edges("peek-picked", on: .rightAndTop) { $0.section = .inbox; $0.selection = .firstNeedsYou },
    ].flatMap { $0 }

    /// Inbox: the tabs of its peek, and a list longer than it shows.
    private static let inbox: [Shot] = [
        Shot.edges("peek-reviews", on: .rightAndTop) { $0.section = .inbox; $0.tab = "Reviews for you" },
        Shot.edges("peek-bot-chatter", on: .rightAndTop) { $0.section = .inbox; $0.tab = "Bot chatter" },
        Shot.edges("peek-done", on: .rightAndTop) { $0.section = .inbox; $0.tab = "Done" },
        Shot.edges("peek-bot-chatter-empty", on: .rightAndTop) { $0.section = .inbox; $0.scenario = .botChatterEmpty; $0.tab = "Bot chatter" },
        Shot.edges("peek-done-empty", on: .rightAndTop) { $0.section = .inbox; $0.scenario = .doneEmpty; $0.tab = "Done" },
        // A category hidden: no icon in the bar, no tab.
        Shot.edges("rest-hidden-category", on: .rightAndTop) { $0.scenario = .hiddenCategory },
        // Two sections: two wells, each with its icon.
        Shot.edges("rest-sections", on: .rightAndTop) { $0.scenario = .sections },
        Shot.edges("peek-hidden-category", on: .rightAndTop) { $0.section = .inbox; $0.scenario = .hiddenCategory },
        Shot.edges("peek-inbox-many", on: .rightAndTop) { $0.section = .inbox; $0.scenario = .inboxMany },
        // Jev's category: comments that ask you, review requests it rates high or urgent.
        Shot.edges("peek-jev", on: [.right]) { $0.section = .inbox; $0.scenario = .jev; $0.tab = "Asks me" },
    ].flatMap { $0 }

    /// A scenario on the right and top at rest and/or with its peek.
    private static func scenarioShots(_ slug: String, _ scenario: Demo.Scenario, rest: Bool = false, peek: HubSection? = nil,
                                      tab: String? = nil) -> [Shot] {
        var shots: [Shot] = []
        if rest { shots += Shot.edges("rest-\(slug)", on: .rightAndTop) { $0.scenario = scenario } }
        if let peek {
            shots += Shot.edges("peek-\(slug)", on: .rightAndTop) { $0.section = peek; $0.scenario = scenario; $0.tab = tab }
        }
        return shots
    }

    /// The accessibility settings, on the bar at rest and with its peek.
    private static func environmentShots(_ slug: String, _ environment: ShotEnvironment) -> [Shot] {
        Shot.edges("rest-\(slug)", on: .rightAndTop) { $0.environment = environment }
            + Shot.edges("peek-\(slug)", on: .rightAndTop) { $0.section = .inbox; $0.environment = environment }
    }

    /// The Router: its cell at rest and its peek on every edge; the Router itself, a card open, under Increase Contrast, and
    /// switched off.
    private static let routerShots: [Shot] = {
        var shots = Shot.edges("rest-router") { $0.scenario = .router }
        shots += Shot.edges("peek-router") { $0.scenario = .router; $0.section = .router }
        // A screen too short for the Router's peek under its cell: it moves up to stay on it.
        shots += Shot.edges("peek-router-short", on: [.right]) { $0.scenario = .router; $0.section = .router; $0.size = CGSize(width: 1280, height: 560) }
        let window = { (name: String, configure: (inout Shot) -> Void) -> Shot in
            var shot = Shot(name: "right-router-window\(name)", scenario: .router, routerWindow: RouterWindowShot())
            configure(&shot)
            return shot
        }
        shots.append(window("") { $0.routerWindow?.opensCard = true })
        shots.append(window("-contrast") { $0.environment = .contrast })
        shots.append(window("-off") { $0.scenario = .routerOff })

        return shots
    }()

    /// Every shot, in the order they are rendered.
    static let catalog: [Shot] = {
        var shots = baseline + inbox
        // Causes: why a list is empty or the sync is not healthy.
        for (slug, scenario) in causes { shots += scenarioShots(slug, scenario, rest: true, peek: .inbox) }
        for (slug, scenario) in ci { shots += scenarioShots(slug, scenario, peek: .inbox, tab: "CI") }
        for (slug, scenario) in updates { shots += scenarioShots(slug, scenario, rest: true) }
        shots += environmentShots("contrast", .contrast)
        shots += environmentShots("motion", .motion)
        shots += environmentShots("differentiate", .differentiate)
        shots += routerShots
        shots += CategoriesShot.allCases.map { Shot(name: $0.name, categories: $0) }
        // A 1280x720 screen: the bar and its peek must fit the edge without overflowing.
        shots += Shot.edges("peek-720", on: .rightAndTop) { $0.section = .inbox; $0.size = Shot.hd }
        shots += Shot.edges("peek-many-ci-720", on: .rightAndTop) { $0.section = .inbox; $0.scenario = .manyCI; $0.tab = "CI"; $0.size = Shot.hd }
        return shots
    }()

    /// The shots whose name contains one of `filters` (all of them without any).
    static func select(_ filters: [String]) -> [Shot] {
        let filters = filters.map { $0.lowercased() }
        return catalog.filter { shot in filters.isEmpty || filters.contains { shot.name.contains($0) } }
    }

    /// `--playground-shots <dir> [substring...]`.
    static func run(to dir: String) {
        let arguments = CommandLine.arguments
        let start = (arguments.firstIndex(of: "--playground-shots") ?? 0) + 2
        let filters = Array(arguments.dropFirst(start).filter { !$0.hasPrefix("--") })
        let shots = select(filters)
        guard !shots.isEmpty else {
            print("No shot matches \(filters.joined(separator: ", ")). \(catalog.count) shots, e.g. \(catalog[0].name)")
            exit(1)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        ShotRun.prepare()
        Task {
            // Some at a time: every window is a live SwiftUI hierarchy, and a full set is too much to hold at once.
            for batch in stride(from: 0, to: shots.count, by: 10).map({ Array(shots[$0..<min($0 + 10, shots.count)]) }) {
                let windows = batch.map { (name: $0.name, window: open($0)) }
                try? await Task.sleep(for: .seconds(2.5))
                for (name, window) in windows {
                    capture(window, to: "\(dir)/\(name).png")
                    window.close()
                }
            }
            print("\(shots.count) shots in \(dir)")
            exit(0)
        }
    }

    /// The shot's window, offscreen and showing the playground in its state.
    private static func open(_ shot: Shot) -> NSWindow {
        let store = Store()
        Demo.populate(store, shot.scenario)
        if let router = shot.routerWindow { return openRouterWindow(router, store: store, environment: shot.environment) }
        if let page = shot.categories { return CategoriesDemo.window(page, store: store) }
        let ui = UIState(persists: false, edge: shot.edge)
        let hub = HubState()
        hub.section = shot.section
        if let name = shot.tab {
            hub.tab = name == "Done" ? .done : store.categories.first { $0.name == name }.map { .category($0.id) }
        }
        if shot.selection == .firstNeedsYou { hub.selection = store.entries(in: store.tabNeedingYou).first.map { "i:" + $0.id } }
        // Glass can't be captured: shots draw the opaque chrome, whatever the Mac's settings or FJORD_GLASS.
        let root = PlaygroundView(store: store, ui: ui, hub: hub, showsExplainer: false, minSize: shot.size,
                                  chrome: Chrome(mode: .opaque))
            .environment(\.previewTip, shot.tip)
            .shotEnvironment(shot.environment)
            .frame(width: shot.size.width, height: shot.size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame.size = shot.size
        let window = ShotWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        ShotRun.show(window)
        return window
    }

    /// The Router, offscreen, as the app window shows it.
    private static func openRouterWindow(_ shot: RouterWindowShot, store: Store, environment: ShotEnvironment) -> NSWindow {
        let page = store.routerPage
        if shot.opensCard, let first = store.routerRecords.lines(in: .needsYou).first { page.select(.line(first.id)) }
        let size = RouterWindowShot.size
        let root = RouterScreen(model: page, store: store, text: RouterComposerModel())
            .environment(Chrome(mode: .opaque))
            .shotEnvironment(environment)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame.size = size
        let window = ShotWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        ShotRun.show(window)
        return window
    }

    private static func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView else { return }
        ShotCapture.write(view, to: path)
    }
}
