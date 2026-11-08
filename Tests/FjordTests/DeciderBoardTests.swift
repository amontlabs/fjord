import Foundation
import Testing
@testable import Fjord

/// The decider's board: the Swift renderer produces exactly the text of the E3 run's Python (`render_board` and `candidates` in
/// `deciders-t3/common.py`) on invented boards, the candidate rules hold, and the board is built from T3's shell rows.
/// Fixtures (Fixtures/DeciderBoard/*.json) hold invented data only, with the Python's output as `expected`.
@MainActor
@Suite struct DeciderBoardTests {
    struct Fixture: Decodable {
        struct Thread: Decodable {
            var id: String, project: String, title: String, flag: String, running: Bool, minutesIdle: Int
            var summary: String, step: String, said: String
            var youSaid: String?, waiting: String?
        }
        var name: String
        var projects: [String]
        var purposes: [String: String]
        var threads: [Thread]
        var expected: String

        var board: DeciderBoard {
            DeciderBoard(projects: projects, purposes: purposes, threads: threads.map { t in
                DeciderBoard.Thread(id: t.id, project: t.project, title: t.title,
                                    flag: t.flag == "running" ? .running : t.flag == "waiting" ? .waiting : .finished,
                                    running: t.running, minutesIdle: t.minutesIdle, summary: t.summary, step: t.step, said: t.said,
                                    youSaid: t.youSaid, waiting: t.waiting)
            })
        }
    }

    static func fixture(_ name: String) throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/DeciderBoard/\(name).json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    // MARK: Parity with the Python reference

    @Test(arguments: ["small", "messy", "cap"]) func theRendererWritesWhatThePythonWrote(_ name: String) throws {
        let f = try Self.fixture(name)
        let got = f.board.render()
        if got != f.expected {
            let a = got.split(separator: "\n", omittingEmptySubsequences: false), b = f.expected.split(separator: "\n", omittingEmptySubsequences: false)
            let i = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
            Issue.record("\(name) differs at line \(i + 1):\nswift:  \(i < a.count ? a[i] : "<end>")\npython: \(i < b.count ? b[i] : "<end>")")
        }
        #expect(got == f.expected)
    }

    // MARK: Candidates

    private func thread(_ id: String, _ project: String = "p", flag: DeciderBoard.Flag = .finished, idle: Int) -> DeciderBoard.Thread {
        .init(id: id, project: project, title: id, flag: flag, minutesIdle: idle)
    }

    @Test func runningAndWaitingThreadsAreNeverCutAndFinishedOnesAreTheLatestThreePerProjectWithin12Hours() {
        let b = DeciderBoard(projects: ["p", "q"], threads: [
            thread("old", idle: 721), thread("f1", idle: 5), thread("f2", idle: 6), thread("f3", idle: 7), thread("f4", idle: 8),
            thread("run", flag: .running, idle: 2000), thread("wait", "q", flag: .waiting, idle: 9000), thread("g1", "q", idle: 720),
        ])
        #expect(Set(b.candidates.map(\.id)) == ["run", "wait", "f1", "f2", "f3", "g1"])
        #expect(b.candidates.prefix(2).map(\.id) == ["run", "wait"])
    }

    @Test func theBoardHoldsAtMostTwentyThreadsBeforeLiveOnesAreCounted() {
        var threads = (0..<30).map { thread("f\($0)", "p\($0 % 10)", idle: $0) }
        threads += (0..<3).map { thread("r\($0)", "p0", flag: .running, idle: 100 + $0) }
        let b = DeciderBoard(projects: (0..<10).map { "p\($0)" }, threads: threads)
        #expect(b.candidates.count == 20 && b.candidates.filter { $0.flag == .running }.count == 3)
        let few = DeciderBoard(projects: ["p"], threads: (0..<25).map { thread("w\($0)", flag: .waiting, idle: $0) })
        #expect(few.candidates.count == 25)
    }

    @Test func aProjectWithNoThreadStillGetsItsNewThreadLineAndFjordClosesTheBoard() {
        let text = DeciderBoard(projects: ["empty"], threads: []).render()
        #expect(text == "## empty\n- new in empty | start a new thread here | purpose: unknown\n## Fjord\n" + DeciderBoard.fjordLine)
    }

