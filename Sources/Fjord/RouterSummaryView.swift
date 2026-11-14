import AppKit
import SwiftUI

// One layered structure for every thread and item (docs/design/router-v2/DESIGN.md 1.5, 1.6, R10): the hover is the line
// plus more, the card is the hover plus more, and nothing jumps between them or repeats.
// - Line: the sentence (what matters now), whole, wrapping under the name.
// - Hover: the sentence, then the detail (a sentence or two, if any) and the facts (quiet chips: `#41 merged`, `4 files
//   +96 −212`, `2 subagents · Opus 5.5`, `waiting on CI`); no quote (the card's quote mark has the agent's words).
// - Card, under its line (which says the sentence): the detail with the quote mark after it (with no detail, the mark
//   trails the line's sentence; the agent's words on hover, `RouterQuoteMark`), the facts, then the source (a plan, a permission's command, your words), the controls (options,
//   Continue), the thread's history (its timeline; for Working that is the source), then the footer's acts.
// The engine fills `RouterThread.summary` and `RouterThread.history`; an item's comes from the item itself.

struct RouterSummaryView: View {
    enum Layer {
        case hover
        /// The open card, with its line's box (its last lines as they grow).
        case card(RouterLineBox)
    }

    let model: RouterModel
    let thread: RouterThread
    /// The item the view is about: an item's row in a block.
    var item: RouterItem?
    let layer: Layer

    private typealias M = Router.Card
    private var d: CDS.Density { .compact }

    var body: some View {
        switch layer {
        case .hover: hover
        case .card(let box): RouterSummaryCard(model: model, box: box, thread: thread, item: item)
        }
    }

    // MARK: Hover

    private var hover: some View {
        let layers = RouterLayers(thread, item)
        return VStack(alignment: .leading, spacing: 8) {
            Text(RouterInline.text(layers.sentence, size: d.prose.0))
                .font(layers.mono ? CDS.mono(12) : CDS.sans(d.prose.0)).foregroundStyle(CDS.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            RouterLayerDetail(detail: layers.detail)
            RouterFacts(model: model, thread: thread, facts: layers.facts, live: false)
            // No quote: the agent's own words are the card's quote mark's (R11).
        }
        .routerPeekShell()
    }

    /// Whether a hover has more than the line says: a detail or a fact. A line that says it all has none.
    static func peeks(_ thread: RouterThread, _ item: RouterItem? = nil) -> Bool {
        let layers = RouterLayers(thread, item)
        return layers.detail != nil || !layers.facts.isEmpty
    }
}

extension EnvironmentValues {
    /// The card's words' column from its ground's edge, where the wide page (`RouterWide`) draws the card.
    @Entry var routerCardLeading: CGFloat? = nil
}

// MARK: - The layers' words

/// What a thread or an item says, layer by layer: the line's sentence, the detail, the facts and the quote. One reading
/// for the hover and the card, so they never disagree.
struct RouterLayers {
    enum Detail: Equatable {
        case words(String)
        /// A real stop's error: on the danger ground.
        case error(String)
    }

    var sentence: String
    var mono = false
    var detail: Detail?
    var facts: [RouterSummary.Fact] = []
    /// The agent's own words behind it: an item's quote, else (and for a thread) the thread's last message. None for a
    /// summed-up working thread (the last turn's words aren't news) or an ask whose card shows what it is about (a plan,
    /// a permission's command, your words).
    var quote: String?

    /// `lastLines`: the thread's last message where the record is the card's (its line's box keeps them apart).
    init(_ thread: RouterThread, _ item: RouterItem?, lastLines: String? = nil) {
        let last = Self.words(lastLines ?? thread.lastLines)
        // T3's request or the stop says what the thread's line said: the thread's own words and detail.
        if let item, item.request == nil {
            sentence = item.sentence
            detail = item.extra.map(Detail.words)
            facts = item.summary.facts
            quote = Self.words(item.quote) ?? last
            return
        }
        quote = Self.quotes(thread, asks: item != nil || thread.ledger.request == nil) ? last : nil
        // The header over a request: the thread's own words; the request's item says the rest.
        if item == nil, thread.ledger.request != nil {
            sentence = RouterBlockHeader.words(thread)
            facts = thread.summary?.facts ?? []
            return
        }
        sentence = thread.sentence.text
        mono = thread.sentence.mono
        facts = thread.summary?.facts ?? []
        if let words = thread.summary?.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty,
           words.caseInsensitiveCompare(sentence) != .orderedSame {
            detail = .words(words)
        } else if thread.state == .stopped, let stop = thread.stop {
            detail = .error(stop.error)
        } else if case .needsYou = thread.state, let ask = thread.question {
            detail = .words(ask)
        }
    }

