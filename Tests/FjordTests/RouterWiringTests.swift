import Foundation
import Testing
@testable import Fjord

/// The Router v2 page on a real store (track 9a): T3's events reach the records first and the page model after, the acts
/// done outside the page hide through the records, and the sidebar's count follows them.
@MainActor @Suite struct RouterWiringTests {
    typealias F = T3Fixture

    private func store(_ threads: [T3JSON]) -> Store {
        let s = Store.reading(threads, projects: [F.project("p1", title: "Garden", root: "/code/app")])
        s.router.enabled = true
        return s
    }

    /// One thread's update as T3's stream delivers it: the shell applied, then `onShell` (the records first, then the rest).
    private func stream(_ s: Store, _ thread: T3JSON) {
        var shell = s.t3.store.shell
        let item = T3ShellItem.threadUpdated(sequence: (shell.sequence ?? 0) + 1, location: .active, thread: T3ThreadShell(json: thread))
        shell.apply(item)
        s.t3.store.seed(shell, notify: false)
        s.t3.store.onShell?(item)
    }

    private static let asking: T3JSON = ["id": "r1", "kind": "user_input", "createdAt": .string(T3Fixture.ago(2)), "blocking": true]

    @Test func aSeededShellGivesThePageItsLines() {
        let s = store([F.shell("t1", title: "Fix the fence"), F.shell("t2", title: "Plant the beans")])
        #expect(s.routerRecords.record("t1") != nil && s.routerRecords.record("t2") != nil)
        #expect(s.routerPage.thread("t1")?.title == "Fix the fence")
        #expect(s.routerPage.thread("t2")?.title == "Plant the beans")
    }

    @Test func aThreadsUpdateReachesThePageMadeBeforeIt() {
        let s = store([F.shell("t1", title: "Fix the fence")])
        let page = s.routerPage
        stream(s, F.shell("t1", title: "Fix the gate", minutes: 1))
        #expect(page.thread("t1")?.title == "Fix the gate")
        stream(s, F.shell("t3", title: "Water the roses", minutes: 1))
        #expect(page.thread("t3")?.title == "Water the roses")
    }

    @Test func aPendingRequestCountsOnTheSidebarsBadge() {
        let s = store([F.shell("t1"), F.shell("t2")])
        #expect(s.routerNeedsYou == 0)
        stream(s, F.shell("t1", extra: ["pendingRuntimeRequest": Self.asking]))
        #expect(s.routerNeedsYou == 1)
        #expect(s.routerRecords.lines(in: .needsYou).map(\.id) == ["t1"])
    }

    @Test func aFocusFromHistoryOrTheBarSelectsTheLineAndAnUnknownThreadNothing() {
        let s = store([F.shell("t1")])
        s.routerFocus("t1")
        #expect(s.routerPage.selection == .line("t1"))
        s.routerFocus("gone")
        #expect(s.routerPage.selection == .line("t1"))
    }

    @MainActor final class Commands { var commands: [T3Command] = [] }

    @Test func aSettleFromOutsideThePageHidesItsLineAndItsRevertBringsItBack() async throws {
        let s = store([F.shell("t1", title: "Fix the fence")])
        let sent = Commands()
        s.requestSender = { command, _ in sent.commands.append(command) }
        #expect(s.routerPage.thread("t1") != nil)
        s.settleThread(BriefTarget(project: "p1", thread: "t1"))
        #expect(s.routerRecords.record("t1") == nil && s.routerPage.thread("t1") == nil)
        let change = try #require(s.router.changes.last)
        s.replayBriefAction(change.patch, forward: false)
        #expect(s.routerPage.thread("t1") != nil)
        await waitUntil { sent.commands.count == 2 }
        #expect(sent.commands.map { $0.payload(commandId: "c").str("type") } == ["thread.settle", "thread.unsettle"])
    }

