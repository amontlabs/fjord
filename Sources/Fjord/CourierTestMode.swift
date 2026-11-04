import Foundation

// `Fjord --courier-test --db <path>`: the conformance bridge of docs/design/router-swift-port.md ("The conformance bridge", "Protocol").
// It reads JSON lines on stdin and writes JSON lines on stdout, opens no window, and answers what poc/router/tests/fake_bridge.py (its
// Python stand-in) answers. Every request carries the injected time (`t`, `up`); the commands the core sends and the callbacks it fires
// are written as they happen, so they come before the reply. Test-only: nothing in the app calls it.

struct BridgeError: Error, CustomStringConvertible {
    let type: String
    let message: String
    init(_ type: String, _ message: String) { self.type = type; self.message = message }
    var description: String { "\(type): \(message)" }
}

final class CourierTestMode {
    /// The injected clocks: both come from the request.
    final class Time { var t = 0.0; var up = 0.0 }

    let dbPath: String
    let time = Time()
    var core: CourierCore?
    var held: [Int: Run] = [:]  // the runs as the last `state` had them: one that has since ended is reported with its final fields

    init(dbPath: String) { self.dbPath = dbPath }

    static let calls: Set<String> = ["advance_all", "safely", "acting", "yielded", "in_page", "tab_held", "tab_idle", "cancel_send", "finish", "command",
                                     "next_id", "remember", "recheck_pauses", "ready", "stale", "goto", "advance", "start", "tool_busy", "unheard_sends",
                                     "done", "wake_me"]
    static let pure: [String: ([JSON]) throws -> JSON] = {
        var all: [String: ([JSON]) throws -> JSON] = [:]
        for ops in [CourierBoard.testOps, CourierDo.testOps, CourierPage.testOps, CourierTell.testOps] {
            for (name, fn) in ops { all[name] = fn }
        }
        return all
    }()

