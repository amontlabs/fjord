import Foundation

// What the Router changed in Fjord itself, kept so the user can see it in the history and take it back. A
// record holds the before and after of exactly the one thing it touched (a category, a group, the categories' order, a
// setting, the marks of some entries), nothing around it. The records live in the Router's state
// (`RouterState.changes`) and are saved with it.

/// A setting's value, whichever kind it is.
enum SettingValue: Codable, Hashable {
    case on(Bool)
    case number(Double)
    /// A date; `nil` is none (no snooze).
    case date(Date?)
}

struct EntryChange: Codable, Hashable {
    var thing: String
    var before: EntryMarks?
    var after: EntryMarks?
}

struct FjordChange: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    /// One line: "Created category Contributions", "Changed snooze to 1 hour", "Archived 3".
    var title: String
    /// What the card is about, as the model has it.
    var patch: Patch
    var revertedAt: Date?
    /// What the revert said ("Reverted (later edits to it were undone too)").
    var revertNote: String?
    /// Why it waits for your Apply: made by the Router but not applied (`FjordGate`). Nil once applied, or for one that
    /// applied at once.
    var pending: String?
    /// A waiting category change: the groups its rules name, as they were when it was made (or last refused). Its Details
    /// show them whole, and Apply refuses when they have changed since.
    var groups: [InboxGroup]?

    enum Patch: Codable, Hashable {
        /// `before` nil: made; `after` nil: deleted. `index`: where it was (or is).
        case category(index: Int, before: InboxCategory?, after: InboxCategory?)
        case group(index: Int, before: InboxGroup?, after: InboxGroup?)
        case order(before: [UUID], after: [UUID])
        case setting(key: String, before: SettingValue, after: SettingValue)
        case marks(state: String, [EntryChange])
        /// An action on the Router page (archive, reopen, mute), done at once and taken back by Revert.
        case cardAction(CardAction)
    }

    var isReverted: Bool { revertedAt != nil }
    /// Why the last Apply or Revert didn't go through, for a card still active or waiting (a reverted or discarded one
    /// shows its note as it is). Cleared by the next success.
    var failureNote: String? { isReverted ? nil : revertNote }

    init(date: Date = Date(), title: String, patch: Patch) {
        self.date = date
        self.title = title
        self.patch = patch
    }

    /// The SF Symbol the card shows for what changed (a category shows its own).
    var symbol: String {
        switch patch {
        case .category(_, let before, let after): (after ?? before)?.symbol ?? "tray"
        case .group(_, let before, let after): ((after ?? before)?.kind ?? .people) == .people ? "person.2" : "folder"
        case .order: "arrow.up.arrow.down"
        case .setting: "gearshape"
        case .marks: "checkmark.circle"
        case .cardAction(let action): action.symbol
        }
    }

    // MARK: Coalescing

    /// What a later change of one run does to an earlier one of the same run.
    enum Coalesced {
        /// They touch different things: both stay.
        case separate
        /// The two together change nothing (made, then deleted; changed, then changed back): neither is kept.
        case cancelled
        /// One record for both: the earlier one's before, the later one's after.
        case merged(FjordChange)
    }

    /// The one record that stands for `self` and then `later`, when they touch the same category, group, the order or
    /// setting. A marks change never joins another.
    func coalesced(with later: FjordChange) -> Coalesced {
        var merged = self
        switch (patch, later.patch) {
        case (.category(let index, let before, let middle), .category(let laterIndex, let laterBefore, let after))
            where (middle ?? before)?.id == (laterBefore ?? after)?.id && middle != nil:
            if before == after { return .cancelled }
            merged.patch = .category(index: after == nil ? laterIndex : index, before: before, after: after)
            merged.title = Self.title(forCategory: before, after)
        case (.group(let index, let before, let middle), .group(let laterIndex, let laterBefore, let after))
            where (middle ?? before)?.id == (laterBefore ?? after)?.id && middle != nil:
            if before == after { return .cancelled }
            merged.patch = .group(index: after == nil ? laterIndex : index, before: before, after: after)
            merged.title = Self.title(forGroup: before, after)
        case (.order(let before, _), .order(_, let after)):
            if before == after { return .cancelled }
            merged.patch = .order(before: before, after: after)
            merged.title = later.title
        case (.setting(let key, let before, _), .setting(let laterKey, _, let after)) where key == laterKey:
            if before == after { return .cancelled }
            merged.patch = .setting(key: key, before: before, after: after)
            merged.title = later.title
        default:
            return .separate
        }
        return .merged(merged)
    }

    // MARK: Titles

    static func title(forCategory before: InboxCategory?, _ after: InboxCategory?) -> String {
        switch (before, after) {
        case (nil, let after?): "Created category \(after.title)"
        case (let before?, nil): "Deleted category \(before.title)"
        case (let before?, let after?): before.name != after.name && rulesAndFlagsSame(before, after)
            ? "Renamed category \(before.title) to \(after.title)" : "Changed category \(after.title)"
        default: "Changed a category"
        }
    }

    private static func rulesAndFlagsSame(_ a: InboxCategory, _ b: InboxCategory) -> Bool {
        var a = a, b = b
        a.name = b.name
        return a == b
    }

    static func title(forGroup before: InboxGroup?, _ after: InboxGroup?) -> String {
        switch (before, after) {
        case (nil, let after?): "Created group \(after.name)"
        case (let before?, nil): "Deleted group \(before.name)"
        case (_, let after?): "Changed group \(after.name)"
        default: "Changed a group"
        }
    }

    // MARK: Previews, in words

    /// What a category change did, field by field (the card shows the rules as chips beside it).
    static func diff(_ before: InboxCategory, _ after: InboxCategory) -> [String] {
        var out: [String] = []
        if before.name != after.name { out.append("Name: \(before.title) → \(after.title)") }
        if before.symbol != after.symbol { out.append("Icon: \(before.symbol) → \(after.symbol)") }
        if before.color != after.color { out.append("Color: \(before.color.rawValue) → \(after.color.rawValue)") }
        if before.notifies != after.notifies { out.append("Notifications: \(before.notifies ? "on" : "off") → \(after.notifies ? "on" : "off")") }
        if before.hidden != after.hidden { out.append(after.hidden ? "Hidden from the bar" : "Shown in the bar") }
        if before.rules != after.rules {
            let removed = before.rules.filter { r in !after.rules.contains { $0.id == r.id } }.count
            let added = after.rules.filter { r in !before.rules.contains { $0.id == r.id } }.count
            let edited = after.rules.filter { r in before.rules.first { $0.id == r.id }.map { $0 != r } ?? false }.count
            let parts = [added > 0 ? "\(added) added" : nil, edited > 0 ? "\(edited) changed" : nil,
                         removed > 0 ? "\(removed) removed" : nil].compactMap { $0 }
            out.append("Rules: " + (parts.isEmpty ? "reordered" : parts.joined(separator: ", ")))
        }
        if before.actions != after.actions {
            out.append("Actions: " + (after.actions.isEmpty ? "none" : after.actions.items.map(\.title).joined(separator: ", ")))
        }
        return out
    }
}