    @Test func aSettleT3RefusesPutsTheLineBackAndThePageSaysWhy() async {
        let s = store([F.shell("t1", title: "Fix the fence")])
        s.requestSender = { _, _ in throw ThreadSendFailure("T3 said no") }
        s.settleThread(BriefTarget(project: "p1", thread: "t1"))
        await waitUntil { s.routerPage.toast != nil }
        #expect(s.routerPage.thread("t1") != nil)
        #expect(s.routerPage.toast?.revertible == false)
    }

    /// A store whose model calls are real (not a demo's): its verdicts run on `fake` instead of `claude -p`.
    private func asking(_ threads: [T3JSON], _ fake: FakeClaude) -> Store {
        let s = store(threads)
        s.stateFile = FileManager.default.temporaryDirectory.appendingPathComponent("router-wiring-\(UUID().uuidString).json")
        s.persists = true
        let verdicts = RouterVerdicts(binary: { "/bin/claude" }, runner: fake.runner)
        verdicts.onEvent = { [weak s] thread, fingerprint, event in s?.routerRecords.verdict(thread, fingerprint: fingerprint, event) }
        s.routerVerdicts = verdicts
        return s
    }

    @Test func aTurnEndAsksOneVerdictAndItsWordsReachTheLine() async throws {
        let fake = FakeClaude()
        let s = asking([F.shell("t1", title: "Install guide", minutes: 1, extra: ["latestRunId": "r1"])], fake)
        defer { s.persists = false; if let f = s.stateFile { try? FileManager.default.removeItem(at: f) } }
        let page = s.routerPage
        // Asked once its reply is in (T3's projection of the thread).
        var detail = RouterDetail()
        detail.reply = "Rewrote the install guide for the Chrome setup and opened PR #41."
        s.routerRecords.detail("t1", detail)
        #expect(page.thread("t1")?.reading == true, "a finished turn is being read until its verdict lands")
        await waitUntil { !fake.calls.isEmpty }
        for i in fake.calls.indices {
            fake.send(i, FakeClaude.answer(FakeClaude.quiet))
            fake.close(i)
        }
        await waitUntil { page.thread("t1")?.sentence.text == "install guide written; PR #41" }
        let line = try #require(page.thread("t1"))
        #expect(line.sentence.text == "install guide written; PR #41" && line.state == .done && !line.reading)
        #expect(fake.calls.count <= 2, "one verdict (and at most one name) for the turn")
    }

    @Test func returnOnAPickedOptionAnswersTheRequestAndTheLineIsSentAtOnce() async throws {
        let s = store([F.shell("t1", title: "Pick a db", extra: ["pendingRuntimeRequest": Self.asking])])
        let sent = Commands()
        s.requestSender = { command, _ in sent.commands.append(command) }
        let request = ThreadRequest(id: "r1", threadID: "t1", body: .question([T3Question(demo: "Db", "Which one?", id: "q1",
            options: [("Postgres", ""), ("SQLite", "")])]), live: true)
        s.requests["t1"] = request
        var detail = RouterDetail()
        detail.request = request
        s.routerRecords.detail("t1", detail)
        let page = s.routerPage
        page.select(.line("t1"))
        page.pick(2)
        page.send()
        // In the same turn: the line is Sent.
        #expect(page.thread("t1")?.state == .sent)
        let answers = { sent.commands.filter { if case .respondAnswers = $0 { true } else { false } } }
        await waitUntil { !answers().isEmpty }
        #expect(answers() == [.respondAnswers(threadId: "t1", requestId: "r1", answers: ["q1": .one("SQLite")])])
    }

    @Test func settleThenUndoSendsSettleThenUnsettle() async {
        let s = store([F.shell("t1", title: "Fix the fence")])
        let sent = Commands()
        s.requestSender = { command, _ in sent.commands.append(command) }
        let page = s.routerPage
        page.settle("t1")
        #expect(page.thread("t1") == nil)
        page.undo()
        #expect(page.thread("t1") != nil)
        await waitUntil { sent.commands.count == 2 }
        #expect(sent.commands.map { $0.payload(commandId: "c").str("type") } == ["thread.settle", "thread.unsettle"])
    }

}
