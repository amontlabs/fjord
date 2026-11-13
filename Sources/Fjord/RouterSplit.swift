import AppKit
import SwiftUI

// A message split across threads (docs/design/router-v2/SPLIT.md). The composer stays plain: the owner's words and
// pills. The Router writes each destination's message from those words (their wording, trimmed of what belongs
// elsewhere, never rephrased) and the preview is on the page, on the targets: each target line or item has the arrow in
// its dot's slot and, under its row, a quiet line with what it will receive; a new thread is a ghost line in Working.
// Over the composer, one compact row a destination says the same: the arrow, the place as the page names it, what it
// receives (quoted to a thread, said as the answer to an item). The decider writes the parts (`RouterProjectDecision.sends`,
// the reader's `RouterRead.sends`); the cards' answers are sends by code (`answerSends`); Return sends every one.

/// A new thread the split starts, as its ghost line shows it.
struct RouterGhost: Equatable {
    var project: String
    var words: String
}

extension RouterModel {
    /// The sends the page shows, while there is a draft and no place you picked yourself for all of it: the cards'
    /// answers in the composer (by code, never read) and the read's parts of the words. With answers, the words read
    /// to one place are one more send. nil: the message goes to one place, as the usual destination row says.
    /// While the Router reads again, the parts the last read knew stay.
    var split: [RouterSend]? {
        guard !draft.isEmpty, explicit == nil, !waved else { return nil }
        let answers = hasAnswers ? answerSends : []
        var parts: [RouterSend] = []
        if !draftEmpty, let read {
            if !read.sends.isEmpty {
                parts = read.sends
            } else if !answers.isEmpty, let first = read.places.first,
                      // Words typed on the open card's form answer its question: the form's path, not a split.
                      !formTyping(first) {
                parts = [RouterSend(places: read.sure ? [read.places[0]] : Array(read.places.prefix(3)), sure: read.sure,
                                    words: plainDraft)]
            }
        }
        // Answers with words still unread: a split already (the words' row is the skeleton).
        let unread = !draftEmpty && parts.isEmpty && !answers.isEmpty
        guard answers.count + parts.count >= 2 || unread else { return nil }
        // Your own picks, by the part's words.
        for i in parts.indices where !parts[i].sure {
            if let mine = splitMine[parts[i].words], let at = parts[i].places.firstIndex(of: mine) {
                parts[i].lit = at
                parts[i].mine = true
            }
        }
        // Words to a thread that asks one thing answer it: its T3 question, or its one open Decide item.
        let answered = Set(answers.map(\.threadID))
        for i in parts.indices where parts[i].item == nil {
            guard let id = parts[i].threadID, !answered.contains(id), let t = thread(id) else { continue }
            parts[i].item = Self.asked(t)
        }
        return answers + parts
    }

    /// Words to the selected thread while its form is open: they answer its current question (`send`'s form path).
    private func formTyping(_ place: RouterPlace) -> Bool {
        guard case .thread(let id) = place, selection == .line(id), let t = thread(id) else { return false }
        return !t.form.isEmpty
    }

    /// The send ⌘1–3 light: the one Tab moved to, else the first the Router isn't sure of.
    var splitFocus: Int? {
        guard let split else { return nil }
        if let at = splitAt, at < split.count, !split[at].sure { return at }
        return split.firstIndex { !$0.sure }
    }

    /// Tab with a split: on to the next part the Router isn't sure of (round). False when none is unsure.
    @discardableResult func nextSplitPart() -> Bool {
        guard let split else { return false }
        let unsure = split.indices.filter { !split[$0].sure }
        guard !unsure.isEmpty else { return false }
        let now = splitFocus ?? unsure[0]
        let next = unsure.first { $0 > now } ?? unsure[0]
        animate(.fade) { splitAt = next }
        if let target = splitTarget(split[next]) { splitLit = target }
        return true
    }

    /// ⌘1–3 or a click on a place of the focused send: it is lit, and yours. False when no send asks for a place.
    @discardableResult func lightPart(_ index: Int, send: Int? = nil) -> Bool {
        guard let split, let at = send ?? splitFocus, at < split.count, !split[at].sure,
              index < min(3, split[at].places.count) else { return false }
        animate(.fade) {
            splitMine[split[at].words] = split[at].places[index]
            splitAt = at
        }
        return true
    }

