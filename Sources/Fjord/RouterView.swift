import AppKit
import SwiftUI

// What the Router's window is built on (`RouterCodeView` lays it out): the store's side of the Router (the switch, your
// messages, a form's answer through the hook), the window's model (the draft, its chips and @, the thread it replies to),
// the notice of what stands in the way, the needs-you lines and the Working list the bar shows.

// MARK: - Store

extension Store {
    /// A session's visible project keeps its execution owner and guest root separate from the host folder mirror.
    func routerSessionProject(_ sessionID: String) -> (name: String, color: Color?) {
        guard let start = router.pendingDesktopStarts.first(where: { $0.desktopSessionID == sessionID && $0.state == .matched }),
              let project = router.runsOnProjects.first(where: { $0.id == start.projectID }) else {
            let folder = threads[sessionID]?.folderKey ?? ""
            return (folderName(folder), projectColor(folder))
        }
        let owner = start.location.key
        return ("\(project.name) · \(start.alias) @ \(owner):\(start.folder)", projectColor(project.sourceFolder))
    }

    /// A project's key: local projects keep their folder key; guest folders include project and owner identity.
    func routerProjectGroupKey(sessionID: String, folder: String) -> String {
        guard let start = router.pendingDesktopStarts.first(where: { $0.desktopSessionID == sessionID && $0.state == .matched }) else {
            return folder
        }
        return "guest-project:\(start.projectID.uuidString):\(start.location.key):\(start.folder)"
    }

    func routerProjectGroupName(_ key: String) -> String {
        guard key.hasPrefix("guest-project:"),
              let start = router.pendingDesktopStarts.first(where: {
                  $0.state == .matched && routerProjectGroupKey(sessionID: $0.desktopSessionID ?? "", folder: $0.folder) == key
              }) else { return folderName(key) }
        return routerSessionProject(start.desktopSessionID ?? "").name
    }

    /// The Router's switch: it turns the reading of Claude's sessions, which it works on, on and off with it.
    func switchRouter(_ on: Bool) {
        if on { setAgentsEnabled(true) }
        setRouterEnabled(on)
        if !on {
            GuestRouterRuntime.shared.disableAll()
            setAgentsEnabled(false)
        }
    }

    /// The sessions working now (not those stopped on you), and those whose turn is over with subagents or commands still
    /// running (the tiles count them as working too); the longest running first.
    var routerWorkingRows: [ThreadRow] {
        allAgentRows.filter { ($0.session.running && !$0.waitsForYou) || (!$0.session.running && !$0.tasks.isEmpty) }
            .sorted { (Self.workingStart($0) ?? .distantFuture) < (Self.workingStart($1) ?? .distantFuture) }
    }

    /// Since when a row in the Working list works: its turn, or the oldest thing it left running.
    static func workingStart(_ row: ThreadRow) -> Date? {
        row.session.running ? row.workingSince : row.tasks.map(\.since).min()
    }

    /// The Router's own process must never reach real sessions from a demo or a playground: it answers for itself there.
    var routerIsPretend: Bool { Store.isDemo || !persists }

    /// Your message to the Router, with the thread it replies to and the projects you tagged; in a demo, a canned reply
    /// instead of a real process. Whether it went: an ask-back's target named that is gone since sends nothing.
    @discardableResult
    func sendToRouter(_ text: String, context: RouterContext = RouterContext(), now: Date = Date()) -> Bool {
        let text = RouterModel.sendable(text)
        guard !text.isEmpty else { return false }
        if routerIsPretend {
            var entry = RouterDecision(at: now, trigger: .you(text), decision: .init(intent: "message"), outcome: .done,
                                       links: .init(threads: context.replyTo.map { [$0.key] } ?? []))
            let mentions = RouterDispatcher.mentions(context.mentions, in: text)
            entry.mentions = mentions.isEmpty ? nil : mentions
            entry.reply = "In a demo the Router only says what it would do."
            logDecision(entry)
            return true
        }
        return routerDispatcher.submit(text, context: context) != nil
    }

    /// The form Fjord's hook holds for a thread now: on this Mac, or on the remote computer its Desktop session runs on.
    func heldForm(_ target: BriefTarget) -> PendingForm? {
        guestPendingForm(for: target)?.form ?? routerBriefs.localForm(target, store: self)
    }

    /// A remote computer's form for a thread: its Desktop session matched to the guest session the form is of.
    func guestPendingForm(for target: BriefTarget) -> GuestPendingForm? {
        guard let desktop = routerBriefs.desktopSession(target, store: self),
              let start = router.pendingDesktopStarts.first(where: { $0.desktopSessionID == desktop && $0.state == .matched })
        else { return nil }
        return router.guestPendingForms.first { $0.location == start.location && $0.form.cliSessionID == start.guestSessionID }
    }

