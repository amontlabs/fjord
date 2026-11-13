import SwiftUI

// A working thread's summaries and raw detail (docs/design/router-v2/DESIGN.md 1.4, 1.5, 1.6 "Working"): the line reads
// the newest summary; the open card lists them as a timeline, newest first, each with its clock time; the pointer on the
// line shows one peek with what runs now, the last few steps, and its subagents, background commands and waits.

extension Router {
    enum Work {
        /// The card's timeline: this many summaries, then "N earlier".
        static let timeline = 5
        /// The peek's earlier steps.
        static let recent = 3
        /// The working peek: commands and the activity's meta need more room than the name's peek.
        static let peekWidth: CGFloat = 400
        /// A timeline mark: the newest a little larger.
        static let dot: CGFloat = 5
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

/// Each summary the model wrote of the run, newest first: a mark on a hairline rail in the glyph column (the steps' and
/// the activity's), the words at the prose's width, and its clock time trailing in the line's ages column. The newest
/// isn't listed while the line above reads it (`RouterWork.lineReadsNewest`): the timeline is what came before.
struct RouterWorkTimeline: View {
    let work: RouterWork

    private typealias W = Router.Work
    private var d: CDS.Density { .compact }

    var body: some View {
        let all = work.listed
        let shown = Array(all.prefix(W.timeline))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(RouterInline.text(s.text, size: d.body.0))
                        .cdsText(d.body, .regular, i == 0 && !work.lineReadsNewest ? CDS.Text.primary : CDS.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Router.Activity.glyphBox + 7)
                        .frame(maxWidth: Router.Card.maxWidth, alignment: .leading)
                    Spacer(minLength: 8)
                    Text(RouterWorkTime.clock(s.at)).font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted)
                        .fixedSize()
                }
                .padding(.bottom, i == shown.count - 1 ? 0 : 6)
                .overlay(alignment: .topLeading) { mark(newest: i == 0 && !work.lineReadsNewest, first: i == 0, last: i == shown.count - 1) }
            }
            if all.count > shown.count {
                Text(verbatim: "\(all.count - shown.count) earlier").cdsText(d.footnote, .regular, CDS.Text.muted)
                    .padding(.leading, Router.Activity.glyphBox + 7).padding(.top, 4)
            }
        }
        .agesColumn()
        .accessibilityElement(children: .combine)
    }


    /// The row's mark on the rail: a hairline from the row above's mark into this one, and on from it to the row's end
    /// (where the next row's picks up), each stopping 3 pt clear of the mark.
    private func mark(newest: Bool, first: Bool, last: Bool) -> some View {
        let lineMid = d.body.1 / 2
        let size = newest ? W.dot + 1 : W.dot
        let clear: CGFloat = 3
        return VStack(spacing: 0) {
            Rectangle().fill(first ? .clear : CDS.Settings.railLine).frame(width: 1, height: max(0, lineMid - size / 2 - clear))
            Circle().fill(newest ? CDS.Text.secondary : CDS.Text.muted.opacity(0.7)).frame(width: size, height: size)
                .padding(.vertical, clear)
            Rectangle().fill(last ? .clear : CDS.Settings.railLine).frame(width: 1).frame(maxHeight: .infinity)
        }
        .frame(width: Router.Activity.glyphBox)
        .frame(maxHeight: .infinity, alignment: .top)
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
    /// "13:58", in the user's locale (24-hour where it is the custom).
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
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
            Text(thread.title).cdsText(d.footnote, .medium, CDS.Text.muted).lineLimit(1)
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
