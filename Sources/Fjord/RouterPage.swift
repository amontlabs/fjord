import AppKit
import SwiftUI

// Router v2's page (docs/design/router-v2/DESIGN.md 1): the title line, the sticky filter bar, one list of rows (a
// section's header, its lines, the housekeeping line) and the dock floating at the bottom. All rows are one `ForEach`
// with stable ids, declared in an order that never changes and laid out in the page's (`RouterStack`), so a line that
// changes section keeps its identity and glides there. What floats (the hover peek, the snooze menu) is drawn over the
// whole page from the targets' frames, so nothing clips it.

// MARK: - The list

struct RouterList: View {
    let model: RouterModel
    let edges: RouterEdges
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.windowArrival) private var arrival

    var body: some View {
        // The stored layout: this body runs when the order or a count changes, not when a line's fields do.
        let rows = model.layout
        let _ = RouterBodies.count("list", of: model)
        // Each row's place on the page. The rows themselves are declared by id, an order no change of section moves:
        // a reordered `ForEach` takes the row out and puts it back in, and then nothing glides.
        let places = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let declared = rows.sorted { $0.id < $1.id }
        let leading = edges.leading - Router.Line.nameLeading
        let trailing = edges.trailing - Router.Line.reach
        ScrollViewReader { proxy in
            ScrollView {
                RouterStack {
                    ForEach(declared) { row in
                        view(row, first: row.id == rows.first?.id)
                            .layoutValue(key: RouterStack.Order.self, value: places[row.id] ?? 0)
                            // Read top to bottom, whatever the order they are declared in.
                            .accessibilitySortPriority(Double(rows.count - (places[row.id] ?? 0)))
                            .transition(.routerFold(reduce: reduce))
                    }
                }
                // Every change but one where rows come or go (a card opening or shutting, a line moving, a count): every
                // row is placed where it goes at once and glides there on Core Animation (`RouterGlides`). Animated here,
                // the stack moved each row's container on every frame of the change's curve while its hosting view, placed
                // at once, sat at its new place inside it, outside the container's clip: the rows under a card that opened
                // or shut were blank until the curve ended, and AppKit told every hosting view below that its place in
                // the window had changed, each line laying out on every frame. Rows that come or go keep the change's
                // animation, for their fold.
                .transaction { [model] in if !model.folding { $0.animation = nil } }
                .coordinateSpace(.named(Router.listSpace))
                .padding(.leading, leading).padding(.trailing, trailing)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(ProcessInfo.processInfo.environment["FJORD_E1"] == nil)
                .overlayScrollers()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // With no thread the bar goes, and its place stays: the sentence under it doesn't jump.
                ZStack {
                    if model.hasThreads {
                        RouterHostedBar(model: model)
                            .padding(.leading, edges.leading - CDS.Tabs.pad).padding(.trailing, edges.trailing - CDS.Tabs.pad)
                            .transition(.opacity)
                    }
                }
                .frame(height: Router.Bar.control + 2 * Router.Bar.padY)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RouterDock(model: model)
                    .padding(.leading, edges.leading).padding(.trailing, edges.trailing)
                    .padding(.bottom, Router.Dock.bottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The page's ground, solid from the dock's top edge down, and a fade above it: lines scroll out under
                    // the fade and never show through between the dock's rows.
                    .background {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [CDS.Surface.s1.opacity(0), CDS.Surface.s1], startPoint: .top, endPoint: .bottom)
                                .frame(height: Router.Bar.fade)
                            CDS.Surface.s1
                        }
                        .padding(.top, -Router.Bar.fade)
                        .allowsHitTesting(false)
                    }
            }
            .background { RouterReveal(model: model, proxy: proxy) }
        }
    }

    @ViewBuilder private func view(_ row: RouterSlot, first: Bool) -> some View {
        // Every row in a hosting view of its own, gliding on Core Animation (`RouterGlides`).
        if case .line(let id) = row.kind {
            RouterHostedLine(model: model, box: model.box(id), slot: row.id)
        } else {
            RouterHostedRow(model: model, slot: row, first: first)
        }
    }
}

