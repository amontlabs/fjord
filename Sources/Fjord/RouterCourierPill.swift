import SwiftUI

// The engine's intents as pills over the composer, drawn as the Router's own (`FlightPill`): the mark, your words or what the
// tool does, what it is at, muted. What the engine said about it (a cause, why it waits) is a line under the face, as it
// said it, and the one thing to do about it is the pill's one button.

/// The engine's pills, oldest first (the newest nearest the composer).
struct RouterCourierStack: View {
    let pills: RouterCourierPills
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pills.items) { item in
                RouterCourierPill(pills: pills, item: item)
                    // Rises out of the composer, as your messages do; goes as a fade.
                    .transition(.asymmetric(insertion: reduce ? .opacity : .offset(y: 26).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(.glass, value: pills.items.map { "\($0.id)\($0.state)\($0.acting)\($0.cause ?? "")" })
    }
}

struct RouterCourierPill: View {
    let pills: RouterCourierPills
    let item: RouterCourierPills.Item

    var body: some View {
        let face = RouterCourierPills.face(item)
        if let note = face.note {
            VStack(alignment: .leading, spacing: 0) {
                line(face).padding(.horizontal, 12).frame(height: 34)
                Rectangle().fill(CDS.border).frame(height: 1)
                Text(note).cdsText((13, 18), .regular, CDS.Text.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .flightPillGround()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label(face))
        } else {
            // With a button it spreads to the box's width, as one with a note does; else it hugs its words.
            line(face).padding(.horizontal, 12).frame(height: 34)
                .frame(maxWidth: face.action != nil || face.dismissible ? 560 : nil, alignment: .leading)
                .flightPillGround()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label(face))
        }
    }

    private func label(_ face: RouterCourierPills.Face) -> String {
        [face.words, face.status, face.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func line(_ face: RouterCourierPills.Face) -> some View {
        HStack(spacing: 8) {
            mark(face)
            // Your words get the room first: the place after them truncates before they do.
            Text(face.words).cdsText((13, 18), .regular, face.mark == .working || face.mark == .asks ? CDS.Text.primary : CDS.Text.secondary)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            if !face.status.isEmpty {
                Text(face.status).cdsText((12, 16), .regular, CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                    .id(face.status)
                    .transition(.opacity)
            }
            if face.note != nil || face.action != nil || face.dismissible { Spacer(minLength: 0) }
            if let action = face.action { button(action).fixedSize() }
            if face.dismissible {
                ChipClose(label: item.state == .awaiting ? "Don't allow" : "Dismiss") { pills.dismiss(item.id) }
            }
        }
        .motion(.fade, value: face.status)
    }

    @ViewBuilder private func mark(_ face: RouterCourierPills.Face) -> some View {
        Group {
            switch face.mark {
            case .working: FjordLoader(color: CDS.Text.secondary, label: face.status)
            case .done: symbol("checkmark", .semibold, CDS.Text.accent)
            case .quiet: symbol("checkmark", .semibold, CDS.Text.muted)
            case .warning: symbol("exclamationmark.triangle", .medium, CDS.Text.warning)
            case .paused: symbol("pause.circle", .medium, CDS.Text.warning)
            case .asks: symbol("folder.badge.plus", .medium, CDS.Text.accent)
            }
        }
        .frame(width: 14, height: 14)
    }

    private func symbol(_ name: String, _ weight: Font.Weight, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 11, weight: weight)).foregroundStyle(color)
    }

    @ViewBuilder private func button(_ action: RouterCourierPills.Action) -> some View {
        switch action {
        case .allow:
            ClaudeButton(action.label, primary: true, size: .sm, shortcut: ["↩"]) { pills.perform(action, on: item.id) }
        case .revert:
            ClaudeButton(action.label, variant: .ghost, size: .sm, icon: "arrow.uturn.backward", busy: item.acting) {
                pills.perform(action, on: item.id)
            }
        default:
            ClaudeButton(action.label, variant: .secondary, size: .sm) { pills.perform(action, on: item.id) }
        }
    }
}
