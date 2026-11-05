import SwiftUI

// The CDS controls the Router and Settings draw with: a text area, a button and its keycaps.

// MARK: - Fields

/// CDS TextArea (§5.7): white-5% fill, a 1px white-10% ring (20% on hover), radius 8, 8 × 12, text 14/20, muted placeholder.
struct CDSTextArea: View {
    let placeholder: String
    let lines: ClosedRange<Int>
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let D = CDS.Density.comfortable
        let shape = RoundedRectangle(cornerRadius: D.radius, style: .continuous)
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(CDS.Text.muted), axis: .vertical)
            .textFieldStyle(.plain)
            .cdsBlock(D.body)
            .lineLimit(lines)
            .onSubmit(onSubmit)
            .padding(.vertical, D.pad.sm).padding(.horizontal, D.pad.md)
            .background(shape.fill(CDS.Fill.field))
            .overlay(shape.strokeBorder(hovered && enabled ? CDS.borderStrong : CDS.border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}

// MARK: - Button

/// CDS Button (§4): a paint layer under the label (inset 0.5 for primary and danger), which alone squishes to 0.975 on
/// press and springs back; hover fills; disabled at 40%. Shortcuts show as keycaps 8 after the label, 7 from the edge.
struct ClaudeButton: View {
    enum Variant { case primary, secondary, ghost, danger }

    enum Size {
        case sm, base
        var height: CGFloat { self == .sm ? 28 : 32 }
        var padding: CGFloat { self == .sm ? 10 : 12 }
        var radius: CGFloat { self == .sm ? 7 : 8 }
    }

    let title: String
    var variant: Variant
    var size: Size
    var icon: String?
    var iconOnly = false
    var shortcut: [String]
    var busy: Bool
    let action: () -> Void

    init(_ title: String, primary: Bool = false, variant: Variant? = nil, size: Size = .base, icon: String? = nil,
         shortcut: [String] = [], busy: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.variant = variant ?? (primary ? .primary : .secondary)
        self.size = size
        self.icon = icon
        self.shortcut = shortcut
        self.busy = busy
        self.action = action
    }

    /// Icon only: square at the size's height, the label read out (and shown as the tooltip).
    init(icon: String, label: String, variant: Variant = .ghost, size: Size = .base, action: @escaping () -> Void) {
        self.init(label, variant: variant, size: size, icon: icon, action: action)
        iconOnly = true
    }

    var body: some View {
        Button(action: action) {
            content.opacity(busy ? 0 : 1)
                .overlay { if busy { FjordLoader(color: ink).frame(width: 14, height: 14) } }
        }
        .buttonStyle(CDSButtonStyle(variant: variant, size: size, iconOnly: iconOnly))
        .allowsHitTesting(!busy)
        .accessibilityLabel(title)
        .help(iconOnly ? title : "")
    }

    private var ink: Color {
        switch variant {
        case .primary: CDS.Text.onPrimary
        case .danger: .white
        case .secondary, .ghost: CDS.Text.primary
        }
    }

    @ViewBuilder private var content: some View {
        if iconOnly, let icon {
            ButtonIcon(name: icon, size: 13).foregroundStyle(ink)
        } else {
            let weight: CDS.Weight = variant == .primary || variant == .danger ? .medium : .regular
            HStack(spacing: 4) {
                if let icon {
                    ButtonIcon(name: icon, size: 13).padding(.leading, -4)
                }
                Text(title).cdsText(CDS.Density.comfortable.body, weight, ink).lineLimit(1)
                if !shortcut.isEmpty {
                    CDSShortcut(keys: shortcut, ink: variant == .primary || variant == .danger ? ink : CDS.Keycap.ink)
                        .padding(.leading, 4)
                        // `me-[calc((h − 1em − 6px)/2 − pad)]`: the keycap as far from the right as from the top.
                        .padding(.trailing, (size.height - 18) / 2 - size.padding)
                }
            }
            .foregroundStyle(ink)
        }
    }
}

private struct CDSButtonStyle: ButtonStyle {
    let variant: ClaudeButton.Variant
    let size: ClaudeButton.Size
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, variant: variant, size: size, iconOnly: iconOnly)
    }

    struct Styled: View {
        let configuration: Configuration
        let variant: ClaudeButton.Variant
        let size: ClaudeButton.Size
        let iconOnly: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed && enabled
            let solid = variant == .primary || variant == .danger
            let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
            configuration.label
                .padding(.horizontal, iconOnly ? 0 : size.padding)
                .frame(width: iconOnly ? size.height : nil, height: size.height)
                .background {
                    shape.fill(fill(hovered && enabled))
                        .bakedShadow(variant == .secondary ? CDS.fieldShadow : .clear, .rounded(size.radius), radius: 1, y: 1,
                                     fill: fill(hovered && enabled))
                        .padding(solid ? 0.5 : 0)
                        .scaleEffect(pressed ? 0.975 : 1)
                        .motion(pressed ? .easeOut(duration: 0.06) : .spring(duration: 0.45, bounce: 0.35), value: pressed)
                        .hoverMotion(hovered)
                }
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }

        private func fill(_ hot: Bool) -> Color {
            switch variant {
            case .primary: hot ? CDS.Fill.primaryHover : CDS.Fill.primary
            case .secondary: hot ? CDS.Fill.secondaryHover : CDS.Fill.secondary
            case .ghost: hot ? CDS.Fill.ghostHover : .clear
            case .danger: hot ? CDS.Fill.dangerHover : CDS.Fill.danger
            }
        }
    }
}

