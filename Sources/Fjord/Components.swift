import AppKit
import SwiftUI

// The design system's pieces. Tokens live in `Theme` (Theme.swift); shared components live here.
//
// TOKENS (Theme.swift)
//   Colours   Claude's dark palette (CDS): bg black (the island), raised, hover, stroke, text #f0efec, secondary #c3c2b7,
//             tertiary #898781 (CDS muted), accent, amber, green, red, purple, claude; `Theme.onTint` = text on a tinted fill.
//   Radius    CDS compact: Theme.Radius.xs 4 (keycaps, badges) / sm 6 (menus, tiles) / md 6 (rows, fields, buttons)
//             / lg 10 (cards, popovers: `rounded-card`) / panel 14. All `.continuous`: use `Theme.Radius.shape(_)`.
//   Fill      CDS alpha steps: Theme.Fill.rest 0 / faint .05 / field .05 / hover .075 (ghost hover, highlighted row) /
//             selected .15 / pressed .15 / tile .10 (avatars, `fill-control`). Disabled fades to 40%.
//   Font      Anthropic Sans on CDS compact roles, dark weights (360 / 460 / 540): title 14 medium (heading) / body 13
//             (row text) / meta 12 (labels, second lines: 12/16) / caption 11 / eyebrow 12 (sentence-case labels) /
//             count 12 medium / badge 10 medium (Badge xs). `Theme.Typography.glyph(_ size, weight)` for SF Symbols.
//   Space     Theme.Space.xs 4 / sm 6 / md 8 / lg 12 / xl 16.
//   Metrics   Theme.Metrics.line 30 (header / one-line row), row 36 (session row), bar 46 (bar depth), inset 6 (the
//             one outer inset), field 32, chip 26.
//   Motion    Motion.swift: the tokens instant / release / fade / spatial / glass, each with its Reduce Motion
//             fallback. `.motion(.fade, value:)` replaces `.animation(_:value:)` (Reduce Motion read live from the
//             environment); `.hoverMotion(hovering)` for hover fills (in instantly, out with `release`); elsewhere
//             `withAnimation(Motion.spatial.resolved(reduce: reduce))` or `.transition(.slide(from: .trailing, reduce: reduce))`.
//
// COMPONENTS (this file)
//   HoverFillButtonStyle   (respects isEnabled) `.buttonStyle(HoverFillButtonStyle(...))`: hover/active/pressed fill: in at once, out eased. Use
//                          for every button that fills on hover (rows, icon buttons, chips). Any shape.
//   .rowHighlight(on)      Claude's compact row: 8x5 padding, radius 6, white 7.5% while `on` (hovered or picked).
//   Hairline(axis:inset:)  CDS divider: 0.5pt white 10%. Never `Rectangle().fill(Theme.stroke)`.
//   CountBadge(n, tint:)   CDS Badge xs (16 tall, radius 4, 10pt 460): neutral, or tinted (amber = warning variant).
//   DotCount(n, color:)    A 6pt status dot + number, numeric-text transition; muted when 0 (CI counts, status counts).
//   Eyebrow(title)         Claude's sidebar label: sentence case, 12/16 muted (settings sections, "Working").
//   .tile(size)            Frames a view as a rounded square filled `Fill.tile`, clipped, radius size*0.3.
//   Tile.shape(size)       The same shape, for your own backgrounds / clipping.
//   plural(n, "folder")    "1 folder", "2 folders"; third arg for irregulars: plural(2, "repository", "repositories").

extension Theme {
    /// Claude's (CDS, compact): 6 on controls and rows, 10 on cards (`rounded-card`), 4 on keycaps and badges.
    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 6
        static let lg: CGFloat = 10

        static func shape(_ radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

        /// The radius of a shape `inset` inside one of radius `outer`, so their corners share a centre; never under
        /// `minimum`, so a square outer corner (a full-screen window's) still leaves rounded ones inside.
        static func concentric(_ outer: CGFloat, inset: CGFloat, minimum: CGFloat = sm) -> CGFloat {
            max(minimum, outer - inset)
        }
    }

    /// Translucent white fills, one per state, so hover looks the same everywhere: Claude's alpha steps (dark mode).
    enum Fill {
        static let rest = Color.clear
        static let faint = CDS.alpha(0.05)
        static let field = CDS.alpha(0.05)
        static let hover = CDS.alpha(0.075)
        static let tile = CDS.alpha(0.10)
        static let selected = CDS.alpha(0.15)
        static let pressed = CDS.alpha(0.15)
    }

