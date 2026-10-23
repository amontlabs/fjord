import Foundation

// What the Router asks Jev besides where a sent message goes: the same question while you type (the composer shows his
// pick). Every call goes through a `JevAsker`, so tests answer for it.

/// Typed questions about a state, all in one call (`JevClient.ask`).
typealias JevAsker = @MainActor ([String: JevClient.Question], [String: String]) async throws -> [String: JevClient.Answer]

extension JevClient {
    /// An older one-choice stand-in (`RouterTools.chooser`) as an asker: it answers the choices,
    /// one call each, and leaves every other question unanswered.
    static func asker(choosing choose: @escaping ([String], [String: String], [String: String], String) async throws -> Choice) -> JevAsker {
        { questions, state in
            var out: [String: Answer] = [:]
            for (id, question) in questions {
                guard case .choice(let options, let hints, let instructions) = question else { continue }
                out[id] = .choice(try await choose(options, hints, state, instructions))
            }
            return out
        }
    }
}

extension Store {
    /// Settings' "Let Jev read what you type": the draft goes to TypeSafe while you type (on unless turned off).
    var jevReadsDrafts: Bool { settings.jevReadsDrafts ?? true }
}

// MARK: - The target while you type

/// Jev's pick for the draft, asked once typing pauses: shown over the composer when he is sure (as the dispatcher would act
/// on it), its card or working row marked on the page. Clicking it fixes the target; Esc waves it off for this draft.
@Observable @MainActor
final class RouterLiveTarget {
    struct Prediction: Equatable {
        var target: String
        /// The chip's words ("Fix the login bug", "New session · lookout") and the tooltip's.
        var title: String
        var detail: String
        /// The draft it was made for.
        var text: String
        /// What the page marks: the card's id or the working row's.
        var mark: String?
        /// What Jev made of the draft: sent as shown, the send goes with it without asking him again.
        var found: RouterDispatcher.Classification? = nil
        /// Jev isn't sure of it (the dispatcher would ask): shown with a "?", and a send still decides as it does without it.
        var unsure = false
    }

    private(set) var prediction: Prediction?
    /// The draft divided into several places, for the words it was read for (`predictDivision`): its parts show under the
    /// composer, each place with its words, in place of the one target chip, and a send goes with them as shown.
    private(set) var division: RouterDivision?
    /// What the strip shows for each part of `division`.
    private(set) var chips: [DivisionChip] = []
    /// Jev's read divides (both compound gates up, or compound his top pick) and the divider is being asked: the strip says so.
    private(set) var dividing = false
    /// Sessions ⌘-clicked on the Brief (`session:<id>`): each gets the whole message, whatever else fixes where it goes.
    var recipients: [String] = []
    /// A target you fixed by clicking the prediction (a card's goes to `RouterModel.replyTo` instead).
    var pinned: String?
    var pinnedTitle: String?
    /// The prediction you clicked: while it is still where the draft goes, the send logs his pick as confirmed.
    var chosen: Prediction?
    /// The target you waved off for this draft: it isn't shown again, and the message doesn't go there unasked.
    private(set) var dismissed: String?

    /// What the strip shows of Jev's read: the pick's target, the parts, or the divider being asked (for the strip's fade).
    var shown: String? {
        if !chips.isEmpty { return "division \(chips.count)" }
        return dividing ? "dividing" : prediction?.target
    }

    /// The targets shown or fixed that can be gone with no card or session changing: a project, until a scan finds it gone.
    var watchedTargets: [String] {
        (pinned.map { [$0] } ?? []) + (prediction.map { [$0.target] } ?? []) + chips.map(\.target)
    }

    /// A part of the division as the strip shows it.
    struct DivisionChip: Equatable {
        var target: String
        /// The place's words ("Fix the login bug", "New session · lookout") and the tooltip's.
        var title: String
        var detail: String
        /// The part's own words.
        var words: String
        /// It needs another place's answer first: it is held until you send it.
        var waits: Bool
    }

    /// What a pick or the parts shown are for: the words as they are sent (the first line's indentation is part of them) and
    /// the projects.
    private static func key(_ exact: String, _ projects: [String]) -> String {
        ([exact] + projects).joined(separator: "\u{1}")
    }

    /// How long typing pauses before Jev is asked, and the fewest characters worth asking about.
    @ObservationIgnored var delay: Duration = .milliseconds(600)
    static let minLength = 12
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The words and projects Jev is being asked about, the draft's as they now are (nil while nothing is to be asked), and
    /// the ones the prediction shown was made for.
    @ObservationIgnored private var asking: String?
    @ObservationIgnored private var current: String?
    @ObservationIgnored private var predicted: String?
    /// A demo or a shot put what is shown there: nothing in a demo reads the draft, so it stays until the draft is sent.
    @ObservationIgnored private var previewing = false

