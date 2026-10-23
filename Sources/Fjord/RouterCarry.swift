import CryptoKit
import Foundation

// One way for your words to reach a session, whether it runs or sleeps (docs/design/claude-channel.md). Fjord gives a signed
// order to the plugin of another session the Claude app runs, the carrier; that plugin hands Fjord's signed message to the
// app's own send tool (no model turn), and the app delivers it: it starts a sleeping session with the message as its first
// prompt, or hands it to a running one. The target's plugin checks the signature, puts the words in Claude's place as the
// person's own, and answers in its inbox folder: that answer, not the app's receipt, is what says it went.
//
// Why a carrier for every message, a running target included: one path to reason about, test and show. The target's own inbox
// (`RelayInbox.deliver`) stays for what only it can do (stop, interrupt, cancel) and as the fallback when no other session
// is running and the target is.

/// One message's journey from Fjord to a session, kept before anything is ordered and settled by what the target's plugin said:
/// `waiting` (persisted, ordered), `sent` (the target's plugin answered ok), `unsure` (no answer: it may have gone, and is never
/// ordered again by Fjord itself), `refused` (the target's plugin said no, or every carrier refused before the app had it:
/// nothing was sent) or `needsYou`
/// (nothing can send it until you open the session).
struct DeliveryOperation: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Your words to a session that already existed.
        case message
        /// The first message of a session Fjord started.
        case firstMessage
    }

    enum State: String, Codable, Sendable { case waiting, sent, unsure, refused, needsYou }

    /// Which way it was ordered: through a carrier, into the target's own inbox, or after opening the target in the app.
    enum Route: String, Codable, Sendable { case carried, direct, opened }

    /// The signed message's nonce: the target's plugin claims it, so it can only ever go once.
    var nonce: String
    /// The target's Claude Code session id.
    var target: String
    var kind: Kind
    /// The first 16 hex digits of the SHA-256 of the words (so the history can tell which message it is, never what it said).
    var bodyHash: String
    var state: State
    var route: Route?
    /// The Claude Code session id of the carrier last asked.
    var carrier: String?
    /// Why it is `refused`, `unsure` or `needsYou`.
    var reason: String?
    var decisionID: UUID?
    var createdAt: Date
    var updatedAt: Date

    var id: String { nonce }

    static func hash(of body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// How many operations are kept.
    static let kept = 500
}

enum RouterCarry {
    /// How long each part of a delivery waits.
    struct Waits: Sendable {
        /// For a carrier's plugin to say it took the order (it looks every half second).
        var taken: TimeInterval = 6
        /// For a running target's plugin to answer once ordered; the app queues a message behind a turn under way.
        var running: TimeInterval = 45
        /// For a target the app has to start: a cold start.
        var cold: TimeInterval = 90
        /// For a target opened in the app to bring its plugin up.
        var opened: TimeInterval = 60
        var interval: TimeInterval = 0.05
    }

    /// Where an order goes.
    enum Plan: Equatable, Sendable {
        /// Through these carriers, best first; the second is tried when the first fails.
        case carry([String])
        /// Into the target's own inbox (it runs and no other session can carry).
        case direct
        /// Nothing runs: the target is opened in the app, then its own inbox is used.
        case open
    }

    /// How a delivery ended short of sent, with the state to keep.
    struct Failure: LocalizedError, Equatable {
        var state: DeliveryOperation.State
        var message: String
        var errorDescription: String? { message }
    }

    /// What a delivery reports as it goes.
    struct Update: Sendable {
        var route: DeliveryOperation.Route
        var carrier: String?
    }

    /// How many carriers are tried: the first, and one more.
    static let attempts = 2

    // MARK: Choosing

