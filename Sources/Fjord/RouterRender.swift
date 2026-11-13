import AppKit
import SwiftUI

// What the Router v2 page's views read, so that a change redraws only what it changes (IMPLEMENTATION.md 2.2): one
// observable box per thread (its record without the fields that stream, which are boxes of their own, and the flags the
// owner's pointer and keys set on it), one per thing that can be pointed at (hot, pressed), the list's stored layout and
// counts, one minute clock for every age, and the turn's end, where streamed words and replies are applied once and the
// flags read from the draft are set. The model keeps them in step with its records (RouterModel.swift); no view reads
// the records, the selection or the pointer directly.

/// One thread's line, as its views read it.
@MainActor @Observable
final class RouterLineBox {
    let id: String
    /// The record, with its sentence, last lines and writing blanked: those change on their own (`sentence`, `lastLines`,
    /// `writing`), so a streamed word or a growing reply doesn't redraw the line or the card around it.
    private(set) var head: RouterThread
    private(set) var sentence: RouterThread.Sentence
    /// The sentence's identity: a new one when the words are other words (a new verdict, the code's line), not when they
    /// grow (`.words` of the same stream) or settle.
    private(set) var sentenceID = 0
    /// The model's words of this stream are all there (`.words(done:)`): once drawn, the line settles.
    var complete = true
    private(set) var lastLines: String
    private(set) var writing: Bool
    /// The card has the agent's words (or is about to): its last lines are shown.
    private(set) var talking: Bool

    /// The owner's flags on this line: its card is open, it is changing section, the draft goes to it.
    var selected = false
    var moving = false
    var marked = false
    /// Its card has a body: from its opening until its closing roll has ended.
    var built = false
    /// In a block: the item whose card is open (nil: the header's). Kept once the card shuts, so the rows split where they
    /// were while it rolls shut and after (`RouterBlockLayout.cut`); the next selection sets it again.
    var item: String?
    /// Two or more open items: a header and a row per item (`RouterLedger.block`). Stored, so what only needs to know reads
    /// this and not the record.
    private(set) var block: Bool
    /// The line's slot view, for the block's rows under its card, on a layer of their own (`RouterLineSlotView.placeTail`).
    @ObservationIgnored weak var slot: RouterLineSlotView?
    /// A block's rows under the open card, as laid out (0 when it isn't a block).
    var tailHeight: CGFloat = 0
    /// What the line's height follows besides those flags, for the list's slot (`RouterHostedLine`): words queued
    /// under it, and its card's own height as laid out.
    private(set) var queued: Bool
    var cardHeight: CGFloat = 0
    /// Its row's and its queued words' heights as laid out (0 before the line is first laid out, or with none queued).
    var rowHeight: CGFloat = 0
    var queuedHeight: CGFloat = 0

    /// The whole record as last taken; `revision` changes with it, for what reads the whole record (`model.thread(id)`).
    @ObservationIgnored private(set) var record: RouterThread
    private(set) var revision = 0

    init(_ thread: RouterThread) {
        id = thread.id
        record = thread
        head = Self.head(thread)
        sentence = thread.sentence
        lastLines = thread.lastLines
        writing = thread.writing
        talking = !thread.lastLines.isEmpty || thread.writing
        queued = thread.queued != nil
        block = thread.ledger.block
    }

    private static let blank = RouterThread.Sentence(text: "")

    private static func head(_ t: RouterThread) -> RouterThread {
        var head = t
        head.sentence = blank
        head.lastLines = ""
        head.writing = false
        return head
    }

    /// Its thread left the page.
    func left() { revision &+= 1 }

    /// Takes a record: only the fields that changed are written, so only their readers redraw. True when its place on the
    /// page may have changed (its section, its order, its project).
    @discardableResult func take(_ t: RouterThread) -> Bool {
        let old = record
        guard t != old else { return false }
        record = t
        revision &+= 1
        let head = Self.head(t)
        if head != self.head { self.head = head }
        if t.sentence != sentence {
            let s = sentence
            // Words of the same stream growing, or settling once drawn, are the same line of words.
            let grows = t.sentence.stream == s.stream && t.sentence.text.hasPrefix(s.text) && s.phase == .streaming
                && t.sentence.phase != .reassessing && t.sentence.mono == s.mono
            let settles = t.sentence.stream == s.stream && t.sentence.text == s.text
            if !grows, !settles { sentenceID &+= 1 }
            sentence = t.sentence
        }
        if t.lastLines != lastLines { lastLines = t.lastLines }
        if t.writing != writing { writing = t.writing }
        let talks = !t.lastLines.isEmpty || t.writing
        if talks != talking { talking = talks }
        if (t.queued != nil) != queued { queued = t.queued != nil }
        if t.ledger.block != block { block = t.ledger.block }
        return RouterModel.OrderKey(old) != RouterModel.OrderKey(t)
    }
}

