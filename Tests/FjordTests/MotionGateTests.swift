import Foundation
import Testing
@testable import Fjord

/// Work that can wait holds while the window's morph plays, then goes in the order it was asked, a turn at a time.
@MainActor @Suite struct MotionGateTests {
    /// Lets the main queue run its turns.
    private func turns(_ n: Int = 10) async {
        for _ in 0..<n { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func workWaitsForTheMotionAndGoesInOrderAfterIt() async {
        let gate = MotionGate.Gate(longest: 600)
        var done: [Int] = []
        gate.whenStill { done.append(0) }
        #expect(done == [0])
        gate.began()
        gate.whenStill { done.append(1) }
        gate.whenStill { done.append(2) }
        await turns()
        #expect(done == [0])
        gate.ended()
        // Not inside the turn that ends the morph.
        #expect(done == [0])
        // Asked while the held work is still being let go: it goes behind it.
        gate.whenStill { done.append(3) }
        for _ in 0..<3000 where done.count < 4 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(done == [0, 1, 2, 3])
        #expect(!gate.holding)
    }

    @Test func aMorphBegunAndEndedInOneTurnStartsNoSecondRelease() async {
        let gate = MotionGate.Gate(longest: 600)
        var done = 0
        gate.began()
        for _ in 0..<4 { gate.whenStill { done += 1 } }
        gate.ended()
        // A morph that never ran: began and ended in the same turn, the release already queued.
        gate.began()
        gate.ended()
        // One hop of the main queue: one release chain lets at most its first item and the one it queued go by then.
        await withCheckedContinuation { (hop: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { hop.resume() } }
        #expect(done <= 2)
        for _ in 0..<3000 where done < 4 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(done == 4)
    }

    @Test func aStoreUnderTestWaitsOnAGateOfItsOwnAndItsFeedOnTheSame() {
        let s = Store()
        // The app's gate, which window tests hold, holds no store's work in the suites beside them.
        #expect(s.motionGate !== MotionGate.shared && s.claudeFeed.gate === s.motionGate)
        let gate = MotionGate.Gate(longest: 600)
        s.motionGate = gate
        #expect(s.claudeFeed.gate === gate)
    }

    @Test func stillWaitsItsTurnBehindWhatWasHeld() async {
        let gate = MotionGate.Gate(longest: 600)
        var done: [String] = []
        gate.began()
        gate.whenStill { done.append("held") }
        gate.ended()
        // Nothing moves, but held work has yet to go: an await takes its turn behind it.
        await gate.still()
        done.append("still")
        #expect(done == ["held", "still"])
    }

    @Test func stillWaitsOutAMotionThatBeganBeforeItResumed() async {
        let gate = MotionGate.Gate(longest: 600)
        gate.began()
        var resumed = false
        let waiter = Task { @MainActor in
            await gate.still()
            resumed = true
            #expect(!gate.moving)
        }
        await turns()
        gate.ended()
        // Another morph starts before the waiter's turn comes.
        gate.began()
        await turns()
        #expect(!resumed)
        gate.ended()
        await waiter.value
        #expect(resumed)
    }

    @Test func aMorphThatNeverSaysItEndedLetsTheWorkGo() async {
        let gate = MotionGate.Gate(longest: 0.05)
        var done = false
        gate.began()
        gate.whenStill { done = true }
        for _ in 0..<3000 where !done { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(done && !gate.moving)
    }
}

/// Claude's reads that come while the window moves are taken in after it, every one in order, as if each came then.
@MainActor @Suite struct ClaudeFeedHold {
    private let now = Date()

    private func session(_ id: String, turns: Int, message: Double = -120, archived: Bool = false) -> AgentThread {
        var s = AgentThread(id: id, title: "Session \(id)", folder: "/code/app", completedTurns: turns,
                              lastActivity: now.addingTimeInterval(-60), lastFocused: now.addingTimeInterval(-3600),
                              lastUserMessage: now.addingTimeInterval(message), summary: .init(blocked: false, detail: "Done it"),
                              cliID: "cli-\(id)")
        s.isArchived = archived
        return s
    }

    private func store(_ dir: TempDir, _ sessions: [AgentThread], dots: Set<String> = []) -> Store {
        let s = Store()
        s.persists = false
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.routerExecutable = "/Applications/Fjord.app/Contents/MacOS/Fjord"
        s.interceptOpen = { _ in }
        s.agents.enabled = true
        s.agents.enabledAt = now.addingTimeInterval(-7200)
        s.ingest(sessions, appUnread: dots, claudeFrontmost: false)
        s.setRouterEnabled(true)
        return s
    }

    private func read(_ sessions: [AgentThread], dots: Set<String> = []) -> ClaudeSnapshot {
        var read = ClaudeSnapshot()
        read.sessions = sessions
        read.appUnread = dots
        read.activity = [:]
        read.tasks = [:]
        return read
    }

    /// The reads taken in one by one, and held by a motion then let go: the same cards, the same read flags.
    private func expectHeldAsInTurn(_ start: [AgentThread], dots: Set<String> = [], setUp: (Store) -> Void = { _ in },
                                    _ reads: [ClaudeSnapshot], sourceLocation: SourceLocation = #_sourceLocation) async {
        let dirA = TempDir(), dirB = TempDir()
        let inTurn = store(dirA, start, dots: dots), held = store(dirB, start, dots: dots)
        setUp(inTurn)
        setUp(held)
        for var read in reads {
            read.stamp = inTurn.claudeStamp
            inTurn.applyClaude(read)
        }
        let gate = MotionGate.Gate(longest: 600)
        gate.began()
        var applied = 0
        for var read in reads {
            read.stamp = held.claudeStamp
            held.claudeFeed.deliver(read, { applied += 1; held.applyClaude($0) }, gate: gate)
        }
        await Task.yield()
        #expect(applied == 0, sourceLocation: sourceLocation)
        gate.ended()
        for _ in 0..<3000 where applied < reads.count { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(held.agents.entries.map(\.unread) == inTurn.agents.entries.map(\.unread), sourceLocation: sourceLocation)
    }

    @Test func aBacklogGoesASliceATurnInOrderEveryReadItsOwn() async {
        let gate = MotionGate.Gate(longest: 600)
        let feed = ClaudeFeed(activityReader: Claude.ActivityReader())
        feed.sliceBudget = 0.004
        var applied: [String] = []
        let apply: @MainActor (ClaudeSnapshot) -> Void = { read in
            applied.append(read.activity?.keys.first ?? "full")
            Thread.sleep(forTimeInterval: 0.003)
        }
        func activity(_ id: String) -> ClaudeSnapshot {
            var read = ClaudeSnapshot()
            read.activity = [id: ThreadWork(text: id, since: Date())]
            read.tasks = [:]
            return read
        }
        var full = ClaudeSnapshot()
        full.sessions = []
        gate.began()
        // Every read in its place, activity reads in a row too (each may say a question began, or ended).
        for read in [activity("a"), activity("b"), full, activity("c"), full, activity("d"), activity("e"), full, activity("f")] {
            feed.deliver(read, apply, gate: gate)
        }
        gate.ended()
        // The first slice, the turn after the motion: not all of it.
        for _ in 0..<3000 where applied.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(applied.count < 9)
        // Read while the backlog goes: behind it.
        feed.deliver(activity("g"), apply, gate: gate)
        for _ in 0..<3000 where applied.last != "g" { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(applied == ["a", "b", "full", "c", "full", "d", "e", "full", "f", "g"])
        // Nothing held: taken in at once.
        let before = applied.count
        feed.deliver(full, apply, gate: gate)
        #expect(applied.count == before + 1)
    }

    @Test func aDotClearedThenBackLeavesTheSessionUnread() async {
        await expectHeldAsInTurn([session("local_a", turns: 1)], dots: ["local_a"], [
            read([session("local_a", turns: 1)], dots: []),
            read([session("local_a", turns: 1)], dots: ["local_a"]),
        ])
    }
}

/// A sync's results, and what it says of them, wait for the window's morph.
@MainActor @Suite struct SyncHeldByMotion {
    @Test func aSyncsResultsAndItsErrorWaitForTheMotion() async {
        let gate = MotionGate.Gate(longest: 600)
        let s = Store()
        s.persists = false
        s.settings.triage = true
        s.motionGate = gate
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            switch request.url?.path ?? "" {
            case "/repos/a/x": return .init(200, #"{"full_name":"a/x","default_branch":"main"}"#)
            case "/repos/a/x/branches/main": return .init(200, #"{"commit":{"sha":"s1","commit":{"message":"Fix"}}}"#)
            default: return .init(500, #"{"message":"Server Error"}"#)
            }
        }
        var ci = InboxStore.ci
        ci.rules = [Rule(scope: Scope(kinds: [.workflow], in: Pick(include: [.repo("a/x")])), conditions: [.workflow([.failing])],
                         createdAt: .distantPast)]
        s.categories = [ci]
        gate.began()
        let sync = Task { await s.syncInbox() }
        for _ in 0..<3000 where gate.waitingCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.waitingCount == 1)
        // Answered, but nothing said or taken while the window moves.
        #expect(s.inboxError == nil)
        gate.ended()
        await sync.value
        #expect(s.inboxError != nil)
    }
}

/// A poll, and a refresh that stops early, say nothing while the window moves.
@MainActor @Suite struct PollHeldByMotion {
    private func store(_ gate: MotionGate.Gate) -> Store {
        let s = Store()
        s.persists = false
        s.settings.triage = true
        s.motionGate = gate
        return s
    }

    @Test func aPollStartsAndEndsOnlyOnceTheWindowIsStill() async {
        let gate = MotionGate.Gate(longest: 600)
        let s = store(gate)
        s.me = nil
        s.gh.token = nil
        s.resolveToken = { nil }
        gate.began()
        let poll = Task { await s.pollAll() }
        for _ in 0..<3000 where gate.waitingCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.waitingCount == 1)
        #expect(!s.isSyncing && s.authError == nil && s.lastSync == nil)
        gate.ended()
        await poll.value
        #expect(s.authError != nil && s.lastSync != nil && !s.isSyncing)
    }

    @Test func aRefreshThatStopsAtItsTeamsSaysSoOnlyOnceTheWindowIsStill() async {
        final class Ref: @unchecked Sendable { var gate: MotionGate.Gate? }
        let gate = MotionGate.Gate(longest: 600), ref = Ref()
        ref.gate = gate
        let s = store(gate)
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        // The window starts to open while GitHub is asked for your teams.
        s.gh.session = StubbedGitHub.session { _ in
            DispatchQueue.main.sync { MainActor.assumeIsolated { ref.gate?.began() } }
            return .init(502, #"{"message":"Server Error"}"#)
        }
        s.categories = [InboxCategory(name: "Team", symbol: "eye", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], to: Pick(include: [.myTeams]), toRoles: [.reviewRequested])),
        ])]
        let sync = Task { await s.syncInbox() }
        for _ in 0..<3000 where gate.waitingCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.waitingCount == 1 && s.inboxError == nil)
        gate.ended()
        await sync.value
        #expect(s.inboxError?.hasPrefix("Your teams couldn't be looked up") == true)
    }
}

/// The icons a session can get are worked out off the main thread.
@Suite struct SessionIconsOffMain {
    @Test func theIconsOfferedOffTheMainThreadAreThoseOfferedOnIt() async {
        let excluded: Set<String> = ["hammer", "ladybug"]
        let off = await Task.detached { await SessionIcons.openOffMain(excluding: excluded) }.value
        let on = SessionIcons.open(excluding: excluded)
        #expect(off.map(\.category) == on.map(\.category) && off.map(\.icons) == on.map(\.icons))
        #expect(SessionIcons.drawableCount != nil)
    }
}

/// A poll whose task is cancelled while it waits for the window commits nothing.
@MainActor @Suite struct CancelledPollHeldByMotion {
    @Test func aPollCancelledAtTheGateLeavesNothingAndLetsGoOfSyncing() async {
        final class Count: @unchecked Sendable { var looks = 0 }
        let gate = MotionGate.Gate(longest: 600), count = Count()
        let s = Store()
        s.persists = false
        s.settings.triage = true
        s.motionGate = gate
        s.me = nil
        s.gh.token = nil
        s.resolveToken = { count.looks += 1; return nil }
        gate.began()
        let poll = Task { await s.pollAll() }
        for _ in 0..<3000 where gate.waitingCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        poll.cancel()
        gate.ended()
        await poll.value
        #expect(!s.isSyncing && s.lastSync == nil && s.authError == nil && count.looks == 0)
        // Cancelled while it signed in: what it found isn't said, and syncing is let go of.
        final class Latch: @unchecked Sendable { var open = false }
        let latch = Latch()
        s.resolveToken = { count.looks += 1; while !latch.open { Thread.sleep(forTimeInterval: 0.002) }; return nil }
        let second = Task { await s.pollAll() }
        for _ in 0..<3000 where count.looks == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(s.isSyncing)
        gate.began()
        second.cancel()
        latch.open = true
        for _ in 0..<3000 where gate.waitingCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        gate.ended()
        await second.value
        #expect(!s.isSyncing && s.lastSync == nil && s.authError == nil)
    }

    @Test func aSignInCancelledLeavesItsRetryAndTheBackoffAsTheyWere() async {
        final class Count: @unchecked Sendable { var looks = 0; var open = false }
        for retry in [false, true] {
            let gate = MotionGate.Gate(longest: 600), count = Count()
            let s = Store()
            s.persists = false
            s.settings.triage = true
            s.motionGate = gate
            s.me = nil
            s.gh.token = nil
            s.resolveToken = { count.looks += 1; while !count.open { Thread.sleep(forTimeInterval: 0.002) }; return nil }
            s.authRetry = retry
            let poll = Task { await s.pollAll() }
            for _ in 0..<3000 where count.looks == 0 { try? await Task.sleep(for: .milliseconds(2)) }
            poll.cancel()
            count.open = true
            await poll.value
            #expect(s.authRetry == retry && s.authError == nil)
            // The next poll looks for a token at once: the cancelled one used up neither the Retry nor the backoff.
            await s.pollAll()
            #expect(count.looks == 2 && s.authError != nil && !s.authRetry)
        }
    }
}
