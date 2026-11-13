import AppKit
import SwiftUI

// Router v2's page model (docs/design/router-v2/DESIGN.md 2 to 5): the records, what the owner has selected, picked,
// filtered and typed, and the page as a pure function of them (`rows()`, the counts, the destination row). The owner's
// acts are its methods (the keys, the pointer and the demo's script all call the same ones); what T3 and the model do
// arrives as whole records through `apply` (RouterPort.swift). A source takes the acts that leave the page.

enum RouterSelection: Equatable {
    case line(String), housekeeping, failure(Int)
}

enum RouterFilterItem: Hashable {
    case project(String?), state(RouterSection)
}

/// A row of the page's one list: a section's header (or the sentence in its place), a thread's line, the housekeeping line.
struct RouterRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case header(RouterSection, Int)
        /// "Nothing needs you." and its kin; `clear` adds the ghost Clear filter.
        case sentence(String, clear: Bool)
        /// "Reading 2 threads…": finished threads whose verdicts are pending, listed under it.
        case reading(Int)
        case line(RouterThread)
        case housekeeping(Int)
    }
    var id: String
    var kind: Kind
}

extension RouterRow.Kind {
    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }
}

/// The revert toast: the act, the thread's name, what follows it.
struct RouterToast: Equatable, Identifiable {
    let id: Int
    var before: String
    var name: String
    var after = ""
    /// A Revert to offer: false for a toast that only says why an act didn't go.
    var revertible = true
}

struct RouterSnoozeMenu: Equatable {
    var thread: String
    var index = 0
}

/// What the destination row shows (1.9).
enum RouterDestination: Equatable {
    /// A picked option: Return answers with it.
    case picked(thread: String, words: String)
    /// One place, sure (or your own pick): its mode words after it.
    case place(RouterPlace, mode: String)
    /// The selection, shown at once as the prior while the read is under way.
    case prior(thread: String)
    case reading
    /// The guess first and lit, alternatives beside it; `mine`: you picked the lit one yourself.
    case unsure([RouterPlace], lit: Int, mine: Bool, mode: String)
    case noGuess
}

/// Where the things you can point at are (in the page's space) and what a click on them does: the peek's placement and
/// the demo's drawn pointer read it. Not observed: writing a frame redraws nothing.
@MainActor final class RouterTargets {
    /// Every target's frame as laid out, and the ones that can't be pointed at now (inside a closed card). A target in a
    /// line's own hosting view (`RouterHostedLine`) is laid out in its line's space: `rows` names its line, and the
    /// line's origin on the page (`origins`) places it.
    var laid: [RouterHit: CGRect] = [:]
    var rows: [RouterHit: String] = [:]
    var origins: [String: CGPoint] = [:]
    var off: Set<RouterHit> = []
    var actions: [RouterHit: () -> Void] = [:]
    var viewport: CGSize = .zero

    var frames: [RouterHit: CGRect] {
        var out: [RouterHit: CGRect] = [:]
        out.reserveCapacity(laid.count)
        for (hit, frame) in laid where !off.contains(hit) {
            if let row = rows[hit] {
                guard let origin = origins[row] else { continue }
                out[hit] = frame.offsetBy(dx: origin.x, dy: origin.y)
            } else {
                out[hit] = frame
            }
        }
        return out
    }
}

enum RouterCurve {
    case spatial, lineMove, fade, glass, follow

    func resolved(reduce: Bool) -> Animation? { curve(reduce: reduce).animation }

    /// The curve as plain values: SwiftUI runs it (`resolved`), and so does Core Animation for the lines' glides
    /// (`RouterGlides`).
    func curve(reduce: Bool) -> Motion.Curve {
        switch self {
        case .spatial: Motion.spatial.curve(reduce: reduce)
        case .lineMove: reduce ? Motion.spatial.curve(reduce: true) : Router.lineMoveCurve
        case .fade: Motion.fade.curve(reduce: reduce)
        case .glass: Motion.glass.curve(reduce: reduce)
        case .follow: Motion.follow.curve(reduce: reduce)
        }
    }
}

