import SwiftUI

// A working thread's subagents, background commands and waits as rows in its card (docs/design/router-v2/DESIGN.md 1.5
// "Working: activity", R5, R11): under the steps, before the history, at footnote size in the muted ink, their glyphs
// hung in the steps' column under the line's mark, their ages trailing in the line's ages column (relative, the clock
// time under the pointer). The facts' chips that only count them give way to them (`RouterCardActivity.covers`).

struct RouterCardActivity: View {
    let model: RouterModel
    let thread: RouterThread

    private typealias A = Router.Activity
    private typealias M = Router.Card
    private var d: CDS.Density { .compact }

    /// Whether a card lists its thread's activity: a working thread's own card (not an item's), with any.
    static func shows(_ thread: RouterThread, item: RouterItem?) -> Bool {
        item == nil && thread.state == .working && !thread.activity.isEmpty
    }

    /// Whether a fact only counts what the rows list (`2 subagents`, `1 background command`, `waiting on 2`).
    static func covers(_ fact: RouterSummary.Fact, _ activity: RouterActivity) -> Bool {
        switch fact.kind {
        case .agents: !activity.agents.isEmpty
        case .commands: !activity.processes.isEmpty
        case .waits: !activity.waits.isEmpty
        default: false
        }
    }

    var body: some View {
        let a = thread.activity
        VStack(alignment: .leading, spacing: 5) {
            ForEach(a.agents) { agent in
                row(A.subagent, since: agent.since) {
                    Text(agent.name).foregroundColor(CDS.Text.muted)
                        + Text(verbatim: agent.model.map { "  " + RouterActivity.modelName($0) } ?? "")
                        .foregroundColor(CDS.Text.muted.opacity(0.7))
                }
                .accessibilityLabel("Subagent: \(agent.name)" + (agent.model.map { ", " + RouterActivity.modelName($0) } ?? ""))
            }
            ForEach(a.processes) { p in
                row(A.process, since: p.since) {
                    Text(p.command).font(p.mono ? CDS.mono(d.footnote.0 - 1) : CDS.sans(d.footnote.0)).foregroundColor(CDS.Text.muted)
                }
                .accessibilityLabel("Background command: \(p.command)")
            }
            ForEach(a.waits) { w in
                row(A.wait, since: w.since) {
                    Text(what(w)).font(w.mono ? CDS.mono(d.footnote.0 - 1) : CDS.sans(d.footnote.0)).foregroundColor(CDS.Text.muted)
                }
                .accessibilityLabel("Waiting on \(what(w))")
            }
        }
        // The glyphs hang left of the column, under the line's mark; the words start on it, as the steps'.
        .padding(.leading, -M.hang)
        .agesColumn()
        .accessibilityElement(children: .contain)
    }

    /// A wait on another thread reads that thread's name.
    private func what(_ w: RouterActivity.Wait) -> String {
        guard w.kind == .thread else { return w.what }
        return w.thread.flatMap { model.thread($0)?.name } ?? w.what
    }

    private func row<Words: View>(_ symbol: String, since: Date?, @ViewBuilder words: () -> Words) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: M.glyphGap) {
                Image(systemName: symbol).font(.system(size: 9, weight: .medium)).foregroundStyle(CDS.Text.muted)
                    .frame(width: M.glyphBox)
                words().font(CDS.sans(d.footnote.0)).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: M.maxWidth + M.hang, alignment: .leading)
            Spacer(minLength: 8)
            if let since { RouterTimelineAge(model: model, at: since) }
        }
    }
}
