import AppKit
import SwiftUI

// The Router window's page (docs/design/router-watch-and-briefs.md 4 and 5): the general brief on top, what's for you and
// what's worth a look, then a paragraph per project in the order of 4 (needs you, stranded, finished and not told, working,
// quiet; 12 at most, the rest folded to a line of names). The prose names its threads as highlights (RouterBriefMarkup.swift),
// each in the colour and mark of what its thread is at now, read from the Board. Hovering one shows a peek of it; clicking
// opens a popover that answers it: its question and options (a click on one sends it), every question of a form with one
// Send, a line to type an answer or a message, Mark read and Open. A project folds to its header line, as one with nothing for
// you starts. The composer stays under it, the history beside or under it.

struct RouterBriefView: View {
    let store: Store
    @Bindable var model: RouterModel
    var edges = RouterEdges.standalone

    static let column: CGFloat = 720
    /// The room each side of the column when the page is narrower than it with it.
    static let gutter: CGFloat = 32
    static let bottom: CGFloat = 150

    var body: some View {
        let briefs = store.routerBriefs
        let page = briefs.page()
        let now = briefs.clock().timeIntervalSince1970
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                BriefLead(store: store, page: page)
                if page.sections.isEmpty {
                    Text(store.router.enabled || !briefs.docs.isEmpty
                         ? "Nothing going on. When a thread asks you something, finishes or gets stuck, it will be here."
                         : "Turn the Router on and the brief will tell you what your threads need, project by project.")
                        .cdsText(CDS.Density.compact.prose, .regular, CDS.Text.secondary)
                }
                let waiting = page.sections.filter { !$0.entries.isEmpty }
                let rest = page.sections.filter { $0.entries.isEmpty }
                ForEach(waiting) { section in
                    BriefSectionView(store: store, section: section, now: now, open: briefs.isOpen(section))
                        .zIndex(briefs.raised(section.id + "#") ? 1 : 0)
                }
                if !rest.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Nothing for you").cdsText(CDS.Density.compact.footnote, .medium, CDS.Text.muted)
                        ForEach(rest) { section in
                            BriefSectionView(store: store, section: section, now: now, open: briefs.isOpen(section))
                                .zIndex(briefs.raised(section.id + "#") ? 1 : 0)
                        }
                    }
                }
                if !page.folded.isEmpty {
                    Text("Also: " + page.folded.joined(separator: ", "))
                        .cdsText(CDS.Density.compact.body, .regular, CDS.Text.muted)
                        .lineLimit(2)
                }
            }
            .padding(.leading, edges.leading).padding(.trailing, edges.trailing)
            .padding(.top, 20)
            .padding(.bottom, Self.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { briefs.shown(page) }
        .onChange(of: page.sections.map(\.finished)) { briefs.shown(page) }
        // The told rule: what the page told of finished threads leaves it once you leave it.
        .onDisappear { briefs.left() }
    }
}

// MARK: - The general brief

private struct BriefLead: View {
    let store: Store
    let page: BriefPage

    var body: some View {
        let counts = Self.counts(page)
        let lead = page.lead
        let briefs = store.routerBriefs
        VStack(alignment: .leading, spacing: 16) {
            if !counts.isEmpty {
                HStack(spacing: 10) {
                    ForEach(counts, id: \.0) { text, color in
                        Text(text).cdsText(CDS.Density.compact.footnote, .medium, color)
                    }
                }
            }
            let forYou = BriefLeadText.forYou(page)
            if !forYou.isEmpty {
                part("For you", symbol: "exclamationmark.circle", tint: CDS.Text.warning, markup: forYou, key: Self.forYou)
                    .zIndex(briefs.raised(Self.forYou + "#") ? 2 : 1)
            }
            if !lead.worthALook.isEmpty {
                part("Worth a look", symbol: "eye", tint: CDS.Text.accent, markup: lead.worthALook, key: Self.look)
                    .zIndex(briefs.raised(Self.look + "#") ? 2 : 0)
            }
            if !counts.isEmpty || !forYou.isEmpty || !lead.worthALook.isEmpty {
                Rectangle().fill(CDS.border).frame(height: CDS.hairline).padding(.top, 2)
            }
        }
        .zIndex(briefs.raised("lead-") ? 2 : 0)
    }

    static let forYou = "lead-you"
}

