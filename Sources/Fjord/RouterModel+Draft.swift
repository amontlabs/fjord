import AppKit
import SwiftUI

// Router v2's page model: the draft, where it goes (the read, the destination row, the places), and Return.

extension RouterModel {
    // MARK: The draft and where it goes

    func setDraft(_ text: String) {
        guard text != draft else { return }
        let wasEmpty = draft.isEmpty
        let grew = text.count > draft.count
        // Typing again takes the words back from a held Return.
        unhold()
        // The page's own writes (Return emptying the composer, a prefill) never untick a card: only a pill you take out
        // does (`RouterAnswerPills`).
        if text.isEmpty {
            let syncing = syncingAnswers
            syncingAnswers = true
            mentions = []
            syncingAnswers = syncing
            // The draft empties in the same transaction as the row's reset: written apart (no animation, then the
            // spring), SwiftUI updated the page synchronously between the two, inside the key's handler.
            animate(.spatial) {
                draft = text
                if scripted || still { updateScriptedMention() }
                read = nil; explicit = nil; waved = false; lit = 0; placesMenu = false
                splitAt = nil; splitMine = [:]
                reading = false
                launchMine = RouterLaunchAsk(); launchPills = RouterLaunchAsk(); launchFocus = nil; launchMenu = nil; launchRolls = [:]
            }
            return
        }
        // Words from the page with no pill for each mark carry none; the cards' answers come back as their pills.
        if mentions.count != text.filter({ $0 == MentionText.mark }).count {
            let syncing = syncingAnswers
            syncingAnswers = true
            mentions = []
            syncingAnswers = syncing
        }
        draft = text
        if scripted || still { updateScriptedMention() }
        // The answers' pills put back lead the words: that write read the draft.
        answersChanged()
        if draft != text { return }
        if wasEmpty { animate(.spatial) { read = nil } }
        // More words: a guess waved off is asked again.
        if grew, waved { waved = false }
        startRead()
    }

    func unhold() {
        heldPrior = nil
        heldDigit = nil
        if held { animate(.fade) { held = false } }
    }

    /// The Router's model reads the draft: its mark shows in the row until the read lands. A thread pill is an explicit
    /// place (1.5): nothing is read for it.
    private func startRead() {
        // Answer pills alone go to their threads as picks: nothing to read.
        if pilled || draftEmpty { reading = false; return }
        reading = true
        let plain = RouterMentions.plain(draft, marks: mentions)
        source?.read(plain.text, selected: selectedThread?.id, mentions: plain.mentions)
    }

    /// The draft as the Router and the thread get it: each pill as "@name", a thread pill leading the words (an
    /// address) taken out.
    var plainDraft: String { mentions.isEmpty ? draft : RouterMentions.plain(draft, marks: mentions).text }

    /// Which pill (counting the pills of the text) sets the explicit place, when it came from a thread pill.
    var explicitPill: Int? {
        guard let explicit, case .thread = explicit else { return nil }
        return mentions.firstIndex { RouterMentions.place($0.pointer, has: { thread($0) != nil }, projectName: { $0 }) == explicit }
    }

    private var pilled: Bool { explicitPill != nil }

    /// The composer's text changed (typing, a pick from the @ list, an undo): `marks` are its pills, one for each mark
    /// in `text` (`RouterMentions.marks`). A thread pill picked is the explicit place (the last one picked wins); one
    /// removed takes the place it set with it. `projectName`: a project's name from T3's id, for a new-thread pill.
    func edit(_ text: String, marks: [RouterMention], projectName: @escaping (String) -> String = { $0 }) {
        let before = mentions
        mentions = marks
        if before.map(\.pointer) != marks.map(\.pointer) {
            followPills(before: before.map(\.pointer), now: marks.map(\.pointer))
            var added = marks.map(\.pointer)
            for old in before.map(\.pointer) { if let i = added.firstIndex(of: old) { added.remove(at: i) } }
            let place = { (p: RouterPointer) in RouterMentions.place(p, has: { self.thread($0) != nil }, projectName: projectName) }
            if let picked = added.compactMap(place).last {
                animate(.fade) {
                    explicit = picked
                    waved = false
                    placesMenu = false
                    settleLaunch()
                }
            } else if let explicit, !marks.map(\.pointer).contains(where: { place($0) == explicit }),
                      before.contains(where: { place($0.pointer) == explicit }) {
                animate(.fade) {
                    self.explicit = nil
                    settleLaunch()
                }
            }
        }
        setDraft(text)
    }

