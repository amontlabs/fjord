import Darwin
import Foundation
import Testing
@testable import Fjord

/// A plain TCP client on 127.0.0.1, blocking: used off the main thread only (the server answers on it).
private final class Client: @unchecked Sendable {
    let fd: Int32

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        // A watchdog, not a timing: a slow CI runner may take long, a broken server still ends the test.
        var timeout = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard ok == 0 else { close(fd); return nil }
    }

    deinit { close(fd) }

    func send(_ text: String) {
        let data = Array(text.utf8)
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Everything until the server closes (or 30 s pass: the main thread may be busy with other suites): the text, and whether it closed.
    func readToEnd() -> (text: String, closed: Bool) {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 { out.append(contentsOf: buffer[0..<n]); continue }
            return (String(decoding: out, as: UTF8.self), n == 0)
        }
    }

    /// One response on a kept-alive connection: its head and as much body as it says.
    func readResponse() -> String {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            if let end = out.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: out[..<end.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if out.count - end.upperBound >= length { return String(decoding: out, as: UTF8.self) }
            }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return String(decoding: out, as: UTF8.self) }
            out.append(contentsOf: buffer[0..<n])
        }
    }
}

/// The MCP server on a real socket: what it takes, what it refuses, and how long it waits.
@MainActor
@Suite struct RouterTransport {
    /// The server's own deadlines, generous here: only the tests of those deadlines set short ones.
    nonisolated private static var generous: RouterMCPServer.Limits {
        var limits = RouterMCPServer.Limits()
        limits.requestTimeout = 300
        limits.idleTimeout = 300
        return limits
    }

    private func start(_ limits: RouterMCPServer.Limits = generous, deadlines: Events? = nil,
                       handle: @escaping @MainActor (Data) async -> RouterRPC.Reply = { body in
                           await RouterRPC.handle(body, tools: RouterTools.specs) { _, _ in nil }
                       }) async throws -> (RouterMCPServer, UInt16) {
        let server = RouterMCPServer(limits: limits, handle: handle)
        if let deadlines { server.onDeadline = { deadlines.add($0) } }
        let port: UInt16 = try await withCheckedThrowingContinuation { c in server.start { c.resume(with: $0) } }
        return (server, port)
    }

    private func post(_ token: String, _ body: String, close: Bool = false) -> String {
        "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\n"
            + (close ? "Connection: close\r\n" : "") + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
    }

