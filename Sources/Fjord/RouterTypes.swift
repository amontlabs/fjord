import AppKit
import SwiftUI

// Router v2 (docs/design/router-v2/DESIGN.md): one line per thread, grouped by state. This file holds every number, curve
// and word of the page in one place (`Router`), and the record the page is a pure function of (`RouterThread`).
// The components (RouterPage, RouterLine, RouterCard, RouterDock) take the model as a value and send acts back;
// RouterDemo feeds them fake data today, the real engine later.

enum Router {
    /// The page's column, as the brief's.
    static let column: CGFloat = 720
    static let gutter: CGFloat = 32
    /// The page's coordinate space: the targets' frames are read in it (the peek's placement, the demo's pointer).
    static let space = "router-page"

    // MARK: Metrics

    enum Bar {
        static let control: CGFloat = 24
        static let padY: CGFloat = 12
        static let pillGap: CGFloat = 2
        static let tokenGap: CGFloat = 4
        static let mark: CGFloat = 10
        /// The fade under the bar and over the dock: lines scroll out under both.
        static let fade: CGFloat = 24
    }

    enum Header {
        static let height: CGFloat = 28
        static let top: CGFloat = 16
        static let firstTop: CGFloat = 8
        static let countGap: CGFloat = 6
    }

    enum Line {
        static let minHeight: CGFloat = 34
        static let padY: CGFloat = 6
        /// The row's ground past its words, each side: the name starts this far in (past the dot's column), and the age
        /// ends as far from the other edge, so a line's ground and its card have the same inset left and right.
        static let reach: CGFloat = nameLeading
        /// The dot's column (new, or where your words go), from the row's edge.
        static let dotLeading: CGFloat = 4
        static let radius: CGFloat = Surface.row
        static let dotGap: CGFloat = 4
        /// Where the name starts, from the row's edge: the dot's column, the dot, gap.
        static let nameLeading: CGFloat = dotLeading + CDS.Dot.size + dotGap
        static let mark: CGFloat = 9.5
        static let markBox: CGFloat = 13
        static let markGap: CGFloat = 4
        static let namePadX: CGFloat = 5
        static let namePadY: CGFloat = 1
        static let nameRadius: CGFloat = Surface.control
        static let ground: Double = Surface.tint
        static let groundHover: Double = Surface.tintStrong
        static let sentenceGap: CGFloat = 8
        static let pillGap: CGFloat = 12
        static let ageGap: CGFloat = 8
        static let ageWidth: CGFloat = 28
        static let selectedRadius: CGFloat = Surface.card
        static let queuedHeight: CGFloat = 22
        /// A name is never cut under this many characters; a new thread's first words stop there.
        static let nameCharacters = 28
        /// The most of the row a name takes before it truncates (T3's whole title, until the model's name comes); the
        /// sentence gives way first below that.
        static let nameShare: CGFloat = 0.45
        /// T3's title as a name until the model's comes: whole on one line, the row truncating it at its own width; cut
        /// here only past this many characters.
        static let titleCharacters = 120
    }

    enum Card {
        /// The card's one text column, from the ground's edge: where the line's name words start (past its ground's pad
        /// and its mark). Every block's words start here; glyphs, radios and rails hang in the gutter to its left.
        static let leading: CGFloat = Line.nameLeading + Line.namePadX + Line.markBox + Line.markGap
        /// The footer's keys, the options' and the line's age end on one edge, as far from the ground's edge as the
        /// line's name ground starts from the other.
        static let trailing: CGFloat = Line.reach
        /// A glyph hung left of the column (a step's, an activity row's, a run start's arrow, a warning): the line's
        /// mark box and gap, so it sits under the line's mark.
        static let glyphBox: CGFloat = Line.markBox
        static let glyphGap: CGFloat = Line.markGap
        static let hang: CGFloat = glyphBox + glyphGap
        /// An option's radio and the gap after it, hung left of the column so its label starts on it.
        static let radio: CGFloat = 16
        static let radioGap: CGFloat = 8
        static let radioHang: CGFloat = radio + radioGap
        /// An option's ground past its radio and past the card's trailing edge.
        static let optionReach: CGFloat = 8
        static let optionTrailing: CGFloat = optionReach
        /// A form's option grounds reach less far: its current question's rail hangs left of them.
        static let formReach: CGFloat = 4
        static let bottom: CGFloat = 10
        static let gap: CGFloat = 10
        static let maxWidth: CGFloat = 560
        static let railInset: CGFloat = 10
        static let lastLines = 4
        static let lastLinesDone = 6
        static let planLines = 8
        static let footerGap: CGFloat = 16
        static let steps = 5
    }

