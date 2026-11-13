import SwiftUI

// What the app window shows for a destination, and the inbox list at full width.

/// A tab of the inbox at the window's width: the same rows as the hub's (`EntryRow`: open, mark read, archive, restore, the
/// context menu), newest first, with the undo line after an archive and "Mark all as read" in the toolbar.
struct InboxListView: View {
    let store: Store
    let tab: InboxTab
    /// The rows' picked state (a row under the pointer), kept here: the window has no hub.
    @State private var hub: HubState
    @State private var search: InboxSearch
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.openApp) private var openApp
    @Environment(\.windowArrival) private var arrival

    static let column: CGFloat = 880
    /// Room the header leaves at its start (the window's buttons, when the sidebar is away).
    let leadingInset: CGFloat

    init(store: Store, tab: InboxTab, hub: HubState? = nil, search: InboxSearch? = nil, leadingInset: CGFloat = 0) {
        self.store = store
        self.leadingInset = leadingInset
        self.tab = tab
        _hub = State(initialValue: hub ?? HubState())
        _search = State(initialValue: search ?? InboxSearch())
    }

    private var entries: [InboxEntry] { store.inboxRows(tab, search: search.query) }
    private var searching: Bool { search.isSearching }

    var body: some View {
        // Worked out once per redraw: the header, the list and the toolbar read the same rows.
        let entries = entries
        let unread = unread(entries)
        AppPage(title: title, subtitle: subtitle(entries, unread: unread), leadingInset: leadingInset,
                column: AppPage<EmptyView, EmptyView>.inboxColumn) {
            if case .category(let id) = tab, store.rulesOff(id) > 0 {
                RulesOffMark(count: store.rulesOff(id), size: 12) { store.editCategory(id, go: openApp) }
            }
            if unread > 0 {
                IconButton(symbol: "envelope.open", help: "Mark all as read", detail: store.shortcut(.markAllRead).display,
                           size: IconButton.Size.header) {
                    withAnimation(Motion.fade.resolved(reduce: reduce)) { entries.filter(\.isUnread).forEach(store.markSeen) }
                }
            }
            // Last, so what comes and goes before it never moves it.
            PaletteTrigger()
        } content: {
            if entries.isEmpty {
                empty
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(entries) { EntryRow(entry: $0, store: store, hub: hub).id($0.id) }
                        }
                        .frame(maxWidth: Self.column)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        // A scroller showing up never moves the column.
                        .overlayScrollers()
                    }
                    // An entry asked for (a banner's click) is scrolled to, also when the list is made after the request.
                    .onAppear { scroll(proxy, to: hub.keyboardSelection) }
                    .onChange(of: hub.keyboardSelection) { _, request in scroll(proxy, to: request) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { undoLine }
        .motion(.fade, value: store.inboxRevision)
        // A new search picks its first result, so ↩ opens it straight away.
        .onChange(of: search.query) { hub.selection = searching ? entries.first.map { "i:" + $0.id } : nil }
    }

    /// An unsearched category shares the inbox's count; a query that filters rows counts only what is shown.
    func unread(_ entries: [InboxEntry]) -> Int {
        if tab == .done && !searching { return 0 }
        // The row search splits on spaces, so other whitespace can filter rows even when the header isn't searching.
        if case .category(let id) = tab, search.query.split(separator: " ").isEmpty { return store.unreadCount(id) }
        return entries.reduce(0) { $1.isUnread ? $0 + 1 : $0 }
    }

    private func scroll(_ proxy: ScrollViewProxy, to request: ScrollRequest?) {
        guard let id = request?.id.dropFirst(2) else { return }
        DispatchQueue.main.async {
            // While the window's content arrives, a jump (`WindowArrival`).
            withAnimation(arrival?.active == true ? nil : Motion.follow.resolved(reduce: reduce)) {
                proxy.scrollTo(String(id), anchor: .center)
            }
        }
    }

    private var title: String {
        if searching { return "Search" }
        switch tab {
        case .done: return "Archive"
        case .category: return store.category(tab)?.title ?? "Inbox"
        }
    }

    private func subtitle(_ all: [InboxEntry], unread: Int) -> String {
        if searching { return all.isEmpty ? "" : "\(all.count) found" }
        if all.isEmpty { return "" }
        if tab == .done { return "\(all.count) archived" }
        if store.category(tab)?.isCI == true { return "\(all.count) failing" }
        return unread > 0 ? "\(unread) unread of \(all.count)" : "\(all.count), all read"
    }

    private var empty: some View {
        let text: String = if searching {
            "Nothing found"
        } else if tab == .done {
            "Nothing here yet"
        } else if store.category(tab)?.isCI == true {
            "Everything is passing"
        } else {
            "All caught up"
        }
        return VStack(spacing: 8) {
            Image(systemName: tab == .done ? "archivebox" : (store.category(tab)?.symbol ?? "tray"))
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(CDS.Text.muted.opacity(0.7))
            Text(text).font(CDS.sans(13)).foregroundStyle(CDS.Text.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// After an archive, for a few seconds: what happened and a way to take it back (⌘Z does it for 30 s).
    private var undoLine: some View {
        Group {
            if let entry = store.undoStack.line {
                HStack(spacing: 10) {
                    Text(entry.message).font(CDS.sans(13)).foregroundStyle(CDS.Text.secondary)
                    Button("Undo") { store.undoLast() }
                        .buttonStyle(.plain)
                        .font(CDS.sans(13, .medium))
                        .foregroundStyle(CDS.Text.accent)
                        .help("Puts it back · ⌘Z")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(CDS.Surface.s3))
                .overlay(Capsule().strokeBorder(CDS.border, lineWidth: 1))
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .motion(.fade, value: store.undoStack.line?.id)
    }
}

/// A page under Claude's 48pt header: the title (13pt, medium) and what it holds, muted, then the page's own buttons at the
/// end. The header's start is left to the window's buttons (sidebar toggle, back, forward). On macOS 26 the header is the
/// page's top bar and its scroll view runs under it, softened by the system's scroll edge effect (glass-plan §5.3); before,
/// the header sits over the page.
struct AppPage<Trailing: View, Content: View>: View {
    let title: String
    var subtitle = ""
    var leadingInset: CGFloat = 0
    /// The page's content column: at most `width` wide, `padding` in from the page's edges, centred. The header's title
    /// and its buttons line up with its edges.
    var column: (width: CGFloat, padding: CGFloat)
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(title: String, subtitle: String = "", leadingInset: CGFloat = 0,
         column: (width: CGFloat, padding: CGFloat) = AppPage.settingsColumn,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.leadingInset = leadingInset
        self.column = column
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26, *) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top, spacing: 0) { header }
                .scrollEdgeEffectHidden(true, for: .top)
        } else {
            VStack(spacing: 0) {
                header
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The inbox's list column (`InboxListView.column`, 20 in), and Settings' and Categories' (680 with 24 inside it).
    static var inboxColumn: (width: CGFloat, padding: CGFloat) { (InboxListView.column, 20) }
    static var settingsColumn: (width: CGFloat, padding: CGFloat) { (680 - 2 * CDS.Settings.pagePadX, CDS.Settings.pagePadX) }

    /// From the page's edges to its content column's, on a page `pageWidth` wide.
    static func columnInset(_ column: (width: CGFloat, padding: CGFloat), pageWidth: CGFloat) -> CGFloat {
        guard pageWidth > 0 else { return column.padding }
        return max(column.padding, (pageWidth - min(column.width, pageWidth - 2 * column.padding)) / 2)
    }

    private var header: some View {
        // On the content column's edges, so the title starts where the content does and the buttons end where it ends;
        // the title 14 past the window's buttons at least when they are in the header. Worked out from the width the
        // header is given as it is laid out, so the first layout has them right (no measuring, no second pass).
        HeaderInsets(column: column, leadingInset: leadingInset) {
            HStack(spacing: 8) {
                Text(title)
                    .font(CDS.sans(CDS.Density.compact.body.0, .medium))
                    .foregroundStyle(CDS.Text.primary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle).font(CDS.sans(CDS.Density.compact.footnote.0)).foregroundStyle(CDS.Text.muted).lineLimit(1)
                }
                Spacer(minLength: 24)
                trailing
            }
        }
        .frame(height: CDS.TitleBar.header)
        .frame(maxWidth: .infinity)
        // The page's own ground behind its title line, so nothing scrolled under it shows through the title.
        .background(CDS.Surface.s1)
    }
}

/// A page header's line, inset from the width it is given to the page's content column (`AppPage.columnInset`), its
/// leading inset at least `leadingInset + 14`: as wide as it is offered. The Router's header uses it too, on the inbox's
/// column, so its title and the palette's trigger are where the inbox's are.
struct HeaderInsets: Layout {
    let column: (width: CGFloat, padding: CGFloat)
    let leadingInset: CGFloat

    private func insets(_ width: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let inset = AppPage<EmptyView, EmptyView>.columnInset(column, pageWidth: width)
        return (max(inset, leadingInset + 14), inset)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let line = subviews.first else { return .zero }
        guard let width = proposal.width else {
            let natural = line.sizeThatFits(.unspecified)
            let pad = insets(0)
            return CGSize(width: natural.width + pad.leading + pad.trailing, height: natural.height)
        }
        let pad = insets(width)
        let size = line.sizeThatFits(ProposedViewSize(width: max(0, width - pad.leading - pad.trailing), height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let line = subviews.first else { return }
        let pad = insets(bounds.width)
        line.place(at: CGPoint(x: bounds.minX + pad.leading, y: bounds.midY), anchor: .leading,
                   proposal: ProposedViewSize(width: max(0, bounds.width - pad.leading - pad.trailing), height: bounds.height))
    }
}

/// The window's content column for the selected destination.
struct AppContent: View {
    let store: Store
    let navigator: AppNavigator
    let routerModel: RouterComposerModel
    let hub: HubState
    var search = InboxSearch()
    var checksClaudeCode = true
    /// Room the window's buttons take at the start when the sidebar is away.
    var leadingInset: CGFloat = 0

    var body: some View {
        Group {
            switch navigator.selection {
            case .category(let id): InboxListView(store: store, tab: .category(id), hub: hub, search: search, leadingInset: leadingInset).id(id)
            case .done: InboxListView(store: store, tab: .done, hub: hub, search: search, leadingInset: leadingInset).id("done")
            case .router:
                if let v2 = RouterDemo.model {
                    // The Router v2 page on its demo records (`--router-v2-demo`, the `v2-` shots).
                    RouterScreen(model: v2, store: store, text: routerModel, stage: RouterDemo.stage, leadingInset: leadingInset)
                        .transformEnvironment(\._accessibilityReduceMotion) { if RouterDemo.reduceMotion { $0 = true } }
                } else {
                    RouterScreen(model: store.routerPage, store: store, text: routerModel, leadingInset: leadingInset)
                        .task { if checksClaudeCode { await routerModel.checkClaudeCode(store) } }
                }
            case .settings:
                AppPage(title: "Settings", leadingInset: leadingInset, trailing: { EmptyView() }) {
                    column { SettingsView(store: store, hub: hub) }
                }
            case .categories:
                AppPage(title: "Inbox categories", leadingInset: leadingInset, trailing: { EmptyView() }) {
                    column { CategoriesView(store: store, hub: hub) }
                }
            case .snippets:
                AppPage(title: "Snippets", subtitle: store.snippets.isEmpty ? "" : plural(store.snippets.count, "snippet"),
                        leadingInset: leadingInset, trailing: { EmptyView() }) {
                    column { SnippetsView(store: store) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Under the window's top bar only, where it has a ground of its own (before macOS 26): the header shows it.
        .background { CDS.Surface.s1.padding(.top, Self.groundTop) }
        .clipped()
    }

    /// Where the page's own ground starts: under the top bar before macOS 26, at the top on 26, where the page runs under
    /// its header.
    static var groundTop: CGFloat {
        if #available(macOS 26, *) { return 0 }
        return CDS.TitleBar.header
    }

    /// Settings, the categories and the snippets were made for a narrow panel: a readable column, centred.
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
    }
}
