import AppKit
import Foundation

// Acts on a T3 thread from the brief (docs/design/t3-port-plan.md, Step 14). Each one applies at once, is sent to T3 as a
// command, and leaves a `FjordChange` whose Revert sends the opposite command. Read state, archive, snooze, settle, title and
// tags are T3's, so they agree with its sidebar and phone app. Fjord keeps only what it hides until T3 has confirmed.

/// An act on a brief entry's thread that Revert sets back: what `FjordChange.briefAction` records.
enum BriefAction: String, Codable, Hashable, Sendable {
    case archive, read, snooze, settle, rename, tag

    var label: String {
        switch self {
        case .archive: "Archived"
        case .read: "Marked read"
        case .snooze: "Snoozed"
        case .settle: "Settled"
        case .rename: "Renamed"
        case .tag: "Tagged"
        }
    }

    var symbol: String {
        switch self {
        case .archive: "archivebox"
        case .read: "checkmark.circle"
        case .snooze: "moon.zzz"
        case .settle: "checkmark.seal"
        case .rename: "pencil"
        case .tag: "tag"
        }
    }

    /// What the thread was before, as the entry's Details say it.
    var before: String {
        switch self {
        case .archive, .snooze, .settle, .read: "Needs you"
        case .rename: "Old title"
        case .tag: "Not tagged"
        }
    }

    /// T3 refuses a tag longer than this.
    static let tagLimit = 64
}

/// What an act carries beyond the thread: `FjordChange.briefAction`'s `mark`, with the two sides of a rename or a tag.
enum ThreadActDetail {
    private static let sep = "\u{1F}"

    static func rename(from old: String, to new: String) -> String { old + sep + new }
    static func tag(_ tag: String, on: Bool) -> String { tag + sep + (on ? "on" : "off") }

    /// (first, second) of a two-part detail.
    static func parts(_ detail: String) -> (String, String) {
        let p = detail.components(separatedBy: sep)
        return (p.first ?? "", p.count > 1 ? p[1] : "")
    }
}

extension Store {
    /// The commands an act sends going forward, or back for Revert.
    static func commands(for act: BriefAction, thread: String, detail: String, forward: Bool, now: Date = Date()) -> [T3Command] {
        switch act {
        case .read: return [forward ? .threadVisit(threadId: thread, visitedAt: T3Timestamp(date: now)) : .threadMarkUnread(threadId: thread)]
        case .archive: return [forward ? .threadArchive(threadId: thread) : .threadUnarchive(threadId: thread)]
        case .settle: return [forward ? .threadSettle(threadId: thread) : .threadUnsettle(threadId: thread)]
        case .snooze:
            if forward, let until = T3Timestamp(detail).date { return [.snooze(threadId: thread, until: T3Timestamp(date: until))] }
            return [.unsnooze(threadId: thread)]
        case .rename:
            let (old, new) = ThreadActDetail.parts(detail)
            let title = (forward ? new : old).trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? [] : [.threadRename(threadId: thread, title: title)]
        case .tag:
            let (tag, state) = ThreadActDetail.parts(detail)
            guard !tag.isEmpty, tag.count <= BriefAction.tagLimit else { return [] }
            return [.tagSet(threadId: thread, tag: tag, tagged: (state == "on") == forward)]
        }
    }

    /// Does an act on the entry's thread: hidden or marked here at once, sent to T3, and logged with its Revert. A refusal puts
    /// it back and says why on the entry. `hold` is what hides the thread meanwhile (default: the brief's); `refused` hears
    /// the reason after it is put back (default: the brief's `trouble`). Returns the change it logged.
    @discardableResult
    func threadAct(_ act: BriefAction, on t: BriefTarget, detail: String = "", title: String, now: Date = Date(),
                   hold: (@MainActor (_ on: Bool) -> Void)? = nil, refused: (@MainActor (String) -> Void)? = nil) -> UUID? {
        guard !Self.commands(for: act, thread: t.thread, detail: detail, forward: true, now: now).isEmpty else { return nil }
        let hide = hold ?? { [weak self] on in
            guard let self else { return }
            self.routerBriefs.holdAct(act, t, detail: detail, on: on, store: self)
        }
        hide(true)
        let change = FjordChange(date: now, title: "\(act.label) \(title)",
                                 patch: .briefAction(project: t.project, thread: t.thread, act: act, mark: detail))
        var state = router
        state.changes.append(change)
        state.pruneChanges()
        router = state
        logChange(change)
        let id = change.id
        send(Self.commands(for: act, thread: t.thread, detail: detail, forward: true, now: now)) { [weak self] reason in
            guard let self else { return }
            hide(false)
            if let refused { refused(reason) } else { self.routerBriefs.trouble[t] = reason }
            if let i = self.router.changes.firstIndex(where: { $0.id == id }) {
                var failed = self.router.changes[i]
                failed.revertedAt = Date()
                failed.revertNote = "T3 refused it: \(reason)"
                self.router.changes[i] = failed
            }
        }
        return id
    }

    /// Revert or Apply of an act: the opposite command (or the same again) and the hidden state set to match.
    func replayBriefAction(_ patch: FjordChange.Patch, forward: Bool) {
        guard case .briefAction(let project, let thread, let act, let detail) = patch else { return }
        routerBriefs.holdAct(act, BriefTarget(project: project, thread: thread), detail: detail, on: forward, store: self)
        send(Self.commands(for: act, thread: thread, detail: detail, forward: forward)) { [weak self] reason in
            self?.routerBriefs.trouble[BriefTarget(project: project, thread: thread)] = reason
        }
    }

    /// Sends the commands in order; `failed` hears T3's words for a refusal.
    private func send(_ commands: [T3Command], failed: @escaping @MainActor (String) -> Void) {
        Task { @MainActor [weak self] in
            for command in commands {
                do { try await self?.dispatch(command) } catch {
                    failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    return
                }
            }
        }
    }

    // MARK: Entry points

    func snoozeThread(_ t: BriefTarget, until: Date) {
        threadAct(.snooze, on: t, detail: T3Timestamp(date: until).text, title: routerBriefs.title(t))
    }

    func settleThread(_ t: BriefTarget) { threadAct(.settle, on: t, title: routerBriefs.title(t)) }

    /// A new title for the thread (`thread.metadata.update`); the old one is what Revert sends.
    func renameThread(_ t: BriefTarget, to title: String) {
        let old = threads[t.thread]?.title ?? routerBriefs.title(t)
        let new = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old else { return }
        threadAct(.rename, on: t, detail: ThreadActDetail.rename(from: old, to: new), title: old)
    }

    /// Tags (or untags) the thread; T3 keeps a tag to 64 characters.
    func tagThread(_ t: BriefTarget, tag: String, on: Bool = true) {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, tag.count <= BriefAction.tagLimit else { return }
        threadAct(.tag, on: t, detail: ThreadActDetail.tag(tag, on: on), title: routerBriefs.title(t))
    }

    /// The times the Snooze menu offers: an hour, three, tomorrow at 9:00.
    static func snoozeChoices(now: Date = Date()) -> [(title: String, until: Date)] {
        let cal = Calendar.current
        let tomorrow = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now) ?? now) ?? now
        return [("1 hour", now.addingTimeInterval(3600)), ("3 hours", now.addingTimeInterval(3 * 3600)), ("Tomorrow, 9:00", tomorrow)]
    }
}

/// The title asked for in a small alert (Rename in the brief's panel).
@MainActor enum RenameAsk {
    static func title(for old: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename thread"
        alert.informativeText = "The new title is T3's too."
        let field = NSTextField(string: old)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
