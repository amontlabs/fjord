import Foundation

// The engine's side of docs/design/router-watch-and-briefs.md: events by frame (§1.6), the frame set it alone owns (§1.3, §1.8), frame
// failure and staleness (§1.5), owed checks (§1.8), the run-less `home` step (§1.3), the handover grant (§1.7), and the log of items and
// thread statuses (§2). The `.answer` run is in CourierCoreFramesAnswer.swift.
//
// Frames are in use once the top frame reports `frames {have}`: until then no `frames`, `home` or checks are sent (a worker without
// frames, and the POC's fake page, see the engine as before). The log of items is kept either way.

extension CourierCore {
    static let frameWait = CourierDo.timeout  // seconds after `frame_loaded` for that frame's `page`: then `frame_inject`, then blank
    static let handoverWait = CourierDo.timeout  // seconds after a granted `handover` for `handover_done`, else `handover_abort`
    static let activeStatuses: Set<String> = ["working", "needs you", "paused"]

    // MARK: Entry

    /// An event the watch handles alone: anything from a frame, `frames {have}`, the handover's, and the `done` of `home` or an
    /// answer. Returns whether it was one.
    func handleWatch(_ event: JSON) throws -> Bool {
        let type = event.get("type")?.asString ?? ""
        if let frame = CourierFrame(event.get("frame")) {
            try handleFrame(frame, event)
            try afterWatch()
            return true
        }
        switch type {
        case "frames":
            watching.have = event.get("have")?.asArray ?? []
            if !watching.on {
                watching.on = true
                watching.homeWanted = true  // at launch the projects page's complete read lists projects made elsewhere
                syncFrames(base: true)
            }
            try afterWatch()
            return true
        case "frame_loaded", "frame_blank", "frame_gone", "frame_stuck":
            return true  // always carries `frame`; one without names no frame
        case "handover_wanted":
            watching.handoverBudget = event.get("budget")?.asInt ?? 6
            watching.finishesAtWant = watching.finishes
            try afterWatch()
            return true
        case "commands":
            if let h = watching.homeID {  // a `home` the top frame neither holds nor reported never ran
                let said = CourierPage.items(event.get("done")).contains { $0.get("id")?.asString == h }
                if !said && !(event.get("waiting")?.asArray ?? []).contains(.string(h)) { watching.homeID = nil }
            }
            return false  // the runs' replay goes on as before
        case "handover_done":
            try handoverDone()
            try afterWatch()
            return true
        case "done":
            let id = event.get("id")?.asString
            if let id, id == watching.homeID {  // the home step belongs to no run: its `done` sets nothing on any run
                watching.homeID = nil
                try advanceAll()
                try afterWatch()
                return true
            }
            if let id, watching.answers.values.contains(where: { $0.command == id }) {
                try answerDone(event)
                try afterWatch()
                return true
            }
            return false
        default:
            return false
        }
    }

    /// After a top-frame event: the log, statuses and departures of what it showed, a new document's frames.
    func watchTop(_ event: JSON, document before: (JSON?, JSON?)) throws {
        let type = event.get("type")?.asString ?? ""
        let (project, thread) = CourierPage.place(event)
        try logEvent(event, project: project, thread: thread)
        if type == "page" && event.get("gone") != .bool(true) && watching.on {
            if event.get("signed_in") == .bool(true) { for s in watching.states.values { s.staleTries = 0 } }
            if loaded?.numeric != nil && (before.0 != loaded || before.1 != instance) { newTopDocument() }
        }
        if type == "projects" && event.get("complete") == .bool(true) { for s in watching.states.values { s.staleTries = 0 } }
        try afterWatch()
    }

    /// What follows every event and tick once frames are in use: checks served, a wanted handover granted, `home`, the wanted set.
    func afterWatch() throws {
        guard watching.on else { return }
        try serveChecks()
        tryGrant()
        maybeHome()
        syncFrames()
    }

