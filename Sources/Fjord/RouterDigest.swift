import SwiftUI

// The Brief: Now written as prose. On top, what's for you and what's worth a look, in a few plain sentences; under it a
// paragraph per project saying where it stands. The parts that point at a session are tags the writer puts in the text,
// `<need s="…">`, `<look s="…">` and `<run s="…">`; the page draws them as highlights, marked with what their session is
// at now (read from its card, not from the words). Hovering one shows its card's gist and the keys that act on it there
// (`DigestAction`: the inbox's Mark as read, Archive and Open), clicking opens the card under the paragraph and points the
// composer at it, so you answer as you do a card's. Whenever something comes in from a session,
// or from you, the writer (RouterDigestWriter.swift) rewrites the paragraphs it touches, and each rewrite is kept in the
// brief's history with what set it off, why, and a diff of what changed.

/// The Brief: the lead's two parts and a paragraph per project, in an order the app keeps (new projects at the end), and
/// its history.
struct RouterDigest: Codable, Equatable {
    struct Project: Codable, Equatable, Identifiable {
        /// The project's folder, as the canvas keys it.
        let folder: String
        var text: String
        var id: String { folder }
    }

    /// What needs you, in a few sentences.
    var forYou: String
    /// What's worth a look, in a sentence or two (empty: none).
    var worthALook: String
    var projects: [Project]
    /// When it was last rewritten.
    var at: Date
    /// Every rewrite, newest first: what set it off, what it changed and why.
    var history: [Revision] = []
    /// When you last left the Brief: what changed after it is marked new.
    var seenAt: Date?

    /// The history kept, newest first; older rewrites are dropped.
    static let historyLimit = 200

    init(forYou: String, worthALook: String, projects: [Project], at: Date, history: [Revision] = [], seenAt: Date? = nil) {
        self.forYou = forYou
        self.worthALook = worthALook
        self.projects = projects
        self.at = at
        self.history = history
        self.seenAt = seenAt
    }

    /// A paragraph's text by its key ("lead-you", "lead-look" or a project's folder); nil for a project not in it.
    func text(_ key: String) -> String? {
        switch key {
        case Revision.forYouKey: forYou
        case Revision.lookKey: worthALook
        default: projects.first { $0.folder == key }?.text
        }
    }

    /// The keys of the paragraphs a rewrite after `seenAt` changed.
    var changedSinceSeen: Set<String> {
        let since = seenAt ?? .distantPast
        return Set(history.prefix { $0.at > since }.flatMap { $0.changes.map(\.key) })
    }

    /// A rewrite of the brief: the events that set it off (a session's, yours), a label for it, why the text changed, and
    /// each paragraph it changed, before and after.
    struct Revision: Codable, Equatable, Identifiable {
        static let forYouKey = "lead-you"
        static let lookKey = "lead-look"

        enum Trigger: Codable, Equatable {
            /// Something came in from a session.
            case session(String)
            /// You said something (to the Router or a session).
            case you(String)
        }

        struct Change: Codable, Equatable {
            /// The paragraph: "lead-you", "lead-look" or a project's folder.
            let key: String
            let before: String
            let after: String
        }

        var id: String { "\(at.timeIntervalSince1970)" }
        let at: Date
        /// What set it off, first the one that matters most; several events close together make one rewrite.
        let triggers: [Trigger]
        /// What changed, in a few words.
        let label: String
        /// Why, in a sentence: what the event was and what it means for you.
        let why: String
        let changes: [Change]

        init(at: Date, triggers: [Trigger], label: String, why: String, changes: [Change]) {
            self.at = at
            self.triggers = triggers
            self.label = label
            self.why = why
            self.changes = changes
        }

        init(at: Date, trigger: Trigger, label: String, why: String, changes: [Change]) {
            self.init(at: at, triggers: [trigger], label: label, why: why, changes: changes)
        }
    }

    /// A rewrite recorded: newest first, the oldest past the limit dropped.
    mutating func record(_ revision: Revision) {
        history.insert(revision, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }
}

/// A unified diff of two paragraphs, tags read out, as a code review shows one: the text cut into sentences (a paragraph's
/// lines), sentences taken out and put in as − and + lines, the words that changed inside a sentence rewritten marked on
/// it, and the sentences kept shown only next to a change, the rest folded to ⋯.
enum DigestDiff {
    enum Line: Equatable {
        /// A sentence kept, shown as context.
        case same(String)
        /// Kept sentences folded away.
        case fold
        /// A sentence taken out, the ranges of its words that went (none: all of it).
        case removed(String, changed: [Range<String.Index>])
        /// A sentence put in, the ranges of its words that came.
        case added(String, changed: [Range<String.Index>])
    }

    static func lines(_ before: String, _ after: String) -> [Line] {
        let a = sentences(before), b = sentences(after)
        var ops: [(kind: Int, text: String)] = []  // 0 same, -1 removed, 1 added
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { ops.append((-1, a[i])); i += 1; continue }
            if j < b.count, inserted.contains(j) { ops.append((1, b[j])); j += 1; continue }
            if i < a.count, j < b.count { ops.append((0, b[j])); i += 1; j += 1; continue }
            if i < a.count { ops.append((-1, a[i])); i += 1 } else { ops.append((1, b[j])); j += 1 }
        }
        // A run of − lines then + lines is a rewrite: pair them, line by line, to mark the words that changed.
        var out: [Line] = []
        var k = 0
        while k < ops.count {
            if ops[k].kind == 0 { out.append(.same(ops[k].text)); k += 1; continue }
            var minus: [String] = [], plus: [String] = []
            while k < ops.count, ops[k].kind == -1 { minus.append(ops[k].text); k += 1 }
            while k < ops.count, ops[k].kind == 1 { plus.append(ops[k].text); k += 1 }
            var plusMarks: [[Range<String.Index>]] = plus.map { _ in [] }
            for (n, old) in minus.enumerated() {
                if n < plus.count {
                    let (gone, came) = changedWords(old, plus[n])
                    out.append(.removed(old, changed: gone))
                    plusMarks[n] = came
                } else {
                    out.append(.removed(old, changed: []))
                }
            }
            for (n, new) in plus.enumerated() { out.append(.added(new, changed: plusMarks[n])) }
        }
        return folded(out)
    }