@MainActor @Observable
final class RouterModel {
    // MARK: Records

    /// Views don't read the records: each line reads its box (`box(_:)`), the list its layout, the bar its tally. Every
    /// change is mirrored there in the same turn (`threadsChanged`).
    var threads: [RouterThread] = [] { didSet { threadsChanged() } }
    var older: [RouterOlder] = [] { didSet { if older != oldValue { relayout() } } }
    var failures: [RouterFailure] = []
    var connectionLost = false

    // MARK: The owner's state

    var selection: RouterSelection? { didSet { if selection != oldValue { selectionChanged(from: oldValue) } } }
    /// The filters: one project or all, one state or all.
    var project: String? { didSet { if project != oldValue { relayout() } } }
    var section: RouterSection? { didSet { if section != oldValue { relayout() } } }
    /// ⌘F: the keyboard is on the filter bar, the ring on `ring`.
    var filterMode = false
    var ring: RouterFilterItem = .project(nil)
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
    var read: RouterRead?
    var explicit: RouterPlace?
    var lit = 0
    var waved = false
    var placesMenu = false
    /// The places menu's row under the keyboard (Tab opens it from the row).
    var placesIndex = 0
    /// Return came before the read: the words wait in the composer (it shows them held) and go when the read lands
    /// sure and agrees with what the row showed; with nothing shown yet, where Fjord is sure.
    var held = false
    /// What the row showed when Return came: a new thread whose draft was still being read, or the selection as the prior.
    @ObservationIgnored var heldPrior: String?
    /// ⌘1–3 pressed while the places were still being read: lit when the read lands unsure.
    @ObservationIgnored var heldDigit: Int?
    var optionHeld = false
    /// The Router's model is reading the draft: Fjord's mark is in the row's arrow slot.
    var reading = false
    /// The composer's @ pills: they go with each read of the draft.
    @ObservationIgnored var mentions: [RouterMention] = []

    // A new thread's settings (RouterLaunch.swift): T3's default and models, what you set by hand, where the keyboard
    // is in the row, the chip whose menu is open.
    /// Only T3's (`.launch`): until its config is read there are no models, and the row offers no settings.
    var launchDefault = RouterLaunch.demoDefault
    var launchModels: [RouterLaunchModel] = []
    var launchMine = RouterLaunchAsk()
    /// What the settings pills in the draft name (`RouterSetting`): they win over what you set by hand before, and a chip you
    /// change by hand afterwards wins over them.
    var launchPills = RouterLaunchAsk()
    /// Scripted only (the demo types into a drawn composer): the @ word being typed, and the list's row lit.
    var scriptedMention: String?
    var scriptedMentionIndex = 0
    var launchFocus: RouterLaunchField?
    var launchMenu: RouterLaunchField?
    /// Each setting's last change: the value it had and which way the new one rolls in.
    var launchRolls: [RouterLaunchField: RouterRoll] = [:]

    var toast: RouterToast?
    var snoozeMenu: RouterSnoozeMenu?

    // The pointer (the real one, or the demo's drawn one).
    var hoverRow: String? { didSet { if hoverRow != oldValue { hotChanged(oldValue.map(RouterHit.row), hoverRow.map(RouterHit.row)) } } }
    var hoverName: String? { didSet { if hoverName != oldValue { hotChanged(oldValue.map(RouterHit.name), hoverName.map(RouterHit.name)) } } }
    var hoverControl: RouterHit? { didSet { if hoverControl != oldValue { hotChanged(oldValue, hoverControl) } } }
    var pressed: RouterHit? { didSet { if pressed != oldValue { pressedChanged(from: oldValue) } } }