    /// The draft (as it will be sent) changed, or what fixes its target did. Nothing is asked while a reply, a pinned target,
    /// recipients or a lone @project fixes where it goes, nor for a few characters. A pick for other words goes at once; only
    /// an answer for the draft as it is when it lands is shown. When his read divides (`Classification.divides`), the divider
    /// is asked once, after the same stillness (never per keystroke), and its parts replace the pick.
    func update(text: String, context: RouterContext, store: Store) {
        if previewing, Store.isDemo { return }
        // The words as they will be sent (an indented first line kept): what a division is for, to the character.
        let exact = RouterModel.sendable(text)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixed = pinned != nil || !recipients.isEmpty || RouterDispatcher.plan(text: text, context: context, store: store) != .classify
        guard store.routerOn, store.jevReadsDrafts, !Store.isDemo, !fixed, text.count >= Self.minLength else {
            cancel()
            clear()
            if text.isEmpty { dismissed = nil }
            return
        }
        let key = Self.key(exact, context.projects)
        current = key
        if prediction != nil || division != nil, predicted != key { clear() }
        // The pick or the parts shown are for these words: whatever was asked since is for others.
        if prediction != nil || division != nil { return cancel() }
        guard key != asking else { return }
        task?.cancel()
        dividing = false
        asking = key
        let delay = delay
        task = Task { [weak self, weak store] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let store else { return }
            let found = await store.routerDispatcher.predict(text, projects: context.projects, mentions: context.mentions)
            guard !Task.isCancelled, let self, self.current == key else { return }
            if let found, found.divides {
                self.dividing = true
                let division = await store.routerDispatcher.predictDivision(exact, found: found, projects: context.projects,
                                                                            mentions: context.mentions)
                // The draft changed, or the composer left, while the divider was read: its parts are for other words.
                guard !Task.isCancelled, self.current == key else { return }
                self.dividing = false
                if let division {
                    self.asking = nil
                    self.task = nil
                    self.division = division
                    self.chips = Self.chips(division, store: store)
                    self.predicted = key
                    return
                }
            }
            self.asking = nil
            self.task = nil
            self.prediction = found.flatMap { self.prediction(from: $0, text: text, store: store) }
            self.predicted = self.prediction == nil ? nil : key
        }
    }

    /// The prediction, if it is still for this draft and its target can still be sent to: what a click may pin.
    func valid(text: String, context: RouterContext, store: Store) -> Prediction? {
        guard let p = prediction, predicted == Self.key(RouterModel.sendable(text), context.projects), context.replyTo == nil,
              context.target == nil, p.target != dismissed, store.routerDispatcher.eligible(p.target, store: store) else { return nil }
        return p
    }

    /// The parts shown, if they are still for this draft and every place in them can still be sent to: what a send goes with.
    /// The words are the draft's as it is sent, by the exact text.
    func validDivision(text: String, context: RouterContext, store: Store) -> RouterDivision? {
        let text = RouterModel.sendable(text)
        guard let division, predicted == Self.key(text, context.projects), division.text == text,
              context.replyTo == nil, context.target == nil, context.recipients.isEmpty,
              division.parts.allSatisfy({ store.routerDispatcher.eligible($0.target, store: store) }) else { return nil }
        return division
    }

    /// Shown when Jev answered, with a "?" when he isn't sure (`unsure`: the dispatcher would ask), and not to what you waved off.
    private func prediction(from found: RouterDispatcher.Classification, text: String, store: Store) -> Prediction? {
        guard found.assisted, let top = found.top, top.target != dismissed,
              top.target != RouteLabel.compound.rawValue, store.routerDispatcher.eligible(top.target, store: store),
              let option = store.routerDispatcher.option(top.target, store: store) else { return nil }
        return Prediction(target: top.target, title: Self.title(top.target, option),
                          detail: store.routerDispatcher.describe(top.target, store: store),
                          text: text, mark: found.sure ? Self.mark(top.target, store: store) : nil, found: found, unsure: !found.sure)
    }

    /// The chip's words for a target's option: a new session's with its folder.
    static func title(_ target: String, _ option: RouterAskBack.Option) -> String {
        target.hasPrefix("new:") ? "\(option.title) · \(option.detail)" : option.title
    }

