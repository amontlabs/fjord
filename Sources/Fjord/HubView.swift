import AppKit
import SwiftUI

// Fjord docked: one bar on a screen edge. Hovering an item opens its peek beside the bar, and the peek's rows
// act; a click opens the app window (AppWindow.swift) on that item, and the bar leaves the edge until the window
// closes.

/// A tab of the inbox: a category, or the archive at the end.
enum InboxTab: Hashable {
    case category(UUID)
    case done
}

extension EnvironmentValues {
    /// Opens the app window on a place. The window controller in the app; a toast in shots.
    @Entry var openApp: (AppDestination) -> Void = { _ in }
    /// Opens the app window where it was left (the mark at the end of the bar).
    @Entry var reopenApp: () -> Void = {}
    /// Opens the app window on Settings, scrolled to Updates.
    @Entry var openUpdates: () -> Void = {}
    /// Opens the app window on the Router, on a brief entry if one is given.
    @Entry var openRouter: (BriefTarget?) -> Void = { _ in }
    /// Opens the app window on the Router, scrolled to a message of its conversation (an inbox action's).
    @Entry var openRouterMessage: (UUID) -> Void = { _ in }
    /// Picks a brief entry (window open or not): a click on it in the bar's panel, before the window opens on the Router.
    @Entry var pickBriefEntry: (BriefTarget) -> Void = { _ in }
    /// "Open in Router" on an inbox thing (its id): the app window on the Router, its composer holding the thing's pill and
    /// the keyboard, for you to say what to do with it. Nil where the Router can't take it (off, or nothing to open it):
    /// the rows offer no such action.
    @Entry var openInRouter: ((String) -> Void)? = nil
    /// Whether SwiftUI has the pointer over the bar or its panel, for a host that has no `HubController` (the playground). The
    /// app ignores it: the controller alone decides, from where the hub is drawn.
    @Entry var hubPointer: (Bool) -> Void = { _ in }
}

@Observable
@MainActor
final class HubState {
    var hovering = false
    /// No hover panels until the pointer has left the bar (set when the bar comes back under a still pointer).
    var quiet = false
    /// The bar is away while the app window is open (the playground draws it, the app orders its panel out).
    var barHidden = false
    /// "i:<item id>": the row the pointer is on (or the one an opened notification names); its actions show.
    var selection: String? {
        didSet {
            guard selection != oldValue else { return }
            if let oldValue { marks[oldValue]?.on = false }
            if let selection { marks[selection]?.on = true }
            if marks.count > Mark.kept { marks = Mark.pruned(marks) }
        }
    }
    /// Whether a row is the selection, read by the row itself (`isSelected`): each row observes its own mark, so the pointer
    /// moving from row to row redraws the two rows it left and entered, not every row that compares itself with
    /// `selection`.
    @ObservationIgnored private var marks: [String: Mark] = [:]
    @Observable final class Mark {
        var on: Bool
        init(on: Bool) { self.on = on }

        /// More marks than rows are ever drawn: those of rows gone (archived, filtered out, another tab's) are let go.
        static let kept = 400

        /// None kept: each is touched on the way out, so a row still drawn reads its mark again (making a new one) and
        /// one gone is forgotten. Called on a change of the pick, never while a row is drawn.
        static func pruned(_ marks: [String: Mark]) -> [String: Mark] {
            // Flipped there and back: setting the same value tells nobody.
            for mark in marks.values { mark.on.toggle(); mark.on.toggle() }
            return [:]
        }
    }

