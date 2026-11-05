import AppKit
import Carbon
import SwiftUI

// The inbox's keys in the app window: the arrows pick a row, the configured shortcuts act on it, typing searches, ⌘Z takes
// back an archive (or, on Inbox categories, a category edit), Esc steps out (never closing the window).

/// The search of the window's inbox: a query over every category and the archive, and the field's focus handshake with the keys.
@Observable
@MainActor
final class InboxSearch {
    /// What is typed; empty is no search.
    var query = ""
    /// Mirrors the field's focus, for the key handler.
    var focused = false
    /// Bumped to ask the field for focus.
    var focusRequest = 0
    /// The next focus is the typing's own: the caret goes after what the field holds, and the key is typed.
    var caretAtEnd = false
    /// The keys that started the search, for the field to type itself once it has the keyboard (a dead key, an input
    /// method's first key, a plain letter).
    @ObservationIgnored var pendingKeys: [NSEvent] = []

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Asks the field for the keyboard; `replaying`: the key that started it, typed into it once it has it.
    func start(replaying event: NSEvent? = nil) {
        caretAtEnd = true
        if let event { pendingKeys.append(event) }
        focusRequest &+= 1
    }

    /// With the field editor up: the caret goes after what the field holds, then the pending keys are typed into it.
    func typePendingKeys() {
        guard let editor = (pendingKeys.first?.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView,
              editor.isFieldEditor else { return }
        if caretAtEnd { editor.moveToEndOfDocument(nil) }
        caretAtEnd = false
        let keys = pendingKeys
        pendingKeys = []
        keys.forEach(editor.keyDown(with:))
    }

    func end() {
        query = ""
        focused = false
        caretAtEnd = false
        pendingKeys = []
    }
}

extension Store {
    /// What the inbox lists: the tab's entries, or with a search every entry (archived last) matching all its words.
    func inboxRows(_ tab: InboxTab, search: String = "") -> [InboxEntry] {
        let words = search.lowercased().split(separator: " ")
        guard !words.isEmpty else { return entries(in: tab) }
        let keys = inboxSearchKeys
        return entries.filter { entry in
            guard let key = keys[entry.id] else { return false }
            return words.allSatisfy { key.contains($0) }
        }
        .sorted { ($0.isDone ? 1 : 0, $1.thing.updatedAt) < ($1.isDone ? 1 : 0, $0.thing.updatedAt) }
    }
}

@MainActor
final class AppWindowKeys {
    let store: Store
    let navigator: AppNavigator
    let hub: HubState
    let search: InboxSearch
    /// "Open in Router" on a thing (its id): the window on the Router, the thing tagged in its composer. Done only while
    /// the Router is on.
    var openInRouter: (String) -> Void = { _ in }
    /// Opens the palette (⌘F, or typing: the key that started it is typed into the palette's field).
    var openPalette: (NSEvent?) -> Void = { _ in }

    init(store: Store, navigator: AppNavigator, hub: HubState, search: InboxSearch) {
        self.store = store
        self.navigator = navigator
        self.hub = hub
        self.search = search
    }

    /// The rows the arrows walk, top to bottom, as ids ("i:<entry id>").
    func targets() -> [String] {
        guard let tab = navigator.selection.tab else { return [] }
        return store.inboxRows(tab, search: search.query).map { "i:" + $0.id }
    }

