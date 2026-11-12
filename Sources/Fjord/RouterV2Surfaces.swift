import SwiftUI

// Router v2's surfaces (docs/design/router-v2/DESIGN.md 1.0): the page's one small system of grounds. Four radii set by
// a thing's height, four neutral fills, a state's tint at two strengths, one ring for the keyboard, one shell for what
// floats. Nothing on the page has an outline: a border is the keyboard's ring or a floating panel's edge, nothing else.
// And the list's own layout, which keeps every row's identity so a line that changes section glides there as itself.

extension RouterV2 {
    enum Surface {
        // MARK: Radii, by the thing's height

        /// Up to 18 tall: a project pill, a PR badge, a setting's chip, the words taken in the composer.
        static let token: CGFloat = 4
        /// 20 to 24 tall: a name's ground, a place, a filter pill, a button, a menu's row, a code block.
        static let control: CGFloat = 6
        /// 28 to 36 tall: a line under the pointer, an option, a banner, the toast, the failure line.
        static let row: CGFloat = 8
        /// The selected line with its card.
        static let card: CGFloat = 12
        /// What floats (the peek, a menu): CDS Menu's.
        static let panel: CGFloat = CDS.Menu.radius

        // MARK: Fills (the neutral ink's alpha steps)

        /// A ground at rest: the selected card, a pill, a chip, the toast, code.
        static let quiet = CDS.Fill.neutral
        /// The pointer on something with no ground of its own.
        static let hover = CDS.Fill.ghostHover
        /// Chosen: a picked option, the lit place, a setting you changed, a button; and the pointer on a quiet ground.
        static let chosen = CDS.Fill.secondary
        /// The pointer on a chosen ground.
        static let chosenHover = CDS.Fill.secondaryHover
        /// Pressed, a menu open from it, the active filter.
        static let pressed = CDS.Fill.ghostSelected

        // MARK: Tints (a state's colour, or the accent for what came from you)

        static let tint: Double = 0.12
        /// Under the pointer, and a setting's glow as your words set it.
        static let tintStrong: Double = 0.24

        // MARK: Keys

        /// A key's glyph beside its act: dimmer than the act's own word, so it reads as a hint.
        static let keyInk = CDS.alpha(0.5)

        // MARK: The keyboard's ring

        static let ringWidth: CGFloat = 1.5
        static let ringGap: CGFloat = 1.5

        // MARK: A line in flight

        /// How far past the row its veil fades out, and how far inside it is whole.
        static let veilOut: CGFloat = 7
        static let veilIn: CGFloat = 4
    }
}

// MARK: - Keys

/// An act's keys as plain glyphs, the way a menu shows them: no cap, no outline. Modifiers first (ctrl, alt, shift, cmd).
struct RouterV2KeyHint: View {
    let keys: [String]
    var ink: Color = RouterV2.Surface.keyInk

    private static let order = ["ctrl", "alt", "shift", "cmd"]
    private static let glyphs = ["cmd": "⌘", "shift": "⇧", "alt": "⌥", "ctrl": "⌃", "enter": "⏎", "esc": "esc",
                                 "tab": "⇥", "space": "␣", "backspace": "⌫", "left": "←", "up": "↑", "right": "→", "down": "↓"]

