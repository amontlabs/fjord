import AppKit
import Observation
import SwiftUI

// The Router composer's text model: the draft, its @ pills and suggestions, and the caret the composer's text view follows.

/// What the window remembers while it is closed (the draft and its pills), and what the keys act on.
@Observable
@MainActor
final class RouterModel {
    var draft = "" {
        didSet { if draft != oldValue { mentionChanged() } }
    }
    /// What the pills in the draft point to, one for each `MentionText.mark` in it, in order.
    var pointers: [RouterPointer] = []
    /// Local projects tagged with @ (their folders), in the order they stand in the draft: context for the Router.
    var projects: [String] {
        var seen = Set<String>()
        return pointers.compactMap { if case .project(let folder) = $0 { folder } else { nil } }.filter { seen.insert($0).inserted }
    }

    /// Pills for `pointers` added to the draft, then `text` (an inbox thing's "Open in Router", a test): the draft as it is
    /// when blank, else after it; what it tags already isn't tagged again. The composer takes the keyboard, its caret at
    /// the end.
    func prefill(_ pointers: [RouterPointer], text: String = "") {
        var added: [RouterPointer] = []
        for p in pointers where !self.pointers.contains(p) && !added.contains(p) { added.append(p) }
        let pills = added.map { _ in MentionText.markString }.joined(separator: " ")
        let words = text.replacingOccurrences(of: MentionText.markString, with: "")
        let start = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : draft + (draft.last?.isWhitespace == true ? "" : " ")
        let tail = [pills, words].filter { !$0.isEmpty }.joined(separator: " ")
        let next = start + tail + (words.isEmpty && !pills.isEmpty ? " " : "")
        caret = nil
        self.pointers = (start.isEmpty ? [] : self.pointers) + added
        draft = next
        caretRequest = (next as NSString).length
        focusRequest &+= 1
    }
    /// While an @ is being typed: what follows it, and the suggestion picked with ↑↓. Words typed across spaces that name
    /// nothing make no suggestions, and the keys act as with none (`suggestions`).
    /// While an @ is being typed: what follows it, and the suggestion picked with ↑↓. Words typed across spaces that name
    /// nothing make no suggestions, and the keys act as with none (`suggestions`).
    private(set) var mention: String?
    var mentionIndex = 0
    /// The @ word Esc dismissed: its suggestions stay away until it changes (not as words typed on after a space).
    @ObservationIgnored private var dismissedMention: String?
    /// Mirrors the composer's focus, for the keys.
    var composerFocused = false
    /// Bumped to ask the composer for the keyboard.
    var focusRequest = 0
    /// The keys that put the focus in the composer, typed into it once it has it.
    @ObservationIgnored var pendingKeys: [NSEvent] = []
    /// Claude Code wasn't found (nil until looked for).
    var claudeCodeMissing: Bool?

    init() {}

    /// Whether a message can go to the Router now: it is on (with the sessions extension) and Claude Code is there.
    func canSend(_ store: Store) -> Bool {
        store.routerOn && !(claudeCodeMissing == true && store.routerStatus.claudeCode == nil)
    }

    /// Looks for Claude Code once the window shows: until the search has finished
    /// nothing is said, and Send waits. In a demo it is never missing. The binary known (`RouterStatus`, which every run
    /// takes its path from) is only checked to be still there, one stat; gone, or none known, it is looked for again.
    func checkClaudeCode(_ store: Store) async {
        if store.routerIsPretend {
            if claudeCodeMissing != false { claudeCodeMissing = false }
            return
        }
        guard store.routerStatus.lookup != nil || store.routerStatus.claudeCode != nil else {
            if claudeCodeMissing != false { claudeCodeMissing = false }
            return
        }
        let found = await store.routerStatus.current() != nil
        if claudeCodeMissing != !found { claudeCodeMissing = !found }
    }

    /// The composer takes the keyboard (typing anywhere in the window lands there).
    func reply() { focusRequest &+= 1 }

    // MARK: @

    /// The @ word being typed at the end of the draft, if any ("…@look" → "look").
    static func mentionQuery(in text: String, caret: Int? = nil) -> String? { mention(in: text, caret: caret)?.query }

    /// How far an @ word may run across spaces ("@fjord comp"): past this it is prose, not a name being looked up.
    static let mentionLimit = (characters: 40, words: 4)

    /// The @ word the caret is in or just after (`caret`: UTF-16 offset, nil for the end): its range (the whole word, past
    /// the caret too) and what is typed between the @ and the caret. An @ inside a word (an email) is not one. What is
    /// typed may run across single spaces (not a new line, a pill, two spaces in a row or one right after the @), a few
    /// words at most; whether it still names something is the suggestions' to say (none: the list is closed).
    static func mention(in text: String, caret: Int?) -> (range: Range<String.Index>, query: String)? {
        if let caret, caret < 0 { return nil }
        let utf16 = text.utf16
        let offset = min(caret ?? utf16.count, utf16.count)
        guard let caretIndex = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
              let at = text[..<caretIndex].lastIndex(of: "@") else { return nil }
        if at != text.startIndex, !MentionText.isBreak(text[text.index(before: at)]) { return nil }
        let typed = text[text.index(after: at)..<caretIndex]
        var end = text[caretIndex...].firstIndex(where: MentionText.isBreak) ?? text.endIndex
        if typed.contains(where: MentionText.isBreak) {
            guard let first = typed.first, !first.isWhitespace,
                  !typed.contains(where: { $0.isNewline || $0 == MentionText.mark }),
                  !zip(typed, typed.dropFirst()).contains(where: { $0.isWhitespace && $1.isWhitespace }),
                  typed.count <= mentionLimit.characters,
                  typed.split(whereSeparator: \.isWhitespace).count <= mentionLimit.words else { return nil }
            // After a space, the word past the caret is the next one, not the @ word's.
            if typed.last?.isWhitespace == true { end = caretIndex }
        }
        return (at..<end, String(typed))
    }

