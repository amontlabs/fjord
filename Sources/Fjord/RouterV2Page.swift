import AppKit
import SwiftUI

// Router v2's page (docs/design/router-v2/DESIGN.md 1): the title line, the sticky filter bar, one list of rows (a
// section's header, its lines, the housekeeping line) and the dock floating at the bottom. All rows are one `ForEach`
// with stable ids, declared in an order that never changes and laid out in the page's (`RouterV2Stack`), so a line that
// changes section keeps its identity and glides there. What floats (the hover peek, the snooze menu) is drawn over the
// whole page from the targets' frames, so nothing clips it.

// MARK: - The list

struct RouterV2List: View {
    let model: RouterV2Model
    let edges: RouterEdges
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.windowArrival) private var arrival

    var body: some View {
        // The stored layout: this body runs when the order or a count changes, not when a line's fields do.
        let rows = model.layout
        let _ = RouterV2Bodies.count("list")
        // Each row's place on the page. The rows themselves are declared by id, an order no change of section moves:
        // a reordered `ForEach` takes the row out and puts it back in, and then nothing glides.
        let places = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let declared = rows.sorted { $0.id < $1.id }
        let leading = edges.leading - RouterV2.Line.nameLeading
        let trailing = edges.trailing - RouterV2.Line.reach
        ScrollViewReader { proxy in
            ScrollView {
                RouterV2Stack {
                    ForEach(declared) { row in
                        view(row, first: row.id == rows.first?.id)
                            .layoutValue(key: RouterV2Stack.Order.self, value: places[row.id] ?? 0)
                            // Read top to bottom, whatever the order they are declared in.
                            .accessibilitySortPriority(Double(rows.count - (places[row.id] ?? 0)))
                            .transition(.routerV2Fold(reduce: reduce))
                    }
                }
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
                        RouterV2FilterBar(model: model)
                            .padding(.leading, edges.leading - CDS.Tabs.pad).padding(.trailing, edges.trailing - CDS.Tabs.pad)
                            .transition(.opacity)
                    }
                }
                .frame(height: RouterV2.Bar.control + 2 * RouterV2.Bar.padY)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RouterV2Dock(model: model)
                    .padding(.leading, edges.leading).padding(.trailing, edges.trailing)
                    .padding(.bottom, RouterV2.Dock.bottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The page's ground, solid from the dock's top edge down, and a fade above it: lines scroll out under
                    // the fade and never show through between the dock's rows.
                    .background {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [CDS.Surface.s1.opacity(0), CDS.Surface.s1], startPoint: .top, endPoint: .bottom)
                                .frame(height: RouterV2.Bar.fade)
                            CDS.Surface.s1
                        }
                        .padding(.top, -RouterV2.Bar.fade)
                        .allowsHitTesting(false)
                    }
            }
            .background { RouterV2Reveal(model: model, proxy: proxy) }
        }
    }

    @ViewBuilder private func view(_ row: RouterV2Slot, first: Bool) -> some View {
        switch row.kind {
        // The first row's content (the Needs-you header, or the sentence in its place) swaps in place. The swap's
        // fades carry their own curve: a curve set here on all the rows would take the lines' glide from them.
        case .header(let section, let count):
            RouterV2HeaderRow(model: model, section: section, count: count, first: first)
                .transition(.routerV2Swap)
        case .sentence(let words, let clear):
            RouterV2SentenceRow(model: model, words: words, clear: clear)
                .transition(.routerV2Swap)
        case .line(let id):
            RouterV2HostedLine(model: model, box: model.box(id))
        case .housekeeping(let count):
            RouterV2HousekeepingRow(model: model, count: count)
        }
    }
}