    enum Peek {
        static let width: CGFloat = 360
        static let radius: CGFloat = Surface.panel
        static let pad: CGFloat = 12
        static let gap: CGFloat = 10
        /// The housekeeping line's peek: its names are T3 titles, whole.
        static let olderWidth: CGFloat = 400
    }

    enum Dock {
        static let rowHeight: CGFloat = 24
        static let toastHeight: CGFloat = 28
        static let failureHeight: CGFloat = 34
        /// A place in the row: its ground when it is the lit one of several.
        static let place: CGFloat = 20
        static let placePadX: CGFloat = 6
        /// A button of the page (Continue, Send again, Settle all): the filter pills' height.
        static let button: CGFloat = 24
        static let bottom: CGFloat = 10
        /// The place a first read is about to name, as a skeleton bar.
        static let skeleton = CGSize(width: 96, height: 8)
    }

    /// Fjord's mark where the Router's model is at work (`RouterThinking`): in the destination row's arrow slot, and
    /// after the words of a line it is reading.
    enum Thinking {
        static let row: CGFloat = 14
        static let line: CGFloat = 13
        static let gap: CGFloat = 6
    }

    /// A new thread's settings in the destination row (1.9): one chip a setting.
    enum Launch {
        static let chip: CGFloat = 18
        static let radius: CGFloat = Surface.token
        static let padX: CGFloat = 6
        static let gap: CGFloat = 4
        static let font: CGFloat = 12
        /// How far a value rolls as it changes.
        static let travel: CGFloat = 13
        static let menuWidth: CGFloat = 220
        /// A setting's glow as your words set it, and the ground of those words in the composer: the accent's tint.
        static let glowFill: Double = Surface.tintStrong
    }

    // MARK: Curves (section 3). Each resolves for Reduce Motion where it is used.

    /// A line changing section: a little longer than `spatial`, so the eye can follow it.
    static let lineMoveCurve = Motion.Curve.spring(duration: 0.45, bounce: 0.14)
    static let lineMove = Animation.spring(duration: 0.45, bounce: 0.14)
    /// A card that opens as a line takes off shows what is in it once the line has passed its place.
    static let cardAfterFlight: (delay: Double, fade: Double) = (0.14, 0.16)
    /// A PR's state word as it flips: it swaps in one frame and pops from `prPopScale`.
    static let prPop = Animation.spring(duration: 0.35, bounce: 0.3)
    static let prPopScale: CGFloat = 1.25
    /// Counts ticking.
    static let counts = Animation.snappy
    /// The model's words: one every `wordEvery` (a verdict's words take about half a second to stream), each fading in
    /// over `wordFade`, the first `streamLead` after the code line starts to go.
    static let wordEvery: Double = 0.05
    static let wordFade: Double = 0.12
    static let streamLead: Double = 0.04
    /// One text taking another's place (a sentence, a placeholder, the row's words, a toast): the old one out in
    /// `swapOut`, then the new one in over `swapIn`, so the two are never read on top of each other.
    static let swapOut: Double = 0.06
    static let swapIn: Double = 0.12
    /// The sheen: a band `sheenBand` of the sentence wide, crossing it in `sheenPeriod`.
    static let sheenPeriod: Double = 1.4
    static let sheenBand: Double = 0.4
    /// A setting's value as it changes: the new one rolls in, the old one out; settings your words set roll one after
    /// the other, `rollStagger` apart, and their chips glow in the accent, held `glowHold` then fading over `glowFade`.
    static let roll = Animation.spring(duration: 0.34, bounce: 0.22)
    static let rollStagger: Double = 0.07
    static let glowHold: Double = 0.35
    static let glowFade: Double = 0.9
    /// The danger ground (a Stopped card's reason, a failure line): the danger ink's tint, as a name's ground. No ring.
    static let dangerFill = CDS.Text.danger.opacity(Surface.tint)
    /// The revert toast's life; the clock stops under the pointer.
    static let toastLife: Double = 8
    /// How long typing pauses before Jev reads the draft, and before Sonnet decides (both from the same keystroke):
    /// the one timer between a key and a read (IMPLEMENTATION.md risk 3). Return never waits for them.
    static let jevPause: Duration = .milliseconds(300)
    static let sonnetPause: Duration = .milliseconds(600)
    /// The failure line's shake: 6 pt, 2 cycles, 0.3 s.
    static let shake: (distance: CGFloat, cycles: Double, duration: Double) = (6, 2, 0.3)

