import Foundation
import Security

// Native client for T3 Code's orchestration protocol 2 (Effect RPC over one WebSocket).
// Facts and corrections: docs/design/t3-research/S1-spikes.md.

// MARK: - Framing

/// Effect-RPC frames. Ids are decimal strings; a stream's `Chunk` must be answered with an `Ack` at once (S1 #2).
enum T3Frame: Equatable {
    case request(id: String, tag: String, payload: T3JSON)
    case ack(requestId: String)
    case interrupt(requestId: String)
    case ping, pong
    case chunk(requestId: String, values: [T3JSON])
    case exit(requestId: String, exit: T3JSON)
    case unknown(T3JSON)

    var json: T3JSON {
        switch self {
        case .request(let id, let tag, let payload): ["_tag": "Request", "id": .string(id), "tag": .string(tag), "payload": payload, "headers": []]
        case .ack(let id): ["_tag": "Ack", "requestId": .string(id)]
        case .interrupt(let id): ["_tag": "Interrupt", "requestId": .string(id)]
        case .ping: ["_tag": "Ping"]
        case .pong: ["_tag": "Pong"]
        case .chunk(let id, let values): ["_tag": "Chunk", "requestId": .string(id), "values": .array(values)]
        case .exit(let id, let exit): ["_tag": "Exit", "requestId": .string(id), "exit": exit]
        case .unknown(let j): j
        }
    }

    func encoded() throws -> String { String(decoding: try json.data(), as: UTF8.self) }

    init(json j: T3JSON) {
        switch j.string ?? j["_tag"]?.string {
        case "Request": self = .request(id: j["id"]?.string ?? "", tag: j["tag"]?.string ?? "", payload: j["payload"] ?? .null)
        case "Ack": self = .ack(requestId: j["requestId"]?.string ?? "")
        case "Interrupt": self = .interrupt(requestId: j["requestId"]?.string ?? "")
        case "Ping": self = .ping
        case "Pong": self = .pong
        case "Chunk": self = .chunk(requestId: j["requestId"]?.string ?? "", values: j["values"]?.array ?? [])
        case "Exit": self = .exit(requestId: j["requestId"]?.string ?? "", exit: j["exit"] ?? .null)
        default: self = .unknown(j)
        }
    }

    /// A text frame may hold one message or an array of them.
    static func decode(_ text: String) -> [T3Frame] {
        guard let j = T3JSON.parse(text) else { return [] }
        if let a = j.array { return a.map(T3Frame.init(json:)) }
        return [T3Frame(json: j)]
    }

    /// Maps an `Exit` to a result: the success value, or the typed failure (OrchestrationV2DispatchCommandError etc.).
    static func result(ofExit exit: T3JSON, tag: String? = nil) -> Result<T3JSON, T3Error> {
        if exit["_tag"]?.string == "Success" { return .success(exit["value"] ?? .null) }
        let causes = exit["cause"]?.array ?? []
        for c in causes {
            if c["_tag"]?.string == "Fail", let err = c["error"] {
                let msg = err["message"]?.string ?? err["_tag"]?.string ?? "The server refused the request"
                return .failure(T3Error(kind: .server, message: msg, detail: err["detail"]?.string,
                                        commandType: err["commandType"]?.string, tag: err["_tag"]?.string))
            }
        }
        if causes.contains(where: { $0["_tag"]?.string == "Interrupt" }) {
            return .failure(T3Error(kind: .interrupted, message: "Interrupted"))
        }
        let defect = causes.first.flatMap { $0["defect"]?.string ?? $0["_tag"]?.string }
        return .failure(T3Error(kind: .server, message: defect ?? "The server failed the request"))
    }
}

// MARK: - Transport

protocol T3Socket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

struct T3Endpoint: Sendable {
    var webSocketRequest: URLRequest
    var environmentId: String?
}

final class T3URLSocket: T3Socket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    init(request: URLRequest) {
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 << 20  // the shell snapshot is ~1 MB
        task.resume()
    }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(decoding: d, as: UTF8.self)
        @unknown default: return ""
        }
    }
    func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}

enum T3ConnectionState: Equatable, Sendable {
    case connecting, connected
    case reconnecting(attempt: Int)
    case incompatible(String)
    case noToken, noServer, tokenRejected
    case idle
}

// MARK: - Discovery and credentials

enum T3Discovery {
    static let tokenService = "fjord-t3-token"
    static let protocolVersion = 2

    static var runtimeFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata/server-runtime.json") }

    /// The server's origin from `server-runtime.json` (it holds no credentials).
    static func origin(runtimeFile: URL = T3Discovery.runtimeFile) -> URL? {
        guard let data = try? Data(contentsOf: runtimeFile), let j = T3JSON.parse(data) else { return nil }
        if let o = j.str("origin"), let u = URL(string: o) { return u }
        if let port = j["port"]?.int { return URL(string: "http://127.0.0.1:\(port)") }
        return nil
    }