/// Brings the selection's line into view as it moves: its own view, so a reveal doesn't run the list's body.
private struct RouterV2Reveal: View {
    let model: RouterV2Model
    let proxy: ScrollViewProxy
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.windowArrival) private var arrival

    var body: some View {
        Color.clear
            .onChange(of: model.revealTick) {
                guard let line = model.reveal,
                      let row = model.layout.first(where: { $0.id == line || $0.id.hasPrefix(line + "@") }) else { return }
                // After the card has its place in the layout.
                let follow = arrival?.active == true ? nil : Motion.follow.resolved(reduce: reduce)
                DispatchQueue.main.async { withAnimation(follow) { proxy.scrollTo(row.id) } }
            }
    }
}

/// `Needs you 5`: the section's name in its tint, the number of lines under it. A click is a click on its token.
struct RouterV2HeaderRow: View {
    let model: RouterV2Model
    let section: RouterV2Section
    let count: Int
    let first: Bool

    var body: some View {
        RouterV2Button(model: model, hit: .header(section), action: { model.toggle(section: section) }) { hot, _ in
            HStack(alignment: .firstTextBaseline, spacing: RouterV2.Header.countGap) {
                Text(section.title).font(CDS.sans(12, .semibold)).foregroundStyle(section.tint)
                    .underline(hot, color: section.tint.opacity(0.6))
                RouterV2Count(count: count, size: 12)
            }
            .frame(height: RouterV2.Header.height)
            // The count ticks inside the header and moves with it: it never leaves its label on the way.
            .geometryGroup()
        }
        .fixedSize()
        .padding(.top, first ? RouterV2.Header.firstTop : RouterV2.Header.top)
        .padding(.leading, RouterV2.Line.nameLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(section.title), \(count)")
    }
}

/// A count that ticks: `numericText` on `.snappy`, a fade under Reduce Motion.
struct RouterV2Count: View {
    let count: Int
    var size: CGFloat = 11
    var tint: Color = CDS.Text.muted
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Text(verbatim: "\(count)").font(CDS.sans(size)).monospacedDigit().foregroundStyle(tint)
            .contentTransition(reduce ? .opacity : .numericText(value: Double(count)))
            .motion(reduce ? .easeOut(duration: 0.12) : RouterV2.counts, value: count)
    }
}

/// The sentence that takes a header's place: "Nothing needs you." and its kin.
struct RouterV2SentenceRow: View {
    let model: RouterV2Model
    let words: String
    let clear: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(words).cdsText(CDS.Density.compact.prose, .regular, CDS.Text.secondary)
                .id(words).transition(.routerV2Swap)
            if clear {
                RouterV2PushButton(model: model, hit: .clearFilter, title: RouterV2.Copy.clearFilter, variant: .ghost) { model.clearFilters() }
            }
        }
        .frame(height: RouterV2.Header.height)
        .padding(.top, RouterV2.Header.firstTop)
        .padding(.leading, RouterV2.Line.nameLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(.fade, value: words)
    }
}

/// The list's last row: the threads that finished more than a day ago and were not settled, as one count and one act.
struct RouterV2HousekeepingRow: View {
    let model: RouterV2Model
    let count: Int

    var body: some View {
        let selected = model.flags(.housekeeping).selected
        HStack(spacing: 8) {
            Text(RouterV2.Copy.older(count)).font(CDS.sans(13)).foregroundStyle(CDS.Text.muted).lineLimit(1)
                .frame(height: 24)
                .contentShape(Rectangle())
                .routerV2Target(model, .housekeepingWords)
            Spacer(minLength: 8)
            RouterV2PushButton(model: model, hit: .settleAll, title: count == 1 ? "Settle" : "Settle all", variant: .ghost,
                               removes: true) { model.settleAll() }
        }
        .padding(.leading, RouterV2.Line.nameLeading).padding(.trailing, 5)
        .frame(minHeight: RouterV2.Line.minHeight)
        // Selected: the card's ground, at a row's size.
        .background {
            RoundedRectangle(cornerRadius: RouterV2.Surface.row, style: .continuous).fill(selected ? RouterV2.Surface.quiet : .clear)
        }
        .padding(.top, 12)
        .routerV2Target(model, .housekeeping)
    }
}

