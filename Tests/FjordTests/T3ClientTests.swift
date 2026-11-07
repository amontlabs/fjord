import Foundation
import Testing
@testable import Fjord

/// A socket the test drives: `push` is the server talking, `outbox` is what the client sent.
final class FakeT3Socket: T3Socket, @unchecked Sendable {
    let outbox = FrameBox()
    private let inbound: AsyncThrowingStream<String, Error>
    private let feed: AsyncThrowingStream<String, Error>.Continuation
    private var iterator: AsyncThrowingStream<String, Error>.Iterator
    private let lock = NSLock()
    private(set) var closed = false

    init() {
        (inbound, feed) = AsyncThrowingStream<String, Error>.makeStream()
        iterator = inbound.makeAsyncIterator()
    }
    func send(_ text: String) async throws {
        for f in T3Frame.decode(text) { await outbox.push(f) }
    }
    func receive() async throws -> String {
        var it = lock.withLock { iterator }
        defer { lock.withLock { iterator = it } }
        guard let next = try await it.next() else { throw T3Error(kind: .disconnected, message: "closed") }
        return next
    }
    func close() { lock.withLock { closed = true }; feed.finish() }
    /// The server drops the connection.
    func drop() { feed.finish(throwing: T3Error(kind: .disconnected, message: "dropped")) }
    func push(_ frame: T3Frame) { feed.yield((try? frame.encoded()) ?? "") }
    func pushRaw(_ text: String) { feed.yield(text) }
}

/// Frames the client sent, awaited without polling.
actor FrameBox {
    private var items: [T3Frame] = []
    private var waiters: [(UUID, (T3Frame) -> Bool, CheckedContinuation<T3Frame, Never>)] = []
    private(set) var all: [T3Frame] = []
    func push(_ f: T3Frame) {
        all.append(f)
        if let i = waiters.firstIndex(where: { $0.1(f) }) { let w = waiters.remove(at: i); w.2.resume(returning: f); return }
        items.append(f)
    }
    func next(where match: @escaping (T3Frame) -> Bool) async -> T3Frame {
        if let i = items.firstIndex(where: match) { return items.remove(at: i) }
        return await withCheckedContinuation { waiters.append((UUID(), match, $0)) }
    }
    func request(_ tag: String) async -> (id: String, payload: T3JSON) {
        let f = await next { if case .request(_, let t, _) = $0 { t == tag } else { false } }
        guard case .request(let id, _, let payload) = f else { fatalError() }
        return (id, payload)
    }
}