/// Brings the selection's line into view as it moves: the model calls it (`RouterModel.revealer`), so a reveal neither
/// runs the list's body nor joins the act's update.
private struct RouterReveal: View {
    let model: RouterModel
    let proxy: ScrollViewProxy
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.windowArrival) private var arrival

    var body: some View {
        Color.clear
            .onAppear { install() }
            .onChange(of: reduce) { install() }
    }

    private func install() {
        model.revealer = { [model, proxy, reduce, arrival] line in
            // After the card has its place in the layout.
            DispatchQueue.main.async {
                guard let row = model.layout.first(where: { $0.id == line || $0.id.hasPrefix(line + "@") }) else { return }
                let follow = arrival?.active == true ? nil : Motion.follow.resolved(reduce: reduce)
                withAnimation(follow) { proxy.scrollTo(row.id) }
            }
        }
    }
}

/// `Needs you 5`: the section's name in its tint, the number of lines under it. A click is a click on its token.
struct RouterHeaderRow: View {
    let model: RouterModel
    let section: RouterSection
    let count: Int
    let first: Bool

    var body: some View {
        RouterButton(model: model, hit: .header(section), action: { model.toggle(section: section) }) { hot, _ in
            HStack(alignment: .firstTextBaseline, spacing: Router.Header.countGap) {
                Text(section.title).font(CDS.sans(12, .semibold)).foregroundStyle(section.tint)
                    .underline(hot, color: section.tint.opacity(0.6))
                RouterCount(count: count, size: 12)
            }
            .frame(height: Router.Header.height)
            // The count ticks inside the header and moves with it: it never leaves its label on the way.
            .geometryGroup()
        }
        .fixedSize()
        .padding(.top, first ? Router.Header.firstTop : Router.Header.top)
        .padding(.leading, Router.Line.nameLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(section.title), \(count)")
    }
}

/// A count that ticks as `numericText` on `.snappy` did, on Core Animation (`RouterTick`); at once under Reduce Motion.
struct RouterCount: View {
    let count: Int
    var size: CGFloat = 11
    var tint: Color = CDS.Text.muted

    var body: some View {
        let font = CDS.nsSans(size).monospacedDigits
        RouterTick(key: "\(count)", style: .numeric(font: font), look: "\(tint)") {
            Text(verbatim: "\(count)").font(CDS.sans(size)).monospacedDigit().foregroundStyle(tint)
        }
        // Its text's baseline, for the header's row (a hosting view has none of its own to give).
        .alignmentGuide(.firstTextBaseline) { _ in font.ascender }
        .alignmentGuide(.lastTextBaseline) { _ in font.ascender }
    }
}

/// The sentence that takes a header's place: "Nothing needs you." and its kin.
struct RouterSentenceRow: View {
    let model: RouterModel
    let words: String
    let clear: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(words).cdsText(CDS.Density.compact.prose, .regular, CDS.Text.secondary)
                .id(words).transition(.routerSwap)
            if clear {
                RouterPushButton(model: model, hit: .clearFilter, title: Router.Copy.clearFilter, variant: .ghost) { model.clearFilters() }
            }
        }
        .frame(height: Router.Header.height)
        .padding(.top, Router.Header.firstTop)
        .padding(.leading, Router.Line.nameLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(.fade, value: words)
    }
}

/// "Reading 2 threads…" with Fjord's mark: finished threads whose verdicts are pending, listed under it. In the first
/// row's place when nothing is known to need you yet, so the page never says "Nothing needs you" before it knows.
struct RouterReadingRow: View {
    let count: Int
    let first: Bool

    var body: some View {
        HStack(spacing: Router.Thinking.gap) {
            Text(Router.Copy.reading(count)).cdsText(CDS.Density.compact.prose, .regular, CDS.Text.secondary)
                .contentTransition(.numericText(value: Double(count)))
            RouterThinking(label: "Fjord is reading them")
        }
        .frame(height: Router.Header.height)
        .padding(.top, first ? Router.Header.firstTop : Router.Header.top)
        .padding(.leading, Router.Line.nameLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Router.counts, value: count)
        .accessibilityElement(children: .combine)
    }
}