/// A button of the page, ghost or secondary, lit and pressed from the model (so the drawn pointer does both): `Settle
/// all`, `Continue`, `Edit`, `Send again`. As tall as a filter pill, a control's radius. A ghost one is a text button
/// with a hover ground: footnote size, as the card footer's. `ringed`: the keyboard is on it (Return presses it).
struct RouterV2PushButton: View {
    enum Variant { case ghost, secondary }

    let model: RouterV2Model
    let hit: RouterV2Hit
    let title: String
    var variant: Variant = .secondary
    var keys: [String] = []
    var removes = false
    var ringed = false
    let action: () -> Void

    var body: some View {
        let s = RouterV2.Surface.self
        let shape = RoundedRectangle(cornerRadius: s.control, style: .continuous)
        RouterV2Button(model: model, hit: hit, removes: removes, action: action) { hot, pressed in
            HStack(spacing: 6) {
                if variant == .ghost {
                    Text(title).cdsText(CDS.Density.compact.footnote, .regular, hot ? CDS.Text.primary : CDS.Text.secondary)
                        .lineLimit(1).fixedSize()
                } else {
                    Text(title).cdsText(CDS.Density.compact.body, .regular, CDS.Text.primary).lineLimit(1).fixedSize()
                }
                if !keys.isEmpty { RouterV2KeyHint(keys: keys) }
            }
            .padding(.horizontal, 8)
            .frame(height: RouterV2.Dock.button)
            .background {
                shape.fill(pressed ? s.pressed : fill(hot))
                    .scaleEffect(pressed ? 0.975 : 1)
                    .hoverMotion(hot)
            }
            .overlay { if ringed { RouterV2Ring(radius: s.control) } }
        }
        .accessibilityLabel(title)
    }

    private func fill(_ hot: Bool) -> Color {
        let s = RouterV2.Surface.self
        switch variant {
        case .ghost: return hot ? s.hover : .clear
        case .secondary: return hot ? s.chosenHover : s.chosen
        }
    }
}

// MARK: - Filter bar

/// One row, sticky over the list: the project pills (`All` first, then the projects with a line, alphabetical) and the
/// three state tokens. One choice in each group; counts are faceted. ⌘F puts the keyboard on it.
struct RouterV2FilterBar: View {
    let model: RouterV2Model
    @Namespace private var grounds
    @Environment(\.accessibilityReduceMotion) private var reduce

    private typealias M = RouterV2.Bar

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
                    RouterV2ClearFilters(model: model)
                        .padding(.leading, 12 - M.pillGap)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: M.tokenGap) {
                ForEach(RouterV2Section.allCases, id: \.self) { token($0) }
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
            .padding(.horizontal, -400)
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
        return RouterV2Button(model: model, hit: .project(project), action: { model.toggle(project: project) }) { hot, pressed in
            HStack(spacing: CDS.Tabs.badgeGap) {
                Text(project ?? RouterV2.Copy.all).font(CDS.sans(13, .medium))
                    .foregroundStyle(active || hot ? CDS.Text.primary : count == 0 ? CDS.Text.disabled : CDS.Text.muted)
                RouterV2Count(count: count, tint: count == 0 ? CDS.Text.disabled : CDS.Text.muted)
            }
            .lineLimit(1).fixedSize()
            .geometryGroup()
            .modifier(Shell(model: model, item: .project(project), active: active, hot: hot, pressed: pressed, grounds: grounds, group: "project"))
        }
        .accessibilityLabel("\(project ?? "All projects"), \(count)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func token(_ section: RouterV2Section) -> some View {
        let count = model.count(section: section)
        let active = model.section == section
        return RouterV2Button(model: model, hit: .state(section), action: { model.toggle(section: section) }) { hot, pressed in
            HStack(spacing: CDS.Tabs.badgeGap) {
                Image(systemName: section.symbol).font(.system(size: M.mark, weight: .semibold))
                    .foregroundStyle(count == 0 ? CDS.Text.disabled : section.tint)
                RouterV2Count(count: count, tint: count == 0 ? CDS.Text.disabled : active || hot ? CDS.Text.primary : CDS.Text.muted)
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
        let model: RouterV2Model
        let item: RouterV2FilterItem
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
                        shape.fill(pressed ? RouterV2.Surface.pressed : hot && !active ? RouterV2.Surface.hover : .clear).hoverMotion(hot)
                        if active { shape.fill(RouterV2.Surface.pressed).matchedGeometryEffect(id: group, in: grounds) }
                    }
                }
                .overlay { if ringed { RouterV2Ring(radius: CDS.Tabs.radius) } }
                .scaleEffect(pressed ? 0.975 : 1)
        }
    }
}

