import SwiftUI

// The app window's sidebar: the bar's items with their names and counts, in Claude's Code-tab sidebar look
// (docs/design/spec/global-sidebar-titlebar.md §2): flat #111, 26pt rows, a 24pt leading slot, 13pt labels.
//
// Inbox: each category shown (its symbol in its colour, what is unread or failing), then the archive. The Router after it, with
// what needs you and what is done. The snippets, Settings and the inbox's categories at the bottom.

/// Whether the sidebar is an icon rail, remembered across launches (a shot or a test passes `defaults: nil`; a demo
/// remembers nothing, so trying it never changes your own).
@MainActor @Observable
final class SidebarState {
    static let shared = SidebarState(defaults: Store.isDemo ? nil : .standard)
    private static let key = "appSidebarCollapsed"

    @ObservationIgnored private let defaults: UserDefaults?
    private(set) var collapsed: Bool

    init(defaults: UserDefaults?, collapsed: Bool? = nil) {
        self.defaults = defaults
        self.collapsed = collapsed ?? defaults?.bool(forKey: Self.key) ?? false
    }

    func set(collapsed value: Bool) {
        guard value != collapsed else { return }
        let fold = LatencySignposts.signposter.beginInterval("Fold")
        // One spring on the width and on everything that follows it: the glass token, since the sidebar's glass and the
        // page's inset move in lockstep with it (under Reduce Motion a short fade, no travel).
        withAnimation(Motion.glass.resolved(reduce: Motion.systemReduce), completionCriteria: .logicallyComplete) { collapsed = value } completion: {
            LatencySignposts.signposter.endInterval("Fold", fold)
        }
        defaults?.set(value, forKey: Self.key)
    }

    func toggle() { set(collapsed: !collapsed) }
}

