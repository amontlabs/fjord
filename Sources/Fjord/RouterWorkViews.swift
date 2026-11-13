import SwiftUI

// A thread's history (docs/design/router-v2/DESIGN.md 1.5 "History", R6, R10): on every thread's card, newest first, the
// Router's summaries of each run with what started it, the items as they were raised and closed, and the turns as they
// ended. A working line reads its newest summary; its card's history is its source.

extension Router {
    enum Work {
        /// The card's timeline holds the whole kept history (20 summaries and their runs' starts) and shows about this
        /// many lines of it (13/19 rows, 3 apart), scrolling inside the card past them.
        static let timelineHeight: CGFloat = 8 * 19 + 7 * 3
        /// The soft fade at its bottom while more is under it.
        static let timelineFade: CGFloat = 28
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
        /// Over the pill's place at the timeline's top edge (2 + its height + 3) the words are gone, then fade in over this:
        /// the pill never sits on words.
        static let pillBand: CGFloat = 2 + pillHeight + 3
        static let pillFade: CGFloat = 12
        /// The pill springing in and the timeline gliding back to its top.
        static let pillIn = Animation.spring(duration: 0.32, bounce: 0.24)
        static let toTop = Animation.smooth(duration: 0.4)
    }
}


extension RouterThread {
    /// A working line whose one peek shows from anywhere on its row: it has more to say than its line.
    var peeksWork: Bool { state == .working && RouterSummaryView.peeks(self) }
}

/// The thread's history, newest first, read as a conversation: each run's summaries and what happened in it (an item
/// raised, one closed with how, the turn ending with its outcome), then under them, quiet, what started the run: your
/// message (`↑ "fix the timeline…"`, one line), or what woke the agent (`↑ subagent finished · Review the diff`, `↑
/// background command finished · swift test`, `↑ resumed after the usage limit`, `↑ resumed by itself`). The arrow points
/// up at what it led to. Summaries are the words; the rest are quiet one-liners with their mark hung in the gutter. The
/// words sit on the line's text column, the clock times trail in the line's ages column. A working line's newest summary
/// isn't listed while the line reads it (`RouterWork.lineReadsNewest`).
///
/// It holds the whole kept history and shows about eight lines of it, scrolling inside the card, softly faded at the
/// bottom while more is under it. Read back (not at its top), something new doesn't move what you read: the timeline
/// holds what it showed and a quiet `↑ 1 new` pill springs in at its top edge, counting up; the pill (or scrolling up)
/// takes it back to its top, where the new ones fold in and the pill fades out.
struct RouterTimeline: View {
    let thread: RouterThread

    /// What shows while you read back: the entries as they were when the first new one came; nil at the top.
    @State private var held: [Entry]?
    /// How far it is scrolled, and how tall its content is.
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var hot = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias W = Router.Work
    private var d: CDS.Density { .compact }
    private static let space = "routerTimeline"

    /// One row: a history event, and its gap above it (none for the first, `rowGap` within a run, `runGap` between runs).
    struct Entry: Identifiable, Equatable {
        var event: RouterEvent
        var gap: CGFloat
        /// The newest summary of the run working now, which the line doesn't read: the primary ink.
        var newest = false
        var id: String { event.id }
        var isSummary: Bool { if case .summary = event.kind { true } else { false } }
        /// Counted by the new pill: anything but a run's start.
        var counts: Bool { if case .started = event.kind { false } else { true } }
    }

    private var atTop: Bool { offset <= 1 }

    /// Whether a card has any history to show.
    static func has(_ thread: RouterThread) -> Bool { !entries(thread).isEmpty }