/// A thing that can be pointed at: whether the pointer is on it, whether it is pressed, whether it is selected (the
/// housekeeping line).
@MainActor @Observable
final class RouterHitBox {
    var hot = false
    var pressed = false
    var selected = false

    init(hot: Bool = false, pressed: Bool = false, selected: Bool = false) {
        self.hot = hot
        self.pressed = pressed
        self.selected = selected
    }
}

/// A row of the page as the list lays it out: its id and its kind, a line by its id only. Equal as long as nothing on
/// the page moves, so the list's body runs only when the order (or a header's count) changes.
struct RouterSlot: Identifiable, Equatable {
    enum Kind: Equatable {
        case header(RouterSection, Int)
        case sentence(String, clear: Bool)
        case reading(Int)
        case line(String)
        case housekeeping(Int)
    }
    var id: String
    var kind: Kind
}

/// The counts the filter bar, the headers and the badge show, stored with the layout.
struct RouterTally: Equatable {
    /// Every line, by section.
    var all: [RouterSection: Int] = [:]
    /// Each project's lines, by section.
    var byProject: [String: [RouterSection: Int]] = [:]
    /// Running threads shown in another section (with items open), by project ("" for none): the Working header's faint
    /// count, so the counts add up.
    var runningElsewhere: [String: Int] = [:]
    /// The project's lines being read (no state yet; "" for no project).
    var reading: [String: Int] = [:]
    /// The projects with a line or an older thread, alphabetical.
    var projects: [String] = []

    func reading(project: String?) -> Int {
        project.map { reading[$0] ?? 0 } ?? reading.values.reduce(0, +)
    }

    func count(project: String?, section: RouterSection?) -> Int {
        let counts = project.map { byProject[$0] ?? [:] } ?? all
        if let section { return counts[section] ?? 0 }
        return counts.values.reduce(0, +)
    }
}

/// The ages' clock: one for the page, ticking on the minute the page was made on, stopped while the window is away.
@MainActor @Observable
final class RouterClock {
    private(set) var minute = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let from: Date

    init(from: Date) { self.from = from }

    func start() {
        guard timer == nil else { return }
        tick()
        let next = from.addingTimeInterval((Date().timeIntervalSince(from) / 60).rounded(.down) * 60 + 60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Int(Date().timeIntervalSince(from) / 60)
        if now != minute { minute = now }
    }
}

/// The end of the main loop's turn: work kept for it runs once, before the turn's changes are drawn (a `beforeWaiting`
/// observer ahead of Core Animation's commit), then the observer goes. Nothing runs while nothing is kept.
@MainActor
final class RouterTurn {
    private var observer: CFRunLoopObserver?
    private let work: () -> Void

    init(_ work: @escaping () -> Void) { self.work = work }

    func schedule() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.observer = nil
                self.work()
            }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Runs what is kept now (a test, or a change that must come after it).
    func runNow() {
        guard let observer else { return }
        CFRunLoopObserverInvalidate(observer)
        self.observer = nil
        work()
    }

    deinit {
        if let observer { CFRunLoopObserverInvalidate(observer) }
    }
}

/// Body evaluations by component, counted under test only, per page (the model that drew them): the render tests read
/// them (RouterRenderTests), and other suites hosting a page side by side don't add to their counts.
@MainActor
enum RouterBodies {
    private static var pages: [ObjectIdentifier: [String: Int]] = [:]

    /// Counts one evaluation of `name` on `model`'s page, and of `name:id` when it is one thread's.
    static func count(_ name: String, _ id: String? = nil, of model: RouterModel) {
        guard UnderTest.isRunning else { return }
        let page = ObjectIdentifier(model)
        pages[page, default: [:]][name, default: 0] += 1
        if let id { pages[page, default: [:]][name + ":" + id, default: 0] += 1 }
    }

    static func reset(_ model: RouterModel) { pages[ObjectIdentifier(model)] = nil }
    static func counts(_ model: RouterModel) -> [String: Int] { pages[ObjectIdentifier(model)] ?? [:] }
    static subscript(_ model: RouterModel, _ name: String) -> Int { counts(model)[name] ?? 0 }
    static subscript(_ model: RouterModel, _ name: String, _ id: String) -> Int { counts(model)[name + ":" + id] ?? 0 }
}
