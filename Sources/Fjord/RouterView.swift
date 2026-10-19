import AppKit
import SwiftUI

// What the Router's window is built on (`RouterCodeView` lays it out): the store's side of the Router, the cards' lines and
// tags, the window's model (the pick, the draft, its chips and @, the forms and plans being answered), the notice of what
// stands in the way, and the Working list the bar shows.

// MARK: - Store

extension Store {
    /// A session's visible project keeps its execution owner and guest root separate from the host folder mirror.
    func routerSessionProject(_ sessionID: String) -> (name: String, color: Color?) {
        guard let start = router.pendingDesktopStarts.first(where: { $0.desktopSessionID == sessionID && $0.state == .matched }),
              let project = router.runsOnProjects.first(where: { $0.id == start.projectID }) else {
            let folder = claudeSessions[sessionID]?.folderKey ?? ""
            return (folderName(folder), projectColor(folder))
        }
        let owner = start.location.key
        return ("\(project.name) · \(start.alias) @ \(owner):\(start.folder)", projectColor(project.sourceFolder))
    }

    /// A card's project, as the lists name and colour it.
    func routerProject(_ card: RouterCard) -> (name: String, color: Color?) {
        if router.pendingDesktopStarts.contains(where: { $0.desktopSessionID == card.sessionID && $0.state == .matched }) {
            return routerSessionProject(card.sessionID)
        }
        let folder = card.folder ?? ""
        return (folderName(folder), projectColor(folder))
    }

    /// A canvas frame key. Local projects keep their old folder key; guest folders include project and owner identity.
    func routerProjectGroupKey(sessionID: String, folder: String) -> String {
        guard let start = router.pendingDesktopStarts.first(where: { $0.desktopSessionID == sessionID && $0.state == .matched }) else {
            return folder
        }
        return "guest-project:\(start.projectID.uuidString):\(start.location.key):\(start.folder)"
    }

    func routerProjectGroupName(_ key: String) -> String {
        guard key.hasPrefix("guest-project:"),
              let start = router.pendingDesktopStarts.first(where: {
                  $0.state == .matched && routerProjectGroupKey(sessionID: $0.desktopSessionID ?? "", folder: $0.folder) == key
              }) else { return folderName(key) }
        return routerSessionProject(start.desktopSessionID ?? "").name
    }

    func routerProjectGroupSource(_ key: String) -> String {
        guard key.hasPrefix("guest-project:"),
              let start = router.pendingDesktopStarts.first(where: {
                  $0.state == .matched && routerProjectGroupKey(sessionID: $0.desktopSessionID ?? "", folder: $0.folder) == key
              }), let project = router.runsOnProjects.first(where: { $0.id == start.projectID }) else { return key }
        return project.sourceFolder
    }

    func routerProjectGroupColor(_ key: String) -> Color? {
        projectColor(routerProjectGroupSource(key))
    }

    /// The Router's switch: it turns the reading of Claude's sessions, which it works on, on and off with it.
    func switchRouter(_ on: Bool) {
        if on { setAgentsEnabled(true) }
        setRouterEnabled(on)
        if !on {
            GuestRouterRuntime.shared.disableAll()
            setAgentsEnabled(false)
        }
    }

    /// The sessions working now (not those stopped on you), and those whose turn is over with subagents or commands still
    /// running (the tiles count them as working too); the longest running first.
    var routerWorkingRows: [AgentRow] {
        allAgentRows.filter { ($0.session.running && !$0.waitsForYou) || (!$0.session.running && !$0.tasks.isEmpty) }
            .sorted { (Self.workingStart($0) ?? .distantFuture) < (Self.workingStart($1) ?? .distantFuture) }
    }

    /// Since when a row in the Working list works: its turn, or the oldest thing it left running.
    static func workingStart(_ row: AgentRow) -> Date? {
        row.session.running ? row.workingSince : row.tasks.map(\.since).min()
    }

    /// The Router's own process must never reach real sessions from a demo or a playground: it answers for itself there.
    var routerIsPretend: Bool { Store.isDemo || !persists }

    /// Your message to the Router, with the card it replies to and the projects you tagged; in a demo, a canned reply
    /// instead of a real process. Whether it went: an ask-back's target named that is gone since sends nothing.
    @discardableResult
    func sendToRouter(_ text: String, context: RouterContext = RouterContext(), now: Date = Date()) -> Bool {
        let text = RouterModel.sendable(text)
        guard !text.isEmpty else { return false }
        if routerIsPretend && !RouterFlightDemo.on {
            var entry = RouterDecision(at: now, trigger: .you(text), decision: .init(intent: "message"), outcome: .done,
                                       links: .init(cards: context.replyTo.map { [$0] } ?? []))
            let mentions = RouterDispatcher.mentions(context.mentions, in: text)
            entry.mentions = mentions.isEmpty ? nil : mentions
            entry.reply = "In a demo the Router only says what it would do."
            logDecision(entry)
            return true
        }
        return routerDispatcher.submit(text, context: context) != nil
    }

    /// Writes a form's answer for its card's session (the hook passes it on) through the shared `FormWriter`, off the main
    /// thread; in a demo, nothing is written. The folder is taken now, on the main thread: none while the Router is off. The
    /// write is dropped if, by the time it happens, the Router or the sessions are off or the card is no longer open.
    /// The last check before a form's answer is written: the Router is on, the card still open and, for an answer the Router
    /// read, still holding the form it was read against.
    func answerStillValid(card: String, snapshot: FormSnapshot?, alsoValid: (@MainActor () -> Bool)? = nil) -> Bool {
        routerOn && alsoValid?() != false && router.cards.first(where: { $0.id == card })?.isOpen == true
            && snapshot.map { $0.holds(self) } != false
    }

