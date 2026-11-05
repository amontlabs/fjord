import AppKit
import SwiftUI

private typealias M = CDS.Palette

// The palette's overlay (docs/design/palette/DESIGN.md): Claude desktop's command palette (search-tabs-avatars.md §1, comfortable
// density, the restyle gate on) drawn over the app window: a backdrop, the surface with its query field, the list and the footer
// of key hints.

extension CDS {
    /// The palette's own metrics (search-tabs-avatars.md §1.2–§1.7); the colours, type and keycaps are the design system's.
    enum Palette {
        /// `min(viewport − 80, 672)`; `viewport − 32` below 768.
        static let maxWidth: CGFloat = 672
        static let sideMargin: CGFloat = 40
        static let narrowMargin: CGFloat = 16
        static let radius: CGFloat = 20
        /// `--cp-inset` (the desktop title bar), `--cp-clearance`, and `--cp-settled-h`.
        static let inset: CGFloat = 45
        static let clearance: CGFloat = 61
        static let settledHeight: CGFloat = 583.9
        /// The input row: `pl-6 pt-[1.1rem] pr-2.5 pb-[0.9rem]`, a 32pt field, a 32pt close button, gap 2.
        static let inputPad = EdgeInsets(top: 17.6, leading: 24, bottom: 14.4, trailing: 10)
        static let inputGap: CGFloat = 8
        static let fieldHeight: CGFloat = 32
        static let fontSize: CGFloat = 14
        static let icon: CGFloat = 20
        static let closeSize: CGFloat = 32
        /// The list: `p-2.5`, at most 440 tall (481 with no footer), groups 4 apart.
        static let listPad: CGFloat = 10
        static let listMax: CGFloat = 440
        static let listMaxNoFooter: CGFloat = 481
        static let groupGap: CGFloat = 4
        /// Rows: `px-3 py-2 rounded-lg`, 14/20, 12 between the title and the end; headers `px-3.5 pt-3 pb-2`, 12/17.
        static let row: CGFloat = 36
        static let rowPadX: CGFloat = 12
        static let rowRadius: CGFloat = 8
        static let rowGap: CGFloat = 12
        static let contentGap: CGFloat = 8
        static let header: CGFloat = 37
        static let headerPadX: CGFloat = 14
        /// The status dot on the icon: 6pt, 1pt up and right of the icon's corner, with a cut-out around it.
        static let dot: CGFloat = 6
        /// The footer: `pr-4 pl-5 py-2.5`, hints 20 apart.
        static let footer: CGFloat = 40.5
        static let footerPad = EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16)
        static let hintGap: CGFloat = 20
        /// What the empty state asks for in height.
        static let empty: CGFloat = 132
    }

    /// The palette's footer text: caption, 12/17 muted.
    static var paletteCaption: (CGFloat, CGFloat) { Density.comfortable.caption }
}

/// Where the palette's surface goes in a window, and how tall its list may be (§1.2): the surface hangs from `top`, centred,
/// and its column is at most as tall as the window leaves under it.
struct PaletteLayout: Equatable {
    var width: CGFloat
    var top: CGFloat
    /// The tallest the whole column may be.
    var columnMax: CGFloat

    init(window: CGSize) {
        width = window.width >= 768 ? min(window.width - M.sideMargin * 2, M.maxWidth) : max(0, window.width - M.narrowMargin * 2)
        if window.width < 640 {
            top = M.clearance
        } else {
            let cap = window.height * (window.width >= 1024 ? 0.25 : 0.15)
            top = max(M.clearance, min(cap, max(M.inset + 32, (window.height - M.settledHeight + M.inset) / 2)))
        }
        columnMax = max(0, window.height - top - 32)
    }

    /// The list's height for `content` points of rows: all of them up to what the column leaves.
    func listHeight(content: CGFloat, footer: Bool) -> CGFloat {
        let input = M.inputPad.top + M.fieldHeight + M.inputPad.bottom + CDS.hairline
        let room = columnMax - input - (footer ? M.footer : 0)
        return max(0, min(content, footer ? M.listMax : M.listMaxNoFooter, room))
    }
}

