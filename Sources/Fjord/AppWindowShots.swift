import AppKit
import SwiftUI

// Dev entries for the app window: `--window` opens it alone on the demo data; `--window-shots <dir> [substring...]` renders
// its destinations as PNGs, offscreen, the title bar included.

@MainActor
enum AppWindowDev {
    /// `--window`: the window on the demo data (the Router's brief included), the app ending with it.
    static func open(_ store: Store) -> AppWindowController {
        Demo.populate(store, .router)
        let controller = AppWindowController(store: store, remembers: false)
        controller.onClose = { NSApp.terminate(nil) }
        if RouterDemo.isRequested {
            // `--router-v2-demo`: the Router v2 page on its fake records, the storyboard playing (RouterDemo.swift). Its
            // window is 1280 × 960 and opens at once (no morph), its frame not remembered.
            RouterDemo.install()
            AppTransition.enabled = false
            // Writing frames (not filming): offscreen, like the window shots, so nothing shows or takes the focus.
            if RouterDemo.offscreen {
                ShotRun.prepare()
                AppPolicy.offscreen = true
            }
            controller.prepare()
            if let window = controller.window {
                window.setFrameAutosaveName("")
                window.setContentSize(NSSize(width: 1280, height: 960))
                window.center()
            }
            controller.show(.router)
            return controller
        }
        controller.show()
        return controller
    }
}

/// The window of a shot: it may sit anywhere, so it can be off every screen, and it never becomes key or main, so no field
/// in it takes keyboard focus or the keystrokes typed in other apps while a shot runs.
final class ShotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Writes a shot's window content to a PNG.
///
/// `cacheDisplay` walks the views' `draw(_:)`, which skips what SwiftUI keeps in layers of its own: the content of every
/// `ScrollView` (the Router's list and history, the Brief) came out empty. The window server composites those layers,
/// and may be asked for a window of this process without any screen-recording permission, even when the window sits
/// off every screen, so the shot is the window's own picture, cropped to its content view (a full-size-content window's
/// traffic lights and rounded corners are in it).
@MainActor
enum ShotCapture {
    static func write(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let png = windowPicture(of: view) ?? cachedDisplay(of: view)
        try? png?.write(to: URL(fileURLWithPath: path))
    }

