import Darwin
import Dispatch
import Foundation

// The Router's server glue: a port of poc/router/routerd.py's `serve`, `link`, the timer thread and the `{"op": …}` debug ops (docs/design/
// router-swift-port.md, "Threading and clocks" and "Socket and persistence"). `CourierHost` owns the one `CourierCore` and serializes every
// input through it: socket lines, the timer and the app's calls. The socket reads run on dispatch sources and only queue what they read;
// the actor handles it in order. Nothing in the app starts it yet.

/// What the app asks the engine to do (the doc's `CourierIntent`; named so because `CourierIntent` is already the row of the `intents` table).
enum CourierRequest {
    /// `key`: the app's idempotency key: a repeat of it while its intent hasn't failed is that intent, not a second send.
    case send(words: String, project: String, thread: String?, continues: String? = nil, key: String? = nil)
    case tool(name: CourierTool, args: [String: JSON])
    case confirm(intentID: Int)
    case correct(intentID: Int, project: String)
}

enum CourierTool: String {
    case createProject = "create_project", setGoal = "set_goal", setInstructions = "set_instructions", addRepo = "add_repo"
    case preapproveFolder = "preapprove_folder"
}

enum CourierState: Equatable {
    case sending, taken, delivered, deliveredLate, failed, refused, paused, awaiting, toolDone, toolUnconfirmed
}

/// An intent as the engine's database has it now (`CourierHost.status`).
struct CourierIntentStatus: Equatable, Sendable {
    var state: CourierState
    var cause: String?
    /// A confirmed create's project id (`chan_`).
    var project: String?
}

/// A delivery looked up by its words (`CourierHost.intent(matching:)`): found, surely none, or the engine can't say now.
enum CourierLookup: Equatable, Sendable { case found(Int), none, unknown }

/// Why a paused intent waits, as a code: the same conditions `CourierDo.blocked` words in its cause (`CourierDo.pause`), and the
/// Claude app's wait (`CourierDo.appWait`).
enum CourierPause: String, CaseIterable, Sendable {
    case chromeClosed, chromeNotConnected, signedOut, away, tabUnreadable, appClosed
}

/// One per status or cause change of an intent, read from the rows of the `intents` table. `pause`: why a paused one waits, when
/// the app can do something about it (nil for a restart's pause, and for every other state).
struct CourierUpdate {
    let intentID: Int
    let state: CourierState
    let cause: String?
    let before: JSON?
    let at: Date
    var pause: CourierPause? = nil
}

/// A claude.ai project on the Board, as the app routes to it: its threads, latest touched first.
struct CourierPlace: Equatable, Sendable {
    struct Thread: Equatable, Sendable {
        var id: String
        var title: String
        var state: String
        var touched: Double
    }
    var id: String
    var name: String
    var purpose: String
    var threads: [Thread]
}

/// What the app keeps of the engine between its updates: the page's health (the setup's) and the claude.ai places (the
/// dispatcher's candidates). Sent when it changes.
struct CourierSnapshot: Equatable, Sendable {
    var health = CourierSetupHealth()
    var places: [CourierPlace] = []

    /// From a Board: the tab is linked when the page's health says connected; signed in only as the page said. A project
    /// of a local folder only (`local:`) has no claude.ai project to send to, and isn't one.
    static func of(_ board: JSON) -> CourierSnapshot {
        let health = board["health"] ?? .null
        let connected = health.get("connected") == .bool(true)
        var out = CourierSnapshot(health: CourierSetupHealth(tabConnected: connected, signedIn: connected ? health.get("signed_in")?.asBool : nil))
        let threads = board["threads"]?.asObject?.values ?? []
        for p in board["projects"]?.asObject?.values ?? [] {
            guard let id = p["id"]?.asString, !id.hasPrefix("local:"), let name = p["name"]?.asString, !name.isEmpty else { continue }
            let mine = threads.filter { $0["project"]?.asString == id }.compactMap { t -> CourierPlace.Thread? in
                guard let tid = t["id"]?.asString else { return nil }
                return .init(id: tid, title: t.get("title")?.asString ?? "", state: t.get("state")?.asString ?? "", touched: t.get("touched")?.asDouble ?? 0)
            }.sorted { ($0.touched, $0.id) > ($1.touched, $1.id) }
            out.places.append(CourierPlace(id: id, name: name, purpose: p.get("purpose")?.asString ?? "", threads: mine))
        }
        out.places.sort { ($0.name, $0.id) < ($1.name, $1.id) }
        return out
    }
}

