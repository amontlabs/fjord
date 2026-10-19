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
                                                 rephrased: false, session: session, newSessionIn: nil)
            }
            dispatcher.effects.abortable = { [unowned self] _ in abortable }
            dispatcher.effects.cancel = { [unowned self] sent in
                cancels.append(sent)
                return try answer.get()
            }
            dispatcher.traceLog = RouterTraceLog(url: dir.path("router-trace.jsonl"))
        }

        func entry(_ id: UUID?) -> RouterDecision? { store.router.decisions.first { $0.id == id } }

        func finish(_ id: UUID?) async {
            await waitUntil { id.map { fakes.finished.contains($0) } ?? true }
        }

        func trace() -> [RouterTrace] {
            dispatcher.traceLog.flush()
            guard let url = dispatcher.traceLog.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return text.split(separator: "\n").compactMap { try? decoder.decode(RouterTrace.self, from: Data($0.utf8)) }
        }
    }

    @Test func aSendRecordsWhatItDeliveredForACancel() async throws {
        let w = World()
        w.fakes.ranked = [.init(target: "session:local_b", p: 0.95)]
        let id = w.dispatcher.submit("add a changelog entry")
        await w.finish(id)
        let sent = try #require(w.entry(id)?.delivered)
        #expect(sent.session == "local_b" && sent.cli == "cli-local_b" && sent.nonce == w.nonces.first)
        // The session as it was just before: 7 turns finished, none running.
        #expect(sent.turns == 7 && !sent.busy && sent.abortable && sent.cancelled == nil)
        #expect(w.store.canCancel(w.entry(id)!))
    }

    @Test func aCancelIsRecordedOnTheEntryAndInTheTrace() async throws {
        let w = World()
        w.fakes.ranked = [.init(target: "session:local_b", p: 0.95)]
        let id = try #require(w.dispatcher.submit("add a changelog entry"))
        await w.finish(id)
        #expect(await w.dispatcher.cancel(id) == .aborted)
        #expect(w.cancels.map(\.nonce) == [w.nonces[0]])
        let entry = try #require(w.entry(id))
        #expect(entry.delivered?.cancelled == .aborted && entry.done.last == .cancelled(.aborted))
        #expect(entry.summary == "cancelled" && !w.store.canCancel(entry))
        let line = try #require(w.trace().first { $0.kind == .cancelled })
        #expect(line.id == id && line.how == "aborted" && line.target == "session:local_b" && line.elsewhere == nil)
        #expect((line.after ?? -1) >= 0)
        // Once is all: a second cancel sends nothing.
        #expect(await w.dispatcher.cancel(id) == nil)
        #expect(w.cancels.count == 1)
    }

    @Test func aCancelThatFailsSaysSoAndCanBeTriedAgain() async throws {
        let w = World()
        w.fakes.ranked = [.init(target: "session:local_b", p: 0.95)]
        let id = try #require(w.dispatcher.submit("add a changelog entry"))
        await w.finish(id)
        w.answer = .failure(RouterTools.Failure("The session's plugin didn't pick the message up"))
        #expect(await w.dispatcher.cancel(id) == nil)
        #expect(w.entry(id)?.done.last == .failed("couldn't cancel: The session's plugin didn't pick the message up"))
        #expect(w.entry(id)?.delivered?.cancelled == nil && w.store.canCancel(w.entry(id)!))
        #expect(!w.trace().contains { $0.kind == .cancelled })
        w.answer = .success(.tooLate)
        #expect(await w.dispatcher.cancel(id) == .tooLate)
        #expect(w.entry(id)?.summary.hasPrefix("sent to") == true)
    }

    @Test func aSessionWhosePluginCantAbortIsNotOfferedIt() async throws {
        let w = World()
        w.abortable = false
        w.fakes.ranked = [.init(target: "session:local_b", p: 0.95)]
        let id = try #require(w.dispatcher.submit("add a changelog entry"))
        await w.finish(id)
        #expect(w.entry(id)?.delivered?.abortable == false && !w.store.canCancel(w.entry(id)!))
        #expect(await w.dispatcher.cancel(id) == nil && w.cancels.isEmpty)
    }

    @Test func aWrongSendIsCancelledAndAskedAgainWithoutWhereItWent() async throws {
        let w = World()
        w.fakes.ranked = [.init(target: "session:local_b", p: 0.95), .init(target: "session:local_a", p: 0.04)]
        let id = try #require(w.dispatcher.submit("fix the login redirect"))
        await w.finish(id)
        w.fakes.finished = []
        w.dispatcher.sendElsewhere(id)
        #expect(w.entry(id)?.outcome == .pending, "the line shows it under way")
        await w.finish(id)
        #expect(w.cancels.count == 1 && w.entry(id)?.delivered?.cancelled == .aborted)
        // Asked again, the wrong place left out; a pick corrects it.
        let ask = try #require(w.dispatcher.askBacks.first { $0.id == id })
        #expect(!ask.options.contains { $0.target == "session:local_b" } && ask.options.first?.target == "session:local_a")
        #expect(ask.suggestion == "session:local_b")
        w.fakes.finished = []
        #expect(w.dispatcher.pick(id, target: "session:local_a"))
        await w.finish(id)
        let entry = try #require(w.entry(id))
        #expect(w.fakes.sent.map(\.to) == ["peer-local_b", "peer-local_a"])
        if case .corrected = entry.outcome {} else { Issue.record("not a correction: \(entry.outcome)") }
        #expect(entry.decision.fromID == "session:local_b" && entry.decision.targetID == "session:local_a")
        // The new send is the one a Cancel now takes back.
        #expect(entry.delivered?.session == "local_a" && entry.delivered?.cancelled == nil)
        let lines = w.trace()
        #expect(lines.contains { $0.kind == .cancelled && $0.elsewhere == true && $0.target == "session:local_b" })
        // The re-ask is a line of its own kind: the first decided line stays the wrong send's.
        #expect(lines.contains { $0.kind == .reasked && $0.path == "elsewhere" && $0.action == "ask" })
        #expect(lines.filter { $0.kind == .decided && $0.id == id }.map(\.action) == ["send"])
        #expect(lines.contains { $0.kind == .corrected && $0.from == "session:local_b" && $0.target == "session:local_a" })
    }

    @Test func anActionsMessageSentElsewhereIsStillAnActionsMessage() async throws {
        let w = World()
        w.store.codeFolders.scan = { _ in .init(repos: ["/code/lookout": ["o/lookout"], "/code/lookout-2": ["o/lookout"]]) }
        w.store.addCodeFolders(["/code"])
        await w.store.codeFolders.settled()
        w.store.things["pr:o/lookout#7"] = InboxFixture.pr(7, repo: "o/lookout", title: "Login fails")
        let (text, mentions) = w.store.composeForRouter([.text("Address "), .pointer(.notification("pr:o/lookout#7"))])
        var context = RouterContext()
        context.tag(mentions)
        context.action = RouterActionSource(origin: SessionOrigin(category: "Contributions", thing: "o/lookout#7 Login fails",
                                                                  actionID: "a", runID: "r"),
                                            title: "o/lookout#7 Login fails", model: "opus", effort: "high")
        w.fakes.ranked = [.init(target: "session:local_a", p: 0.95), .init(target: "unclear", p: 0.05)]
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finish(id)
        #expect(w.fakes.prepared == ["local_a"] && w.entry(id)?.actionSource == context.action)
        // Asked again, Jev now sure it changes Fjord: still never the Router's own runs, nor a folder not offered.
        w.fakes.finished = []
        w.fakes.ranked = [.init(target: "change_fjord", p: 0.9), .init(target: "question", p: 0.05), .init(target: "new:/code/lookout-2", p: 0.05)]
        w.dispatcher.sendElsewhere(id)
        await w.finish(id)
        let ask = try #require(w.dispatcher.askBacks.first { $0.id == id })
        #expect(ask.options.map(\.target) == ["new:/code/lookout-2"] && ask.context.action == context.action)
        #expect(!w.dispatcher.pick(id, target: "question") && !w.dispatcher.pick(id, target: "change_fjord"))
        #expect(!w.dispatcher.pick(id, folder: "/somewhere"))
        // The new session is the action's: called after its thing, on its model and effort, tagged with its origin.
        w.fakes.finished = []
        #expect(w.dispatcher.pick(id, target: "new:/code/lookout-2"))
        await w.finish(id)
        #expect(w.fakes.started.map(\.title) == ["o/lookout#7 Login fails"])
        #expect(w.fakes.startSettings.first??.model == "opus" && w.fakes.startSettings.first??.effort == "high")
        #expect(w.store.router.origins["local_new"]?.category == "Contributions")
        // An entry from before the settings were kept: its thing's line is the title, on your defaults.
        var old = try #require(w.entry(id))
        old.actionStart = nil
        let back = try JSONDecoder().decode(RouterDecision.self, from: JSONEncoder().encode(old))
        #expect(back.actionSource == RouterActionSource(origin: context.action!.origin, title: "o/lookout#7 Login fails"))
        // Triage off: not sent elsewhere at all.
        w.store.settings.triage = false
        w.dispatcher.sendElsewhere(id)
        #expect(w.dispatcher.progress[id] == nil)
    }

    @Test func anActionsMessageSentElsewhereFromItsReposOnlyCloneOffersAFolder() async throws {
        let w = World()
        w.store.codeFolders.scan = { _ in .init(repos: ["/code/solo": ["o/solo"]]) }
        w.store.addCodeFolders(["/code"])
        await w.store.codeFolders.settled()
        w.store.things["pr:o/solo#3"] = InboxFixture.pr(3, repo: "o/solo", title: "Solo")
        // The new session's first message is signed, so it can be taken back.
        w.dispatcher.effects.start = { _, _, title, settings in
            let signed = RelaySigner.sign(body: "hello", target: "cli-new", key: RelaySigning.key)
            return .delivery(RouterDispatcher.Delivery(to: "peer-new", text: signed, body: "hello", original: "hello", rephrased: false,
                                                       session: "local_new", newSessionIn: "solo", settings: settings, settingsSigned: false))
        }
        let (text, mentions) = w.store.composeForRouter([.text("Fix "), .pointer(.notification("pr:o/solo#3"))])
        var context = RouterContext()
        context.tag(mentions)
        context.action = RouterActionSource(origin: SessionOrigin(category: "C", thing: "o/solo#3 Solo", actionID: "a", runID: "r"),
                                            title: "o/solo#3 Solo")
        w.fakes.ranked = [.init(target: "new:/code/solo", p: 0.97), .init(target: "unclear", p: 0.03)]
        let id = try #require(w.dispatcher.submit(text, context: context))
        await w.finish(id)
        #expect(w.entry(id)?.delivered?.session == "local_new")
        // Its one clone, and the session started there, are where it went: what is left is a folder of your choosing.
        w.fakes.finished = []
        w.dispatcher.sendElsewhere(id)
        await w.finish(id)
        let ask = try #require(w.dispatcher.askBacks.first { $0.id == id })
        #expect(ask.options.map(\.target) == [RouterAskBack.chooseFolder])
        w.fakes.finished = []
        #expect(w.dispatcher.pick(id, folder: "/elsewhere/solo"))
        await w.finish(id)
        #expect(w.fakes.sent.count == 2)
    }

    @Test func aWrongSendDismissedIsSentNowhereElse() async throws {
        let w = World()
        w.fakes.ranked = [.init(target: "session:local_b", p: 0.95), .init(target: "session:local_a", p: 0.04)]
        let id = try #require(w.dispatcher.submit("fix the login redirect"))
        await w.finish(id)
        w.fakes.finished = []
        w.dispatcher.sendElsewhere(id)
        await w.finish(id)
        w.dispatcher.dismiss(id)
        #expect(w.entry(id)?.reply == "Dismissed: sent nowhere else." && w.entry(id)?.outcome == .done)
        #expect(w.fakes.sent.count == 1)
    }

    @Test func aWrongSendThatWasntStoppedIsNotSentElsewhere() async throws {
        for answer in [Result<RouterDecision.Cancelled, Error>.success(.tooLate), .success(.together), .success(.unknown),
                       .failure(RouterTools.Failure("The session's plugin didn't pick the message up"))] {
            let w = World()
            w.answer = answer
            w.fakes.ranked = [.init(target: "session:local_b", p: 0.95), .init(target: "session:local_a", p: 0.04)]
            let id = try #require(w.dispatcher.submit("fix the login redirect"))
            await w.finish(id)
            w.fakes.finished = []
            w.dispatcher.sendElsewhere(id)
            await w.finish(id)
            #expect(w.dispatcher.askBacks.isEmpty && w.fakes.sent.count == 1 && w.fakes.ranks == 1)
            #expect(w.entry(id)?.outcome == .done && w.entry(id)?.reply?.contains("wasn't sent elsewhere") == true)
            #expect(!w.trace().contains { $0.kind == .reasked })
        }
    }
}
