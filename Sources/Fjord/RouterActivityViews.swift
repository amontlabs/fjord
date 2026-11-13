import SwiftUI

// A thread's subagents, background commands and waits (docs/design/router-v2/DESIGN.md 1.4, 1.5, 1.6): on the line, a
// few muted glyphs at the end of the sentence's place, a count beside one only when it is more than one; the pointer on them shows
// the line's hover, whose facts say them (`RouterSummaryView`).

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
    }
}

extension RouterModel {
    /// The line whose hover shows from its glyphs: the pointer is on them, its card isn't open, and the hover says more
    /// than the line. A working line's shows from anywhere on its row (`peeked`).
    var activityPeeked: String? {
        guard case .activity(let id)? = hoverControl, selection != .line(id), let t = thread(id), !t.activity.isEmpty,
              !t.peeksWork, RouterSummaryView.peeks(t, nil) else { return nil }
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