    /// ⌫ with the caret at the start of the draft: the explicit place (one picked from the places menu) goes, and the
    /// draft is read again. A thread pill is dropped by taking it out of the text (`explicitPill`). False when there was
    /// none (the key is the text's).
    func dropExplicit() -> Bool {
        guard explicit != nil else { return false }
        animate(.fade) {
            explicit = nil
            waved = false
            placesMenu = false
            settleLaunch()
        }
        if !draft.isEmpty { startRead() }
        return true
    }

    /// A character typed with no field focused goes to the composer.
    func insert(_ characters: String) {
        setDraft(draft + characters)
        focusTick &+= 1
    }

    func draftContextChanged() {
        guard !draft.isEmpty, explicit == nil else { return }
        startRead()
    }

    /// The Router's read of the draft landed.
    func readLanded(_ new: RouterRead) {
        guard !draft.isEmpty, new.draft == plainDraft else { return }
        animate(.fade) {
            read = new
            reading = false
            // A pick you made yourself is never changed by a later read.
            if let explicit, let i = new.places.firstIndex(of: explicit) { lit = i } else if explicit == nil { lit = 0 }
            // ⌘1–3 pressed while the places were being read: that place is lit, and yours.
            if let digit = heldDigit, explicit == nil, !new.sure, digit < min(3, new.places.count) {
                explicit = new.places[digit]
                lit = digit
            }
            heldDigit = nil
            settleLaunch()
        }
        // Return came first: the words go if the read is sure and agrees with what the row showed. With nothing shown
        // yet (the skeleton), they go where Fjord is sure; unsure, the row shows the places and Return is asked again.
        guard held else { return }
        let prior = heldPrior
        unhold()
        // A split: every part goes when each is sure or lit by you; else the rows show the places and Return is asked again.
        if let split {
            if split.allSatisfy({ $0.sure || $0.mine }) { sendSplit(split) }
            return
        }
        let goes: Bool
        if let prior {
            goes = new.sure && new.places.first == .thread(prior)
        } else {
            goes = new.sure && !new.places.isEmpty
        }
        guard goes else { return }
        send()
    }

    private func mode(_ place: RouterPlace) -> String {
        guard case .thread(let id) = place, let t = thread(id) else { return "" }
        switch t.state {
        case .needsYou(.plan): return "asks for changes to the plan"
        // T3 takes typed words on a permission as a refusal with feedback.
        case .needsYou(.permission): return "denies it, with your words"
        case .needsYou(.form):
            let at = min(formAt[id] ?? 0, t.form.count - 1)
            return "answers “\(t.form[at].title)”"
        case .needsYou: return "answers its question"
        case .stopped, .done: return "starts a new turn"
        // An agent that can't take words mid-turn only queues them.
        case .working, .sent: return optionHeld || !t.steers ? Router.Copy.queueAfter : Router.Copy.steerNow
        }
    }

