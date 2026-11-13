import SwiftUI

// A working thread's summaries and raw detail (docs/design/router-v2/DESIGN.md 1.4, 1.5, 1.6 "Working"): the line reads
// the newest summary; the open card lists them as a timeline, newest first, each with its clock time; the pointer on the
// line shows one peek with what runs now, the last few steps, and its subagents, background commands and waits.

extension Router {
    enum Work {
        /// The card's timeline holds the whole kept history (20 summaries and their runs' starts) and shows about this
        /// many lines of it (13/19 rows, 3 apart), scrolling inside the card past them.
        static let timelineHeight: CGFloat = 8 * 19 + 7 * 3
        /// The soft fade at its bottom while more is under it.
        static let timelineFade: CGFloat = 28
        /// The peek's earlier steps.
        static let recent = 3
        /// The working peek: commands and the activity's meta need more room than the name's peek.
        static let peekWidth: CGFloat = 400
        /// Between a run's summaries, and between a run's summaries and what started it.
        static let rowGap: CGFloat = 3
        /// Between one run and the one before it.
        static let runGap: CGFloat = 9
        /// What started a run when it wasn't your message (DESIGN.md R6).
        static let subagentFinished = "subagent finished"
        static func subagentsFinished(_ n: Int) -> String { "\(n) subagents finished" }
        static let commandFinished = "background command finished"
        static let usageLimit = "resumed after the usage limit"
        static let woken = "resumed by itself"
        /// The new pill over a timeline read back: "1 new".
        static func new(_ n: Int) -> String { "\(n) new" }
        static let pillHeight: CGFloat = 20
        /// The pill springing in and the timeline gliding back to its top.
        static let pillIn = Animation.spring(duration: 0.32, bounce: 0.24)
        static let toTop = Animation.smooth(duration: 0.4)
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
/// then under them, quiet, what started the run: your message (`↑ "fix the timeline…"`, one line), or what woke the agent
/// (`↑ subagent finished · Review the diff`, `↑ background command finished · swift test`, `↑ resumed after the usage
/// limit`, `↑ resumed by itself`). The arrow points up at what it led to. The words sit on the line's text column, the clock
/// times trail in the line's ages column. The newest isn't listed while the line above reads it
/// (`RouterWork.lineReadsNewest`).
///
/// It holds the whole kept history and shows about eight lines of it, scrolling inside the card, softly faded at the
/// bottom while more is under it. Read back (not at its top), a new summary doesn't move what you read: the timeline
/// holds what it showed and a quiet `↑ 1 new` pill springs in at its top edge, counting up; the pill (or scrolling up)
/// takes it back to its top, where the new ones fold in and the pill fades out.
struct RouterWorkTimeline: View {
    let work: RouterWork

    /// What shows while you read back: the entries as they were when the first new one came; nil at the top.
    @State private var held: [Entry]?
    /// How far it is scrolled, and how tall its content is.
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var hot = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias W = Router.Work
    private var d: CDS.Density { .compact }
    private static let space = "routerWorkTimeline"

    /// One row: a summary, or what started its run.
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case summary(RouterWork.Summary, newest: Bool)
            case start(RouterWork.Start)
        }
        var id: String
        var kind: Kind
        /// Above it: none for the first, `rowGap` within a run, `runGap` between runs.
        var gap: CGFloat
        var isSummary: Bool { if case .summary = kind { true } else { false } }
    }

    private var atTop: Bool { offset <= 1 }

