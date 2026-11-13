import SwiftUI

// Open items per thread (docs/design/router-v2/OPEN-ITEMS.md, DESIGN.md 1.15): each thread keeps a ledger of what is
// open with you (Stuck, Decide, Do, Know). The page shows one block per thread, in the section of its most urgent item;
// one item is the line itself, two or more make the thread's line a quiet header with an indented line per item. The
// demo's store fills the ledger today (RouterDemoItems.swift); the real engine fills the same type later: one read per
// turn end and per owner message, each item kept, closed (with how), merged (its age reset) or added.

/// One thing open with you on a thread.
struct RouterItem: Identifiable, Equatable {
    /// Four kinds, no more. Stuck first, then Decide and Do, then Know.
    enum Kind: String, CaseIterable, Equatable, Codable, Sendable {
        case stuck, decide, `do`, know

        /// The section its thread goes to when it is the thread's most urgent item.
        var section: RouterSection { self == .know ? .done : .needsYou }

        /// Lower is more urgent.
        var rank: Int {
            switch self {
            case .stuck: 0
            case .decide, .do: 1
            case .know: 2
            }
        }

        var word: String {
            switch self {
            case .stuck: "Stuck"
            case .decide: "Decide"
            case .do: "Do"
            case .know: "Know"
            }
        }

        var symbol: String {
            switch self {
            case .stuck: "exclamationmark.octagon.fill"
            case .decide: "questionmark.circle.fill"
            case .do: "checklist"
            case .know: "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .stuck: CDS.Text.danger
            case .decide, .do: CDS.Text.warning
            case .know: CDS.Text.accent
            }
        }
    }

    /// Where the item is in its life on the page. `checking`: a read (your message, a new turn) may close it; it sheens
    /// until the read lands. `closing`: the read closed it, with how ("answered by your message"); it strikes briefly,
    /// then folds away. `new`: the read just added it; it lands with a brief highlight, then is open.
    enum State: Equatable {
        case open, checking, closing(String), new
    }

    let id: String
    var kind: Kind
    /// What is open, in a short sentence (the model's).
    var sentence: String
    /// Since it was opened, or last restated (a merge resets it).
    var since: Date
    /// A choice's options, when the agent gave some: the item's card lists them.
    var options: [String] = []
    var state: State = .open

    var closing: Bool { if case .closing = state { true } else { false } }
    /// What a read under way found, shown before it lands (with the id it lands with): not in the ledger yet, so it
    /// has no Done.
    var preview = false
    /// Still open: counted, ranked, walked.
    var live: Bool { !closing }
}

/// A thread's open items and the read that may change them.
struct RouterLedger: Equatable {
    /// The read under way, if any: what it reads.
    enum Read: Equatable {
        /// Your words to the thread: they show as a line in the block (`↑ "…" · sent`) until the read lands.
        case message(String)
        /// A turn that just ended: a faint placeholder where new items land.
        case turn
    }

    var items: [RouterItem] = []
    var read: Read?
    /// Moves once per new turn: the header pulses once.
    var pulse = 0

    var live: [RouterItem] { items.filter(\.live) }
    var isEmpty: Bool { items.isEmpty }

    /// The most urgent open item's kind.
    var top: RouterItem.Kind? { live.min { $0.kind.rank < $1.kind.rank }?.kind }

    /// The thread shows as a block (a header with its items under it), not as one line: two or more items. One item stays
    /// the line through a read (REVIEW-items 5.1): it sheens on the line, your words follow it there, so a read doesn't
    /// turn the line into a block and back.
    var block: Bool { items.count >= 2 }

    /// The one item that is the line itself (a thread with one item and nothing else to show).
    var single: RouterItem? { !block && items.count == 1 ? items.first : nil }

    /// What the page counts as the block's rows: items, the sent line, the placeholder (their coming and going moves the
    /// lines under the block).
    var rows: [String] {
        items.map(\.id) + (read.map { if case .message = $0 { ["sent"] } else { ["reading"] } } ?? [])
    }
}

extension RouterItem {
    /// The mark and tint, as a line's `Look`.
    var look: RouterThread.Look {
        RouterThread.Look(symbol: kind.symbol, tint: kind.tint, ground: true, label: kind.word)
    }
}

extension Router {
    /// The block's rows (1.15): items indented under the header's name.
    enum Items {
        /// An item's row: shorter than a line, so a block reads as one thing.
        static let rowHeight: CGFloat = 28
        /// Items start under the header's name (its words, past the mark).
        static let indent: CGFloat = Line.nameLeading + Line.namePadX + Line.markBox + Line.markGap
        /// An item's mark sits under the name's words (`indent`), so its rows hang under the name.
        static let markLeading: CGFloat = indent
        static let mark: CGFloat = 9.5
        /// How long a closed item strikes before it folds away, and how long a new one's highlight holds.
        static let strike: Double = 1.6
        static let highlight: Double = 1.8
        /// The header's pulse on a new turn.
        static let pulse: Double = 0.7

