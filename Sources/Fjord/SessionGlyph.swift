import SwiftUI

// A session's face: its glyph and Claude's status dot.

/// A session's face in the Router's lists: the icon Jev picked (else its letters, or an emoji) on a neutral square, in the
/// project's colour, with Claude's status dot on its corner when `dot` is on. Without a session behind it, nothing.
struct SessionGlyph: View {
    let row: AgentRow
    var size: CGFloat = 18
    var dot = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CDS.Tile.radius * size / CDS.Tile.size + 1, style: .continuous)
        let kind = ClaudeDot.Kind(row)
        let emoji = row.label.unicodeScalars.first.map { $0.properties.isEmoji && $0.value > 0xFF } ?? false
        Group {
            if let icon = row.icon {
                Image(systemName: icon).font(.system(size: size * 0.6, weight: .medium)).symbolRenderingMode(.monochrome)
            } else {
                Text(row.label)
                    .font(emoji ? .system(size: size * 0.55) : CDS.sans(size * 0.45, .medium))
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
        }
        .foregroundStyle(row.color ?? CDS.Text.secondary)
        .frame(width: size, height: size)
        .background(shape.fill(CDS.Tile.fill))
        .overlay(alignment: .topTrailing) {
            if dot, kind != .quiet {
                ClaudeDot(kind: kind)
                    .scaleEffect(0.8)
                    .background(Circle().fill(Theme.bg).frame(width: 9, height: 9))
                    .offset(x: 5, y: -5)
            }
        }
        .accessibilityHidden(true)
    }
}

extension ClaudeDot.Kind {
    /// A session's dot, as Claude's list draws it: needs you, done and unread, working (or left something running), else
    /// the quiet hollow ring.
    init(_ row: AgentRow) {
        switch row.group {
        case .needsYou: self = .needsYou
        case .done: self = .done
        case .working: self = .working
        case .idle: self = .quiet
        }
    }
}

/// Claude's session status dot (§1.7), 6pt in a 14pt box: awaiting #fab219 (a question or a plan), ready #2a78d6 (a
/// finished turn), running #898781 blinking (a working session), idle a 1pt hollow ring at 50% (addressed).
struct ClaudeDot: View {
    enum Kind {
        case needsYou, done, working, quiet
    }

    let kind: Kind

    var body: some View {
        ZStack {
            switch kind {
            case .needsYou: Circle().fill(CDS.Fill.warning).frame(width: 6, height: 6)
            case .done: Circle().fill(CDS.Fill.accent).frame(width: 6, height: 6)
            case .quiet: Circle().strokeBorder(CDS.Text.muted, lineWidth: 1).frame(width: 6, height: 6).opacity(0.5)
            case .working: BlinkingDot()
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}