/// What the overlay draws: the palette while it is open, nothing (no hit-testing either) while it is not.
struct PaletteOverlay: View {
    let palette: PaletteModel
    let store: Store

    var body: some View {
        if palette.isOpen {
            PaletteView(palette: palette, store: store)
                .transition(.opacity)
                .zIndex(101)
        }
    }
}

struct PaletteView: View {
    let palette: PaletteModel
    let store: Store
    @State private var scrolled = false

    var body: some View {
        GeometryReader { geometry in
            let layout = PaletteLayout(window: geometry.size)
            ZStack(alignment: .top) {
                Color.black.opacity(0.5)
                    .contentShape(Rectangle())
                    .onTapGesture { palette.close() }
                    .accessibilityHidden(true)
                surface(layout)
                    .frame(width: layout.width)
                    .padding(.top, layout.top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
        // The data under the open palette moved (an item arrived, an entry was archived): the rows follow it.
        .onChange(of: palette.sourceStamp) { palette.reloadSoon() }
        // The window went elsewhere without the palette (a shortcut, a notification), or the quit dialog came up: out of the way.
        .onChange(of: palette.navigationSelection) { palette.close(restoringFocus: false) }
        .onChange(of: palette.quitPromptUp) { _, up in if up { palette.close(restoringFocus: false) } }
    }

    private func surface(_ layout: PaletteLayout) -> some View {
        let shape = RoundedRectangle(cornerRadius: M.radius, style: .continuous)
        return VStack(spacing: 0) {
            inputRow
            Rectangle().fill(CDS.border).frame(height: CDS.hairline)
            list(layout)
            if !palette.footerCollapsed { PaletteFooter(page: palette.page) }
        }
        // The list is already as tall as the column leaves it room for.
        .fixedSize(horizontal: false, vertical: true)
        .background(CDS.Surface.s3, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(CDS.borderStrong, lineWidth: CDS.hairline))
        // `shadow-2xl`: 0 25px 50px -12px black 25%. SwiftUI has no spread: the shadow is cast by a shape drawn 12 smaller.
        .background {
            RoundedRectangle(cornerRadius: M.radius - 12, style: .continuous).fill(Color.black)
                .padding(12)
                .shadow(color: .black.opacity(0.25), radius: 25, y: 25)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
    }

    // MARK: Input row

    private var inputRow: some View {
        return HStack(spacing: M.inputGap) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(CDS.Text.muted)
                .frame(width: M.icon, height: M.icon)
                .padding(.leading, -4)
                .padding(.trailing, 4)
                .accessibilityHidden(true)
            PaletteField(model: palette, placeholder: palette.placeholder, text: palette.query)
                .frame(height: M.fieldHeight)
            Button { palette.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CDS.Text.muted)
                    .frame(width: M.closeSize, height: M.closeSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverFillButtonStyle(shape: RoundedRectangle(cornerRadius: CDS.Density.comfortable.radius, style: .continuous),
                                              rest: .clear, hover: CDS.Fill.ghostHover))
            .accessibilityLabel("Close")
            .focusable(false)
        }
        .padding(M.inputPad)
    }

    // MARK: List

    /// What the list lays out: group headers and rows, flat, so only the rows near the window are made.
    private enum Entry: Identifiable {
        case header(id: String, title: String, first: Bool)
        case hit(PaletteHit)
        case action(PaletteAction)

        var id: String {
            switch self {
            case .header(let id, _, _): "header:" + id
            case .hit(let hit): hit.id
            case .action(let action): action.id
            }
        }

        var height: CGFloat {
            switch self {
            case .header(_, _, let first): CDS.Palette.header + (first ? 0 : CDS.Palette.groupGap)
            case .hit, .action: CDS.Palette.row
            }
        }
    }

    private var entries: [Entry] {
        switch palette.page {
        case .actions:
            return palette.actionRows.map(Entry.action)
        case .list:
            var result: [Entry] = []
            for section in palette.sections {
                if let title = section.title { result.append(.header(id: section.id, title: title, first: result.isEmpty)) }
                else if !result.isEmpty { result.append(.header(id: section.id, title: "", first: false)) }
                result += section.hits.map(Entry.hit)
            }
            return result
        }
    }

    @ViewBuilder
    private func list(_ layout: PaletteLayout) -> some View {
        let entries = entries
        let content = entries.reduce(0) { $0 + $1.height } + M.listPad * 2
        let height = entries.isEmpty ? M.empty : layout.listHeight(content: content, footer: !palette.footerCollapsed)
        if entries.isEmpty {
            PaletteEmpty().frame(height: height)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // The probe whose position says whether the content has scrolled under the top edge.
                        Color.clear.frame(height: 0)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("palette-scroll")).minY } action: { offset in
                                // Rows moved under the pointer: it has to move again before it selects.
                                palette.listScrolled(offset: offset)
                                if scrolled != (offset < -0.5) { scrolled = offset < -0.5 }
                            }
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in row(entry) }
                        }
                        .padding(M.listPad)
                    }
                }
                .coordinateSpace(name: "palette-scroll")
                .scrollIndicators(.automatic)
                .frame(height: height)
                .overlay(alignment: .top) { scrollShadow }
                .onChange(of: palette.scroll) { _, request in
                    guard let request else { return }
                    reveal(request.id, entries: entries, proxy: proxy)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Results")
            }
        }
    }

    /// `0 2px 8px black 6%` along the top edge, once the list has scrolled under it.
    private var scrollShadow: some View {
        Rectangle().fill(Color.clear).frame(height: 0)
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            .opacity(scrolled ? 1 : 0)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry {
        case .header(_, let title, let first):
            PaletteHeader(title: title, first: first)
        case .hit(let hit):
            PaletteRow(hit: hit, selected: hit.id == palette.selection, glyph: icon(hit.item.icon))
                .equatable()
                .id(hit.id)
                .onContinuousHover(coordinateSpace: .named("palette-scroll")) { phase in
                    if case .active(let point) = phase { palette.pointer(over: hit.id, at: point) }
                }
                .onTapGesture { palette.pick(hit.id) }
        case .action(let action):
            PaletteActionRow(action: action, selected: action.id == palette.selection)
                .equatable()
                .id(action.id)
                .onContinuousHover(coordinateSpace: .named("palette-scroll")) { phase in
                    if case .active(let point) = phase { palette.pointer(over: action.id, at: point) }
                }
                .onTapGesture { palette.pick(action.id) }
        }
    }

    /// The icon of an item: its glyph for a session, else its symbol.
    private func icon(_ icon: PaletteIcon) -> PaletteGlyph {
        switch icon {
        case .symbol(let name, let tint): PaletteGlyph(symbol: name, tint: tint, session: nil)
        case .session(let id): PaletteGlyph(symbol: "bubble.left", tint: nil, session: store.sessionRow(id))
        }
    }

    /// Scrolls `id` (or the top) into view by the least that shows it, and a first row with its header.
    private func reveal(_ id: String?, entries: [Entry], proxy: ScrollViewProxy) {
        guard let id else {
            if let first = entries.first { proxy.scrollTo(first.id, anchor: .top) }
            return
        }
        // A group's first row is scrolled to with its header above it.
        if let i = entries.firstIndex(where: { $0.id == id }), i > 0, case .header = entries[i - 1] {
            proxy.scrollTo(entries[i - 1].id)
        }
        proxy.scrollTo(id)
    }
}

