import Foundation
import Testing
@testable import Fjord

/// Acts on a T3 thread (read, archive, snooze, settle, rename, tags) and the banners the shell drives.
@MainActor @Suite struct ThreadActsTests {
    @MainActor final class Sent { var commands: [T3Command] = [] }
    private func target() -> BriefTarget { BriefTarget(project: "p", thread: "t1") }

    private func fixture() -> (store: Store, sent: Sent) {
        let store = Store()
        store.persists = false
        let sent = Sent()
        store.requestSender = { command, _ in sent.commands.append(command) }
        return (store, sent)
    }

    @Test func eachActSendsItsCommandAndRevertSendsTheOpposite() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let until = T3Timestamp(date: at).text
        let cases: [(BriefAction, String, [String], [String])] = [
            (.read, "", ["thread.visit"], ["thread.mark-unread"]),
            (.archive, "", ["thread.archive"], ["thread.unarchive"]),
            (.settle, "", ["thread.settle"], ["thread.unsettle"]),
            (.snooze, until, ["thread.snooze"], ["thread.unsnooze"]),
            (.rename, ThreadActDetail.rename(from: "Old", to: "New"), ["thread.metadata.update"], ["thread.metadata.update"]),
            (.tag, ThreadActDetail.tag("ship", on: true), ["thread.tag.set"], ["thread.tag.set"]),
        ]
        for (act, detail, forward, back) in cases {
            func types(_ f: Bool) -> [String] {
                Store.commands(for: act, thread: "t1", detail: detail, forward: f, now: at)
                    .compactMap { $0.payload(commandId: "c").str("type") }
            }
            #expect(types(true) == forward && types(false) == back, "\(act)")
        }
        let rename = Store.commands(for: .rename, thread: "t1", detail: ThreadActDetail.rename(from: "Old", to: "New"), forward: false)
        #expect(rename.first?.payload(commandId: "c").str("title") == "Old")
        let untag = Store.commands(for: .tag, thread: "t1", detail: ThreadActDetail.tag("ship", on: true), forward: false)
        #expect(untag.first?.payload(commandId: "c")["tagged"]?.bool == false)
    }

    @Test func anActHidesThroughTheCallersHoldAndReportsARefusalAfterTheLineIsBack() async throws {
        let (store, sent) = fixture()
        var holds: [Bool] = []
        var told: [String] = []
        let id = store.threadAct(.settle, on: target(), title: "Layout", hold: { holds.append($0) }, refused: { told.append($0) })
        #expect(id != nil && store.router.changes.last?.id == id && holds == [true])
        await waitUntil { sent.commands.count == 1 }
        store.requestSender = { _, _ in throw ThreadSendFailure("T3 said no") }
        store.threadAct(.settle, on: target(), title: "Layout", hold: { holds.append($0) }, refused: { told.append($0) })
        await waitUntil { told.count == 1 }
        #expect(holds == [true, true, false] && told == ["T3 said no"])
        #expect(store.router.changes.last?.revertNote == "T3 refused it: T3 said no" && store.routerPage.toast == nil)
    }

    @Test func aTagOver64CharactersIsNotSent() {
        let long = String(repeating: "x", count: 65)
        #expect(Store.commands(for: .tag, thread: "t1", detail: ThreadActDetail.tag(long, on: true), forward: true).isEmpty)
    }

    @Test func archiveGoesToT3AtOnceAndRevertUnarchives() async {
        let (store, sent) = fixture()
        store.threadAct(.archive, on: target(), title: "Layout")
        let change = store.router.changes.last
        #expect(change?.isBriefAction == true)
        await waitUntil { sent.commands.count == 1 }
        store.revertFjordChange(change!.id)
        await waitUntil { sent.commands.count == 2 }
        #expect(sent.commands.map { $0.payload(commandId: "c").str("type") } == ["thread.archive", "thread.unarchive"])
    }

    @Test func aRefusedActIsPutBackWithT3sWords() async {
        let (store, _) = fixture()
        struct Refused: LocalizedError { var errorDescription: String? { "thread is busy" } }
        store.requestSender = { _, _ in throw Refused() }
        store.threadAct(.settle, on: target(), title: "Layout")
        // The Router page's toast says why, with nothing to revert.
        await waitUntil { store.routerPage.toast?.revertible == false }
        #expect(store.routerPage.toast?.after.contains("thread is busy") == true)
        #expect(store.router.changes.last?.isReverted == true)
    }

    @Test func readStateIsTheThreadsNotAMarkOfFjords() {
        let marks = BriefMarks()
        #expect(BriefMarks.Kind.allCases.map(\.rawValue).sorted() == ["notified", "told"])
        #expect(marks.told.isEmpty && marks.notified.isEmpty)
    }

    // MARK: Banners

    private func thread(_ build: (inout AgentThread) -> Void) -> AgentThread {
        var t = AgentThread(id: "t1", title: "Fix login", lastActivity: Date(timeIntervalSince1970: 1_000))
        build(&t)
        return t
    }
    private let now = Date(timeIntervalSince1970: 1_060)

    @Test func aFinishedThreadFailureAndLimitEachGetABannerKeyedByTheirRun() {
        let done = ThreadNotices.notices(thread { $0.unseen = true; $0.lastRunEndedAt = Date(timeIntervalSince1970: 1_000) }, request: nil, now: now)
        #expect(done.map(\.kind) == [.finished] && done[0].key == "done:t1@1000")
        let failed = ThreadNotices.notices(thread { $0.status = .failed; $0.lastError = "boom" }, request: nil, now: now)
        #expect(failed.map(\.kind) == [.failed] && failed[0].body == "boom")
        let limit = ThreadNotices.notices(thread { $0.status = .failed; $0.usageLimit = true; $0.limitResetAt = Date(timeIntervalSince1970: 1_800) },
                                          request: nil, now: now)
        #expect(limit.map(\.kind) == [.usageLimit] && limit[0].body.hasPrefix("It resumes by itself at "))
    }

    @Test func anOldChangeGetsNoBannerAfterARelaunch() {
        let old = ThreadNotices.notices(thread { $0.status = .failed }, request: nil, now: Date(timeIntervalSince1970: 1_000 + 3_600))
        #expect(old.isEmpty)
    }

    @Test func aWaitingThreadIsKeyedByItsRequestOrPlan() {
        let ask = thread { $0.pendingRequest = T3PendingRequest(json: T3JSON.parse(#"{"id":"r9","kind":"command","blocking":true}"#)) }
        #expect(ThreadNotices.notices(ask, request: nil, now: now).map(\.key) == ["ask:r9"])
        let plan = thread { $0.hasPlan = true }
        #expect(ThreadNotices.notices(plan, request: nil, now: now).map(\.key) == ["plan:t1@1000"])
    }
}