    /// The one thing a thread asks that words to it answer (an item's id): its T3 question (one, no form), else its one
    /// open Decide item. nil: a plan, a permission, a form, several asks, or none.
    static func asked(_ t: RouterThread) -> String? {
        if let request = t.ledger.request {
            if case .ask(.question) = request.request, t.form.count <= 1 { return request.id }
            return nil
        }
        let decides = t.ledger.live.filter { $0.kind == .decide && !$0.preview }
        return decides.count == 1 ? decides[0].id : nil
    }

    /// Words that answer a thread's T3 question go as its structured answer: the option they name (its label, whatever
    /// the case and end punctuation), else typed. nil: they go as words.
    func requestAnswer(_ send: RouterSend) -> RouterOutgoing.Kind? {
        guard send.item == RouterItem.requestID, let id = send.threadID, let t = thread(id),
              case .needsYou(.question) = t.state, t.form.count <= 1 else { return nil }
        func plain(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        let options = t.form.first?.options ?? t.options
        if let at = options.firstIndex(where: { plain($0) == plain(send.words) }) {
            return .answer(picks: [0: at + 1], typed: [:])
        }
        return .answer(picks: [:], typed: [0: send.words])
    }

    /// Return on a split: every destination at once, each going Sent on its own line (a refusal is that line's, with Send
    /// again). The answers go by code (`sendWithAnswers`: a T3 request's first and structured, an item's as words to its
    /// thread, led into the words that go there too); the words' parts to their threads (steering a run, or queued behind
    /// it as any send) or a new thread started with the settings the row showed. One decision log entry for all of it.
    func sendSplit(_ sends: [RouterSend], queue: Bool = false) {
        // The answers lead the sends (`split`): the rest are the words' parts.
        let parts = sends.dropFirst(hasAnswers ? answerSends.count : 0).map { (words: $0.words, place: $0.place, kind: requestAnswer($0)) }
        source?.logSplit(plainDraft, sends: sends)
        // The parts go without the read: it was the whole message's (a new thread takes its first words for a name), and
        // the log has it once.
        let launch = launch
        read = nil
        sendWithAnswers(parts, queue: queue, launch: launch)
    }

    /// What each target on the page will receive, by thread id (the thread itself) or item key (an item it answers).
    /// Two sends to one target keep the first: the Router writes one message a destination.
    var pendingTargets: [String: RouterPending] {
        guard let split else { return [:] }
        var out: [String: RouterPending] = [:]
        for send in split {
            guard case .thread(let id) = send.place else { continue }
            let key = send.item.map { Self.itemKey(id, $0) } ?? id
            if out[key] == nil { out[key] = RouterPending(words: send.words, answer: send.item != nil, guess: !send.sure && !send.mine) }
        }
        return out
    }

    /// The new threads the split starts: a ghost line each.
    var ghosts: [RouterGhost] {
        split?.compactMap { send in
            if case .newThread(let project) = send.place { RouterGhost(project: project, words: send.words) } else { nil }
        } ?? []
    }

    /// The sends the rows over the composer show, by index, and how many more there are: the first few, with the one
    /// ⌘1–3 light always among them.
    var splitRows: (rows: [Int], more: Int) {
        guard let split else { return ([], 0) }
        var rows = Array(split.indices.prefix(Router.Split.rows))
        if let focus = splitFocus, !rows.contains(focus), !rows.isEmpty { rows[rows.count - 1] = focus }
        return (rows, split.count - rows.count)
    }

    /// The row on the page a send goes to: its item's row in a block, else its thread's line. nil: a new thread.
    func splitTarget(_ send: RouterSend) -> RouterHit? {
        guard case .thread(let id) = send.place else { return nil }
        if let item = send.item, box(id).block { return .row(Self.itemKey(id, item)) }
        return .row(id)
    }

    /// A click on a send's row: its target comes into view and lights (a new thread's ghost line comes into view).
    func revealSend(_ n: Int) {
        guard let split, n < split.count else { return }
        let send = split[n]
        if case .thread(let id) = send.place {
            splitLit = splitTarget(send)
            show(id)
        } else if case .newThread = send.place {
            let ghost = split[..<n].filter { if case .newThread = $0.place { true } else { false } }.count
            show("ghost-\(ghost)")
        }
    }
}

// MARK: - On the page

/// What a target will receive, under its row: a muted arrow in the mark's box, then the words, quoted (an item's
/// answer is said as the answer). Quiet: nothing has gone yet.
struct RouterPendingLine: View {
    let pending: RouterPending
    /// Where the arrow's box starts: under the row's mark.
    let leading: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Router.Line.markGap) {
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                .frame(width: Router.Line.markBox)
                .accessibilityHidden(true)
            Text(pending.answer ? pending.words : "“\(pending.words)”")
                .cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.secondary)
                .opacity(Router.Split.pendingInk)
                .lineLimit(Router.Split.pendingLines)
                .fixedSize(horizontal: false, vertical: true)
            // The Router's guess for a part it isn't sure of: the line over the composer asks (⌘1–3).
            if pending.guess {
                Text("· a guess").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).fixedSize()
            }
        }
        .padding(.leading, leading)
        .padding(.trailing, Router.Line.reach + Router.Line.ageWidth)
        .padding(.top, 1).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Return sends \(pending.answer ? pending.words : "“\(pending.words)”")\(pending.guess ? ", a guess" : "")")
    }
}

