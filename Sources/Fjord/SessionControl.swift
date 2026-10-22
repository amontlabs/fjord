import Foundation

// Session control: stopping the turn a Claude Code session is running, and interrupting it with a new message, through the
// session's Fjord plugin (`stop-v1`, `interrupt-v1`; see `ClaudePlugin.register` for the wire). Both go through the
// session's inbox, local or in a guest computer (Silo's files API), signed with the relay key, and both are refused by a
// plugin too old to know them (`.unsupported`: nothing is written).
//
// For callers (cards, the Router): `canStop` says, from presence, whether a stop is worth offering; `stopTurn` and `interrupt`
// do it. Each takes a `gate`, asked on the main actor right before the message is written: a reason refuses it, nothing
// written (a stale request, a card already archived, the Router turned off). The session is named by its Desktop id
// (`claudeSessions`' key), as everywhere else; a CLI session id is taken too.

/// How a stop went.
enum StopOutcome: Equatable, Sendable {
    /// The running turn was stopped (its id).
    case stopped(String)
    /// No turn was running: nothing was stopped (and nothing written when presence already said so).
    case idle
    /// The turn named in the request wasn't the running one any more (it finished, or a newer one began): left alone.
    case notRunning
    /// The session's plugin can't stop a turn, or there is no live plugin there. The reason names what to do.
    case unsupported(String)
    /// The gate refused it, the plugin refused it, nobody answered, or the Router is off.
    case failed(String)
}

/// How an interrupting message went.
enum DeliveryOutcome: Equatable, Sendable {
    /// The plugin took it. `interrupted` is the id of the turn it stopped first; nil when none ran (it was just submitted).
    /// `ack` is the plugin's whole answer.
    case delivered(ack: String, interrupted: String?)
    case unsupported(String)
    /// The gate or the plugin said no (the reason).
    case refused(String)
    /// Nothing reached the plugin (or it said so): confirmed not delivered.
    case failed(String)
    /// The message was put in the inbox and no answer came back (or the answer was lost): it may have been submitted. `signed`
    /// is the text as written, with its nonce: sent again as it is, the plugin's claim of the nonce makes a second copy
    /// impossible; a new message (another nonce) could arrive twice.
    case unconfirmed(String, signed: String)
}

enum SessionControlAck {
    /// The plugin's answer to a stop: "ok stopped <turn id>", "ok idle", "ok not-running". Nil for anything else.
    static func stop(_ ack: String) -> StopOutcome? {
        let words = ack.split(separator: " ").map(String.init)
        guard words.first == "ok", words.count >= 2 else { return nil }
        switch words[1] {
        case "stopped": return words.count == 3 ? .stopped(words[2]) : nil
        case "idle" where words.count == 2: return .idle
        case "not-running" where words.count == 2: return .notRunning
        default: return nil
        }
    }

    /// What a delivery's answer says. Nil when it isn't an "ok" at all.
    struct Delivered: Equatable {
        /// The turn it stopped first: "ok interrupted <turn id> ..." has one; "ok idle ..." and a plain "ok ..." none.
        var interrupted: String?
    }

    static func delivery(_ ack: String) -> Delivered? {
        let words = ack.split(separator: " ").map(String.init)
        // "ok not-running" is a stop's word for a turn it couldn't reach: an interrupt behind it was not delivered.
        guard words.first == "ok", words.dropFirst().first != "not-running" else { return nil }
        return Delivered(interrupted: words.count >= 3 && words[1] == "interrupted" ? words[2] : nil)
    }
}

extension Store {
    /// What Fjord knows of a session's plugin: where to reach it, and what its presence says.
    struct ControlTarget {
        var cli: String
        var guest: (computer: GuestReference, client: any GuestClient)?
        var capabilities: [String]
        /// The turn under way; nil when idle, or when the plugin doesn't say (`hasTurnField` false).
        var turn: ClaudePlugin.Presence.Turn?
        var hasTurnField: Bool

        func can(_ capability: String) -> Bool { capabilities.contains(capability) }
    }

