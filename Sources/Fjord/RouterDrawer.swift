import SwiftUI

// The history: a panel in the left sidebar's material, at the window's right beside the brief when the window is wide, and
// across its bottom under the composer when it is narrow (RouterCode.swift places it). Under the composer (docs/design/router-watch-and-briefs.md 5.0): your messages with where they went, the Router's
// reply and what it changed in Fjord (Apply, Revert), your acts on the brief with Revert (`FjordChange.briefAction`), the
// answers you gave (one line each), and the briefs' prose versions. It reads RouterDecisions, the changes, the briefs' versions
// and the answers.

struct RouterDrawer: View {
    let store: Store
    /// Its title line's height: the window's title line beside the page, shorter across the bottom.
    var titleHeight: CGFloat = 34

    /// Its height across the bottom, its width at the right.
    static let height: CGFloat = 260
    static let width: CGFloat = 340

    /// One line of the drawer, newest first.
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable { case message(changes: [UUID]), act(FjordChange), answer, version }
        var id: String
        var at: Date
        var kind: Kind
        var text: String
        var detail: String
    }

    @State private var column: CGFloat = RouterDrawer.width

    var body: some View {
        let briefs = store.routerBriefs
        let lines = Self.lines(store)
        VStack(alignment: .leading, spacing: 0) {
            Text("History").font(CDS.sans(CDS.Density.compact.body.0, .medium)).foregroundStyle(CDS.Text.primary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 14).frame(height: titleHeight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty {
                        Text("Your messages, answers and the briefs' changes will be here.")
                            .cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
                    }
                    ForEach(lines) { line in
                        DrawerLine(store: store, line: line, now: briefs.clock())
                        if case .message(let ids) = line.kind {
                            ForEach(store.router.changes.filter { ids.contains($0.id) }) { ChangeCard(change: $0, store: store) }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The change cards' text stops at the panel's width, not the brief's column.
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { column = $0 }
                .environment(\.cdsColumnWidth, column)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(SidebarPanel())
    }

    /// Every line, newest first: your messages (RouterDecisions), your acts and answers, the briefs' versions.
    static func lines(_ store: Store) -> [Line] {
        let briefs = store.routerBriefs
        var out: [Line] = []
        for d in store.router.decisions.suffix(60) {
            guard case .you(let words) = d.trigger, !words.isEmpty, d.decision.intent != "answer" else { continue }
            let changes = d.links.changes.filter { id in
                store.router.changes.contains { $0.id == id && !$0.isBriefAction }
            }
            out.append(Line(id: d.id.uuidString, at: d.at, kind: .message(changes: changes), text: words,
                            detail: d.reply ?? d.decision.target ?? d.decision.label ?? ""))
        }
        for c in store.router.changes.suffix(60) where c.isBriefAction {
            out.append(Line(id: c.id.uuidString, at: c.date, kind: .act(c), text: c.title, detail: c.revertNote ?? ""))
        }
        for a in briefs.answers {
            out.append(Line(id: a.id.uuidString, at: a.at, kind: .answer, text: "Answered \(a.title)", detail: a.words))
        }
        for (project, versions) in briefs.versions() {
            let name = briefs.names[project].flatMap { $0.isEmpty ? nil : $0 } ?? BriefPage.fallbackName(project)
            for v in versions.suffix(10) where !v.diff.isEmpty {
                let added = v.diff.split(separator: "\n").filter { $0.hasPrefix("+ now: ") }.map { BriefMarkup.plain(String($0.dropFirst(7))) }
                out.append(Line(id: "\(project)#\(v.version)", at: Date(timeIntervalSince1970: v.at), kind: .version,
                                text: "\(name)'s brief changed", detail: added.first ?? ""))
            }
        }
        return out.sorted { $0.at > $1.at }
    }
}

private struct DrawerLine: View {
    let store: Store
    let line: RouterDrawer.Line
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(CDS.Text.muted).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.text).cdsText(CDS.Density.compact.body, .regular, reverted ? CDS.Text.muted : CDS.Text.secondary)
                    .strikethrough(reverted).lineLimit(1).truncationMode(.tail)
                if !line.detail.isEmpty {
                    Text(line.detail).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            if case .act(let change) = line.kind, !change.isReverted {
                Button("Revert") { store.revertFjordChange(change.id) }
                    .buttonStyle(.plain).font(CDS.sans(12, .medium)).foregroundStyle(CDS.Text.accent)
            }
            if case .message = line.kind, store.routerDispatcher.canSendElsewhere(UUID(uuidString: line.id)) {
                Button("Elsewhere…") { if let id = UUID(uuidString: line.id) { store.routerDispatcher.sendElsewhere(id) } }
                    .buttonStyle(.plain).font(CDS.sans(12, .medium)).foregroundStyle(CDS.Text.accent)
            }
            Text(BriefAge.text(now.timeIntervalSince(line.at))).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).fixedSize()
        }
    }

    private var reverted: Bool { if case .act(let c) = line.kind { return c.isReverted }; return false }

    private var symbol: String {
        switch line.kind {
        case .message: "arrow.up.right"
        case .act(let c): c.symbol
        case .answer: "checkmark.bubble"
        case .version: "doc.text"
        }
    }
}

extension RouterBriefs {
    /// The stored versions of every project's brief (a demo's own).
    func versions() -> [String: [BriefVersion]] {
        if let engine { return Dictionary(uniqueKeysWithValues: docs.keys.map { ($0, engine.versions($0)) }) }
        return demoVersions
    }
}

/// The left sidebar's panel look: its glass (or the sidebar's fill with a hairline) in the window's concentric shape on
/// macOS 26, the sidebar's fill with a hairline in a rounded rectangle before it.
struct SidebarPanel: ViewModifier {
    @Environment(\.windowGlass) private var glass

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background {
                Color.clear.modifier(PanelMaterial(shape: WindowChrome.panelShape, glass: glass, fill: CDS.Surface.sidebar, standsIn: false))
            }
            .environment(\.onGlass, glass)
        } else {
            let shape = RoundedRectangle(cornerRadius: CDS.Density.compact.panelRadius, style: .continuous)
            content
                .background(shape.fill(CDS.Surface.sidebar))
                .overlay(shape.strokeBorder(CDS.border, lineWidth: CDS.Sidebar.edge).allowsHitTesting(false))
        }
    }
}

extension EnvironmentValues {
    /// The window's chrome is glass (InsetWindowLayout sets it), for panels drawn by a page.
    @Entry var windowGlass: Bool = false
}
