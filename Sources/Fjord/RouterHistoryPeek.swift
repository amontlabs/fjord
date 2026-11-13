import SwiftUI

// A card's history rows are one line each, cut with … when they are long (your message that started a run, an outcome).
// The pointer on a cut row shows its words whole in the page's usual hover shell, hung under the row (DESIGN.md R10).

/// The hover: the row's words, whole.
struct RouterHistoryPeek: View {
    let words: String

    var body: some View {
        Text(RouterInline.text(words, size: CDS.Density.compact.prose.0))
            .font(CDS.sans(CDS.Density.compact.prose.0)).foregroundStyle(CDS.Text.primary)
            .fixedSize(horizontal: false, vertical: true)
            .routerPeekShell()
    }

    /// An event's words as one string, for the hover.
    static func plain(_ event: RouterEvent) -> String {
        switch event.kind {
        case .summary(let text): return text
        case .raised(_, let sentence): return sentence
        case .closed(_, let sentence, let how): return sentence + "  " + how
        case .finished(let outcome): return outcome
        case .started(let start):
            switch start {
            case .asked(let text): return "\u{201C}" + text.split(whereSeparator: \.isWhitespace).joined(separator: " ") + "\u{201D}"
            case .subagents(let titles):
                let head = titles.count > 1 ? Router.Work.subagentsFinished(titles.count) : Router.Work.subagentFinished
                return titles.isEmpty ? head : head + " \u{00B7} " + titles.joined(separator: ", ")
            case .command(let command):
                guard let command else { return Router.Work.commandFinished }
                return Router.Work.commandFinished + " \u{00B7} " + command
            case .usageLimit: return Router.Work.usageLimit
            case .woken: return Router.Work.woken
            }
        }
    }

    /// The hit of a row: its thread and its event.
    static func hit(_ thread: String, _ event: String) -> RouterHit { .history(thread + "\u{1F}" + event) }
}

extension RouterModel {
    /// The history row the pointer is on, with its words whole.
    var historyPeeked: (key: String, words: String)? {
        guard case .history(let key)? = hoverControl else { return nil }
        let parts = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        guard parts.count == 2, let t = thread(parts[0]), let event = t.history.first(where: { $0.id == parts[1] }) else { return nil }
        return (key, RouterHistoryPeek.plain(event))
    }
}

extension View {
    /// Makes a history row a hover target, but only while its words are cut: the row measures them uncut against what it
    /// has.
    func historyPeek(_ model: RouterModel, thread: String, event: RouterEvent) -> some View {
        modifier(RouterHistoryTarget(model: model, hit: RouterHistoryPeek.hit(thread, event.id), words: RouterHistoryPeek.plain(event)))
    }
}

private struct RouterHistoryTarget: ViewModifier {
    let model: RouterModel
    let hit: RouterHit
    let words: String
    @State private var cut = false
    @State private var room: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0; measure() }
            .background(alignment: .leading) {
                // The words on one line, uncut, unseen: wider than the row's room is cut.
                Text(verbatim: words).font(CDS.sans(CDS.Density.compact.footnote.0)).lineLimit(1).fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { natural = $0; measure() }
            }
            .modifier(Gated(on: cut, model: model, hit: hit))
    }

    @State private var natural: CGFloat = 0

    private func measure() {
        // The mark and its gap take the first 20 points.
        let now = natural > max(0, room - 20) + 0.5 && room > 0
        if now != cut { cut = now }
    }

    private struct Gated: ViewModifier {
        let on: Bool
        let model: RouterModel
        let hit: RouterHit
        @ViewBuilder func body(content: Content) -> some View {
            if on { content.contentShape(Rectangle()).routerTarget(model, hit) } else { content }
        }
    }
}