    /// The last check before a form's answer is written: the Router is on, the thread still holds that very form and, for an
    /// answer the Router read, still the form it was read against.
    func answerStillValid(_ form: PendingForm, target: BriefTarget, snapshot: FormSnapshot?,
                          alsoValid: (@MainActor () -> Bool)? = nil) -> Bool {
        guard routerOn, alsoValid?() != false, let held = heldForm(target) else { return false }
        return held.id == form.id && held.toolUseID == form.toolUseID && snapshot.map { $0.holds(self) } != false
    }

    /// Writes a form's answer for its thread's session (the hook passes it on) through the shared `FormWriter`, off the main
    /// thread, or through the remote computer that holds it; in a demo, nothing is written. With a `snapshot` (an answer the
    /// Router read), it is written only while the thread still holds that very form, checked again right before the write.
    func answerForm(_ form: PendingForm, _ answers: [String: String], target: BriefTarget,
                    snapshot: FormSnapshot? = nil, alsoValid: (@MainActor () -> Bool)? = nil) async -> Result<Void, Error> {
        if let snapshot, !snapshot.holds(self) { return .failure(FormWriter.Cancelled()) }
        if routerIsPretend { return Result { _ = try FormBridge.validate(form, answers) } }
        if let guestForm = guestPendingForm(for: target), guestForm.form.id == form.id {
            do {
                try await GuestRouterRuntime.shared.answer(guestForm, answers: answers, target: target, snapshot: snapshot)
                logEntryAction("Answered the form", target: target)
                return .success(())
            } catch { return .failure(error) }
        }
        guard let dir = formBridge.dir else { return .failure(FormWriter.Cancelled()) }
        do {
            try await FormWriter.write(form, answers: answers, dir: dir, stillValid: { [weak self] in
                self?.answerStillValid(form, target: target, snapshot: snapshot, alsoValid: alsoValid) ?? false
            })
            logEntryAction("Answered the form", target: target)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// The same for a plan: your decision is written for the hook, which gives it to the session as Approve or Keep planning
    /// in the app would.
    func answerPlan(_ form: PendingForm, _ decision: PendingForm.PlanDecision, target: BriefTarget,
                    snapshot: FormSnapshot? = nil) async -> Result<Void, Error> {
        if let snapshot, !snapshot.holds(self) { return .failure(FormWriter.Cancelled()) }
        if routerIsPretend { return Result { _ = try FormBridge.answerData(form, plan: decision) } }
        let words = decision.approve ? "Approved the plan" : "Sent the plan back"
        if let guestForm = guestPendingForm(for: target), guestForm.form.id == form.id {
            do {
                try await GuestRouterRuntime.shared.answer(guestForm, plan: decision, target: target, snapshot: snapshot)
                logEntryAction(words, target: target)
                return .success(())
            } catch { return .failure(error) }
        }
        guard let dir = formBridge.dir else { return .failure(FormWriter.Cancelled()) }
        do {
            try await FormWriter.write(form, plan: decision, dir: dir, stillValid: { [weak self] in
                self?.answerStillValid(form, target: target, snapshot: snapshot) ?? false
            })
            logEntryAction(words, target: target)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

/// Content redrawn on the minute and only then (ages, the status line): nothing else ticks for it.
struct MinuteTicking<Content: View>: View {
    /// Out of sight: it stops on the minute it was at, and catches up once shown.
    var paused = false
    @ViewBuilder let content: (Date) -> Content

    init(paused: Bool = false, @ViewBuilder content: @escaping (Date) -> Content) {
        self.paused = paused
        self.content = content
    }

    var body: some View {
        TimelineView(Minutes(paused: paused)) { context in content(context.date) }
    }
}

/// Every minute on the minute, as `.everyMinute`; paused, only the moment it started.
private struct Minutes: TimelineSchedule {
    let paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, paused: paused)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let paused: Bool

        mutating func next() -> Date? {
            guard let date = upcoming else { return nil }
            if paused {
                upcoming = nil
            } else {
                let minute = (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
                upcoming = Date(timeIntervalSinceReferenceDate: minute + 60)
            }
            return date
        }
    }
}

/// A thread's words or a plan: inline Markdown (**bold**, `code`) as the sessions show it.
enum RouterText {
    /// Parsed once per text: the brief asks again on every redraw. Up to 1000 texts, 4 MB of them.
    private static let parsed = RenderCache<AttributedString>(countLimit: 1000, totalCostLimit: 4 << 20)

    static func inline(_ text: String) -> AttributedString {
        parsed.value(text, cost: text.utf8.count) {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        }
    }

    /// A plan's Markdown, line by line as written: headings in bold without their #, the rest with its inline styles.
    static func plan(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (i, raw) in text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            if i > 0 { out += AttributedString("\n") }
            let line = String(raw)
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("#") {
                var heading = inline(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                heading.inlinePresentationIntent = .stronglyEmphasized
                out += heading
            } else {
                out += inline(line)
            }
        }
        return out
    }
}

// MARK: - Window model

/// What the window remembers while it is closed (the draft and its chips), and what the keys act on. The thread it replies to
/// is the brief's (`RouterBriefs.mentioned`): one or more, whoever set them.
@Observable
@MainActor
final class RouterModel {
    var draft = "" {
        didSet { if draft != oldValue { sendRefused = nil; mentionChanged() } }
    }
    /// Why the draft wasn't sent (it stays in the composer), until it changes.
    var sendRefused: String?
    static let goneTarget = "Not sent: what you named is gone since. Pick where it goes on the ask, or say more."
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

    /// Looks for Claude Code once the window shows (the app updates its copy now and then): until the search has finished
    /// nothing is said, and Send waits. In a demo it is never missing. The binary known (`RouterStatus`, which every run
    /// takes its path from) is only checked to be still there, one stat; gone, or none known, it is looked for again.
    func checkClaudeCode(_ store: Store) async {
        if store.routerIsPretend {
            if claudeCodeMissing != false { claudeCodeMissing = false }
            return
        }
        guard store.routerStatus.codeRoot != nil || store.routerStatus.claudeCode != nil else {
            if claudeCodeMissing != false { claudeCodeMissing = false }
            return
        }
        let found = await store.routerStatus.current() != nil
        if claudeCodeMissing != !found { claudeCodeMissing = !found }
    }

    /// Sends the draft with its reply, its @pills (written as "@name" where they stand, their projects going with it) and the
    /// target you pinned; the composer keeps the focus for the next one.
    func send(store: Store) {
        // A proposed project takes the words (and an empty composer creates it).
        if answerProposal(store: store) { return }
        // Threads to reply to: your words go to each, no model. One that refuses them stays picked, with the words, so
        // sending again reaches only it.
        let briefs = store.routerBriefs
        if !briefs.mentioned.isEmpty, pointers.isEmpty, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let refused = briefs.mentioned.filter { !briefs.send(draft, to: $0, store: store) }
            if refused.isEmpty {
                caret = nil
                draft = ""
            } else if refused != briefs.mentioned {
                briefs.mentioned = refused
            }
            return
        }
        let (text, _) = sentDraft(store)
        guard !text.isEmpty, canSend(store) else { return }
        guard store.sendToRouter(text, context: context(store)) else {
            sendRefused = Self.goneTarget
            Announce.say(Self.goneTarget)
            return
        }
        caret = nil
        pointers = []
        draft = ""
        store.routerBriefs.focus(nil)
    }

    /// The composer takes the keyboard (typing anywhere in the window lands there).
    func reply() { focusRequest &+= 1 }

    // MARK: Chips and @

    /// Backspace at the start of the composer: the last reply chip goes.
    @discardableResult
    func removeLastChip(store: Store) -> Bool {
        guard !store.routerBriefs.mentioned.isEmpty else { return false }
        store.routerBriefs.mentioned.removeLast()
        return true
    }

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
        return RouterMentions.suggest(RouterMentions.candidates(store, except: Set(pointers), query: query, first: first),
                                      query: query)
    }

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

// MARK: - Notice

/// What stands in the way of using the Router, in one line, and the fix. Nothing when all is well.
struct RouterSetupNotice: View {
    let store: Store
    let model: RouterModel
    /// The view the notice is in, to know whether its window is on screen.
    @State private var place = ShownProbe.Place()

    var body: some View {
        Group {
            if !store.agents.enabled || !store.router.enabled {
                line("The Router is off.", color: Theme.amber, action: "Turn on") { store.switchRouter(true) }
            } else if model.claudeCodeMissing == true && store.routerStatus.claudeCode == nil {
                line("Claude Code wasn't found. Install or open the Claude desktop app.", color: Theme.amber,
                     action: "Look again") { Task { await model.checkClaudeCode(store) } }
            } else if let error = store.routerHookError {
                line("The form hook couldn't be installed: \(error)", color: Theme.red, action: nil) {}
            }
        }
    }

    private func line(_ text: String, color: Color, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(color).accessibilityHidden(true)
                Text(text).font(Theme.Typography.meta).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let action { ActionButton(action, action: perform) }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.md)
            Hairline()
        }
        .background(ShownProbe(place: place))
        // Said once its window is on screen, a moment after: not while the window's content is prepared out of sight, nor
        // once it has left the window again (the task is cancelled then).
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, place.isShown else { return }
            Announce.say(text, after: .zero)
        }
    }
}