    // MARK: Events by frame (§1.6): never `pages`, `loaded`, `instance`, the health row or `notice`

    func handleFrame(_ f: CourierFrame, _ event: JSON) throws {
        let s = watching.state(f)
        switch event.get("type")?.asString ?? "" {
        case "page":
            if event.get("gone") == .bool(true) { return try frameGone(f) }
            let loaded = event.get("loaded"), inst = event.get("instance")
            if loaded?.numeric != nil && !(loaded == s.loaded && inst == s.instance) {
                for a in watching.answers.values where a.frame == f && a.inFlight && a.frameInstance != nil && a.frameInstance != inst { a.lost = true }
                s.loaded = loaded; s.instance = inst; s.settled = false; s.live = false; s.stop = false; s.streaming = false
            }
            s.loadDue = nil; s.injected = false
            s.health = JSONObject([("signed_in", event.get("signed_in") ?? .null), ("page_ok", event.get("page_ok") ?? .null), ("away", event.get("away") ?? .null)])
            if f.thread == nil && event.get("stand_in") == .bool(true) { return try archive(f.project) }
            if event.get("signed_in") == .bool(false) || event.get("away") == .bool(true) { stale(f) }
        case "rows":
            try frameRows(f, s, event)
        case "threads":
            try frameThreads(f, s, event)
        case "notice":  // kept for this frame's own answers' failures, never a send's cause
            s.notice = ((event.get("text").map { $0.isTruthy ? $0.pyStr : "" }) ?? "", clock())
        case "wake_me":
            if let ms = event.get("after")?.numeric, ms.isFinite {
                watching.wakes.append((clock() + min(max(ms, 0), Self.wakeCap) / 1000, f))
                wake()
            }
        case "done":
            try answerDone(event)
        case "commands":
            try frameReplay(f, event)
        case "frame_loaded":
            s.frameId = event.get("frameId")
            s.loadDue = clock() + Self.frameWait
            s.injected = false
            wake()
        case "frame_blank":
            try frameFailed(f)
        case "frame_gone":
            try frameGone(f)
        case "frame_stuck":
            s.stuck += 1
            if s.stuck >= 2 { stale(f) } else { reload(f) }
        default:
            break
        }
    }

    /// The event as if it were stamped with the frame's own place: a project frame may sit on `?thread=` for a moment, and the
    /// address is never its identity.
    func placed(_ f: CourierFrame, _ event: JSON, threadSide: Bool) -> JSON {
        var e = event
        e["path"] = .string("/code/project/\(f.project)")
        e["thread"] = threadSide ? JSON(f.thread ?? event.get("thread")?.asString) : .null
        return e
    }

    /// A frame's rows: positive evidence only. They merge by key into the place (never `full`), go through `ingest` only, and may let a
    /// send's proof hold sooner; `vanished`, `returned`, `reloaded` and `readWhole` stay the top frame's.
    func frameRows(_ f: CourierFrame, _ s: CourierFrameState, _ event: JSON) throws {
        let threadSide = event.get("side") == "thread"
        var e = placed(f, event, threadSide: threadSide)
        e["full"] = false
        let thread = threadSide ? e.get("thread")?.asString : nil
        if threadSide && thread == nil { return }
        var rows = CourierPage.seenRows(e).map { r -> JSON in
            var r = r
            r["fields"]?["frame"] = .string(f.name)
            return r
        }
        if !threadSide {
            let messages = rows.first?["fields"]?["messages"]?.asArray ?? []
            rows += claimRows(f.project, messages)
            if !messages.isEmpty { chatted.insert(f.project) }
        }
        try ingest(rows)
        try logRows(f.project, thread, event.get("rows"))
        let raw = CourierPage.items(event.get("rows"))
        for a in watching.answers.values where a.frame.thread == thread && raw.contains(where: { $0.get("key")?.asString == a.card && $0.get("answered") == .bool(true) }) {
            a.answered = true
        }
        if threadSide, f.thread != nil, event.get("full") == .bool(true), event.get("settled") == .bool(true) {
            s.settled = true
            s.stop = event.get("stop") == .bool(true)
            s.streaming = raw.contains { $0.get("streaming") == .bool(true) }
            live(f)
            try threadRead(f, s, raw, approval: event.get("approval")?.asString.map { !$0.isEmpty } ?? false)
        }
        try proveAnswers()
        try advanceAll()
        if !watched.isEmpty { try reconcileSends(Place(f.project, thread)) }
    }

