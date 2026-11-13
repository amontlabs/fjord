import AppKit
import SwiftUI

// The hub's sections: what goes in the bar's cells and beside them.
//
// One set of measures for every piece, so the sections read as one surface, Claude's compact density on black:
// - section headers are 30pt: the title as Claude's sidebar label (12/16 muted), then a status in its state's colour,
//   trailing actions as Claude's 24pt ghost icon buttons;
// - the inbox's tabs (a category each, then the archive) are Claude's Tabs, its counts Claude's Badges, its facts chips;
// - rows pad their content 8 × 5 inside a radius-6 fill (white 7.5% on hover or when picked);
//   the layout adds the one outer inset, so nothing here pads itself from the outside;
// - every control has a tooltip: a verb phrase, then what it does and its shortcut, read from the user's settings.

extension FjordHub {
    // MARK: Inbox

    /// The GitHub mark: opens the window on the first category with something unread (the first, when none has).
    var inboxIcon: some View {
        InboxCell(vertical: !edge.isHorizontal) { openApp(firstDestination) }
    }

    /// A section's icon at the top of its well: a click folds its categories into it (their counts added up on it) or
    /// unfolds them. Hovering it peeks its first category with something new.
    func sectionCell(_ section: CategorySection, _ part: BarSection) -> some View {
        SectionCell(section: section, badge: store.sectionBadge(part), vertical: !edge.isHorizontal) {
            withAnimation(Motion.fade.resolved(reduce: reduce)) { store.toggleCollapsed(section.id) }
        }
        .onHover { over in
            guard over, let first = part.categories.first(where: { store.badge($0) > 0 }) ?? part.categories.first else { return }
            hoverTab(.category(first.id))
        }
    }

    /// One cell per category given, in order: its symbol, and on its corner what is unread. Hovering one peeks its list.
    @ViewBuilder func categoryCells(_ categories: [InboxCategory]) -> some View {
        ForEach(categories) { category in
            CategoryCell(category: category, badge: store.badge(category), vertical: !edge.isHorizontal) {
                openApp(.category(category.id))
            }
            .onHover { if $0 { hoverTab(.category(category.id)) } }
        }
    }

    /// A bar hover changes tabs only when it shows a different list, keeping the current row picked otherwise.
    func hoverTab(_ tab: InboxTab) {
        guard !hub.barHidden, !hub.quiet, !hub.dragging, store.hubTab(hub) != tab else { return }
        hub.tab = tab
    }

    /// The peek's header: the inbox's tabs.
    var inboxHeader: some View {
        filters.frame(height: Theme.Metrics.line)
    }