/// Finds the window a SwiftUI view is in: whether it is on screen.
struct ShownProbe: NSViewRepresentable {
    @MainActor final class Place {
        weak var view: NSView?
        var isShown: Bool { view?.window?.isVisible == true }
    }

    let place: Place

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        place.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { place.view = view }
}

/// The projects an @ word matches: names that start with it first, then ones that contain it, then ones that hold its
/// letters in order (fuzzy); shorter names first within each.
enum RouterMentions {
    static func rank(_ projects: [(String, String)], query: String, limit: Int) -> [(folder: String, name: String)] {
        func score(_ name: String) -> Int? { Self.score(name, query: query) }
        struct Hit { var folder: String; var name: String; var score: Int }
        var hits: [Hit] = []
        for (folder, name) in projects {
            if let s = score(name) { hits.append(Hit(folder: folder, name: name, score: s)) }
        }
        hits.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name < b.name
        }
        return hits.prefix(limit).map { (folder: $0.folder, name: $0.name) }
    }
}

/// Router only: the sessions working now, under what needs you (the bar has no tiles to say so). One line each: the
/// project's colour, the title, what it is doing and for how long (on the minute); a click opens it in Claude.
struct RouterWorkingList: View {
    let store: Store
    /// Rows shown before the rest are counted.
    var limit = 5