    /// A project frame's thread rows. The one replacement a frame may make: a `listed` whole read (§2).
    func frameThreads(_ f: CourierFrame, _ s: CourierFrameState, _ event: JSON) throws {
        let e = placed(f, event, threadSide: false)
        try ingestThreads(f.project, e, listedOnly: true)
        if event.get("listed") == .bool(true) {
            s.settled = true
            live(f)
        }
        try advanceAll()
    }

    /// Thread rows into Seen (departure rows aside), and their items and statuses. `listedOnly`: an empty list says nothing unless
    /// `listed` (a frame's first partial render makes no departures).
    func ingestThreads(_ project: String, _ e: JSON, listedOnly: Bool) throws {
        let all = CourierPage.items(e.get("threads"))
        let listed = e.get("listed") == .bool(true)
        if !(listedOnly && all.isEmpty && !listed) { try ingest(CourierPage.seenRows(e)) }
        try threadsSeen(project, all, listed: listed)
    }

    // MARK: Statuses and departures (§2)

    /// The status a thread row says, per the measured row table; nil says nothing.
    static func rowStatus(_ t: JSON) -> String? {
        let state = t.get("state")?.asString
        switch t.get("section")?.asString {
        case "needs": return "needs you"
        case "running": return "working"
        case "done": return "done"
        case "active": return state == "working" ? "working" : state == "paused" ? "paused" : nil
        default:
            switch state {
            case "needs_you": return "needs you"
            case "working": return "working"
            case "paused": return "paused"
            case "done": return "done"
            default: return nil
            }
        }
    }

    /// A row's `time[datetime]`: ISO 8601, or a number (ms past 1e11, else seconds).
    static func rowTime(_ v: JSON?) -> Double? {
        if let n = v?.numeric { return n > 1e11 ? n / 1000 : n }
        guard let s = v?.asString else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }

    func threadsSeen(_ project: String, _ rows: [JSON], listed: Bool) throws {
        var ids = Set<String>()
        for t in rows {
            guard let id = t.get("thread")?.asString, !id.isEmpty, CourierPage.belongs(id, project) else { continue }
            ids.insert(id)
            if t.get("gone") == .bool(true) { try depart(project, id); continue }
            var content: JSON = ["title": .string(t.get("title")?.asString ?? "")]
            if let n = t.get("needs")?.asString, !n.isEmpty { content["needs"] = .string(n) }
            if let x = t.get("text")?.asString, !x.isEmpty { content["text"] = .string(pyPrefix(x, 300)) }
            try log.record(clock(), project: project, thread: id, kind: "thread", id: id, content: content)
            watching.rowSig[id] = [t.get("section")?.asString ?? "", t.get("state")?.asString ?? "", t.get("time").map { $0.pyStr } ?? ""].joined(separator: "|")
            if let time = Self.rowTime(t.get("time")) { watching.rowTime[id] = time }
            let st = Self.rowStatus(t)
            if let st { watching.rowStatus[id] = st }
            try applyStatus(project, id, st)
        }
        if listed {  // a thread of the active list absent from a listed read is gone: its run ended
            for (id, st) in log.statuses(project: project) where Self.activeStatuses.contains(st) && !ids.contains(id) { try depart(project, id) }
        }
        try proveAnswers()
    }