    /// Writes the window server's picture of the view; false when there is none (nothing is written).
    static func writeWindowPicture(_ view: NSView, to path: String) -> Bool {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let png = windowPicture(of: view) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    private static func windowPicture(of view: NSView) -> Data? {
        guard let content = windowImage(of: view) else { return nil }
        return NSBitmapImageRep(cgImage: content).representation(using: .png, properties: [:])
    }

    /// The window server's picture of the view, as it is on screen now (what Core Animation is moving included). The
    /// window is the app's own, so this needs no Screen Recording permission.
    static func windowImage(of view: NSView) -> CGImage? {
        guard let window = view.window, window.windowNumber > 0 else { return nil }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming]), image.width > 0 else { return nil }
        let scale = CGFloat(image.width) / window.frame.width
        let rect = view.convert(view.bounds, to: nil)
        let crop = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                          width: rect.width * scale, height: rect.height * scale).integral
        return image.cropping(to: crop)
    }

    private static func cachedDisplay(of view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// The shot runs (`--window-shots`, `--playground-shots`) never activate the app.
@MainActor
enum ShotRun {
    /// Before any shot window is made: an accessory app (no Dock icon, no menu bar) that nothing activates.
    static func prepare() {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Shows a shot's window offscreen: ordered front without activating the app or making the window key.
    static func show(_ window: NSWindow) {
        // The shot loop closes the window while ARC owns it, and its close animation over-released it (a crash that
        // cut a run with several shots after the first).
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
    }
}

@MainActor
enum AppWindowShots {
    struct Shot {
        let name: String
        /// Resolved against the demo data when the shot is made.
        let destination: (Store) -> AppDestination
        var sidebarHidden = false
        var size = CGSize(width: 1280, height: 800)
        /// Sets the Router's composer up (a draft with a pill in it).
        var compose: ((RouterComposerModel, Store) -> Void)?
        /// Prepares a tool page or stateful overlay for this shot.
        var prepare: ((Store) -> Void)? = nil
        /// The window's look; nil follows the Mac.
        var appearance: NSAppearance.Name?
        /// Opens the ⌘K palette over the window.
        var palette: PaletteShot?
        /// A view drawn on its own in the window instead of the app (for what the app's pages don't show by themselves).
        var standalone: ((Store, RouterComposerModel) -> AnyView)?
        /// A tooltip shown at once: the one whose title starts with this.
        var tip: String?
        /// The Router v2 page (RouterPage.swift) on its demo records, in the Router's place: the state to draw.
        var v2: (() -> RouterModel)?
        /// What the pointer is on in a v2 shot, set once the page is laid out (a peek hangs from its name's frame).
        var v2Pointer: ((RouterModel) -> Void)?
    }

    /// How a shot opens the palette: with a query typed, on the first row's actions page, on fixture items rather than the
    /// demo data's.
    struct PaletteShot {
        var query = ""
        var actions = false
        var fixture = false
    }

    static let catalog: [Shot] = [
        Shot(name: "category") { $0.shownCategories[0].id.asCategory },
        Shot(name: "reviews") { store in store.shownCategories.first { $0.name.contains("Review") }?.id.asCategory ?? .done },
        Shot(name: "ci") { store in store.shownCategories.first(where: \.isCI)?.id.asCategory ?? .done },
        Shot(name: "done") { _ in .done },
        Shot(name: "settings-t3-linked", destination: { _ in .settings }, size: CGSize(width: 1400, height: 2000),
             compose: { _, store in store.t3.demoStatus = .connected(threads: store.threads.count) }),
        Shot(name: "palette", destination: { $0.shownCategories[0].id.asCategory }, palette: PaletteShot()),
        Shot(name: "palette-search", destination: { $0.shownCategories[0].id.asCategory }, palette: PaletteShot(query: "fix")),
        Shot(name: "palette-actions", destination: { $0.shownCategories[0].id.asCategory },
             palette: PaletteShot(query: "fix", actions: true)),
        Shot(name: "palette-router", destination: { _ in .router }, palette: PaletteShot()),
        Shot(name: "palette-fixture", destination: { $0.shownCategories[0].id.asCategory }, palette: PaletteShot(fixture: true)),
        Shot(name: "palette-fixture-search", destination: { $0.shownCategories[0].id.asCategory },
             palette: PaletteShot(query: "fix", fixture: true)),
        Shot(name: "palette-fixture-many", destination: { $0.shownCategories[0].id.asCategory },
             palette: PaletteShot(query: "e", fixture: true)),
        Shot(name: "palette-fixture-actions", destination: { $0.shownCategories[0].id.asCategory },
             palette: PaletteShot(query: "fix", actions: true, fixture: true)),
        Shot(name: "settings") { _ in .settings },
        // What the Router's models used, in Settings › T3 Code: today's calls, tokens and the API price estimate per model.
        Shot(name: "settings-model-usage", destination: { _ in .settings }, size: CGSize(width: 1400, height: 2000), compose: { _, store in
            store.t3.demoStatus = .connected(threads: store.threads.count)
            store.modelUsageShown = Self.demoUsage(Date())
        }),
        Shot(name: "settings-t3-not-linked", destination: { _ in .settings }, size: CGSize(width: 1400, height: 2000), compose: { _, store in store.t3.demoStatus = .notLinked }),
        Shot(name: "settings-t3-refused", destination: { _ in .settings }, size: CGSize(width: 1400, height: 2000), compose: { _, store in store.t3.demoStatus = .tokenRejected }),
        Shot(name: "settings-t3-not-installed", destination: { _ in .settings }, size: CGSize(width: 1400, height: 2000), compose: { _, store in store.t3.demoStatus = .notInstalled }),
        Shot(name: "categories") { _ in .categories },
        Shot(name: "snippets") { _ in .snippets },
        // Two sections, one folded: its row with the counts added up and its caret turned, its categories gone from the sidebar.
        Shot(name: "categories-sections", destination: { _ in .categories }, compose: { _, store in
            let builds = store.createSection(name: "Builds")
            for c in store.categories where c.isCI { store.moveCategory(c.id, toSection: builds.id) }
            store.toggleCollapsed(builds.id)
        }),
        Shot(name: "category-collapsed", destination: { $0.shownCategories[0].id.asCategory }),
        Shot(name: "router-collapsed", destination: { _ in .router }),
        Shot(name: "router-760", destination: { _ in .router }, size: CGSize(width: 760, height: 1000)),
        Shot(name: "router-collapsed-760", destination: { _ in .router }, sidebarHidden: true, size: CGSize(width: 760, height: 1000)),
        Shot(name: "category-narrow", destination: { $0.shownCategories[0].id.asCategory }, size: CGSize(width: 1000, height: 640)),
    ] + RouterShots.catalog + RouterLayerShots.catalog + RouterMentionShot.catalog + RouterSplitShots.catalog + RouterFilterShots.catalog
        + RouterQuoteShots.catalog + RouterTrailShots.catalog

    /// `--window-shots <dir> [substring...]`.
    static func run(to dir: String) {
        let arguments = CommandLine.arguments
        let start = (arguments.firstIndex(of: "--window-shots") ?? 0) + 2
        let filters = Array(arguments.dropFirst(start).filter { !$0.hasPrefix("--") }).map { $0.lowercased() }
        let shots = catalog.filter { shot in filters.isEmpty || filters.contains { shot.name.contains($0) } }
        guard !shots.isEmpty else {
            print("No shot matches \(filters.joined(separator: ", ")). \(catalog.count) shots, e.g. \(catalog[0].name)")
            exit(1)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        ShotRun.prepare()
        Task {
            for shot in shots {
                let window = open(shot)
                try? await Task.sleep(for: .seconds(2))
                capture(window, to: "\(dir)/window-\(shot.name).png")
                window.close()
            }
            print("\(shots.count) shots in \(dir)")
            exit(0)
        }
    }

    private static func open(_ shot: Shot) -> NSWindow {
        // The last shot's page model goes first: the new store's page is its own, not the last shot's.
        RouterDemo.model = nil
        let store = Store()
        Demo.populate(store, .router)
        shot.prepare?(store)
        let v2 = shot.v2?()
        RouterDemo.model = v2
        if let v2, let point = shot.v2Pointer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { point(v2) } }
        let navigator = AppNavigator(start: shot.destination(store), defaults: nil)
        let routerModel = RouterComposerModel()
        shot.compose?(routerModel, store)
        let hub = HubState()
        let palette = PaletteModel(store: store, navigator: navigator, routerModel: routerModel, hub: hub,
                                   sources: shot.palette?.fixture == true ? PaletteFixture.sources(store) : nil)
        if let open = shot.palette {
            palette.open()
            if !open.query.isEmpty { palette.setQuery(open.query) }
            if open.actions { palette.showActions() }
        }
        if let standalone = shot.standalone {
            let controller = NSHostingController(rootView: standalone(store, routerModel).environment(\.cdsColumnWidth, shot.size.width))
            controller.sizingOptions = []
            let window = ShotWindow(contentRect: NSRect(origin: .zero, size: shot.size), styleMask: [.titled], backing: .buffered, defer: false)
            if let look = shot.appearance { window.appearance = NSAppearance(named: look) }
            window.contentViewController = controller
            window.setContentSize(shot.size)
            ShotRun.show(window)
            return window
        }
        let root = AppRootView(store: store, navigator: navigator, routerModel: routerModel, hub: hub, palette: palette,
                               checksClaudeCode: false,
                               sidebar: SidebarState(defaults: nil, collapsed: shot.sidebarHidden),
                               // Glass can't be captured: shots draw the opaque chrome, whatever the Mac's settings.
                               chrome: Chrome(mode: .opaque))
        let controller = NSHostingController(rootView: root.environment(\.previewTip, shot.tip))
        controller.sizingOptions = []
        let window = ShotWindow(contentRect: NSRect(origin: .zero, size: shot.size),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        AppWindowController.style(window)
        if let look = shot.appearance { window.appearance = NSAppearance(named: look) }
        window.contentViewController = controller
        window.setContentSize(shot.size)
        ShotRun.show(window)
        return window
    }

    /// The content as drawn (the title bar and its toolbar belong to the window server, which a CLI can't ask for the
    /// window without screen-recording permission).
    ///
    /// `cacheDisplay` of the whole window skips the content of every SwiftUI `ScrollView` (its document view is only drawn
    /// when asked for on its own), so the Router's brief was missing. Each scroll view's visible content is drawn on its
    /// own and composited over the window, then the views stacked above that scroll view (the bar, the chips, the composer)
    /// again over it.
    private static func capture(_ window: NSWindow, to path: String) {
        let captureWindow = window.attachedSheet ?? window
        guard let view = captureWindow.contentView else { return }
        // The window server's picture first (it has every scroll view's content as shown); without one, the window drawn
        // here.
        if ShotCapture.writeWindowPicture(view, to: path) { return }
        view.layoutSubtreeIfNeeded()
        guard let base = snapshot(view, view.bounds) else { return }
        // Composited in a bitmap context of our own, top to bottom: the window pass, then each scroll view's content, then
        // the views stacked above it.
        let scale = captureWindow.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        func draw(_ rep: NSBitmapImageRep, at rect: NSRect) {
            guard let image = rep.cgImage else { return }
            // `rect` is in the root's coordinates (flipped or not); the context's origin is the bottom left.
            let y = view.isFlipped ? view.bounds.height - rect.maxY : rect.minY
            ctx.draw(image, in: CGRect(x: rect.minX * scale, y: y * scale, width: rect.width * scale, height: rect.height * scale))
        }
        // Opaque from the start: what no pass draws is the window's ground, not a hole.
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(base, at: view.bounds)
        var above = false
        for child in view.subviews {
            let documents = scrollViews(in: child).compactMap(\.documentView)
            if !documents.isEmpty {
                for document in documents {
                    let visible = document.visibleRect
                    if let shot = snapshot(document, visible) { draw(shot, at: document.convert(visible, to: view)) }
                }
                above = true
            } else if above, let shot = snapshot(child, child.bounds) {
                draw(shot, at: child.convert(child.bounds, to: view))
            }
        }
        guard let cg = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func snapshot(_ view: NSView, _ rect: NSRect) -> NSBitmapImageRep? {
        // With an alpha channel (the cache `bitmapImageRepForCachingDisplay` makes has none, so a transparent view came out
        // black and shadows piled up), and transparent to begin with.
        let scale = view.window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rect.size
        if let data = rep.bitmapData { memset(data, 0, rep.bytesPerRow * rep.pixelsHigh) }
        view.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// The SwiftUI scroll views with a document (the sidebar's included) under a view, in drawing order.
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        // SwiftUI's only: an AppKit text field's own scroll view draws fine in the window pass.
        if let scroll = view as? NSScrollView, scroll.documentView != nil, String(describing: type(of: scroll)).contains("Hosting") { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }
}

private extension UUID {
    var asCategory: AppDestination { .category(self) }
}

extension AppWindowShots {
    /// A day of the Router's model calls, for the usage shot.
    static func demoUsage(_ now: Date) -> [ModelUsageLog.Entry] {
        func e(_ role: ModelUsageLog.Role, _ model: String, _ n: Int, _ u: ModelUsage, ago: TimeInterval) -> [ModelUsageLog.Entry] {
            (0..<n).map { i in ModelUsageLog.Entry(at: now.addingTimeInterval(-ago - Double(i) * 60), role: role, model: model, usage: u) }
        }
        return e(.decider, "claude-sonnet-5-5", 14, ModelUsage(inputTokens: 7400, outputTokens: 300, cacheReadTokens: 27800, cacheCreationTokens: 0, costUSD: 0.024), ago: 600)
            + e(.cards, "claude-haiku-5-5", 31, ModelUsage(inputTokens: 3100, outputTokens: 150, cacheReadTokens: 1400, cacheCreationTokens: 0, costUSD: 0.0004), ago: 300)
            + e(.brief, "claude-haiku-5-5", 22, ModelUsage(inputTokens: 5200, outputTokens: 420, cacheReadTokens: 2100, cacheCreationTokens: 300, costUSD: 0.0008), ago: 200)
            + e(.jev, "jev-1.14.0", 40, ModelUsage(inputTokens: 3200, outputTokens: 40, costUSD: 3200 * 0.042 / 1e6), ago: 100)
            + e(.decider, "claude-sonnet-5-5", 60, ModelUsage(inputTokens: 7000, outputTokens: 290, cacheReadTokens: 26000, cacheCreationTokens: 900, costUSD: 0.026), ago: 3 * 86400)
    }
}
