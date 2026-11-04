import AppKit
import Carbon
import Foundation

/// The Router's keys in the app window. In the composer: Return sends, ⇧Return starts a new line, ↑↓ pick a card while it is empty;
/// with @ suggestions showing, ↑↓ walk them and Return or Tab picks one; Backspace at the very start takes the last chip off.
/// Elsewhere: ↑↓ pick a card, Return replies to it, and typing goes to the composer; Space is no key of the Router's (a card
/// leaves only by its Archive button). The cards are walked in the order the page shows them (`RouterModel.cards`). Esc is
/// first the Back of a plan in revise mode (its feedback field showing), then dismisses the suggestions, then Jev's pick of a
/// target, then the pinned target, then the search, then (on the Brief) the card open under a paragraph with its reply,
/// then the reply chip, then (on the canvas) closes the history's panel,
/// then is the Revise… of the plan shown in full (on the canvas, not again once Back left it), then (on the canvas) folds
/// the card open on it and clears its filter. It never closes the window: with nothing left to step out of, it goes on to
/// what has the keyboard. On the Brief, the pointer on a highlight, the inbox's shortcuts act on its session
/// (`DigestAction`). ⌘F puts the keyboard in the search field (RouterSearch.swift), where ↑↓ walk what it lists, Return
/// replies to the pick and Esc ends the search first; typing elsewhere still goes to the composer.
@MainActor
final class RouterKeys {
    let store: Store
    let model: RouterModel
    /// Opens the palette (⌘F).
    var openPalette: () -> Void = {}

    static let pickKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]

    init(store: Store, model: RouterModel) {
        self.store = store
        self.model = model
    }

    /// Whether the key was handled. `responder`: what has the keyboard (the window's first responder), for tests.
    func key(_ event: NSEvent, responder: NSResponder? = nil) -> Bool {
        let responder = responder ?? event.window?.firstResponder
        // An input method composing: its keys are its own.
        if (responder as? NSTextView)?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        let code = Int(event.keyCode)
        // The @ suggestions are the caret's: where it is now decides what the keys do.
        if model.composerFocused, let editor = responder as? NSTextView { model.followCaret(editor) }
        // ⌘1–⌘4 pick that button on the newest "Where should this go?", wherever the keyboard is. By key position, so on
        // any layout (on AZERTY, the & é " ' keys).
        if flags == .command, let index = Self.pickKeys.firstIndex(of: code), let ask = store.routerDispatcher.askBacks.last {
            let options = ask.options.filter { store.routerDispatcher.eligible($0.target, store: store) }
            guard index < options.count else { return false }
            store.routerDispatcher.pick(ask.id, target: options[index].target)
            return true
        }
        // ⌘F: the palette opens (by key position, as the inbox's).
        if flags == .command, code == kVK_ANSI_F {
            openPalette()
            return true
        }
        if code == kVK_Escape, flags.isEmpty {
            let plan = model.expandedPlan(store)
            // In the search field: the search ends, its words and the field's focus, as the inbox's does.
            if model.search.focused {
                if responder is NSText { event.window?.makeFirstResponder(nil) }
                model.endSearch()
            }
            else if let revising = model.revisingPlan, revising == plan?.id {
                model.revisingPlan = nil
                if model.layout == .canvas { model.canvas.backedOutOf = revising }
            }
            // The suggestions shown (an @ word that names nothing shows none, and Esc goes on to what is there).
            else if !model.suggestions(store).isEmpty { model.dismissMention() }
            // A proposed project is dropped and its message is yours again.
            else if model.dropProposal(store: store) {}
            // A search on, the field left: it ends before the pick's reply goes.
            else if !model.search.query.isEmpty { model.endSearch() }
            // On the Brief, the card open under a paragraph closes, with its reply.
            else if model.layout == .brief, model.digest.open != nil { model.closeDigestCard(store: store) }
            else if model.replyTo != nil { model.replyTo = nil }
            // On the canvas, the history's panel over it closes.
            else if model.layout == .canvas, model.pane == .history { model.show(.now) }
            else if let plan, model.layout != .canvas || model.canvas.backedOutOf != plan.id { model.revisingPlan = plan.id }
            // On the canvas: the card open on it folds; then the solos and mutes go.
            else if model.layout == .canvas, model.foldCanvasNode(store) {}
            else if !model.filter.isClear { model.filter.clear() }
            // Nothing to step out of: a field keeps it (an NSTextView's own Esc would offer completions), anything else
            // gets it.
            else { return responder is NSText }
            return true
        }
        let editing = responder is NSText
        let isReturn = code == kVK_Return || code == kVK_ANSI_KeypadEnter
        // The Brief: the highlight under the pointer takes the inbox's shortcuts, unless a field has words to type them
        // into (an empty composer gives them up) or a control the Tab ring is on has the keyboard.
        if model.layout == .brief, !(responder is NSControl), !editing || (model.composerFocused && model.draft.isEmpty),
           let action = model.digestAction(Shortcut(event), store: store) {
            action.perform(model: model, store: store)
            return true
        }
        if editing {
            // The search field: ↑↓ walk what it lists, Return replies to the pick; the rest is the field's own.
            if model.search.focused {
                guard flags.isEmpty else { return false }
                if code == kVK_UpArrow || code == kVK_DownArrow {
                    model.move(down: code == kVK_DownArrow, store: store)
                    return true
                }
                guard isReturn else { return false }
                model.reconcile(store: store)
                guard let id = model.selection, model.cards(store).contains(where: { $0.id == id }) else { return false }
                model.reply(to: id, store: store)
                return true
            }
            guard model.composerFocused else { return false }
            let suggestions = model.suggestions(store)
            if !suggestions.isEmpty, flags.isEmpty {
                if code == kVK_UpArrow || code == kVK_DownArrow {
                    model.moveMention(down: code == kVK_DownArrow, count: suggestions.count)
                    return true
                }
                if isReturn || code == kVK_Tab {
                    model.pickMention(suggestions[min(model.mentionIndex, suggestions.count - 1)])
                    return true
                }
            }
            if code == kVK_Delete, flags.isEmpty, (responder as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 0) {
                return model.removeLastChip()
            }
            if isReturn, flags == .shift {
                (responder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if isReturn, flags.isEmpty {
                // Nothing typed and a grant waiting: Return allows it.
                // A proposed project: your words revise it, nothing typed creates it.
                if model.answerProposal(store: store) { return true }
                if model.draft.isEmpty, store.routerCourier.allowNewest() { return true }
                model.send(store: store)
                return true
            }
            if (code == kVK_UpArrow || code == kVK_DownArrow), flags.isEmpty, model.draft.isEmpty {
                model.move(down: code == kVK_DownArrow, store: store)
                return true
            }
            return false
        }
        // A button or chip the Tab ring is on takes Return and Space itself.
        if flags.isEmpty, responder is NSControl, [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space].contains(code) { return false }
        if flags.isEmpty {
            if code == kVK_UpArrow || code == kVK_DownArrow {
                model.move(down: code == kVK_DownArrow, store: store)
                return true
            }
            // Space archives nothing: it took the picked card, and the pick moving on to the next, a second press took one
            // you hadn't seen. It goes on to whatever has the keyboard, and starts no reply with a blank.
            if code == kVK_Space { return false }
            if isReturn {
                // Only a card that is listed: the pick follows the list first.
                model.reconcile(store: store)
                if let id = model.selection, model.cards(store).contains(where: { $0.id == id }) {
                    model.reply(to: id, store: store)
                } else {
                    model.reply()
                }
                return true
            }
        }
        // Typing anywhere writes to the Router: the key is handed to the composer, which types it itself.
        if model.canSend(store), flags.subtracting(.shift).isEmpty, let typed = event.characters, !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            model.pendingKeys.append(event)
            model.reply()
            return true
        }
        return false
    }
}