    /// Claude's type: Fjord's sans (`Brand.sans`, the system font without it) on the CDS compact scale, at Claude's
    /// dark weights; the system font when it isn't there.
    enum Typography {
        /// Page and field titles: CDS heading 14, medium.
        static let title = ui(14, .medium)
        /// Section header titles: Claude's sidebar labels, 12.
        static let heading = ui(12)
        /// Chips, buttons and settings labels: CDS body 13 (tabs set their own 460).
        static let control = ui(13)
        /// Row text, CDS body 13 (wght 360): `bodyMedium` 460, `bodyStrong` 540.
        static let body = ui(13)
        static let bodyMedium = ui(13, .medium)
        static let bodyStrong = ui(13, .semibold)
        /// What Claude and the sessions say: CDS prose.
        static let prose = ui(14)
        /// Secondary info and second lines: `text-xs` 12/16 (sidebar labels, row descriptions).
        static let meta = ui(12)
        /// Hints: CDS caption, compact.
        static let caption = ui(11)
        /// Small section labels ("Pinned", "Needs you"): sentence case, 12, muted, as Claude's sidebar.
        static let eyebrow = ui(12)
        static let eyebrowTracking: CGFloat = 0
        /// Numbers beside dots.
        static let count = ui(12, .medium).monospacedDigit()
        /// Numbers in badges: Badge xs, 10 at 460.
        static let badge = ui(10, .medium).monospacedDigit()

        /// An icon or initials sized off the box that holds it.
        static func glyph(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: size, weight: weight)
        }

        /// Anthropic Sans at a size and weight (`CDS.sans`), or the system font. Claude's dark weights on the variable
        /// font's axis: regular 360, medium 460, semibold 540, bold 560.
        static func ui(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            CDS.sans(size, cds(weight))
        }

        /// The same, for AppKit measuring.
        static func nsUI(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .regular) -> NSFont {
            CDS.nsSans(size, cds(weight))
        }

        private static func cds(_ weight: SwiftUI.Font.Weight) -> CDS.Weight {
            switch weight {
            case .medium: .medium
            case .semibold: .semibold
            case .bold, .heavy, .black: .bold
            default: .regular
            }
        }
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    enum Metrics {
        /// A section header, or a one-line row.
        static let line: CGFloat = 30
        /// A session row.
        static let row: CGFloat = 36
        /// The bar's depth: a cell's width on the sides, the strip's height along the top and bottom.
        static let bar: CGFloat = 46
        /// The one outer inset around the hub's pieces.
        static let inset: CGFloat = 6
        static let field: CGFloat = 32
        static let chip: CGFloat = 26
    }

    /// Text and glyphs on a tinted (amber, green...) fill.
    static let onTint = Color.black.opacity(0.8)
}

extension View {
    /// Claude's compact row (sidebar §2.7, two-line rows §5.1): 8 × 5 padding, radius 6, white 7.5% while `on` (hovered
    /// or picked: as in Claude's palette, hovering moves the pick, one fill for both).
    func rowHighlight(_ on: Bool) -> some View {
        self
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.Radius.shape(Theme.Radius.md).fill(on ? Theme.Fill.hover : Theme.Fill.rest))
            .contentShape(Theme.Radius.shape(Theme.Radius.md))
            .hoverMotion(on)
    }

    /// A rounded square filled like a tile (see `Tile`).
    func tile(_ size: CGFloat, fill: Color = Theme.Fill.tile) -> some View {
        frame(width: size, height: size).background(Tile.shape(size).fill(fill)).clipShape(Tile.shape(size))
    }
}

/// Fills its shape on hover (and a stronger one while `active` or pressed): at once, easing only as the pointer leaves;
/// for `.buttonStyle`.
/// The label keeps its own colours: labels that should change on hover read `@Environment(\.hoverFillHovering)`.
struct HoverFillButtonStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(Theme.Radius.shape(Theme.Radius.md))
    var rest: Color = Theme.Fill.rest
    var hover: Color = Theme.Fill.hover
    var active: Color = Theme.Fill.selected
    var pressed: Color = Theme.Fill.pressed
    var isActive = false

    init(shape: some Shape = Theme.Radius.shape(Theme.Radius.md), rest: Color = Theme.Fill.rest, hover: Color = Theme.Fill.hover,
         active: Color = Theme.Fill.selected, pressed: Color = Theme.Fill.pressed, isActive: Bool = false) {
        self.shape = AnyShape(shape)
        self.rest = rest
        self.hover = hover
        self.active = active
        self.pressed = pressed
        self.isActive = isActive
    }

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, style: self)
    }

    private struct Label: View {
        let configuration: Configuration
        let style: HoverFillButtonStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let hot = enabled && hovering
            let fill = !enabled ? style.rest : configuration.isPressed ? style.pressed : style.isActive ? style.active : hot ? style.hover : style.rest
            configuration.label
                .environment(\.hoverFillHovering, hot)
                .background(style.shape.fill(fill))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(style.shape)
                .onHover { hovering = $0 }
                // In at once, out with `release`; a press is instant both ways (nothing animates it).
                .hoverMotion(hovering)
        }
    }
}

