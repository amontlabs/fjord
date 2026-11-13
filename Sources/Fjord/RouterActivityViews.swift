import SwiftUI

// A thread's subagents, background commands and waits (docs/design/router-v2/DESIGN.md 1.4, 1.5, 1.6): on the line, a
// few muted glyphs at the end of the sentence's place, a count beside one only when it is more than one; the pointer on them shows a
// read-only peek listing each; the open card lists them under its steps.

extension Router {
    enum Activity {
        static let subagent = "person.2"
        static let process = "terminal"
        static let wait = "hourglass"
        /// The glyphs on the line: 10 pt, the line's muted ink.
        static let glyph: CGFloat = 10
        /// Between a glyph and its count, and between groups.
        static let countGap: CGFloat = 2
        static let groupGap: CGFloat = 7
        /// The least room between the sentence's words and the glyphs.
        static let lead: CGFloat = 8
        /// The rows' glyph column.
        static let glyphBox: CGFloat = 14
    }
}

extension RouterModel {
    /// The line whose activity peek shows: the pointer is on its glyphs, and its card (which lists the same) isn't open.
    /// A working line's glyphs are in its one working peek (`peeked`, RouterWorkViews.swift).
    var activityPeeked: String? {
        guard case .activity(let id)? = hoverControl, selection != .line(id), let t = thread(id), !t.activity.isEmpty,
              !t.peeksWork else { return nil }
        return id
    }
}

extension View {
    /// The line's sentence with the thread's activity glyphs pinned at the end of its place, right before the project
    /// pill and the age: they hold still as the sentence changes. The words give way first: the glyphs never truncate.
    func routerActivity(_ model: RouterModel, _ thread: RouterThread) -> some View {
        modifier(RouterActivityTrail(model: model, thread: thread))
    }
}

private struct RouterActivityTrail: ViewModifier {
    let model: RouterModel
    let thread: RouterThread

    func body(content: Content) -> some View {
        HStack(spacing: Router.Activity.lead) {
            // The sentence takes the rest of the place, so the glyphs sit at its end whatever its words' width.
            content.frame(maxWidth: .infinity, alignment: .leading)
            if !thread.activity.isEmpty {
                RouterActivityMark(model: model, thread: thread.id, activity: thread.activity)
                    .fixedSize()
                    .layoutPriority(1)
                    .transition(.opacity)
            }
        }
        .motion(.fade, value: thread.activity.isEmpty)
    }
}

/// `person.2 2  terminal  hourglass`: one glyph per kind there is, its count after it when more than one. Muted, no
/// ground; the pointer on it brightens it to the secondary ink and shows the peek.
struct RouterActivityMark: View {
    let model: RouterModel
    let thread: String
    let activity: RouterActivity
    @Environment(\.accessibilityReduceMotion) private var reduce

    private typealias A = Router.Activity

    var body: some View {
        let hot = model.flags(.activity(thread)).hot
        HStack(spacing: A.groupGap) {
            group(A.subagent, activity.agents.count)
            group(A.process, activity.processes.count)
            group(A.wait, activity.waits.count)
        }
        .foregroundStyle(hot ? CDS.Text.secondary : CDS.Text.muted)
        .hoverMotion(hot)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .routerTarget(model, .activity(thread))
        .motion(.fade, value: activity.agents.isEmpty)
        .motion(.fade, value: activity.processes.isEmpty)
        .motion(.fade, value: activity.waits.isEmpty)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.summary)
    }

    @ViewBuilder private func group(_ symbol: String, _ count: Int) -> some View {
        if count > 0 {
            HStack(spacing: A.countGap) {
                Image(systemName: symbol).font(.system(size: A.glyph, weight: .medium))
                if count > 1 {
                    Text(verbatim: "\(count)").font(CDS.sans(11)).monospacedDigit()
                        .contentTransition(reduce ? .opacity : .numericText())
                        .motion(reduce ? .easeOut(duration: 0.12) : Router.counts, value: count)
                }
            }
            .transition(.opacity)
        }
    }
}

/// Each subagent (name · model · how long), each background command (in mono · how long), each wait (what · how long).
/// The peek's rows at body size, the card's at footnote size.
struct RouterActivityRows: View {
    let model: RouterModel
    let activity: RouterActivity
    /// The card's: footnote size, the muted ink, as its steps.
    var compact = false

    private typealias A = Router.Activity

    var body: some View {
        let _ = model.clock.minute
        VStack(alignment: .leading, spacing: compact ? 5 : 6) {
            ForEach(activity.agents) { a in
                row(A.subagent, Text(a.name), meta: [a.model.map(RouterActivity.modelName), age(a.since)])
            }
            ForEach(activity.processes) { p in
                row(A.process, Text(p.command).font(p.mono ? CDS.mono(compact ? 11 : 12) : nil), meta: [age(p.since)])
            }
            ForEach(activity.waits) { w in
                row(A.wait, Text(what(w)).font(w.mono ? CDS.mono(compact ? 11 : 12) : nil), meta: [age(w.since)])
            }
        }
    }

    private func what(_ w: RouterActivity.Wait) -> String {
        guard w.kind == .thread else { return w.what }
        return w.thread.flatMap { model.thread($0)?.name } ?? w.what
    }

    private func age(_ since: Date?) -> String? {
        since.map { BriefAge.short(model.now.timeIntervalSince($0)) }
    }

    private func row(_ symbol: String, _ text: Text, meta: [String?]) -> some View {
        let d = CDS.Density.compact
        let size = compact ? d.footnote : d.body
        let meta = meta.compactMap { $0 }.joined(separator: " · ")
        // The card's glyphs sit under the line's mark, hung left of the card's column (`Router.Card.hang`).
        return HStack(spacing: compact ? Router.Card.glyphGap : 8) {
            Image(systemName: symbol).font(.system(size: compact ? 9 : 10, weight: .medium)).foregroundStyle(CDS.Text.muted)
                .frame(width: compact ? Router.Card.glyphBox : A.glyphBox)
            text.cdsText(size, .regular, compact ? CDS.Text.muted : CDS.Text.primary).lineLimit(1).truncationMode(.tail)
            if !meta.isEmpty {
                Spacer(minLength: 8)
                Text(meta).font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
            }
        }
    }
}

/// The activity glyphs' peek: read-only, the page's floating shell, its rows.
struct RouterActivityPeek: View {
    let model: RouterModel
    let thread: RouterThread

    var body: some View {
        RouterActivityRows(model: model, activity: thread.activity)
            .padding(Router.Peek.pad)
            .frame(width: Router.Peek.width, alignment: .leading)
            .routerFloating(radius: Router.Peek.radius)
            .allowsHitTesting(false)
    }
}
