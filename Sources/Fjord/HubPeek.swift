import SwiftUI

// Hovering a section of the bar opens just that section beside it, in a panel lined up with its cells. The bar
// itself never moves, so what you're pointing at stays under the pointer. A click goes to the app window.

enum HubSection: Hashable, CaseIterable { case inbox, router, controls }

struct PeekMeasure: Equatable {
    let section: HubSection
    let size: CGSize
}

/// Reports a section's place in the bar and makes it the one shown when the pointer enters it.
struct SectionProbe: ViewModifier {
    let section: HubSection
    let hub: HubState
    @Binding var frames: [HubSection: CGRect]

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FjordHub.barSpace)) } action: { frame in
                if frames[section] != frame { frames[section] = frame }
            }
            .onHover { if $0 { hub.enter(section) } else { hub.cancelDwell() } }
    }
}

extension FjordHub {
    static let barSpace = "hub-bar"
    /// Between the bar and a section's panel: none, so the pointer never falls between them.
    static let peekGap: CGFloat = 0

    func probe(_ section: HubSection) -> SectionProbe {
        SectionProbe(section: section, hub: hub, frames: $sectionFrames)
    }

    /// The hovered section.
    var peeking: HubSection? { hub.quiet ? nil : hub.section }

    /// Where a panel sits along the bar: from `start`, `length` long (both along the bar's edge), and which of the
    /// bar's ends it reaches.
    struct Placement: Equatable {
        var start: CGFloat
        var length: CGFloat
        /// Flush with the bar's start (top, or left), or reaching its end (bottom, or right): the bar's corner there
        /// goes square, so the two make one clean edge.
        var atStart: Bool
        var atEnd: Bool
        /// Runs on past the bar's end: its own corner there stays round.
        var pastEnd: Bool
    }

    /// Closer than this to an end of the bar, a panel snaps flush with it.
    static let peekSnap: CGFloat = 60

    /// Beside the bar, a panel's header lines up with its section's first cell (the inbox's starts at the bar's
    /// top, the controls' ends at its bottom); along the top and bottom it starts under its segment (ends under it,
    /// for the controls). Then it's kept within the bar, and snapped flush with an end it comes close to.
    func placement(_ section: HubSection, _ frame: CGRect) -> Placement? {
        let bar = edge.isHorizontal ? barSize.width : barSize.height
        // This section's own measured size: until it's known (or while another's is all there is), nothing to place.
        let natural = edge.isHorizontal ? panelWidth(section) : peekSizes[section]?.height ?? 0
        guard bar > 0, natural > 0, peekSizes[section] != nil else { return nil }
        var start: CGFloat
        var length = natural
        if edge.isHorizontal {
            start = section == .controls ? frame.maxX - length : frame.minX
            start = min(max(start, 0), max(bar - length, 0))
            if start < Self.peekSnap { start = 0 }
            if length <= bar, bar - (start + length) < Self.peekSnap { start = bar - length }
        } else {
            // Its lines stay level with their cells, so it only moves at the ends: it grows to meet the bar's
            // bottom if it ends close to it.
            start = section == .inbox ? 0 : section == .controls ? bar - length : max(frame.minY - Self.peekPad, 0)
            let short = bar - (start + length)
            if short >= 0, short < Self.peekSnap { length = bar - start }
            // Kept on screen: one that would run past the screen's bottom moves up until it fits (past the bar's top if it
            // must), and one taller than the screen is cut to it.
            let room = hub.room
            if start + length > room.after { start = max(room.after - length, -room.before) }
            length = min(length, room.before + room.after)
        }
        let end = start + length
        return Placement(start: start, length: length, atStart: abs(start) <= 0.5, atEnd: end >= bar - 0.5, pastEnd: end > bar + 0.5)
    }