    @Test func ageAndCutsFollowTheSpec() {
        #expect([0, 59, 60, 1439, 1440, 4000].map(DeciderBoard.age) == ["0m", "59m", "1h", "23h", "1d", "2d"])
        #expect(DeciderBoard.one("a \n\t b   c", 10) == "a b c")
        #expect(DeciderBoard.tail("abcdef", 3) == "def" && DeciderBoard.one("abcdef", 3) == "abc")
        #expect(DeciderBoard.one("key sk-abcdefghijklmnopqrstuvwxyz0123 end", 80) == "key [redacted] end")
    }

    // MARK: From T3

    @Test func theBoardIsBuiltFromT3sShellRowsWithoutSettledOrSnoozedThreads() {
        let later = T3Fixture.ago(-60)
        let s = Store.reading([
            T3Fixture.shell("11111111-aaaa", title: "Fix the login", minutes: 20),
            T3Fixture.shell("22222222-bbbb", title: "Wait on me", status: "running", minutes: 2,
                            extra: ["pendingRuntimeRequest": ["id": "r1", "kind": "user_input", "createdAt": .string(T3Fixture.ago(2)), "blocking": true]]),
            T3Fixture.shell("33333333-cccc", title: "Settled", minutes: 30, extra: ["settledAt": .string(T3Fixture.ago(30))]),
            T3Fixture.shell("44444444-dddd", title: "Snoozed", minutes: 30, extra: ["snoozedUntil": .string(later)]),
        ], projects: [T3Fixture.project("p1", title: "Garden", root: "/code/app"), T3Fixture.project("p2", title: "Garden", root: "/code/other")])
        s.requests["22222222-bbbb"] = ThreadRequest(id: "r1", threadID: "22222222-bbbb",
                                                    body: .question([T3Question(demo: "Q", "Which beds?", options: [("North", ""), ("South", "")])]))
        let b = s.deciderBoard()
        // Two projects named alike are told apart.
        #expect(b.projects == ["Garden", "Garden (2)"])
        #expect(Set(b.projectIDs.values) == ["p1", "p2"])
        #expect(Set(b.threads.map(\.title)) == ["Fix the login", "Wait on me"])
        let waits = b.threads.first { $0.title == "Wait on me" }
        #expect(waits?.flag == .waiting && waits?.running == true && waits?.id == "22222222" && waits?.key == "22222222-bbbb")
        #expect(waits?.waiting == "Which beds? Options: North / South")
        #expect(b.render().contains("- 22222222 | Wait on me | waiting on you, running, 2m ago"))
    }

    @Test func aShortIdGrowsUntilItIsUnique() {
        let s = Store.reading([T3Fixture.shell("abcd1234-0001", minutes: 1), T3Fixture.shell("abcd1234-0002", minutes: 2)])
        let ids = s.deciderBoard().threads.map(\.id)
        #expect(Set(ids).count == 2 && ids.allSatisfy { $0.hasPrefix("abcd1234") })
    }

    @Test func yourLastMessageComesFromTheShellOrTheKnownReads() {
        let s = Store.reading([T3Fixture.shell("aaaa1111", minutes: 1)])
        #expect(s.deciderBoard().threads.first?.youSaid == nil)
        #expect(s.deciderBoard(reads: ["aaaa1111": ThreadReads(youSaid: "ship it", reply: "not shown")]).threads.first?.youSaid == "ship it")
    }

    // MARK: Real activity, the reply, git, the read-ahead