    var body: some View {
        let live = Self.entries(work)
        let shown = held ?? live
        let newer = held.map { Self.newSummaries(live, since: $0) } ?? 0
        let overflows = contentHeight > W.timelineHeight + 0.5
        let more = overflows && offset + W.timelineHeight < contentHeight - 1
        ScrollViewReader { proxy in
            CappedHeight(cap: W.timelineHeight) {
                ScrollView(.vertical) {
                    column(shown)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { r in
                            offset = -r.minY
                            contentHeight = r.height
                        }
                }
                .coordinateSpace(.named(Self.space))
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
            }
            .mask(alignment: .bottom) { fade(more) }
            .overlay(alignment: .top) {
                if newer > 0 {
                    pill(newer) { toTop(proxy, shown) }
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .scale(scale: 0.85, anchor: .top).combined(with: .opacity)
                                                    .combined(with: .offset(y: -4)),
                                                  removal: .opacity))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : W.pillIn, value: newer > 0)
            .animation(.easeOut(duration: 0.15), value: more)
            .onChange(of: live) { old, new in arrived(old, new) }
            .onChange(of: atTop) { _, top in if top, held != nil { release() } }
            .onChange(of: work.pose?.toTop) { _, _ in toTop(proxy, shown) }
            .onAppear { pose(proxy, live) }
        }
        .padding(.leading, Router.Activity.glyphBox + 7)
        .agesColumn()
        .accessibilityElement(children: .contain)
    }

    private func column(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { e in
                Group {
                    switch e.kind {
                    case .summary(let s, let newest): row(s, newest: newest)
                    case .start(let start): self.start(start)
                    }
                }
                .padding(.top, e.gap)
                .id(e.id)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Entries

    /// The listed summaries cut into runs, newest first, each run followed by what started it.
    static func entries(_ work: RouterWork, dropping newest: Int = 0) -> [Entry] {
        let listed = Array(work.listed.dropFirst(newest))
        let first = work.listed.first?.id
        var out: [Entry] = []
        for (i, s) in listed.enumerated() {
            let newRun = i == 0 || listed[i - 1].run != s.run
            let newest = s.id == first && newest == 0 && !work.lineReadsNewest && s.run == work.run
            out.append(Entry(id: "s\(s.id)", kind: .summary(s, newest: newest), gap: i == 0 ? 0 : newRun ? W.runGap : W.rowGap))
            let runEnds = i == listed.count - 1 || listed[i + 1].run != s.run
            if runEnds, let run = s.run, let start = work.starts[run] {
                out.append(Entry(id: "r\(s.id)", kind: .start(start), gap: W.rowGap))
            }
        }
        return out
    }

    /// The summaries in `live` that `held` doesn't show.
    static func newSummaries(_ live: [Entry], since held: [Entry]) -> Int {
        let had = Set(held.lazy.filter(\.isSummary).map(\.id))
        return live.lazy.filter { $0.isSummary && !had.contains($0.id) }.count
    }

    // MARK: Reading back

    /// A new summary while read back: hold what showed, so nothing moves; the pill counts it.
    private func arrived(_ old: [Entry], _ new: [Entry]) {
        guard held == nil, !atTop, Self.newSummaries(new, since: old) > 0 else { return }
        held = old
    }

    /// Back at the top: the new ones fold in, the pill fades out.
    private func release() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Router.lineMove) { held = nil }
    }

    /// The pill pressed: glide back to the top (at once with Reduce Motion); `release` follows there.
    private func toTop(_ proxy: ScrollViewProxy, _ shown: [Entry]) {
        guard let first = shown.first?.id else { return }
        if reduceMotion {
            proxy.scrollTo(first, anchor: .top)
        } else {
            withAnimation(W.toTop) { proxy.scrollTo(first, anchor: .top) }
        }
    }

    /// A shot's or the demo's pose: read back to a summary, the newest held behind the pill.
    private func pose(_ proxy: ScrollViewProxy, _ live: [Entry]) {
        guard let pose = work.pose else { return }
        if pose.newer > 0 { held = Self.entries(work, dropping: pose.newer) }
        if let id = pose.scrolledTo { proxy.scrollTo("s\(id)", anchor: .top) }
    }

    // MARK: Pieces

    /// The soft fade at the bottom while more is under it.
    private func fade(_ on: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(on ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: W.timelineFade)
        }
    }

    /// `↑ 2 new`: footnote, on the card's raised ground, a hairline around it.
    private func pill(_ n: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").font(.system(size: 9, weight: .semibold))
                Text(W.new(n)).contentTransition(.numericText(value: Double(n)))
            }
            .font(CDS.sans(d.footnote.0))
            .monospacedDigit()
            .foregroundStyle(hot ? CDS.Text.primary : CDS.Text.secondary)
            .padding(.horizontal, 9)
            .frame(height: W.pillHeight)
            .background(Capsule().fill(.background))
            .overlay(Capsule().strokeBorder(CDS.Text.muted.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hot = $0 }
        .animation(reduceMotion ? nil : W.pillIn, value: n)
        .padding(.top, 2)
        .accessibilityLabel(n == 1 ? "1 new summary, show it" : "\(n) new summaries, show them")
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

    /// Your words that started the run, quoted on one line; or, quieter still and unquoted, what woke it.
    private func start(_ start: RouterWork.Start) -> some View {
        let ink = Self.yours(start) ? CDS.Text.muted : CDS.Text.muted.opacity(0.7)
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "arrow.up").font(.system(size: 9, weight: .medium)).foregroundStyle(ink)
            Self.words(start, size: d.footnote.0).cdsText(d.footnote, .regular, ink).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: Router.Card.maxWidth, alignment: .leading)
    }

    static func yours(_ start: RouterWork.Start) -> Bool { if case .asked = start { true } else { false } }

    /// A run's start in words: your message quoted on one line; what woke it, with what T3 names (a command in mono).
    static func words(_ start: RouterWork.Start, size: CGFloat) -> Text {
        switch start {
        case .asked(let text):
            return Text("\u{201C}" + text.split(whereSeparator: \.isWhitespace).joined(separator: " ") + "\u{201D}")
        case .subagents(let titles):
            let head = titles.count > 1 ? W.subagentsFinished(titles.count) : W.subagentFinished
            return Text(titles.isEmpty ? head : head + " \u{00B7} " + titles.joined(separator: ", "))
        case .command(let command):
            guard let command else { return Text(W.commandFinished) }
            return Text(W.commandFinished + " \u{00B7} ") + Text(command).font(CDS.mono(size - 1))
        case .usageLimit:
            return Text(W.usageLimit)
        case .woken:
            return Text(W.woken)
        }
    }
}

/// Its content's height, up to `cap`: a scroll view as tall as what it holds until it holds more.
private struct CappedHeight: Layout {
    var cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let ideal = s.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, cap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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
