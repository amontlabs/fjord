import Foundation

// What a message to a thread carries besides your words (docs/design/t3-code-map.md, A10): the notification or category a
// pill points to travels as a T3 context record, and the text points at it where the pill sat with a
// `[@name](t3-context://v1/<kind>/<id>)` reference. Your words stay as you typed them (the reference's label is the pill's
// own "@name"); what GitHub wrote is data in a record, which T3 escapes in the `<t3_context>` envelope it gives the agent, so
// a comment can't forge another record or give an instruction.

/// A message for a thread, ready to dispatch.
struct ThreadWords: Equatable {
    /// What you typed, with the addressing taken out (`Addressing`): what the entry shows.
    var words: String
    /// Everything you typed.
    var original: String
    var rephrased: Bool
    /// The text T3 gets: `words` with a reference at each pill that has a record.
    var text: String
    var records: [T3JSON]
}

extension RouterPointers {
    /// T3 context kinds Fjord makes (unknown to T3, so their payload travels as JSON).
    static let notificationKind = "fjord-notification"
    static let categoryKind = "fjord-category"

    /// Your message for a thread: the addressing taken out, a reference and a record for each notification or category pill
    /// that is still where it was after that. Throws when nothing is left of it (`Addressing.NothingLeft`).
    @MainActor
    static func threadMessage(_ original: String, pills: [Range<Int>], mentions: [RouterMention], store: Store) throws -> ThreadWords {
        let (prepared, origins) = try Addressing.editMapped(original, pills: pills)
        let chars = Array(prepared.text)
        var newIndex: [Int: Int] = [:]
        for (i, o) in origins.enumerated() { newIndex[o] = i }
        var ids: [RouterPointer: String] = [:]
        var records: [T3JSON] = []
        var spans: [(range: Range<Int>, reference: String)] = []
        var end = 0
        for m in mentions.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard !m.range.isEmpty, let first = newIndex[m.range.lowerBound], let last = newIndex[m.range.upperBound - 1],
                  last - first == m.range.count - 1, first >= end, last < chars.count else { continue }
            let kind: String
            switch m.pointer {
            case .notification: kind = notificationKind
            case .category: kind = categoryKind
            case .project, .t3, .thisItem: continue
            }
            let label = String(chars[first...last])
            let id: String
            if let known = ids[m.pointer] {
                id = known
            } else {
                id = "ctx_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
                ids[m.pointer] = id
                records.append(record(m.pointer, kind: kind, id: id, label: label, store: store))
            }
            spans.append((first..<(last + 1), "[\(referenceLabel(label))](t3-context://v1/\(kind)/\(id))"))
            end = last + 1
        }
        var text = ""
        var at = 0
        for span in spans {
            text += String(chars[at..<span.range.lowerBound]) + span.reference
            at = span.range.upperBound
        }
        text += String(chars[at...])
        return ThreadWords(words: prepared.text, original: original, rephrased: prepared.rephrased, text: text, records: records)
    }

    /// A pill's name as a link label: no brackets or line breaks, at most 200 characters, never empty.
    static func referenceLabel(_ name: String) -> String {
        let kept = name.filter { !"[]".contains($0) && !$0.isNewline }
        let label = String(kept.prefix(200))
        return label.isEmpty ? "context" : label
    }

    @MainActor
    private static func record(_ pointer: RouterPointer, kind: String, id: String, label: String, store: Store) -> T3JSON {
        var record: [String: T3JSON] = ["version": 1, "contextId": .string(id), "kind": .string(kind),
                                        "label": .string(referenceLabel(label))]
        record["payload"] = .object(payload(pointer, store: store))
        return .object(record)
    }

    /// What a pill stands for, as plain fields. Text GitHub's people wrote is cleaned and bounded, and named under
    /// `untrusted`; the rest is Fjord's own.
    @MainActor
    static func payload(_ pointer: RouterPointer, store: Store) -> [String: T3JSON] {
        switch pointer {
        case .notification(let id):
            guard let thing = store.things[id] else {
                return ["note": "A notification that is no longer in the Triage inbox."]
            }
            let entry = store.entries.first { $0.id == id }
            let category = entry.flatMap { e in store.categories.first { $0.id == e.categoryID } }
            let kind = switch thing.kind {
            case .pr: "pull request"
            case .issue: "issue"
            case .workflow: "workflow run"
            }
            var out: [String: T3JSON] = [
                "source": "Fjord's Triage inbox", "kind": .string(kind), "state": .string(thing.status.rawValue),
                "archived": .bool(entry?.isDone ?? false),
            ]
            if let checks = thing.checks { out["checks"] = .string(checks.rawValue) }
            if let url = InboxActions.trustedURL(thing) { out["url"] = .string(url) }
            var untrusted: [String: T3JSON] = ["title": .string(UntrustedText.clean(thing.title, limit: 300))]
            if let reference = InboxActions.trustedReference(thing) { out["reference"] = .string(reference) }
            else { untrusted["reference"] = .string(UntrustedText.clean(InboxActions.reference(thing), limit: 200)) }
            if let author = thing.author { untrusted["author"] = .string("@" + UntrustedText.clean(author.login, limit: 80)) }
            if let category { untrusted["category"] = .string(UntrustedText.clean(category.name, limit: 80)) }
            if let facts = entry?.facts, !facts.isEmpty {
                untrusted["whyItIsThere"] = .string(UntrustedText.clean(facts.map(\.label).joined(separator: " · "), limit: 400))
            }
            if thing.kind == .workflow, !thing.failingJobs.isEmpty {
                untrusted["failingJobs"] = .string(UntrustedText.clean(thing.failingJobs.joined(separator: ", "), limit: 400))
            }
            if let last = thing.comments.max(by: { $0.at < $1.at }) {
                untrusted["lastComment"] = .string("@\(UntrustedText.clean(last.author.login, limit: 80)): "
                                                   + UntrustedText.clean(last.snippet, limit: 400))
            }
            out["writtenOnGitHub"] = .object(untrusted)
            return out
        case .category(let id):
            guard let c = store.categories.first(where: { $0.id == id }) else {
                return ["note": "A category that is no longer in the Triage inbox."]
            }
            let open = store.entries(in: c.id)
            return ["source": "Fjord's Triage inbox", "name": .string(UntrustedText.clean(c.title, limit: 80)),
                    "open": .number(Double(open.count)), "unread": .number(Double(open.filter(\.isUnread).count)),
                    "rules": .array(RuleWords(store: store).summary(c).prefix(20).map { .string(UntrustedText.clean($0, limit: 300)) })]
        case .project, .t3, .thisItem:
            return [:]
        }
    }
}