    @Test func theAgeIsRealActivityNotTheRowsUpdatedAt() {
        // Pinned just now (updatedAt moves), but the last message and run are hours old.
        let old = T3Fixture.ago(180), ran = T3Fixture.ago(120)
        let s = Store.reading([T3Fixture.shell("aaaa1111", minutes: 0, extra: [
            "latestVisibleMessage": ["id": "m0", "role": "assistant", "text": "done", "updatedAt": .string(old)],
            "latestUserMessageAt": .string(old), "latestUserAuthoredMessageAt": .string(old), "latestRunCompletedAt": .string(ran)]),
            T3Fixture.shell("bbbb2222", minutes: 0, extra: [
                "latestVisibleMessage": ["id": "m1", "role": "assistant", "text": "done", "updatedAt": .string(T3Fixture.ago(30))],
                "latestUserMessageAt": .string(T3Fixture.ago(30)), "latestUserAuthoredMessageAt": .string(T3Fixture.ago(30))])])
        let b = s.deciderBoard()
        let a = b.threads.first { $0.key == "aaaa1111" }, c = b.threads.first { $0.key == "bbbb2222" }
        #expect(a.map { (119...121).contains($0.minutesIdle) } == true)
        #expect(c.map { (29...31).contains($0.minutesIdle) } == true)
        // Ordered by it, not by updatedAt (both 0m).
        #expect(b.threads.map(\.key) == ["bbbb2222", "aaaa1111"])
    }

    @Test func anImportedThreadWithNoRunOnT3IsOldWhateverItsMessagesSay() {
        let now = T3Fixture.ago(1)
        let s = Store.reading([T3Fixture.shell("aaaa1111", minutes: 1, extra: [
            "historyOrigin": "v1_import", "createdAt": .string(T3Fixture.ago(60 * 24 * 9)),
            "latestUserAuthoredMessageAt": .string(now), "latestVisibleMessage": ["id": "m", "role": "assistant", "text": "x", "updatedAt": .string(now)]])])
        #expect(s.deciderBoard().threads.first.map { $0.minutesIdle > 60 * 24 * 8 } == true)
    }