    /// The sessions that can carry a message to `target`, best first: a local session the Claude app runs (its registry entry
    /// says `claude-desktop`) with Fjord's plugin up and able to carry, not the target. An idle one before a busy one, then the
    /// most recently active.
    static func carriers(presence: [String: ClaudePlugin.Presence], registry: [Int32: [ClaudePeers.Registered]],
                         excluding target: String) -> [String] {
        struct Candidate { var cli: String; var idle: Bool; var active: Int64 }
        var found: [Candidate] = []
        for (cli, file) in presence where cli != target && file.can(ClaudePlugin.carryCapability) {
            guard let pid = file.pid,
                  let entry = registry[pid]?.first(where: { $0.sessionID == cli && $0.startedAt == file.startedAt }),
                  entry.entrypoint == "claude-desktop" else { continue }
            // The plugin's own word on its turn when it gives one; else the registry's.
            let idle = file.hasTurnField ? file.turn == nil : entry.status != "busy"
            found.append(Candidate(cli: cli, idle: idle, active: entry.updatedAt ?? 0))
        }
        return found.sorted {
            if $0.idle != $1.idle { return $0.idle }
            if $0.active != $1.active { return $0.active > $1.active }
            return $0.cli < $1.cli
        }.map(\.cli)
    }

    /// Where the order for `target` goes: through a carrier when one can carry (a running target must be able to answer the
    /// way a carried message needs, which a plugin of an older version can't), else into the target's own inbox when it runs,
    /// else by opening it.
    static func plan(carriers: [String], target: Presence?) -> Plan {
        if let target {
            return !carriers.isEmpty && target.can(ClaudePlugin.carryCapability) ? .carry(carriers) : .direct
        }
        return carriers.isEmpty ? .open : .carry(carriers)
    }

    typealias Presence = ClaudePlugin.Presence

    // MARK: Delivering

    /// Orders `signed` (a message of Fjord's for the Claude Code session in its header) to `local`'s plugin by `plan`, and
    /// returns the target's answer ("ok", with what its settings did). Throws `Failure` with the state it ends in.
    /// - `sign`: the signed carry order for a carrier (`RelaySigner.signCarry`), made when one is chosen.
    /// - `isUp`: whether the target's plugin is up (for a target opened in the app); `open` opens it.
    /// - `gate`: asked on the main actor right before each order is put in place (`RelayInbox.place`).
    /// - `update`: told which way and which carrier, before the wait.
    static func deliver(signed: String, plan: Plan, asleep: Bool, inbox: RelayInbox, waits: Waits = Waits(),
                        sign: @escaping @Sendable (String) async throws -> String,
                        isUp: @escaping @Sendable () async -> Bool = { true },
                        open: @MainActor @escaping () -> Void = {},
                        gate: (@MainActor () -> String?)? = nil,
                        update: @MainActor @escaping (Update) -> Void = { _ in }) async throws -> String {
        guard let header = RelayInbox.header(of: signed) else {
            throw Failure(state: .refused, message: "That isn't a message signed for a session; nothing was sent")
        }
        switch plan {
        case .direct:
            await update(Update(route: .direct, carrier: nil))
            return try await direct(signed, inbox: inbox, gate: gate)
        case .open:
            await update(Update(route: .opened, carrier: nil))
            await open()
            let deadline = Date().addingTimeInterval(waits.opened)
            while !(await isUp()) {
                try Task.checkCancellation()
                guard Date() < deadline else {
                    throw Failure(state: .needsYou, message: "No other session in the Claude app could carry it, and this one didn't come up "
                                  + "within \(Int(waits.opened)) s: open it in the Claude app, then send it again; nothing was sent")
                }
                try await Task.sleep(nanoseconds: UInt64(waits.interval * 1_000_000_000))
            }
            return try await direct(signed, inbox: inbox, gate: gate)
        case .carry(let carriers):
            return try await carried(signed, target: header.target, nonce: header.nonce, carriers: carriers,
                                     total: asleep ? waits.cold : waits.running, inbox: inbox, waits: waits, sign: sign,
                                     gate: gate, update: update)
        }
    }

    /// Into the target's own inbox: its plugin's answer is the answer.
    private static func direct(_ signed: String, inbox: RelayInbox, gate: (@MainActor () -> String?)?) async throws -> String {
        guard let header = RelayInbox.header(of: signed) else {
            throw Failure(state: .refused, message: "That isn't a message signed for a session; nothing was sent")
        }
        let placed = Flag()
        do {
            return try await inbox.deliver(signed, to: header.target, gate: gate, placed: { placed.set() })
        } catch is CancellationError {
            // Stopped before the message was in place: nothing was sent. After: the plugin may have read it already, and
            // withdrawing the file can't take back what it submitted.
            guard placed.isSet else { throw CancellationError() }
            throw Failure(state: .unsure, message: unsure("it was stopped while it was being delivered"))
        } catch RelayInbox.Failure.unanswered {
            throw Failure(state: .unsure, message: unsure("the session's plugin didn't answer"))
        } catch RelayInbox.Failure.refused(let why) {
            throw Failure(state: .refused, message: "The session's plugin refused the message: \(why)")
        }
    }