// MARK: - Everything Apply allows

/// A change's whole before and after, in words, for the card to show before you apply it: every field, rule, action (its
/// full prompt or comment, trigger, model and effort), group member, position or mark. Nothing is cut or summarised.
struct ChangePayload: Equatable {
    var before: [String]
    var after: [String]
}

extension FjordChange {
    @MainActor
    func payload(store: Store) -> ChangePayload {
        let words = RuleWords(store: store)
        func category(_ c: InboxCategory?, groups: [InboxGroup]? = nil) -> [String] {
            guard let c else { return ["(none)"] }
            var out = ["Name: \(c.title)", "Icon: \(c.symbol)", "Color: \(c.color.rawValue)",
                       "Notifications: \(c.notifies ? "on" : "off")", c.hidden ? "Hidden from the bar" : "Shown in the bar"]
            if let section = c.section {
                out.append("Folder: " + (store.categories.first { $0.id == section }?.title ?? section.uuidString))
            }
            out += c.rules.isEmpty ? ["Rules: none"] : c.rules.enumerated().map { "Rule \($0.offset + 1): " + words.summary($0.element) }
            out += c.actions.isEmpty ? ["Actions: none"] : c.actions.items.enumerated().map { "Action \($0.offset + 1): " + Self.describe($0.element) }
            // Every member of every group its rules name: what a rule by a group takes is its members.
            out += FjordGate.groups(of: c, in: groups ?? store.groups).map { g in
                "Group \(g.name) (\(g.kind.rawValue)): " + (g.members.isEmpty ? "no members" : g.members.joined(separator: ", "))
            }
            return out
        }
        func group(_ g: InboxGroup?) -> [String] {
            guard let g else { return ["(none)"] }
            return ["Name: \(g.name)", "Kind: \(g.kind.rawValue)", "Members: " + (g.members.isEmpty ? "none" : g.members.joined(separator: ", "))]
        }
        func order(_ ids: [UUID]) -> [String] {
            ids.enumerated().map { i, id -> String in
                let name = store.categories.first { $0.id == id }?.title ?? id.uuidString
                return "\(i + 1). \(name)"
            }
        }
        switch patch {
        case .category(_, let before, let after):
            return ChangePayload(before: category(before), after: category(after, groups: isPending ? groups : nil))
        case .group(_, let before, let after): return ChangePayload(before: group(before), after: group(after))
        case .order(let before, let after): return ChangePayload(before: order(before), after: order(after))
        case .setting(let key, let before, let after):
            let display = FjordSetting.named(key)?.display ?? { "\($0)" }
            return ChangePayload(before: ["\(key): \(display(before))"], after: ["\(key): \(display(after))"])
        case .marks(_, let changes):
            func name(_ thing: String) -> String {
                store.things[thing].map { "\($0.repo)\($0.number.map { "#\($0)" } ?? "") · \($0.title)" } ?? thing
            }
            return ChangePayload(before: changes.map { "\(name($0.thing)): \(Self.describe($0.before))" },
                                 after: changes.map { "\(name($0.thing)): \(Self.describe($0.after))" })
        case .cardAction(let action):
            return ChangePayload(before: [action.before], after: [action.after])
        }
    }

    /// An action in full: what it is, when it runs, and its whole prompt or comment.
    static func describe(_ action: CategoryAction) -> String {
        let when = action.trigger == .enter ? "when a thing comes in" : "for each new fact"
        switch action.kind {
        case .askRouter(let prompt): return "\(action.title) (\(when)), prompt: \(prompt.words())"
        case .comment(let body): return "\(action.title) (\(when)), comment: \(body)"
        case .rerun: return "\(action.title) (\(when))"
        }
    }

    static func describe(_ marks: EntryMarks?) -> String {
        guard let marks else { return "no marks" }
        if marks.doneAt != nil { return "done" }
        return "not done, \(marks.acked.count) acknowledged, \(marks.seen.count) seen, \(marks.notified.count) notified"
    }
}

// MARK: - Settings

/// The settings the Router may change: the ones a person sets on the Settings page for how Fjord behaves.
/// Never the GitHub token, the account, quitting, or the Router's own switch. One table gives `get_settings`,
/// `set_setting`'s schema and the cards' words, so they can't disagree.
@MainActor
struct FjordSetting {
    let key: String
    /// "snooze", for "Changed snooze to 1 hour".
    let label: String
    let doc: String
    /// The JSON schema of the value.
    let schema: [String: Any]
    let read: (Store) -> SettingValue
    /// A value as the Router wrote it, or why not.
    let parse: (Any, Date) throws -> SettingValue
    let apply: (Store, SettingValue) throws -> Void
    let display: (SettingValue) -> String

