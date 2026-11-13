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
}
