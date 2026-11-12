import AppKit
import SwiftUI

// Router v2's page model (docs/design/router-v2/DESIGN.md 2 to 5): the records, what the owner has selected, picked,
// filtered and typed, and the page as a pure function of them (`rows()`, the counts, the destination row). The owner's
// acts are its methods (the keys, the pointer and the demo's script all call the same ones); what T3 and the model do
// arrives as whole records through `apply` (RouterV2Port.swift). A source takes the acts that leave the page.

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
    /// A Revert to offer: false for a toast that only says why an act didn't go.
    var revertible = true
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

    /// Views don't read the records: each line reads its box (`box(_:)`), the list its layout, the bar its tally. Every
    /// change is mirrored there in the same turn (`threadsChanged`).
    var threads: [RouterV2Thread] = [] { didSet { threadsChanged() } }
    var older: [RouterV2Older] = [] { didSet { if older != oldValue { relayout() } } }
    var failures: [RouterV2Failure] = []
    var connectionLost = false

    // MARK: The owner's state

    var selection: RouterV2Selection? { didSet { if selection != oldValue { selectionChanged(from: oldValue) } } }
    /// The filters: one project or all, one state or all.
    var project: String? { didSet { if project != oldValue { relayout() } } }
    var section: RouterV2Section? { didSet { if section != oldValue { relayout() } } }
    /// ⌘F: the keyboard is on the filter bar, the ring on `ring`.
    var filterMode = false
    var ring: RouterV2FilterItem = .project(nil)
    @ObservationIgnored var typeAhead = ""

    /// Written through `setDraft`.
    var draft = "" { didSet { if draft.isEmpty != draftEmpty { draftEmpty = draft.isEmpty } } }
    /// No draft: what reads only that doesn't redraw on each key.
    private(set) var draftEmpty = true
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
    /// The composer's @ pills: they go with each read of the draft.
    @ObservationIgnored var mentions: [RouterMention] = []

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
    var hoverRow: String? { didSet { if hoverRow != oldValue { hotChanged(oldValue.map(RouterV2Hit.row), hoverRow.map(RouterV2Hit.row)) } } }
    var hoverName: String? { didSet { if hoverName != oldValue { hotChanged(oldValue.map(RouterV2Hit.name), hoverName.map(RouterV2Hit.name)) } } }
    var hoverControl: RouterV2Hit? { didSet { if hoverControl != oldValue { hotChanged(oldValue, hoverControl) } } }
    var pressed: RouterV2Hit? { didSet { if pressed != oldValue { pressedChanged(from: oldValue) } } }

    /// The lines changing section now: drawn over their neighbours.
    var moving: Set<String> = [] { didSet { if moving != oldValue { movingChanged(from: oldValue) } } }
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
    var reduce = false { didSet { if reduce != oldValue { relayout() } } }
    /// The fake clock: `clockStart` at the moment the page was made.
    @ObservationIgnored let made = Date()
    @ObservationIgnored var clockStart: Date = RouterV2Model.today(14, 2)
    /// Tests: each change's curve, and whether it animated.
    @ObservationIgnored var trace: ((RouterV2Curve, Bool) -> Void)?
    /// Inside a `.batch`: nothing animates.
    @ObservationIgnored private var unanimated = 0

    /// The acts with a Revert, newest last: the toast they showed, the threads they hid, how to take them back.
    @ObservationIgnored var undos: [(toast: Int, threads: [String], undo: () -> Void)] = []
    @ObservationIgnored private var nextID = 0
    /// What a send in flight changed, to put back if it is refused, and what it was.
    @ObservationIgnored var backups: [String: (thread: RouterV2Thread, picks: [Int: Int]?, kind: RouterV2Outgoing.Kind)] = [:]
    @ObservationIgnored var toastLife: Task<Void, Never>?
    /// The pointer's last move over a line-removing button, by generation: a button is armed only by a move made after
    /// the last removal (the 2026-10-12 rule, without a timer).
    @ObservationIgnored private var armGeneration = 0
    @ObservationIgnored private var armed: [RouterV2Hit: Int] = [:]
    @ObservationIgnored private var lastPointer: [RouterV2Hit: CGPoint] = [:]

    // MARK: What the views read (RouterV2Render.swift)

    /// The list's rows, rewritten only when the order or a header's count changes.
    private(set) var layout: [RouterV2Slot] = [RouterV2Slot(id: RouterV2Model.firstRow, kind: .sentence(RouterV2.Copy.nothingAtAll, clear: false))]
    /// The counts and the projects, stored with the layout.
    private(set) var tally = RouterV2Tally()
    /// There is a thread: the filter bar shows.
    private(set) var hasThreads = false
    /// The ages' one clock.
    @ObservationIgnored private(set) lazy var clock = RouterV2Clock(from: made)
    @ObservationIgnored private var boxes: [String: RouterV2LineBox] = [:]
    @ObservationIgnored private var hits: [RouterV2Hit: RouterV2HitBox] = [:]
    /// What is hot and pressed, for a hit's box made after the fact.
    @ObservationIgnored private var hot: Set<RouterV2Hit> = []
    /// The line marked as the draft's destination, as last set on the boxes.
    @ObservationIgnored private var markedShown: String?
    /// Streamed changes kept for the turn's end, by thread, in arrival order (`post`).
    @ObservationIgnored private var kept: [(id: String, change: RouterV2Change)] = []
    /// Threads whose words of the current stream are still coming (`.words(done: false)`).
    @ObservationIgnored private var growing: Set<String> = []
    @ObservationIgnored private lazy var turn = RouterV2Turn { [weak self] in self?.endTurn() }

    init() {
        trackMarked()
    }

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

    func thread(_ id: String) -> RouterV2Thread? {
        access(keyPath: \.threads)
        return boxes[id]?.record
    }

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
        layout.compactMap { if case .line(let id) = $0.kind { boxes[id]?.record } else { nil } }
    }

    var shownOlder: [RouterV2Older] {
        guard section == nil || section == .done else { return [] }
        return older.filter { project == nil || $0.project == project }
    }

    /// The Needs-you header and the sentence that takes its place are one row: its content cross-fades, nothing folds.
    static let firstRow = "header-0"

    /// The page: headers, lines, the sentences that take a header's place, the housekeeping line.
    func rows() -> [RouterV2Row] {
        layout.compactMap { slot in
            switch slot.kind {
            case .header(let s, let n): RouterV2Row(id: slot.id, kind: .header(s, n))
            case .sentence(let words, let clear): RouterV2Row(id: slot.id, kind: .sentence(words, clear: clear))
            case .line(let id): boxes[id].map { RouterV2Row(id: slot.id, kind: .line($0.record)) }
            case .housekeeping(let n): RouterV2Row(id: slot.id, kind: .housekeeping(n))
            }
        }
    }

    /// The page's rows from the records: sorted here, once per change of order, never in a body.
    private func slots() -> [RouterV2Slot] {
        if threads.isEmpty {
            return [RouterV2Slot(id: Self.firstRow, kind: .sentence(RouterV2.Copy.nothingAtAll, clear: false))]
        }
        var out: [RouterV2Slot] = []
        let older = shownOlder
        var shown: [RouterV2Section: [RouterV2Thread]] = [:]
        for s in RouterV2Section.allCases { shown[s] = ordered(s).filter { matches($0, project: project, section: section) } }
        if shown.values.allSatisfy(\.isEmpty), older.isEmpty, let project {
            return [RouterV2Slot(id: Self.firstRow, kind: .sentence(RouterV2.Copy.noThreads(in: project), clear: true))]
        }
        for s in RouterV2Section.allCases {
            let lines = shown[s] ?? []
            if lines.isEmpty {
                if s == .needsYou, section == nil || section == .needsYou {
                    let words = project.map(RouterV2.Copy.nothingNeedsYou(in:)) ?? RouterV2.Copy.nothingNeedsYou
                    out.append(RouterV2Slot(id: Self.firstRow, kind: .sentence(words, clear: false)))
                }
                continue
            }
            out.append(RouterV2Slot(id: "header-\(s.rawValue)", kind: .header(s, lines.count)))
            // Under Reduce Motion a line that changes section fades out where it was and in where it goes: its row is
            // another one there.
            out += lines.map { RouterV2Slot(id: reduce ? "\($0.id)@\(s.rawValue)" : $0.id, kind: .line($0.id)) }
        }
        if !older.isEmpty { out.append(RouterV2Slot(id: "housekeeping", kind: .housekeeping(older.count))) }
        return out
    }

    /// The projects with at least one line (or a finished thread under the housekeeping line), alphabetical: the bar's
    /// pills.
    var projects: [String] { tally.projects }

    /// A pill's count: its lines under the current state choice.
    func count(project p: String?) -> Int { tally.count(project: p, section: section) }
    /// A token's count: its lines under the current project choice.
    func count(section s: RouterV2Section) -> Int { tally.count(project: project, section: s) }
    /// The sidebar's badge: every Needs-you line, whatever the filters.
    var needsYou: Int { tally.all[.needsYou] ?? 0 }

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
        let interval = RouterSignposts.begin("Select")
        defer { RouterSignposts.end(interval, afterCommit: true) }
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
        case .words(let id, let stream, let text, let done):
            words(id, stream: stream, text: text, done: done)
        case .named(let id, let name):
            guard let t = thread(id), t.name != name || t.naming else { return }
            animate(.fade) { update(id) { $0.name = name; $0.naming = false } }
        case .read(let read):
            readLanded(read)
        case .refused(let id, let reason, let offline):
            sendRefused(id, reason: reason, offline: offline)
        case .actRefused(let id, let reason):
            actRefused(id, reason: reason)
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
    /// one grows it (the words that arrived since fade in where they are), an older one is late and dropped. `done`: the
    /// stream's words are all there, and the line settles once they are drawn; until then it keeps streaming, however
    /// long the words take to come.
    private func words(_ id: String, stream: Int, text: String, done: Bool) {
        guard let t = thread(id), stream >= t.sentence.stream else { return }
        let wasGrowing = growing.contains(id)
        if done { growing.remove(id) } else { growing.insert(id) }
        if stream > t.sentence.stream {
            if !done { growing.insert(id) }
            boxes[id]?.complete = done
            update(id) { $0.sentence = .init(text: text, phase: .streaming, stream: stream, stateWord: $0.sentence.stateWord) }
        } else if t.sentence.text != text {
            boxes[id]?.complete = done
            update(id) {
                $0.sentence.text = text
                $0.sentence.phase = .streaming
            }
        } else if wasGrowing, done {
            // The same words, now all there: drawn, the line settles.
            boxes[id]?.complete = true
        }
    }

    /// The sentence's words are all drawn (the line's view says so), and none are still coming.
    func streamed(_ id: String, stream: Int) {
        guard !growing.contains(id) else { return }
        update(id) { if $0.sentence.stream == stream, $0.sentence.phase == .streaming { $0.sentence.phase = .settled } }
    }

    /// Your send is refused, or T3 drops: the line returns to the state and place it had, a failure line enters.
    private func sendRefused(_ id: String, reason: String, offline: Bool) {
        guard let t = thread(id), let sent = t.sent else { return }
        let failure = RouterV2Failure(id: fresh(), thread: id, words: sent.words, reason: reason,
                                      kind: backups[id]?.kind ?? .words, offline: offline)
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

    // MARK: Streaming: one flush a turn

    /// The hot path's entry (IMPLEMENTATION.md 2.2, streaming): a verdict's words and a reply, which come faster than
    /// frames, are kept by thread (the last one of each wins: they are whole) and applied once, at the end of the main
    /// loop's turn; anything else is applied at once, after what was kept, so the order of changes holds.
    func post(_ change: RouterV2Change) {
        switch change {
        case .words(let id, _, _, _):
            keep(id, change) { if case .words = $0 { true } else { false } }
        case .reply(let id, _, _):
            keep(id, change) { if case .reply = $0 { true } else { false } }
        default:
            flush()
            apply(change)
        }
    }

    private func keep(_ id: String, _ change: RouterV2Change, replacing same: (RouterV2Change) -> Bool) {
        if let i = kept.firstIndex(where: { $0.id == id && same($0.change) }) {
            // Newer words of an older stream never replace a newer stream's: the late ones are dropped by `apply`.
            if case .words(_, let stream, _, _) = change, case .words(_, let held, _, _) = kept[i].change, stream < held { return }
            kept[i].change = change
        } else {
            kept.append((id, change))
        }
        turn.schedule()
    }

    /// Applies what was kept for the turn's end.
    func flush() {
        guard !kept.isEmpty else { return }
        let changes = kept
        kept = []
        RouterV2Bodies.count("flush")
        let interval = RouterSignposts.begin("Flush")
        for (_, change) in changes { apply(change) }
        RouterSignposts.end(interval, afterCommit: true)
    }

    /// The turn's end: what was streamed is applied, and the line the draft goes to is marked.
    func endTurn() {
        flush()
        syncMarked()
    }

    /// Runs the turn's end now (tests; a still).
    func finishTurn() { turn.runNow() }

    // MARK: Keeping the boxes in step

    /// What places a line on the page: a change of any of these may move it, or change a count.
    struct OrderKey: Equatable {
        var section: RouterV2Section
        var orderClass: RouterV2Thread.OrderClass
        var since: Date
        var order: Int
        var reassessing: Bool
        var project: String?

        init(_ t: RouterV2Thread) {
            section = t.section
            orderClass = t.orderClass
            since = t.since
            order = t.order
            reassessing = t.sentence.phase == .reassessing
            project = t.project
        }
    }

    /// A line's box. Its view is only made for a line the model holds.
    func box(_ id: String) -> RouterV2LineBox {
        if let box = boxes[id] { return box }
        // A row whose thread just left, drawn once more on its way out: a box of its own, not kept.
        return RouterV2LineBox(RouterV2Thread(id: id, name: "", title: "", state: .done, sentence: .init(text: ""), since: made))
    }

    /// The flags of a thing that can be pointed at.
    func flags(_ hit: RouterV2Hit) -> RouterV2HitBox {
        if let box = hits[hit] { return box }
        let box = RouterV2HitBox(hot: hot.contains(hit), pressed: pressed == hit, selected: hit == .housekeeping && selection == .housekeeping)
        hits[hit] = box
        return box
    }

    private func threadsChanged() {
        var moved = boxes.count != threads.count
        for t in threads {
            if let box = boxes[t.id] {
                if box.take(t) { moved = true }
            } else {
                let box = RouterV2LineBox(t)
                box.selected = selection == .line(t.id)
                box.built = box.selected
                box.moving = moving.contains(t.id)
                box.marked = markedShown == t.id
                boxes[t.id] = box
                moved = true
            }
        }
        if boxes.count != threads.count {
            let ids = Set(threads.map(\.id))
            boxes = boxes.filter { ids.contains($0.key) }
            growing = growing.filter { ids.contains($0) }
        }
        if moved { relayout() }
        if hasThreads == threads.isEmpty { hasThreads = !threads.isEmpty }
    }

    /// The layout and the counts from the records, written only when they changed.
    private func relayout() {
        let slots = slots()
        if slots != layout { layout = slots }
        var tally = RouterV2Tally()
        var projects = Set<String>()
        for t in threads {
            tally.all[t.section, default: 0] += 1
            if let p = t.project {
                tally.byProject[p, default: [:]][t.section, default: 0] += 1
                projects.insert(p)
            }
        }
        for o in older { if let p = o.project { projects.insert(p) } }
        tally.projects = projects.sorted()
        if tally != self.tally { self.tally = tally }
    }

    private func selectionChanged(from old: RouterV2Selection?) {
        if case .line(let id)? = old { boxes[id]?.selected = false }
        if case .line(let id)? = selection, let box = boxes[id] {
            box.selected = true
            box.built = true
        }
        if old == .housekeeping || selection == .housekeeping { hits[.housekeeping]?.selected = selection == .housekeeping }
    }

    private func hotChanged(_ old: RouterV2Hit?, _ new: RouterV2Hit?) {
        if let old {
            hot.remove(old)
            hits[old]?.hot = false
        }
        if let new {
            hot.insert(new)
            hits[new]?.hot = true
        }
    }

    private func pressedChanged(from old: RouterV2Hit?) {
        if let old { hits[old]?.pressed = false }
        if let pressed { hits[pressed]?.pressed = true }
    }

    private func movingChanged(from old: Set<String>) {
        for id in old.subtracting(moving) { boxes[id]?.moving = false }
        for id in moving.subtracting(old) { boxes[id]?.moving = true }
    }

    /// `marked` reads the draft, the read, the places and the selection: it is followed, and set on the two lines it
    /// leaves and enters at the turn's end.
    private func trackMarked() {
        _ = withObservationTracking { marked } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.turn.schedule() }
        }
    }

    private func syncMarked() {
        let now = withObservationTracking { marked } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.turn.schedule() }
        }
        guard now != markedShown else { return }
        if let old = markedShown { boxes[old]?.marked = false }
        if let now { boxes[now]?.marked = true }
        markedShown = now
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