    var filters: some View {
        let tab = store.hubTab(hub)
        let unread = tab == .done ? 0 : store.entries(in: tab).filter(\.isUnread).count
        // Claude's Tabs abut: each pill is inset 1 at its sides, so two pills are 2 apart.
        return HStack(spacing: 0) {
            // The tabs scroll when the column is narrow: the actions after them stay.
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(store.shownCategories) { category in categoryTab(category, selected: tab == .category(category.id)) }
                }
            }
            .scrollIndicators(.never)
            .mask(tabsFade)
            // The archive is not a category: after a gap and a rule, at the tabs' trailing end.
            doneTab(selected: tab == .done).padding(.leading, 6)
            Spacer(minLength: 2)
            // The header's own buttons, apart from the tabs.
            IslandRule(axis: .vertical).frame(height: 14).padding(.horizontal, 3)
            if unread > 0 {
                IconButton(symbol: "envelope.open", help: "Mark all as read",
                           detail: "Everything in \(store.category(tab)?.name ?? "Archive") · \(store.shortcut(.markAllRead).display)",
                           size: IconButton.Size.header) {
                    withAnimation(Motion.fade.resolved(reduce: reduce)) { store.markAllSeen(tab) }
                }
                .transition(.opacity)
            }
            categoriesMenu
        }
        .padding(.trailing, 3)
        .motion(.fade, value: unread > 0)
    }

    /// The tabs' end fades out where more are scrolled out of sight.
    private var tabsFade: some View {
        HStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing).frame(width: 12)
        }
    }

    func categoryTab(_ category: InboxCategory, selected: Bool) -> some View {
        let n = store.badge(category)
        return CategoryTab(category: category, selected: selected, badge: n, store: store) {
            withAnimation(Motion.fade.resolved(reduce: reduce)) { hub.tab = .category(category.id) }
        }
    }

    func doneTab(selected: Bool) -> some View {
        Button {
            withAnimation(Motion.fade.resolved(reduce: reduce)) { hub.tab = .done }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "archivebox").font(.system(size: 12, weight: .medium))
                if selected { Text("Archive") }
            }
            .font(CDS.sans(13, .medium))
            .chromeInk(selected ? .primary : .tertiary, selected ? CDS.Text.primary : CDS.Text.muted)
            .padding(.horizontal, selected ? CDS.Tabs.pad : 4)
            .frame(height: CDS.Tabs.height)
        }
        .buttonStyle(HoverFillButtonStyle(shape: RoundedRectangle(cornerRadius: CDS.Tabs.radius, style: .continuous),
                                          hover: BarGlass.fill(.hover, glass: glass, scheme: colorScheme, opaque: CDS.Fill.ghostHover),
                                          active: BarGlass.fill(.selected, glass: glass, scheme: colorScheme, opaque: CDS.Fill.ghostHover),
                                          pressed: BarGlass.fill(.selected, glass: glass, scheme: colorScheme, opaque: CDS.Fill.ghostHover),
                                          isActive: selected))
        .accessibilityLabel("Archive")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .fixedSize()
        .tip("Archive", "What you archived · it comes back when something new happens")
    }

    /// Like a table's columns menu: a checkmark per category shown. Hidden ones are muted (no notifications, no icon in
    /// the bar) and still collect, so the menu says how many each holds.
    var categoriesMenu: some View {
        CategoriesMenu(store: store) { openApp(.categories) }
    }

    /// One quiet line where the list would be: nothing to act on, so nothing to draw the eye.
    var emptyInbox: some View {
        let tab = store.hubTab(hub)
        let text: String = if store.shownCategories.isEmpty && tab == .done && store.categories.isEmpty == false {
            "Every category is hidden"
        } else if tab == .done {
            "Nothing here yet"
        } else if store.category(tab)?.isCI == true {
            "Everything is passing"
        } else {
            "All caught up"
        }
        return HStack(spacing: 6) {
            Text(text).font(Theme.Typography.body).chromeInk(.tertiary, Theme.tertiary)
            if case .category(let id) = tab, store.rulesOff(id) > 0 {
                RulesOffMark(count: store.rulesOff(id)) { store.editCategory(id, go: openApp) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 5)
    }

    func itemRow(_ entry: InboxEntry) -> some View {
        EntryRow(entry: entry, store: store, hub: hub).capEdge()
    }

    /// A line of text with a link after it, padded like a row ("No CI shown  Choose repositories").
    func linkRow(_ text: String, action: String, _ perform: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(text).chromeInk(.tertiary, Theme.tertiary)
            Button(action, action: perform).buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.control)
        .padding(.horizontal, Theme.Space.md)
        .frame(minHeight: Theme.Metrics.line)
    }

    /// After an archive, for a few seconds: what happened and a way to take it back (⌘Z does it for 30 s). Nothing otherwise.
    var undoLine: some View {
        Group {
            if let entry = store.undoStack.line {
                linkRow(entry.message, action: "Undo") { store.undoLast() }
                    .tip("Undo", "Puts it back · ⌘Z")
                    .transition(.opacity)
            }
        }
        .motion(.fade, value: store.undoStack.line?.id)
    }

    // MARK: Section headers

    /// A section's header: its title and status on the left, its actions on the right; 30pt tall.
    func sectionHeader<Trailing: View>(_ title: String, status: [(String, Color)] = [],
                                       @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.Typography.heading).chromeInk(.tertiary, Theme.tertiary).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(status.enumerated()), id: \.offset) { _, part in
                Text(part.0).font(Theme.Typography.meta.monospacedDigit()).foregroundStyle(part.1).lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, Theme.Space.md)
        .padding(.trailing, 3)
        .frame(height: Theme.Metrics.line)
        .motion(.fade, value: status.map(\.0))
    }

    // MARK: Router

    /// The Router's cell in the bar; a click opens its window. Its count is read in a view of its own, so the brief changing
    /// redraws the cell and not the whole bar.
    var routerCell: some View {
        let openApp = openApp
        return CountedRouterCell(store: store) { openApp(.router) }
    }

    /// "Router", then how many entries need you (amber). The whole line opens its window.
    var routerHeader: some View {
        sectionHeader("Router", status: routerStatusParts)
            .contentShape(Rectangle())
            .onTapGesture { openApp(.router) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the Router · \(store.shortcut(.router).display)")
            .accessibilityAction { openApp(.router) }
    }

    /// An entry clicked on the bar: the Router opens on it, focused. Its thread isn't opened.
    func openRouterRecord(_ record: RouterThread) {
        // The environment closure still takes a `BriefTarget` (HubView, HubController and the window are 9a's); its thread is the record's id.
        pickBriefEntry(BriefTarget(project: record.project ?? "", thread: record.id))
        openApp(.router)
    }

    var routerStatusParts: [(String, Color)] {
        let needsYou = store.routerRecords.needsYou
        return needsYou > 0 ? [("\(needsYou) need you", Theme.amber)] : [("nothing open", Theme.tertiary)]
    }

    /// Entries a panel lists before the rest are left to the window.
    static let routerEntryLimit = 5

    /// The Router in its panel: the header, the entries that need you (in the brief's order), then what works and the way to
    /// the window.
    @ViewBuilder var peekRouter: some View {
        let entries = store.routerRecords.lines(in: .needsYou)
        routerHeader.frame(height: Self.peekLine)
        if entries.isEmpty {
            Text("Nothing needs you").font(Theme.Typography.body).chromeInk(.tertiary, Theme.tertiary)
                .padding(.horizontal, Theme.Space.md).frame(height: Theme.Metrics.line)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(entries.prefix(Self.routerEntryLimit)) { e in
                    RouterRecordLine(record: e) { openRouterRecord(e) }
                }
            }
            if entries.count > Self.routerEntryLimit {
                Text("\(entries.count - Self.routerEntryLimit) more in the Router").font(Theme.Typography.meta)
                    .chromeInk(.tertiary, Theme.tertiary).padding(.horizontal, Theme.Space.md).padding(.top, 2)
            }
        }
        routerWorking
        Hairline(inset: Theme.Space.md).padding(.vertical, Theme.Space.xs)
        routerFooter
    }

    /// What is working, under the entries, and the T3 link when it needs a look.
    var routerWorking: some View {
        VStack(alignment: .leading, spacing: 0) {
            T3Notice(store: store).padding(.horizontal, Theme.Space.md)
            RouterWorkingList(store: store)
        }
    }

    /// The button to the Router in the window (the Working list above says what is running).
    var routerFooter: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ActionButton("Open Router") { openApp(.router) }
                .fixedSize()
                .tip("Open Router", "The page and the composer · \(store.shortcut(.router).display)")
        }
        .padding(.leading, Theme.Space.md)
        .frame(minHeight: Theme.Metrics.line)
    }

    /// Sync state, as a dot and a few words (problems first, then snoozed, then when it was last updated), and a refresh.
    var syncStatus: some View {
        HStack(spacing: 8) {
            Ticking(coarse: true) { now in
                syncLabel(now: now)
            }
            // The rate limit is part of syncing: it pauses at 0, inbox included.
            RateNotice(store: store, fill: false).lineLimit(1).layoutPriority(-1)
            Spacer(minLength: 0)
            refreshButton
        }
    }

    /// Checks GitHub now; the loader in its place while a check runs.
    @ViewBuilder private var refreshButton: some View {
        if store.isSyncing {
            FjordLoader(color: CDS.Text.secondary, label: "Checking GitHub").frame(width: 13, height: 13)
                .frame(width: CDS.Density.compact.control, height: CDS.Density.compact.control)
        } else {
            IconButton(symbol: "arrow.clockwise", help: "Check now", detail: store.shortcut(.refresh).display,
                       size: CDS.Density.compact.control) { store.refreshNow() }
        }
    }

    private func syncLabel(now: Date) -> some View {
        let s = sync(now: now)
        return Button {
            if store.authError != nil { openApp(.settings) } else { store.refreshNow() }
        } label: {
            HStack(spacing: 6) {
                Group {
                    if let symbol = s.symbol {
                        Image(systemName: symbol).font(Theme.Typography.glyph(9, .bold)).foregroundStyle(s.color)
                    } else {
                        Circle().fill(s.color).frame(width: CDS.Dot.size, height: CDS.Dot.size)
                    }
                }
                .frame(width: 10, height: 10)
                // A status colour stays fixed; all well, the words are quiet chrome.
                Text(s.text).font(Theme.Typography.meta)
                    .foregroundStyle(s.color == Theme.green ? BarGlass.ink(.tertiary, glass: glass, opaque: Theme.tertiary)
                                     : AnyShapeStyle(s.color))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: Theme.Metrics.chip)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.text)
        .accessibilityHint(s.title)
        .tip(s.title, s.detail)
    }

    struct SyncState {
        var color: Color
        var text: String
        var title: String
        var detail: String?
        var symbol: String? = nil
    }

    func sync(now: Date) -> SyncState {
        let refresh = "Click to check now · \(store.shortcut(.refresh).display)"
        // First: edits being lost at quit are what you can't see otherwise (GitHub's state is said under it).
        if let problem = store.saveProblem {
            let also = store.authError != nil ? "\nAlso: can't sign in to GitHub · Click for Settings" : store.unreachable ? "\nAlso: couldn't reach GitHub" : ""
            return SyncState(color: Theme.amber, text: "Not saved", title: "Changes aren't being saved", detail: problem + also)
        }
        if let error = store.authError {
            return SyncState(color: Theme.red, text: "Sign-in problem", title: "Can't sign in to GitHub",
                             detail: error + "\nClick for Settings")
        }
        if store.unreachable {
            return SyncState(color: Theme.amber, text: "Not syncing", title: "Couldn't reach GitHub",
                             detail: "Check your connection · Triage tries again on its own\n" + refresh)
        }
        if let error = store.inboxError {
            // An edit's actions waiting for what can't be read: nothing runs until it is, which isn't seen otherwise.
            let paused = store.actionsPausedFor().map { "\nActions paused until \($0) can be read" } ?? ""
            return SyncState(color: Theme.amber, text: "Inbox didn't sync", title: "GitHub didn't answer the inbox's search",
                             detail: error + paused + "\n" + refresh)
        }
        if let error = store.inboxReadError {
            return SyncState(color: Theme.amber, text: "Jev can't read", title: "Jev couldn't read the inbox's new comments",
                             detail: error + "\nLabels and importance wait for him; everything else is as your rules say\n" + refresh)
        }
        guard let last = store.lastSync else {
            // The first check: nothing to date yet (the refresh button spins while it runs).
            return SyncState(color: Theme.tertiary, text: store.me == nil ? "Connecting to GitHub…" : "Never updated",
                             title: "Connecting to GitHub", detail: "Pull requests, issues and workflows")
        }
        let interval = store.settings.pollInterval
        let checked = "Last checked at \(last.formatted(date: .omitted, time: .shortened))"
        if now.timeIntervalSince(last) > interval * 3 {
            return SyncState(color: Theme.amber, text: "Updated \(agoPhrase(last, now: now))", title: "Not syncing",
                             detail: "\(checked) · check your connection or token\n" + refresh)
        }
        if store.isSnoozed, let until = store.settings.snoozeUntil {
            return SyncState(color: Theme.purple, text: "Snoozed until \(until.formatted(date: .omitted, time: .shortened))",
                             title: "Notifications snoozed", detail: "No banners; the inbox keeps filling · resume in Settings",
                             symbol: "moon.fill")
        }
        let next = max(0, Int(last.addingTimeInterval(interval).timeIntervalSince(now)))
        let upcoming = store.isSyncing ? "Checking now" : "Next check in about \(next < 60 ? "\(next)s" : "\(next / 60)m")"
        return SyncState(color: Theme.green, text: "Updated \(agoPhrase(last, now: now))", title: checked,
                         detail: "\(upcoming)\n\(refresh)")
    }
}