    /// The lines changing section now: drawn over their neighbours.
    var moving: Set<String> = [] { didSet { if moving != oldValue { movingChanged(from: oldValue) } } }
    /// The card your own act advanced to: its "new" dot goes (and T3 is told) at your next key or pointer move, not as
    /// it opens, so nothing is marked seen that you didn't look at.
    @ObservationIgnored var pendingSeen: String?
    @ObservationIgnored var keyTurn: KeyTurn?
    /// Asks the composer for the keyboard.
    var focusTick = 0
    /// Brings a row into view (the selection as it moves), set by the list (`RouterReveal`). A call, not observed state:
    /// a write SwiftUI observes, made outside the act's own animation, made SwiftUI update the page synchronously
    /// inside the key's handler before the act could join it.
    @ObservationIgnored var revealer: ((String) -> Void)?

    // MARK: Plumbing

    @ObservationIgnored weak var source: RouterSource?
    @ObservationIgnored let targets = RouterTargets()
    /// The curve the list's rows glide on, for the change being made now (`RouterGlides`).
    @ObservationIgnored let glides = RouterGlides()
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The demo's script holds the pointer and the keys: the real pointer's hover is not read.
    @ObservationIgnored var scripted = false
    /// A still (a shot): the sheen and the dots hold one pose, the clock stands.
    @ObservationIgnored var still = false
    var reduce = false { didSet { if reduce != oldValue { relayout() } } }
    /// The fake clock: `clockStart` at the moment the page was made.
    @ObservationIgnored let made = Date()
    @ObservationIgnored var clockStart: Date = RouterModel.today(14, 2)
    /// Tests: each change's curve, and whether it animated.
    @ObservationIgnored var trace: ((RouterCurve, Bool) -> Void)?
    /// Inside a `.batch`: nothing animates.
    @ObservationIgnored private var unanimated = 0

    /// The lines an act with a Revert took off the page, as they were: the demo's store puts them back from here on a
    /// Revert (the real one from its records).
    @ObservationIgnored var parked: [String: RouterThread] = [:]
    /// The acts with a Revert, newest last: the toast they showed, the threads they hid, how to take them back.
    @ObservationIgnored var undos: [(toast: Int, threads: [String], undo: () -> Void)] = []
    @ObservationIgnored private var nextID = 0
    /// Each thread's last send from here, its words and kind: a refusal that comes after T3's row already moved on still
    /// has them for its failure line.
    @ObservationIgnored var lastSends: [String: (words: String, kind: RouterOutgoing.Kind)] = [:]
    /// What a send in flight changed, to put back if it is refused, and what it was.
    @ObservationIgnored var backups: [String: (thread: RouterThread, picks: [Int: Int]?, kind: RouterOutgoing.Kind)] = [:]
    @ObservationIgnored var toastLife: Task<Void, Never>?
    /// The pointer's last move over a line-removing button, by generation: a button is armed only by a move made after
    /// the last removal (the 2026-10-12 rule, without a timer).
    @ObservationIgnored private var armGeneration = 0
    @ObservationIgnored private var armed: [RouterHit: Int] = [:]
    @ObservationIgnored private var lastPointer: [RouterHit: CGPoint] = [:]

    // MARK: What the views read (RouterRender.swift)

    /// The list's rows, rewritten only when the order or a header's count changes.
    private(set) var layout: [RouterSlot] = [RouterSlot(id: RouterModel.firstRow, kind: .sentence(Router.Copy.nothingAtAll, clear: false))]
    /// This turn's change of the layout moves rows and adds or takes none: the list places its rows at once and they
    /// glide on Core Animation (`RouterList`). Any other change keeps its SwiftUI animation (the rows' folds, a card's
    /// roll).
    @ObservationIgnored private(set) var placedAtOnce = false
    /// The counts and the projects, stored with the layout.
    private(set) var tally = RouterTally()
    /// There is a thread: the filter bar shows.
    private(set) var hasThreads = false
    /// The ages' one clock.
    @ObservationIgnored private(set) lazy var clock = RouterClock(from: made)
    @ObservationIgnored private var boxes: [String: RouterLineBox] = [:]
    @ObservationIgnored private var hits: [RouterHit: RouterHitBox] = [:]
    /// What is hot and pressed, for a hit's box made after the fact.
    @ObservationIgnored private var hot: Set<RouterHit> = []
    /// The line marked as the draft's destination, as last set on the boxes.
    @ObservationIgnored private var markedShown: String?
    /// Streamed changes kept for the turn's end, by thread, in arrival order (`post`).
    @ObservationIgnored private var kept: [(id: String, change: RouterChange)] = []
    /// Threads whose words of the current stream are still coming (`.words(done: false)`).
    @ObservationIgnored private var growing: Set<String> = []
    @ObservationIgnored private lazy var turn = RouterTurn { [weak self] in self?.endTurn() }

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