private struct HoverFillHoveringKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside a `HoverFillButtonStyle` label while the pointer is over an enabled button. Read-only for consumers.
    var hoverFillHovering: Bool {
        get { self[HoverFillHoveringKey.self] }
        set { self[HoverFillHoveringKey.self] = newValue }
    }
}

/// Claude's divider: 0.5pt, white 10% (`--cds-border`). `inset` trims both ends.
struct Hairline: View {
    var axis: Axis = .horizontal
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: axis == .vertical ? CDS.hairline : nil, height: axis == .horizontal ? CDS.hairline : nil)
            .padding(axis == .horizontal ? .horizontal : .vertical, inset)
    }
}

/// A count as Claude's Badge (search-tabs-avatars.md §3), compact xs: 16 tall, 4 padding, radius 4, 10pt at 460, tabular.
/// Without a tint, the neutral variant (white 5%, secondary); with one, its tinted variant (amber is CDS warning, the
/// others their colour on a quiet tint of it).
struct CountBadge: View {
    let count: Int
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduce

    init(_ count: Int, tint: Color? = nil) {
        self.count = count
        self.tint = tint
    }

    var body: some View {
        let (fill, ink) = Self.colors(tint)
        Text("\(count)")
            .font(Theme.Typography.badge)
            .foregroundStyle(ink)
            .padding(.horizontal, CDS.Badge.padX)
            .frame(minWidth: CDS.Badge.height, minHeight: CDS.Badge.height)
            .background(RoundedRectangle(cornerRadius: CDS.Badge.radius, style: .continuous).fill(fill))
            .contentTransition(reduce ? .opacity : .numericText(value: Double(count)))
    }

    /// The Badge variant for a tint: fill and text.
    static func colors(_ tint: Color?) -> (Color, Color) {
        switch tint {
        case nil: (CDS.Badge.fill, CDS.Badge.ink)
        case Theme.amber?: (CDS.BadgeTint.warningFill, CDS.BadgeTint.warningText)
        case Theme.accent?: (CDS.BadgeTint.accentFill, CDS.BadgeTint.accentText)
        case Theme.red?: (CDS.BadgeTint.dangerFill, CDS.BadgeTint.dangerText)
        case Theme.green?: (CDS.BadgeTint.successFill, CDS.BadgeTint.successText)
        case Theme.purple?: (CDS.BadgeTint.violetFill, CDS.BadgeTint.violetText)
        case let tint?: (tint.opacity(0.16), tint)
        }
    }
}

/// Claude's 6pt status dot and a number beside it; both go muted at zero.
struct DotCount: View {
    let count: Int
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduce

    init(_ count: Int, color: Color) {
        self.count = count
        self.color = color
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(count == 0 ? Theme.tertiary.opacity(0.5) : color).frame(width: CDS.Dot.size, height: CDS.Dot.size)
            Text("\(count)")
                .font(Theme.Typography.meta.monospacedDigit())
                .foregroundStyle(count == 0 ? Theme.tertiary : Theme.secondary)
                .contentTransition(reduce ? .opacity : .numericText(value: Double(count)))
        }
    }
}

/// A section label as Claude's sidebar draws it ("Pinned", project groups, global §2.6): sentence case, 12/16, muted;
/// a count after it, 4 apart, in the same ink.
struct Eyebrow: View {
    let title: String
    var count: Int? = nil

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let count { Text("\(count)").monospacedDigit() }
        }
        .font(Theme.Typography.eyebrow)
        .tracking(Theme.Typography.eyebrowTracking)
        .foregroundStyle(Theme.tertiary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The rounded square behind avatars, icons and the "+" tile: radius is a fixed share of the size.
enum Tile {
    static let ratio: CGFloat = 0.3
    static func shape(_ size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: size * ratio, style: .continuous)
    }
}

/// "1 folder", "2 folders"; pass the plural for irregular words.
func plural(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
}

/// Says something aloud to VoiceOver: what appears or fails without anyone looking at it. The same words twice within a few
/// seconds are said once (a failure announced where it happens, and again by the pane that shows it).
@MainActor
enum Announce {
    private static var last: (text: String, at: Date)?
    /// Where the words go instead of VoiceOver; the tests replace it (there is no app to post to).
    static var sink: ((String) -> Void)?

    /// A moment after what asked for it, so a window taking the keyboard doesn't talk over it.
    /// `again`: a repeated attempt is news (a refusal at each try), so the same words are said again.
    static func say(_ text: String, again: Bool = false, after delay: Duration = .milliseconds(300)) {
        guard sink != nil || (NSApp != nil && NSWorkspace.shared.isVoiceOverEnabled) else { return }
        if !again, let last, last.text == text, Date().timeIntervalSince(last.at) < 3 { return }
        last = (text, Date())
        if let sink { sink(text); return }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            AccessibilityNotification.Announcement(text).post()
        }
    }

    /// Forgets what was last said, so the tests don't depend on each other.
    static func reset() { last = nil; sink = nil }
}