    /// Whether `id` is the selection, observing only that row's mark.
    func isSelected(_ id: String) -> Bool {
        if let mark = marks[id] { return mark.on }
        // The stored value, read without observing it (the row observes its mark alone).
        let mark = Mark(on: _selection == id)
        marks[id] = mark
        return mark.on
    }
    /// The last row asked for (a notification's): the lists scroll to it. Never set by hovering, so the pointer moving over a
    /// row doesn't move the list.
    var keyboardSelection: ScrollRequest?
    /// The tab the inbox peek shows: the category cell the pointer is on, or one of its tabs; nil is the first category shown.
    var tab: InboxTab? {
        didSet { selection = nil; keyboardSelection = nil }
    }
    /// Asks the lists to scroll to a row, even one asked for before (a new request every time).
    func requestScroll(_ id: String) {
        keyboardSelection = ScrollRequest(id: id, seq: (keyboardSelection?.seq ?? 0) + 1)
    }
    /// Asks Settings to scroll to a section (by name), once it is open: where Check for Updates shows what it found.
    var settingsScroll: ScrollRequest?
    /// Asks Settings to scroll to its Updates section, also when it is open already, scrolled elsewhere.
    func showUpdates() {
        settingsScroll = ScrollRequest(id: SettingsView.updatesID, seq: (settingsScroll?.seq ?? 0) + 1)
    }
    /// Asks the categories page to open a category's editor, or unfold a group (a Router change's Open button): it takes the
    /// request when it appears, or at once when it is open.
    var categoryRequest: ScrollRequest?
    var groupRequest: ScrollRequest?
    func openCategory(_ id: UUID) { categoryRequest = ScrollRequest(id: id.uuidString, seq: (categoryRequest?.seq ?? 0) + 1) }
    func openGroup(_ id: UUID) { groupRequest = ScrollRequest(id: id.uuidString, seq: (groupRequest?.seq ?? 0) + 1) }
    var toast: String?

    /// The category editor's own step back, set while one is open (see `CategoriesView`).
    @ObservationIgnored var stepBack: (() -> Bool)?

    /// The section the pointer is on: just that one opens beside the bar.
    var section: HubSection?
    /// The bar is being carried to another edge: no panels meanwhile.
    @ObservationIgnored var dragging = false
    @ObservationIgnored private var dwell: Task<Void, Never>?
    /// The section a dwell is waiting on, only while it waits: on glass its panel is measured meanwhile, out of sight, so it
    /// opens already placed and its glass grows out of the bar's.
    private(set) var arriving: HubSection?

    /// How long the pointer rests on a section before its first panel opens: long enough that sweeping along the edge opens
    /// nothing, short enough that a hover reads as instant.
    static let dwell: Duration = .milliseconds(70)

    /// The pointer entered a section. The first panel waits for the pointer to settle (so sweeping along the edge
    /// opens nothing); once one is open, moving to another section switches at once, with no transition.
    func enter(_ next: HubSection) {
        dwell?.cancel()
        guard !barHidden, !quiet, !dragging else { arrive(nil); return }
        if section != nil {
            arrive(nil)
            guard section != next else { return }
            var instant = Transaction(animation: nil)
            instant.disablesAnimations = true
            withTransaction(instant) { section = next }
            return
        }
        arrive(next)
        dwell = Task { [weak self] in
            try? await Task.sleep(for: HubState.dwell)
            guard let self, !Task.isCancelled else { return }
            arrive(nil)
            guard !barHidden, !quiet, !dragging else { return }
            // "Peek": until the commit that carries the panel to the render server, its first frame.
            let peek = LatencySignposts.signposter.beginInterval("Peek")
            section = next
            LatencySignposts.endAfterCommit("Peek", peek)
        }
    }

    /// The pointer left a section before it settled: nothing opens.
    func cancelDwell() {
        dwell?.cancel()
        arrive(nil)
    }

    /// Only a change is written, so a bar at rest (or a pointer moving over one section) invalidates nothing.
    private func arrive(_ next: HubSection?) {
        if arriving != next { arriving = next }
    }

    /// The bar's and the panels' views (`HubPiece`): where each is drawn, read when the pointer moves.
    @ObservationIgnored let pieces = NSHashTable<HubPieceView>.weakObjects()

