import Foundation
import Testing
@testable import Fjord

/// The engine's pills: what each `CourierUpdate` shows, what stays and settles, and what the buttons send.
@MainActor
@Suite struct RouterCourierTests {
    private func update(_ id: Int, _ state: CourierState, _ cause: String? = nil, before: JSON? = nil) -> CourierUpdate {
        CourierUpdate(intentID: id, state: state, cause: cause, before: before, at: Date())
    }

    private func pills() -> RouterCourierPills {
        let pills = RouterCourierPills()
        pills.settleAfter = nil
        pills.open = { _ in }
        return pills
    }

    private func face(_ pills: RouterCourierPills, _ id: Int) -> RouterCourierPills.Face? {
        pills.items.first { $0.id == id }.map(RouterCourierPills.face)
    }

    private let send = RouterCourierPills.Item.Work.send(words: "run it again", project: "lookout", thread: nil)
    private let goal = RouterCourierPills.Item.Work.tool(.setGoal, args: ["project": "lookout", "text": "Ship it"])

    @Test func targetsRoundTripAndOthersAreNotTheEngines() {
        #expect(RouterCourier.Target("claude-project:lookout") == .project("lookout"))
        #expect(RouterCourier.Target("claude-thread:a/b/t1") == .thread(project: "a/b", thread: "t1"))
        #expect(RouterCourier.Target("claude-thread:a/b/t1")?.targetID == "claude-thread:a/b/t1")
        for other in ["session:x", "new:/code", "claude-project:", "claude-thread:lookout", "claude-thread:/t", "claude-thread:p/"] {
            #expect(RouterCourier.Target(other) == nil)
        }
        #expect(!RouterCourier.enabled)
    }

    @Test func aSendShowsSendingThenDeliveredAndSettles() {
        let pills = pills()
        pills.track(1, .send(words: "merge it", project: "lookout", thread: "Fix login"))
        #expect(face(pills, 1)?.status == "Sending to lookout · Fix login")
        #expect(face(pills, 1)?.mark == .working)
        pills.apply(update(1, .taken))
        #expect(face(pills, 1)?.status == "Sending to lookout · Fix login")
        pills.apply(update(1, .delivered))
        #expect(face(pills, 1)?.mark == .done)
        #expect(face(pills, 1)?.settles == true)
        #expect(face(pills, 1)?.dismissible == false)
    }

    @Test func aFailureShowsTheCauseAsItIsAndALateDeliveryReplacesIt() {
        let pills = pills()
        pills.track(1, send)
        pills.apply(update(1, .failed, CourierCore.went))
        #expect(face(pills, 1)?.note == CourierCore.went)
        #expect(face(pills, 1)?.settles == false)
        pills.apply(update(1, .deliveredLate, "confirmed late by a later row"))
        #expect(pills.items.count == 1)
        #expect(face(pills, 1)?.status == "Delivered to lookout after all")
        #expect(face(pills, 1)?.note == nil)
    }

    @Test func aDismissedFailureComesBackOnlyToSayItWentAfterAll() {
        let pills = pills()
        pills.track(1, send)
        pills.apply(update(1, .failed, "stuck"))
        pills.dismiss(1)
        pills.apply(update(1, .failed, "stuck again"))
        #expect(pills.items.isEmpty)
        pills.apply(update(1, .deliveredLate))
        #expect(face(pills, 1)?.status == "Delivered to lookout after all")
    }

    @Test func anUpdateBeforeTheIdReturnedIsKeptForIt() {
        let pills = pills()
        pills.apply(update(4, .delivered))
        #expect(pills.items.isEmpty)
        pills.track(4, send)
        #expect(pills.items.first?.state == .delivered)
    }

    @Test func eachPauseTheEngineGivesHasItsOneButton() {
        // By the engine's code (`CourierUpdate.pause`); the sentence is only shown.
        #expect(RouterCourier.action(.chromeClosed) == .openChrome)
        #expect(RouterCourier.action(.chromeNotConnected) == .openSetup)
        #expect(RouterCourier.action(.signedOut) == .signIn)
        #expect(RouterCourier.action(.away) == .openTab)
        #expect(RouterCourier.action(.tabUnreadable) == .openTab)
        #expect(RouterCourier.action(.appClosed) == .showClaudeApp)
        #expect(RouterCourier.action(nil) == nil)
        let pills = pills()
        var opened: [RouterCourierPills.Action] = []
        pills.open = { opened.append($0) }
        pills.track(1, send)
        pills.apply(CourierUpdate(intentID: 1, state: .paused, cause: "signed out of claude.ai", before: nil, at: Date(), pause: .signedOut))
        #expect(face(pills, 1)?.note == "signed out of claude.ai")
        #expect(face(pills, 1)?.action == .signIn)
        pills.perform(.signIn, on: 1)
        #expect(opened == [.signIn])
        pills.apply(update(1, .paused, "routerd restarted"))
        #expect(face(pills, 1)?.action == nil)
    }

