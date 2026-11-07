import AppKit
import SwiftUI

// Claude's design system (CDS) as the Claude desktop app's Code tab uses it, dark mode, read from Claude's own shipped
// code (see docs/design/spec/). Every value here is traced there; the views that copy a Claude component use these and
// nothing else. 1 CSS px = 1 pt.

enum CDS {
    // MARK: Colour (dark)

    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Brand.map(Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255,
                        opacity: a))
    }

    /// A colour the same in both looks, for a fill that carries its own ink (a count badge): the light look's mapping is
    /// made for text and would turn a bright fill dark.
    static func solid(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// The neutral alpha steps: white in dark mode.
    static func alpha(_ a: Double) -> Color { Brand.ink.opacity(a) }

    enum Surface {
        static let s0 = hex(0x0B0B0B)
        /// The page and the transcript.
        static let s1 = hex(0x151515)
        static let s2 = hex(0x1A1A19)
        /// Popovers, menus, tooltips, the composer card.
        static let s3 = hex(0x20201F)
        /// The sidebar: the page mixed 80% with black.
        static let sidebar = hex(0x111111)
    }

    enum Text {
        static let primary = hex(0xF0EFEC)
        static let secondary = hex(0xC3C2B7)
        static let muted = hex(0x898781)
        static let disabled = alpha(0.35)
        static let accent = hex(0x6DA7EC)
        static let warning = hex(0xDB9300)
        static let danger = hex(0xEC7E7E)
        static let onPrimary = hex(0x0B0B0B)
    }

    enum Fill {
        static let field = alpha(0.05)
        static let neutral = alpha(0.05)
        static let secondary = alpha(0.10)
        static let secondaryHover = alpha(0.14)
        static let ghostHover = alpha(0.075)
        static let ghostSelected = alpha(0.15)
        static let control = alpha(0.10)
        static let primary = Brand.ink
        static let primaryHover = hex(0xE1E0D9)
        static let accent = hex(0x2A78D6)
        static let warning = hex(0xFAB219)
        static let danger = hex(0xD03B3B)
        static let dangerHover = hex(0xE34948)
        static let accentHover = hex(0x3987E5)
    }

    static let border = alpha(0.10)
    static let borderStrong = alpha(0.20)
    static let borderStronger = alpha(0.40)

    /// The Code tab's approval cards in the transcript (forms-buttons.md §1A–§3, comfortable): the card shell, the
    /// question card's 20pt mark and the receipt.
    enum Approval {
        static let maxWidth: CGFloat = 480
        /// `rounded-card`; the receipt is `rounded-lg`.
        static let radius: CGFloat = 12
        static let receiptRadius: CGFloat = 8
        static let pad = Density.comfortable.pad
        static let gap = Density.comfortable.gap
        /// `--cds-checkbox`, the checkbox's radius.
        static let mark: CGFloat = 20
        static let checkboxRadius: CGFloat = 5
        /// The card header's `min-h-[24px]`.
        static let headerMinHeight: CGFloat = 24
    }

    /// CDS Shortcut keycaps (§4.6): 18pt caps, radius 4, ink gray-300 (a solid button's own text colour inside it).
    enum Keycap {
        static let size: CGFloat = 18
        static let radius: CGFloat = 4
        static let ink = hex(0xA5A49A)
    }
    static let clay = hex(0xD97757)

    enum Git {
        static let added = hex(0x32D74B)
        static let removed = hex(0xFF2C56)
        static let modified = hex(0xFFD014)
        static let merged = hex(0xB796FF)
        static let closed = hex(0xFF6159)
    }

    // MARK: Composer (Code tab's picker-row card, composer-overlays.md §3–§7)

    enum Composer {
        /// The card: `--cds-radius-composer` as the Code tab overrides it, `--cmp-pad-x` / `py-2`, the 28 pt control row.
        static let radius: CGFloat = 14
        static let pad: CGFloat = 8
        static let row: CGFloat = 28
        static let minHeight: CGFloat = 44
        /// The editor's `pl-[4px]`: text starts 12 from the card's edge.
        static let textInset: CGFloat = 4
        /// `maxHeight: min(24rem, 40svh)`.
        static let maxHeight: CGFloat = 384
        static let maxHeightShare: CGFloat = 0.4
        /// `shadow-composer`: the inset ring (rest / hover and focus) and the drop (rest / focus).
        static let ring = alpha(0.10)
        static let ringHot = alpha(0.20)
        static let drop = Color.black.opacity(0.035)
        static let dropFocus = Color.black.opacity(0.075)
        /// The context strip over the card: `min-h-[40px] p-[8px] rounded-[10px] bg-alpha-1 gap-[5px]`.
        static let stripHeight: CGFloat = 40
        static let stripRadius: CGFloat = 10
        static let stripGap: CGFloat = 5
        /// The dock's `gap-1.5` between strip and card, the chin's `mt-1.5` and its xs row.
        static let dockGap: CGFloat = 6
        static let chinRow: CGFloat = 20
        /// The @-mention popover: Code-tab width, `p-1`, sideOffset from the caret.
        static let mentionWidth: CGFloat = 420
        static let mentionOffset: CGFloat = 24
    }

    /// `shadow-panel`'s two drops (its inset ring is `border`): `0 8px 24px` black 32%, `0 2px 6px` black 20%.
    enum PanelShadow {
        static let far = (color: Color.black.opacity(0.32), radius: CGFloat(12), y: CGFloat(8))
        static let near = (color: Color.black.opacity(0.20), radius: CGFloat(3), y: CGFloat(2))
    }

    /// `shadow-field`'s drop: `0 1px 2px` black 5%.
    static let fieldShadow = Color.black.opacity(0.05)

    // MARK: Density

    /// CDS's two densities: the frame (sidebar, chrome) is compact in the desktop app; dialogs and cards may be comfortable.
    struct Density {
        let radius: CGFloat, radiusComposer: CGFloat, panelRadius: CGFloat
        let control: CGFloat, controlNested: CGFloat, icon: CGFloat
        let pad: (xs: CGFloat, sm: CGFloat, md: CGFloat, lg: CGFloat, xl: CGFloat)
        let gap: (xs: CGFloat, sm: CGFloat, md: CGFloat, lg: CGFloat, xl: CGFloat)
        /// Text roles: size / line height.
        let caption: (CGFloat, CGFloat), footnote: (CGFloat, CGFloat), code: (CGFloat, CGFloat), body: (CGFloat, CGFloat)
        let prose: (CGFloat, CGFloat), heading: (CGFloat, CGFloat), title: (CGFloat, CGFloat)

        static let compact = Density(
            radius: 6, radiusComposer: 12, panelRadius: 10, control: 24, controlNested: 18, icon: 16,
            pad: (4, 6, 8, 12, 20), gap: (6, 8, 12, 20, 32),
            caption: (11, 17), footnote: (12, 15), code: (12, 17), body: (13, 19), prose: (14, 20), heading: (14, 18),
            title: (20, 25))
        static let comfortable = Density(
            radius: 8, radiusComposer: 14, panelRadius: 12, control: 32, controlNested: 22, icon: 20,
            pad: (6, 8, 12, 16, 24), gap: (8, 12, 16, 28, 40),
            caption: (12, 17), footnote: (13, 17), code: (13, 19), body: (14, 20), prose: (16, 24), heading: (15, 20),
            title: (22, 28))
    }

    // MARK: Frame

    /// The Code tab's sidebar, compact density with the hub rail (spec §2): `--df-*` variables.
    enum Sidebar {
        static let rowHeight: CGFloat = 26
        static let rowPadding: CGFloat = 2
        static let rowGap: CGFloat = 4
        static let rowFont: CGFloat = 13
        static let groupFont: CGFloat = 12
        static let leadingSlot: CGFloat = 24
        static let railShift: CGFloat = 4
        static let radius: CGFloat = 6
        static let groupTop: CGFloat = 12
        /// `.df-label-inset`: row padding 2 + iconless pad 8.
        static let labelInset: CGFloat = 10
        static let labelMinHeight: CGFloat = 34
        /// Nav rows: 26 + 0.5 margin = a 26.5 pitch.
        static let navGap: CGFloat = 0.5
        /// Session rows: 26 + 0.5 margin + 1 list gap = a 27.5 pitch.
        static let sessionGap: CGFloat = 1.5
        /// From a group's last row to the next label (MEASURED 11, less the row's own 1.5).
        static let sectionGap: CGFloat = 9.5
        /// Claude's 16pt Anthropicons glyph (wght 533) drawn as an SF Symbol: the point size whose ink matches it.
        static let symbol: CGFloat = 13
        /// The 0.5pt white-10% right edge.
        static let edge: CGFloat = 0.5
        /// A section's categories, one step in from its row: their icons clear the tree guide under the section's own.
        static let treeIndent: CGFloat = 14
        /// The tree guide's stroke.
        static let treeGuide: CGFloat = 1
    }

    /// The Code session pane's title bar (spec §3).
    enum TitleBar {
        /// `header.dframe-header`.
        static let header: CGFloat = 48
        /// `.epitaxy-titlebar`, centred in the header.
        static let bar: CGFloat = 32
        static let endInset: CGFloat = 12
        /// The title's left edge from the content edge, where the origin glyph was (MEASURED).
        static let glyphLeading: CGFloat = 19
        static let button: CGFloat = 26
        static let buttonGap: CGFloat = 4
        /// The project chip (MEASURED on the reference: 17 tall, white 10%).
        static let chipHeight: CGFloat = 17
        static let chipPadding: CGFloat = 5
        static let chipRadius: CGFloat = 5
        static let chipFill = alpha(0.10)
    }

    /// The Code tab's transcript (spec transcript.md): compact density, text 14/20.
    enum Transcript {
        /// §0: `--chat-body` 14 / 20 (body and prose alike).
        static let text: (CGFloat, CGFloat) = (14, 20)
        /// §1: `--max-content-width` (Narrow) and `--chat-gutter`; under a 560 tile the gutter is 16.
        static let measure: CGFloat = 768
        static let gutter: CGFloat = 32
        static let narrowGutter: CGFloat = 16
        /// §1: the sticky top fade strip.
        static let fade: CGFloat = 32
        /// §1: `--chat-item-gap`, `--chat-turn-gap`, AssistantMessage blocks (`compact:gap-4`).
        static let itemGap: CGFloat = 10
        static let turnGap: CGFloat = 15
        static let blockGap: CGFloat = 16
        /// §1 MEASURED (the user turn's hidden action line included): a row's end to the bubble, the bubble to the reply.
        static let userTurnTop: CGFloat = 50
        static let userTurnBottom: CGFloat = 36
        /// §3: `--cds-assistant-message-text-inset`, and the stop: clamp(0, (w − 384) × .175, 56).
        static let textInset: CGFloat = 4
        static func textStop(_ width: CGFloat) -> CGFloat { min(56, max(0, (width - 384) * 0.175)) }
        /// §3 prose: `--_prose-flow` .75em, after a list ×2, `li` margin ×.333, list indent 2em, `li` padding .5em.
        static let flow: CGFloat = 10.5
        static let listIndent: CGFloat = 28
        static let itemFlow: CGFloat = 3.5
        static let itemPad: CGFloat = 7
        /// §3 inline code: .9em mono, white 5%.
        static let codeSize: CGFloat = 12.6
        static let codeFill = alpha(0.05)
        /// §2 the user bubble: 85% measure, 12 × 8, radius 10, white 5%; enters in 0.45 s from 0.92 and 6 down.
        static let bubbleMeasure: CGFloat = 0.85
        static let bubblePadX: CGFloat = 12
        static let bubblePadY: CGFloat = 8
        static let bubbleRadius: CGFloat = 10
        static let bubbleFill = alpha(0.05)
        /// §4 TurnStatus: the 24 row, 4 side padding, the 12 caret box (its glyph ≈ 4 × 7).
        static let statusRow: CGFloat = 24
        static let statusPad: CGFloat = 4
        static let caretBox: CGFloat = 12
        /// §5 the opened step card: `pt-sm pb-xs`, radius 10, cells 8 × 6.
        static let stepCardRadius: CGFloat = 10
        static let cellPadX: CGFloat = 8
        static let cellPadY: CGFloat = 6
        /// §9 summary card: radius 10, `px-md py-xs`, gap 4, a 24 header with `px-xs`.
        static let cardRadius: CGFloat = 10
        static let cardPadX: CGFloat = 8
        static let cardPadY: CGFloat = 4
        /// §7 the working mark: a 20 box, the 7 static dot (20 × .35); the sprite's three dots (MEASURED 3.7, pitch 4.6).
        static let markBox: CGFloat = 20
        static let markDot: CGFloat = 7
        static let markDots: (size: CGFloat, pitch: CGFloat) = (3.7, 4.6)
        /// §7 shimmer: 3 s, the sheen (muted 30% with white).
        static let shimmerPeriod: Double = 3
        static let shimmerPeak = hex(0xDCDBD9)
        /// §8 danger banner.
        static let dangerFill = hex(0x3C0E0E)
        static let dangerRing = hex(0x641919)
    }

    // MARK: Type

    /// Claude's dark-mode weights, set on Anthropic Sans's variable `wght` axis (lighter than the named instances).
    enum Weight: CGFloat {
        case regular = 360, medium = 460, semibold = 540, bold = 560
    }

    /// Fjord's own sans (`Brand.sans`) at a size and Claude's dark weight; the system font
    /// without it. Cached: one NSFont per size and weight.
    static func sans(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        let key = FaceKey(size: size, weight: weight)
        if let cached = fonts[key] { return cached }
        let font = Font(nsSans(size, weight))
        fonts[key] = font
        return font
    }

    static func nsSans(_ size: CGFloat, _ weight: Weight = .regular) -> NSFont {
        let key = FaceKey(size: size, weight: weight)
        if let cached = cache[key] { return cached }
        let font: NSFont
        if let fjord = Brand.sans(size, weight) {
            font = fjord
        } else {
            let w: NSFont.Weight = switch weight { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold }
            font = .systemFont(ofSize: size, weight: w)
        }
        cache[key] = font
        return font
    }

    /// SF Mono, as Claude falls back to (no Anthropic Mono on the Mac).
    static func mono(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        if let fjord = Brand.mono(size, weight) { return fjord }
        return .system(size: size, weight: weight == .regular ? .regular : .medium, design: .monospaced)
    }

    /// A size and weight, as the caches key them: hashed as two numbers, not a string built on every text drawn.
    private struct FaceKey: Hashable {
        let size: CGFloat
        let weight: Weight
    }
    nonisolated(unsafe) private static var cache: [FaceKey: NSFont] = [:]
    /// The SwiftUI fonts made from them, so each text drawn doesn't wrap its NSFont again.
    nonisolated(unsafe) private static var fonts: [FaceKey: Font] = [:]
}