enum BriefLeadText {
    /// What's for you: the lead's words, then every thread that waits on you and that they don't name, so the count over it
    /// and the threads under it always agree.
    static func forYou(_ page: BriefPage) -> String {
        let text = page.lead.forYou
        let named = Set(BriefMarkup.ids(text))
        let missing = page.entries.filter { !named.contains($0.target.key) }.map { e in
            "<t id=\"\(e.target.key)\">\(BriefSectionView.words(e, title: page.sections.first { $0.id == e.project }?.doc.thread(e.thread)?.title))</t>"
        }
        guard !missing.isEmpty else { return text }
        let list = missing.joined(separator: ", ")
        return text.isEmpty ? list + "." : text + " Also: " + list + "."
    }
}

extension BriefLead {
    static let look = "lead-look"

    private func part(_ title: String, symbol: String, tint: Color, markup: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(CDS.sans(12, .semibold)).foregroundStyle(tint)
            BriefProse(store: store, markup: markup, key: key, project: nil, size: 16)
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

/// A project: one header line, the same open or folded, a click on it opening or folding it in place (the chevron turns, the
/// name stays where it is). Open, its paragraph and your latest message to it under the line; folded, the paragraph's first
/// words on the line itself, muted. A project with something for you is open until you fold it; one with nothing, folded
/// until you open it.
struct BriefSectionView: View {
    let store: Store
    let section: BriefPage.Section
    let now: Double
    let open: Bool

    var body: some View {
        let doc = section.doc
        VStack(alignment: .leading, spacing: 8) {
            header
            if open {
                let markup = Self.markup(section)
                if !markup.isEmpty {
                    BriefProse(store: store, markup: markup, key: section.id, project: section.id, size: 15)
                }
                if doc.proseStale {
                    Text("Being rewritten").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
                }
                if let sent = doc.sent.last { BriefSentLine(line: sent) }
            }
        }
    }

    /// The paragraph: its `now` lines, then each thread that waits on you and that they don't name, as a highlight of its
    /// own, so nothing that needs you is ever missing from it.
    static func markup(_ section: BriefPage.Section) -> String {
        let text = section.doc.now.joined(separator: " ")
        let named = Set(BriefMarkup.ids(text))
        let missing = section.entries.filter { !named.contains($0.thread) }.map { e in
            "<t id=\"\(e.thread)\">\(words(e, title: section.doc.thread(e.thread)?.title))</t>"
        }
        return ([text] + missing).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A few words for a thread that waits on you when no text names it: its title, else its question, short.
    static func words(_ e: BriefEntry, title: String?) -> String {
        let source = title?.nonEmpty ?? BriefMarkup.plain(BriefEntryText.question(e))
        let words = source.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: "\n", with: " ")
        return words.count > 48 ? String(words.prefix(46)).trimmingCharacters(in: .whitespaces) + "…" : words
    }

    private var header: some View {
        Button { store.routerBriefs.toggle(section) } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                Circle().fill(Self.tint(section.group)).frame(width: 7, height: 7)
                Text(section.name).font(CDS.sans(13, .semibold)).foregroundStyle(CDS.Text.primary).lineLimit(1).fixedSize()
                Text(Self.label(section.group)).font(CDS.sans(12)).foregroundStyle(Self.labelTint(section.group)).lineLimit(1).fixedSize()
                if let since = section.staleSince {
                    Text("as of \(BriefAge.text(now - since))").font(CDS.sans(12)).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
                        .help("Fjord can't see this project's page now: this is what it showed last")
                }
                if !open {
                    Text(BriefMarkup.plain(section.doc.now.joined(separator: " ")))
                        .font(CDS.sans(12.5)).foregroundStyle(CDS.Text.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.name), \(Self.label(section.group))")
        .accessibilityValue(open ? "open" : "folded")
        .accessibilityHint(open ? "Folds it" : "Shows its paragraph")
        .accessibilityAddTraits(.isHeader)
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

// MARK: - Prose with highlights

/// A paragraph of the brief: its words and its threads' highlights, laid out as text. `project`: the section's, whose tags
/// name its threads by id; nil for the lead, whose tags are "project/thread".
struct BriefProse: View {
    let store: Store
    let markup: String
    let key: String
    let project: String?
    var size: CGFloat = 15

    var body: some View {
        BriefFlow(spacing: size * 0.27, lineSpacing: 5) {
            ForEach(Array(BriefMarkup.tokens(markup).enumerated()), id: \.offset) { _, token in
                switch token {
                case .word(let word, let tight):
                    Text(RouterText.inline(word)).font(CDS.sans(size)).foregroundStyle(CDS.Text.secondary)
                        .layoutValue(key: TightKey.self, value: tight)
                case .link(let url, let text, let tight):
                    if let destination = URL(string: url) {
                        let linkKey = key + "#link:" + url
                        BriefLink(store: store, destination: destination, text: text, size: size, key: linkKey)
                            .layoutValue(key: TightKey.self, value: tight)
                            .zIndex(store.routerBriefs.raised(linkKey) ? 1 : 0)
                    }
                case .thread(let id, let text, let tight):
                    if let target = target(id) {
                        let spanKey = BriefSpan.key(key, target)
                        BriefSpan(store: store, target: target, key: spanKey, text: text, size: size, showsProject: project == nil)
                            .layoutValue(key: TightKey.self, value: tight)
                            .zIndex(store.routerBriefs.raised(spanKey) ? 1 : 0)
                    } else {
                        Text(text).font(CDS.sans(size)).foregroundStyle(CDS.Text.secondary)
                            .layoutValue(key: TightKey.self, value: tight)
                    }
                }
            }
        }
        // A highlight's peek floats over what comes after the paragraph.
        .zIndex(store.routerBriefs.raised(key + "#") ? 1 : 0)
        .accessibilityElement(children: .contain)
    }

    private func target(_ id: String) -> BriefTarget? {
        if let project { return BriefTarget(project: project, thread: id) }
        return BriefTarget(key: id)
    }
}

/// A link in the prose: its words, underlined in the accent; hovered, where it leads floats under it (its host bold, then its
/// path), as a browser's status line shows it.
private struct BriefLink: View {
    let store: Store
    let destination: URL
    let text: String
    let size: CGFloat
    let key: String

    var body: some View {
        let briefs = store.routerBriefs
        let hovered = briefs.hovered == key
        SwiftUI.Link(destination: destination) {
            Text(text).font(CDS.sans(size, .medium)).foregroundStyle(CDS.Text.accent)
                .underline(color: CDS.Text.accent.opacity(hovered ? 0.9 : 0.4))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { briefs.hovered = key; NSCursor.pointingHand.push() } else {
                NSCursor.pop()
                if briefs.hovered == key { briefs.hovered = nil }
            }
        }
        .overlay(alignment: .topLeading) {
            if hovered {
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                    (Text(destination.host() ?? "").foregroundStyle(CDS.Text.primary).fontWeight(.medium)
                        + Text(Self.rest(destination)).foregroundStyle(CDS.Text.muted))
                        .font(CDS.sans(12)).lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(shape.fill(CDS.Surface.s3))
                .overlay(shape.strokeBorder(CDS.borderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .frame(maxWidth: 460, alignment: .leading)
                .fixedSize()
                .offset(y: size + 12)
                .allowsHitTesting(false)
            }
        }
        .accessibilityHint("Opens \(destination.absoluteString)")
    }

    /// Everything after the host: the path, query and fragment.
    static func rest(_ url: URL) -> String {
        let s = url.absoluteString
        guard let host = url.host(), let r = s.range(of: host) else { return s }
        return String(s[r.upperBound...])
    }
}

/// What a highlight's thread is at, in a mark and a colour: what it asks of you (by its entry's kind), an answer on its way
/// or one that didn't go, finished, working, stopped. Read from the Board's documents and the page's own state, never from
/// the words.
struct BriefSpanState: Equatable {
    var symbol: String
    var tint: Color
    var label: String
    /// Working, stopped or unknown: the words underlined, not on a ground of their colour.
    var quiet = false

    @MainActor static func of(_ t: BriefTarget, store: Store) -> BriefSpanState {
        let briefs = store.routerBriefs
        let doc = briefs.docs[t.project]
        if briefs.trouble[t] != nil { return BriefSpanState(symbol: "exclamationmark.triangle.fill", tint: CDS.Text.danger, label: "Didn't go") }
        if briefs.answering.contains(t) || briefs.sending[t] != nil {
            return BriefSpanState(symbol: "arrow.up.circle.fill", tint: CDS.Text.accent, label: "Answering")
        }
        if let e = doc?.needsYou.first(where: { $0.thread == t.thread }) {
            if briefs.read.contains(BriefPage.entryKey(e)) || briefs.archived.contains(t.key) {
                return BriefSpanState(symbol: "checkmark.circle", tint: CDS.Text.muted, label: "Read", quiet: true)
            }
            switch e.kind {
            case .stranded: return BriefSpanState(symbol: "exclamationmark.triangle.fill", tint: CDS.Text.danger, label: "Stopped")
            case .plan: return BriefSpanState(symbol: "list.bullet.clipboard.fill", tint: CDS.Text.warning, label: "Plan to approve")
            case .permission: return BriefSpanState(symbol: "lock.fill", tint: CDS.Text.warning, label: "Waits for a permission")
            case .question, .request: return BriefSpanState(symbol: "questionmark.circle.fill", tint: CDS.Text.warning, label: "Asks you")
            }
        }
        switch doc?.thread(t.thread)?.status {
        case .done: return BriefSpanState(symbol: "checkmark.circle.fill", tint: CDS.Text.accent, label: "Finished")
        case .working: return BriefSpanState(symbol: "ellipsis", tint: CDS.Text.muted, label: "Working", quiet: true)
        case .paused: return BriefSpanState(symbol: "pause.circle", tint: CDS.Text.muted, label: "Stopped, checking", quiet: true)
        case .needsYou: return BriefSpanState(symbol: "checkmark.circle", tint: CDS.Text.muted, label: "Answered", quiet: true)
        case nil: return BriefSpanState(symbol: "circle", tint: CDS.Text.muted, label: "", quiet: true)
        }
    }
}

/// A highlight: its state's mark, its words on a ground of its state's colour (underlined when quiet), and in the lead its
/// project's name after them. Hovered, a peek of its thread floats under it; clicked, its popover answers it.
struct BriefSpan: View {
    let store: Store
    let target: BriefTarget
    let key: String
    let text: String
    let size: CGFloat
    var showsProject = false

    /// Shots draw the popover under the highlight, in the window: an offscreen render has no popover window.
    @MainActor static var popoverInline = false

    static func key(_ place: String, _ t: BriefTarget) -> String { place + "#" + t.key }

    var body: some View {
        let briefs = store.routerBriefs
        let state = BriefSpanState.of(target, store: store)
        let hovered = briefs.hovered == key
        let open = briefs.opened == key
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Button {
            briefs.hovered = nil
            if open { briefs.opened = nil } else {
                briefs.opened = key
                briefs.focus(target)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state.symbol)
                    .font(.system(size: size * 0.66, weight: .semibold))
                    .foregroundStyle(state.tint)
                Text(RouterText.inline(text))
                    .font(CDS.sans(size, state.quiet ? .regular : .medium))
                    .foregroundStyle(state.quiet ? CDS.Text.primary : state.tint)
                    .overlay(alignment: .bottom) {
                        if state.quiet {
                            Rectangle().fill(CDS.Text.muted.opacity(hovered || open ? 0.9 : 0.4)).frame(height: 1).offset(y: 1)
                        }
                    }
                if showsProject {
                    Text(store.routerBriefs.projectName(target.project))
                        .font(CDS.sans(size * 0.62, .medium)).foregroundStyle(CDS.Text.muted)
                        .padding(.horizontal, 4).frame(minHeight: size * 1.05)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(CDS.alpha(0.06)))
                }
            }
            .padding(.horizontal, state.quiet ? 0 : 5)
            .padding(.vertical, 1)
            .background {
                if !state.quiet { shape.fill(state.tint.opacity(hovered || open ? 0.24 : 0.12)) }
            }
            .overlay { if open { shape.strokeBorder(state.tint.opacity(0.7), lineWidth: 1) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { briefs.hovered = key } else if briefs.hovered == key { briefs.hovered = nil }
        }
        .overlay(alignment: .topLeading) {
            if hovered, !open {
                BriefPeek(store: store, target: target, state: state)
                    .frame(width: 380, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: size + 14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else if open, Self.popoverInline {
                BriefAnswerPanel(store: store, target: target, close: {})
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CDS.Surface.s3))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CDS.borderStrong, lineWidth: 1))
                    .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
                    .fixedSize()
                    .offset(y: size + 14)
            }
        }
        .popover(isPresented: Binding(get: { open && !Self.popoverInline }, set: { if !$0, briefs.opened == key { briefs.opened = nil } }),
                 arrowEdge: .bottom) {
            BriefAnswerPanel(store: store, target: target) { if briefs.opened == key { briefs.opened = nil } }
        }
        .accessibilityLabel(state.label.isEmpty ? text : "\(text), \(state.label)")
        .accessibilityHint("Opens it to answer")
    }
}

/// What a highlight points at, floating over the text while hovered: the thread, what it's at, and what it asks.
private struct BriefPeek: View {
    let store: Store
    let target: BriefTarget
    let state: BriefSpanState

    var body: some View {
        let briefs = store.routerBriefs
        let entry = briefs.entry(target, store: store)
        let now = briefs.clock().timeIntervalSince1970
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            BriefThreadHeader(store: store, target: target, state: state, now: now)
            if let entry {
                Text(RouterText.inline(BriefEntryText.question(entry))).font(CDS.sans(12.5)).foregroundStyle(CDS.Text.primary)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                if !entry.options.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(entry.options.enumerated()), id: \.offset) { n, option in
                            Text("\(n + 1). \(option)").font(CDS.sans(12)).foregroundStyle(CDS.Text.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Text(entry == nil ? "Click to message it or open it" : "Click to answer").font(CDS.sans(11)).foregroundStyle(CDS.Text.muted)
        }
        .padding(12)
        .background(shape.fill(CDS.Surface.s3))
        .overlay(shape.strokeBorder(CDS.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
    }
}

/// A thread's name, its project, what it's at and since when: the peek's and the popover's first line.
private struct BriefThreadHeader: View {
    let store: Store
    let target: BriefTarget
    let state: BriefSpanState
    let now: Double

    var body: some View {
        let briefs = store.routerBriefs
        let doc = briefs.docs[target.project]
        let since = briefs.entry(target, store: store)?.since ?? doc?.thread(target.thread)?.age
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: state.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(state.tint)
                Text(briefs.title(target)).font(CDS.sans(13, .semibold)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                Spacer(minLength: 6)
                if let since { Text(BriefAge.text(now - since)).font(CDS.sans(11)).foregroundStyle(CDS.Text.muted).fixedSize() }
            }
            Text([briefs.projectName(target.project), state.label].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(CDS.sans(11.5)).foregroundStyle(CDS.Text.muted).lineLimit(1)
        }
    }
}

// MARK: - Answering

/// A highlight's popover. A thread that waits on you: its question, and its options, one click sending one (an answer
/// can't be unsent, but it is the one click the thread's own card asks); a form of several questions shows each with its
/// options and sends them together with Send; a plan, its buttons. Then a line to type an answer (or, for a thread that
/// doesn't wait on you, a message to it), Mark read and Open. 1–9 pick an option and Return sends it, as on the page.
struct BriefAnswerPanel: View {
    let store: Store
    let target: BriefTarget
    let close: () -> Void
    @State private var words = ""
    /// A form's choices so far: each question's picked option labels.
    @State private var choices: [String: [String]] = [:]
    @State private var keys: Any?
    @FocusState private var typing: Bool

    static let width: CGFloat = 400

    var body: some View {
        let briefs = store.routerBriefs
        let now = briefs.clock().timeIntervalSince1970
        let entry = briefs.entry(target, store: store)
        let form = entry.flatMap { briefs.form($0, store: store) }
        VStack(alignment: .leading, spacing: 12) {
            BriefThreadHeader(store: store, target: target, state: BriefSpanState.of(target, store: store), now: now)
            if let entry {
                if let form, !form.isPlan, form.questions.count > 1 || form.questions.contains(where: \.multiSelect) {
                    formQuestions(form)
                } else {
                    question(entry)
                    if !entry.options.isEmpty { options(entry) }
                }
            }
            status
            field(entry: entry)
            footer(entry: entry)
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .onAppear { watchKeys() }
        .onDisappear { if let keys { NSEvent.removeMonitor(keys) }; keys = nil }
    }

    private func question(_ e: BriefEntry) -> some View {
        ScrollView {
            Text(RouterText.inline(BriefEntryText.question(e)))
                .cdsText(CDS.Density.compact.prose, .regular, CDS.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func options(_ e: BriefEntry) -> some View {
        let briefs = store.routerBriefs
        let picked = briefs.picked[target]
        let busy = briefs.answering.contains(target)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return VStack(spacing: 0) {
            ForEach(Array(e.options.enumerated()), id: \.offset) { n, option in
                if n > 0 { Rectangle().fill(CDS.border).frame(height: 1) }
                BriefOptionRow(number: n + 1, label: option, on: picked == n + 1, keyed: true) {
                    guard !busy else { return }
                    if briefs.answer(target, option: n + 1, store: store) { close() }
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(CDS.border, lineWidth: 1))
        .disabled(busy)
    }

    /// Every question of a form, each with its options (several for a multi-select), and one Send once each has one.
    private func formQuestions(_ form: PendingForm) -> some View {
        let briefs = store.routerBriefs
        let complete = form.questions.allSatisfy { !(choices[$0.question] ?? []).isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(form.questions, id: \.question) { q in
                VStack(alignment: .leading, spacing: 6) {
                    Text(RouterText.inline(q.question)).cdsText(CDS.Density.compact.prose, .medium, CDS.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                    VStack(spacing: 0) {
                        ForEach(Array(q.options.enumerated()), id: \.offset) { n, option in
                            if n > 0 { Rectangle().fill(CDS.border).frame(height: 1) }
                            BriefOptionRow(number: n + 1, label: option.label, on: choices[q.question]?.contains(option.label) == true,
                                           keyed: false) { choose(option.label, in: q) }
                        }
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(CDS.border, lineWidth: 1))
                }
            }
            HStack {
                Spacer()
                ClaudeButton("Send", variant: .primary, size: .sm, busy: briefs.answering.contains(target)) {
                    let answers = choices.mapValues { $0.joined(separator: ", ") }
                    if briefs.answerAll(target, answers, store: store) { close() }
                }
                .disabled(!complete || briefs.answering.contains(target))
            }
        }
    }

    private func choose(_ label: String, in q: PendingForm.Question) {
        var picked = choices[q.question] ?? []
        if q.multiSelect {
            if let i = picked.firstIndex(of: label) { picked.remove(at: i) } else { picked.append(label) }
        } else {
            picked = picked == [label] ? [] : [label]
        }
        choices[q.question] = picked
    }

    @ViewBuilder private var status: some View {
        let briefs = store.routerBriefs
        if let trouble = briefs.trouble[target] {
            Text(trouble).cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.danger).fixedSize(horizontal: false, vertical: true)
        } else if briefs.answering.contains(target) || briefs.sending[target] != nil {
            Text("Answering…").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
        }
    }

    private func field(entry: BriefEntry?) -> some View {
        let briefs = store.routerBriefs
        let canType = entry.map { $0.kind != .permission && $0.kind != .stranded } ?? true
        return Group {
            if canType {
                TextField(entry == nil ? "Message this thread" : "Or type an answer", text: $words)
                    .textFieldStyle(.plain)
                    .font(CDS.sans(13))
                    .focused($typing)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CDS.alpha(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CDS.border, lineWidth: 1))
                    .onSubmit {
                        if briefs.send(words, to: target, store: store) { words = ""; close() }
                    }
            }
        }
    }

    private func footer(entry: BriefEntry?) -> some View {
        let briefs = store.routerBriefs
        return HStack(spacing: 8) {
            if let entry, entry.kind == .permission || entry.kind == .stranded {
                Text("Open it to go on").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
            } else if entry?.options.isEmpty == false {
                Text("Click an option, or 1–\(min(entry!.options.count, 9)) and Return").cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
            }
            Spacer(minLength: 0)
            if entry != nil {
                ClaudeButton("Mark read", variant: .ghost, size: .sm) { briefs.markRead(target, store: store); close() }
                    .help("It leaves the brief; Revert in the history")
            }
            ClaudeButton("Open", variant: .secondary, size: .sm, icon: "arrow.up.right") { briefs.open(target, store: store); close() }
                .help(target.project.hasPrefix("local:") ? "Open the session in the Claude app" : "Open the thread on claude.ai")
        }
    }

    /// 1–9 (by key position, as on the page) pick an option and Return sends it, while the line to type in isn't focused.
    private func watchKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let briefs = store.routerBriefs
                guard !typing, briefs.opened != nil, event.window?.firstResponder is NSText == false,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                let code = Int(event.keyCode)
                if let i = BriefKeys.digits.firstIndex(of: code), let e = briefs.entry(target, store: store), i < e.options.count {
                    briefs.pick(target, i + 1, store: store)
                    return nil
                }
                if code == 36 || code == 76, briefs.picked[target] != nil {
                    if briefs.confirm(target, store: store) { close() }
                    return nil
                }
                return event
            }
        }
    }
}

// MARK: - An entry's words

enum BriefEntryText {
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

/// A thread's status in words.
enum BriefThreadWord {
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
