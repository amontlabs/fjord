import SwiftUI

// The history: a panel in the left sidebar's material, at the window's right beside the page when the window is wide, and
// across its bottom under the composer when it is narrow (RouterScreen places it). One line per event, newest first under
// its day: your message, the thread or project it went to (in its line's state colours), whether it got there, and when;
// an answer you gave; a change the Router or you made to Fjord, with Revert, opened to its card on a click. What didn't go is
// pinned on top, with Send again and Elsewhere, until it goes. Filters over it: Sent, Answers, Changes (only those it has).
// A click on a message or an answer selects its thread's line, so the composer writes to it.

struct RouterDrawer: View {
    let store: Store
    /// Its title line's height: the window's title line beside the page, shorter across the bottom.
    var titleHeight: CGFloat = 34

    /// Its height across the bottom, its width at the right.
    static let height: CGFloat = 260
    static let width: CGFloat = 340

    enum Filter: String, CaseIterable, Identifiable {
        case sent = "Sent", answers = "Answers", changes = "Changes"
        var id: String { rawValue }
    }

    /// Whether a message got where it went.
    enum Status: Equatable {
        case sending, delivered, asked, failed(String?), cancelled
        /// Nothing says (an entry from before the engine told it).
        case unknown
        var failed: Bool { if case .failed = self { true } else { false } }
    }

    /// One line, newest first.
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            case message(Status)
            case answer
            case change(FjordChange)
        }
        var id: String
        var at: Date
        var kind: Kind
        /// Your words, the answer's words, or the change's title.
        var text: String
        /// The thread it went to or answered, when there is one.
        var target: BriefTarget?
        /// Else the project it went to (a message to a project's coordinator, a new thread).
        var project: String?
        /// The decision it came from (a message's).
        var decision: UUID?

        var filter: Filter {
            switch kind {
            case .message: .sent
            case .answer: .answers
            case .change: .changes
            }
        }
    }

    @State private var filter: Filter?
    @State private var opened: Set<String> = []
    @State private var column: CGFloat = RouterDrawer.width

    var body: some View {
        let all = Self.lines(store)
        let now = Date()
        let failed = all.filter { if case .message(let s) = $0.kind { s.failed && now.timeIntervalSince($0.at) < 86_400 } else { false } }
        let shown = all.filter { line in (filter == nil || line.filter == filter) && !failed.contains(line) }
        let kinds = Filter.allCases.filter { f in all.contains { $0.filter == f } }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("History").font(CDS.sans(CDS.Density.compact.body.0, .medium)).foregroundStyle(CDS.Text.primary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.trailing, 6)
                if kinds.count > 1 {
                    ForEach(kinds) { f in
                        FilterPill(title: f.rawValue, on: filter == f) { filter = filter == f ? nil : f }
                    }
                }
            }
            .padding(.horizontal, 14).frame(height: titleHeight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if all.isEmpty {
                        Text("What you send, answer and change will be here.")
                            .cdsText(CDS.Density.compact.footnote, .regular, CDS.Text.muted)
                            .padding(.vertical, 6)
                    }
                    if !failed.isEmpty {
                        DayHeader(title: "Didn't go", tint: CDS.Text.danger)
                        ForEach(failed) { row($0, now: now) }
                    }
                    ForEach(Self.days(shown, now: now), id: \.title) { day in
                        DayHeader(title: day.title)
                        ForEach(day.lines) { row($0, now: now) }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The change cards' text stops at the panel's width, not the page's column.
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { column = $0 }
                .environment(\.cdsColumnWidth, column)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(SidebarPanel())
    }

    @ViewBuilder private func row(_ line: Line, now: Date) -> some View {
        HistoryLine(store: store, line: line, now: now, open: opened.contains(line.id)) {
            if opened.contains(line.id) { opened.remove(line.id) } else { opened.insert(line.id) }
        }
        if case .change(let change) = line.kind, opened.contains(line.id) {
            ChangeCard(change: change, store: store).padding(.horizontal, 6).padding(.bottom, 4)
        }
    }

    struct Day { var title: String; var lines: [Line] }

    /// The lines under their day: Today, Yesterday, then the date.
    static func days(_ lines: [Line], now: Date, calendar: Calendar = .current) -> [Day] {
        var out: [Day] = []
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        for line in lines {
            let title = calendar.isDate(line.at, inSameDayAs: now) ? "Today"
                : calendar.isDate(line.at, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) ? "Yesterday"
                : formatter.string(from: line.at)
            if out.last?.title == title { out[out.count - 1].lines.append(line) } else { out.append(Day(title: title, lines: [line])) }
        }
        return out
    }

    /// Every line, newest first: your messages (RouterDecisions) with where they went and how it went, your answers, and
    /// the changes to Fjord (the Router's, and your acts on the page).
    static func lines(_ store: Store) -> [Line] {
        var out: [Line] = []
        for d in store.router.decisions.suffix(80) {
            guard case .you(let words) = d.trigger, !words.isEmpty, d.decision.intent != "answer" else { continue }
            let target = d.links.threads.lazy.compactMap(BriefTarget.init(key:)).first ?? place(d.decision.targetID, store: store).thread
            out.append(Line(id: d.id.uuidString, at: d.at, kind: .message(status(d, store: store)), text: words, target: target,
                            project: target == nil ? place(d.decision.targetID, store: store).project : nil, decision: d.id))
        }
        for c in store.router.changes.suffix(80) {
            out.append(Line(id: c.id.uuidString, at: c.date, kind: .change(c), text: c.title))
        }
        return out.sorted { $0.at > $1.at }
    }

    /// Where a decision's target sends: a thread, or a project.
    static func place(_ targetID: String?, store: Store) -> (thread: BriefTarget?, project: String?) {
        switch targetID.flatMap(RouteTarget.init) {
        case .newThread(let project)?: (nil, project)
        // A thread's project isn't in its target: T3's shell has it.
        case .thread(let id)?: store.threads[id].map { (BriefTarget(project: $0.projectID, thread: id), nil) } ?? (nil, nil)
        default: (nil, nil)
        }
    }

    /// How a message went: what it did, then what the engine says of its delivery.
    static func status(_ d: RouterDecision, store: Store) -> Status {
        for done in d.done.reversed() {
            switch done {
            case .failed(let why): return .failed(why)
            case .cancelled: return .cancelled
            case .asked where d.outcome == .pending: return .asked
            default: continue
            }
        }
        if d.done.contains(where: \.sendsWords) { return .delivered }
        return d.outcome == .pending && Date().timeIntervalSince(d.at) < 120 ? .sending : .unknown
    }
}

