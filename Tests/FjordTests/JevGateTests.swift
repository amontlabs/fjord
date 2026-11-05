import Foundation
import Testing
@testable import Fjord

/// TypeSafe's failures, typed, and the one gate every call to Jev goes through.
@MainActor
@Suite(.serialized) struct JevGateTests {
    private func response(_ status: Int, headers: [String: String] = [:]) -> JevClient.Transport {
        { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    private func failure(_ transport: @escaping JevClient.Transport) async -> JevClient.Failure? {
        var client = JevClient(key: "k")
        client.transport = transport
        do {
            _ = try await client.ask(["q": .noul(instructions: "?")], about: "x")
            return nil
        } catch {
            return error as? JevClient.Failure
        }
    }

    @Test func failuresAreTyped() async {
        #expect(await failure(response(401)) == .unauthorized)
        #expect(await failure(response(429, headers: ["Retry-After": "7"])) == .rateLimited(retryAfter: 7))
        #expect(await failure(response(429)) == .rateLimited(retryAfter: nil))
        #expect(await failure(response(529)) == .overloaded(retryAfter: nil))
        #expect(await failure(response(500)) == .transport("TypeSafe returned 500"))
        if case .refused = await failure(response(422)) {} else { Issue.record("422 isn't refused") }
        #expect(await failure { _ in throw URLError(.cancelled) } == .cancelled)
        #expect(await failure { _ in throw CancellationError() } == .cancelled)
        if case .transport = await failure({ _ in throw URLError(.notConnectedToInternet) }) {} else { Issue.record("offline isn't transport") }
        if case .invalidAnswer = await failure(response(200)) {} else { Issue.record("an empty answer isn't invalid") }
    }

    @Test func theGateLatchesARejectedKeyHonoursRetryAfterAndBacksOff() {
        let gate = JevGate()
        var now = Date(timeIntervalSince1970: 1_000_000)
        gate.now = { now }
        gate.failed(JevClient.Failure.unauthorized, key: "old")
        #expect(!gate.isOpen(for: "old") && gate.isOpen(for: "other"))
        // Retry-After, then nothing until it passes.
        gate.failed(JevClient.Failure.rateLimited(retryAfter: 90), key: "k")
        #expect(!gate.isOpen(for: "k"))
        now += 89
        #expect(!gate.isOpen(for: "k"))
        now += 2
        #expect(gate.isOpen(for: "k"))
        // Failures in a row wait longer each time (the rate limit above was the first).
        gate.failed(JevClient.Failure.transport("offline"), key: "k")
        #expect(gate.until == now.addingTimeInterval(JevGate.shortest * 2))
        now = gate.until
        gate.failed(JevClient.Failure.overloaded(retryAfter: nil), key: "k")
        #expect(gate.until == now.addingTimeInterval(JevGate.shortest * 4))
        // A call that worked starts over; odd answers and refusals are that call's alone; other errors aren't TypeSafe's.
        gate.succeeded()
        gate.failed(JevClient.Failure.invalidAnswer("odd"), key: "k")
        gate.failed(JevClient.Failure.refused("bad"), key: "k")
        gate.failed(URLError(.timedOut), key: "k")
        #expect(gate.isOpen(for: "k") && gate.failures == 0)
        // Still latched until a new key is saved.
        #expect(!gate.isOpen(for: "old"))
        gate.keyChanged()
        #expect(gate.isOpen(for: "old"))
    }

    private func store() -> Store {
        let s = InboxFixture.store([])
        s.router.enabled = true
        s.agents.enabled = true
        s.typesafeKeyCache = "sk-old"
        s.hasTypesafeKey = true
        s.keychainWrite = { _, _ in true }
        return s
    }

    @Test func aRejectedKeyStopsEveryUseUntilANewOneIsSaved() async {
        let s = store()
        var sent: [String] = []
        s.jevGate.transport = { request in
            sent.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let routing = s.jevAsker(.routing)
        await #expect(throws: JevClient.Failure.unauthorized) { try await routing?(["q": .noul(instructions: "?")], [:]) }
        #expect(sent == ["Bearer sk-old"])
        // The routing's chooser, the icons and the inbox don't call with it either.
        await #expect(throws: JevClient.Failure.unauthorized) { try await s.jevChooser(.routing)?(["a"], [:], [:], "") }
        s.agents.iconsEnabled = true
        await #expect(throws: JevClient.Failure.unauthorized) { try await s.jevChooser(.icons)?(["a"], [:], [:], "") }
        #expect(!s.jevGate.isOpen(for: "sk-old") && sent.count == 1)
        // A new key is tried.
        #expect(s.setTypesafeKey("sk-new"))
        _ = try? await s.jevAsker(.routing)?(["q": .noul(instructions: "?")], [:])
        #expect(sent == ["Bearer sk-old", "Bearer sk-new"])
    }

    @Test func aBusyTypeSafeIsLeftAloneByEveryUse() async {
        let s = store()
        var calls = 0
        s.inboxAsker = { _, _ in calls += 1; throw JevClient.Failure.overloaded(retryAfter: 60) }
        let routing: JevAsker = { _, _ in calls += 1; return [:] }
        await #expect(throws: JevClient.Failure.overloaded(retryAfter: 60)) {
            try await s.throughJevGate(.inbox, generation: s.jevGate.generation) { try await s.inboxAsker!([:], [:]) }
        }
        await #expect(throws: JevClient.Failure.overloaded(retryAfter: 60)) {
            try await s.jevAsker(.routing, base: routing)?([:], [:])
        }
        #expect(calls == 1)
    }

    @Test func anOlderCallThatWorkedDoesntLiftANewerPause() async throws {
        let s = store()
        let latch = Latch()
        var inside = false
        // B is let through and still asks when A is told to wait a minute.
        let b = Task { try await s.throughJevGate(.inbox, generation: s.jevGate.generation) { inside = true; await latch.wait(); return 1 } }
        while !inside { await Task.yield() }
        await #expect(throws: JevClient.Failure.rateLimited(retryAfter: 60)) {
            try await s.throughJevGate(.inbox, generation: s.jevGate.generation) { () async throws -> Int in throw JevClient.Failure.rateLimited(retryAfter: 60) }
        }
        latch.open = true
        #expect(try await b.value == 1)
        // C still waits.
        var asked = false
        await #expect(throws: JevClient.Failure.rateLimited(retryAfter: 60)) {
            try await s.throughJevGate(.inbox, generation: s.jevGate.generation) { asked = true; return 1 }
        }
        #expect(!asked && s.jevGate.failures == 1)
        // A call let through after it does start over.
        let pauses = s.jevGate.pauses
        s.jevGate.succeeded(since: pauses)
        #expect(s.jevGate.isOpen(for: "sk-old") && s.jevGate.failures == 0)
    }

    @Test func anAnswerAfterTheKeyOrTheSwitchChangedIsDropped() async {
        let s = store()
        var flip: () -> Void = {}
        let ask = s.jevAsker(.routing, base: { _, _ in flip(); return ["q": .noul(1)] })
        flip = { _ = s.setTypesafeKey("sk-other") }
        await #expect(throws: JevClient.Failure.cancelled) { try await ask?([:], [:]) }
        // Taken before the switch went off, it asks nothing.
        var asked = false
        let off = s.jevAsker(.routing, base: { _, _ in asked = true; return [:] })
        s.router.enabled = false
        await #expect(throws: JevClient.Failure.cancelled) { try await off?([:], [:]) }
        #expect(!asked && s.jevAsker(.routing, base: { _, _ in [:] }) == nil)
    }

    @Test func aRejectionOfAKeySinceReplacedIsDroppedAndPausesNoIcons() async {
        let s = store()
        s.agents.iconsEnabled = true
        let old = s.jevChooser(.icons, base: { _, _, _, _ in
            _ = s.setTypesafeKey("sk-new")
            throw JevClient.Failure.unauthorized
        })
        await #expect(throws: JevClient.Failure.cancelled) { try await old?(["a"], [:], [:], "") }
        #expect(s.jevGate.isOpen(for: "sk-new") && s.jevGate.isOpen(for: "sk-old"))
        // A cancelled call's failure is dropped too.
        let task = Task { try await s.throughJevGate(.icons, generation: s.jevGate.generation) { () async throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            throw JevClient.Failure.unauthorized
        } }
        await #expect(throws: JevClient.Failure.cancelled) { try await task.value }
        #expect(s.jevGate.isOpen(for: "sk-new"))
        // The icons take it as nothing failed: no pause.
        s.iconPickFailed(JevClient.Failure.cancelled)
        #expect(s.iconsPausedUntil < .distantFuture && s.iconError == nil)
    }

    /// Lets a read go on once opened (from any thread).
    final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        var open: Bool {
            get { lock.lock(); defer { lock.unlock() }; return isOpen }
            set { lock.lock(); isOpen = newValue; lock.unlock() }
        }
        func wait() async { while !open { try? await Task.sleep(for: .milliseconds(2)) } }
    }

    @Test func anIconUnderWayAsksNothingOnceIconsAreOffOrTheKeyChanged() async throws {
        let s = store()
        s.agents.iconsEnabled = true
        s.agents.enabledAt = Date().addingTimeInterval(-3600)
        s.ingest([ClaudeSession(id: "a", title: "Fix the login", folder: "/code/app", completedTurns: 1, lastActivity: Date(), cliID: "cli-a")],
                 appUnread: [], claudeFrontmost: false, now: Date())
        let latch = Latch()
        s.iconFirstMessage = { _ in while !latch.open { Thread.sleep(forTimeInterval: 0.002) }; return "Fix the login form" }
        var asked = 0
        s.iconChooser = { options, _, _, _ in asked += 1; return .init(choice: options[0], confidence: 1, probabilities: [options[0]: 1]) }
        s.pickIcons()
        let first = try #require(s.iconTask)
        // Icons turned off while the transcript is read: nothing is asked.
        s.setIconsEnabled(false)
        latch.open = true
        await first.value
        #expect(asked == 0 && s.agents.entries.first?.icon == nil)
        // On again, and the key changes while it is read: the old pick asks nothing, the new one does.
        latch.open = false
        s.setIconsEnabled(true)
        let second = try #require(s.iconTask)
        #expect(s.setTypesafeKey("sk-new"))
        latch.open = true
        await second.value
        while let task = s.iconTask { await task.value }
        #expect(asked == 2 && s.agents.entries.first?.icon != nil)
    }
}
