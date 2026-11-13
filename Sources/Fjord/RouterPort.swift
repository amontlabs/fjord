import Foundation

// Router v2's seam (docs/design/router-v2/IMPLEMENTATION.md 1.2): what a store (the real one, RouterRecords, or the
// demo's) hands the page, and what the page hands its source. The page is a pure function of one record per thread:
// the store says what a thread is, `RouterModel.apply` works out the motion. Signatures here are the contract every
// track codes against: change them only after telling every track.

/// One change from the store to the page.
enum RouterChange: Equatable {
    /// The whole record: the code state, the verdict when its fingerprint is current, the pending act. The record's
    /// `order` is ignored (the model's own); `sentence.stream` is the store's count of the model's lines for the thread
    /// (the model keeps the higher of the two).
    case upsert(RouterThread)
    /// Settled, snoozed, archived, aged out.
    case remove(String)
    /// The housekeeping line's threads, whole.
    case older([RouterOlder])
    /// The card's last lines as the agent writes them (the hot path): one field, nothing animated by the model.
    case reply(String, text: String, writing: Bool)
    /// A verdict's line as it streams (the hot path). A new `stream` starts the line, the same one grows it, an older
    /// one is late and dropped. `done`: no more words will come for it; the line's view settles it once they are drawn.
    case words(String, stream: Int, text: String, done: Bool)
    /// The short name, once.
    case named(String, String)
    /// A draft's destination landed.
    case read(RouterRead)
    /// A send didn't go: the line returns to what it was, a failure line enters.
    case refused(String, reason: String, offline: Bool)
    /// T3 refused a settle or a snooze: the thread is back (its record says so), the toast says why, and the act has
    /// nothing left to revert.
    case actRefused(String, reason: String)
    /// An act on a thread didn't go, in the page's own words (no Revert): a queued message T3 kept.
    case note(String, words: String)
    case connection(lost: Bool)
    /// T3's defaults for a new thread and the models it offers (`server.getConfig`).
    case launch(defaults: RouterLaunch, models: [RouterLaunchModel])
    /// The first load, or what a held window morph kept: one update, nothing animated.
    case batch([RouterChange])
}

/// What Return (or Continue, or Send again) sends.
struct RouterOutgoing: Equatable {
    enum Kind: Equatable {
        /// Your words: a message, a steer, a queued message, words on a request (T3 takes them as its answer: a
        /// refusal with feedback on a permission, changes on a plan).
        case words
        /// Options picked on a T3 request (question, form, plan, permission), by question (0 for a single question)
        /// the option's number through the card (`RouterThread.numbered`), and a form's typed answers by question.
        /// `words` is what the line shows. A step's options (the model's) go as `.words`.
        case answer(picks: [Int: Int], typed: [Int: String])
        /// Continue on a Stopped card: T3's "Continue where you left off.", with the run's id when it allows.
        case continuing
    }

    var thread: String
    var words: String
    var kind: Kind
    /// The thread is running and the words steer it now (`deliveryIntent: steer`).
    var steering: Bool
    /// The thread is running and the words wait for its turn to end (⌥, or an agent that can't steer).
    var queue: Bool
    /// The read the row showed, for the decision log; nil for a picked answer or Continue.
    var read: RouterRead?
}

/// What takes the page's acts: the demo's fake T3 (RouterDemoSource), or the real one (RouterActs). The page has
/// already changed its own copy when it calls these; the store mirrors the act as a pending one and ends it on T3's
/// word (or its refusal: `.refused`). Nothing here is awaited on the way to the frame.
@MainActor protocol RouterSource: AnyObject {
    /// Reads where a draft goes; answers with `.read`. `selected`: the card open now (the prior); `mentions`: the
    /// composer's @ pills.
    func read(_ draft: String, selected: String?, mentions: [RouterMention])
    func send(_ out: RouterOutgoing)
    /// Cancel on a queued row: the words came back to the composer.
    func cancelQueued(_ thread: String)
    /// The id a new thread will have (T3's own: a lowercase UUID), so its line is there before T3 answers.
    func mintThread() -> String
    /// Starts a thread with your words and the settings the row showed.
    func start(_ thread: String, words: String, project: String, launch: RouterLaunch, read: RouterRead?)
    func stop(_ thread: String)
    /// A card opened here: T3's `thread.visit`.
    func visit(_ thread: String)
    /// Open in T3.
    func open(_ thread: String)
    /// Settle (several: Settle all); `on: false` is its Revert.
    func settle(_ threads: [String], on: Bool)
    /// Snooze until then; nil is its Revert (unsnooze).
    func snooze(_ thread: String, until: Date?)
    /// Done on one of the thread's open items; `on: false` is its Revert.
    func itemDone(_ thread: String, item: String, on: Bool)
}

extension RouterSource {
    func itemDone(_ thread: String, item: String, on: Bool) {}
}
