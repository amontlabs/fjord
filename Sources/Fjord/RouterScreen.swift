import AppKit
import SwiftUI

// Router v2's screen: the page (`RouterList`) under its title line, with what floats over it, on the window's ground.
// The page model is made once per app run (`Store.routerPage`) and kept across window opens.

struct RouterScreen: View {
    let model: RouterModel
    /// The app's store and the composer's text model: the History drawer, the setup notice and the @ field read them. A
    /// shot or a test may leave them out (the page alone).
    var store: Store?
    var text: RouterComposerModel?
    /// The demo's stage (its caption, key caps and drawn pointer), when a script plays.
    var stage: RouterStage?
    /// Room the window's buttons take at the header's start (when the sidebar is a rail).
    var leadingInset: CGFloat = 0

    @State private var width: CGFloat = 0
    @State private var screenWidth: CGFloat = 0
    @State private var flags = RouterFlagsWatch()
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.undoManager) private var undoManager
    @Environment(\.windowGlass) private var glass

    /// The width from which the History drawer sits beside the page: the page's column, its margins and the drawer.
    static let sideFrom: CGFloat = Router.column + 2 * Router.gutter + RouterDrawer.width + WindowChrome.inset
    /// The drawer's toggle from the window's far edge, as the sidebar's is from its near one; and the room it takes.
    static let toggleTrailing: CGFloat = WindowChrome.inset + 10
    static let toggleRoom: CGFloat = toggleTrailing + CDS.TitleBar.button + 8

    private var drawerOpen: Bool { store?.routerDrawerOpen == true }
    private var side: Bool { screenWidth >= Self.sideFrom }

    /// The column's edges from the page's sides: the title, the headers, the names and the composer share them. With
    /// the drawer's toggle on the title line, the column's end stays clear of it.
    private var edges: RouterEdges {
        // A wide layout being looked at (`RouterLab`): the title starts with its reading column, the search ends with
        // its last one.
        if let lab {
            let toggle = store != nil && !(drawerOpen && side) ? Self.toggleRoom : 0
            return RouterEdges(leading: max(lab.frame.start, leadingInset + 14), trailing: max(width - lab.frame.end, toggle))
        }
        let column = model.lab == nil ? Router.Wide.column(page: width) : Router.column
        let inset = AppPage<EmptyView, EmptyView>.columnInset((column, Router.gutter), pageWidth: width)
        let toggle = store != nil && !(drawerOpen && side) ? Self.toggleRoom : 0
        return RouterEdges(leading: max(inset, leadingInset + 14), trailing: max(inset, toggle))
    }

    /// The wide layout being looked at, when the page has the room for it (demo only; without, the page is its own).
    private var lab: (option: RouterLab.Option, frame: RouterLab.Frame)? {
        guard let option = model.lab, let frame = RouterLab.frame(option, page: width) else { return nil }
        return (option, frame)
    }

    var body: some View {
        if let store {
            HStack(spacing: 0) {
                page(store).frame(maxWidth: .infinity)
                if drawerOpen && side {
                    // The window's whole height, inset as the left sidebar is: its title on the title line, the toggle over it.
                    RouterDrawer(store: store, titleHeight: CDS.TitleBar.header - WindowChrome.inset)
                        .frame(width: RouterDrawer.width)
                        .padding([.top, .trailing, .bottom], WindowChrome.inset)
                        .transition(AnyTransition.slide(from: .trailing, reduce: reduce))
                }
            }
            .overlay(alignment: .topTrailing) { toggle(store) }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { screenWidth = $0 }
            .environment(\.routerComposer, text.map { (store, $0) })
        } else {
            page(nil)
        }
    }

    /// The History drawer's toggle (⌥⌘B), mirroring the sidebar's: at the title line's far end.
    private func toggle(_ store: Store) -> some View {
        AppIconButton(symbol: side ? "sidebar.right" : "rectangle.bottomthird.inset.filled",
                      help: drawerOpen ? "Hide history" : "Show history", key: "⌥⌘B", enabled: true) {
            withAnimation(Motion.spatial.resolved(reduce: reduce)) { store.routerDrawerOpen.toggle() }
        }
        .environment(\.onGlass, glass && drawerOpen && side)
        .padding(.trailing, Self.toggleTrailing)
        .frame(height: CDS.TitleBar.header)
    }

    private func page(_ store: Store?) -> some View {
        VStack(spacing: 0) {
            topBar
            // The Router off, or Claude Code missing: one line under the title, with its button.
            if let store, let text { RouterSetupNotice(store: store, model: text, edges: edges) }
            if let lab {
                RouterLabPage(model: model, option: lab.option, frame: lab.frame, page: width)
            } else {
                RouterList(model: model, edges: edges)
            }
            if let store, drawerOpen, !side {
                RouterDrawer(store: store)
                    .frame(height: RouterDrawer.height)
                    .padding([.leading, .trailing, .bottom], WindowChrome.inset)
                    .transition(AnyTransition.slide(from: .bottom, reduce: reduce))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { CDS.Surface.s1.padding(.top, AppContent.groundTop) }
        .overlay(alignment: .topLeading) { RouterFloating(model: model) }
        .overlay(alignment: .topLeading) { if let stage { RouterPointerView(stage: stage) } }
        .coordinateSpace(.named(Router.space))
        .onGeometryChange(for: CGSize.self, of: \.size) {
            width = $0.width
            model.targets.viewport = $0
            // The page wide enough for the two-column blocks: they take it at once, with no motion (DESIGN.md 1.15.1).
            let wide = model.lab == nil && Router.Wide.column(page: $0.width) >= Router.Wide.from
            if model.wide != wide { model.wide = wide }
        }
        .foregroundStyle(Theme.text)
        .modifier(Brand.Scheme())
        .environment(\.routerStill, model.still)
        .onAppear {
            model.reduce = reduce
            model.undoManager = undoManager
            flags.start(model)
            // The ages tick on one clock while the page shows (a still's stands).
            if !model.still { model.clock.start() }
            RouterBlockWarmup.once(model)
        }
        .onDisappear {
            flags.stop()
            model.clock.stop()
        }
        .onChange(of: reduce) { _, now in model.reduce = now }
    }

    /// The 48 pt header: the title and, while a script plays, the beat's caption and the keys just pressed.
    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Router")
                .font(CDS.sans(CDS.Density.compact.body.0, .medium))
                .foregroundStyle(CDS.Text.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let stage { RouterCaptionView(stage: stage) }
            Spacer(minLength: 24)
            PaletteTrigger()
        }
        .frame(height: CDS.TitleBar.bar)
        .padding(.leading, edges.leading).padding(.trailing, edges.trailing)
        .frame(height: CDS.TitleBar.header)
        .frame(maxWidth: .infinity)
        .background(CDS.Surface.s1)
    }
}

/// ⌥ held flips the destination row's "steer now" to "queue after this turn", live.
@MainActor final class RouterFlagsWatch {
    private var monitor: Any?

    func start(_ model: RouterModel) {
        guard monitor == nil, !model.still else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak model] event in
            MainActor.assumeIsolated {
                if let model, !model.scripted { model.setOption(event.modifierFlags.contains(.option)) }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Where the Router page's column starts and ends, from the page's sides (`RouterMain.edges`).
struct RouterEdges: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
}