    // MARK: Copy

    enum Copy {
        static let all = "All"
        static let clear = "Clear"
        static let clearFilter = "Clear filter"
        static let nothingNeedsYou = "Nothing needs you."
        /// Finished threads whose verdicts are pending: never "Nothing needs you" while one may.
        static func reading(_ n: Int) -> String { n == 1 ? "Reading 1 thread…" : "Reading \(n) threads…" }
        static let nothingAtAll = "Nothing needs you. Nothing is running."
        static func nothingNeedsYou(in project: String) -> String { "Nothing needs you in \(project)." }
        static func noThreads(in project: String) -> String { "No threads in \(project) right now." }
        static func older(_ n: Int) -> String { "\(n) finished earlier, not settled" }
        static let finished = "finished"
        static let stoppedByYou = "stopped by you"
        static let starting = "starting"
        static let interrupted = "interrupted"
        static let sending = "sending…"
        static let steering = "steering…"
        static let pickAPlace = "not sure where this goes: pick a place"
        static let answersHere = "Fjord answers here"
        static let steerNow = "steer now · ⌥ queue"
        static let queueAfter = "queue after this turn"
        static let queued = "queued, sends when this turn ends"
        static let unreachable = "T3 Code isn't reachable."
        /// In the destination row while T3 is away: Return keeps the words.
        static let unreachableRow = "T3 Code isn't reachable"
        static let reconnecting = "T3 Code isn't reachable. Reconnecting…"
        /// A request T3 can no longer answer (after a T3 restart): its options give way to Open in T3.
        static let notLive = "T3 can no longer take an answer to this from here."
        static let snooze = "Snooze"
        static let snoozeChoices = ["For 1 hour", "For 3 hours", "Until tomorrow, 9:00"]
        static let snoozedUntil = ["for 1 hour", "for 3 hours", "until tomorrow, 9:00"]
        /// What Continue on a Stopped card sends: T3's own words for it (it has no rerun).
        static let continueWords = "Continue where you left off."
        static let continueTitle = "Continue"
        /// Why Settle and Snooze are off on a line T3 won't let go of yet (a request waits, a run is live, a message is queued).
        static let answerOrStopFirst = "Answer or stop it first"
        /// A settle or snooze T3 refused for no reason the page can see.
        static let t3KeptIt = "T3 didn't take it"
        /// Cancel on a queued row that T3 refused.
        static let queueKept = "the queued message still goes"
        static func moreToAnswer(_ n: Int) -> String { "\(n) more to answer" }
    }

    /// A thread's first words as its name, until the model names it: 28 characters at most, cut at a word.
    static func firstWords(_ text: String, limit: Int = Line.nameCharacters) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        var out = ""
        for word in flat.split(separator: " ") {
            if out.count + word.count + (out.isEmpty ? 0 : 1) > limit - 1 { break }
            out += (out.isEmpty ? "" : " ") + word
        }
        return (out.isEmpty ? String(flat.prefix(limit - 1)) : out) + "…"
    }
}

// MARK: - The record

/// The page's three sections, in page order. Stopped lines live in Needs you, Sent lines in Working.
enum RouterSection: Int, CaseIterable, Hashable {
    case needsYou, done, working

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .done: "Done"
        case .working: "Working"
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: CDS.Text.warning
        case .done: CDS.Text.accent
        case .working: CDS.Text.muted
        }
    }

    /// The state's mark in the filter bar's token.
    var symbol: String {
        switch self {
        case .needsYou: "questionmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .working: "ellipsis"
        }
    }
}

/// One thread, as the page draws it: a code state, the sentence (the code's, or the model's verdict), and what its card
/// shows. Icon, colour, section, counts and age are all read from it.
struct RouterThread: Identifiable, Equatable {
    enum Ask: Equatable { case question, form, plan, permission }
    enum State: Equatable { case needsYou(Ask), stopped, sent, working, done }
    enum Worth: Equatable { case look, quiet }