// MARK: Pieces

/// The leading glyph of a row, and what draws it.
struct PaletteGlyph {
    let symbol: String
    let tint: Color?
    let session: AgentRow?
}

/// A group's title: caption, muted.
private struct PaletteHeader: View {
    let title: String
    let first: Bool

    var body: some View {
        Text(title)
            .cdsText(CDS.paletteCaption, .regular, CDS.Text.muted)
            .padding(.horizontal, M.headerPadX)
            .padding(.top, 12 + (first ? 0 : M.groupGap))
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, minHeight: M.header + (first ? 0 : M.groupGap),
                   maxHeight: M.header + (first ? 0 : M.groupGap), alignment: .topLeading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHidden(title.isEmpty)
    }
}

/// One result: its icon with the status dot, the title with the matched letters bold, a muted subtitle, and at the end a
/// short time (↩ on the selected row). Redrawn only when it changes or is (de)selected.
private struct PaletteRow: View, Equatable {
    let hit: PaletteHit
    let selected: Bool
    let glyph: PaletteGlyph

    static func == (a: PaletteRow, b: PaletteRow) -> Bool {
        a.selected == b.selected && a.hit.ranges == b.hit.ranges && a.hit.item.id == b.hit.item.id
            && a.hit.item.title == b.hit.item.title && a.hit.item.subtitle == b.hit.item.subtitle
            && a.hit.item.date == b.hit.item.date && a.hit.item.dot == b.hit.item.dot
            && a.hit.item.icon.sameLook(b.hit.item.icon) && a.glyph.session == b.glyph.session
    }