    /// The real login item; tests stand something in for it.
    static var launchAtLogin: (read: () -> Bool, write: (Bool) throws -> Void) = ({ LaunchAtLogin.isEnabled }, { try LaunchAtLogin.set($0) })

    private static func flag(_ any: Any) throws -> SettingValue {
        guard let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw RouterTools.Failure("must be true or false") }
        return .on(n.boolValue)
    }

    private static func onOff(_ value: SettingValue) -> String {
        if case .on(let on) = value { return on ? "on" : "off" }
        return "?"
    }

    static let intervals: [Double] = [30, 60, 120, 300]

    static func intervalText(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) seconds" : seconds == 60 ? "1 minute" : "\(Int(seconds / 60)) minutes"
    }

    static let snoozes: [(word: String, seconds: TimeInterval?)] = [("off", nil), ("30m", 1800), ("1h", 3600), ("3h", 3 * 3600), ("tomorrow", -1)]

    /// Snooze words and what they mean now; `tomorrow` is 9:00 the next day, as Settings has it.
    static func snoozeDate(_ word: String, now: Date) -> Date? {
        switch word {
        case "30m": return now.addingTimeInterval(1800)
        case "1h": return now.addingTimeInterval(3600)
        case "3h": return now.addingTimeInterval(3 * 3600)
        case "tomorrow":
            let cal = Calendar.current
            return cal.date(byAdding: .day, value: 1, to: now).flatMap { cal.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
        default: return nil
        }
    }

    static let all: [FjordSetting] = [
        FjordSetting(key: "notifications", label: "desktop notifications", doc: "Desktop notifications for the inbox and the Router.",
                       schema: ["type": "boolean"], read: { .on($0.settings.notifications) }, parse: { v, _ in try flag(v) },
                       apply: { s, v in if case .on(let on) = v { s.settings.notifications = on } }, display: onOff),
        FjordSetting(key: "snooze", label: "snooze", doc: "Silences banners for a while: `off`, `30m`, `1h`, `3h`, or `tomorrow` (9:00).",
                       schema: ["type": "string", "enum": snoozes.map(\.word)],
                       read: { .date($0.isSnoozed ? $0.settings.snoozeUntil : nil) },
                       parse: { v, now in
                           guard let word = v as? String, snoozes.contains(where: { $0.word == word }) else {
                               throw RouterTools.Failure("must be one of \(snoozes.map(\.word).joined(separator: ", "))")
                           }
                           return .date(snoozeDate(word, now: now))
                       },
                       apply: { s, v in if case .date(let date) = v { s.settings.snoozeUntil = date.flatMap { $0 > Date() ? $0 : nil } } },
                       display: { v in
                           guard case .date(let date) = v, let date else { return "off" }
                           return "until " + date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
                       }),
        FjordSetting(key: "pollInterval", label: "check interval", doc: "How often Triage asks GitHub: 30, 60, 120 or 300 seconds.",
                       schema: ["type": "integer", "enum": intervals.map { Int($0) }], read: { .number($0.settings.pollInterval) },
                       parse: { v, _ in
                           guard let n = v as? NSNumber, intervals.contains(n.doubleValue) else {
                               throw RouterTools.Failure("must be one of \(intervals.map { String(Int($0)) }.joined(separator: ", ")) (seconds)")
                           }
                           return .number(n.doubleValue)
                       },
                       apply: { s, v in
                           if case .number(let n) = v, s.settings.pollInterval != n { s.settings.pollInterval = n; s.restartPolling() }
                       },
                       display: { v in if case .number(let n) = v { intervalText(n) } else { "?" } }),
        FjordSetting(key: "centerBar", label: "centering the bar", doc: "Keep the bar at the middle of its screen edge (dragging only picks the edge).",
                       schema: ["type": "boolean"], read: { .on($0.settings.centerPill ?? false) }, parse: { v, _ in try flag(v) },
                       apply: { s, v in if case .on(let on) = v { s.settings.centerPill = on } }, display: onOff),
        FjordSetting(key: "launchAtLogin", label: "launch at login", doc: "Open Fjord when the Mac starts.",
                       schema: ["type": "boolean"], read: { _ in .on(launchAtLogin.read()) }, parse: { v, _ in try flag(v) },
                       apply: { _, v in if case .on(let on) = v { try launchAtLogin.write(on) } }, display: onOff),
        FjordSetting(key: "sessionIcons", label: "icons picked for sessions", doc: "Icons picked for Claude sessions in the Router (their titles go to TypeSafe; needs its key).",
                       schema: ["type": "boolean"], read: { .on($0.agents.iconsEnabled) }, parse: { v, _ in try flag(v) },
                       apply: { s, v in if case .on(let on) = v, s.agents.iconsEnabled != on { s.setIconsEnabled(on) } }, display: onOff),
    ]

    static func named(_ key: String) -> FjordSetting? { all.first { $0.key == key } }

    /// The change's one line: "Changed snooze to 1 hour", "Turned off desktop notifications".
    func title(after: SettingValue, word: String?) -> String {
        switch after {
        case .on(let on): return "Turned \(on ? "on" : "off") \(label)"
        case .date(let date):
            guard date != nil else { return "Ended \(label)" }
            let said = ["30m": "30 minutes", "1h": "1 hour", "3h": "3 hours", "tomorrow": "tomorrow 9:00"][word ?? ""] ?? display(after)
            return "Changed \(label) to \(said)"
        case .number: return "Changed \(label) to \(display(after))"
        }
    }
}