    func animate(_ curve: RouterCurve, _ body: () -> Void) {
        let off = motionOff
        trace?(curve, !off)
        if !off { glides.began(curve.curve(reduce: reduce)) }
        let animation = off ? nil : curve.resolved(reduce: reduce)
        keyTurn = KeyTurn(animation: animation)
        withAnimation(animation) { body() }
    }

    /// The animation of the last change made through `animate` or `move` since the key began (`takeSeen`).
    struct KeyTurn { let animation: Animation? }

    /// A change that takes `id` to another section: it is on top of its neighbours for the length of the move.
    func move(_ id: String, _ body: () -> Void) {
        let off = motionOff
        trace?(.lineMove, !off)
        if scripted { RouterFrames.note("move \(id)") }
        // Landed: its ground fades, and its card opens if it landed selected.
        let land: () -> Void = { [weak self] in self?.animate(.spatial) { _ = self?.moving.remove(id) } }
        guard !off else {
            keyTurn = KeyTurn(animation: nil)
            withAnimation(nil, completionCriteria: .logicallyComplete) {
                moving.insert(id)
                body()
            } completion: { land() }
            return
        }
        // In flight from the same frame as the change that moves it: one update, nothing drawn in between. Its row
        // glides on Core Animation (`RouterGlides`), which says when it has landed.
        let curve = RouterCurve.lineMove.curve(reduce: reduce)
        glides.began(curve)
        glides.landing(id, land)
        keyTurn = KeyTurn(animation: curve.animation)
        withAnimation(curve.animation) {
            moving.insert(id)
            body()
        }
    }

    // MARK: Reading the records

    func thread(_ id: String) -> RouterThread? {
        // What reads one thread follows that thread only: its box's revision, or the records while it has none (it may
        // come). Following all the records redrew the dock and the peek on every streamed word of every line.
        guard let box = boxes[id] else {
            access(keyPath: \.threads)
            return nil
        }
        _ = box.revision
        return box.record
    }

