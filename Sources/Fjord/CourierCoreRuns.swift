import Foundation

// routerd.py's run machinery: the passes over the runs (`advance_all`), one run's step (`advance`), proof waiting (`await_proof`), and the
// end of a run (`finish`). Ported line for line.

extension CourierCore {
    /// Another run's look is under way (a taken send opened its place to read it once more, `looking` not yet passed): it holds the tab
    /// against every other run until it ends, at most until `looking`, so the row it waits for can show. A send made meanwhile would move
    /// the tab away, and the look would fail with the row in a place no longer shown.
    func lookingNow(_ run: Run) -> Bool {
        runs.pairs.contains { $0.key != run.id && !$0.value.flag("tool") && yielded($0.value) && lookLive($0.value) }
    }

    /// Another run has the tab: it hasn't yielded and is acting (it has opened, read or sent), or is paused with a command still in the
    /// page, or its look is under way (`looking_now`). Of two paused runs with commands in the page, the older goes first.
    func tabHeld(_ run: Run) -> Bool {
        let mine = inPage(run)
        if lookingNow(run) { return true }
        return runs.pairs.contains { i, o in
            i != run.id && !yielded(o) && ((!o.flag("paused") && !o.flag("lost") && acting(o)) || (o.flag("paused") && inPage(o) && !(mine && run.id < i)))
        }
    }

    /// One run's step. (Python ends a run whose step raises, so its waiter gets an outcome; a Swift step has no exceptions to catch.)
    func safely(_ run: Run, late: Bool = false) {
        advance(run, late: late)
    }

    /// One tab, one composer: only the oldest run that hasn't yielded acts. A yielded run waits for its proof and blocks nobody. A run
    /// added during the pass (a tool step whose earlier step was just confirmed) is the newest, and is advanced in it too. A run coming
    /// out of a pause waits its turn while another run has the tab: opening its own place would move the tab under it. One that waited
    /// is visited again once a run finished or yielded in the pass (a newer one that held the tab may have let it go), until none does.
    /// So is every taken send once one that went back finished, or a run that had the tab let it go (`back_due`): it may go back now.
    /// Last, a watched send may go back (`back_to_watched`).
    func advanceAll() {
        var acting = false
        var passed = Set<Int>(), held = Set<Int>(), freed = false
        func unpassed() -> Set<Int> { Set(runs.keys).subtracting(passed) }
        while !unpassed().isEmpty || (freed && !held.isEmpty) || backDue {
            if unpassed().isEmpty {  // the pass is over and a run let the tab go: the runs that waited for it are visited again
                let taken: Set<Int> = backDue ? Set(runs.pairs.filter { !$0.value.flag("tool") && yielded($0.value) }.map(\.key)) : []
                passed = passed.subtracting(held).subtracting(taken)
                held = []; freed = false; backDue = false
                acting = runs.pairs.contains { i, r in passed.contains(i) && !yielded(r) && !r.flag("paused") && !r.flag("lost") && !r.flag("open_wait") }
            }
            for runID in unpassed().sorted() {
                passed.insert(runID)
                guard let run = runs[runID] else { continue }
                if acting && !yielded(run) { continue }
                if run.flag("paused") && tabHeld(run) {
                    held.insert(runID)
                    continue
                }
                let was = yielded(run)
                safely(run)
                if runs.has(runID) {
                    let waits = run.pop("waits_tab")?.isTruthy ?? false
                    if waits || run.flag("gated") || run.flag("retry") { held.insert(runID) }  // waits for the tab: a pass that frees it comes back
                }
                let letsGo = !runs.has(runID) || (yielded(run) && !was)
                freed = freed || letsGo
                if letsGo && !was { backDue = true }  // a run that had the tab let it go: the taken sends may go back now, before the watched ones
                // A run whose open was lost or erred (`lost`, `open_wait`) opens again at its deadline: until then it holds nobody back.
                acting = acting || (runs.has(runID) && !yielded(run) && !run.flag("paused") && !run.flag("lost") && !run.flag("open_wait"))
            }
        }
        backToWatched()
    }

