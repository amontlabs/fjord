import AppKit
import SwiftUI

// Router v2's page model (docs/design/router-v2/DESIGN.md 2 to 5): the records, what the owner has selected, picked,
// filtered and typed, and the page as a pure function of them (`rows()`, the counts, the destination row). The owner's
// acts are its methods (the keys, the pointer and the demo's script all call the same ones); what T3 and the model do
// arrives as whole records through `apply` (RouterV2Port.swift). A source takes the acts that leave the page.

/// What takes the page's acts and feeds its events: the demo's fake T3 today, the real engine later.
@MainActor protocol RouterV2Source: AnyObject {
    /// Reads where a draft goes; answers with `readLanded`.
    func read(_ draft: String, selected: String?)
    /// `continuing`: Continue on a Stopped card (T3's "Continue where you left off.", with the run's id when it allows).
    func send(_ words: String, to thread: String, steering: Bool, continuing: Bool)
    func queue(_ words: String, on thread: String)
    /// Starts a thread with your words and the settings the row showed.
    func start(_ thread: String, words: String, project: String, launch: RouterV2Launch)
    func stop(_ thread: String)
    /// A card opened here: T3's `threadVisit`.
    func visit(_ thread: String)
    func open(_ thread: String)
}

enum RouterV2Selection: Equatable {
    case line(String), housekeeping, failure(Int)
}

enum RouterV2FilterItem: Hashable {
    case project(String?), state(RouterV2Section)
}

/// A row of the page's one list: a section's header (or the sentence in its place), a thread's line, the housekeeping line.
struct RouterV2Row: Identifiable, Equatable {
    enum Kind: Equatable {
        case header(RouterV2Section, Int)
        /// "Nothing needs you." and its kin; `clear` adds the ghost Clear filter.
        case sentence(String, clear: Bool)
        case line(RouterV2Thread)
        case housekeeping(Int)
    }
    var id: String
    var kind: Kind
}

extension RouterV2Row.Kind {
    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }
}

/// The revert toast: the act, the thread's name, what follows it.
struct RouterV2Toast: Equatable, Identifiable {
    let id: Int
    var before: String
    var name: String
    var after = ""
}

struct RouterV2SnoozeMenu: Equatable {
    var thread: String
    var index = 0
}

/// What the destination row shows (1.9).
enum RouterV2Destination: Equatable {
    /// A picked option: Return answers with it.
    case picked(thread: String, words: String)
    /// One place, sure (or your own pick): its mode words after it.
    case place(RouterV2Place, mode: String)
    /// The selection, shown at once as the prior while the read is under way.
    case prior(thread: String)
    case reading
    /// The guess first and lit, alternatives beside it; `mine`: you picked the lit one yourself.
    case unsure([RouterV2Place], lit: Int, mine: Bool, mode: String)
    case noGuess
}

/// Where the things you can point at are (in the page's space) and what a click on them does: the peek's placement and
/// the demo's drawn pointer read it. Not observed: writing a frame redraws nothing.
@MainActor final class RouterV2Targets {
    /// Every target's frame as laid out, and the ones that can't be pointed at now (inside a closed card).
    var laid: [RouterV2Hit: CGRect] = [:]
    var off: Set<RouterV2Hit> = []
    var actions: [RouterV2Hit: () -> Void] = [:]
    var viewport: CGSize = .zero

    var frames: [RouterV2Hit: CGRect] { off.isEmpty ? laid : laid.filter { !off.contains($0.key) } }
}

enum RouterV2Curve {
    case spatial, lineMove, fade, glass, follow

    func resolved(reduce: Bool) -> Animation? {
        switch self {
        case .spatial: Motion.spatial.resolved(reduce: reduce)
        case .lineMove: reduce ? Motion.spatial.resolved(reduce: true) : RouterV2.lineMove
        case .fade: Motion.fade.resolved(reduce: reduce)
        case .glass: Motion.glass.resolved(reduce: reduce)
        case .follow: Motion.follow.resolved(reduce: reduce)
        }
    }
}