// MARK: - The store's side

extension Store {
    /// After a change that is not the editor's: what the editor's undo steps hold is older than this (undoing one would
    /// quietly undo the change as well), so they go; and the actions take what the categories now match as old news.
    func categoriesChangedByRouter() {
        categoryHistory?.reset(to: self)
        categoriesEdited()
    }

    /// Takes a change back: only what it touched goes to its state before. A thing edited since is put back all the same,
    /// and the note says so. Nil when it can't (already reverted, or no longer kept).
    @discardableResult
    func revertFjordChange(_ id: UUID, now: Date = Date()) -> FjordChange? {
        changingInbox(.revert) { revertingFjordChange(id, now: now) }
    }

    private func revertingFjordChange(_ id: UUID, now: Date) -> FjordChange? {
        guard let message = router.changes.firstIndex(where: { $0.id == id }), !router.changes[message].isReverted,
              router.changes[message].pending == nil else { return nil }
        var change = router.changes[message]
        var edited = false
        switch change.patch {
        case .category(let index, let before, let after):
            let current = categories.first { $0.id == (before ?? after)?.id }
            if let before {
                if let i = categories.firstIndex(where: { $0.id == before.id }) {
                    edited = current != after
                    categories[i] = before
                } else {
                    edited = after != nil
                    categories.insert(before, at: min(index, categories.count))
                }
            } else if let after, let i = categories.firstIndex(where: { $0.id == after.id }) {
                edited = categories[i] != after
                categories.remove(at: i)
            }
            categoriesChangedByRouter()
        case .group(let index, let before, let after):
            if let before {
                if let i = groups.firstIndex(where: { $0.id == before.id }) {
                    edited = groups[i] != after
                    groups[i] = before
                } else {
                    edited = after != nil
                    groups.insert(before, at: min(index, groups.count))
                }
            } else if let after, let i = groups.firstIndex(where: { $0.id == after.id }) {
                edited = groups[i] != after
                groups.remove(at: i)
            }
            categoriesChangedByRouter()
        case .order(let before, let after):
            edited = categories.map(\.id).filter(after.contains) != after.filter { id in categories.contains { $0.id == id } }
            categories = Self.ordered(categories, by: before)
            categoriesChangedByRouter()
        case .setting(let key, let before, let after):
            if let setting = FjordSetting.named(key) {
                edited = setting.read(self) != after
                do { try setting.apply(self, before) } catch {
                    change.revertNote = "Couldn't put it back: \(error.localizedDescription)"
                    router.changes[message] = change
                    return change
                }
            }
        case .marks(_, let changes):
            for item in changes {
                if marks[item.thing] != item.after { edited = true }
                marks[item.thing] = item.before
            }
        case .cardAction(let action):
            do { try revertCardAction(action) } catch {
                change.revertNote = "Couldn't put it back: \(error.localizedDescription)"
                router.changes[message] = change
                return change
            }
        }
        change.revertedAt = now
        change.revertNote = edited ? "Reverted (later edits to it were undone too)" : "Reverted"
        router.changes[message] = change
        noteReverted(change.id)
        return change
    }