extension View {
    /// A CDS text role: font plus its line height (SwiftUI spacing = line height − the font's own).
    func cdsText(_ role: (CGFloat, CGFloat), _ weight: CDS.Weight = .regular, _ color: Color = CDS.Text.primary) -> some View {
        let font = CDS.nsSans(role.0, weight)
        let natural = font.ascender - font.descender + font.leading
        return self.font(CDS.sans(role.0, weight)).foregroundStyle(color).lineSpacing(max(0, role.1 - natural))
    }
}

// MARK: Island (the hub's shell: the bar and the panels hung from it)

extension CDS {
    /// `--cds-border` drawn as Claude's frame dividers draw it (the sidebar edge, the footer tray): 0.5pt.
    static let hairline: CGFloat = 0.5

    /// CDS Badge, `variant:"neutral"`, `size:"xs"`, compact (global-sidebar-titlebar.md §2.5): the count pill beside a
    /// label. 16 tall, `px-sm` 4, `rounded-chip` 4, white 5%, caption xs 10pt medium in secondary.
    enum Badge {
        static let height: CGFloat = 16
        static let padX: CGFloat = 4
        static let radius: CGFloat = 4
        static let fill = alpha(0.05)
        static let font: CGFloat = 10
        static let ink = Text.secondary
    }

