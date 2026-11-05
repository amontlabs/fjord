import SwiftUI

// The Router window's page (docs/design/router-watch-and-briefs.md 4 and 5): the general brief on top, then a section per
// project in the order of 4 (needs you, stranded, finished and not told, working, quiet; 12 at most, the rest folded to a
// line of names). A section: where it stands (`now`), the threads that wait on you with their question and options, the
// threads touched in 24 h, your sends; opened, the whole document. The composer stays under it, the history in its drawer.

struct RouterBriefView: View {
    let store: Store
    @Bindable var model: RouterModel

    static let column: CGFloat = 720
    static let bottom: CGFloat = 150

    var body: some View {
        let briefs = store.routerBriefs
        let page = briefs.page()
        let now = briefs.clock().timeIntervalSince1970
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                BriefLead(page: page)
                if page.sections.isEmpty {
                    Text(store.router.enabled || !briefs.docs.isEmpty
                         ? "Nothing going on. When a thread asks you something, finishes or gets stuck, it will be here."
                         : "Turn the Router on and the brief will tell you what your threads need, project by project.")
                        .cdsText(CDS.Density.compact.prose, .regular, CDS.Text.secondary)
                }
                ForEach(page.sections) { section in
                    BriefSectionView(store: store, model: model, section: section, now: now,
                                     expanded: briefs.expanded.contains(section.id))
                }
                if !page.folded.isEmpty {
                    Text("Also: " + page.folded.joined(separator: ", "))
                        .cdsText(CDS.Density.compact.body, .regular, CDS.Text.muted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: Self.column, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, Self.bottom)
            .frame(maxWidth: .infinity)
        }
        .onAppear { briefs.shown(page) }
        .onChange(of: page.sections.map(\.finished)) { briefs.shown(page) }
        // The told rule: what the page told of finished threads leaves it once you leave it.
        .onDisappear { briefs.left() }
    }
}

// MARK: - The general brief

private struct BriefLead: View {
    let page: BriefPage

    var body: some View {
        let counts = Self.counts(page)
        VStack(alignment: .leading, spacing: 10) {
            if !counts.isEmpty {
                HStack(spacing: 10) {
                    ForEach(counts, id: \.0) { text, color in
                        Text(text).cdsText(CDS.Density.compact.footnote, .medium, color)
                    }
                }
            }
            if !page.lead.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(page.lead.enumerated()), id: \.offset) { _, line in
                        Text(RouterText.inline(line))
                            .cdsText(CDS.Density.comfortable.prose, .regular, CDS.Text.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            if !counts.isEmpty || !page.lead.isEmpty {
                Rectangle().fill(CDS.border).frame(height: CDS.hairline).padding(.top, 6)
            }
        }
    }

    static func counts(_ page: BriefPage) -> [(String, Color)] {
        var out: [(String, Color)] = []
        if page.needsYou > 0 { out.append(("\(page.needsYou) need\(page.needsYou == 1 ? "s" : "") you", CDS.Text.warning)) }
        let finished = page.sections.reduce(0) { $0 + $1.finished.count }
        if finished > 0 { out.append(("\(finished) finished", CDS.Text.accent)) }
        let working = page.sections.reduce(0) { $0 + $1.doc.threads.filter { $0.status == .working }.count }
        if working > 0 { out.append(("\(working) working", CDS.Text.secondary)) }
        return out
    }
}

// MARK: - A project

struct BriefSectionView: View {
    let store: Store
    let model: RouterModel
    let section: BriefPage.Section
    let now: Double
    let expanded: Bool

