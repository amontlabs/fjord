import AppKit
import Foundation

// How the Router asks Jev its questions: every call goes through a `JevAsker`, so tests answer for it.

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

extension RouterModel {
    /// What the draft goes with: the reply and the pills.
    func context(_ store: Store) -> RouterContext { context(store, sent: sentDraft(store)) }

    /// The same, for the draft as it will be sent, worked out once by the caller (`sentDraft` writes every pill's name).
    func context(_ store: Store, sent: (text: String, mentions: [RouterMention])) -> RouterContext {
        let reply = store.routerBriefs.focused.flatMap { t in store.routerBriefs.docs[t.project]?.thread(t.thread) != nil ? t : nil }
        // The place picked in the composer is where it goes; the one waved off is never sent to unasked.
        let preview = store.routerPreview
        var context = RouterContext(replyTo: reply, target: preview.pinned, notTo: preview.dismissed)
        context.tag(sent.mentions)
        context.preview = preview.carried(for: sent.text)
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
}