    /// Kept sentences more than one away from a change folded to ⋯.
    static func folded(_ lines: [Line]) -> [Line] {
        let near: (Int) -> Bool = { index in
            [index - 1, index + 1].contains { n in
                guard lines.indices.contains(n) else { return false }
                if case .same = lines[n] { return false }
                return true
            }
        }
        var out: [Line] = []
        for (index, line) in lines.enumerated() {
            if case .same = line, !near(index) {
                if out.last != .fold { out.append(.fold) }
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// The words of `old` that went and of `new` that came, as ranges in each.
    static func changedWords(_ old: String, _ new: String) -> ([Range<String.Index>], [Range<String.Index>]) {
        let a = wordRanges(old), b = wordRanges(new)
        let diff = b.map { new[$0] }.difference(from: a.map { old[$0] })
        var gone: [Int] = [], came: [Int] = []
        for change in diff {
            switch change {
            case .remove(let offset, _, _): gone.append(offset)
            case .insert(let offset, _, _): came.append(offset)
            }
        }
        return (runs(gone.sorted(), a), runs(came.sorted(), b))
    }

    /// Words next to each other marked as one run, the space between them with them.
    private static func runs(_ offsets: [Int], _ words: [Range<String.Index>]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: Int?, last = -2
        for offset in offsets {
            if offset != last + 1, let s = start { out.append(words[s].lowerBound..<words[last].upperBound); start = nil }
            if start == nil { start = offset }
            last = offset
        }
        if let s = start { out.append(words[s].lowerBound..<words[last].upperBound) }
        return out
    }

    private static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isWhitespace {
                if let s = start { out.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
        }
        if let s = start { out.append(s..<text.endIndex) }
        return out
    }

    /// The paragraph's sentences, its tags dropped (their text kept): cut after . ? ! or ; and the space after it.
    static func sentences(_ markup: String) -> [String] {
        let text = DigestMarkup.parse(markup).map { piece -> String in
            switch piece {
            case .text(let text): text
            case .span(_, _, let text): text
            }
        }
        .joined()
        var out: [String] = []
        var current = ""
        var previous: Character?
        for char in text {
            if char.isWhitespace, let p = previous, ".?!;".contains(p) {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { out.append(sentence) }
                current = ""
            } else {
                current.append(char)
            }
            previous = char
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { out.append(last) }
        return out
    }
}

/// The text with its tags read out.
enum DigestMarkup {
    enum Kind: String {
        case need, look, run

        var tint: Color {
            switch self {
            case .need: RouterZone.needs.tint
            case .look: CDS.Text.accent
            case .run: CDS.Text.muted
            }
        }
    }

    enum Piece: Equatable {
        case text(String)
        case span(Kind, session: String, text: String)
    }

    // The text of a tag holds no `<`: a tag opened inside another, or one that never closed, can't swallow the words
    // between it and the next one.
    // swiftlint:disable:next force_try
    nonisolated(unsafe) private static let tag = try! Regex(#"<(need|look|run)\s+s="([^"]+)">([^<]*)</\1>"#,
                                                            as: (Substring, Substring, Substring, Substring).self)
    // Any tag-shaped text left over: an opening tag, a closing one, whatever the writer made up.
    // swiftlint:disable:next force_try
    nonisolated(unsafe) private static let stray = try! Regex(#"</?[A-Za-z][^<>]*>"#)

    /// The text without any tag-shaped text in it.
    static func plain(_ text: String) -> String { text.replacing(stray, with: "") }

    /// The pieces in order. A tag it doesn't know, one left open or one that closes as another kind is dropped, its words
    /// kept as text; no piece ever holds tag text.
    static func parse(_ markup: String) -> [Piece] {
        var pieces: [Piece] = []
        func add(_ text: Substring) {
            let clean = plain(String(text))
            guard !clean.isEmpty else { return }
            if case .text(let last)? = pieces.last { pieces[pieces.count - 1] = .text(last + clean) } else { pieces.append(.text(clean)) }
        }
        var rest = Substring(markup)
        while let match = rest.firstMatch(of: tag) {
            add(rest[rest.startIndex..<match.range.lowerBound])
            if let kind = Kind(rawValue: String(match.output.1)) {
                pieces.append(.span(kind, session: String(match.output.2), text: String(match.output.3)))
            } else {
                add(match.output.3)
            }
            rest = rest[match.range.upperBound...]
        }
        add(rest)
        return pieces
    }
}

/// What the Brief keeps while the window lives: the highlight under the pointer and the card opened; and, across launches
/// with the window's other preferences, whether its history is beside it and how wide.
@Observable final class RouterDigestState {
    /// "paragraph#session" under the pointer.
    var hovered: String?
    /// "paragraph#session" opened under its paragraph.
    var open: String?
    /// The brief's history beside it.
    var historyOpen: Bool {
        didSet { if historyOpen != oldValue { defaults?.set(historyOpen, forKey: Self.openKey) } }
    }
    /// The history's width, as its edge was last dragged to (kept when the drag ends, `keepWidth`).
    var historyWidth: CGFloat
    /// The rewrites opened to their diff.
    var expanded: Set<String> = []
    /// Where the history's place is kept: the app's preferences for the window's model, none for shots and tests.
    @ObservationIgnored private let defaults: UserDefaults?

    static let openKey = "routerBriefHistoryOpen"
    static let widthKey = "routerBriefHistoryWidth"
    static let widths: ClosedRange<CGFloat> = 280...640

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        historyOpen = defaults?.bool(forKey: Self.openKey) ?? false
        let kept = defaults?.double(forKey: Self.widthKey) ?? 0
        historyWidth = kept > 0 ? Self.clamp(kept) : DigestHistory.width
    }

    static func clamp(_ width: CGFloat) -> CGFloat { min(max(width, widths.lowerBound), widths.upperBound) }

    /// Shows or hides the history, with the panels' spring.
    func toggleHistory() {
        withAnimation(Motion.spatial.resolved(reduce: Motion.systemReduce)) { historyOpen.toggle() }
    }

    func keepWidth() { defaults?.set(Double(historyWidth), forKey: Self.widthKey) }

    /// The session of the highlight under the pointer.
    var hoveredSession: String? { Self.session(hovered) }

    /// The session of a "paragraph#session" key (a folder may have a # in it, a session's id doesn't).
    static func session(_ key: String?) -> String? {
        guard let key, let mark = key.lastIndex(of: "#") else { return nil }
        return String(key[key.index(after: mark)...])
    }
}

/// What a key does to the highlight under the pointer: the inbox's own shortcuts (Settings), so they are the same keys
/// everywhere. Mark as read or unread marks what's worth a look seen, or opens again what was handled; Archive takes what
/// waits on you out; Open opens the session in Claude. Read from the session's cards, not the words.
enum DigestAction: Equatable {
    case seen(card: String)
    case reopen(card: String)
    case archive(card: String)
    case open(session: String)

    var shortcut: ShortcutAction {
        switch self {
        case .seen, .reopen: .toggleRead
        case .archive: .discard
        case .open: .openItem
        }
    }

    var label: String {
        switch self {
        case .seen: "Mark seen"
        case .reopen: "Open again"
        case .archive: "Archive"
        case .open: "Open in Claude"
        }
    }

    /// What can be done to a session's highlight now: its open card seen or archived, else (it stopped) its last card
    /// opened again; and the session opened.
    @MainActor static func available(session: String, store: Store) -> [DigestAction] {
        var out: [DigestAction] = []
        if let card = store.router.cards.last(where: { $0.sessionID == session && $0.isOpen }) {
            out.append(card.tier == .note ? .seen(card: card.id) : .archive(card: card.id))
        } else if store.claudeSessions[session]?.running != true,
                  let card = store.router.cards.last(where: { $0.sessionID == session }), store.routerCanReopen(card) {
            out.append(.reopen(card: card.id))
        }
        out.append(.open(session: session))
        return out
    }

    @MainActor func perform(model: RouterModel, store: Store) {
        withAnimation(Motion.spatial.resolved(reduce: Motion.systemReduce)) {
            switch self {
            case .seen(let card), .archive(let card):
                // Its card open under the paragraph closes with it, as the card's own Mark seen does.
                let session = store.router.cards.first { $0.id == card }?.sessionID
                if session != nil, RouterDigestState.session(model.digest.open) == session { model.digest.open = nil }
                model.address(card, store: store)
            case .reopen(let card): model.reopen(card, store: store)
            case .open(let session): store.openAgent(session)
            }
        }
    }
}

/// A key that acts on a highlight, and what it does, under its peek.
struct DigestHint: Hashable {
    let key: String
    let label: String
}

extension RouterModel {
    /// The card opened under a paragraph closes, and the reply it armed goes with it, unless you have started writing it.
    func closeDigestCard(store: Store) {
        guard let session = RouterDigestState.session(digest.open) else { return }
        digest.open = nil
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let reply = replyTo,
           store.router.cards.first(where: { $0.id == reply })?.sessionID == session {
            replyTo = nil
            selection = nil
        }
    }

    /// The action `shortcut` is on the Brief's highlight under the pointer, if it is one there.
    func digestAction(_ shortcut: Shortcut, store: Store) -> DigestAction? {
        guard let session = digest.hoveredSession else { return nil }
        return DigestAction.available(session: session, store: store).first { store.shortcut($0.shortcut) == shortcut }
    }
}

// MARK: - Page

struct DigestPage: View {
    let store: Store
    let model: RouterModel

    static let column: CGFloat = 720
    /// The room under the text for the composer floating over it.
    static let bottom: CGFloat = 150
    /// What the history leaves the text at least, however wide it was dragged.
    static let textRoom: CGFloat = 360
    @State private var pageWidth: CGFloat = 0

    var body: some View {
        let page = model.zones(store)
        let folders = model.canvasFolders(store, page: page)
        // Every tagged session resolves, not only the notes the canvas shows (it caps a project's at three).
        let items = Self.items(RouterCanvasModel.make(page: page, done: [], muted: Set(store.agents.mutedFolders),
                                                      name: store.routerProjectGroupName, color: { _ in nil }, showsAll: true,
                                                      projectKey: { store.routerProjectGroupKey(sessionID: $0, folder: $1) },
                                                      projectSource: store.routerProjectGroupSource))
        ScrollView {
            Group {
                if let digest = store.routerDigest {
                    let fresh = digest.changedSinceSeen
                    VStack(alignment: .leading, spacing: 28) {
                        lead(digest, items: items, page: page, fresh: fresh)
                        ForEach(digest.projects) { project in
                            let folder = folders.first { $0.key == project.folder }
                            DigestParagraph(store: store, model: model, page: page, items: items, key: project.folder,
                                            markup: project.text) {
                                HStack(spacing: 7) {
                                    Circle().fill(folder?.color ?? CDS.Text.muted).frame(width: 8, height: 8)
                                    Text(folder?.name ?? (project.folder as NSString).lastPathComponent)
                                        .font(CDS.sans(13, .semibold)).foregroundStyle(CDS.Text.primary)
                                    if fresh.contains(project.folder) { NewTag() }
                                }
                            }
                            .zIndex(model.digest.hovered?.hasPrefix(project.folder + "#") == true ? 1 : 0)
                        }
                    }
                } else {
                    empty
                }
            }
            .frame(maxWidth: Self.column, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, DigestPage.bottom)
            .frame(maxWidth: .infinity)
        }
        // The history, a column on the right, beside the text rather than over it: as wide as it was dragged to, leaving
        // the text room in a narrow window.
        .safeAreaInset(edge: .trailing, spacing: 0) {
            if model.digest.historyOpen {
                DigestHistory(store: store, model: model, history: store.routerDigest?.history ?? [],
                              seenAt: store.routerDigest?.seenAt, folders: folders,
                              messages: DigestHistory.messages(in: store.router.decisions))
                    .frame(width: historyWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        // Working sessions are kept current while it is on screen; left, what changes from now on is new when you come back.
        .onAppear { store.routerDigester.setVisible(true, store: store) }
        .onDisappear {
            store.routerDigester.setVisible(false, store: store)
            Self.markSeen(store)
        }
    }

    /// What was new has been seen: what changes after now is marked new.
    static func markSeen(_ store: Store, now: Date = Date()) {
        guard var digest = store.routerDigest, !digest.changedSinceSeen.isEmpty || digest.seenAt == nil else { return }
        digest.seenAt = now
        store.routerDigest = digest
    }

    /// The history's width as dragged, narrower if the page would leave the text less than `textRoom`.
    private var historyWidth: CGFloat {
        let width = model.digest.historyWidth
        guard pageWidth > 0 else { return width }
        return min(width, max(RouterDigestState.widths.lowerBound, pageWidth - Self.textRoom))
    }

    /// No brief yet: the Router off, the first one being written, or nothing going on.
    @ViewBuilder private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if !store.router.enabled {
                    Text("Turn the Router on and the Brief will tell you what your sessions need, project by project.")
                } else if store.routerDigester.writing {
                    Text("Writing the brief…")
                } else if store.routerZones.needs.isEmpty && store.routerZones.notes.isEmpty && store.routerZones.working.isEmpty {
                    Text("Nothing going on. When a session finishes, asks something or gets stuck, it will be here.")
                } else {
                    Text("The brief will be written in a moment.")
                }
            }
            .font(CDS.sans(14)).foregroundStyle(CDS.Text.secondary)
        }
    }

    /// The lead: what's for you, then what's worth a look, each under its name in its colour.
    private func lead(_ digest: RouterDigest, items: [String: CanvasItem], page: RouterPage, fresh: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            DigestParagraph(store: store, model: model, page: page, items: items, key: RouterDigest.Revision.forYouKey,
                            markup: digest.forYou, size: 16) {
                HStack(spacing: 7) {
                    Label("For you", systemImage: RouterZone.needs.symbol)
                        .font(CDS.sans(12, .semibold)).foregroundStyle(RouterZone.needs.tint)
                    if fresh.contains(RouterDigest.Revision.forYouKey) { NewTag() }
                }
            }
            .zIndex(model.digest.hovered?.hasPrefix("lead-you#") == true ? 2 : 1)
            if !digest.worthALook.isEmpty {
                DigestParagraph(store: store, model: model, page: page, items: items, key: RouterDigest.Revision.lookKey,
                                markup: digest.worthALook, size: 16) {
                    HStack(spacing: 7) {
                        Label("Worth a look", systemImage: RouterZone.notes.symbol)
                            .font(CDS.sans(12, .semibold)).foregroundStyle(CDS.Text.accent)
                        if fresh.contains(RouterDigest.Revision.lookKey) { NewTag() }
                        Spacer()
                        let looks = page.notes
                        if !looks.isEmpty {
                            Button {
                                for card in looks { store.setCardAddressed(card.id, true) }
                                Announce.say("Marked seen")
                            } label: {
                                Label(looks.count == 1 ? "Mark seen" : "Mark all seen", systemImage: "checkmark")
                                    .font(CDS.sans(11.5, .medium)).foregroundStyle(CDS.Text.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Mark everything worth a look as seen: it leaves the brief")
                        }
                    }
                }
                .zIndex(model.digest.hovered?.hasPrefix("lead-look#") == true ? 2 : 0)
            }
            Rectangle().fill(CDS.border).frame(height: CDS.hairline).padding(.top, 4)
        }
        .zIndex(model.digest.hovered?.hasPrefix("lead-") == true ? 2 : 0)
    }

    /// Each session's item on the page: what it is waiting on you for first, else what it is doing.
    static func items(_ folders: [CanvasFolder]) -> [String: CanvasItem] {
        var out: [String: CanvasItem] = [:]
        func rank(_ item: CanvasItem) -> Int {
            switch item {
            case .need, .ready: 0
            case .note: 1
            case .waiting: 2
            case .working: 3
            case .done: 4
            }
        }
        for item in folders.flatMap({ $0.groups.flatMap(\.items) }) {
            if let had = out[item.sessionID], rank(had) <= rank(item) { continue }
            out[item.sessionID] = item
        }
        return out
    }
}

/// "New": a paragraph a rewrite changed since you last left the Brief.
private struct NewTag: View {
    var body: some View {
        Text("New")
            .font(CDS.sans(CDS.Badge.font, .semibold))
            .foregroundStyle(CDS.BadgeTint.accentText)
            .padding(.horizontal, CDS.Badge.padX)
            .frame(height: CDS.Badge.height)
            .background(RoundedRectangle(cornerRadius: CDS.Badge.radius, style: .continuous).fill(CDS.BadgeTint.accentFill))
            .accessibilityLabel("Changed since you last looked")
    }
}

/// A paragraph of the brief: its name over it, the text with its highlights, and the card opened from it under it.
private struct DigestParagraph<Title: View>: View {
    let store: Store
    let model: RouterModel
    let page: RouterPage
    let items: [String: CanvasItem]
    let key: String
    let markup: String
    var size: CGFloat = 15
    @ViewBuilder let title: Title

    var body: some View {
        let state = model.digest
        let opened = state.open.flatMap { $0.hasPrefix(key + "#") ? String($0.dropFirst(key.count + 1)) : nil }
        VStack(alignment: .leading, spacing: 8) {
            title
            DigestFlow(spacing: size * 0.27, lineSpacing: 5) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    switch token {
                    case .word(let word, let tight):
                        Text(word).font(CDS.sans(size)).foregroundStyle(CDS.Text.secondary)
                            .layoutValue(key: TightKey.self, value: tight)
                    case .span(let kind, let session, let text, let tight):
                        DigestSpan(store: store, model: model, page: page, item: items[session], kind: kind,
                                   id: key + "#" + session, session: session, text: text, size: size)
                            .layoutValue(key: TightKey.self, value: tight)
                            .zIndex(state.hovered == key + "#" + session ? 1 : 0)
                    }
                }
            }
            // A highlight's peek floats over the card opened under the text, not under it.
            .zIndex(state.hovered?.hasPrefix(key + "#") == true ? 1 : 0)
            if let opened, let item = items[opened] {
                HStack(alignment: .top, spacing: 8) {
                    CanvasNode(item: item, store: store, model: model, page: page)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 6) {
                        Button {
                            withAnimation(Motion.spatial.resolved(reduce: false)) { model.closeDigestCard(store: store) }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(CDS.Text.muted)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(CDS.alpha(0.06)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close the card")
                        // Worth a look: seen, and it leaves the brief.
                        if case .note(let card) = item {
                            Button {
                                withAnimation(Motion.spatial.resolved(reduce: false)) { state.open = nil }
                                model.address(card.id, store: store)
                            } label: {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(CDS.Text.accent)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(CDS.Text.accent.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            .help("Mark seen: it leaves the brief")
                            .accessibilityLabel("Mark seen")
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private enum Token {
        case word(String, tight: Bool)
        case span(DigestMarkup.Kind, session: String, text: String, tight: Bool)
    }

    /// The text cut into words and highlights; a word that follows a highlight without a space (its comma) sits against it.
    private var tokens: [Token] {
        var out: [Token] = []
        var glued = false
        for piece in DigestMarkup.parse(markup) {
            switch piece {
            case .text(let text):
                let startsTight = !(text.first?.isWhitespace ?? true)
                let words = text.split(whereSeparator: \.isWhitespace)
                for (i, word) in words.enumerated() {
                    out.append(.word(String(word), tight: i == 0 && startsTight && glued))
                }
                glued = !(text.last?.isWhitespace ?? true)
            case .span(let kind, let session, let text):
                out.append(.span(kind, session: session, text: text, tight: glued))
                glued = true
            }
        }
        return out
    }
}


// MARK: - History

/// The brief's history: each rewrite, newest first, in a line: who set it off (a session's icon, or you), what changed, and
/// when. Opened, why, then each paragraph it changed as a unified diff.
struct DigestHistory: View {
    let store: Store
    let model: RouterModel
    let history: [RouterDigest.Revision]
    let seenAt: Date?
    let folders: [CanvasFolder]
    /// What you sent (`messages(in:)`): in the list among the rewrites, by when, so every message is in the history with where
    /// it went, whether or not it changed the brief.
    var messages: [RouterDecision] = []

    /// One line of the list.
    private enum Item: Identifiable {
        case revision(RouterDigest.Revision)
        case message(RouterDecision)
        var id: String {
            switch self {
            case .revision(let r): r.id
            case .message(let d): d.id.uuidString
            }
        }
        var at: Date {
            switch self {
            case .revision(let r): r.at
            case .message(let d): d.at
            }
        }
    }

    private var items: [Item] {
        (history.map(Item.revision) + messages.map(Item.message)).sorted { $0.at > $1.at }
    }

    /// The messages you sent from the composer (or an action's prompt): your words went to a session, started one, or
    /// couldn't. What only answered a card, archived one or asked you has its own line among the rewrites when it changed
    /// the brief.
    static func messages(in decisions: [RouterDecision]) -> [RouterDecision] {
        decisions.filter { decision in
            guard case .you = decision.trigger else { return false }
            return decision.places.contains { place in
                place.done.contains { item in
                    switch item {
                    case .sent, .started, .interrupted, .preparedGuest, .failed: true
                    default: false
                    }
                }
            }
        }
    }

    /// Its width until its edge is dragged.
    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("History").font(CDS.sans(12, .semibold)).foregroundStyle(CDS.Text.primary)
                if !history.isEmpty {
                    Text(history.count == 1 ? "1 rewrite" : "\(history.count) rewrites").font(CDS.sans(11)).foregroundStyle(CDS.Text.muted)
                }
                Spacer(minLength: 0)
            }
            // Shown and hidden from the header's button (BriefHistoryToggle), as the window's sidebar is: no second one here.
            .padding(.leading, 12).padding(.trailing, 12).frame(height: 34)
            Rectangle().fill(CDS.border).frame(height: CDS.hairline)
            if history.isEmpty && messages.isEmpty {
                Text("Each time the Router rewrites the brief, what changed and why will be here.")
                    .font(CDS.sans(12)).foregroundStyle(CDS.Text.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            switch item {
                            case .revision(let revision): entry(revision)
                            case .message(let decision): message(decision)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, DigestPage.bottom)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CDS.Surface.s2)
        .overlay(alignment: .leading) { Rectangle().fill(CDS.border).frame(width: CDS.hairline) }
        // Its edge drags it wider or narrower; the width is kept once you let go.
        .overlay(alignment: .leading) { DigestHistoryEdge(state: model.digest).offset(x: -DigestHistoryEdge.reach / 2) }
    }

    /// A message you sent: you, where it went and when; opened, your words and what happened at each place.
    private func message(_ decision: RouterDecision) -> some View {
        let id = decision.id.uuidString
        let open = model.digest.expanded.contains(id)
        let places = decision.places
        let where_ = places.map { Self.destination($0) }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.spatial.resolved(reduce: false)) {
                    if open { model.digest.expanded.remove(id) } else { model.digest.expanded.insert(id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(CDS.Text.muted).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 8)
                    trigger(.you("")).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text("You told " + where_).font(CDS.sans(12.5, .medium)).foregroundStyle(CDS.Text.primary)
                        .lineLimit(open ? nil : 1)
                    Spacer(minLength: 4)
                    Text(shortAgo(decision.at)).font(CDS.sans(11)).foregroundStyle(CDS.Text.muted).monospacedDigit()
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(open ? CDS.alpha(0.05) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if case .you(let said) = decision.trigger, !said.isEmpty {
                        Text("“" + said + "”").font(CDS.sans(11.5)).foregroundStyle(CDS.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(places) { place in
                        Text(Self.destination(place) + ": " + Self.state(place))
                            .font(CDS.sans(11.5)).foregroundStyle(CDS.Text.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 21).padding(.trailing, 6).padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
    }

    /// Where a message went, in words: the session or project it was decided for.
    static func destination(_ place: RouterDecision) -> String {
        for item in place.done.reversed() {
            switch item {
            case .sent(let to, _, _): return place.decision.target ?? "“\(to)”"
            case .started(_, let project, _, _): return "a new session in \(project)"
            case .interrupted(let title, _, _): return "“\(title)”"
            default: continue
            }
        }
        return place.decision.target ?? "the Router"
    }

    /// What became of it at that place.
    static func state(_ place: RouterDecision) -> String {
        if place.isCancelled || place.parts.first?.endsCancelled == true { return "cancelled" }
        for item in place.done.reversed() {
            switch item {
            case .failed(let why): return "didn't go: " + why
            case .sent: return "sent"
            case .started: return "started a session"
            case .interrupted: return "stopped its turn and sent"
            case .preparedGuest: return "handed to Claude Desktop"
            default: continue
            }
        }
        return "pending"
    }

    private func entry(_ revision: RouterDigest.Revision) -> some View {
        let open = model.digest.expanded.contains(revision.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.spatial.resolved(reduce: false)) {
                    if open { model.digest.expanded.remove(revision.id) } else { model.digest.expanded.insert(revision.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(CDS.Text.muted).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 8)
                    trigger(revision.triggers.first ?? .you("")).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    if revision.at > (seenAt ?? .distantPast) {
                        Circle().fill(CDS.Text.accent).frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            .accessibilityLabel("New")
                    }
                    Text(revision.label).font(CDS.sans(12.5, .medium)).foregroundStyle(CDS.Text.primary)
                        .lineLimit(open ? nil : 1)
                    Spacer(minLength: 4)
                    Text(shortAgo(revision.at)).font(CDS.sans(11)).foregroundStyle(CDS.Text.muted).monospacedDigit()
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(open ? CDS.alpha(0.05) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    Text(revision.triggers.map(source).joined(separator: "; ") + ". " + revision.why)
                        .font(CDS.sans(11.5)).foregroundStyle(CDS.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(revision.changes.enumerated()), id: \.offset) { _, change in
                        diff(change)
                    }
                }
                .padding(.leading, 21).padding(.trailing, 6).padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
    }

    /// A paragraph's change as a code review shows a file's: its name on a bar, then its lines.
    private func diff(_ change: RouterDigest.Revision.Change) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Text(title(change.key)).font(CDS.mono(10.5, .medium)).foregroundStyle(CDS.Text.muted)
                .padding(.horizontal, 8).frame(height: 22).frame(maxWidth: .infinity, alignment: .leading)
                .background(CDS.alpha(0.04))
            Rectangle().fill(CDS.border).frame(height: CDS.hairline)
            ForEach(Array(DigestDiff.lines(change.before, change.after).enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(CDS.border, lineWidth: 1))
    }

    @ViewBuilder private func row(_ line: DigestDiff.Line) -> some View {
        switch line {
        case .fold:
            Text("⋯").font(CDS.mono(10.5)).foregroundStyle(CDS.Text.muted)
                .padding(.horizontal, 8).frame(height: 16).frame(maxWidth: .infinity, alignment: .leading)
                .background(CDS.alpha(0.02))
        case .same(let text):
            diffLine("", text, AttributedString(text), ink: CDS.Text.muted, ground: .clear)
        case .removed(let text, let changed):
            diffLine("−", text, marked(text, changed, Theme.red), ink: CDS.Text.secondary, ground: Theme.red.opacity(0.09))
        case .added(let text, let changed):
            diffLine("+", text, marked(text, changed, Theme.green), ink: CDS.Text.primary, ground: Theme.green.opacity(0.10))
        }
    }

    private func diffLine(_ sign: String, _ text: String, _ styled: AttributedString, ink: Color, ground: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sign).font(CDS.mono(11, .medium)).foregroundStyle(ink.opacity(0.7)).frame(width: 8)
            Text(styled).font(CDS.sans(11.5)).foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 2.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ground)
    }

    /// The sentence with the words that changed in it on a stronger ground of the line's colour.
    private func marked(_ text: String, _ ranges: [Range<String.Index>], _ tint: Color) -> AttributedString {
        var out = AttributedString(text)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].backgroundColor = tint.opacity(0.28)
        }
        return out
    }

    /// Who set it off: the session's own icon, or you.
    @ViewBuilder private func trigger(_ trigger: RouterDigest.Revision.Trigger) -> some View {
        switch trigger {
        case .session(let id):
            SessionMark(store: store, session: id, size: 15)
        case .you:
            Image(systemName: "person.fill").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(CDS.Text.accent)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(CDS.Text.accent.opacity(0.14)))
        }
    }

    private func source(_ trigger: RouterDigest.Revision.Trigger) -> String {
        switch trigger {
        case .session(let id): "From “\(store.claudeSessions[id]?.title ?? "a session")”"
        case .you(let said): "You said “\(said)”"
        }
    }

    private func title(_ key: String) -> String {
        switch key {
        case "lead-you": "For you"
        case "lead-look": "Worth a look"
        default: folders.first { $0.key == key }?.name ?? (key as NSString).lastPathComponent
        }
    }
}

/// What a highlight's session is at, in a mark and a colour: what it asks of you (its card's kind), worth a look, ready to go
/// on, waiting, or working.
struct DigestState {
    let symbol: String
    let tint: Color
    let label: String

    /// Its card handled since the text was written.
    static let handled = DigestState(symbol: "checkmark.circle.fill", tint: CDS.Text.muted, label: "Done")

    init(symbol: String, tint: Color, label: String) {
        (self.symbol, self.tint, self.label) = (symbol, tint, label)
    }

    init(_ item: CanvasItem?, kind: DigestMarkup.Kind) {
        switch item {
        case .need(let c), .done(let c):
            (symbol, tint, label) = (c.kind.symbol, c.kind.color, c.kind.label)
        case .ready:
            (symbol, tint, label) = ("arrow.right.circle.fill", CDS.Text.accent, "Ready to go on")
        case .note:
            (symbol, tint, label) = (RouterZone.notes.symbol, CDS.Text.accent, "Worth a look")
        case .waiting:
            (symbol, tint, label) = (RouterZone.waiting.symbol, RouterTriage.waitingTint, "Waiting")
        case .working:
            (symbol, tint, label) = ("ellipsis", CDS.Text.muted, "Working")
        case nil:
            (symbol, tint, label) = ("circle", kind.tint, "")
        }
    }
}

/// A highlight: its state's mark, its words on a ground of its state's colour, and its session's own icon after them, so
/// you see which session it is and what it's at before you hover it. Hovered, its card's gist floats under it; clicked,
/// the card opens under the paragraph and the composer answers it. Clicked with ⌘, it is picked as a recipient instead: your
/// message goes to it whole, with every other one picked (a chip over the composer for each).
private struct DigestSpan: View {
    let store: Store
    let model: RouterModel
    let page: RouterPage
    let item: CanvasItem?
    let kind: DigestMarkup.Kind
    let id: String
    let session: String
    let text: String
    let size: CGFloat

    /// The open card an item is, if it has one.
    static func cardID(_ item: CanvasItem) -> String? {
        switch item {
        case .need(let c), .ready(let c), .note(let c): c.id
        default: nil
        }
    }

    var body: some View {
        let state = model.digest
        let hovered = state.hovered == id
        let open = state.open == id
        // Handled since the text was written (answered, archived, seen): a check at once, before the rewrite says so.
        let finished: Bool = { if case .done = item { true } else { item == nil } }()
        let handled = finished && store.router.cards.last(where: { $0.sessionID == session }).map { !$0.isOpen } == true
        let status = handled ? DigestState.handled : DigestState(item, kind: kind)
        let quiet = kind == .run
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let recipient = model.live.recipients.contains(target)
        Button {
            // ⌘-click picks the session to send your message to; it opens nothing.
            if NSEvent.modifierFlags.contains(.command) { return toggleRecipient() }
            withAnimation(Motion.spatial.resolved(reduce: false)) {
                if open { model.closeDigestCard(store: store) } else { state.open = id }
                state.hovered = nil
            }
            if !open, let item {
                switch item {
                case .need(let c), .ready(let c), .note(let c): model.select(c.id, store: store, reveal: false)
                default: break
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: status.symbol)
                    .font(.system(size: size * 0.66, weight: .semibold))
                    .foregroundStyle(status.tint)
                Text(text)
                    .font(CDS.sans(size, quiet ? .regular : .medium))
                    .foregroundStyle(quiet ? CDS.Text.primary : status.tint)
                    .overlay(alignment: .bottom) {
                        if quiet {
                            Rectangle().fill(CDS.Text.muted.opacity(hovered ? 0.9 : 0.4)).frame(height: 1).offset(y: 1)
                        }
                    }
                SessionMark(store: store, session: session, size: size)
            }
            .padding(.horizontal, quiet ? 0 : 5)
            .padding(.vertical, 1)
            .background {
                if !quiet { shape.fill(status.tint.opacity(hovered || open ? 0.24 : 0.11)) }
            }
            .overlay { if open { shape.strokeBorder(status.tint.opacity(0.7), lineWidth: 1) } }
            // A recipient: ringed in the accent and marked with an arrow, whatever its state's colour.
            .overlay {
                if recipient { shape.strokeBorder(CDS.Text.accent, lineWidth: 1.5).padding(-1) }
            }
            .overlay(alignment: .topTrailing) {
                if recipient {
                    Image(systemName: "arrow.right.circle.fill").font(.system(size: size * 0.7))
                        .foregroundStyle(CDS.Text.accent).background(Circle().fill(CDS.Surface.s1).padding(2))
                        .offset(x: size * 0.3, y: -size * 0.4).accessibilityHidden(true)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { state.hovered = id } else if state.hovered == id { state.hovered = nil }
        }
        .overlay(alignment: .topLeading) {
            if hovered, !open, item != nil || handled {
                DigestPeek(item: item, fallback: store.router.cards.last { $0.sessionID == session }, page: page, hints: hints)
                    .frame(width: 400, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: size + 14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .contextMenu {
            Button(recipient ? "Don't send my message here" : "Send my message here") { toggleRecipient() }
            if let item, let card = DigestSpan.cardID(item) {
                Button("Open card") {
                    withAnimation(Motion.spatial.resolved(reduce: false)) { state.open = id }
                    model.select(card, store: store, reveal: false)
                }
                if case .note = item {
                    Button("Mark seen") { model.address(card, store: store) }
                } else {
                    Button("Archive") { model.address(card, store: store) }
                }
            }
        }
        .accessibilityLabel(status.label.isEmpty ? text : "\(text), \(status.label)")
        .accessibilityValue(recipient ? "Your message goes here" : "")
        .accessibilityHint(item == nil ? "Command-click picks it to send your message to" : "Opens its card. Command-click picks it to send your message to")
        .accessibilityAction(named: recipient ? "Don't send my message here" : "Send my message here") { toggleRecipient() }
    }

    /// The target of a recipient: the session itself.
    private var target: String { "session:\(session)" }

    /// Picks the session as a recipient of your message, or takes it off; the composer takes the keyboard for the words.
    private func toggleRecipient() { model.toggleRecipient(target, store: store) }

    /// The keys that act on it while the pointer is on it, as they are bound now.
    private var hints: [DigestHint] {
        DigestAction.available(session: session, store: store).compactMap { action in
            let shortcut = store.shortcut(action.shortcut)
            return shortcut.isUnassigned ? nil : DigestHint(key: shortcut.display, label: action.label)
        }
    }
}

/// A session's own icon, small and quiet, as the sidebar and its card show it: its symbol, else its letters or emoji.
private struct SessionMark: View {
    let store: Store
    let session: String
    let size: CGFloat

    var body: some View {
        let entry = store.agents.entries.first { $0.id == session }
        Group {
            if let icon = entry?.icon, entry?.label == nil {
                Image(systemName: icon).font(.system(size: size * 0.62, weight: .medium))
            } else {
                Text(entry?.label ?? initials).font(CDS.sans(size * 0.55, .semibold))
            }
        }
        .foregroundStyle(CDS.Text.muted)
        .frame(width: size * 1.05, height: size * 1.05)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(CDS.alpha(0.06)))
        .help(store.claudeSessions[session]?.title ?? "")
    }

    private var initials: String {
        let words = (store.claudeSessions[session]?.title ?? "").split(separator: " ").prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// What a highlight points at, floating over the text while hovered: the session, what kind of thing it is, what it says
/// and what it asks. Click to open the card itself.
private struct DigestPeek: View {
    /// Nil: its session is on no board any more, and its last card (`fallback`) is shown.
    let item: CanvasItem?
    var fallback: RouterCard?
    let page: RouterPage
    /// The keys that act on it, each with what it does.
    var hints: [DigestHint] = []

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(CDS.sans(13, .semibold)).foregroundStyle(CDS.Text.primary).lineLimit(1)
                if let card { KindTag(kind: card.kind) }
                Spacer(minLength: 4)
                Text(shortAgo(at)).font(CDS.sans(11)).foregroundStyle(CDS.Text.muted)
            }
            if !text.isEmpty {
                Text(LocalizedStringKey(text)).font(CDS.sans(12.5)).foregroundStyle(CDS.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let asks = card?.asks, !asks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(asks, id: \.question) { ask in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(CDS.Text.muted)
                            Text(LocalizedStringKey(ask.question)).foregroundStyle(CDS.Text.primary)
                        }
                        .font(CDS.sans(12.5))
                    }
                }
            }
            HStack(spacing: 10) {
                if item != nil { Text("Click to open") }
                ForEach(hints, id: \.label) { hint in
                    HStack(spacing: 4) {
                        Text(hint.key).font(CDS.sans(10.5, .medium)).foregroundStyle(CDS.Text.secondary)
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(CDS.alpha(0.07)))
                        Text(hint.label)
                    }
                }
            }
            .font(CDS.sans(11)).foregroundStyle(CDS.Text.muted)
        }
        .padding(12)
        .background(shape.fill(CDS.Surface.s3))
        .overlay(shape.strokeBorder(CDS.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
    }

    private var card: RouterCard? {
        switch item {
        case .need(let c), .ready(let c), .note(let c), .waiting(let c), .done(let c): c
        case .working: nil
        case nil: fallback
        }
    }

    private var title: String {
        switch item {
        case .working(let row): row.session.title
        default: card?.title ?? ""
        }
    }

    private var text: String {
        switch item {
        case .working(let row): row.activity?.text ?? page.summaries[row.id]?.text ?? ""
        default: card.map { $0.brief ?? $0.text } ?? ""
        }
    }

    private var at: Date {
        switch item {
        case .working(let row): row.activity?.since ?? row.session.lastActivity
        default: card?.createdAt ?? Date()
        }
    }
}

// MARK: - Flow

private struct TightKey: LayoutValueKey { static let defaultValue = false }

/// Words and highlights laid out as text is: left to right, onto the next line when the line is full, each line's items on
/// a shared middle. A tight item sits against the one before it.
struct DigestFlow: Layout {
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

/// The Brief history's leading edge: nothing drawn, the resize cursor on it, dragged to make the history wider or
/// narrower. The width follows the drag and is kept when you let go.
private struct DigestHistoryEdge: View {
    let state: RouterDigestState
    @State private var start: CGFloat?
    @State private var pushed = false
    @State private var inside = false

    /// How wide the edge reacts, centred on the history's border.
    static let reach: CGFloat = 8

    var body: some View {
        Color.clear
            .frame(width: Self.reach)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { over in
                inside = over
                if over, !pushed { NSCursor.resizeLeftRight.push(); pushed = true }
                // Left mid-drag, the cursor stays until the drag ends.
                if !over, pushed, start == nil { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = start ?? state.historyWidth
                        if start == nil { start = from }
                        // The edge is on the history's left: dragging left widens it.
                        state.historyWidth = RouterDigestState.clamp(from - drag.translation.width)
                    }
                    .onEnded { _ in
                        start = nil
                        state.keepWidth()
                        if !inside, pushed { NSCursor.pop(); pushed = false }
                    }
            )
            .accessibilityHidden(true)
    }
}

/// When the brief was last written, beside the Router's title as the other pages' subtitles, and that it is being
/// rewritten while it is.
struct BriefUpdated: View {
    let store: Store

    var body: some View {
        if store.routerDigester.writing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                subtitle("Updating the brief…")
            }
        } else if let digest = store.routerDigest {
            // Kept current while it shows: "updated 2m ago" moves on with the minute.
            TimelineView(.everyMinute) { context in
                subtitle("Updated " + agoPhrase(digest.at, now: context.date))
            }
        }
    }

    private func subtitle(_ text: String) -> some View {
        Text(text).font(CDS.sans(CDS.Density.compact.footnote.0)).foregroundStyle(CDS.Text.muted).lineLimit(1)
    }
}

/// The Brief's history beside it, shown and hidden from the Router's header (⌥⌘B), as the window's sidebar is from its
/// own button (⌘B); a dot on it while a rewrite you haven't seen is in the history.
struct BriefHistoryToggle: View {
    let store: Store
    let model: RouterModel

    static let key = "⌥⌘B"

    var body: some View {
        let open = model.digest.historyOpen
        let digest = store.routerDigest
        let unseen = digest.map { d in d.history.contains { $0.at > (d.seenAt ?? .distantPast) } } ?? false
        IconButton(symbol: "sidebar.right", help: open ? "Hide history" : "Show history", detail: Self.key,
                   size: IconButton.Size.header, active: open) { model.digest.toggleHistory() }
            .overlay(alignment: .topTrailing) {
                if unseen && !open {
                    Circle().fill(CDS.Text.accent).frame(width: 6, height: 6).offset(x: -3, y: 3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