    var body: some View {
        let doc = section.doc
        VStack(alignment: .leading, spacing: 10) {
            header
            if doc.proseStale || !doc.now.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(doc.now.enumerated()), id: \.offset) { _, line in
                        Text(RouterText.inline(line))
                            .cdsText(CDS.Density.compact.prose, .regular, CDS.Text.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if doc.proseStale {
                        Text("Being rewritten").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
                    }
                }
            }
            ForEach(section.entries, id: \.target) { entry in
                BriefEntryCard(store: store, model: model, entry: store.routerBriefs.resolved(entry, store: store), now: now)
            }
            let lines = expanded ? doc.threads.filter { t in !section.entries.contains { $0.thread == t.id } } : section.recent
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.id) { BriefThreadLine(thread: $0, now: now, told: !section.finished.contains($0)) }
                }
            }
            if !doc.sent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(doc.sent.suffix(expanded ? 5 : 2), id: \.intent) { BriefSentLine(line: $0) }
                }
            }
            if expanded { full(doc) }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(Self.tint(section.group)).frame(width: 8, height: 8)
            Text(section.name).font(CDS.sans(13, .semibold)).foregroundStyle(CDS.Text.primary).lineLimit(1)
            Text(Self.label(section.group)).font(CDS.sans(12)).foregroundStyle(Self.labelTint(section.group)).lineLimit(1)
            if let since = section.staleSince {
                Text("as of \(BriefAge.text(now - since))").font(CDS.sans(12)).foregroundStyle(CDS.Text.muted).lineLimit(1)
                    .help("Fjord can't see this project's page now: this is what it showed last")
            }
            Spacer(minLength: 8)
            Button {
                let briefs = store.routerBriefs
                if briefs.expanded.contains(section.id) { briefs.expanded.remove(section.id) } else { briefs.expanded.insert(section.id) }
            } label: {
                HStack(spacing: 4) {
                    Text(expanded ? "Less" : "More").font(CDS.sans(12, .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .foregroundStyle(CDS.Text.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Show less of \(section.name)" : "Show all of \(section.name)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The rest of the document: its purpose, what was decided, what's left loose.
    @ViewBuilder private func full(_ doc: BriefDoc) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let purpose = doc.purpose, !purpose.isEmpty { part("Purpose", [purpose]) }
            if !doc.decisions.isEmpty {
                part("Decided", doc.decisions.map { d in
                    let who = d.thread == BriefDoc.yourSend ? "You" : (doc.thread(d.thread)?.title.nonEmpty ?? "A thread")
                    return "\(who): \(d.text)"
                })
            }
            if !doc.looseEnds.isEmpty { part("Loose ends", doc.looseEnds) }
            if doc.purpose == nil && doc.decisions.isEmpty && doc.looseEnds.isEmpty {
                Text("Nothing more yet.").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
            }
        }
        .padding(.leading, 15)
    }

    private func part(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).cdsText(CDS.Density.compact.footnote, .medium, CDS.Text.muted)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(RouterText.inline(line)).cdsText(CDS.Density.compact.body, .regular, CDS.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func tint(_ g: BriefPage.Group) -> Color {
        switch g {
        case .needsYou: CDS.Fill.warning
        case .stranded: CDS.Text.danger
        case .finished: CDS.Fill.accent
        case .working: CDS.Text.secondary
        case .quiet: CDS.Text.muted
        }
    }

    static func labelTint(_ g: BriefPage.Group) -> Color {
        switch g {
        case .needsYou: CDS.Text.warning
        case .stranded: CDS.Text.danger
        case .finished: CDS.Text.accent
        case .working, .quiet: CDS.Text.muted
        }
    }

    static func label(_ g: BriefPage.Group) -> String {
        switch g {
        case .needsYou: "needs you"
        case .stranded: "stopped"
        case .finished: "finished"
        case .working: "working"
        case .quiet: "quiet"
        }
    }
}

// MARK: - An entry that waits on you

struct BriefEntryCard: View {
    let store: Store
    let model: RouterModel
    let entry: BriefEntry
    let now: Double

    var body: some View {
        let briefs = store.routerBriefs
        let t = entry.target
        let focused = briefs.focused == t
        let picked = briefs.picked[t]
        let A = CDS.Approval.self
        let shape = RoundedRectangle(cornerRadius: A.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(entry.kind)).font(.system(size: 11, weight: .semibold)).foregroundStyle(CDS.Text.warning)
                    Text(briefs.title(t)).cdsText(CDS.Density.compact.footnote, .medium, CDS.Text.secondary).lineLimit(1)
                    Text("· \(Self.kindLabel(entry)) · \(BriefAge.text(now - entry.since))")
                        .cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).lineLimit(1)
                    if let asOf = entry.asOf {
                        Text("· as of \(BriefAge.text(now - asOf))").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).lineLimit(1)
                    }
                }
                Text(RouterText.inline(Self.question(entry)))
                    .cdsText(CDS.Density.comfortable.body, .regular, CDS.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.vertical, A.pad.md).padding(.horizontal, A.pad.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CDS.Fill.neutral)

            if !entry.options.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(entry.options.enumerated()), id: \.offset) { n, option in
                        if n > 0 { Rectangle().fill(CDS.border).frame(height: 1) }
                        BriefOptionRow(number: n + 1, label: option, on: picked == n + 1, keyed: focused) {
                            briefs.pick(t, n + 1, store: store)
                        }
                    }
                }
                Rectangle().fill(CDS.border).frame(height: 1)
            }

            footer(focused: focused, picked: picked)
                .padding(.vertical, A.pad.md).padding(.horizontal, A.pad.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        .overlay(shape.inset(by: -0.5).stroke(focused ? CDS.Fill.accent : CDS.border, lineWidth: focused ? 1.5 : 1))
        .contentShape(shape)
        .onTapGesture { briefs.focus(t); model.reply() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(briefs.title(t)) needs you")
    }

    @ViewBuilder private func footer(focused: Bool, picked: Int?) -> some View {
        let briefs = store.routerBriefs
        let t = entry.target
        HStack(spacing: 8) {
            if let trouble = briefs.trouble[t] {
                Text(trouble).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if briefs.answering.contains(t) || briefs.sending[t] != nil {
                Text("Answering…").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
            } else {
                Text(Self.hint(entry, picked: picked)).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            ClaudeButton("Mark read", variant: .ghost, size: .sm) { briefs.markRead(t, store: store) }
                .help("It leaves the brief (R); Revert in the history")
            ClaudeButton("Open", variant: .secondary, size: .sm, icon: "arrow.up.right") { briefs.open(t, store: store) }
                .help(entry.source == .local ? "Open the session in the Claude app (O)" : "Open the thread on claude.ai (O)")
            if !entry.options.isEmpty {
                ClaudeButton(picked.map { "Answer \($0)" } ?? "Answer", variant: .primary, size: .sm, shortcut: ["enter"],
                             busy: briefs.answering.contains(t)) { briefs.confirm(t, store: store) }
                    .disabled(picked == nil || briefs.answering.contains(t))
            }
        }
    }

    static func symbol(_ k: BriefEntry.Kind) -> String {
        switch k {
        case .question, .request: "questionmark.circle.fill"
        case .plan: "list.bullet.clipboard"
        case .permission: "lock.fill"
        case .stranded: "exclamationmark.triangle.fill"
        }
    }

    static func kindLabel(_ e: BriefEntry) -> String {
        switch e.kind {
        case .question: e.source == .local ? "asks (on this Mac)" : "asks"
        case .plan: "proposes a plan"
        case .request: "asks in words"
        case .permission: "waits for a permission"
        case .stranded: "stopped"
        }
    }

    static func question(_ e: BriefEntry) -> String {
        if let q = e.question, !q.isEmpty { return q }
        switch e.kind {
        case .permission: return "Waiting for a permission. Open the thread to see what it asks."
        case .stranded: return "The session stopped before it finished."
        case .plan: return "Approve the plan?"
        default: return "It waits on your answer."
        }
    }

    static func hint(_ e: BriefEntry, picked: Int?) -> String {
        if e.kind == .permission || e.kind == .stranded { return "Open it to go on" }
        if let picked { return "Return answers with option \(picked)" }
        if !e.options.isEmpty { return "Pick an option, or type an answer below" }
        return "Type your answer below"
    }
}

/// One option of a card, in the page's words: a compact row of the approval card's (its radio mark), its key on the right.
struct BriefOptionRow: View {
    let number: Int
    let label: String
    let on: Bool
    let keyed: Bool
    let action: () -> Void

    var body: some View {
        let A = CDS.Approval.self
        Button(action: action) {
            HStack(spacing: A.gap.sm) {
                ZStack {
                    Circle().fill(on ? CDS.Fill.accent : .clear)
                    if on { Circle().fill(.white).frame(width: 6, height: 6) } else { Circle().strokeBorder(CDS.borderStrong, lineWidth: 1) }
                }
                .frame(width: 16, height: 16)
                Text(RouterText.inline(label)).cdsText(CDS.Density.compact.prose, .regular, CDS.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if number <= 9 { CDSShortcut(keys: ["\(number)"]).opacity(keyed ? 1 : 0.5) }
            }
            .padding(.vertical, 9).padding(.horizontal, A.pad.lg)
            .background(on ? CDS.Fill.ghostHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint("Option \(number)")
    }
}

// MARK: - Lines

struct BriefThreadLine: View {
    let thread: BriefThread
    let now: Double
    var told = true

    var body: some View {
        HStack(spacing: 7) {
            Self.glyph(thread.status).frame(width: 12)
            Text(thread.title.nonEmpty ?? "Untitled thread").cdsText(CDS.Density.compact.body, told ? .regular : .medium, CDS.Text.secondary)
                .lineLimit(1).truncationMode(.tail)
            Text(Self.word(thread.status)).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).lineLimit(1).fixedSize()
            Text(BriefAge.text(now - thread.age)).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted).lineLimit(1).fixedSize()
            if thread.source == .local {
                Image(systemName: "laptopcomputer").font(.system(size: 10)).foregroundStyle(CDS.Text.muted)
                    .help("A session on this Mac")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder static func glyph(_ s: ThreadState) -> some View {
        switch s {
        case .working: ProgressView().controlSize(.mini).scaleEffect(0.7)
        case .needsYou: Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(CDS.Fill.warning)
        case .paused: Image(systemName: "pause.circle").font(.system(size: 10)).foregroundStyle(CDS.Text.muted)
        case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(CDS.Text.accent)
        }
    }

    static func word(_ s: ThreadState) -> String {
        switch s {
        case .working: "working"
        case .needsYou: "needs you"
        case .paused: "stopped, checking"
        case .done: "finished"
        }
    }
}

/// One of your messages to the project: your words on one line, then how it is going.
struct BriefSentLine: View {
    let line: SentLine

    var body: some View {
        let failed = line.state == "failed" || line.state == "refused"
        HStack(spacing: 6) {
            Image(systemName: failed ? "exclamationmark.triangle" : "arrow.turn.down.right")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(failed ? CDS.Text.warning : CDS.Text.muted)
                .frame(width: 12)
            Text(line.words).font(CDS.sans(12)).foregroundStyle(CDS.Text.muted).lineLimit(1).truncationMode(.tail)
            Text(line.state).font(CDS.sans(12)).foregroundStyle(failed ? CDS.Text.warning : CDS.Text.muted).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You sent: \(line.words), \(line.state)")
    }
}

enum BriefAge {
    static func text(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86_400))d ago"
    }
}

/// When the brief was last written, beside the Router's title as the other pages' subtitles: the newest of the general
/// brief and the projects' documents, kept current on the minute.
struct BriefUpdated: View {
    let store: Store

    var body: some View {
        let briefs = store.routerBriefs
        let at = ([briefs.general.at] + briefs.docs.values.map(\.at)).max() ?? 0
        if at > 0 {
            TimelineView(.everyMinute) { context in
                Text("Updated " + agoPhrase(Date(timeIntervalSince1970: at), now: context.date))
                    .font(CDS.sans(CDS.Density.compact.footnote.0)).foregroundStyle(CDS.Text.muted).lineLimit(1)
            }
        }
    }
}

/// An act on a brief entry that Revert sets back: what `FjordChange.briefAction` records.
enum BriefAction: String, Codable, Hashable, Sendable {
    case archive, read

    var label: String {
        switch self {
        case .archive: "Archived"
        case .read: "Marked read"
        }
    }

    var symbol: String {
        switch self {
        case .archive: "archivebox"
        case .read: "checkmark.circle"
        }
    }
}