    func deadline(_ run: Run) {
        run.set("deadline", clock() + CourierDo.timeout)
        wake()
    }

    /// The page took the words: Send was clicked and the draft is empty now.
    func taken(_ run: Run, _ board: JSON, _ place: Place) -> Bool {
        let shown = CourierBoard.placeOf(board, place.project, place.thread)
        guard run.flag("clicked"), shows(board, place), let shown, let draft = shown.get("draft") else { return false }
        return CourierBoard.squash(draft.pyStr).isEmpty
    }

    /// The words are back in the draft after the page took them.
    func returned(_ board: JSON, _ place: Place, _ intent: JSON) -> Bool {
        let shown = CourierBoard.placeOf(board, place.project, place.thread)
        return shows(board, place) && shown != nil && CourierBoard.loose(shown?.get("draft")?.asString) == CourierBoard.loose(intent.str("words"))
    }

    /// A taken send's end with no row from you: the cause says what is known of it. It is watched (`finish`).
    func takenFailed(_ run: Run) {
        if run.flag("stuck") {  // the draft emptied after a click that had left the words there: a navigation may have dropped them
            return finish(run, "failed", "the words stayed in the draft after a click, then the draft emptied with no row from you: the page may not have sent them, and they were never confirmed")
        }
        if run.flag("went") { return finish(run, "failed", Self.went) }  // dropped with a page that went: no page said it took them
        if run.get("vanished_at") != nil { return finish(run, "failed", Self.vanished) }
        return finish(run, "failed", "the page took the words but never confirmed them")
    }

