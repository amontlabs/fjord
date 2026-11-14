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
        s.settleThread(ThreadTarget(project: "p1", thread: "t1"))
        #expect(s.routerRecords.record("t1") == nil && s.routerPage.thread("t1") == nil)
        let change = try #require(s.router.changes.last)
        s.replayThreadAct(change.patch, forward: false)
        #expect(s.routerPage.thread("t1") != nil)
        await waitUntil { sent.commands.count == 2 }
        #expect(sent.commands.map { $0.payload(commandId: "c").str("type") } == ["thread.settle", "thread.unsettle"])
    }

    @Test func aSettleT3RefusesPutsTheLineBackAndThePageSaysWhy() async {
        let s = store([F.shell("t1", title: "Fix the fence")])
        s.requestSender = { _, _ in throw ThreadSendFailure("T3 said no") }
        s.settleThread(ThreadTarget(project: "p1", thread: "t1"))
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
        verdicts.onItems = { [weak s] thread, key, event in s?.routerRecords.items(thread, key: key, event) }
        s.routerVerdicts = verdicts
        return s
    }

    @Test func aTurnEndIsReadOnceAgainstItsOpenItemsAndItsWordsReachTheLine() async throws {
        let fake = FakeClaude()
        let s = asking([F.shell("t1", title: "Install guide", minutes: 1, extra: ["latestRunId": "r1"])], fake)
        defer { s.persists = false; if let f = s.stateFile { try? FileManager.default.removeItem(at: f) } }
        let page = s.routerPage
        // T3's projection of the thread: its reply for the card.
        var detail = RouterDetail()
        detail.reply = "Rewrote the install guide for the Chrome setup and opened PR #41."
        s.routerRecords.detail("t1", detail)
        #expect(page.thread("t1")?.reading == true, "a finished turn is being read until its read lands")
        // Its projection's facts (here given as T3 would answer the read).
        s.routerRecords.itemFacts("t1", key: "turn:r1", RouterItemFacts(turns: ["r1": .init(
            reply: "Rewrote the install guide for the Chrome setup and opened PR #41. Merge it when you're happy.",
            status: "completed", live: false)]))
        await waitUntil { fake.calls.contains { $0.arguments.contains { $0.contains(#""found""#) } } }
        for (i, call) in fake.calls.enumerated() {
            let items = call.arguments.contains { $0.contains(#""found""#) }
            fake.send(i, FakeClaude.answer(items ? ["open": [Any](), "found": [["kind": "do", "same_as": "", "sentence": "merge PR #41", "options": [String]()]],
                                                    "line": "install guide written; PR #41"] : ["name": "Install guide"]))
            fake.close(i)
        }
        await waitUntil { s.routerRecords.saved["t1"]?.ledger?.lineRun == "r1" && page.thread("t1")?.ledger.items.isEmpty == false }
        let line = try #require(page.thread("t1"))
        #expect(line.ledger.items.map(\.sentence) == ["merge PR #41"] && line.section == .needsYou && !line.reading)
        #expect(s.routerRecords.saved["t1"]?.ledger?.lineRun == "r1")
        #expect(fake.calls.filter { $0.arguments.contains { $0.contains(#""found""#) } }.count == 1, "one read for the turn")
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


    // MARK: A read's new thread is named as the page names its project (FINAL-REVIEW #8)

    @Test func aNewThreadTheDeciderPicksIsNamedByItsProjectNotItsID() {
        let s = store([F.shell("t1", title: "Fix the fence")])
        let read = RouterRead(draft: "plant tomatoes", places: [.newThread(project: "p1"), .thread("t1")], sure: false)
        #expect(s.routerNamed(read).places == [.newThread(project: "Garden"), .thread("t1")])
        // The page's line names the same project.
        #expect(s.routerPage.thread("t1")?.project == "Garden")
        // A name the page shows is not touched.
        let named = RouterRead(draft: "x", places: [.newThread(project: "Garden")], sure: true)
        #expect(s.routerNamed(named) == named)
        // The start finds T3's id again from that name.
        #expect(s.routerActs.env.projectID("Garden") == "p1")
    }

    // MARK: The open card reaches the decider (FINAL-REVIEW #9)

    @Test func theOpenCardIsTheDecidersPrior() {
        let s = store([F.shell("t1", title: "Fix the fence"), F.shell("t2", title: "Plant the beans")])
        let board = s.deciderBoard()
        let none = s.deciderContext("yes, the second one", board: board)
        let open = s.deciderContext("yes, the second one", board: board, open: "t1")
        #expect(none.key != open.key)
        #expect(open.blocks.joined() != none.blocks.joined())
    }

    // MARK: The real page's settings are T3's only (FINAL-REVIEW #12)

    @Test func theRealPageOffersNoModelsOrSettingsUntilT3sConfigLands() {
        let s = store([F.shell("t1", title: "Fix the fence")])
        let page = s.routerPage
        #expect(page.launchModels.isEmpty)
        page.select(nil)
        page.setDraft("garden: plant tomatoes")
        page.apply(.read(RouterRead(draft: page.draft, places: [.newThread(project: "Garden")], sure: true)))
        #expect(!page.launchShown)
        let opus = RouterLaunchModel(id: "claude-opus-5-5", name: "Opus 5.5", provider: "Claude", instance: "claudeAgent",
                                       efforts: [.low, .high], defaultEffort: .low, access: [.full])
        let mine = RouterLaunch(model: "claude-opus-5-5", effort: .low, access: .full)
        page.apply(.launch(defaults: mine, models: [opus]))
        #expect(page.launchShown)
        #expect(page.launch == mine)
    }
}
