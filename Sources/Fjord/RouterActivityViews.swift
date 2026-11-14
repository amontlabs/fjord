import SwiftUI

// A thread's subagents, background commands and waits (docs/design/router-v2/DESIGN.md 1.4, 1.6 R5, R11): on the line, a
// few muted glyphs at its trailing end, a count beside one only when it is more than one; the pointer on them shows their
// peek, one row per subagent (title, model, age), background command and wait (`RouterActivityPeek`).

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
        /// The peek's glyph column.
        static let glyphBox: CGFloat = 14
    }
}

extension RouterModel {
    /// The line whose activity peek shows: the pointer is on its glyphs and its card isn't open. On the glyphs it takes
    /// the place of the line's own hover, a working line's too (`peeked`).
    var activityPeeked: String? {
        guard case .activity(let id)? = hoverControl, selection != .line(id), let t = thread(id), !t.activity.isEmpty
        else { return nil }
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
        // On the words' first line, which a sentence that wraps keeps them on (the glyphs' place for the pointer is
        // taller than a line: centred against it, the words sat lower).
        HStack(alignment: .top, spacing: Router.Activity.lead) {
            // The sentence takes the rest of the place, so the glyphs sit at its end whatever its words' width.
            content.frame(maxWidth: .infinity, alignment: .leading)
            if !thread.activity.isEmpty {
                RouterActivityMark(model: model, thread: thread.id, activity: thread.activity)
                    .fixedSize()
                    .frame(height: Router.Items.lineHeight)
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

/// The activity glyphs' peek: read-only, the page's floating shell, one row per subagent (its title · its model as a
/// person says it · its age), background command (in mono · its age) and wait (what · its age), in that order.
struct RouterActivityPeek: View {
    let model: RouterModel
    let thread: RouterThread

    private typealias A = Router.Activity

    var body: some View {
        let _ = model.clock.minute
        let activity = thread.activity
        VStack(alignment: .leading, spacing: 6) {
            ForEach(activity.agents) { a in
                row(A.subagent, Text(a.name), meta: [a.model.map(RouterActivity.modelName), age(a.since)])
            }
            ForEach(activity.processes) { p in
                row(A.process, Text(p.command).font(p.mono ? CDS.mono(12) : nil), meta: [age(p.since)])
            }
            ForEach(activity.waits) { w in
                row(A.wait, Text(what(w)).font(w.mono ? CDS.mono(12) : nil), meta: [age(w.since)])
            }
        }
        .routerPeekShell()
        .allowsHitTesting(false)
    }

    /// A thread wait by the waited thread's page name.
    private func what(_ w: RouterActivity.Wait) -> String {
        guard w.kind == .thread else { return w.what }
        return w.thread.flatMap { model.thread($0)?.name } ?? w.what
    }

    private func age(_ since: Date?) -> String? {
        since.map { BriefAge.short(model.now.timeIntervalSince($0)) }
    }

    private func row(_ symbol: String, _ text: Text, meta: [String?]) -> some View {
        let meta = meta.compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: A.glyph, weight: .medium)).foregroundStyle(CDS.Text.muted)
                .frame(width: A.glyphBox)
            text.cdsText(CDS.Density.compact.body, .regular, CDS.Text.primary).lineLimit(1).truncationMode(.tail)
            if !meta.isEmpty {
                Spacer(minLength: 8)
                Text(meta).font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
            }
        }
    }
}
