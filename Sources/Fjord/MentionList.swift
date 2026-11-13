import SwiftUI

/// The projects an @ word matches: names that start with it first, then ones that contain it, then ones that hold its
/// letters in order (fuzzy); shorter names first within each.
enum RouterMentions {
    static func rank(_ projects: [(String, String)], query: String, limit: Int) -> [(folder: String, name: String)] {
        func score(_ name: String) -> Int? { Self.score(name, query: query) }
        struct Hit { var folder: String; var name: String; var score: Int }
        var hits: [Hit] = []
        for (folder, name) in projects {
            if let s = score(name) { hits.append(Hit(folder: folder, name: name, score: s)) }
        }
        hits.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name < b.name
        }
        return hits.prefix(limit).map { (folder: $0.folder, name: $0.name) }
    }
}

/// The @ suggestions as Claude's MentionDropdown: what the word matches, under its section's heading (projects, sessions,
/// notifications, categories), the one ↑↓ (or the pointer) picked lit.
struct MentionList: View {
    let suggestions: [MentionSuggestion]
    let index: Int
    var width: CGFloat = CDS.Composer.mentionWidth
    var store: Store? = nil
    var hover: ((Int) -> Void)? = nil
    let pick: (MentionSuggestion) -> Void

    /// Where the list goes under a caret at `caretX` in a card `available` wide (0 while that isn't known yet): no wider than
    /// the card, and moved left as far as it takes to end inside it.
    static func place(caretX: CGFloat, available: CGFloat, preferred: CGFloat = CDS.Composer.mentionWidth)
        -> (x: CGFloat, width: CGFloat) {
        guard available > 0 else { return (max(0, caretX), preferred) }
        let width = min(preferred, available)
        return (min(max(0, caretX), available - width), width)
    }

    var body: some View {
        let d = CDS.Density.compact
        let shape = RoundedRectangle(cornerRadius: d.panelRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, row in
                // A section's heading over its first row, when the list holds more than one section.
                if i == 0 ? Set(suggestions.map(\.section)).count > 1 : suggestions[i - 1].section != row.section {
                    Text(row.section.title).font(CDS.sans(d.caption.0, .medium)).foregroundStyle(CDS.Text.muted)
                        .padding(.horizontal, d.pad.md).padding(.top, i == 0 ? 2 : 6).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                Group {
                    Button { pick(row) } label: {
                        HStack(spacing: d.gap.xs) {
                            Image(systemName: row.look.symbol ?? "folder").font(.system(size: 12))
                                .foregroundStyle(row.look.tint ?? CDS.Text.secondary)
                                .frame(width: d.icon, height: d.icon)
                            rowText(row, density: d)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, d.pad.md)
                        .frame(maxWidth: .infinity)
                        .frame(height: d.control)
                        .background(RoundedRectangle(cornerRadius: d.radius, style: .continuous)
                            .fill(i == index ? CDS.Fill.ghostHover : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { hover?(i) } }
                }
                .accessibilityLabel("\(row.section.title.dropLast()) \(row.name), \(row.detail)")
                .accessibilityAddTraits(i == index ? .isSelected : [])
            }
        }
        .padding(d.pad.xs)
        .frame(width: width)
        .background(shape.fill(CDS.Surface.s3))
        .overlay(shape.strokeBorder(CDS.border, lineWidth: 1))
        .shadow(color: CDS.PanelShadow.near.color, radius: CDS.PanelShadow.near.radius, y: CDS.PanelShadow.near.y)
        .shadow(color: CDS.PanelShadow.far.color, radius: CDS.PanelShadow.far.radius, y: CDS.PanelShadow.far.y)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    /// A row's name and, muted after it, its detail.
    private func rowText(_ row: MentionSuggestion, density d: CDS.Density) -> some View {
        let truncation: Text.TruncationMode = row.folder == nil ? .tail : .head
        return HStack(alignment: .firstTextBaseline, spacing: d.gap.xs) {
            Text(row.rowName).font(CDS.sans(d.body.0)).foregroundStyle(CDS.Text.primary).lineLimit(1).layoutPriority(1)
            Text(row.detail).font(CDS.sans(d.caption.0)).foregroundStyle(CDS.Text.muted).lineLimit(1).truncationMode(truncation)
        }
    }

    /// `~/code/lookout` rather than the whole path.
    static func shortPath(_ folder: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}