    var body: some View {
        let mods = keys.filter { Self.order.contains($0) }.sorted { Self.order.firstIndex(of: $0)! < Self.order.firstIndex(of: $1)! }
        let rest = keys.filter { !Self.order.contains($0) }
        HStack(spacing: 1.5) {
            ForEach(Array((mods + rest).enumerated()), id: \.offset) { _, key in
                let glyph = Self.glyphs[key] ?? key.uppercased()
                // A symbol in the system's face (CDS's has no ⌘ ⇧ ⌫); a letter, a digit or a word in the page's.
                Text(glyph)
                    .font(Self.glyphs[key] != nil && glyph.count == 1 ? .system(size: 12) : CDS.sans(glyph.count > 1 ? 11 : 12))
                    .monospacedDigit()
                    .foregroundStyle(ink)
                    .fixedSize()
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}

// MARK: - Ring and shell

/// The keyboard is on this: the page's one ring, the accent, a hair past the thing's edge. Lay it over the thing.
struct RouterV2Ring: View {
    /// The ringed thing's own radius.
    let radius: CGFloat

    var body: some View {
        let s = RouterV2.Surface.self
        let out = s.ringGap + s.ringWidth
        RoundedRectangle(cornerRadius: radius + out, style: .continuous)
            .strokeBorder(CDS.Text.accent, lineWidth: s.ringWidth)
            .padding(-out)
            .allowsHitTesting(false)
    }
}

extension View {
    /// What floats over the page (the peek, a menu): the raised surface, its hairline and one soft shadow. The only
    /// edge on the page that isn't the keyboard's ring: a thing over other things needs one, in the dark look above all.
    /// The shadow is the surface's alone: the words and badges on it cast none.
    func routerV2Floating(radius: CGFloat = RouterV2.Surface.panel) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            shape.fill(CDS.Surface.s3)
                .shadow(color: CDS.PanelShadow.near.color.opacity(0.5), radius: CDS.PanelShadow.near.radius, y: CDS.PanelShadow.near.y)
                .shadow(color: CDS.PanelShadow.far.color.opacity(0.5), radius: CDS.PanelShadow.far.radius, y: CDS.PanelShadow.far.y)
        }
        .overlay(shape.strokeBorder(CDS.border, lineWidth: 1))
    }
}

// MARK: - A line in flight

/// Under a line while it changes section: the words it passes fade out under it and come back behind it. No plate, no
/// edge, no shadow: the page's own ground, whole behind the line's words and fading to nothing a few points past the
/// row, so there is nothing to see of it but the line gliding over clear ground.
struct RouterV2Veil: View {
    var body: some View {
        let s = RouterV2.Surface.self
        GeometryReader { proxy in
            let height = proxy.size.height + 2 * s.veilOut
            let edge = height > 0 ? (s.veilOut + s.veilIn) / height : 0
            LinearGradient(stops: [.init(color: CDS.Surface.s1.opacity(0), location: 0), .init(color: CDS.Surface.s1, location: edge),
                                   .init(color: CDS.Surface.s1, location: 1 - edge), .init(color: CDS.Surface.s1.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height)
                .offset(y: -s.veilOut)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The list's layout

/// The list's rows, top to bottom in the order each one carries (`RouterV2Stack.Order`), not in the order they are
/// declared. The rows are declared in an order that never changes (by id), so a line that changes section is the same
/// view at another place and glides there; in a plain stack a reordered row is taken out and put back in.
struct RouterV2Stack: Layout {
    struct Order: LayoutValueKey {
        static let defaultValue = 0
    }

    /// The rows' heights at a width and their order, measured once per pass: `placeSubviews` takes them from
    /// `sizeThatFits` instead of measuring every row again. Cleared whenever the rows or their inputs change.
    struct Cache {
        var width: CGFloat?
        var heights: [CGFloat] = []
        var order: [Int] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func measure(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) {
        guard cache.width != width || cache.heights.count != subviews.count else { return }
        cache.width = width
        cache.heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        // Each row's order read once (a layout value's lookup is not free), then its rows sorted by it.
        let orders = subviews.map { $0[Order.self] }
        cache.order = subviews.indices.sorted { orders[$0] < orders[$1] }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        measure(width, subviews, &cache)
        return CGSize(width: width, height: cache.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(bounds.width, subviews, &cache)
        var y = bounds.minY
        for i in cache.order {
            let height = cache.heights[i]
            subviews[i].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    /// No alignment guides of its own: without these, every pass asked every row for its guides.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout Cache) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout Cache) -> CGFloat? { nil }
}
