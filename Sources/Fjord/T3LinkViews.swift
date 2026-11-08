import SwiftUI

/// Under the Router's header: the T3 link needing a look (nothing when it is fine or on its way).
struct T3Notice: View {
    let store: Store

    var body: some View {
        let status = store.t3.status
        if status.isProblem || status == .notLinked {
            Text(status.text)
                .font(Theme.Typography.meta)
                .foregroundStyle(status.isProblem ? Theme.red : Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Space.xs)
                .accessibilityLabel(status.text)
        }
    }
}

/// The link's rows in Settings: its state and button, then what the Router's models used.
struct T3SettingsRows: View {
    let store: Store

    var body: some View {
        let link = store.t3
        let status = link.status
        SettingsRow("T3 Code", description: description(status),
                    info: ("T3 Code", "Fjord reads your threads from the T3 Code app on this Mac and sends your words to them. Linking asks T3 for a token that can read and act on threads, and keeps it in your Keychain. Unlink forgets it here; T3's own settings can revoke the session.")) {
            if status != .notInstalled {
                if status.isConnected {
                    ActionButton("Unlink") { link.unlink() }
                } else if status == .linking {
                    ProgressView().controlSize(.small)
                } else if status == .notLinked || status == .tokenRejected || status.isMintFailure {
                    ActionButton("Link to T3") { Task { await link.link() } }
                }
            }
        }
        SettingsRail {
            SettingsStatusLine(text: status.text, color: color(status))
        }
        SettingsDivider()
        ModelUsageRows(store: store)
    }

    private func description(_ status: T3LinkStatus) -> String? {
        status == .notInstalled ? "Install T3 Code to use the Router" : nil
    }

    private func color(_ status: T3LinkStatus) -> Color {
        if status.isConnected { return Theme.green }
        if status.isProblem { return Theme.red }
        return Theme.tertiary
    }

}

extension T3LinkStatus {
    var isMintFailure: Bool { if case .mintFailed = self { true } else { false } }
}

/// What the Router's model calls used (`ModelUsageLog`): today, the last 7 days or all time, per model, as plain numbers.
struct ModelUsageRows: View {
    let store: Store
    @State private var span = ModelUsageLog.Span.today
    @State private var entries: [ModelUsageLog.Entry] = []

    var body: some View {
        let totals = ModelUsageLog.totals(entries, now: Date())[span] ?? [:]
        SettingsRow("Model usage", info: ("Model usage", "Every call the Router makes: the decider (Sonnet), the thread cards and briefs (Haiku) through Claude Code on your subscription, and Jev. Cost is Claude Code's own figure at API prices when it gives one, else the API price estimate; Jev's is his input tokens at $0.042 per million.")) {
            Picker("", selection: $span) {
                ForEach(ModelUsageLog.Span.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityLabel("Span")
        }
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(["", "Calls", "Input", "Cache read", "Cache write", "Output", "Cost"], id: \.self) { h in
                    Text(h).font(CDS.sans(11, .medium)).foregroundStyle(CDS.Text.muted)
                        .gridColumnAlignment(h.isEmpty ? .leading : .trailing)
                }
            }
            ForEach(ModelUsageLog.Role.allCases, id: \.self) { role in
                let t = totals[role] ?? ModelUsageLog.Totals()
                GridRow {
                    Text(role.title).font(CDS.sans(12)).foregroundStyle(CDS.Text.primary).gridColumnAlignment(.leading)
                    ForEach([Self.count(t.calls), Self.tokens(t.input), Self.tokens(t.cacheRead), Self.tokens(t.cacheWrite),
                             Self.tokens(t.output), Self.cost(t.cost)], id: \.self) { v in
                        Text(v).font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model usage, \(span.rawValue)")
        SettingsNote("Cost is an API price estimate; on your subscription it is not billed per call.")
            .task { entries = await Self.load(store) }
    }

    static func load(_ store: Store) async -> [ModelUsageLog.Entry] {
        if let shown = store.modelUsageShown { return shown }
        guard let log = ModelUsageLog.shared else { return [] }
        return await Task.detached(priority: .utility) { log.entries() }.value
    }

    static func count(_ n: Int) -> String { n == 0 ? "–" : "\(n)" }

    /// `840`, `12.4k`, `3.1M`.
    static func tokens(_ n: Int) -> String {
        if n == 0 { return "–" }
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    static func cost(_ c: Double) -> String {
        if c == 0 { return "–" }
        return c < 0.01 ? String(format: "$%.4f", c) : String(format: "$%.2f", c)
    }
}