    /// Where the caret is in the composer (UTF-16 offset; nil: at the end), as its text view says: the @ suggestions follow it.
    var caret: Int? {
        didSet { if caret != oldValue { mentionChanged() } }
    }
    /// Asks the composer to put its caret here (after a pick replaced the @ word).
    var caretRequest: Int?

    /// Takes the caret from the composer's text view; a selection (not a caret) shows no suggestions.
    func followCaret(_ editor: NSTextView) {
        let range = editor.selectedRange()
        let at = range.length == 0 ? range.location : -1
        let next: Int? = at == (draft as NSString).length ? nil : at
        if caret != next { caret = next }
    }

    private func mentionChanged() {
        var query = Self.mentionQuery(in: draft, caret: caret)
        // Words typed on past a space after Esc are the message going on: the list stays away.
        if let dismissed = dismissedMention, let typed = query, typed.hasPrefix(dismissed),
           typed.dropFirst(dismissed.count).contains(where: \.isWhitespace) {
            query = dismissed
        }
        if query != dismissedMention { dismissedMention = nil }
        let next = query == dismissedMention ? nil : query
        if next != mention {
            mention = next
            mentionIndex = 0
        }
    }

    /// What the @ word matches, by section (projects, sessions, notifications, categories, snippets), best first in each (a
    /// few of each for a bare @); what the draft tags already left out.
    func suggestions(_ store: Store) -> [MentionSuggestion] {
        guard let query = mention else { return [] }
        // A bare @ shows the first few of each section, in order: only those are made.
        let first = query.isEmpty ? RouterMentions.perSection.bare : nil
        var rows = RouterMentions.candidates(store, except: Set(pointers), query: query, first: first)
        // The Router v2 page's settings (a new thread's model, effort, access, mode), not those the draft names already.
        if let settingRows { rows += settingRows(query).filter { row in
            if case .pointer(let p) = row.pick { !pointers.contains(p) } else { true }
        } }
        return RouterMentions.suggest(rows, query: query)
    }

    /// Rows the page adds to the @ list for a typed word (Router v2's settings); nil: none.
    @ObservationIgnored var settingRows: (@MainActor (String) -> [MentionSuggestion])?

    /// The composer's text view (`MentionField`): text a pick inserts goes in through it while it shows the draft, so ⌘Z
    /// takes it back as it does what you type.
    @ObservationIgnored weak var editor: MentionTextView?

    /// Return or Tab on a suggestion: a pill in the @ word's place, or the text it inserts (a snippet's).
    func pickMention(_ suggestion: MentionSuggestion) {
        switch suggestion.pick {
        case .pointer(let pointer): pickMention(pointer)
        case .text(let text): insertMention(text)
        }
    }

    /// The @ word replaced by `text`, as typed (no pill); the caret after it. With the composer's text view showing the
    /// draft, the edit is the view's own, one step of its undo (the @ word comes back).
    func insertMention(_ text: String) {
        guard mention != nil, let found = Self.mention(in: draft, caret: caret) else { return }
        let start = draft.utf16.distance(from: draft.utf16.startIndex, to: found.range.lowerBound.samePosition(in: draft.utf16)!)
        let words = text.replacingOccurrences(of: MentionText.markString, with: "")
        var next = draft
        next.replaceSubrange(found.range, with: words)
        let end = start + (words as NSString).length
        if let editor, !editor.hasMarkedText(), MentionText.serialize(editor.attributedString()) == (draft, pointers) {
            editor.breakUndoCoalescing()
            editor.insertPlain(words, replacing: NSRange(found.range, in: draft))
            editor.breakUndoCoalescing()
        }
        caret = end
        if draft != next { draft = next }
        caretRequest = end
        mention = nil
    }

    /// The @ word becomes the pill for `pointer`, in its place, with a space after it.
    func pickMention(_ pointer: RouterPointer) {
        guard mention != nil, let found = Self.mention(in: draft, caret: caret) else { return }
        let start = draft.utf16.distance(from: draft.utf16.startIndex, to: found.range.lowerBound.samePosition(in: draft.utf16)!)
        let before = draft[..<found.range.lowerBound].filter { $0 == MentionText.mark }.count
        let offset = draft.distance(from: draft.startIndex, to: found.range.lowerBound)
        var text = draft
        text.replaceSubrange(found.range, with: MentionText.markString)
        // One space after it, the one already there if any.
        let after = text.index(text.startIndex, offsetBy: offset + 1)
        let spaced = after < text.endIndex && text[after] == " "
        if !spaced { text.insert(" ", at: after) }
        var next = pointers
        next.insert(pointer, at: min(before, next.count))
        caret = start + 2
        pointers = next
        draft = text
        caretRequest = start + 2
        mention = nil
    }

    /// Esc on the suggestions: they go until the @ word changes.
    func dismissMention() {
        dismissedMention = mention
        mention = nil
    }

    /// ↑↓ in the suggestions.
    func moveMention(down: Bool, count: Int) {
        guard count > 0 else { return }
        mentionIndex = (mentionIndex + (down ? 1 : count - 1)) % count
    }

}
