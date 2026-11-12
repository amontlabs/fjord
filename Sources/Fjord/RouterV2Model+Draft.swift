import AppKit
import SwiftUI

// Router v2's page model: the draft, where it goes (the read, the destination row, the places), and Return.

extension RouterV2Model {
    // MARK: The draft and where it goes

    func setDraft(_ text: String) {
        guard text != draft else { return }
        let wasEmpty = draft.isEmpty
        let grew = text.count > draft.count
        draft = text
        // Typing again takes the words back from a held Return.
        unhold()
        if text.isEmpty {
            animate(.spatial) {
                read = nil; explicit = nil; waved = false; lit = 0; placesMenu = false
                reading = false
                launchMine = RouterV2LaunchAsk(); launchFocus = nil; launchMenu = nil; launchRolls = [:]
            }
            return
        }
        if wasEmpty { animate(.spatial) { read = nil } }
        // More words: a guess waved off is asked again.
        if grew, waved { waved = false }
        startRead()
    }

    func unhold() {
        heldPlace = nil
        heldPrior = nil
        heldTaken = nil
        heldDigit = nil
        if held { animate(.fade) { held = false } }
    }

    /// The Router's model reads the draft: its mark shows in the row until the read lands.
    private func startRead() {
        reading = true
        source?.read(draft, selected: selectedThread?.id)
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
    func readLanded(_ new: RouterV2Read) {
        guard new.draft == draft, !draft.isEmpty else { return }
        let before = read?.launch ?? RouterV2LaunchAsk()
        animate(.fade) {
            rolling {
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
                // A setting you wrote since the last read wins over the one you set by hand before writing it.
                if new.launch.model != nil, new.launch.model != before.model { launchMine.clear(.model) }
                if new.launch.effort != nil, new.launch.effort != before.effort { launchMine.clear(.effort) }
                if new.launch.access != nil, new.launch.access != before.access { launchMine.clear(.access) }
                if new.launch.plan != nil, new.launch.plan != before.plan { launchMine.clear(.mode) }
                settleLaunch()
            }
        }
        // Return came first: the words go if the read is sure and agrees with what the row showed. With nothing shown
        // yet (the skeleton), they go where Fjord is sure; unsure, the row shows the places and Return is asked again.
        guard held else { return }
        let shown = heldPlace, prior = heldPrior, marked = heldTaken
        unhold()
        let goes: Bool
        if let shown {
            goes = explicit == shown || (new.sure && new.places.first == shown)
        } else if let prior {
            goes = new.sure && new.places.first == .thread(prior)
        } else {
            goes = new.sure && !new.places.isEmpty
        }
        guard goes else { return }
        // Words are left out of the message only when you saw them marked before Return: otherwise the settings apply
        // and the draft goes as typed.
        let seen = marked != nil && marked == taken.map { String(draft[$0]) }
        send(asTyped: !seen)
    }

    private func mode(_ place: RouterV2Place) -> String {
        guard case .thread(let id) = place, let t = thread(id) else { return "" }
        switch t.state {
        case .needsYou(.plan): return "asks for changes to the plan"
        // T3 takes typed words on a permission as a refusal with feedback.
        case .needsYou(.permission): return "denies it, with your words"
        case .needsYou(.form):
            let at = min(formAt[id] ?? 0, t.form.count - 1)
            return "answers “\(t.form[at].title)”"
        // A step Fjord found: the thread asked nothing, the words start its next turn.
        case .needsYou(.step): return "answers it"
        case .needsYou: return "answers its question"
        case .stopped, .done: return "starts a new turn"
        // An agent that can't take words mid-turn only queues them.
        case .working, .sent: return optionHeld || !t.steers ? RouterV2.Copy.queueAfter : RouterV2.Copy.steerNow
        }
    }

    /// What the destination row shows; nil when Return would send nothing.
    var destination: RouterV2Destination? {
        if draft.isEmpty {
            guard let t = selectedThread else { return nil }
            if let words = answerWords(t) { return .picked(thread: t.id, words: words) }
            // A Stopped card: Return continues it, and the row says so as it does for any send.
            if t.state == .stopped { return .picked(thread: t.id, words: RouterV2.Copy.continueWords) }
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
    func openQuestions(_ t: RouterV2Thread) -> Int { t.form.indices.filter { !answered(t, $0) }.count }

    /// What the row adds after its words when Return won't send yet: T3 is away, or a form has questions left.
    var rowNote: String? {
        if connectionLost { return RouterV2.Copy.unreachableRow }
        if case .picked(let id, _)? = destination, let t = thread(id), !t.form.isEmpty {
            let open = openQuestions(t)
            if open > 0 { return RouterV2.Copy.moreToAnswer(open) }
        }
        return nil
    }

    /// Return would send now: the send button is lit.
    var canSend: Bool {
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
        guard !draft.isEmpty, let id = destinationThread, selection != .line(id) else { return nil }
        return id
    }

    /// ⌘1–3 or a click on a place: it is lit, and yours.
    func light(_ index: Int) {
        guard case .unsure(let places, _, _, _)? = destination, index < places.count else { return }
        if scripted { RouterV2Frames.note("light \(index)") }
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
    func choose(_ place: RouterV2Place) {
        animate(.fade) {
            explicit = place
            waved = false
            placesMenu = false
            settleLaunch()
        }
    }

    /// The places menu: the read's, then a new thread in each project.
    var menuPlaces: [RouterV2Place] {
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
        case .needsYou(.question), .needsYou(.step): return "Answer \(t.name)"
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
    /// line, otherwise nothing. It never settles. `asTyped`: a held Return whose marked words were never on screen.
    func send(queue: Bool = false, asTyped: Bool = false) {
        guard let destination else {
            if case .failure(let id)? = selection, !connectionLost { sendAgain(id) }
            return
        }
        // T3 is away, and the page knows: the words stay in the composer, the row says why.
        if connectionLost { return }
        switch destination {
        case .picked(let id, let words):
            guard let t = thread(id) else { return }
            if t.state == .stopped { resume(id); return }
            // A form goes once every question has an answer: until then Return moves on to the next open one.
            if !t.form.isEmpty, let open = t.form.indices.first(where: { !answered(t, $0) }) {
                animate(.spatial) { formAt[id] = open }
                return
            }
            deliver(words, to: .thread(id), queue: false, asTyped: true)
        case .place(let place, _):
            if case .thread(let id) = place, let t = thread(id), !t.form.isEmpty, selection == .line(id) {
                // Typed on a form: the words answer the current question; they go with the rest of the form.
                let at = min(formAt[id] ?? 0, t.form.count - 1)
                animate(.spatial) {
                    typed[id, default: [:]][at] = draft
                    picks[id]?[at] = nil
                    if let open = t.form.indices.first(where: { $0 != at && !answered(t, $0) }) { formAt[id] = open }
                }
                setDraft("")
                return
            }
            if waitsForRead(place) { return }
            deliver(draft, to: place, queue: queue, asTyped: asTyped)
        case .unsure(let places, let lit, _, _):
            if waitsForRead(places[lit]) { return }
            deliver(draft, to: places[lit], queue: queue, asTyped: asTyped)
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

    /// A new thread starts with the settings the row shows: while the draft is still being read (it may name some),
    /// Return waits for the read, as it does before a first one.
    private func waitsForRead(_ place: RouterV2Place) -> Bool {
        guard reading, case .newThread = place else { return false }
        heldPlace = place
        heldTaken = taken.map { String(draft[$0]) }
        animate(.fade) { held = true }
        return true
    }

    private func deliver(_ words: String, to place: RouterV2Place, queue: Bool, asTyped: Bool) {
        let name = read?.name
        // Without the words taken as a new thread's settings, when you saw them marked: those went into the chips.
        let message = asTyped ? draft : message
        let launch = launch
        // The composer empties first: the row leaves saying what it said at Return, not what the send made of the thread.
        setDraft("")
        switch place {
        case .thread(let id):
            guard let t = thread(id) else { return }
            // Words for a thread that exists are never taken: they go as written.
            if (queue || !t.steers), t.state == .working {
                animate(.spatial) { update(id) { $0.queued = words } }
                source?.queue(words, on: id)
            } else {
                dispatch(words, to: t, continuing: false)
            }
        case .newThread(let project):
            let id = "new-\(fresh())"
            var t = RouterV2Thread(id: id, name: name ?? RouterV2.firstWords(message), title: message, project: project, state: .sent,
                                   sentence: .init(text: ""), since: now)
            t.naming = true
            t.order = fresh()
            t.sent = .init(words: message, status: .sending)
            t.launch = launch
            animate(.spatial) { threads.append(t) }
            source?.start(id, words: message, project: project, launch: launch)
        case .here:
            break
        }
    }

    /// The thread's line becomes Sent, at the top of Working, in the same frame; the selection goes on to the next line
    /// that needs you when the words went from its card.
    func dispatch(_ words: String, to t: RouterV2Thread, continuing: Bool) {
        let id = t.id
        backups[id] = (t, picks[id])
        let next: RouterV2Selection?? = selection == .line(id) && t.section == .needsYou ? .some(nextNeedsYou(after: id)) : nil
        move(id) {
            update(id) {
                $0.state = .sent
                $0.sent = .init(words: words, status: t.isRunning ? .steering : .sending)
                $0.since = now
                $0.order = fresh()
                $0.isNew = false
                $0.paused = false
            }
            picks[id] = nil
            typed[id] = nil
            formAt[id] = nil
            expanded.remove(id)
            if let next {
                selection = next
                snoozeMenu = nil
            }
        }
        if let next { advanced(to: next) }
        source?.send(words, to: id, steering: t.isRunning, continuing: continuing)
    }

    /// Your act moved the selection on: the card is shown; its "new" dot waits for your next key or pointer move.
    func advanced(to next: RouterV2Selection?) {
        guard case .line(let n)? = next else { pendingSeen = nil; return }
        pendingSeen = n
        show(n)
    }

    func nextNeedsYou(after id: String) -> RouterV2Selection? {
        let lines = shownLines.filter { $0.section == .needsYou }
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return nil }
        let rest = lines[(i + 1)...] + lines[..<i]
        return rest.first.map { .line($0.id) }
    }

    /// Continue on a Stopped card. T3 has no rerun: its own button sends these words, and the thread then shows them.
    func resume(_ id: String) {
        guard let t = thread(id), t.state == .stopped, !connectionLost else { return }
        dispatch(RouterV2.Copy.continueWords, to: t, continuing: true)
    }

    func stop(_ id: String) { source?.stop(id) }
    func open(_ id: String) { source?.open(id) }

    /// Cancel on a queued row: the words go back to the composer.
    func cancelQueued(_ id: String) {
        guard let words = thread(id)?.queued else { return }
        animate(.spatial) { update(id) { $0.queued = nil } }
        setDraft(words)
        focusTick &+= 1
    }
}
