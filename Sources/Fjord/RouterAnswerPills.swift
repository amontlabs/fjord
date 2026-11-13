import AppKit
import SwiftUI

// The composer's item and answer pills (Router v2; shots `v2-pill-*`). The look for the owner to validate, on the demo's
// data; what Return sends is unchanged.
//
// - An **item pill** names an open item in your words: picked from the @ list (found by the words of its sentence, listed
//   under its thread's name) or ⌘-clicked on the page. Its kind's mark and its short words on its kind's tint, as its name
//   sits on the page. While the @ list lights an item, its row on the page lights as the pointer would and comes into view.
// - An **answer pill** is what you picked or typed on a card: one per card, `[? trial build → owed live tests]`, every
//   question of a form in the same pill. It follows the card (changing the option changes it, "Other" typed shows live)
//   and the card follows it (taking it out unticks the card). It leads the draft (`.answer` pills, before your words):
//   the picks are what it says, the draft mirrors them. Answer pills alone are no words (`draftEmpty`): the digits
//   still pick and Return sends the picks as before.
// - A click on either opens its card.

/// One card's answer as the composer shows it.
struct RouterAnswerPill: Identifiable, Equatable {
    /// Whose picks they are (`RouterModel.picks`): the thread's id, or an item's key.
    let key: String
    let thread: String
    let item: String?
    let look: MentionLook
    var id: String { key }
    /// How it reads as words (the split's row, the text Return sends, a cut): the item or thread as the page names it, an
    /// arrow, the answer. Never the answer alone, never an "@": `Settings layout → one scrolling page`.
    var name: String { look.label + " → " + (look.answer ?? "") }
}

/// How the item and answer pills show and what they are called, where only the store is at hand (`Store.pointerName`,
/// `Store.pointerLook`, the composer's static drawing): written by the page's model each time it makes or changes one.
@MainActor
enum RouterPillLooks {
    static var looks: [RouterPointer: MentionLook] = [:]
    static var names: [RouterPointer: String] = [:]

    static func note(_ pointer: RouterPointer, _ look: MentionLook, name: String) {
        looks[pointer] = look
        names[pointer] = name
    }
}

extension RouterModel {
    /// The most an item's words take in a pill, and an answer in its pill.
    static let pillShort = 28
    static let pillAnswer = 44

    /// The thread and item an item key names (`itemKey`), when it is still on the page.
    func item(key: String) -> (thread: RouterThread, item: RouterItem)? {
        for t in threads {
            for i in t.ledger.items where Self.itemKey(t.id, i.id) == key { return (t, i) }
        }
        return nil
    }

    /// An item in a few words: its own short words, else its sentence's first words.
    static func short(_ item: RouterItem) -> String {
        if let short = item.short?.trimmingCharacters(in: .whitespaces), !short.isEmpty { return clip(short, pillShort) }
        return clip(item.sentence, pillShort)
    }

    /// `text` cut at a word to `limit` characters, with an ellipsis when cut.
    static func clip(_ text: String, _ limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:?.")) + "…"
    }

    /// An item pill's look: its kind's mark and tint, its short words.
    func itemPillLook(_ key: String) -> MentionLook? {
        guard let found = item(key: key)?.item else { return nil }
        return MentionLook(label: Self.short(found), symbol: found.kind.symbol, tint: found.kind.tint, item: true)
    }


    // MARK: Items in the @ list

    /// The open items the @ list offers for a typed word, in the page's order, each under its thread's name: found by a
    /// word of its sentence or its short words (a prefix, a word, a substring; never loose letters).
    func itemRows(_ query: String) -> [MentionSuggestion] {
        var rows: [MentionSuggestion] = []
        for t in shownLines {
            for item in t.ledger.live where !item.preview {
                let keys = [item.sentence] + (item.short.map { [$0] } ?? [])
                if !query.isEmpty, !keys.contains(where: { RouterMentions.score($0, query: query).map { $0 <= 2 } ?? false }) { continue }
                let key = Self.itemKey(t.id, item.id)
                rows.append(MentionSuggestion(section: .items, pick: .pointer(.item(key)), name: Self.clip(item.sentence, 64),
                                              detail: "", look: MentionLook(label: Self.short(item), symbol: item.kind.symbol,
                                                                            tint: item.kind.tint, item: true),
                                              keys: keys, group: t.name))
            }
        }
        return rows
    }

