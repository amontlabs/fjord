import Foundation

// Pictures and files pasted with an answer to a T3 request's card. T3 takes them only with a question's custom answer
// (`runtime-request.respond`'s `attachmentsByQuestionId`; docs/user/question-attachments.md in T3): its web client leaves no
// reference in the answer's words, and T3 adds the saved files' paths to the answer the agent gets. A question with only
// its options, a permission and a plan take none: the send says so (`RequestFailure.noAttachments`), nothing is dropped
// silently. The uploads are those of the composer (`RouterAttachments`), waited for as a message's are.

extension RouterModel {
    /// The words of an answer typed in the composer, the attachments' pills taken out (with a space they leave doubled), and
    /// those pills. `draft`: the composer's, `marks`: its pills.
    static func answerWithoutAttachments(_ draft: String, marks: [RouterMention]) -> (words: String, pills: [RouterMention]) {
        let (text, kept) = RouterMentions.plain(draft, marks: marks)
        let pills = kept.filter { $0.pointer.attachment != nil }
        return (withoutPills(text, pills), pills)
    }

    /// `text` without the characters of `pills` (ranges in it), trimmed.
    static func withoutPills(_ text: String, _ pills: [RouterMention]) -> String {
        guard !pills.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let chars = Array(text)
        var cut = Set<Int>()
        for p in pills { for i in p.range where chars.indices.contains(i) { cut.insert(i) } }
        var out = ""
        var i = 0
        while i < chars.count {
            if cut.contains(i) {
                var end = i
                while cut.contains(end) { end += 1 }
                // "see [image: a.png] here": one space stays between the words.
                if out.last == " ", end < chars.count, chars[end] == " " { end += 1 }
                i = end
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A form's typed answer to `question`, as its pill and the line show it: the words, with the pictures' and files' names
    /// pasted with them while they still go with it.
    func typedWords(_ key: String, _ question: Int) -> String? {
        guard let words = typed[key]?[question] else { return nil }
        guard let entry = typedAttached[key]?[question], entry.words == words else { return words }
        let names = entry.pills.map { $0.pointer.said($0.name) }.joined(separator: " ")
        return words.isEmpty ? names : words + " " + names
    }

    /// The attachments that go with a card's typed answers, by question: only those whose answer is still the words they
    /// were typed with (an option picked since, or other words, leaves them out).
    func typedAttachments(_ key: String) -> [Int: [String]] {
        var out: [Int: [String]] = [:]
        for (question, entry) in typedAttached[key] ?? [:] where typed[key]?[question] == entry.words {
            let ids = entry.pills.compactMap(\.pointer.attachment)
            if !ids.isEmpty { out[question] = ids }
        }
        return out
    }

    /// The pills a card's typed answers keep while they wait to go (the draft let them go when their words moved to the
    /// card): an answer retyped or replaced by an option lets its pills go, and their uploads are deleted.
    func answersHoldAttachments() {
        attachments?.holds(Set(typedAttached.keys.flatMap { typedAttachments($0).values.joined() }), by: "answers")
    }

    /// Words with pictures or files to a card that holds a T3 question or permission: its structured answer, so the
    /// attachments go with a custom answer or the send says why they can't (`ThreadAnswers.resolve`). The words naming one
    /// of the question's options pick it. nil: no attachments, a plan (the words go as a message that sends it back, with
    /// them where they sat: `RouterDispatcher.attachedReply`), a card with a form (the dispatcher finds the question they
    /// go with) or no request.
    func attachedAnswer(_ words: String, to t: RouterThread, attached: [RouterMention]) -> RouterOutgoing.Kind? {
        let pills = attached.filter { $0.pointer.attachment != nil }
        guard !pills.isEmpty, case .needsYou(let ask) = t.state, ask != .form, ask != .plan, t.form.isEmpty else { return nil }
        let ids = pills.compactMap(\.pointer.attachment)
        let said = Self.withoutPills(words, pills)
        func plain(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        if ask == .question, !said.isEmpty, let at = t.options.firstIndex(where: { plain($0) == plain(said) }) {
            return .answer(picks: [0: at + 1], typed: [:], attached: [0: ids])
        }
        return .answer(picks: [:], typed: said.isEmpty ? [:] : [0: said], attached: [0: ids])
    }
}
