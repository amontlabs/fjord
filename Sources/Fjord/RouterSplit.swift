import AppKit
import SwiftUI

// A message split across threads (docs/design/router-v2/SPLIT.md). The composer stays plain: the owner's words and
// pills. The Router writes each destination's message from those words (their wording, trimmed of what belongs
// elsewhere, never rephrased) and the preview is on the page, on the targets: each target line or item has the arrow in
// its dot's slot and, under its row, a quiet line with what it will receive; a new thread is a ghost line in Working.
// Over the composer one short line says how many places Return sends to. Look only for now: the demo's reads carry the
// sends; the decider doesn't write them yet.

/// A new thread the split starts, as its ghost line shows it.
struct RouterGhost: Equatable {
    var project: String
    var words: String
}

extension RouterModel {
    /// The sends the page shows: the read's, while there is a draft and no place you picked yourself for all of it. nil:
    /// the message goes to one place, as the usual destination row says.
    var split: [RouterSend]? {
        guard !draft.isEmpty, explicit == nil, !waved, let sends = read?.sends, !sends.isEmpty else { return nil }
        return sends
    }

    /// The send ⌘1–3 light: the first one the Router isn't sure of.
    var splitFocus: Int? { split?.firstIndex { !$0.sure } }

    /// ⌘1–3 or a click on a place of the focused send: it is lit, and yours. False when no send asks for a place.
    @discardableResult func lightPart(_ index: Int, send: Int? = nil) -> Bool {
        guard split != nil, let at = send ?? splitFocus, var r = read, at < r.sends.count, !r.sends[at].sure,
              index < min(3, r.sends[at].places.count) else { return false }
        r.sends[at].lit = index
        r.sends[at].mine = true
        animate(.fade) { read = r }
        return true
    }

    /// What each target on the page will receive, by thread id (the thread itself) or item key (an item it answers).
    /// Two sends to one target keep the first: the Router writes one message a destination.
    var pendingTargets: [String: RouterPending] {
        guard let split else { return [:] }
        var out: [String: RouterPending] = [:]
        for send in split {
            guard case .thread(let id) = send.place else { continue }
            let key = send.item.map { Self.itemKey(id, $0) } ?? id
            if out[key] == nil { out[key] = RouterPending(words: send.words, answer: send.item != nil, guess: !send.sure) }
        }
        return out
    }

    /// The new threads the split starts: a ghost line each.
    var ghosts: [RouterGhost] {
        split?.compactMap { send in
            if case .newThread(let project) = send.place { RouterGhost(project: project, words: send.words) } else { nil }
        } ?? []
    }

    /// The places Return sends to, counted once each.
    var splitCount: Int {
        guard let split else { return 0 }
        var seen: [RouterPlace] = []
        for send in split where !seen.contains(send.place) { seen.append(send.place) }
        return seen.count
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

/// One short line over the composer: where Return sends (`3 threads · Return sends`, or the one place by name); the
/// mark and a sheen while the Router reads; the usual places, ⌘1–3, for a part it isn't sure of, named in a few words.
struct RouterSplitLine: View {
    let model: RouterModel
    let sends: [RouterSend]
    @Namespace private var light
    @Namespace private var lightNarrow

    var body: some View {
        HStack(spacing: 7) {
            lead
            if let focus = model.splitFocus {
                unsure(sends[focus], n: focus)
            } else {
                sure
            }
        }
        .padding(.leading, CDS.Composer.pad + CDS.Composer.textInset - 2)
        .frame(height: Router.Dock.rowHeight)
        .motion(.fade, value: model.splitFocus)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var label: String {
        if let focus = model.splitFocus {
            let send = sends[focus]
            return "Not sure where \(send.part ?? "a part") goes. Return sends it to \(model.name(send.place))"
        }
        return model.splitCount == 1 ? "Return sends to \(model.name(sends[0].place))" : "Return sends to \(model.splitCount) threads"
    }

    /// The arrow, and in its place Fjord's mark while the Router reads.
    private var lead: some View {
        ZStack {
            if model.reading {
                RouterThinking(tint: CDS.Text.accent, size: Router.Thinking.row, label: "Reading where it goes")
                    .transition(.opacity)
            } else {
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(CDS.Text.accent)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .frame(width: Router.Thinking.row, height: Router.Thinking.row)
        .motion(.fade, value: model.reading)
    }

    /// The place by name when there is one, else how many; then what Return does. Sheened while the Router reads again.
    private var sure: some View {
        let count = model.splitCount
        return sureWords(count)
            .overlay {
                // The band passes over the words only.
                if model.reading { RouterSheen().mask { sureWords(count) }.transition(.opacity) }
            }
            .motion(Router.counts, value: count)
            .motion(.fade, value: model.reading)
    }

    private func sureWords(_ count: Int) -> some View {
        HStack(spacing: 7) {
            if count == 1 {
                RouterPlaceView(model: model, place: sends[0].place)
            } else {
                Text("\(count) threads").font(CDS.sans(13, .medium)).foregroundStyle(CDS.Text.primary)
                    .contentTransition(.numericText(value: Double(count)))
            }
            Text("· Return sends").font(CDS.sans(13)).foregroundStyle(CDS.Text.muted)
        }
        .fixedSize()
    }

    /// The part named in a few words, its places (the guess lit, ⌘1–3), then what Return does.
    private func unsure(_ send: RouterSend, n: Int) -> some View {
        HStack(spacing: 7) {
            Text(send.part ?? "this part").font(CDS.sans(13)).foregroundStyle(CDS.Text.secondary).lineLimit(1).fixedSize()
            ViewThatFits(in: .horizontal) {
                places(send, n: n, pills: true, light: light)
                places(send, n: n, pills: false, light: lightNarrow)
            }
        }
    }

    private func places(_ send: RouterSend, n: Int, pills: Bool, light: Namespace.ID) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(send.places.prefix(3).enumerated()), id: \.offset) { i, place in
                Button { model.lightPart(i, send: n) } label: {
                    chip(place, i: i, lit: i == send.lit, mine: send.mine, pill: pills || i == send.lit, light: light)
                }
                .buttonStyle(.plain)
                .accessibilityLabel((i == send.lit ? "Sends to " : "Or ") + model.name(place))
            }
            Text("· Return sends").font(CDS.sans(13)).foregroundStyle(CDS.Text.muted).fixedSize().padding(.leading, 5)
        }
        .motion(.glass, value: send.lit)
        .motion(.fade, value: send.mine)
    }

    private func chip(_ place: RouterPlace, i: Int, lit: Bool, mine: Bool, pill: Bool, light: Namespace.ID) -> some View {
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
                shape.fill(mine ? CDS.Text.accent.opacity(s.tintStrong) : s.chosen)
                    .matchedGeometryEffect(id: "light", in: light)
            }
        }
        .contentShape(shape)
    }
}