    var body: some View {
        let live = Self.entries(thread)
        let shown = held ?? live
        let newer = held.map { Self.newer(live, since: $0) } ?? 0
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
            .mask(alignment: .top) { band(newer > 0) }
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
            .animation(Motion.fade.resolved(reduce: reduceMotion), value: more)
            .onChange(of: live) { old, new in arrived(old, new) }
            .onChange(of: atTop) { _, top in if top, held != nil { release() } }
            .onChange(of: thread.work.pose?.toTop) { _, _ in toTop(proxy, shown) }
            .onAppear { pose(proxy) }
        }
        // The marks hang left of the card's column (inside the scroll view, so they aren't clipped); every row's words
        // start on it.
        .padding(.leading, -Router.Card.hang)
        .agesColumn()
        .accessibilityElement(children: .contain)
    }

    private func column(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { e in
                row(e)
                    .padding(.top, e.gap)
                    .id(e.id)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Entries

    /// The history as rows, newest first, the newest `dropping` summaries (and what came after them) held back.
    static func entries(_ thread: RouterThread, dropping: Int = 0) -> [Entry] {
        var events = thread.history[...]
        // The line reads the newest summary: the card is what came before it.
        if thread.work.lineReadsNewest, let i = events.firstIndex(where: { if case .summary = $0.kind { true } else { false } }) {
            events = events[events.index(after: i)...]
        }
        // An item still open is on the page already (the line, or its row): its raising isn't repeated.
        let open = Set(thread.ledger.live.map { "raised:" + $0.id })
        events = events.filter { !open.contains($0.id) }[...]
        if dropping > 0 {
            var left = dropping
            while let e = events.first, left > 0 {
                if case .summary = e.kind { left -= 1 }
                events = events.dropFirst()
            }
        }
        var out: [Entry] = []
        var previous: RouterEvent?
        for e in events {
            let gap: CGFloat
            if let p = previous {
                if case .started = p.kind { gap = W.runGap } else { gap = p.run == e.run ? W.rowGap : W.runGap }
            } else {
                gap = 0
            }
            var entry = Entry(event: e, gap: gap)
            if previous == nil, dropping == 0, case .summary = e.kind, thread.state == .working, !thread.work.lineReadsNewest,
               e.run == thread.work.run {
                entry.newest = true
            }
            out.append(entry)
            previous = e
        }
        return out
    }

    /// The rows in `live` that `held` doesn't show (a run's start isn't counted).
    static func newer(_ live: [Entry], since held: [Entry]) -> Int {
        let had = Set(held.lazy.map(\.id))
        return live.lazy.filter { $0.counts && !had.contains($0.id) }.count
    }

    // MARK: Reading back

    /// Something new while read back: hold what showed, so nothing moves; the pill counts it.
    private func arrived(_ old: [Entry], _ new: [Entry]) {
        guard held == nil, !atTop, Self.newer(new, since: old) > 0 else { return }
        held = old
    }

    /// Back at the top: the new ones fold in, the pill fades out.
    private func release() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Router.lineMove) { held = nil }
    }

    /// The pill pressed: glide back to the top (at once with Reduce Motion); `release` follows there.
    private func toTop(_ proxy: ScrollViewProxy, _ shown: [Entry]) {
        guard let first = shown.first?.id else { return }
        withAnimation(reduceMotion ? nil : W.toTop) { proxy.scrollTo(first, anchor: .top) }
    }

    /// A shot's or the demo's pose: read back to a summary, the newest held behind the pill.
    private func pose(_ proxy: ScrollViewProxy) {
        guard let pose = thread.work.pose else { return }
        if pose.newer > 0 { held = Self.entries(thread, dropping: pose.newer) }
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

    /// While the pill shows, its own band at the top edge: the words scroll out under it, gone behind the pill and
    /// fading in under it, so the pill never covers text; nothing moves as it comes.
    private func band(_ on: Bool) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
            VStack(spacing: 0) {
                Rectangle().frame(height: W.pillBand)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: W.pillFade)
            }
            .opacity(on ? 1 : 0)
            .blendMode(.destinationOut)
        }
        .compositingGroup()
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
        .accessibilityLabel(n == 1 ? "1 new in its history, show it" : "\(n) new in its history, show them")
    }

    @ViewBuilder private func row(_ e: Entry) -> some View {
        switch e.event.kind {
        case .summary(let text):
            timed(e.event.at) {
                Text(RouterInline.text(text, size: d.body.0))
                    .cdsText(d.body, .regular, e.newest ? CDS.Text.primary : CDS.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Router.Card.maxWidth, alignment: .leading)
                    .padding(.leading, Router.Card.hang)
            }
        case .started(let start):
            started(start)
        case .raised(let kind, let sentence):
            timed(e.event.at) {
                quiet(Image(systemName: kind.symbol).foregroundStyle(kind.tint.opacity(0.8))) {
                    Text(RouterInline.text(sentence, size: d.footnote.0)).foregroundColor(CDS.Text.secondary)
                }
            }
            .accessibilityLabel("\(kind.word): \(sentence)")
        case .closed(let kind, let sentence, let how):
            timed(e.event.at) {
                quiet(Image(systemName: kind.symbol).foregroundStyle(CDS.Text.muted.opacity(0.7))) {
                    Text(RouterInline.text(sentence, size: d.footnote.0)).strikethrough(color: CDS.Text.muted).foregroundColor(CDS.Text.muted)
                        + Text(verbatim: "  " + how).foregroundColor(CDS.Text.muted.opacity(0.8))
                }
            }
            .accessibilityLabel("\(kind.word), closed: \(sentence), \(how)")
        case .finished(let outcome):
            timed(e.event.at) {
                quiet(Image(systemName: "checkmark.circle").foregroundStyle(CDS.Text.muted)) {
                    Text(RouterInline.text(outcome, size: d.footnote.0)).foregroundColor(CDS.Text.secondary)
                }
            }
            .accessibilityLabel("Turn ended: \(outcome)")
        }
    }

    /// A row with its clock time trailing in the ages column.
    private func timed<Words: View>(_ at: Date, @ViewBuilder words: () -> Words) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            words()
            Spacer(minLength: 8)
            Text(RouterWorkTime.clock(at)).font(CDS.sans(12)).monospacedDigit().foregroundStyle(CDS.Text.muted)
                .fixedSize()
        }
    }

    /// A quiet one-liner: its mark hung in the gutter under the line's mark, its words footnote on the column.
    private func quiet<Words: View>(_ mark: some View, @ViewBuilder words: () -> Words) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Router.Card.glyphGap) {
            mark.font(.system(size: 9, weight: .medium)).frame(width: Router.Card.glyphBox)
            words().font(CDS.sans(d.footnote.0)).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: Router.Card.maxWidth + Router.Card.hang, alignment: .leading)
    }

    /// Your words that started the run, quoted on one line; or, quieter still and unquoted, what woke it.
    private func started(_ start: RouterWork.Start) -> some View {
        let ink = Self.yours(start) ? CDS.Text.muted : CDS.Text.muted.opacity(0.7)
        return HStack(alignment: .firstTextBaseline, spacing: Router.Card.glyphGap) {
            Image(systemName: "arrow.up").font(.system(size: 9, weight: .medium)).foregroundStyle(ink)
                .frame(width: Router.Card.glyphBox)
            Self.words(start, size: d.footnote.0).cdsText(d.footnote, .regular, ink).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: Router.Card.maxWidth + Router.Card.hang, alignment: .leading)
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