    /// The page's item for a target: the card, or the session's working row, else its open card.
    static func mark(_ target: String, store: Store) -> String? {
        if target.hasPrefix("answer:") { return String(target.dropFirst("answer:".count)) }
        guard target.hasPrefix("session:") else { return nil }
        let session = String(target.dropFirst("session:".count))
        if store.routerWorkingRows.contains(where: { $0.id == session }) { return RouterModel.workingID(session) }
        return store.routerShownOpenCards.first { $0.sessionID == session }?.id
    }

    /// Esc: the prediction goes, and stays away for this draft.
    func dismiss() {
        dismissed = prediction?.target
        clear()
    }

    /// A demo or a shot: a pick shown with nothing behind it, for its words.
    func preview(_ prediction: Prediction) {
        self.prediction = prediction
        predicted = Self.key(prediction.text, [])
        previewing = true
    }

    /// A demo or a shot: parts shown with nothing behind them, for their words.
    func preview(division: RouterDivision, store: Store) {
        self.division = division
        chips = Self.chips(division, store: store)
        predicted = Self.key(division.text, [])
        previewing = true
    }

    /// A demo or a shot: the divider being asked.
    func previewDividing() {
        dividing = true
        previewing = true
    }

    /// The strip's words for a division: each part's place, as a pick's chip names it, and its words.
    static func chips(_ division: RouterDivision, store: Store) -> [DivisionChip] {
        let dispatcher = store.routerDispatcher
        return division.parts.map { part in
            let option = dispatcher.option(part.target, store: store)
            return DivisionChip(target: part.target, title: option.map { title(part.target, $0) } ?? "a session",
                                detail: dispatcher.describe(part.target, store: store),
                                words: part.text.split(whereSeparator: \.isNewline).joined(separator: " "), waits: part.waitsFor != nil)
        }
    }

    /// The composer is gone (its window closed, the page left): nothing more is asked until it is back, and a question on
    /// its way is dropped. What you pinned or waved off stays with the draft, and so does a pick already in for it: back
    /// with the same words, it shows again (once `revalidate` has checked its target) without asking Jev again; with
    /// other words, it goes and they are asked about.
    func suspend() {
        cancel()
    }

    /// Sent or cleared: everything starts over.
    func reset() {
        cancel()
        clear()
        current = nil
        pinned = nil
        pinnedTitle = nil
        chosen = nil
        dismissed = nil
        recipients = []
        previewing = false
    }

    private func cancel() {
        task?.cancel()
        task = nil
        asking = nil
        dividing = false
    }

    /// The prediction and the parts go (they no longer hold), with nothing waved off.
    func clear() {
        prediction = nil
        if division != nil { division = nil }
        if !chips.isEmpty { chips = [] }
        predicted = nil
    }
}

extension RouterModel {
    /// What the draft goes with: the reply, the @projects, the target you pinned and the one you waved off.
    func context(_ store: Store) -> RouterContext { context(store, sent: sentDraft(store)) }

    /// The same, for the draft as it will be sent, worked out once by the caller (`sentDraft` writes every pill's name).
    func context(_ store: Store, sent: (text: String, mentions: [RouterMention])) -> RouterContext {
        let reply = replyTo.flatMap { id in store.router.cards.contains { $0.id == id } ? id : nil }
        var context = RouterContext(replyTo: reply, target: live.pinned, notTo: live.dismissed)
        context.tag(sent.mentions)
        // Jev's pick shown over the composer for the draft as it is now: sending it goes with it, as it was shown (the
        // dispatcher's copy of it may have expired, and asking again could go elsewhere).
        let shown = live.valid(text: sent.text, context: context, store: store)
        // Only a pick Jev was sure of is sent as shown; one with a "?" goes as it would without it (asking if it must).
        let sure = shown.flatMap { $0.unsure ? nil : $0 }
        context.shown = sure?.target
        context.jev = sure?.found
        // Recipients each get the whole message; the parts shown for these very words are sent as shown, asking nobody again.
        context.recipients = live.recipients
        context.division = live.validDivision(text: sent.text, context: context, store: store)
        // Jev's pick you clicked, while the draft still goes there (as the pinned target or the reply to its card).
        if let chosen = live.chosen, chosen.target == live.pinned || reply.map({ "answer:\($0)" }) == chosen.target {
            context.predicted = chosen.target
        }
        return context
    }

    /// The draft's words as they will be sent (pills written as @name): as written, the first line's indentation kept (code
    /// pasted), only blank lines before it and whitespace after the end left out.
    func plainDraft(_ store: Store) -> String { sentDraft(store).text }