    /// The panel for the hovered section, placed beside (or under) its cells in the bar.
    @ViewBuilder var peekPanel: some View {
        // On glass it comes in only once placed (measured ahead, `peekMeasurer`), so its glass grows out of the bar's from
        // the start rather than showing up in place a layout later.
        if let section = peeking, let frame = sectionFrames[section], !glass || placement(section, frame) != nil {
            let place = placement(section, frame)
            let shape = panelShape(place)
            let content = peekContent(section)
                // The section is part of what's observed: an equal size on switching must still fill that section's entry.
                .onGeometryChange(for: PeekMeasure.self) { PeekMeasure(section: section, size: $0.size) } action: {
                    if peekSizes[$0.section] != $0.size { peekSizes[$0.section] = $0.size }
                }
                .frame(height: edge.isHorizontal ? nil : place?.length, alignment: .top)
            let o = peekOffset(section, place)
            panelSurface(content, shape, place)
                .fixedSize()
                .onHover { overPanel = $0; hubPointer(overBar || overPanel) }
                // Where it is drawn, for the controller to tell whether the pointer is on it.
                .background(HubPiece(hub: hub, section: section))
                // Hidden until it's been measured and placed, so it never shows up in the wrong spot first.
                .opacity(place == nil ? 0 : 1)
                .transition(glass ? glassPeekTransition : peekTransition)
                .offset(x: o.width, y: o.height)
        }
    }

