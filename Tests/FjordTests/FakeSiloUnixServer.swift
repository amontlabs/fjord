import Darwin
import Foundation

struct FakeSiloRequest: Sendable {
    let id: String
    let method: String
    let jobId: String?
    let subscription: String?
    let events: [String]?
    let protocolMin: Int?
    let protocolMax: Int?
    let connection: Int
    let params: Data
}

actor FakeSiloRequestLog {
    private(set) var requests: [FakeSiloRequest] = []

    func append(_ request: FakeSiloRequest) { requests.append(request) }

    func waitForCount(_ count: Int, attempts: Int = 300) async {
        for _ in 0..<attempts {
            if requests.count >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

actor FakeSiloGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class FakeSiloSocket: @unchecked Sendable {
    fileprivate let descriptor: Int32
    private let lock = NSLock()
    private var isClosed = false

    init(descriptor: Int32) { self.descriptor = descriptor }

    func write(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        try write(data)
    }

    func writeFragmented(_ value: Any, chunks: [Int]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        try writeFrame(data, chunks: chunks)
    }

    func write(_ data: Data) throws {
        try writeFrame(data, chunks: [])
    }

    private func writeFrame(_ data: Data, chunks: [Int]) throws {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw Self.failure("invalid frame length") }
        let length = UInt32(data.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        frame.append(data)
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw Self.failure("socket closed") }
        try frame.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            var lengths = chunks.filter { $0 > 0 }
            if lengths.isEmpty { lengths = [buffer.count] }
            let requested = lengths.reduce(0, +)
            if requested < buffer.count { lengths.append(buffer.count - requested) }
            for requestedLength in lengths {
                let end = min(buffer.count, offset + requestedLength)
                while offset < end {
                    let count = Darwin.send(descriptor, base.advanced(by: offset), end - offset, 0)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw Self.failure("write frame")
                    }
                    guard count > 0 else { throw Self.failure("socket closed") }
                    offset += count
                }
                if offset < buffer.count { _ = Darwin.usleep(1_000) }
            }
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private static func failure(_ operation: String) -> NSError {
        NSError(domain: "FakeSiloUnixServer", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }
}

final class FakeSiloUnixServer: @unchecked Sendable {
    typealias Handler = @Sendable (FakeSiloRequest, FakeSiloSocket) async -> Void
    typealias ReadGate = @Sendable (FakeSiloRequest) async -> Void

    let path: String
    let requestLog = FakeSiloRequestLog()

    private let listener: Int32
    private let handler: Handler?
    private let readGate: ReadGate
    private let stopLock = NSLock()
    private var isStopped = false
    private var connections: [FakeSiloSocket] = []
    private var task: Task<Void, Never>?
    private let defaultResponses = FakeSiloDefaultResponses()

    init(handler: Handler? = nil, readGate: @escaping ReadGate = { _ in }) throws {
        self.handler = handler
        self.readGate = readGate
        path = "/tmp/fjord-silo-\(UUID().uuidString).sock"
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.failure("create listener") }
        listener = fd
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw NSError(domain: "FakeSiloUnixServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket path is too long."])
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        pathBytes.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.initializeMemory(as: UInt8.self, repeating: 0)
                destination.copyBytes(from: source)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let error = Self.failure("bind listener")
            Darwin.close(fd)
            throw error
        }
        task = Task.detached(priority: .utility) { [weak self] in await self?.acceptConnections() }
    }

    deinit { stop() }

    func stop() {
        stopLock.lock()
        guard !isStopped else { stopLock.unlock(); return }
        isStopped = true
        let openConnections = connections
        connections.removeAll()
        stopLock.unlock()
        task?.cancel()
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        openConnections.forEach { $0.close() }
        _ = Darwin.unlink(path)
    }

    private func acceptConnections() async {
        var connectionNumber = 0
        let listener = self.listener
        while !Task.isCancelled {
            let descriptor = await Self.blocking { Darwin.accept(listener, nil, nil) }
            guard descriptor >= 0 else { return }
            connectionNumber += 1
            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let connection = FakeSiloSocket(descriptor: descriptor)
            let wasStopped = stopLock.withLock {
                guard !isStopped else { return true }
                connections.append(connection)
                return false
            }
            if wasStopped { connection.close(); return }
            let acceptedNumber = connectionNumber
            Task.detached(priority: .utility) { [weak self] in
                await self?.serve(connection, number: acceptedNumber)
            }
        }
    }

    private func serve(_ connection: FakeSiloSocket, number: Int) async {
        defer { connection.close() }
        let descriptor = connection.descriptor
        // One frame at a time, the next read only once the read gate lets it: a gate holding it leaves the client's writes
        // to fill the socket.
        while !Task.isCancelled, let frame = await Self.blocking({ try? Self.readFrame(descriptor) }) {
            guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  let id = object["id"] as? String, let method = object["method"] as? String else { return }
            let params = object["params"] as? [String: Any] ?? [:]
            let version = params["protocol"] as? [String: Any]
            let paramsData = (try? JSONSerialization.data(withJSONObject: params, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
            let request = FakeSiloRequest(id: id, method: method, jobId: params["jobId"] as? String,
                                          subscription: params["subscription"] as? String,
                                          events: params["events"] as? [String],
                                          protocolMin: version?["min"] as? Int, protocolMax: version?["max"] as? Int,
                                          connection: number, params: paramsData)
            await requestLog.append(request)
            if let handler {
                Task.detached(priority: .utility) { await handler(request, connection) }
            } else {
                Task.detached(priority: .utility) { [defaultResponses] in
                    await defaultResponses.respond(request, to: connection)
                }
            }
            await readGate(request)
        }
    }

    /// `work` (an `accept` or a read, which block) on a thread of its own, never on Swift's cooperative pool: that pool has a
    /// thread per core, and on CI's three-core runner the server's accept and read and the client's reader filled it, so the
    /// task that would have answered never ran and the suite hung.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private static func readFrame(_ fd: Int32) throws -> Data? {
        guard let header = try readExactly(4, from: fd, allowEOF: true) else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 4 * 1024 * 1024 else { throw failure("invalid frame length") }
        return try readExactly(Int(length), from: fd, allowEOF: false)
    }

    private static func readExactly(_ length: Int, from fd: Int32, allowEOF: Bool) throws -> Data? {
        var data = Data(count: length)
        var received = 0
        var eof = false
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while received < length {
                let count = Darwin.recv(fd, base.advanced(by: received), length - received, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("read frame")
                }
                if count == 0 { eof = true; break }
                received += count
            }
        }
        if eof {
            if allowEOF && received == 0 { return nil }
            throw failure("truncated frame")
        }
        return data
    }

    private static func failure(_ operation: String) -> NSError {
        NSError(domain: "FakeSiloUnixServer", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }
}

private actor FakeSiloDefaultResponses {
    private struct WaitingJobReply {
        let request: FakeSiloRequest
        let socket: FakeSiloSocket
    }

    private var subscriptionCount = 0
    private var waitingJobReply: WaitingJobReply?

    func respond(_ request: FakeSiloRequest, to socket: FakeSiloSocket) {
        switch request.method {
        case "engine.handshake":
            try? socket.write(["id": request.id, "result": ["deviceId": "device-1", "name": "Fake Silo",
                                                                 "protocol": 6, "capabilities": ["computers.*", "operations.*"]]])
        case "events.subscribe":
            subscriptionCount += 1
            let subscription = "sub-\(subscriptionCount)"
            try? socket.write(["id": request.id, "result": ["subscription": subscription]])
            if subscriptionCount == 1 {
                for event in Self.sampleEvents(subscription: subscription) { try? socket.write(event) }
            }
        case "operations.job.get":
            if let previous = waitingJobReply {
                waitingJobReply = nil
                try? socket.write(Self.jobResult(id: request.id, jobId: request.jobId ?? ""))
                try? previous.socket.write(Self.jobResult(id: previous.request.id, jobId: previous.request.jobId ?? ""))
            } else {
                waitingJobReply = WaitingJobReply(request: request, socket: socket)
            }
        default:
            try? socket.write(["id": request.id, "result": NSNull()])
        }
    }

    private static func sampleEvents(subscription: String) -> [[String: Any]] {
        [
            ["event": "operations.job.progress", "subscription": subscription, "deviceId": "device-1", "seq": 1,
             "payload": ["jobId": "job:123", "source": "lifecycle",
                         "data": ["computerId": "computer-1", "action": "start", "step": "boot"]]],
            ["event": "operations.job.finished", "subscription": subscription, "deviceId": "device-1", "seq": 2,
             "payload": ["jobId": "job:123", "result": ["answer": 42]]],
            ["event": "computers.changed", "subscription": subscription, "deviceId": "device-1", "seq": 4,
             "payload": ["linux": ["activities": [], "computers": [], "github": NSNull(),
                                      "repositoryPushOperations": [], "secrets": []]]],
        ]
    }

    private static func jobResult(id: String, jobId: String) -> [String: Any] {
        ["id": id, "result": ["jobId": jobId, "state": "finished", "outcome": ["result": ["answer": 42]]]]
    }
}
