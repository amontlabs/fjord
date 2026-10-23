import Foundation
import Testing
@testable import Fjord

/// The one way for your words to reach a session (`RouterCarry`): which session carries, how an order goes and ends, and what
/// the store keeps of it. The plugins are stood in for by tasks that watch the inbox folders as the real ones do.
@MainActor
@Suite(.serialized) struct RouterCarryTests {
    static let key = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    static let fast = RouterCarry.Waits(taken: 0.4, running: 1.5, cold: 2.5, opened: 1.0, interval: 0.01)

    // MARK: Choosing

    private func presence(_ pid: Int32 = 10, started: Int64 = 1, carry: Bool = true, turn: Bool? = false) -> ClaudePlugin.Presence {
        var object: [String: Any] = ["state": "live", "pid": Int(pid), "startedAt": started]
        if carry { object["capabilities"] = ["inbox-v1", ClaudePlugin.carryCapability] }
        if let turn { object["turn"] = turn ? ["id": "t1"] : NSNull() }
        return try! JSONDecoder().decode(ClaudePlugin.Presence.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func entry(_ cli: String, started: Int64 = 1, entrypoint: String? = "claude-desktop", status: String? = "idle",
                       updated: Int64 = 100) -> ClaudePeers.Registered {
        ClaudePeers.Registered(sessionID: cli, startedAt: started, entrypoint: entrypoint, status: status, updatedAt: updated)
    }

    @Test func aCarrierIsALocalDesktopSessionWithThePluginUpThatIsNotTheTarget() {
        let found = ["target": presence(1), "idle": presence(2), "other": presence(3), "old": presence(4, carry: false),
                     "cli": presence(5), "gone": presence(6)]
        let registry: [Int32: [ClaudePeers.Registered]] = [
            1: [entry("target")], 2: [entry("idle")], 3: [entry("other")], 4: [entry("old")],
            5: [entry("cli", entrypoint: "cli")],
            // The process is another one than the presence was written for.
            6: [entry("gone", started: 2)],
        ]
        #expect(RouterCarry.carriers(presence: found, registry: registry, excluding: "target") == ["idle", "other"])
        // With no registry entry at all, or no plugin that carries, nothing carries.
        #expect(RouterCarry.carriers(presence: found, registry: [:], excluding: "target").isEmpty)
        #expect(RouterCarry.carriers(presence: ["old": presence(4, carry: false)], registry: [4: [entry("old")]], excluding: "x").isEmpty)
    }

    @Test func anIdleCarrierIsPreferredThenTheMostRecentlyActive() {
        let found = ["busy-new": presence(1, turn: true), "idle-old": presence(2), "idle-new": presence(3), "idle-same": presence(4)]
        let registry: [Int32: [ClaudePeers.Registered]] = [
            1: [entry("busy-new", status: "busy", updated: 900)], 2: [entry("idle-old", updated: 100)],
            3: [entry("idle-new", updated: 500)], 4: [entry("idle-same", updated: 500)],
        ]
        #expect(RouterCarry.carriers(presence: found, registry: registry, excluding: "t") == ["idle-new", "idle-same", "idle-old", "busy-new"])
        // A plugin that doesn't say its turn (an older one) is as the registry says: busy there is busy.
        let silent = ["a": presence(1, turn: nil), "b": presence(2, turn: nil)]
        let reg: [Int32: [ClaudePeers.Registered]] = [1: [entry("a", status: "busy", updated: 900)], 2: [entry("b", status: "idle", updated: 100)]]
        #expect(RouterCarry.carriers(presence: silent, registry: reg, excluding: "t") == ["b", "a"])
    }

    @Test func theOrderGoesThroughACarrierWhenOneCanCarryElseTheTargetsOwnInboxWhenItRunsElseTheTargetIsOpened() {
        #expect(RouterCarry.plan(carriers: ["c"], target: presence(1)) == .carry(["c"]))
        #expect(RouterCarry.plan(carriers: ["c", "d"], target: nil) == .carry(["c", "d"]))
        // No other session runs: a running target takes it itself, a sleeping one is opened.
        #expect(RouterCarry.plan(carriers: [], target: presence(1)) == .direct)
        #expect(RouterCarry.plan(carriers: [], target: nil) == .open)
        // A running target whose plugin is older than carrying (it wouldn't answer a carried message) takes it itself.
        #expect(RouterCarry.plan(carriers: ["c"], target: presence(1, carry: false)) == .direct)
    }

    // MARK: Stand-ins

    /// What a carrier's plugin does with an order.
    enum Carrier: Sendable {
        /// Takes it, calls the app, which delivers: the target's plugin answers `target` (nil: it never does), the carrier `app`.
        case delivers(app: String, target: String?)
        case refuses(String)
        /// Takes it, and the app answers with an error after it had the message (`unsure:`): the target answers `target` (nil: never).
        case appUnsure(String, target: String?, after: TimeInterval = 0)
        /// As a plugin that has read the order and is slow to check it: writes `taken` only after `after` s, then looks for
        /// `withdrawn` (it carries the order out only when there is none), and delivers like `.delivers`.
        case slow(after: TimeInterval)
        /// As `.slow`, paused until Fjord has withdrawn the order however long that takes, rather than for a set time.
        case pausedUntilWithdrawn
        /// Never looks at its inbox.
        case silent
        /// Takes it, and the app never answers.
        case stuck
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _orders: [(carrier: String, text: String)] = []
        private var _carriedOut: [String] = []
        func add(_ carrier: String, _ text: String) { lock.withLock { _orders.append((carrier, text)) } }
        var orders: [(carrier: String, text: String)] { lock.withLock { _orders } }
        /// The carriers that handed the message to the app.
        func carriedOut(_ carrier: String) { lock.withLock { _carriedOut.append(carrier) } }
        var carriedOutBy: [String] { lock.withLock { _carriedOut } }
    }

    nonisolated private static func answer(_ url: URL, _ text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((text + "\n").utf8).write(to: url)
    }

    /// A carrier's plugin: sees an order in its folder, says it took it, and acts by `behavior`; the order is kept in `seen`.
    private func carrier(_ cli: String, _ inbox: RelayInbox, behavior: Carrier, seen: Seen) -> Task<Void, Never> {
        Task.detached {
            var handled: Set<String> = []
            for _ in 0..<600 {
                if Task.isCancelled { return }
                let folder = inbox.folder(for: cli)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                for name in names where name.hasSuffix(".msg") && !handled.contains(name) {
                    guard let text = try? String(contentsOfFile: folder.appendingPathComponent(name).path, encoding: .utf8) else { continue }
                    handled.insert(name)
                    seen.add(cli, text)
                    let base = String(name.dropLast(4))
                    if case .silent = behavior { continue }
                    let withdrawn = folder.appendingPathComponent("\(base).withdrawn")
                    var paused = false
                    if case .slow(let after) = behavior {
                        try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                        paused = true
                    } else if case .pausedUntilWithdrawn = behavior {
                        var watchdog = Watchdog()
                        while !FileManager.default.fileExists(atPath: withdrawn.path), !watchdog.expired() {
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                        paused = true
                    }
                    if paused {
                        Self.answer(folder.appendingPathComponent("\(base).taken"), "taken")
                        if FileManager.default.fileExists(atPath: withdrawn.path) {
                            Self.answer(folder.appendingPathComponent("\(base).ack"), "refused: withdrawn")
                            continue
                        }
                        let inner = text.split(separator: "\n", maxSplits: 1).last.flatMap { Data(base64Encoded: String($0)) }
                            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        seen.carriedOut(cli)
                        if let header = RelayInbox.header(of: inner) {
                            Self.answer(inbox.files(for: header.target, nonce: header.nonce).ack, "ok")
                        }
                        Self.answer(folder.appendingPathComponent("\(base).ack"), "ok delivered")
                        continue
                    }
                    Self.answer(folder.appendingPathComponent("\(base).taken"), "taken")
                    let inner = text.split(separator: "\n", maxSplits: 1).last.flatMap { Data(base64Encoded: String($0)) }
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    switch behavior {
                    case .refuses(let why): Self.answer(folder.appendingPathComponent("\(base).ack"), "refused: \(why)")
                    case .appUnsure(let why, let target, let after):
                        Self.answer(folder.appendingPathComponent("\(base).ack"), "unsure: \(why)")
                        if let header = RelayInbox.header(of: inner), let target {
                            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                            Self.answer(inbox.files(for: header.target, nonce: header.nonce).ack, target)
                        }
                    case .delivers(let app, let target):
                        seen.carriedOut(cli)
                        if let header = RelayInbox.header(of: inner), let target {
                            Self.answer(inbox.files(for: header.target, nonce: header.nonce).ack, target)
                        }
                        Self.answer(folder.appendingPathComponent("\(base).ack"), "ok \(app)")
                    case .stuck, .silent, .slow, .pausedUntilWithdrawn: break
                    }
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    /// A session's plugin reading its own inbox, as `RelayInbox.deliver` expects: answers every message it finds.
    private func owner(_ cli: String, _ inbox: RelayInbox, reply: String, seen: Seen) -> Task<Void, Never> {
        Task.detached {
            var handled: Set<String> = []
            for _ in 0..<600 {
                if Task.isCancelled { return }
                let folder = inbox.folder(for: cli)
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".msg") && !handled.contains(name) {
                    guard let text = try? String(contentsOfFile: folder.appendingPathComponent(name).path, encoding: .utf8) else { continue }
                    handled.insert(name)
                    seen.add(cli, text)
                    Self.answer(folder.appendingPathComponent(String(name.dropLast(4)) + ".ack"), reply)
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    private func signed(_ body: String = "hello", target: String = "cli-target") -> String {
        RelaySigner.sign(body: body, target: target, key: Self.key)
    }

    private func sign(_ message: String, local: String = "local_t") -> @Sendable (String) async throws -> String {
        { carrier in RelaySigner.signCarry(message: message, local: local, carrier: carrier, key: Self.key) }
    }

    private func deliver(_ message: String, plan: RouterCarry.Plan, inbox: RelayInbox, asleep: Bool = false,
                         isUp: @escaping @Sendable () async -> Bool = { true }, open: @MainActor @escaping () -> Void = {},
                         gate: (@MainActor () -> String?)? = nil, waits: RouterCarry.Waits = RouterCarryTests.fast,
                         update: @MainActor @escaping (RouterCarry.Update) -> Void = { _ in }) async throws -> String {
        try await RouterCarry.deliver(signed: message, plan: plan, asleep: asleep, inbox: inbox, waits: waits, sign: sign(message),
                                      isUp: isUp, open: open, gate: gate, update: update)
    }

    private func failure(_ work: () async throws -> String) async -> RouterCarry.Failure? {
        do { _ = try await work(); return nil } catch let failure as RouterCarry.Failure { return failure } catch { return nil }
    }

    // MARK: Carried

    @Test func aMessageIsOrderedToTheCarrierSignedForItAndIsSentWhenTheTargetsPluginSaysSo() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let message = signed()
        let header = try #require(RelayInbox.header(of: message))
        let seen = Seen()
        let plugin = carrier("cli-carrier", inbox, behavior: .delivers(app: "Message delivered to session local_t", target: "ok model=opus"), seen: seen)
        var updates: [RouterCarry.Update] = []
        let ack = try await deliver(message, plan: .carry(["cli-carrier"]), inbox: inbox, update: { updates.append($0) })
        // The target's own answer is the answer, not the app's receipt.
        #expect(ack == "ok model=opus")
        #expect(updates.map(\.route) == [.carried] && updates.first?.carrier == "cli-carrier")
        let order = try #require(seen.orders.first)
        #expect(seen.orders.count == 1 && order.carrier == "cli-carrier")
        #expect(order.text.hasPrefix("⟦fjord carry v1 cli-carrier ") && order.text.contains(" local_t "))
        // Its base64 line is the signed message, unchanged.
        let carried = try #require(order.text.split(separator: "\n", maxSplits: 1).last.flatMap { Data(base64Encoded: String($0)) }.flatMap { String(data: $0, encoding: .utf8) })
        #expect(carried == message)
        // The target's answer stays until the caller has the outcome on disk; nothing else is left behind in either folder.
        #expect(FileManager.default.fileExists(atPath: inbox.files(for: header.target, nonce: header.nonce).ack.path))
        RouterCarry.discardAnswer(inbox: inbox, target: header.target, nonce: header.nonce)
        #expect(!FileManager.default.fileExists(atPath: inbox.files(for: header.target, nonce: header.nonce).ack.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: inbox.folder(for: "cli-carrier").path)) ?? []).isEmpty)
        plugin.cancel()
    }

    @Test func aCarrierThatRefusesIsFollowedByOneMoreAndNoMore() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        let first = carrier("c1", inbox, behavior: .refuses("that session did not respond"), seen: seen)
        let second = carrier("c2", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let ack = try await deliver(signed(), plan: .carry(["c1", "c2", "c3"]), inbox: inbox)
        #expect(ack == "ok" && seen.orders.map(\.carrier) == ["c1", "c2"])
        // Both refuse: the third is never asked; nothing was sent, and the reasons are said.
        let one = carrier("d1", inbox, behavior: .refuses("archived"), seen: seen)
        let two = carrier("d2", inbox, behavior: .refuses("offline"), seen: seen)
        let message = signed("again")
        let ended = await failure { try await self.deliver(message, plan: .carry(["d1", "d2", "d3"]), inbox: inbox) }
        #expect(ended?.state == .refused && ended?.message.contains("archived; offline") == true && ended?.message.contains("nothing was sent") == true)
        #expect(!seen.orders.map(\.carrier).contains("d3"))
        [first, second, one, two].forEach { $0.cancel() }
    }

    @Test func anOrderNobodyPicksUpIsWithdrawnAndAnotherCarrierIsAsked() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        // c1's plugin never looks; c2 does.
        let working = carrier("c2", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let message = signed()
        let ack = try await deliver(message, plan: .carry(["c1", "c2"]), inbox: inbox)
        #expect(ack == "ok" && seen.orders.map(\.carrier) == ["c2"])
        // The order for c1 was taken back: its plugin must never find it later, and one that has read it already is told.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: inbox.folder(for: "c1").path)) ?? []
        #expect(!left.contains { $0.hasSuffix(".msg") } && left.contains { $0.hasSuffix(".withdrawn") })
        working.cancel()
    }

    @Test func aPluginThatReadTheOrderBeforeItWasWithdrawnButWritesTakenLaterDoesNotCarryItOut() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        // c1 read the order, then pauses past the wait for it to be taken; Fjord withdraws it and asks c2. c1 resumes: it
        // writes `taken`, finds `withdrawn`, and must not hand the message to the app (the words would arrive twice).
        let slow = carrier("c1", inbox, behavior: .pausedUntilWithdrawn, seen: seen)
        let working = carrier("c2", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let ack = try await deliver(signed(), plan: .carry(["c1", "c2"]), inbox: inbox)
        #expect(ack == "ok")
        // Once c1 has answered its order, whichever way.
        let c1 = inbox.folder(for: "c1")
        await waitUntilAnywhere {
            ((try? FileManager.default.contentsOfDirectory(atPath: c1.path)) ?? []).contains { $0.hasSuffix(".ack") }
        }
        #expect(seen.carriedOutBy == ["c2"])
        slow.cancel(); working.cancel()
    }

    @Test func anOrderTakenAsItIsWithdrawnIsWaitedForNotTakenForUnsent() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        // c1 writes `taken` just after the wait ends, but before Fjord could have looked again: it carried the order out.
        let slow = carrier("c1", inbox, behavior: .slow(after: 0.42), seen: seen)
        let working = carrier("c2", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let message = signed()
        // Whichever way the race falls, the message is carried out exactly once.
        _ = try? await deliver(message, plan: .carry(["c1", "c2"]), inbox: inbox)
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(seen.carriedOutBy.count == 1)
        slow.cancel(); working.cancel()
    }

    @Test func aTargetThatRefusesEndsItAndNoOtherCarrierIsAsked() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        let a = carrier("c1", inbox, behavior: .delivers(app: "ok", target: "refused: stale"), seen: seen)
        let b = carrier("c2", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let ended = await failure { try await self.deliver(self.signed(), plan: .carry(["c1", "c2"]), inbox: inbox) }
        #expect(ended?.state == .refused && ended?.message == "The session's plugin refused the message: stale")
        #expect(seen.orders.map(\.carrier) == ["c1"])
        a.cancel(); b.cancel()
    }

    @Test func noAnswerFromTheTargetIsUnsureAndNothingIsOrderedAgain() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        // The app says it delivered; the target's plugin never answers.
        let a = carrier("c1", inbox, behavior: .delivers(app: "Message not delivered to session local_t", target: nil), seen: seen)
        let b = carrier("c2", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let began = Date()
        let ended = await failure { try await self.deliver(self.signed(), plan: .carry(["c1", "c2"]), inbox: inbox) }
        #expect(ended?.state == .unsure && ended?.message.contains("won't send it again by itself") == true)
        #expect(Date().timeIntervalSince(began) >= Self.fast.running)
        #expect(seen.orders.map(\.carrier) == ["c1"])
        // A sleeping target is given the cold start's longer time.
        let cold = Date()
        let late = await failure { try await self.deliver(self.signed("later"), plan: .carry(["c1"]), inbox: inbox, asleep: true) }
        #expect(late?.state == .unsure && Date().timeIntervalSince(cold) >= Self.fast.cold)
        a.cancel(); b.cancel()
    }

    @Test func anErrorFromTheAppAfterItHadTheMessageIsUnsureNotRefusedAndNoOtherCarrierIsAsked() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        // The app's "undelivered / no_turn": the target may still pick the message up. The second carrier would deliver it twice.
        let a = carrier("c1", inbox, behavior: .appUnsure("that session gave no sign of starting on it; it can still pick it up later", target: nil), seen: seen)
        let b = carrier("c2", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let ended = await failure { try await self.deliver(self.signed(), plan: .carry(["c1", "c2"]), inbox: inbox) }
        #expect(ended?.state == .unsure && ended?.message.contains("can still pick it up later") == true)
        #expect(ended?.message.contains("nothing was sent") != true)
        #expect(seen.orders.map(\.carrier) == ["c1"])
        a.cancel(); b.cancel()
    }

    @Test func aTargetThatAnswersAfterTheAppsUncertainErrorStillSettlesItAsSentWithoutAnotherOrder() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        let a = carrier("c1", inbox, behavior: .appUnsure("no sign of starting", target: "ok", after: 0.3), seen: seen)
        let b = carrier("c2", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let ack = try await deliver(signed(), plan: .carry(["c1", "c2"]), inbox: inbox)
        #expect(ack == "ok" && seen.orders.map(\.carrier) == ["c1"])
        a.cancel(); b.cancel()
    }

    @Test func aCarrierThatTookTheOrderAndIsNeverAnsweredByTheAppLeavesTheTargetsAnswerToDecide() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let message = signed()
        let header = try #require(RelayInbox.header(of: message))
        let seen = Seen()
        let stuck = carrier("c1", inbox, behavior: .stuck, seen: seen)
        // The app takes its time; the target's plugin has answered meanwhile.
        let late = Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            Self.answer(inbox.files(for: header.target, nonce: header.nonce).ack, "ok")
        }
        let ack = try await deliver(message, plan: .carry(["c1"]), inbox: inbox)
        #expect(ack == "ok" && seen.orders.count == 1)
        stuck.cancel(); late.cancel()
    }

    @Test func aGateThatRefusesStopsTheOrderBeforeItIsWritten() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        let plugin = carrier("c1", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let ended = await failure { try await self.deliver(self.signed(), plan: .carry(["c1"]), inbox: inbox, gate: { "Stopped; nothing was done" }) }
        #expect(ended?.state == .refused && ended?.message == "Stopped; nothing was done")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(seen.orders.isEmpty)
        plugin.cancel()
    }

    @Test func aTaskStoppedWhileOrderedLeavesItUnsureNotNotSent() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        let plugin = carrier("c1", inbox, behavior: .stuck, seen: seen)
        let task = Task { try await self.deliver(self.signed(), plan: .carry(["c1"]), inbox: inbox, waits: .init(taken: 5, running: 30, cold: 30, opened: 5, interval: 0.01)) }
        while seen.orders.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        do { _ = try await task.value; Issue.record("sent") } catch let failure as RouterCarry.Failure {
            #expect(failure.state == .unsure)
        }
        plugin.cancel()
    }

    // MARK: The target's own inbox, and opening it

    @Test func withNoCarrierARunningTargetTakesItInItsOwnInbox() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        let message = signed()
        let plugin = owner("cli-target", inbox, reply: "ok model=opus", seen: seen)
        var updates: [RouterCarry.Update] = []
        let ack = try await deliver(message, plan: .direct, inbox: inbox, update: { updates.append($0) })
        #expect(ack == "ok model=opus" && updates.map(\.route) == [.direct] && seen.orders.map(\.text) == [message])
        plugin.cancel()
        // It refuses: said. It doesn't answer: unsure, not another way.
        let refuser = owner("cli-target", inbox, reply: "refused: stale", seen: seen)
        let refused = await failure { try await self.deliver(self.signed("two"), plan: .direct, inbox: inbox) }
        #expect(refused?.state == .refused && refused?.message == "The session's plugin refused the message: stale")
        refuser.cancel()
        var quiet = inbox
        quiet.timeout = 0.2
        let silent = await failure { try await self.deliver(self.signed("three"), plan: .direct, inbox: quiet) }
        #expect(silent?.state == .unsure)
    }

    /// A target's plugin that reads what is in its inbox and takes its time to answer (nil: never).
    private func slowOwner(_ cli: String, _ inbox: RelayInbox, reply: String?, after: TimeInterval, seen: Seen) -> Task<Void, Never> {
        Task.detached {
            var handled: Set<String> = []
            for _ in 0..<600 {
                if Task.isCancelled { return }
                let folder = inbox.folder(for: cli)
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".msg") && !handled.contains(name) {
                    guard let text = try? String(contentsOfFile: folder.appendingPathComponent(name).path, encoding: .utf8) else { continue }
                    handled.insert(name)
                    seen.add(cli, text)
                    if let reply {
                        try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                        Self.answer(folder.appendingPathComponent(String(name.dropLast(4)) + ".ack"), reply)
                    }
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    @Test func stoppingADirectDeliveryAfterThePluginReadItIsUnsureNotNothingWasSent() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        let plugin = slowOwner("cli-target", inbox, reply: nil, after: 0, seen: seen)
        let task = Task { try await self.deliver(self.signed(), plan: .direct, inbox: inbox, waits: .init(taken: 5, running: 30, cold: 30, opened: 5, interval: 0.01)) }
        while seen.orders.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        do { _ = try await task.value; Issue.record("sent") } catch let failure as RouterCarry.Failure {
            #expect(failure.state == .unsure && !failure.message.contains("nothing was sent"))
        }
        plugin.cancel()
    }

    @Test func stoppingADirectDeliveryBeforeItIsInPlaceStillSaysNothingWasSent() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        // The gate refuses: nothing was ever written.
        let gated = await failure { try await self.deliver(self.signed(), plan: .direct, inbox: inbox, gate: { "Stopped; nothing was done" }) }
        #expect(gated?.state == .refused)
    }

    @Test func aSendStoppedAfterTheTargetReadItIsKeptUnsureAndNeverClaimsNothingWasSent() async throws {
        let dir = TempDir()
        let s = store(dir)
        // Only the target runs: its own inbox is used.
        running("cli-target", dir, carries: false)
        let (tools, text) = tools(s, "hello")
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        let seen = Seen()
        let plugin = slowOwner("cli-target", inbox, reply: nil, after: 0, seen: seen)
        let task = Task { try await RouterSender.send(store: s, to: "Target", text: text, tools: tools, session: "local_t", body: "hello", waits: Self.fast) }
        while seen.orders.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        do { _ = try await task.value; Issue.record("sent") } catch {
            #expect(!(error is CancellationError) && !error.localizedDescription.contains("nothing was sent"), "\(error.localizedDescription)")
        }
        let kept = try #require(s.router.operations.first)
        #expect(kept.state == .unsure && kept.route == .direct && kept.reason?.contains("nothing was sent") != true)
        plugin.cancel()
    }

    @Test func aSleepingTargetWithNoCarrierIsOpenedThenGivenItsMessageInItsOwnInbox() async throws {
        let dir = TempDir()
        let inbox = RelayInbox(root: dir.path("relay"))
        let seen = Seen()
        final class Up: @unchecked Sendable { let lock = NSLock(); private var v = false; var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } } }
        let up = Up()
        var opened = 0
        let plugin = owner("cli-target", inbox, reply: "ok", seen: seen)
        var updates: [RouterCarry.Update] = []
        let ack = try await deliver(signed(), plan: .open, inbox: inbox, asleep: true, isUp: { up.value },
                                    open: { opened += 1; Task.detached { try? await Task.sleep(nanoseconds: 200_000_000); up.value = true } },
                                    update: { updates.append($0) })
        #expect(ack == "ok" && opened == 1 && updates.map(\.route) == [.opened] && seen.orders.count == 1)
        plugin.cancel()
        // It never comes up: it needs you, with nothing sent.
        let never = await failure { try await self.deliver(self.signed("two"), plan: .open, inbox: inbox, asleep: true, isUp: { false }) }
        #expect(never?.state == .needsYou && never?.message.contains("open it in the Claude app") == true && never?.message.contains("nothing was sent") == true)
    }

    // MARK: What the store keeps

    private func store(_ dir: TempDir) -> Store {
        let s = Store()
        s.persists = false
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.claudeSessions = ["local_t": ClaudeSession(id: "local_t", title: "Target", folder: "/code/api", completedTurns: 1,
                                                     lastActivity: Date(), running: false, cliID: "cli-target")]
        try? FileManager.default.createDirectory(at: dir.path("support"), withIntermediateDirectories: true)
        try? Data(Self.key.utf8).write(to: dir.path("support/relay.key"))
        PluginFixture.useKey(s)
        s.router.enabled = true
        s.agents.enabled = true
        return s
    }

    private func running(_ cli: String, _ dir: TempDir, carries: Bool = true, entrypoint: String = "claude-desktop", status: String = "idle",
                         updated: Int64 = 100) {
        var capabilities = ["inbox-v1", "settings-v1", "abort-v1", "stop-v1"]
        if carries { capabilities.append(ClaudePlugin.carryCapability) }
        PluginFixture.live(cli, support: dir.path("support"), claude: dir.path("claude"),
                           extra: ["capabilities": capabilities, "turn": NSNull()],
                           registryExtra: ["entrypoint": entrypoint, "status": status, "updatedAt": updated])
    }

    private func tools(_ s: Store, _ message: String, asleep: Bool = false) -> (RouterTools, String) {
        let text = RelaySigner.sign(body: "hello", target: "cli-target", key: Self.key)
        let tools = RouterTools(store: s)
        tools.beginTurn("hello")
        var prepared = Prepared(text: text, original: "hello", rephrased: false, body: "hello", local: "local_t")
        prepared.asleep = asleep
        tools.prepared["Target"] = prepared
        return (tools, text)
    }

    @Test func aSendIsKeptWaitingBeforeAnyOrderAndSentWhenTheTargetAnswers() async throws {
        let dir = TempDir()
        let s = store(dir)
        running("cli-target", dir)
        running("cli-carrier", dir)
        let (tools, text) = tools(s, "hello")
        let header = try #require(RelayInbox.header(of: text))
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        let seen = Seen()
        // When the order reaches the carrier, the operation is already kept, waiting.
        let state = Seen()
        let c = carrier("cli-carrier", inbox, behavior: .stuck, seen: seen)
        let plugin = Task.detached {
            while seen.orders.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            let kept = await MainActor.run { s.router.operations.first { $0.nonce == header.nonce } }
            state.add(kept?.state.rawValue ?? "none", kept?.bodyHash ?? "")
            // The target's plugin answers once the order has been seen.
            Self.answer(inbox.files(for: header.target, nonce: header.nonce).ack, "ok model=opus")
        }
        defer { c.cancel() }
        let ack = try await RouterSender.send(store: s, to: "Target", text: text, tools: tools, session: "local_t", decisionID: nil,
                                              body: "hello", waits: Self.fast)
        #expect(ack == "ok model=opus")
        #expect(state.orders.first?.carrier == "waiting" && state.orders.first?.text == DeliveryOperation.hash(of: "hello"))
        let kept = try #require(s.router.operations.first)
        #expect(s.router.operations.count == 1 && kept.nonce == header.nonce && kept.target == "cli-target" && kept.state == .sent)
        #expect(kept.kind == .message && kept.route == .carried && kept.carrier == "cli-carrier" && kept.reason == nil)
        // What it says is not the words.
        #expect(kept.bodyHash.count == 16 && !kept.bodyHash.contains("hello"))
        plugin.cancel()
    }

    /// What the persistence stand-in saw each time it was asked.
    final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var _seen: [(orders: Int, answers: Int, state: String)] = []
        var fail: [String?] = []
        func add(_ item: (orders: Int, answers: Int, state: String)) -> String? {
            lock.withLock { _seen.append(item); return fail.isEmpty ? nil : fail.removeFirst() }
        }
        var seen: [(orders: Int, answers: Int, state: String)] { lock.withLock { _seen } }
    }

    private func files(_ inbox: RelayInbox, _ cli: String, _ suffix: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: inbox.folder(for: cli).path)) ?? []).filter { $0.hasSuffix(suffix) }.count
    }