    func update(_ id: String, _ change: (inout RouterThread) -> Void) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[i])
    }

    var selectedThread: RouterThread? {
        if case .line(let id)? = selection { return thread(id) }
        return nil
    }

    /// A section's lines in their stable order (2.1), unfiltered.
    func ordered(_ section: RouterSection) -> [RouterThread] {
        let all = threads.filter { $0.section == section }
        func oldest(_ a: RouterThread, _ b: RouterThread) -> Bool { a.since != b.since ? a.since < b.since : a.order < b.order }
        func newest(_ a: RouterThread, _ b: RouterThread) -> Bool { a.since != b.since ? a.since > b.since : a.order > b.order }
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

    private func matches(_ t: RouterThread, project: String?, section: RouterSection?) -> Bool {
        (project == nil || t.project == project) && (section == nil || t.section == section)
    }

    /// The lines shown, top to bottom.
    var shownLines: [RouterThread] {
        layout.compactMap { if case .line(let id) = $0.kind { boxes[id]?.record } else { nil } }
    }

    var shownOlder: [RouterOlder] {
        guard section == nil || section == .done else { return [] }
        return older.filter { project == nil || $0.project == project }
    }

    /// The Needs-you header and the sentence that takes its place are one row: its content cross-fades, nothing folds.
    static let firstRow = "header-0"
    /// The "Reading 2 threads…" row under Needs-you lines (with none, it takes the first row's place).
    static let readingRow = "reading"

    /// The page: headers, lines, the sentences that take a header's place, the housekeeping line.
    func rows() -> [RouterRow] {
        layout.compactMap { slot in
            switch slot.kind {
            case .header(let s, let n): RouterRow(id: slot.id, kind: .header(s, n))
            case .sentence(let words, let clear): RouterRow(id: slot.id, kind: .sentence(words, clear: clear))
            case .reading(let n): RouterRow(id: slot.id, kind: .reading(n))
            case .line(let id): boxes[id].map { RouterRow(id: slot.id, kind: .line($0.record)) }
            case .housekeeping(let n): RouterRow(id: slot.id, kind: .housekeeping(n))
            }
        }
    }

    /// The page's rows from the records: sorted here, once per change of order, never in a body.
    private func slots() -> [RouterSlot] {
        if threads.isEmpty {
            return [RouterSlot(id: Self.firstRow, kind: .sentence(Router.Copy.nothingAtAll, clear: false))]
        }
        var out: [RouterSlot] = []
        let older = shownOlder
        var shown: [RouterSection: [RouterThread]] = [:]
        for s in RouterSection.allCases { shown[s] = ordered(s).filter { matches($0, project: project, section: section) && !$0.reading } }
        // Finished threads Fjord is still reading: they may need you or not, so they wait in a group of their own under
        // the Needs-you place (under a Needs-you or a Done filter alike), newest first.
        let reading = section == .working ? [] : threads.filter { $0.reading && (project == nil || $0.project == project) }
            .sorted { $0.since != $1.since ? $0.since > $1.since : $0.order > $1.order }
        if shown.values.allSatisfy(\.isEmpty), reading.isEmpty, older.isEmpty, let project {
            return [RouterSlot(id: Self.firstRow, kind: .sentence(Router.Copy.noThreads(in: project), clear: true))]
        }
        func lines(_ list: [RouterThread], _ place: String) -> [RouterSlot] {
            // Under Reduce Motion a line that changes section fades out where it was and in where it goes: its row is
            // another one there.
            list.map { RouterSlot(id: reduce ? "\($0.id)@\(place)" : $0.id, kind: .line($0.id)) }
        }
        for s in RouterSection.allCases {
            let list = shown[s] ?? []
            if list.isEmpty {
                if s == .needsYou, !reading.isEmpty {
                    // Never "Nothing needs you" while a verdict that may say otherwise is pending.
                    out.append(RouterSlot(id: Self.firstRow, kind: .reading(reading.count)))
                    out += lines(reading, "reading")
                } else if s == .needsYou, section == nil || section == .needsYou {
                    let words = project.map(Router.Copy.nothingNeedsYou(in:)) ?? Router.Copy.nothingNeedsYou
                    out.append(RouterSlot(id: Self.firstRow, kind: .sentence(words, clear: false)))
                }
                continue
            }
            out.append(RouterSlot(id: "header-\(s.rawValue)", kind: .header(s, list.count)))
            out += lines(list, "\(s.rawValue)")
            if s == .needsYou, !reading.isEmpty {
                out.append(RouterSlot(id: Self.readingRow, kind: .reading(reading.count)))
                out += lines(reading, "reading")
            }
        }
        if !older.isEmpty { out.append(RouterSlot(id: "housekeeping", kind: .housekeeping(older.count))) }
        return out
    }

    /// The projects with at least one line (or a finished thread under the housekeeping line), alphabetical: the bar's
    /// pills.
    var projects: [String] { tally.projects }

    /// A pill's count: its lines under the current state choice.
    func count(project p: String?) -> Int {
        // The lines being read show under every state choice but Working.
        tally.count(project: p, section: section) + (section == .working ? 0 : tally.reading(project: p))
    }
    /// A token's count: its lines under the current project choice.
    func count(section s: RouterSection) -> Int { tally.count(project: project, section: s) }
    /// The sidebar's badge: every Needs-you line, whatever the filters.
    var needsYou: Int { tally.all[.needsYou] ?? 0 }

    var filtered: Bool { project != nil || section != nil }

    /// Esc would clear the filters now: nothing else is left for it to step out of (5.3).
    var escClears: Bool {
        filtered && selection == nil && draft.isEmpty && snoozeMenu == nil && !placesMenu && launchMenu == nil && !filterMode
    }

    func name(_ place: RouterPlace) -> String {
        switch place {
        case .thread(let id): thread(id)?.name ?? ""
        case .newThread(let project): "new thread in \(project)"
        case .here: Router.Copy.answersHere
        }
    }

    // MARK: The pointer

    /// The pointer came onto `hit` or left it.
    func hover(_ hit: RouterHit, _ inside: Bool) {
        switch hit {
        case .row(let id): if inside { hoverRow = id } else if hoverRow == id { hoverRow = nil }
        case .name(let id): if inside { hoverName = id } else if hoverName == id { hoverName = nil }
        default:
            if inside { hoverControl = hit } else if hoverControl == hit { hoverControl = nil }
            switch hit {
            case .toast, .revert:
                // The toast's clock stops under the pointer and starts again as it leaves.
                if inside { toastLife?.cancel() } else if toast != nil { startToastLife(Router.toastLife) }
            case .launch:
                // The pointer has the row: the keyboard's ring goes.
                if inside, launchFocus != nil { animate(.fade) { launchFocus = nil } }
            default: break
            }
        }
    }

    /// Your next key or pointer move after your own act opened a card: its "new" dot goes, and T3 is told.
    func ownerActed() { markSeen(takeSeen()) }

    /// A key begins: T3 is told of the line your own act opened, and its id comes back for `markSeen`, once the key's
    /// act is made.
    func takeSeen() -> String? {
        keyTurn = nil
        guard let id = pendingSeen else { return nil }
        pendingSeen = nil
        guard selection == .line(id), thread(id)?.isNew == true else { return nil }
        source?.visit(id)
        return id
    }

    /// `id`'s "new" dot goes (it fades on its own, `RouterLineView.row`). Written in the transaction of the key's act
    /// when it made one: in another (the fade, or none), SwiftUI updated that line synchronously before the act's own
    /// writes could join it.
    func markSeen(_ id: String?) {
        guard let id, thread(id)?.isNew == true else { return }
        if let keyTurn {
            withAnimation(keyTurn.animation) { update(id) { $0.isNew = false } }
        } else {
            animate(.fade) { update(id) { $0.isNew = false } }
        }
    }

    /// The real pointer's; not read while the script holds the pointer.
    func realHover(_ hit: RouterHit, _ inside: Bool) {
        guard !scripted else { return }
        if inside { ownerActed() }
        hover(hit, inside)
    }

    func isHot(_ hit: RouterHit) -> Bool {
        switch hit {
        case .row(let id): hoverRow == id
        case .name(let id): hoverName == id
        default: hoverControl == hit
        }
    }

    /// The pointer moved over a button that removes a line: it is armed.
    func pointerMoved(over hit: RouterHit, at point: CGPoint) {
        if let last = lastPointer[hit], last != point { armed[hit] = armGeneration }
        lastPointer[hit] = point
    }

    func isArmed(_ hit: RouterHit) -> Bool { armed[hit] == armGeneration }

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
    private var walk: [RouterSelection] {
        shownLines.map { .line($0.id) } + (shownOlder.isEmpty ? [] : [.housekeeping]) + failures.map { .failure($0.id) }
    }

    /// `walk`: the arrows moved it there: a new line's dot goes (and T3 is told) only at your next key that isn't an
    /// arrow, or a pointer move, so lines walked past aren't marked read on T3's sidebar and phone.
    func select(_ new: RouterSelection?, walk: Bool = false) {
        guard new != selection else { return }
        let interval = RouterSignposts.begin("Select"), work = RouterSignposts.begin("Select work")
        defer {
            RouterSignposts.end(work)
            RouterSignposts.end(interval, afterCommit: true)
        }
        pendingSeen = nil
        animate(.spatial) {
            selection = new
            snoozeMenu = nil
            // Another card: the row's guess is asked again.
            waved = false
            if case .line(let id)? = new, thread(id)?.isNew == true {
                // You opened its card: no longer new, and T3 is told (only of a new one).
                if walk {
                    pendingSeen = id
                } else {
                    update(id) { $0.isNew = false }
                    source?.visit(id)
                }
            }
        }
        if case .line(let id)? = new { show(id) }
        if case .housekeeping? = new { show("housekeeping") }
        draftContextChanged()
    }

    func show(_ row: String) {
        revealer?(row)
    }

    /// A click on a line's row: its card, or none if it was the open one.
    func click(row id: String) { select(selection == .line(id) ? nil : .line(id)) }

    func step(down: Bool) {
        let rows = walk
        guard !rows.isEmpty else { return }
        guard let selection, let i = rows.firstIndex(of: selection) else {
            select(down ? rows.first : rows.last, walk: true)
            return
        }
        select(rows[(i + (down ? 1 : rows.count - 1)) % rows.count], walk: true)
    }

    /// ⌥↓ / ⌥↑: the first line of the next or previous section shown.
    func stepSection(down: Bool) {
        let lines = shownLines
        let sections = RouterSection.allCases.filter { s in lines.contains { $0.section == s } }
        guard !sections.isEmpty else { return }
        let current = selectedThread.flatMap { sections.firstIndex(of: $0.section) }
        let next: Int
        if let current { next = (current + (down ? 1 : sections.count - 1)) % sections.count } else { next = down ? 0 : sections.count - 1 }
        if let first = lines.first(where: { $0.section == sections[next] }) { select(.line(first.id), walk: true) }
    }

    /// Where the selection goes when its line leaves `section`: the line after it there, else the one before, else none.
    func neighbour(of id: String) -> RouterSelection? {
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

    func toggle(section s: RouterSection) {
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
    var filterItems: [RouterFilterItem] {
        [.project(nil)] + projects.map { .project($0) } + RouterSection.allCases.map { .state($0) }
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

    func answered(_ t: RouterThread, _ question: Int) -> Bool {
        picks[t.id]?[question] != nil || typed[t.id]?[question] != nil
    }

    func answeredCount(_ t: RouterThread) -> Int { t.form.indices.filter { answered(t, $0) }.count }

    /// Tab / ⇧Tab on a form: the next or previous question.
    func moveQuestion(forward: Bool) {
        guard let t = selectedThread, !t.form.isEmpty else { return }
        let at = min(t.form.count - 1, max(0, (formAt[t.id] ?? 0) + (forward ? 1 : -1)))
        animate(.spatial) { formAt[t.id] = at }
    }

    /// The words an answer sends: the picked option, or each question's answer in order.
    func answerWords(_ t: RouterThread) -> String? {
        let mine = picks[t.id] ?? [:]
        let options = t.numbered
        // A pick the card no longer has (its ask changed under it) says nothing.
        func label(_ n: Int) -> String? { options.indices.contains(n - 1) ? options[n - 1].label : nil }
        if t.form.isEmpty { return mine[0].flatMap(label) }
        let parts = t.form.indices.compactMap { q in typed[t.id]?[q] ?? mine[q].flatMap(label) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The card's ask changed, or it asks nothing now: what you picked or typed for the old one goes.
    private func dropAnswers(_ id: String) {
        picks[id] = nil
        typed[id] = nil
        formAt[id] = nil
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
    func apply(_ change: RouterChange) {
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
        case .note(let id, let words):
            note(id, words)
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
    private func upsert(_ new: RouterThread) {
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
        if t.askID != old.askID || t.section != .needsYou || t.state == .stopped { dropAnswers(id) }
        // A send T3 took, or that ended: nothing is left to put back if it is refused.
        if t.state != .sent || t.sent?.status == .taken { backups[id] = nil }
        let leaves = t.section != old.section
        if leaves || t.orderClass != old.orderClass {
            let next: RouterSelection?? = leaves && selection == .line(id) ? .some(neighbour(of: id)) : nil
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
    private static func curve(from old: RouterThread, to new: RouterThread) -> RouterCurve? {
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
        dropAnswers(id)
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
        let last = lastSends.removeValue(forKey: id)
        guard thread(id) != nil, let words = thread(id)?.sent?.words ?? last?.words else { return }
        let failure = RouterFailure(id: fresh(), thread: id, words: words, reason: reason,
                                      kind: backups[id]?.kind ?? last?.kind ?? .words, offline: offline)
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
    func post(_ change: RouterChange) {
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

    private func keep(_ id: String, _ change: RouterChange, replacing same: (RouterChange) -> Bool) {
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
        RouterBodies.count("flush", of: self)
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
        var section: RouterSection
        var orderClass: RouterThread.OrderClass
        var since: Date
        var order: Int
        var reassessing: Bool
        var reading: Bool
        var project: String?

        init(_ t: RouterThread) {
            reading = t.reading
            section = t.section
            orderClass = t.orderClass
            since = t.since
            order = t.order
            reassessing = t.sentence.phase == .reassessing
            project = t.project
        }
    }

    /// A line's box. Its view is only made for a line the model holds.
    func box(_ id: String) -> RouterLineBox {
        if let box = boxes[id] { return box }
        // A row whose thread just left, drawn once more on its way out: a box of its own, not kept.
        return RouterLineBox(RouterThread(id: id, name: "", title: "", state: .done, sentence: .init(text: ""), since: made))
    }

    /// The flags of a thing that can be pointed at.
    func flags(_ hit: RouterHit) -> RouterHitBox {
        if let box = hits[hit] { return box }
        let box = RouterHitBox(hot: hot.contains(hit), pressed: pressed == hit, selected: hit == .housekeeping && selection == .housekeeping)
        hits[hit] = box
        return box
    }

    private func threadsChanged() {
        var moved = boxes.count != threads.count
        for t in threads {
            if let box = boxes[t.id] {
                if box.take(t) { moved = true }
            } else {
                let box = RouterLineBox(t)
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
            // What read a thread that left hears it once more (`thread(id)` follows its box).
            for (id, box) in boxes where !ids.contains(id) { box.left() }
            boxes = boxes.filter { ids.contains($0.key) }
            growing = growing.filter { ids.contains($0) }
        }
        if moved { relayout() }
        if hasThreads == threads.isEmpty { hasThreads = !threads.isEmpty }
    }

    /// The layout and the counts from the records, written only when they changed.
    private func relayout() {
        let slots = slots()
        if slots != layout {
            if slots.count == layout.count, Set(slots.map(\.id)) == Set(layout.map(\.id)) {
                placedAtOnce = true
                // For this turn's update only.
                DispatchQueue.main.async { [weak self] in self?.placedAtOnce = false }
            }
            layout = slots
        }
        var tally = RouterTally()
        var projects = Set<String>()
        for t in threads {
            if let p = t.project { projects.insert(p) }
            // A line being read is in no state yet: its own count, on the pills, not on a token.
            if t.reading {
                tally.reading[t.project ?? "", default: 0] += 1
                continue
            }
            tally.all[t.section, default: 0] += 1
            if let p = t.project { tally.byProject[p, default: [:]][t.section, default: 0] += 1 }
        }
        for o in older { if let p = o.project { projects.insert(p) } }
        tally.projects = projects.sorted()
        if tally != self.tally { self.tally = tally }
    }

    private func selectionChanged(from old: RouterSelection?) {
        if case .line(let id)? = old { boxes[id]?.selected = false }
        if case .line(let id)? = selection, let box = boxes[id] {
            box.selected = true
            box.built = true
        }
        if old == .housekeeping || selection == .housekeeping { hits[.housekeeping]?.selected = selection == .housekeeping }
    }

    private func hotChanged(_ old: RouterHit?, _ new: RouterHit?) {
        if let old {
            hot.remove(old)
            hits[old]?.hot = false
        }
        if let new {
            hot.insert(new)
            hits[new]?.hot = true
        }
    }

    private func pressedChanged(from old: RouterHit?) {
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

extension RouterThread {
    /// The groups a section orders its lines in (`RouterModel.ordered`): a line that goes from one to another moves.
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