    private static func words(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Whether the thread's card quotes its last message: not while the Router's summaries say what it does, nor for an
    /// ask that shows what it is about (`asks`: the card is the ask's, not the header's over it).
    private static func quotes(_ thread: RouterThread, asks: Bool) -> Bool {
        if thread.state == .working, thread.work.current { return false }
        guard asks else { return true }
        switch thread.state {
        case .needsYou(.plan), .needsYou(.permission), .sent: return false
        default: return true
        }
    }
}

/// Where a detail's quote mark goes: its thread and its item.
struct RouterQuoteMarkSpec {
    let model: RouterModel
    let thread: String
    let item: String?

    var hit: RouterHit { RouterQuoteMark.hit(thread, item) }
}

/// The detail: prose in the primary ink; a stop's error in mono on the danger ground, its words on the column.
struct RouterLayerDetail: View {
    let detail: RouterLayers.Detail?
    /// In the card, with a quote: the mark after the detail's last word.
    var mark: RouterQuoteMarkSpec?

    var body: some View {
        let d = CDS.Density.compact
        switch detail {
        case .words(let words)?:
            trailed(Text(RouterInline.text(words, size: d.prose.0)))
                .cdsText(d.prose, .regular, CDS.Text.primary)
                .fixedSize(horizontal: false, vertical: true).prose()
        case .error(let error)?:
            trailed(Text(error)).font(CDS.mono(12)).foregroundStyle(CDS.Text.primary).lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Router.Surface.row, style: .continuous).fill(Router.dangerFill))
                // The error's words on the column, its ground around them.
                .padding(.leading, -10)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func trailed(_ words: Text) -> some View {
        if let mark {
            RouterQuoteTrail(model: mark.model, hit: mark.hit, thread: mark.thread, words: words)
        } else {
            words
        }
    }
}

// MARK: - Facts

/// The facts as quiet chips, wrapping: a PR as its tinted badge (from the board, so its state word is live), the diff with
/// its counts in the git inks, the rest as words on the quiet ground with their kind's glyph. In the card a PR's badge
/// opens it; the hover is read-only.
struct RouterFacts: View {
    let model: RouterModel
    let thread: RouterThread
    let facts: [RouterSummary.Fact]
    /// In the card: a PR's badge is a link.
    let live: Bool

    var body: some View {
        if !facts.isEmpty {
            RouterChipFlow(spacing: 6) {
                ForEach(facts) { fact in chip(fact) }
            }
            // In the card, the first chip's words on the column, its ground around them.
            .padding(.leading, live ? -Router.Facts.pad : 0)
        }
    }

    @ViewBuilder private func chip(_ fact: RouterSummary.Fact) -> some View {
        if fact.kind == .pr, let pr = pr(fact) {
            if live {
                RouterPRBadge(pr: pr).routerTarget(model, .prBadge(thread.id, pr.number)).routerLink()
            } else {
                RouterPRBadge(pr: pr)
            }
        } else if fact.kind == .diff, let diff = thread.diff {
            plain(nil) {
                (Text(verbatim: "\(diff.files) file\(diff.files == 1 ? "" : "s")  ").foregroundColor(CDS.Text.secondary)
                    + Text(verbatim: "+\(diff.added)").foregroundColor(CDS.Git.added)
                    + Text(verbatim: "  −\(diff.removed)").foregroundColor(CDS.Git.removed))
                    .monospacedDigit()
            }
        } else {
            plain(Self.symbol(fact)) {
                Text(fact.text).foregroundColor(Self.ink(fact.tone))
            }
        }
    }