    /// A local thread (a Claude app session) or a `local:` one needs no frame.
    func isCloud(_ thread: String) -> Bool {
        if pyStartsWith(thread, "local:") { return false }
        let s = board()["threads"]?.get(thread)?.get("session")?.asString
        return s == nil || s!.isEmpty
    }

    func applyStatus(_ project: String, _ thread: String, _ status: String?) throws {
        guard let status else { return }
        // A pending card outranks every row: the row lags the card by about 12 s, and a waiting row looks idle. Only a thread-view read
        // clears it; then the row must show `working` before a `paused` or `done` of it counts.
        if watching.pendingCard[thread] != nil { return }
        if status == "working" { watching.expectWork.remove(thread) } else if watching.expectWork.contains(thread) && status != "needs you" { return }
        let prev = log.status[thread]
        if status == "paused" && prev == "done", let c = checks()[thread], c.readRow != nil, c.readRow == watching.rowSig[thread] {
            return  // a finished thread left in `active + dashed`: the row didn't change since its read
        }
        if status == "done" { try log.setStatus(clock(), project: project, thread: thread, "done"); return dropThread(thread) }
        try log.setStatus(clock(), project: project, thread: thread, status)
        // A change moves its frames; so does a working thread with no frame yet (at launch, or after one was dropped).
        let unframed = status == "working" && !watching.holds(thread) && !watching.overCap.contains(thread)
        guard prev != status || unframed, watching.on, isCloud(thread) else { return }
        try threadFrameOn(project, thread, status)
    }

    /// A departure: the row left the active list (a `gone` row, or absent from a `listed` read) with no `done` row seen.
    func depart(_ project: String, _ thread: String) throws {
        if watching.pendingCard[thread] != nil { return }
        watching.expectWork.remove(thread)
        if log.status[thread] != "done" { try log.setStatus(clock(), project: project, thread: thread, "done") }
        let place = CourierAcc.Place(kind: "thread", subject: thread)
        if var f = acc.latest[place]?["page"]?.asObject, !CourierBoard.finished.contains(f["state"]?.asString ?? "") {
            f["state"] = "done"; f["needs"] = .null
            try ingest([CourierPage.row("thread", thread, f.pairs.map { ($0.key, $0.value) })])
        }
        dropThread(thread)
    }

    /// The thread's frames, kept or check, go; it owes nothing.
    func dropThread(_ thread: String) {
        if let i = watching.keptIndex(thread) { watching.kept.remove(at: i) }
        if watching.check?.thread == thread && !watching.checkAnswer { watching.check = nil }
        watching.overCap.remove(thread)
        watching.removeAfterRead.remove(thread)
        if var c = checks()[thread], c.owed { c.owed = false; putCheck(c) }
    }

    /// A thread's status changed: its frames follow (§1.8).
    func threadFrameOn(_ project: String, _ thread: String, _ status: String) throws {
        let f = CourierFrame(project: project, thread: thread)
        switch status {
        case "working":
            if watching.keptIndex(thread) != nil { return }
            if watching.check == f && !watching.checkAnswer { watching.check = nil }  // the check becomes a kept frame
            if keep(project, thread, card: false) { return }
            watching.overCap.insert(thread)
        case "paused":
            if watching.keptIndex(thread) != nil {  // its kept frame's last settled read decides, or the next one
                if let s = watching.states[f], s.settled { try threadRead(f, s, nil, approval: false) }
                return
            }
            watching.overCap.remove(thread)
            owe(project, thread, why: "paused with no thread-view read since it ran")
        case "needs you":
            if !watching.holds(thread) {
                if watching.pendingCard[thread] == nil { owe(project, thread, why: "needs you, card not confirmed", needs: true) }
                return
            }
            if watching.pendingCard[thread] == nil {  // a plain-words request: its frame goes after its read
                if let s = watching.states[f], s.settled { removeThreadFrame(f) } else { watching.removeAfterRead.insert(thread) }
            }
        default:
            break
        }
    }

