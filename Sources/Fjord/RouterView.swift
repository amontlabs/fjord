import AppKit
import SwiftUI

// What the Router's window is built on (`RouterCodeView` lays it out): the store's side of the Router (the switch, your
// messages, a form's answer through the hook), the window's model (the draft, its chips and @, the thread it replies to),
// the notice of what stands in the way, the needs-you lines and the Working list the bar shows.

/// A brief entry on two short lines, for the bar's panel: the thread and how long it has waited, then what it waits for and
/// its project. Clicking it opens the Router on it.
struct BriefEntryLine: View {
    let entry: BriefEntry
    let store: Store
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let briefs = store.routerBriefs
        let title = briefs.title(entry.target)
        let project = briefs.names[entry.project].flatMap { $0.isEmpty ? nil : $0 } ?? BriefPage.fallbackName(entry.project)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: BriefEntryText.symbol(entry.kind)).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.amber)
                    Text(title).font(Theme.Typography.bodyMedium).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(BriefAge.text(briefs.clock().timeIntervalSince1970 - entry.since))
                        .font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
                Text("\(BriefEntryText.kindLabel(entry)) · \(project)" + (entry.question.map { " · " + $0 } ?? ""))
                    .font(Theme.Typography.meta).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowHighlight(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
        .accessibilityValue("\(BriefEntryText.kindLabel(entry)), \(project)")
        .accessibilityHint("Opens the Router on it")
    }
}