    /// The board's PR the fact is about: the one whose link it carries, else the thread's only one.
    private func pr(_ fact: RouterSummary.Fact) -> RouterThread.PR? {
        if let link = fact.link, let n = Int(link.lastPathComponent) { return thread.prs.first { $0.number == n } }
        return thread.prs.count == 1 ? thread.prs.first : nil
    }

    private func plain<Words: View>(_ symbol: String?, @ViewBuilder words: () -> Words) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .medium)).foregroundStyle(CDS.Text.muted)
            }
            words().font(CDS.sans(11, .medium)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, Router.Facts.pad)
        .frame(height: 18)
        .frame(maxWidth: Router.Facts.maxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous).fill(Router.Surface.quiet))
    }

    static func symbol(_ fact: RouterSummary.Fact) -> String? {
        switch fact.kind {
        case .agents: Router.Activity.subagent
        case .commands: Router.Activity.process
        case .waits: Router.Activity.wait
        case .tests: fact.tone == .bad ? "xmark" : "checkmark"
        case .pr, .diff, .note: nil
        }
    }

    static func ink(_ tone: RouterSummary.Fact.Tone) -> Color {
        switch tone {
        case .neutral: CDS.Text.secondary
        case .good: CDS.BadgeTint.successText
        case .warning: CDS.Text.warning
        case .bad: CDS.Text.danger
        }
    }
}

extension Router {
    enum Facts {
        /// A chip's longest: a long command or title is cut in its middle.
        static let maxWidth: CGFloat = 300
        /// A chip's words from its ground's edge (as a PR badge's).
        static let pad: CGFloat = 6
    }
}