/// A category's tab: Claude's Tabs with its unread count, dragged onto another to reorder the categories (their order is
/// their priority: the first to match a thing keeps it).
struct CategoryTab: View {
    let category: InboxCategory
    let selected: Bool
    let badge: Int
    let store: Store
    let action: () -> Void
    @State private var target = false
    @Environment(\.openApp) private var openApp
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.onBarGlass) private var glass
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            CategoryTabLabel(category: category, selected: selected, badge: badge, rulesOff: store.rulesOff(category.id)) {
                store.editCategory(category.id, go: openApp)
            }
        }
            .buttonStyle(HoverFillButtonStyle(shape: RoundedRectangle(cornerRadius: CDS.Tabs.radius, style: .continuous),
                                              hover: BarGlass.fill(.hover, glass: glass, scheme: scheme, opaque: CDS.Fill.ghostHover),
                                              active: BarGlass.fill(.selected, glass: glass, scheme: scheme, opaque: CDS.Fill.ghostHover),
                                              pressed: BarGlass.fill(.selected, glass: glass, scheme: scheme, opaque: CDS.Fill.ghostHover),
                                              isActive: selected))
            .padding(.horizontal, CDS.Tabs.pillInset)
            .fixedSize()
            .accessibilityLabel(category.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: "Move earlier") { withAnimation(Motion.spatial.resolved(reduce: reduce)) { move(-1) } }
            .accessibilityAction(named: "Move later") { withAnimation(Motion.spatial.resolved(reduce: reduce)) { move(1) } }
            .contextMenu {
                Button("Move earlier") { withAnimation(Motion.spatial.resolved(reduce: reduce)) { move(-1) } }
                    .disabled(!store.canMoveCategory(category.id, by: -1, among: store.shownCategories))
                Button("Move later") { withAnimation(Motion.spatial.resolved(reduce: reduce)) { move(1) } }
                    .disabled(!store.canMoveCategory(category.id, by: 1, among: store.shownCategories))
            }
            .overlay(alignment: .leading) {
                if target { Capsule().fill(Theme.accent).frame(width: 2, height: 16) }
            }
            .draggable("category:" + category.id.uuidString) {
                Text(category.title)
                    .font(CDS.sans(CDS.Sidebar.rowFont))
                    .padding(.horizontal, 8)
                    .frame(height: CDS.Sidebar.rowHeight)
                    .background(RoundedRectangle(cornerRadius: CDS.Sidebar.radius, style: .continuous).fill(CDS.Surface.s3))
                    .foregroundStyle(CDS.Text.primary)
            }
            .dropDestination(for: String.self) { ids, _ in
                guard let raw = ids.first, raw.hasPrefix("category:"), let id = UUID(uuidString: String(raw.dropFirst(9))) else { return false }
                withAnimation(Motion.spatial.resolved(reduce: reduce)) { store.moveCategory(id, onto: category.id) }
                return true
            } isTargeted: { target = $0 }
            .tip(category.title, "Drag to reorder · ⌃\(store.shownCategories.firstIndex { $0.id == category.id }.map { $0 + 1 } ?? 0)")
    }
}

