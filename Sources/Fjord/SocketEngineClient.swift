import Darwin
import Foundation

private enum SocketClientFailure: LocalizedError, Sendable {
    case socket(String)
    case frameTooLarge
    case malformed(String)
    case closed
    case incompatibleVersion(Int, SiloWireProtocolRange)
    case remote(String, String)

    var errorDescription: String? {
        switch self {
        case .socket(let message): message
        case .frameTooLarge: "The Silo frame exceeds the 4 MiB limit."
        case .malformed(let message): "Invalid Silo response: \(message)"
        case .closed: "The Silo socket is closed."
        case .incompatibleVersion(let version, let range):
            "Silo negotiated protocol \(version), outside Fjord's supported range \(range.min)…\(range.max)."
        case .remote(_, let message): message
        }
    }

    var engineError: Error {
        switch self {
        case .remote(let code, let message):
            switch code {
            case "not_found": EngineClientError.notFound(message)
            case "unsupported_remote_operation", "incompatible_version": EngineClientError.unsupported(message)
            case "changed", "already_queued", "busy": EngineClientError.invalidAction(message)
            case _ where EngineErrorText.known.contains(code): EngineClientError.coded(code: code, message: message)
            default: EngineClientError.jobFailed(message)
            }
        case .incompatibleVersion(_, _): EngineClientError.unsupported(errorDescription ?? "Incompatible Silo protocol.")
        default: self
        }
    }
}

private final class UnixDomainSocket: @unchecked Sendable {
    private static let maximumFrameBytes = 4 * 1024 * 1024
    private let descriptor: Int32
    private let writerQueue = DispatchQueue(label: "fjord.silo.socket.writer", qos: .utility)

    init(path: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.systemFailure("create socket") }
        descriptor = fd

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < pathCapacity else {
            Darwin.close(fd)
            throw SocketClientFailure.socket("Unix socket path is too long.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        pathBytes.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.initializeMemory(as: UInt8.self, repeating: 0)
                destination.copyBytes(from: source)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let failure = Self.systemFailure("connect \(path)")
            Darwin.close(fd)
            throw failure
        }
    }

    deinit { Darwin.close(descriptor) }

    func shutdown() { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }

    func writeFrame(_ json: Data, completion: @escaping @Sendable (Result<Void, SocketClientFailure>) -> Void) {
        writerQueue.async { [self] in
            do {
                try writeFrameBlocking(json)
                completion(.success(()))
            } catch let error as SocketClientFailure {
                completion(.failure(error))
            } catch {
                completion(.failure(.socket(error.localizedDescription)))
            }
        }
    }

    private func writeFrameBlocking(_ json: Data) throws {
        guard !json.isEmpty, json.count <= Self.maximumFrameBytes else { throw SocketClientFailure.frameTooLarge }
        let length = UInt32(json.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        frame.append(json)
        try frame.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(descriptor, base.advanced(by: offset), buffer.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Self.systemFailure("write frame")
                }
                guard written > 0 else { throw SocketClientFailure.closed }
                offset += written
            }
        }
    }

    func readFrame() throws -> Data? {
        guard let header = try readExactly(4, allowEOF: true) else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= Self.maximumFrameBytes else { throw SocketClientFailure.frameTooLarge }
        return try readExactly(Int(length), allowEOF: false)
    }

    private func readExactly(_ length: Int, allowEOF: Bool) throws -> Data? {
        var data = Data(count: length)
        var received = 0
        var reachedEOF = false
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while received < length {
                let amount = Darwin.recv(descriptor, base.advanced(by: received), length - received, 0)
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw Self.systemFailure("read frame")
                }
                if amount == 0 { reachedEOF = true; break }
                received += amount
            }
        }
        if reachedEOF {
            if allowEOF && received == 0 { return nil }
            throw SocketClientFailure.socket("The Silo socket closed inside a frame.")
        }
        return data
    }

    private static func systemFailure(_ operation: String) -> SocketClientFailure {
        .socket("\(operation): \(String(cString: strerror(errno)))")
    }
}

private struct SocketRequestFrame<Params: Encodable & Sendable>: Encodable {
    let id: String
    let method: String
    let params: Params
}

private struct SocketResponseFrame: Decodable {
    let id: String
    let result: SiloJSONValue?
    let error: SiloWireErrorObject?

    private enum CodingKeys: String, CodingKey { case id, result, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        error = try container.decodeIfPresent(SiloWireErrorObject.self, forKey: .error)
        result = container.contains(.result) ? try container.decode(SiloJSONValue.self, forKey: .result) : nil
    }
}