    static func main() -> Never {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--db"), i + 1 < args.count else {
            FileHandle.standardError.write(Data("usage: Fjord --courier-test --db <path>\n".utf8))
            exit(2)
        }
        let bridge = CourierTestMode(dbPath: args[i + 1])
        while let text = readLine(strippingNewline: true) {
            if text.isEmpty { continue }
            guard let m = try? JSON.parse(text), m.asObject != nil else { continue }
            let id = m["id"] ?? .null
            do {
                let result = try bridge.request(m)
                write(["id": id, "result": result])
            } catch {  // the process goes on after an error
                write(["id": id, "error": .string(bridge.describe(error))])
            }
        }
        exit(0)
    }

    static func write(_ line: JSON) {
        let data = Data((line.encoded() + "\n").utf8)
        data.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, data.count, stdout) }
        fflush(stdout)
    }

    func describe(_ error: Error) -> String {
        if let e = error as? BridgeError { return e.description }
        return "\(type(of: error)): \(error)"
    }

    func line(_ pairs: [(String, JSON)]) { Self.write(.object(JSONObject(pairs))) }

    func callback(_ kind: String, _ cb: JSON) -> (JSON) -> Void {
        { [self] value in line([(kind, cb), (kind == "reply" ? "event" : "intent", value)]) }
    }

    func core(_ op: String) throws -> CourierCore {
        guard let core else { throw BridgeError("RuntimeError", "\(op) before start") }
        return core
    }

    // ---- requests

    func request(_ m: JSON) throws -> JSON {
        let op = m["op"]?.asString ?? ""
        time.t = m["t"]?.asDouble ?? 0
        time.up = m["up"]?.asDouble ?? 0
        if m["db"]?.isTruthy ?? false, let core { core.chatted = try core.db.chatProjects() }  // Python wrote to the file: what is cached from it is read again
        switch op {
        case "start":
            for (name, value) in m["constants"]?.asObject ?? JSONObject() { try setConstant(name, value) }
            let time = self.time
            let clock = CourierClock(now: { time.t }, uptime: { time.up })
            core = try CourierCore(db: try CourierStore(path: dbPath), out: { [self] command in line([("out", command)]) }, clock: clock)
            held = [:]
            return .null
        case "set_constant":
            try setConstant(m["name"]?.asString ?? "", m["value"] ?? .null)
            return .null
        case "pure":
            return try pureCall(m["fn"]?.asString ?? "", m["args"]?.asArray ?? [], m["kwargs"]?.asObject ?? JSONObject())
        case "handle":
            try core(op).handle(m["event"] ?? .null)
            return .null
        case "connection":
            try core(op).connection(m["host"]?.isTruthy ?? false, current: m.get("current")?.isTruthy ?? true)
            return .null
        case "local":
            let local = m["local"] ?? .null
            try core(op).local(local.isNull ? nil : local)
            return .null
        case "say":
            let c = try core(op)
            let project = m.str("project").flatMap { $0.isEmpty ? nil : $0 }, thread = m.str("thread").flatMap { $0.isEmpty ? nil : $0 }
            if project == nil && thread == nil { throw BridgeError("ValueError", "no model here: say needs a project or a thread") }
            let cb = m["cb"] ?? .null
            try c.say(m.str("message") ?? "", project: m.str("project"), thread: m.str("thread"), reply: callback("reply", cb), finished: callback("finished", cb))
            return .null
        case "tool":
            let cb = m["cb"] ?? .null
            let args = (m["args"]?.asObject ?? JSONObject()).pairs.map { ($0.key, $0.value) }
            try core(op).tool(m.str("name") ?? "", args: args, reply: callback("reply", cb), finished: callback("finished", cb))
            return .null
        case "confirm":
            return try core(op).confirm(m["intent"]?.asInt ?? 0, finished: callback("finished", m["cb"] ?? .null)) ?? .null
        case "correct":
            return try core(op).correct(m["intent"]?.asInt ?? 0, m.str("project") ?? "")
        case "note":
            return try core(op).note(m.str("topic") ?? "", m.str("text") ?? "")
        case "tell":
            return .strings(try core(op).tell())
        case "tick":
            try core(op).tick(m.get("now")?.asDouble)
            return .null
        case "next_deadline":
            return JSON(try core(op).nextDeadline())
        case "dev_command":
            let fields = (m["fields"]?.asObject ?? JSONObject()).pairs.map { ($0.key, $0.value) }
            return JSON(try core(op).devCommand(m.str("kind") ?? "", callback("reply", m["cb"] ?? .null), fields))
        case "dev_cancel":
            return .bool(try core(op).devCancel(m.str("target") ?? ""))
        case "set_run":
            let id = m["run"]?.asInt ?? 0
            guard let run = try core(op).runs[id] else { throw BridgeError("KeyError", "\(id)") }
            run[m.str("field") ?? ""] = m["value"] ?? .null
            return .null
        case "call":
            return try call(m)
        case "state":
            return try state()
        default:
            throw BridgeError("ValueError", "unknown op \(op)")
        }
    }

    func setConstant(_ name: String, _ value: JSON) throws {
        switch name {
        case "KEPT": CourierDo.kept = value.asInt ?? Int(value.asDouble ?? 5)
        case "DEV_WAIT": CourierCore.devWait = value.asDouble ?? 60
        default: throw BridgeError("KeyError", name)
        }
    }

    // ---- pure

    func pureCall(_ fn: String, _ argsIn: [JSON], _ kwargs: JSONObject) throws -> JSON {
        guard let op = Self.pure[fn] else { throw BridgeError("KeyError", fn) }
        var args = argsIn
        if let claimed = kwargs.get("claimed"), args.count == 2 { args.append(claimed) }  // `claimed` is positional (third) for the Swift ops
        if fn == "tell.plan", let window = kwargs.get("window"), args.count == 4 { args.append(window) }
        if fn == "do.baselined", args.count > 2, let known = args[2].asObject { args[2] = .strings(known.keys) }  // the stored keys are a dict on the wire
        if fn == "board.merge_rows", let full = kwargs.get("full"), args.count == 2 { args.append(full) }
        return try op(args)
    }

    // ---- call

    /// A `{"$run": id}` is that live run; one that ended carries its fields.
    func runOf(_ value: JSON?) throws -> Run? {
        guard let value, let o = value.asObject, let id = o["$run"] else { return nil }
        if let run = try core("call").runs[id.asInt ?? -1] { return run }
        if let fields = o["fields"]?.asObject { return Run(fields) }
        throw BridgeError("KeyError", "run \(id.pyStr)")
    }

    func call(_ m: JSON) throws -> JSON {
        let name = m.str("name") ?? ""
        guard Self.calls.contains(name) else { throw BridgeError("ValueError", "call \(name) is not whitelisted") }
        let c = try core("call")
        let args = m["args"]?.asArray ?? []
        let kwargs = m["kwargs"]?.asObject ?? JSONObject()
        /// The argument `i`, or the keyword `key` when it isn't positional.
        func arg(_ i: Int, _ key: String) -> JSON? { i < args.count ? args[i] : kwargs[key] }
        func run(_ i: Int, _ key: String = "run") throws -> Run {
            guard let r = try runOf(arg(i, key)) else { throw BridgeError("TypeError", "\(name) needs a run") }
            return r
        }
        func flag(_ i: Int, _ key: String) -> Bool { arg(i, key)?.isTruthy ?? false }
        let place = { () throws -> Place in
            guard let p = Place(arg(1, "place")) else { throw BridgeError("TypeError", "\(name) needs a place") }
            return p
        }
        switch name {
        case "advance_all": try c.advanceAll(); return .null
        case "safely": c.safely(try run(0), late: flag(1, "late")); return .null
        case "acting": return .bool(c.acting(try run(0)))
        case "yielded": return .bool(c.yielded(try run(0)))
        case "in_page": return .bool(c.inPage(try run(0)))
        case "tab_held": return .bool(c.tabHeld(try run(0)))
        case "tab_idle": return .bool(c.tabIdle(try run(0)))
        case "cancel_send": c.cancelSend(try run(0)); return .null
        case "finish":
            let known: Set<String> = ["run", "status", "cause", "row"]
            let changes = kwargs.pairs.filter { !known.contains($0.key) }.map { ($0.key, $0.value) }
            try c.finish(try run(0), arg(1, "status")?.asString ?? "", arg(2, "cause")?.asString, row: arg(3, "row")?.asString, changes: changes)
            return .null
        case "command":
            let fields = kwargs.pairs.filter { $0.key != "kind" }.map { ($0.key, $0.value) }
            return .string(c.command(arg(0, "kind")?.asString ?? "", fields))
        case "next_id": return .string(c.nextID())
        case "remember": c.remember(arg(0, "subject")?.asString ?? "", arg(1, "messages")?.asArray ?? []); return .null
        case "recheck_pauses": try c.recheckPauses(); return .null
        case "ready": return .bool(c.ready(c.board(), try place()))
        case "stale":
            switch c.stale(c.board(), try place()) {
            case .yes: return .bool(true)
            case .due(let at): return .double(at)
            case nil: return .null
            }
        case "goto": c.goto(try run(0), arg(1, "stage")?.asString ?? ""); return .null
        case "advance": try c.advance(try run(0), late: flag(1, "late")); return .null
        case "start": try c.start(arg(0, "intent") ?? .null, arg(1, "t0")?.asDouble ?? 0); return .null
        case "tool_busy":
            let r = arg(0, "run").flatMap { $0.isNull ? nil : $0 }
            return .bool(c.toolBusy(r == nil ? nil : try runOf(r)))
        case "unheard_sends": return .strings(c.unheardSends(try run(0)))
        case "done": try c.done(arg(0, "event") ?? .null, replayed: flag(1, "replayed")); return .null
        case "wake_me": c.wakeMe(arg(0, "after")); return .null
        default: throw BridgeError("ValueError", "call \(name) is not whitelisted")
        }
    }

    // ---- state

    /// A run's fields as Python's `plain` has them: the `heard` set sorted by its JSON text.
    func fields(_ run: Run) -> JSON {
        var o = run.fields
        if let heard = o["heard"]?.asArray { o["heard"] = .array(heard.sorted { $0.encoded() < $1.encoded() }) }
        return .object(o)
    }

    func sortedByText(_ values: [JSON]) -> JSON { .array(values.sorted { $0.encoded() < $1.encoded() }) }

    func state() throws -> JSON {
        let c = try core("state")
        var ended: [(String, JSON)] = []
        for (id, run) in held.sorted(by: { $0.key < $1.key }) where !c.runs.has(id) { ended.append((String(id), fields(run))) }
        held = Dictionary(uniqueKeysWithValues: c.runs.pairs.map { ($0.key, $0.value) })
        let watchOpen: JSON = c.watchOpen.map { w in
            .obj([("open", JSON(w.open)), ("to", w.to.json), ("id", .int(w.id)), ("hold_until", .double(w.holdUntil)), ("moving_from", JSON(w.movingFrom)),
                  ("open_from", .int(w.openFrom)), ("shown", .bool(w.shown))])
        } ?? .null
        let claimed: [JSON] = c.claimed.sorted { ($0.key.project ?? "", $0.key.thread ?? "") < ($1.key.project ?? "", $1.key.thread ?? "") }
            .map { [JSON($0.key.project), JSON($0.key.thread), .strings(pySorted(Array($0.value)))] }
        return .obj([
            ("runs", .obj(c.runs.pairs.map { (String($0.key), fields($0.value)) })),
            ("ended", .obj(ended)),
            ("watched", .obj(c.watched.pairs.map { (String($0.key), .double($0.value)) })),
            ("watch_open", watchOpen),
            ("watch_back", .obj(c.watchBack.sorted { $0.key < $1.key }.map { (String($0.key), .int($0.value)) })),
            ("moves", .int(c.moves)),
            ("unproved", sortedByText(c.unproved.map(JSON.int))),
            ("stale_goal", .obj(c.staleGoal.pairs.map { ($0.key, $0.value) })),
            ("unsettled", sortedByText(c.unsettled.map(JSON.string))),
            ("arrived", [JSON(c.arrived.project), .double(c.arrived.at)]),
            ("pages", .int(c.pages)),
            ("linked", .int(c.linked)),
            ("commands", .int(c.commands)),
            ("known", .obj(c.known.sorted { $0.key < $1.key }.map { ($0.key, .strings($0.value.keys)) })),
            ("dev", .strings(c.dev.keys)),
            ("closing", .obj(c.closing.pairs.map { ($0.key, .double($0.value)) })),
            ("relinked", .bool(c.relinked)),
            ("claimed", .array(claimed)),
            ("board", c.board()),
        ])
    }
}