    /// The generic Menu (composer-overlays.md §8), compact: 24 items, `px-2`, `gap-xs`, radius 6; the popup `p-1`,
    /// radius 10, 128–320 wide; a trailing hint `ml-md` in footnote muted; a group label `px-2 py-1` footnote medium muted.
    enum Menu {
        static let item: CGFloat = 24
        static let itemPadX: CGFloat = 8
        static let itemGap: CGFloat = 6
        static let itemRadius: CGFloat = 6
        static let pad: CGFloat = 4
        static let radius: CGFloat = 10
        static let minWidth: CGFloat = 128
        static let maxWidth: CGFloat = 320
        static let hintGap: CGFloat = 8
        static let labelHeight: CGFloat = 23
        /// Separator: `mx-2 my-1 h-px`.
        static let separatorInset: CGFloat = 8
    }

    /// The sidebar's status dots (global-sidebar-titlebar.md §1.7): 6pt.
    enum Dot {
        static let size: CGFloat = 6
    }
}

extension CDS {
    /// A session's tile on the bar, drawn as Claude would: a neutral compact square, radius 6, white
    /// 10% (15% when picked, with a white 20% ring), letters 12 at wght 460, Claude's 6pt status dot as its badge.
    enum Tile {
        static let size: CGFloat = 28
        static let radius: CGFloat = 6
        static let fill = alpha(0.10)
        static let fillSelected = alpha(0.15)
        static let ring = alpha(0.20)
        static let letters: CGFloat = 12
        static let dot: CGFloat = 6
        /// The black gap around the badge dot, against the tile.
        static let dotGap: CGFloat = 2
    }