    var body: some View {
        let item = hit.item
        HStack(spacing: M.rowGap) {
            HStack(spacing: M.contentGap) {
                PaletteIconView(glyph: glyph, dot: item.dot)
                HStack(alignment: .firstTextBaseline, spacing: M.contentGap) {
                    Text(Self.title(item.title, ranges: hit.ranges, selected: selected))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .cdsText(CDS.Density.comfortable.footnote, .regular, CDS.Text.muted)
                            .font(CDS.sans(12))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if selected {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CDS.Text.muted)
                    .frame(width: 16, height: 16)
            } else if let label = PaletteTime.label(item.date) {
                Text(label).font(CDS.sans(12)).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, M.rowPadX)
        .frame(height: M.row)
        .background(selected ? CDS.Fill.ghostHover : Color.clear, in: RoundedRectangle(cornerRadius: M.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The title in the row's ink, the matched letters semibold and primary.
    static func title(_ title: String, ranges: [Range<String.Index>], selected: Bool) -> AttributedString {
        var text = AttributedString(title)
        text.font = CDS.sans(CDS.Palette.fontSize)
        text.foregroundColor = selected ? CDS.Text.primary : CDS.Text.secondary
        for range in ranges {
            guard let found = Range(range, in: text) else { continue }
            text[found].font = CDS.sans(CDS.Palette.fontSize, .semibold)
            text[found].foregroundColor = CDS.Text.primary
        }
        return text
    }
}

/// One action of the actions page: its symbol, its title (red when it removes something) and the keycaps that do the same
/// outside the palette.
private struct PaletteActionRow: View, Equatable {
    let action: PaletteAction
    let selected: Bool

    static func == (a: PaletteActionRow, b: PaletteActionRow) -> Bool {
        a.selected == b.selected && a.action.id == b.action.id && a.action.title == b.action.title
            && a.action.symbol == b.action.symbol && a.action.caps == b.action.caps && a.action.destructive == b.action.destructive
    }

    var body: some View {
        let ink = action.destructive ? CDS.Text.danger : (selected ? CDS.Text.primary : CDS.Text.secondary)
        HStack(spacing: M.rowGap) {
            HStack(spacing: M.contentGap) {
                Image(systemName: action.symbol ?? "circle.fill")
                    .font(.system(size: action.symbol == nil ? 4 : 14, weight: .medium))
                    .foregroundStyle(action.destructive ? CDS.Text.danger : CDS.Text.muted)
                    .frame(width: M.icon, height: M.icon)
                Text(action.title).font(CDS.sans(M.fontSize)).foregroundStyle(ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !action.caps.isEmpty { Keycaps(caps: action.caps.map(PaletteCaps.glyph), ink: CDS.Keycap.ink) }
        }
        .padding(.horizontal, M.rowPadX)
        .frame(height: M.row)
        .background(selected ? CDS.Fill.ghostHover : Color.clear, in: RoundedRectangle(cornerRadius: M.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A row's icon: 20pt, a session's own glyph or a symbol, and the status dot at its corner with the icon cut out around it.
private struct PaletteIconView: View {
    let glyph: PaletteGlyph
    let dot: PaletteDot?

    var body: some View {
        Group {
            if let row = glyph.session {
                SessionGlyph(row: row, size: M.icon, dot: false)
            } else {
                Image(systemName: glyph.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(glyph.tint ?? CDS.Text.muted)
                    .frame(width: M.icon, height: M.icon)
            }
        }
        .frame(width: M.icon, height: M.icon)
        .mask {
            if dot == nil {
                Rectangle()
            } else {
                // `radial-gradient(circle at (100% − r + 1, r − 1), transparent r + 2, black r + 2.5)`, r = 3.
                let r = M.dot / 2
                ZStack(alignment: .topLeading) {
                    Rectangle()
                    Circle().frame(width: (r + 2) * 2, height: (r + 2) * 2)
                        .offset(x: M.icon - r + 1 - (r + 2), y: r - 1 - (r + 2))
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
        }
        .overlay(alignment: .topTrailing) {
            if let dot {
                Circle().fill(Self.color(dot))
                    .frame(width: M.dot, height: M.dot)
                    .offset(x: 1, y: -1)
            }
        }
        .accessibilityHidden(true)
    }

    /// Waiting for you, failed, unread: blue (`#2a78d6`); working: orange (`#c6613f`).
    static func color(_ dot: PaletteDot) -> Color {
        switch dot {
        case .attention: CDS.Fill.accent
        case .running: CDS.hex(0xC6613F)
        }
    }
}

/// "No results", for a palette with nothing to list.
private struct PaletteEmpty: View {
    var body: some View {
        Text("No results found")
            .font(CDS.sans(CDS.Palette.fontSize))
            .foregroundStyle(CDS.Text.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("No results")
    }
}

/// The footer: what the keys do, as caption text and keycaps (§1.6).
private struct PaletteFooter: View {
    let page: PaletteModel.Page

    var body: some View {
        HStack(spacing: M.hintGap) {
            hint("Select", ["↑", "↓"])
            switch page {
            case .list:
                hint("Open", ["↩"])
                hint("Actions", ["Tab"])
            case .actions:
                hint("Run", ["↩"])
            }
            Spacer(minLength: 0)
            hint(page == .list ? "Close" : "Back", ["Esc"])
        }
        .frame(minHeight: 20)
        .padding(M.footerPad)
        .background(CDS.Surface.s3)
        .overlay(alignment: .top) { Rectangle().fill(CDS.border).frame(height: CDS.hairline) }
    }

    private func hint(_ label: String, _ caps: [String]) -> some View {
        HStack(spacing: CDS.Palette.contentGap) {
            Text(label).cdsText(CDS.paletteCaption, .regular, CDS.Text.muted)
            Keycaps(caps: caps, ink: CDS.Keycap.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(caps.joined(separator: " "))")
    }
}

/// A row's date as the short label Claude's palette gives it (§1.5): "Just now" … "Past year", nothing older.
enum PaletteTime {
    static func label(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let age = now.timeIntervalSince(date)
        if age < 0 { return "Just now" }
        if age < 5 * 60 { return "Just now" }
        if age < 3600 { return "Past hour" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if age < 7 * 86_400 { return "Past week" }
        if age < 30 * 86_400 { return "Past month" }
        if age < 365 * 86_400 { return "Past year" }
        return nil
    }
}

extension PaletteIcon {
    /// Whether two icons draw the same (a session's glyph aside, which `PaletteRow` compares by its row).
    func sameLook(_ other: PaletteIcon) -> Bool {
        switch (self, other) {
        case (.symbol(let a, let tintA), .symbol(let b, let tintB)): a == b && tintA == tintB
        case (.session(let a), .session(let b)): a == b
        default: false
        }
    }
}

/// The palette's keycaps are glyphs where the key has one (↩, ⌫), as the footer's are; the rest keep their names.
enum PaletteCaps {
    static func glyph(_ cap: String) -> String {
        switch cap {
        case "Return", "Enter", "⏎": "↩"
        case "Delete", "Backspace": "⌫"
        case "Forward Delete": "⌦"
        case "Escape": "Esc"
        default: cap
        }
    }
}
