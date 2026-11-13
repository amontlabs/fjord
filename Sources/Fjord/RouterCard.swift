import AppKit
import SwiftUI

// Router v2's card (docs/design/router-v2/DESIGN.md 1.5): one component, inline under the selected line, inside the
// selected surface. T3's title, the agent's last lines, the kind's block (question, form, plan, permission, a step the
// model found, done, stopped, working, sent), and a footer of text buttons with their keys. Options only pick: Return
// sends what the destination row shows.

struct RouterCard: View {
    let model: RouterModel
    /// Its line's box: the card redraws when the record does, not as the reply grows (`RouterLastLines` does).
    let box: RouterLineBox
    @Namespace private var rail
    @Environment(\.accessibilityReduceMotion) private var reduce

    private typealias M = Router.Card
    private var d: CDS.Density { .compact }
    private var thread: RouterThread { box.head }

    /// The open item's card instead, in a block (its focused item) or on a thread whose one item is the line.
    private var item: RouterItem? {
        if let focus = box.shown { return thread.ledger.items.first { $0.id == focus } }
        return thread.ledger.single
    }

    var body: some View {
        if let item {
            RouterItemCard(model: model, thread: thread, item: item)
        } else {
            card
        }
    }

    private var card: some View {
        let _ = RouterBodies.count("card", box.id, of: model)
        return VStack(alignment: .leading, spacing: M.gap) {
            if thread.loading {
                VStack(alignment: .leading, spacing: 8) {
                    RouterSkeletonBar(share: 0.92)
                    RouterSkeletonBar(share: 0.61)
                }
                .padding(.leading, M.railInset + 1)
                .padding(.vertical, 4)
                .prose()
                .transition(.opacity)
            } else if box.talking, !summarized {
                // A working thread with summaries shows them instead (below): its last turn's words aren't news.
                RouterLastLines(model: model, box: box).prose().transition(.opacity)
            }
            kind
            footer
        }
        .padding(.leading, M.leading).padding(.trailing, M.trailing).padding(.bottom, M.bottom)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A working thread the Router's model has summed up: its card is the timeline of those lines, not the last quote.
    /// Until the run working now has a summary, the card quotes its last words; earlier runs' summaries follow, apart.
    private var summarized: Bool { thread.state == .working && thread.work.current }

    // MARK: Kind blocks. Prose keeps to 560 pt; option rows run the card's width, their keycaps under the footer's.

    @ViewBuilder private var kind: some View {
        if case .needsYou(let request) = thread.state, !thread.live {
            if let question = thread.question { ask(question) }
            if request == .permission, let p = thread.permission { permission(p).prose() }
            notLive
        } else {
            live
        }
    }

    /// A request T3 can no longer answer (IMPLEMENTATION.md 1.3): no options, Open in T3 in their place.
    private var notLive: some View {
        HStack(spacing: 10) {
            Text(Router.Copy.notLive).cdsText(d.footnote, .regular, CDS.Text.muted).lineLimit(2)
            RouterPushButton(model: model, hit: .footer(thread.id, .open), title: "Open in T3", keys: ["cmd", "O"]) {
                model.open(thread.id)
            }
        }
    }

    @ViewBuilder private var live: some View {
        switch thread.state {
        case .needsYou(.question):
            if let question = thread.question { ask(question) }
            RouterOptions(model: model, thread: thread, labels: thread.options, from: 0)
        case .needsYou(.form):
            form
        case .needsYou(.plan):
            RouterPlan(model: model, thread: thread).prose()
            RouterOptions(model: model, thread: thread, labels: thread.options, from: 0)
        case .needsYou(.permission):
            if let p = thread.permission { permission(p).prose() }
            RouterOptions(model: model, thread: thread, labels: thread.options, from: 0)
        case .done:
            HStack(spacing: 8) {
                badges
                if let diff = thread.diff {
                    (Text(verbatim: "\(diff.files) file\(diff.files == 1 ? "" : "s")  ").foregroundColor(CDS.Text.muted)
                        + Text(verbatim: "+\(diff.added)").foregroundColor(CDS.Git.added)
                        + Text(verbatim: "  −\(diff.removed)").foregroundColor(CDS.Git.removed))
                        .font(CDS.sans(12)).monospacedDigit()
                }
            }
        case .stopped:
            if let stop = thread.stop { stopped(stop).prose() }
        case .working:
            // A thread started here: what it runs on, through its first run.
            if let launch = thread.launch { started(launch) }
            // What it has been doing, as the Router's model summed it up, newest first.
            if thread.state == .working, !thread.work.listed.isEmpty { RouterWorkTimeline(work: thread.work) }
            // T3's to-do steps, when the thread has a list (Claude sends one only with T3's to-do setting on).
            if !thread.steps.isEmpty { steps.prose() }
            // Its subagents, background commands and waits, each with how long it has run.
            if !thread.activity.isEmpty {
                RouterActivityRows(model: model, activity: thread.activity, compact: true).agesColumn()
                    .transition(.opacity)
            }
        case .sent:
            if let sent = thread.sent {
                Text(sent.words).cdsText(d.body, .regular, CDS.Text.primary).fixedSize(horizontal: false, vertical: true).prose()
            }
            // A thread started here: what it starts with.
            if let launch = thread.launch { started(launch) }
        }
    }

    private func started(_ launch: RouterLaunch) -> some View {
        Text(model.words(launch)).cdsText(d.footnote, .regular, CDS.Text.muted).lineLimit(1)
    }

    private func ask(_ text: String) -> some View {
        Text(RouterInline.text(text, size: d.prose.0)).cdsText(d.prose, .regular, CDS.Text.primary)
            .fixedSize(horizontal: false, vertical: true).prose()
    }

    @ViewBuilder private var badges: some View {
        if !thread.prs.isEmpty {
            HStack(spacing: 6) {
                ForEach(thread.prs) { pr in
                    RouterPRBadge(pr: pr).routerTarget(model, .prBadge(thread.id, pr.number)).routerLink()
                }
            }
        }
    }

    /// Each question with its option rows, numbered through the form; the current one has the accent rail, one rail
    /// that slides from question to question.
    private var form: some View {
        let at = min(model.formAt[thread.id] ?? 0, thread.form.count - 1)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(thread.form.enumerated()), id: \.element.id) { q, question in
                let from = thread.form.prefix(q).reduce(0) { $0 + $1.options.count }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(question.title).cdsText(d.prose, .medium, CDS.Text.primary)
                        if model.answered(thread, q) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                                .transition(.opacity)
                        }
                    }
                    // Its options' grounds stop short of the rail.
                    RouterOptions(model: model, thread: thread, labels: question.options, from: from, reach: 8)
                    if let typed = model.typed[thread.id]?[q] {
                        Text("Your answer: \(typed)").cdsText(d.body, .regular, CDS.Text.secondary).lineLimit(2)
                            .transition(.opacity)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    if q == at {
                        RoundedRectangle(cornerRadius: 1).fill(CDS.Text.accent).frame(width: 2)
                            .matchedGeometryEffect(id: "rail", in: rail)
                    }
                }
            }
        }
        .motion(.spatial, value: at)
        .motion(.fade, value: model.answeredCount(thread))
    }

    /// The command and its warning. T3 sends no reason with a permission: the line's words say what it is for.
    private func permission(_ p: RouterThread.Permission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.command).font(CDS.mono(12)).foregroundStyle(CDS.Text.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Router.Surface.control, style: .continuous).fill(Router.Surface.quiet))
            if !p.warning.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium))
                    Text(p.warning)
                }
                .cdsText(d.footnote, .regular, CDS.Text.warning)
            }
        }
    }

    private func stopped(_ stop: RouterThread.Stop) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The reason on the danger ink's tint: a ground, no ring.
            let shape = RoundedRectangle(cornerRadius: Router.Surface.row, style: .continuous)
            Text(stop.error).font(CDS.mono(12)).foregroundStyle(CDS.Text.primary).lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(Router.dangerFill))
            (Text("Last step: ") + Text(RouterInline.text(stop.lastStep, size: d.footnote.0)))
                .cdsText(d.footnote, .regular, CDS.Text.muted)
        }
    }

    /// T3's to-do steps: done, the running one with the dots, pending; five at most.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(thread.steps.prefix(M.steps)) { step in
                HStack(spacing: 7) {
                    ZStack {
                        switch step.state {
                        case .done: Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                        case .running: RouterWorkingDots(tint: CDS.Text.primary)
                        case .pending: Circle().strokeBorder(CDS.borderStrong, lineWidth: 1).frame(width: 7, height: 7)
                        }
                    }
                    .frame(width: 14, height: 14)
                    Text(step.text).cdsText(d.footnote, .regular, step.state == .running ? CDS.Text.primary : CDS.Text.muted).lineLimit(1)
                }
            }
            if thread.steps.count > M.steps {
                Text(verbatim: "+\(thread.steps.count - M.steps) more").cdsText(d.footnote, .regular, CDS.Text.muted).padding(.leading, 21)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        let id = thread.id
        return HStack(spacing: M.footerGap) {
            if thread.state == .stopped {
                // T3 has no rerun: Continue sends its words for it, and the destination row shows them.
                RouterPushButton(model: model, hit: .footer(id, .rerun), title: Router.Copy.continueTitle, keys: ["enter"]) {
                    model.resume(id)
                }
            }
            if thread.state == .needsYou(.form) {
                Text(verbatim: "\(model.answeredCount(thread)) of \(thread.form.count) answered")
                    .cdsText(d.footnote, .regular, CDS.Text.muted).contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            switch thread.state {
            case .working:
                // The page's one act with no way back: a button only, no key.
                RouterTextButton(model: model, hit: .footer(id, .stop), title: "Stop") { model.stop(id) }
                openButton
            case .sent:
                openButton
            default:
                if let why = model.holdReason(thread) {
                    // T3 won't let go of it yet: shown off, with why.
                    RouterHeldActs(why: why)
                } else {
                    RouterTextButton(model: model, hit: .footer(id, .snooze), title: "Snooze", keys: ["alt", "cmd", "backspace"],
                                       removes: true) { model.openSnooze() }
                    RouterTextButton(model: model, hit: .footer(id, .settle), title: "Settle", keys: ["cmd", "backspace"],
                                       removes: true) { model.settle(id) }
                }
                // A request that is no longer live has it in its options' place.
                if thread.live { openButton }
            }
        }
        .padding(.top, 2)
    }

    private var openButton: some View {
        RouterTextButton(model: model, hit: .footer(thread.id, .open), title: "Open in T3", keys: ["cmd", "O"]) { model.open(thread.id) }
    }
}

