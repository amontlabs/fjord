import SwiftUI

/// Router only: the sessions working now, under what needs you (the bar has no tiles to say so). One line each: the
/// project's colour, the title, what it is doing and for how long (on the minute); a click opens it in Claude.
struct RouterWorkingList: View {
    let store: Store
    /// Rows shown before the rest are counted.
    var limit = 5

    var body: some View {
        let rows = store.routerWorkingRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Eyebrow("Working", count: rows.count).padding(.horizontal, Theme.Space.md).padding(.top, 4).padding(.bottom, 2)
                MinuteTicking { now in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rows.prefix(limit)) { WorkingLine(row: $0, store: store, now: now) }
                    }
                }
                if rows.count > limit {
                    Text("\(rows.count - limit) more").font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, Theme.Space.md)
                }
            }
        }
    }
}

private struct WorkingLine: View {
    let row: ThreadRow
    let store: Store
    let now: Date
    @State private var hover = false

    /// How long, in whole minutes: the lists are redrawn once a minute, so seconds would only ever be wrong.
    private static func minutes(_ t: TimeInterval) -> String {
        let m = max(0, Int(t)) / 60
        if m < 1 { return "<1m" }
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    var body: some View {
        // A turn that is over but left things running: how many, since the oldest of them.
        let start = Store.workingStart(row)
        let since = Self.minutes(now.timeIntervalSince(start ?? now))
        let doing = row.session.running ? row.activity?.text ?? row.session.backgroundStep ?? "Working" : row.tasksText ?? "Working"
        Button { store.openThread(row.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SessionGlyph(row: row, size: 16, dot: false)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(row.session.title).font(Theme.Typography.bodyMedium).foregroundStyle(Theme.text).lineLimit(1)
                    .layoutPriority(1)
                Text(doing).font(Theme.Typography.meta).foregroundStyle(row.session.running ? Theme.secondary : Theme.claude)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(since).font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.claude)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowHighlight(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open in T3") { store.openThread(row.id) }
            if store.canPickIcons && row.entry.label == nil {
                Button(row.entry.icon == nil ? "Pick an icon" : "Pick another icon") { store.repickIcon(row.id) }
            }
        }
        .modifier(RunningTip(tasks: row.tasks))
        .modifier(WorkTip(detail: row.session.running ? row.activity?.detail(branch: row.session.branch, pullRequests: row.session.pullRequests) : nil))
        .accessibilityLabel(row.session.title)
        .accessibilityValue("working, \(row.projectName), \(doing), \(since)")
        .accessibilityHint("Opens it in T3")
    }
}

/// A working thread's task list, files changed, branch and pull requests, in a tooltip (nothing when it has none).
private struct WorkTip: ViewModifier {
    let detail: String?
    func body(content: Content) -> some View {
        if let detail { content.tip("Progress", detail) } else { content }
    }
}

/// What a session left running, by name, in a tooltip (nothing when it left nothing).
private struct RunningTip: ViewModifier {
    let tasks: [BackgroundWork]
    func body(content: Content) -> some View {
        if tasks.isEmpty { content } else { content.tip("Running", tasks.map(\.title).joined(separator: "\n")) }
    }
}