    @Test func gitAndTheReplyAndWhatYouSaidAfterItAreOnTheThreadsLines() {
        let t = DeciderBoard.Thread(id: "t1", project: "p", title: "T", flag: .finished, minutesIdle: 4, said: "Done, see the diff.",
                                    youSaid: "Now squash it", youSaidLast: true, branch: "feat/squash", pullRequests: ["#12 open", "#9 merged"])
        #expect(DeciderBoard.lines(t) == [
            "- t1 | T | finished, 4m ago", "  last message: Done, see the diff.", "  you said after that: Now squash it",
            "  git: branch feat/squash, pull requests #12 open, #9 merged"])
        var plain = t; plain.youSaidLast = false; plain.branch = ""; plain.pullRequests = []
        #expect(DeciderBoard.lines(plain).contains("  you last said there: Now squash it"))
    }

    @Test func sonnetsBoardShowsEachThreadsFirstAskAndYourLastThreeMessagesThere() {
        let long = String(repeating: "x", count: 250), msg = String(repeating: "m", count: 130)
        let t = DeciderBoard.Thread(id: "t1", project: "p", title: "T", flag: .finished, minutesIdle: 4, said: "Done.",
                                    first: long, earlier: ["one", "two", "three", msg])
        let lines = DeciderBoard.lines(t)
        #expect(lines[0] == "- t1 | T | finished, 4m ago")
        #expect(lines[1] == "  first ask: \(String(repeating: "x", count: 200))")
        #expect(lines[2] == "  your earlier messages there: two / three / \(String(repeating: "m", count: 100))")
        #expect(lines[3] == "  last message: Done.")
        // One earlier message is not repeated, and no first ask shows nothing.
        let one = DeciderBoard.Thread(id: "t2", project: "p", title: "T", flag: .finished, minutesIdle: 4, first: "ask", earlier: ["only"])
        #expect(DeciderBoard.lines(one) == ["- t2 | T | finished, 4m ago", "  first ask: ask"])
        #expect(DeciderBoard.lines(.init(id: "t3", project: "p", title: "T", flag: .finished, minutesIdle: 4)) == ["- t3 | T | finished, 4m ago"])
        // Jev's request keeps the older lines, and the rendered board has them.
        #expect(DeciderBoard.lines(t, firstAsk: false) == ["- t1 | T | finished, 4m ago", "  last message: Done."])
        #expect(DeciderBoard(projects: ["p"], threads: [t]).render().contains("  first ask: "))
    }

    @Test func theBranchAndPullRequestsComeFromTheShell() {
        let pr: T3JSON = ["url": "https://x/pull/12", "number": 12, "snapshot": ["state": "OPEN", "title": "t"]]
        let s = Store.reading([T3Fixture.shell("aaaa1111", extra: ["branch": "feat/x", "pullRequests": [pr]])])
        let t = s.deciderBoard().threads.first
        #expect(t?.branch == "feat/x" && t?.pullRequests == ["#12 open"])
    }

    @Test func whenYourMessageIsLatestTheReadsReplyShowsBesideIt() {
        let s = Store.reading([T3Fixture.shell("aaaa1111", extra: [
            "latestVisibleMessage": ["id": "m9", "role": "user", "text": "also add tests", "updatedAt": .string(T3Fixture.ago(2))]])])
        let t = s.deciderBoard(reads: ["aaaa1111": ThreadReads(youSaid: "older", reply: "Implemented the parser.")]).threads.first
        #expect(t?.said == "Implemented the parser." && t?.youSaid == "also add tests" && t?.youSaidLast == true)
        #expect(s.deciderBoard().threads.first?.said == "")
    }

    @Test func theBoardForADecisionUsesTheCacheAndNeverWaitsWithoutARead() async {
        let s = Store.reading([T3Fixture.shell("aaaa1111", extra: [
            "latestVisibleMessage": ["id": "m9", "role": "user", "text": "also add tests", "updatedAt": .string(T3Fixture.ago(2))]])])
        // No T3 behind it: nothing to read, nothing waited for.
        let started = Date()
        let none = await s.deciderBoardWithReads()
        #expect(none.threads.first?.said == "" && Date().timeIntervalSince(started) < 0.2)
        s.deciderReads.keep("aaaa1111", stamp: "m9", ThreadReads(youSaid: nil, reply: "Implemented the parser."))
        #expect(await s.deciderBoardWithReads().threads.first?.said == "Implemented the parser.")
        // A new latest message makes the kept read stale.
        s.deciderReads.keep("aaaa1111", stamp: "m8", ThreadReads(youSaid: nil, reply: "stale"))
        s.deciderReads.prune(keeping: [])
        #expect(await s.deciderBoardWithReads().threads.first?.said == "")
    }

    @Test func aReadIsStartedOncePerLatestMessageAndKeptWhenItEnds() async {
        let cache = ThreadReadCache()
        let count = Counter()
        let read: @Sendable () async -> ThreadReads? = {
            await count.bump()
            try? await Task.sleep(for: .milliseconds(30))
            return ThreadReads(youSaid: "y", reply: "r")
        }
        let first = cache.fetch("t", stamp: "m1", read: read)
        _ = cache.fetch("t", stamp: "m1", read: read)
        await first.value
        #expect(await count.value == 1)
        #expect(cache.cached("t", stamp: "m1") == ThreadReads(youSaid: "y", reply: "r"))
        #expect(cache.cached("t", stamp: "m2") == nil)
    }

    @Test func aProjectionYieldsTheLastReply() {
        let p = T3Projection(json: [
            "thread": T3Fixture.thread("t1"), "runs": [], "messages": [T3Fixture.message("m1", text: "q"), T3Fixture.message("m2", role: "assistant", text: " first "),
                                                                       T3Fixture.message("m3", role: "assistant", text: " second \n"), T3Fixture.message("m4", text: "next")],
            "runtimeRequests": [], "plans": [], "turnItems": [], "providerSessions": [], "updatedAt": "2026-01-02T03:04:05.000Z"])
        #expect(T3Store.tail(of: p) == ThreadReads(youSaid: "next", reply: "second", first: "q", earlier: ["q", "next"]))
    }

    @Test func aProjectionYieldsTheLastUserMessage() {
        let p = T3Projection(json: [
            "thread": T3Fixture.thread("t1"), "runs": [], "messages": [T3Fixture.message("m1", text: "first"), T3Fixture.message("m2", role: "assistant", text: "ok"),
                                                                       T3Fixture.message("m3", text: "  second one \n")],
            "runtimeRequests": [], "plans": [], "turnItems": [], "providerSessions": [], "updatedAt": "2026-01-02T03:04:05.000Z"])
        #expect(T3Store.lastUserMessage(in: p) == "second one")
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