    /// Set once, from any thread.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    static func unsure(_ why: String) -> String {
        "It may not have arrived: \(why). Fjord won't send it again by itself: look in the session, and send it again yourself if it isn't there"
    }

    private static func carried(_ signed: String, target: String, nonce: String, carriers: [String], total: TimeInterval,
                                inbox: RelayInbox, waits: Waits, sign: @Sendable (String) async throws -> String,
                                gate: (@MainActor () -> String?)?, update: @MainActor (Update) -> Void) async throws -> String {
        let fm = FileManager.default
        let mine = inbox.files(for: target, nonce: nonce)
        // The target's plugin answers in its folder: it has to be there, private, before anything is ordered.
        try await OffMain.run {
            Swift.Result { try fm.createDirectory(at: inbox.folder(for: target), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        }.get()
        func answer(_ url: URL) -> String? {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
            // An empty file is an answer still being written: not an answer yet.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func settle(_ reply: String) throws -> String {
            try? fm.removeItem(at: mine.ack)
            if reply == "ok" || reply.hasPrefix("ok ") { return reply }
            throw Failure(state: .refused, message: "The session's plugin refused the message: "
                          + (reply.hasPrefix("refused: ") ? String(reply.dropFirst("refused: ".count)) : reply))
        }
        var reasons: [String] = []
        var placed = false
        for carrier in carriers.prefix(attempts) {
            let order = try await sign(carrier)
            guard let orderHeader = RelayInbox.header(of: order) else { continue }
            let theirs = inbox.files(for: carrier, nonce: orderHeader.nonce)
            func clean() { for url in [theirs.message, theirs.ack, theirs.taken] { try? fm.removeItem(at: url) } }
            do {
                _ = try await inbox.place(order, to: carrier, gate: gate)
            } catch RelayInbox.Failure.refused(let why) {
                // Stopped before anything was ordered (the run is over): nothing was sent.
                throw Failure(state: .refused, message: why)
            }
            placed = true
            await update(Update(route: .carried, carrier: carrier))
            let started = Date()
            var took = false, handed = false
            var appSaid: String?
            do {
                while true {
                    if let reply = answer(mine.ack) { clean(); return try settle(reply) }
                    if let reply = answer(theirs.ack) {
                        if reply.hasPrefix("refused:") {
                            // This carrier couldn't hand it to the app: another is tried, once. The app's own words are the reason.
                            reasons.append(String(reply.dropFirst("refused:".count)).trimmingCharacters(in: .whitespaces))
                            clean()
                            break
                        }
                        // The app took it, or may have: "unsure:" is the app's word after it had the message (a session slow to
                        // start says it "can still pick it up later"; a call that failed may have got there). Neither is a
                        // refusal, and no other carrier is asked: the target's own answer settles it, else it ends unsure.
                        handed = true
                        if reply.hasPrefix("unsure:"), appSaid == nil {
                            appSaid = String(reply.dropFirst("unsure:".count)).trimmingCharacters(in: .whitespaces)
                        }
                    }
                    if !took, fm.fileExists(atPath: theirs.taken.path) { took = true }
                    if !took, !handed, Date().timeIntervalSince(started) > waits.taken {
                        // Nobody seems to have picked the order up. A plugin that has read it may still be checking it: the order is
                        // withdrawn by saying so where that plugin looks after it says it took it (`withdrawn`, written first),
                        // and only then is `taken` looked for. One that took it is seen here; one that didn't sees `withdrawn` and
                        // never carries it out. It is never taken for unsent on the file's absence alone.
                        try? Data("withdrawn\n".utf8).write(to: theirs.withdrawn)
                        try? fm.removeItem(at: theirs.message)
                        if fm.fileExists(atPath: theirs.taken.path) || answer(theirs.ack) != nil { took = true; continue }
                        reasons.append("its plugin didn't pick the order up")
                        clean()
                        break
                    }
                    if Date().timeIntervalSince(started) > total {
                        clean()
                        let why = "the session's plugin hasn't answered within \(Int(total)) s" + (appSaid.map { " (the app said: \($0))" } ?? "")
                        throw Failure(state: .unsure, message: unsure(why))
                    }
                    try await Task.sleep(nanoseconds: UInt64(waits.interval * 1_000_000_000))
                }
            } catch is CancellationError {
                // Stopped while ordered: whether it went is not known, and it is left as it is.
                clean()
                throw Failure(state: placed ? .unsure : .refused, message: unsure("it was stopped while it was being delivered"))
            }
        }
        let why = reasons.isEmpty ? "" : " (\(reasons.joined(separator: "; ")))"
        throw Failure(state: .refused, message: "No session in the Claude app could carry the message\(why); nothing was sent")
    }
}

// MARK: - The store's side

extension Store {
    /// The carriers for `target` and the plan, read now (off the main thread): live presence under the key held now, and
    /// Claude Code's registry of processes.
    func carryPlan(target: String) async -> (plan: RouterCarry.Plan, targetUp: Bool) {
        guard let paths = routerFiles, let keyID = relayKeyCache?.keyID else { return (.open, false) }
        let found = await OffMain.run {
            ClaudePlugin.live(in: paths.pluginSessions,
                              registry: ClaudePeers.registry(dir: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true)),
                              keyID: keyID)
        }
        let registry = await OffMain.run {
            ClaudePeers.registry(dir: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true))
        }
        let carriers = RouterCarry.carriers(presence: found, registry: registry, excluding: target)
        return (RouterCarry.plan(carriers: carriers, target: found[target]), found[target] != nil)
    }

    /// Whether Fjord's plugin runs in `cli` now.
    func pluginUp(_ cli: String) async -> Bool {
        guard let paths = routerFiles, let keyID = relayKeyCache?.keyID else { return false }
        return await OffMain.run {
            ClaudePlugin.sessions(in: paths.pluginSessions,
                                  registry: ClaudePeers.registry(dir: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true)),
                                  keyID: keyID).contains(cli)
        }
    }

    /// Keeps `operation` (added, or replaced by its nonce); only the latest are kept.
    func noteOperation(_ operation: DeliveryOperation) {
        var state = router
        if let i = state.operations.firstIndex(where: { $0.nonce == operation.nonce }) {
            state.operations[i] = operation
        } else {
            state.operations.append(operation)
            if state.operations.count > DeliveryOperation.kept { state.operations.removeFirst(state.operations.count - DeliveryOperation.kept) }
        }
        router = state
    }

    /// Moves the operation with `nonce` to `state`.
    func updateOperation(_ nonce: String, _ change: (inout DeliveryOperation) -> Void) {
        guard var operation = router.operations.first(where: { $0.nonce == nonce }) else { return }
        change(&operation)
        operation.updatedAt = Date()
        noteOperation(operation)
    }

    /// Operations still `waiting` when Fjord starts again were lost with the quit: whether they went is looked up in the
    /// target's inbox folder (its plugin's answer is left there until read), else they are `unsure`. Never ordered again.
    func settleLostOperations() {
        // A test that gave the store no files of its own is not sent to the person's (`UnderTest`).
        guard routerPaths != nil || !UnderTest.isRunning, let paths = routerFiles else { return }
        let inbox = RelayInbox(root: paths.relay)
        for operation in router.operations where operation.state == .waiting || operation.state == .unsure {
            let reply = inbox.leftover(target: operation.target, nonce: operation.nonce)
            updateOperation(operation.nonce) {
                if let reply {
                    if reply == "ok" || reply.hasPrefix("ok ") { $0.state = .sent; $0.reason = nil }
                    else { $0.state = .refused; $0.reason = reply.hasPrefix("refused: ") ? String(reply.dropFirst(9)) : reply }
                } else if $0.state == .waiting {
                    $0.state = .unsure
                    $0.reason = "Fjord quit while it was being delivered"
                }
            }
        }
    }
}

extension RelayInbox {
    /// The answer waiting for the message `nonce` in `target`'s folder, if its plugin left one.
    func leftover(target: String, nonce: String) -> String? {
        guard let data = try? Data(contentsOf: files(for: target, nonce: nonce).ack),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
