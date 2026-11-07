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
        #expect(s.deciderBoard(youSaid: ["aaaa1111": "ship it"]).threads.first?.youSaid == "ship it")
    }

    @Test func aProjectionYieldsTheLastUserMessage() {
        let p = T3Projection(json: [
            "thread": T3Fixture.thread("t1"), "runs": [], "messages": [T3Fixture.message("m1", text: "first"), T3Fixture.message("m2", role: "assistant", text: "ok"),
                                                                       T3Fixture.message("m3", text: "  second one \n")],
            "runtimeRequests": [], "plans": [], "turnItems": [], "providerSessions": [], "updatedAt": "2026-01-02T03:04:05.000Z"])
        #expect(T3Store.lastUserMessage(in: p) == "second one")
    }
}