    /// The page took the words, or shows a row from you: never send again. Wait for the row; at ACCEPTED_WAIT open the place once, so a
    /// full scan can prove it, then fail. One whose words a reload lost (`vanished_at`) ends do.TIMEOUT after the page went (`reloaded`), or
    /// VANISH_GRACE after the reloaded page's rows showed it when that is later (a first render may not hold the bottom yet), rather
    /// than at ACCEPTED_WAIT: it fails then with no look while the tab shows the place (the reloaded page's rows were fetched afresh,
    /// and its stream delivers a later row of yours), and takes the look's open only when another run moved the tab away. A later row
    /// of yours still confirms it late (`reconcile_sends`).
    func awaitProof(_ run: Run, _ intent: JSON) {
        let now = clock()
        if !run.flag("accepted") { run.set("accepted", now) }
        var end = run.num("accepted")! + Self.acceptedWait
        // Not while the coordinator is mid-turn: the server may hold the words queued behind it, so the reloaded page shows no row yet.
        // Once it ends the queued row gets a full wait to show: `turn_seen` is the last look that saw the turn, or the first after it.
        let turning = CourierDo.turning(board(), intent["proof"] ?? .null)
        if turning || run.flag("turn_on") { run.set("turn_seen", now) }
        run["turn_on"] = .bool(turning)
        let early = run.get("vanished_at") != nil && !turning
        if early {
            let waits = [run.num("vanished_at")! + Self.vanishGrace, (run.num("reloaded") ?? 0) + CourierDo.timeout, (run.num("turn_seen") ?? 0) + CourierDo.timeout]
            end = min(end, waits.max()!)
        }
        let place = Place(intent.str("project"), intent.str("thread"))
        if now < end {
            if run.flag("looking") {  // its end moved on (the look found the coordinator mid-turn): the look is over, it holds nobody
                run["looking"] = .null; run["relooked"] = false  // a look taken again after this one has its own retry if its open is lost
                if !run.flag("open") {  // an open still in the page holds until its `done` (`going_back`)
                    run["moving_to"] = .null
                    run.pop("hold_until")
                }
            }
            run.set("deadline", end)
            // Another run took the tab away before the row came (a tool's read, a send elsewhere): once the tab is idle, go back at once,
            // so the row proves it now rather than at the look. Idle means every other run is a send the page took: a tool, even one
            // whose act is done, may still open its project to read.
            // A paused run with no command in the page (waiting for the Claude app, say) leaves the tab idle too.
            // It goes back once per time a run moved the tab (another send's going back doesn't count, so two never take turns).
            // Only with a host linked: an open sent with none is lost, and would use up the going back.
            // Not while another run is about to act (unpaused, not yielded: queued behind none, it moves the tab anyway): its move lets
            // this one go back after it.
            // Nor while a watched send's going back is in flight (`back_to_watched`): it goes back once that is over.
            if connected() && !shows(board(), place) && run.get("back") != .int(moves) && tabIdle(run) && !aboutToAct(run) && watchOpen == nil {
                // Several taken sends going back in one pass supersede each other's opens (the newest wins); the others go back on `back_due`.
                run["back"] = .int(moves); run["moving_to"] = place.json; run.set("hold_until", now + CourierDo.timeout)
                run["open_from"] = .int(arrivals); run["open_shown"] = .bool(shows(board(), place))  // an arrival after this, before its `done`, ends the move at the `done`
                run["open"] = .string(command("open", [("project", intent["project"] ?? .null), ("thread", intent["thread"] ?? .null)]))
            }
            return wake()
        }
        let board = self.board()
        let lost = run.flag("went") ? Self.went : Self.vanished
        if early && shows(board, place) && CourierDo.anchored(board, intent["proof"] ?? .null) { return finish(run, "failed", lost) }  // rows read afresh: no look
        if run.get("looking") == nil {
            // With the page away (Chrome closed, signed out, no host) no look can be taken: it fails at its bound, watched as any
            // taken send that failed, so a later row of yours still confirms it (`reconcile_sends`), and nobody waits past the bound.
            if CourierDo.blocked(self.board()["health"] ?? .null) != nil || !connected() {
                if now < (run.num("relook_by") ?? 0) {  // a look lost with the host is sent again if one links within a wait (`lost_open`)
                    run["deadline"] = run["relook_by"]
                    return wake()
                }
                return takenFailed(run)
            }
            if !tabIdle(run) { return deadline(run) }  // another run is using the tab, or a tool may read
            if let w = watchOpen {  // a watched send's going back is in flight: the look goes once it is over (its read, or its hold)
                run.set("deadline", w.holdUntil)
                return wake()
            }
            run.set("looking", now + CourierDo.timeout); moves += 1; run["moving_to"] = place.json
            run.set("hold_until", now + CourierDo.timeout); run["open_from"] = .int(arrivals); run["look_read"] = false; run["look_done"] = false
            run["open_shown"] = .bool(shows(board, place))
            run["open"] = .string(command("open", [("project", intent["project"] ?? .null), ("thread", intent["thread"] ?? .null)]))
            run["deadline"] = run["looking"]
            return wake()
        }
        // The look ends at its end, or once its open is done and a settled whole read of the place came after it with no row from you
        // (`look_read`, set in `handle`; the proof was checked against it before this): the outcome is known, and the tab is let go.
        if now >= (run.num("looking") ?? 0) || (run.flag("look_read") && !run.flag("open")) { return takenFailed(run) }
    }

    /// Another run, not paused and not yielded, will take the tab: it acts now or once the ones ahead of it let go.
    func aboutToAct(_ run: Run) -> Bool {
        runs.pairs.contains { $0.key != run.id && !$0.value.flag("paused") && !yielded($0.value) }
    }