    /// What the destination row shows; nil when Return would send nothing.
    var destination: RouterDestination? {
        if draftEmpty {
            // The cards' answers in the composer (`RouterAnswerPills`): the selected card's first, else the first that
            // can go (a form owed an answer can't).
            let answers = pillContext.filter { $0.kind == .answer }
            if let a = answers.first(where: { $0.thread == selectedThread?.id }) ?? answers.first(where: ready) ?? answers.first {
                return .picked(thread: a.thread, words: a.answer ?? "")
            }
            guard let t = selectedThread else { return nil }
            if let words = answerWords(t) { return .picked(thread: t.id, words: words) }
            // A Stopped card: Return continues it, and the row says so as it does for any send.
            if t.state == .stopped { return .picked(thread: t.id, words: Router.Copy.continueWords) }
            return nil
        }
        if let explicit {
            if let read, !read.sure, read.places.contains(explicit) {
                return .unsure(read.places, lit: read.places.firstIndex(of: explicit) ?? 0, mine: true, mode: mode(explicit))
            }
            return .place(explicit, mode: mode(explicit))
        }
        if waved { return .noGuess }
        guard let read else {
            if let t = selectedThread { return .prior(thread: t.id) }
            return .reading
        }
        if read.places.isEmpty { return .noGuess }
        if read.sure { return .place(read.places[0], mode: mode(read.places[0])) }
        let at = min(lit, read.places.count - 1)
        return .unsure(read.places, lit: at, mine: false, mode: mode(read.places[at]))
    }

    /// A form's questions still without an answer.
    func openQuestions(_ t: RouterThread) -> Int { t.form.indices.filter { !answered(t, $0) }.count }

    /// What the row adds after its words when Return won't send yet: T3 is away, or a form has questions left.
    var rowNote: String? {
        if connectionLost { return Router.Copy.unreachableRow }
        if case .picked(let id, _)? = destination, let t = thread(id), !t.form.isEmpty {
            let open = openQuestions(t)
            if open > 0 { return Router.Copy.moreToAnswer(open) }
        }
        return nil
    }

    /// Return would send now: the send button is lit.
    var canSend: Bool {
        if split != nil { return !connectionLost && !held }
        guard let destination, !connectionLost, !held else { return false }
        switch destination {
        case .picked(let id, _): return thread(id).map { openQuestions($0) == 0 } ?? false
        case .noGuess: return false
        default: return true
        }
    }

    /// The thread the row sends to.
    var destinationThread: String? {
        switch destination {
        case .picked(let id, _), .prior(let id): return id
        case .place(.thread(let id), _): return id
        case .unsure(let places, let lit, _, _): if case .thread(let id) = places[lit] { return id } else { return nil }
        default: return nil
        }
    }

    /// The line the draft goes to, when it isn't the selected one: its name is outlined, dashed.
    var marked: String? {
        // A split message marks its targets itself (`pendingTargets`).
        guard !draft.isEmpty, split == nil, let id = destinationThread, selection != .line(id) else { return nil }
        return id
    }

    /// ⌘1–3 or a click on a place: it is lit, and yours.
    func light(_ index: Int) {
        guard case .unsure(let places, _, _, _)? = destination, index < places.count else { return }
        if scripted { RouterFrames.note("light \(index)") }
        animate(.fade) {
            explicit = places[index]
            lit = index
            placesMenu = false
            settleLaunch()
        }
    }

    /// ⌘1–3 with a draft: lights a place the row shows; pressed while the places are still being read, it is kept and
    /// lit when the read lands unsure. Never the Go menu's while there is a draft.
    func cmdDigit(_ index: Int) -> Bool {
        guard !draft.isEmpty else { return false }
        // A split message: they light a place for the part the Router isn't sure of.
        if lightPart(index) { return true }
        if case .unsure? = destination { light(index) } else if reading, explicit == nil { heldDigit = index }
        return true
    }

    /// Tab from the words when the row asks for a place (no guess, or not sure): its menu, ↑↓ and Return.
    func openPlaces() {
        animate(.fade) {
            placesMenu.toggle()
            if case .unsure(_, let lit, _, _)? = destination { placesIndex = lit } else { placesIndex = 0 }
            launchMenu = nil
        }
    }

    func movePlaces(down: Bool) {
        let n = menuPlaces.count
        guard n > 0 else { return }
        placesIndex = (min(placesIndex, n - 1) + (down ? 1 : n - 1)) % n
    }

