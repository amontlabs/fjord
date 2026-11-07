import SwiftUI

/// Open in T3, the same everywhere: Fjord's own glyph (a thread card with an arrow leaving it), drawn here, so nothing is
/// read from another app's bundle.
enum ThreadMark {
    /// What `ClaudeButton` and the icon buttons take, in place of a symbol's name, for Open in T3.
    static let openSymbol = "fjord.open-in-t3"
}

/// The glyph's outline in a unit square: a rounded card open at its top right, and an arrow going out through the gap.
struct OpenInT3Shape: Shape {
    func path(in rect: CGRect) -> Path {
        let d = min(rect.width, rect.height)
        let o = CGPoint(x: rect.midX - d / 2, y: rect.midY - d / 2)
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: o.x + x * d, y: o.y + y * d) }
        var path = Path()
        // The card: from the top, left of the gap, round the left, bottom and right sides, up to below the gap.
        path.move(to: p(0.46, 0.14))
        path.addLine(to: p(0.24, 0.14))
        path.addArc(tangent1End: p(0.1, 0.14), tangent2End: p(0.1, 0.28), radius: 0.14 * d)
        path.addLine(to: p(0.1, 0.72))
        path.addArc(tangent1End: p(0.1, 0.86), tangent2End: p(0.24, 0.86), radius: 0.14 * d)
        path.addLine(to: p(0.76, 0.86))
        path.addArc(tangent1End: p(0.9, 0.86), tangent2End: p(0.9, 0.72), radius: 0.14 * d)
        path.addLine(to: p(0.9, 0.54))
        // The arrow: its shaft from the card's middle to the corner, and its head.
        path.move(to: p(0.42, 0.58))
        path.addLine(to: p(0.88, 0.12))
        path.move(to: p(0.6, 0.12))
        path.addLine(to: p(0.88, 0.12))
        path.addLine(to: p(0.88, 0.4))
        return path
    }
}

struct OpenInT3Glyph: View {
    /// The box it fills, as a symbol's point size.
    var size: CGFloat = 13

    var body: some View {
        OpenInT3Shape()
            .stroke(style: StrokeStyle(lineWidth: max(1.2, size / 9), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A button's icon: a symbol by name, or Open in T3's glyph for `ThreadMark.openSymbol`.
struct ButtonIcon: View {
    let name: String
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        if name == ThreadMark.openSymbol {
            OpenInT3Glyph(size: size)
        } else {
            Image(systemName: name).font(.system(size: size, weight: weight))
        }
    }
}