    /// Where the bar is drawn on screen, if it is in a window.
    var barOnScreen: NSRect? {
        pieces.allObjects.lazy.filter { $0.section == nil }.compactMap(\.screenFrame).first
    }

    /// Where the panel of the section shown is drawn on screen: none while quiet; two while one closing (still fading
    /// out) is drawn under the same section opening again. One fading out after another section opened doesn't count.
    var panelsOnScreen: [NSRect] {
        guard let section, !quiet else { return [] }
        return pieces.allObjects.filter { $0.section == section }.compactMap(\.screenFrame)
    }
}

/// An empty AppKit view SwiftUI lays out exactly where a piece of the hub is drawn: the bar, or a section's panel. Whether
/// the pointer is on the hub is decided from these, read as the pointer moves, so it is always where things are on screen
/// at that moment. A frame SwiftUI reports (`onGeometryChange`) can come a layout late, or not until something else changes:
/// the inbox panel, sized from its own measured list, kept the frame of its header alone while its rows were drawn under it,
/// and moving onto a row closed it.
final class HubPieceView: NSView {
    /// nil: the bar; else the section whose panel this is.
    var section: HubSection?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Never in the way of the pointer: SwiftUI's own hovers and clicks go on as if it weren't there.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where it is on screen, if it is in a window.
    var screenFrame: NSRect? {
        guard let window, !isHiddenOrHasHiddenAncestor else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}

/// Puts a `HubPieceView` behind a piece of the hub, the same size and in the same place.
struct HubPiece: NSViewRepresentable {
    let hub: HubState
    let section: HubSection?

    func makeNSView(context: Context) -> HubPieceView {
        let view = HubPieceView()
        view.section = section
        hub.pieces.add(view)
        return view
    }

    func updateNSView(_ view: HubPieceView, context: Context) {
        view.section = section
        hub.pieces.add(view)
    }
}

/// The bar, and beside it the peek of the section the pointer is on: each cell of the bar stays beside the content it stands for.
struct FjordHub: View {
    let store: Store
    let ui: UIState
    @Bindable var hub: HubState
    /// Where each section's cells are in the bar, and whether the pointer is on the bar or a section's panel (for a host
    /// without the controller, the playground: `hubPointer`).
    @State var sectionFrames: [HubSection: CGRect] = [:]
    @State var overBar = false
    @State var overPanel = false
    /// The bar's size and the open panel's natural size, to place the panel against the bar's ends.
    @State var barSize: CGSize = .zero
    @State var peekSizes: [HubSection: CGSize] = [:]
    @Environment(\.accessibilityReduceMotion) var reduce
    /// Opens the app window on a place, or on a brief entry.
    @Environment(\.openApp) var openApp
    @Environment(\.reopenApp) var reopenApp
    @Environment(\.openUpdates) var openUpdates
    @Environment(\.openRouter) var openRouter
    @Environment(\.pickBriefEntry) var pickBriefEntry
    @Environment(\.hubPointer) var hubPointer
    /// How the bar and its panels draw (none in a test that draws the bar alone: opaque).
    @Environment(Chrome.self) var chrome: Chrome?
    @Environment(\.colorScheme) var colorScheme
    /// The bar's and the panel's glass shapes, for the panel to grow out of the bar.
    @Namespace var glassSpace

    /// The bar's depth: a cell's width on the sides, the strip's height along the top and bottom.
    static let cell = Theme.Metrics.bar
    /// A peek's width.
    static let detail: CGFloat = 400
    /// The one outer inset. Pieces pad their own 8 inside it, so text starts 14pt from the hub's side everywhere.
    static let inset = Theme.Metrics.inset
    /// The hub's one coordinate space name (the hosting root's).
    static let rootSpace = "hub-root"

    var edge: DockEdge { ui.edge }

    /// The bar and its panels are glass: macOS 26, and the chrome says so.
    var glass: Bool { Chrome.glassAvailable && chrome?.mode == .glass }