    @Test func returnAllowsTheNewestGrantAtOnce() async {
        var asked: [CourierRequest] = []
        let pills = pills()
        pills.attach(RouterCourierSource(submit: { asked.append($0); return 1 }, updates: AsyncStream { _ in }))
        #expect(!pills.allowNewest())
        pills.track(1, .tool(.preapproveFolder, args: ["project": "lookout", "path": "~/code/x"]))
        pills.apply(update(1, .awaiting))
        #expect(face(pills, 1)?.words == "Let lookout use ~/code/x")
        #expect(face(pills, 1)?.action == .allow)
        #expect(pills.allowNewest())
        // Shown as under way before the engine says anything.
        #expect(face(pills, 1)?.status == "Allowing…")
        #expect(face(pills, 1)?.action == nil)
        #expect(!pills.allowNewest())
        await Task.yield()
        guard case .confirm(let id)? = asked.first else { Issue.record("no confirm sent"); return }
        #expect(id == 1)
    }

    @Test func aSettingDoneOffersRevertWithWhatItWasAndRevertSendsItBack() async {
        var asked: [CourierRequest] = []
        let pills = pills()
        pills.attach(RouterCourierSource(submit: { asked.append($0); return 2 }, updates: AsyncStream { _ in }))
        pills.track(1, goal)
        pills.apply(update(1, .toolDone, before: "Port the board"))
        #expect(face(pills, 1)?.words == "Goal set for lookout")
        #expect(face(pills, 1)?.action == .revert)
        #expect(face(pills, 1)?.settles == false)
        pills.perform(.revert, on: 1)
        #expect(pills.items.first?.acting == true)
        for _ in 0..<5 { await Task.yield() }
        guard case .tool(let name, let args)? = asked.first else { Issue.record("no revert sent"); return }
        #expect(name == .setGoal)
        #expect(args["text"] == "Port the board")
        #expect(args["project"] == "lookout")
        // The revert takes the pill's place.
        #expect(pills.items.map(\.id) == [2])
        pills.apply(update(2, .toolDone, before: "Ship it"))
        #expect(face(pills, 2)?.words == "Goal set back for lookout")
    }

    @Test func noRevertWithoutBeforeOrForATheToolHasNoReverseOf() {
        let pills = pills()
        pills.track(1, goal)
        pills.apply(update(1, .toolDone))
        #expect(face(pills, 1)?.action == nil)
        #expect(face(pills, 1)?.settles == true)
        pills.track(2, .tool(.addRepo, args: ["project": "lookout", "repo": "a/b"]))
        pills.apply(update(2, .toolDone, before: .array([])))
        #expect(face(pills, 2)?.action == nil)
        #expect(face(pills, 2)?.words == "a/b added to lookout")
    }

    @Test func alreadySoRefusedAndUnconfirmedSayTheEnginesWords() {
        let pills = pills()
        pills.track(1, goal)
        pills.apply(update(1, .toolDone, "it was already so", before: "Ship it"))
        #expect(face(pills, 1)?.words == "The goal of lookout")
        #expect(face(pills, 1)?.status == "it was already so")
        #expect(face(pills, 1)?.action == nil)
        pills.track(2, .tool(.addRepo, args: ["project": "lookout", "repo": "amontlabs/x"]))
        pills.apply(update(2, .refused, "no repo option amontlabs/x"))
        #expect(face(pills, 2)?.words == "Add amontlabs/x to lookout")
        #expect(face(pills, 2)?.note == "no repo option amontlabs/x")
        #expect(face(pills, 2)?.dismissible == true)
        pills.track(3, .tool(.createProject, args: ["name": "site"]))
        pills.apply(update(3, .toolUnconfirmed, "not listed yet"))
        #expect(face(pills, 3)?.status == "done, not confirmed")
        #expect(face(pills, 3)?.note == "not listed yet")
    }

    @Test func yourNextMessageClearsTheRevertsLeftUp() {
        let pills = pills()
        pills.track(1, goal)
        pills.apply(update(1, .toolDone, before: "Port the board"))
        pills.track(2, .tool(.addRepo, args: ["project": "lookout", "repo": "a/b"]))
        pills.apply(update(2, .refused, "no repo option a/b"))
        pills.track(3, send)
        #expect(pills.items.map(\.id) == [2, 3])
    }

    @Test func theFakeEngineFeedsThePillsThroughAttach() async {
        let (source, _) = RouterCourierSource.fake { _, _ in [(.taken, nil, nil), (.delivered, nil, nil)] }
        let pills = pills()
        pills.attach(source)
        let id = await pills.send("hello", to: .project("lookout"))
        #expect(id == 1)
        for _ in 0..<20 where pills.items.first?.state != .delivered { await Task.yield() }
        #expect(pills.items.first?.state == .delivered)
    }
}