/// The arrow in a target's dot slot.
struct RouterTargetArrow: View {
    var body: some View {
        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.accent)
            .fixedSize()
    }
}

/// A new thread the message starts: a line in Working that isn't one yet. The arrow in its dot's slot, "New thread" on a
/// dashed ground where a name sits, its project pill in the pills' column, and under it what it will receive.
struct RouterGhostLine: View {
    let ghost: RouterGhost

    private typealias M = Router.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                RouterTargetArrow()
                    .frame(width: CDS.Dot.size, height: CDS.Dot.size)
                    .padding(.leading, M.dotLeading).padding(.trailing, M.dotGap)
                Text("New thread").font(CDS.sans(14, .medium)).foregroundStyle(CDS.Text.secondary).lineLimit(1)
                    .padding(.horizontal, M.namePadX).padding(.vertical, M.namePadY)
                    .background {
                        RoundedRectangle(cornerRadius: M.nameRadius, style: .continuous)
                            .strokeBorder(CDS.alpha(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                    }
                Spacer(minLength: M.pillGap)
                RouterProjectBadge(project: ghost.project)
                // The age's column stays empty: it hasn't started.
                Color.clear.frame(width: M.ageWidth, height: 1)
                    .padding(.leading, M.ageGap).padding(.trailing, M.reach)
            }
            .frame(minHeight: M.minHeight)
            RouterPendingLine(pending: RouterPending(words: ghost.words), leading: M.nameLeading + M.namePadX)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New thread in \(ghost.project): Return starts it with “\(ghost.words)”")
    }
}

// MARK: - Over the composer

/// One compact row a destination over the composer, as the page's pending lines say it: the arrow, the place as the
/// page names it (a thread's mark, name and project; an item's mark and words; `+ New thread` and its project), then
/// what it receives, quoted to a thread and said as the answer to an item, cut once at the end. Past a few rows,
/// "+N more". The part the Router isn't sure of shows its places on its row (⌘1–3). While the Router reads again the
/// rows it knows stay and a skeleton row with Fjord's mark stands for the rest. The pointer on a row lights its target
/// on the page; a click brings it into view.
struct RouterSplitRows: View {
    let model: RouterModel
    let sends: [RouterSend]

    var body: some View {
        let shown = model.splitRows
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown.rows, id: \.self) { n in
                RouterSplitRow(model: model, send: sends[n], n: n, focused: n == model.splitFocus)
                    .transition(.opacity)
            }
            if shown.more > 0 {
                Text("+\(shown.more) more").font(CDS.sans(12)).foregroundStyle(CDS.Text.muted)
                    .padding(.leading, Router.Thinking.row + 7)
                    .frame(height: Router.Split.rowHeight)
                    .contentTransition(.numericText(value: Double(shown.more)))
                    .accessibilityLabel("and \(shown.more) more places")
            }
            if model.reading {
                skeleton.transition(.opacity)
            }
        }
        .padding(.leading, CDS.Composer.pad + CDS.Composer.textInset - 2)
        .motion(.fade, value: shown.rows)
        .motion(.fade, value: model.reading)
        .motion(.fade, value: model.splitFocus)
        .onDisappear { model.splitLit = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Return sends to \(sends.count) places")
    }

    /// What the Router is still reading: Fjord's mark in the arrow's slot, a bar where the place will be.
    private var skeleton: some View {
        HStack(spacing: 7) {
            RouterThinking(tint: CDS.Text.accent, size: Router.Thinking.row, label: "Reading where the rest goes")
                .frame(width: Router.Thinking.row, height: Router.Thinking.row)
            let bar = RoundedRectangle(cornerRadius: Router.Dock.skeleton.height / 2, style: .continuous)
            bar.fill(CDS.alpha(0.06))
                .frame(width: Router.Dock.skeleton.width, height: Router.Dock.skeleton.height)
                .overlay { RouterSheen(color: RouterSheen.skeleton).mask { bar } }
        }
        .frame(height: Router.Split.rowHeight)
    }
}

