import SwiftUI

/// What the Router keeps of a session in two lines (RouterLife.swift), under its row, quiet: what it is about overall, then
/// what its latest finished turn did. Nothing at all while it has neither. It reads the store itself, so a row it sits in
/// is not redrawn for it.
struct SessionLinesView: View {
    let store: Store
    let sessionID: String

    var body: some View {
        if let lines = store.sessionLines(sessionID) {
            VStack(alignment: .leading, spacing: 2) {
                if let life = lines.life { line("text.alignleft", "Overall", life, help: "What the session is about overall") }
                if let latest = lines.latest { line("arrow.turn.down.right", "Last turn", latest, help: "What its latest finished turn did") }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func line(_ symbol: String, _ label: String, _ text: String, help: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 9, weight: .medium)).foregroundStyle(CDS.Text.muted).frame(width: 18)
            (Text(label + "  ").font(CDS.sans(12, .medium)) + Text(text))
                .cdsText((12, 16), .regular, CDS.Text.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(help)
        .accessibilityValue(text)
    }
}
