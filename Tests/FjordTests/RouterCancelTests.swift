import Foundation
import Testing
@testable import Fjord

/// Cancel: the abort Fjord signs (the vector the plugin's tests check too), its trip through the inbox, how a cancel is
/// recorded on its entry and in the trace, when the history offers it, and a wrong send sent elsewhere.
@MainActor
@Suite(.serialized) struct RouterCancelTests {
    // MARK: The abort

    @Test func theAbortIsSignedAsThePluginChecksIt() throws {
        // The vector of `Resources/ClaudePlugin/tests/relay.test.ts` ("taking a delivery back").
        let now = Date(timeIntervalSince1970: Double(RelaySigning.ts) / 1000)
        let abort = RelaySigner.signAbort(target: RelaySigning.target, cancels: RelaySigning.nonce, key: RelaySigning.key,
                                          nonce: UUID(uuidString: "323e4567-e89b-12d3-a456-426614174000")!, now: now)
        #expect(abort == "⟦fjord abort v1 cli-target 323e4567-e89b-12d3-a456-426614174000 2000000000000 \(RelaySigning.nonce) "
            + "0dbaf1b1ec9728c6d3c3e507515ae0c1ba74dccda5c17011ccfb04a3f688a66a⟧\n")
        // The inbox goes by its own nonce, for its own ack; it is no delivery's text.
        let header = try #require(RelayInbox.header(of: abort))
        #expect(header.target == "cli-target" && header.nonce == "323e4567-e89b-12d3-a456-426614174000")
    }

    @Test func theAbortGoesThroughTheInboxAndItsAckSaysHowFarItHadGone() async throws {
        let dir = TempDir()
        var inbox = RelayInbox(root: dir.path("relay"))
        inbox.timeout = waitWatchdog  // a watchdog: the fake plugin answers as soon as it sees the file
        let abort = RelaySigner.signAbort(target: "cli-a", cancels: RelaySigning.nonce, key: RelaySigning.key)
        let nonce = try #require(RelayInbox.header(of: abort)?.nonce)
        let folder = inbox.folder(for: "cli-a")
        let fake = Task.detached { () -> String? in
            var watchdog = Watchdog()
            while !watchdog.expired() {
                if let text = try? String(contentsOf: folder.appendingPathComponent("\(nonce).msg"), encoding: .utf8) {
                    try? Data("ok aborted\n".utf8).write(to: folder.appendingPathComponent("\(nonce).ack"), options: .atomic)
                    return text
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return nil
        }
        let ack = try await inbox.deliver(abort, to: "cli-a")
        #expect(await fake.value == abort)
        #expect(RouterDecision.Cancelled(ack: ack) == .aborted)
    }

    @Test func theAckIsReadStrictly() {
        #expect(RouterDecision.Cancelled(ack: "ok before-start") == .beforeStart)
        #expect(RouterDecision.Cancelled(ack: "ok aborted") == .aborted)
        #expect(RouterDecision.Cancelled(ack: "ok too-late") == .tooLate)
        #expect(RouterDecision.Cancelled(ack: "ok together") == .together && !RouterDecision.Cancelled.together.stopped)
        #expect(RouterDecision.Cancelled(ack: "ok unknown") == .unknown && !RouterDecision.Cancelled.unknown.stopped)
        #expect(RouterDecision.Cancelled(ack: "ok") == nil)
        #expect(RouterDecision.Cancelled(ack: "ok model=opus") == nil)
        #expect(RouterDecision.Cancelled(ack: "aborted") == nil)
    }

    // MARK: When it's offered

    private static let sentAt = Date(timeIntervalSince1970: 1_900_000_000)

    private static func delivered(turns: Int = 3, busy: Bool = false, abortable: Bool = true) -> RouterDecision.Delivered {
        .init(session: "local_a", cli: "cli-a", nonce: RelaySigning.nonce, at: sentAt, turns: turns, busy: busy, abortable: abortable)
    }

    private static func session(turns: Int, archived: Bool = false) -> ClaudeSession {
        ClaudeSession(id: "local_a", title: "Fix the login bug", folder: "/code/lookout", isArchived: archived, completedTurns: turns,
                      lastActivity: sentAt)
    }

    @Test func cancelIsOfferedUntilItsTurnFinishes() {
        let soon = Self.sentAt.addingTimeInterval(30)
        let idle = Self.delivered()
        #expect(idle.cancellable(session: Self.session(turns: 3), now: soon))
        // Its own turn finished: nothing left to stop.
        #expect(!idle.cancellable(session: Self.session(turns: 4), now: soon))
        // Sent behind a running turn: that one finishing is not its own.
        let queued = Self.delivered(busy: true)
        #expect(queued.cancellable(session: Self.session(turns: 4), now: soon))
        #expect(!queued.cancellable(session: Self.session(turns: 5), now: soon))
        // A session not read yet (just started) is given the window; an archived one isn't.
        #expect(idle.cancellable(session: nil, now: soon))
        #expect(!idle.cancellable(session: Self.session(turns: 3, archived: true), now: soon))
    }

    @Test func cancelIsNotOfferedLateOnceDoneOrWhereThePluginCantDoIt() {
        let soon = Self.sentAt.addingTimeInterval(30)
        #expect(!Self.delivered().cancellable(session: Self.session(turns: 3), now: Self.sentAt.addingTimeInterval(11 * 60)))
        #expect(!Self.delivered(abortable: false).cancellable(session: Self.session(turns: 3), now: soon))
        var done = Self.delivered()
        done.cancelled = .tooLate
        #expect(!done.cancellable(session: Self.session(turns: 3), now: soon))
    }

    @Test func theStoreOffersItOnlyForAnEntryThatDeliveredSomething() {
        let s = InboxFixture.store([])
        s.claudeSessions = ["local_a": Self.session(turns: 3)]
        var entry = RouterDecision(at: Self.sentAt, trigger: .you("hi"), outcome: .done)
        #expect(!s.canCancel(entry, now: Self.sentAt))
        entry.delivered = Self.delivered()
        #expect(s.canCancel(entry, now: Self.sentAt.addingTimeInterval(5)))
        s.claudeSessions["local_a"]?.completedTurns = 4
        #expect(!s.canCancel(entry, now: Self.sentAt.addingTimeInterval(5)))
    }

    @Test func anEntryFromBeforeReadsWithoutADelivery() throws {
        let entry = RouterDecision(at: Self.sentAt, trigger: .you("hi"), done: [.sent(to: "p", text: "hi", original: nil)], outcome: .done)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json["delivered"] = nil
        let read = try JSONDecoder().decode(RouterDecision.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.delivered == nil && read.done == entry.done)
        // And one with a cancel keeps it.
        var cancelled = entry
        cancelled.delivered = Self.delivered()
        cancelled.delivered?.cancelled = .beforeStart
        cancelled.add(.cancelled(.beforeStart))
        #expect(try JSONDecoder().decode(RouterDecision.self, from: JSONEncoder().encode(cancelled)) == cancelled)
    }

    @Test func theLineSaysItWasCancelledAndHow() {
        var entry = RouterDecision(at: Self.sentAt, trigger: .you("hi"), done: [.sent(to: "Fix the login bug", text: "hi", original: nil)],
                                   outcome: .done)
        entry.delivered = Self.delivered()
        #expect(entry.summary == "sent to Fix the login bug")
        entry.delivered?.cancelled = .aborted
        entry.add(.cancelled(.aborted))
        #expect(entry.summary == "cancelled" && entry.symbol == "xmark.circle")
        #expect(entry.doneLines.last?.contains("what it already did stays done") == true)
        #expect(entry.contextLine(now: Self.sentAt).contains("cancelled"))
        // Too late: it was sent, and stays so.
        var late = entry
        late.delivered?.cancelled = .tooLate
        late.done = [late.done[0], .cancelled(.tooLate)]
        #expect(late.summary == "sent to Fix the login bug +1" && late.symbol == "paperplane")
    }

    // MARK: The dispatcher

    /// A store and a dispatcher whose sends are signed as the real ones are (so a delivery's nonce is known), with the
    /// plugin's answer to an abort stood in for.
    @MainActor private final class World {
        let dir = TempDir()
        let store: Store
        let dispatcher: RouterDispatcher
        let fakes = RouterDispatcherTests.Fakes()
        var cancels: [RouterDecision.Delivered] = []
        var answer: Result<RouterDecision.Cancelled, Error> = .success(.aborted)
        var abortable = true
        var nonces: [String] = []

        init() {
            let s = InboxFixture.store([])
            s.categories = [InboxStore.ci]
            s.router.enabled = true
            s.agents.enabled = true
            s.claudeSessions = [
                "local_a": ClaudeSession(id: "local_a", title: "Fix the login bug", folder: "/code/lookout", completedTurns: 3,
                                         lastActivity: Date(), running: true),
                "local_b": ClaudeSession(id: "local_b", title: "Update the docs", folder: "/code/docs", completedTurns: 7,
                                         lastActivity: Date().addingTimeInterval(-60)),
            ]
            store = s
            dispatcher = RouterDispatcher(store: s)
            fakes.install(dispatcher)
            fakes.store = s
            dispatcher.effects.prepare = { [unowned self] _, session in
                fakes.prepared.append(session)
                let signed = RelaySigner.sign(body: "body-\(session)", target: "cli-\(session)", key: RelaySigning.key)
                nonces.append(RelayInbox.header(of: signed)!.nonce)
                return RouterDispatcher.Delivery(to: "peer-\(session)", text: signed, body: "body-\(session)", original: "orig",
                                                 rephrased: false, session: session)
            }
            dispatcher.effects.abortable = { [unowned self] _ in abortable }
            dispatcher.effects.cancel = { [unowned self] sent in
                cancels.append(sent)
                return try answer.get()
            }
        }

        func entry(_ id: UUID?) -> RouterDecision? { store.router.decisions.first { $0.id == id } }

        func finish(_ id: UUID?) async {
            await waitUntil { id.map { fakes.finished.contains($0) } ?? true }
        }

    }









}