/// Snooze and Settle where T3 refuses them (a request waits, a run is live): off, with the reason before them.
private struct RouterHeldActs: View {
    let why: String

    var body: some View {
        let d = CDS.Density.compact
        HStack(spacing: 10) {
            Text(why).cdsText(d.caption, .regular, CDS.Text.muted).lineLimit(1).fixedSize()
            Text("Snooze").cdsText(d.footnote, .regular, CDS.Text.muted).opacity(0.45).fixedSize()
            Text("Settle").cdsText(d.footnote, .regular, CDS.Text.muted).opacity(0.45).fixedSize()
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Snooze and Settle are off: \(why)")
    }
}

private extension View {
    /// A card's prose keeps to a readable measure.
    func prose() -> some View { frame(maxWidth: Router.Card.maxWidth, alignment: .leading) }
}

/// Inline Markdown as the Router's text has it, with code a little smaller than the words beside it (0.92 of their
/// size): at the same size mono reads a size bigger than the sans.
enum RouterInline {
    static func text(_ markdown: String, size: CGFloat) -> AttributedString {
        var out = RouterText.inline(markdown)
        let code = CDS.mono((size * 0.92).rounded())
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].font = code
        }
        return out
    }
}

/// The agent's last message behind a rail: clipped to 4 lines (6 for Done) with a bottom fade and "Show all" (→) under
/// it; open, the whole text and "Show less" (←). While the agent writes, the text grows live with a caret after its last
/// word.
struct RouterLastLines: View {
    let model: RouterModel
    let box: RouterLineBox