    var body: some View {
        let bar = Group {
            if edge.isHorizontal { horizontal } else { vertical }
        }
        .coordinateSpace(.named(Self.barSpace))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in if barSize != size { barSize = size } }
        surface(bar, barOutline)
        // On glass the panel's glass grows out of the bar's on the `glass` spring, its corners with it (its content fades on
        // `fade`, `PeekReveal`); opaque, it fades.
        .motion(glass ? Motion.glass : Motion.fade, value: peeking != nil)
        .fixedSize()
        .contextMenu {
            Button("Open Fjord") { openApp(firstDestination) }
            if store.routerOn {
                Button("Open Router") { openApp(.router) }
            }
            Button("Settings…") { openApp(.settings) }
            if store.triageOn {
                Button("Inbox Categories…") { openApp(.categories) }
            }
            // The snippets serve both tools, as in the window's sidebar.
            if store.triageOn || store.routerOn {
                Button("Snippets…") { openApp(.snippets) }
            }
            if store.updater.isRelease {
                // Settings' update row says what the check finds (up to date, or why it failed); the bar has no room to.
                Button("Check for Updates") {
                    openUpdates()
                    Task { await store.updater.update(manual: true) }
                }
            }
            Divider()
            Button("Quit Fjord") { NSApp.terminate(nil) }
        }
        .modifier(Brand.Scheme())
        .background(UpdateAnnouncer(updater: store.updater))
    }