    /// The scoped bearer token from Keychain (service `fjord-t3-token`). Never logged.
    static func keychainToken() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: tokenService,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Checks `/.well-known/t3/environment` and builds the `/ws` upgrade request.
    static func endpoint(origin: URL, token: String, session: URLSession = .shared, timeout: TimeInterval = 4) async throws -> T3Endpoint {
        var req = URLRequest(url: origin.appendingPathComponent(".well-known/t3/environment"))
        req.timeoutInterval = timeout
        let data: Data
        do { (data, _) = try await session.data(for: req) }
        catch { throw T3Error(kind: .noServer, message: "T3 isn't answering at \(origin.host ?? "?")") }
        let env = T3JSON.parse(data)
        guard let v = env?["orchestrationProtocolVersion"]?.int, v == protocolVersion else {
            throw T3Error(kind: .incompatible, message: "T3 speaks orchestration protocol \(env?["orchestrationProtocolVersion"]?.int.map(String.init) ?? "?"), Fjord needs \(protocolVersion)")
        }
        // The upgrade would only answer 401 with no reason: ask the session endpoint whether the token still counts.
        var auth = URLRequest(url: origin.appendingPathComponent("api/auth/session"))
        auth.timeoutInterval = timeout
        auth.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let answer: Data
        do { (answer, _) = try await session.data(for: auth) }
        catch { throw T3Error(kind: .noServer, message: "T3 isn't answering at \(origin.host ?? "?")") }
        guard T3JSON.parse(answer)?["authenticated"]?.bool == true else {
            throw T3Error(kind: .tokenRejected, message: "T3 doesn't accept Fjord's token")
        }
        var c = URLComponents(url: origin.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        c.scheme = origin.scheme == "https" ? "wss" : "ws"
        c.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: String(protocolVersion))]
        var ws = URLRequest(url: c.url!)
        ws.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return T3Endpoint(webSocketRequest: ws, environmentId: env?["environmentId"]?.string)
    }
}


// MARK: - Client