    /// Takes a kept slot, evicting the least recently used card frame when all three are held. Returns whether it got one.
    @discardableResult
    func keep(_ project: String, _ thread: String, card: Bool) -> Bool {
        if watching.kept.count >= CourierFrames.keptCap {
            guard let lru = watching.lruCard() else { return false }
            watching.kept.remove(at: lru)  // its thread keeps its `needs you`; an answer reopens a frame on demand
        }
        watching.kept.append(CourierKept(thread: thread, project: project, card: card, used: clock()))
        return true
    }

    func removeThreadFrame(_ f: CourierFrame) {
        guard let thread = f.thread else { return }
        if let i = watching.keptIndex(thread) { watching.kept.remove(at: i) }
        if watching.check == f { watching.check = nil; watching.checkAnswer = false }
        watching.removeAfterRead.remove(thread)
    }

    /// A thread frame's settled read (or, `rows` nil, its last one again): a pending card or an approval is `needs you`; no card with
    /// the row `paused` is confirmed idle (`done`) when the project frame is live, or, under a stale one, with no `code-prompt-stop` and
    /// no streaming row. A check is one read, then removed.
    func threadRead(_ f: CourierFrame, _ s: CourierFrameState, _ rows: [JSON]?, approval: Bool) throws {
        guard let thread = f.thread else { return }
        let project = f.project
        let wasCheck = watching.check == f && !watching.checkAnswer
        if let rows {
            let pending = rows.last { r in
                (r.get("options")?.asArray.map { !$0.isEmpty } ?? false) && r.get("answered") != .bool(true) && r.get("key")?.asString != nil
            }
            if let key = pending?.get("key")?.asString {
                watching.pendingCard[thread] = key
            } else if watching.pendingCard.removeValue(forKey: thread) != nil {  // answered or gone: the row says what follows
                watching.expectWork.insert(thread)
                if watching.rowStatus[thread] == "working" { try applyStatus(project, thread, "working") }
            }
        }
        let card = watching.pendingCard[thread]
        var c = checks()[thread] ?? CourierCheck(thread: thread, project: project, owed: false, why: nil, needs: false)
        c.readAt = clock(); c.readRow = watching.rowSig[thread]
        if card != nil || approval {
            try log.setStatus(clock(), project: project, thread: thread, "needs you", needs: approval && card == nil ? "permission" : nil)
            if let i = watching.keptIndex(thread) { watching.kept[i].card = true; watching.kept[i].used = clock() }
        } else if log.status[thread] == "paused" {
            if watch(project) == .live || (!s.stop && !s.streaming) {
                try log.setStatus(clock(), project: project, thread: thread, "done")
                if let i = watching.keptIndex(thread) { watching.kept.remove(at: i) }
                watching.overCap.remove(thread)
            }
        } else if log.status[thread] == "needs you" || watching.removeAfterRead.contains(thread) {
            removeThreadFrame(f)  // a plain-words request: the project's model writes the question from the rows this read logged
        }
        if wasCheck {
            if watching.check == f { watching.check = nil }
            c.owed = false
        }
        if watching.keptIndex(thread) != nil { c.owed = false }
        putCheck(c)
    }

    // MARK: Owed checks (§1.8), in router.db

    func checks() -> [String: CourierCheck] {
        if let c = watching.checks { return c }
        let c = (try? db.checks()) ?? [:]
        watching.checks = c
        return c
    }

    func putCheck(_ c: CourierCheck) {
        _ = checks()
        watching.checks![c.thread] = c
        try? db.putCheck(c)
    }

    func owe(_ project: String, _ thread: String, why: String, needs: Bool = false) {
        var c = checks()[thread] ?? CourierCheck(thread: thread, project: project, owed: false, why: nil, needs: false)
        c.owed = true; c.why = why; c.needs = c.needs && c.owed || needs; c.project = project
        c.time = watching.rowTime[thread] ?? (board()["threads"]?.get(thread)?.get("touched")?.numeric) ?? clock()
        putCheck(c)
    }

