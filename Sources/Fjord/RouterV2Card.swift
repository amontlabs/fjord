import AppKit
import SwiftUI

// Router v2's card (docs/design/router-v2/DESIGN.md 1.5): one component, inline under the selected line, inside the
// selected surface. T3's title, the agent's last lines, the kind's block (question, form, plan, permission, a step the
// model found, done, stopped, working, sent), and a footer of text buttons with their keys. Options only pick: Return
// sends what the destination row shows.

struct RouterV2Card: View {
    let model: RouterV2Model
    let thread: RouterV2Thread
    @Namespace private var rail
    @Environment(\.accessibilityReduceMotion) private var reduce

    private typealias M = RouterV2.Card
    private var d: CDS.Density { .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: M.gap) {
            Text(thread.title).cdsText(d.footnote, .regular, CDS.Text.muted).lineLimit(1).prose()
            if thread.loading {
                VStack(alignment: .leading, spacing: 8) {
                    RouterV2SkeletonBar(share: 0.92)
                    RouterV2SkeletonBar(share: 0.61)
                }
                .padding(.leading, M.railInset + 1)
                .padding(.vertical, 4)
                .prose()
                .transition(.opacity)
            } else if !thread.lastLines.isEmpty || thread.writing {
                RouterV2LastLines(model: model, thread: thread).prose().transition(.opacity)
            }
            kind
            footer
        }
        .padding(.leading, M.leading).padding(.trailing, M.trailing).padding(.bottom, M.bottom)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Kind blocks. Prose keeps to 560 pt; option rows run the card's width, their keycaps under the footer's.

    @ViewBuilder private var kind: some View {
        switch thread.state {
        case .needsYou(.question):
            if let question = thread.question { ask(question) }
            RouterV2Options(model: model, thread: thread, labels: thread.options, from: 0)
        case .needsYou(.form):
            form
        case .needsYou(.plan):
            RouterV2Plan(model: model, thread: thread).prose()
            RouterV2Options(model: model, thread: thread, labels: thread.options, from: 0)
        case .needsYou(.permission):
            if let p = thread.permission { permission(p).prose() }
            RouterV2Options(model: model, thread: thread, labels: thread.options, from: 0)
        case .needsYou(.step):
            if let question = thread.question { ask(question) }
            badges
            if !thread.options.isEmpty { RouterV2Options(model: model, thread: thread, labels: thread.options, from: 0) }
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
            // T3's to-do steps, when the thread has a list (Claude sends one only with T3's to-do setting on).
            if !thread.steps.isEmpty { steps.prose() }
        case .sent:
            if let sent = thread.sent {
                Text(sent.words).cdsText(d.body, .regular, CDS.Text.primary).fixedSize(horizontal: false, vertical: true).prose()
            }
            // A thread started here: what it starts with.
            if let launch = thread.launch { started(launch) }
        }
    }

    private func started(_ launch: RouterV2Launch) -> some View {
        Text(model.words(launch)).cdsText(d.footnote, .regular, CDS.Text.muted).lineLimit(1)
    }

    private func ask(_ text: String) -> some View {
        Text(RouterV2Inline.text(text, size: d.prose.0)).cdsText(d.prose, .regular, CDS.Text.primary)
            .fixedSize(horizontal: false, vertical: true).prose()
    }

    @ViewBuilder private var badges: some View {
        if !thread.prs.isEmpty {
            HStack(spacing: 6) {
                ForEach(thread.prs) { pr in
                    RouterV2PRBadge(pr: pr).routerV2Target(model, .prBadge(thread.id, pr.number)).routerV2Link()
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
                    RouterV2Options(model: model, thread: thread, labels: question.options, from: from, reach: 8)
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
    private func permission(_ p: RouterV2Thread.Permission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.command).font(CDS.mono(12)).foregroundStyle(CDS.Text.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: RouterV2.Surface.control, style: .continuous).fill(RouterV2.Surface.quiet))
            if !p.warning.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium))
                    Text(p.warning)
                }
                .cdsText(d.footnote, .regular, CDS.Text.warning)
            }
        }
    }

    private func stopped(_ stop: RouterV2Thread.Stop) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The reason on the danger ink's tint: a ground, no ring.
            let shape = RoundedRectangle(cornerRadius: RouterV2.Surface.row, style: .continuous)
            Text(stop.error).font(CDS.mono(12)).foregroundStyle(CDS.Text.primary).lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(RouterV2.dangerFill))
            (Text("Last step: ") + Text(RouterV2Inline.text(stop.lastStep, size: d.footnote.0)))
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
                        case .running: RouterV2WorkingDots(tint: CDS.Text.primary)
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
                RouterV2PushButton(model: model, hit: .footer(id, .rerun), title: RouterV2.Copy.continueTitle, keys: ["enter"]) {
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
                RouterV2TextButton(model: model, hit: .footer(id, .stop), title: "Stop") { model.stop(id) }
                openButton
            case .sent:
                openButton
            default:
                if thread.state == .needsYou(.step) {
                    RouterV2TextButton(model: model, hit: .footer(id, .notForMe), title: RouterV2.Copy.doesntNeedMe, removes: true) {
                        model.notForMe(id)
                    }
                }
                RouterV2TextButton(model: model, hit: .footer(id, .snooze), title: "Snooze", keys: ["alt", "cmd", "backspace"],
                                   removes: true) { model.openSnooze() }
                RouterV2TextButton(model: model, hit: .footer(id, .settle), title: "Settle", keys: ["cmd", "backspace"],
                                   removes: true) { model.settle(id) }
                openButton
            }
        }
        .padding(.top, 2)
    }

    private var openButton: some View {
        RouterV2TextButton(model: model, hit: .footer(thread.id, .open), title: "Open in T3", keys: ["cmd", "O"]) { model.open(thread.id) }
    }
}