    /// Another run's open is in the page for a send the page took (its going back, or its look): the tab is about to move there, so
    /// a run that checks or acts on the place the Board shows now waits for it. The open's `done` can come before the tab says it arrived (normally the arrival's `page`
    /// comes first; a muted port's replay, or the fake page, sends the `done` first): after an ok one it waits on until the tab arrives somewhere (`arrivals`): that place, or another (you moved the tab).
    /// Each event advances the runs. It holds at most do.TIMEOUT from the open's sending, then from its `done` (`hold_until`): an open
    /// the page dropped, or a tab that never arrived, holds nobody for longer (`next_deadline` wakes the runs then).
    func goingBack(_ run: Run) -> Bool {
        let board = self.board()
        if let w = watchOpen, clock() < w.holdUntil { return true }  // a watched send's going back holds until its place's settled whole read (`handle`)
        for (i, o) in runs.pairs {
            if i == run.id || o.flag("tool") || !yielded(o) || clock() >= (o.num("hold_until") ?? .infinity) { continue }
            let to = o.place("moving_to")
            if o.flag("open") || (to != nil && o["moving_from"]?.asInt == arrivals && !shows(board, to!)) { return true }
        }
        return false
    }

    /// No other run may move the tab: each is a send the page took, paused with no command in the page, or not acting (queued behind
    /// the runs that are, it moves nothing until they let the tab go).
    func tabIdle(_ run: Run) -> Bool {
        runs.pairs.allSatisfy { i, o in
            i == run.id || (yielded(o) && !o.flag("tool") && !lookLive(o)) || (o.flag("paused") && !inPage(o)) || !acting(o)
        }
    }