@MainActor @Observable
final class RouterV2Model {
    // MARK: Records

    var threads: [RouterV2Thread] = []
    var older: [RouterV2Older] = []
    var failures: [RouterV2Failure] = []
    var connectionLost = false

    // MARK: The owner's state

    var selection: RouterV2Selection?
    /// The filters: one project or all, one state or all.
    var project: String?
    var section: RouterV2Section?
    /// ⌘F: the keyboard is on the filter bar, the ring on `ring`.
    var filterMode = false
    var ring: RouterV2FilterItem = .project(nil)
    @ObservationIgnored var typeAhead = ""

    /// Written through `setDraft`.
    var draft = ""
    /// The picked options: per thread, per question (0 for a single question), the option's number through the card.
    var picks: [String: [Int: Int]] = [:]
    /// A form's typed answers, per question.
    var typed: [String: [Int: String]] = [:]
    /// A form's current question.
    var formAt: [String: Int] = [:]
    /// The cards whose long text (plan, last lines) is open.
    var expanded: Set<String> = []

    // The destination of the draft.
    var read: RouterV2Read?
    var explicit: RouterV2Place?
    var lit = 0
    var waved = false
    var placesMenu = false
    /// The places menu's row under the keyboard (Tab opens it from the row).
    var placesIndex = 0
    /// Return came before the read: the words wait in the composer (it shows them held) and go when the read lands
    /// sure and agrees with what the row showed; with nothing shown yet, where Fjord is sure.
    var held = false
    /// What the row showed when Return came: a new thread whose draft was still being read, or the selection as the prior.
    @ObservationIgnored var heldPlace: RouterV2Place?
    @ObservationIgnored var heldPrior: String?
    /// The words marked as taken in the composer when Return came: only those are left out of the message.
    @ObservationIgnored var heldTaken: String?
    /// ⌘1–3 pressed while the places were still being read: lit when the read lands unsure.
    @ObservationIgnored var heldDigit: Int?
    var optionHeld = false
    /// The Router's model is reading the draft: Fjord's mark is in the row's arrow slot.
    var reading = false

    // A new thread's settings (RouterV2Launch.swift): T3's default and models, what you set by hand, where the keyboard
    // is in the row, the chip whose menu is open.
    var launchDefault = RouterV2Launch.t3Default
    var launchModels = RouterV2Launch.demoModels
    var launchMine = RouterV2LaunchAsk()
    var launchFocus: RouterV2LaunchField?
    var launchMenu: RouterV2LaunchField?
    /// Each setting's last change: the value it had and which way the new one rolls in.
    var launchRolls: [RouterV2LaunchField: RouterV2Roll] = [:]

    var toast: RouterV2Toast?
    var snoozeMenu: RouterV2SnoozeMenu?

    // The pointer (the real one, or the demo's drawn one).
    var hoverRow: String?
    var hoverName: String?
    var hoverControl: RouterV2Hit?
    var pressed: RouterV2Hit?

    /// The lines changing section now: drawn over their neighbours.
    var moving: Set<String> = []
    /// The card your own act advanced to: its "new" dot goes (and T3 is told) at your next key or pointer move, not as
    /// it opens, so nothing is marked seen that you didn't look at.
    @ObservationIgnored var pendingSeen: String?
    /// Asks the composer for the keyboard.
    var focusTick = 0
    /// The line to bring into view (the selection as it moves).
    var reveal: String?
    var revealTick = 0

    // MARK: Plumbing

    @ObservationIgnored weak var source: RouterV2Source?
    @ObservationIgnored let targets = RouterV2Targets()
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The demo's script holds the pointer and the keys: the real pointer's hover is not read.
    @ObservationIgnored var scripted = false
    /// A still (a shot): the sheen and the dots hold one pose, the clock stands.
    @ObservationIgnored var still = false
    var reduce = false
    /// The fake clock: `clockStart` at the moment the page was made.
    @ObservationIgnored let made = Date()
    @ObservationIgnored var clockStart: Date = RouterV2Model.today(14, 2)
    /// Tests: each change's curve, and whether it animated.
    @ObservationIgnored var trace: ((RouterV2Curve, Bool) -> Void)?
    /// Inside a `.batch`: nothing animates.
    @ObservationIgnored private var unanimated = 0