extension CategoryTab {
    fileprivate func move(_ step: Int) { store.moveCategory(category.id, by: step, among: store.shownCategories) }
}

/// The inbox's columns menu: a checkmark per category shown; hidden ones carry their count.
struct CategoriesMenu: View {
    let store: Store
    let edit: () -> Void
    @State private var hover = false
    @Environment(\.onBarGlass) private var glass
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Menu {
            ForEach(store.categories) { category in
                Toggle(isOn: Binding(get: { !category.hidden }, set: { store.setHidden(category.id, !$0) })) {
                    Text(category.hidden ? "\(category.title) · \(store.count(category.id))" : category.title)
                }
            }
            Divider()
            Button("Edit Categories…", action: edit)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: CDS.GhostIcon.glyph(IconButton.Size.header), weight: .medium))
                .foregroundStyle(BarGlass.ink(hover ? .primary : .secondary, glass: glass, opaque: hover ? Brand.ink : Theme.secondary))
                .frame(width: IconButton.Size.header, height: IconButton.Size.header)
                .background(Theme.Radius.shape(CDS.GhostIcon.radius(IconButton.Size.header))
                    .fill(hover ? BarGlass.fill(.hover, glass: glass, scheme: scheme, opaque: Theme.Fill.hover) : .clear))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .accessibilityLabel("Categories")
        .tip("Categories", "Hidden ones keep collecting, quietly")
    }
}

