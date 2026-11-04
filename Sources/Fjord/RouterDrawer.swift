import SwiftUI

// The history under the composer (docs/design/router-watch-and-briefs.md 5.0): your messages with where they went, your acts
// on the brief with Revert, the answers you gave (one line each), and the briefs' prose versions. It reads RouterDecisions,
// the briefs' versions and the acts; never a card.

struct RouterDrawer: View {
    let store: Store

    static let height: CGFloat = 260

    /// One line of the drawer, newest first.
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable { case message, act(BriefAct), version }
        var id: String
        var at: Date
        var kind: Kind
        var text: String
        var detail: String
    }

    var body: some View {
        let briefs = store.routerBriefs
        VStack(spacing: 0) {
            Button {
                briefs.drawerOpen.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .medium))
                    Text("History").font(CDS.sans(12, .medium))
                    Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(briefs.drawerOpen ? 180 : 0))
                }
                .foregroundStyle(CDS.Text.muted)
                .padding(.horizontal, 8).frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(briefs.drawerOpen ? "Hide the history" : "Show the history")
            if briefs.drawerOpen {
                let lines = Self.lines(store)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if lines.isEmpty {
                            Text("Your messages, answers and the briefs' changes will be here.")
                                .cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
                        }
                        ForEach(lines) { DrawerLine(store: store, line: $0, now: briefs.clock()) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: Self.height)
                .background(RoundedRectangle(cornerRadius: CDS.Density.compact.panelRadius, style: .continuous).fill(CDS.Surface.s2))
                .overlay(RoundedRectangle(cornerRadius: CDS.Density.compact.panelRadius, style: .continuous).strokeBorder(CDS.border, lineWidth: 1))
                .transition(.opacity)
            }
        }
    }

    /// Every line, newest first: your messages (RouterDecisions), your acts and answers, the briefs' versions.
    static func lines(_ store: Store) -> [Line] {
        let briefs = store.routerBriefs
        var out: [Line] = []
        for d in store.router.decisions.suffix(60) {
            guard case .you(let words) = d.trigger, !words.isEmpty else { continue }
            out.append(Line(id: d.id.uuidString, at: d.at, kind: .message, text: words,
                            detail: d.decision.label ?? d.decision.target ?? ""))
        }
        for a in briefs.acts {
            let text: String, detail: String
            switch a.kind {
            case .answered(let words): text = "Answered \(a.title)"; detail = words
            case .read: text = "Marked \(a.title) read"; detail = ""
            case .archived: text = "Archived \(a.title)"; detail = ""
            }
            out.append(Line(id: a.id.uuidString, at: a.at, kind: .act(a), text: text, detail: detail))
        }
        for (project, versions) in briefs.versions() {
            let name = briefs.names[project].flatMap { $0.isEmpty ? nil : $0 } ?? BriefPage.fallbackName(project)
            for v in versions.suffix(10) where !v.diff.isEmpty {
                let added = v.diff.split(separator: "\n").filter { $0.hasPrefix("+ now: ") }.map { String($0.dropFirst(7)) }
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
            if case .act(let act) = line.kind, !act.reverted, !isAnswer(act) {
                Button("Revert") { store.routerBriefs.revert(act) }
                    .buttonStyle(.plain).font(CDS.sans(12, .medium)).foregroundStyle(CDS.Text.accent)
            }
            Text(BriefAge.text(now.timeIntervalSince(line.at))).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).fixedSize()
        }
    }

    private var reverted: Bool { if case .act(let a) = line.kind { return a.reverted }; return false }

    private func isAnswer(_ a: BriefAct) -> Bool { if case .answered = a.kind { return true }; return false }

    private var symbol: String {
        switch line.kind {
        case .message: "arrow.up.right"
        case .act(let a): isAnswer(a) ? "checkmark.bubble" : "arrow.uturn.backward"
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