    /// The bar's surface, with the hovered section's panel beside it (outside the bar's clip; the bar's own size doesn't
    /// change).
    @ViewBuilder func surface(_ bar: some View, _ shape: UnevenRoundedRectangle) -> some View {
        if #available(macOS 26, *) {
            if glass { glassSurface(bar, shape) } else { opaqueSurface(bar, shape) }
        } else {
            opaqueSurface(bar, shape)
        }
    }

    @available(macOS 26, *)
    func glassSurface(_ bar: some View, _ shape: UnevenRoundedRectangle) -> some View {
        // Regular glass, no tint; no ring and no shadows: the material has its own edge and shadow. Bar and panel in one
        // container, so the panel's glass grows out of the bar's and the two read as one shape. Everything on them
        // draws with the glass fills and label styles.
        GlassEffectContainer(spacing: BarGlass.spacing) {
            bar
                .clipShape(shape)
                // The whole shape takes the pointer, as the opaque fill did.
                .contentShape(shape)
                .glassEffect(.regular, in: shape)
                .glassEffectID(BarGlass.ID.bar, in: glassSpace)
                // Where the bar is drawn, for the controller to tell whether the pointer is on it.
                .background(HubPiece(hub: hub, section: nil))
                .onHover { overBar = $0; hubPointer(overBar || overPanel) }
                .overlay(alignment: peekAlignment) { peekPanel }
                .overlay(alignment: peekAlignment) { peekMeasurer }
        }
        .environment(\.onBarGlass, true)
        // A panel's size on one edge is not its size on another: measured again on the next dwell.
        .onChange(of: edge) { peekSizes = [:] }
    }

    /// Today's bar: filled black, ringed, with shadows from shapes.
    func opaqueSurface(_ bar: some View, _ shape: UnevenRoundedRectangle) -> some View {
        bar
            // Where the bar is drawn, for the controller to tell whether the pointer is on it.
            .background(HubPiece(hub: hub, section: nil))
            .onHover { overBar = $0; hubPointer(overBar || overPanel) }
            .background(shape.fill(Theme.bg))
            // Claude's panel ring (`shadow-panel`'s inset white 10%) against the desktop.
            .overlay(shape.strokeBorder(CDS.border, lineWidth: 1))
            .clipShape(shape)
            .overlay(alignment: peekAlignment) { peekPanel }
            // Shadows come from shapes alone, in a layer under the bar and its panel (never a blurred composite of their
            // content, which would be redone on every frame of anything animating inside): the panel's can't fall
            // across the bar, which is opaque above it.
            .background(alignment: peekAlignment) { peekShadow }
            .background {
                // Claude's `shadow-panel` (its two drops) while a panel is open; at rest, only its near one, so the bar sits light.
                let open = peeking != nil
                shape.fill(Theme.bg)
                    .shadow(color: open ? CDS.PanelShadow.far.color : .clear, radius: CDS.PanelShadow.far.radius,
                            y: CDS.PanelShadow.far.y)
                    .shadow(color: CDS.PanelShadow.near.color, radius: CDS.PanelShadow.near.radius, y: CDS.PanelShadow.near.y)
            }
    }

    /// Where the GitHub mark and the bar's Open lead (see `Store.firstPlace`).
    var firstDestination: AppDestination { store.firstPlace }

    // MARK: Data

    /// What the inbox peek lists.
    var items: [InboxEntry] { store.entries(in: store.hubTab(hub)) }
    /// What the inbox list animates on: its entries changing, or the tab swapping them.
    struct ListKey: Equatable { let revision: Int; let tab: InboxTab }
    var listKey: ListKey { ListKey(revision: store.inboxRevision, tab: store.hubTab(hub)) }

    // MARK: Vertical (left / right edges)

    var vertical: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) { mainRows }
            // Last, Fjord's mark: hover for the controls, a click for the window where it was left.
            if store.triageOn || store.routerOn { sectionDivider }
            controlsCell.padding(.vertical, 9)
                .frame(width: Self.cell)
                .modifier(probe(.controls))
        }
    }

    @ViewBuilder var mainRows: some View {
        // Inbox: each section's well, its icon and its categories' cells under it, apart from the Router. With nothing shown,
        // the GitHub mark alone.
        if store.triageOn {
            let sections = store.barSections
            VStack(spacing: 6) {
                if sections.isEmpty { inboxIcon.padding(.vertical, 2).frame(width: Self.cell) }
                ForEach(Array(sections.enumerated()), id: \.element.id) { i, part in
                    VStack(spacing: 0) {
                        if let section = part.section {
                            sectionCell(section, part).padding(.vertical, 2).frame(width: Self.cell)
                        }
                        if part.section?.isCollapsed != true {
                            VStack(spacing: 0) { categoryCells(part.categories) }.frame(width: Self.cell)
                        }
                    }
                    .padding(.bottom, 2)
                    .frame(width: Self.cell)
                    .background {
                        if part.section != nil { sectionWell(first: i == 0).fill(CDS.alpha(0.06)).padding(.horizontal, 6) }
                    }
                }
            }
            // Down from the bar's top as far as a well is in from its sides, so the first sits inset all round.
            .padding(.top, 6)
            .frame(width: Self.cell)
            .modifier(probe(.inbox))
        }
        // The Router: its cell and counts (apart from the inbox, when there is one).
        if store.routerOn {
            if store.triageOn { sectionDivider.padding(.vertical, 6) }
            routerCell.padding(.top, store.triageOn ? 0 : 6).frame(width: Self.cell)
                .modifier(probe(.router))
        }
        if store.updater.showsInPill {
            UpdateButton(updater: store.updater, horizontal: false).padding(.vertical, 4)
                .frame(width: Self.cell)
                .transition(.scaleFade(0.8, reduce: reduce))
        }
    }

    /// A section's well, 6pt inside the bar's sides. The first's top corners follow the bar's (concentric where the bar is
    /// rounded, the tile's radius where it meets the screen edge); every other corner is the tile's.
    func sectionWell(first: Bool) -> UnevenRoundedRectangle {
        let base = CDS.Tile.radius + 4, bar = barOutline.cornerRadii
        func inner(_ r: CGFloat) -> CGFloat { first ? max(base, r - 6) : base }
        return UnevenRoundedRectangle(topLeadingRadius: inner(bar.topLeading), bottomLeadingRadius: base,
                                      bottomTrailingRadius: base, topTrailingRadius: inner(bar.topTrailing), style: .continuous)
    }

    /// A short rule centred in the bar.
    var sectionDivider: some View {
        IslandRule()
            .frame(width: Self.cell - 24)
            .frame(width: Self.cell)
            .padding(.vertical, 4)
    }

    // MARK: Horizontal (top / bottom edges)

    var horizontal: some View {
        HStack(alignment: .center, spacing: 0) { strip }
            .frame(height: Self.cell)
    }

    /// The bar along the top or bottom: the inbox's segment, the Router's, Fjord's mark, the update button.
    @ViewBuilder var strip: some View {
        if store.triageOn {
            let sections = store.barSections
            HStack(spacing: 12) {
                if sections.isEmpty { inboxIcon }
                ForEach(sections) { part in
                    HStack(spacing: 0) {
                        if let section = part.section { sectionCell(section, part) }
                        // The categories' cells beside its icon.
                        if part.section?.isCollapsed != true { HStack(spacing: 0) { categoryCells(part.categories) } }
                    }
                    .background {
                        if part.section != nil {
                            RoundedRectangle(cornerRadius: CDS.Tile.radius + 4, style: .continuous).fill(CDS.alpha(0.06))
                                .padding(.vertical, 5).padding(.horizontal, -3)
                        }
                    }
                }
            }
            .padding(.leading, Self.inset + 1)
            .padding(.trailing, Self.inset)
            .frame(maxHeight: .infinity)
            .modifier(probe(.inbox))
        }
        if store.routerOn {
            if store.triageOn { stripDivider.padding(.horizontal, 6) }
            routerCell
                .padding(.leading, Self.inset + 1)
                .padding(.trailing, Self.inset)
                .frame(maxHeight: .infinity)
                // The whole segment opens the window, not only its cell.
                .contentShape(Rectangle())
                .onTapGesture { openApp(.router) }
                .modifier(probe(.router))
        }
        if store.triageOn || store.routerOn { stripDivider }
        controlsCell
            .padding(.horizontal, Self.inset)
            .frame(maxHeight: .infinity)
            .modifier(probe(.controls))
        if store.updater.showsInPill {
            stripDivider
            HStack(spacing: 0) {
                UpdateButton(updater: store.updater, horizontal: true)
                UpdateMenu(updater: store.updater)
            }
            .padding(.horizontal, 6)
        }
    }

    var stripDivider: some View {
        IslandRule(axis: .vertical).frame(height: 16)
    }
}