    /// The session rows' hover controls (global-sidebar-titlebar.md §2.7): 24 × 24, radius 6, 2 apart, 3 from the end;
    /// and a row's second line, footnote 12/15 muted.
    enum RowControl {
        static let size: CGFloat = 24
        static let gap: CGFloat = 2
        static let inset: CGFloat = 3
        static let detail: (CGFloat, CGFloat) = (12, 15)
    }
}

extension CDS {
    /// Claude's Settings pages (settings.md, comfortable): sections, rows, nest cards, rails and the controls on rows.
    enum Settings {
        /// §1.4 the scroll area's `px-xl pt-2 pb-lg`.
        static let pagePadX: CGFloat = 24
        static let pageTop: CGFloat = 8
        static let pageBottom: CGFloat = 16
        /// §2.1 `mb-xl` between sections, `mb-md` under a section's header, `gap-1` title to description.
        static let sectionGap: CGFloat = 40
        static let headerGap: CGFloat = 16
        /// §2.2 a row's `py-md` and its `gap-lg` to the control; `gap-1` label to description.
        static let rowPad: CGFloat = 12
        static let rowGap: CGFloat = 28
        static let labelGap: CGFloat = 4
        /// §2.1 the row divider: 1pt white 5%.
        static let divider = alpha(0.05)
        /// §2.4 nest card: `rounded-card`, a 1pt white-10% inset ring, `padding:"sm"` 12 × 8.
        static let nestRadius: CGFloat = 12
        static let nestPadX: CGFloat = 12
        static let nestPadY: CGFloat = 8
        /// §2.5 rail: 1pt white 20% leading line, `ps-xl`, `gap-md`, `mb-md`.
        static let railLine = alpha(0.20)
        static let railPad: CGFloat = 24
        static let railGap: CGFloat = 16
        /// §2.3 select wrapper `w-[160px]`; §3.1 text input `w-56`.
        static let selectWidth: CGFloat = 160
        static let fieldWidth: CGFloat = 224
        /// §3.1 / §3.2 fields: 32 tall, radius 8, `px-md` (select `px-sm`), white 5%, ring 10% (hover 20%).
        static let field: CGFloat = 32
        static let fieldRadius: CGFloat = 8
        static let fieldPad: CGFloat = 12
        static let fieldRing = alpha(0.10)
        static let fieldRingHover = alpha(0.20)
        /// `--cds-focus-shadow`: a 1pt #0b0b0b gap inside, 1pt accent outside, a 6pt glow; danger for invalid.
        static let focusGap = hex(0x0B0B0B)
        static let focusGlow = Color(.sRGB, red: 24 / 255, green: 79 / 255, blue: 149 / 255, opacity: 0.6)
        static let focusGlowDanger = Color(.sRGB, red: 142 / 255, green: 38 / 255, blue: 38 / 255, opacity: 0.6)
        /// §3.3 switch, base: 36 × 20, knob 16, 120 ms overshoot.
        static let switchSize = CGSize(width: 36, height: 20)
        static let knob: CGFloat = 16
        static let switchTrack = alpha(0.10)
        static let switchTrackHover = alpha(0.20)
        /// §3.4 segmented, contained: 32 tall, track white 5% with 1pt padding, thumb radius 7 white 10%, items 12 padding.
        static let segmentThumbRadius: CGFloat = 7
        static let segmentPad: CGFloat = 12
    }
}