    var body: some View {
        let _ = RouterBodies.count("lastLines", box.id, of: model)
        let d = CDS.Density.compact
        let thread = box.head
        let open = model.expanded.contains(thread.id) && thread.plan.isEmpty
        let limit = thread.state == .done ? Router.Card.lastLinesDone : Router.Card.lastLines
        // The agent's words are Markdown: its inline code reads as code.
        let words = Text(RouterInline.text(box.lastLines, size: d.body.0))
        let text = (box.writing ? words + RouterTextCaret.text : words).cdsText(d.body, .regular, CDS.Text.secondary)
        // Whether it is cut, where, its fade and its button are all worked out in the layout that places it. Measured a
        // turn later, an opening quote laid out its whole text unclipped for a frame (the card grew past it, its options
        // drawn over the words), then came back as a box 320 pt tall that scrolled, its scroller hidden and its words cut
        // with no fade: it read as still shut, and → had nothing left to open.
        RouterQuoteCut(open: open) {
            text.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                // A click on the cut words opens them too (open, only "Show less" and ← shut them: a click while
                // reading doesn't fold them away). A quote with nothing past its first lines shows the same either way.
                .contentShape(Rectangle())
                .onTapGesture { if !open { model.expand(true) } }
            text.lineLimit(limit).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                .blendMode(.destinationOut)
                .allowsHitTesting(false)
            Rectangle().fill(CDS.Settings.railLine)
            // Only when there is more than the first lines: offered no size, it is clipped to nothing. (In a
            // `ViewThatFits`, the title started a click's roll from the top of the words while its key rode the edge.)
            RouterShowAll(model: model, id: thread.id, open: open)
                .frame(minWidth: 0, minHeight: 0, alignment: .topLeading)
                .clipped()
        }
        .compositingGroup()
    }
}