    /// The line's words: the code's (settled, or sheening while the model reads the thread), or the model's (each line
    /// that lands streams in once).
    struct Sentence: Equatable {
        enum Phase: Equatable { case settled, reassessing, streaming }
        var text: String
        /// A permission's command, as the code writes it.
        var mono = false
        var phase: Phase = .settled
        /// Counts the model's lines as they land.
        var stream = 0
        /// The code draws the PR's state word after its link (off when the words say it themselves).
        var stateWord = true
    }

    struct Sent: Equatable {
        enum Status: Equatable { case sending, steering, taken }
        var words: String
        var status: Status
    }

    struct PR: Equatable, Identifiable {
        enum State: String { case open, merged, closed }
        var number: Int
        var state: State
        var id: Int { number }
    }

    struct Question: Equatable, Identifiable {
        var id: String
        var title: String
        var options: [String]
    }

    struct Permission: Equatable {
        var command: String
        var warning: String
        /// The options (by number) the warning is about.
        var warned: Set<Int>
    }

    struct Stop: Equatable {
        var error: String
        var lastStep: String
    }

    struct Step: Equatable, Identifiable {
        enum State: Equatable { case done, running, pending }
        var id: Int
        var text: String
        var state: State
    }

    struct Diff: Equatable {
        var files: Int
        var added: Int
        var removed: Int
    }

    let id: String
    /// The page's short name (the model's, written once); a new thread's is T3's title or your first words until then.
    var name: String
    /// The name is being given: it sheens.
    var naming = false
    /// T3's title.
    var title: String
    var project: String?
    var state: State
    /// A finished turn whose verdict hasn't said yet whether it needs you: Fjord is reading it. It is shown as being read
    /// (its own group, under the Needs-you place), never as a settled Done line.
    var judging = false
    var worth: Worth = .quiet
    var sentence: Sentence
    /// What the age counts from: how long it has waited, run, or been finished.
    var since: Date
    /// Its turn among lines that entered their state at the same time (a stable order).
    var order = 0
    /// T3's `unseen`.
    var isNew = false
    /// Paused at the usage limit, resuming on its own: Working, the dots still.
    var paused = false
    var sent: Sent?
    /// Words waiting for the turn under way.
    var queued: String?
    /// Its agent takes words mid-turn (Claude does); one that can't only queues them.
    var steers = true
    /// The verdict's result line, kept beside the ask it found: the line's words once you say it doesn't need you.
    var result: String?

    // The card.
    var lastLines = ""
    /// The thread's messages are loading: skeleton bars.
    var loading = false
    /// T3 can still take an answer to its request (`ThreadRequest.live`): false after a T3 restart, and the card offers
    /// Open in T3 in its options' place.
    var live = true
    /// The agent is writing: the last lines grow, a caret after them.
    var writing = false
    /// The question, when it isn't already the line; a step's ask.
    var question: String?
    var options: [String] = []
    var form: [Question] = []
    var plan: [String] = []
    var permission: Permission?
    var stop: Stop?
    var prs: [PR] = []
    var diff: Diff?
    var steps: [Step] = []
    /// Its subagents, background commands and waits: a few glyphs on the line, listed in the peek and the card.
    var activity = RouterActivity()
    /// Working: the model's summaries of the run (the newest is the line's words) and the raw detail its peek lists.
    var work = RouterWork()
    /// What it was started with from here (a new thread's settings), through its first run.
    var launch: RouterLaunch?
    /// Which ask the card answers (T3's request id, the plan's run, the step's fingerprint); nil when it asks nothing.
    /// Picks and typed answers belong to one ask: a new one, or none, drops them.
    var askID: String?
    /// Its open items (Stuck, Decide, Do, Know) and the read that may change them (RouterItems.swift). The block is
    /// placed in the section of its most urgent item.
    var ledger = RouterLedger()

    var section: RouterSection {
        if let top = ledger.top, state != .stopped { return top.section }
        return switch state {
        case .needsYou, .stopped: .needsYou
        case .done: .done
        case .sent, .working: .working
        }
    }

    var isRunning: Bool { state == .working || state == .sent }

    /// Being read on the page: finished, its verdict pending.
    var reading: Bool { judging && state == .done }

