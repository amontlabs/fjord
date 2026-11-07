import AppKit
import Carbon
import Foundation

/// The Router's keys in the app window. The brief's own (`BriefKeys`), while an entry is focused and the composer is empty:
/// Return and Esc; ↑↓ walk its entries and put the keyboard on the brief, where 1–9, O, A and R are its keys too (in the
/// composer, letters and digits are your words). In the composer: Return sends (steering a thread that runs), ⌥Return sends to wait for the turn under way, ⇧Return starts a new line; with @
/// suggestions showing, ↑↓ walk them and Return or Tab picks one; Backspace at the very start takes the reply chip off.
/// ⌘1–⌘4 pick a place on "Where should this go?". Esc dismisses the suggestions, then drops a proposed project, then the reply
/// chip; it never closes the window: with nothing left to step out of, it goes on to what has the keyboard. ⌘F opens the
/// palette. Typing elsewhere goes to the composer.
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
        // The brief (RouterBriefs.swift): with an entry focused and the composer empty, Return and Esc are its own; ↑↓ walk
        // its entries, the keyboard leaving the composer for the brief. Only there are 1–9 (by key position), O, A and R its
        // keys: in the composer they are your words. A field other than the composer keeps its keys.
        let briefs = store.routerBriefs
        let inComposer = responder is NSText && model.composerFocused
        let fieldOtherThanComposer = responder is NSText && !model.composerFocused
        if !fieldOtherThanComposer, !(responder is NSControl), model.draft.isEmpty {
            let walk = flags.isEmpty && (code == kVK_UpArrow || code == kVK_DownArrow) && !briefs.page().entries.isEmpty
            if walk, inComposer, model.suggestions(store).isEmpty {
                // Walking the brief: the keyboard is on it now, its letter keys with it.
                (responder as? NSView)?.window?.makeFirstResponder(nil)
                model.composerFocused = false
                briefs.move(down: code == kVK_DownArrow)
                return true
            }
            if let action = BriefKeys.action(code: code, characters: event.charactersIgnoringModifiers, flags: flags,
                                             focused: briefs.focused != nil || briefs.hoveredTarget != nil, composerEmpty: true, inComposer: inComposer),
               briefs.key(action, model: model, store: store) { return true }
            if briefs.focused == nil, walk, !inComposer {
                briefs.move(down: code == kVK_DownArrow)
                return true
            }
        }
        // ⌘F: the palette opens (by key position, as the inbox's).
        if flags == .command, code == kVK_ANSI_F {
            openPalette()
            return true
        }
        if code == kVK_Escape, flags.isEmpty {
            // The suggestions shown (an @ word that names nothing shows none, and Esc goes on to what is there).
            if !model.suggestions(store).isEmpty { model.dismissMention() }
            else if briefs.focused != nil { briefs.focus(nil) }
            // Nothing to step out of: a field keeps it (an NSTextView's own Esc would offer completions), anything else
            // gets it.
            else { return responder is NSText }
            return true
        }
        let isReturn = code == kVK_Return || code == kVK_ANSI_KeypadEnter
        if responder is NSText {
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
                return model.removeLastChip(store: store)
            }
            if isReturn, flags == .shift {
                (responder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if isReturn, flags == .option {
                // ⌥Return: the words wait for the turn under way instead of steering it.
                if model.draft.isEmpty { return true }
                model.send(store: store, queue: true)
                return true
            }
            if isReturn, flags.isEmpty {
                // Nothing typed and a "Where should this go?" up: Return confirms the decider's guess (the button in the primary
                // colour); the others are ⌘1–⌘4. No modal: the ask sits over the composer while you decide.
                if model.draft.isEmpty, let ask = store.routerDispatcher.askBacks.last, let guess = ask.suggestion,
                   store.routerDispatcher.pick(ask.id, target: guess) { return true }
                // Nothing typed and a grant waiting: Return allows it.
                if model.draft.isEmpty, store.routerCourier.allowNewest() { return true }
                model.send(store: store)
                return true
            }
            return false
        }
        // A button or chip the Tab ring is on takes Return and Space itself.
        if flags.isEmpty, responder is NSControl, [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space].contains(code) { return false }
        if flags.isEmpty, isReturn {
            model.reply()
            return true
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