    /// Whether the key was handled. `responder`: what has the keyboard (the window's first responder), for tests.
    func key(_ event: NSEvent, responder: NSResponder? = nil) -> Bool {
        let responder = responder ?? event.window?.firstResponder
        // An input method composing: its keys are its own.
        if (responder as? NSTextView)?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        let shortcut = Shortcut(event)
        let editing = responder is NSText
        let window = event.window
        // The categories keep their own history of edits, also while a field has the keyboard. (By the character, as Done's
        // undo is, so it is the Z key on any layout.)
        if navigator.selection == .categories {
            guard Self.isUndo(event, flags), let history = store.categoryHistory, !history.drafting else { return false }
            if editing { window?.makeFirstResponder(nil) }
            if flags == .command { history.undo(store) } else { history.redo(store) }
            return true
        }
        // The snippets too.
        if navigator.selection == .snippets {
            guard Self.isUndo(event, flags), let history = store.snippetHistory else { return false }
            if editing { window?.makeFirstResponder(nil) }
            if flags == .command { history.undo(store) } else { history.redo(store) }
            return true
        }
        guard navigator.selection.tab != nil else { return false }
        if flags == .command, Int(event.keyCode) == kVK_ANSI_F {
            openPalette(nil)
            return true
        }
        if Int(event.keyCode) == kVK_Escape, flags.isEmpty { return escape(window: window, editing: editing) }
        if editing {
            // Only the search field is a field here: everything but what acts on the results is the field's own.
            guard search.focused else { return false }
            return searchKey(event, flags: flags, shortcut: shortcut)
        }
        // A control the Tab ring is on (Undo, a button) takes Return and Space itself, not the picked row.
        if flags.isEmpty, responder is NSControl,
           [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space].contains(Int(event.keyCode)) { return false }
        if flags == .command, Self.isUndo(event, flags) { return store.undoLast() }
        if shortcut == store.shortcut(.refresh) { store.refreshNow(); return true }
        // What the user bound comes before the typing that starts a search: a letter bound to Mark as read marks the picked row.
        // Once a search has text, a bound letter is a letter like any other.
        if (!search.isSearching || !typesText(event)), isBound(shortcut), act(shortcut) { return true }
        if startsSearch(event, flags: flags) {
            openPalette(event)
            return true
        }
        if flags.isEmpty, Int(event.keyCode) == kVK_DownArrow || Int(event.keyCode) == kVK_UpArrow {
            move(down: Int(event.keyCode) == kVK_DownArrow)
            return true
        }
        return false
    }

    /// Esc steps out one level: the search field's focus, the search, then the pick. With nothing to step out of it isn't
    /// the inbox's: it goes on to what has the keyboard, and never closes the window.
    private func escape(window: NSWindow?, editing: Bool) -> Bool {
        if editing { window?.makeFirstResponder(nil) }
        if search.isSearching || !search.query.isEmpty || search.focused {
            search.end()
        } else if hub.selection != nil, !editing {
            hub.selection = nil
            hub.keyboardSelection = nil
        } else {
            return editing
        }
        return true
    }

    /// A key while the search field has focus: ↑↓ walk the results, the configured Open shortcut opens one, the chords of the
    /// other bound actions act on the pick as off the search. Everything else (typing, ⌫, Space, ⌘Z) is the field's own.
    private func searchKey(_ event: NSEvent, flags: NSEvent.ModifierFlags, shortcut: Shortcut) -> Bool {
        if shortcut == store.shortcut(.openItem), !typesText(event) { return rowCommand(shortcut) }
        if shortcut.hasCommandLikeModifier, isBound(shortcut), act(shortcut) { return true }
        if !typesText(event), shortcut == store.shortcut(.markAllRead) { return act(shortcut) }
        if shortcut == store.shortcut(.refresh), shortcut.hasCommandLikeModifier { store.refreshNow(); return true }
        guard flags.isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_DownArrow:
            move(down: Int(event.keyCode) == kVK_DownArrow)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return rowCommand(isBound(shortcut) ? shortcut : store.shortcut(.openItem))
        default:
            return false
        }
    }

    // MARK: Actions

    /// The bound action `shortcut` is, done: Mark all as read, or one on the picked row. False when it is none or there is
    /// nothing to act on.
    @discardableResult
    func act(_ shortcut: Shortcut) -> Bool {
        if shortcut == store.shortcut(.markAllRead) {
            guard let tab = navigator.selection.tab else { return false }
            withAnimation(Motion.fade.resolved(reduce: Motion.systemReduce)) {
                if search.isSearching { store.inboxRows(tab, search: search.query).filter(\.isUnread).forEach(store.markSeen) }
                else { store.markAllSeen(tab) }
            }
            return true
        }
        return rowCommand(shortcut)
    }