    func choosePlaces() {
        let places = menuPlaces
        guard placesIndex < places.count else { return }
        choose(places[placesIndex])
    }

    /// A place picked from the row's menu.
    func choose(_ place: RouterPlace) {
        animate(.fade) {
            explicit = place
            waved = false
            placesMenu = false
            settleLaunch()
        }
    }

    /// The places menu: the read's, then a new thread in each project.
    var menuPlaces: [RouterPlace] {
        var out = read?.places ?? []
        for p in projects where !out.contains(.newThread(project: p)) { out.append(.newThread(project: p)) }
        return out
    }

    func setOption(_ down: Bool) {
        guard optionHeld != down else { return }
        animate(.fade) { optionHeld = down }
    }

    /// The composer's placeholder: what Return does (1.8).
    var placeholder: String {
        guard let t = selectedThread else { return "Message your threads" }
        switch t.state {
        case .needsYou(.question): return "Answer \(t.name)"
        case .needsYou(.form):
            let at = min(formAt[t.id] ?? 0, t.form.count - 1)
            return "Answer “\(t.form[at].title)”"
        case .needsYou(.plan): return "Or say what to change in the plan"
        case .needsYou(.permission): return "Or tell it what to do instead"
        case .stopped: return "Tell \(t.name) how to go on"
        case .working: return "Steer \(t.name)"
        case .done, .sent: return "Message \(t.name)"
        }
    }

    // MARK: Return

    /// Return (⌥Return: `queue`): sends what the destination row shows. With no row: Send again on a focused failure
    /// line, otherwise nothing. It never settles.
    func send(queue: Bool = false) {
        // Return to the commit of what it changed (the Sent line, the counts, the next card).
        let interval = RouterSignposts.begin("Send")
        defer { RouterSignposts.end(interval, afterCommit: true) }
        // A split goes whole: once the read of these very words is in (else held until it lands).
        if let split {
            if connectionLost || held { return }
            if !draftEmpty, reading || read?.draft != plainDraft {
                animate(.fade) { held = true }
            } else {
                sendSplit(split, queue: queue)
            }
            return
        }
        guard let destination else {
            if case .failure(let id)? = selection, !connectionLost { sendAgain(id) }
            return
        }
        // T3 is away, and the page knows: the words stay in the composer, the row says why.
        if connectionLost { return }
        switch destination {
        case .picked(let id, let words):
            guard let t = thread(id) else { return }
            // A form goes once every question has an answer: until then Return moves on to the next open one.
            if !t.form.isEmpty, let open = t.form.indices.first(where: { !answered(t, $0) }) {
                animate(.spatial) { formAt[id] = open }
                return
            }
            // The answers in the composer go by code, each to its thread.
            if hasAnswers { sendWithAnswers(nil, to: nil, queue: false); return }
            if t.state == .stopped { resume(id); return }
            deliver(words, to: .thread(id), queue: false, kind: answerKind(t))
        case .place(let place, _):
            if case .thread(let id) = place, let t = thread(id), !t.form.isEmpty, selection == .line(id) {
                // Typed on a form: the words answer the current question; they go with the rest of the form.
                let at = min(formAt[id] ?? 0, t.form.count - 1)
                animate(.spatial) {
                    typed[id, default: [:]][at] = plainDraft
                    picks[id]?[at] = nil
                    if let open = t.form.indices.first(where: { $0 != at && !answered(t, $0) }) { formAt[id] = open }
                }
                setDraft("")
                // The form's answer stays in the composer as its pill, with the words in it now.
                answersChanged()
                return
            }
            if hasAnswers { sendWithAnswers(plainDraft, to: place, queue: queue); return }
            deliver(plainDraft, to: place, queue: queue)
        case .unsure(let places, let lit, _, _):
            if hasAnswers { sendWithAnswers(plainDraft, to: places[lit], queue: queue); return }
            deliver(plainDraft, to: places[lit], queue: queue)
        case .prior(let id):
            // Not before the read: the words wait, shown held, and go if it agrees with the thread shown.
            heldPrior = id
            animate(.fade) { held = true }
        case .reading:
            animate(.fade) { held = true }
        case .noGuess:
            break
        }
    }