    @Test func theOperationIsOnDiskBeforeAnyOrderIsPublishedAndAMessageThatCantBeRecordedIsNotSent() async throws {
        let dir = TempDir()
        let s = store(dir)
        running("cli-target", dir)
        running("cli-carrier", dir)
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        let seen = Seen()
        let carrying = carrier("cli-carrier", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let writes = Writes()
        writes.fail = ["disk full"]
        s.persistStandIn = { [weak s] in
            let state = await MainActor.run { s?.router.operations.last?.state.rawValue ?? "none" }
            return writes.add((self.files(inbox, "cli-carrier", ".msg"), self.files(inbox, "cli-target", ".ack"), state))
        }
        let (tools, text) = tools(s, "hello")
        do {
            _ = try await RouterSender.send(store: s, to: "Target", text: text, tools: tools, session: "local_t", body: "hello", waits: Self.fast)
            Issue.record("sent")
        } catch {
            #expect(error.localizedDescription.contains("couldn't save") && error.localizedDescription.contains("nothing was sent"))
        }
        // Asked once, with the operation waiting and no order anywhere; then nothing was ever ordered.
        #expect(writes.seen.first?.orders == 0 && writes.seen.first?.state == "waiting")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(seen.orders.isEmpty && s.router.operations.last?.state == .refused)
        carrying.cancel()
    }

    @Test func theOutcomeIsOnDiskBeforeTheTargetsAnswerIsRemoved() async throws {
        let dir = TempDir()
        let s = store(dir)
        running("cli-target", dir)
        running("cli-carrier", dir)
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        let seen = Seen()
        let carrying = carrier("cli-carrier", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let writes = Writes()
        s.persistStandIn = { [weak s] in
            let state = await MainActor.run { s?.router.operations.last?.state.rawValue ?? "none" }
            return writes.add((self.files(inbox, "cli-carrier", ".msg"), self.files(inbox, "cli-target", ".ack"), state))
        }
        let (tools, text) = tools(s, "hello")
        let header = try #require(RelayInbox.header(of: text))
        _ = try await RouterSender.send(store: s, to: "Target", text: text, tools: tools, session: "local_t", body: "hello", waits: Self.fast)
        // The terminal write saw `sent` with the target's answer still in its folder; the answer is gone once it is written.
        let last = try #require(writes.seen.last)
        #expect(writes.seen.count == 2 && last.state == "sent" && last.answers == 1)
        #expect(files(inbox, "cli-target", ".ack") == 0)
        _ = header
        carrying.cancel()
    }

    @Test func anOutcomeThatCouldntBeWrittenLeavesTheTargetsAnswerForTheNextLaunch() async throws {
        let dir = TempDir()
        let s = store(dir)
        running("cli-target", dir)
        running("cli-carrier", dir)
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        let seen = Seen()
        let carrying = carrier("cli-carrier", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        let writes = Writes()
        writes.fail = [nil, "disk full"]
        s.persistStandIn = { writes.add((0, 0, "")) }
        let (tools, text) = tools(s, "hello")
        let header = try #require(RelayInbox.header(of: text))
        _ = try await RouterSender.send(store: s, to: "Target", text: text, tools: tools, session: "local_t", body: "hello", waits: Self.fast)
        // The record of `sent` didn't reach the disk: the evidence stays, for `settleLostOperations`.
        #expect(inbox.leftover(target: header.target, nonce: header.nonce) == "ok")
        carrying.cancel()
    }

    @Test func aSendTheTargetRefusesOrDoesntAnswerIsKeptWithItsReasonAndItsStateNeverSent() async throws {
        let dir = TempDir()
        let s = store(dir)
        running("cli-target", dir)
        running("cli-carrier", dir)
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        let seen = Seen()
        // Refused by the target.
        var (tools1, text1) = tools(s, "hello")
        let refusing = carrier("cli-carrier", inbox, behavior: .delivers(app: "ok", target: "refused: stale"), seen: seen)
        await #expect(throws: (any Error).self) {
            try await RouterSender.send(store: s, to: "Target", text: text1, tools: tools1, session: "local_t", waits: Self.fast)
        }
        let first = try #require(s.router.operations.first)
        #expect(first.state == .refused && first.reason == "The session's plugin refused the message: stale")
        refusing.cancel()
        // No answer from the target: unsure.
        let quiet = carrier("cli-carrier", inbox, behavior: .delivers(app: "ok", target: nil), seen: seen)
        (tools1, text1) = {
            let text = RelaySigner.sign(body: "again", target: "cli-target", key: Self.key)
            let t = RouterTools(store: s)
            t.beginTurn("again")
            t.prepared["Target"] = Prepared(text: text, original: "again", rephrased: false, body: "again", local: "local_t")
            return (t, text)
        }()
        do {
            _ = try await RouterSender.send(store: s, to: "Target", text: text1, tools: tools1, session: "local_t", waits: Self.fast)
            Issue.record("sent")
        } catch {
            #expect(error.localizedDescription.contains("It may not have arrived"), "\(error.localizedDescription)")
        }
        let second = try #require(s.router.operations.last)
        #expect(second.state == .unsure && second.nonce != first.nonce && second.reason?.contains("won't send it again by itself") == true)
        quiet.cancel()
    }

    @Test func aSessionWithAProcessButNoPluginIsNeverSentTo() async throws {
        let dir = TempDir()
        let s = store(dir)
        running("cli-carrier", dir)
        // Prepared for a session that runs (not asleep): its plugin isn't up now, so a carried message would read as a peer's.
        let (tools, text) = tools(s, "hello")
        do {
            _ = try await RouterSender.send(store: s, to: "Target", text: text, tools: tools, session: "local_t", waits: Self.fast)
            Issue.record("sent")
        } catch {
            #expect(error.localizedDescription.contains("plugin isn't running in that session"), "\(error.localizedDescription)")
        }
        #expect(s.router.operations.first?.state == .refused)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path("support/relay/cli-carrier").path)) ?? []).isEmpty)
    }

    @Test func aSleepingTargetIsOrderedThroughACarrierAndNoProcessIsEverRun() async throws {
        let dir = TempDir()
        let s = store(dir)
        running("cli-carrier", dir)
        let (tools, text) = tools(s, "hello", asleep: true)
        // Claude Code isn't known to the tools, nor to the store: the send has no binary to run.
        #expect(tools.claudePath() == nil)
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        let seen = Seen()
        let plugin = carrier("cli-carrier", inbox, behavior: .delivers(app: "Message delivered; its turn has started", target: "ok"), seen: seen)
        let ack = try await RouterSender.send(store: s, to: "Target", text: text, tools: tools, session: "local_t", kind: .firstMessage,
                                              waits: Self.fast)
        #expect(ack == "ok" && seen.orders.count == 1 && s.router.operations.first?.kind == .firstMessage)
        plugin.cancel()
    }

    @Test func withNoOtherSessionRunningARunningTargetIsGivenItsMessageInItsOwnInboxAndASleepingOneIsOpened() async throws {
        let dir = TempDir()
        let s = store(dir)
        running("cli-target", dir)
        let (tools, text) = tools(s, "hello")
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        let seen = Seen()
        let plugin = owner("cli-target", inbox, reply: "ok", seen: seen)
        _ = try await RouterSender.send(store: s, to: "Target", text: text, tools: tools, session: "local_t", waits: Self.fast)
        #expect(s.router.operations.first?.route == .direct && s.router.operations.first?.state == .sent)
        plugin.cancel()
        // Asleep, nothing else running: opened (the app is told), and when its plugin never comes up, it needs you.
        let dir2 = TempDir()
        let t = store(dir2)
        var opened: [String] = []
        t.interceptOpen = { opened.append($0) }
        let (tools2, text2) = self.tools(t, "hello", asleep: true)
        var stages: [String] = []
        tools2.stage = { stages.append($0) }
        await #expect(throws: (any Error).self) {
            try await RouterSender.send(store: t, to: "Target", text: text2, tools: tools2, session: "local_t",
                                        waits: .init(taken: 0.2, running: 0.5, cold: 0.5, opened: 0.3, interval: 0.01))
        }
        #expect(opened == ["Open in Claude · Target"] && stages == ["opening Target"])
        #expect(t.router.operations.first?.state == .needsYou && t.router.operations.first?.route == .opened)
    }

    @Test func aMessageLostWithAQuitIsLookedForInTheTargetsFolderThenLeftUnsureNeverOrderedAgain() async throws {
        let dir = TempDir()
        let s = store(dir)
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        func op(_ nonce: String, _ state: DeliveryOperation.State) -> DeliveryOperation {
            DeliveryOperation(nonce: nonce, target: "cli-target", kind: .message, bodyHash: "0123456789abcdef", state: state,
                              createdAt: Date(), updatedAt: Date())
        }
        s.noteOperation(op("went", .waiting))
        s.noteOperation(op("refused", .waiting))
        s.noteOperation(op("lost", .waiting))
        s.noteOperation(op("later", .unsure))
        s.noteOperation(op("done", .sent))
        for (nonce, reply) in [("went", "ok model=opus"), ("refused", "refused: stale"), ("later", "ok")] {
            try FileManager.default.createDirectory(at: inbox.folder(for: "cli-target"), withIntermediateDirectories: true)
            try Data((reply + "\n").utf8).write(to: inbox.files(for: "cli-target", nonce: nonce).ack)
        }
        s.settleLostOperations()
        func state(_ nonce: String) -> DeliveryOperation? { s.router.operations.first { $0.nonce == nonce } }
        #expect(state("went")?.state == .sent && state("refused")?.state == .refused && state("refused")?.reason == "stale")
        #expect(state("lost")?.state == .unsure && state("lost")?.reason == "Fjord quit while it was being delivered")
        #expect(state("later")?.state == .sent && state("done")?.state == .sent)
        // Nothing was written anywhere: no order is made for a lost message.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path("support/relay").path)) ?? []) == ["cli-target"])
    }

    @Test func aTargetsAnswerFoundAfterAQuitMakesTheHistoryShowItDeliveredNotFailed() async throws {
        let dir = TempDir()
        let s = store(dir)
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        func pending(_ text: String) -> UUID { s.logDecision(RouterDecision(trigger: .you(text), decision: .init(intent: "send"))) }
        let went = pending("ship it"), refused = pending("stale one"), quiet = pending("nobody answers")
        func op(_ nonce: String, _ id: UUID) -> DeliveryOperation {
            DeliveryOperation(nonce: nonce, target: "cli-target", kind: .message, bodyHash: "0123456789abcdef", state: .waiting,
                              decisionID: id, session: "local_t", to: "Target", createdAt: Date(), updatedAt: Date())
        }
        s.noteOperation(op("went", went)); s.noteOperation(op("refused", refused)); s.noteOperation(op("quiet", quiet))
        // Fjord quits with the three runs pending; loading ends them as interrupted.
        var loaded = s.router
        loaded.settleInterrupted()
        s.router = loaded
        func done(_ id: UUID) -> [RouterDecision.Done] { s.router.record(id)?.done ?? [] }
        #expect(done(went) == [.failed("interrupted")])
        // The target's plugin answered while Fjord was down.
        try FileManager.default.createDirectory(at: inbox.folder(for: "cli-target"), withIntermediateDirectories: true)
        try Data("ok\n".utf8).write(to: inbox.files(for: "cli-target", nonce: "went").ack)
        try Data("refused: stale\n".utf8).write(to: inbox.files(for: "cli-target", nonce: "refused").ack)
        s.settleLostOperations()
        #expect(done(went) == [.sent(to: "Target", text: "ship it", original: nil)])
        #expect(s.router.record(went)?.delivered?.nonce == "went" && s.router.record(went)?.links.sessions == ["local_t"])
        #expect(done(refused) == [.failed("stale")])
        // Without an answer it is unsure, and says so rather than "interrupted".
        let line = done(quiet).compactMap { item -> String? in if case .failed(let why) = item { why } else { nil } }.first
        #expect(line?.hasPrefix("It may not have arrived") == true)
        // The history the page draws is made from these.
        let shown = s.routerHistory.compactMap { entry -> RouterDecision? in if case .decision(let d) = entry { d } else { nil } }
        #expect(shown.first { $0.id == went }?.done == [.sent(to: "Target", text: "ship it", original: nil)])
    }

    @Test func aFirstMessageOfAForkLostWithAQuitIsNotToldAsNeverSentOnceItsAnswerIsFound() async throws {
        let dir = TempDir()
        let s = store(dir)
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        let id = s.logDecision(RouterDecision(trigger: .you("fork it"), decision: .init(intent: "fork")))
        s.updateDecision(id) { $0.add(.started(session: "local_t", project: "api (fork)", model: nil, effort: nil), session: "local_t") }
        s.noteOperation(DeliveryOperation(nonce: "first", target: "cli-target", kind: .firstMessage, bodyHash: "0123456789abcdef",
                                          state: .waiting, decisionID: id, session: "local_t", to: "Target", createdAt: Date(), updatedAt: Date()))
        var loaded = s.router
        loaded.settleInterrupted()
        s.router = loaded
        try FileManager.default.createDirectory(at: inbox.folder(for: "cli-target"), withIntermediateDirectories: true)
        try Data("ok\n".utf8).write(to: inbox.files(for: "cli-target", nonce: "first").ack)
        s.settleLostOperations()
        let items = s.router.record(id)?.done ?? []
        #expect(items.count == 2 && !items.contains { if case .failed = $0 { true } else { false } })
    }

    // MARK: A start's session survives a Retry

    /// A stand-in for Claude Code that counts its runs (one line each, in `runs`) and answers like a bootstrap.
    private func counting(_ dir: TempDir) -> String {
        let path = dir.path("claude").path
        let script = "#!/bin/sh\necho run >> \"\(dir.path("runs").path)\"\ncat <<'EOF'\n{\"type\":\"result\",\"is_error\":false,\"result\":\"\"}\nEOF\n"
        FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    private func runs(_ dir: TempDir) -> Int {
        ((try? String(contentsOf: dir.path("runs"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    @Test func aSessionIsReservedOnDiskBeforeItIsMadeAndARetryContinuesWithItNotAnotherOne() async throws {
        let dir = TempDir()
        let s = store(dir)
        try FileManager.default.createDirectory(at: dir.path("code"), withIntermediateDirectories: true)
        let binary = counting(dir)
        let opened = Seen()
        s.interceptOpen = { opened.add($0, "") }
        let writes = Writes()
        s.persistStandIn = { [weak s] in
            let kept = await MainActor.run { s?.router.starts.last }
            return writes.add((self.runs(dir), 0, kept.map { "\($0.uuid) \($0.stage.rawValue)" } ?? "none"))
        }
        // The first attempt: the app never imports it.
        let first = RouterTools(store: s)
        first.beginTurn("make it")
        first.decision = UUID()
        first.claudePath = { binary }
        first.importedStandIn = { _ in false }
        first.importTimeout = 0.3
        await #expect(throws: (any Error).self) {
            _ = try await first.start(s, folder: dir.path("code").path, name: "code", title: "T", ticket: first.ticket())
        }
        // The reservation was on disk before the bootstrap ran, and the bootstrap ran once.
        let reserved = try #require(writes.seen.first)
        #expect(reserved.orders == 0 && reserved.state.hasSuffix(" reserved"))
        #expect(runs(dir) == 1)
        let kept = try #require(s.openStart(for: first.decision!))
        #expect(kept.stage == .bootstrapped)
        // Retry: the same session, no second run of Claude Code, and the app is asked to open it again.
        let again = RouterTools(store: s)
        again.beginTurn("make it")
        again.decision = UUID()
        again.claudePath = { binary }
        again.importedStandIn = { _ in true }
        again.reuseStart = kept.uuid
        let started = try await again.start(s, folder: dir.path("code").path, name: "code", title: "T", ticket: again.ticket())
        #expect(started.sessionID == "local_\(kept.uuid)" && runs(dir) == 1 && s.router.starts.count == 1)
        #expect(s.router.starts.first?.stage == .imported && s.router.starts.first?.decisionID == again.decision)
        // Imported already, and its first message failed: a third attempt neither runs nor opens anything.
        let opens = opened.orders.count
        let third = RouterTools(store: s)
        third.beginTurn("make it")
        third.decision = UUID()
        third.claudePath = { binary }
        third.importedStandIn = { _ in false }
        third.importTimeout = 0.1
        third.reuseStart = kept.uuid
        let last = try await third.start(s, folder: dir.path("code").path, name: "code", title: "T", ticket: third.ticket())
        #expect(last.sessionID == started.sessionID && runs(dir) == 1 && opened.orders.count == opens && s.router.starts.count == 1)
    }

    @Test func aReservationForAnotherFolderOrAlreadyDeliveredIsNotContinued() async throws {
        let dir = TempDir()
        let s = store(dir)
        try FileManager.default.createDirectory(at: dir.path("code"), withIntermediateDirectories: true)
        let binary = counting(dir)
        s.interceptOpen = { _ in }
        s.noteStart(StartReservation(uuid: "old", decisionID: nil, folder: "/elsewhere", title: "T", stage: .imported, createdAt: Date()))
        s.noteStart(StartReservation(uuid: "done", decisionID: nil, folder: dir.path("code").path, title: "T", stage: .delivered, createdAt: Date()))
        for reuse in ["old", "done"] {
            let tools = RouterTools(store: s)
            tools.beginTurn("make it")
            tools.claudePath = { binary }
            tools.importedStandIn = { _ in true }
            tools.reuseStart = reuse
            let started = try await tools.start(s, folder: dir.path("code").path, name: "code", title: "T", ticket: tools.ticket())
            #expect(started.sessionID != "local_\(reuse)")
        }
        #expect(runs(dir) == 2)
    }

    @Test func aFirstMessageThatWentEndsItsStartAndOneThatFailedLeavesItOpen() async throws {
        let dir = TempDir()
        let s = store(dir)
        running("cli-target", dir)
        running("cli-carrier", dir)
        let inbox = RelayInbox(root: try #require(s.routerFiles).relay)
        let seen = Seen()
        s.noteStart(StartReservation(uuid: "t", decisionID: nil, folder: "/code/api", title: "T", stage: .imported, createdAt: Date()))
        let (tools, text) = tools(s, "hello")
        // Refused by the target: nothing went, the session is still there for a Retry.
        let refusing = carrier("cli-carrier", inbox, behavior: .delivers(app: "ok", target: "refused: stale"), seen: seen)
        await #expect(throws: (any Error).self) {
            try await RouterSender.send(store: s, to: "Target", text: text, tools: tools, session: "local_t", kind: .firstMessage, waits: Self.fast)
        }
        #expect(s.router.starts.first?.stage == .imported)
        refusing.cancel()
        // The retry's message is sent.
        let second = RelaySigner.sign(body: "hello", target: "cli-target", key: Self.key)
        let t2 = RouterTools(store: s)
        t2.beginTurn("hello")
        t2.prepared["Target"] = Prepared(text: second, original: "hello", rephrased: false, body: "hello", local: "local_t")
        let working = carrier("cli-carrier", inbox, behavior: .delivers(app: "ok", target: "ok"), seen: seen)
        _ = try await RouterSender.send(store: s, to: "Target", text: second, tools: t2, session: "local_t", kind: .firstMessage, waits: Self.fast)
        #expect(s.router.starts.first?.stage == .delivered)
        working.cancel()
    }

    @Test func operationsAreKeptInTheRoutersStateAndOnlyTheLatestAreKept() throws {
        let s = Store()
        s.persists = false
        for i in 0..<(DeliveryOperation.kept + 5) {
            s.noteOperation(DeliveryOperation(nonce: "n\(i)", target: "cli", kind: .message, bodyHash: "h", state: .waiting,
                                              createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)))
        }
        #expect(s.router.operations.count == DeliveryOperation.kept && s.router.operations.first?.nonce == "n5")
        s.updateOperation("n6") { $0.state = .sent }
        #expect(s.router.operations.first { $0.nonce == "n6" }?.state == .sent)
        // They survive the state's own coding, and a state from before has none.
        let data = try JSONEncoder().encode(s.router)
        #expect(try JSONDecoder().decode(RouterState.self, from: data).operations == s.router.operations)
        let old = try JSONDecoder().decode(RouterState.self, from: Data(#"{"enabled":true,"relay":{"sessionID":"x","cliID":"y"}}"#.utf8))
        #expect(old.operations.isEmpty && old.enabled)
    }
}