/// "Show all" (→) under a shut quote, "Show less" (←) under an open one. Both titles are always there, one of them
/// clear: a title that swapped in (a new view) was drawn where the button ends from its first frame, ahead of the edge
/// of the words it rides as they roll.
private struct RouterShowAll: View {
    let model: RouterModel
    let id: String
    let open: Bool

    var body: some View {
        RouterButton(model: model, hit: .longText(id), action: { model.expand(!open) }) { hot, pressed in
            let style = CDS.Density.compact.footnote
            let color = hot ? CDS.Text.primary : CDS.Text.muted
            ZStack(alignment: .leading) {
                HStack(spacing: 5) {
                    Text("Show all").cdsText(style, .regular, color).lineLimit(1).fixedSize()
                    RouterKeyHint(keys: ["right"])
                }
                .opacity(open ? 0 : 1)
                HStack(spacing: 5) {
                    Text("Show less").cdsText(style, .regular, color).lineLimit(1).fixedSize()
                    RouterKeyHint(keys: ["left"])
                }
                .opacity(open ? 1 : 0)
            }
            .frame(height: 22)
            // It moves as one: the quote rolling takes it from under the pointer, and the title's colour going back
            // to muted mid-roll put the title at the roll's end at once while its key still rode the words' edge.
            .geometryGroup()
            .opacity(pressed ? 0.7 : 1)
            .hoverMotion(hot)
        }
        .accessibilityLabel(open ? "Show less" : "Show all")
    }
}

/// A quote's views in one layout: its words (all of them, clipped to what they are offered), its first lines (not drawn,
/// for the cut), the fade over the cut's bottom, the rail beside the words and the button under them. Cut while shut and
/// longer than its first lines; the fade and the button only then (the button stays, as "Show less", while open).
private struct RouterQuoteCut: Layout {
    var open: Bool
    private typealias M = Router.Card
    private static let buttonGap: CGFloat = 4

    struct Cache {
        var width: CGFloat = -1
        var all: CGFloat = 0
        var first: CGFloat = 0
        var button: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func measure(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) {
        guard cache.width != width, subviews.count == 5 else { return }
        let words = ProposedViewSize(width: max(0, width - M.railInset), height: nil)
        cache = Cache(width: width, all: subviews[0].sizeThatFits(words).height, first: subviews[1].sizeThatFits(words).height,
                      button: subviews[4].sizeThatFits(.unspecified).height)
    }