    /// The target for `sessionID` from the presence read last (no file is read here); nil when no live plugin is known there.
    func controlTarget(_ sessionID: String) -> ControlTarget? {
        if let computer = GuestRouterRuntime.shared.guestReference(for: sessionID) {
            guard let cli = GuestRouterRuntime.shared.guestSessionID(for: sessionID),
                  let client = GuestRouterRuntime.shared.guestClient(for: sessionID),
                  let presence = GuestRouterRuntime.shared.presence(forGuestSessionID: cli) else { return nil }
            return ControlTarget(cli: cli, guest: (computer, client), capabilities: presence.capabilities, turn: presence.turn,
                                 hasTurnField: presence.hasTurnField)
        }
        let known = claudeFeed.presence
        guard let cli = claudeSessions[sessionID]?.cliID ?? (known[sessionID] != nil ? sessionID : nil),
              let presence = known[cli] else { return nil }
        return ControlTarget(cli: cli, guest: nil, capabilities: presence.capabilities ?? [], turn: presence.turn,
                             hasTurnField: presence.hasTurnField)
    }

    /// Whether a stop is worth offering for `sessionID`: its plugin says `stop-v1` and presence says a turn runs.
    func canStop(sessionID: String) -> Bool {
        guard let target = controlTarget(sessionID) else { return false }
        return target.can(ClaudePlugin.stopCapability) && target.turn != nil
    }

    /// The turn `sessionID` runs now, if its plugin says so.
    func runningTurn(sessionID: String) -> ClaudePlugin.Presence.Turn? { controlTarget(sessionID)?.turn }