    /// With a `snapshot` (an answer the Router read), it is written only while the card still holds that very form, checked
    /// again right before the write.
    func answerForm(_ form: PendingForm, _ answers: [String: String], card: String,
                    snapshot: FormSnapshot? = nil, alsoValid: (@MainActor () -> Bool)? = nil) async -> Result<Void, Error> {
        if let snapshot, !snapshot.holds(self) { return .failure(FormWriter.Cancelled()) }
        if routerIsPretend { return Result { _ = try FormBridge.validate(form, answers) } }
        if let cardState = router.cards.first(where: { $0.id == card }),
           let guestForm = guestPendingForm(for: cardState) {
            do {
                try await GuestRouterRuntime.shared.answer(guestForm, answers: answers, cardID: card, snapshot: snapshot)
                logCardAction("Answered the form", card: card)
                return .success(())
            } catch { return .failure(error) }
        }
        guard let dir = formBridge.dir else { return .failure(FormWriter.Cancelled()) }
        do {
            try await FormWriter.write(form, answers: answers, dir: dir, stillValid: { [weak self] in
                self?.answerStillValid(card: card, snapshot: snapshot, alsoValid: alsoValid) ?? false
            })
            logCardAction("Answered the form", card: card)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// The same for a plan: your decision is written for the hook, which gives it to the session as Approve or Keep planning
    /// in the app would.
    func answerPlan(_ form: PendingForm, _ decision: PendingForm.PlanDecision, card: String,
                    snapshot: FormSnapshot? = nil) async -> Result<Void, Error> {
        if let snapshot, !snapshot.holds(self) { return .failure(FormWriter.Cancelled()) }
        if routerIsPretend { return Result { _ = try FormBridge.answerData(form, plan: decision) } }
        if let cardState = router.cards.first(where: { $0.id == card }),
           let guestForm = guestPendingForm(for: cardState) {
            do {
                try await GuestRouterRuntime.shared.answer(guestForm, plan: decision, cardID: card, snapshot: snapshot)
                logCardAction(decision.approve ? "Approved the plan" : "Sent the plan back", card: card)
                return .success(())
            } catch { return .failure(error) }
        }
        guard let dir = formBridge.dir else { return .failure(FormWriter.Cancelled()) }
        do {
            try await FormWriter.write(form, plan: decision, dir: dir, stillValid: { [weak self] in
                self?.answerStillValid(card: card, snapshot: snapshot) ?? false
            })
            logCardAction(decision.approve ? "Approved the plan" : "Sent the plan back", card: card)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

/// Content redrawn on the minute and only then (ages, the status line): nothing else ticks for it.
struct MinuteTicking<Content: View>: View {
    /// Out of sight: it stops on the minute it was at, and catches up once shown.
    var paused = false
    @ViewBuilder let content: (Date) -> Content

    init(paused: Bool = false, @ViewBuilder content: @escaping (Date) -> Content) {
        self.paused = paused
        self.content = content
    }

    var body: some View {
        TimelineView(Minutes(paused: paused)) { context in content(context.date) }
    }
}

/// Every minute on the minute, as `.everyMinute`; paused, only the moment it started.
private struct Minutes: TimelineSchedule {
    let paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, paused: paused)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let paused: Bool

        mutating func next() -> Date? {
            guard let date = upcoming else { return nil }
            if paused {
                upcoming = nil
            } else {
                let minute = (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
                upcoming = Date(timeIntervalSinceReferenceDate: minute + 60)
            }
            return date
        }
    }
}

// MARK: - Cards

extension RouterCard.Kind {
    var label: String {
        switch self {
        case .question: "Question"
        case .plan: "Plan"
        case .done: "Done"
        case .stuck: "Stuck"
        case .asks: "Asks you"
        case .approval: "Needs your OK"
        case .waiting: "Waiting"
        case .finish: "Finish up"
        }
    }

    var color: Color {
        switch self {
        case .question: Theme.amber
        case .plan: Theme.purple
        case .done: Theme.accent
        case .stuck: Theme.red
        case .asks: Theme.amber
        case .approval: RouterTriage.approvalTint
        case .waiting: RouterTriage.waitingTint
        case .finish: Theme.amber
        }
    }

    var symbol: String {
        switch self {
        case .question: "questionmark.bubble.fill"
        case .plan: "list.bullet.clipboard.fill"
        case .done: "checkmark"
        case .stuck: "exclamationmark.triangle.fill"
        case .asks: "bubble.left.and.text.bubble.right.fill"
        case .approval: "hand.raised.fill"
        case .waiting: "hourglass"
        case .finish: "flag.fill"
        }
    }
}

extension RouterCard.Addressed {
    /// What happened to an addressed card, in a few words.
    var label: String {
        switch self {
        case .you: "Archived"
        case .reply: "You replied"
        case .router: "The Router passed it on"
        case .answered: "Answered"
        case .opened: "Opened"
        case .superseded: "Followed by a newer card"
        case .gone: "Session archived"
        case .settled: "Done"
        }
    }
}

extension RouterCard {
    /// Whether it can be opened again (Reopen): an addressed card, unless a newer card of its session replaced it or
    /// its session was archived or deleted.
    var canReopen: Bool { !isOpen && addressedBy != .superseded && addressedBy != .gone }
}

extension Store {
    /// `RouterCard.canReopen`, and once the app's sessions have been read, only while its session is still there and not
    /// archived: a card handled before its session went (only open cards are marked gone) isn't opened again on nothing. A
    /// read failing since goes by the sessions last read.
    func routerCanReopen(_ card: RouterCard) -> Bool {
        guard card.canReopen else { return false }
        guard claudeSessionsRead else { return true }
        return claudeSessions[card.sessionID].map { !$0.isArchived } ?? false
    }
}

/// A card's kind in its colour: words and a glyph, never colour alone.
struct KindTag: View {
    let kind: RouterCard.Kind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(Theme.Typography.caption.weight(.semibold))
            .foregroundStyle(kind.color)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(kind.color.opacity(0.14)))
            .fixedSize()
    }
}

/// A card's kind as its icon alone, in its tag's tint, named in its tip: `KindTag` where there is no room for its name.
struct KindGlyph: View {
    let kind: RouterCard.Kind

    var body: some View {
        Image(systemName: kind.symbol)
            .font(Theme.Typography.caption.weight(.semibold))
            .foregroundStyle(kind.color)
            .frame(width: 18, height: 16)
            .background(Capsule().fill(kind.color.opacity(0.14)))
            .fixedSize()
            .help(kind.label)
            .accessibilityLabel(kind.label)
    }
}

/// Card text is the app's own summary or the session's question: inline Markdown (**bold**, `code`) as the sessions show it.
enum RouterText {
    /// Parsed once per text: cards, the page and the transcript ask again on every redraw. Up to 1000 texts, 4 MB of them.
    private static let parsed = RenderCache<AttributedString>(countLimit: 1000, totalCostLimit: 4 << 20)

    static func inline(_ text: String) -> AttributedString {
        parsed.value(text, cost: text.utf8.count) {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        }
    }

    /// A plan's Markdown, line by line as written: headings in bold without their #, the rest with its inline styles.
    static func plan(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (i, raw) in text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            if i > 0 { out += AttributedString("\n") }
            let line = String(raw)
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("#") {
                var heading = inline(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                heading.inlinePresentationIntent = .stronglyEmphasized
                out += heading
            } else {
                out += inline(line)
            }
        }
        return out
    }
}

/// A card on two short lines, for the bar's panel: the session and its age, then the kind, the project and the text.
/// Clicking it opens the Router on it.
struct RouterCardLine: View {
    let card: RouterCard
    let store: Store
    /// In a narrow column: the project goes (the kind and the text stay).
    var narrow = false
    let open: (String) -> Void
    @State private var hover = false

    var body: some View {
        let project = store.routerProject(card)
        Button { open(card.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                if let session = store.sessionRow(card.sessionID) {
                    SessionGlyph(row: session, size: 18, dot: false).padding(.top, 1)
                } else {
                    Circle().fill(card.kind.color).frame(width: 6, height: 6).padding(.top, 6)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(card.title).font(Theme.Typography.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(shortAgo(card.createdAt)).font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                            .help(exactTime(card.createdAt))
                    }
                    HStack(spacing: 6) {
                        KindTag(kind: card.kind)
                        if !narrow {
                            ProjectLabel(name: project.name, color: project.color, maxWidth: 160)
                                .font(Theme.Typography.meta).foregroundStyle(Theme.tertiary).layoutPriority(1)
                        }
                        Text(RouterText.inline(card.text)).font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowHighlight(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu { if let session = store.sessionRow(card.sessionID) { SessionMenu(row: session, store: store) } }
        .accessibilityLabel("\(card.kind.label): \(card.title)")
        .accessibilityValue("\(project.name), \(card.text), \(AgentRow.spokenAge(Date().timeIntervalSince(card.createdAt))) ago, at \(exactTime(card.createdAt))")
        .accessibilityHint("Opens it in the Router")
    }
}

// MARK: - Window model

/// What the window remembers while it is closed (the draft, the picked card, the answers being put together), and what
/// the keys act on.
@Observable
@MainActor
final class RouterModel {
    /// The Working sessions' summaries being made.
    @ObservationIgnored let summarizer = RouterSummarizer()
    /// Your messages on their way: pills over the composer, flying to where each went.
    @ObservationIgnored let flights = RouterFlights()
    /// The card the keys act on.
    var selection: String? {
        didSet { if selection != oldValue { remark(oldValue); remark(selection); pruneMarks() } }
    }
    /// Whether an item is picked or marked, by item, read by the item itself (`isMarked`): each card or row observes its
    /// own, so the keys moving the pick redraw the two cards it left and reached, not every card of the page.
    @ObservationIgnored private var marks: [String: Mark] = [:]
    @Observable final class Mark {
        var on: Bool
        init(on: Bool) { self.on = on }
    }

    /// Whether `id` is the pick or the item marked for now (`highlighted`), observing only that item's mark.
    func isMarked(_ id: String) -> Bool {
        if let mark = marks[id] { return mark.on }
        // The stored values, read without observing them.
        let mark = Mark(on: _selection == id || _highlighted == id)
        marks[id] = mark
        return mark.on
    }

    /// The marks of items gone (cards archived to the history, sessions done) let go once there are more than the page
    /// draws (`HubState.Mark.pruned`: an item still drawn makes its own again).
    private func pruneMarks() {
        guard marks.count > HubState.Mark.kept else { return }
        for mark in marks.values { mark.on.toggle(); mark.on.toggle() }
        marks = [:]
    }

    private func remark(_ id: String?) {
        guard let id, let mark = marks[id] else { return }
        let on = _selection == id || _highlighted == id
        if mark.on != on { mark.on = on }
    }
    var draft = "" {
        didSet { if draft != oldValue { sendRefused = nil; mentionChanged() } }
    }
    /// Why the draft wasn't sent (it stays in the composer), until it changes.
    var sendRefused: String?
    static let goneTarget = "Not sent: what you named was handled or is gone since. Pick where it goes on the ask, or say more."
    /// Asks the Router's conversation to scroll to a message (an inbox action's), selecting no card and replying to none:
    /// what you write next goes to the Router.
    var messageRequest: ScrollRequest?
    func show(message: UUID) {
        // A search or the Unread filter could hide the message: they end.
        if searching { endSearch() }
        unreadOnly = false
        selection = nil
        replyTo = nil
        show(.history)
        messageRequest = ScrollRequest(id: message.uuidString, seq: (messageRequest?.seq ?? 0) + 1)
    }
    /// The card your next message answers: it goes to that card's session ("Replying to …" over the composer). Armed, it
    /// ends an edit (the draft then answers the card).
    var replyTo: String? {
        didSet { if replyTo != nil, editing != nil { editing = nil } }
    }
    /// A message of yours being edited ("Edit and resend"): sending the draft forks its session from before it, with the
    /// draft as the fork's first message. The session stays as it was; files its agent changed aren't rolled back.
    var editing: Editing?
    struct Editing: Equatable {
        var session: String
        /// The message as it was sent, and when the run that sent it began: where the fork is cut.
        var original: String
        var sentAt: Date? = nil
    }

    /// "Edit and resend": the message in the composer, which takes the keyboard; no reply or pin goes with it (picking one
    /// later ends the edit: the draft then goes there as a message of its own). Its pills come back as the "@name" they were
    /// sent as; an attachment character in it (pasted before the composer left them out) goes, as a paste's does.
    func edit(session: String, message: String, sentAt: Date? = nil) {
        replyTo = nil
        live.reset()
        pointers = []
        editing = Editing(session: session, original: message, sentAt: sentAt)
        let words = message.replacingOccurrences(of: MentionText.markString, with: "")
        draft = words
        caretRequest = (words as NSString).length
        focusRequest &+= 1
    }
    /// In a narrow window, the side of the page shown: it follows what you pick (an open card is in Now, an addressed one and
    /// the Router's conversation in History). A wide window shows both.
    var pane: RouterPane = .now
    /// Shows a side of the page, written only when it changes: the page's frame redraws on it.
    func show(_ side: RouterPane) { if pane != side { pane = side } }
    /// The history shows only its unread lines (the Unread toggle over it). A line read while it does stays until the filter
    /// goes off, so reading one doesn't pull it from under you.
    var unreadOnly = false {
        didSet { if unreadOnly != oldValue { unreadKept = [] } }
    }
    /// The lines the filter has shown unread since it went on, kept once read; added to as the history is filtered, so not
    /// drawn from.
    @ObservationIgnored var unreadKept: Set<String> = []

    /// The sections of Now folded, as you last left them (kept across launches with the window's other preferences, not in
    /// the Router's state: a fold redraws only the page).
    var folded: Set<RouterZone> {
        didSet {
            guard folded != oldValue else { return }
            defaults?.set(RouterZone.allCases.filter(folded.contains).map(\.rawValue), forKey: RouterZone.foldsKey)
        }
    }
    /// Where the folds are kept: the app's preferences for the window's model, none for shots and tests.
    @ObservationIgnored private let defaults: UserDefaults?

    /// Now as the Brief (the default), a canvas or a list, picked in the top bar, kept as the folds are.
    var layout: RouterLayout {
        didSet {
            guard layout != oldValue else { return }
            defaults?.set(layout.rawValue, forKey: RouterLayout.key)
        }
    }
    /// The states soloed and muted, the same in the list and on the canvas (RouterFilter.swift).
    var filter = RouterFilter()
    /// What the canvas keeps while the window lives: its camera and folds (RouterCanvas.swift).
    let canvas: RouterCanvasState
    /// What the Brief keeps (RouterDigest.swift).
    let digest: RouterDigestState

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        folded = RouterZone.folds(in: defaults)
        layout = defaults?.string(forKey: RouterLayout.key).flatMap(RouterLayout.init(rawValue:)) ?? .brief
        canvas = RouterCanvasState(defaults: defaults)
        digest = RouterDigestState(defaults: defaults)
    }
    /// A fold of yours, or while a search is on, of the search's (`shownFolds`).
    func setFolded(_ zone: RouterZone, _ on: Bool) {
        if searching {
            if on { searchFolds.insert(zone) } else { searchFolds.remove(zone) }
            return
        }
        if on { folded.insert(zone) } else { folded.remove(zone) }
    }
    /// The search over Now and History, in the page's header (RouterSearch.swift), and the folds made while it is on.
    let search = InboxSearch()
    var searchFolds: Set<RouterZone> = []
    /// The history as the search last left it, for its words and the history's revision (`searchedHistory`).
    @ObservationIgnored var searchedHistoryMemo: (query: String, revision: Int, entries: [RouterPage.Entry])?
    /// Jev's pick for the draft while you type, and the target you fixed from it (see RouterJev.swift).
    let live = RouterLiveTarget()
    /// What the pills in the draft point to, one for each `MentionText.mark` in it, in order.
    var pointers: [RouterPointer] = []
    /// Projects tagged with @ (their folders), in the order they stand in the draft: the Router looks there, and starts a
    /// session there.
    var projects: [String] {
        var seen = Set<String>()
        return pointers.compactMap { if case .project(let folder) = $0 { folder } else { nil } }.filter { seen.insert($0).inserted }
    }

    /// Pills for `pointers` added to the draft, then `text` (an inbox thing's "Open in Router", a test): the draft as it is
    /// when blank, else after it; what it tags already isn't tagged again. The composer takes the keyboard, its caret at
    /// the end.
    func prefill(_ pointers: [RouterPointer], text: String = "") {
        var added: [RouterPointer] = []
        for p in pointers where !self.pointers.contains(p) && !added.contains(p) { added.append(p) }
        let pills = added.map { _ in MentionText.markString }.joined(separator: " ")
        let words = text.replacingOccurrences(of: MentionText.markString, with: "")
        let start = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : draft + (draft.last?.isWhitespace == true ? "" : " ")
        let tail = [pills, words].filter { !$0.isEmpty }.joined(separator: " ")
        let next = start + tail + (words.isEmpty && !pills.isEmpty ? " " : "")
        caret = nil
        self.pointers = (start.isEmpty ? [] : self.pointers) + added
        draft = next
        caretRequest = (next as NSString).length
        focusRequest &+= 1
    }
    /// While an @ is being typed: what follows it, and the suggestion picked with ↑↓. Words typed across spaces that name
    /// nothing make no suggestions, and the keys act as with none (`suggestions`).
    private(set) var mention: String?
    var mentionIndex = 0
    /// The @ word Esc dismissed: its suggestions stay away until it changes (not as words typed on after a space).
    @ObservationIgnored private var dismissedMention: String?
    /// Mirrors the composer's focus, for the keys.
    var composerFocused = false
    /// Bumped to ask the composer for the keyboard.
    var focusRequest = 0
    /// The keys that put the focus in the composer, typed into it once it has it.
    @ObservationIgnored var pendingKeys: [NSEvent] = []
    /// Per form (by its key): the options picked for each question, and the words typed in "Other".
    var picks: [String: [String: [String]]] = [:]
    var other: [String: [String: String]] = [:]
    /// Forms answered from here, until the session moves on, and what was sent.
    var sent: Set<String> = []
    var delivered: [String: [String: String]] = [:]
    /// Per plan (by its form's key): the note typed to go with "Keep planning", and what was decided from here.
    var planNotes: [String: String] = [:]
    var planDecided: [String: PendingForm.PlanDecision] = [:]
    /// The plan (its form's key) in revise mode, its feedback field showing: Esc is its Back before anything else.
    var revisingPlan: String?

    /// The plan of the card shown in full in Needs you, while it can still be decided: Esc opens its revise mode (Revise…)
    /// once nothing else is there to dismiss, and is Back while it is in it.
    func expandedPlan(_ store: Store) -> PendingForm? {
        guard let id = openNeed(store),
              let card = store.router.cards.first(where: { $0.id == id }),
              let form = store.pendingForm(for: card), form.isPlan, !locked(form) else { return nil }
        return form
    }

    /// The form's controls are shut while its answer is written and once it is.
    func locked(_ form: PendingForm) -> Bool { sending.contains(form.id) || sent.contains(form.id) }
    var formErrors: [String: String] = [:]

    /// Whether Claude Code was looked for and isn't there (see `checkClaudeCode`); nil until looked for.
    var claudeCodeMissing: Bool?
    /// Forms whose answer is being written.
    var sending: Set<String> = []
    /// The latest answer being written, for tests to wait on.
    @ObservationIgnored var lastWrite: Task<Void, Never>?
    /// The cards listed at the last reconcile, in order: where a picked card that left the list was.
    @ObservationIgnored private var listed: [String] = []

    /// The cards the keys walk, in the order the page shows them: the addressed ones as the history draws them (oldest
    /// first, the older ones it hasn't drawn yet before them); then Now top to bottom, what needs you (see
    /// `RouterPage.ranked`) and the finished turns worth a look, both open. Sessions waiting are with the working ones. Past
    /// either end of a side, the keys go on to the other, which shows.
    func sections(_ store: Store) -> (needs: [RouterCard], done: [RouterCard], earlier: [RouterCard]) {
        // Only what the page shows, as it shows it: a finished turn whose session still runs things isn't there yet; a wait
        // over that is yours to continue is at the end of Needs you. What a search leaves out isn't there either.
        let page = layout == .canvas ? zones(store) : listZones(store)
        let byID = Dictionary(store.router.cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let earlier = history(store).compactMap { entry -> RouterCard? in
            guard case .card(let card) = entry, let now = byID[card.id], !now.isOpen else { return nil }
            return now
        }
        // On the canvas, the open cards as it draws them, frame by frame (its Done lines are the history's cards), those
        // past "+n more" too: the pick moving onto one draws it.
        if layout == .canvas {
            let open = Dictionary((page.needs + page.ready + page.notes).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let all = RouterCanvasModel.make(page: page, done: canvasDone(store), muted: Set(store.agents.mutedFolders),
                                             name: store.routerProjectGroupName, color: store.routerProjectGroupColor,
                                             filter: filter, showsAll: true,
                                             projectKey: { store.routerProjectGroupKey(sessionID: $0, folder: $1) },
                                             projectSource: store.routerProjectGroupSource)
            let order = RouterCanvasModel.order(all, folded: canvas.folded)
            return (order.compactMap { open[$0] }, [], earlier)
        }
        return (page.needs + page.ready, page.notes, earlier)
    }

    /// Every card the keys walk, top to bottom.
    func cards(_ store: Store) -> [RouterCard] {
        let s = sections(store)
        return s.earlier + s.needs + s.done
    }

    /// Whether a message can go to the Router now: it is on (with the sessions extension) and Claude Code is there.
    func canSend(_ store: Store) -> Bool {
        store.routerOn && !(claudeCodeMissing == true && store.routerStatus.claudeCode == nil)
    }

    /// Looks for Claude Code once the window shows (the app updates its copy now and then): until the search has finished
    /// nothing is said, and Send waits. In a demo it is never missing. The binary known (`RouterStatus`, which every run
    /// takes its path from) is only checked to be still there, one stat; gone, or none known, it is looked for again.
    func checkClaudeCode(_ store: Store) async {
        if store.routerIsPretend {
            if claudeCodeMissing != false { claudeCodeMissing = false }
            return
        }
        guard store.routerStatus.codeRoot != nil || store.routerStatus.claudeCode != nil else {
            if claudeCodeMissing != false { claudeCodeMissing = false }
            return
        }
        let found = await store.routerStatus.current() != nil
        if claudeCodeMissing != !found { claudeCodeMissing = !found }
    }

    /// The pick follows the list: kept while it is listed; when the search or the cards change and it isn't, the nearest
    /// card listed after it (or before it) is picked, else none. Every key acts on the list as it is now.
    func reconcile(store: Store) {
        let ids = cards(store).map(\.id)
        defer { listed = ids }
        guard let id = selection, !ids.contains(id) else { return }
        let visible = Set(ids)
        var next: String?
        if let i = listed.firstIndex(of: id) {
            next = listed[(i + 1)...].first(where: visible.contains) ?? listed[..<i].reversed().first(where: visible.contains)
        }
        advance(from: id, to: next, store: store)
    }

    /// The pick moved on by itself (its card handled or gone from the list): a reply on that card follows it while nothing is
    /// written, while no reply (one you took off) stays none. Only a card you pick (a click, a banner, the keys) arms a reply.
    /// The page shows the new pick as it shows one you make (the card of Needs you opened in full), and goes there if `shows`.
    private func advance(from id: String, to next: String?, store: Store, reveal shows: Bool = false) {
        selection = next
        replyTo = followingReply(from: id, to: next)
        if let next { showPick(next, store: store, reveal: shows) }
    }

    /// The reply once the pick moved on by itself from `id` to `next`: words written to that card stay its own (its session
    /// still takes them, handled or not), rather than going to the next card's.
    private func followingReply(from id: String, to next: String?) -> String? {
        replyTo == id && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? next : replyTo
    }

    /// Picks a card, or none (the Router itself), and takes the page there: an addressed card opens in the history, the
    /// Router row goes back down to the live zones. A card clicked is where you see it: the page is not taken anywhere.
    /// The composer replies to what is picked, at once: a banner's card picked while the page isn't drawn is answered too,
    /// not the card the reply was on when the page was left.
    func select(_ id: String?, store: Store, reveal shows: Bool = true, expand: Bool = true) {
        selection = id
        replyTo = id
        guard let id else { reveal(Self.endID, highlight: false); return }
        // A card picked that the search leaves out (a banner's, the away strip's): the search ends, so it shows.
        if searching, let card = store.router.cards.first(where: { $0.id == id }), !matchesSearch(card, store: store) {
            endSearch()
        }
        // One the Unread filter leaves out, as well: the filter goes off.
        if let card = store.router.cards.first(where: { $0.id == id }), filtersOut(card) { unreadOnly = false }
        showPick(id, store: store, reveal: shows, expand: expand)
    }

    /// The picked card opened (in full in Needs you, out in the history) and, if `shows`, gone to.
    private func showPick(_ id: String, store: Store, reveal shows: Bool, expand: Bool = true) {
        if layout == .canvas { return showOnCanvas(id, store: store, reveal: shows, expand: expand) }
        if let card = store.router.cards.first(where: { $0.id == id }) {
            // A session waiting is a row under Working; one whose wait is over and is yours to continue, a row of Needs you.
            show(card.isOpen ? .now : .history)
            // The state it is in shows, if the chips hid it.
            if card.isOpen, let zone = zones(store).zone(of: card.kind == .waiting && store.routerTier(card) != .needsYou
                                                         ? Self.workingID(card.sessionID) : id), !filter.shows(zone: zone) {
                filter.reveal(CanvasGroup(zone))
            }
            if card.isOpen, card.kind == .waiting {
                if shows { reveal(store.routerTier(card) == .needsYou ? id : Self.workingID(card.sessionID)) }
                return
            }
            if card.isOpen { expandedNeed = id } else if expand { expanded.insert(id) }
        }
        if shows { reveal(id) }
    }

    /// What the page scrolls to for the bottom of the history, and the id of a working session's card.
    static let endID = "end"
    nonisolated static func workingID(_ session: String) -> String { "working#" + session }

    /// A section of Now asked for: opened and scrolled to (its id).
    var zoneRequest: ScrollRequest?
    func jump(to zone: RouterZone) {
        show(.now)
        zoneRequest = ScrollRequest(id: zone.rawValue, seq: (zoneRequest?.seq ?? 0) + 1)
    }

    /// Asks the page to scroll to an item (a card, a message, a working session's card) and, for a moment, to mark it.
    var revealRequest: ScrollRequest?
    /// The item marked for a moment after it was scrolled to.
    var highlighted: String? {
        didSet { if highlighted != oldValue { remark(oldValue); remark(highlighted); pruneMarks() } }
    }
    /// The card of Needs you shown in full (see `RouterPage.openNeed`); the others are summary rows.
    var expandedNeed: String?
    /// Addressed cards and runs opened out in the history.
    var expanded: Set<String> = []

    /// A history line (a run, a summary) opened out, or folded back.
    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
    @ObservationIgnored private var highlightTask: Task<Void, Never>?

    /// The reveal each of the page's scrolls (the history, each zone) last went to: drawn again (the page left and come back
    /// to), it doesn't go there again, while one asked for before it was drawn is gone to once it is.
    @ObservationIgnored private var revealsTaken: [String: Int] = [:]

    /// The request, if the scroll named hasn't gone to it yet (it now has).
    func takeReveal(_ request: ScrollRequest?, by scroll: String) -> ScrollRequest? {
        guard let request, revealsTaken[scroll] != request.seq else { return nil }
        revealsTaken[scroll] = request.seq
        return request
    }

    func reveal(_ id: String, highlight: Bool = true) {
        revealRequest = ScrollRequest(id: id, seq: (revealRequest?.seq ?? 0) + 1)
        guard highlight else { return }
        highlighted = id
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { self?.highlighted = nil }
        }
    }

    /// A card's Archive: it goes to the history at once (no timed undo: Reopen is there). The pick moves to the next open
    /// card if it was on this one.
    func address(_ id: String, store: Store) {
        reconcile(store: store)
        guard let card = store.router.cards.first(where: { $0.id == id }), card.isOpen else { return }
        let open = cards(store).filter(\.isOpen).map(\.id)
        let next = open.firstIndex(of: id).map { i in open.indices.contains(i + 1) ? open[i + 1] : i > 0 ? open[i - 1] : nil } ?? nil
        store.act(.archive(card: id, title: UntrustedText.clean(card.title, limit: 60), project: UntrustedText.clean(store.routerProject(card).name, limit: 40)))
        Announce.say("Archived")
        if selection == id { advance(from: id, to: next, store: store, reveal: true) }
    }

    /// Reopen on a history line: the card is back in Needs you and the page goes to it.
    func reopen(_ id: String, store: Store) {
        guard let card = store.router.cards.first(where: { $0.id == id }), store.routerCanReopen(card) else { return }
        guard store.act(.reopen(card: id, title: UntrustedText.clean(card.title, limit: 60), project: UntrustedText.clean(store.routerProject(card).name, limit: 40))) != nil else { return }
        expanded.remove(id)
        Announce.say("Open again")
        select(id, store: store)
    }

    /// ↑↓: the next card up or down the page. None picked, ↓ picks the first open card (the history is above it) and ↑ the
    /// last card.
    func move(down: Bool, store: Store) {
        reconcile(store: store)
        let shown = cards(store)
        guard !shown.isEmpty else { return }
        let ids = shown.map(\.id)
        guard let i = ids.firstIndex(of: selection ?? "") else {
            select(down ? (shown.first(where: \.isOpen) ?? shown[0]).id : ids[ids.count - 1], store: store)
            return
        }
        select(ids[min(max(i + (down ? 1 : -1), 0), ids.count - 1)], store: store)
    }

    /// Sends the draft with its reply, its @pills (written as "@name" where they stand, their projects going with it) and the
    /// target you pinned; the composer keeps the focus for the next one.
    func send(store: Store) {
        let (text, mentions) = sentDraft(store)
        guard !text.isEmpty, canSend(store) else { return }
        if let editing {
            // Resent to a fork from before the original: never to the session itself, never routed. What it tags goes with
            // it, fenced after your words, as to a session it is delivered to.
            guard store.forkSession(editing.session, point: .before(editing.original, after: editing.sentAt), message: text,
                                    edited: true, mentions: mentions) != nil else { return }
            caret = nil
            pointers = []
            draft = ""
            self.editing = nil
            show(.history)
            return
        }
        // A pill over the composer from here until it lands where it went (`RouterFlights`): the page stays where it is.
        var context = context(store)
        context.flies = true
        guard store.sendToRouter(text, context: context) else {
            sendRefused = Self.goneTarget
            Announce.say(Self.goneTarget)
            return
        }
        caret = nil
        pointers = []
        draft = ""
        replyTo = nil
        live.reset()
    }

    /// A card clicked: its session opens in Claude, and the card is picked (it stays open).
    func open(_ id: String, store: Store) {
        store.openCard(id)
        select(id, store: store)
    }

    /// The composer takes the keyboard (typing anywhere in the window lands there).
    func reply() { focusRequest &+= 1 }

    /// Reply: a "Replying to" chip for that card over the composer, which takes the keyboard. Your words are yours to write.
    func reply(to card: String, store: Store, reveal: Bool = true, expand: Bool = true) {
        select(card, store: store, reveal: reveal, expand: expand)
        replyTo = card
        focusRequest &+= 1
    }

    /// A card's header clicked: shown in full, with the composer ready to reply to it. A resolved card already shown in full
    /// folds back; the reply stays armed.
    func tap(_ id: String, store: Store) {
        let card = store.router.cards.first { $0.id == id }
        // On the canvas a card shown in full folds back the same way; the reply stays armed.
        if layout == .canvas, let card, card.isOpen, expandedNeed == id {
            expandedNeed = nil
            return
        }
        if let card, !card.isOpen, expanded.contains(id) {
            expanded.remove(id)
            return
        }
        reply(to: id, store: store, reveal: card?.isOpen != false)
    }

    // MARK: Chips and @

    /// Backspace at the start of the composer: the last recipient's chip goes, then the pinned target's, then the reply chip.
    @discardableResult
    func removeLastChip() -> Bool {
        if !live.recipients.isEmpty { live.recipients.removeLast(); return true }
        if live.pinned != nil { live.reset(); return true }
        if replyTo != nil { replyTo = nil; return true }
        if editing != nil { editing = nil; return true }
        return false
    }

    /// The @ word being typed at the end of the draft, if any ("…@look" → "look").
    static func mentionQuery(in text: String, caret: Int? = nil) -> String? { mention(in: text, caret: caret)?.query }

    /// How far an @ word may run across spaces ("@fjord comp"): past this it is prose, not a name being looked up.
    static let mentionLimit = (characters: 40, words: 4)

    /// The @ word the caret is in or just after (`caret`: UTF-16 offset, nil for the end): its range (the whole word, past
    /// the caret too) and what is typed between the @ and the caret. An @ inside a word (an email) is not one. What is
    /// typed may run across single spaces (not a new line, a pill, two spaces in a row or one right after the @), a few
    /// words at most; whether it still names something is the suggestions' to say (none: the list is closed).
    static func mention(in text: String, caret: Int?) -> (range: Range<String.Index>, query: String)? {
        if let caret, caret < 0 { return nil }
        let utf16 = text.utf16
        let offset = min(caret ?? utf16.count, utf16.count)
        guard let caretIndex = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
              let at = text[..<caretIndex].lastIndex(of: "@") else { return nil }
        if at != text.startIndex, !MentionText.isBreak(text[text.index(before: at)]) { return nil }
        let typed = text[text.index(after: at)..<caretIndex]
        var end = text[caretIndex...].firstIndex(where: MentionText.isBreak) ?? text.endIndex
        if typed.contains(where: MentionText.isBreak) {
            guard let first = typed.first, !first.isWhitespace,
                  !typed.contains(where: { $0.isNewline || $0 == MentionText.mark }),
                  !zip(typed, typed.dropFirst()).contains(where: { $0.isWhitespace && $1.isWhitespace }),
                  typed.count <= mentionLimit.characters,
                  typed.split(whereSeparator: \.isWhitespace).count <= mentionLimit.words else { return nil }
            // After a space, the word past the caret is the next one, not the @ word's.
            if typed.last?.isWhitespace == true { end = caretIndex }
        }
        return (at..<end, String(typed))
    }

    /// Where the caret is in the composer (UTF-16 offset; nil: at the end), as its text view says: the @ suggestions follow it.
    var caret: Int? {
        didSet { if caret != oldValue { mentionChanged() } }
    }
    /// Asks the composer to put its caret here (after a pick replaced the @ word).
    var caretRequest: Int?

    /// Takes the caret from the composer's text view; a selection (not a caret) shows no suggestions.
    func followCaret(_ editor: NSTextView) {
        let range = editor.selectedRange()
        let at = range.length == 0 ? range.location : -1
        let next: Int? = at == (draft as NSString).length ? nil : at
        if caret != next { caret = next }
    }

    private func mentionChanged() {
        var query = Self.mentionQuery(in: draft, caret: caret)
        // Words typed on past a space after Esc are the message going on: the list stays away.
        if let dismissed = dismissedMention, let typed = query, typed.hasPrefix(dismissed),
           typed.dropFirst(dismissed.count).contains(where: \.isWhitespace) {
            query = dismissed
        }
        if query != dismissedMention { dismissedMention = nil }
        let next = query == dismissedMention ? nil : query
        if next != mention {
            mention = next
            mentionIndex = 0
        }
    }

    /// What the @ word matches, by section (projects, sessions, notifications, categories, snippets), best first in each (a
    /// few of each for a bare @); what the draft tags already left out.
    func suggestions(_ store: Store) -> [MentionSuggestion] {
        guard let query = mention else { return [] }
        // A bare @ shows the first few of each section, in order: only those are made.
        let first = query.isEmpty ? RouterMentions.perSection.bare : nil
        return RouterMentions.suggest(RouterMentions.candidates(store, except: Set(pointers), query: query, first: first),
                                      query: query)
    }

    /// The composer's text view (`MentionField`): text a pick inserts goes in through it while it shows the draft, so ⌘Z
    /// takes it back as it does what you type.
    @ObservationIgnored weak var editor: MentionTextView?

    /// Return or Tab on a suggestion: a pill in the @ word's place, or the text it inserts (a snippet's).
    func pickMention(_ suggestion: MentionSuggestion) {
        switch suggestion.pick {
        case .pointer(let pointer): pickMention(pointer)
        case .text(let text): insertMention(text)
        }
    }

    /// The @ word replaced by `text`, as typed (no pill); the caret after it. With the composer's text view showing the
    /// draft, the edit is the view's own, one step of its undo (the @ word comes back).
    func insertMention(_ text: String) {
        guard mention != nil, let found = Self.mention(in: draft, caret: caret) else { return }
        let start = draft.utf16.distance(from: draft.utf16.startIndex, to: found.range.lowerBound.samePosition(in: draft.utf16)!)
        let words = text.replacingOccurrences(of: MentionText.markString, with: "")
        var next = draft
        next.replaceSubrange(found.range, with: words)
        let end = start + (words as NSString).length
        if let editor, !editor.hasMarkedText(), MentionText.serialize(editor.attributedString()) == (draft, pointers) {
            editor.breakUndoCoalescing()
            editor.insertPlain(words, replacing: NSRange(found.range, in: draft))
            editor.breakUndoCoalescing()
        }
        caret = end
        if draft != next { draft = next }
        caretRequest = end
        mention = nil
    }

    /// The @ word becomes the pill for `pointer`, in its place, with a space after it.
    func pickMention(_ pointer: RouterPointer) {
        guard mention != nil, let found = Self.mention(in: draft, caret: caret) else { return }
        let start = draft.utf16.distance(from: draft.utf16.startIndex, to: found.range.lowerBound.samePosition(in: draft.utf16)!)
        let before = draft[..<found.range.lowerBound].filter { $0 == MentionText.mark }.count
        let offset = draft.distance(from: draft.startIndex, to: found.range.lowerBound)
        var text = draft
        text.replaceSubrange(found.range, with: MentionText.markString)
        // One space after it, the one already there if any.
        let after = text.index(text.startIndex, offsetBy: offset + 1)
        let spaced = after < text.endIndex && text[after] == " "
        if !spaced { text.insert(" ", at: after) }
        var next = pointers
        next.insert(pointer, at: min(before, next.count))
        caret = start + 2
        pointers = next
        draft = text
        caretRequest = start + 2
        mention = nil
    }

    /// Esc on the suggestions: they go until the @ word changes.
    func dismissMention() {
        dismissedMention = mention
        mention = nil
    }

    /// ↑↓ in the suggestions.
    func moveMention(down: Bool, count: Int) {
        guard count > 0 else { return }
        mentionIndex = (mentionIndex + (down ? 1 : count - 1)) % count
    }

    // MARK: Forms

    func picked(_ form: PendingForm, _ question: PendingForm.Question) -> [String] { picks[form.id]?[question.question] ?? [] }

    func otherText(_ form: PendingForm, _ question: PendingForm.Question) -> String { other[form.id]?[question.question] ?? "" }

    /// One choice picks it (and clears "Other"); several toggle.
    func pick(_ label: String, in question: PendingForm.Question, of form: PendingForm) {
        guard !locked(form) else { return }
        var current = picked(form, question)
        if question.multiSelect {
            if let i = current.firstIndex(of: label) { current.remove(at: i) } else { current.append(label) }
        } else {
            current = current == [label] ? [] : [label]
            other[form.id, default: [:]][question.question] = ""
        }
        picks[form.id, default: [:]][question.question] = current
        formErrors[form.id] = nil
    }

    /// Typing your own answer to a one-choice question unpicks the option.
    func setOther(_ text: String, in question: PendingForm.Question, of form: PendingForm) {
        guard !locked(form) else { return }
        other[form.id, default: [:]][question.question] = text
        if !question.multiSelect, !text.isEmpty { picks[form.id, default: [:]][question.question] = [] }
        formErrors[form.id] = nil
    }

    /// Every question's answer as the form takes it, or nil while one is missing.
    func answers(_ form: PendingForm) -> [String: String]? {
        var out: [String: String] = [:]
        for q in form.questions {
            let typed = otherText(form, q).trimmingCharacters(in: .whitespacesAndNewlines)
            let labels = picked(form, q) + (typed.isEmpty ? [] : [typed])
            guard !labels.isEmpty else { return nil }
            out[q.question] = q.multiSelect ? FormBridge.joined(labels) : labels[0]
        }
        return out
    }

    /// Fjord writes the answer itself (the hook passes it on to the session). The file is written off the main thread;
    /// "Sent" or the error shows once it is.
    func sendAnswer(_ form: PendingForm, card: String, store: Store) {
        guard let answers = answers(form), !sending.contains(form.id), !sent.contains(form.id) else { return }
        sending.insert(form.id)
        lastWrite = Task { [weak self] in
            let result = await store.answerForm(form, answers, card: card)
            guard let self else { return }
            self.sending.remove(form.id)
            switch result {
            case .success:
                self.sent.insert(form.id)
                self.delivered[form.id] = answers
                self.formErrors[form.id] = nil
                Announce.say("Answer sent")
            case .failure(let error):
                self.formErrors[form.id] = error.localizedDescription
                Announce.say("Couldn't send the answer: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Plans

    func planNote(_ form: PendingForm) -> String { planNotes[form.id] ?? "" }

    func setPlanNote(_ text: String, of form: PendingForm) {
        guard !locked(form) else { return }
        planNotes[form.id] = text
        formErrors[form.id] = nil
    }

    /// Approve, or Keep planning with the note if one is typed: written off the main thread like an answer, and passed on
    /// by the hook as the app's own buttons would.
    func decidePlan(_ form: PendingForm, approve: Bool, card: String, store: Store) {
        guard form.isPlan, !sending.contains(form.id), !sent.contains(form.id) else { return }
        let decision = PendingForm.PlanDecision(approve: approve, feedback: approve ? "" : planNote(form))
        sending.insert(form.id)
        lastWrite = Task { [weak self] in
            let result = await store.answerPlan(form, decision, card: card)
            guard let self else { return }
            self.sending.remove(form.id)
            switch result {
            case .success:
                self.sent.insert(form.id)
                self.planDecided[form.id] = decision
                self.formErrors[form.id] = nil
                Announce.say(approve ? "Plan approved" : "Sent back to keep planning")
            case .failure(let error):
                self.formErrors[form.id] = error.localizedDescription
                Announce.say("Couldn't send the decision: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Notice

/// What stands in the way of using the Router, in one line, and the fix. Nothing when all is well.
struct RouterSetupNotice: View {
    let store: Store
    let model: RouterModel
    /// The view the notice is in, to know whether its window is on screen.
    @State private var place = ShownProbe.Place()

    var body: some View {
        Group {
            if !store.agents.enabled || !store.router.enabled {
                line("The Router is off.", color: Theme.amber, action: "Turn on") { store.switchRouter(true) }
            } else if model.claudeCodeMissing == true && store.routerStatus.claudeCode == nil {
                line("Claude Code wasn't found. Install or open the Claude desktop app.", color: Theme.amber,
                     action: "Look again") { Task { await model.checkClaudeCode(store) } }
            } else if let error = store.routerHookError {
                line("The form hook couldn't be installed: \(error)", color: Theme.red, action: nil) {}
            }
        }
    }

    private func line(_ text: String, color: Color, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(color).accessibilityHidden(true)
                Text(text).font(Theme.Typography.meta).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let action { ActionButton(action, action: perform) }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.md)
            Hairline()
        }
        .background(ShownProbe(place: place))
        // Said once its window is on screen, a moment after: not while the window's content is prepared out of sight, nor
        // once it has left the window again (the task is cancelled then).
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, place.isShown else { return }
            Announce.say(text, after: .zero)
        }
    }
}

/// Finds the window a SwiftUI view is in: whether it is on screen.
struct ShownProbe: NSViewRepresentable {
    @MainActor final class Place {
        weak var view: NSView?
        var isShown: Bool { view?.window?.isVisible == true }
    }

    let place: Place

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        place.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { place.view = view }
}

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

/// Router only: the sessions working now, under the Router's cards (the bar has no tiles to say so). One line each: the
/// project's colour, the title, what it is doing and for how long (on the minute); a click opens it in Claude.
struct RouterWorkingList: View {
    let store: Store
    /// Rows shown before the rest are counted.
    var limit = 5

    var body: some View {
        let rows = store.routerWorkingRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Eyebrow("Working", count: rows.count).padding(.horizontal, Theme.Space.md).padding(.top, 4).padding(.bottom, 2)
                MinuteTicking { now in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rows.prefix(limit)) { WorkingLine(row: $0, store: store, now: now) }
                    }
                }
                if rows.count > limit {
                    Text("\(rows.count - limit) more").font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, Theme.Space.md)
                }
            }
        }
    }
}

private struct WorkingLine: View {
    let row: AgentRow
    let store: Store
    let now: Date
    @State private var hover = false

    /// How long, in whole minutes: the lists are redrawn once a minute, so seconds would only ever be wrong.
    private static func minutes(_ t: TimeInterval) -> String {
        let m = max(0, Int(t)) / 60
        if m < 1 { return "<1m" }
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    var body: some View {
        // A turn that is over but left things running: how many, since the oldest of them.
        let start = Store.workingStart(row)
        let since = Self.minutes(now.timeIntervalSince(start ?? now))
        let doing = row.session.running ? row.activity?.text ?? "Working" : row.tasksText ?? "Working"
        Button { store.openAgent(row.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SessionGlyph(row: row, size: 16, dot: false)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(row.session.title).font(Theme.Typography.bodyMedium).foregroundStyle(Theme.text).lineLimit(1)
                    .layoutPriority(1)
                Text(doing).font(Theme.Typography.meta).foregroundStyle(row.session.running ? Theme.secondary : Theme.claude)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(since).font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.claude)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowHighlight(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu { SessionMenu(row: row, store: store) }
        .runningTip(row.tasks)
        .accessibilityLabel(row.session.title)
        .accessibilityValue("working, \(row.projectName), \(doing), \(since)")
        .accessibilityHint("Opens it in Claude")
    }
}