    /// The draft as it will be sent, and its pills: where each "@name" is in it (character offsets) and what it points to.
    func sentDraft(_ store: Store) -> (text: String, mentions: [RouterMention]) {
        RouterPointers.message(draft: draft, pointers: pointers, name: store.pointerName)
    }

    /// `text` without the blank lines it starts with or the whitespace it ends with; the rest (the first line's indentation)
    /// as written. Empty when it is only whitespace.
    nonisolated static func sendable(_ text: String) -> String { sendableCut(text).text }

    /// `sendable`, and how many characters were cut from the start.
    nonisolated static func sendableCut(_ text: String) -> (text: String, lead: Int) {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }) else { return ("", 0) }
        let lineStart = text[..<first].lastIndex(where: \.isNewline).map(text.index(after:)) ?? text.startIndex
        var out = String(text[lineStart...])
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return (out, text.distance(from: text.startIndex, to: lineStart))
    }

    /// The draft changed: Jev's pick follows it.
    func predictTarget(store: Store) {
        // Once per keystroke: the draft as it will be sent, made once for both.
        let sent = sentDraft(store)
        live.update(text: sent.text, context: context(store, sent: sent), store: store)
    }

    /// The prediction's item changed (`from` → `to`): the page marks the new one; a mark of another (a reveal) isn't touched.
    func markPrediction(from old: String?, to new: String?) {
        if let old, highlighted == old { highlighted = nil }
        if let new { highlighted = new }
    }

    /// A session ⌘-clicked on the Brief: picked as a recipient of the draft, or taken off. Picking one ends an edit, as arming
    /// another reply does (the draft then goes to the recipients as a message of its own, not to a fork).
    func toggleRecipient(_ target: String, store: Store) {
        if let at = live.recipients.firstIndex(of: target) {
            live.recipients.remove(at: at)
        } else if store.routerDispatcher.eligible(target, store: store) {
            editing = nil
            live.recipients.append(target)
        }
        focusRequest &+= 1
    }

    /// The prediction clicked: a card's becomes the reply, anything else the pinned target.
    func pinPrediction(store: Store) {
        // Only a pick for the draft as it is, to a target still there.
        guard let p = live.valid(text: plainDraft(store), context: context(store), store: store) else {
            live.clear()
            return predictTarget(store: store)
        }
        // A target picked ends an edit: the draft goes there instead.
        editing = nil
        if p.target.hasPrefix("answer:") {
            replyTo = String(p.target.dropFirst("answer:".count))
        } else {
            live.pinned = p.target
            live.pinnedTitle = p.title
        }
        live.reset(keepingPin: true)
        live.chosen = p
        focusRequest &+= 1
    }

    /// Esc on the prediction.
    func dismissPrediction() { live.dismiss() }
}

extension RouterLiveTarget {
    /// After a pin: the prediction goes, the pin stays.
    func reset(keepingPin: Bool) {
        let (pin, title) = (pinned, pinnedTitle)
        reset()
        if keepingPin { (pinned, pinnedTitle) = (pin, title) }
    }
}

extension RouterLiveTarget {
    /// What can be routed to changed (a card addressed or superseded, a session gone, one no longer working): a pick or a pin
    /// whose target can't be sent to any more goes; a pick still good marks where its target now is on the page. Whether the
    /// pick went.
    @discardableResult
    func revalidate(store: Store) -> Bool {
        let dispatcher = store.routerDispatcher
        if let pin = pinned, !dispatcher.eligible(pin, store: store) {
            pinned = nil
            pinnedTitle = nil
            chosen = nil
        }
        recipients.removeAll { !dispatcher.eligible($0, store: store) }
        // Parts with a place gone since go (and the draft is read again); the others are named as the places are now.
        if let division {
            guard division.parts.allSatisfy({ dispatcher.eligible($0.target, store: store) }) else {
                clear()
                return true
            }
            let now = Self.chips(division, store: store)
            if now != chips { chips = now }
            return false
        }
        guard var p = prediction else { return false }
        guard p.target != dismissed, dispatcher.eligible(p.target, store: store) else {
            clear()
            return true
        }
        let before = p
        if !p.unsure { p.mark = Self.mark(p.target, store: store) }
        // Its words from the target as it is now (a session renamed while the pick was kept), without asking Jev again.
        if let option = dispatcher.option(p.target, store: store) {
            p.title = Self.title(p.target, option)
            p.detail = dispatcher.describe(p.target, store: store)
        }
        if p != before { prediction = p }
        return false
    }
}
