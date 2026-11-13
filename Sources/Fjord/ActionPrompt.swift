import Foundation

// A category's "Send to the Router" action: its prompt, written as the Router's composer is (your words, with pills), and
// what the Router made of each message it sent. The message goes through the Router as yours, from the category, with the
// thing tagged; the Router sends it to a session working in the thing's repo or starts one in a local clone of it, and asks
// you when it isn't sure (RouterDispatcher). The user-facing contract is in docs/design/spec/inbox.md.

// MARK: - The prompt

/// A "Send to the Router" prompt: your words with a `MentionText.mark` for each pill in `text`, and what the pills point to
/// in `pointers`, in order (as `RouterComposerModel.draft` and `pointers` have a draft). `RouterPointer.thisItem` stands for the thing
/// the action runs for.
struct ActionPrompt: Hashable, ExpressibleByStringLiteral {
    var text: String
    var pointers: [RouterPointer]

    /// What "this notification" is called, in the editor and in words.
    static let thisItemName = "this notification"

    /// One pointer for each mark: marks with no pointer, or pointers with no mark, are left out.
    init(text: String = "", pointers: [RouterPointer] = []) {
        let marks = text.filter { $0 == MentionText.mark }.count
        var kept = 0
        self.text = String(text.filter { c in
            guard c == MentionText.mark else { return true }
            kept += 1
            return kept <= pointers.count
        })
        self.pointers = Array(pointers.prefix(marks))
    }

    /// Words and pills in order, as `Store.composeForRouter` takes them.
    init(_ parts: [RouterMessagePart]) {
        var text = ""
        var pointers: [RouterPointer] = []
        for part in parts {
            switch part {
            case .text(let words): text += words.replacingOccurrences(of: MentionText.markString, with: "")
            case .pointer(let pointer):
                text.append(MentionText.mark)
                pointers.append(pointer)
            }
        }
        self.init(text: text, pointers: pointers)
    }

    /// A prompt as plain text (a literal in code, one saved before prompts had pills, one the Router writes): its
    /// placeholders become pills (`migrated`).
    init(stringLiteral value: String) { self = Self.migrated(value) }

    /// A prompt saved before prompts had pills, with its placeholders: a run of `{repo}`, `{number}`, `{url}` and `{title}`
    /// (alone, or joined by a `#`: `{repo}#{number}`) becomes the "this notification" pill; `{author}` becomes "its author".
    /// What was a mark in it goes.
    static func migrated(_ old: String) -> ActionPrompt {
        let words = old.replacingOccurrences(of: MentionText.markString, with: "")
            .replacingOccurrences(of: "{author}", with: "its author")
        let placeholder = #"\{(?:repo|number|url|title)\}"#
        let run = try! NSRegularExpression(pattern: "\(placeholder)(?:#?\(placeholder))*")
        var text = ""
        var pointers: [RouterPointer] = []
        var at = words.startIndex
        for match in run.matches(in: words, range: NSRange(words.startIndex..., in: words)) {
            guard let range = Range(match.range, in: words) else { continue }
            text += words[at..<range.lowerBound]
            text.append(MentionText.mark)
            pointers.append(.thisItem)
            at = range.upperBound
        }
        text += words[at...]
        return ActionPrompt(text: text, pointers: pointers)
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Whether it says where the thing goes in it ("this notification" pill); else the thing is tagged at its end.
    var tagsThisItem: Bool { pointers.contains(.thisItem) }

    /// The message for `thing` (its id), as the composer would send it: "this notification" made the thing's pill, and the
    /// thing's pill after your words when the prompt has none.
    func parts(thing: String) -> [RouterMessagePart] {
        var out: [RouterMessagePart] = []
        var words = ""
        var next = pointers.makeIterator()
        for c in text {
            if c == MentionText.mark, let pointer = next.next() {
                if !words.isEmpty { out.append(.text(words)) }
                words = ""
                out.append(.pointer(pointer == .thisItem ? .notification(thing) : pointer))
            } else {
                words.append(c)
            }
        }
        if !tagsThisItem {
            // A space before it, after your words or a pill.
            if !(words.last?.isWhitespace ?? out.isEmpty) { words += " " }
            if !words.isEmpty { out.append(.text(words)) }
            out.append(.pointer(.notification(thing)))
        } else if !words.isEmpty {
            out.append(.text(words))
        }
        return out
    }

    /// The prompt in words, each pill as "@name".
    func words(_ name: (RouterPointer) -> String = ActionPrompt.plainName) -> String {
        MentionText.plain(text, pointers: pointers, name: name)
    }

    /// A pill's name where no store is at hand (a change's description): "this notification", a project's folder name, the
    /// kind of anything else.
    static func plainName(_ pointer: RouterPointer) -> String {
        switch pointer {
        case .thisItem: thisItemName
        case .project(let folder): (folder as NSString).lastPathComponent
        case .t3: "a thread"
        case .notification(let id): id
        case .category: "a category"
        case .setting(let s): s.label
        }
    }
}

// The prompt is kept as the `askRouter` action's `prompt` (its text, a mark per pill) and, when it has pills, `pointers`.
// One saved without `pointers` (before prompts had pills, or written by the Router) is read as plain text (`migrated`).
extension ActionPrompt {
    enum CodingKeys: String, CodingKey { case prompt, pointers }