/// A tab's face: its symbol in the category's colour; the picked one (and any with something unread) says its name too, so
/// the tabs fit a narrow column.
private struct CategoryTabLabel: View {
    let category: InboxCategory
    let selected: Bool
    let badge: Int
    var rulesOff = 0
    var fix: () -> Void = {}
    @Environment(\.hoverFillHovering) private var hover
    @Environment(\.onBarGlass) private var glass

    var body: some View {
        HStack(spacing: selected ? 5 : 3) {
            Image(systemName: category.symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(badge > 0 || selected ? AnyShapeStyle(category.color.swatch)
                                 : BarGlass.ink(.tertiary, glass: glass, opaque: CDS.Text.muted))
            if selected { Text(category.title).lineLimit(1) }
            if badge > 0 { CountBadge(badge, tint: category.color.swatch) }
            if !category.actions.isEmpty {
                Image(systemName: "bolt.fill").font(.system(size: 8)).chromeInk(.tertiary, CDS.Text.muted).accessibilityHidden(true)
            }
            if rulesOff > 0 { RulesOffMark(count: rulesOff, size: 8, open: fix) }
        }
        .font(CDS.sans(13, .medium))
        .foregroundStyle(BarGlass.ink(selected ? .primary : hover ? .secondary : .tertiary, glass: glass,
                                      opaque: selected ? CDS.Text.primary : hover ? CDS.Text.secondary : CDS.Text.muted))
        // Only the picked tab has its name: the rest are tight, so all the tabs fit the column.
        .padding(.horizontal, selected ? CDS.Tabs.pad - CDS.Tabs.pillInset : 3)
        .frame(height: CDS.Tabs.height)
    }
}
