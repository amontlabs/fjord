import SwiftUI

// The briefs' prose with its threads tagged: the model wraps the words about a thread in `<t id="…">`, a project's brief with
// the thread's id, the general brief's lead with "project/thread". The page draws each tag as a highlight in the colour of
// what its thread is at now, read from the Board, not from the words (RouterBriefView.swift). A tag whose id isn't a known
// thread is dropped when the model's answer is checked, its words kept. A link is `<a href="https://…">words</a>`, kept only when
// its address is one the model was given (an item's or the brief's own), never one it made up.

enum BriefMarkup {
    enum Piece: Equatable {
        case text(String)
        case thread(id: String, text: String)
        case link(url: String, text: String)
    }

    // A tag's text holds no `<`: a tag opened inside another, or one never closed, can't swallow the words after it.
    // swiftlint:disable:next force_try
    nonisolated(unsafe) private static let tag = try! Regex(#"<t\s+id="([^"]+)">([^<]*)</t>"#, as: (Substring, Substring, Substring).self)
    // swiftlint:disable:next force_try
    nonisolated(unsafe) private static let anchor = try! Regex(#"<a\s+href="(https?://[^"\s<>]+)">([^<]*)</a>"#, as: (Substring, Substring, Substring).self)
    // swiftlint:disable:next force_try
    nonisolated(unsafe) private static let address = try! Regex(#"https?://[^\s<>()\[\]"']+"#)
    // Any tag-shaped text left over: an opening tag, a closing one, whatever the model made up.
    // swiftlint:disable:next force_try
    nonisolated(unsafe) private static let stray = try! Regex(#"</?[A-Za-z][^<>]*>"#)

    /// The text with no tag-shaped text in it.
    static func plain(_ text: String) -> String {
        parse(text).map { piece in
            switch piece {
            case .text(let s): s
            case .thread(_, let s), .link(_, let s): s
            }
        }.joined()
    }

    /// The web addresses a text holds (a markdown link's, a bare one), for checking the links a model writes.
    static func addresses(_ text: String) -> Set<String> {
        Set(text.matches(of: address).map { String(text[$0.range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) })
    }

    /// The pieces in order; no piece ever holds tag text.
    static func parse(_ markup: String) -> [Piece] {
        var pieces: [Piece] = []
        func add(_ text: Substring) {
            let clean = String(text).replacing(stray, with: "")
            guard !clean.isEmpty else { return }
            if case .text(let last)? = pieces.last { pieces[pieces.count - 1] = .text(last + clean) } else { pieces.append(.text(clean)) }
        }
        var rest = Substring(markup)
        while true {
            let t = rest.firstMatch(of: tag), a = rest.firstMatch(of: anchor)
            guard let match = [t, a].compactMap({ $0 }).min(by: { $0.range.lowerBound < $1.range.lowerBound }) else { break }
            add(rest[rest.startIndex..<match.range.lowerBound])
            let words = String(match.output.2).replacing(stray, with: "")
            if words.trimmingCharacters(in: .whitespaces).isEmpty { add(match.output.2) } else if let t, t.range == match.range {
                pieces.append(.thread(id: String(match.output.1), text: words))
            } else {
                pieces.append(.link(url: String(match.output.1), text: words))
            }
            rest = rest[match.range.upperBound...]
        }
        add(rest)
        return pieces
    }

    /// The ids it tags, in order.
    static func ids(_ markup: String) -> [String] {
        parse(markup).compactMap { if case .thread(let id, _) = $0 { id } else { nil } }
    }

    /// The text written back with only the tags whose id `known` accepts and the links whose address is one of `links`; the
    /// others' words kept as text.
    static func checked(_ markup: String, known: (String) -> Bool, links: Set<String> = []) -> String {
        parse(markup).map { piece in
            switch piece {
            case .text(let s): s
            case .thread(let id, let s): known(id) ? "<t id=\"\(id)\">\(s)</t>" : s
            case .link(let url, let s): links.contains(url) ? "<a href=\"\(url)\">\(s)</a>" : s
            }
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    /// A word of the text, or a highlight; a tight one sits against the one before it (the comma after a highlight).
    enum Token: Equatable {
        case word(String, tight: Bool)
        case thread(id: String, text: String, tight: Bool)
        case link(url: String, text: String, tight: Bool)
    }

    static func tokens(_ markup: String) -> [Token] {
        var out: [Token] = []
        var glued = false
        for piece in parse(markup) {
            switch piece {
            case .text(let text):
                let startsTight = !(text.first?.isWhitespace ?? true)
                for (i, word) in text.split(whereSeparator: \.isWhitespace).enumerated() {
                    out.append(.word(String(word), tight: i == 0 && startsTight && glued))
                }
                glued = !(text.last?.isWhitespace ?? true)
            case .thread(let id, let text):
                out.append(.thread(id: id, text: text, tight: glued))
                glued = true
            case .link(let url, let text):
                out.append(.link(url: url, text: text, tight: glued))
                glued = true
            }
        }
        return out
    }
}

struct TightKey: LayoutValueKey { static let defaultValue = false }

/// Words and highlights laid out as text is: left to right, onto the next line when the line is full, each line's items on
/// a shared middle. A tight item sits against the one before it.
struct BriefFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = lines(subviews, width: width)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            for (index, x, size) in line.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: y + (line.height - size.height) / 2),
                                      proposal: size.width > bounds.width ? ProposedViewSize(width: bounds.width, height: nil) : ProposedViewSize(size))
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [(Int, CGFloat, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = [Line()]
        for (index, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            // Wider than a line: it wraps within one rather than overflowing.
            if size.width > width, width.isFinite { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            let gap = view[TightKey.self] || lines[lines.count - 1].items.isEmpty ? 0 : spacing
            if !lines[lines.count - 1].items.isEmpty, lines[lines.count - 1].width + gap + size.width > width {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            let x = line.items.isEmpty ? 0 : line.width + gap
            line.items.append((index, x, size))
            line.width = x + size.width
            line.height = max(line.height, size.height)
            lines[lines.count - 1] = line
        }
        return lines
    }
}