private extension View {
    /// A card's prose keeps to a readable measure.
    func prose() -> some View { frame(maxWidth: RouterV2.Card.maxWidth, alignment: .leading) }
}

/// Inline Markdown as the Router's text has it, with code a little smaller than the words beside it (0.92 of their
/// size): at the same size mono reads a size bigger than the sans.
enum RouterV2Inline {
    static func text(_ markdown: String, size: CGFloat) -> AttributedString {
        var out = RouterText.inline(markdown)
        let code = CDS.mono((size * 0.92).rounded())
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].font = code
        }
        return out
    }
}

/// The agent's last message behind a rail: clipped to 4 lines (6 for Done) with a bottom fade; → rolls it open whole.
/// While the agent writes, the text grows live with a caret after its last word.
struct RouterV2LastLines: View {
    let model: RouterV2Model
    let thread: RouterV2Thread
    /// The whole text's height, and the height of its first lines (where it is cut while closed).
    @State private var full: CGFloat = 0
    @State private var cut: CGFloat = 0

    var body: some View {
        let d = CDS.Density.compact
        let open = model.expanded.contains(thread.id) && thread.plan.isEmpty
        let limit = thread.state == .done ? RouterV2.Card.lastLinesDone : RouterV2.Card.lastLines
        // The agent's words are Markdown: its inline code reads as code.
        let words = Text(RouterV2Inline.text(thread.lastLines, size: d.body.0))
        let text = (thread.writing ? words + RouterV2TextCaret.text : words).cdsText(d.body, .regular, CDS.Text.secondary)
        let clipped = !open && cut > 0 && full > cut + 1
        Group {
            if open, full > RouterV2.Card.openHeight {
                // Longer than the card allows: it scrolls.
                ScrollView {
                    text.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: RouterV2.Card.openHeight)
            } else {
                // The whole text, top-aligned in a place as tall as its first lines: open, the place rolls down to it.
                text.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full = $0 }
                    .frame(height: clipped ? cut : nil, alignment: .top)
                    .clipped()
                    .background(alignment: .topLeading) {
                        text.lineLimit(limit).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cut = $0 }
                            .hidden()
                    }
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: clipped ? 0.6 : 1),
                                               .init(color: .black.opacity(clipped ? 0 : 1), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
            }
        }
        .padding(.leading, RouterV2.Card.railInset)
        .overlay(alignment: .leading) { Rectangle().fill(CDS.Settings.railLine).frame(width: 1) }
    }
}

/// A plan's Markdown: its first 8 lines with a bottom fade, and under it "Show all · 23 lines" (→), "Show less" (←).
/// All its lines are one block in a place as tall as the first 8: opening rolls the place down to the whole plan, the
/// button riding its edge.
struct RouterV2Plan: View {
    let model: RouterV2Model
    let thread: RouterV2Thread
    /// The first lines' height: where the plan is cut while closed.
    @State private var cut: CGFloat = 0