    /// The next small step for one run, from the Board and the events so far. `late`: its deadline passed.
    func advance(_ run: Run, late lateIn: Bool = false) {
        var late = lateIn
        var intent = sql.intent(run.id)
        if CourierDo.done.contains(intent.str("status") ?? "") {
            runs.pop(run.id)
            return
        }
        if run.flag("tool") { return advanceTool(run, intent, late) }
        if run.flag("went_due") { return }  // its dropped send is decided at the next `page` (`settle_unwent`)
        let board = self.board()
        // Nothing reached the thread while no click was reported and nothing was taken: a reply may still go to the coordinator instead.
        let gone: JSON? = intent.flag("thread") && !run.flag("clicked") && !run.flag("taken") ? CourierDo.stranded(board, intent) : nil
        if gone != nil && run.flag("app") {  // the app is back but the thread isn't yet: it gets one full wait to come back too
            if run.get("grace") == nil {
                run.set("grace", clock() + CourierDo.timeout)
                run["deadline"] = run["grace"]
                return wake()
            }
            if clock() < run.num("grace")! { return }
        }
        if let gone {
            if inPage(run) { cancelSend(run) }  // a send to the thread may still wait in the page
            // The sends so far went to the dead thread: a click of one reported after this doesn't make the coordinator's send click-only.
            run["app"] = .null; run["grace"] = .null; run["sends"] = []
            run["stage"] = "start"  // an open of the thread may be under way: the project is the place now
            intent = handOff(intent, gone)
        }
        if let refused = CourierDo.refusal(board, intent) {
            // One the page may have sent (a click reported, taken, or a send not heard from) failed: a later row of yours may still
            // confirm it (`watched`). Only one that surely never reached the server is refused.
            let mayHave = run.flag("clicked") || run.flag("taken") || !unheardSends(run).isEmpty
            return finish(run, mayHave ? "failed" : "refused", refused)
        }
        let place = Place(intent.str("project"), intent.str("thread"))
        var holds = false
        if intent.obj("proof").has("baseline") {
            let proved = provedAt(place, intent)[.int(run.id)] ?? CourierDo.Proved(done: false, cause: nil, key: nil)
            holds = proved.done
            let cause = proved.cause
            if holds && cause == nil { return finish(run, "confirmed", row: proved.key) }
            // A row from you with other words after the baseline (you typed in the chat meanwhile): a run that never clicked and isn't
            // taken has nothing of its own to wait for, so it fails now. One that may have sent keeps the cause and waits for its row: so
            // does one with a cut-off send not heard from, which may have clicked before the cancel reached it. A send still waiting in
            // the page is cancelled by the failure instead (and watched, `finish`).
            let cutOff = unheardSends(run).filter { !($0 == run.str("command") && inPage(run)) }
            if holds && !run.flag("clicked") && !run.flag("taken") && cutOff.isEmpty { return finish(run, "failed", cause) }
            if holds && intent.get("cause") != cause.map(JSON.string) { intent = sql.update(clock(), run.id, [("cause", JSON(cause))]) }
            // Each read placed against the baseline anchors Claude's rows after it: a busy chat's window can scroll past
            // the baseline (a coordinator's long turn while your message is queued), and a later read is placed by them.
            let anchored = !holds ? CourierDo.anchor(board, intent["proof"] ?? .null) : (intent["proof"] ?? .null)
            if anchored != (intent["proof"] ?? .null) { intent = sql.update(clock(), run.id, [("proof", anchored)]) }
        }
        if taken(run, board, place) { run["taken"] = true }
        // The tab reloaded right after a reported click: whatever the new page shows, the old one may have given the server the words, so
        // the run is taken, sends nothing more (not even click-only) and only waits for its row. Words back in a reloaded page's draft are
        // its saved draft, not the page giving up.
        if run.flag("reloaded") && run.flag("clicked") {
            run["taken"] = true
        }
        // The page gave up: it puts the words back, so nothing was sent. Only the page that took the click does: a page that replaced it
        // (a reload, maybe while no host was linked) shows its saved draft. A replayed click proves no page: it leaves `click_page` as it
        // was (an earlier live click's, or none).
        else if run.flag("taken") && (run["command"] ?? .null) == (lastSend[place].map(JSON.string) ?? .null) && run.get("click_page") == .int(pages)
                    && returned(board, place, intent) {
            run["taken"] = false; run["clicked"] = false; run["ignored"] = false; run["accepted"] = .null; run["stuck"] = false; late = true
            let said = !notice.text.isEmpty && clock() - notice.at < Self.noticeFresh ? ": \(notice.text)" : ""
            intent = sql.update(clock(), run.id, [("cause", .string("the page couldn't send it\(said)"))])
        }
        // The tab reloaded after the click, and the new page's rows of the place, read from the server and placed against the baseline,
        // hold no row from you after it: the old page went before the server had the words. Never sent again (the server may yet have
        // them): the look comes sooner, and the failure says why. Only a whole read the page marked `settled` says so: one that isn't
        // can lack the bottom rows, the run's among them.
        if run.flag("reloaded") && !holds && run.get("vanished_at") == nil && shows(board, place)
            && !unsettled.contains(intent.flag("thread") ? intent.str("thread") ?? "" : intent.str("project") ?? "") && CourierDo.anchored(board, intent["proof"] ?? .null) {
            run.set("vanished_at", clock())
        }
        if run.flag("taken") || holds { return awaitProof(run, intent) }  // the page took the words, or shows a row from you. It queues them while the coordinator replies.
        let why = (intent.flag("thread") ? CourierDo.appWait(board, intent) : nil) ?? CourierDo.blocked(board["health"] ?? .null)
        if why == CourierDo.appClosed {  // the page is up and would click: a send still waiting in it is cut off
            run["app"] = true; run["grace"] = .null
            if inPage(run) && run.str("stage") == "waiting" {
                cancelSend(run)
                run["stage"] = "start"
            }
        }
        if let why {
            run["paused"] = true; run["deadline"] = .null
            return mark(intent, "paused", why)
        }
        if run.flag("paused") {  // a lost open is behind it too: its deadline was dropped with the pause
            run["paused"] = false; run["lost"] = false; late = false
            run["stage"] = run.str("stage") == "opening" ? "start" : (run["stage"] ?? .null)
            mark(intent, "pending", nil)
            if run.str("stage") == "waiting" && run.get("dropped") == run.get("command") {  // its send went with a page that is gone (`replay`)
                let command = run.str("command") ?? ""
                if run.strings("unran").contains(command) {  // unless that page says it never ran: it is made again, in the same attempt
                    neverRan(run)
                    late = true
                } else if relinked && unran.contains(where: { $0.0 == run.id && $0.1 == command }) {  // the next `page` says if it was that page
                    run["went_due"] = true
                    unwent.append(run.id)
                    return
                } else {  // taken now: the run's checks are made again, out of the pause (a row may prove it), and the taken one waits for its proof
                    went(run)
                    return advance(run)
                }
            }
            if run.str("stage") == "waiting" { deadline(run) }
        }
        if run.flag("lost") {  // its open was superseded by another run's: it opens again at its deadline, not against that run
            if !late { return }
            run["lost"] = false
        }
        let held = (run.flag("held") && !toolBusy()) || (run.flag("retry") && !tabHeld(run))
        if run.str("stage") == "waiting" && !late && !held { return }
        run["held"] = false; run["retry"] = false
        run["gated"] = .bool(toolBusy())
        if run.flag("gated") {  // a tool's dialog may be open in the page: nothing is typed or opened until it ends, which advances this run at once
            if inPage(run) && run.str("stage") == "waiting" {
                run["ignored"] = true  // not tried: the same attempt goes on (a click reported already made it so)
                cancelSend(run)
                run["stage"] = "start"
            } else if run.str("stage") == "waiting" {  // its retry is due (TAKE_WAIT, a deadline) with nothing in the page: the gate's end makes it
                run["held"] = true
            } else if run.str("stage") == "opening" {  // its open would move the tab under the dialog: it opens again, with a full wait, once it ends
                if let o = run.str("open") {
                    command("cancel", [("target", .string(o))])
                    if run.get("open") == run.get("fresh_open") { run["fresh"] = false }  // the fresh open never ran: the next open may ask for it again
                    run["open"] = .null
                }
                run["stage"] = "start"
            }
            return deadline(run)  // only a wake-up: at it the run is gated again, or goes on
        }
        if run.str("stage") == "opening" && late {  // the tab showing the place with its whole read never settled is another failure
            let unsettledHere = shows(board, place) && unsettled.contains(intent.flag("thread") ? intent.str("thread") ?? "" : intent.str("project") ?? "")
            return finish(run, "failed", intent.str("cause") ?? (unsettledHere ? "the page never settled on that place" : "the page never showed that place"))
        }
        // A taken send's open will move the tab (`going_back`): the place the Board shows is about to change. Its `done` advances this run.
        // So does another taken send's look under way: it holds the tab until its end (`looking_now`), which advances this run.
        if (run.str("stage") != "waiting" || late || held) && (goingBack(run) || lookingNow(run)) {
            run["waits_tab"] = true  // a pass in which the look ends, or the open is done, comes back to it (`advance_all`)
            if run.get("deadline") == nil { deadline(run) }
            return
        }
        // A send held by a dialog goes on only to a place still ready: the tool may have moved the tab.
        if (run.str("stage") != "waiting" || late || held) && !ready(board, place) {
            // A project shown but never settled since the tab arrived on it, FRESH_AFTER on: the page may never have fetched its rows
            // this visit (a script injected into a long-lived tab, a re-open served from the page's cache), so the open asks the page
            // to make it (`fresh`: content.js leaves for `/code` and comes back, when it has seen no fetch since the arrival).
            // Once a run: one that still never settles fails at its deadline as before.
            let stale: Stale? = run.flag("fresh") ? nil : self.stale(board, place)
            if run.str("stage") != "opening" || stale == .yes {
                if inPage(run) { cancelSend(run) }  // its send may still wait in the page, and would click behind the next one
                let fresh: [(String, JSON)] = stale == .yes ? [("fresh", true)] : []
                run["fresh"] = .bool(run.flag("fresh") || stale == .yes)
                if run.str("stage") != "opening" { moves += 1 }
                deadline(run)  // a fresh open gets its own full wait too
                run["stage"] = "opening"
                run["open"] = .string(command("open", [("project", intent["project"] ?? .null), ("thread", intent["thread"] ?? .null)] + fresh))
                if !fresh.isEmpty { run["fresh_open"] = run["open"] }
            }
            if case .due(let at)? = stale {  // not due yet (a time, not True): a timer comes back to it (`next_deadline`, `tick`)
                run.set("fresh_at", at)
                wake()
            }
            return
        }
        run["fresh_at"] = .null  // the place settled first: no `fresh` open is due
        let key = intent.flag("thread") ? intent.str("thread") ?? "" : intent.str("project") ?? ""
        let proof = CourierDo.baselined(board, intent["proof"] ?? .null, known: known[key]?.keys ?? [])
        if proof != (intent["proof"] ?? .null) {
            intent = sql.update(clock(), run.id, [("proof", proof)])
            if !intent.flag("thread") { chatted.insert(intent.str("project") ?? "") }  // Fjord has seen this chat: what comes after its send is news, even if it was empty
        }
        if run.flag("clicked") && returned(board, place, intent) { run["stuck"] = true }  // a reported click left the words in the draft
        // A click the page reported but ignored is clicked again within the same attempt: that attempt's deadline stays the limit. A new
        // attempt is a send with no click reported, or a retry after the deadline or after the page erred.
        let again = run.flag("ignored") && clock() < (run.num("limit") ?? 0)
        if !again {
            if (intent["attempts"]?.asInt ?? 0) > CourierDo.retries {
                return finish(run, "failed", intent.str("cause") ?? "the words never showed up")
            }
            intent = sql.update(clock(), run.id, [("status", "pending"), ("attempts", .int((intent["attempts"]?.asInt ?? 0) + 1)), ("cause", .null)])
            run.set("limit", clock() + CourierDo.timeout)
        }
        let side = intent.flag("thread") ? "thread" : "project"
        // After a reported click the page may still take the words late: the retry only clicks words already in the draft, and any later
        // empty draft counts as taken, so the words are never typed twice. The page refuses a send while the tab shows another place.
        run["stage"] = "waiting"; run["ignored"] = false
        let clicks: [(String, JSON)] = run.flag("clicked") ? [("click_only", true)] : []
        // `intent`: whose send it is. The page treats a send that finds the draft empty right after a click of the same intent's words there as
        // a retry that crossed that click's `done` (it never types: another intent's same words, sent after the first was proved, do).
        run.pop("gone_at")  // kept for the send in the page when it went, not this one
        let sent = command("send", [("side", .string(side)), ("text", intent["words"] ?? .null), ("project", intent["project"] ?? .null),
                                    ("thread", intent["thread"] ?? .null), ("intent", .int(run.id))] + clicks)
        run["command"] = .string(sent)
        lastSend[place] = sent
        run.append("sends", .string(sent))  // every send the run issued: a click of an older one, reported late, still counts
        run.put("send_pages", sent, .int(pages))  // the document it was handed to (`replay`)
        run.put("send_scripts", sent, instance ?? .null)  // and the script in it
        run["deadline"] = run["limit"]
        wake()
    }