/// CDS Shortcut (§4.6): one 18pt keycap per key, 2 apart, modifiers ordered ctrl, alt, shift, cmd; caption text, a 1px
/// border at 22% of the ink, radius 4.
struct CDSShortcut: View {
    let keys: [String]
    var ink: Color = CDS.Keycap.ink

    private static let order = ["ctrl", "alt", "shift", "cmd"]
    private static let glyphs = ["cmd": "⌘", "shift": "⇧", "alt": "⌥", "ctrl": "⌃", "enter": "⏎", "esc": "Esc",
                                 "tab": "⇥", "space": "␣", "backspace": "⌫", "left": "←", "up": "↑", "right": "→", "down": "↓"]

    var body: some View {
        let mods = keys.filter { Self.order.contains($0) }.sorted { Self.order.firstIndex(of: $0)! < Self.order.firstIndex(of: $1)! }
        let rest = keys.filter { !Self.order.contains($0) }
        HStack(spacing: 2) {
            ForEach(Array((mods + rest).enumerated()), id: \.offset) { _, key in
                let glyph = Self.glyphs[key] ?? key.uppercased()
                Text(glyph)
                    .font(glyph.count > 1 ? CDS.sans(12) : .system(size: 12))
                    .foregroundStyle(ink)
                    .padding(.horizontal, glyph.count > 1 ? 3 : 0)
                    .frame(minWidth: CDS.Keycap.size, minHeight: CDS.Keycap.size, maxHeight: CDS.Keycap.size)
                    .overlay(RoundedRectangle(cornerRadius: CDS.Keycap.radius, style: .continuous)
                        .strokeBorder(ink.opacity(0.22), lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Type

extension View {
    /// A CDS text role laid out as CSS does: line spacing between lines, and half the leading over and under, so one line
    /// is the role's full line height.
    func cdsBlock(_ role: (CGFloat, CGFloat), _ weight: CDS.Weight = .regular, color: Color = CDS.Text.primary) -> some View {
        let font = CDS.nsSans(role.0, weight)
        let natural = font.ascender - font.descender + font.leading
        return cdsText(role, weight, color).padding(.vertical, max(0, role.1 - natural) / 2)
    }
}
