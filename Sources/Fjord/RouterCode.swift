import SwiftUI

// The Router's window as a sibling of Claude's Code tab: the brief (RouterBriefView.swift) over the composer and its history's
// drawer, in the app window's detail area. Built on `RouterModel` (RouterView.swift); only the presentation is Claude's.

struct RouterCodeView: View {
    let store: Store
    @Bindable var model: RouterModel
    var close: () -> Void = {}
    var checksClaudeCode = true
    /// Inside the app window the detail area sets the size (and the window's top is the window's job); alone it has its own.
    var embedded = false
    /// Room the window's buttons take at the header's start (when the sidebar is a rail).
    var leadingInset: CGFloat = 0


    var body: some View {
        RouterMain(store: store, model: model, leadingInset: leadingInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // In the app window before macOS 26, the header shows the window's top bar.
            .background { CDS.Surface.s1.padding(.top, embedded ? AppContent.groundTop : 0) }
        .frame(minWidth: embedded ? 0 : 760, minHeight: embedded ? 0 : 520)
        .foregroundStyle(Theme.text)
        .modifier(Brand.Scheme())
        // Inside the app window, the window's tip space draws the tips: a second one would only measure the page again.
        .tipSpace(!embedded)
        .task { if checksClaudeCode { await model.checkClaudeCode(store) } }
    }
}

// MARK: - Main column

struct RouterMain: View {
    let store: Store
    @Bindable var model: RouterModel
    var leadingInset: CGFloat = 0

    /// The page's width, which puts the history at the right (wide) or across the bottom (narrow).
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// The width from which the history sits beside the brief: the brief's column, its margins and the panel.
    static let sideFrom: CGFloat = RouterBriefView.column + 2 * RouterBriefView.gutter + RouterDrawer.width + WindowChrome.inset
    static func historyAtSide(_ width: CGFloat) -> Bool { width >= sideFrom }

    private var open: Bool { store.routerBriefs.drawerOpen }
    private var side: Bool { Self.historyAtSide(width) }

    /// The page's column edges, from its sides: the brief's column centred on the page beside the history, its start past
    /// the window's buttons when they sit on the title line, its end past the history's toggle when that sits there. The
    /// title line, the brief and the composer all take them, so they share one left and one right edge.
    var edges: RouterEdges {
        let page = width - (open && side ? RouterDrawer.width + WindowChrome.inset : 0)
        let inset = AppPage<EmptyView, EmptyView>.columnInset((RouterBriefView.column, RouterBriefView.gutter), pageWidth: page)
        return RouterEdges(leading: max(inset, leadingInset + 14), trailing: max(inset, open && side ? 0 : Self.toggleRoom))
    }

    @Environment(\.windowGlass) private var glass

    var body: some View {
        HStack(spacing: 0) {
            page.frame(maxWidth: .infinity)
            if open && side {
                // The window's whole height, inset as the left sidebar is: its title on the title line, the toggle over it.
                RouterDrawer(store: store, titleHeight: CDS.TitleBar.header - WindowChrome.inset)
                    .frame(width: RouterDrawer.width)
                    .padding([.top, .trailing, .bottom], WindowChrome.inset)
                    .transition(AnyTransition.slide(from: .trailing, reduce: reduce))
            }
        }
        // The history's toggle mirrors the sidebar's: at the title line's far end, on the history's glass when it is there.
        .overlay(alignment: .topTrailing) {
            AppIconButton(symbol: side ? "sidebar.right" : "rectangle.bottomthird.inset.filled",
                          help: open ? "Hide history" : "Show history", key: "⌥⌘B", enabled: true) {
                withAnimation(Motion.spatial.resolved(reduce: reduce)) { store.routerBriefs.drawerOpen.toggle() }
            }
            .environment(\.onGlass, glass && open && side)
            .padding(.trailing, Self.toggleTrailing)
            .frame(height: CDS.TitleBar.header)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }

    /// The toggle's room from the window's far edge, as the sidebar's is from its near one past the window's buttons.
    static let toggleTrailing: CGFloat = WindowChrome.inset + 10
    /// What the title line leaves it at its end.
    static let toggleRoom: CGFloat = toggleTrailing + CDS.TitleBar.button + 8

    @ViewBuilder private var page: some View {
        if #available(macOS 26, *) {
            // The page runs under its top bar (glass-plan §5.3). The composer floats over the page's bottom
            // (§5.4): its height is the page's bottom inset, so the last line still lands above it and earlier ones scroll
            // under it, fading out under a soft edge down to the window's bottom, as under Claude's composer.
            VStack(spacing: 0) {
                RouterSetupNotice(store: store, model: model)
                RouterBriefView(store: store, model: model, edges: edges)
                    .frame(maxHeight: .infinity)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                composer
                    .frame(maxWidth: .infinity)
                    // The page's ground from the composer's middle down, so no line shows below it or through its glass.
                    .background {
                        LinearGradient(colors: [CDS.Surface.s1.opacity(0), CDS.Surface.s1], startPoint: .top, endPoint: .center)
                            .allowsHitTesting(false)
                    }
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .top, spacing: 0) { topBar }
            .scrollEdgeEffectHidden(true, for: .top)
        } else {
            VStack(spacing: 0) {
                topBar
                RouterSetupNotice(store: store, model: model)
                RouterBriefView(store: store, model: model, edges: edges)
                    .frame(maxHeight: .infinity)
                composer
            }
        }
    }

    /// The composer, and under it the history across the window's bottom when the window is narrow (RouterDrawer.swift).
    private var composer: some View {
        VStack(spacing: 10) {
            RouterComposer(store: store, model: model)
                .padding(.leading, edges.leading).padding(.trailing, edges.trailing)
                .padding(.bottom, open && !side ? 0 : 10)
            if open && !side {
                RouterDrawer(store: store)
                    .frame(height: RouterDrawer.height)
                    .padding([.trailing, .bottom], WindowChrome.inset)
                    .transition(AnyTransition.slide(from: .bottom, reduce: reduce))
            }
        }
    }

    /// §3: a 48pt header holding the 32pt session bar: the title (13pt, wght 460, primary), and when the brief was last
    /// written, muted, as the other pages' subtitles. On the brief's column, as every page's header is on its content's: the
    /// title starts where the text does and the palette's trigger ends where it ends.
    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Router")
                .font(CDS.sans(CDS.Density.compact.body.0, .medium))
                .foregroundStyle(CDS.Text.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            BriefUpdated(store: store)
            Spacer(minLength: 24)
            // The palette's trigger, where the Router's own search field was.
            PaletteTrigger()
        }
        .frame(height: CDS.TitleBar.bar)
        .padding(.leading, edges.leading).padding(.trailing, edges.trailing)
        .frame(height: CDS.TitleBar.header)
        .frame(maxWidth: .infinity)
        // The page's ground behind its title line, so nothing scrolled under it shows through the title.
        .background(CDS.Surface.s1)
    }
}

/// Where the Router page's column starts and ends, from the page's sides (`RouterMain.edges`).
struct RouterEdges: Equatable {
    var leading: CGFloat
    var trailing: CGFloat

    static let standalone = RouterEdges(leading: RouterBriefView.gutter, trailing: RouterBriefView.gutter)
}