actor SocketLog {
    private var sockets: [FakeT3Socket] = []
    private var waiters: [CheckedContinuation<FakeT3Socket, Never>] = []
    private var handed = 0
    func made(_ s: FakeT3Socket) {
        sockets.append(s)
        if !waiters.isEmpty { handed += 1; waiters.removeFirst().resume(returning: s) }
    }
    /// The next socket the client opens that the test hasn't taken yet.
    func next() async -> FakeT3Socket {
        if handed < sockets.count { handed += 1; return sockets[handed - 1] }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("T3 client over a fake socket", .timeLimit(.minutes(1)))
struct T3ClientTests {
    typealias F = T3Fixture

    func makeClient(ping: Duration = .seconds(60), attempts: Int = 3) -> (T3Client, SocketLog) {
        var o = T3Client.Options()
        o.pingInterval = ping; o.backoff = [.milliseconds(1)]; o.maxDispatchAttempts = attempts; o.connectTimeout = .seconds(30)
        let log = SocketLog()
        let client = T3Client(options: o,
                              resolve: { T3Endpoint(webSocketRequest: URLRequest(url: URL(string: "ws://127.0.0.1:1/ws")!), environmentId: "env1") },
                              connect: { _ in let s = FakeT3Socket(); await log.made(s); return s })
        return (client, log)
    }

    @Test func shellStreamIsAckedAndYielded() async throws {
        let (client, log) = makeClient()
        var shell = await client.subscribeShell().makeAsyncIterator()
        let sock = await log.next()
        let req = await sock.outbox.request("orchestration.subscribeShell")
        #expect(req.payload == [:])
        sock.push(.pong)
        sock.push(.chunk(requestId: req.id, values: [F.snapshot(threads: [F.thread("a")], sequence: 40)]))
        guard case .snapshot(let s)? = await shell.next() else { Issue.record("no snapshot"); return }
        #expect(s.threads.map(\.id) == ["a"])
        // The Ack goes back for that chunk, immediately.
        let ack = await sock.outbox.next { if case .ack = $0 { true } else { false } }
        #expect(ack == .ack(requestId: req.id))
        // Two more chunks, two more acks.
        sock.push(.chunk(requestId: req.id, values: [["kind": "thread.updated", "sequence": 41, "location": "active", "thread": F.thread("a", status: "running")]]))
        sock.push(.chunk(requestId: req.id, values: [["kind": "mystery", "sequence": 42]]))
        _ = await shell.next(); _ = await shell.next()
        _ = await sock.outbox.next { $0 == .ack(requestId: req.id) }
        _ = await sock.outbox.next { $0 == .ack(requestId: req.id) }
        #expect(await client.connectionState == .connected)
        await client.shutdown()
    }

    @Test func pingsAreSentAndPongKeepsTheSocket() async throws {
        let (client, log) = makeClient(ping: .milliseconds(20))
        let shell = await client.subscribeShell()
        defer { withExtendedLifetime(shell) {} }
        let sock = await log.next()
        for _ in 0..<3 {
            _ = await sock.outbox.next { $0 == .ping }
            sock.push(.pong)
        }
        #expect(sock.closed == false)
        await client.shutdown()
    }

    @Test func missingPongMeansDeadSocketAndReconnect() async throws {
        let (client, log) = makeClient(ping: .milliseconds(30))
        let shell = await client.subscribeShell()
        defer { withExtendedLifetime(shell) {} }
        let first = await log.next()
        first.push(.pong)  // connected, then silence
        let second = await log.next()
        #expect(first.closed)
        _ = await second.outbox.request("orchestration.subscribeShell")
        await client.shutdown()
    }

    @Test func reconnectResumesWithAfterSequence() async throws {
        let (client, log) = makeClient()
        var shell = await client.subscribeShell().makeAsyncIterator()
        let first = await log.next()
        let req = await first.outbox.request("orchestration.subscribeShell")
        first.push(.pong)
        first.push(.chunk(requestId: req.id, values: [F.snapshot(threads: [F.thread("a")], sequence: 40),
                                                      ["kind": "thread.updated", "sequence": 47, "location": "active", "thread": F.thread("a", status: "running")]]))
        _ = await shell.next(); _ = await shell.next()
        first.drop()
        let second = await log.next()
        let again = await second.outbox.request("orchestration.subscribeShell")
        #expect(again.payload == ["afterSequence": 47])
        #expect(again.id != req.id)
        await client.shutdown()
    }

    @Test func threadSubscriptionCarriesIdAndCursor() async throws {
        let (client, log) = makeClient()
        var items = await client.subscribeThread("t1").makeAsyncIterator()
        let first = await log.next()
        let req = await first.outbox.request("orchestration.subscribeThread")
        #expect(req.payload == ["threadId": "t1"])
        first.push(.pong)
        first.push(.chunk(requestId: req.id, values: [F.projection(), F.event("run.updated", 501, payload: F.run("r1", status: "waiting"))]))
        _ = await items.next(); _ = await items.next()
        first.drop()
        let second = await log.next()
        let again = await second.outbox.request("orchestration.subscribeThread")
        #expect(again.payload == ["threadId": "t1", "afterSequence": 501])
        await client.shutdown()
    }

    @Test func cancellingTheStreamInterrupts() async throws {
        let (client, log) = makeClient()
        let task = Task { for await _ in await client.subscribeThread("t1") {} }
        let sock = await log.next()
        let req = await sock.outbox.request("orchestration.subscribeThread")
        sock.push(.pong)
        task.cancel()
        _ = await sock.outbox.next { $0 == .interrupt(requestId: req.id) }
        await client.shutdown()
    }

    @Test func dispatchReturnsSequence() async throws {
        let (client, log) = makeClient()
        let result = Task { try await client.dispatch(.threadVisit(threadId: "t1", visitedAt: T3Timestamp("2026-01-02T03:04:05.000Z")), commandId: "cmd-1") }
        let sock = await log.next()
        sock.push(.pong)
        let req = await sock.outbox.request("orchestration.dispatchCommand")
        #expect(req.payload == ["commandId": "cmd-1", "type": "thread.visit", "threadId": "t1", "visitedAt": "2026-01-02T03:04:05.000Z"])
        sock.push(.exit(requestId: req.id, exit: ["_tag": "Success", "value": ["sequence": 7]]))
        #expect(try await result.value.sequence == 7)
        await client.shutdown()
    }

    @Test func dispatchSurfacesTheTypedError() async throws {
        let (client, log) = makeClient()
        let result = Task { try await client.dispatch(.messageDispatch(threadId: "t1", messageId: "m", text: "go", dispatch: .startImmediately(intent: .steer))) }
        let sock = await log.next()
        sock.push(.pong)
        let req = await sock.outbox.request("orchestration.dispatchCommand")
        sock.push(.exit(requestId: req.id, exit: T3JSON.parse(#"{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"OrchestrationV2DispatchCommandError","commandType":"message.dispatch","message":"Runtime request is resolved.","detail":"Runtime request is resolved."}}]}"#)!))
        do { _ = try await result.value; Issue.record("should have thrown") }
        catch let e as T3Error { #expect(e.kind == .server && e.message == "Runtime request is resolved." && e.commandType == "message.dispatch") }
        await client.shutdown()
    }

    @Test func dispatchRetriesWithTheSameCommandId() async throws {
        let (client, log) = makeClient()
        let result = Task { try await client.dispatch(.threadArchive(threadId: "t1"), commandId: "once") }
        let first = await log.next()
        first.push(.pong)
        let req = await first.outbox.request("orchestration.dispatchCommand")
        #expect(req.payload["commandId"] == "once")
        first.drop()  // dropped before the answer: the client doesn't know if it landed
        let second = await log.next()
        second.push(.pong)
        let retry = await second.outbox.request("orchestration.dispatchCommand")
        #expect(retry.payload["commandId"] == "once")  // the server's receipt makes this idempotent
        second.push(.exit(requestId: retry.id, exit: ["_tag": "Success", "value": ["sequence": 12]]))
        #expect(try await result.value.sequence == 12)
        await client.shutdown()
    }

    @Test func requestIdsAreDecimalStringsAndGrow() async throws {
        let (client, log) = makeClient()
        let s1 = await client.subscribeShell()
        let s2 = await client.subscribeThread("t1")
        defer { withExtendedLifetime((s1, s2)) {} }
        let sock = await log.next()
        let a = await sock.outbox.request("orchestration.subscribeShell")
        let b = await sock.outbox.request("orchestration.subscribeThread")
        #expect(Int(a.id) != nil && Int(b.id) != nil && a.id != b.id)
        await client.shutdown()
    }
}