    init(from container: KeyedDecodingContainer<CodingKeys>) {
        let text = (try? container.decode(String.self, forKey: .prompt)) ?? ""
        if let pointers = try? container.decode([RouterPointer].self, forKey: .pointers) {
            self.init(text: text, pointers: pointers)
        } else {
            self = Self.migrated(text)
        }
    }

    func encode(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(text, forKey: .prompt)
        if !pointers.isEmpty { try container.encode(pointers, forKey: .pointers) }
    }
}

// MARK: - The message

/// Where a message an action sends comes from, and what a session the Router starts for it is called and runs on (nil: your
/// Claude Code defaults). A message with it is unattended: it goes only to a session, never to the Router's own runs, and
/// when the Router isn't sure where, it waits for you (`RouterDispatcher`).
struct RouterActionSource: Equatable {
    var origin: SessionOrigin
    /// The item's repository (`owner/name`): the T3 project that has it is where the work goes (`DeciderBoard.project(forRepo:)`).
    var repo: String?
}

/// What a "Send to the Router" action sends for a thing: the prompt's words and pills, the thing's among them.
struct ActionMessage: Equatable {
    var parts: [RouterMessagePart]
    var source: RouterActionSource
}

// MARK: - What the Router made of it

extension InboxActions {
    /// What a run's chip says while the Router waits for your pick.
    static let waitingWords = "waiting on you in the Router"

    /// What the Router made of an action's message, for its run: still routing (`.running`, no words), waiting for your pick
    /// on an ask, sent to a claude.ai place ("sent to <it>"), or failed and why.
    /// `waiting`, `busy`: the dispatcher has an ask for it, a run under way. `title`: a session's title.
    static func outcome(of entry: RouterDecision, waiting: Bool, busy: Bool, title: (String) -> String?)
        -> (state: ActionRun.State, detail: String, session: String?) {
        if waiting { return (.running, waitingWords, nil) }
        if busy { return (.running, "", nil) }
        let failed = entry.done.compactMap { if case .failed(let why) = $0 { why } else { nil } }.last
        var sent: String?
        for item in entry.done {
            switch item {
            case .sent(let to, _, _): sent = to
            case .answered(let card): sent = sent ?? card
            default: break
            }
        }
        if let sent {
            let session = entry.links.sessions.last
            return (.done, "sent to " + (session.flatMap(title) ?? sent), session)
        }
        if let failed { return (.failed, failed, nil) }
        if entry.reply?.hasPrefix("Dismissed") == true { return (.failed, "dismissed in the Router", nil) }
        return (.failed, "nothing was sent", nil)
    }
}

extension Store {
    /// An action's message moved on in the Router (asked you, was sent, started a session, failed): its runs say so. Nothing
    /// for a message that isn't an action's. `dispatcher`: the one routing it (the store's own unless a test has another).
    func followActionRun(_ decision: UUID, dispatcher: RouterDispatcher? = nil) {
        guard let entry = router.decisions.last(where: { $0.id == decision }) else {
            // Its entry is gone from the history: what became of it can't be told any more.
            var ledger = actionLedger
            for (key, run) in ledger.runs where run.message == decision && run.state == .running {
                ledger.runs[key]?.state = .failed
                ledger.runs[key]?.detail = "its message is no longer in the Router's history"
            }
            if ledger != actionLedger { actionLedger = ledger }
            return
        }
        guard entry.fromAction != nil else { return }
        let dispatcher = dispatcher ?? routerDispatcher
        let (state, detail, session) = InboxActions.outcome(
            of: entry, waiting: dispatcher.askBacks.contains { $0.id == decision }, busy: dispatcher.progress[decision] != nil,
            title: { [threads] in threads[$0]?.title })
        var ledger = actionLedger
        for (key, run) in ledger.runs where run.message == decision && run.state != .baselined {
            var next = run
            next.state = state
            next.detail = detail
            if let session { next.sessionID = session }
            if next != run { ledger.runs[key] = next }
        }
        if ledger != actionLedger { actionLedger = ledger }
    }
}