/// The list's last row: the threads that finished more than a day ago and were not settled, as one count and one act.
struct RouterHousekeepingRow: View {
    let model: RouterModel
    let count: Int

    var body: some View {
        let selected = model.flags(.housekeeping).selected
        HStack(spacing: 8) {
            Text(Router.Copy.older(count)).font(CDS.sans(13)).foregroundStyle(CDS.Text.muted).lineLimit(1)
                .frame(height: 24)
                .contentShape(Rectangle())
                .routerTarget(model, .housekeepingWords)
            Spacer(minLength: 8)
            RouterPushButton(model: model, hit: .settleAll, title: count == 1 ? "Settle" : "Settle all", variant: .ghost,
                               removes: true) { model.settleAll() }
        }
        .padding(.leading, Router.Line.nameLeading).padding(.trailing, 5)
        .frame(minHeight: Router.Line.minHeight)
        // Selected: the card's ground, at a row's size.
        .background {
            RoundedRectangle(cornerRadius: Router.Surface.row, style: .continuous).fill(selected ? Router.Surface.quiet : .clear)
        }
        .padding(.top, 12)
        .routerTarget(model, .housekeeping)
    }
}

/// A button of the page, ghost or secondary, lit and pressed from the model (so the drawn pointer does both): `Settle
/// all`, `Continue`, `Edit`, `Send again`. As tall as a filter pill, a control's radius. A ghost one is a text button
/// with a hover ground: footnote size, as the card footer's. `ringed`: the keyboard is on it (Return presses it).
struct RouterPushButton: View {
    enum Variant { case ghost, secondary }

    let model: RouterModel
    let hit: RouterHit
    let title: String
    var variant: Variant = .secondary
    var keys: [String] = []
    var removes = false
    var ringed = false
    let action: () -> Void

    var body: some View {
        let s = Router.Surface.self
        let shape = RoundedRectangle(cornerRadius: s.control, style: .continuous)
        RouterButton(model: model, hit: hit, removes: removes, action: action) { hot, pressed in
            HStack(spacing: 6) {
                if variant == .ghost {
                    Text(title).cdsText(CDS.Density.compact.footnote, .regular, hot ? CDS.Text.primary : CDS.Text.secondary)
                        .lineLimit(1).fixedSize()
                } else {
                    Text(title).cdsText(CDS.Density.compact.body, .regular, CDS.Text.primary).lineLimit(1).fixedSize()
                }
                if !keys.isEmpty { RouterKeyHint(keys: keys) }
            }
            .padding(.horizontal, 8)
            .frame(height: Router.Dock.button)
            .background {
                shape.fill(pressed ? s.pressed : fill(hot))
                    .scaleEffect(pressed ? 0.975 : 1)
                    .hoverMotion(hot)
            }
            .overlay { if ringed { RouterRing(radius: s.control) } }
        }
        .accessibilityLabel(title)
    }

    private func fill(_ hot: Bool) -> Color {
        let s = Router.Surface.self
        switch variant {
        case .ghost: return hot ? s.hover : .clear
        case .secondary: return hot ? s.chosenHover : s.chosen
        }
    }
}

// MARK: - Filter bar

/// One row, sticky over the list: the project pills (`All` first, then the projects with a line, alphabetical) and the
/// three state tokens. One choice in each group; counts are faceted. ⌘F puts the keyboard on it.
struct RouterFilterBar: View {
    let model: RouterModel
    @Namespace private var grounds
    @Environment(\.accessibilityReduceMotion) private var reduce

