import Foundation

struct GuestRelayRecord: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case inFlight, delivered, refused, unconfirmed }
    var id: UUID
    var location: SessionLocation
    var sessionID: String
    var nonce: String
    var createdAt: Date
    var state: State
    /// The one signed payload admitted, reused verbatim for retries so a retry cannot become a new task.
    var signedPayload: String?
    var body: String?
    var decisionID: UUID?
    var hostSessionID: String?

    init(id: UUID = UUID(), location: SessionLocation, sessionID: String, nonce: String,
         createdAt: Date = Date(), state: State = .inFlight, signedPayload: String? = nil, body: String? = nil,
         decisionID: UUID? = nil, hostSessionID: String? = nil) {
        self.id = id
        self.location = location
        self.sessionID = sessionID
        self.nonce = nonce
        self.createdAt = createdAt
        self.state = state
        self.signedPayload = signedPayload
        self.body = body
        self.decisionID = decisionID
        self.hostSessionID = hostSessionID
    }
}

/// Sends a signed relay message into the guest inbox. The watch is subscribed before the atomic message write; every hint
/// causes a reread, and an uncertain timeout keeps the nonce so a retry can't invent a new delivery.
struct GuestRelayInbox: Sendable {
    enum Failure: LocalizedError, Equatable {
        case invalidMessage
        case duplicateNonce(String)
        case refused(String)
        case deliveryUnconfirmed(String)

        var errorDescription: String? {
            switch self {
            case .invalidMessage: "The guest message isn't signed for this session."
            case .duplicateNonce(let nonce): "This guest delivery already used nonce \(nonce). Fjord kept its earlier state."
            case .refused(let reason): "The guest plugin refused the message: \(reason)"
            case .deliveryUnconfirmed(let nonce): "Delivery is unconfirmed for nonce \(nonce). Fjord kept it and won't resend with a new nonce."
            }
        }
    }

    var client: any GuestClient
    var timeout: TimeInterval? = RelayInbox.wait
    var onState: @MainActor @Sendable (GuestRelayRecord) async -> Void = { _ in }

    func deliver(_ signedText: String, to sessionID: String, computer: GuestReference,
                 now: Date = Date(), decisionID: UUID? = nil, hostSessionID: String? = nil,
                 body: String? = nil, gate: (@MainActor @Sendable () -> String?)? = nil,
                 preflight: (@MainActor @Sendable () -> String?)? = nil) async throws -> String {
        guard let header = RelayInbox.header(of: signedText), header.target == sessionID,
              Self.safeSegment(sessionID), Self.safeSegment(header.nonce) else { throw Failure.invalidMessage }
        let account = try await client.account(for: computer)
        let paths = try GuestRouterPaths(home: account.home)
        let sessionFolder = GuestRouterPaths.join(paths.inbox, sessionID)
        let messagePath = GuestRouterPaths.join(sessionFolder, "\(header.nonce).msg")
        let ackPath = GuestRouterPaths.join(sessionFolder, "\(header.nonce).ack")
        let location = SessionLocation.computer(deviceId: computer.deviceId, computerId: computer.computerId)
        var receipt = GuestRelayRecord(location: location, sessionID: sessionID, nonce: header.nonce, createdAt: now,
            signedPayload: signedText, body: body, decisionID: decisionID, hostSessionID: hostSessionID)
        await onState(receipt)

        let watch = try await client.filesWatch(computer: computer, paths: [sessionFolder])
        do {
            func checkGate(_ check: (@MainActor @Sendable () -> String?)?) async throws {
                if let check, let refusal = await MainActor.run(body: check) {
                    receipt.state = .refused
                    await onState(receipt)
                    throw Failure.refused(refusal)
                }
            }
            try await checkGate(preflight ?? gate)
            if let ack = try await readAck(ackPath, computer: computer) {
                return try await finish(ack, computer: computer, messagePath: messagePath, ackPath: ackPath, receipt: receipt)
            }
            if try await messageExists(messagePath, payload: signedText, computer: computer) == false {
                // The reads above are awaited: what the gate saw before them may be gone (Discard, the Router turned off), so
                // it is asked again, and the task's cancellation looked at, right before the write.
                try Task.checkCancellation()
                try await checkGate(gate)
                let message = GuestFileWriteRequest(computer: computer, path: messagePath, data: Data(signedText.utf8), mode: 0o600,
                                                    createParents: true, replace: .never)
                do { _ = try await client.filesWrite(message) }
                catch GuestClientFailure.exists(_) {
                    guard try await messageExists(messagePath, payload: signedText, computer: computer) else {
                        throw Failure.duplicateNonce(header.nonce)
                    }
                }
            }
            if let ack = try await readAck(ackPath, computer: computer) {
                return try await finish(ack, computer: computer, messagePath: messagePath, ackPath: ackPath, receipt: receipt)
            }
            let ack = try await waitForAck(watch: watch, path: ackPath, computer: computer)
            return try await finish(ack, computer: computer, messagePath: messagePath, ackPath: ackPath, receipt: receipt)
        } catch is CancellationError {
            receipt.state = .unconfirmed
            await onState(receipt)
            throw CancellationError()
        } catch is GuestRelayTimeout {
            if let late = try? await readAck(ackPath, computer: computer) {
                return try await finish(late, computer: computer, messagePath: messagePath, ackPath: ackPath, receipt: receipt)
            }
            receipt.state = .unconfirmed
            await onState(receipt)
            throw Failure.deliveryUnconfirmed(header.nonce)
        } catch let failure as Failure {
            if case .refused = failure {
                if receipt.state != .refused { receipt.state = .refused; await onState(receipt) }
                throw failure
            }
            receipt.state = .unconfirmed
            await onState(receipt)
            throw failure
        } catch {
            receipt.state = .unconfirmed
            await onState(receipt)
            throw Failure.deliveryUnconfirmed(header.nonce)
        }
    }

