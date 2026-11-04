import Foundation

// Which of the Router's changes to Fjord wait for you. A run acts on your message, but it reads what sessions and
// GitHub wrote, and words there could try to steer it. So a change whose effect reaches outside Fjord (an action that
// comments on GitHub, starts sessions or re-runs CI by itself; what such a category runs on, or what reaches it past
// the categories before it; session titles sent to TypeSafe), one that takes something away (a category or group
// deleted, many things marked at once), and one your message didn't speak of (a setting it never named, marks it never
// asked for) is not applied: its card says why, with Apply and Discard. A local change you asked for applies at once,
// with Revert.

enum FjordGate {
    /// Things marked at once beyond which marking waits for Apply.
    static let manyMarks = 5

    /// Why `change` waits for your Apply, or nil when it applies at once. `request`: your message for the run;
    /// `categories`: the categories as they are now; `pending`: the changes waiting for your Apply, whose categories count as
    /// made (a group or category one depends on can't change unseen under it).
    static func reason(_ change: FjordChange, request: String, categories: [InboxCategory], pending: [FjordChange] = []) -> String? {
        let said = words(request)
        let categories = prospective(categories, pending: pending)
        switch change.patch {
        case .category(let index, let before, let after):
            guard let after else { return "Deleting a category waits for you" }
            // By value and by count: an action copied (the same one twice) runs twice, so it is as new as one never there.
            var had = Dictionary((before?.actions.items ?? []).map { ($0, 1) }, uniquingKeysWith: +)
            let new = after.actions.items.filter { action in
                guard let left = had[action], left > 0 else { return true }
                had[action] = left - 1
                return false
            }
            if !new.isEmpty {
                return "It adds an action that runs by itself (" + new.map(\.title).joined(separator: ", ") + ")"
            }
            if !after.actions.isEmpty, before?.rules != after.rules {
                return "It changes what a category with actions runs on"
            }
            // A thing goes to the first category that takes it: what an earlier one takes (its rules, whether it is shown)
            // decides what reaches a later one with actions.
            let routes = before.map { $0.rules != after.rules || $0.hidden != after.hidden } ?? !after.rules.isEmpty
            if routes {
                let at = categories.firstIndex { $0.id == after.id } ?? min(max(index, 0), categories.count)
                let later = categories[at...].filter { $0.id != after.id && !$0.actions.isEmpty }
                if !later.isEmpty {
                    return "It changes what reaches a later category with actions (" + later.map(\.title).joined(separator: ", ") + ")"
                }
            }
            return nil
        case .group(_, let before, let after):
            guard let after else { return "Deleting a group waits for you" }
            guard before != nil else { return nil }
            // Those with actions, and those before one: what they take decides what reaches it.
            let lastActing = categories.lastIndex { !$0.actions.isEmpty } ?? -1
            let users = categories.enumerated().filter { i, c in
                uses(c, group: after.id) && (!c.actions.isEmpty || i < lastActing)
            }.map(\.element)
            return users.isEmpty ? nil : "Categories with actions, or before one, use this group (" + users.map(\.title).joined(separator: ", ") + ")"
        case .order(let before, let after):
            let acting = Set(categories.filter { !$0.actions.isEmpty }.map(\.id))
            guard !acting.isEmpty else { return nil }
            let moved = acting.contains { before.firstIndex(of: $0) != after.firstIndex(of: $0) }
                || before.filter { !acting.contains($0) } != after.filter { !acting.contains($0) }
            return moved ? "The order decides which category's actions run on a thing" : nil
        case .setting(let key, _, let after):
            if key == "sessionIcons", case .on(true) = after { return "It sends your sessions' titles to TypeSafe" }
            guard let topic = topics[key], !said.contains(where: { word in topic.contains { word.hasPrefix($0) } }) else { return nil }
            return "Your message didn't speak of this setting"
        case .marks(_, let changes):
            if changes.count > manyMarks { return "It marks \(changes.count) things at once" }
            return said.contains(where: { word in markWords.contains { word.hasPrefix($0) } }) ? nil : "Your message didn't ask to mark anything"
        case .cardAction:
            return nil
        }
    }

    /// Why marking `changes` waits beyond the change's own reasons: together with what this turn marked already, more than
    /// `manyMarks` things (however the marking was split); or a thing your message doesn't name (`named`).
    static func marksReason(_ changes: [EntryChange], named: Set<String>, markedThisTurn: Set<String>) -> String? {
        let total = markedThisTurn.union(changes.map(\.thing)).count
        if total > manyMarks { return "It marks \(total) things in this run" }
        let unnamed = changes.filter { !named.contains($0.thing) }.count
        return unnamed == 0 ? nil : "Your message didn't name \(unnamed == 1 ? "a thing" : "\(unnamed) things") it marks"
    }