private actor SocketRequestTransport {
    private let socket: UnixDomainSocket
    private var readerTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var cancelledResponseIDs = Set<String>()
    private var cancelledResponseOrder: [String] = []
    private var pendingWrites = 0
    private var closed = false
    private var eventHandler: (@Sendable (SiloWireEventEnvelope) -> Void)?
    private var disconnectHandler: (@Sendable (String) -> Void)?

    init(path: String) throws { socket = try UnixDomainSocket(path: path) }

    func setEventHandler(_ handler: @escaping @Sendable (SiloWireEventEnvelope) -> Void) {
        eventHandler = handler
    }

    func setDisconnectHandler(_ handler: @escaping @Sendable (String) -> Void) {
        disconnectHandler = handler
    }

    func start() {
        guard readerTask == nil else { return }
        let socket = self.socket
        // The blocking reads on a thread of their own, never on Swift's cooperative pool: it has a thread per core, and one
        // held in `recv` for the connection's life is one fewer for everything else (on a three-core machine, with two
        // more held elsewhere, the task that would have answered never ran). The frames come back in order through a stream.
        let (frames, sink) = AsyncThrowingStream.makeStream(of: Data.self)
        let reader = Thread {
            do {
                while let frame = try socket.readFrame() { sink.yield(frame) }
                sink.finish(throwing: SocketClientFailure.closed)
            } catch {
                sink.finish(throwing: error)
            }
        }
        reader.name = "fjord.silo.socket.reader"
        reader.qualityOfService = .utility
        reader.start()
        readerTask = Task.detached(priority: .utility) { [weak self] in
            do {
                for try await frame in frames { await self?.receive(frame) }
                // Cancelled (`close`): the socket is shut down, and the reader ends on its own.
                throw SocketClientFailure.closed
            } catch {
                await self?.connectionFailed(error)
            }
        }
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ call: SiloGeneratedMethodCall<Params, Result>
    ) async throws -> Result {
        guard !closed else { throw SocketClientFailure.closed }
        try Task.checkCancellation()
        let id = UUID().uuidString.lowercased()
        let request = try JSONEncoder().encode(SocketRequestFrame(id: id, method: call.name, params: call.params))
        do {
            let responseData = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pending[id] = continuation
                    pendingWrites += 1
                    socket.writeFrame(request) { [weak self] result in
                        Task { await self?.writeCompleted(result: result) }
                    }
                }
            } onCancel: { [weak self] in
                Task { await self?.cancelPending(id: id) }
            }
            try Task.checkCancellation()
            let response = try JSONDecoder().decode(SocketResponseFrame.self, from: responseData)
            guard response.id == id else { throw SocketClientFailure.malformed("response id did not match request") }
            guard !(response.error != nil && response.result != nil) else {
                throw SocketClientFailure.malformed("response included both result and error")
            }
            if let error = response.error { throw SocketClientFailure.remote(error.code.rawValue, error.message) }
            guard let result = response.result else { throw SocketClientFailure.malformed("response omitted result") }
            let resultData = try JSONEncoder().encode(result)
            return try JSONDecoder().decode(Result.self, from: resultData)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func disconnect() async throws {
        guard !closed else { return }
        guard pendingWrites == 0 else {
            close()
            return
        }
        do {
            let _: SiloNull = try await request(SiloGeneratedMethods.engineDisconnect([:]))
            close()
        } catch {
            close()
            throw error
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        readerTask = nil
        socket.shutdown()
        failPending(SocketClientFailure.closed)
    }

    private func receive(_ frame: Data) {
        guard !closed else { return }
        do {
            let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any]
            if object?["event"] != nil {
                let envelope = try JSONDecoder().decode(SiloWireEventEnvelope.self, from: frame)
                eventHandler?(envelope)
            } else {
                let response = try JSONDecoder().decode(SocketResponseFrame.self, from: frame)
                if let continuation = pending.removeValue(forKey: response.id) {
                    continuation.resume(returning: frame)
                } else {
                    if cancelledResponseIDs.remove(response.id) != nil {
                        cancelledResponseOrder.removeAll { $0 == response.id }
                    }
                }
            }
        } catch {
            connectionFailed(error)
        }
    }

    private func connectionFailed(_ error: Error) {
        guard !closed else { return }
        closed = true
        socket.shutdown()
        failPending(error)
        disconnectHandler?(error.localizedDescription)
    }

    private func failPending(_ error: Error) {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func writeCompleted(result: Result<Void, SocketClientFailure>) {
        pendingWrites = max(0, pendingWrites - 1)
        if case .failure(let error) = result { connectionFailed(error) }
    }

    private func cancelPending(id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        cancelledResponseIDs.insert(id)
        cancelledResponseOrder.append(id)
        if cancelledResponseOrder.count > 256 {
            let expired = cancelledResponseOrder.removeFirst()
            cancelledResponseIDs.remove(expired)
        }
        continuation.resume(throwing: CancellationError())
    }
}

/// A debug-selectable Unix-socket implementation. It performs `engine.handshake` before
/// issuing any other request and reconnects with fresh subscriptions after socket loss.
@MainActor
final class SocketEngineClient: EngineClient {
    static let defaultProtocolRange = SiloWireProtocolRange(max: 6, min: 6)
    static var defaultSocketPath: String {
        AppIdentity.engineSocketPath()
    }

    private struct Subscription {
        let events: [String]
        let handler: @MainActor (EngineEventDelivery) -> Void
        var serverId: String?
        var sequence: UInt64?
    }

    private struct ConnectionAttempt {
        let id: UUID
        let task: Task<SocketRequestTransport, Error>
    }

    private let path: String
    private let protocolRange: SiloWireProtocolRange
    private var transport: SocketRequestTransport?
    private var openingTransport: (generation: UInt64, transport: SocketRequestTransport)?
    private var connectionAttempt: ConnectionAttempt?
    private var reconnectTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var shouldResync = false
    private var restoringGeneration: UInt64?
    private var explicitlyDisconnected = false
    private var subscriptions: [String: Subscription] = [:]
    private var subscriptionByServerId: [String: String] = [:]
    private var unmatchedEvents: [SiloWireEventEnvelope] = []
    private var restorationEvents: [(UInt64, SiloWireEventEnvelope)] = []
    private(set) var handshakeResult: SiloWireHandshakeResult?

    init(path: String? = nil, protocolRange: SiloWireProtocolRange = SiloWireProtocolRange(max: 6, min: 6)) {
        self.path = path ?? Self.defaultSocketPath
        self.protocolRange = protocolRange
    }

    /// Opens the Unix socket and completes `engine.handshake` without issuing a domain request.
    func connect() async throws -> SiloWireHandshakeResult {
        _ = try await ensureTransport()
        guard let handshakeResult else { throw EngineClientError.unavailable }
        return handshakeResult
    }

    func updatesState() async throws -> SiloWireUpdateSnapshot {
        try await invoke(SiloGeneratedMethods.updatesState(SiloWireEmptyParams()))
    }

    func deviceFactsRead(deviceId: String?) async throws -> DeviceFacts {
        let wire = try await invoke(SiloGeneratedMethods.deviceFacts(SiloWireDeviceParams(deviceId: deviceId)))
        return DeviceFacts(
            deviceCapacity: wire.deviceCapacity.map {
                DeviceCapacity(logicalCpus: $0.logicalCpus, physicalMemoryBytes: $0.physicalMemoryBytes,
                               maxMemoryGib: Int(exactly: $0.maxMemoryGib) ?? Int.max)
            },
            macosHostLimits: wire.macosHostLimits.map {
                MacosHostLimits(cpus: Int(exactly: $0.cpus) ?? Int.max, memory_gib: Int(exactly: $0.memoryGib) ?? Int.max)
            },
            remoteLogin: wire.remoteLogin)
    }

    func computersList(deviceId: String?) async throws -> ComputerInventory {
        try await invoke(SiloGeneratedMethods.computersList(SiloWireComputerListParams(deviceId: deviceId)))
    }

    func connectionsDevicesList() async throws -> [SiloWireDevice] {
        try await invoke(SiloGeneratedMethods.connectionsDevicesList([:]))
    }

    func computersCreate(_ request: ComputerCreateRequest) async throws -> ComputerCreateResult {
        let wireRequest: SiloWireMacosComputerCreateRequest?
        if let value = request.request {
            guard let cpus = UInt64(exactly: value.cpus), let memory = UInt64(exactly: value.memoryGiB),
                  let disk = UInt64(exactly: value.diskGiB) else {
                throw EngineClientError.invalidAction("macOS computer limits must be nonnegative integers.")
            }
            wireRequest = SiloWireMacosComputerCreateRequest(cpus: cpus, diskGiB: disk, memoryGiB: memory, name: value.name)
        } else {
            wireRequest = nil
        }
        let params = SiloWireComputerCreateParams(configuration: request.configuration, deviceId: request.deviceId,
                                                   kind: request.kind, requestId: request.requestId, request: wireRequest)
        return try await invoke(SiloGeneratedMethods.computersCreate(params))
    }

    func computersStart(_ reference: ComputerReference) async throws -> ComputerJob {
        try await invoke(SiloGeneratedMethods.computersStart(reference))
    }

    func computersStop(_ reference: ComputerReference) async throws -> ComputerJob {
        try await invoke(SiloGeneratedMethods.computersStop(reference))
    }

    func computersForceStop(_ reference: ComputerReference) async throws {
        let _: SiloNull = try await invoke(SiloGeneratedMethods.computersForceStop(reference))
    }

    func computersDelete(_ request: ComputerDeleteRequest) async throws -> ComputerJob {
        try await invoke(SiloGeneratedMethods.computersDelete(request))
    }

    func computersConfigurationRead(deviceId: String?) async throws -> ComputerConfigurationRequest {
        try await invoke(SiloGeneratedMethods.computersConfigurationRead(SiloWireDeviceParams(deviceId: deviceId)))
    }

    func checkpointsList(computerId: String, deviceId: String?) async throws -> [ComputerCheckpoint] {
        let inventory = try await computersList(deviceId: deviceId)
        guard let row = inventory.computer(computerId) else { throw EngineClientError.notFound("This computer no longer exists.") }
        return row.checkpoints
    }

    func checkpointsCreate(_ request: CheckpointCreateRequest) async throws -> ComputerJob {
        try await invoke(SiloGeneratedMethods.checkpointsCreate(request))
    }

    func checkpointsRestore(_ request: CheckpointRestoreRequest) async throws -> ComputerJob {
        try await invoke(SiloGeneratedMethods.checkpointsRestore(request))
    }

    func checkpointsFork(_ request: CheckpointForkRequest) async throws -> ComputerJob {
        try await invoke(SiloGeneratedMethods.checkpointsFork(request))
    }

    func checkpointsDelete(_ request: CheckpointDeleteRequest) async throws -> ComputerJob {
        try await invoke(SiloGeneratedMethods.checkpointsDelete(request))
    }

    func displayShow(_ reference: ComputerReference) async throws {
        let _: SiloNull = try await invoke(SiloGeneratedMethods.displayShow(reference))
    }

    func operationsList(deviceId: String?) async throws -> OperationsList {
        let queue = try await invoke(SiloGeneratedMethods.operationsList(SiloWireOperationsListParams(deviceId: deviceId)))
        return OperationsList(running: queue.running.map(Self.projectQueueEntry),
                              waiting: queue.waiting.map(Self.projectQueueEntry),
                              unacknowledgedJobIds: queue.unacknowledgedJobIds)
    }

    func operationsJobGet(jobId: String, deviceId: String?) async throws -> OperationJobSnapshot {
        let result = try await invoke(SiloGeneratedMethods.operationsJobGet(SiloWireGetJobParams(deviceId: deviceId, jobId: jobId)))
        var outcome = result.outcome
        if outcome == nil, let first = result.outcomeChunk {
            // A retained outcome too large for one response comes as slices of its JSON; read them all.
            var bytes = Data(first.data.utf8)
            var chunk = first
            while let next = chunk.nextOffsetBytes, next > chunk.offsetBytes, next < chunk.totalBytes {
                let more = try await invoke(SiloGeneratedMethods.operationsJobGet(
                    SiloWireGetJobParams(deviceId: deviceId, jobId: jobId, offsetBytes: next)))
                guard let following = more.outcomeChunk else { break }
                bytes.append(Data(following.data.utf8))
                chunk = following
            }
            outcome = try JSONDecoder().decode(SiloWireJobOutcome.self, from: bytes)
        }
        return OperationJobSnapshot(jobId: result.jobId, state: OperationJobState(rawValue: result.state.rawValue) ?? .running,
                                     outcome: outcome.map {
                                         OperationJobOutcome(result: $0.result, error: $0.error.map(Self.projectError))
                                     })
    }

    func operationsCancel(jobId: String, deviceId: String?) async throws {
        let _: SiloNull = try await invoke(SiloGeneratedMethods.operationsCancel(SiloWireCancelJobParams(deviceId: deviceId, jobId: jobId)))
    }

    func eventsSubscribe(events: [String], deviceIds: [String],
                         handler: @escaping @MainActor (EngineEventDelivery) -> Void) async throws -> String {
        let result = try await invoke(SiloGeneratedMethods.eventsSubscribe(
            SiloWireEventsSubscribeParams(deviceIds: deviceIds.isEmpty ? nil : deviceIds, events: events)))
        let localId = UUID().uuidString.lowercased()
        subscriptions[localId] = Subscription(events: events, handler: handler, serverId: result.subscription, sequence: nil)
        subscriptionByServerId[result.subscription] = localId
        drainUnmatchedEvents(for: result.subscription)
        return localId
    }

    func eventsUnsubscribe(subscription: String) async {
        guard let entry = subscriptions.removeValue(forKey: subscription) else { return }
        if let serverId = entry.serverId {
            subscriptionByServerId.removeValue(forKey: serverId)
            guard let transport = transport ?? openingTransport?.transport else { return }
            let params = SiloWireEventsUnsubscribeParams(subscription: serverId)
            let call = SiloGeneratedMethods.eventsUnsubscribe(params)
            do { let _: SiloNull = try await transport.request(call) } catch { }
        }
    }

    func operationsJobAcknowledge(jobId: String, deviceId: String?) async throws {
        let params = SiloWireAcknowledgeJobParams(deviceId: deviceId, jobId: jobId)
        let _: SiloNull = try await invoke(SiloGeneratedMethods.operationsJobAcknowledge(params))
    }

    func engineDisconnect() async throws {
        explicitlyDisconnected = true
        connectionGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionAttempt?.task.cancel()
        connectionAttempt = nil
        let opening = openingTransport
        openingTransport = nil
        if let opening { await opening.transport.close() }
        guard let transport else { return }
        do {
            try await transport.disconnect()
            self.transport = nil
        } catch {
            await transport.close()
            self.transport = nil
            throw Self.map(error)
        }
    }

    func guestAccount(_ params: SiloWireGuestAccountParams) async throws -> SiloWireGuestAccount {
        try await invokeGuest(SiloGeneratedMethods.guestAccount(params))
    }

    func guestExec(_ params: SiloWireGuestExecParams) async throws -> SiloWireGuestExecResult {
        try await invokeGuest(SiloGeneratedMethods.guestExec(params))
    }

    func guestExecStart(_ params: SiloWireGuestExecStartParams) async throws -> SiloWireJobStartResult {
        try await invokeGuest(SiloGeneratedMethods.guestExecStart(params))
    }

    func guestExecGet(_ params: SiloWireGuestExecGetParams) async throws -> SiloWireGuestExecGetResult {
        try await invokeGuest(SiloGeneratedMethods.guestExecGet(params))
    }

    func guestFilesList(_ params: SiloWireGuestFilesListParams) async throws -> SiloWireGuestFilesListResult {
        try await invokeGuest(SiloGeneratedMethods.guestFilesList(params), path: params.path)
    }

    func guestFilesRead(_ params: SiloWireGuestFilesReadParams) async throws -> SiloWireGuestFilesReadResult {
        try await invokeGuest(SiloGeneratedMethods.guestFilesRead(params), path: params.path)
    }

    func guestFilesRemove(_ params: SiloWireGuestFilesRemoveParams) async throws -> SiloWireGuestFilesRemoveResult {
        try await invokeGuest(SiloGeneratedMethods.guestFilesRemove(params), path: params.paths.first)
    }

    func guestFilesWatch(_ params: SiloWireGuestFilesWatchParams) async throws -> SiloWireGuestFilesWatchResult {
        try await invokeGuest(SiloGeneratedMethods.guestFilesWatch(params), path: params.paths.first)
    }

    func guestFilesWrite(_ params: SiloWireGuestFilesWriteParams) async throws -> SiloWireGuestFilesWriteResult {
        try await invokeGuest(SiloGeneratedMethods.guestFilesWrite(params), path: params.path)
    }

    func guestSSHAliasEnsure(_ params: SiloWireGuestSshAliasEnsureParams) async throws -> SiloWireGuestSshAliasEnsureResult {
        try await invokeGuest(SiloGeneratedMethods.guestSshAliasEnsure(params))
    }

    func guestSSHAliasRemove(_ params: SiloWireComputerTargetParams) async throws {
        let _: SiloNull = try await invokeGuest(SiloGeneratedMethods.guestSshAliasRemove(params))
    }

    func invoke<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ call: SiloGeneratedMethodCall<Params, Result>
    ) async throws -> Result {
        do {
            try Task.checkCancellation()
            let activeTransport = try await ensureTransport()
            guard !explicitlyDisconnected else { throw SocketClientFailure.closed }
            try Task.checkCancellation()
            let result = try await activeTransport.request(call)
            guard !explicitlyDisconnected else { throw SocketClientFailure.closed }
            try Task.checkCancellation()
            return result
        }
        catch { throw Self.map(error) }
    }

    private func invokeGuest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ call: SiloGeneratedMethodCall<Params, Result>, path: String? = nil
    ) async throws -> Result {
        do {
            try Task.checkCancellation()
            let activeTransport = try await ensureTransport()
            guard !explicitlyDisconnected else { throw SocketClientFailure.closed }
            try Task.checkCancellation()
            let result = try await activeTransport.request(call)
            guard !explicitlyDisconnected else { throw SocketClientFailure.closed }
            try Task.checkCancellation()
            return result
        } catch let failure as SocketClientFailure {
            if case .remote(let code, let message) = failure {
                switch code {
                case "not_found": throw GuestClientFailure.notFound(path ?? message)
                case "not_a_file": throw GuestClientFailure.notAFile(path ?? message)
                case "exists": throw GuestClientFailure.exists(path ?? message)
                case "changed": throw GuestClientFailure.changed(path ?? message)
                case "permission_denied": throw GuestClientFailure.permissionDenied(path ?? message)
                case "not_running": throw GuestClientFailure.notRunning(message)
                default: throw GuestClientFailure.unavailable(message)
                }
            }
            throw Self.map(failure)
        } catch {
            throw Self.map(error)
        }
    }

    private func ensureTransport() async throws -> SocketRequestTransport {
        guard !explicitlyDisconnected else { throw SocketClientFailure.closed }
        if let transport { return transport }
        if let attempt = connectionAttempt {
            let opened = try await attempt.task.value
            guard !explicitlyDisconnected, transport === opened else { throw SocketClientFailure.closed }
            if connectionAttempt?.id == attempt.id { connectionAttempt = nil }
            return opened
        }
        guard protocolRange.min <= protocolRange.max else {
            throw EngineClientError.invalidAction("The supported Silo protocol range is invalid.")
        }
        let attempt = ConnectionAttempt(id: UUID(), task: Task { @MainActor in try await self.openTransport() })
        connectionAttempt = attempt
        do {
            let opened = try await attempt.task.value
            if connectionAttempt?.id == attempt.id { connectionAttempt = nil }
            guard !explicitlyDisconnected, transport === opened else { throw SocketClientFailure.closed }
            return opened
        } catch {
            if connectionAttempt?.id == attempt.id { connectionAttempt = nil }
            throw Self.map(error)
        }
    }

    private func openTransport() async throws -> SocketRequestTransport {
        let candidate = try SocketRequestTransport(path: path)
        connectionGeneration &+= 1
        let generation = connectionGeneration
        openingTransport = (generation, candidate)
        await candidate.setEventHandler { [weak self] envelope in
            Task { @MainActor [weak self] in self?.receive(envelope, generation: generation) }
        }
        guard connectionIsCurrent(generation) else { throw SocketClientFailure.closed }
        await candidate.setDisconnectHandler { [weak self] reason in
            Task { @MainActor [weak self] in self?.connectionLost(reason, generation: generation) }
        }
        guard connectionIsCurrent(generation) else { throw SocketClientFailure.closed }
        await candidate.start()
        guard connectionIsCurrent(generation) else { throw SocketClientFailure.closed }
        do {
            let params = SiloWireHandshakeParams(
                client: SiloWireClientMetadata(name: "Fjord", version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"),
                handshakeParamsProtocol: protocolRange)
            let result = try await candidate.request(SiloGeneratedMethods.engineHandshake(params))
            guard connectionIsCurrent(generation) else { throw SocketClientFailure.closed }
            guard (protocolRange.min...protocolRange.max).contains(result.handshakeResultProtocol) else {
                throw SocketClientFailure.incompatibleVersion(result.handshakeResultProtocol, protocolRange)
            }
            if shouldResync {
                restoringGeneration = generation
                do {
                    try await restoreSubscriptions(on: candidate, generation: generation)
                } catch {
                    if restoringGeneration == generation { restoringGeneration = nil }
                    restorationEvents.removeAll { $0.0 == generation }
                    throw error
                }
            }
            guard connectionIsCurrent(generation) else { throw SocketClientFailure.closed }
            handshakeResult = result
            transport = candidate
            if openingTransport?.generation == generation { openingTransport = nil }
            return candidate
        } catch {
            if openingTransport?.generation == generation { openingTransport = nil }
            if transport === candidate { transport = nil }
            if connectionGeneration == generation { connectionGeneration &+= 1 }
            subscriptionByServerId.removeAll()
            unmatchedEvents.removeAll()
            restorationEvents.removeAll { $0.0 == generation }
            if restoringGeneration == generation { restoringGeneration = nil }
            for id in Array(subscriptions.keys) {
                guard var subscription = subscriptions[id] else { continue }
                subscription.serverId = nil
                subscription.sequence = nil
                subscriptions[id] = subscription
            }
            await candidate.close()
            throw Self.map(error)
        }
    }

    private func restoreSubscriptions(on candidate: SocketRequestTransport, generation: UInt64) async throws {
        subscriptionByServerId.removeAll()
        for localId in subscriptions.keys.sorted() {
            guard generation == connectionGeneration, !explicitlyDisconnected else { throw SocketClientFailure.closed }
            guard let subscription = subscriptions[localId] else { continue }
            let params = SiloWireEventsSubscribeParams(events: subscription.events)
            let response = try await candidate.request(SiloGeneratedMethods.eventsSubscribe(params))
            guard connectionIsCurrent(generation) else { throw SocketClientFailure.closed }
            guard var current = subscriptions[localId] else {
                await unsubscribe(response.subscription, on: candidate)
                guard connectionIsCurrent(generation) else { throw SocketClientFailure.closed }
                continue
            }
            current.serverId = response.subscription
            current.sequence = nil
            subscriptions[localId] = current
            subscriptionByServerId[response.subscription] = localId
        }
        if shouldResync {
            shouldResync = false
            for subscription in subscriptions.values { subscription.handler(.reconnected) }
        }
        let events = restorationEvents.filter { $0.0 == generation }.map(\.1)
        restorationEvents.removeAll { $0.0 == generation }
        if restoringGeneration == generation { restoringGeneration = nil }
        for event in events {
            if let localId = subscriptionByServerId[event.subscription] {
                deliver(event, to: localId)
            } else {
                unmatchedEvents.append(event)
            }
        }
        let serverIds = Set(subscriptionByServerId.keys)
        for id in serverIds { drainUnmatchedEvents(for: id) }
    }

    private func connectionLost(_ reason: String, generation: UInt64) {
        guard generation == connectionGeneration, !explicitlyDisconnected else { return }
        transport = nil
        subscriptionByServerId.removeAll()
        unmatchedEvents.removeAll()
        shouldResync = true
        for id in Array(subscriptions.keys) {
            guard var subscription = subscriptions[id] else { continue }
            subscription.serverId = nil
            subscription.sequence = nil
            subscriptions[id] = subscription
            subscription.handler(.disconnected(reason))
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, !explicitlyDisconnected else { return }
        reconnectTask = Task { @MainActor [weak self] in
            var delay: Int64 = 200
            while let self, !Task.isCancelled, !self.explicitlyDisconnected {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                    _ = try await self.ensureTransport()
                    self.reconnectTask = nil
                    return
                } catch {
                    delay = min(delay * 2, 5_000)
                }
            }
            self?.reconnectTask = nil
        }
    }

    private func connectionIsCurrent(_ generation: UInt64) -> Bool {
        !explicitlyDisconnected && generation == connectionGeneration
    }

    private func unsubscribe(_ serverId: String, on candidate: SocketRequestTransport) async {
        let params = SiloWireEventsUnsubscribeParams(subscription: serverId)
        do { let _: SiloNull = try await candidate.request(SiloGeneratedMethods.eventsUnsubscribe(params)) } catch { }
    }

    private func receive(_ envelope: SiloWireEventEnvelope, generation: UInt64) {
        guard generation == connectionGeneration, !explicitlyDisconnected else { return }
        if restoringGeneration == generation {
            restorationEvents.append((generation, envelope))
            if restorationEvents.count > 256 { restorationEvents.removeFirst(restorationEvents.count - 256) }
            return
        }
        guard let localId = subscriptionByServerId[envelope.subscription] else {
            unmatchedEvents.append(envelope)
            if unmatchedEvents.count > 128 { unmatchedEvents.removeFirst(unmatchedEvents.count - 128) }
            return
        }
        deliver(envelope, to: localId)
    }

    private func drainUnmatchedEvents(for serverId: String) {
        let events = unmatchedEvents.filter { $0.subscription == serverId }
        unmatchedEvents.removeAll { $0.subscription == serverId }
        for event in events {
            if let localId = subscriptionByServerId[serverId] { deliver(event, to: localId) }
        }
    }

    private func deliver(_ envelope: SiloWireEventEnvelope, to localId: String) {
        guard var subscription = subscriptions[localId] else { return }
        if let previous = subscription.sequence {
            guard envelope.seq > previous else { return }
            if envelope.seq != previous &+ 1 {
                subscription.sequence = envelope.seq
                subscriptions[localId] = subscription
                subscription.handler(.reconnected)
                return
            }
        }
        subscription.sequence = envelope.seq
        subscriptions[localId] = subscription
        guard let event = Self.projectEvent(envelope) else {
            subscription.handler(.sequenceAdvanced(sequence: envelope.seq))
            return
        }
        subscription.handler(.event(sequence: envelope.seq, event: event))
    }

    private static func projectEvent(_ envelope: SiloWireEventEnvelope) -> EngineEvent? {
        if envelope.event == .connectionsDevicesChanged { return .connectionsDevicesChanged }
        guard let payload = envelope.payload, let data = try? JSONEncoder().encode(payload) else { return nil }
        let decoder = JSONDecoder()
        switch envelope.event {
        case .computersChanged:
            guard let value = try? decoder.decode(ComputersChangedPayload.self, from: data) else { return nil }
            return .computersChanged(value, deviceId: envelope.deviceId)
        case .checkpointsChanged:
            guard let value = try? decoder.decode(CheckpointsChangedPayload.self, from: data) else { return nil }
            return .checkpointsChanged(value, deviceId: envelope.deviceId)
        case .operationsQueueChanged:
            guard let value = try? decoder.decode(SiloWireOperationQueue.self, from: data) else { return nil }
            return .operationsQueueChanged(OperationsList(
                running: value.running.map(projectQueueEntry), waiting: value.waiting.map(projectQueueEntry),
                unacknowledgedJobIds: value.unacknowledgedJobIds), deviceId: envelope.deviceId)
        case .operationsJobProgress:
            guard let value = try? decoder.decode(SiloWireJobProgress.self, from: data),
                  let progress = try? projectProgress(value) else { return nil }
            return .jobProgress(progress, deviceId: envelope.deviceId)
        case .operationsJobFinished:
            guard let value = try? decoder.decode(SiloWireJobFinished.self, from: data) else { return nil }
            return .jobFinished(OperationJobFinished(jobId: value.jobId, result: value.result,
                                                      error: value.error.map(projectError),
                                                      outcomeChunked: value.outcomeChunked), deviceId: envelope.deviceId)
        case .guestFilesChanged:
            guard let value = try? decoder.decode(SiloWireGuestFilesChangedPayload.self, from: data) else { return nil }
            return .guestFilesChanged(deviceId: envelope.deviceId, payload: value)
        case .settingsChanged:
            guard let value = try? decoder.decode(SiloWireSettingsSnapshot.self, from: data) else { return nil }
            return .settingsChanged(value)
        case .exportsChanged:
            guard let value = try? decoder.decode(SiloWireBackupState.self, from: data) else { return nil }
            return .exportsChanged(value)
        case .displayViewerPage:
            guard let value = try? decoder.decode(SiloWireViewerPageEvent.self, from: data) else { return nil }
            return .viewerPage(value)
        default:
            return nil
        }
    }

    private static func projectProgress(_ wire: SiloWireJobProgress) throws -> OperationJobProgress {
        let source = JobProgressSource(rawValue: wire.source.rawValue) ?? .macos
        let data = wire.data
        let projection: OperationJobProgressData
        switch source {
        case .setup:
            let fraction = data.fraction.map { value in value > 1 ? Double(value) / 100 : Double(value) }
            projection = .setup(SetupJobProgressData(
                schemaVersion: data.schemaVersion ?? 1, type: data.type ?? "computer-configuration",
                requestId: data.requestId ?? wire.jobId, phase: data.phase ?? "", step: data.step ?? "",
                computer: data.computer, fraction: fraction, message: data.message ?? "",
                safeForDisplay: data.safeForDisplay ?? true, timestamp: String(data.timestamp ?? 0),
                level: data.level ?? "info", elapsedSeconds: Double(data.elapsedSeconds ?? 0),
                downloadedBytes: data.downloadedBytes, totalBytes: data.totalBytes,
                failureCode: data.failureCode, exitCode: data.exitCode.map { Int($0) },
                diagnostic: data.diagnostic, partial: data.partial ?? false))
        case .lifecycle:
            projection = .lifecycle(LifecycleJobProgressData(computerId: data.computerId ?? wire.computerId ?? "",
                                                              action: data.action ?? "", step: data.step ?? ""))
        case .transfer:
            projection = .transfer(TransferJobProgressData(
                id: data.id ?? wire.jobId, computer: data.computer ?? wire.computerId ?? "",
                direction: data.direction?.rawValue ?? "download", state: data.state?.rawValue ?? "transferring",
                name: data.name ?? "", fileIndex: UInt64(max(0, data.fileIndex ?? 0)),
                fileCount: UInt64(max(0, data.fileCount ?? 0)), bytesDone: data.bytesDone ?? 0,
                bytesTotal: data.bytesTotal ?? 0))
        case .backup:
            let archive = data.archive
            let phase = data.phases?.map { BackupJobProgressPhase(title: $0.title, detail: $0.detail, tone: $0.tone) } ?? []
            projection = .backup(BackupJobProgressData(
                operation: data.operation?.rawValue ?? wire.jobId,
                archive: BackupJobProgressArchive(name: archive?.name ?? "backup", archivePath: archive?.archivePath ?? "",
                                                  completedLabel: archive?.completedLabel ?? "Backup",
                                                  size: UInt64(archive?.size ?? "") ?? 0,
                                                  destination: archive?.destination ?? "", computers: archive?.computers ?? [],
                                                  checkpointName: archive?.checkpointName),
                runningNames: data.runningNames ?? [], targetName: data.targetName,
                progress: UInt8(max(0, min(100, numericProgress(data.progress) ?? 0))),
                indeterminate: data.indeterminate, canCancel: data.canCancel, phases: phase))
        case .push:
            let target = data.target.flatMap(encodeJSONValue) ?? .null
            projection = .push(PushJobProgressData(
                operationId: data.operationId ?? wire.jobId, computer: data.computer ?? wire.computerId ?? "",
                repositoryPath: data.repositoryPath ?? "", status: data.status?.rawValue ?? "unknown",
                commitCount: Int(exactly: data.commitCount ?? 0) ?? Int.max, message: data.message, target: target))
        case .macos:
            projection = .macos(MacosJobProgressData(computerId: data.computerId ?? wire.computerId ?? "",
                                                      state: data.state?.rawValue ?? "running",
                                                      progress: numericProgress(data.progress), detail: data.detail,
                                                      checkpointOperation: data.checkpointOperation))
        case .update:
            projection = .update(UpdateJobProgressData(
                phase: data.phase ?? "", lastChecked: data.lastChecked, retryAction: data.retryAction,
                currentVersion: data.currentVersion ?? "", availableVersion: data.availableVersion,
                releaseNotes: data.releaseNotes, downloadedBytes: data.downloadedBytes, totalBytes: data.totalBytes,
                automaticChecks: data.automaticChecks ?? false, packageKind: data.packageKind ?? "",
                releaseUrl: data.releaseUrl ?? "", error: data.error, errorDetails: data.errorDetails,
                runningComputers: data.runningComputers ?? [], canInstall: data.canInstall ?? false,
                installBlockReason: data.installBlockReason))
        }
        return OperationJobProgress(jobId: wire.jobId, kind: wire.kind?.rawValue, computerId: wire.computerId,
                                    source: source, data: projection)
    }

    private static func numericProgress(_ value: SiloWireProgress?) -> Double? {
        switch value {
        case .double(let value): value
        case .integer(let value): Double(value)
        case .null, nil: nil
        }
    }

    private static func encodeJSONValue<Value: Encodable>(_ value: Value) -> SiloJSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(SiloJSONValue.self, from: data)
    }

    private static func projectQueueEntry(_ value: SiloWireOperationEntry) -> OperationQueueEntry {
        OperationQueueEntry(id: value.id, jobId: value.jobId, label: value.label, kind: value.kind.rawValue,
                            computerId: value.computerId, computerName: value.computerName, sinceMs: value.sinceMs,
                            cancellable: value.cancellable, expectedMs: value.expectedMs,
                            blockedByHidden: value.blockedByHidden ?? false)
    }

    private static func projectError(_ value: SiloWireErrorObject) -> OperationJobError {
        OperationJobError(code: value.code.rawValue, message: value.message)
    }

    private static func map(_ error: Error) -> Error {
        (error as? SocketClientFailure)?.engineError ?? error
    }
}