/// Under the Router's header: Claude's session files missing or unreadable (nothing when all is well).
struct ClaudeNotice: View {
    let store: Store

    var body: some View {
        switch store.claudeLink {
        case .missing, .unreadable:
            HStack(spacing: 6) { ClaudeLinkStatus(store: store) }
                // One element for VoiceOver: what is wrong, said as shown.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(store.claudeLink == .missing ? "Claude's sessions not found" : "Can't read Claude's sessions")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Space.xs)
        default:
            EmptyView()
        }
    }
}

/// Beside the sync status, on every edge: the GitHub rate limit running low (nothing otherwise).
struct RateNotice: View {
    let store: Store
    /// Takes the whole line (its text at the leading edge); off, only the room it needs.
    var fill = true

    var body: some View {
        RateLimitWarning(store: store)
            .font(Theme.Typography.meta)
            .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
    }
}

// MARK: Island pieces (Claude's frame: dividers, group labels)

/// Claude's divider: `--cds-border` (white 10%) at 0.5pt. `inset` trims both ends.
struct IslandRule: View {
    var axis: Axis = .horizontal
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(CDS.border)
            .frame(width: axis == .vertical ? CDS.hairline : nil, height: axis == .horizontal ? CDS.hairline : nil)
            .padding(axis == .horizontal ? .horizontal : .vertical, inset)
    }
}