    func sweep(computer: GuestReference, sessionID: String, now: Date? = nil) async throws {
        guard Self.safeSegment(sessionID) else { return }
        let account = try await client.account(for: computer)
        let paths = try GuestRouterPaths(home: account.home)
        let folder = GuestRouterPaths.join(paths.inbox, sessionID)
        let entries = try await client.filesList(computer: computer, path: folder)
        let current: Int64
        if let now { current = Int64(now.timeIntervalSince1970 * 1000) }
        else { current = try await GuestClock.sampleMilliseconds(client: client, computer: computer, account: account) }
        let cutoff = current - Int64(RelayInbox.leftover * 1000)
        let stale = entries.filter { $0.type == .file && $0.mtimeMs < cutoff }
            .map { GuestRouterPaths.join(folder, $0.name) }
        if !stale.isEmpty { _ = try await client.filesRemove(computer: computer, paths: stale) }
    }

    private func waitForAck(watch: GuestFilesWatch, path: String, computer: GuestReference) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await event in watch.events {
                    let hint = event.path.hasSuffix("/") ? String(event.path.dropLast()) : event.path
                    let coversAcknowledgement = hint == path
                        || (hint == "/" ? path.hasPrefix("/") : path.hasPrefix(hint + "/"))
                    guard coversAcknowledgement else { continue }
                    if let ack = try await readAck(path, computer: computer) { return ack }
                }
                throw CancellationError()
            }
            if let timeout {
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw GuestRelayTimeout()
                }
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func readAck(_ path: String, computer: GuestReference) async throws -> String? {
        let read: GuestFileReadResult
        do { read = try await client.filesRead(computer: computer, path: path, offset: nil, length: nil) }
        catch GuestClientFailure.notFound(_) { return nil }
        guard let value = String(data: read.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func messageExists(_ path: String, payload: String, computer: GuestReference) async throws -> Bool {
        let read: GuestFileReadResult
        do { read = try await client.filesRead(computer: computer, path: path, offset: nil, length: nil) }
        catch GuestClientFailure.notFound(_) { return false }
        guard read.data == Data(payload.utf8) else {
            throw Failure.duplicateNonce(RelayInbox.header(of: payload)?.nonce ?? "unknown")
        }
        return true
    }

    private func finish(_ ack: String, computer: GuestReference, messagePath: String, ackPath: String,
                        receipt original: GuestRelayRecord) async throws -> String {
        _ = try? await client.filesRemove(computer: computer, paths: [messagePath, ackPath])
        var receipt = original
        if ack == "ok" || ack.hasPrefix("ok ") {
            receipt.state = .delivered
            await onState(receipt)
            return ack
        }
        receipt.state = .refused
        await onState(receipt)
        throw Failure.refused(ack.hasPrefix("refused: ") ? String(ack.dropFirst("refused: ".count)) : ack)
    }

    private static func safeSegment(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

private struct GuestRelayTimeout: Error {}

/// Reads the relay key from the guest, signs the existing v1/v2 wire format on the controller, and sends only through
/// guest.files. A timeout's record retains its nonce for a deliberate retry.
struct GuestRelayDelivery: Sendable {
    var client: any GuestClient
    var onState: @MainActor @Sendable (GuestRelayRecord) async -> Void = { _ in }
    var timeout: TimeInterval = RelayInbox.wait

    func send(body: String, to cliSessionID: String, computer: GuestReference, nonce: UUID = UUID(),
              now: Date? = nil) async throws -> String {
        let account = try await client.account(for: computer)
        let paths = try GuestRouterPaths(home: account.home)
        let keyFile = try await client.filesRead(computer: computer, path: paths.key, offset: nil, length: nil)
        guard let key = String(data: keyFile.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              key.count == 64, key.allSatisfy(\.isHexDigit) else {
            throw GuestClientFailure.permissionDenied(paths.key)
        }
        let guestNowMs = if let now { Int64(now.timeIntervalSince1970 * 1000) }
            else { try await GuestClock.sampleMilliseconds(client: client, computer: computer, account: account) }
        let signedAt = GuestClock.date(milliseconds: guestNowMs)
        let live = try await GuestSessionObserver(client: client).read(computer: computer, paths: paths, guestNowMs: guestNowMs)
        guard live.contains(where: { $0.cliSessionID == cliSessionID && $0.capabilities.contains(ClaudePlugin.inboxCapability) }) else {
            throw GuestClientFailure.notRunning(computer.key)
        }
        let signed = RelaySigner.sign(body: body, target: cliSessionID, key: key, nonce: nonce, now: signedAt)
        return try await GuestRelayInbox(client: client, timeout: timeout, onState: onState)
            .deliver(signed, to: cliSessionID, computer: computer, now: signedAt)
    }
}

enum GuestRelayLedger {
    static func upsert(_ record: GuestRelayRecord, into records: inout [GuestRelayRecord], limit: Int = 500) {
        if let index = records.firstIndex(where: { $0.location == record.location && $0.sessionID == record.sessionID && $0.nonce == record.nonce }) {
            var updated = record
            updated.id = records[index].id
            records[index] = updated
        } else {
            records.append(record)
        }
        if records.count > limit { records.removeFirst(records.count - limit) }
    }
}

extension Store {
    func saveGuestRelayState(_ record: GuestRelayRecord) {
        var state = router
        GuestRelayLedger.upsert(record, into: &state.guestRelayDeliveries)
        router = state
    }
}