/// A banner for each new card that needs you and can't wait (a question, a plan, an OK asked, a stuck turn, a turn asking you
/// something soon: RouterAttention.swift decides) and for a waiting session ready to continue, unless notifications are off
/// or snoozed or the app window is open on the Router. Clicking it opens the window on that card.
@MainActor
enum RouterBanners {
    /// Banner ids: the card's, after this.
    static let prefix = "router#"

    /// Hooks the store's new cards to banners, and banner clicks to `open`.
    static func attach(store: Store, windowIsKey: @escaping () -> Bool, open: @escaping (String) -> Void) {
        store.onNewRouterCards = { cards in post(cards, store: store, windowIsKey: windowIsKey()) }
        store.routerTriager.onReady = { card in postReady(card, store: store, windowIsKey: windowIsKey()) }
        store.routerAttention.onBack = { strip in postBack(strip, store: store, windowIsKey: windowIsKey()) }
        store.routerAttention.start { [weak store] in store?.routerShownCards ?? [] }
        let previous = store.notifier.onOpen
        store.notifier.onOpen = { id, url in
            if id.hasPrefix(prefix) { open(String(id.dropFirst(prefix.count))) } else { previous?(id, url) }
        }
    }

    static func post(_ cards: [RouterCard], store: Store, windowIsKey: Bool) {
        // What can wait waits (RouterAttention.swift).
        // Turned off meanwhile (a triage that came back after, say): nothing.
        guard store.router.enabled else { return }
        let now = store.routerAttention.admit(cards)
        guard !windowIsKey, store.settings.notifications, !store.isSnoozed else { return }
        for card in now {
            let project = store.routerProject(card).name
            // A turn that asks you says what, as its card lists it.
            let asked = card.asks?.map(\.question) ?? []
            store.notifier.post(id: prefix + card.id, title: card.title, subtitle: "\(card.kind.label) · \(project)",
                                body: asked.isEmpty ? card.text : asked.joined(separator: "\n"), quiet: false)
            store.routerAttention.posted(card.id)
        }
    }

    /// A waiting session's wait is over: it is ready to continue.
    static func postReady(_ card: RouterCard, store: Store, windowIsKey: Bool) {
        guard store.router.enabled, store.routerAttention.admitReady(card), !windowIsKey, store.settings.notifications, !store.isSnoozed, let triage = card.triage,
              let message = RouterWaits.message(triage) else { return }
        store.notifier.post(id: prefix + card.id, title: card.title, subtitle: "Ready to continue · \(store.routerProject(card).name)",
                            body: message, quiet: false)
    }

    /// Back after being away: one banner for what came meanwhile, opening on the most urgent of it.
    /// With the Router off, its cards are left out: only what came in the inbox is said.
    static func postBack(_ strip: AwayStrip, store: Store, windowIsKey: Bool) {
        let cards = store.router.enabled ? store.routerShownCards : []
        // With Triage off, what the inbox held back isn't said either.
        var strip = strip
        if !store.triageOn { strip.inbox = 0 }
        store.routerAttention.reported(strip.listed(cards))
        guard !windowIsKey, store.settings.notifications, !store.isSnoozed, let line = strip.line(cards) else { return }
        let first = strip.listed(cards).first
        store.notifier.post(id: first.map { prefix + $0.id } ?? Notifier.summaryPrefix + UUID().uuidString,
                            title: "While you were away", subtitle: "", body: line, quiet: false)
    }
}