    /// A panel's surface: glass growing out of the bar's, or today's opaque panel.
    @ViewBuilder func panelSurface(_ content: some View, _ shape: UnevenRoundedRectangle, _ place: Placement?) -> some View {
        if #available(macOS 26, *) {
            if glass { glassPanel(content, shape, place) } else { opaquePanel(content, shape, place) }
        } else {
            opaquePanel(content, shape, place)
        }
    }

    /// On glass the panel's glass comes out of the bar's edge as one shape (the bar's container merges the two, so there
    /// is no seam to hide), its content fading in just behind. Reduce Motion: no morph, the panel fades as a whole.
    @available(macOS 26, *)
    func glassPanel(_ content: some View, _ shape: UnevenRoundedRectangle, _ place: Placement?) -> some View {
        content
            .modifier(PeekReveal(reduce: reduce))
            .clipShape(shape)
            .contentShape(shape)
            .glassEffect(.regular, in: shape)
            .glassEffectID(BarGlass.ID.panel, in: glassSpace)
            .glassEffectTransition(reduce ? .identity : .matchedGeometry)
    }

    /// Today's panel: filled black and ringed, the seam where it meets the bar painted over.
    func opaquePanel(_ content: some View, _ shape: UnevenRoundedRectangle, _ place: Placement?) -> some View {
        content
            .background(shape.fill(Theme.bg))
            .overlay(shape.strokeBorder(CDS.border, lineWidth: 1))
            .clipShape(shape)
            // No seam where it meets the bar: the two outlines there are painted over, so bar and panel read
            // as one shape.
            .overlay(alignment: seamAlignment) { seam(place) }
    }

    /// Only the first open and the last close fade and slide; switching sections is instant (no Reduce Motion: no slide).
    var peekTransition: AnyTransition {
        let d: CGFloat = reduce ? 0 : Theme.Space.sm
        return .opacity.combined(with: .offset(x: edge == .right ? d : edge == .left ? -d : 0,
                                               y: edge == .top ? -d : edge == .bottom ? d : 0))
    }

    /// On glass the glass itself does the coming and going (`glassEffectTransition`, on the `glass` spring): the panel is there
    /// at once and its content fades in behind, and going, its content fades on `fade` as its glass goes back into the bar
    /// (`PeekReveal`). The removal also fades the whole panel on the transaction's spring: a transition that animates
    /// nothing was taken out at once (seen on screen), so the opacity keeps it there while its glass goes back. Reduce
    /// Motion: a plain fade both ways.
    var glassPeekTransition: AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: .identity, removal: AnyTransition(PeekLeave()).combined(with: .opacity))
    }

    /// On glass, the panels measured out of sight (`toMeasure`).
    var peekMeasurer: some View {
        PeekMeasurer(hub: hub, peeking: peeking, inBar: Set(sectionFrames.keys), measured: Set(peekSizes.keys),
                     content: { AnyView(peekContent($0)) }, report: takeMeasure)
    }

    /// The sections whose panels are measured out of sight on glass, so each opens already placed: the one a dwell is
    /// waiting on, afresh (its content may have changed size since it was last open), and while a dwell waits or a panel is
    /// open, each section of the bar not measured yet (so switching to one finds it placed). None at rest.
    static func toMeasure(arriving: HubSection?, peeking: HubSection?, inBar: Set<HubSection>,
                          measured: Set<HubSection>) -> [HubSection] {
        // While no panel is open only the one on its way is measured (a sweep along the bar measures one at a time); once
        // one is open, the others not measured yet too, so switching to them finds their place.
        guard peeking != nil else { return arriving.map { [$0] } ?? [] }
        return HubSection.allCases.filter { $0 == arriving || (inBar.contains($0) && !measured.contains($0)) }
    }

    /// A size measured out of sight. The open section's first one places its panel: on the `glass` spring, so its glass
    /// grows out of the bar's even then.
    func takeMeasure(_ m: PeekMeasure) {
        guard peekSizes[m.section] != m.size else { return }
        if m.section == peeking, peekSizes[m.section] == nil {
            withAnimation(Motion.glass.resolved(reduce: reduce)) { peekSizes[m.section] = m.size }
        } else {
            peekSizes[m.section] = m.size
        }
    }

    /// Laid over the bar from its top-left (bottom-left on the bottom edge), then moved out beside it.
    func peekOffset(_ section: HubSection, _ place: Placement?) -> CGSize {
        let along = place?.start ?? 0
        return switch edge {
        case .right: CGSize(width: -(panelWidth(section) + Self.peekGap), height: along)
        case .left: CGSize(width: Self.cell + Self.peekGap, height: along)
        case .top: CGSize(width: along, height: Self.cell + Self.peekGap)
        case .bottom: CGSize(width: along, height: -(Self.cell + Self.peekGap))
        }
    }

    /// The open panel's outline with its shadow, in the layer behind the bar and panel.
    @ViewBuilder var peekShadow: some View {
        if let section = peeking, let frame = sectionFrames[section], let place = placement(section, frame),
           let size = peekSizes[section] {
            let o = peekOffset(section, place)
            Color.clear
                .frame(width: panelWidth(section), height: edge.isHorizontal ? size.height : place.length)
                // Claude's `shadow-panel` drops.
                .background {
                    panelShape(place).fill(Theme.bg)
                        .shadow(color: CDS.PanelShadow.far.color, radius: CDS.PanelShadow.far.radius, y: CDS.PanelShadow.far.y)
                        .shadow(color: CDS.PanelShadow.near.color, radius: CDS.PanelShadow.near.radius, y: CDS.PanelShadow.near.y)
                }
                .offset(x: o.width, y: o.height)
                .transition(peekTransition)
        }
    }

    /// Where the panel hangs from: the bar's top-left, or its bottom-left on the bottom edge.
    var peekAlignment: Alignment { edge == .bottom ? .bottomLeading : .topLeading }

    /// The current panel's place, for the bar's own outline.
    var currentPlacement: Placement? {
        guard let section = peeking, let frame = sectionFrames[section] else { return nil }
        return placement(section, frame)
    }

    var seamAlignment: Alignment {
        switch edge {
        case .right: .topTrailing
        case .left: .topLeading
        case .top: .topLeading
        case .bottom: .bottomLeading
        }
    }

    /// Paint over both outlines along what the panel shares with the bar (1pt into each), short of its ends so
    /// the panel's own outline still meets the bar there; not past the bar's end, where the panel's edge is its own.
    func seam(_ place: Placement?) -> some View {
        let bar = edge.isHorizontal ? barSize.width : barSize.height
        let shared = place.map { max(0, min($0.start + $0.length, bar) - $0.start - 2) } ?? 0
        return Rectangle().fill(Theme.bg)
            .frame(width: edge.isHorizontal ? shared : 2, height: edge.isHorizontal ? 2 : shared)
            .offset(x: edge == .right ? 1 : edge == .left ? -1 : 1, y: edge == .top ? -1 : edge == .bottom ? 1 : 1)
    }

    /// The bar's outline: a corner goes square where a panel is flush with (or runs past) that end of the bar.
    var barOutline: UnevenRoundedRectangle {
        let r = BarGlass.barRadius
        let place = currentPlacement
        let start: CGFloat = place?.atStart == true ? 0 : r
        let end: CGFloat = place?.atEnd == true ? 0 : r
        return switch edge {
        case .right: UnevenRoundedRectangle(topLeadingRadius: start, bottomLeadingRadius: end, style: .continuous)
        case .left: UnevenRoundedRectangle(bottomTrailingRadius: end, topTrailingRadius: start, style: .continuous)
        case .top: UnevenRoundedRectangle(bottomLeadingRadius: start, bottomTrailingRadius: end, style: .continuous)
        case .bottom: UnevenRoundedRectangle(topLeadingRadius: start, topTrailingRadius: end, style: .continuous)
        }
    }

    /// A panel against the bar: square where it meets the bar, rounded elsewhere, and rounded on the bar's side too
    /// where it runs on past the bar's end. On glass its corners are the bar's, so the shape the two make has one radius.
    func panelShape(_ place: Placement?) -> UnevenRoundedRectangle {
        let r = glass ? BarGlass.panelRadius : Self.panelRadius
        let past: CGFloat = place?.pastEnd == true ? r : 0
        return switch edge {
        case .right: UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: past, style: .continuous)
        case .left: UnevenRoundedRectangle(bottomLeadingRadius: past, bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        case .top: UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: past, style: .continuous)
        case .bottom: UnevenRoundedRectangle(topLeadingRadius: r, bottomTrailingRadius: past, topTrailingRadius: r, style: .continuous)
        }
    }

    /// A panel's free corners (opaque): the hub's shell round, larger than Claude's 10pt popovers as it is part of the island.
    static let panelRadius: CGFloat = 16
    /// A panel's padding, all round, as Claude's sidebar body (8 at the sides); rows pad their own inside it.
    static let peekPad: CGFloat = Theme.Space.md
    /// A section header's height, the same as a CI or agents cell in the bar, so the lines under it line up.
    static let peekLine: CGFloat = Theme.Metrics.line

    /// A panel's width: the controls' is a small menu.
    func panelWidth(_ section: HubSection) -> CGFloat {
        section == .controls ? Self.controlsWidth : Self.detail
    }

    /// The controls' panel: a Claude menu's width (128–320).
    static let controlsWidth: CGFloat = 232

    @ViewBuilder func peekContent(_ section: HubSection) -> some View {
        Group {
            if section == .controls { peekControls }
            else if edge.isHorizontal { peekColumn(section) } else { peekRows(section) }
        }
        // The controls are a menu: Claude's `p-1` around its rows (and 2 more, for the panel's larger round).
        .padding(section == .controls ? CDS.Menu.pad + 2 : Self.peekPad)
        .frame(width: panelWidth(section))
    }

    /// Beside the bar: the header level with the section's first cell, then one line per cell, as tall as the
    /// cell; then whatever only the panel has (the inbox list).
    @ViewBuilder func peekRows(_ section: HubSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch section {
            case .inbox:
                inboxHeader.frame(height: Self.peekLine)
                peekInbox.padding(.top, 4)
            case .router:
                peekRouter
            default:
                // (The controls have their own panel.)
                EmptyView()
            }
        }
        .frame(width: Self.detail - 2 * Self.peekPad, alignment: .leading)
    }

    /// Under (or over) a strip segment: that section's header, then its content.
    @ViewBuilder func peekColumn(_ section: HubSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch section {
            case .inbox:
                inboxHeader.frame(height: Self.peekLine)
                peekInbox
            case .router:
                peekRouter
            default:
                EmptyView()
            }
        }
        .frame(width: Self.detail - 2 * Self.peekPad, alignment: .leading)
    }

    /// The bar's last cell: a gear. Hovering shows the controls; a click goes to Settings.
    var controlsCell: some View {
        ControlsMark { reopenApp() }
    }

    /// The controls: when the inbox was last updated (and a refresh), then the window and settings, each with its key.
    var peekControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            // As a Claude menu's group label: `px-2 py-1`, footnote, muted.
            if store.triageOn {
                syncStatus
                    .padding(.horizontal, CDS.Menu.itemPadX)
                    .frame(maxWidth: .infinity, minHeight: CDS.Menu.labelHeight, alignment: .leading)
            }
            MenuRow(symbol: "macwindow", title: "Open window", key: store.shortcut(.togglePanel).display) {
                openApp(firstDestination)
            }
            MenuRow(symbol: "gearshape", title: "Settings", key: "⌘,") { openApp(.settings) }
        }
    }

    /// The inbox list in a panel: scrolls once it's long.
    @ViewBuilder var peekInbox: some View {
        undoLine
        if items.isEmpty {
            emptyInbox
        } else {
            CappedScroll(cap: 360, hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(items.count)) {
                AdaptiveStack(count: items.count, spacing: 1) { ForEach(items) { itemRow($0).id("i:" + $0.id) } }
                    .motion(.fade, value: listKey)
            }
        }
    }
}