/// Chips in rows: each as wide as its words, wrapping to a next row when the next doesn't fit.
struct RouterChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.last.map { $0.x + $0.size.width } ?? 0 }.max() ?? 0
        let height = rows.last.flatMap { row in row.map { $0.y + $0.size.height }.max() } ?? 0
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var i = 0
        for row in arrange(bounds.width, subviews) {
            for p in row {
                subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: ProposedViewSize(p.size))
                i += 1
            }
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [[(x: CGFloat, y: CGFloat, size: CGSize)]] {
        var rows: [[(x: CGFloat, y: CGFloat, size: CGSize)]] = [[]]
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rows[rows.count - 1].append((x, y, size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return rows
    }
}

// MARK: - The card

/// The card layer: the detail (with the quote mark after it) and the facts as the hover shows them, the source, the
/// controls, the history, the footer. Every kind's card is this one view; an item's in a block starts under its row's
/// words and has no history (the header's card has it).
private struct RouterSummaryCard: View {
    let model: RouterModel
    let box: RouterLineBox
    let thread: RouterThread
    let item: RouterItem?
    @Namespace private var rail
    @Environment(\.routerCardLeading) private var leading
    /// Off over an open item (`RouterWidePane`): no footer; the thread's acts wait for its header.
    @Environment(\.routerThreadActs) private var threadActs

    private typealias M = Router.Card
    private var d: CDS.Density { .compact }

    var body: some View {
        let _ = RouterBodies.count("card", box.id, of: model)
        // Whether it quotes: the line's box has the last lines (the record's are blanked so the card doesn't redraw as they
        // grow); the mark only needs to know there are some.
        let layers = RouterLayers(thread, item, lastLines: box.talking ? "…" : "")
        let inBlock = item != nil && thread.ledger.block
        let mark = layers.quote == nil ? nil : RouterQuoteMarkSpec(model: model, thread: thread.id, item: item?.id)
        return VStack(alignment: .leading, spacing: M.gap) {
            if layers.detail != nil {
                RouterLayerDetail(detail: layers.detail, mark: mark)
            }
            // No detail: the mark trails the sentence the card is about, where that is drawn (`RouterQuoteMark.onSentence`).
            // A working thread's chips that only count its subagents, commands or waits give way to their rows.
            RouterFacts(model: model, thread: thread,
                        facts: RouterCardActivity.shows(thread, item: item)
                            ? layers.facts.filter { !RouterCardActivity.covers($0, thread.activity) } : layers.facts,
                        live: true)
            source
            // What answers it comes before the past: the controls, then the thread's history, newest first, on every
            // thread's card but an item's in a block (its header's card has it); for a summed-up working thread it
            // is the source itself. Then the footer's acts.
            controls
            if !inBlock, RouterTimeline.has(thread) { RouterTimeline(model: model, thread: thread) }
            // Over an open item the thread's card has no footer: Open in T3 is an icon in the pane's name row.
            if threadActs { footer }
        }
        .padding(.leading, leading ?? (inBlock ? Router.Items.indent + M.hang : M.leading))
        // With no footer (over an open item) the history's own fade ends it: the item's gap is the only space under it.
        .padding(.trailing, M.trailing).padding(.bottom, threadActs ? M.bottom : 0)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The card answers T3's request or the stop: the request's item's card (the line's, for a thread whose record has
    /// none, as in a test). The header's card over a request is the thread's: its words and history, not the request.
    private var asks: Bool { item.map { $0.request != nil } ?? (thread.ledger.request == nil) }

    // MARK: Source: what the ask is about (the agent's own words are the quote mark's)

    @ViewBuilder private var source: some View {
        if let item, item.request == nil {
            let links = item.links
            if !links.isEmpty {
                let key = RouterModel.itemKey(thread.id, item.id)
                HStack(spacing: 6) {
                    ForEach(Array(links.enumerated()), id: \.offset) { n, url in
                        RouterLinkButton(model: model, hit: .link(key, n), url: url)
                    }
                }
                // The first link's words on the column, its ground around them.
                .padding(.leading, -8)
            }
        } else if thread.loading {
            VStack(alignment: .leading, spacing: 8) {
                RouterSkeletonBar(share: 0.92)
                RouterSkeletonBar(share: 0.61)
            }
            .padding(.vertical, 4)
            .prose()
            .transition(.opacity)
        } else {
            switch asks ? thread.state : .done {
            case .needsYou(.plan):
                RouterPlan(model: model, thread: thread).prose()
            case .needsYou(.permission):
                if let p = thread.permission { permission(p).prose() }
            case .sent:
                if let sent = thread.sent {
                    Text(sent.words).cdsText(d.body, .regular, CDS.Text.primary).fixedSize(horizontal: false, vertical: true).prose()
                }
            default:
                EmptyView()
            }
            if asks, thread.state == .stopped, let step = thread.stop?.lastStep, !step.isEmpty {
                (Text("Last step: ") + Text(RouterInline.text(step, size: d.footnote.0)))
                    .cdsText(d.footnote, .regular, CDS.Text.muted)
            }
            // A thread started here: what it runs on, through its first run.
            if thread.isRunning, let launch = thread.launch {
                Text(model.words(launch)).cdsText(d.footnote, .regular, CDS.Text.muted).lineLimit(1)
            }
            // T3's to-do steps, when the thread has a list (Claude sends one only with T3's to-do setting on).
            if thread.state == .working, !thread.steps.isEmpty { steps.prose() }
            // Then its subagents, background commands and waits, each on a row with its age.
            if RouterCardActivity.shows(thread, item: item) { RouterCardActivity(model: model, thread: thread) }
        }
    }

    /// T3's to-do steps: done, the running one with the dots, pending; five at most.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(thread.steps.prefix(M.steps)) { step in
                HStack(spacing: M.glyphGap) {
                    ZStack {
                        switch step.state {
                        case .done: Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                        case .running: RouterWorkingDots(tint: CDS.Text.primary)
                        case .pending: Circle().strokeBorder(CDS.borderStrong, lineWidth: 1).frame(width: 7, height: 7)
                        }
                    }
                    .frame(width: M.glyphBox, height: 14)
                    Text(step.text).cdsText(d.footnote, .regular, step.state == .running ? CDS.Text.primary : CDS.Text.muted).lineLimit(1)
                }
            }
            if thread.steps.count > M.steps {
                Text(verbatim: "+\(thread.steps.count - M.steps) more").cdsText(d.footnote, .regular, CDS.Text.muted).padding(.leading, M.hang)
            }
        }
        // The marks hang left of the column; the steps' words start on it.
        .padding(.leading, -M.hang)
    }

    /// The command and its warning. T3 sends no reason with a permission: the line's words say what it is for.
    private func permission(_ p: RouterThread.Permission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.command).font(CDS.mono(12)).foregroundStyle(CDS.Text.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Router.Surface.control, style: .continuous).fill(Router.Surface.quiet))
                // The command's words on the column, its ground around them.
                .padding(.leading, -8)
            if !p.warning.isEmpty {
                HStack(spacing: M.glyphGap) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium)).frame(width: M.glyphBox)
                    Text(p.warning)
                }
                .cdsText(d.footnote, .regular, CDS.Text.warning)
                .padding(.leading, -M.hang)
            }
        }
    }

    // MARK: Controls: options, then the footer

    @ViewBuilder private var controls: some View {
        if asks, thread.state == .stopped {
            // T3 has no rerun: Continue sends its words for it, and the destination row shows them. It answers the
            // stop, so it sits with the controls, before the history.
            RouterPushButton(model: model, hit: .footer(thread.id, .rerun), title: Router.Copy.continueTitle, keys: ["enter"]) {
                model.resume(thread.id)
            }
            // Its title on the column, its ground around it.
            .padding(.leading, -8)
        }
        if let item, item.request == nil {
            if !item.options.isEmpty {
                RouterOptions(model: model, key: RouterModel.itemKey(thread.id, item.id), labels: item.options, from: 0)
            }
        } else if asks, case .needsYou(let request) = thread.state {
            if !thread.live {
                // A request T3 can no longer answer (IMPLEMENTATION.md 1.3): no options, Open in T3 in their place.
                HStack(spacing: 10) {
                    Text(Router.Copy.notLive).cdsText(d.footnote, .regular, CDS.Text.muted).lineLimit(2)
                    RouterPushButton(model: model, hit: .footer(thread.id, .open), title: "Open in T3", keys: ["cmd", "O"]) {
                        model.open(thread.id)
                    }
                }
            } else if request == .form {
                form
            } else {
                RouterOptions(model: model, key: thread.id, labels: thread.options, from: 0)
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
                    RouterOptions(model: model, key: thread.id, labels: question.options, from: from, reach: M.formReach)
                    if let typed = model.typed[thread.id]?[q] {
                        Text("Your answer: \(typed)").cdsText(d.body, .regular, CDS.Text.secondary).lineLimit(2)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .leading) {
                    // Hung in the gutter, left of the radios and their grounds.
                    if q == at {
                        RoundedRectangle(cornerRadius: 1).fill(CDS.Text.accent).frame(width: 2)
                            .matchedGeometryEffect(id: "rail", in: rail)
                            .offset(x: -(M.radioHang + M.formReach + 4))
                    }
                }
            }
        }
        .motion(.spatial, value: at)
        .motion(.fade, value: model.answeredCount(thread))
    }

    private var footer: some View {
        let id = thread.id
        return HStack(spacing: M.footerGap) {
            if asks, thread.state == .needsYou(.form) {
                Text(verbatim: "\(model.answeredCount(thread)) of \(thread.form.count) answered")
                    .cdsText(d.footnote, .regular, CDS.Text.muted).contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if let item, item.request == nil {
                RouterTextButton(model: model, hit: .footer(RouterModel.itemKey(id, item.id), .settle), title: Router.Items.Copy.done,
                                 keys: ["cmd", "backspace"], removes: true) { model.itemDone(id, item.id) }
                // No Open in T3: it can't open at the item's place (⌘O still opens the thread).
            } else if let item {
                // T3's request or the stop: its Done is the thread's Settle, off while T3 holds the thread.
                if let why = model.holdReason(thread) {
                    RouterHeldActs(why: why, acts: [Router.Items.Copy.done])
                } else {
                    RouterTextButton(model: model, hit: .footer(RouterModel.itemKey(id, item.id), .settle), title: Router.Items.Copy.done,
                                     keys: ["cmd", "backspace"], removes: true) { model.itemDone(id, item.id) }
                }
                // No Open in T3 (⌘O still opens the thread); a request T3 can no longer answer has it in its options' place.
            } else {
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
        }
        .padding(.top, 2)
    }

    private var openButton: some View {
        RouterTextButton(model: model, hit: .footer(thread.id, .open), title: "Open in T3", keys: ["cmd", "O"]) { model.open(thread.id) }
    }
}