    @ObservationIgnored var undos: [(toast: Int, undo: () -> Void)] = []
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored var backups: [String: (thread: RouterV2Thread, picks: [Int: Int]?)] = [:]
    @ObservationIgnored var toastLife: Task<Void, Never>?
    /// The pointer's last move over a line-removing button, by generation: a button is armed only by a move made after
    /// the last removal (the 2026-10-12 rule, without a timer).
    @ObservationIgnored private var armGeneration = 0
    @ObservationIgnored private var armed: [RouterV2Hit: Int] = [:]
    @ObservationIgnored private var lastPointer: [RouterV2Hit: CGPoint] = [:]

    static func today(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    var now: Date { still ? clockStart : clockStart.addingTimeInterval(Date().timeIntervalSince(made)) }

    func fresh() -> Int { nextID += 1; return nextID }

    /// Nothing animates: a still, the window arriving, or a `.batch` being applied.
    private var motionOff: Bool { WindowArrival.appWindow.active || still || unanimated > 0 }

    func animate(_ curve: RouterV2Curve, _ body: () -> Void) {
        let off = motionOff
        trace?(curve, !off)
        withAnimation(off ? nil : curve.resolved(reduce: reduce)) { body() }
    }

    /// A change that takes `id` to another section: it is on top of its neighbours for the length of the move.
    func move(_ id: String, _ body: () -> Void) {
        let off = motionOff
        trace?(.lineMove, !off)
        if scripted { RouterV2Frames.note("move \(id)") }
        // In flight from the same frame as the change that moves it: one update, nothing drawn in between.
        withAnimation(off ? nil : RouterV2Curve.lineMove.resolved(reduce: reduce), completionCriteria: .logicallyComplete) {
            moving.insert(id)
            body()
        } completion: { [weak self] in
            // Landed: its ground fades, and its card opens if it landed selected.
            self?.animate(.spatial) { self?.moving.remove(id) }
        }
    }

    // MARK: Reading the records

    func thread(_ id: String) -> RouterV2Thread? { threads.first { $0.id == id } }

    func update(_ id: String, _ change: (inout RouterV2Thread) -> Void) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[i])
    }

    var selectedThread: RouterV2Thread? {
        if case .line(let id)? = selection { return thread(id) }
        return nil
    }

    /// A section's lines in their stable order (2.1), unfiltered.
    func ordered(_ section: RouterV2Section) -> [RouterV2Thread] {
        let all = threads.filter { $0.section == section }
        func oldest(_ a: RouterV2Thread, _ b: RouterV2Thread) -> Bool { a.since != b.since ? a.since < b.since : a.order < b.order }
        func newest(_ a: RouterV2Thread, _ b: RouterV2Thread) -> Bool { a.since != b.since ? a.since > b.since : a.order > b.order }
        switch section {
        case .needsYou:
            // Asks, longest waiting first; then Stopped, longest first.
            return all.filter { $0.state != .stopped }.sorted(by: oldest) + all.filter { $0.state == .stopped }.sorted(by: oldest)
        case .done:
            // Worth a look (and what just finished, still being read), newest first; then quiet, newest first.
            let top = all.filter { $0.worth == .look || $0.sentence.phase == .reassessing }
            return top.sorted(by: newest) + all.filter { !top.contains($0) }.sorted(by: newest)
        case .working:
            // Sent, newest first; then running, latest start first.
            return all.filter { $0.state == .sent }.sorted(by: newest) + all.filter { $0.state != .sent }.sorted(by: newest)
        }
    }

    private func matches(_ t: RouterV2Thread, project: String?, section: RouterV2Section?) -> Bool {
        (project == nil || t.project == project) && (section == nil || t.section == section)
    }

    /// The lines shown, top to bottom.
    var shownLines: [RouterV2Thread] {
        RouterV2Section.allCases.flatMap { s in ordered(s).filter { matches($0, project: project, section: section) } }
    }

    var shownOlder: [RouterV2Older] {
        guard section == nil || section == .done else { return [] }
        return older.filter { project == nil || $0.project == project }
    }

    /// The Needs-you header and the sentence that takes its place are one row: its content cross-fades, nothing folds.
    static let firstRow = "header-0"

    /// The page: headers, lines, the sentences that take a header's place, the housekeeping line.
    func rows() -> [RouterV2Row] {
        if threads.isEmpty {
            return [RouterV2Row(id: Self.firstRow, kind: .sentence(RouterV2.Copy.nothingAtAll, clear: false))]
        }
        var out: [RouterV2Row] = []
        let shown = shownLines
        let older = shownOlder
        if shown.isEmpty, older.isEmpty, let project {
            return [RouterV2Row(id: Self.firstRow, kind: .sentence(RouterV2.Copy.noThreads(in: project), clear: true))]
        }
        for s in RouterV2Section.allCases {
            let lines = shown.filter { $0.section == s }
            if lines.isEmpty {
                if s == .needsYou, section == nil || section == .needsYou {
                    let words = project.map(RouterV2.Copy.nothingNeedsYou(in:)) ?? RouterV2.Copy.nothingNeedsYou
                    out.append(RouterV2Row(id: Self.firstRow, kind: .sentence(words, clear: false)))
                }
                continue
            }
            out.append(RouterV2Row(id: "header-\(s.rawValue)", kind: .header(s, lines.count)))
            // Under Reduce Motion a line that changes section fades out where it was and in where it goes: its row is
            // another one there.
            out += lines.map { RouterV2Row(id: reduce ? "\($0.id)@\(s.rawValue)" : $0.id, kind: .line($0)) }
        }
        if !older.isEmpty { out.append(RouterV2Row(id: "housekeeping", kind: .housekeeping(older.count))) }
        return out
    }

    /// The projects with at least one line (or a finished thread under the housekeeping line), alphabetical: the bar's
    /// pills.
    var projects: [String] { Set(threads.compactMap(\.project) + older.compactMap(\.project)).sorted() }

    /// A pill's count: its lines under the current state choice.
    func count(project p: String?) -> Int { threads.filter { matches($0, project: p, section: section) }.count }
    /// A token's count: its lines under the current project choice.
    func count(section s: RouterV2Section) -> Int { threads.filter { matches($0, project: project, section: s) }.count }
    /// The sidebar's badge: every Needs-you line, whatever the filters.
    var needsYou: Int { threads.filter { $0.section == .needsYou }.count }

    var filtered: Bool { project != nil || section != nil }

    /// Esc would clear the filters now: nothing else is left for it to step out of (5.3).
    var escClears: Bool {
        filtered && selection == nil && draft.isEmpty && snoozeMenu == nil && !placesMenu && launchMenu == nil && !filterMode
    }

    func name(_ place: RouterV2Place) -> String {
        switch place {
        case .thread(let id): thread(id)?.name ?? ""
        case .newThread(let project): "new thread in \(project)"
        case .here: RouterV2.Copy.answersHere
        }
    }

    // MARK: The pointer

    /// The pointer came onto `hit` or left it.
    func hover(_ hit: RouterV2Hit, _ inside: Bool) {
        switch hit {
        case .row(let id): if inside { hoverRow = id } else if hoverRow == id { hoverRow = nil }
        case .name(let id): if inside { hoverName = id } else if hoverName == id { hoverName = nil }
        default:
            if inside { hoverControl = hit } else if hoverControl == hit { hoverControl = nil }
            switch hit {
            case .toast, .revert:
                // The toast's clock stops under the pointer and starts again as it leaves.
                if inside { toastLife?.cancel() } else if toast != nil { startToastLife(RouterV2.toastLife) }
            case .launch:
                // The pointer has the row: the keyboard's ring goes.
                if inside, launchFocus != nil { animate(.fade) { launchFocus = nil } }
            default: break
            }
        }
    }

    /// Your next key or pointer move after your own act opened a card: its "new" dot goes, and T3 is told.
    func ownerActed() {
        guard let id = pendingSeen else { return }
        pendingSeen = nil
        guard selection == .line(id), thread(id)?.isNew == true else { return }
        animate(.fade) { update(id) { $0.isNew = false } }
        source?.visit(id)
    }

    /// The real pointer's; not read while the script holds the pointer.
    func realHover(_ hit: RouterV2Hit, _ inside: Bool) {
        guard !scripted else { return }
        if inside { ownerActed() }
        hover(hit, inside)
    }

    func isHot(_ hit: RouterV2Hit) -> Bool {
        switch hit {
        case .row(let id): hoverRow == id
        case .name(let id): hoverName == id
        default: hoverControl == hit
        }
    }

    /// The pointer moved over a button that removes a line: it is armed.
    func pointerMoved(over hit: RouterV2Hit, at point: CGPoint) {
        if let last = lastPointer[hit], last != point { armed[hit] = armGeneration }
        lastPointer[hit] = point
    }

    func isArmed(_ hit: RouterV2Hit) -> Bool { armed[hit] == armGeneration }

    /// A line left by your act: every such button under the pointer waits for the pointer to move again.
    func disarm() {
        armGeneration += 1
        lastPointer = [:]
    }

    /// The line whose peek shows: the one whose name the pointer is on, unless it is selected.
    var peeked: String? {
        guard let id = hoverName, selection != .line(id) else { return nil }
        return id
    }

    // MARK: Selection

    /// The rows ↑↓ walk: lines top to bottom, the housekeeping line, the failure lines.
    private var walk: [RouterV2Selection] {
        shownLines.map { .line($0.id) } + (shownOlder.isEmpty ? [] : [.housekeeping]) + failures.map { .failure($0.id) }
    }

    func select(_ new: RouterV2Selection?) {
        guard new != selection else { return }
        pendingSeen = nil
        animate(.spatial) {
            selection = new
            snoozeMenu = nil
            // Another card: the row's guess is asked again.
            waved = false
            if case .line(let id)? = new {
                // You opened its card: no longer new, and T3 is told.
                update(id) { $0.isNew = false }
                source?.visit(id)
            }
        }
        if case .line(let id)? = new { show(id) }
        if case .housekeeping? = new { show("housekeeping") }
        draftContextChanged()
    }

    func show(_ row: String) {
        reveal = row
        revealTick &+= 1
    }

    /// A click on a line's row: its card, or none if it was the open one.
    func click(row id: String) { select(selection == .line(id) ? nil : .line(id)) }

    func step(down: Bool) {
        let rows = walk
        guard !rows.isEmpty else { return }
        guard let selection, let i = rows.firstIndex(of: selection) else {
            select(down ? rows.first : rows.last)
            return
        }
        select(rows[(i + (down ? 1 : rows.count - 1)) % rows.count])
    }

    /// ⌥↓ / ⌥↑: the first line of the next or previous section shown.
    func stepSection(down: Bool) {
        let lines = shownLines
        let sections = RouterV2Section.allCases.filter { s in lines.contains { $0.section == s } }
        guard !sections.isEmpty else { return }
        let current = selectedThread.flatMap { sections.firstIndex(of: $0.section) }
        let next: Int
        if let current { next = (current + (down ? 1 : sections.count - 1)) % sections.count } else { next = down ? 0 : sections.count - 1 }
        if let first = lines.first(where: { $0.section == sections[next] }) { select(.line(first.id)) }
    }

    /// Where the selection goes when its line leaves `section`: the line after it there, else the one before, else none.
    func neighbour(of id: String) -> RouterV2Selection? {
        guard let t = thread(id) else { return nil }
        let lines = shownLines.filter { $0.section == t.section }
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return nil }
        if i + 1 < lines.count { return .line(lines[i + 1].id) }
        if i > 0 { return .line(lines[i - 1].id) }
        return nil
    }

    /// The selected line is no longer shown (a filter): the first Needs-you line shown, else none.
    func settleSelection() {
        switch selection {
        case .line(let id)?:
            if !shownLines.contains(where: { $0.id == id }) {
                selection = shownLines.first { $0.section == .needsYou }.map { .line($0.id) }
            }
        case .housekeeping?: if shownOlder.isEmpty { selection = nil }
        case .failure(let id)?: if !failures.contains(where: { $0.id == id }) { selection = nil }
        case nil: break
        }
    }

    // MARK: Filters

    func toggle(project p: String?) {
        animate(.spatial) {
            project = project == p ? nil : p
            settleSelection()
        }
    }

    func toggle(section s: RouterV2Section) {
        animate(.spatial) {
            section = section == s ? nil : s
            settleSelection()
        }
    }

    func clearFilters() {
        guard filtered else { return }
        animate(.spatial) {
            project = nil
            section = nil
        }
    }

    /// The bar's items in order: All, the projects, the three tokens.
    var filterItems: [RouterV2FilterItem] {
        [.project(nil)] + projects.map { .project($0) } + RouterV2Section.allCases.map { .state($0) }
    }

    func enterFilterMode() {
        filterMode.toggle()
        typeAhead = ""
        if filterMode { ring = .project(project) }
    }

    func moveRing(forward: Bool) {
        let items = filterItems
        guard let i = items.firstIndex(of: ring) else { ring = .project(nil); return }
        ring = items[min(items.count - 1, max(0, i + (forward ? 1 : -1)))]
        typeAhead = ""
    }

    /// Type-ahead: the ring jumps to the first project that starts with what was typed since entering. False when no
    /// project does: those characters were words, not a project's name.
    func typeAhead(_ characters: String) -> Bool {
        let typed = typeAhead + characters.lowercased()
        guard let p = projects.first(where: { $0.lowercased().hasPrefix(typed) }) else { return false }
        typeAhead = typed
        ring = .project(p)
        return true
    }

    /// Space or Return on the ring: it is the choice (again: cleared).
    func chooseRing() {
        switch ring {
        case .project(let p): toggle(project: p)
        case .state(let s): toggle(section: s)
        }
    }

    // MARK: Options, forms, long text

    /// A digit on the open card: picks that option (again: unpicks). Never sends.
    func pick(_ number: Int) {
        guard let t = selectedThread, draft.isEmpty else { return }
        let options = t.numbered
        guard number >= 1, number <= options.count else { return }
        let q = options[number - 1].question
        var mine = picks[t.id] ?? [:]
        if mine[q] == number {
            mine[q] = nil
        } else {
            mine[q] = number
            typed[t.id]?[q] = nil
        }
        picks[t.id] = mine.isEmpty ? nil : mine
        if !t.form.isEmpty {
            // The current question follows the pick, then goes on to the next one still open.
            var at = q
            if mine[q] != nil, let open = t.form.indices.first(where: { $0 > q && !answered(t, $0) }) { at = open }
            if formAt[t.id] != at { animate(.spatial) { formAt[t.id] = at } }
        }
    }

    func answered(_ t: RouterV2Thread, _ question: Int) -> Bool {
        picks[t.id]?[question] != nil || typed[t.id]?[question] != nil
    }

    func answeredCount(_ t: RouterV2Thread) -> Int { t.form.indices.filter { answered(t, $0) }.count }

    /// Tab / ⇧Tab on a form: the next or previous question.
    func moveQuestion(forward: Bool) {
        guard let t = selectedThread, !t.form.isEmpty else { return }
        let at = min(t.form.count - 1, max(0, (formAt[t.id] ?? 0) + (forward ? 1 : -1)))
        animate(.spatial) { formAt[t.id] = at }
    }

    /// The words an answer sends: the picked option, or each question's answer in order.
    func answerWords(_ t: RouterV2Thread) -> String? {
        let mine = picks[t.id] ?? [:]
        let options = t.numbered
        if t.form.isEmpty { return mine[0].map { options[$0 - 1].label } }
        let parts = t.form.indices.compactMap { q in typed[t.id]?[q] ?? mine[q].map { options[$0 - 1].label } }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// → / ←: opens or closes the card's long text (a plan, the last lines).
    func expand(_ open: Bool) {
        guard let t = selectedThread, expanded.contains(t.id) != open else { return }
        animate(.spatial) { if open { expanded.insert(t.id) } else { expanded.remove(t.id) } }
        if open { show(t.id) }
    }

    // MARK: Records from the store (docs/design/router-v2/IMPLEMENTATION.md 1.2)

    /// What T3 and the Router's models change reaches the page here, and only here, as whole records: the store (the
    /// real one or the demo's) says what a thread is, the model works out the motion. A record equal to the one held
    /// changes nothing. The owner's own acts change the model's copy at once (`dispatch`, `remove`, `notForMe`): the
    /// store mirrors them as pending acts, so the record it sends next agrees and changes nothing either.
    func apply(_ change: RouterV2Change) {
        switch change {
        case .upsert(let t): upsert(t)
        case .remove(let id): removeLine(id)
        case .older(let list):
            guard list != older else { return }
            animate(.spatial) {
                older = list
                if selection == .housekeeping, shownOlder.isEmpty { selection = nil }
                settleFilters()
            }
        case .reply(let id, let text, let writing):
            // The hot path: one field of one line, nothing animated here (the card's text draws its own growth).
            guard let t = thread(id), t.lastLines != text || t.writing != writing else { return }
            update(id) { $0.lastLines = text; $0.writing = writing }
        case .words(let id, let stream, let text, _):
            words(id, stream: stream, text: text)
        case .named(let id, let name):
            guard let t = thread(id), t.name != name || t.naming else { return }
            animate(.fade) { update(id) { $0.name = name; $0.naming = false } }
        case .read(let read):
            readLanded(read)
        case .refused(let id, let reason, let offline):
            sendRefused(id, reason: reason, offline: offline)
        case .connection(let lost):
            guard lost != connectionLost else { return }
            animate(.spatial) { connectionLost = lost }
        case .launch(let defaults, let models):
            guard defaults != launchDefault || models != launchModels else { return }
            animate(.fade) {
                rolling {
                    launchDefault = defaults
                    launchModels = models
                }
            }
        case .batch(let changes):
            // One update, nothing animated: the first load, or what a held window morph kept.
            unanimated += 1
            defer { unanimated -= 1 }
            for change in changes { apply(change) }
        }
    }

    /// A thread's record. New: its line grows in. Its section or its place in the section's order changed: it moves,
    /// and if it was selected and left its section, the selection goes to its neighbour (T3 never moves the selection
    /// otherwise, and never opens a card). Otherwise its fields change in place.
    private func upsert(_ new: RouterV2Thread) {
        let id = new.id
        guard let old = thread(id) else {
            var t = new
            t.order = fresh()
            animate(.spatial) { threads.append(t) }
            return
        }
        // What is the model's own: the order among lines that entered their state at once (a fresh one only when the
        // state changes), and the count of the model's lines (it never goes back). A line whose words are still
        // streaming in keeps streaming when the record says they are all there.
        var t = new
        t.order = old.order
        t.sentence.stream = max(old.sentence.stream, new.sentence.stream)
        if old.sentence.phase == .streaming, new.sentence.phase == .settled, new.sentence.text == old.sentence.text {
            t.sentence.phase = .streaming
        }
        if t.state != old.state { t.order = fresh() }
        guard t != old else { return }
        // A send T3 took, or that ended: nothing is left to put back if it is refused.
        if t.state != .sent || t.sent?.status == .taken { backups[id] = nil }
        let leaves = t.section != old.section
        if leaves || t.orderClass != old.orderClass {
            let next: RouterV2Selection?? = leaves && selection == .line(id) ? .some(neighbour(of: id)) : nil
            move(id) {
                update(id) { $0 = t }
                if let next { selection = next }
            }
        } else if let curve = Self.curve(from: old, to: t) {
            animate(curve) { update(id) { $0 = t } }
        } else {
            update(id) { $0 = t }
        }
    }

    /// How a line that keeps its place changes: on the fade, unless the change draws its own motion.
    private static func curve(from old: RouterV2Thread, to new: RouterV2Thread) -> RouterV2Curve? {
        // A PR's state word swaps in one frame and pops on its own; the model's words stream in on their own.
        if old.prs != new.prs { return nil }
        if new.sentence.stream != old.sentence.stream, new.sentence.phase == .streaming { return nil }
        // The queued row rises into the line, or comes under it: the line's height changes.
        if (old.queued == nil) != (new.queued == nil) { return .spatial }
        return .fade
    }

    /// Settled, snoozed or archived in T3, aged out: the line leaves. No toast: it wasn't done here.
    private func removeLine(_ id: String) {
        guard thread(id) != nil else { return }
        let next = selection == .line(id) ? neighbour(of: id) : selection
        animate(.spatial) {
            threads.removeAll { $0.id == id }
            if selection == .line(id) { selection = next }
            settleFilters()
        }
        backups[id] = nil
    }

    /// A verdict's line as it lands: a new `stream` starts it (its words stream in over the sentence's place), the same
    /// one grows it, an older one is late and dropped.
    private func words(_ id: String, stream: Int, text: String) {
        guard let t = thread(id), stream >= t.sentence.stream else { return }
        if stream > t.sentence.stream {
            update(id) { $0.sentence = .init(text: text, phase: .streaming, stream: stream, stateWord: $0.sentence.stateWord) }
        } else if t.sentence.text != text {
            update(id) {
                $0.sentence.text = text
                $0.sentence.phase = .streaming
            }
        }
    }

    /// The sentence's words are all drawn (the line's view says so).
    func streamed(_ id: String, stream: Int) {
        update(id) { if $0.sentence.stream == stream, $0.sentence.phase == .streaming { $0.sentence.phase = .settled } }
    }

    /// Your send is refused, or T3 drops: the line returns to the state and place it had, a failure line enters.
    private func sendRefused(_ id: String, reason: String, offline: Bool) {
        guard let t = thread(id), let sent = t.sent else { return }
        let failure = RouterV2Failure(id: fresh(), thread: id, words: sent.words, reason: reason,
                                      continuing: backups[id]?.thread.state == .stopped, offline: offline)
        if let backup = backups[id] {
            move(id) {
                update(id) { $0 = backup.thread }
                picks[id] = backup.picks
            }
            backups[id] = nil
        }
        animate(.spatial) {
            // It takes the keyboard when it appears, if the draft is empty and Return isn't some card's already: nothing
            // is selected, or the line that failed is. (Set before the line is added: it is drawn focused from its
            // first frame.)
            if draft.isEmpty, selection == nil || selection == .line(id) { selection = .failure(failure.id) }
            failures.append(failure)
        }
    }
}

extension RouterV2Thread {
    /// The groups a section orders its lines in (`RouterV2Model.ordered`): a line that goes from one to another moves.
    /// Sent and running are one: a Sent line becomes Working where it is, on the fade.
    enum OrderClass { case ask, stopped, working, look, quiet }

    var orderClass: OrderClass {
        switch state {
        case .needsYou: .ask
        case .stopped: .stopped
        case .sent, .working: .working
        case .done: worth == .look ? .look : .quiet
        }
    }
}
