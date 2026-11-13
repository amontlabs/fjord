import AppKit
import SwiftUI
import Testing
@testable import Fjord

/// The window's macOS 26 chrome (docs/design/fjord/glass-plan.md §5.2): an inset sidebar, the page beside it laid out once
/// at the fold's end and drawn by an offset that starts at the whole distance and lands with the sidebar's edge.
@MainActor
@Suite struct WindowChromeTests {
    @Test func thePageStartsWhereTheInsetPanelEnds() {
        #expect(WindowChrome.pageLeading(collapsed: false) == WindowChrome.inset + AppRootView.sidebarWidth)
        #expect(WindowChrome.pageLeading(collapsed: true) == WindowChrome.inset + AppSidebar.railWidth)
    }

    /// Out, the panel runs from the inset with the window's three buttons on it; as a rail it starts under the header's
    /// line, which holds the three buttons and the nav buttons after them, clear of each other.
    @Test func theRailStartsUnderTheHeadersLine() {
        #expect(WindowChrome.panelTop(collapsed: false) == WindowChrome.inset)
        #expect(WindowChrome.panelTop(collapsed: true) == CDS.TitleBar.header)
        #expect(WindowChrome.panelWidth(collapsed: true) == AppSidebar.railWidth)
        // The nav buttons, centred on the line, end above the rail's top.
        #expect((CDS.TitleBar.header + CDS.TitleBar.button + 2 * AppNavButtons.capsulePad) / 2 <= WindowChrome.panelTop(collapsed: true))
    }

    /// The nav buttons sit after the window's three, inside the expanded sidebar; folded, the page's title makes room for
    /// them over its line, and out it starts at the page's start.
    @Test func theNavButtonsSitAfterTheWindowsButtonsInsideTheSidebar() {
        #expect(AppNavButtons.leading >= TrafficLights.end + 10)
        #expect(AppNavButtons.leading + AppNavButtons.capsuleWidth <= WindowChrome.pageLeading(collapsed: false) - WindowChrome.inset)
        #expect(WindowChrome.pageLeading(collapsed: true) + WindowChrome.headerInset(collapsed: true)
                == AppNavButtons.leading + AppNavButtons.capsuleWidth)
        #expect(WindowChrome.headerInset(collapsed: false) == 0)
    }

    /// Opaque, the sidebar's ghost tokens as before; on glass ink steps of their own, nothing at rest either way.
    @Test func chromeFillsAreInkStepsOnGlassAndTheGhostTokensOpaque() {
        for scheme in [ColorScheme.dark, .light] {
            #expect(ChromeFill.color(selected: false, hovered: false, glass: false, scheme: scheme) == .clear)
            #expect(ChromeFill.color(selected: false, hovered: true, glass: false, scheme: scheme) == CDS.Fill.ghostHover)
            #expect(ChromeFill.color(selected: true, hovered: false, glass: false, scheme: scheme) == CDS.Fill.ghostSelected)
            #expect(ChromeFill.color(selected: true, hovered: true, glass: false, scheme: scheme) == CDS.Fill.ghostSelected)
            #expect(ChromeFill.color(selected: false, hovered: false, glass: true, scheme: scheme) == .clear)
            #expect(ChromeFill.color(selected: false, hovered: true, glass: true, scheme: scheme) != CDS.Fill.ghostHover)
            #expect(ChromeFill.color(selected: true, hovered: false, glass: true, scheme: scheme) != CDS.Fill.ghostSelected)
        }
    }


    @Test func aShapeInsetInTheWindowKeepsTheFloorInFullScreen() {
        #expect(Theme.Radius.concentric(0, inset: WindowChrome.inset, minimum: WindowChrome.minimumRadius) == 6)
        #expect(Theme.Radius.concentric(26, inset: WindowChrome.inset, minimum: WindowChrome.minimumRadius) == 18)
    }
}

/// The window's root in a window: the page where the panel ends and under its header, the same geometry with glass and with
/// the opaque fills, and a fold the page follows.
@MainActor
@Suite(.hostsWindows) struct WindowChromeHostedTests {
    private func scrolls(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls) }

    @Test(arguments: [Chrome.Mode.glass, .opaque])
    func thePageSitsBesideTheSidebarAndFollowsItsFold(mode: Chrome.Mode) async throws {
        guard #available(macOS 26, *) else { return }
        let store = Store()
        Demo.populate(store)
        let category = try #require(store.shownCategories.max { store.count($0.id) < store.count($1.id) })
        let sidebar = SidebarState(defaults: nil, collapsed: false)
        let root = AppRootView(store: store, navigator: AppNavigator(start: .category(category.id), defaults: nil),
                               routerModel: RouterComposerModel(), hub: HubState(), checksClaudeCode: false, sidebar: sidebar,
                               chrome: Chrome(mode: mode))
        let size = NSSize(width: 1200, height: 800)
        let hosting = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
        let window = AwayWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
                                defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.orderOut(nil) }

        /// The inbox list: the widest scroll (the sidebar's is narrower).
        func list() -> NSRect? {
            hosting.layoutSubtreeIfNeeded()
            return scrolls(hosting).map { $0.convert($0.bounds, to: nil) }.max { $0.width < $1.width }
        }
        await waitUntil { (list()?.width ?? 0) > 600 }
        await waitUntilSteady(turns: 8) { list().map { [Int($0.minX), Int($0.width)] } }
        let out = try #require(list())
        #expect(Int(out.minX) == Int(WindowChrome.pageLeading(collapsed: false)), "\(out)")
        // The list runs under the page's header (its top bar), not from under it.
        #expect(out.maxY > size.height - CDS.TitleBar.header, "\(out)")

        // Folded: the page lands beside the rail.
        sidebar.set(collapsed: true)
        await waitUntilSteady(turns: 8, quiet: 0.5) { list().map { [Int($0.minX), Int($0.width)] } }
        let rail = try #require(list())
        #expect(Int(rail.minX) == Int(WindowChrome.pageLeading(collapsed: true)), "\(rail)")
    }

}