/// One destination's row: `→ [place]  “words”`, or for the part ⌘1–3 light, `→ [places ⌘1–3]  “words”`.
private struct RouterSplitRow: View {
    let model: RouterModel
    let send: RouterSend
    let n: Int
    let focused: Bool
    @Namespace private var light
    @Namespace private var lightNarrow

    private var quoted: String { send.item != nil ? send.words : "“\(send.words)”" }

    var body: some View {
        HStack(spacing: 7) {
            RouterTargetArrow()
                .frame(width: Router.Thinking.row, height: Router.Thinking.row)
            if focused {
                ViewThatFits(in: .horizontal) {
                    places(pills: true, light: light)
                    places(pills: false, light: lightNarrow)
                }
                .layoutPriority(1)
            } else {
                place.layoutPriority(1)
            }
            Text(quoted).font(CDS.sans(13)).foregroundStyle(CDS.Text.secondary)
                .lineLimit(1).truncationMode(.tail)
            if !send.sure, !focused {
                Text("· a guess").font(CDS.sans(13)).foregroundStyle(CDS.Text.muted).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .frame(height: Router.Split.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.revealSend(n) }
        .onHover { inside in
            let hit = model.splitTarget(send)
            if inside { model.splitLit = hit } else if model.splitLit == hit { model.splitLit = nil }
        }
        .motion(.fade, value: send.words)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sends \(quoted) to \(name)\(send.sure ? "" : ", a guess")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.revealSend(n) }
    }

    private var name: String {
        if case .thread(let id) = send.place, let item = send.item,
           let found = model.item(key: RouterModel.itemKey(id, item))?.item {
            return RouterModel.short(found)
        }
        return model.name(send.place)
    }

    /// The place as the page names it.
    @ViewBuilder private var place: some View {
        switch send.place {
        case .thread(let id):
            if let item = send.item, let found = model.item(key: RouterModel.itemKey(id, item))?.item {
                HStack(spacing: 5) {
                    Image(systemName: found.kind.symbol).font(.system(size: Router.Line.mark, weight: .semibold))
                        .foregroundStyle(found.kind.tint)
                        .frame(width: Router.Line.markBox, height: Router.Line.markBox)
                    Text(RouterModel.short(found)).font(CDS.sans(13, .medium)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                }
                .fixedSize()
            } else {
                RouterPlaceView(model: model, place: send.place)
            }
        case .newThread(let project):
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(CDS.Text.secondary)
                    .frame(width: Router.Line.markBox, height: Router.Line.markBox)
                Text("New thread").font(CDS.sans(13, .medium)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                RouterProjectBadge(project: project)
            }
            .fixedSize()
        case .here:
            RouterPlaceView(model: model, place: send.place)
        }
    }

    /// The part's places, the guess lit, ⌘1–3.
    private func places(pills: Bool, light: Namespace.ID) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(send.places.prefix(3).enumerated()), id: \.offset) { i, place in
                Button { model.lightPart(i, send: n) } label: {
                    chip(place, i: i, lit: i == send.lit, pill: pills || i == send.lit, light: light)
                }
                .buttonStyle(.plain)
                .accessibilityLabel((i == send.lit ? "Sends to " : "Or ") + model.name(place))
            }
        }
        .fixedSize()
        .motion(.glass, value: send.lit)
        .motion(.fade, value: send.mine)
    }

    private func chip(_ place: RouterPlace, i: Int, lit: Bool, pill: Bool, light: Namespace.ID) -> some View {
        let s = Router.Surface.self
        let shape = RoundedRectangle(cornerRadius: s.control, style: .continuous)
        return HStack(spacing: 6) {
            RouterPlaceView(model: model, place: place, project: pill, ink: lit ? CDS.Text.primary : CDS.Text.secondary)
            RouterKeyHint(keys: ["cmd", "\(i + 1)"])
        }
        .padding(.horizontal, Router.Dock.placePadX)
        .frame(height: Router.Dock.place)
        .background {
            if lit {
                shape.fill(send.mine ? CDS.Text.accent.opacity(s.tintStrong) : s.chosen)
                    .matchedGeometryEffect(id: "light", in: light)
            }
        }
        .contentShape(shape)
    }
}