actor CourierHost {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        static let alreadyRunning = Failure(message: "routerd is already running")
    }

    /// Seconds a `dev_command` op waits for the page's `done` (`DEV_WAIT`).
    nonisolated static let devWait = 60.0

    /// A socket client: a native host linked by its first event, or a debug client (`router.py`).
    final class Connection: @unchecked Sendable {
        let fd: Int32
        private let lock = NSLock()
        private var open = true
        var source: DispatchSourceRead?
        var buffer = Data()  // the actor's: the unfinished line
        var isHost = false

        init(fd: Int32) {
            self.fd = fd
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        /// One line, written whole. A peer that went is ignored (`except OSError: pass`).
        func write(_ json: JSON) {
            let data = Data((json.encoded() + "\n").utf8)
            lock.lock(); defer { lock.unlock() }
            guard open else { return }
            _ = NativeHost.writeAll(fd, data)
        }

        func close() {
            lock.lock(); defer { lock.unlock() }
            guard open else { return }
            open = false
            source?.cancel()
            source = nil
            Darwin.close(fd)
        }
    }

    private enum Input {
        case accepted(Connection)
        case data(Connection, Data)
        case ended(Connection)
    }

    let socketPath: String
    let dbPath: String
    private let clock: CourierClock
    private let sleeper: @Sendable (Double) async throws -> Void
    private let devWait: Double
    private let log: @Sendable (String) -> Void

    nonisolated let updates: AsyncStream<CourierUpdate>
    private let updateSink: AsyncStream<CourierUpdate>.Continuation
    /// The Board's health and places, each time they change (the first once started).
    nonisolated let snapshots: AsyncStream<CourierSnapshot>
    private let snapshotSink: AsyncStream<CourierSnapshot>.Continuation
    private var lastSnapshot: CourierSnapshot?
    private var core: CourierCore?
    private var hosts: [Connection] = []
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var inputs: AsyncStream<Input>.Continuation?
    private var pump: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var generation = 0
    private var lastFired: Double?
    private var known: [Int: (state: CourierState, cause: String?, pause: CourierPause?)] = [:]
    private let queue = DispatchQueue(label: "fjord.courier.socket")

    /// `dbPath`: `router.db` next to the socket unless given. `sleeper`: how the timer waits (a test releases it by hand).
    init(socketPath: String = NativeHost.socketPath(), dbPath: String? = nil, clock: CourierClock = .system,
         sleeper: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) },
         devWait: Double = CourierHost.devWait, log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        self.socketPath = socketPath
        self.dbPath = dbPath ?? URL(fileURLWithPath: socketPath).deletingLastPathComponent().appendingPathComponent("router.db").path
        self.clock = clock
        self.sleeper = sleeper
        self.devWait = devWait
        self.log = log
        var sink: AsyncStream<CourierUpdate>.Continuation!
        updates = AsyncStream(bufferingPolicy: .unbounded) { sink = $0 }
        updateSink = sink
        var shots: AsyncStream<CourierSnapshot>.Continuation!
        snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { shots = $0 }
        snapshotSink = shots
    }

    // MARK: Start and stop

    /// Opens the database (a restart rebuilds the runs in `CourierCore.init`), refuses a second listener, and listens.
    func start() throws {
        guard core == nil else { return }
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try probe()
        let created = try CourierCore(db: try CourierStore(path: dbPath), out: { [unowned self] in self.send($0) }, clock: clock)
        try listen()
        core = created
        known = [:]
        snapshot()
        lastSnapshot = nil
        share()
        var sink: AsyncStream<Input>.Continuation!
        let stream = AsyncStream<Input>(bufferingPolicy: .unbounded) { sink = $0 }
        inputs = sink
        pump = Task { [weak self] in
            for await input in stream {
                guard let self else { return }
                await self.handle(input)
            }
        }
        accepting(listener, sink)
        arm()
    }

    /// `serve`: a socket that answers a connect belongs to a running routerd; one that doesn't is a leftover and goes.
    private func probe() throws {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(fd) }
        var address = try Self.address(socketPath)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } == 0
        }
        if connected { throw Failure.alreadyRunning }
        unlink(socketPath)
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure(message: "socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return address
    }

    private func listen() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket: \(String(cString: strerror(errno)))") }
        var address = try Self.address(socketPath)
        let old = umask(0o177)  // owner only
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } == 0
        }
        umask(old)
        guard bound, Darwin.listen(fd, 16) == 0 else {
            let why = String(cString: strerror(errno))
            Darwin.close(fd)
            throw Failure(message: "can't listen on \(socketPath): \(why)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
    }

    private nonisolated func accepting(_ fd: Int32, _ sink: AsyncStream<Input>.Continuation) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [queue] in
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { return }
                let connection = Connection(fd: client)
                let reader = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
                reader.setEventHandler {
                    var chunk = [UInt8](repeating: 0, count: 65536)
                    let got = read(client, &chunk, chunk.count)
                    if got > 0 {
                        sink.yield(.data(connection, Data(chunk[0..<got])))
                    } else if got == 0 || (errno != EINTR && errno != EAGAIN) {
                        reader.cancel()
                        sink.yield(.ended(connection))
                    }
                }
                connection.source = reader
                sink.yield(.accepted(connection))
                reader.resume()
            }
        }
        source.resume()
        Task { await self.keep(source) }
    }

    private func keep(_ source: DispatchSourceRead) { acceptSource = source }

    /// Stops listening and closes every connection; the socket file goes (`finally: os.unlink(sock)`).
    func stop() {
        timer?.cancel(); timer = nil
        generation += 1
        acceptSource?.cancel(); acceptSource = nil
        if listener >= 0 { Darwin.close(listener); listener = -1; unlink(socketPath) }
        for c in connections.values { c.close() }
        connections = [:]
        hosts = []
        inputs?.finish(); inputs = nil
        pump?.cancel(); pump = nil
        core = nil
        updateSink.finish()
        snapshotSink.finish()
    }

    // MARK: Socket input

    private func handle(_ input: Input) {
        switch input {
        case .accepted(let connection):
            connections[ObjectIdentifier(connection)] = connection
        case .data(let connection, let data):
            guard connections[ObjectIdentifier(connection)] != nil else { return }
            connection.buffer.append(data)
            while let end = connection.buffer.firstIndex(of: 0x0A) {
                let line = connection.buffer[connection.buffer.startIndex..<end]
                connection.buffer.removeSubrange(connection.buffer.startIndex...end)
                lineFrom(connection, Data(line))
            }
        case .ended(let connection):
            guard connections.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
            if connection.isHost {
                let current = hosts.last === connection  // commands go to the latest host (`send`)
                hosts.removeAll { $0 === connection }
                safely("connection") { try core?.connection(false, current: current) }
            }
            connection.close()
            finishInput()
        }
    }

    /// One line from a connection (`Handler.handle`): an event, or an op.
    private func lineFrom(_ connection: Connection, _ line: Data) {
        guard let text = String(data: line, encoding: .utf8), let message = try? JSON.parse(text), message.asObject != nil else { return }
        if message.has("type") {
            if !connection.isHost {  // `link`: its stream joins the hosts, and the commands sent so far are the ones its `commands` answers for
                connection.isHost = true
                hosts.append(connection)
                safely("connection") { try core?.connection(true) }
            }
            safely("event") { try core?.handle(message) }
            finishInput()
        } else if message.has("op") {
            op(connection, message)
            finishInput()
        }
    }

    /// After every input: the updates it caused, and the timer re-armed to the next deadline.
    private func finishInput() {
        publish()
        share()
        arm()
    }

    /// The Board's health and places, sent when they changed.
    private func share() {
        guard let core else { return }
        let now = CourierSnapshot.of(core.board())
        guard now != lastSnapshot else { return }
        lastSnapshot = now
        snapshotSink.yield(now)
    }

    /// `send`: a command goes to the latest host. With none linked it is loud, so a command that goes nowhere isn't taken for one the page ignored.
    private func send(_ command: JSON) {
        guard let host = hosts.last else {
            log("\(clock.now()) no host linked: dropped \(command.get("kind")?.pyStr ?? "None") \(command.get("id")?.pyStr ?? "None")")
            return
        }
        host.write(command)
    }

    /// `carry_on`: an error outside a run is logged and the server goes on.
    private func safely(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch { log("routerd \(what): \(error)") }
    }

    // MARK: Debug ops

    private func op(_ connection: Connection, _ m: JSON) {
        guard let core else { return }
        let kind = m["op"]?.asString ?? ""
        let reply: (JSON) -> Void = { connection.write($0) }
        let outcome: (JSON) -> Void = { connection.write(["event": "outcome", "intent": $0]) }
        do {
            switch kind {
            case "say":
                try core.say(m.get("message")?.asString ?? "", project: m.get("project")?.asString, thread: m.get("thread")?.asString, reply: reply, finished: outcome)
            case "tool":
                try core.tool(m.get("tool")?.asString ?? "", args: (m.get("args")?.asObject?.pairs ?? []).map { ($0.key, $0.value) }, reply: reply, finished: outcome)
            case "confirm":
                guard let id = m["id"]?.asInt else { return reply(["error": "confirm needs an id"]) }
                try core.confirm(id, finished: outcome)
            case "board":
                reply(["board": core.board(), "now": .double(clock.now())])
            case "tell":
                reply(["tell": .strings(try core.tell())])
            case "notes":
                if let topic = m.get("topic")?.asString, !topic.isEmpty {
                    reply(["intent": try core.note(topic, m.get("text")?.asString ?? "")])
                } else {
                    reply(["notes": .object(try core.sql.notes())])
                }
            case "log":
                reply(["intents": .array(try core.db.intents(limit: 100, columns: CourierStore.brief))])  // no proofs: a send's holds its baseline's keys
            case "correct":
                guard let id = m["id"]?.asInt, let project = m["project"]?.asString else { return reply(["error": "correct needs an id and a project"]) }
                reply(["intent": try core.correct(id, project)])
            case "dev_command":
                guard let step = m.get("kind")?.asString, !step.isEmpty else { return reply(["error": .string("unknown op \(kind)")]) }
                devCommand(connection, step, m)
            case "reload_extension", "reload_tab":  // the extension reloads itself (edited scripts), or the tab loads afresh at the projects page
                if core.connected() {
                    core.command(kind)
                    reply(["ok": true])
                } else {
                    reply(["ok": false, "error": "no host linked"])
                }
            default:
                reply(["error": .string("unknown op \(kind)")])
            }
        } catch {
            log("routerd op \(kind): \(error)")
            reply(["error": .string("\(error)")])
        }
    }

    /// A dev step: one page command, answered with its `done` (at once with no host), or with an error when the page doesn't answer in `devWait`.
    private func devCommand(_ connection: Connection, _ step: String, _ m: JSON) {
        guard let core else { return }
        let answered = Flag()
        let fields = (m.asObject?.pairs ?? []).filter { !["op", "kind", "id"].contains($0.key) }.map { ($0.key, $0.value) }  // the id is routerd's
        let id = core.devCommand(step, { done in
            guard !answered.set else { return }
            answered.set = true
            connection.write(done)
        }, fields)
        guard let id else { return }
        let wait = devWait
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))  // real time: the page's answer is not a clock matter
            await self?.devTimedOut(id, connection, answered)
        }
    }

    private final class Flag: @unchecked Sendable { var set = false }

    private func devTimedOut(_ id: String, _ connection: Connection, _ answered: Flag) {
        guard !answered.set, let core else { return }
        answered.set = true
        var cancelled = false
        safely("dev_cancel") { cancelled = try core.devCancel(id) }  // false: its done came just as the wait ended
        if cancelled { connection.write(["type": "done", "id": .string(id), "ok": false, "error": .string("the page didn't answer in \(Int(devWait)) s")]) }
        finishInput()
    }

    // MARK: Timer

    /// One timer, re-armed after every input: sleeps until `next_deadline()` and then ticks. Nothing here polls.
    private func arm() {
        timer?.cancel(); timer = nil
        guard let core, let due = core.nextDeadline() else { return }
        generation += 1
        let mine = generation
        var delay = max(0.0, due - clock.now())
        if delay == 0, lastFired == due { delay = 0.05 }  // a deadline a tick left behind isn't spun on
        let sleeper = self.sleeper
        timer = Task { [weak self] in
            do { try await sleeper(delay) } catch { return }
            if Task.isCancelled { return }
            await self?.fire(mine, due)
        }
    }

    private func fire(_ mine: Int, _ due: Double) {
        guard mine == generation, let core else { return }
        timer = nil
        lastFired = due
        safely("tick") { try core.tick() }
        finishInput()
    }

    // MARK: The app's API

    /// Hands a request to the engine. Returns the intent's id (after the 120 s duplicate check), or 0 when the engine failed or the host isn't started
    /// (logged, never thrown into the app).
    @discardableResult
    func submit(_ request: CourierRequest) -> Int {
        guard let core else { log("routerd submit: the host isn't started"); return 0 }
        var id = 0
        var failure: String?
        let noted: (JSON) -> Void = { decision in
            if let i = decision["intent"]?["id"]?.asInt { id = i }
            if decision["event"] == "error" { failure = decision["error"]?.asString }
        }
        safely("submit") {
            switch request {
            case .send(let words, let project, let thread, _, let key):
                // The same key again (an app that quit before it heard the id, and sends again): the intent it named, while
                // that one hasn't failed; a failed one is sent anew under the key.
                if let key, let earlier = try core.db.keyedIntent(key), let row = try core.db.intent(earlier),
                   !["failed", "refused"].contains(row["status"]?.asString ?? "") {
                    id = earlier
                    return
                }
                try core.say(words, project: project, thread: thread, reply: noted)
                if let key, id > 0 { try core.db.keyIntent(key, id) }
            case .tool(let name, let args):
                try core.tool(name.rawValue, args: args.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }, reply: noted)
            case .confirm(let intentID):
                id = intentID
                try core.confirm(intentID)
            case .correct(let intentID, let project):
                id = intentID
                try core.correct(intentID, project)
            }
        }
        if let failure { log("routerd submit: \(failure)") }
        finishInput()
        return id
    }

    /// Where intent `id` is now, read from the engine's own database (it survives a relaunch); nil when the host isn't
    /// started or has no such intent. For a confirmed create_project, `project` is the claude.ai id its proof found (the
    /// project that wasn't on the Board before that create).
    func status(of id: Int) -> CourierIntentStatus? {
        guard let core, let intent = (try? core.db.intent(id)) ?? nil else { return nil }
        let state = Self.state(intent, taken: core.runs[id]?.flag("taken") ?? false)
        let made = intent.str("tool") == "create_project" && state == .toolDone ? intent.str("project").flatMap { $0.isEmpty ? nil : $0 } : nil
        return CourierIntentStatus(state: state, cause: intent.get("cause")?.asString, project: made)
    }

    /// The newest delivery of exactly `words` to `project` (its id; nil: any) made at `since` or later: a send whose intent id never
    /// reached the app (it quit while submitting). `.unknown` when the host isn't started.
    func intent(matching words: String, project: String?, since: Date) -> CourierLookup {
        guard let core else { return .unknown }
        // No project given (it went by its name): any project; the words and the time tell it.
        let rows = (try? core.db.query("select id from intents where tool in ('send_to_project', 'reply_in_thread') and words = ? "
                                       + (project == nil ? "" : "and project = ? ") + "and at >= ? order by id desc limit 1",
                                       [.string(words)] + (project.map { [JSON.string($0)] } ?? []) + [.double(since.timeIntervalSince1970)])) ?? []
        return rows.first?["id"]?.asInt.map(CourierLookup.found) ?? .none
    }

    /// How many native hosts are linked.
    var linkedHosts: Int { hosts.count }

    /// A snapshot of the Board for `RouterContext` and the brief.
    func board() -> JSON { core?.board() ?? .null }

    /// The facts not yet told.
    func tell() -> [String] {
        guard let core else { return [] }
        var told: [String] = []
        safely("tell") { told = try core.tell() }
        finishInput()
        return told
    }

    /// The app's reading of the local sessions, then the pauses that depended on them are checked again (`watch`).
    func local(_ json: JSON?) {
        guard let core else { return }
        safely("local") { try core.local(json) }
        recheck()
    }

    func recheck() {
        guard let core else { return }
        safely("recheck") { try core.recheckPauses() }
        finishInput()
    }

    // MARK: Updates

    nonisolated static func state(_ intent: JSON, taken: Bool) -> CourierState {
        let tool = intent["tool"]?.asString ?? "", cause = intent.get("cause")?.asString ?? ""
        switch intent["status"]?.asString ?? "" {
        case "pending": return taken ? .taken : .sending
        case "queued": return .sending
        case "paused": return .paused
        case "awaiting": return .awaiting
        case "confirmed":
            if CourierDo.tools.contains(tool) { return .toolDone }
            return cause.hasPrefix("confirmed late") ? .deliveredLate : .delivered
        case "failed":
            return CourierDo.tools.contains(tool) && (intent.get("result")?.get("acted")?.isTruthy ?? false) ? .toolUnconfirmed : .failed
        case "refused": return .refused
        default: return .delivered  // answered, asked
        }
    }

    private func rows() -> [(id: Int, state: CourierState, cause: String?, before: JSON?, pause: CourierPause?)] {
        guard let core else { return [] }
        let found = (try? core.db.intents(limit: 100, columns: "id, tool, status, cause, result")) ?? []
        return found.compactMap { i in
            guard let id = i["id"]?.asInt else { return nil }
            let taken = core.runs[id]?.flag("taken") ?? false
            let state = Self.state(i, taken: taken)
            // The run's code, only while the row says it waits: a restart's pause has none.
            let pause = state == .paused && core.runs.has(id) ? core.pauses[id] : nil
            return (id, state, i.get("cause")?.asString, i.get("result")?.get("before"), pause)
        }
    }

    private func snapshot() {
        for r in rows() { known[r.id] = (r.state, r.cause, r.pause) }
    }

    /// One update per intent whose state, cause or pause changed since the last look.
    private func publish() {
        guard core != nil else { return }
        let at = Date(timeIntervalSince1970: clock.now())
        for r in rows() {
            if let old = known[r.id], old.state == r.state, old.cause == r.cause, old.pause == r.pause { continue }
            known[r.id] = (r.state, r.cause, r.pause)
            updateSink.yield(CourierUpdate(intentID: r.id, state: r.state, cause: r.cause, before: r.before, at: at, pause: r.pause))
        }
    }
}