/// Fjord's mark at the end of the bar, without a tooltip: hovering it opens the controls, clicking it the app window where
/// it was left. Claude's ghost icon button, compact: a 24 square, radius 6, the mark in one secondary ink going white on a
/// white-7.5% hover.
struct ControlsMark: View {
    let action: () -> Void
    @Environment(\.onBarGlass) private var glass
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) { ControlsMarkLabel() }
            .buttonStyle(HoverFillButtonStyle(shape: RoundedRectangle(cornerRadius: CDS.Density.compact.radius, style: .continuous),
                                              rest: .clear,
                                              hover: BarGlass.fill(.hover, glass: glass, scheme: scheme, opaque: CDS.Fill.ghostHover),
                                              pressed: BarGlass.fill(.selected, glass: glass, scheme: scheme, opaque: CDS.Fill.ghostSelected)))
            .accessibilityLabel("Fjord")
            .accessibilityHint("Opens the window where you left it; hover for Settings and the last update")
    }
}

private struct ControlsMarkLabel: View {
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        ZStack { ForEach(0..<3, id: \.self) { FjordMarkPart(part: $0) } }
            .frame(width: 15, height: 15)
            .chromeInk(hover ? .primary : .secondary, hover ? Brand.ink : CDS.Text.secondary)
            .frame(width: CDS.Density.compact.control, height: CDS.Density.compact.control)
    }
}

