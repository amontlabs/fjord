import Foundation

// routerd.py's watched sends: a send failed after a click (taken but never confirmed, stuck, VANISHED; `finish`) is watched for
// ACCEPTED_WAIT of uptime, goes back to its place like a taken one, and is confirmed late by a later row of yours.

extension CourierCore {
    /// A watched send (failed after a click, `finish`) goes back to its place as a taken one does: the row that confirms it late comes
    /// only in a `rows` event of that place, and a tab that stays elsewhere would never read it. Once per move during its watch (it last
    /// went at another `moves`), behind every live run: only while no run acts, is about to, or has an open or a look in the page, and
    /// every taken send that may go back has (the tab idle, as for a taken send's going back), and no tool or dialog may use the page.
    /// It only opens the place: an open never types or clicks. Its going back is no move: a taken send whose place it leaves goes back
    /// to it once it is over (as after a move), and no other watched send goes back for it.
    func backToWatched() {
        if watched.isEmpty || watchOpen != nil || !connected() || CourierDo.blocked(board()["health"] ?? .null) != nil || toolBusy() { return }
        let board = self.board()
        for o in runs.values {
            if o.flag("paused") && !inPage(o) { continue }
            if o.flag("tool") || !yielded(o) || lookLive(o) || o.flag("open") || o.flag("moving_to") { return }
            let i = sql.intent(o.id)
            if o.get("back") != .int(moves) && !shows(board, Place(i.str("project"), i.str("thread"))) { return }  // its own going back comes first
        }
        for intentID in watched.keys.sorted() {
            if watchBack[intentID] == moves { continue }
            let i = sql.intent(intentID)
            let place = Place(i.str("project"), i.str("thread"))
            // Shown with its rows read since the tab arrived: a row of yours comes in its `rows` events. A project shown beside a thread
            // whose own rows weren't read again on arrival isn't: the open reads them.
            if shows(board, place) && CourierBoard.rowsOf(CourierBoard.placeOf(board, place.project, place.thread), place.thread) != nil { continue }
            watchBack[intentID] = moves
            for o in runs.values {  // a taken send whose place the tab leaves for this goes back to it once this is over
                let theirs = sql.intent(o.id)
                if !o.flag("tool") && shows(board, Place(theirs.str("project"), theirs.str("thread"))) { o["back"] = .null }
            }
            watchOpen = WatchOpen(open: command("open", [("project", i["project"] ?? .null), ("thread", i["thread"] ?? .null)]), to: place, id: intentID,
                                  holdUntil: clock() + CourierDo.timeout, movingFrom: nil, openFrom: arrivals, shown: shows(board, place))
            return wake()
        }
    }

    /// A watched send's going back is over. `used`: it counts for this move (a settled whole read of its place came, the page failed
    /// its open, or its hold ran out); else (superseded, lost with the host or a dropped page, the tab gone elsewhere before the read) it
    /// may go back again.
    func releaseWatch(used: Bool) {
        let w = watchOpen
        watchOpen = nil
        if let w, !used { watchBack.removeValue(forKey: w.id) }
    }

    /// A send failed after a click (taken but never confirmed, stuck, VANISHED; `finish`) is confirmed late by a later read of its place
    /// (project, thread: a rows event of that side) that proves it, for ACCEPTED_WAIT of uptime after its failure: the server may have
    /// had the words all along, queued behind a coordinator's turn.
    /// Its proof (baseline and anchors) is kept, and moves forward as a run's does. Only words that match prove it: another row of yours
    /// is someone else's message, and a row that proved another send (a live run of the same words claims it first) is that send's.
    /// Its watch over, its proof keeps only the tail any finished send's does (`do.tail`).
    func reconcileSends(_ place: Place) {
        unwatch()
        let board = self.board()
        let proved = provedAt(place)
        for intentID in watched.keys {
            let intent = sql.intent(intentID)
            guard Place(intent.str("project"), intent.str("thread")) == place, let p = proved[.int(intentID)] else { continue }
            if p.done && p.cause == nil {
                watched.pop(intentID)
                claimed[place, default: []].insert(p.key ?? "")
                confirmLate(intent, "confirmed late, by a later read that showed the words after it was failed", ["row": JSON(p.key)],
                            columns: [("proof", CourierDo.tail(intent["proof"] ?? .null))])
                continue
            }
            let anchored = CourierDo.anchor(board, intent["proof"] ?? .null)
            if anchored != (intent["proof"] ?? .null) { sql.update(clock(), intentID, [("proof", anchored)]) }
        }
    }

    /// [(id, proof)] of the sends of a place that a row of yours may prove, judged together (`do.proved_all`): the live runs that
    /// sent (a baseline), first, so a row of the same words goes to a live run before a send failed earlier, then the watched ones.
    /// `current`: a run's intent as `advance` holds it.
    func proofsAt(_ place: Place, _ current: JSON? = nil) -> [(id: JSON, proof: JSON)] {
        var live: [(id: JSON, proof: JSON)] = [], watchedProofs: [(id: JSON, proof: JSON)] = []
        for runID in runs.keys.sorted() {
            if runs[runID]!.flag("tool") { continue }
            let i = current != nil && current?["id"]?.asInt == runID ? current! : sql.intent(runID)
            if Place(i.str("project"), i.str("thread")) == place && !CourierDo.done.contains(i.str("status") ?? "") && i.obj("proof").has("baseline") {
                live.append((.int(runID), i["proof"]!))
            }
        }
        for intentID in watched.keys.sorted() {
            let i = sql.intent(intentID)
            if !runs.has(intentID) && Place(i.str("project"), i.str("thread")) == place && i.str("status") == "failed" && i.obj("proof").has("baseline") {
                watchedProofs.append((.int(intentID), i["proof"]!))
            }
        }
        return live + watchedProofs
    }

    /// {id: (done, cause, key)} for each send of the place `proofs_at` lists.
    func provedAt(_ place: Place, _ current: JSON? = nil) -> [JSON: CourierDo.Proved] {
        CourierDo.provedAll(board(), proofsAt(place, current), claimed[place] ?? [])
    }

    /// The watches that are over (past their uptime, or the intent no longer failed) end, each proof cut to its tail: at each tick
    /// (`next_deadline` gives the earliest end) and before a read is reconciled, so an expired proof isn't kept until a later read.
    func unwatch() {
        let now = uptime()
        for (intentID, until) in watched.pairs {
            let intent = sql.intent(intentID)
            if now >= until || intent.str("status") != "failed" {  // at its end: a tick then must not find it due again
                watched.pop(intentID)
                watchBack.removeValue(forKey: intentID)
                sql.update(intent.num("updated") ?? 0, intentID, [("proof", CourierDo.tail(intent["proof"] ?? .null))])  // cutting it changes no outcome
            }
        }
    }
}