    /// The owed queue, one at a time in the check slot: needs-you first, then the newest row time.
    func serveChecks() throws {
        guard watching.on, watching.check == nil, watching.handoverDue == nil else { return }
        let next = checks().values.filter { $0.owed && !watching.holds($0.thread) }
            .sorted { ($0.needs ? 1 : 0, $0.time ?? 0, $0.thread) > ($1.needs ? 1 : 0, $1.time ?? 0, $1.thread) }.first
        if let next {
            watching.check = CourierFrame(project: next.project, thread: next.thread)
            watching.checkAnswer = false
        }
    }

    /// A project frame live again (or for the first time: launch, a handover's new document): its paused cloud threads touched within
    /// 24 h whose row changed since their last read, or never read, are owed a check; so is an open `needs you` no read confirmed.
    func sweep(_ project: String) {
        let threads = board()["threads"]?.asObject ?? JSONObject()
        for (id, status) in log.statuses(project: project) where isCloud(id) && !watching.holds(id) {
            let touched = watching.rowTime[id] ?? threads[id]?.get("touched")?.numeric ?? 0
            if clock() - touched > CourierFrames.recent { continue }  // older: checked when its row changes, or when opened
            let c = checks()[id]
            if status == "paused" && (c?.readRow == nil || c?.readRow != watching.rowSig[id]) {
                owe(project, id, why: "paused, row changed since its read")
            } else if status == "needs you" && watching.pendingCard[id] == nil && (c?.readAt == nil || c!.readAt! < touched) {
                owe(project, id, why: "needs you, card not confirmed", needs: true)
            }
        }
    }

    // MARK: Watch, failure and staleness (§1.5)

    func watch(_ project: String) -> CourierWatch {
        guard let s = watching.states[CourierFrame(project: project, thread: nil)] else { return .none }
        if let since = s.staleSince { return .stale(since: since) }
        return s.live ? .live : .none
    }

    func live(_ f: CourierFrame) {
        let s = watching.state(f)
        let was = s.live
        s.staleSince = nil; s.reloaded = false; s.stuck = 0; s.staleTries = 0; s.live = true
        if f.thread == nil && !was { sweep(f.project) }
    }

    func stale(_ f: CourierFrame) {
        let s = watching.state(f)
        if s.staleSince == nil { s.staleSince = clock() }
        s.settled = false; s.live = false
    }

    func reload(_ f: CourierFrame) {
        out(["kind": "reload", "frame": f.json])
    }

    /// Blank, gone without a removal: reload once, then stale.
    func frameFailed(_ f: CourierFrame) throws {
        let s = watching.state(f)
        s.loadDue = nil
        if !s.reloaded { s.reloaded = true; reload(f) } else { stale(f) }
    }

    func frameGone(_ f: CourierFrame) throws {
        for a in watching.answers.values where a.frame == f && a.inFlight { a.lost = true }
        let s = watching.state(f)
        s.settled = false; s.live = false
        if wanted().contains(f) { try frameFailed(f) } else { watching.states.removeValue(forKey: f) }
    }

    /// The project shows the archived stand-in: its frame goes, and its threads fold to idle.
    func archive(_ project: String) throws {
        watching.archived.insert(project)
        watching.states.removeValue(forKey: CourierFrame(project: project, thread: nil))
        try ingest([CourierPage.row("threadlist", project, [("ids", .array([]))])])
        for (id, st) in log.statuses(project: project) where Self.activeStatuses.contains(st) {
            try log.setStatus(clock(), project: project, thread: id, "done")
            dropThread(id)
        }
    }

    // MARK: The wanted set: the engine is its one owner

