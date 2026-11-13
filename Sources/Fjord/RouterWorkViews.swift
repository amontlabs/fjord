import SwiftUI

// A working thread's summaries and raw detail (docs/design/router-v2/DESIGN.md 1.4, 1.5, 1.6 "Working"): the line reads
// the newest summary; the open card lists them as a timeline, newest first, each with its clock time; the pointer on the
// line shows one peek with what runs now, the last few steps, and its subagents, background commands and waits.

extension Router {
    enum Work {
        /// The card's timeline: this many summaries, then a quiet "Show all".
        static let timeline = 5
        /// The peek's earlier steps.
        static let recent = 3
        /// The working peek: commands and the activity's meta need more room than the name's peek.
        static let peekWidth: CGFloat = 400
        /// Between a run's summaries, and between a run's summaries and what started it.
        static let rowGap: CGFloat = 3
        /// Between one run and the one before it.
        static let runGap: CGFloat = 9
        /// A run T3 woke with no message of yours.
        static let woken = "woke on its own"
    }
}

extension RouterWork {
    /// The summaries the card lists: all but the newest while the line reads it.
    var listed: ArraySlice<Summary> { lineReadsNewest ? summaries.dropFirst() : summaries[...] }
}

extension RouterThread {
    /// A working line whose peek lists its raw detail: what runs now and before, or its subagents, commands and waits.
    var peeksWork: Bool { state == .working && (work.hasSteps || !activity.isEmpty) }
}

/// What the thread did, as the Router's model summed it up, newest first, read as a conversation: each run's summaries,
/// then under them, quiet, what started the run: your message (`↑ "fix the timeline…"`, one line), or that T3 woke the
/// agent itself. The arrow points up at what your words led to. The words sit on the line's text column, the clock times
/// trail in the line's ages column. The newest isn't listed while the line above reads it (`RouterWork.lineReadsNewest`).
struct RouterWorkTimeline: View {
    let work: RouterWork

    @State private var all = false
    @State private var hot = false

    private typealias W = Router.Work
    private var d: CDS.Density { .compact }

    /// A run's summaries in the card, and what started it once its first summary is shown.
    private struct Run: Identifiable {
        var id: Int
        var summaries: [RouterWork.Summary]
        var start: RouterWork.Start?
    }

    var body: some View {
        let listed = Array(work.listed)
        let shown = all ? listed : Array(listed.prefix(W.timeline))
        let runs = Self.runs(shown, cut: shown.count < listed.count, work: work)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.element.id) { i, run in
                VStack(alignment: .leading, spacing: W.rowGap) {
                    ForEach(run.summaries) { s in
                        row(s, newest: i == 0 && s.id == listed.first?.id && !work.lineReadsNewest && s.run == work.run)
                    }
                    if let start = run.start { self.start(start) }
                }
                .padding(.top, i == 0 ? 0 : W.runGap)
            }
            if listed.count > W.timeline { more(open: all).padding(.top, 2) }
        }
        .padding(.leading, Router.Activity.glyphBox + 7)
        .agesColumn()
        .accessibilityElement(children: .combine)
    }

    /// The shown summaries cut into runs, newest first. A run whose first summary is cut off doesn't show what started it.
    private static func runs(_ shown: [RouterWork.Summary], cut: Bool, work: RouterWork) -> [Run] {
        var runs: [Run] = []
        for s in shown {
            if let last = runs.last, last.summaries.last?.run == s.run {
                runs[runs.count - 1].summaries.append(s)
            } else {
                runs.append(Run(id: s.id, summaries: [s]))
            }
        }
        for i in runs.indices where !(cut && i == runs.count - 1) {
            if let run = runs[i].summaries.first?.run { runs[i].start = work.starts[run] }
        }
        return runs
    }

    private func row(_ s: RouterWork.Summary, newest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(RouterInline.text(s.text, size: d.body.0))
                .cdsText(d.body, .regular, newest ? CDS.Text.primary : CDS.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Router.Card.maxWidth, alignment: .leading)
            Spacer(minLength: 8)
            Text(RouterWorkTime.clock(s.at)).font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted)
                .fixedSize()
        }
    }

    /// Your words that started the run, quoted on one line; or, quieter still and unquoted, that T3 woke it.
    private func start(_ start: RouterWork.Start) -> some View {
        let words: String
        let ink: Color
        switch start {
        case .asked(let text):
            words = "\u{201C}" + text.split(whereSeparator: \.isWhitespace).joined(separator: " ") + "\u{201D}"
            ink = CDS.Text.muted
        case .woken:
            words = W.woken
            ink = CDS.Text.muted.opacity(0.7)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "arrow.up").font(.system(size: 9, weight: .medium)).foregroundStyle(ink)
            Text(words).cdsText(d.footnote, .regular, ink).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: Router.Card.maxWidth, alignment: .leading)
    }

    /// "Show all" under a cut timeline, "Show less" under an open one.
    private func more(open: Bool) -> some View {
        Button { withAnimation(.snappy(duration: 0.25)) { all.toggle() } } label: {
            Text(open ? "Show less" : "Show all").cdsText(d.footnote, .regular, hot ? CDS.Text.primary : CDS.Text.muted)
                .frame(height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hot = $0 }
    }
}

extension View {
    /// Runs a card block out to the line's ages column (its times trailing where the line's age ends), past the card's
    /// trailing inset, as the options' ground does.
    func agesColumn() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, -(Router.Card.trailing - Router.Line.reach))
    }
}

enum RouterWorkTime {
    /// "13:58", or "1:58 PM": the system's 12- or 24-hour clock, its own digits for the hour.
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
    }
}

/// The working line's peek: T3's title; what runs now (the working dots) and the steps before it (checked), each with
/// how long ago it started; then its subagents, background commands and waits. Read-only, the page's floating shell.
struct RouterWorkingPeek: View {
    let model: RouterModel
    let thread: RouterThread

    private typealias W = Router.Work
    private typealias A = Router.Activity
    private var d: CDS.Density { .compact }

    var body: some View {
        let _ = model.clock.minute
        let work = thread.work
        VStack(alignment: .leading, spacing: 10) {
            if work.hasSteps {
                VStack(alignment: .leading, spacing: 6) {
                    if let now = work.now {
                        row(now, primary: true) { RouterWorkingDots(tint: CDS.Text.secondary) }
                    }
                    ForEach(work.recent.prefix(W.recent)) { step in
                        row(step, primary: false) {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                        }
                    }
                }
            }
            if !thread.activity.isEmpty {
                RouterActivityRows(model: model, activity: thread.activity)
                    .padding(.top, work.hasSteps ? 2 : 0)
            }
        }
        .padding(Router.Peek.pad)
        .frame(width: W.peekWidth, alignment: .leading)
        .routerFloating(radius: Router.Peek.radius)
        .allowsHitTesting(false)
    }

    private func row<G: View>(_ step: RouterWork.Step, primary: Bool, @ViewBuilder glyph: () -> G) -> some View {
        HStack(spacing: 8) {
            glyph().frame(width: A.glyphBox, height: 14)
            Text(step.text)
                .font(step.mono ? CDS.mono(12) : CDS.sans(d.body.0))
                .foregroundStyle(primary ? CDS.Text.primary : CDS.Text.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(BriefAge.short(model.now.timeIntervalSince(step.at))).font(CDS.sans(12)).monospacedDigit()
                .foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
        }
    }
}