    /// What your message names, read once as its turn begins, before its run changes anything: the things it names (by
    /// reference, number or title) and the categories (by name), by id. A mark is bound to these: a name the run gives a
    /// category, or a title that comes in meanwhile, names nothing.
    struct Named: Equatable {
        var things: Set<String> = []
        var categories: Set<UUID> = []
    }

    @MainActor static func named(_ request: String, store: Store) -> Named {
        Named(things: Set(store.things.values.filter { names(request, thing: $0, category: nil) }.map(\.id)),
              categories: Set(store.categories.filter { calls(request, $0.name) }.map(\.id)))
    }

    /// Whether your message names a thing: its reference (`owner/repo#12`), its number (`#12`), its whole title, or the
    /// category it is marked by (`category`, when the marking is by category).
    static func names(_ request: String, thing: Thing, category: String?) -> Bool {
        let said = request.lowercased()
        if let number = thing.number {
            if mentions(said, ref: "\(thing.repo)#\(number)") { return true }
            if said.range(of: #"(?<![\w/])#\#(number)(?!\d)"#, options: .regularExpression) != nil { return true }
        }
        let title = (thing.kind == .workflow ? thing.workflowName ?? thing.title : thing.title)
        if title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4, calls(request, title) { return true }
        if let category, category.trimmingCharacters(in: .whitespaces).count >= 2, calls(request, category) { return true }
        return false
    }

    /// Whether your message says `name` as whole words, outside its references (`owner/repo#12`, `#12`), and with a word of
    /// its own besides the command's (done, seen, mark…): an issue titled "done", or "123 done", isn't named by "mark
    /// acme/api#123 done".
    static func calls(_ request: String, _ name: String) -> Bool {
        let name = words(name)
        guard name.contains(where: { !commandWords.contains($0) }) else { return false }
        let pieces = request.lowercased().replacingOccurrences(of: #"[\w.-]*/[\w.-]+(#\d+)?|#\d+"#, with: "\n",
                                                               options: .regularExpression).split(separator: "\n")
        return pieces.contains { piece in
            let said = words(String(piece))
            guard said.count >= name.count else { return false }
            return (0...(said.count - name.count)).contains { Array(said[$0..<($0 + name.count)]) == name }
        }
    }

    /// The words of a marking command, which name no thing or category however they are titled.
    private static let commandWords: Set<String> = [
        "done", "undone", "seen", "unseen", "read", "unread", "mark", "marked", "marking", "restore", "restored", "clear",
        "archive", "archived", "dismiss", "ack", "acknowledge", "reopen", "back", "open", "as", "all", "every", "everything",
        "it", "them", "the", "a", "an", "and", "or", "to", "of", "in", "this", "that", "these", "those", "please", "now", "again",
    ]

    /// Whether `text` says `ref` (`owner/repo#12`, or `owner/repo`) as a whole: not part of a longer one (`acme/api#123` is
    /// not `acme/api#12`, `acme/api-v2` is not `acme/api`, nor is `acme/api#12` the repo alone).
    static func mentions(_ text: String, ref: String) -> Bool {
        let tail = ref.contains("#") ? #"(?!\d)"# : #"(?![\w/-]|\.\w|#\d)"#
        let pattern = #"(?<![\w./-])"# + NSRegularExpression.escapedPattern(for: ref.lowercased()) + tail
        return text.lowercased().range(of: pattern, options: .regularExpression) != nil
    }

    /// The words that name each setting (a word of your message starting with one counts).
    private static let topics: [String: [String]] = [
        "notifications": ["notif", "banner", "alert", "mute", "silen", "quiet", "disturb"],
        "snooze": ["snooze", "notif", "banner", "alert", "mute", "silen", "quiet", "disturb", "pause"],
        "pollInterval": ["interval", "poll", "often", "frequen", "check", "refresh", "second", "minute", "sync"],
        "centerBar": ["center", "centre", "middle", "bar"],
        "launchAtLogin": ["login", "log", "launch", "start", "boot"],
        "sessionIcons": ["icon"],
    ]

    private static let markWords = ["done", "seen", "read", "unread", "mark", "restor", "clear", "archiv", "dismiss", "ack", "undone", "reopen", "back"]

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The categories as they would be with the waiting changes' categories applied, each where it would go.
    static func prospective(_ categories: [InboxCategory], pending: [FjordChange]) -> [InboxCategory] {
        var out = categories
        for change in pending where change.isPending {
            guard case .category(let index, _, let after?) = change.patch else { continue }
            if let i = out.firstIndex(where: { $0.id == after.id }) { out[i] = after }
            else { out.insert(after, at: min(max(index, 0), out.count)) }
        }
        return out
    }

    /// The groups a category's rules name, as they are in `groups`.
    static func groups(of category: InboxCategory, in groups: [InboxGroup]) -> [InboxGroup] {
        groups.filter { uses(category, group: $0.id) }
    }

    /// What changed in the groups a waiting change was shown with (`old`), now `new`: "Crew: added mallory, removed bob".
    static func groupChanges(from old: [InboxGroup], to new: [InboxGroup]) -> [String] {
        var out: [String] = []
        for g in old {
            guard let now = new.first(where: { $0.id == g.id }) else { out.append("\(g.name): no longer used or gone"); continue }
            var parts: [String] = []
            if now.name != g.name { parts.append("renamed to \(now.name)") }
            if now.kind != g.kind { parts.append("now \(now.kind.rawValue)") }
            let added = now.members.filter { !g.members.contains($0) }, removed = g.members.filter { !now.members.contains($0) }
            if !added.isEmpty { parts.append("added " + added.joined(separator: ", ")) }
            if !removed.isEmpty { parts.append("removed " + removed.joined(separator: ", ")) }
            if parts.isEmpty, now != g { parts.append("members reordered") }
            if !parts.isEmpty { out.append("\(g.name): " + parts.joined(separator: ", ")) }
        }
        for g in new where !old.contains(where: { $0.id == g.id }) {
            out.append("\(g.name) (" + (g.members.isEmpty ? "no members" : g.members.joined(separator: ", ")) + ")")
        }
        return out
    }

    /// Whether a category's rules name the group (by its id, anywhere in them).
    private static func uses(_ category: InboxCategory, group: UUID) -> Bool {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(category.rules) else { return true }
        return String(decoding: data, as: UTF8.self).contains(group.uuidString)
    }
}

extension FjordChange {
    /// Made, but waiting for your Apply (or Discard): nothing of it is applied yet.
    var isPending: Bool { pending != nil && !isReverted }
    /// Discarded before it was applied.
    var isDiscarded: Bool { pending != nil && isReverted }
}

extension Store {
    /// Applies a change that waited for you, as it was made: what it touched goes to its state after. Nil when it can't
    /// (not waiting, or no longer kept).
    @discardableResult
    func applyFjordChange(_ id: UUID, now: Date = Date()) -> FjordChange? {
        guard let i = router.changes.firstIndex(where: { $0.id == id }), router.changes[i].isPending else { return nil }
        var change = router.changes[i]
        // What its Details showed of the groups it uses is what it applies with: changed since, it waits again, saying how,
        // and its Details show them as they are now.
        if case .category(_, _, let after?) = change.patch {
            let now = FjordGate.groups(of: after, in: groups), shown = change.groups ?? []
            if now != shown {
                let what = FjordGate.groupChanges(from: shown, to: now)
                change.groups = now
                change.revertNote = nil
                change.pending = "A group it uses changed since you could see it (" + what.joined(separator: "; ") + "); check the details again"
                router.changes[i] = change
                return change
            }
        }
        let decision = router.decisions.first { $0.links.changes.contains(id) }?.id
        do {
            try changingInbox(.routerTool(decision: decision)) { try applyPatch(change.patch) }
        } catch {
            change.revertNote = "Couldn't apply it: \(error.localizedDescription)"
            router.changes[i] = change
            return change
        }
        change.pending = nil
        change.revertNote = nil
        router.changes[i] = change
        return change
    }

