import AppKit
import SwiftUI

// Router v2's card (docs/design/router-v2/DESIGN.md 1.5): inline under the selected line, inside the selected surface;
// the card layer of the one layered view (`RouterSummaryView`). This file holds its pieces: a quote's cut, the plan, the
// option rows, the snooze menu. Options only pick: Return sends what the destination row shows.

struct RouterCard: View {
    let model: RouterModel
    /// Its line's box: the card redraws when the record does, not as the reply grows.
    let box: RouterLineBox

    /// The open item's card: the block's focused item.
    private var item: RouterItem? {
        box.item.flatMap { focus in box.head.ledger.items.first { $0.id == focus } }
    }

    var body: some View {
        RouterSummaryView(model: model, thread: box.head, item: item, layer: .card(box))
    }
}

/// Snooze and Settle where T3 refuses them (a request waits, a run is live): off, with the reason before them.
struct RouterHeldActs: View {
    let why: String
    /// The acts held: the thread's Snooze and Settle, or a request's Done.
    var acts = ["Snooze", "Settle"]

    var body: some View {
        let d = CDS.Density.compact
        HStack(spacing: 10) {
            Text(why).cdsText(d.caption, .regular, CDS.Text.muted).lineLimit(1).fixedSize()
            ForEach(acts, id: \.self) { act in
                Text(act).cdsText(d.footnote, .regular, CDS.Text.muted).opacity(0.45).fixedSize()
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(acts.joined(separator: " and ")) \(acts.count == 1 ? "is" : "are") off: \(why)")
    }
}

extension View {
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
    /// Whose picks they are: the thread's id, or an item's key.
    let key: String
    let labels: [String]
    /// The options before these in the card: numbers run through a form.
    let from: Int
    /// The rows' ground past the column, at the leading edge.
    var reach: CGFloat = Router.Card.optionReach

    /// The form's question these options are of (0 for a single question or an item).
    private var question: Int {
        guard let t = model.thread(key), !t.form.isEmpty, t.numbered.indices.contains(from) else { return 0 }
        return t.numbered[from].question
    }

    var body: some View {
        let picked = Set((model.picks[key] ?? [:]).values)
        // With a draft, digits are words and Return sends the words: the rows show they are not what goes.
        let quiet = !model.draftEmpty
        VStack(spacing: 1) {
            ForEach(Array(labels.enumerated()), id: \.offset) { n, label in
                let number = from + n + 1
                RouterButton(model: model, hit: .option(key, number), action: { model.pick(number) }) { hot, pressed in
                    RouterOptionRow(number: number, label: label, on: picked.contains(number), hot: hot, pressed: pressed, quiet: quiet,
                                      reach: reach)
                }
                .accessibilityLabel(label)
                .accessibilityAddTraits(picked.contains(number) ? .isSelected : [])
                .accessibilityHint("Option \(number)")
            }
            // Every Decide and form has its own words too: typed here, they are the answer, live in its pill.
            RouterOtherRow(model: model, key: key, question: question, reach: reach)
        }
        // The radios hang left of the column; the labels start on it.
        .padding(.leading, -(reach + Router.Card.radioHang))
        .padding(.trailing, -Router.Card.optionReach)
    }
}

/// A card's Other: an option row whose label is a field. Typed, its radio is on and its ground chosen, as a picked
/// option's; the words are the card's answer and show live in its pill in the composer (`RouterAnswerPills`).
struct RouterOtherRow: View {
    let model: RouterModel
    let key: String
    let question: Int
    var reach: CGFloat = Router.Card.optionReach
    @FocusState private var focused: Bool
    @State private var hot = false
    @Environment(\.routerStill) private var still

    static let placeholder = "Other"

    var body: some View {
        let words = model.typed[key]?[question] ?? ""
        let on = !words.isEmpty
        let d = CDS.Density.compact
        HStack(spacing: Router.Card.radioGap) {
            ZStack {
                Circle().fill(on ? CDS.Fill.accent : .clear)
                if on { Circle().fill(.white).frame(width: 6, height: 6) } else { Circle().strokeBorder(CDS.borderStrong, lineWidth: 1) }
            }
            .frame(width: Router.Card.radio, height: Router.Card.radio)
            Group {
                if still {
                    // A still draws the words (a field there would draw its own focus).
                    Text(on ? words : Self.placeholder).foregroundStyle(on ? CDS.Text.primary : CDS.Text.muted)
                } else {
                    TextField("", text: Binding(get: { words }, set: { model.typeOther(key, question: question, $0) }),
                              prompt: Text(Self.placeholder).foregroundColor(CDS.Text.muted))
                        .textFieldStyle(.plain)
                        .foregroundStyle(CDS.Text.primary)
                        .focused($focused)
                }
            }
            .font(CDS.sans(d.prose.0))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7).padding(.leading, reach).padding(.trailing, Router.Card.optionTrailing)
        .background {
            let s = Router.Surface.self
            RoundedRectangle(cornerRadius: s.row, style: .continuous)
                .fill(on ? (hot ? s.chosenHover : s.chosen) : hot || focused ? s.hover : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hot = $0 }
        .onTapGesture { focused = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(on ? "Other: \(words)" : "Other answer")
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
        HStack(spacing: Router.Card.radioGap) {
            ZStack {
                Circle().fill(on ? CDS.Fill.accent : .clear)
                if on { Circle().fill(.white).frame(width: 6, height: 6) } else { Circle().strokeBorder(CDS.borderStrong, lineWidth: 1) }
            }
            .frame(width: Router.Card.radio, height: Router.Card.radio)
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