    func wanted() -> [CourierFrame] {
        let projects = (board()["projects"]?.asObject?.values ?? []).compactMap { p -> String? in
            guard p.get("where") == "cloud", let id = p["id"]?.asString, pyStartsWith(id, "chan_"), !watching.archived.contains(id) else { return nil }
            return id
        }.sorted()
        return projects.map { CourierFrame(project: $0, thread: nil) } + watching.threadFrames()
    }

    /// Sends `frames {want, base}` when the set changed, or always for a new document (`base`).
    func syncFrames(base: Bool = false) {
        guard watching.on else { return }
        let want = wanted()
        let j: JSON = .array(want.map(\.json))
        if !base && j == watching.lastWant { return }
        watching.lastWant = j
        for f in watching.states.keys where !want.contains(f) { watching.states.removeValue(forKey: f) }
        out(["kind": "frames", "want": j, "base": .bool(base)])
    }

    /// The top frame is a new document: its frames are gone. The kept frames of working threads come back in the base set; card frames
    /// reopen on demand; a check in flight is requeued (it stays owed).
    func newTopDocument() {
        watching.states.removeAll()
        watching.kept.removeAll { $0.card }
        watching.homeID = nil  // went with the old document
        if !watching.checkAnswer { watching.check = nil }
        try? serveChecks()
        syncFrames(base: true)
    }

    // MARK: Deadlines

    func frameDeadlines() -> [Double] {
        var all = watching.states.values.compactMap(\.loadDue) + watching.wakes.map(\.at) + watching.answers.values.compactMap(\.deadline)
        if let d = watching.handoverDue { all.append(d) }
        return all
    }

    func frameTick(_ now: Double) throws {
        let due = watching.wakes.filter { $0.at <= now }
        watching.wakes.removeAll { $0.at <= now }
        if connected() { for f in Set(due.map(\.frame)) { out(["kind": "wake", "frame": f.json]) } }
        for (f, s) in watching.states {
            guard let d = s.loadDue, d <= now else { continue }
            if !s.injected {  // no `page` from that frame: inject once
                s.injected = true
                s.loadDue = now + Self.frameWait
                out(["kind": "frame_inject", "frame": f.json, "frameId": s.frameId ?? .null])
            } else {  // a second miss: blank
                s.injected = false
                try frameFailed(f)
            }
        }
        if let d = watching.handoverDue, d <= now {
            watching.handoverDue = nil
            out(["kind": "handover_abort"])  // the old tab stays; the budget stays and the next increment asks again
        }
        try answerTick(now)
        try afterWatch()
    }

    // MARK: home (§1.3)

    /// Issued once no run is left that acts or proves: an `open` of the projects page with `home: true`, tied to no run. A stale frame
    /// is retried at each such step, one reload per frame, three times.
    func maybeHome() {
        guard watching.on, watching.homeWanted, watching.homeID == nil, watchOpen == nil, connected(),
              runs.values.allSatisfy({ $0.flag("paused") && !inPage($0) }) else { return }
        watching.homeWanted = false
        for (f, s) in watching.states where s.staleSince != nil && s.staleTries < CourierFrames.staleTries {
            s.staleTries += 1
            reload(f)
        }
        if acc.here.isTruthy {  // not already on the projects page
            watching.homeID = command("open", [("project", .null), ("thread", .null), ("home", true)])
            moves += 1
        }
    }

    /// A run ends: `home` is wanted, and a wanted handover may be granted.
    func runEnded() {
        watching.finishes += 1
        if watching.on { watching.homeWanted = true }
    }

    /// A run submitted before `home` was issued skips it.
    func runAdded() {
        if watching.homeID == nil { watching.homeWanted = false }
    }

    // MARK: The handover grant (§1.7)

