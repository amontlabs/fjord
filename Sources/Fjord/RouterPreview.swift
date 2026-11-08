import Foundation
import Observation

// Where the draft will go, shown while you type (E5 "E", J1 §3 "the ghost chip"): after a 600 ms pause in typing and at least
// 12 characters, E5's fused path (`JevPath`) reads the draft. When its pick is an idle thread at P ≥ 0.90, the composer shows
// that thread in a chip and the brief marks it; below that nothing shows (E5: under 0.90 it misled on 5-7% of drafts). A click
// opens a menu of its three likeliest places, and picking one fixes where the message goes; Esc (or the chip's ×) waves it off
// for this draft, and the message then never goes there without an ask. Sending the same words on the same board reuses the
// answer: the decider asks Jev nothing again. A keystroke cancels the read under way; typing never waits on it. In shadow
// (`Store.jevSends` off) the chip still shows: at 0.90 it never disagreed with the final place on the 182 moments, and a
// decision elsewhere is logged as a preview miss.

@Observable @MainActor
final class RouterPreview {
    /// The place shown for the draft (its words may be a few keystrokes old until the next read lands).
    private(set) var shown: JevPath.Shown?
    /// The chip's menu is open.
    var menuOpen = false
    /// A place picked from the menu: where the message goes (`RouterContext.target`), and its words for the chip.
    private(set) var pinned: String?
    private(set) var pinnedTitle: String?
    /// The place waved off for this draft: not shown again, and the message doesn't go there unasked.
    private(set) var dismissed: String?

    /// How long typing pauses before the draft is read, and the fewest characters worth reading.
    @ObservationIgnored var delay: Duration = .milliseconds(600)
    static let minLength = 12
    /// How a draft is read: the fused path on the board now (tests stand in). Nil when there is no Jev.
    @ObservationIgnored var read: (@MainActor (_ text: String, _ tagged: String?) async -> JevPath.Result?)?
    /// Whether a draft may be read now (the Router on, a key for Jev, not a demo); tests stand in.
    @ObservationIgnored var allowed: () -> Bool = { true }
    /// The last answer, for its words: what a send of those very words reuses, shown or not.
    @ObservationIgnored private(set) var last: (text: String, result: JevPath.Result)?
    /// The preview a menu pick replaced: still logged with the send.
    @ObservationIgnored private var pinnedOver: JevPath.Shown?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The words a read is waiting or under way for.
    @ObservationIgnored private(set) var asking: String?
    /// Reads started (tests).
    @ObservationIgnored private(set) var reads = 0
    /// A shot put what is shown: nothing reads the draft, so it stays.
    @ObservationIgnored private var previewing = false

    /// The thread the brief marks: the one shown or the one picked.
    var markedThread: String? {
        (pinned ?? shown?.target).flatMap(RouteTarget.init)?.threadID
    }

    /// The draft (as it will be sent) or what fixes its target changed. Nothing is read when the draft is short, or when a
    /// reply, a tagged thread or a picked place already says where it goes. A read for other words is cancelled at once;
    /// only an answer for the draft as it is when it lands is shown.
    func update(text: String, context: RouterContext, tagged: String? = nil, store: Store) {
        if previewing { return }
        let fixed = RouterDispatcher.plan(text: text, context: context, store: store) != .decide
        guard allowed(), read != nil, !fixed, text.count >= Self.minLength else {
            cancel()
            if text.isEmpty {
                reset()
            } else if fixed || text.count < Self.minLength {
                shown = nil
                menuOpen = false
            }
            return
        }
        // Shown, or being read, for these very words: nothing to do.
        if shown?.text == text || asking == text { return }
        task?.cancel()
        asking = text
        reads += 1
        let delay = delay
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let read = self?.read else { return }
            let result = await read(text, tagged)
            guard !Task.isCancelled, let self, self.asking == text else { return }
            self.asking = nil
            self.task = nil
            self.apply(result, text: text, store: store)
        }
    }

    private func apply(_ result: JevPath.Result?, text: String, store: Store) {
        if let result { last = (text, result) }
        guard let result, let row = result.preview, row.place.targetID != dismissed,
              store.routerDispatcher.eligible(row.place.targetID, store: store) else {
            shown = nil
            menuOpen = false
            return
        }
        shown = JevPath.Shown(text: text, target: row.place.targetID, p: row.p, result: result)
    }

    /// What a send of `text` carries: the place shown (or the one a pick replaced), and the answer to reuse when it was for
    /// these very words.
    func carried(for text: String) -> (shown: JevPath.Shown?, reuse: JevPath.Result?) {
        (shown ?? pinnedOver, last?.text == text ? last?.result : nil)
    }

    /// The menu's places: the three likeliest, best first, that can still be sent to.
    func menu(store: Store) -> [RouterAskBack.Option] {
        guard let shown else { return [] }
        let dispatcher = store.routerDispatcher
        return shown.result.topPlaces.compactMap { dispatcher.option($0.targetID, store: store) }
    }

    /// A place picked from the menu: the message goes there (as a tag would send it), and the chip says so.
    func pick(_ target: String, store: Store) {
        guard let option = store.routerDispatcher.option(target, store: store) else { return }
        pinnedOver = shown
        pinned = target
        pinnedTitle = option.title
        shown = nil
        menuOpen = false
        cancel()
    }

    /// The picked place taken off: the draft is read again.
    func unpin() {
        pinned = nil
        pinnedTitle = nil
        pinnedOver = nil
    }

    /// Esc, or the chip's ×: the place shown goes and stays away for this draft.
    func dismiss() {
        guard let shown else { return }
        dismissed = shown.target
        self.shown = nil
        menuOpen = false
    }

    /// Sent or cleared: everything starts over.
    func reset() {
        cancel()
        shown = nil
        menuOpen = false
        pinned = nil
        pinnedTitle = nil
        pinnedOver = nil
        dismissed = nil
        last = nil
        previewing = false
    }

    private func cancel() {
        task?.cancel()
        task = nil
        asking = nil
    }

    /// A shot: a place shown with nothing behind it.
    func show(_ shown: JevPath.Shown) {
        self.shown = shown
        previewing = true
    }
}

extension Store {
    /// The fused path on a draft, on the board as it is now (nothing waited for): nil without Jev.
    func readDraft(_ text: String, tagged: String?) async -> JevPath.Result? {
        guard let jev = jevAsker(.routing, base: routerDispatcher.asker) else { return nil }
        let board = await deciderBoardWithReads()
        let request = JevPath.request(text, board, tagged: tagged)
        return await JevPath.run(request, message: text, jev: jev)
    }

    /// Whether the composer may read drafts now: the Router on, Jev reachable, and a real session (a demo reads nothing).
    var previewsDrafts: Bool { routerOn && !routerIsPretend && jevAsker(.routing, base: routerDispatcher.asker) != nil }
}

extension RouterModel {
    /// The draft changed: the preview follows it.
    func previewDraft(store: Store) {
        let sent = sentDraft(store)
        let context = context(store, sent: sent)
        let tagged = RouterPointers.context(sent.mentions, store: store)
        store.routerPreview.update(text: sent.text, context: context, tagged: tagged, store: store)
    }
}
