import SwiftUI

// The app window's chrome on macOS 26 (docs/design/fjord/glass-plan.md §5.2–§5.3): the sidebar an inset panel, glass (or
// its opaque fill), folding to a rail of the same shape; the page beside it, laid out once at the fold's end and drawn on
// the fold's spring; the sidebar toggle, back and forward as plain buttons on the title line right after the window's
// three buttons, in the same place whether the sidebar is out (on its glass) or a rail (over the page's line), so a fold
// moves everything round them and never them. macOS 14 and 15 keep the flat sidebar.

/// Where the window's chrome sits on macOS 26.
@MainActor
enum WindowChrome {
    /// The sidebar's distance from the window's top, leading and bottom edges.
    static let inset: CGFloat = 8
    /// The smallest corner a shape concentric with the window takes, so a full-screen window (no radius) still leaves
    /// rounded corners inside it.
    static let minimumRadius: CGFloat = 6

    /// The sidebar panel's width: the rail's, or the sidebar's.
    static func panelWidth(collapsed: Bool) -> CGFloat { collapsed ? AppSidebar.railWidth : AppRootView.sidebarWidth }

    /// The sidebar panel's top, from the window's: the inset when it is out, the window's three buttons on its glass; under
    /// the header's line as a rail, which leaves that line to the three buttons and the nav buttons after them.
    static func panelTop(collapsed: Bool) -> CGFloat { collapsed ? CDS.TitleBar.header : inset }

    /// Where the page starts, from the window's leading edge: the panel and its inset.
    static func pageLeading(collapsed: Bool) -> CGFloat { inset + panelWidth(collapsed: collapsed) }

    /// Room the page's header leaves at its start for the nav buttons: up to their end and a gap when the sidebar is a rail
    /// (they sit over the page's line then), none when it is out (they sit on the sidebar).
    static func headerInset(collapsed: Bool) -> CGFloat {
        collapsed ? AppNavButtons.leading + AppNavButtons.capsuleWidth - pageLeading(collapsed: true) : 0
    }

    /// The sidebar's shape: concentric with the window's corners (its radius less the inset) under the root's
    /// `containerShape`, never under `minimumRadius`; the same radius on all four corners.
    @available(macOS 26, *)
    static var panelShape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(minimumRadius)), isUniform: true)
    }
}

/// Ink levels for text and glyphs on chrome: over glass the system's label styles (they adapt to what is behind and to
/// light and dark, §11 S6(4)); on the opaque fills Claude's fixed inks. Status colours are not levels and stay fixed.
enum ChromeInk {
    case primary, secondary, tertiary, disabled

    func style(glass: Bool) -> AnyShapeStyle {
        if glass {
            switch self {
            case .primary: return AnyShapeStyle(HierarchicalShapeStyle.primary)
            case .secondary: return AnyShapeStyle(HierarchicalShapeStyle.secondary)
            case .tertiary: return AnyShapeStyle(HierarchicalShapeStyle.tertiary)
            case .disabled: return AnyShapeStyle(HierarchicalShapeStyle.quaternary)
            }
        }
        switch self {
        case .primary: return AnyShapeStyle(CDS.Text.primary)
        case .secondary: return AnyShapeStyle(CDS.Text.secondary)
        case .tertiary: return AnyShapeStyle(CDS.Text.muted)
        case .disabled: return AnyShapeStyle(CDS.Text.disabled)
        }
    }
}

/// Fills for hover and selection on the window's chrome (sidebar rows, the nav buttons): over glass the alpha
/// steps of `Brand.ink` (`BarGlass.alpha`, §5.8), on the opaque fills Claude's ghost tokens, where a selected row hovered
/// stays selected.
enum ChromeFill {
    static func color(selected: Bool, hovered: Bool, glass: Bool, scheme: ColorScheme) -> Color {
        guard glass else { return selected ? CDS.Fill.ghostSelected : hovered ? CDS.Fill.ghostHover : .clear }
        let step: BarGlass.Step? = selected ? (hovered ? .selectedHover : .selected) : hovered ? .hover : nil
        return step.map { Brand.ink.opacity(BarGlass.alpha($0, dark: scheme == .dark)) } ?? .clear
    }
}

extension EnvironmentValues {
    /// The view is drawn on a glass piece of the chrome: its text and glyphs take the label styles (`ChromeInk`).
    @Entry var onGlass = false
}

extension View {
    /// `foregroundStyle` at a chrome ink level, as the glass under it (or not) wants it.
    func chromeInk(_ ink: ChromeInk, glass: Bool) -> some View { foregroundStyle(ink.style(glass: glass)) }
}

/// The app window's root on macOS 26: the inset sidebar over the window's ground, the page beside it.
@available(macOS 26, *)
struct InsetWindowLayout: View {
    let store: Store
    let navigator: AppNavigator
    let routerModel: RouterComposerModel
    let hub: HubState
    let search: InboxSearch
    let checksClaudeCode: Bool
    let sidebar: SidebarState
    let chrome: Chrome