    /// Stops the turn `sessionID` is running. A session with no plugin presence has no turn to stop, so it is never woken for
    /// this (nor for `interrupt`, which stops a running turn first): only a message to it (`RouterTools.prepare`) wakes it. The turn named is the one presence shows now: a plugin whose running turn is
    /// another one leaves it alone (`.notRunning`). A session whose presence says it is idle is not written to (`.idle`).
    /// `turn`: the turn the caller saw (the one the stop was judged on); a plugin whose running turn is another leaves it alone.
    func stopTurn(sessionID: String, turn expected: String? = nil, gate: (@MainActor @Sendable () -> String?)? = nil) async -> StopOutcome {
        do {
            let target: ControlTarget
            if let guest = GuestRouterRuntime.shared.guestReference(for: sessionID) {
                target = try await freshGuestTarget(sessionID, computer: guest)
            } else {
                guard routerFiles != nil else { return .failed("The Router is off") }
                guard let local = await freshLocalTarget(sessionID) else {
                    return .unsupported("Fjord's plugin isn't running in this session: restart it or run /reload-plugins in it")
                }
                target = local
            }
            guard target.can(ClaudePlugin.stopCapability) else {
                return .unsupported("Fjord's plugin in this session is too old to stop a turn: restart it or run /reload-plugins in it")
            }
            if target.hasTurnField, target.turn == nil { return .idle }
            // Another turn than the one judged: left alone, nothing written.
            if let expected, let running = target.turn?.id, running != expected { return .notRunning }
            // A refusal known now is returned without writing; the gate is asked again right before the write.
            if let refusal = await MainActor.run(body: { gate?() }) { return .failed(refusal) }
            // The turn named is the one judged (else whichever presence shows): the plugin answers not-running for another.
            let turn = expected ?? target.turn?.id
            let ack: String
            if let guest = target.guest {
                let signed = try await guestSigned(target.cli, guest: guest) { key, now in
                    RelaySigner.signStop(target: target.cli, turn: turn, key: key, now: now)
                }
                ack = try await GuestRouterRuntime.shared.deliver(signed, to: target.cli, computer: guest.computer, gate: gate, preflight: gate)
            } else {
                let text = try await localSigned { key in RelaySigner.signStop(target: target.cli, turn: turn, key: key) }
                guard let paths = routerFiles else { return .failed("The Router is off") }
                ack = try await RelayInbox(root: paths.relay).deliver(text, to: target.cli, gate: gate)
            }
            return SessionControlAck.stop(ack) ?? .failed("The session's plugin answered “\(RouterDecision.clip(ack, 60))”")
        } catch let failure as RelayInbox.Failure {
            return .failed(failure.localizedDescription)
        } catch is CancellationError {
            return .failed("Stopped; nothing was sent")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Interrupts `sessionID`: the turn it runs (if any) is stopped and `text` submitted as the person's own words, in one
    /// step in the plugin (a v3 message); the model and effort of `settings` ride along when the plugin applies them.
    /// `text` is sent as it is: the caller adds whatever the message carries. An idle session just takes the message.
    /// `turn`: the turn the caller judged; when another one runs now, nothing is written (`.refused`).
    /// `resend`: the signed text of an earlier try that ended `.unconfirmed`, written again as it was (same nonce) instead of
    /// signing a new message; `text` is then only what it says.
    func interrupt(sessionID: String, text: String, settings: SessionSettings? = nil, turn expected: String? = nil,
                   resend: String? = nil, gate: (@MainActor @Sendable () -> String?)? = nil) async -> DeliveryOutcome {
        // Set once the message may have reached the inbox: from there on a failure is not a proof it wasn't delivered.
        var written: String?
        do {
            let target: ControlTarget
            if let guest = GuestRouterRuntime.shared.guestReference(for: sessionID) {
                target = try await freshGuestTarget(sessionID, computer: guest)
            } else {
                guard routerFiles != nil else { return .failed("The Router is off") }
                guard let local = await freshLocalTarget(sessionID) else {
                    return .unsupported("Fjord's plugin isn't running in this session: restart it or run /reload-plugins in it")
                }
                target = local
            }
            guard target.can(ClaudePlugin.inboxCapability), target.can(ClaudePlugin.interruptCapability) else {
                return .unsupported("Fjord's plugin in this session is too old to interrupt a turn: restart it or run /reload-plugins in it")
            }
            // A resend of a message already in the plugin's hands is not refused for the turn moving on: it either was taken
            // (the plugin says so) or wasn't, and a new turn is no reason to hide that.
            if resend == nil, let expected, let running = target.turn?.id, running != expected {
                return .refused("Its turn changed since you asked: it isn't the one you meant to stop")
            }
            // The turn judged rides inside the signed request, which the plugin checks atomically against the turn it stops (a
            // turn that began meanwhile is never interrupted, a retry included). A resend carries what it was signed with.
            if resend == nil, expected != nil, !target.can(ClaudePlugin.interruptTurnCapability) {
                return .unsupported("Fjord's plugin in this session is too old to interrupt a given turn: restart it or run /reload-plugins in it")
            }
            let applied = target.can(ClaudePlugin.settingsCapability) ? settings : nil
            let ack: String
            if let guest = target.guest {
                let signed: String
                if let resend { signed = resend } else {
                    signed = try await guestSigned(target.cli, guest: guest) { key, now in
                        RelaySigner.sign(body: text, target: target.cli, key: key, now: now, model: applied?.model, effort: applied?.effort,
                                         interrupt: true, expectTurn: expected)
                    }
                }
                written = signed
                ack = try await GuestRouterRuntime.shared.deliver(signed, to: target.cli, computer: guest.computer, body: text,
                                                                   gate: gate, preflight: gate)
            } else {
                let signed: String
                if let resend { signed = resend } else {
                    signed = try await localSigned { key in
                        RelaySigner.sign(body: text, target: target.cli, key: key, model: applied?.model, effort: applied?.effort, interrupt: true, expectTurn: expected)
                    }
                }
                guard let paths = routerFiles else { return .failed("The Router is off") }
                written = signed
                ack = try await RelayInbox(root: paths.relay).deliver(signed, to: target.cli, gate: gate)
            }
            guard let how = SessionControlAck.delivery(ack) else { return .failed("The session's plugin answered “\(RouterDecision.clip(ack, 60))”") }
            return .delivered(ack: ack, interrupted: how.interrupted)
        } catch let failure as RelayInbox.Failure {
            if case .refused(let why) = failure { return .refused(why) }
            return unknown(failure, written)
        } catch let failure as GuestRelayInbox.Failure {
            if case .refused(let why) = failure { return .refused(why) }
            return unknown(failure, written)
        } catch is CancellationError {
            if let written { return .unconfirmed("Stopped while it was being sent: it may have gone", signed: written) }
            return .failed("Stopped; nothing was sent")
        } catch {
            return unknown(error, written)
        }
    }

    /// A failure after the message was put in the inbox is an unknown outcome; before, it is a failure.
    private func unknown(_ error: Error, _ written: String?) -> DeliveryOutcome {
        guard let written else { return .failed(error.localizedDescription) }
        return .unconfirmed(error.localizedDescription, signed: written)
    }

    // MARK: Reading and signing

    /// A fresh read of the presence files for a local session (off the main thread), not the cached one.
    private func freshLocalTarget(_ sessionID: String) async -> ControlTarget? {
        guard let paths = routerFiles, let keyID = relayKeyCache?.keyID else { return nil }
        let known = claudeSessions[sessionID]?.cliID
        let found = await OffMain.run {
            ClaudePlugin.live(in: paths.pluginSessions,
                              registry: ClaudePeers.registry(dir: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true)),
                              keyID: keyID)
        }
        guard let cli = known ?? (found[sessionID] != nil ? sessionID : nil), let presence = found[cli] else { return nil }
        return ControlTarget(cli: cli, guest: nil, capabilities: presence.capabilities ?? [], turn: presence.turn,
                             hasTurnField: presence.hasTurnField)
    }

    /// The guest session's presence, read from the computer now.
    private func freshGuestTarget(_ sessionID: String, computer: GuestReference) async throws -> ControlTarget {
        guard let client = GuestRouterRuntime.shared.guestClient(for: sessionID),
              let cli = GuestRouterRuntime.shared.guestSessionID(for: sessionID) else {
            throw RouterTools.Failure("Fjord's guest file client isn't connected for this session")
        }
        let account = try await client.account(for: computer)
        let paths = try GuestRouterPaths(home: account.home)
        let nowMs = try await GuestClock.sampleMilliseconds(client: client, computer: computer, account: account)
        let live = try await GuestSessionObserver(client: client).read(computer: computer, paths: paths, guestNowMs: nowMs)
        guard let found = live.first(where: { $0.cliSessionID == cli }) else {
            throw RouterTools.Failure("Fjord's plugin isn't running in this guest session")
        }
        return ControlTarget(cli: cli, guest: (computer, client), capabilities: found.capabilities, turn: found.turn,
                             hasTurnField: found.hasTurnField)
    }

    /// `sign` applied to the relay key (read again when the cached one is stale).
    private func localSigned(_ sign: (String) -> String) async throws -> String {
        guard let paths = routerFiles else { throw RouterTools.Failure("The Router is off") }
        if let cached = relayKeyCache, cached.matches(paths.relayKey) { return sign(cached.key) }
        guard await reloadRelayKey(), let key = relayKeyCache?.key else { throw RouterTools.Failure("The Router is off") }
        return sign(key)
    }

    /// `sign` applied to the guest's relay key and clock.
    private func guestSigned(_ cli: String, guest: (computer: GuestReference, client: any GuestClient),
                             _ sign: (String, Date) -> String) async throws -> String {
        let account = try await guest.client.account(for: guest.computer)
        let paths = try GuestRouterPaths(home: account.home)
        let keyFile = try await guest.client.filesRead(computer: guest.computer, path: paths.key, offset: nil, length: nil)
        guard let key = String(data: keyFile.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              key.count == 64, key.allSatisfy(\.isHexDigit) else {
            throw RouterTools.Failure("Fjord's guest relay key is unavailable")
        }
        let nowMs = try await GuestClock.sampleMilliseconds(client: guest.client, computer: guest.computer, account: account)
        return sign(key, GuestClock.date(milliseconds: nowMs))
    }
}