    /// The @ list lit a row: an item's row on the page lights and comes into view; anything else, none.
    func lightAt(_ pointer: RouterPointer?) {
        guard case .item(let key)? = pointer, let t = item(key: key)?.thread else {
            if atLit != nil { atLit = nil }
            return
        }
        let hit: RouterHit = t.ledger.block ? .row(key) : .row(t.id)
        guard atLit != hit else { return }
        atLit = hit
        show(t.id)
    }

    // MARK: ⌘-click

    /// The item as a pill at the end of the draft, the composer given the keyboard. False when it isn't on the page.
    @discardableResult
    func pillItem(_ itemID: String, of threadID: String) -> Bool {
        let key = Self.itemKey(threadID, itemID)
        guard let look = itemPillLook(key) else { return false }
        let pointer = RouterPointer.item(key)
        RouterPillLooks.note(pointer, look, name: look.label)
        if !mentions.contains(where: { $0.pointer == pointer }) {
            let lead = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
            let text = draft + lead + MentionText.markString + " "
            let pointers = mentions.map(\.pointer) + [pointer]
            let names = Dictionary(mentions.map { ($0.pointer, $0.name) }, uniquingKeysWith: { a, _ in a })
            edit(text, marks: RouterMentions.marks(text, pointers: pointers, name: { p in p == pointer ? look.label : names[p] ?? "" }))
        }
        focusTick &+= 1
        return true
    }

    // MARK: Answers

    /// The cards' answers as the composer's pills, in the page's order: a card with a pick, or words typed in its Other.
    var answerPills: [RouterAnswerPill] {
        var out: [RouterAnswerPill] = []
        for t in shownLines {
            if let words = answerText(t) {
                out.append(RouterAnswerPill(key: t.id, thread: t.id, item: nil,
                                            look: MentionLook(label: Self.clip(t.name, Self.pillShort), symbol: t.look.symbol ?? "circle.fill",
                                                              tint: t.look.tint, answer: Self.clip(words, Self.pillAnswer))))
            }
            for item in t.ledger.live {
                let key = Self.itemKey(t.id, item.id)
                guard let words = answerText(item, key: key) else { continue }
                // Named as the page names it: an item by its own short words; one with none, or a line's one item, by its
                // thread's name (its sentence is the question, which would only say the answer twice).
                let own = item.short?.trimmingCharacters(in: .whitespaces) ?? ""
                let label = t.ledger.block && !own.isEmpty ? Self.short(item) : Self.clip(t.name, Self.pillShort)
                out.append(RouterAnswerPill(key: key, thread: t.id, item: item.id,
                                            look: MentionLook(label: label, symbol: item.kind.symbol, tint: item.kind.tint,
                                                              answer: Self.clip(words, Self.pillAnswer))))
            }
        }
        return out
    }