    /// Lets a waiting change go: nothing of it was applied, and nothing is.
    @discardableResult
    func discardFjordChange(_ id: UUID, now: Date = Date()) -> FjordChange? {
        guard let i = router.changes.firstIndex(where: { $0.id == id }), router.changes[i].isPending else { return nil }
        var change = router.changes[i]
        change.revertedAt = now
        change.revertNote = "Discarded"
        router.changes[i] = change
        noteReverted(change.id)
        return change
    }

    /// What a change makes of what it touched: its after.
    func applyPatch(_ patch: FjordChange.Patch) throws {
        switch patch {
        case .category(let index, let before, let after):
            if let after {
                if let i = categories.firstIndex(where: { $0.id == after.id }) { categories[i] = after }
                else { categories.insert(after, at: min(max(index, 0), categories.count)) }
            } else if let before, let i = categories.firstIndex(where: { $0.id == before.id }) {
                categories.remove(at: i)
            }
            categoriesChangedByRouter()
        case .group(let index, let before, let after):
            if let after {
                if let i = groups.firstIndex(where: { $0.id == after.id }) { groups[i] = after }
                else { groups.insert(after, at: min(max(index, 0), groups.count)) }
            } else if let before, let i = groups.firstIndex(where: { $0.id == before.id }) {
                groups.remove(at: i)
            }
            categoriesChangedByRouter()
        case .order(_, let after):
            categories = Self.ordered(categories, by: after)
            categoriesChangedByRouter()
        case .setting(let key, _, let after):
            try FjordSetting.named(key)?.apply(self, after)
        case .marks(_, let changes):
            for item in changes { marks[item.thing] = item.after }
        case .cardAction(let action):
            try applyCardAction(action)
        }
    }
}