    private func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        // Blocking socket reads go on a dispatch queue, never on Swift's shared pool (which other tests need).
        await OffMain.run(work)
    }

    @Test func aRequestIsAnsweredAndTheConnectionKept() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let request = post(server.token, ping)
        let (first, second) = await off { () -> (String, String) in
            guard let c = Client(port: port) else { return ("", "") }
            c.send(request)
            let a = c.readResponse()
            c.send(request)
            return (a, c.readResponse())
        }
        #expect(first.hasPrefix("HTTP/1.1 200 OK") && first.contains("Connection: keep-alive") && first.contains(#""result":{}"#))
        #expect(second.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test func aStrangerIsTurnedAwayBeforeItsBodyIsRead() async throws {
        var handled = 0
        let (server, port) = try await start { _ in handled += 1; return RouterRPC.Reply(status: 202, body: nil) }
        defer { server.stop() }
        // A huge body announced and never sent: the answer comes from the head alone.
        let reply = await off { () -> (String, Bool) in
            guard let c = Client(port: port) else { return ("", false) }
            c.send("POST /mcp HTTP/1.1\r\nAuthorization: Bearer nope\r\nContent-Length: 900000\r\n\r\n")
            return c.readToEnd()
        }
        #expect(reply.0.hasPrefix("HTTP/1.1 401") && reply.1)
        let token = server.token
        let big = await off { () -> (String, Bool) in
            guard let c = Client(port: port) else { return ("", false) }
            c.send("POST /mcp HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(MiniHTTP.maxBody + 1)\r\n\r\n")
            return c.readToEnd()
        }
        #expect(big.0.hasPrefix("HTTP/1.1 413") && big.1)
        let get = await off { () -> (String, Bool) in
            guard let c = Client(port: port) else { return ("", false) }
            c.send("GET /mcp HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n")
            return c.readToEnd()
        }
        #expect(get.0.hasPrefix("HTTP/1.1 405") && get.0.contains("Allow: POST"))
        #expect(handled == 0)
    }

    @Test func connectionsAreCapped() async throws {
        var limits = Self.generous
        limits.maxConnections = 2
        let (server, port) = try await start(limits)
        defer { server.stop() }
        let held = await off { [Client(port: port), Client(port: port)] }
        await waitUntil { server.connectionCount() >= 2 }
        #expect(server.connectionCount() == 2)
        let third = await off { () -> (String, Bool) in
            guard let c = Client(port: port) else { return ("", false) }
            return c.readToEnd()
        }
        #expect(third.0.hasPrefix("HTTP/1.1 503") && third.1)
        #expect(held.count == 2)
    }

    @Test func aSlowRequestAndAnIdleConnectionAreClosedByTheirDeadlines() async throws {
        var limits = RouterMCPServer.Limits()
        limits.requestTimeout = 0.3
        limits.idleTimeout = 0.5
        let deadlines = Events()
        let (server, port) = try await start(limits, deadlines: deadlines)
        defer { server.stop() }
        // Half a head, then nothing: closed, and by the request deadline (the server says so; no time is measured).
        let slow = await off { () -> Bool in
            guard let c = Client(port: port) else { return false }
            c.send("POST /mcp HTTP/1.1\r\nHost: 127")
            return c.readToEnd().closed
        }
        #expect(slow)
        await waitUntil { deadlines.all.contains("request") }
        #expect(deadlines.all == ["request"])
        // A request answered, then quiet on the kept connection: closed by the idle deadline.
        let request = post(server.token, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        let idle = await off { () -> (String, Bool) in
            guard let c = Client(port: port) else { return ("", false) }
            c.send(request)
            return (c.readResponse(), c.readToEnd().closed)
        }
        #expect(idle.0.hasPrefix("HTTP/1.1 200") && idle.1)
        await waitUntil { deadlines.all.contains("idle") }
        #expect(deadlines.all == ["request", "idle"])
    }

    @Test func stoppingCancelsTheRequestsBeingAnswered() async throws {
        let gate = RouterGate()
        let cancelled = StopFlag()
        var sawCancel: Bool?
        let (server, port) = try await start { _ in
            // The handler hears the cancellation as it happens (acknowledged), and finishes only when let go.
            await withTaskCancellationHandler { await gate.wait() } onCancel: { cancelled.set() }
            sawCancel = Task.isCancelled
            return RouterRPC.Reply(status: 202, body: nil)
        }
        let request = post(server.token, "{}")
        let reading = Task { await OffMain.run { () -> (String, Bool) in
            guard let c = Client(port: port) else { return ("", false) }
            c.send(request)
            return c.readToEnd()
        } }
        await waitUntil { gate.waiting }
        server.stop()
        // Stopping cancelled the request being answered: waited for, not assumed after a pause.
        await waitUntil { cancelled.isSet }
        #expect(cancelled.isSet)
        gate.open()
        let reply = await reading.value
        await waitUntil { sawCancel != nil }
        #expect(sawCancel == true)
        // The connection is dropped without the answer.
        #expect(reply.0.isEmpty && reply.1)
    }

    @Test func aRequestLateInAnIdleSpellGetsItsOwnDeadline() async throws {
        // Wide margins for a slow machine: idle 10 s; the request starts 1 s in and ends 12 s in.
        var limits = Self.generous
        limits.idleTimeout = 10
        let (server, port) = try await start(limits)
        defer { server.stop() }
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let request = post(server.token, ping)
        let half = request.index(request.startIndex, offsetBy: 20)
        let (first, second) = (String(request[..<half]), String(request[half...]))
        // Answered, idle for half the idle time, then a request that takes longer than what was left of it.
        let reply = await off { () -> String in
            guard let c = Client(port: port) else { return "" }
            c.send(request)
            _ = c.readResponse()
            Thread.sleep(forTimeInterval: 1)
            c.send(first)
            Thread.sleep(forTimeInterval: 11)
            c.send(second)
            return c.readResponse()
        }
        #expect(reply.hasPrefix("HTTP/1.1 200 OK"))
    }
}

/// What a server's deadlines did, in order (from its queue).
final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var all: [String] { lock.withLock { items } }
    func add(_ item: String) { lock.withLock { items.append(item) } }
}