    /// A thread's ask answered on its card: the option picked or the words typed, each question's for a form.
    private func answerText(_ t: RouterThread) -> String? {
        guard picks[t.id] != nil || typed[t.id] != nil else { return nil }
        let numbered = t.numbered
        func label(_ n: Int) -> String? { numbered.indices.contains(n - 1) ? numbered[n - 1].label : nil }
        let questions = t.form.isEmpty ? [0] : Array(t.form.indices)
        let parts = questions.compactMap { q -> String? in
            if let words = typed[t.id]?[q], !words.isEmpty { return words }
            return picks[t.id]?[q].flatMap(label).map(RouterModel.spoken)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// An item answered on its card.
    private func answerText(_ item: RouterItem, key: String) -> String? {
        if let words = typed[key]?[0], !words.isEmpty { return words }
        guard let n = picks[key]?[0], item.options.indices.contains(n - 1) else { return nil }
        return Self.spoken(item.options[n - 1])
    }

    /// An option's label as the answer reads after the arrow: its first letter lowered (`One scrolling page` → `one
    /// scrolling page`), unless it starts a name or an acronym (`PR`, `iOS`). Words you typed stay as typed.
    static func spoken(_ option: String) -> String {
        let chars = Array(option)
        guard chars.count > 1, chars[0].isUppercase, !chars[1].isUppercase, chars[1].isLetter else { return option }
        return chars[0].lowercased() + String(chars.dropFirst())
    }

    /// The answer pill taken out: its card is unticked, its Other emptied.
    func removeAnswer(_ key: String) {
        guard picks[key] != nil || typed[key] != nil else { return }
        animate(.fade) {
            picks[key] = nil
            typed[key] = nil
        }
    }

    /// No words in the draft: only whitespace and answer pills.
    var wordless: Bool {
        draft.allSatisfy { $0.isWhitespace || $0 == MentionText.mark }
            && mentions.allSatisfy { if case .answer = $0.pointer { true } else { false } }
    }

    /// The picks changed: the draft's answer pills follow, at its start in the page's order, each followed by a space;
    /// the rest of the draft as it was.
    func answersChanged() {
        guard !syncingAnswers else { return }
        let want = answerPills
        for pill in want { RouterPillLooks.note(.answer(pill.key), pill.look, name: pill.name) }
        let have = mentions.filter { if case .answer = $0.pointer { true } else { false } }
        guard have.map(\.pointer) != want.map({ .answer($0.key) }) || have.map(\.name) != want.map(\.name)
        else { return }
        syncingAnswers = true
        defer { syncingAnswers = false }
        // The draft without its answer pills (and the space after each).
        var rest = ""
        var kept: [RouterMention] = []
        var pills = mentions.makeIterator()
        var skipSpace = false
        for ch in draft {
            if skipSpace, ch == " " { skipSpace = false; continue }
            skipSpace = false
            if ch == MentionText.mark, let m = pills.next() {
                if case .answer = m.pointer { skipSpace = true; continue }
                kept.append(m)
            }
            rest.append(ch)
        }
        let text = String(repeating: MentionText.markString + " ", count: want.count) + rest
        let pointers = want.map { RouterPointer.answer($0.key) } + kept.map(\.pointer)
        let names = Dictionary(want.map { (RouterPointer.answer($0.key), $0.name) } + kept.map { ($0.pointer, $0.name) },
                               uniquingKeysWith: { a, _ in a })
        edit(text.trimmingCharacters(in: .whitespaces).isEmpty && kept.isEmpty && want.isEmpty ? "" : text,
             marks: RouterMentions.marks(text, pointers: pointers, name: { names[$0] ?? "" }))
    }

    /// The draft's pills changed (a pill taken out by ⌫ or a cut): an answer pill gone unticks its card.
    func pillsChanged(from old: [RouterMention]) {
        guard !syncingAnswers else { return }
        let now = Set(mentions.map(\.pointer))
        for m in old where !now.contains(m.pointer) {
            if case .answer(let key) = m.pointer {
                syncingAnswers = true
                picks[key] = nil
                typed[key] = nil
                syncingAnswers = false
            }
        }
    }

    /// Words typed in a card's Other (`question` of a form, else 0): they are the answer, the option picked there goes.
    func typeOther(_ key: String, question: Int, _ words: String) {
        let empty = words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty {
            typed[key]?[question] = nil
            if typed[key]?.isEmpty == true { typed[key] = nil }
        } else {
            typed[key, default: [:]][question] = words
            picks[key]?[question] = nil
            if picks[key]?.isEmpty == true { picks[key] = nil }
        }
    }

    // MARK: A click on a pill

    /// An item's or an answer's pill clicked in the composer: its card opens.
    func openPill(_ pointer: RouterPointer) {
        switch pointer {
        case .item(let key), .answer(let key): openPill(key: key)
        default: break
        }
    }

    /// A pill clicked in the composer: its card opens (an item's under its block's row).
    func openPill(key: String) {
        if let found = item(key: key) {
            let t = found.thread
            if selection != .line(t.id) { select(.line(t.id)) }
            focusItem(t.ledger.block ? found.item.id : nil)
            show(t.id)
        } else if thread(key) != nil {
            if selection != .line(key) { select(.line(key)) }
            focusItem(nil)
            show(key)
        }
    }
}