    var body: some View {
        let rows = store.routerWorkingRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Eyebrow("Working", count: rows.count).padding(.horizontal, Theme.Space.md).padding(.top, 4).padding(.bottom, 2)
                MinuteTicking { now in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rows.prefix(limit)) { WorkingLine(row: $0, store: store, now: now) }
                    }
                }
                if rows.count > limit {
                    Text("\(rows.count - limit) more").font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, Theme.Space.md)
                }
            }
        }
    }
}

private struct WorkingLine: View {
    let row: ThreadRow
    let store: Store
    let now: Date
    @State private var hover = false

    /// How long, in whole minutes: the lists are redrawn once a minute, so seconds would only ever be wrong.
    private static func minutes(_ t: TimeInterval) -> String {
        let m = max(0, Int(t)) / 60
        if m < 1 { return "<1m" }
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    var body: some View {
        // A turn that is over but left things running: how many, since the oldest of them.
        let start = Store.workingStart(row)
        let since = Self.minutes(now.timeIntervalSince(start ?? now))
        let doing = row.session.running ? row.activity?.text ?? "Working" : row.tasksText ?? "Working"
        Button { store.openThread(row.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SessionGlyph(row: row, size: 16, dot: false)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(row.session.title).font(Theme.Typography.bodyMedium).foregroundStyle(Theme.text).lineLimit(1)
                    .layoutPriority(1)
                Text(doing).font(Theme.Typography.meta).foregroundStyle(row.session.running ? Theme.secondary : Theme.claude)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(since).font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.claude)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowHighlight(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open in Claude") { store.openThread(row.id) }
            if store.canPickIcons && row.entry.label == nil {
                Button(row.entry.icon == nil ? "Pick an icon" : "Pick another icon") { store.repickIcon(row.id) }
            }
        }
        .modifier(RunningTip(tasks: row.tasks))
        .accessibilityLabel(row.session.title)
        .accessibilityValue("working, \(row.projectName), \(doing), \(since)")
        .accessibilityHint("Opens it in Claude")
    }
}

/// What a session left running, by name, in a tooltip (nothing when it left nothing).
private struct RunningTip: ViewModifier {
    let tasks: [BackgroundWork]
    func body(content: Content) -> some View {
        if tasks.isEmpty { content } else { content.tip("Running", tasks.map(\.title).joined(separator: "\n")) }
    }
}

/// A brief entry on two short lines, for the bar's panel: the thread and how long it has waited, then what it waits for and
/// its project. Clicking it opens the Router on it.
struct BriefEntryLine: View {
    let entry: BriefEntry
    let store: Store
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let briefs = store.routerBriefs
        let title = briefs.title(entry.target)
        let project = briefs.names[entry.project].flatMap { $0.isEmpty ? nil : $0 } ?? BriefPage.fallbackName(entry.project)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: BriefEntryText.symbol(entry.kind)).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.amber)
                    Text(title).font(Theme.Typography.bodyMedium).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(BriefAge.text(briefs.clock().timeIntervalSince1970 - entry.since))
                        .font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
                Text("\(BriefEntryText.kindLabel(entry)) · \(project)" + (entry.question.map { " · " + $0 } ?? ""))
                    .font(Theme.Typography.meta).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowHighlight(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
        .accessibilityValue("\(BriefEntryText.kindLabel(entry)), \(project)")
        .accessibilityHint("Opens the Router on it")
    }
}
