import Foundation

// Router v2's seam (docs/design/router-v2/IMPLEMENTATION.md 1.2): what a store (the real one, RouterRecords, or the
// demo's) hands the page, and what the page hands its source. The page is a pure function of one record per thread:
// the store says what a thread is, `RouterV2Model.apply` works out the motion. Signatures here are the contract every
// track codes against: change them only after telling every track.

/// One change from the store to the page.
enum RouterV2Change: Equatable {
    /// The whole record: the code state, the verdict when its fingerprint is current, the pending act. The record's
    /// `order` is ignored (the model's own); `sentence.stream` is the store's count of the model's lines for the thread
    /// (the model keeps the higher of the two).
    case upsert(RouterV2Thread)
    /// Settled, snoozed, archived, aged out.
    case remove(String)
    /// The housekeeping line's threads, whole.
    case older([RouterV2Older])
    /// The card's last lines as the agent writes them (the hot path): one field, nothing animated by the model.
    case reply(String, text: String, writing: Bool)
    /// A verdict's line as it streams (the hot path). A new `stream` starts the line, the same one grows it, an older
    /// one is late and dropped. `done`: no more words will come for it; the line's view settles it once they are drawn.
    case words(String, stream: Int, text: String, done: Bool)
    /// The short name, once.
    case named(String, String)
    /// A draft's destination landed.
    case read(RouterV2Read)
    /// A send didn't go: the line returns to what it was, a failure line enters.
    case refused(String, reason: String, offline: Bool)
    case connection(lost: Bool)
    /// T3's defaults for a new thread and the models it offers (`server.getConfig`).
    case launch(defaults: RouterV2Launch, models: [RouterV2LaunchModel])
    /// The first load, or what a held window morph kept: one update, nothing animated.
    case batch([RouterV2Change])
}