    /// The run is over. `row`: the key of the row that proved a send. It is kept in the intent's result and claimed for its place: it proves no other.
    func finish(_ run: Run, _ status: String, _ cause: String? = nil, row: String? = nil, changes extra: [(String, JSON)] = []) {
        var changes = extra
        runs.pop(run.id)
        // A send still waiting in the page must not click later, whatever the outcome (a confirmed run's retry may wait too). A tool's
        // command is cut off only on a failure: a confirming read's own `done` closes its dialog.
        let waiting = !run.flag("tool") && inPage(run)
        // A read whose settings already arrived is only closing its dialog: it is left to close, since a cancel now would stop that close
        // (the page would report the cut-off as the read's first and only `done`, leaving the dialog open). Sends wait for it until its
        // `done`, a `commands` that no longer lists it, or its deadline, when it is cancelled after all (`tick`).
        let reading = run.flag("tool") && run.get("mark") != nil && run.flag("command") && reads[sql.intent(run.id).str("project") ?? "", default: 0] > (run["mark"]?.asInt ?? 0)
        if reading {
            closing[run.str("command")!] = clock() + CourierDo.timeout
            wake()
        } else if let c = run.str("command"), run.get("dropped") != .string(c), status == "failed" || status == "refused" || waiting {
            command("cancel", [("target", .string(c))])
        }
        if !run.flag("tool"), let o = run.str("open") { command("cancel", [("target", .string(o))]) }  // its open (a look, say) still waits in the page: it must not move the tab later
        if status == "confirmed" { run.put("ms", "proved", .int(ms(run))) }
        let intent = sql.intent(run.id)
        var result = intent.obj("result").asObject ?? JSONObject()
        result["ms"] = run["ms"] ?? .null
        if let row, !row.isEmpty { result["row"] = .string(row) }
        if let row, !row.isEmpty { claimed[Place(intent.str("project"), intent.str("thread")), default: []].insert(row) }
        // A finished send's proof is read again only when it failed after a click (taken but never confirmed, stuck, VANISHED): the
        // server may yet show the words (`reconcile_sends`). Any other keeps a short tail of its baseline and anchors (`do.tail`), so the
        // intents table doesn't grow by hundreds of keys a send. A watched one is cut to it when its watch ends.
        let proof = intent.obj("proof")
        // A send failed while still in the page (`waiting`) is watched too: the page may click it before the cancel reaches it. So is
        // one with any send not heard from: a cut-off one may have clicked before its cancel arrived.
        let mayHave = run.flag("clicked") || run.flag("taken") || waiting || (!run.flag("tool") && !unheardSends(run).isEmpty)
        let watch = !run.flag("tool") && status == "failed" && mayHave && proof.has("baseline")
        if proof.has("baseline") && !watch {
            changes.removeAll { $0.0 == "proof" }
            changes.append(("proof", CourierDo.tail(proof)))
        }
        if watch { result["watch"] = .double(clock() + Self.acceptedWait) }  // its end on the wall clock, for a restart (`__init__`)
        let updated = sql.update(clock(), run.id, [("status", .string(status)), ("cause", JSON(cause)), ("result", .object(result))] + changes)
        if status == "failed" && result["acted"]?.isTruthy == true && Self.provable(.object(result)) { unproved.insert(updated["id"]?.asInt ?? 0) }
        if watch {  // a later row of yours still confirms it (`reconcile_sends`)
            watched[updated["id"]?.asInt ?? 0] = uptime() + Self.acceptedWait
            wake()  // its end is a deadline: the tick then cuts its proof (`unwatch`)
        }
        if run.get("back") != nil {  // it took the tab back to its place: another taken send may go back once more (`await_proof`)
            moves += 1
            backDue = true
        }
        follow(updated)
        settle(updated)
    }

    /// The tool steps queued after one that is over. When it is confirmed the next is checked and started, and whoever waits on this
    /// step waits on the next; otherwise every later step is refused, naming it.
    func follow(_ intent: JSON) {
        let id = intent["id"]?.asInt ?? 0
        guard let queued = chains.removeValue(forKey: id), !queued.isEmpty else { return }
        if intent.str("status") != "confirmed" {
            for i in queued { sql.update(clock(), i, [("status", "refused"), ("cause", .string(after(intent)))]) }
            var r = intent.obj("result").asObject ?? JSONObject()
            r["stopped"] = .array(queued.map(JSON.int))
            sql.update(clock(), id, [("result", .object(r))])  // a late confirmation says so on them
            return
        }
        let step = startStep(sql.intent(queued[0]))
        let stepID = step["id"]?.asInt ?? 0
        waiters[stepID] = waiters.removeValue(forKey: id) ?? []
        if queued.count > 1 { chains[stepID] = Array(queued.dropFirst()) }
        if step.str("status") == "pending" { return addRun(step, clock()) }  // the pass that finished this step advances it
        if step.str("status") == "refused" { follow(step) }  // so are the rest. A grant (`awaiting`) keeps them queued until `confirm` runs it.
        settle(step)
    }
}