// MARK: Hub rows and shared components (search-tabs-avatars.md §2–§4, composer-overlays.md §8–§9)

extension CDS {
    /// CDS Badge's tinted variants (§3.3), dark. The fill is the TINT hex (what `rgba(…, .75)` composites to).
    enum BadgeTint {
        static let neutralFill = alpha(0.05)
        static let neutralText = Text.secondary
        static let warningFill = hex(0x311A00)
        static let warningText = Text.warning
        static let accentFill = hex(0x032042)
        static let accentText = Text.accent
        static let dangerFill = hex(0x3C0E0E)
        static let dangerText = Text.danger
        static let successFill = hex(0x11260F)
        static let successText = hex(0x55BF50)
        static let violetFill = hex(0x1D1649)
        static let violetText = hex(0xA096EB)
    }

    /// CDS Tooltip (composer-overlays.md §9).
    enum Tooltip {
        static let radius: CGFloat = 6
        static let padX: CGFloat = 8
        static let padY: CGFloat = 3
        static let padYMulti: CGFloat = 6
        static let minHeight: CGFloat = 24
        static let maxWidth: CGFloat = 240
        static let text: (CGFloat, CGFloat) = (13, 18)
        static let offset: CGFloat = 4
        static let delay: Double = 0.3
        /// `shadow-panel-sm` (dark): the 1px white-10% ring, `0 1px 2px` black 6%, `0 2px 8px` black 24%.
        static let ring = alpha(0.10)
        static let shadowNear = Color.black.opacity(0.06)
        static let shadowFar = Color.black.opacity(0.24)
    }