    private func more(_ cache: Cache) -> Bool { cache.all > cache.first + 1 }

    /// The words' shown height.
    private func shown(_ cache: Cache) -> CGFloat { more(cache) && !open ? cache.first : cache.all }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? M.maxWidth
        measure(width, subviews, &cache)
        let button = more(cache) ? Self.buttonGap + cache.button : 0
        return CGSize(width: width, height: shown(cache) + button)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 5 else { return }
        measure(bounds.width, subviews, &cache)
        let height = shown(cache)
        let words = max(0, bounds.width - M.railInset)
        let origin = CGPoint(x: bounds.minX + M.railInset, y: bounds.minY)
        subviews[0].place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(width: words, height: height))
        subviews[1].place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(width: words, height: nil))
        // The fade: the cut's last 40 %, shut only.
        let cut = more(cache) && !open
        let fade = cut ? height * 0.4 : 0
        subviews[2].place(at: CGPoint(x: origin.x, y: bounds.minY + height - fade), anchor: .topLeading,
                          proposal: ProposedViewSize(width: cut ? words : 0, height: fade))
        subviews[3].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: 1, height: height))
        let button = more(cache) ? cache.button : 0
        subviews[4].place(at: CGPoint(x: origin.x, y: bounds.minY + height + Self.buttonGap), anchor: .topLeading,
                          proposal: ProposedViewSize(width: more(cache) ? nil : 0, height: button))
    }
}

/// A plan's Markdown: its first 8 lines with a bottom fade, and under it "Show all · 23 lines" (→), "Show less" (←).
/// All its lines are one block in a place as tall as the first 8: opening rolls the place down to the whole plan, the
/// button riding its edge.
struct RouterPlan: View {
    let model: RouterModel
    let thread: RouterThread