    /// What the bound row actions do to the picked row, if it is listed now.
    private func rowCommand(_ shortcut: Shortcut) -> Bool {
        let targets = targets()
        guard let selection = hub.selection, targets.contains(selection),
              let entry = store.entries.first(where: { $0.id == String(selection.dropFirst(2)) }) else { return false }
        if shortcut == store.shortcut(.openItem) {
            store.open(entry)
        } else if shortcut == store.shortcut(.toggleRead) {
            if entry.isUnread { store.markSeen(entry) } else if !entry.isDone { store.markUnread(entry) }
        } else if shortcut == store.shortcut(.openInRouter) {
            guard store.offers(.openInRouter) else { return false }
            openInRouter(entry.id)
        } else if shortcut == store.shortcut(.discard) {
            let i = targets.firstIndex(of: selection) ?? 0
            // The pick moves on to the next row (the previous one at the end) as this one leaves the list.
            let next = targets.indices.contains(i + 1) ? targets[i + 1] : (i > 0 ? targets[i - 1] : nil)
            pick(next)
            withAnimation(Motion.fade.resolved(reduce: Motion.systemReduce)) { entry.isDone ? store.restore(entry) : store.finish(entry) }
        } else {
            return false
        }
        return true
    }

    func move(down: Bool) {
        let targets = targets()
        guard !targets.isEmpty else { return }
        let i = targets.firstIndex(of: hub.selection ?? "") ?? (down ? -1 : targets.count)
        pick(targets[min(max(i + (down ? 1 : -1), 0), targets.count - 1)])
    }

    private func pick(_ target: String?) {
        hub.selection = target
        if let target { hub.requestScroll(target) } else { hub.keyboardSelection = nil }
    }

    // MARK: Matching

    /// ⌘Z (undo) or ⇧⌘Z (redo) by the character, so it is the Z key on any layout.
    private static func isUndo(_ event: NSEvent, _ flags: NSEvent.ModifierFlags) -> Bool {
        (flags == .command || flags == [.command, .shift]) && event.charactersIgnoringModifiers?.lowercased() == "z"
    }

    private func isBound(_ shortcut: Shortcut) -> Bool {
        ShortcutAction.allCases.contains { !$0.isGlobal && store.shortcut($0) == shortcut }
    }

    /// Whether a field would put this key in its text: a printable character without ⌃⌥⌘.
    private func typesText(_ event: NSEvent) -> Bool {
        !Shortcut(event).hasCommandLikeModifier && Self.printable(event) != nil
    }

    /// Whether the key types something into a field: a printable character (not Space before the first one), or a dead key.
    private func startsSearch(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        if flags.subtracting(.shift).isEmpty, let typed = Self.printable(event) { return !(typed == " " && search.query.isEmpty) }
        return flags.isDisjoint(with: [.command, .control]) && isDeadKey(event)
    }

    /// Whether the key is a dead key of the current layout (⌥E on US, ^ on French). Replaceable, as it depends on the keyboard.
    var isDeadKey: (NSEvent) -> Bool = AppWindowKeys.layoutHasDeadKey

    private static func layoutHasDeadKey(_ event: NSEvent) -> Bool {
        guard event.characters?.isEmpty ?? true,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return false }
        let layout = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
        var state: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let modifiers = (Shortcut(event).carbonModifiers >> 8) & 0xFF
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, event.keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                           0, &state, chars.count, &length, &chars)
        }
        return status == noErr && state != 0
    }

    /// What a key types, when it is printable text (not a control character or a function key).
    private static func printable(_ event: NSEvent) -> String? {
        guard let typed = event.characters, !typed.isEmpty,
              typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return nil }
        return typed
    }
}
