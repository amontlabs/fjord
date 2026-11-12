import AppKit
import Carbon

// Router v2's keyboard map (docs/design/router-v2/DESIGN.md 5), AZERTY-safe: digits and ⌘digits are read by key
// position, ⌘-letter chords by character, and no bare letter does anything but type. A new thread's settings are reached
// with Tab and changed with the arrows. Real keys reach `key(_:model:)`
// from the window's monitor; the demo's script calls `handle` with the same keys.

/// A key press, as the map reads it.
struct RouterV2Key {
    var code: Int
    var flags: NSEvent.ModifierFlags = []
    /// The character the key gives, without its modifiers.
    var characters: String?
    var isRepeat = false
}

@MainActor
enum RouterV2Keys {
    /// Whether the key was handled.
    static func key(_ event: NSEvent, model: RouterV2Model) -> Bool {
        let responder = event.window?.firstResponder
        // An input method composing: its keys are its own.
        if (responder as? NSTextView)?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        let key = RouterV2Key(code: Int(event.keyCode), flags: flags,
                              characters: flags.subtracting(.shift).isEmpty ? event.characters : event.charactersIgnoringModifiers,
                              isRepeat: event.isARepeat)
        return handle(key, model: model, inField: responder is NSText)
    }

    /// `inField`: the composer has the keyboard (its text view types what isn't handled here).
    static func handle(_ key: RouterV2Key, model: RouterV2Model, inField: Bool) -> Bool {
        let code = key.code
        let flags = key.flags
        let letter = key.characters?.lowercased()
        let isReturn = code == kVK_Return || code == kVK_ANSI_KeypadEnter
        let empty = model.draft.isEmpty
        // Your first key after your own act opened a card: its "new" dot goes now.
        model.ownerActed()

        // Filter mode (section 4): the keyboard is on the bar.
        if model.filterMode {
            if flags == .command, letter == "f" { model.enterFilterMode(); return true }
            guard flags.subtracting(.shift).isEmpty else { return false }
            switch code {
            case kVK_LeftArrow: model.moveRing(forward: false)
            case kVK_RightArrow: model.moveRing(forward: true)
            case kVK_Space: model.chooseRing()
            case kVK_Return, kVK_ANSI_KeypadEnter:
                model.chooseRing()
                model.filterMode = false
            case kVK_Delete: model.clearFilters()
            case kVK_DownArrow, kVK_Escape: model.filterMode = false
            default:
                guard let typed = key.characters, typed.count == 1, flags.subtracting(.shift).isEmpty,
                      typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else {
                    model.typeAhead = ""
                    return true
                }
                // Type-ahead while a project starts with what was typed; anything else is a message: the bar gives
                // the keyboard back and the words go to the composer, none dropped.
                if !model.typeAhead(typed) {
                    let words = model.typeAhead + typed
                    model.typeAhead = ""
                    model.filterMode = false
                    model.insert(words)
                }
            }
            return true
        }

        if flags == .command {
            switch letter {
            case "f":
                model.enterFilterMode()
                return true
            case "z":
                // The last act while it is the newest undo, else the text's.
                if inField, !empty { return false }
                guard model.canUndo else { return false }
                model.undo()
                return true
            case "o":
                guard let t = model.selectedThread else { return false }
                model.open(t.id)
                return true
            default: break
            }
            // ⌘1–3 with a draft light a place: one the row shows, or (pressed while the places are still being read)
            // the one the read is about to show. With a draft they are never the Go menu's: the same chord doesn't
            // leave the page mid-draft because a model was slow.
            if let index = RouterKeys.pickKeys.firstIndex(of: code), index < 3, model.cmdDigit(index) { return true }
        }

        // The places menu (the row's chevron, or Tab when the row asks for a place): ↑↓ Return, Tab or Esc closes.
        if model.placesMenu, flags.isEmpty {
            if code == kVK_UpArrow || code == kVK_DownArrow { model.movePlaces(down: code == kVK_DownArrow); return true }
            if isReturn { model.choosePlaces(); return true }
            if code == kVK_Tab { model.openPlaces(); return true }
        }
        // Tab goes into the row: its places when it asks for one, a new thread's settings below.
        if !empty, code == kVK_Tab, flags.isEmpty, !model.launchShown {
            switch model.destination {
            case .noGuess?, .unsure?:
                model.openPlaces()
                return true
            default: break
            }
        }

        // A new thread's settings (1.9.1): Tab moves into the row and on through its chips, ← → across them, ↑ ↓ open the
        // ringed one's menu and move through it, the value applying as they do. Any other key is the words' again.
        if model.launchShown {
            if code == kVK_Tab, flags.subtracting(.shift).isEmpty {
                model.moveLaunchFocus(forward: flags.isEmpty, leaves: true)
                return true
            }
            if model.launchFocus != nil {
                if flags.isEmpty {
                    switch code {
                    case kVK_LeftArrow, kVK_RightArrow:
                        model.moveLaunchFocus(forward: code == kVK_RightArrow, leaves: false)
                        return true
                    case kVK_UpArrow, kVK_DownArrow:
                        model.stepLaunch(down: code == kVK_DownArrow)
                        return true
                    default: break
                    }
                }
                if !isReturn, code != kVK_Escape, flags.subtracting(.shift).isEmpty { model.leaveLaunch() }
            }
            // Return on an open menu closes it.
            if isReturn, flags.isEmpty, model.launchMenu != nil {
                model.leaveLaunch()
                return true
            }
        }

        // Esc never closes the window: with nothing to step out of, a field keeps it.
        if code == kVK_Escape, flags.isEmpty { return model.escape() || inField }

        // The snooze menu at the card: ↑↓ Return, or 1–3.
        if model.snoozeMenu != nil {
            if flags.isEmpty, code == kVK_UpArrow || code == kVK_DownArrow { model.moveSnooze(down: code == kVK_DownArrow); return true }
            if flags.isEmpty, isReturn { model.chooseSnooze(); return true }
            if flags == .shift, let n = BriefKeys.digits.firstIndex(of: code), n < RouterV2.Copy.snoozeChoices.count { model.chooseSnooze(n); return true }
        }

        if isReturn {
            // ⇧Return is a new line in the composer.
            if flags == .shift { return false }
            // Never on a repeat: a held Return doesn't carry over into the card the selection moved to (the 2026-10-12
            // rule, for Return as for ⌘⌫).
            if key.isRepeat { return true }
            if flags == .option {
                if !empty { model.send(queue: true) }
                return true
            }
            if flags.isEmpty {
                model.send()
                return true
            }
        }

        // With a draft, the arrows and ⌘⌫ are the text's.
        if empty {
            if code == kVK_Delete, flags == .command {
                // Settle; never on a repeat (no carry-over from a held press).
                if !key.isRepeat { model.settleSelected() }
                return true
            }
            if code == kVK_Delete, flags == [.command, .option] {
                if !key.isRepeat { model.openSnooze() }
                return true
            }
            if code == kVK_UpArrow || code == kVK_DownArrow {
                if flags.isEmpty { model.step(down: code == kVK_DownArrow); return true }
                if flags == .option { model.stepSection(down: code == kVK_DownArrow); return true }
            }
            if let t = model.selectedThread, flags.subtracting(.shift).isEmpty {
                if flags.isEmpty, code == kVK_RightArrow || code == kVK_LeftArrow {
                    model.expand(code == kVK_RightArrow)
                    return true
                }
                if code == kVK_Tab, !t.form.isEmpty {
                    model.moveQuestion(forward: flags.isEmpty)
                    return true
                }
                // ⇧1…⇧9 pick an option of the open card, by key position, so a bare digit-row key (é, &, ") always
                // types; they are words again once a draft is started.
                if flags == .shift, let n = BriefKeys.digits.firstIndex(of: code), n < t.numbered.count {
                    model.pick(n + 1)
                    return true
                }
            }
        }

        // Any character typed with no field focused goes to the composer.
        if !inField, flags.subtracting(.shift).isEmpty, let typed = key.characters, !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            model.insert(typed)
            return true
        }
        return false
    }
}
