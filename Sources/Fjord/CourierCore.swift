import Foundation

// The Router's delivery engine: a line-for-line port of poc/router/routerd.py's `Core` (the part that has no sockets and no timers of its
// own). The server feeds it events, calls `tick` at `nextDeadline()`, and tests do the same. It is synchronous and not Sendable, as the
// Python one is: ordering is the reference's. Runs are `Run` objects over JSON with the Python field names (a run dict is mutated in place
// by everything that holds it); places are `Place`; commands and events are JSON.

/// The two clocks: wall time, and a clock that stands still while the Mac sleeps (`time.monotonic` on macOS).
struct CourierClock {
    var now: () -> Double
    var uptime: () -> Double
    static let system = CourierClock(now: { Date().timeIntervalSince1970 }, uptime: { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 })
}

/// A place the tab can show: a project, or a thread of it. The Python tuple `(project, thread)`.
struct Place: Hashable {
    var project: String?
    var thread: String?
    init(_ project: String?, _ thread: String? = nil) { self.project = project; self.thread = thread }
    init?(_ json: JSON?) {
        guard let a = json?.asArray, a.count == 2 else { return nil }
        self.project = a[0].asString
        self.thread = a[1].asString
    }
    var json: JSON { [JSON(project), JSON(thread)] }
}