    /// Granted when no run is sending, taken or in a tool step and no answer is between its issue and its `done` or `lost`; else at
    /// the next run end; at budget 12 the next run end grants it even with runs queued. An answer in flight always holds it.
    func tryGrant() {
        guard let budget = watching.handoverBudget, watching.handoverDue == nil else { return }
        if watching.answers.values.contains(where: \.inFlight) { return }
        let idle = runs.values.allSatisfy { $0.flag("paused") }
        guard idle || (budget >= CourierFrames.grantBound && watching.finishes > watching.finishesAtWant) else { return }
        watching.handoverBudget = nil
        watching.kept.removeAll { $0.card }  // thread frames go before a handover; the base set reopens the working ones
        if !watching.checkAnswer { watching.check = nil }  // a check in flight is requeued: it stays owed
        out(["kind": "handover"])
        watching.handoverDue = clock() + Self.handoverWait
        wake()
    }

    func handoverDone() throws {
        watching.handoverDue = nil
        watching.homeWanted = true
        newTopDocument()
    }

    // MARK: The log (§2)

    /// Items from one event of any frame: projects, thread rows (in `threadsSeen`), message rows and cards.
    func logEvent(_ event: JSON, project: String?, thread: String?) throws {
        switch event.get("type")?.asString ?? "" {
        case "projects":
            for p in CourierPage.items(event.get("projects")) {
                guard let id = p.get("id")?.asString, pyStartsWith(id, "chan_"), !pyStartsWith(id, "chan_pending_") else { continue }
                try log.record(clock(), project: id, thread: nil, kind: "project", id: id, content: ["name": .string(p.get("name")?.asString ?? "")])
            }
        case "threads":
            if let project { try threadsSeen(project, CourierPage.items(event.get("threads")), listed: event.get("listed") == .bool(true)) }
        case "rows":
            if let project { try logRows(project, event.get("side") == "thread" ? thread : nil, event.get("rows")) }
        default:
            break
        }
    }

    /// Settled rows the server has, each once by its key; a decision row with options is also a card item.
    func logRows(_ project: String, _ thread: String?, _ rows: JSON?) throws {
        for r in CourierPage.items(rows) {
            guard let key = r.get("key")?.asString, !key.isEmpty, !(r.get("pending")?.isTruthy ?? false), r.get("streaming") != .bool(true),
                  CourierPage.belongs(key, project), let text = r.get("text")?.asString else { continue }
            let from = r.get("from")?.asString
            var content: JSON = ["from": .string(from == "you" || from == "claude" ? from! : "unknown"), "text": .string(text),
                                 "decision": .bool(r.get("decision")?.isTruthy ?? false), "index": r.get("index") ?? .null]
            for k in ["entry_index", "answered", "options", "card"] { if let v = r.get(k) { content[k] = v } }
            try log.record(clock(), project: project, thread: thread, kind: "row", id: key, content: content)
            if let thread, let options = r.get("options")?.asArray, !options.isEmpty {
                let plan = board()["threads"]?.get(thread)?.get("needs")?.isTruthy ?? false
                try log.record(clock(), project: project, thread: thread, kind: "card", id: key,
                               content: ["kind": plan ? "plan" : "question", "options": .array(options), "answered": .bool(r.get("answered") == .bool(true))])
            }
        }
    }

    /// A local session's item and status, from its file (`CourierLocal`).
    func logLocal() throws {
        for (id, t) in board()["threads"]?.asObject ?? JSONObject() {
            guard let session = t.get("session")?.asString, !session.isEmpty else { continue }
            var content: JSON = ["state": t.get("state") ?? .null, "title": t.get("title") ?? .null]
            if let n = t.get("needs") { content["needs"] = n }
            if let d = t.get("detail") { content["detail"] = d }
            let project = t.get("project")?.asString
            try log.record(clock(), project: project, thread: id, kind: "session", id: session, content: content)
            let status: String? = switch t.get("state")?.asString {
            case "working": "working"
            case "needs_you", "stranded", "waiting_app": "needs you"
            case "idle", "resolved": "done"
            default: nil
            }
            if let status { try log.setStatus(clock(), project: project, thread: id, status) }
        }
    }
}