private struct DayHeader: View {
    let title: String
    var tint: Color = CDS.Text.muted

    var body: some View {
        Text(title).cdsText(CDS.Density.compact.footnote, .medium, tint)
            .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct FilterPill: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(CDS.sans(11.5, .medium)).foregroundStyle(on ? CDS.Text.primary : CDS.Text.muted)
                .padding(.horizontal, 7).frame(height: 20)
                .background(Capsule().fill(on ? CDS.alpha(0.10) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One event on one line: its mark, its words, where it went (a thread in its line's state colours, or a project), how it
/// went, and when; its one button at the end. A change's line opens its card under it on a click; a message's or an answer's
/// selects its thread's line.
private struct HistoryLine: View {
    let store: Store
    let line: RouterDrawer.Line
    let now: Date
    let open: Bool
    let toggle: () -> Void
    @State private var hover = false
    /// Editing a queued message's words in place.
    @State private var editing = false
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    /// The decision this line is about, and what changing your mind can do to it now.
    private var entry: RouterDecision? { line.decision.flatMap { store.router.record($0) } }
    private var mind: Store.ChangeOfMind { entry.map { store.changeOfMind($0) } ?? .none }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            lineButton
            if editing, case .cancelAndEdit = mind { editor }
        }
        // The message left the queue (it started, or was cancelled) while it was being edited.
        .onChange(of: mind) { if case .cancelAndEdit = mind {} else { editing = false } }
    }

    /// The queued message's words, changed in place: Return saves them, Esc leaves them be.
    private var editor: some View {
        HStack(spacing: 6) {
            TextField("Your words", text: $editText)
                .textFieldStyle(.plain).font(CDS.sans(12.5)).focused($editFocused)
                .onSubmit { save() }
                .onExitCommand { editing = false }
                .padding(.horizontal, 6).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(CDS.alpha(0.07)))
            small("Save") { save() }
            small("Leave") { editing = false }
        }
        .padding(.leading, 24).padding(.trailing, 6)
    }

    private func save() {
        guard let id = line.decision else { return }
        let words = editText
        editing = false
        Task { await store.editQueued(id, to: words) }
    }

    @ViewBuilder private var lineButton: some View {
        // A line with nothing to say under it (a change) keeps its button on its one line.
        let sub = line.target != nil || line.project != nil || statusWord != nil
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).frame(width: 12)
                    Text(line.text).font(CDS.sans(12.5)).foregroundStyle(reverted ? CDS.Text.muted : CDS.Text.primary)
                        .strikethrough(reverted).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if !sub { action }
                    Text(BriefAge.short(now.timeIntervalSince(line.at))).font(CDS.sans(11)).foregroundStyle(CDS.Text.muted).fixedSize()
                }
                if sub { HStack(spacing: 5) {
                    if let target = line.target {
                        let record = store.routerRecords.record(target.thread)
                        let look = record?.look
                        Image(systemName: look?.symbol ?? "ellipsis").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(look?.tint ?? CDS.Text.muted)
                        Text(store.threads[target.thread]?.title.nonEmpty ?? record?.title.nonEmpty ?? "a thread").font(CDS.sans(11.5, .medium))
                            .foregroundStyle(look?.ground == true ? look?.tint ?? CDS.Text.secondary : CDS.Text.secondary)
                            .lineLimit(1)
                        Text(store.routerProjectName(target.project)).font(CDS.sans(11)).foregroundStyle(CDS.Text.muted).lineLimit(1).fixedSize()
                    } else if let project = line.project {
                        Text(store.routerProjectName(project)).font(CDS.sans(11.5, .medium)).foregroundStyle(CDS.Text.secondary).lineLimit(1)
                    }
                    if let word = statusWord {
                        Text(word.0).font(CDS.sans(11)).foregroundStyle(word.1).lineLimit(1).fixedSize()
                    }
                    Spacer(minLength: 0)
                    action
                }
                .padding(.leading, 18) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover || open ? CDS.alpha(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private func tap() {
        if case .change = line.kind { toggle(); return }
        guard let target = line.target else { return }
        // Its line, selected: the composer writes to its card.
        store.routerFocus(target.thread)
    }

    /// Its one button: Revert on a change, Send again and Elsewhere on what didn't go.
    @ViewBuilder private var action: some View {
        switch line.kind {
        case .change(let change) where !change.isReverted && change.pending == nil:
            small("Revert") { store.revertFjordChange(change.id) }
        case .change(let change) where change.pending != nil:
            Text("waits for Apply").font(CDS.sans(11)).foregroundStyle(CDS.Text.warning).lineLimit(1).fixedSize()
        case .message(let status) where !status.failed && mind != .none:
            switch mind {
            case .cancelAndEdit:
                small("Edit") { editText = entry?.delivered?.editedTo ?? line.text; editing = true; editFocused = true }
                small("Cancel") { if let id = line.decision { Task { await store.cancelQueued(id) } } }
            case .stop:
                small("Stop") { if let id = line.decision { Task { await store.stopRun(id) } } }
            case .none:
                EmptyView()
            }
        case .message(let status) where status == .cancelled && (entry?.delivered).map({ store.queueHeld($0.thread) }) == true:
            small("Resume queue") { if let thread = entry?.delivered?.thread { Task { await store.resumeQueue(thread) } } }
        case .message(let status) where status.failed:
            small("Send again") {
                if let target = line.target { _ = store.sendToRouter(line.text, context: RouterContext(replyTo: target)) } else { _ = store.sendToRouter(line.text) }
            }
            if store.routerDispatcher.canSendElsewhere(line.decision) {
                small("Elsewhere…") { if let id = line.decision { store.routerDispatcher.sendElsewhere(id) } }
            }
        default:
            EmptyView()
        }
    }

    private func small(_ title: String, _ act: @escaping () -> Void) -> some View {
        Button(title, action: act).buttonStyle(.plain).font(CDS.sans(11.5, .medium)).foregroundStyle(CDS.Text.accent).fixedSize()
    }

    private var statusWord: (String, Color)? {
        switch line.kind {
        case .message(let s):
            switch s {
            case .sending: ("sending", CDS.Text.muted)
            case .delivered: Self.deliveredWord(entry?.delivered, store: store)
            case .asked: ("asked where", CDS.Text.warning)
            case .failed: ("didn't go", CDS.Text.danger)
            case .cancelled: ("cancelled", CDS.Text.muted)
            case .unknown: nil
            }
        case .answer: ("answered", CDS.Text.muted)
        case .change(let c): c.isReverted ? ("reverted", CDS.Text.muted) : nil
        }
    }

    /// Where a delivered message stands in its thread: waiting its turn (and where), in a turn under way, or delivered.
    private static func deliveredWord(_ sent: RouterDecision.Delivered?, store: Store) -> (String, Color) {
        guard let sent else { return ("delivered", CDS.Text.muted) }
        switch store.delivery(sent) {
        case .queued(_, let position): return ("queued (\(position))", CDS.Text.warning)
        case .working: return (sent.outcome == .steered ? "steered · can't be taken back" : "running", CDS.Text.muted)
        case .over, .unknown: return (sent.outcome == .queued ? "sent after its turn" : "delivered", CDS.Text.muted)
        }
    }

    private var help: String {
        switch line.kind {
        case .message(.failed(let why)): why ?? "It didn't go"
        case .change(let c): c.revertNote ?? c.pending ?? "Shows what it changed"
        default: line.text
        }
    }

    private var reverted: Bool { if case .change(let c) = line.kind { return c.isReverted }; return false }

    private var symbol: String {
        switch line.kind {
        case .message(let s): s.failed ? "exclamationmark.triangle.fill" : "arrow.up.right"
        case .answer: "checkmark.bubble"
        case .change(let c): c.symbol
        }
    }

    private var tint: Color {
        switch line.kind {
        case .message(let s): s.failed ? CDS.Text.danger : CDS.Text.muted
        default: CDS.Text.muted
        }
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