    var body: some View {
        let collapsed = sidebar.collapsed
        let glass = chrome.mode == .glass
        ZStack(alignment: .topLeading) {
            page(start: WindowChrome.pageLeading(collapsed: collapsed), collapsed: collapsed)
                .environment(\.windowGlass, glass)
            panel(collapsed: collapsed, glass: glass)
            // The sidebar toggle, back and forward: plain buttons on the title line right after the window's three, at the
            // same place out and folded, on the sidebar's glass when it is out and over the page's line as a rail.
            AppNavButtons(navigator: navigator,
                          sidebarShown: Binding(get: { !sidebar.collapsed }, set: { sidebar.set(collapsed: !$0) }))
                .padding(AppNavButtons.capsulePad)
                .environment(\.onGlass, glass && !collapsed)
                .padding(.leading, AppNavButtons.leading - AppNavButtons.capsulePad)
                .frame(height: CDS.TitleBar.header)
        }
        // What the page uncovers while it follows the fold (its far side as the sidebar comes out) is the window's own s1.
        .clipped()
    }

    /// The page from `start`: a fold animates it on the fold's own spring, in step with the sidebar's edge, its header's
    /// title making room for the nav buttons when they sit over its line. (Laying the page out once at its end and moving
    /// it with an offset measured worse, 13 to 14 hitches in 12 folds against 10 to 11, and jumped what is anchored to the
    /// page's far side; §11.)
    private func page(start: CGFloat, collapsed: Bool) -> some View {
        AppContent(store: store, navigator: navigator, routerModel: routerModel, hub: hub, search: search,
                   checksClaudeCode: checksClaudeCode, leadingInset: WindowChrome.headerInset(collapsed: collapsed))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, start)
    }

    /// The sidebar: an inset panel of glass (or the sidebar's fill) whose width and top follow the fold's spring, and the
    /// sidebar over it, laid out once at its full width and at a fixed place (its rows from the header's line) and only
    /// masked to the panel's shape, so nothing in it moves or lays out again as it folds: the panel's edges move round it.
    private func panel(collapsed: Bool, glass: Bool) -> some View {
        let shape = WindowChrome.panelShape
        let width = WindowChrome.panelWidth(collapsed: collapsed)
        let top = WindowChrome.panelTop(collapsed: collapsed)
        return ZStack(alignment: .topLeading) {
            GlassEffectContainer {
                // Its glass stays on for the morph's capture (left out of the picture, its place cleared there for the
                // morph's G2).
                Color.clear
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .modifier(PanelMaterial(shape: shape, glass: glass, fill: CDS.Surface.sidebar, standsIn: false))
            }
            .padding(.top, top)
            AppSidebar(store: store, navigator: navigator, hub: hub, collapsed: collapsed)
                .frame(width: AppRootView.sidebarWidth, alignment: .leading)
                .frame(maxHeight: .infinity)
                .environment(\.onGlass, glass)
                .frame(width: width, alignment: .leading)
                // Clipped to the panel's width, and its clicks with it: a clip alone leaves the sidebar's scroll view (an
                // AppKit view, 240 wide) taking the clicks on the page's first 180 beside a rail.
                .clipped()
                .contentShape(Rectangle())
                // The panel's shape, from where it is now (above the rows when it is out): what is past a rail's edge is
                // out of sight.
                .mask(alignment: .topLeading) {
                    shape.frame(width: width).frame(maxHeight: .infinity).padding(.top, top - CDS.TitleBar.header)
                }
                .padding(.top, CDS.TitleBar.header)
        }
        .padding([.leading, .bottom], WindowChrome.inset)
    }
}

/// A chrome piece's material: Regular glass, or `fill` with a hairline (Reduce Transparency, Increase Contrast,
/// `FJORD_GLASS=0`). The same views either way, so a switch keeps what is inside (the sidebar's scroll, a hover). A piece
/// that `standsIn` draws its fill instead of glass while the window is captured for the morph (`GlassCapture`); one that
/// doesn't never reads the flag, so a capture never redraws it.
@available(macOS 26, *)
struct PanelMaterial<S: Shape>: ViewModifier {
    let shape: S
    let glass: Bool
    let fill: Color
    let standsIn: Bool
    @Environment(\.glassCapture) private var capture
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let look = GlassLook.of(glass: glass, capturing: standsIn && capture?.on == true, hairline: true)
        content
            .background(shape.fill(fill).opacity(look.fill ? 1 : 0))
            // Twice the width, clipped to the shape: the hairline sits inside it (`ConcentricRectangle` can't be inset).
            .overlay(shape.stroke(CDS.border, lineWidth: 2 * CDS.Sidebar.edge).clipShape(shape).opacity(look.hairline ? 1 : 0)
                .allowsHitTesting(false))
            .glassEffect(look.glass ? .regular : .identity, in: shape)
            // Made again for each appearance: glass whose appearance changes while the window is closed (its content out of
            // the window) keeps the old one's material until something reshapes it, and one that never stands in for a
            // capture is never redrawn on the way in.
            .id(scheme)
    }
}