actor T3Client {
    struct Options: Sendable {
        var pingInterval: Duration = .seconds(5)
        var backoff: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)]
        var connectTimeout: Duration = .seconds(10)
        var maxDispatchAttempts = 3
        init() {}
    }

    typealias Resolver = @Sendable () async throws -> T3Endpoint
    typealias Connector = @Sendable (T3Endpoint) async throws -> T3Socket

    private let resolve: Resolver
    private let connect: Connector
    private let options: Options

    private struct Sub {
        var tag: String
        var payload: [String: T3JSON]
        var cursor: Int?
        var emit: @Sendable (T3JSON) -> Int?
        var finish: @Sendable () -> Void
        var requestId: String?
    }
    private var subs: [UUID: Sub] = [:]
    private var streamIds: [String: UUID] = [:]
    private var pending: [String: CheckedContinuation<T3JSON, Error>] = [:]
    private var nextRequestId = 1

    private var socket: T3Socket?
    private var runner: Task<Void, Never>?
    private var state: T3ConnectionState = .idle
    private var stateObservers: [UUID: AsyncStream<T3ConnectionState>.Continuation] = [:]
    private var connectedWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var gotFrame = false
    private(set) var environmentId: String?

    init(options: Options = Options(), resolve: @escaping Resolver, connect: @escaping Connector = { T3URLSocket(request: $0.webSocketRequest) }) {
        self.options = options; self.resolve = resolve; self.connect = connect
    }

    /// The real thing: discovery from `~/.t3`, the environment check, and the Keychain token.
    static func local(options: Options = Options(), token: @escaping @Sendable () -> String? = { T3Discovery.keychainToken() }) -> T3Client {
        T3Client(options: options, resolve: {
            guard let origin = T3Discovery.origin() else { throw T3Error(kind: .noServer, message: "No T3 server is running (no server-runtime.json)") }
            guard let tok = token() else { throw T3Error(kind: .noToken, message: "No T3 token in Keychain (fjord-t3-token)") }
            return try await T3Discovery.endpoint(origin: origin, token: tok)
        })
    }

    // MARK: Public API

    var connectionState: T3ConnectionState { state }

    func connectionStates() -> AsyncStream<T3ConnectionState> {
        let id = UUID()
        return AsyncStream { c in
            c.yield(state)
            stateObservers[id] = c
            c.onTermination = { [weak self] _ in Task { await self?.dropObserver(id) } }
        }
    }

    /// Every thread, live. Resumes with `afterSequence` after a reconnect. Items repeat harmlessly (rows are whole upserts).
    func subscribeShell() -> AsyncStream<T3ShellItem> {
        subscribe(tag: "orchestration.subscribeShell", payload: [:]) { T3ShellItem(json: $0) } sequence: { $0.sequence }
    }

    /// One thread: a snapshot, then events.
    /// `bounded`: T3 caps the snapshot at the last 10 user turns, 75 items and 1 MiB (for reads that need the end of a thread).
    func subscribeThread(_ threadId: String, bounded: Bool = false) -> AsyncStream<T3ThreadItem> {
        var payload: [String: T3JSON] = ["threadId": .string(threadId)]
        if bounded { payload["acceptBoundedSnapshot"] = .bool(true) }
        return subscribe(tag: "orchestration.subscribeThread", payload: payload) { T3ThreadItem(json: $0) } sequence: { $0.sequence }
    }

    /// Sends a command and returns the sequence it committed at, or a typed error. A retry after a dropped
    /// socket reuses `commandId`, so the server's receipts make it idempotent.
    @discardableResult
    func dispatch(_ command: T3Command, commandId: String = UUID().uuidString.lowercased()) async throws -> T3DispatchResult {
        let payload = command.payload(commandId: commandId)
        var lastError = T3Error(kind: .disconnected, message: "Not connected")
        for _ in 0..<max(1, options.maxDispatchAttempts) {
            do {
                let value = try await call(tag: command.rpcTag, payload: payload)
                return T3DispatchResult(sequence: value["sequence"]?.int, raw: value)
            } catch let e as T3Error where e.kind == .disconnected {
                lastError = e
            }
        }
        throw lastError
    }

    /// Unary RPC (for example `server.getConfig`, `orchestration.getArchivedShellSnapshot`).
    func call(tag: String, payload: T3JSON = [:]) async throws -> T3JSON {
        try await waitConnected()
        let id = takeRequestId()
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<T3JSON, Error>) in
            pending[id] = k
            Task { [weak self] in
                guard let self else { return }
                do { try await self.send(.request(id: id, tag: tag, payload: payload)) }
                catch { await self.failPending(id, T3Error(kind: .disconnected, message: "The connection dropped")) }
            }
        }
    }

    func shutdown() {
        runner?.cancel(); runner = nil
        socket?.close(); socket = nil
        for s in subs.values { s.finish() }
        subs = [:]; streamIds = [:]
        failAllPending(T3Error(kind: .disconnected, message: "Shut down"))
        setState(.idle)
    }

    // MARK: Subscriptions

    private func subscribe<Item: Sendable>(tag: String, payload: [String: T3JSON], decode: @escaping @Sendable (T3JSON) -> Item,
                                           sequence: @escaping @Sendable (Item) -> Int?) -> AsyncStream<Item> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Item>.makeStream(bufferingPolicy: .unbounded)
        let sub = Sub(tag: tag, payload: payload, cursor: nil,
                      emit: { raw in let item = decode(raw); cont.yield(item); return sequence(item) },
                      finish: { cont.finish() })
        subs[id] = sub
        cont.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        ensureRunning()
        if socket != nil { Task { await self.start(id) } }
        return stream
    }

    private func drop(_ id: UUID) async {
        guard let sub = subs.removeValue(forKey: id) else { return }
        if let rid = sub.requestId {
            streamIds[rid] = nil
            try? await send(.interrupt(requestId: rid))
        }
    }

    private func start(_ id: UUID) async {
        guard var sub = subs[id], sub.requestId == nil else { return }
        let rid = takeRequestId()
        sub.requestId = rid
        subs[id] = sub
        streamIds[rid] = id
        var payload = sub.payload
        if let c = sub.cursor { payload["afterSequence"] = .number(Double(c)) }
        try? await send(.request(id: rid, tag: sub.tag, payload: .object(payload)))
    }

    // MARK: Connection loop

    private func ensureRunning() {
        guard runner == nil else { return }
        runner = Task { [weak self] in await self?.runLoop() }
    }

    private func runLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            setState(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
            var terminal: T3ConnectionState?
            do {
                let endpoint = try await resolve()
                environmentId = endpoint.environmentId
                let sock = try await connect(endpoint)
                gotFrame = false
                socket = sock
                try await session(sock)
            } catch let e as T3Error {
                switch e.kind {
                case .incompatible: terminal = .incompatible(e.message)
                case .noToken: terminal = .noToken
                case .noServer: terminal = .noServer
                case .tokenRejected: terminal = .tokenRejected
                default: break
                }
            } catch {}
            socket?.close(); socket = nil
            failAllPending(T3Error(kind: .disconnected, message: "The connection dropped"))
            for (id, var s) in subs { if let rid = s.requestId { streamIds[rid] = nil }; s.requestId = nil; subs[id] = s }
            if gotFrame { attempt = 0 }
            gotFrame = false
            if Task.isCancelled { break }
            if let terminal { setState(terminal); failWaiters(T3Error(kind: terminalKind(terminal), message: "\(terminal)")) }
            // Nothing is using the client: stop trying until something asks again.
            if subs.isEmpty && pending.isEmpty && connectedWaiters.isEmpty { setState(terminal ?? .idle); break }
            attempt += 1
            let wait = options.backoff[min(attempt - 1, options.backoff.count - 1)]
            setState(terminal ?? .reconnecting(attempt: attempt))
            try? await Task.sleep(for: wait)
        }
        runner = nil
    }

    private func terminalKind(_ s: T3ConnectionState) -> T3Error.Kind {
        switch s { case .incompatible: .incompatible; case .noToken: .noToken; case .noServer: .noServer; case .tokenRejected: .tokenRejected; default: .disconnected }
    }

    /// One socket's life: requests go out at once, a reader acks and routes, a pinger declares the socket dead.
    private func session(_ sock: T3Socket) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                while true {
                    let text = try await sock.receive()
                    guard let self else { return }
                    await self.handle(text)
                }
            }
            group.addTask { [weak self, interval = options.pingInterval] in
                // The first ping doubles as the connection handshake.
                var awaiting = false
                while true {
                    guard let self else { return }
                    if awaiting, await !self.sawFrameSincePing() { throw T3Error(kind: .timedOut, message: "No Pong") }
                    await self.clearFrameFlag()
                    try await self.send(.ping)
                    awaiting = true
                    try await Task.sleep(for: interval)
                }
            }
            for id in subs.keys { await start(id) }
            // Closing the socket is what wakes a reader blocked in `receive()`: the group waits for it.
            defer { group.cancelAll(); sock.close() }
            _ = try await group.next()
        }
    }

    private var frameSincePing = false
    private func sawFrameSincePing() -> Bool { frameSincePing }
    private func clearFrameFlag() { frameSincePing = false }

    func handle(_ text: String) async {
        for frame in T3Frame.decode(text) {
            frameSincePing = true
            if !gotFrame {
                gotFrame = true
                setState(.connected)
                let ws = connectedWaiters; connectedWaiters = [:]
                ws.values.forEach { $0.resume() }
            }
            switch frame {
            case .chunk(let rid, let values):
                // Ack first, always: the server stalls the stream until it gets one (S1 #2).
                try? await send(.ack(requestId: rid))
                guard let id = streamIds[rid], var sub = subs[id] else { continue }
                for v in values {
                    if let s = sub.emit(v) { sub.cursor = max(sub.cursor ?? 0, s) }
                }
                subs[id] = sub
            case .exit(let rid, let exit):
                if let k = pending.removeValue(forKey: rid) {
                    switch T3Frame.result(ofExit: exit) {
                    case .success(let v): k.resume(returning: v)
                    case .failure(let e): k.resume(throwing: e)
                    }
                } else if let id = streamIds.removeValue(forKey: rid) {
                    // The server ended a stream we still want: ask again.
                    if var sub = subs[id] { sub.requestId = nil; subs[id] = sub; Task { await self.restart(id) } }
                }
            case .ping: try? await send(.pong)
            case .pong, .request, .ack, .interrupt, .unknown: break
            }
        }
    }

    private func restart(_ id: UUID) async {
        try? await Task.sleep(for: options.backoff.first ?? .seconds(1))
        await start(id)
    }

    // MARK: Helpers

    func send(_ frame: T3Frame) async throws {
        guard let socket else { throw T3Error(kind: .disconnected, message: "Not connected") }
        try await socket.send(try frame.encoded())
    }

    private func takeRequestId() -> String { defer { nextRequestId += 1 }; return String(nextRequestId) }

    private func failPending(_ id: String, _ e: T3Error) {
        pending.removeValue(forKey: id)?.resume(throwing: e)
    }
    private func failAllPending(_ e: T3Error) {
        let all = pending; pending = [:]
        all.values.forEach { $0.resume(throwing: e) }
    }
    private func failWaiters(_ e: T3Error) {
        let all = connectedWaiters; connectedWaiters = [:]
        all.values.forEach { $0.resume(throwing: e) }
    }

    private func setState(_ s: T3ConnectionState) {
        guard s != state else { return }
        state = s
        stateObservers.values.forEach { $0.yield(s) }
    }
    private func dropObserver(_ id: UUID) { stateObservers[id] = nil }

    /// Returns once a frame has arrived on a live socket; throws the terminal error if the server can't be used,
    /// or `timedOut` after `connectTimeout`.
    private func waitConnected() async throws {
        if gotFrame, socket != nil { return }
        ensureRunning()
        let id = UUID()
        let timeout = options.connectTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await self?.timeoutWaiter(id) }
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connectedWaiters[id] = k
        }
    }
    private func timeoutWaiter(_ id: UUID) {
        connectedWaiters.removeValue(forKey: id)?.resume(throwing: T3Error(kind: .timedOut, message: "T3 didn't answer in time"))
    }
}