/// A dict that keeps insertion order (Python's).
struct OrderedMap<K: Hashable, V> {
    private(set) var keys: [K] = []
    private var storage: [K: V] = [:]
    subscript(key: K) -> V? {
        get { storage[key] }
        set {
            if let v = newValue {
                if storage.updateValue(v, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }
    var values: [V] { keys.map { storage[$0]! } }
    var pairs: [(key: K, value: V)] { keys.map { ($0, storage[$0]!) } }
    @discardableResult mutating func pop(_ key: K) -> V? { let v = storage[key]; self[key] = nil; return v }
    mutating func removeAll() { keys = []; storage = [:] }
    func has(_ key: K) -> Bool { storage[key] != nil }
}

/// A run's helpers: the Python dict's `.get` and truthiness over JSON.
extension Run {
    func str(_ k: String) -> String? { fields.get(k)?.asString }
    func num(_ k: String) -> Double? { fields.get(k)?.numeric }
    /// `bool(run.get(k))`.
    func flag(_ k: String) -> Bool { fields.get(k)?.isTruthy ?? false }
    func has(_ k: String) -> Bool { fields.has(k) }
    @discardableResult func pop(_ k: String) -> JSON? { fields.pop(k) }
    func set(_ k: String, _ v: Double?) { fields[k] = v.map(JSON.double) ?? .null }
    func set(_ k: String, _ v: String?) { fields[k] = v.map(JSON.string) ?? .null }
    func set(_ k: String, _ v: Bool) { fields[k] = .bool(v) }
    /// `run.update(k=v, …)`.
    func update(_ pairs: [(String, JSON)]) { for (k, v) in pairs { fields[k] = v } }
    /// `run.get(k, ())` as strings.
    func strings(_ k: String) -> [String] { (fields.get(k)?.asArray ?? []).compactMap(\.asString) }
    func place(_ k: String) -> Place? { Place(fields.get(k)) }
    /// `run.setdefault(k, {})[sub] = v` on a nested object.
    func put(_ k: String, _ sub: String, _ v: JSON) {
        var o = fields.get(k)?.asObject ?? JSONObject()
        o[sub] = v
        fields[k] = .object(o)
    }
    func append(_ k: String, _ v: JSON) { fields[k] = .array((fields.get(k)?.asArray ?? []) + [v]) }
    func insert(_ k: String, _ v: String) {  // a Python set, kept as a list without repeats
        var a = fields.get(k)?.asArray ?? []
        if !a.contains(.string(v)) { a.append(.string(v)) }
        fields[k] = .array(a)
    }
}

extension JSON {
    func str(_ k: String) -> String? { get(k)?.asString }
    func num(_ k: String) -> Double? { get(k)?.numeric }
    func flag(_ k: String) -> Bool { get(k)?.isTruthy ?? false }
    /// `(self.get("result") or {})` style.
    func obj(_ k: String) -> JSON { (get(k)?.isTruthy ?? false) ? get(k)! : .object(JSONObject()) }
}

/// A watched send's going back in flight (`watch_open`): {"open", "to", "id", "hold_until", "moving_from", "open_from", "shown"}.
final class WatchOpen {
    var open: String?
    var to: Place
    var id: Int
    var holdUntil: Double
    var movingFrom: Int?
    var openFrom: Int
    var shown: Bool
    init(open: String?, to: Place, id: Int, holdUntil: Double, movingFrom: Int?, openFrom: Int, shown: Bool) {
        self.open = open; self.to = to; self.id = id; self.holdUntil = holdUntil; self.movingFrom = movingFrom; self.openFrom = openFrom; self.shown = shown
    }
}

/// The part of look.py the Core needs: the local files as Seen rows (`local_rows`).
enum CourierLook {
    static let freshDays = 21.0

    static func row(_ source: String, _ kind: String, _ subject: String, _ fields: [(String, JSON)]) -> JSON {
        ["source": .string(source), "kind": .string(kind), "subject": .string(subject), "fields": .object(JSONObject(fields))]
    }

    /// The app's own words for a session: a busy process is working, a blocked or interrupted one needs you; else unknown.
    static func localState(_ s: JSON, _ status: JSON?) -> JSON {
        if status == "busy" { return "working" }
        if s.flag("needs") || s.flag("interrupted") || s.get("category") == "blocked" { return "needs_you" }
        switch s.get("category")?.asString {
        case "completed": return "resolved"
        case "review_ready": return "idle"
        default: return "unknown"
        }
    }

    static func basename(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return p.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    /// A project-thread child belongs to the page thread with its title, in the project of its folder when titles repeat.
    static func linkChild(_ board: JSON, _ s: JSON) -> String? {
        let projects = board["projects"]?.asObject ?? JSONObject()
        var same = (board["threads"]?.asObject?.values ?? []).filter { t in
            (t.get("title")?.isTruthy ?? false) && t.get("title") == s.get("title") && projects.has(t.get("project")?.asString ?? "\u{0}")
        }
        if same.count > 1 {
            let name = basename(s.get("folder")?.asString ?? "")
            same = same.filter { projects[$0.get("project")?.asString ?? ""]?["name"] == .string(name) }
        }
        return same.count == 1 ? same[0]["id"]?.asString : nil
    }

    /// Session files and the process registry. A process that was alive and has no entry now is gone.
    /// `local`: {"sessions": {key: info}, "processes": {cli: alive}, "statuses": {cli: status}, "app": bool}.
    static func localRows(_ board: JSON, _ local: JSON, _ pageProjects: [JSON], _ now: Double) -> [JSON] {
        var bySession: [String: String] = [:]
        for t in board["threads"]?.asObject?.values ?? [] { if let s = t.get("session")?.asString, !s.isEmpty { bySession[s] = t["id"]?.asString ?? "" } }
        var names: [String: String] = [:]
        for p in pageProjects { names[p["name"]?.asString ?? ""] = p["id"]?.asString ?? "" }
        var rows: [JSON] = []
        var localProjects = OrderedMap<String, JSON>()
        for (key, s) in local["sessions"]?.asObject ?? JSONObject() {
            let child = s.flag("child")
            var subject: String? = bySession[key]
            if subject == nil, child { subject = linkChild(board, s) }
            if subject == nil, !child { subject = "local:\(s["cli"]?.pyStr ?? "")" }
            if subject == nil || (s.flag("active") && now - (s.num("active") ?? 0) > freshDays * 86400) { continue }
            let subject_ = subject!
            var fields: [(String, JSON)] = []
            if pyStartsWith(subject_, "local:") {
                let name = basename(s.get("folder")?.asString.flatMap { $0.isEmpty ? nil : $0 } ?? "scratch")
                let project = names[name] ?? "local:\(name)"
                fields = [("project", .string(project)), ("title", s["title"] ?? .null)]
                localProjects[project] = row("files", "project", project, [("purpose", s.get("purpose") ?? "")] + (names[name] != nil ? [] : [("name", .string(name)), ("where", "local")]))
            }
            let cli = s["cli"]?.asString ?? ""
            var alive: JSON? = local["processes"]?[cli]
            if alive == nil || alive == .null, board["threads"]?.get(subject_)?.get("alive") != nil { alive = .bool(false) }  // seen alive once: gone stays gone
            let status = alive?.isTruthy ?? false ? local["statuses"]?.asObject?[cli] : nil
            rows.append(row("files", "thread", subject_, [("state", localState(s, status)), ("detail", s["detail"] ?? .null),
                                                         ("needs", s.flag("needs") ? s["needs"]! : .null), ("alive", alive ?? .null), ("session", .string(key)),
                                                         ("result", s["result"] ?? .null), ("active", s["active"] ?? .null)] + fields))
        }
        let app = local.has("app") ? [row("files", "app", "claude", [("running", .bool(local["app"]?.isTruthy ?? false))])] : []
        return localProjects.values + rows + app
    }
}

final class CourierCore {
    static let dialogOpen = "a dialog is open"  // content.js's send step, when a settings dialog is open in the page
    nonisolated(unsafe) static var devWait = 60.0  // seconds a dev_command op waits for the page's `done`
    static let acceptedWait = 300.0  // how long a message the page took may stay queued behind a coordinator reply
    static let keepDays = 3.0  // chat and message rows older than this are dropped from Seen at start
    static let replayRows = 200_000  // at most this many of the newest Seen rows are replayed at start
    static let cap = 500  // facts and claims kept for the next tell
    static let vanished = "the tab reloaded right after the click, and the reloaded page doesn't show the words: the old page likely went before the server had them (not sent again)"
    static let went = "the page it was handed to went before it said what it did, and no row from you showed after: the words were likely lost with it, and were never confirmed (not sent again)"
    static let noticeFresh = 15.0  // seconds: a page notice this recent is why words came back (the page gives up about 10.5 s after a 429 or 5xx)
    static let wakeCap = 30_000.0  // ms: the longest a page's `wake_me` is waited for
    static let takeWait = 2.0  // seconds after a click for the page to take the words; a hidden tab's page timers run at most once a second
    static let reloadLoss = 3.0  // seconds after a reported click within which a page that goes can take the words with it (lost at ~0.1 s, measured);
    // a page that goes later went after its pending row had time to reach the server, so it is waited for as any taken message
    static let vanishGrace = 1.0  // seconds a reloaded page's first rows of the place are given to render the rest, a margin of its own
    static let freshAfter = 2.0  // seconds after the tab arrived on a project that a send still waiting for its settled read opens it `fresh`, once
    static let resume = 600.0  // seconds: an intent left unfinished by a restart is picked up again only inside this window
    static let sends = ["send_to_project", "reply_in_thread"]  // context.SENDS
    static var runs_: [String] { sends + CourierDo.tools }
    // A tool run's stages, in order: start (show the place) -> act (sent once; a setting's act reads `before` itself) -> prove (read until it shows)
    // -> look (at the deadline, one more read) -> confirmed or failed. Each stage opens the place at most once and reads at most once.
    static let acted = ["act", "prove", "look"]  // the act is in the page or done: never sent again
    static let proving = ["prove", "look"]  // the act is done: the run yields the composer to sends

    let db: CourierStore
    var out: (JSON) -> Void
    var clock: () -> Double
    var uptime: () -> Double
    var wake: () -> Void
    var gone: () -> Void = {}

    var runs = OrderedMap<Int, Run>()
    var waiters: [Int: [(JSON) -> Void]] = [:]
    var hosts = 0
    var commands = 0
    var wakes = Set<Double>()  // when the page's `wake_me`s are answered with a `wake`: every time asked, rounded up to 50 ms so close ones share one
    // Command ids name this start too: the page keeps and replays its latest `done`s, which a restarted routerd's own c1, c2… must not match.
    var startID: String
    var lastDone: [Int: Int] = [:]  // document (`pages`) -> the newest of this routerd's commands whose `done` arrived from it (`unheard_sends`)
    // read_settings commands whose read arrived and whose run is over: the page is still closing their dialog. Each -> its deadline, at
    // which it is cancelled and let go (`tick`): a dialog that never closes doesn't hold the sends for good.
    var closing = OrderedMap<String, Double>()
    var dev = OrderedMap<String, (JSON) -> Void>()  // dev commands (dev_command) -> the callback waiting for their `done`
    var cutOld = Set<String>()  // commands of an earlier routerd start, waiting in the page, cancelled once
    var staleGoal = OrderedMap<String, JSON>()  // project → a goal the server refused that the tab still shows (the page shows what was typed)
    var chains: [Int: [Int]] = [:]  // intent id -> the ids of the queued tool steps after it, in order
    var notice: (text: String, at: Double) = ("", 0.0)  // the page's latest notice and when it came
    var lastSend: [Place: String] = [:]  // place -> the newest send: words back in the draft belong to it alone
    var reads: [String: Int] = [:]  // project -> how many settings reads the page has sent: a tool's read is the one that comes after its mark
    // The read commands whose `done` arrived, its settings handled (live: the `settings` event before it; or replayed): a snapshot
    // repeats the page's last `done`s, and an old read's settings handled again would count as a new read, or undo a goal's mark.
    var readsDone = OrderedMap<String, Bool>()
    var linked = 0  // how many commands were sent when a host last connected: the page's `commands` answers for those only
    var moves = 0  // how many opens a run made to act or look, or taken sends that went back finished: a taken send goes back once per move
    var backDue = false  // a taken send that went back finished: `advance_all` visits the other taken ones again
    var lists = 0  // how many complete lists of the projects the page has sent: a create's look is the first after its mark
    // Sends that failed after a click (taken but never confirmed, stuck, VANISHED) -> until when a later row of yours confirms them
    // late: the server may have queued the words behind a coordinator's turn, which shows them only once it ends. The time is on
    // `uptime`, which stands still while the Mac sleeps. The intent's result keeps its end on the wall clock too (`watch`), so a restart
    // watches it again for the rest of it.
    var watched = OrderedMap<Int, Double>()
    // A watched send goes back to its place as a taken one does, once per move (`back_to_watched`): id -> `moves` when it last went.
    // The open in flight, if any, which holds the other runs as a taken send's (`going_back`).
    var watchBack: [Int: Int] = [:]
    var watchOpen: WatchOpen?
    // How many times the page was replaced: a `page` with another (`loaded`, `instance`), or a `gone` whose next `page` carries another
    // or none (one with the same pair is the same script back). A click belongs to one of them.
    var pages = 0
    var loaded: JSON?  // the latest page's `loaded`
    // The latest page's `instance`: content.js's own run in the document. An extension reload keeps the document (its `loaded`) but
    // injects a fresh script whose `recent` starts empty, so a document is told by (`loaded`, `instance`). An old page sends none.
    var instance: JSON?
    var regone = false  // a `gone` came and no `page` since: the next one says whether the document was replaced
    // A host linked and no `page` since: a document replaced while none was linked is counted only at the next `page` (its `loaded`),
    // so a snapshot's sends to mark as never run (`replay`) wait for it to say the document is the one they were handed to.
    var relinked = false
    var unran: [(Int, String)] = []
    var nopage = false  // a host linked and no event from it since: the page's health is unknown (`connection`)
    var unwent: [Int] = []  // runs whose send was dropped at a replay while `relinked`: went, or retried, once the next `page` says (`replay`)
    var arrivals = 0  // how many times the tab showed another place (`arrive`)
    var lastSeen: (Double, Double)?  // (wall clock, uptime) at the last check for a jump (`jump`)
    var acc: CourierAcc
    var lastLocal: JSON?
    var _board: JSON?
    var chatted: Set<String>
    // Place (chat or thread) -> the keys of every row of it Seen holds, in the order they were last read (`remember`): the latest last.
    var known: [String: OrderedMap<String, Bool>] = [:]
    // Places shown since the tab arrived on them whose whole read the page hasn't marked `settled`.
    var unsettled = Set<String>()
    var arrived: (project: String?, at: Double) = (nil, 0.0)  // (project, when) the tab last arrived on a project: a `fresh` open is due FRESH_AFTER past it (`stale`)
    // Place (project, thread) -> the keys of its rows that proved a send: one row proves one send. Rebuilt from the confirmed sends'
    // results (`row`), which persist it.
    var claimed: [Place: Set<String>] = [:]
    var facts = OrderedMap<String, JSON>()
    var unproved = Set<Int>()  // acted, never proved: a later read can confirm

    /// `out(command)` sends one command down the socket. `wake()` says a deadline was added. `gone()` (set by the watcher) says the page
    /// went away: the watcher looks at Chrome again. `uptime()` is a clock that stands still while the Mac sleeps.
    init(db: CourierStore, out: @escaping (JSON) -> Void, clock: CourierClock = .system, wake: @escaping () -> Void = {}) throws {
        self.db = db; self.out = out; self.clock = clock.now; self.wake = wake; self.uptime = clock.uptime
        startID = String((0..<6).map { _ in "0123456789abcdef".randomElement()! })
        let sql = CourierSQL(db)
        try sql.compact(clock.now() - Self.keepDays * 86400)
        let rows = try sql.seen(last: Self.replayRows), mark = try sql.mark()
        acc = CourierBoard.start(told: mark)
        CourierBoard.foldInto(acc, rows.filter { ($0["id"]?.asInt ?? 0) <= mark })
        let before = CourierBoard.finish(acc)
        CourierBoard.foldInto(acc, rows.filter { ($0["id"]?.asInt ?? 0) > mark })
        acc.health = JSONObject([("connected", false), ("signed_in", .null), ("page_ok", .null)])
        for k in acc.projects.keys { Self.reset(&acc.projects, k, ["chat", "draft", "disabled", "settings", "turning", "turn_state"]) }
        for k in acc.threads.keys {  // rows from a past run can't be a baseline: the page sends what it shows on load
            Self.reset(&acc.threads, k, ["messages", "draft", "disabled", "turning", "turn_state"])
        }
        chatted = try sql.chatProjects()
        lastLocal = nil
        _board = nil
        for r in rows where ["chat", "messages"].contains(r["kind"]?.asString ?? "") && (r["fields"]?.get("messages")?.isTruthy ?? false) {
            remember(r["subject"]?.asString ?? "", r["fields"]!["messages"]!.asArray ?? [])
        }
        arrived = (nil, 0.0)
        for i in try sql.intents(-1, status: "confirmed", columns: CourierStore.lean) {
            if Self.sends.contains(i.str("tool") ?? ""), let row = i.obj("result").str("row") {
                claimed[Place(i.str("project"), i.str("thread")), default: []].insert(row)
            }
        }
        facts = OrderedMap()
        for f in CourierTell.facts(before, board()) { facts[f["key"]?.asString ?? ""] = f }
        trim()
        let pending = try ["pending", "paused", "queued"].flatMap { try sql.intents(-1, status: $0) }.sorted { ($0["id"]?.asInt ?? 0) < ($1["id"]?.asInt ?? 0) }
        for i in pending {
            let status = i.str("status") ?? "", tool = i.str("tool") ?? "", id = i["id"]?.asInt ?? 0
            if ["pending", "paused"].contains(status) && Self.sends.contains(tool) {
                if self.clock() - (i.num("at") ?? 0) > Self.resume || i.obj("proof").has("baseline") {
                    // One with a baseline issued a send (it is taken just before the first), whose click may have come with no `done`
                    // heard (routerd went just then): it may yet show the words, so it is watched as a send failed after a click is. A
                    // watch confirms only on a matching row no other send claimed, clicked or not: a replayed ok `done` changes nothing.
                    let sent = i.obj("proof").has("baseline")
                    var changes: [(String, JSON)] = [("status", "failed"), ("cause", "routerd restarted before the words were proved")]
                    if sent {
                        var result = i.obj("result").asObject ?? JSONObject()
                        result["watch"] = .double(self.clock() + Self.acceptedWait)
                        changes.append(("result", .object(result)))
                    }
                    try sql.update(self.clock(), id, changes)
                } else {
                    try sql.update(self.clock(), id, [("status", "paused"), ("cause", "routerd restarted")])
                    runs[id] = Run(JSONObject([("id", .int(id)), ("stage", "start"), ("t0", i["at"] ?? .null), ("paused", true), ("deadline", .null),
                                               ("ms", [:]), ("tool", false)]))
                }
            } else if ["pending", "paused"].contains(status) && CourierDo.tools.contains(tool) {  // a tool is never acted on twice: what was done is read, not done again
                try sql.update(self.clock(), id, [("status", "failed"), ("cause", "routerd restarted before the change was proved")])
            } else if status == "queued" {  // its earlier step's run is gone
                try sql.update(self.clock(), id, [("status", "refused"), ("cause", "routerd restarted before the step before it was confirmed")])
            }
        }
        // A send failed after a click is watched again for the rest of its watch (on uptime from now), those the start failed too. Every
        // other failed one keeps only its proof's tail, as a finished send's does. The time it was updated stays: cutting it changes no outcome.
        for i in try sql.intents(-1, status: "failed", columns: CourierStore.lean) {
            if Self.sends.contains(i.str("tool") ?? ""), let until = i.obj("result").get("watch")?.asDouble, until > self.clock() {
                watched[i["id"]?.asInt ?? 0] = self.uptime() + until - self.clock()
            }
        }
        for i in try sql.longProofs(CourierDo.kept) {
            let id = i["id"]?.asInt ?? 0
            if !watched.has(id) { try sql.update(i.num("updated") ?? 0, id, [("proof", CourierDo.tail(i["proof"] ?? .null))]) }
        }
        // acted, never proved: a later read can confirm
        unproved = Set(try sql.intents(-1, status: "failed", columns: CourierStore.lean).filter { i in
            CourierDo.tools.contains(i.str("tool") ?? "") && i.obj("result").flag("acted") && Self.provable(i.obj("result"))
        }.map { $0["id"]?.asInt ?? 0 })
        try markGoals()
    }

    /// `result.get("provable", True)` as a truth value.
    static func provable(_ result: JSON) -> Bool { result.has("provable") ? result["provable"]!.isTruthy : true }

    /// `p.update(chat=None, …)` on one of the acc's places.
    static func reset(_ places: inout JSONObject, _ key: String, _ fields: [String]) {
        guard var p = places[key]?.asObject else { return }
        for f in fields { p[f] = .null }
        places[key] = .object(p)
    }

    /// The store. A SQL error propagates as Python's does: out of `safely` as that run's failure, else out of the call, to the host (`carry_on`).
    var sql: CourierSQL { CourierSQL(db) }

    /// Each project's latest goal that was typed and not proved is marked: the tab, which a restart doesn't reload, may still show it.
    func markGoals(_ project: String? = nil) throws {
        if let project { staleGoal.pop(project) }
        for i in try sql.intents(-1, tool: "set_goal") {
            let result = i.obj("result")
            if result.has("acted") && (project == nil || project == i.str("project")) {
                let key = i.str("project") ?? ""
                if ["failed", "refused"].contains(i.str("status") ?? "") && (!result["acted"]!.isTruthy || result["provable"] == .bool(false)) {
                    staleGoal[key] = i
                } else {
                    staleGoal.pop(key)
                }
            }
        }
    }

    // ---- the Board in memory

    /// The Board as of the last event. Folded again only after a step.
    func board() -> JSON {
        if _board == nil { _board = CourierBoard.finish(acc) }
        return _board!
    }

    /// Appends Seen rows, steps the Board, and keeps the facts and claims the rows make for the next tell.
    func ingest(_ rows: [JSON]) throws {
        if rows.isEmpty { return }
        let rows = try sql.addSeen(clock(), rows)
        let threads = rows.contains { ["thread", "app"].contains($0["kind"]?.asString ?? "") }
        let before = threads ? board() : nil
        for r in rows { CourierBoard.step(acc, r) }
        _board = nil
        if threads { for f in CourierTell.facts(before!, board()) { facts[f["key"]?.asString ?? ""] = f } }
        trim()
    }

    /// The facts and claims waiting for a tell keep only the newest.
    func trim() {
        if acc.claims.count > Self.cap { acc.claims = Array(acc.claims.suffix(Self.cap)) }
        if facts.count > Self.cap { for key in facts.keys.dropLast(Self.cap) { facts.pop(key) } }
    }

    /// What the project's coordinator said that Fjord hasn't seen. Chat seen for the first time is only a baseline.
    func claimRows(_ project: String, _ messages: [JSON]) -> [JSON] {
        let seen = Set(acc.seenClaims.filter { $0.project == .string(project) }.map(\.key))
        let first = !chatted.contains(project)
        return messages.filter { m in
            m.get("from") == "claude" && CourierBoard.settled(m) && (m.get("text")?.isTruthy ?? false) && !seen.contains(m["key"] ?? .null)
        }.map { m in
            CourierLook.row("coordinator", "claim", project, [("project", .string(project)), ("thread", .null), ("key", m["key"] ?? .null), ("text", m["text"] ?? .null),
                                                              ("decision", .bool(m.get("decision")?.isTruthy ?? false)), ("baseline", .bool(first))])
        }
    }

    // ---- events

    /// One event from the page.
    func handle(_ event: JSON) throws {
        jump(clock())
        let type = event.get("type")?.asString
        let quiet = ["done", "notice", "wake_me"].contains(type ?? "\u{0}")
        if nopage && !(type == "page" || quiet) {
            try ingest([CourierPage.row("health", "page", [("page_ok", true)])])  // an event from the content script: there is a page after all
        }
        if !quiet { nopage = false }
        if type == "done" { return try done(event) }
        if type == "notice" {  // the page's own message, kept to say why a send it gave up on failed
            notice = ((event.get("text").map { $0.isTruthy ? $0.pyStr : "" }) ?? "", clock())
            return
        }
        if type == "commands" { return try replay(event) }
        if type == "wake_me" { return wakeMe(event.get("after")) }
        if type == "page" && event.get("gone") == .bool(true) {
            // The worker says the adopted page's port dropped (a reload, say): what was sent so far went to that page, so the next
            // page's `commands` answers for it, and one it doesn't list is dropped. Commands sent after this wait in the worker and
            // reach the next page before its snapshot does, so that snapshot lists them.
            linked = commands
            // A click reported just before went to that page, which may have gone before the server had the words: the next page's
            // rows of the place tell (`advance`: `vanished_at`). `reloaded` is when it went. A click older than RELOAD_LOSS isn't marked:
            // its words had time to reach the server, and a queued message is waited for as usual. A send still in the page when it
            // went keeps when (`gone_at`): if the next page's `commands` doesn't list it, it went with that page (`went`), which may
            // have typed and clicked it just then, so it is `reloaded` from then. One the next page still holds isn't.
            for run in runs.values {
                if run.flag("tool") { continue }
                if run.flag("clicked") && clock() - (run.num("click_at") ?? -.infinity) <= Self.reloadLoss { run.set("reloaded", clock()) }
                if run.str("stage") == "waiting" && inPage(run) { run["gone_at"] = [.double(clock()), run["command"] ?? .null] }
            }
            // The page is counted as replaced at the next `page` only if its (`loaded`, `instance`) differs. An extension reload keeps
            // the document but not the script: the new one's `recent` knows nothing of the old one's sends.
            regone = true
        }
        let (project, thread) = CourierPage.place(event)
        arrive(project != nil ? Place(project, thread) : nil)
        if type == "settings", let project { reads[project, default: 0] += 1 }
        if type == "projects" && event.get("complete") == .bool(true) { lists += 1 }
        let rows = CourierPage.seenRows(event)
        if type == "rows" && !rows.isEmpty {
            let subject = rows[0]["subject"]?.asString ?? "", messages = rows[0]["fields"]?["messages"]?.asArray ?? []
            if event.get("full") == .bool(true) && event.get("settled") == .bool(true) {  // the page's whole render of the place
                unsettled.remove(subject)
                try readWhole(Place(project, event.get("side") == "thread" ? thread : nil), event)
            }
            // Its first rows, maybe not all of them yet, also for a place Fjord has seen (rows may have come while it was away). A
            // delta with rows comes only after a whole read (an empty chat's is settled), so it adds rows to a render already known;
            // a turning-only delta (no rows) may come before it, and the Board leaves the place's rows unread for it (`boards.step`).
            else if event.get("full") == .bool(true) && !messages.isEmpty { unsettled.insert(subject) }
            if !messages.isEmpty { remember(subject, messages) }
        }
        if type == "rows" && event.get("side") == "project", let project {
            let claims = rows.isEmpty ? [] : claimRows(project, rows[0]["fields"]?["messages"]?.asArray ?? [])
            try ingest(rows + claims)
            if !rows.isEmpty && !(rows[0]["fields"]?["messages"]?.asArray ?? []).isEmpty { chatted.insert(project) }  // a page shows no rows before its transcript mounts: that isn't having seen the chat
        } else {
            try ingest(rows)
        }
        let loaded: JSON? = type == "page" ? event.get("loaded") : nil
        let instance: JSON? = type == "page" ? event.get("instance") : nil
        // The same script as the latest page's: an event without `instance` (an old page) is never taken as the same.
        let known = loaded?.numeric != nil && loaded == self.loaded && instance != nil && instance == self.instance
        // The first page since the host linked that comes from a document: content.js's always carries `loaded`; the worker's
        // page-less `page_ok: false` (no tab answered) carries none and defers it further. (fake_page sends no `loaded`.)
        if type == "page" && event.get("gone") != .bool(true) && relinked && (loaded != nil || event.get("page_ok") != .bool(false)) {
            let same = known && !regone
            let unran = self.unran
            relinked = false
            self.unran = []
            if same { try markUnran(unran) }  // the snapshot came from the document its sends were handed to
            try settleUnwent()
        }
        if type == "page" && event.get("gone") != .bool(true) && regone {  // the first page after a `gone`
            regone = false
            if !known { pages += 1 }  // no (`loaded`, `instance`) to tell by: taken as another document
            if loaded?.numeric != nil { self.loaded = loaded; self.instance = instance }
        } else if loaded?.numeric != nil && !(loaded == self.loaded && instance == self.instance) {
            // another document or script: a host lost and back may hide a reload, or an extension reload
            pages += self.loaded != nil ? 1 : 0
            self.loaded = loaded
            self.instance = instance
        }
        if let l = loaded?.numeric {  // a document loaded after a goal was marked shows the server's goals, not what was typed
            for (p, marked) in staleGoal.pairs where l / 1000 > (marked.num("updated") ?? marked.num("at") ?? 0) { staleGoal.pop(p) }
        }
        if type == "settings", let project { dropStaleGoal(project) }  // the tab shows another goal now: the refused one is gone from it
        // The live runs first; the place's sends are judged together (`proved_at`), so a row of a watched send's words is its, not a
        // live run's, and reconcile_sends then confirms it.
        try advanceAll()
        if !unproved.isEmpty && (type == "settings" || type == "projects") {
            try reconcile(type!, project, complete: event.get("complete") == .bool(true))
        }
        if !watched.isEmpty && type == "rows", let project { try reconcileSends(Place(project, event.get("side") == "thread" ? thread : nil)) }
    }

    /// A settled whole read of a place came: a watched send's going back there is over, used (`release_watch`), and a look there
    /// knows its outcome (`look_read`): the run's next step ends it, the proof placed against this read. Only a read made after the
    /// look's open (the tab arrived since it went out, or its `done` came first): one from before is the render the look is there to
    /// refresh. Not one that shows a row of yours still pending, or the coordinator mid-turn: the server may hold your message
    /// queued, and the row may key moments later, so the look waits on to its end.
    func readWhole(_ place: Place, _ event: JSON) throws {
        if let w = watchOpen, w.to == place, arrivals > w.openFrom || w.open == nil || w.shown {
            // An open for a place the tab already shows moves no tab: the page's own read after the send is the one it answers with.
            releaseWatch(used: true)
        }
        let rows = event.get("rows")?.asArray ?? []
        if event.get("turning") == .bool(true) || rows.contains(where: { r in
            if case .object = r { return r.get("from") == "you" && (r.get("pending")?.isTruthy ?? false) } else { return false }
        }) { return }
        for run in runs.values {
            if !run.flag("tool") && lookLive(run) && (arrivals > (run["open_from"]?.asInt ?? arrivals) || run.flag("look_done") || (run.flag("open") && run.flag("open_shown"))) {
                let intent = try sql.intent(run.id)
                if Place(intent.str("project"), intent.str("thread")) == place { run["look_read"] = true }
            }
        }
    }

    /// A read's keys go to the end of the place's `known`, in index order: its tail is the rows read last, the latest.
    func remember(_ subject: String, _ messages: [JSON]) {
        var keys = known[subject] ?? OrderedMap()
        for m in messages.stableSorted(by: { $0["index"]?.numeric ?? 0 }) {
            let key = m["key"]?.pyStr ?? ""
            keys.pop(key)
            keys[key] = true
        }
        known[subject] = keys
    }

    /// The tab shows another place. What the Board held of the places on screen is from a past visit: the page sends it again in full,
    /// and until a whole read of it is `settled` it is unsettled, seen before or not: rows may have come while the tab was elsewhere,
    /// and a first render can lack them (the bottom ones). A thread opened or closed in the same project is no arrival on the project:
    /// the page keeps its chat rendered beside the thread, and content.js keeps the project side's settling too (its arrival is the
    /// address's path, `told.arrived`), so only the thread is read afresh. The page still sends the project's whole read again; one that
    /// isn't settled (a remounted transcript) makes it unsettled as any does.
    func arrive(_ here: Place?) {
        let current = Place(acc.here)
        if here == current && (here != nil) == (acc.here.isTruthy) { return }
        let was = current
        acc.here = here?.json ?? .null
        _board = nil
        arrivals += 1
        // The tab arrived somewhere after a taken send's open was done: its move is over, wherever it went, so it holds nobody, and the
        // timer (`next_deadline`) keeps no hold for it.
        if let w = watchOpen, w.open == nil, let from = w.movingFrom, from != arrivals, !shows(acc, w.to) {
            releaseWatch(used: false)  // the tab went elsewhere after its `done` (you moved it): its place wasn't read, it may go again
        }
        for run in runs.values {
            if run.flag("moving_to") && !run.flag("open"), let from = run["moving_from"]?.asInt, from != arrivals {
                run["moving_to"] = .null
                run.pop("hold_until")
            }
        }
        if let here {
            if !(was != nil && was!.project == here.project), let project = here.project {
                unsettled.insert(project)
                arrived = (project, clock())
                if acc.projects.has(project) { Self.reset(&acc.projects, project, ["chat", "draft", "disabled", "turning", "turn_state"]) }
            }
            if let thread = here.thread, !thread.isEmpty {
                unsettled.insert(thread)
                if acc.threads.has(thread) { Self.reset(&acc.threads, thread, ["messages", "draft", "disabled", "turning", "turn_state"]) }
            }
        }
    }

    /// The tab shows the place and its rows and composer have arrived since. No rows at all for a chat that had some, or for a thread (it
    /// always has its opening message), is the page still loading: its composer can mount before its transcript. For a chat routerd
    /// hasn't seen, the page sends no rows only once its transcript mounted, its rows were fetched and it stayed empty since (content.js's
    /// `settledEmpty`: the page can mount it before its rows), so that empty baseline doesn't turn its history, rendered later, into news.
    /// Every place waits, after the tab arrived on it, for a whole read the page marks `settled` (its render done), since a first render
    /// can lack the bottom rows: the stored keys in the baseline don't cover rows added while the tab was elsewhere.
    func ready(_ board: JSON, _ place: Place) -> Bool {
        let shown = CourierBoard.placeOf(board, place.project, place.thread)
        let rows = CourierBoard.rowsOf(shown, place.thread)
        let subject = place.thread ?? place.project ?? ""
        return shows(board, place) && rows != nil && (!(rows!.isEmpty) || (place.thread == nil && (known[place.project ?? ""]?.isEmpty ?? true)))
            && !unsettled.contains(subject) && shown?.get("draft") != nil
    }

    /// For a project place the tab shows whose whole read hasn't settled since it arrived there: true once FRESH_AFTER has passed
    /// since that arrival, else the time it will have (a float). nil for anything else: a thread (its side settles by the page's flushes,
    /// not by a fetch), a place not shown, or one settled.
    enum Stale: Equatable { case yes, due(Double) }
    func stale(_ board: JSON, _ place: Place) -> Stale? {
        if place.thread != nil || !unsettled.contains(place.project ?? "\u{0}") || !shows(board, place) || arrived.project != place.project { return nil }
        let due = arrived.at + Self.freshAfter
        return clock() >= due ? .yes : .due(due)
    }

    /// The tab shows the project and its composer has arrived since: where a tool starts. A tool acts in the settings dialog, not the
    /// chat, so it waits neither for the chat's rows nor for a settled read of them (`ready`).
    func composes(_ board: JSON, _ project: String) -> Bool {
        shows(board, Place(project, nil)) && CourierBoard.placeOf(board, project, nil)?.get("draft") != nil
    }

    /// The clock jumped (the Mac slept): a deadline that is long past was not missed, so it moves on by a full wait, and a taken
    /// message's wait is pushed back with it. A send's watch after it failed after a click is on `uptime`, which a sleep doesn't move.
    func jump(_ now: Double) {
        // The jump is seen against the last check too, not only a deadline: a taken run paused across the sleep (no deadline) has its
        // waits pushed back as well, or it would take its look at once when the page is back. The sleep is the wall clock's gap less
        // uptime's, so a long idle stretch while awake isn't one.
        let up = uptime()
        let (wall, wasUp) = lastSeen ?? (now, up)
        lastSeen = (now, up)
        let gap = (now - wall) - (up - wasUp)
        let jumped = gap > CourierDo.timeout
        for run in runs.values {
            let late = run.num("deadline").map { now - $0 } ?? 0
            // At least the sleep: a deadline only a little late (a taken send's long wait) has its waits moved by the whole sleep.
            let shift = max(late > CourierDo.timeout ? late + CourierDo.timeout : 0, jumped ? gap : 0)
            if late > CourierDo.timeout {
                run.set("deadline", now + CourierDo.timeout)
                if run.flag("looking") { run["looking"] = run["deadline"] }
            } else if shift != 0 {  // a sleep shorter than the lateness plus a wait: the deadline and the look's end move on by the sleep too
                for key in ["deadline", "looking"] { if let v = run.num(key) { run.set(key, v + shift) } }
            }
            if shift != 0 {
                for key in ["accepted", "vanished_at", "reloaded", "turn_seen", "grace", "click_at"] {  // `grace`: the app's thread's wait
                    if run.flag(key), let v = run.num(key) { run.set(key, v + shift) }
                }
                for key in ["limit", "fresh_at", "hold_until", "relook_by"] {  // its attempt's end, when its `fresh` open is due, its open's hold, a lost look's
                    if run.flag(key), let v = run.num(key) { run.set(key, v + shift) }
                }
                if run.flag("gone_at"), let g = run["gone_at"]?.asArray, g.count == 2 {  // when its page went: it becomes `reloaded` if the next page lost it (`went`)
                    run["gone_at"] = [.double((g[0].numeric ?? 0) + shift), g[1]]
                }
            }
        }
        if jumped, let w = watchOpen { w.holdUntil += gap }  // a watched send's going back holds on across the sleep, as a run's open does
        if jumped && arrived.project != nil { arrived = (arrived.project, arrived.at + gap) }  // the page slept too: FRESH_AFTER for its settling counts from the wake (`stale`)
        for (id, due) in closing.pairs where now - due > CourierDo.timeout {  // a dialog's close waited on across the sleep gets its full wait too
            closing[id] = now + CourierDo.timeout
        }
    }

    /// A native host connected or went away. `current`: the one leaving is the one commands go to (the latest linked). An older
    /// host whose socket closes after a newer one linked takes nothing with it: the commands since went to the newer one.
    func connection(_ up: Bool, current: Bool = true) throws {
        hosts = max(0, hosts + (up ? 1 : -1))
        if up || current || hosts == 0 { try settleUnwent() }  // no `page` decided them: taken as gone with the page
        if up {
            linked = commands
            relinked = true
            unran = []
            sendWake()  // a wake due while no host was linked was dropped, and the page doesn't ask again: settling is idempotent
        }
        if !up && (current || hosts == 0) {  // a cancel lost with the host: a later snapshot listing the old command cancels it again
            cutOld.removeAll()
            if let w = watchOpen, w.open != nil { releaseWatch(used: false) }  // lost with the host: it moves no tab, and may go again
            for run in runs.values {  // a taken send's open lost with the host moves no tab: it holds nobody (`going_back`)
                if !run.flag("tool") && yielded(run) && run.flag("open") { lostOpen(run) }
            }
        }
        if hosts == 0 {  // a `done` lost with the host comes back in the page's next `commands`
            // Where the tab is, and what it showed, is unknown until the next host's events: each watched send may go back once more.
            watchBack.removeAll()
            watchOpen = nil
            // A goal the tab shows wrongly stays marked: a host lost isn't the tab reloaded, and the page keeps its copy of the goal.
            arrive(nil)
            gone()
            for k in acc.projects.keys { Self.reset(&acc.projects, k, ["chat", "draft", "disabled", "turning", "turn_state"]) }
            for k in acc.threads.keys { Self.reset(&acc.threads, k, ["messages", "draft", "disabled", "turning", "turn_state"]) }
            _board = nil
        }
        // At a link the health kept from before is stale (the page may be gone, and an open sent on it fails if the worker finds no
        // tab): the page can't be read until the worker's first event says whether there is one (`connectHost`), so a tick between
        // the two moves no run on a `page_ok: true` from the host before.
        try ingest([CourierPage.row("health", "page", [("connected", .bool(hosts > 0))] + (up ? [("page_ok", false)] : []))])
        nopage = up || (nopage && hosts > 0)
        if !up { try advanceAll() }
    }

    func connected() -> Bool { hosts > 0 }

    /// Why a paused run waits, said again: Chrome may have started (its profile picker showing) since the reason was set.
    func recheckPauses() throws {
        let why = CourierDo.blocked(board()["health"] ?? .null)
        for run in runs.values {
            if run.flag("paused"), let why {
                let intent = try sql.intent(run.id)
                if intent.str("status") == "paused" && intent.str("cause") != why && !pyStartsWith(intent.str("cause") ?? "", "waiting for the Claude app") {
                    try sql.update(clock(), run.id, [("cause", .string(why))])
                }
            }
        }
    }

    func local(_ local: JSON?) throws {
        guard let local, local.isTruthy else { return }
        let now = clock()
        let known = (board()["projects"]?.asObject?.values ?? []).filter { $0.get("where") == "cloud" }.map { (p: JSON) -> JSON in ["id": p["id"] ?? .null, "name": p["name"] ?? .null] }
        let rows = CourierLook.localRows(board(), local, known, now)
        let key: JSON = .array(rows.map { [$0["kind"] ?? .null, $0["subject"] ?? .null, $0["fields"] ?? .null] })
        if lastLocal != key {
            lastLocal = key
            try ingest(rows)
            try advanceAll()
        }
    }

    // ---- do

    func nextID() -> String { "c\(startID).\(commands + 1)" }

    /// Sends a command to the page: `{"id": …, "kind": kind, **fields}`. Returns its id.
    @discardableResult
    func command(_ kind: String, _ fields: [(String, JSON)] = []) -> String {
        let id = nextID()
        var c = JSONObject([("id", .string(id)), ("kind", .string(kind))])
        for (k, v) in fields { c[k] = v }
        commands += 1
        out(.object(c))
        return id
    }

    /// A dev step: sends one page command that belongs to no run and calls `reply` with its `done`. No intent, no proof. Sends and
    /// tool runs wait while it is in the page (`tool_busy`): it may have a dialog open. With no host linked nothing is
    /// sent and `reply` says so at once (returns nil).
    @discardableResult
    func devCommand(_ kind: String, _ reply: @escaping (JSON) -> Void, _ fields: [(String, JSON)] = []) -> String? {
        if !connected() {
            reply(["ok": false, "error": "no host linked"])
            return nil
        }
        let id = command(kind, fields)
        dev[id] = reply
        return id
    }

    /// Gives up on a dev command still waiting: the page is told to drop it, and its `done` is no longer waited for. Returns whether it
    /// was still waiting: false when its `done` already came.
    func devCancel(_ id: String) throws -> Bool {
        if dev.pop(id) != nil {
            command("cancel", [("target", .string(id))])
            try advanceAll()  // the sends that waited for it go on
            return true
        }
        return false
    }

    func ms(_ run: Run) -> Int { Int(((clock() - (run.num("t0") ?? 0)) * 1000).rounded(.toNearestOrEven)) }

    /// Begins delivering a pending send or tool. Anything else is already done.
    func start(_ intent: JSON, _ t0: Double) throws {
        if intent.str("status") != "pending" || !Self.runs_.contains(intent.str("tool") ?? "") { return settle(intent) }
        addRun(intent, t0)
        try advanceAll()
    }

    func addRun(_ intent: JSON, _ t0: Double) {
        let id = intent["id"]?.asInt ?? 0
        let run = Run(JSONObject([("id", .int(id)), ("stage", "start"), ("t0", .double(t0)), ("deadline", .null), ("paused", false),
                                  ("ms", ["decided": .int(Int(((clock() - t0) * 1000).rounded(.toNearestOrEven)))]),
                                  ("tool", .bool(CourierDo.tools.contains(intent.str("tool") ?? "")))]))
        if run.flag("tool") { goto(run, "start") }
        runs[id] = run
    }

    /// The run no longer needs the composer: a send the page took, or a tool whose act is done (it may still read to prove it).
    func yielded(_ run: Run) -> Bool {
        run.flag("tool") ? Self.proving.contains(run.str("stage") ?? "") : run.flag("taken")
    }

    /// The run's last command still waits in the page: not answered, not cancelled, and not missing from a reconnected page's list.
    /// A cancelled send keeps its `command`, so a click the page made before the cancel still lands as its `done`.
    func inPage(_ run: Run) -> Bool {
        guard run.flag("command") else { return false }
        let c = run["command"]!
        return c != (run.get("answered") ?? .null) && c != (run.get("dropped") ?? .null)
    }

    /// A send still waiting in the page is cut off. The page sends no `done` for a cancelled send: it is `dropped`, out of the page. It
    /// stays the run's `command`, and among its `sends`: a click the page made before the cancel arrived still counts when its `done` comes.
    func cancelSend(_ run: Run) {
        let cancel = command("cancel", [("target", run["command"] ?? .null)])
        run["dropped"] = run["command"]
        run.put("cuts", run.str("command") ?? "", seq(cancel).map(JSON.int) ?? .null)  // its cancel's place in the order (`unheard_sends`)
    }

    /// A send dropped with the page it was handed to (`replay`): that page may have typed and clicked it, and the server may have
    /// the words, so it is never sent again, not even click-only (the next page may show them in its draft, its saved draft). It is taken:
    /// its row proves it, or it fails as taken and is watched (`finish`). No page took this click: words back in a draft aren't one
    /// giving up.
    func went(_ run: Run) throws {
        clicked(run)
        run["taken"] = true
        run["click_page"] = .null
        run["went"] = true
        // Dropped with a page that went (a reload: `gone`): the next page's settled rows tell, as after a click a reload may have lost
        // (`vanished_at`), so it fails about do.TIMEOUT after the page went. One dropped at a host's reconnect (no `gone`) waits ACCEPTED_WAIT.
        let g = run.pop("gone_at")
        if (g?.isTruthy ?? false), let a = g?.asArray, a.count == 2, a[1] == (run["command"] ?? .null), (run.get("reloaded") == nil) {
            run["reloaded"] = a[0]
        }
        try sql.update(clock(), run.id, [("cause", "the page it was handed to went before it said what it did")])
    }

    /// The run may have sent the words. A restart watches any send that issued one (its baseline), so this isn't kept.
    func clicked(_ run: Run) { run["clicked"] = true }

    /// A `done` the run still waits for: its open's, its tool command's, or one of the sends it issued that hasn't been heard from.
    func unheard(_ run: Run, _ id: String) -> Bool {
        id == run.str("open") || (run.flag("tool") && id == run.str("command")) || (run.strings("sends").contains(id) && !run.strings("heard").contains(id))
    }

    /// A command's place in this routerd's order, or nil for another's (an older routerd's, a page's own).
    func seq(_ id: String?) -> Int? {
        let s = id ?? ""
        guard let dot = s.lastIndex(of: ".") else { return nil }
        let head = String(s[..<dot]), n = String(s[s.index(after: dot)...])
        return head == "c\(startID)" && !n.isEmpty && n.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(n) : nil
    }

    /// Sends the run issued that no `done` answered: a cut-off one may still have clicked, its `done` to come. The page runs commands in
    /// order, so once the `done` of a command after its cancel arrived from the document it was handed to, a cut-off send with none never
    /// ran: its cancel reached the page first. A later command's `done` alone says nothing: a send waits in the page while the page
    /// settles, and a dev command or a read may run meanwhile. A send never cut off is unheard until its `done`.
    func unheardSends(_ run: Run) -> [String] {
        let cuts = run.get("cuts")?.asObject ?? JSONObject(), pages = run.get("send_pages")?.asObject ?? JSONObject()
        let heard = run.strings("heard")
        return run.strings("sends").filter { id in
            !heard.contains(id) && !((cuts[id]?.isTruthy ?? false) && pages.has(id) && (lastDone[pages[id]?.asInt ?? -1] ?? 0) > (cuts[id]?.asInt ?? 0))
        }
    }

    /// The run has the tab: past its start, or it opened, or a command of its own is in the page. A send cut off (`cancel_send`) is out
    /// of the page, but isn't acting only when its caller also resets its stage to `start` (a hand-off to the coordinator, the app
    /// closing, a tool's dialog); one cut off to open its place again is `opening`, which acts.
    func acting(_ run: Run) -> Bool {
        run.str("stage") != "start" || run.flag("opened") || (run.flag("tool") ? run.flag("command") : inPage(run))
    }

    /// The run's look is under way: its `looking` is set and not passed.
    func lookLive(_ run: Run) -> Bool {
        run.flag("looking") && clock() < (run.num("looking") ?? 0)
    }
}

/// The store as the Core uses it: every call can throw, as Python's can; `safely` turns a throw in one run's step into that run's failure.
struct CourierSQL {
    let db: CourierStore
    init(_ db: CourierStore) { self.db = db }
    func compact(_ before: Double) throws { try db.compact(before: before) }
    func seen(last: Int?) throws -> [JSON] { try db.seen(last: last) }
    func mark() throws -> Int { try db.mark() }
    func setMark(_ v: Int) throws { try db.setMark(v) }
    func lastSeenId() throws -> Int { try db.lastSeenId() }
    func chatProjects() throws -> Set<String> { try db.chatProjects() }
    func addSeen(_ now: Double, _ rows: [JSON]) throws -> [JSON] { try db.addSeen(now, rows) }
    func intents(_ limit: Int = 50, status: String? = nil, tool: String? = nil, columns: String = "*") throws -> [JSON] {
        try db.intents(limit: limit, status: status, tool: tool, columns: columns)
    }
    func longProofs(_ kept: Int) throws -> [JSON] { try db.longProofs(kept: kept) }
    /// `store.intent`: nil when there is none.
    func intentOrNil(_ id: Int) throws -> JSON? { try db.intent(id) }
    /// `store.intent` for an intent that exists.
    func intent(_ id: Int) throws -> JSON { try intentOrNil(id) ?? .null }
    @discardableResult
    func update(_ now: Double, _ id: Int, _ changes: [(String, JSON)]) throws -> JSON { try db.updateIntent(now, id, changes) ?? .null }
    func addIntent(_ now: Double, _ tool: String, words: String? = "", project: String? = nil, thread: String? = nil, args: JSON? = nil, proof: JSON? = nil,
                   status: String = "pending", dup: Bool = true, more: [(String, JSON)] = []) throws -> (intent: JSON, created: Bool) {
        try db.addIntent(now, tool, words: words, project: project, thread: thread, args: args, proof: proof, status: status, dup: dup, more: more)
    }
    func told() throws -> JSONObject { try db.told() }
    func setTold(_ now: Double, _ key: String, _ project: String?, _ kind: String?, _ detail: String?, _ text: String?) throws { try db.setTold(now, key, project, kind, detail, text) }
    func notes() throws -> JSONObject { try db.notes() }
    func setNote(_ now: Double, _ topic: String, _ text: String) throws { try db.setNote(now, topic, text) }
}

/// Whether the tab shows the place. A project shows with or without a thread open beside it: arriving on a project, the page
/// reopens the thread last shown there, and the project's chat and composer are still there.
func shows(_ board: JSON, _ place: Place) -> Bool {
    let here = board["here"]
    let at = Place(here)
    if let at, at == place { return true }
    return place.thread == nil && (here?.isTruthy ?? false) && at?.project == place.project
}

func shows(_ acc: CourierAcc, _ place: Place) -> Bool {
    shows(["here": acc.here], place)
}

// MARK: - The page's reports (replay, done, late reports) and the owner's calls

extension CourierCore {
    private func seqOr(_ id: String?, _ other: Int) -> Int { seq(id) ?? other }

    /// The page's `commands`, sent with each snapshot: the ids still waiting in it, and the last `done`s it sent. A replayed `done` for
    /// a run's open or command that is still unanswered is handled now, as the late `done` it is (an ok send's is its click). A run's
    /// command sent before the host connected, or before the worker said the page was gone, that the page neither lists as waiting nor
    /// reported done (a reloaded page) is marked `dropped`: it no longer holds the tab (`in_page`). It stays unanswered. A send its run
    /// waits on reached a page (a send is made only while a host is linked) that may have typed and clicked it before it went: it is
    /// taken (`went`) and never sent again, at once (a paused one when it comes out of the pause), unless the document it was handed
    /// to says it never ran: then it is sent again (`went_or_retry`; after a new link, decided at the next `page`). A command an earlier routerd start sent that still waits has no run to answer for it: it is
    /// cancelled, so an old send can't click.
    func replay(_ event: JSON) throws {
        let done = event.get("done")?.asArray ?? []
        for d in done {
            guard case .object = d else { continue }
            if let s = d["settings"], case .object = s { try replayedSettings(d) }
            let watchedOpen = watchOpen?.open
            if let id = d.get("id")?.asString, !id.isEmpty, dev.has(id) || id == watchedOpen || runs.values.contains(where: { unheard($0, id) }) {
                try self.done(d, replayed: true)
            }
            if let id = d.get("id")?.asString { closing.pop(id) }
            try typedNothing(d)
            try lateDone(d)
        }
        if let waitingJSON = event.get("waiting")?.asArray {
            let waiting = waitingJSON.compactMap(\.asString)
            closing = {  // a read's close the page no longer holds (a reloaded page) blocks nobody
                var kept = OrderedMap<String, Double>()
                for (k, v) in closing.pairs where waiting.contains(k) { kept[k] = v }
                return kept
            }()
            let olds = waiting.filter { !pyStartsWith($0, "c\(startID).") && !cutOld.contains($0) }
            for old in olds {
                cutOld.insert(old)
                command("cancel", [("target", .string(old))])
            }
            // Fewer than 20 `done`s is all this document has said: a send handed to it that it neither lists as waiting nor reported
            // done never ran, its cancel first, so it is no longer waited on (`unheard_sends`). Only for the document the send was
            // handed to (`send_pages`), which the snapshot may not come from: after a `gone`, or a host linked again (the tab may have
            // reloaded while none was), `pages` is counted at the next `page` that carries `loaded` (not the worker's page-less one), so
            // the marks wait for it to carry the same `loaded`.
            // Only from the script it was handed to (`send_scripts`): a new script's (an extension reload's) `done` list starts empty, and
            // proves nothing of an older one's sends. A snapshot without `instance` (an old page) proves nothing either.
            let said = Set(done.compactMap { d -> String? in if case .object = d { return d.get("id")?.asString } else { return nil } })
            let script = event.get("instance")
            if done.count < 20 && !regone, let script {
                var unran: [(Int, String)] = []
                for run in runs.values {
                    for id in run.strings("sends") {
                        if seqOr(id, linked + 1) <= linked && !waiting.contains(id) && !said.contains(id)
                            && run.get("send_pages")?.get(id) == .int(pages) && run.get("send_scripts")?[id] == script {
                            unran.append((run.id, id))
                        }
                    }
                }
                // So does a tool's act (the worker failed it, its `done` lost with the port): nothing was done (`tool_unran`).
                for run in runs.values where run.flag("tool") && run.str("stage") == "act" && run.flag("command") {
                    let c = run.str("command") ?? ""
                    if seqOr(c, linked + 1) <= linked && !waiting.contains(c) && !said.contains(c) && run.get("command_page") == [.int(pages), script] {
                        unran.append((run.id, c))
                    }
                }
                if relinked { self.unran = unran } else { try markUnran(unran) }
            }
            // A taken send's open (its going back, or its look) sent before the page went that it neither lists nor reported done never
            // ran: the tab won't move for it, so it holds nobody (`going_back`). A look's own deadline still ends it.
            for run in runs.values {
                if let o = run.str("open"), !run.flag("tool"), yielded(run), seqOr(o, linked + 1) <= linked, !waiting.contains(o), !said.contains(o) { lostOpen(run) }
            }
            // a watched send's going back that never ran: as a taken send's (`lost_open`)
            if let o = watchOpen?.open, seqOr(o, linked + 1) <= linked, !waiting.contains(o), !said.contains(o) { releaseWatch(used: false) }
            var lost: [Run] = []
            for run in runs.values {
                let command = run.str("command")
                let sent = command != nil && seqOr(command, linked + 1) <= linked  // one sent since may not be listed yet
                if let command, waiting.contains(command) { run.pop("gone_at") }  // the next page holds it: it didn't go with the page that went
                if sent, let command, run.get("answered") != .string(command), !waiting.contains(command) {
                    if !run.flag("tool") && run.str("stage") == "waiting" && !run.flag("paused") && run.get("dropped") != .string(command) { lost.append(run) }
                    run["dropped"] = .string(command)
                }
            }
            // A dev command sent before the page went (or before the host linked) that it neither lists nor reported done went with it:
            // its caller is told, and the sends it held go on.
            for id in dev.keys where seqOr(id, linked + 1) <= linked && !waiting.contains(id) {
                dev.pop(id)?(["type": "done", "id": .string(id), "ok": false, "error": "the page went before it answered"])
            }
            for run in lost {
                if !runs.has(run.id) { continue }
                if relinked {  // the next `page` says whether the snapshot is of the document the send was handed to
                    run["went_due"] = true
                    unwent.append(run.id)
                } else {  // it reached a page (a send is made only while a host is linked), which may have clicked it, unless it never ran
                    try wentOrRetry(run)
                }
            }
        }
        try advanceAll()
    }

    /// A taken send's open (its going back, or its look) that never reached a page: the tab won't move for it, so it holds nobody
    /// (`going_back`). A look's open is sent again, once (`relooked`), with a fresh wait, when it is next advanced with a host linked;
    /// a second lost one leaves the look to its deadline. A going back may go again (`back`).
    func lostOpen(_ run: Run) {
        run["open"] = .null; run["moving_to"] = .null; run["look_read"] = false; run["look_done"] = false
        run.pop("hold_until")
        if !run.flag("looking") {
            run["back"] = .null
        } else if !run.flag("relooked") {  // it is sent again by `relook_by`, when a host is linked by then
            run["looking"] = .null; run["relooked"] = true; run.set("deadline", clock()); run.set("relook_by", clock() + CourierDo.timeout)
        }
    }

    /// A send dropped from the page it was handed to: one that document says never ran (`mark_unran`) is made again, typed again if
    /// no click was reported; any other went with it (`went`).
    func wentOrRetry(_ run: Run) throws {
        run.pop("went_due")
        if run.strings("unran").contains(run.str("command") ?? "\u{0}") { try neverRan(run) } else { try went(run) }
        safely(run)
    }

    /// A send its document says never ran (`mark_unran`): no attempt used. The same attempt goes on (`ignored`), made again with a
    /// fresh wait of its own.
    func neverRan(_ run: Run) throws {
        run.pop("gone_at")
        run["stage"] = "start"; run["deadline"] = .null; run["ignored"] = true; run.set("limit", clock() + CourierDo.timeout)
        try sql.update(clock(), run.id, [("cause", .null)])
    }

    /// The sends `replay` dropped while relinked, decided now that the next `page` came (its never-ran marks made or not).
    func settleUnwent() throws {
        let list = unwent
        unwent = []
        for id in list {
            if let run = runs[id], run.flag("went_due") { try wentOrRetry(run) }
        }
    }

    /// [(run id, send id)]: sends the document they were handed to says never ran (`replay`).
    func markUnran(_ unran: [(Int, String)]) throws {
        for (runID, id) in unran {
            if let run = runs[runID], run.flag("tool") {
                if run.str("stage") == "act" && run.str("command") == id { try toolUnran(run) }
                continue
            }
            if let run = runs[runID] {
                run.insert("heard", id)
                run.insert("unran", id)
            }
        }
    }

    /// A tool's act the document it was handed to says never ran (`replay`: the worker failed it, its `done` lost): as an act that
    /// erred before its one change (`ok: false`, not `committed`), nothing was done, and a goal typed nowhere marks no stale goal.
    func toolUnran(_ run: Run) throws {
        let intent = try sql.intent(run.id)
        run["command"] = .null
        try keep(run, [("acted", false)] + (intent.str("tool") == "set_goal" ? [("provable", true)] : []))
        try finish(run, "failed", "the page never ran the step: it went before it said what it did")
    }

    /// A replayed read's settings, handled only for a read still unheard (a tool's command or a dev command no `done` answered yet)
    /// and only once: an old read's settings repeated by each snapshot would bump the reads (a tool's proving read would be this old
    /// one) and drop a goal's mark. Only what a settings read does is done: no arrival (the event's place is the read's, not the tab's
    /// now), and the runs advance after the snapshot as a whole.
    func replayedSettings(_ d: JSON) throws {
        guard let id = d.get("id")?.asString, !readsDone.has(id), dev.has(id) || runs.values.contains(where: { $0.flag("tool") && unheard($0, id) }) else { return }
        readHeard(id)
        var event = d["settings"] ?? .null
        event["type"] = "settings"
        guard let project = CourierPage.place(event).project else { return }
        reads[project, default: 0] += 1
        try ingest(CourierPage.seenRows(event))
        dropStaleGoal(project)
        if !unproved.isEmpty { try reconcile("settings", project) }
    }

    /// A read's `done` heard, its settings handled: kept for the newest CAP.
    func readHeard(_ id: String) {
        readsDone[id] = true
        for old in readsDone.keys.dropLast(Self.cap) { readsDone.pop(old) }
    }

    /// A settings read that shows another goal than the refused one marked: the tab no longer shows it.
    func dropStaleGoal(_ project: String) {
        if let marked = staleGoal[project], !CourierDo.toolProved(board(), marked).holds { staleGoal.pop(project) }
    }

    /// A tool's act that an earlier routerd start sent (or that its run was cut off from) and that failed unproved: the page's replayed
    /// `done` for it says what it did. A 2xx `saved` is the server's answer, so the act is confirmed (a goal's too: provable). A refusal
    /// before the change (`ok: false`, not `committed`) means nothing was done. `already` is `typed_nothing`'s. Its run is over: this
    /// changes the intent, never a run.
    func lateDone(_ d: JSON) throws {
        guard case .object = d, let did = d.get("id")?.asString else { return }
        var candidates = unproved
        for m in staleGoal.values { if let i = m["id"]?.asInt { candidates.insert(i) } }
        for intentID in candidates.sorted() {
            let intent = try sql.intent(intentID)
            let result = intent.obj("result")
            if runs.has(intentID) || result.get("act") != .string(did) || !result.flag("acted") || d.get("already") == .bool(true) { continue }
            let goal = intent.str("tool") == "set_goal"
            if d.flag("ok"), let saved = d.get("saved"), saved.isPyInt, let s = saved.numeric, s >= 200 && s < 300 {
                unproved.remove(intentID)
                try confirmLate(intent, "confirmed by the page's late report of its save", goal ? ["provable": true] : nil)
                if goal { try markGoals(intent.str("project")) }
            } else if d.get("ok") == .bool(false) && !d.flag("committed") {
                unproved.remove(intentID)
                var r = result.asObject ?? JSONObject()
                r["acted"] = false
                if goal { r["provable"] = true }
                try sql.update(clock(), intentID, [("result", .object(r))])
                if goal { try markGoals(intent.str("project")) }
            }
        }
    }

    /// A tool that was done but not confirmed is confirmed after all. The steps it stopped are not run now: nobody waits on them any
    /// more, and they were checked against a board that has moved on. Their cause stops naming a failure that turned out not to be one.
    func confirmLate(_ intent: JSON, _ cause: String, _ result: JSON? = nil, columns: [(String, JSON)] = []) throws {
        var merged = intent.obj("result").asObject ?? JSONObject()
        merged.update(result?.asObject ?? JSONObject())
        try sql.update(clock(), intent["id"]?.asInt ?? 0, [("status", "confirmed"), ("cause", .string(cause)), ("result", .object(merged))] + columns)
        let n = intent.obj("result").get("step") ?? .int(1)
        for i in intent.obj("result").get("stopped")?.asArray ?? [] {
            if try sql.intent(i.asInt ?? 0).str("status") == "refused" {
                try sql.update(clock(), i.asInt ?? 0, [("cause", .string("step \(n.pyStr) (\(intent.str("tool") ?? "")) was confirmed later, by a read; this step wasn't run"))])
            }
        }
    }

    /// A goal's act an earlier routerd start sent, which the page reports found it already so: nothing was typed, so its goal is no
    /// longer marked as one the tab may show unsaved (an older mark of that project's still holds).
    func typedNothing(_ d: JSON) throws {
        guard case .object = d, d.get("already") == .bool(true), let did = d.get("id")?.asString else { return }
        for (p, marked) in staleGoal.pairs {
            if marked.obj("result").get("act") == .string(did) {
                var result = JSONObject()
                for (k, v) in marked.obj("result").asObject ?? JSONObject() where k != "acted" && k != "provable" { result[k] = v }
                try sql.update(clock(), marked["id"]?.asInt ?? 0, [("result", .object(result))])
                try markGoals(p)
            }
        }
    }

    /// A reply to a stranded thread goes to its project's coordinator instead: one ordinary project send, with the same proof, that asks
    /// for a new thread continuing it. `continues` ties the new thread to the old one. Nothing is sent into the dead thread.
    func handOff(_ intent: JSON, _ t: JSON) throws -> JSON {
        let (words, args) = CourierDo.handoff(t, intent.str("words") ?? "")
        let proof: JSON = ["kind": "latest_you", "project": t["project"] ?? .null, "thread": .null, "words": .string(words)]
        var changed = intent
        changed["args"] = args
        var result = intent.obj("result").asObject ?? JSONObject()
        result["warning"] = JSON(CourierDo.warning(board(), changed))
        return try sql.update(clock(), intent["id"]?.asInt ?? 0, [("tool", "send_to_project"), ("words", .string(words)), ("project", t["project"] ?? .null), ("thread", .null),
                                                             ("args", args), ("proof", proof), ("result", .object(result))])
    }

    /// Status and cause change only when they differ. A paused intent answers whoever waits: it goes on by itself when the page is back.
    func mark(_ intent: JSON, _ status: String, _ cause: String?) throws {
        if intent.get("status") != .string(status) || intent.get("cause") != cause.map(JSON.string) {
            let updated = try sql.update(clock(), intent["id"]?.asInt ?? 0, [("status", .string(status)), ("cause", JSON(cause))])
            if status == "paused" { settle(updated) }
        }
    }

    /// The page's report of a command: what it did, not whether it worked. A failed step is tried again at once. `replayed`: from a
    /// `commands` snapshot, for a click made some time before (when isn't known): it is a click, but not a fresh one.
    func done(_ event: JSON, replayed: Bool = false) throws {
        let error = (event.get("error").map { $0.isTruthy ? $0.pyStr : "" }).flatMap { $0.isEmpty ? nil : $0 } ?? "the page reported a failure"
        let id = event.get("id")
        let ids = id?.asString
        if let ids { closing.pop(ids) }
        // Kept for the document `pages` counts, which a `done` after a `gone` or a host linked again may not come from (`pages` is
        // counted at the next `page`): a new document's `done` then says nothing of the old one's cut-off sends (`unheard_sends`).
        if !(regone || relinked) { lastDone[pages] = max(lastDone[pages] ?? 0, seq(ids) ?? 0) }
        if let s = event.get("settings"), case .object = s, let ids { readHeard(ids) }  // a live read's: its `settings` event came first
        if let ids, let reply = dev[ids] {
            dev.pop(ids)
            reply(event)  // a dev command belongs to no run
            return try advanceAll()  // the sends that waited for it go on
        }
        if let w = watchOpen, let wo = w.open, id == .string(wo) {  // a watched send's going back (`back_to_watched`)
            if event.flag("ok") {  // it holds on until a settled whole read of the place (`handle`), at most do.TIMEOUT more
                w.open = nil; w.movingFrom = arrivals; w.holdUntil = clock() + CourierDo.timeout
                let board = self.board()
                if w.shown && shows(board, w.to) && !unsettled.contains(w.to.thread ?? w.to.project ?? "")
                    && CourierBoard.rowsOf(CourierBoard.placeOf(board, w.to.project, w.to.thread), w.to.thread) != nil {  // shown and read already: no read is due
                    releaseWatch(used: true)
                }
            } else {  // superseded by another open (it may go again), or failed (it goes after the next move)
                releaseWatch(used: event.get("error") != "superseded")
            }
        }
        for run in runs.values {
            if run.flag("tool") {
                if id == run.get("command") { try toolDone(run, event) }
                continue
            }
            if id == run.get("open") && (event.flag("ok") || (run.flag("accepted") && !run.flag("looking"))) {
                run["open"] = .null  // no longer waiting in the page. A taken send's going back is only a help: it goes back after the next move
                if event.flag("ok") {  // an open that worked: a later error is the first in a row again
                    run["open_error"] = false
                    run["look_done"] = .bool(run.flag("looking"))  // a settled read after this answers its look (`read_whole`)
                    run["moving_from"] = .int(arrivals)  // the tab says it arrived after this `done` (`going_back`)
                    if run.flag("moving_to"), arrivals > (run["open_from"]?.asInt ?? arrivals), let to = run.place("moving_to"), shows(self.board(), to) {
                        // The tab arrived at the open's place since it went out (its `page` came before this `done`): the move is over.
                        // An arrival elsewhere proves nothing: a reloaded page's own arrival can come after the open went out, before
                        // that page runs it.
                        run["moving_to"] = .null
                        run.pop("hold_until")
                    } else if run.flag("moving_to") {
                        run.set("hold_until", clock() + CourierDo.timeout)
                    }
                } else {
                    run["moving_to"] = .null
                }
            } else if id == run.get("open") {
                // Another open replaced it (`superseded`), or the page failed it (no tab to be had, say): the run lost the tab, and opens
                // again at its deadline, as background.js says routerd does. A second error in a row fails it with that error.
                if error != "superseded" && run.flag("open_error") {
                    run["open"] = .null
                    try finish(run, "failed", error)
                    continue
                }
                run["open"] = .null; run["open_error"] = .bool(error != "superseded"); run["moving_to"] = .null
                run.pop("hold_until")
                if run.flag("looking") {  // as a lost one (`lost_open`): looked again once, with a fresh wait; else left to its deadline
                    run["look_read"] = false; run["look_done"] = false
                    if !run.flag("relooked") {
                        run["looking"] = .null; run["relooked"] = true
                        deadline(run)
                    } else {
                        run["deadline"] = run["looking"]
                        wake()
                    }
                } else {
                    run["stage"] = "start"; run["lost"] = true
                    deadline(run)
                }
            } else if let ids, run.strings("sends").contains(ids) {
                if run["heard"] == nil { run["heard"] = [] }
                if run.strings("heard").contains(ids) { continue }
                run.insert("heard", ids)  // a replay that says it again is not heard twice
                // The run's answer is its latest send's, unless that was cut off. An older send's, or a cut-off one's, counts only as a click:
                // it was replaced or cancelled, so its error says nothing of the run.
                let current = run.get("command") == .string(ids) && run.get("dropped") != .string(ids)
                if current { run["answered"] = run["command"] }  // no longer waiting in the page
                if event.flag("ok") {
                    if !(run["ms"]?.asObject?.has("clicked") ?? false) { run.put("ms", "clicked", .int(ms(run))) }
                    clicked(run)
                    run["ignored"] = true  // ignored until the draft says otherwise
                    // The latest click: a page that goes within RELOAD_LOSS of it may lose the words. A replayed one's time and page
                    // aren't known: no reload is taken for its loss, nor words back in a draft for its page giving up.
                    if !replayed { run.set("click_at", clock()); run["click_page"] = .int(pages) }
                    // A click the page takes empties the draft within 65 ms (every one measured). One it ignored (a hidden tab's page
                    // still finishing the last send) leaves the words there: it is tried again after TAKE_WAIT, not at the deadline.
                    // Only while the run waits on a send: a cut-off one's late click while it opens again keeps the open's own deadline.
                    if run.str("stage") == "waiting" && !replayed {
                        let d = run.flag("deadline") ? run.num("deadline")! : .infinity
                        run.set("deadline", min(d, clock() + Self.takeWait))
                        wake()
                    }
                } else if current && error == Self.dialogOpen {  // (an older or cut-off send's error says nothing of the run)
                    // A dialog the page holds open (a tool's, or one routerd doesn't know of): the same attempt goes on, and the send is made
                    // again when the tools end, else at its deadline. It never burns an attempt, nor is retried at once against the dialog.
                    try sql.update(clock(), run.id, [("cause", .string(error))])
                    run["ignored"] = true; run["held"] = .bool(toolBusy())
                } else if current {
                    try sql.update(clock(), run.id, [("cause", .string(error))])
                    if error != "superseded" && tabHeld(run) {  // another run has the tab: the retry waits for it, at most the deadline
                        run["retry"] = true  // the pass that frees the tab makes it (`advance`, `advance_all`)
                        deadline(run)
                    } else if error != "superseded" {  // not a failure of this command: the next attempt needn't wait for the deadline
                        run["deadline"] = .null
                        safely(run, late: true)
                    }
                }
            }
        }
        try advanceAll()
    }

    /// The page asks to be woken after `after` ms: a hidden tab's own timers are throttled, a message is not. Each time asked is kept,
    /// so a later request isn't lost behind an earlier one; one wake answers every time that has passed. Anything that isn't a number of
    /// ms is ignored.
    func wakeMe(_ after: JSON?) {
        guard let after, after.asBool == nil, let ms = after.numeric, ms.isFinite else { return }
        let due = ((clock() + min(max(ms, 0), Self.wakeCap) / 1000) * 20).rounded(.up) / 20  // up: a wake never comes before its time
        if !wakes.contains(due) {
            wakes.insert(due)
            wake()
        }
    }

    /// Called when a deadline passes. A run that got no row from you in time takes its next attempt.
    func tick(_ at: Double? = nil) throws {
        let now = at ?? clock()
        jump(now)
        if wakes.contains(where: { $0 <= now }) {
            wakes = wakes.filter { $0 > now }
            if connected() { sendWake() }  // with no host the wake is dropped: the host that links next is sent one at once (`connection`)
        }
        // A finished read still closing its dialog at its deadline is let go and cancelled: the sends it held go on, and meet the page's
        // own dialog guard if the dialog is still open (they end within their attempts); the next tool's open closes a dialog left open.
        for (id, due) in closing.pairs where due <= now {
            closing.pop(id)
            command("cancel", [("target", .string(id))])
        }
        try unwatch()
        if let w = watchOpen, w.holdUntil <= now {  // an open the page dropped, a tab that never arrived or settled
            releaseWatch(used: true)  // used: a place that never settles isn't opened again and again in one move
        }
        for run in runs.values {
            if let f = run.num("fresh_at"), f != 0, f <= now { run["fresh_at"] = .null }  // its `fresh` open is due: the pass below sends it (`advance`)
            if let d = run.num("deadline"), d <= now {
                if run.flag("paused") && tabHeld(run) {  // as in advance_all: it waits its turn, and the pass that frees the tab advances it
                    run["deadline"] = .null  // a past deadline kept would wake the timers again at once
                    continue
                }
                run["deadline"] = .null
                safely(run, late: true)
            }
        }
        try advanceAll()
    }

    func sendWake() {
        out(["kind": "wake"])  // no id and not counted: the page answers nothing, and it is no command waiting in the page
    }

    func nextDeadline() -> Double? {
        // A watch's end is on uptime: it is given on the wall clock as the time left from now (a sleep only makes the tick early).
        let watches = watched.values.map { clock() + max(0.0, $0 - uptime()) }
        var holds = runs.values.filter { ($0.flag("open") || $0.flag("moving_to")) && ($0.num("hold_until") ?? 0) > clock() }.map { $0.num("hold_until")! }
        if let w = watchOpen, w.holdUntil > clock() { holds.append(w.holdUntil) }
        holds += runs.values.filter { $0.flag("looking") && $0.num("looking")! > clock() }.map { $0.num("looking")! }  // a look's end frees the tab
        let all = runs.values.compactMap { $0.num("deadline") } + holds + runs.values.compactMap { $0.flag("fresh_at") ? $0.num("fresh_at") : nil }
            + Array(wakes) + closing.values + watches
        return all.min()
    }

    func settle(_ intent: JSON) {
        for fn in waiters.removeValue(forKey: intent["id"]?.asInt ?? 0) ?? [] { fn(intent) }
    }

    // ---- say

    /// `decide.send_intent`.
    func sendIntent(_ words: String, _ project: String?, _ thread: String?, _ more: [(String, JSON)] = []) throws -> JSON {
        let proof: JSON = ["kind": "latest_you", "project": JSON(project), "thread": JSON(thread), "words": .string(words)]
        let tool = thread != nil && !thread!.isEmpty ? "reply_in_thread" : "send_to_project"
        return try sql.addIntent(clock(), tool, words: words, project: project, thread: thread, proof: proof, status: more.first { $0.0 == "status" }?.1.asString ?? "pending",
                             more: more.filter { $0.0 != "status" }).intent
    }

    /// `decide.explicit`.
    func explicit(_ board: JSON, _ words: String, _ project: String?, _ thread: String?) throws -> JSON {
        if let thread, !thread.isEmpty {
            let t = board["threads"]?.get(thread)
            return try sendIntent(words, t?.str("project"), thread, [("cause", t != nil ? .null : "that thread isn't on the board"), ("status", t != nil ? "pending" : "refused")])
        }
        let p = project.flatMap { CourierBoard.projectNamed(board, $0) }
        return try sendIntent(words, p?.str("id"), nil, [("cause", p != nil ? .null : .string("no project named \(project ?? "None")")), ("status", p != nil ? "pending" : "refused")])
    }

    /// Decide and start doing. `reply` gets the decision as soon as there is one; `finished` the intent once it is done. Only an explicit
    /// target (a project or a thread) is decided here: choosing one is the app's (`RouterJev`), the engine never calls a model.
    func say(_ message: String, project: String? = nil, thread: String? = nil, reply: @escaping (JSON) -> Void = { _ in }, finished: @escaping (JSON) -> Void = { _ in }) throws {
        let t0 = clock()
        let board = self.board()
        if (project != nil && !project!.isEmpty) || (thread != nil && !thread!.isEmpty) {
            return try begin(try explicit(board, message, project, thread), t0, reply, finished, ["by": "explicit"])
        }
        try reply(["event": "error", "error": "no target: the app decides where a message goes"])
    }

    /// Replies with the decision and starts it. `later`: the tool steps after this one, shown in the decision as `steps` so the owner
    /// sees them all at once; each starts when the one before it is confirmed.
    func begin(_ intent: JSON, _ t0: Double, _ reply: @escaping (JSON) -> Void, _ finished: @escaping (JSON) -> Void, _ log: JSON? = nil, later: [JSON] = []) throws {
        var intent = intent
        if let log, !(intent.get("output")?.isTruthy ?? false) { intent = try sql.update(clock(), intent["id"]?.asInt ?? 0, [("output", log)]) }
        let gone = intent.flag("thread") && intent.str("status") == "pending" ? CourierDo.stranded(board(), intent) : nil
        if let gone { intent = try handOff(intent, gone) }
        let warning = CourierDo.warning(board(), intent)
        if let warning {
            var r = intent.obj("result").asObject ?? JSONObject()
            r["warning"] = .string(warning)
            intent = try sql.update(clock(), intent["id"]?.asInt ?? 0, [("result", .object(r))])
        }
        var decision: JSON = ["event": "decision", "intent": intent, "warning": JSON(warning)]
        if !later.isEmpty { decision["steps"] = .array([intent] + later) }
        try reply(decision)
        let queued = later.filter { $0.str("status") == "queued" }.compactMap { $0["id"]?.asInt }
        let id = intent["id"]?.asInt ?? 0
        if !queued.isEmpty { chains[id] = queued }
        if CourierDo.done.contains(intent.str("status") ?? "") || intent.str("status") == "awaiting" { return finished(intent) }  // a permission grant waits for `confirm`
        waiters[id, default: []].append(finished)
        if !runs.has(id) { try start(intent, t0) }
    }

    /// The owner confirms a permission grant. Until then nothing was done.
    @discardableResult
    func confirm(_ intentID: Int, finished: @escaping (JSON) -> Void = { _ in }) throws -> JSON? {
        let intent = try sql.intentOrNil(intentID)
        guard let intent, intent.str("status") == "awaiting" else {  // whoever asked still gets an outcome: the run's, or the intent as it is
            if let intent, runs.has(intent["id"]?.asInt ?? -1) {
                waiters[intentID, default: []].append(finished)
            } else {
                try finished(intent ?? ["id": .int(intentID), "error": .string("no intent \(intentID)")])
            }
            return intent
        }
        var r = intent.obj("result").asObject ?? JSONObject()
        r["confirmed"] = .double(clock())
        let updated = try sql.update(clock(), intentID, [("status", "pending"), ("result", .object(r))])
        waiters[intentID, default: []].append(finished)
        try start(updated, clock())
        return try sql.intentOrNil(intentID)
    }

    /// The owner says a message belonged to another project. Kept on the intent.
    @discardableResult
    func correct(_ intentID: Int, _ project: String) throws -> JSON {
        try sql.update(clock(), intentID, [("correction", ["project": .string(project), "at": .double(clock())])])
    }

    @discardableResult
    func note(_ topic: String, _ text: String) throws -> JSON {
        try sql.setNote(clock(), topic, text)
        return try sql.addIntent(clock(), "update_notes", words: text, args: ["topic": .string(topic), "text": .string(text)], status: "confirmed", dup: false).intent
    }

    // ---- tell

    /// The brief: facts since the last tell that you weren't told. Records what was told.
    func tell() throws -> [String] {
        let now = clock()
        let known = try sql.told(), board = self.board()
        var found = facts.values
        found += CourierTell.standing(board).filter { known.has($0["key"]?.asString ?? "") && !facts.has($0["key"]?.asString ?? "") }
        // Whether a thread's state is live is as of now, not as of when the fact was found: the tab may have moved since.
        found = found.map { f in
            if let t = f.get("thread")?.asString, let thread = board["threads"]?[t] {
                var g = f
                g["as_of"] = thread["as_of"] ?? .null
                return g
            }
            return f
        }
        found = found.filter { CourierTell.holds($0, board) }  // a thread stranded and back, or an app closed and open again, before the tell
        let (say, quiet) = CourierTell.plan(found, known, acc.claims, now)
        for f in say + quiet {
            try sql.setTold(now, f["key"]?.asString ?? "", f.get("project")?.asString, f.get("kind")?.asString, f.get("detail")?.asString, f.get("text")?.asString)
        }
        try sql.setMark(try sql.lastSeenId())
        facts = OrderedMap()
        acc.claims = []
        _board = nil
        return say.map { $0["text"]?.asString ?? "" }
    }

    /// `decide.after`: why a later step is refused, the step before it that didn't go through.
    func after(_ intent: JSON) -> String {
        let n = intent.obj("result").get("step") ?? .int(1)
        return "step \(n.pyStr) (\(intent.str("tool") ?? "")) \(intent.str("status") ?? ""): \(intent.get("cause")?.pyStr ?? "None")"
    }
}