/// The filter bar's Clear: its Esc keycap shows only when Esc would clear (it steps out of a card or a draft first). Its
/// own view: what Esc does reads the draft, and the bar doesn't redraw on each key.
private struct RouterV2ClearFilters: View {
    let model: RouterV2Model

    var body: some View {
        RouterV2TextButton(model: model, hit: .clear, title: RouterV2.Copy.clear, keys: model.escClears ? ["esc"] : []) {
            model.clearFilters()
        }
        .motion(.fade, value: model.escClears)
    }
}

// MARK: - What floats

/// The hover peek, the housekeeping line's peek and the menus, placed by the frame of what they hang from: under it in
/// the top half of the page, over it in the bottom half.
struct RouterV2Floating: View {
    let model: RouterV2Model
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let frames = model.targets.frames
        ZStack(alignment: .topLeading) {
            if let id = model.peeked, let thread = model.thread(id), let frame = frames[.name(id)] {
                hung(from: frame, width: RouterV2.Peek.width) { RouterV2Peek(thread: thread) }
                    .id("peek-" + id)
                    .transition(.scaleFade(0.98, reduce: reduce))
            }
            if let id = model.activityPeeked, let thread = model.thread(id), let frame = frames[.activity(id)] {
                hung(from: frame, width: RouterV2.Peek.width) { RouterV2ActivityPeek(model: model, thread: thread) }
                    .id("activity-" + id)
                    .transition(.scaleFade(0.98, reduce: reduce))
            }
            if model.flags(.housekeepingWords).hot, let frame = frames[.housekeepingWords], !model.shownOlder.isEmpty {
                hung(from: frame, width: RouterV2.Peek.olderWidth) { RouterV2OlderPeek(model: model, older: model.shownOlder) }
                    .transition(.scaleFade(0.98, reduce: reduce))
            }
            if let menu = model.snoozeMenu, let frame = frames[.footer(menu.thread, .snooze)] {
                // Under its button in the top half of the page, over it in the bottom half, its trailing edge on the
                // button's: it never covers the line it snoozes.
                hung(from: frame, width: 200, trailing: true) { RouterV2SnoozeMenuView(model: model, menu: menu) }
                    .transition(.opacity)
            }
            if model.placesMenu, let frame = frames[.places] {
                hung(from: frame, width: 260, below: false, trailing: true) { RouterV2PlacesMenu(model: model) }
                    .transition(.opacity)
            }
            if let field = model.launchMenu, let frame = frames[.launch(field)] {
                hung(from: frame, width: RouterV2.Launch.menuWidth, below: false) { RouterV2LaunchMenu(model: model, field: field) }
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
                BriefPanelPlacement(dx: shift, gap: RouterV2.Peek.gap, below: below ?? (frame.midY < viewport.height / 2)) {
                    content().fixedSize()
                }
            }
            .allowsHitTesting(true)
            .offset(x: frame.minX, y: frame.minY)
    }
}