    /// What a picked answer is: options on a T3 request, else plain words.
    private func answerKind(_ t: RouterThread) -> RouterOutgoing.Kind {
        switch t.state {
        case .needsYou: return .answer(picks: picks[t.id] ?? [:], typed: typed[t.id] ?? [:])
        default: return .words
        }
    }

    /// `launch`: a new thread's settings when the composer emptied before (a split's second send); else the row's.
    func deliver(_ words: String, to place: RouterPlace, queue: Bool, kind: RouterOutgoing.Kind = .words, launch: RouterLaunch? = nil) {
        // A place that sends nothing never takes the words.
        if case .here = place { return }
        let name = read?.name
        // What the row showed, for the decision log.
        let shown = read
        let launch = launch ?? self.launch
        // The composer empties first: the row leaves saying what it said at Return, not what the send made of the thread.
        setDraft("")
        switch place {
        case .thread(let id):
            guard let t = thread(id) else { return }
            if (queue || !t.steers), t.state == .working {
                animate(.spatial) { update(id) { $0.queued = words } }
                lastSends[id] = (words, .words)
                source?.send(RouterOutgoing(thread: id, words: words, kind: .words, steering: false, queue: true, read: shown))
            } else {
                dispatch(words, to: t, kind: kind, read: shown)
            }
        case .newThread(let project):
            let id = source?.mintThread() ?? "new-\(fresh())"
            var t = RouterThread(id: id, name: name ?? Router.firstWords(words), title: words, project: project, state: .sent,
                                   sentence: .init(text: ""), since: now)
            t.naming = true
            t.order = fresh()
            t.sent = .init(words: words, status: .sending)
            t.launch = launch
            animate(.spatial) { threads.append(t) }
            lastSends[id] = (words, .words)
            source?.start(id, words: words, project: project, launch: launch, read: shown)
        case .here:
            return
        }
    }

    /// The thread's line becomes Sent, at the top of Working, in the same frame; the selection goes on to the next line
    /// that needs you when the words went from its card.
    func dispatch(_ words: String, to t: RouterThread, kind: RouterOutgoing.Kind, read shown: RouterRead? = nil) {
        let id = t.id
        // Into a run only when one is under way: a line still Sent has no run yet, and the words go as a message.
        let steering = t.state == .working
        backups[id] = (t, picks[id], kind)
        lastSends[id] = (words, kind)
        let next: RouterSelection?? = selection == .line(id) && t.section == .needsYou ? .some(nextNeedsYou(after: id)) : nil
        // A thread with open items stays where its most urgent one puts it: your words show in its block, nothing moves,
        // and the next card opens at once (a line marked in flight held the card's words back for a flight that wasn't).
        let stays = t.ledger.found.contains(where: \.live) && t.state != .stopped
        let change = {
            self.update(id) {
                $0.state = .sent
                $0.sent = .init(words: words, status: steering ? .steering : .sending)
                // A block's header keeps how long it has run: your words show in the block, with their own place.
                if !stays {
                    $0.since = self.now
                    $0.order = self.fresh()
                }
                $0.isNew = false
                $0.paused = false
                // Its open items are checked against your words: they show in the block at once, the items sheen.
                $0.ledger.sent(words)
            }
            self.picks[id] = nil
            self.typed[id] = nil
            self.formAt[id] = nil
            self.expanded.remove(id)
            if let next {
                self.selection = next
                self.snoozeMenu = nil
            }
        }
        if stays { animate(.spatial, change) } else { move(id, change) }
        if let next { advanced(to: next) }
        source?.send(RouterOutgoing(thread: id, words: words, kind: kind, steering: steering, queue: false, read: shown))
    }