    /// `list` in the order of `ids`; what `ids` doesn't name follows, in its own order.
    static func ordered(_ list: [InboxCategory], by ids: [UUID]) -> [InboxCategory] {
        let known = ids.compactMap { id in list.first { $0.id == id } }
        return known + list.filter { c in !ids.contains(c.id) }
    }
}


// MARK: - Where Open goes

/// The place in the app a change's Open button shows.
enum FjordTarget: Equatable {
    /// The categories page, on this category's editor.
    case category(UUID)
    /// The categories page, with this group unfolded.
    case group(UUID)
    /// The categories page.
    case categories
    /// Settings, scrolled to a section.
    case settings(section: String)
    /// The Router page.
    case router
    /// The Router page, on this session (a stop names the exact one).
    case session(String)
    /// A thing in its list (its category, or the archive), picked and scrolled to.
    case entry(thing: String, category: UUID?, done: Bool)
}

extension FjordChange {
    /// It changed Triage (its categories, groups or inbox), not the app's settings.
    var touchesTriage: Bool {
        switch patch {
        case .setting, .cardAction: false
        default: true
        }
    }

    /// Where Open goes now: a category or group that is gone opens the page that listed it.
    @MainActor func target(in store: Store) -> FjordTarget {
        switch patch {
        case .category(_, let before, let after):
            guard let id = (after ?? before)?.id, store.categories.contains(where: { $0.id == id }) else { return .categories }
            return .category(id)
        case .group(_, let before, let after):
            guard let id = (after ?? before)?.id, store.groups.contains(where: { $0.id == id }) else { return .categories }
            return .group(id)
        case .order:
            return .categories
        case .setting(let key, _, _):
            return .settings(section: ["notifications", "snooze"].contains(key) ? SettingsView.notificationsID
                             : key == "sessionIcons" ? SettingsView.routerID : SettingsView.generalID)
        case .marks(_, let changes):
            guard let first = changes.first?.thing, let entry = store.entries.first(where: { $0.id == first }) else { return .categories }
            return .entry(thing: first, category: entry.categoryID, done: entry.isDone)
        case .cardAction(let action):
            return action.isMute ? .settings(section: SettingsView.routerID) : .router
        }
    }
}