/// View ▸ Collapse Sidebar, ⌘B, and on the Router's Brief, View ▸ Hide History, ⌥⌘B (the history beside it).
@MainActor
final class SidebarMenu: NSObject, NSMenuItemValidation {
    static let shared = SidebarMenu()
    private let item = NSMenuItem(title: "Collapse Sidebar", action: #selector(toggle), keyEquivalent: "b")
    private let history = NSMenuItem(title: "Show History", action: #selector(toggleHistory), keyEquivalent: "b")

    func makeItem() -> NSMenuItem {
        let top = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "View")
        item.target = self
        item.keyEquivalentModifierMask = [.command]
        menu.addItem(item)
        history.target = self
        history.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(history)
        top.submenu = menu
        return top
    }

    @objc private func toggle() { SidebarState.shared.toggle() }

    @objc private func toggleHistory() { AppWindowController.active?.store.routerBriefs.drawerOpen.toggle() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let window = AppWindowController.active
        let usable = window?.isOpen == true && window?.paletteIsOpen != true
        if menuItem === history {
            menuItem.title = window?.store.routerBriefs.drawerOpen == true ? "Hide History" : "Show History"
            return usable && window?.navigator.selection == .router
        }
        menuItem.title = SidebarState.shared.collapsed ? "Expand Sidebar" : "Collapse Sidebar"
        return usable
    }
}

extension EnvironmentValues {
    @Entry var sidebarCollapsed = false
}

/// A count on the corner of a rail icon (the bar's badge).
struct RailBadge {
    let count: Int
    let fill: Color
    let ink: Color
}

struct AppSidebar: View {
    let store: Store
    let navigator: AppNavigator
    /// Asks the categories page to open a category's editor (the row's Edit…).
    let hub: HubState
    let collapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// On macOS 26's glass panel: label styles rather than Claude's fixed inks.
    @Environment(\.onGlass) private var onGlass
    typealias M = CDS.Sidebar
    /// The rail: the bar's 28pt tile centred in 52 (the expanded rows' icons sit at the same centre, so they never move).
    static let railWidth: CGFloat = 52
    static let tile: CGFloat = CDS.Tile.size

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.triageOn {
                        // On the rail its label is gone but its room stays, so every icon is at the same height folded or not.
                        InboxHeading(on: navigator.selection == .categories, collapsed: collapsed) { navigator.go(.categories) }
                            .frame(height: InboxHeading.height, alignment: .bottom)
                            .clipped()
                            .allowsHitTesting(!collapsed)
                        // Section by section: its row (a caret folds it, its categories' counts then added up on it), then its
                        // categories while it is open; a section's sit a step in, a guide down from its icon beside them (the
                        // expanded sidebar only: on the rail they line up as tiles).
                        ForEach(store.barSections) { part in
                            if let section = part.section { sectionRow(section, part) }
                            if part.section == nil {
                                ForEach(part.categories) { category in categoryRow(category) }
                            } else if part.section?.isCollapsed != true {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(part.categories) { category in categoryRow(category, nested: true) }
                                }
                                .overlay(alignment: .topLeading) { treeGuide }
                            }
                        }
                        AppSidebarRow(title: "Archive", on: navigator.selection == .done,
                                      tip: "Archive · \(store.doneEntries.count)", action: { navigator.go(.done) }) { on in
                            Image(systemName: "archivebox")
                                .font(.system(size: M.symbol, weight: .medium))
                                .chromeInk(on ? .primary : .tertiary, glass: onGlass)
                        } trailing: {
                            CountText(store.doneEntries.count, ink: .tertiary)
                        }
                        .padding(.bottom, rowGap)
                    }
                    if store.routerOn {
                        // The Router stands apart from the inbox: a rule and a gap, no header over a single row.
                        if store.triageOn {
                            rule.padding(.top, 4)
                            Color.clear.frame(height: M.groupTop - 4)
                        }
                        RouterSidebarRow(store: store, navigator: navigator)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            VStack(alignment: .leading, spacing: rowGap) {
                // The snippets serve both tools: there while either is on.
                if store.triageOn || store.routerOn {
                    AppSidebarRow(title: "Snippets", on: navigator.selection == .snippets, tip: "Snippets", action: { navigator.go(.snippets) }) { on in
                        Image(systemName: Snippet.symbol).font(.system(size: M.symbol, weight: .medium))
                            .chromeInk(on ? .primary : .secondary, glass: onGlass)
                    }
                }
                AppSidebarRow(title: "Settings", on: navigator.selection == .settings, tip: "Settings", action: { navigator.go(.settings) }) { on in
                    Image(systemName: "gearshape").font(.system(size: M.symbol, weight: .medium))
                        .chromeInk(on ? .primary : .secondary, glass: onGlass)
                }
            }
            .padding(.top, 6)
            .overlay(alignment: .top) {
                Rectangle().fill(CDS.border).frame(height: 0.5)
                    .frame(width: collapsed ? Self.tile : AppRootView.sidebarWidth - 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, collapsed ? 4 : 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .font(CDS.sans(M.rowFont))
        .environment(\.sidebarCollapsed, collapsed)
        // Always laid out at its full width: the frame around it narrows, so nothing here reflows or moves.
        .frame(width: AppRootView.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func categoryRow(_ category: InboxCategory, nested: Bool = false) -> some View {
        let badge = store.badge(category)
        let off = store.rulesOff(category.id)
        return AppSidebarRow(title: category.title, on: navigator.selection == .category(category.id),
                             badge: badge > 0 ? RailBadge(count: badge, fill: category.color.swatch, ink: category.color.ink) : nil,
                             indent: nested ? M.treeIndent : 0,
                             tip: badge == 0 ? category.title : "\(category.title) · \(category.isCI ? "\(badge) failing" : "\(badge) new")",
                             action: { navigator.go(.category(category.id)) }) { on in
            Image(systemName: category.symbol)
                .font(.system(size: M.symbol, weight: .medium))
                .foregroundStyle(category.color.swatch.opacity(badge > 0 || on ? 1 : 0.6))
        } trailing: {
            HStack(spacing: 6) {
                if off > 0 { RulesOffMark(count: off) { store.editCategory(category.id) { navigator.go($0) } } }
                if badge > 0 {
                    CountText(badge, color: category.color.swatch)
                } else if !category.isCI {
                    CountText(store.count(category.id), ink: .tertiary)
                }
            }
        }
        .padding(.bottom, rowGap)
        .accessibilityValue(badge == 0 ? "Nothing new" : category.isCI ? "\(badge) failing" : "\(badge) unread")
        .contextMenu { categoryMenu(category) }
    }

    /// A section: its icon and name, and a caret. A click folds or unfolds it (in the bar too); folded, its categories'
    /// counts are added up on it.
    private func sectionRow(_ section: CategorySection, _ part: BarSection) -> some View {
        let badge = section.isCollapsed ? store.sectionBadge(part) : nil
        return AppSidebarRow(title: section.title, on: false, badge: badge,
                             tip: badge.map { "\(section.title) · \($0.count) new" } ?? section.title,
                             action: { withAnimation(Motion.spatial.resolved(reduce: reduce)) { store.toggleCollapsed(section.id) } }) { _ in
            SectionGlyph(symbol: section.symbol, size: M.symbol, color: CDS.Text.secondary)
        } trailing: {
            HStack(spacing: 6) {
                if let badge { CountText(badge.count, color: badge.fill) }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .chromeInk(.tertiary, glass: onGlass)
                    .rotationEffect(.degrees(section.isCollapsed ? -90 : 0))
            }
        }
        .padding(.bottom, rowGap)
        .accessibilityValue(section.isCollapsed ? "collapsed" + (badge.map { ", \($0.count) new" } ?? "") : "expanded")
        .accessibilityHint(section.isCollapsed ? "Shows its categories" : "Folds its categories")
    }

    /// A category row's menu, in the expanded sidebar and on the rail alike. Edits go through the store as the categories page
    /// does (its quick toggles mutate `store.categories` too), so its undo history records them when it is open.
    @ViewBuilder
    private func categoryMenu(_ category: InboxCategory) -> some View {
        let shown = store.shownCategories
        Button("Edit…") {
            navigator.go(.categories)
            hub.openCategory(category.id)
        }
        Toggle("Notifications", isOn: Binding(
            get: { store.categories.first { $0.id == category.id }?.notifies ?? false },
            set: { on in
                if let i = store.categories.firstIndex(where: { $0.id == category.id }) { store.categories[i].notifies = on }
            }))
        Button("Hide") { store.setHidden(category.id, true) }
        Divider()
        Button("Mark all as read") { store.markAllSeen(.category(category.id)) }
            .disabled(store.unreadCount(category.id) == 0)
        Divider()
        Button("Move up") { store.moveCategory(category.id, by: -1, among: shown) }
            .disabled(!store.canMoveCategory(category.id, by: -1, among: shown))
        Button("Move down") { store.moveCategory(category.id, by: 1, among: shown) }
            .disabled(!store.canMoveCategory(category.id, by: 1, among: shown))
    }

    /// The same gap between tiles as between rows, so an icon never moves up or down as the sidebar folds.
    private var rowGap: CGFloat { M.sessionGap }

    /// The rule between groups: the rows' width, or the tile's in the rail.
    private var rule: some View {
        Rectangle().fill(CDS.border).frame(height: 0.5)
            .frame(width: collapsed ? Self.tile : AppRootView.sidebarWidth - 16 - 2 * M.labelInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, collapsed ? 4 : M.labelInset)
    }

    /// A section's tree guide: a hairline on its icon's centre, from just under its row to its last category's (short of the
    /// gap after it). It goes and comes with the labels, so the rail never shows it.
    private var treeGuide: some View {
        Rectangle().fill(CDS.border).frame(width: M.treeGuide)
            .padding(.bottom, rowGap + 4)
            .padding(.leading, M.rowPadding + M.railShift + (M.leadingSlot - M.treeGuide) / 2)
            .sidebarText(collapsed)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    static func routerTip(_ needsYou: Int) -> String {
        needsYou > 0 ? "Router · \(needsYou) need you" : "Router"
    }
}

/// The Router's row, with how many of the brief's entries need you: the count read here, so the brief changing redraws
/// this row and not the whole sidebar.
private struct RouterSidebarRow: View {
    let store: Store
    let navigator: AppNavigator
    @Environment(\.onGlass) private var onGlass
    typealias M = CDS.Sidebar

    var body: some View {
        // The v2 demo's page counts its own lines (the unfiltered Needs-you count).
        let needsYou = RouterV2Demo.model?.needsYou ?? store.routerBriefs.untoldNeedsYou
        AppSidebarRow(title: "Router", on: navigator.selection == .router,
                      badge: needsYou > 0 ? RailBadge(count: needsYou, fill: CDS.solid(0xFAB219), ink: CDS.solid(0x0B0B0B)) : nil,
                      tip: AppSidebar.routerTip(needsYou),
                      action: { navigator.go(.router) }) { on in
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: M.symbol, weight: .medium))
                .chromeInk(on ? .primary : .secondary, glass: onGlass)
        } trailing: {
            if needsYou > 0 { CountText(needsYou, color: CDS.Fill.warning) }
        }
        .accessibilityValue(needsYou > 0 ? "\(needsYou) need you" : "Nothing open")
    }
}

private struct CountText: View {
    let value: Int
    /// A status colour (fixed), or else an ink level, which follows the glass under it.
    let color: Color?
    var ink = ChromeInk.tertiary
    @Environment(\.onGlass) private var onGlass

    init(_ value: Int, color: Color) {
        self.value = value
        self.color = color
    }

    init(_ value: Int, ink: ChromeInk) {
        self.value = value
        color = nil
        self.ink = ink
    }

    var body: some View {
        if value > 0 {
            Text(value > 99 ? "99+" : "\(value)")
                .font(CDS.sans(12, .medium).monospacedDigit())
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? ink.style(glass: onGlass))
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}

/// A 26pt row (radius 6, a 24pt leading slot shifted 4, a 4 gap, 13pt text; white 7.5% on hover, 15% and primary text when
/// picked; on glass `ChromeFill`'s ink steps) with something at its end.
struct AppSidebarRow<Leading: View, Trailing: View>: View {
    let title: String
    let on: Bool
    let badge: RailBadge?
    /// How far in its icon sits in the expanded sidebar (a section's categories); none on the rail, where tiles line up.
    let indent: CGFloat
    let tip: String
    let action: () -> Void
    @ViewBuilder let leading: (_ on: Bool) -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovered = false
    @Environment(\.sidebarCollapsed) private var collapsed
    @Environment(\.onGlass) private var onGlass
    @Environment(\.colorScheme) private var scheme
    typealias M = CDS.Sidebar

    init(title: String, on: Bool, badge: RailBadge? = nil, indent: CGFloat = 0, tip: String? = nil, action: @escaping () -> Void,
         @ViewBuilder leading: @escaping (_ on: Bool) -> Leading, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.on = on
        self.badge = badge
        self.indent = indent
        self.tip = tip ?? title
        self.action = action
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: M.rowGap) {
                leading(on)
                    .frame(width: M.leadingSlot, height: M.leadingSlot)
                    // The bar's corner count, small and within the row (the rows' gap leaves no room above it), on the rail
                    // only; it comes in once the labels have gone (their fade out takes 0.12 s), then takes 0.12 s itself.
                    .cornerBadge(badge?.count ?? 0, fill: badge?.fill ?? .clear, ink: badge?.ink ?? .clear, small: true,
                                 opacity: collapsed ? 1 : 0)
                    .animation(collapsed ? .easeIn(duration: 0.12).delay(0.12) : .easeOut(duration: 0.08), value: collapsed)
                    // The indent eases out with the sidebar's width, so a nested icon reaches its tile as the rail closes.
                    .padding(.leading, M.railShift + (collapsed ? 0 : indent))
                Group {
                    Text(title)
                        .font(CDS.sans(M.rowFont))
                        .chromeInk(on ? .primary : .secondary, glass: onGlass)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    trailing().padding(.trailing, 6)
                }
                .sidebarText(collapsed)
            }
            .padding(.horizontal, M.rowPadding)
            .frame(height: M.rowHeight)
            // The full row, or the bar's tile in the rail: one shape whose width follows the sidebar's.
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: M.radius, style: .continuous)
                    .fill(ChromeFill.color(selected: on, hovered: hovered, glass: onGlass, scheme: scheme))
                    // The row's height on the rail too (its tile 28 by 26), so the rows keep their place as it folds.
                    .frame(width: collapsed ? AppSidebar.tile : AppRootView.sidebarWidth - 16, height: M.rowHeight)
                    .padding(.leading, collapsed ? 4 : 0)
                    // On glass hover comes on at once and eases off; the opaque sidebar's stays instant both ways.
                    .hoverMotion(hovered)
            }
            // The whole row, or on the rail only its tile: the rest of the row is folded out of sight and must not take
            // the pointer (a click, a hover or a menu) over the page beside the rail.
            .contentShape(RowHitArea(collapsed: collapsed))
            .overlay(alignment: .leading) {
                if collapsed {
                    Rectangle().fill(.clear).frame(width: AppSidebar.tile, height: M.rowHeight).contentShape(Rectangle())
                        .padding(.leading, 4).tip(tip)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension AppSidebarRow where Trailing == EmptyView {
    init(title: String, on: Bool, badge: RailBadge? = nil, tip: String? = nil, action: @escaping () -> Void,
         @ViewBuilder leading: @escaping (_ on: Bool) -> Leading) {
        self.init(title: title, on: on, badge: badge, tip: tip, action: action, leading: leading) { EmptyView() }
    }
}

private struct SidebarTextModifier: ViewModifier {
    let collapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// Out at once on collapse (0.12 s, before the width has gone far), in soon on expand (after 0.06 s, as the width opens,
    /// over 0.16 s), sliding a few points toward the icons while it goes; Reduce Motion only fades, briefly.
    func body(content: Content) -> some View {
        content
            .opacity(collapsed ? 0 : 1)
            .offset(x: collapsed && !reduce ? -8 : 0)
            .animation(reduce ? .easeOut(duration: 0.1)
                       : collapsed ? .easeOut(duration: 0.12) : .easeOut(duration: 0.16).delay(0.06), value: collapsed)
            .allowsHitTesting(!collapsed)
    }
}

private extension View {
    func sidebarText(_ collapsed: Bool) -> some View { modifier(SidebarTextModifier(collapsed: collapsed)) }
}

/// The sidebar's Inbox label (§2.6, 12/16 muted, its text inset 10), with an edit button at its right on hover that opens the
/// categories page (shown while that page is open).
private struct InboxHeading: View {
    let on: Bool
    let collapsed: Bool
    let edit: () -> Void
    @State private var hovered = false
    @Environment(\.onGlass) private var onGlass
    typealias M = CDS.Sidebar
    /// The label's 20 with the room above and below it.
    static let height: CGFloat = M.groupTop - 2 + 20 + 2

    var body: some View {
        HStack(spacing: 4) {
            Text("Inbox").font(CDS.sans(M.groupFont)).chromeInk(.tertiary, glass: onGlass).lineLimit(1)
            Spacer(minLength: 4)
            EditButton(on: on, action: edit)
                .opacity(hovered || on ? 1 : 0)
        }
        .frame(height: 20)
        .padding(.leading, M.labelInset)
        // Its pencil over the rows' counts.
        .padding(.trailing, M.rowPadding + 2)
        .padding(.top, M.groupTop - 2).padding(.bottom, 2)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .sidebarText(collapsed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inbox")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The Inbox label's edit button: a small pencil in the label's own muted ink, brighter on hover; a faint tile behind it while
/// the categories are open.
private struct EditButton: View {
    let on: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.onGlass) private var onGlass
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .medium))
                .chromeInk(on || hovered ? .secondary : .tertiary, glass: onGlass)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ChromeFill.color(selected: on, hovered: hovered, glass: onGlass, scheme: scheme))
                    .hoverMotion(hovered))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .tip("Edit categories")
        .accessibilityLabel("Edit inbox categories")
    }
}

/// A sidebar row's hit area: the row, or on the rail the tile it folds to (4 in, `AppSidebar.tile` wide).
private struct RowHitArea: Shape {
    let collapsed: Bool
    func path(in rect: CGRect) -> Path {
        Path(collapsed ? CGRect(x: rect.minX + 4, y: rect.minY, width: AppSidebar.tile, height: rect.height) : rect)
    }
}
