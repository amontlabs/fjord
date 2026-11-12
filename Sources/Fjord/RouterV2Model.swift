import AppKit
import SwiftUI

// Router v2's page model (docs/design/router-v2/DESIGN.md 2 to 5): the records, what the owner has selected, picked,
// filtered and typed, and the page as a pure function of them (`rows()`, the counts, the destination row). The owner's
// acts are its methods (the keys, the pointer and the demo's script all call the same ones); what T3 and the model do
// arrives through the methods under "T3 events". A source (the demo's today) takes the acts that leave the page.

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

    private(set) var draft = ""
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

    @ObservationIgnored private var undos: [(toast: Int, undo: () -> Void)] = []
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var backups: [String: (thread: RouterV2Thread, picks: [Int: Int]?)] = [:]
    @ObservationIgnored private var toastLife: Task<Void, Never>?
    /// The pointer's last move over a line-removing button, by generation: a button is armed only by a move made after
    /// the last removal (the 2026-10-12 rule, without a timer).
    @ObservationIgnored private var armGeneration = 0
    @ObservationIgnored private var armed: [RouterV2Hit: Int] = [:]
    @ObservationIgnored private var lastPointer: [RouterV2Hit: CGPoint] = [:]

    static func today(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    var now: Date { still ? clockStart : clockStart.addingTimeInterval(Date().timeIntervalSince(made)) }

    private func fresh() -> Int { nextID += 1; return nextID }

    func animate(_ curve: RouterV2Curve, _ body: () -> Void) {
        let animation = WindowArrival.appWindow.active || still ? nil : curve.resolved(reduce: reduce)
        withAnimation(animation) { body() }
    }

    /// A change that takes `id` to another section: it is on top of its neighbours for the length of the move.
    private func move(_ id: String, _ body: () -> Void) {
        let off = WindowArrival.appWindow.active || still
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

    private func update(_ id: String, _ change: (inout RouterV2Thread) -> Void) {
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
    private func disarm() {
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

    private func show(_ row: String) {
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
    private func neighbour(of id: String) -> RouterV2Selection? {
        guard let t = thread(id) else { return nil }
        let lines = shownLines.filter { $0.section == t.section }
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return nil }
        if i + 1 < lines.count { return .line(lines[i + 1].id) }
        if i > 0 { return .line(lines[i - 1].id) }
        return nil
    }

    /// The selected line is no longer shown (a filter): the first Needs-you line shown, else none.
    private func settleSelection() {
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

    // MARK: The draft and where it goes

    func setDraft(_ text: String) {
        guard text != draft else { return }
        let wasEmpty = draft.isEmpty
        let grew = text.count > draft.count
        draft = text
        // Typing again takes the words back from a held Return.
        unhold()
        if text.isEmpty {
            animate(.spatial) {
                read = nil; explicit = nil; waved = false; lit = 0; placesMenu = false
                reading = false
                launchMine = RouterV2LaunchAsk(); launchFocus = nil; launchMenu = nil; launchRolls = [:]
            }
            return
        }
        if wasEmpty { animate(.spatial) { read = nil } }
        // More words: a guess waved off is asked again.
        if grew, waved { waved = false }
        startRead()
    }

    private func unhold() {
        heldPlace = nil
        heldPrior = nil
        heldTaken = nil
        heldDigit = nil
        if held { animate(.fade) { held = false } }
    }

    /// The Router's model reads the draft: its mark shows in the row until the read lands.
    private func startRead() {
        reading = true
        source?.read(draft, selected: selectedThread?.id)
    }

    /// A character typed with no field focused goes to the composer.
    func insert(_ characters: String) {
        setDraft(draft + characters)
        focusTick &+= 1
    }

    private func draftContextChanged() {
        guard !draft.isEmpty, explicit == nil else { return }
        startRead()
    }

    /// The Router's read of the draft landed.
    func readLanded(_ new: RouterV2Read) {
        guard new.draft == draft, !draft.isEmpty else { return }
        let before = read?.launch ?? RouterV2LaunchAsk()
        animate(.fade) {
            rolling {
                read = new
                reading = false
                // A pick you made yourself is never changed by a later read.
                if let explicit, let i = new.places.firstIndex(of: explicit) { lit = i } else if explicit == nil { lit = 0 }
                // ⌘1–3 pressed while the places were being read: that place is lit, and yours.
                if let digit = heldDigit, explicit == nil, !new.sure, digit < min(3, new.places.count) {
                    explicit = new.places[digit]
                    lit = digit
                }
                heldDigit = nil
                // A setting you wrote since the last read wins over the one you set by hand before writing it.
                if new.launch.model != nil, new.launch.model != before.model { launchMine.clear(.model) }
                if new.launch.effort != nil, new.launch.effort != before.effort { launchMine.clear(.effort) }
                if new.launch.access != nil, new.launch.access != before.access { launchMine.clear(.access) }
                if new.launch.plan != nil, new.launch.plan != before.plan { launchMine.clear(.mode) }
                settleLaunch()
            }
        }
        // Return came first: the words go if the read is sure and agrees with what the row showed. With nothing shown
        // yet (the skeleton), they go where Fjord is sure; unsure, the row shows the places and Return is asked again.
        guard held else { return }
        let shown = heldPlace, prior = heldPrior, marked = heldTaken
        unhold()
        let goes: Bool
        if let shown {
            goes = explicit == shown || (new.sure && new.places.first == shown)
        } else if let prior {
            goes = new.sure && new.places.first == .thread(prior)
        } else {
            goes = new.sure && !new.places.isEmpty
        }
        guard goes else { return }
        // Words are left out of the message only when you saw them marked before Return: otherwise the settings apply
        // and the draft goes as typed.
        let seen = marked != nil && marked == taken.map { String(draft[$0]) }
        send(asTyped: !seen)
    }

    private func mode(_ place: RouterV2Place) -> String {
        guard case .thread(let id) = place, let t = thread(id) else { return "" }
        switch t.state {
        case .needsYou(.plan): return "asks for changes to the plan"
        // T3 takes typed words on a permission as a refusal with feedback.
        case .needsYou(.permission): return "denies it, with your words"
        case .needsYou(.form):
            let at = min(formAt[id] ?? 0, t.form.count - 1)
            return "answers “\(t.form[at].title)”"
        // A step Fjord found: the thread asked nothing, the words start its next turn.
        case .needsYou(.step): return "answers it"
        case .needsYou: return "answers its question"
        case .stopped, .done: return "starts a new turn"
        // An agent that can't take words mid-turn only queues them.
        case .working, .sent: return optionHeld || !t.steers ? RouterV2.Copy.queueAfter : RouterV2.Copy.steerNow
        }
    }

    /// What the destination row shows; nil when Return would send nothing.
    var destination: RouterV2Destination? {
        if draft.isEmpty {
            guard let t = selectedThread else { return nil }
            if let words = answerWords(t) { return .picked(thread: t.id, words: words) }
            // A Stopped card: Return continues it, and the row says so as it does for any send.
            if t.state == .stopped { return .picked(thread: t.id, words: RouterV2.Copy.continueWords) }
            return nil
        }
        if let explicit {
            if let read, !read.sure, read.places.contains(explicit) {
                return .unsure(read.places, lit: read.places.firstIndex(of: explicit) ?? 0, mine: true, mode: mode(explicit))
            }
            return .place(explicit, mode: mode(explicit))
        }
        if waved { return .noGuess }
        guard let read else {
            if let t = selectedThread { return .prior(thread: t.id) }
            return .reading
        }
        if read.places.isEmpty { return .noGuess }
        if read.sure { return .place(read.places[0], mode: mode(read.places[0])) }
        let at = min(lit, read.places.count - 1)
        return .unsure(read.places, lit: at, mine: false, mode: mode(read.places[at]))
    }

    /// A form's questions still without an answer.
    func openQuestions(_ t: RouterV2Thread) -> Int { t.form.indices.filter { !answered(t, $0) }.count }

    /// What the row adds after its words when Return won't send yet: T3 is away, or a form has questions left.
    var rowNote: String? {
        if connectionLost { return RouterV2.Copy.unreachableRow }
        if case .picked(let id, _)? = destination, let t = thread(id), !t.form.isEmpty {
            let open = openQuestions(t)
            if open > 0 { return RouterV2.Copy.moreToAnswer(open) }
        }
        return nil
    }

    /// Return would send now: the send button is lit.
    var canSend: Bool {
        guard let destination, !connectionLost, !held else { return false }
        switch destination {
        case .picked(let id, _): return thread(id).map { openQuestions($0) == 0 } ?? false
        case .noGuess: return false
        default: return true
        }
    }

    /// The thread the row sends to.
    var destinationThread: String? {
        switch destination {
        case .picked(let id, _), .prior(let id): return id
        case .place(.thread(let id), _): return id
        case .unsure(let places, let lit, _, _): if case .thread(let id) = places[lit] { return id } else { return nil }
        default: return nil
        }
    }

    /// The line the draft goes to, when it isn't the selected one: its name is outlined, dashed.
    var marked: String? {
        guard !draft.isEmpty, let id = destinationThread, selection != .line(id) else { return nil }
        return id
    }

    /// ⌘1–3 or a click on a place: it is lit, and yours.
    func light(_ index: Int) {
        guard case .unsure(let places, _, _, _)? = destination, index < places.count else { return }
        if scripted { RouterV2Frames.note("light \(index)") }
        animate(.fade) {
            explicit = places[index]
            lit = index
            placesMenu = false
            settleLaunch()
        }
    }

    /// ⌘1–3 with a draft: lights a place the row shows; pressed while the places are still being read, it is kept and
    /// lit when the read lands unsure. Never the Go menu's while there is a draft.
    func cmdDigit(_ index: Int) -> Bool {
        guard !draft.isEmpty else { return false }
        if case .unsure? = destination { light(index) } else if reading, explicit == nil { heldDigit = index }
        return true
    }

    /// Tab from the words when the row asks for a place (no guess, or not sure): its menu, ↑↓ and Return.
    func openPlaces() {
        animate(.fade) {
            placesMenu.toggle()
            if case .unsure(_, let lit, _, _)? = destination { placesIndex = lit } else { placesIndex = 0 }
            launchMenu = nil
        }
    }

    func movePlaces(down: Bool) {
        let n = menuPlaces.count
        guard n > 0 else { return }
        placesIndex = (min(placesIndex, n - 1) + (down ? 1 : n - 1)) % n
    }

    func choosePlaces() {
        let places = menuPlaces
        guard placesIndex < places.count else { return }
        choose(places[placesIndex])
    }

    /// A place picked from the row's menu.
    func choose(_ place: RouterV2Place) {
        animate(.fade) {
            explicit = place
            waved = false
            placesMenu = false
            settleLaunch()
        }
    }

    /// The places menu: the read's, then a new thread in each project.
    var menuPlaces: [RouterV2Place] {
        var out = read?.places ?? []
        for p in projects where !out.contains(.newThread(project: p)) { out.append(.newThread(project: p)) }
        return out
    }

    func setOption(_ down: Bool) {
        guard optionHeld != down else { return }
        animate(.fade) { optionHeld = down }
    }

    /// The composer's placeholder: what Return does (1.8).
    var placeholder: String {
        guard let t = selectedThread else { return "Message your threads" }
        switch t.state {
        case .needsYou(.question), .needsYou(.step): return "Answer \(t.name)"
        case .needsYou(.form):
            let at = min(formAt[t.id] ?? 0, t.form.count - 1)
            return "Answer “\(t.form[at].title)”"
        case .needsYou(.plan): return "Or say what to change in the plan"
        case .needsYou(.permission): return "Or tell it what to do instead"
        case .stopped: return "Tell \(t.name) how to go on"
        case .working: return "Steer \(t.name)"
        case .done, .sent: return "Message \(t.name)"
        }
    }

    // MARK: Return

    /// Return (⌥Return: `queue`): sends what the destination row shows. With no row: Send again on a focused failure
    /// line, otherwise nothing. It never settles. `asTyped`: a held Return whose marked words were never on screen.
    func send(queue: Bool = false, asTyped: Bool = false) {
        guard let destination else {
            if case .failure(let id)? = selection, !connectionLost { sendAgain(id) }
            return
        }
        // T3 is away, and the page knows: the words stay in the composer, the row says why.
        if connectionLost { return }
        switch destination {
        case .picked(let id, let words):
            guard let t = thread(id) else { return }
            if t.state == .stopped { resume(id); return }
            // A form goes once every question has an answer: until then Return moves on to the next open one.
            if !t.form.isEmpty, let open = t.form.indices.first(where: { !answered(t, $0) }) {
                animate(.spatial) { formAt[id] = open }
                return
            }
            deliver(words, to: .thread(id), queue: false, asTyped: true)
        case .place(let place, _):
            if case .thread(let id) = place, let t = thread(id), !t.form.isEmpty, selection == .line(id) {
                // Typed on a form: the words answer the current question; they go with the rest of the form.
                let at = min(formAt[id] ?? 0, t.form.count - 1)
                animate(.spatial) {
                    typed[id, default: [:]][at] = draft
                    picks[id]?[at] = nil
                    if let open = t.form.indices.first(where: { $0 != at && !answered(t, $0) }) { formAt[id] = open }
                }
                setDraft("")
                return
            }
            if waitsForRead(place) { return }
            deliver(draft, to: place, queue: queue, asTyped: asTyped)
        case .unsure(let places, let lit, _, _):
            if waitsForRead(places[lit]) { return }
            deliver(draft, to: places[lit], queue: queue, asTyped: asTyped)
        case .prior(let id):
            // Not before the read: the words wait, shown held, and go if it agrees with the thread shown.
            heldPrior = id
            animate(.fade) { held = true }
        case .reading:
            animate(.fade) { held = true }
        case .noGuess:
            break
        }
    }

    /// A new thread starts with the settings the row shows: while the draft is still being read (it may name some),
    /// Return waits for the read, as it does before a first one.
    private func waitsForRead(_ place: RouterV2Place) -> Bool {
        guard reading, case .newThread = place else { return false }
        heldPlace = place
        heldTaken = taken.map { String(draft[$0]) }
        animate(.fade) { held = true }
        return true
    }

    private func deliver(_ words: String, to place: RouterV2Place, queue: Bool, asTyped: Bool) {
        let name = read?.name
        // Without the words taken as a new thread's settings, when you saw them marked: those went into the chips.
        let message = asTyped ? draft : message
        let launch = launch
        // The composer empties first: the row leaves saying what it said at Return, not what the send made of the thread.
        setDraft("")
        switch place {
        case .thread(let id):
            guard let t = thread(id) else { return }
            // Words for a thread that exists are never taken: they go as written.
            if (queue || !t.steers), t.state == .working {
                animate(.spatial) { update(id) { $0.queued = words } }
                source?.queue(words, on: id)
            } else {
                dispatch(words, to: t, continuing: false)
            }
        case .newThread(let project):
            let id = "new-\(fresh())"
            var t = RouterV2Thread(id: id, name: name ?? RouterV2.firstWords(message), title: message, project: project, state: .sent,
                                   sentence: .init(text: ""), since: now)
            t.naming = true
            t.order = fresh()
            t.sent = .init(words: message, status: .sending)
            t.launch = launch
            animate(.spatial) { threads.append(t) }
            source?.start(id, words: message, project: project, launch: launch)
        case .here:
            break
        }
    }

    /// The thread's line becomes Sent, at the top of Working, in the same frame; the selection goes on to the next line
    /// that needs you when the words went from its card.
    private func dispatch(_ words: String, to t: RouterV2Thread, continuing: Bool) {
        let id = t.id
        backups[id] = (t, picks[id])
        let next: RouterV2Selection?? = selection == .line(id) && t.section == .needsYou ? .some(nextNeedsYou(after: id)) : nil
        move(id) {
            update(id) {
                $0.state = .sent
                $0.sent = .init(words: words, status: t.isRunning ? .steering : .sending)
                $0.since = now
                $0.order = fresh()
                $0.isNew = false
                $0.paused = false
            }
            picks[id] = nil
            typed[id] = nil
            formAt[id] = nil
            expanded.remove(id)
            if let next {
                selection = next
                snoozeMenu = nil
            }
        }
        if let next { advanced(to: next) }
        source?.send(words, to: id, steering: t.isRunning, continuing: continuing)
    }

    /// Your act moved the selection on: the card is shown; its "new" dot waits for your next key or pointer move.
    private func advanced(to next: RouterV2Selection?) {
        guard case .line(let n)? = next else { pendingSeen = nil; return }
        pendingSeen = n
        show(n)
    }

    private func nextNeedsYou(after id: String) -> RouterV2Selection? {
        let lines = shownLines.filter { $0.section == .needsYou }
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return nil }
        let rest = lines[(i + 1)...] + lines[..<i]
        return rest.first.map { .line($0.id) }
    }

    /// Continue on a Stopped card. T3 has no rerun: its own button sends these words, and the thread then shows them.
    func resume(_ id: String) {
        guard let t = thread(id), t.state == .stopped, !connectionLost else { return }
        dispatch(RouterV2.Copy.continueWords, to: t, continuing: true)
    }

    func stop(_ id: String) { source?.stop(id) }
    func open(_ id: String) { source?.open(id) }

    /// Cancel on a queued row: the words go back to the composer.
    func cancelQueued(_ id: String) {
        guard let words = thread(id)?.queued else { return }
        animate(.spatial) { update(id) { $0.queued = nil } }
        setDraft(words)
        focusTick &+= 1
    }

    // MARK: Failures

    func sendAgain(_ failure: Int) {
        guard let f = failures.first(where: { $0.id == failure }), let t = thread(f.thread) else { return }
        animate(.spatial) {
            failures.removeAll { $0.id == failure }
            if selection == .failure(failure) { selection = nil }
        }
        dispatch(f.words, to: t, continuing: f.continuing)
    }

    /// Edit: the words go back to the composer, the line goes.
    func edit(_ failure: Int) {
        guard let f = failures.first(where: { $0.id == failure }) else { return }
        animate(.spatial) {
            failures.removeAll { $0.id == failure }
            if selection == .failure(failure) { selection = nil }
        }
        if !f.continuing { setDraft(f.words) }
        focusTick &+= 1
    }

    // MARK: Acts with a Revert

    private func act(_ toast: RouterV2Toast, undo: @escaping () -> Void) {
        undos.append((toast.id, undo))
        animate(.fade) { self.toast = toast }
        startToastLife(RouterV2.toastLife)
        undoManager?.registerUndo(withTarget: self) { model in model.revert(toast.id) }
        undoManager?.setActionName(toast.before)
        disarm()
    }

    private func startToastLife(_ seconds: Double) {
        toastLife?.cancel()
        guard !still else { return }
        // The clock stops while the pointer is on it (`hover`), and starts again as it leaves.
        guard hoverControl != .toast, hoverControl != .revert else { return }
        toastLife = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.animate(.fade) { self.toast = nil }
        }
    }

    /// The toast leaves now (the demo's last one, on an empty page).
    func dismissToast() {
        toastLife?.cancel()
        animate(.fade) { toast = nil }
    }

    /// ⌘Z or Revert: the newest act, undone.
    func undo() {
        guard let last = undos.last else { return }
        revert(last.toast)
    }

    var canUndo: Bool { !undos.isEmpty }

    func revert(_ id: Int) {
        guard let i = undos.firstIndex(where: { $0.toast == id }) else { return }
        let entry = undos.remove(at: i)
        entry.undo()
        if toast?.id == id {
            toastLife?.cancel()
            animate(.fade) { toast = nil }
        }
    }

    /// Settle: the line leaves at once.
    func settle(_ id: String) {
        guard let t = thread(id) else { return }
        remove(t, toast: RouterV2Toast(id: fresh(), before: "Settled", name: t.name))
    }

    func snooze(_ id: String, choice: Int) {
        guard let t = thread(id) else { return }
        remove(t, toast: RouterV2Toast(id: fresh(), before: "Snoozed", name: t.name, after: RouterV2.Copy.snoozedUntil[choice]))
    }

    private func remove(_ t: RouterV2Thread, toast: RouterV2Toast) {
        let next = selection == .line(t.id) ? neighbour(of: t.id) : selection
        let kept = (picks[t.id], typed[t.id])
        animate(.spatial) {
            threads.removeAll { $0.id == t.id }
            selection = next
            snoozeMenu = nil
            settleFilters()
        }
        advanced(to: next)
        act(toast) { [weak self] in
            guard let self else { return }
            // It grows back where it was, selected.
            self.animate(.spatial) {
                self.threads.append(t)
                self.picks[t.id] = kept.0
                self.typed[t.id] = kept.1
                self.selection = .line(t.id)
            }
            self.show(t.id)
        }
    }

    /// The filtered project has no line left: its pill is gone, so is the filter.
    private func settleFilters() {
        if let project, !projects.contains(project), !older.contains(where: { $0.project == project }) { self.project = nil }
    }

    /// Settle all on the housekeeping line.
    func settleAll() {
        let gone = shownOlder
        guard !gone.isEmpty else { return }
        let all = older
        animate(.spatial) {
            older.removeAll { o in gone.contains { $0.id == o.id } }
            if selection == .housekeeping { selection = nil }
            if hoverControl == .housekeepingWords || hoverControl == .settleAll { hoverControl = nil }
        }
        let name = gone.count == 1 ? gone[0].name : "\(gone.count) older threads"
        act(RouterV2Toast(id: fresh(), before: "Settled", name: name)) { [weak self] in
            guard let self else { return }
            self.animate(.spatial) { self.older = all }
        }
    }

    /// Doesn't need me: a wrong verdict goes to Done, its line the verdict's result and no longer the ask.
    func notForMe(_ id: String) {
        guard let t = thread(id), t.state == .needsYou(.step) else { return }
        let next = selection == .line(id) ? neighbour(of: id) : selection
        move(id) {
            update(id) {
                $0.state = .done
                $0.worth = .look
                $0.since = now
                $0.order = fresh()
                if let result = $0.result { $0.sentence = .init(text: result, stream: $0.sentence.stream) }
                $0.question = nil
                $0.options = []
            }
            picks[id] = nil
            selection = next
        }
        advanced(to: next)
        act(RouterV2Toast(id: fresh(), before: "Moved", name: t.name, after: "to Done")) { [weak self] in
            guard let self else { return }
            self.move(id) {
                self.update(id) { $0 = t }
                self.selection = .line(id)
            }
        }
    }

    /// ⌘⌫: settles the selected row (the housekeeping line: all; a failure line: Edit).
    func settleSelected() {
        switch selection {
        case .line(let id)?: settle(id)
        case .housekeeping?: settleAll()
        case .failure(let id)?: edit(id)
        case nil: break
        }
    }

    func openSnooze() {
        guard let t = selectedThread, t.state != .working, t.state != .sent else { return }
        animate(.fade) { snoozeMenu = snoozeMenu == nil ? RouterV2SnoozeMenu(thread: t.id) : nil }
    }

    func moveSnooze(down: Bool) {
        guard var menu = snoozeMenu else { return }
        let n = RouterV2.Copy.snoozeChoices.count
        menu.index = (menu.index + (down ? 1 : n - 1)) % n
        snoozeMenu = menu
    }

    func chooseSnooze(_ index: Int? = nil) {
        guard let menu = snoozeMenu else { return }
        snooze(menu.thread, choice: index ?? menu.index)
    }

    // MARK: Esc

    /// Esc, in order (5.3): the snooze, places or settings menu, filter mode, a held Return, a new thread's settings
    /// (back to the words), the row's guess or your place, the picked options, the selection, the filters. It never
    /// clears a draft. False when there was nothing to step out of.
    func escape() -> Bool {
        if snoozeMenu != nil { animate(.fade) { snoozeMenu = nil }; return true }
        if placesMenu { animate(.fade) { placesMenu = false }; return true }
        if launchMenu != nil { animate(.fade) { launchMenu = nil }; return true }
        if filterMode { filterMode = false; return true }
        // A held Return: the words are yours again.
        if held { unhold(); return true }
        // The keyboard in a new thread's settings: back to the words.
        if launchFocus != nil { leaveLaunch(); return true }
        if !draft.isEmpty {
            if explicit != nil { animate(.fade) { explicit = nil; settleLaunch() }; return true }
            if !waved, read?.places.isEmpty == false || (read == nil && selectedThread != nil) {
                animate(.fade) { waved = true; settleLaunch() }
                return true
            }
        }
        if let t = selectedThread, picks[t.id] != nil || typed[t.id] != nil {
            picks[t.id] = nil
            typed[t.id] = nil
            return true
        }
        if selection != nil { select(nil); return true }
        if filtered { clearFilters(); return true }
        return false
    }

    // MARK: T3 events (section 3). Code sets state, section, mark, counts and a plain line in the same frame.

    /// A turn ends with no request: Working → Done at once, "finished", the sentence sheening until the verdict.
    func turnEnded(_ id: String, lastLines: String? = nil, prs: [RouterV2Thread.PR] = [], diff: RouterV2Thread.Diff? = nil) {
        guard let t = thread(id) else { return }
        // Queued words go as the turn ends: the row rises into the line, which becomes Sent.
        if let words = t.queued {
            animate(.spatial) {
                update(id) {
                    $0.queued = nil
                    $0.state = .sent
                    $0.sent = .init(words: words, status: .sending)
                    $0.since = now
                    $0.order = fresh()
                }
            }
            source?.send(words, to: id, steering: false, continuing: false)
            return
        }
        let next = selection == .line(id) ? neighbour(of: id) : selection
        move(id) {
            update(id) {
                $0.state = .done
                $0.worth = .quiet
                $0.sentence = .init(text: RouterV2.Copy.finished, phase: .reassessing, stream: $0.sentence.stream)
                $0.since = now
                $0.order = fresh()
                $0.isNew = true
                $0.sent = nil
                $0.writing = false
                $0.steps = []
                $0.launch = nil
                $0.result = nil
                if let lastLines { $0.lastLines = lastLines }
                if !prs.isEmpty { $0.prs = prs }
                if let diff { $0.diff = diff }
            }
            // T3 never moves the selection: it only follows a line that left its section.
            if selection == .line(id) { selection = next }
        }
    }

    /// The verdict's state, which comes first: Done worth a look or quiet, or it left you a step (the line moves to Needs
    /// you at once, still sheening).
    func verdict(_ id: String, worth: RouterV2Thread.Worth = .quiet, step ask: String? = nil, options: [String] = [],
                 result: String? = nil) {
        guard let t = thread(id), t.state == .done else { return }
        if let ask {
            let next = selection == .line(id) ? neighbour(of: id) : selection
            move(id) {
                update(id) {
                    $0.state = .needsYou(.step)
                    $0.question = ask
                    $0.options = options
                    $0.result = result
                    $0.since = now
                    $0.order = fresh()
                }
                if selection == .line(id) { selection = next }
            }
        } else if t.worth != worth {
            // Quiet under the lines worth a look, or up among them: on the fade, with the ground.
            move(id) { update(id) { $0.worth = worth } }
        }
    }

    /// The model's line lands: its words stream in over the sentence's place.
    func line(_ id: String, _ text: String, stateWord: Bool = true) {
        guard let t = thread(id) else { return }
        if t.sentence.text == text, t.sentence.stateWord == stateWord, !t.sentence.mono {
            // The same words (a PR merged, the result didn't change): nothing streams, the sheen just goes.
            animate(.fade) { update(id) { $0.sentence.phase = .settled } }
            return
        }
        update(id) { $0.sentence = .init(text: text, phase: .streaming, stream: $0.sentence.stream + 1, stateWord: stateWord) }
    }

    /// The sentence's words are all in.
    func streamed(_ id: String, stream: Int) {
        update(id) { if $0.sentence.stream == stream, $0.sentence.phase == .streaming { $0.sentence.phase = .settled } }
    }

    /// The model names a thread: once.
    func named(_ id: String, _ name: String) {
        animate(.fade) { update(id) { $0.name = name; $0.naming = false } }
    }

    /// A new request (question, form, plan, permission): Needs you at once with the kind's mark and T3's words verbatim;
    /// the card is complete at once.
    func asked(_ id: String, _ ask: RouterV2Thread.Ask, line: String, mono: Bool = false, card: (inout RouterV2Thread) -> Void) {
        let next = selection == .line(id) ? neighbour(of: id) : selection
        move(id) {
            update(id) {
                $0.state = .needsYou(ask)
                $0.sentence = .init(text: line, mono: mono, phase: .reassessing, stream: $0.sentence.stream)
                $0.since = now
                $0.order = fresh()
                $0.isNew = true
                $0.sent = nil
                $0.writing = false
                card(&$0)
            }
            if selection == .line(id) { selection = next }
        }
    }

    /// T3 has your words: the status goes (there is no "delivered").
    func taken(_ id: String) {
        animate(.fade) { update(id) { if $0.state == .sent { $0.sent?.status = .taken } } }
        backups[id] = nil
    }

    /// A run starts (your send, a rerun, T3 on its own): Working, under the Sent lines.
    func runStarted(_ id: String, step: String = RouterV2.Copy.starting, mono: Bool = false, steps: [RouterV2Thread.Step] = []) {
        guard let t = thread(id) else { return }
        let change = {
            self.update(id) {
                $0.state = .working
                $0.sentence = .init(text: step, mono: mono, stream: $0.sentence.stream)
                $0.since = self.now
                $0.order = self.fresh()
                $0.sent = nil
                $0.paused = false
                $0.stop = nil
                $0.steps = steps
                // A new turn: the agent has said nothing in it yet.
                $0.lastLines = ""
                $0.diff = nil
                // What it asked is answered.
                $0.question = nil; $0.options = []; $0.form = []; $0.plan = []; $0.permission = nil
                $0.result = nil
                $0.isNew = false
            }
        }
        if t.section == .working { animate(.fade) { change() } } else {
            let next = selection == .line(id) ? neighbour(of: id) : selection
            move(id) {
                change()
                if selection == .line(id) { selection = next }
            }
        }
    }

    /// The running step changes: the sentence cross-fades.
    func step(_ id: String, _ text: String, mono: Bool = false, steps: [RouterV2Thread.Step]? = nil) {
        animate(.fade) {
            update(id) {
                $0.sentence = .init(text: text, mono: mono, stream: $0.sentence.stream)
                if let steps { $0.steps = steps }
            }
        }
    }

    /// A run you stopped yourself (T3's `latestRunStopRequested`): Done, not Needs you. Code only: nothing sheens.
    func interrupted(_ id: String) {
        guard thread(id)?.isRunning == true else { return }
        let next = selection == .line(id) ? neighbour(of: id) : selection
        move(id) {
            update(id) {
                $0.state = .done
                $0.worth = .quiet
                $0.sentence = .init(text: RouterV2.Copy.stoppedByYou, stream: $0.sentence.stream)
                $0.since = now
                $0.order = fresh()
                $0.sent = nil
                $0.writing = false
                $0.queued = nil
                $0.steps = []
                $0.launch = nil
            }
            if selection == .line(id) { selection = next }
        }
    }

    /// A run T3 failed (a provider or transport error, a usage limit with no resume): Stopped, at the end of Needs you.
    /// Code only: nothing sheens.
    func failed(_ id: String, error: String, lastStep: String, line: String? = nil) {
        let next = selection == .line(id) ? neighbour(of: id) : selection
        let first = error.split(separator: "\n").first.map(String.init) ?? error
        move(id) {
            update(id) {
                $0.state = .stopped
                $0.sentence = .init(text: line ?? "failed: " + first, stream: $0.sentence.stream)
                $0.stop = .init(error: error, lastStep: lastStep)
                $0.since = now
                $0.order = fresh()
                $0.sent = nil
                $0.writing = false
                $0.queued = nil
            }
            if selection == .line(id) { selection = next }
        }
    }

    /// Paused at the usage limit, resuming on its own: stays Working, the dots stop.
    func paused(_ id: String, line: String) {
        animate(.fade) { update(id) { $0.paused = true; $0.sentence = .init(text: line, stream: $0.sentence.stream) } }
    }

    /// A pull request opens, merges or closes: the state word flips (the view pops it) and the sentence sheens, since the
    /// PR's state is in the fingerprint.
    func pr(_ id: String, _ number: Int, _ state: RouterV2Thread.PR.State) {
        update(id) {
            if let i = $0.prs.firstIndex(where: { $0.number == number }) { $0.prs[i].state = state } else {
                $0.prs.append(.init(number: number, state: state))
            }
            if $0.state == .done || $0.state == .needsYou(.step) { $0.sentence.phase = .reassessing }
        }
    }

    /// Settled, snoozed or archived in T3: the line leaves. No toast: it wasn't done here.
    func left(_ id: String) {
        let next = selection == .line(id) ? neighbour(of: id) : selection
        animate(.spatial) {
            threads.removeAll { $0.id == id }
            if selection == .line(id) { selection = next }
            settleFilters()
        }
    }

    /// A new thread (or one unsettled, reopened, its snooze over): its line grows in, in its state's section.
    func appeared(_ t: RouterV2Thread) {
        var t = t
        t.order = fresh()
        animate(.spatial) { threads.append(t) }
    }

    /// Your send is refused, or T3 drops: the line returns to the state and place it had, a failure line enters.
    func refused(_ id: String, reason: String, offline: Bool = false) {
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

    func connection(lost: Bool) {
        animate(.spatial) { connectionLost = lost }
    }

    /// The agent's reply as it is written.
    func reply(_ id: String, _ text: String, writing: Bool) {
        update(id) { $0.lastLines = text; $0.writing = writing }
    }

    /// The thread's messages loaded.
    func loaded(_ id: String) {
        animate(.fade) { update(id) { $0.loading = false } }
    }
}