    var body: some View {
        let open = model.expanded.contains(thread.id)
        let more = thread.plan.count > Router.Card.planLines
        VStack(alignment: .leading, spacing: 6) {
            // Cut where the first lines end in the layout that first places the plan: measured a turn later, a card
            // opening on a plan was as tall as the whole plan for a frame, and the rows under it went off the page and
            // came back.
            RouterPlanCut(cut: more && !open) {
                lines(thread.plan)
                lines(Array(thread.plan.prefix(Router.Card.planLines))).hidden()
            }
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(more && !open ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 40)
                    }
                }
            if more {
                RouterTextButton(model: model, hit: .longText(thread.id),
                                   title: open ? "Show less" : "Show all · \(thread.plan.count) lines",
                                   keys: [open ? "left" : "right"]) { model.expand(!open) }
            }
        }
    }

    private func lines(_ lines: [String]) -> some View {
        let d = CDS.Density.compact
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(RouterInline.text(line, size: d.prose.0)).cdsText(d.prose, .regular, CDS.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The plan's lines (the first view), as tall as its first lines (the second, not drawn) while `cut`, or all of them; both
/// measured in the same pass. What is past the cut is drawn: the plan clips it.
private struct RouterPlanCut: Layout {
    var cut: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = ProposedViewSize(width: proposal.width, height: nil)
        guard let all = subviews.first?.sizeThatFits(width) else { return .zero }
        guard cut, subviews.count > 1 else { return all }
        return CGSize(width: all.width, height: min(all.height, subviews[1].sizeThatFits(width).height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// A card's option rows: plain rows, no outline around them and no dividers between. Each has its own ground (the
/// pointer's, or the chosen fill once picked), reaching past the card's column so the radios sit on the column and the
/// keys on the footer's edge. A click or its digit picks one, nothing is sent.
struct RouterOptions: View {
    let model: RouterModel
    let thread: RouterThread
    let labels: [String]
    /// The options before these in the card: numbers run through a form.
    let from: Int
    /// The rows' ground past the column, at the leading edge.
    var reach: CGFloat = Router.Card.optionReach

    var body: some View {
        let picked = Set((model.picks[thread.id] ?? [:]).values)
        // With a draft, digits are words and Return sends the words: the rows show they are not what goes.
        let quiet = !model.draftEmpty
        VStack(spacing: 1) {
            ForEach(Array(labels.enumerated()), id: \.offset) { n, label in
                let number = from + n + 1
                RouterButton(model: model, hit: .option(thread.id, number), action: { model.pick(number) }) { hot, pressed in
                    RouterOptionRow(number: number, label: label, on: picked.contains(number), hot: hot, pressed: pressed, quiet: quiet,
                                      reach: reach)
                }
                .accessibilityLabel(label)
                .accessibilityAddTraits(picked.contains(number) ? .isSelected : [])
                .accessibilityHint("Option \(number)")
            }
        }
        .padding(.leading, -reach)
        .padding(.trailing, -(Router.Card.trailing - Router.Line.reach))
    }
}

/// One option: the approval card's radio, the label, its key. Picked: the accent radio and the chosen fill, at once.
struct RouterOptionRow: View {
    let number: Int
    let label: String
    let on: Bool
    let hot: Bool
    let pressed: Bool
    /// A draft is under way: the key is dim (the digit types) and a picked radio at half strength (it isn't sent).
    var quiet = false
    var reach: CGFloat = Router.Card.optionReach

    var body: some View {
        HStack(spacing: CDS.Approval.gap.sm) {
            ZStack {
                Circle().fill(on ? CDS.Fill.accent : .clear)
                if on { Circle().fill(.white).frame(width: 6, height: 6) } else { Circle().strokeBorder(CDS.borderStrong, lineWidth: 1) }
            }
            .frame(width: 16, height: 16)
            .opacity(on && quiet ? 0.5 : 1)
            Text(RouterInline.text(label, size: CDS.Density.compact.prose.0)).cdsText(CDS.Density.compact.prose, .regular, CDS.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if number <= 9 {
                RouterKeyHint(keys: ["shift", "\(number)"], ink: quiet ? Router.Surface.keyInk.opacity(0.5) : Router.Surface.keyInk)
            }
        }
        .motion(.fade, value: quiet)
        .padding(.vertical, 7).padding(.leading, reach).padding(.trailing, Router.Card.optionTrailing)
        .background {
            let s = Router.Surface.self
            RoundedRectangle(cornerRadius: s.row, style: .continuous)
                .fill(pressed ? s.pressed : on ? (hot ? s.chosenHover : s.chosen) : hot ? s.hover : .clear)
        }
        .hoverMotion(hot || on)
    }
}

/// The snooze menu at the card: for 1 hour, for 3 hours, until tomorrow 9:00; ↑↓ Return, or 1–3 (a digit acts at once
/// here: the act has a Revert).
struct RouterSnoozeMenuView: View {
    let model: RouterModel
    let menu: RouterSnoozeMenu

    var body: some View {
        let m = CDS.Menu.self
        VStack(alignment: .leading, spacing: 0) {
            Text(Router.Copy.snooze).font(CDS.sans(12, .medium)).foregroundStyle(CDS.Text.muted)
                .padding(.horizontal, m.itemPadX).frame(height: m.labelHeight)
            ForEach(Array(Router.Copy.snoozeChoices.enumerated()), id: \.offset) { n, choice in
                RouterButton(model: model, hit: .snoozeChoice(n), action: { model.chooseSnooze(n) }) { hot, _ in
                    HStack(spacing: m.itemGap) {
                        Text(choice).font(CDS.sans(13)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                        Spacer(minLength: m.hintGap)
                        RouterKeyHint(keys: ["shift", "\(n + 1)"])
                    }
                    .padding(.horizontal, m.itemPadX)
                    .frame(height: m.item + 2)
                    .background(RoundedRectangle(cornerRadius: m.itemRadius, style: .continuous)
                        .fill(menu.index == n || hot ? Router.Surface.hover : .clear))
                }
            }
        }
        .padding(m.pad)
        .frame(width: 200)
        .routerFloating()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Snooze")
    }
}
