import AppKit
import SwiftUI

// The composer's item and answer pills (Router v2; shots `v2-pill-*`), on the page's live items and cards.
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
// - Return sends the answers by code, never through the read: a T3 request's as its structured answer (`.answer(picks:
//   typed:)`), an item's as words to its thread (one message a thread; joined to your words when they go there too). The
//   split router gets every pill as `RouterPillContext` (`pillContext`), and the answers as sends (`answerSends`).

/// One pill of the composer as the Router and Return get it: what the split router reads beside the free words, and what
/// Return sends by code. Shared with the split (`RouterSplit`, the reader).
struct RouterPillContext: Equatable {
    enum Kind: Equatable {
        /// An item named in the words (@ or ⌘-click): context for the free text, which says "@name" where it stands.
        case item
        /// A card's answer: never part of the free text; Return sends it by code.
        case answer
    }

    var kind: Kind
    var thread: String
    /// The item it names or answers; nil for an answer to the thread's own T3 request (its picks are the thread's). An
    /// item pill on a T3 request shown as an item names it by its id (`RouterItem.requestID`).
    var item: String?
    /// As the pill reads: `trial build`, `trial build → owed live tests`.
    var name: String
    /// An answer's picks, by question (0 for one question): the option's number, 1-based (`RouterModel.picks`).
    var picks: [Int: Int] = [:]
    /// An answer's words typed in its card's Other, by question.
    var typed: [Int: String] = [:]
    /// An answer as words: the option's label or the typed words, a form's questions joined with " · ".
    var answer: String? = nil

    /// It answers T3's request on the thread: sent structured, not as words.
    var request: Bool { kind == .answer && item == nil }
}

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
                let look = MentionLook(label: Self.short(item), symbol: item.kind.symbol, tint: item.kind.tint, item: true)
                // Picked in the live field, its pill is named and drawn through the store (`Store.pointerName`): noted now.
                RouterPillLooks.note(.item(key), look, name: look.label)
                rows.append(MentionSuggestion(section: .items, pick: .pointer(.item(key)), name: Self.clip(item.sentence, 64),
                                              detail: "", look: look, keys: keys, group: t.name))
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

    // MARK: What Return gets

    /// The draft's pills, in its order, as the split router and Return get them.
    var pillContext: [RouterPillContext] {
        let answers = Dictionary(answerPills.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return mentions.compactMap { m in
            switch m.pointer {
            case .item(let key):
                guard let found = item(key: key) else { return nil }
                return RouterPillContext(kind: .item, thread: found.thread.id, item: found.item.id, name: m.name)
            case .answer(let key):
                guard let pill = answers[key] else { return nil }
                return RouterPillContext(kind: .answer, thread: pill.thread, item: pill.item, name: pill.name,
                                         picks: picks[key] ?? [:], typed: typed[key] ?? [:], answer: answerWords(pill))
            default: return nil
            }
        }
    }

    /// The draft's answers as the split's sends: sure, each to its thread (its item), with the answer as its words.
    var answerSends: [RouterSend] {
        pillContext.filter { $0.kind == .answer }.map {
            RouterSend(places: [.thread($0.thread)], words: $0.answer ?? "", item: $0.item)
        }
    }

    /// An answer pill's words, whole: a request's as the card says them (`answerWords`), an item's picked or typed.
    private func answerWords(_ pill: RouterAnswerPill) -> String? {
        if pill.item == nil { return thread(pill.thread).flatMap(answerWords) }
        guard let found = item(key: pill.key) else { return nil }
        return answerText(found.item, key: pill.key).map { typed[pill.key]?[0] == nil ? Self.unspoken(found.item, $0) : $0 }
    }

    /// A picked option's own label (the pill lowers its first letter; the thread gets it as the card shows it).
    private static func unspoken(_ item: RouterItem, _ words: String) -> String {
        item.options.first { spoken($0) == words } ?? words
    }

    /// A request still owed an answer to a form question can't go yet: its pill stays.
    func ready(_ answer: RouterPillContext) -> Bool {
        guard answer.request, let t = thread(answer.thread) else { return answer.answer != nil }
        return openQuestions(t) == 0
    }

    /// The words a thread gets for its items' answers: the one answer alone, several each after its item's name.
    private static func message(_ answers: [RouterPillContext]) -> String {
        if answers.count == 1 { return answers[0].answer ?? "" }
        return answers.map { a in (a.name.components(separatedBy: " → ").first ?? a.name) + " → " + (a.answer ?? "") }
            .joined(separator: "\n")
    }

    /// Return with answer pills in the draft: each card's answer goes by code, then `words` (the free text, nil: none) to
    /// `place`. A request's answer goes first and structured (so words to the same thread can't answer it instead); an
    /// item's go as one message a thread, led into `words` when those go to that thread too. A form still owed an answer
    /// keeps its pill. The picks of what went are cleared; the draft keeps the pills of what didn't.
    func sendWithAnswers(_ words: String?, to place: RouterPlace?, queue: Bool) {
        let answers = pillContext.filter { $0.kind == .answer && ready($0) }
        syncingAnswers = true
        // Requests first, structured.
        for a in answers where a.request {
            guard let t = thread(a.thread) else { continue }
            dispatch(a.answer ?? "", to: t, kind: .answer(picks: a.picks, typed: a.typed))
        }
        var items: [String: [RouterPillContext]] = [:]
        var order: [String] = []
        for a in answers where !a.request {
            if items[a.thread] == nil { order.append(a.thread) }
            items[a.thread, default: []].append(a)
        }
        // The free words, led by their thread's answers.
        var into: String? = nil
        if let words, let place {
            if case .thread(let id) = place, let lead = items[id] {
                into = id
                deliver(Self.message(lead) + "\n\n" + words, to: place, queue: queue)
            } else {
                deliver(words, to: place, queue: queue)
            }
        }
        setDraft("")
        for id in order where id != into {
            deliver(Self.message(items[id] ?? []), to: .thread(id), queue: false)
        }
        for a in answers {
            let key = a.item.map { Self.itemKey(a.thread, $0) } ?? a.thread
            picks[key] = nil
            typed[key] = nil
        }
        syncingAnswers = false
        // What didn't go comes back as its pills.
        answersChanged()
    }

    /// The draft has a card's answer as a pill.
    var hasAnswers: Bool { mentions.contains { $0.pointer.isAnswer } }

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
        } else if let t = thread(key) {
            if selection != .line(key) { select(.line(key)) }
            // A thread's answer is its request's: that item's card.
            focusItem(t.ledger.request?.id)
            show(key)
        }
    }
}
