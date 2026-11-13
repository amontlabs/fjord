import AppKit
import SwiftUI

// A message split across threads (docs/design/router-v2/SPLIT.md): the read returns one send a destination, each with
// the owner's own words for it and the answer pills it carries. Before Return the destination row becomes one compact
// row a destination, and the composer tints each part's words in its destination's colour, so you see which words go
// where. Look only for now: the demo's reads carry the sends; the decider doesn't write them yet.

extension RouterModel {
    /// The sends the rows show: a read that split the message, or, while the read is under way, the sends code already
    /// knows (the answer pills). nil when the message goes to one place (the usual row), or once you pick a place yourself.
    var split: [RouterSend]? {
        guard !draft.isEmpty, explicit == nil, !waved, let sends = read?.sends, !sends.isEmpty,
              sends.count > 1 || reading else { return nil }
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

    /// Each character of the draft, the send whose words it is: a part is found where it stands in the draft, verbatim
    /// (a part the draft doesn't hold is never shown). Words two sends share keep the first one's colour.
    var splitInk: [Int?]? {
        guard let split else { return nil }
        let chars = Array(draft)
        var ink = [Int?](repeating: nil, count: chars.count)
        for (n, send) in split.enumerated() {
            for part in send.parts {
                guard let r = draft.range(of: part) else { continue }
                let from = draft.distance(from: draft.startIndex, to: r.lowerBound)
                let to = from + draft[r].count
                for i in from..<to where ink[i] == nil { ink[i] = n }
            }
        }
        return ink
    }

    /// The send an answer pill (by its order among the draft's pills) goes with.
    func splitSend(answer pill: Int) -> Int? { split?.firstIndex { $0.answers.contains(pill) } }
}

// MARK: - Rows

/// One compact row a destination, in the order their words come in the message; while the read is under way, the
/// sends code already knows and one more row with Fjord's mark where the rest will be.
struct RouterSplitRows: View {
    let model: RouterModel
    let sends: [RouterSend]

    var body: some View {
        VStack(alignment: .leading, spacing: Router.Split.rowGap) {
            ForEach(Array(sends.enumerated()), id: \.offset) { n, send in
                RouterSplitRow(model: model, send: send, n: n, focused: model.splitFocus == n)
            }
            if model.reading {
                RouterSplitReading()
                    .transition(.opacity)
            }
        }
        .motion(.fade, value: sends)
        .motion(.fade, value: model.reading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Goes to \(sends.count) places")
    }
}

/// The mark in the arrow's slot and a skeleton where the place will be: the Router reading the words no pill places.
private struct RouterSplitReading: View {
    var body: some View {
        HStack(spacing: 7) {
            RouterThinking(tint: CDS.Text.accent, size: Router.Thinking.row, label: "Reading where the rest goes")
                .frame(width: Router.Thinking.row, height: Router.Thinking.row)
            let bar = RoundedRectangle(cornerRadius: Router.Dock.skeleton.height / 2, style: .continuous)
            bar.fill(CDS.alpha(0.06))
                .frame(width: Router.Dock.skeleton.width, height: Router.Dock.skeleton.height)
                .overlay { RouterSheen(color: RouterSheen.skeleton).mask { bar } }
                .accessibilityHidden(true)
        }
        .padding(.leading, CDS.Composer.pad + CDS.Composer.textInset - 2)
        .frame(height: Router.Dock.rowHeight)
    }
}

/// A destination: the arrow, its place (or its places, when unsure), then its words as quotes on its tint (the same
/// ground they have in the composer) and its answers.
private struct RouterSplitRow: View {
    let model: RouterModel
    let send: RouterSend
    let n: Int
    /// The send ⌘1–3 light: its places show their keys.
    let focused: Bool
    @Namespace private var light
    @Namespace private var lightNarrow

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(CDS.Text.accent)
                .frame(width: Router.Thinking.row, height: Router.Thinking.row)
                .accessibilityHidden(true)
            if send.sure {
                RouterPlaceView(model: model, place: send.place)
                words
            } else {
                // Every place with its project pill when the row has the room; else only the lit one keeps its pill.
                ViewThatFits(in: .horizontal) {
                    places(pills: true, light: light)
                    places(pills: false, light: lightNarrow)
                }
            }
        }
        .padding(.leading, CDS.Composer.pad + CDS.Composer.textInset - 2)
        .frame(height: Router.Dock.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        let what = send.parts.map { "“\($0)”" } + answerNames.map { "the answer \($0)" }
        let to = model.name(send.place)
        return send.sure ? "\(what.joined(separator: " and ")) to \(to)"
            : "Not sure where \(what.joined(separator: " and ")) goes. Return sends it to \(to)"
    }

    private var answerNames: [String] {
        send.answers.compactMap { $0 < model.mentions.count ? model.mentions[$0].name : nil }
    }

    /// Its quotes, then its answers: "+ 1 answer" after words; alone, the answer itself, as a picked option's row says it.
    @ViewBuilder private var words: some View {
        let tint = Router.Split.tint(n)
        HStack(spacing: 4) {
            ForEach(Array(send.parts.enumerated()), id: \.offset) { _, part in
                Text(part).font(CDS.sans(13)).foregroundStyle(CDS.Text.primary).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, Router.Split.quotePadX)
                    // Its words' own width, up to the cap: the ground hugs them.
                    .frame(width: min(Self.width(part) + 2 * Router.Split.quotePadX, Router.Split.quoteWidth),
                           height: Router.Split.quote, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Router.Surface.token, style: .continuous)
                        .fill(tint.opacity(Router.Split.ground)))
            }
            let answers = answerNames
            if !answers.isEmpty {
                if send.parts.isEmpty {
                    Text("answers").font(CDS.sans(13)).foregroundStyle(CDS.Text.muted)
                    Text("“\(answers.joined(separator: "”, “"))”").font(CDS.sans(13)).foregroundStyle(CDS.Text.primary)
                        .lineLimit(1)
                } else {
                    Text(answers.count == 1 ? "+ 1 answer" : "+ \(answers.count) answers")
                        .font(CDS.sans(13)).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
                        .padding(.leading, 2)
                }
            }
        }
    }

    private static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: CDS.nsSans(13)]).width) + 1
    }

    /// Unsure: up to three places, the lit one on its ground (the accent's tint once you lit it), the keys only on the
    /// send ⌘1–3 light, then its words.
    private func places(pills: Bool, light: Namespace.ID) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(send.places.prefix(3).enumerated()), id: \.offset) { i, place in
                Button { model.lightPart(i, send: n) } label: {
                    chip(place, i: i, lit: i == send.lit, pill: pills || i == send.lit, light: light)
                }
                .buttonStyle(.plain)
                .accessibilityLabel((i == send.lit ? "Sends to " : "Or ") + model.name(place))
            }
            words.padding(.leading, 5)
        }
        .motion(.glass, value: send.lit)
        .motion(.fade, value: send.mine)
    }

    private func chip(_ place: RouterPlace, i: Int, lit: Bool, pill: Bool, light: Namespace.ID) -> some View {
        let s = Router.Surface.self
        let shape = RoundedRectangle(cornerRadius: s.control, style: .continuous)
        return HStack(spacing: 6) {
            RouterPlaceView(model: model, place: place, project: pill, ink: lit ? CDS.Text.primary : CDS.Text.secondary)
            if focused { RouterKeyHint(keys: ["cmd", "\(i + 1)"]) }
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