        enum Copy {
            static let sent = "sent"
            static let readingTurn = "reading the new turn…"
            static let answered = "answered by your message"
            static let doneByAgent = "done by the agent"
            static let obsolete = "no longer open"
            static let doneByYou = "done by you"
            static let done = "Done"
            /// A turn or message Fjord couldn't read (T3 never had it): kept as a Know, so what it said isn't silently lost.
            static let unread = "a turn couldn't be read: open the thread to see what it said"
            static let unreadMessage = "a message of yours couldn't be read: open the thread to check it was answered"
        }
    }
}

// MARK: - The block's rows

/// The header of a thread with two or more items: its name as a one-item line's, with its most urgent item's mark and
/// tint on the name's ground (so a block reads as one thing, its colour on its name), the working dots and the newest
/// summary while it runs, its project and age; Fjord's mark at the end of its words while a read is under way.
struct RouterBlockHeader: View {
    let model: RouterModel
    let thread: RouterThread
    let hot: Bool
    @State private var pulse: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.routerStill) private var still

    private typealias M = Router.Line

    var body: some View {
        let running = thread.isRunning
        // The run working now's newest summary; an earlier run's is not what it does now (the code's line until it has one).
        let summary = running ? (thread.work.current ? thread.work.summaries.first?.text ?? thread.sentence.text : thread.sentence.text) : ""
        let top = thread.ledger.top
        let shape = RoundedRectangle(cornerRadius: M.nameRadius, style: .continuous)
        HStack(spacing: 0) {
            Color.clear.frame(width: CDS.Dot.size, height: CDS.Dot.size)
                .padding(.leading, M.reach).padding(.trailing, M.dotGap)
            name(top: top, running: running, shape: shape)
                .routerTarget(model, .name(thread.id))
                .layoutPriority(2)
            HStack(spacing: Router.Thinking.gap) {
                // Running with its mark taken by an item's kind: the dots lead its summary.
                if running, top != nil {
                    RouterWorkingDots(tint: CDS.Text.muted, paused: thread.paused).frame(width: M.markBox, height: M.markBox)
                }
                Text(summary).font(CDS.sans(14)).foregroundStyle(CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                // Being re-checked: Fjord's mark, where the activity glyphs sit (the words don't move as it comes).
                if thread.ledger.read != nil {
                    RouterThinking(label: "Fjord is checking what is open").transition(.opacity)
                }
            }
            .padding(.leading, M.sentenceGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let project = thread.project {
                RouterProjectPill(model: model, thread: thread.id, project: project)
                    .padding(.leading, M.pillGap)
                    .opacity(model.project == nil ? 1 : 0)
                    .layoutPriority(1)
            }
            RouterAge(model: model, since: thread.since)
                .padding(.leading, M.ageGap).padding(.trailing, M.reach)
                .layoutPriority(1)
        }
        .frame(minHeight: M.minHeight)
        // A new turn: the header's ground lights once and fades.
        .background {
            RoundedRectangle(cornerRadius: M.radius, style: .continuous).fill(Router.Surface.chosen).opacity(pulse)
        }
        .motion(.fade, value: thread.ledger.read)
        .onChange(of: thread.ledger.pulse) { _, _ in
            guard !reduce, !still else { return }
            var none = Transaction()
            none.disablesAnimations = true
            withTransaction(none) { pulse = 1 }
            withAnimation(Animation.easeOut(duration: Router.Items.pulse).resolved(reduce: reduce)) { pulse = 0 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(thread.name), \(thread.ledger.live.count) open")
    }

    /// The name as a one-item line's: the top kind's mark, the name in its tint, on its ground.
    private func name(top: RouterItem.Kind?, running: Bool, shape: RoundedRectangle) -> some View {
        let tint: Color = top?.tint ?? CDS.Text.primary
        let ground: Color = top.map { $0.tint.opacity(hot ? M.groundHover : M.ground) } ?? .clear
        return HStack(spacing: M.markGap) {
            if let top {
                RouterMark(look: RouterThread.Look(symbol: top.symbol, tint: top.tint, ground: true, label: top.word))
            } else {
                ZStack {
                    if running { RouterWorkingDots(tint: CDS.Text.muted, paused: thread.paused) }
                }
                .frame(width: M.markBox, height: M.markBox)
            }
            Text(thread.name).font(CDS.sans(14, .medium)).foregroundStyle(tint).lineLimit(1)
        }
        .padding(.horizontal, M.namePadX).padding(.vertical, M.namePadY)
        .background { shape.fill(ground) }
    }
}

/// An item's line in a block: its kind's mark in its tint under the name's words (no ground: the colour that asks is the
/// header's), its sentence, its age. Sheening while a read may close it; struck through with how it
/// closed; lit briefly as it lands.
struct RouterItemRow: View {
    let model: RouterModel
    let thread: String
    let item: RouterItem
    let selected: Bool
    let hot: Bool
    let pressed: Bool

    private typealias M = Router.Line
    private typealias I = Router.Items

    var body: some View {
        let closing = item.closing
        let checking = item.state == .checking
        HStack(spacing: 0) {
            kind
                .padding(.leading, I.markLeading)
            ZStack(alignment: .leading) {
                if case .closing(let how) = item.state {
                    HStack(spacing: 8) {
                        Text(item.sentence).font(CDS.sans(14)).foregroundStyle(CDS.Text.muted)
                            .strikethrough(true, color: CDS.Text.muted)
                            .lineLimit(1).truncationMode(.tail)
                        Text(how).font(CDS.sans(12)).foregroundStyle(CDS.Text.secondary).lineLimit(1).fixedSize()
                    }
                    .transition(.opacity)
                } else {
                    let text = Text(item.sentence).font(CDS.sans(14))
                    text.foregroundStyle(checking ? CDS.Text.muted : CDS.Text.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .overlay(alignment: .leading) {
                            if checking {
                                RouterSheen().mask(alignment: .leading) { text.lineLimit(1).truncationMode(.tail) }
                                    .transition(.opacity)
                            }
                        }
                        .transition(.opacity)
                }
            }
            .padding(.leading, M.markGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            RouterAge(model: model, since: item.since)
                .padding(.leading, M.ageGap).padding(.trailing, M.reach)
                .opacity(closing ? 0 : 1)
        }
        .frame(minHeight: I.rowHeight)
        .background {
            let shape = RoundedRectangle(cornerRadius: M.radius, style: .continuous)
            ZStack {
                // Just landed: the kind's tint, fading.
                shape.fill(item.kind.tint.opacity(Router.Surface.tint)).opacity(item.state == .new ? 1 : 0)
                shape.fill(selected ? .clear : pressed ? Router.Surface.pressed : hot ? Router.Surface.hover : .clear)
                    .transaction { $0.animation = nil }
            }
        }
        .motion(.fade, value: item.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kind.word): \(item.sentence)")
    }

    /// The kind's mark, quiet: its tint, no ground, no word (the accessibility label says it).
    private var kind: some View {
        Image(systemName: item.kind.symbol).font(.system(size: I.mark, weight: .semibold)).foregroundStyle(item.kind.tint)
            .frame(width: M.markBox, height: M.markBox)
            .opacity(item.closing ? 0.45 : 1)
            .accessibilityHidden(true)
    }
}

/// Your words in the block, the moment you send them: `↑ "…" · sent`, until the read lands.
struct RouterItemSentRow: View {
    let words: String

    var body: some View {
        HStack(spacing: Router.Line.markGap) {
            Image(systemName: "arrow.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.accent)
                .frame(width: Router.Line.markBox)
            Text("“\(words)”").font(CDS.sans(13)).foregroundStyle(CDS.Text.primary).lineLimit(1).truncationMode(.tail)
            Text("· " + Router.Items.Copy.sent).font(CDS.sans(13)).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
        }
        .frame(height: Router.Items.rowHeight)
        .padding(.leading, Router.Items.indent)
        .padding(.trailing, Router.Line.reach)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You sent: \(words)")
    }
}

/// Where a new turn's items land, while it is read: faint words, sheening.
struct RouterItemPlaceholder: View {
    var body: some View {
        let text = Text(Router.Items.Copy.readingTurn).font(CDS.sans(13))
        HStack(spacing: 0) {
            text.foregroundStyle(CDS.Text.disabled).lineLimit(1).fixedSize()
                .routerSheen { text.lineLimit(1).fixedSize() }
            Spacer(minLength: 0)
        }
        .frame(height: Router.Items.rowHeight)
        .padding(.leading, Router.Items.indent)
        .accessibilityLabel("Reading the new turn")
    }
}

// MARK: - An item's card

/// The selected item's card: its options (they pick; Return sends what the destination row shows) and Done, which closes
/// it with a Revert.
struct RouterItemCard: View {
    let model: RouterModel
    let thread: RouterThread
    let item: RouterItem

    var body: some View {
        let d = CDS.Density.compact
        let key = RouterModel.itemKey(thread.id, item.id)
        let picked = Set((model.picks[key] ?? [:]).values)
        let quiet = !model.draftEmpty
        VStack(alignment: .leading, spacing: Router.Card.gap) {
            if !item.options.isEmpty {
                VStack(spacing: 1) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { n, label in
                        let number = n + 1
                        RouterButton(model: model, hit: .option(key, number), action: { model.pick(number) }) { hot, pressed in
                            RouterOptionRow(number: number, label: label, on: picked.contains(number), hot: hot, pressed: pressed,
                                            quiet: quiet)
                        }
                        .accessibilityLabel(label)
                    }
                }
                .padding(.leading, -Router.Card.optionReach)
                .padding(.trailing, -(Router.Card.trailing - Router.Line.reach))
            }
            HStack(spacing: Router.Card.footerGap) {
                Spacer(minLength: 0)
                RouterTextButton(model: model, hit: .footer(key, .settle), title: Router.Items.Copy.done, keys: ["cmd", "backspace"],
                                 removes: true) { model.itemDone(thread.id, item.id) }
                RouterTextButton(model: model, hit: .footer(thread.id, .open), title: "Open in T3", keys: ["cmd", "O"]) {
                    model.open(thread.id)
                }
            }
            .padding(.top, 2)
        }
        .padding(.leading, Router.Items.indent + Router.Line.markBox + Router.Line.markGap + Router.Line.namePadX - Router.Line.namePadX)
        .padding(.trailing, Router.Card.trailing).padding(.bottom, Router.Card.bottom)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - A read of the ledger

/// What one read says of a thread's open items (OPEN-ITEMS.md "Model"): which close and how, which are restated
/// (merged: no duplicate, age reset), what is new. Items it doesn't name are kept as they were.
struct RouterLedgerRead: Equatable {
    var close: [String: String] = [:]
    var merge: Set<String> = []
    var add: [RouterItem] = []
}

extension RouterLedger {
    /// You sent words to the thread: they show in the block at once, and every open item is being re-checked.
    mutating func sent(_ words: String) {
        guard !live.isEmpty else { return }
        read = .message(words)
        check()
    }

    /// A turn ended: the header pulses once, the open items are being re-checked, a placeholder waits for new ones.
    mutating func turnEnded() {
        guard !live.isEmpty else { return }
        read = .turn
        pulse &+= 1
        check()
    }

    private mutating func check() {
        for i in items.indices where items[i].live { items[i].state = .checking }
    }

    /// The read landed: closed items strike with how, merged ones reset their age, new ones land lit, the rest stop
    /// sheening. `settle()` then folds the closed ones away and puts the new ones at rest.
    mutating func land(_ r: RouterLedgerRead, at now: Date) {
        for i in items.indices where items[i].live {
            if let how = r.close[items[i].id] {
                items[i].state = .closing(how)
            } else {
                items[i].state = .open
                if r.merge.contains(items[i].id) { items[i].since = now }
            }
        }
        items += r.add.map { var item = $0; item.state = .new; return item }
        read = nil
    }

    /// After the strike and the highlight: the closed items are gone, the new ones are open.
    mutating func settle() {
        items.removeAll(where: \.closing)
        for i in items.indices where items[i].state == .new { items[i].state = .open }
    }
}

// MARK: - The first block of a launch

/// The first block drawn in a launch took 41 ms to commit, later ones 7 to 16 ms (SwiftUI making the block's views and
/// their ticks for the first time, `FJORD_LOAD_BLOCKS`). Once the page is still after it opens, one block is laid out
/// off screen and dropped, so the first real one costs what the others do.
@MainActor enum RouterBlockWarmup {
    private static var done = false

    static func once(_ model: RouterModel) {
        guard !done, !model.still else { return }
        done = true
        MotionGate.whenStill {
            var t = RouterThread(id: "warmup", name: "Warmup", title: "Warmup", project: "fjord", state: .done,
                                 sentence: .init(text: "warm"), since: model.now)
            t.ledger.items = [RouterItem(id: "w1", kind: .decide, sentence: "keep it?", since: model.now, state: .checking),
                              RouterItem(id: "w2", kind: .know, sentence: "it is smaller", since: model.now, state: .new)]
            let view = VStack(spacing: 0) {
                RouterBlockHeader(model: model, thread: t, hot: false)
                ForEach(t.ledger.items) { RouterItemRow(model: model, thread: t.id, item: $0, selected: false, hot: false, pressed: false) }
                RouterItemSentRow(words: "warm")
            }
            .frame(width: 900)
            .modifier(Brand.Scheme())
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
        }
    }
}