    /// Every option of the card, numbered through: a form's questions one after the other.
    var numbered: [(question: Int, label: String)] {
        if !form.isEmpty { return form.enumerated().flatMap { q, question in question.options.map { (q, $0) } } }
        return options.map { (0, $0) }
    }
}

extension RouterThread {
    /// A state's mark and colour (1.1): the symbol (nil: the working dots), its tint, and whether the name sits on a ground
    /// of that tint (it asks something of you, or is worth a look).
    struct Look: Equatable {
        var symbol: String?
        var tint: Color
        var ground: Bool
        var label: String
    }

    var look: Look {
        // One open item: the line is the item.
        if let item = ledger.single { return item.look }
        return switch state {
        case .needsYou(.question), .needsYou(.form):
            Look(symbol: "questionmark.circle.fill", tint: CDS.Text.warning, ground: true, label: "Asks you")
        case .needsYou(.plan): Look(symbol: "list.bullet.clipboard.fill", tint: CDS.Text.warning, ground: true, label: "Plan to approve")
        case .needsYou(.permission): Look(symbol: "lock.fill", tint: CDS.Text.warning, ground: true, label: "Waits for a permission")
        case .stopped: Look(symbol: "exclamationmark.triangle.fill", tint: CDS.Text.danger, ground: true, label: "Stopped")
        case .sent: Look(symbol: "arrow.up.circle.fill", tint: CDS.Text.accent, ground: false, label: "Sent")
        case .working: Look(symbol: nil, tint: CDS.Text.muted, ground: false, label: "Working")
        // Being read: no check yet, it isn't known to be done with you.
        case .done where judging: Look(symbol: "circle.dashed", tint: CDS.Text.muted, ground: false, label: "Being read")
        case .done: Look(symbol: "checkmark.circle.fill", tint: CDS.Text.accent, ground: worth == .look, label: "Done")
        }
    }

    /// The sentence's colour once settled.
    var sentenceTint: Color { isRunning && ledger.single == nil ? CDS.Text.muted : CDS.Text.secondary }
}

/// A thread that finished more than a day ago and was not settled: no line of its own, one of the housekeeping line's.
struct RouterOlder: Identifiable, Equatable {
    let id: String
    var name: String
    var project: String?
    var since: Date
}

/// A send that didn't go: one line by the composer until handled.
struct RouterFailure: Identifiable, Equatable {
    let id: Int
    var thread: String
    var words: String
    var reason: String
    /// What it was: your words, picked options, or Continue on a Stopped card.
    var kind: RouterOutgoing.Kind = .words
    /// T3 was away: the reason is said only while it still is.
    var offline = false

    /// Continue on a Stopped card, not words you typed.
    var continuing: Bool { kind == .continuing }
}

/// What can be pointed at on the page: the real pointer's hover and clicks and the demo's drawn pointer go through the
/// same ones.
enum RouterHit: Hashable {
    case row(String), name(String), pill(String)
    /// The line's activity glyphs: the pointer on them shows their peek.
    case activity(String)
    case project(String?), state(RouterSection), clear
    case header(RouterSection)
    case option(String, Int)
    case footer(String, RouterFooterAct)
    case longText(String)
    case snoozeChoice(Int)
    case housekeeping, housekeepingWords, settleAll
    case cancelQueued(String)
    case place(Int), places, placeChoice(Int)
    case launch(RouterLaunchField), launchChoice(RouterLaunchField, Int)
    case failureEdit(Int), failureAgain(Int)
    case revert, toast
    case clearFilter
    case prBadge(String, Int)
    /// A link found in an item's quote (its card's quiet buttons): the item's key, the link's place.
    case link(String, Int)
    /// The quiet Done at an item row's end, on hover: the item's key.
    case itemDone(String)
}

enum RouterFooterAct: Hashable {
    case snooze, settle, open, stop, rerun

    /// It takes its line off the page: disarmed under a pointer that hasn't moved since it arrived there.
    var removes: Bool { self == .snooze || self == .settle }
}

/// Where a draft goes.
enum RouterPlace: Equatable {
    case thread(String)
    case newThread(project: String)
    /// The Router answers itself.
    case here
}

/// The Router's read of a draft: sure (one place), or its guess first and alternatives.
struct RouterRead: Equatable {
    var draft: String
    var places: [RouterPlace]
    var sure: Bool
    /// A new thread's first name, when the read strips an address off the words.
    var name: String?
}