    /// CDS Tabs, compact base (§2): 24 tall, 8 padding, 13/19 at 460, radius 6, the pill inset 1 on each side.
    enum Tabs {
        static let height: CGFloat = 24
        static let pad: CGFloat = 8
        static let radius: CGFloat = 6
        static let pillInset: CGFloat = 1
        static let badgeGap: CGFloat = 6
    }

    /// CDS Avatar, compact (§4): xs 16 / sm 20 / md 28 / lg 36; initials 8 / 9 / 12 / 13 at 460.
    enum Avatar {
        static func initialsSize(_ size: CGFloat) -> CGFloat {
            size <= 16 ? 8 : size <= 22 ? 9 : size <= 30 ? 12 : 13
        }
        /// xs shows one initial; the larger sizes two.
        static func initialsCount(_ size: CGFloat) -> Int { size <= 16 ? 1 : 2 }
    }

    /// Ghost icon buttons (forms-buttons.md §4, compact): 24 square, radius 6; the 16pt glyph as an SF Symbol.
    enum GhostIcon {
        static func radius(_ size: CGFloat) -> CGFloat { size >= 28 ? 7 : size <= 20 ? 5 : 6 }
        static func glyph(_ size: CGFloat) -> CGFloat { size >= 28 ? 14 : size <= 22 ? 12 : Sidebar.symbol }
    }
}