    private typealias M = Router.Bar
    /// How far the bar's ground reaches past its sides.
    static let groundReach: CGFloat = 400

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: M.pillGap) {
                pill(nil)
                ForEach(model.projects, id: \.self) { project in
                    pill(project).transition(.scaleFade(0.96, reduce: reduce))
                }
                // After the pills, so the tokens never move. Its Esc keycap shows only when Esc would clear (it steps
                // out of a card or a draft first).
                if model.filtered {
                    RouterClearFilters(model: model)
                        .padding(.leading, 12 - M.pillGap)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: M.tokenGap) {
                ForEach(RouterSection.allCases, id: \.self) { token($0) }
            }
        }
        .padding(.vertical, M.padY)
        .frame(maxWidth: .infinity)
        // The page's ground behind it, and the fade under it (as tall as the dock's).
        .background {
            VStack(spacing: 0) {
                CDS.Surface.s1
                LinearGradient(colors: [CDS.Surface.s1, CDS.Surface.s1.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: M.fade)
            }
            .padding(.horizontal, -Self.groundReach)
            .padding(.bottom, -M.fade)
            .allowsHitTesting(false)
        }
        .motion(.glass, value: model.project)
        .motion(.glass, value: model.section)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    private func pill(_ project: String?) -> some View {
        let count = model.count(project: project)
        let active = model.project == project
        return RouterButton(model: model, hit: .project(project), action: { model.toggle(project: project) }) { hot, pressed in
            HStack(spacing: CDS.Tabs.badgeGap) {
                Text(project ?? Router.Copy.all).font(CDS.sans(13, .medium))
                    .foregroundStyle(active || hot ? CDS.Text.primary : count == 0 ? CDS.Text.disabled : CDS.Text.muted)
                RouterCount(count: count, tint: count == 0 ? CDS.Text.disabled : CDS.Text.muted)
            }
            .lineLimit(1).fixedSize()
            .geometryGroup()
            .modifier(Shell(model: model, item: .project(project), active: active, hot: hot, pressed: pressed, grounds: grounds, group: "project"))
        }
        .accessibilityLabel("\(project ?? "All projects"), \(count)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func token(_ section: RouterSection) -> some View {
        let count = model.count(section: section)
        let active = model.section == section
        return RouterButton(model: model, hit: .state(section), action: { model.toggle(section: section) }) { hot, pressed in
            HStack(spacing: CDS.Tabs.badgeGap) {
                Image(systemName: section.symbol).font(.system(size: M.mark, weight: .semibold))
                    .foregroundStyle(count == 0 ? CDS.Text.disabled : section.tint)
                RouterCount(count: count, tint: count == 0 ? CDS.Text.disabled : active || hot ? CDS.Text.primary : CDS.Text.muted)
                    // Room for two digits: the tokens don't shift when a count gains one.
                    .frame(minWidth: 14, alignment: .leading)
            }
            .fixedSize()
            .geometryGroup()
            .modifier(Shell(model: model, item: .state(section), active: active, hot: hot, pressed: pressed, grounds: grounds, group: "state"))
            // The word, on the label: a tooltip around the button itself stood between it and an accessibility press.
            .help("\(section.title), \(count)")
        }
        .accessibilityLabel("\(section.title), \(count)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// CDS Tabs' shell: 24 tall, 8 padding, radius 6; the active one's ground slides between the pills of its group.
    private struct Shell: ViewModifier {
        let model: RouterModel
        let item: RouterFilterItem
        let active: Bool
        let hot: Bool
        let pressed: Bool
        let grounds: Namespace.ID
        let group: String

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: CDS.Tabs.radius, style: .continuous)
            let ringed = model.filterMode && model.ring == item
            content
                .padding(.horizontal, CDS.Tabs.pad)
                .frame(height: CDS.Tabs.height)
                .background {
                    ZStack {
                        shape.fill(pressed ? Router.Surface.pressed : hot && !active ? Router.Surface.hover : .clear).hoverMotion(hot)
                        if active { shape.fill(Router.Surface.pressed).matchedGeometryEffect(id: group, in: grounds) }
                    }
                }
                .overlay { if ringed { RouterRing(radius: CDS.Tabs.radius) } }
                .scaleEffect(pressed ? 0.975 : 1)
        }
    }
}

/// The filter bar's Clear: its Esc keycap shows only when Esc would clear (it steps out of a card or a draft first). Its
/// own view: what Esc does reads the draft, and the bar doesn't redraw on each key.
private struct RouterClearFilters: View {
    let model: RouterModel

    var body: some View {
        RouterTextButton(model: model, hit: .clear, title: Router.Copy.clear, keys: model.escClears ? ["esc"] : []) {
            model.clearFilters()
        }
        .motion(.fade, value: model.escClears)
    }
}

// MARK: - What floats

/// The hover peek, the housekeeping line's peek and the menus, placed by the frame of what they hang from: under it in
/// the top half of the page, over it in the bottom half.
struct RouterFloating: View {
    let model: RouterModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let frames = model.targets.frames
        ZStack(alignment: .topLeading) {
            if let id = model.peeked, let thread = model.thread(id), let frame = frames[.name(id)] {
                hung(from: frame, width: Router.Peek.width) { RouterPeek(thread: thread) }
                    .id("peek-" + id)
                    .transition(.scaleFade(0.98, reduce: reduce))
            }
            if let id = model.activityPeeked, let thread = model.thread(id), let frame = frames[.activity(id)] {
                // The glyphs sit at the line's end: their peek hangs back from their trailing edge, inside the page.
                hung(from: frame, width: Router.Peek.width, trailing: true) { RouterActivityPeek(model: model, thread: thread) }
                    .id("activity-" + id)
                    .transition(.scaleFade(0.98, reduce: reduce))
            }
            if model.flags(.housekeepingWords).hot, let frame = frames[.housekeepingWords], !model.shownOlder.isEmpty {
                hung(from: frame, width: Router.Peek.olderWidth) { RouterOlderPeek(model: model, older: model.shownOlder) }
                    .transition(.scaleFade(0.98, reduce: reduce))
            }
            if let menu = model.snoozeMenu, let frame = frames[.footer(menu.thread, .snooze)] {
                // Under its button in the top half of the page, over it in the bottom half, its trailing edge on the
                // button's: it never covers the line it snoozes.
                hung(from: frame, width: 200, trailing: true) { RouterSnoozeMenuView(model: model, menu: menu) }
                    .transition(.opacity)
            }
            if model.placesMenu, let frame = frames[.places] {
                hung(from: frame, width: 260, below: false, trailing: true) { RouterPlacesMenu(model: model) }
                    .transition(.opacity)
            }
            if let field = model.launchMenu, let frame = frames[.launch(field)] {
                hung(from: frame, width: Router.Launch.menuWidth, below: false) { RouterLaunchMenu(model: model, field: field) }
                    .id(field)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .motion(.fade, value: model.peeked)
        .motion(.fade, value: model.activityPeeked)
        .motion(.fade, value: model.flags(.housekeepingWords).hot)
        .motion(.fade, value: model.snoozeMenu != nil)
        .motion(.fade, value: model.placesMenu)
        .motion(.fade, value: model.launchMenu)
    }

    /// `trailing`: the panel's trailing edge on its anchor's (a menu under a trailing button).
    private func hung<Content: View>(from frame: CGRect, width: CGFloat, below: Bool? = nil, trailing: Bool = false,
                                     @ViewBuilder content: () -> Content) -> some View {
        let viewport = model.targets.viewport
        let start = trailing ? frame.maxX - width : frame.minX
        let shift = start - frame.minX + min(0, viewport.width - 16 - (start + width))
        return Color.clear.frame(width: frame.width, height: frame.height)
            .overlay(alignment: .topLeading) {
                BriefPanelPlacement(dx: shift, gap: Router.Peek.gap, below: below ?? (frame.midY < viewport.height / 2)) {
                    content().fixedSize()
                }
            }
            .allowsHitTesting(true)
            .offset(x: frame.minX, y: frame.minY)
    }
}

/// A highlight's panel, placed at its ideal size under the highlight (or above it), moved `dx` sideways; it takes the
/// highlight's own size, so it never changes the line's layout.
struct BriefPanelPlacement: Layout {
    var dx: CGFloat
    var gap: CGFloat
    var below: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let y = below ? bounds.maxY + gap : bounds.minY - gap - size.height
            view.place(at: CGPoint(x: bounds.minX + dx, y: y), proposal: ProposedViewSize(size))
        }
    }
}