/// A line of the controls' panel, as a Claude menu item (composer-overlays.md §8): 24 tall, 8 at the sides, 6 between a
/// 16pt glyph and its 13pt title, radius 6, white 7.5% under the pointer; the key that does the same as its trailing hint.
struct MenuRow: View {
    let symbol: String
    let title: String
    let key: String?
    let action: () -> Void
    @Environment(\.onBarGlass) private var glass
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: CDS.Menu.itemGap) {
                Image(systemName: symbol)
                    .font(.system(size: CDS.Sidebar.symbol, weight: .medium))
                    .chromeInk(.secondary, CDS.Text.secondary)
                    .frame(width: CDS.Density.compact.icon)
                    .accessibilityHidden(true)
                Text(title).font(CDS.sans(CDS.Density.compact.body.0)).chromeInk(.primary, CDS.Text.primary)
                Spacer(minLength: CDS.Menu.hintGap)
                if let key {
                    Text(key).font(CDS.sans(CDS.Density.compact.footnote.0)).chromeInk(.tertiary, CDS.Text.muted)
                }
            }
            .padding(.horizontal, CDS.Menu.itemPadX)
            .frame(height: CDS.Menu.item)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillButtonStyle(shape: RoundedRectangle(cornerRadius: CDS.Menu.itemRadius, style: .continuous),
                                          rest: .clear,
                                          hover: BarGlass.fill(.hover, glass: glass, scheme: scheme, opaque: CDS.Fill.ghostHover),
                                          pressed: BarGlass.fill(.selected, glass: glass, scheme: scheme, opaque: CDS.Fill.ghostSelected)))
        .accessibilityLabel(title)
    }
}