    /// Your act moved the selection on: the card is shown; its "new" dot waits for your next key or pointer move.
    func advanced(to next: RouterSelection?) {
        guard case .line(let n)? = next else { pendingSeen = nil; return }
        pendingSeen = n
        show(n)
    }

    func nextNeedsYou(after id: String) -> RouterSelection? {
        let lines = shownLines.filter { $0.section == .needsYou }
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return nil }
        let rest = lines[(i + 1)...] + lines[..<i]
        return rest.first.map { .line($0.id) }
    }

    /// Continue on a Stopped card. T3 has no rerun: its own button sends these words, and the thread then shows them.
    func resume(_ id: String) {
        guard let t = thread(id), t.state == .stopped, !connectionLost else { return }
        dispatch(Router.Copy.continueWords, to: t, kind: .continuing)
    }

    func stop(_ id: String) { source?.stop(id) }
    func open(_ id: String) { source?.open(id) }

    /// Cancel on a queued row: the words go back to the composer.
    func cancelQueued(_ id: String) {
        guard let words = thread(id)?.queued else { return }
        animate(.spatial) { update(id) { $0.queued = nil } }
        source?.cancelQueued(id)
        setDraft(words)
        focusTick &+= 1
    }
}

// MARK: - The composer's pills

/// The composer's @ pills as the page reads them: the text holds one mark (`MentionText.mark`) for each pill, and the
/// model one `RouterMention` for each mark, its `range` being the mark's place in the draft.
extension RouterMentions {
    /// The pills of a draft, in order: each mark with the pointer it stands for and the name "@name" says.
    static func marks(_ draft: String, pointers: [RouterPointer], name: (RouterPointer) -> String) -> [RouterMention] {
        var next = pointers.makeIterator()
        var out: [RouterMention] = []
        for (i, c) in draft.enumerated() where c == MentionText.mark {
            guard let pointer = next.next() else { break }
            out.append(RouterMention(range: i..<(i + 1), pointer: pointer, name: name(pointer)))
        }
        return out
    }

    /// The draft as the Router and the thread get it: each pill as "@name", where the pointer says no more than the
    /// place the words go to (a thread pill leading the words) taken out with the space after it. The mentions are the
    /// pills left in it, by their characters in that text.
    static func plain(_ draft: String, marks: [RouterMention]) -> (text: String, mentions: [RouterMention]) {
        guard !marks.isEmpty else { return (draft, []) }
        var out = ""
        var count = 0
        var kept: [RouterMention] = []
        var next = marks.makeIterator()
        var leading = true
        var skipSpace = false
        var dropped = false
        for c in draft {
            if skipSpace, c == " " { skipSpace = false; continue }
            skipSpace = false
            guard c == MentionText.mark, let mark = next.next() else {
                if leading, !c.isWhitespace { leading = false }
                out.append(c)
                count += 1
                continue
            }
            if leading, mark.pointer.addresses {
                skipSpace = true
                continue
            }
            // A setting's pill is for the row's chips, not the message, and an answer's goes as the card's picks
            // (`RouterAnswerPills`): either goes, with the space after it.
            if mark.pointer.isSetting || mark.pointer.isAnswer {
                skipSpace = true
                dropped = true
                continue
            }
            leading = false
            let text = mark.pointer.said(mark.name)
            kept.append(RouterMention(range: count..<(count + text.count), pointer: mark.pointer, name: mark.name))
            out += text
            count += text.count
        }
        // The space a pill at the end was typed with goes too.
        if dropped { while out.last?.isWhitespace == true { out.removeLast() } }
        return (out, kept)
    }

    /// The place a pill names: a thread the page has, or a new thread in a project (by its name).
    static func place(_ pointer: RouterPointer, has thread: (String) -> Bool, projectName: (String) -> String) -> RouterPlace? {
        guard case .t3(let target) = pointer, let route = RouteTarget(target) else { return nil }
        switch route {
        case .thread(let id): return thread(id) ? .thread(id) : nil
        case .newThread(let project): return .newThread(project: projectName(project))
        }
    }
}