    var body: some View {
        let open = model.expanded.contains(thread.id)
        let more = thread.plan.count > RouterV2.Card.planLines
        let clipped = more && !open && cut > 0
        VStack(alignment: .leading, spacing: 6) {
            lines(thread.plan)
                .frame(height: clipped ? cut : nil, alignment: .top)
                .clipped()
                .background(alignment: .topLeading) {
                    lines(Array(thread.plan.prefix(RouterV2.Card.planLines)))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cut = $0 }
                        .hidden()
                }
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(more && !open ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 40)
                    }
                }
            if more {
                RouterV2TextButton(model: model, hit: .longText(thread.id),
                                   title: open ? "Show less" : "Show all · \(thread.plan.count) lines",
                                   keys: [open ? "left" : "right"]) { model.expand(!open) }
            }
        }
    }

    private func lines(_ lines: [String]) -> some View {
        let d = CDS.Density.compact
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(RouterV2Inline.text(line, size: d.prose.0)).cdsText(d.prose, .regular, CDS.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card's option rows: plain rows, no outline around them and no dividers between. Each has its own ground (the
/// pointer's, or the chosen fill once picked), reaching past the card's column so the radios sit on the column and the
/// keys on the footer's edge. A click or its digit picks one, nothing is sent.
struct RouterV2Options: View {
    let model: RouterV2Model
    let thread: RouterV2Thread
    let labels: [String]
    /// The options before these in the card: numbers run through a form.
    let from: Int
    /// The rows' ground past the column, at the leading edge.
    var reach: CGFloat = RouterV2.Card.optionReach

    var body: some View {
        let picked = Set((model.picks[thread.id] ?? [:]).values)
        // With a draft, digits are words and Return sends the words: the rows show they are not what goes.
        let quiet = !model.draft.isEmpty
        VStack(spacing: 1) {
            ForEach(Array(labels.enumerated()), id: \.offset) { n, label in
                let number = from + n + 1
                RouterV2Button(model: model, hit: .option(thread.id, number), action: { model.pick(number) }) { hot, pressed in
                    RouterV2OptionRow(number: number, label: label, on: picked.contains(number), hot: hot, pressed: pressed, quiet: quiet,
                                      reach: reach)
                }
                .accessibilityLabel(label)
                .accessibilityAddTraits(picked.contains(number) ? .isSelected : [])
                .accessibilityHint("Option \(number)")
            }
        }
        .padding(.leading, -reach)
        .padding(.trailing, -(RouterV2.Card.trailing - RouterV2.Line.reach))
    }
}

/// One option: the approval card's radio, the label, its key. Picked: the accent radio and the chosen fill, at once.
struct RouterV2OptionRow: View {
    let number: Int
    let label: String
    let on: Bool
    let hot: Bool
    let pressed: Bool
    /// A draft is under way: the key is dim (the digit types) and a picked radio at half strength (it isn't sent).
    var quiet = false
    var reach: CGFloat = RouterV2.Card.optionReach

    var body: some View {
        HStack(spacing: CDS.Approval.gap.sm) {
            ZStack {
                Circle().fill(on ? CDS.Fill.accent : .clear)
                if on { Circle().fill(.white).frame(width: 6, height: 6) } else { Circle().strokeBorder(CDS.borderStrong, lineWidth: 1) }
            }
            .frame(width: 16, height: 16)
            .opacity(on && quiet ? 0.5 : 1)
            Text(RouterV2Inline.text(label, size: CDS.Density.compact.prose.0)).cdsText(CDS.Density.compact.prose, .regular, CDS.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if number <= 9 {
                RouterV2KeyHint(keys: ["shift", "\(number)"], ink: quiet ? RouterV2.Surface.keyInk.opacity(0.5) : RouterV2.Surface.keyInk)
            }
        }
        .motion(.fade, value: quiet)
        .padding(.vertical, 7).padding(.leading, reach).padding(.trailing, RouterV2.Card.optionTrailing)
        .background {
            let s = RouterV2.Surface.self
            RoundedRectangle(cornerRadius: s.row, style: .continuous)
                .fill(pressed ? s.pressed : on ? (hot ? s.chosenHover : s.chosen) : hot ? s.hover : .clear)
        }
        .hoverMotion(hot || on)
    }
}

/// The snooze menu at the card: for 1 hour, for 3 hours, until tomorrow 9:00; ↑↓ Return, or 1–3 (a digit acts at once
/// here: the act has a Revert).
struct RouterV2SnoozeMenuView: View {
    let model: RouterV2Model
    let menu: RouterV2SnoozeMenu

    var body: some View {
        let m = CDS.Menu.self
        VStack(alignment: .leading, spacing: 0) {
            Text(RouterV2.Copy.snooze).font(CDS.sans(12, .medium)).foregroundStyle(CDS.Text.muted)
                .padding(.horizontal, m.itemPadX).frame(height: m.labelHeight)
            ForEach(Array(RouterV2.Copy.snoozeChoices.enumerated()), id: \.offset) { n, choice in
                RouterV2Button(model: model, hit: .snoozeChoice(n), action: { model.chooseSnooze(n) }) { hot, _ in
                    HStack(spacing: m.itemGap) {
                        Text(choice).font(CDS.sans(13)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                        Spacer(minLength: m.hintGap)
                        RouterV2KeyHint(keys: ["shift", "\(n + 1)"])
                    }
                    .padding(.horizontal, m.itemPadX)
                    .frame(height: m.item + 2)
                    .background(RoundedRectangle(cornerRadius: m.itemRadius, style: .continuous)
                        .fill(menu.index == n || hot ? RouterV2.Surface.hover : .clear))
                }
            }
        }
        .padding(m.pad)
        .frame(width: 200)
        .routerV2Floating()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Snooze")
    }
}
