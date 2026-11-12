import Foundation
import Testing
@testable import Fjord

/// What a Router v2 line and card read of a thread's projection.
@Suite struct RouterDetailTests {
    typealias F = T3Fixture

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func projection(runs: [T3JSON] = [F.run("r1", status: "running")], messages: [T3JSON] = [], items: [T3JSON] = [],
                            checkpoints: [T3JSON] = [], status: String = "running", sessions: [T3JSON] = [],
                            thread: [String: T3JSON] = [:]) -> T3Projection {
        guard case .object(var top) = F.projection(), case .object(var body)? = top["projection"] else { fatalError() }
        body["runs"] = .array(runs)
        body["messages"] = .array(messages)
        body["turnItems"] = .array(items)
        body["checkpoints"] = .array(checkpoints)
        body["providerSessions"] = .array(sessions)
        body["thread"] = F.thread("t1", status: status, extra: thread)
        top["projection"] = .object(body)
        guard case .snapshot(_, let p) = T3ThreadItem(json: .object(top)) else { fatalError() }
        return p
    }

    private func say(_ id: String, _ text: String, ordinal: Int, status: String = "completed") -> T3JSON {
        F.item(id, type: "assistant_message", ordinal: ordinal, status: status, ["messageId": .string("m-\(id)"), "text": .string(text), "streaming": false])
    }
    private func command(_ id: String, _ input: String, ordinal: Int, status: String = "running") -> T3JSON {
        F.item(id, type: "command_execution", ordinal: ordinal, status: status, ["input": .string(input), "output": "x"])
    }
    private func todo(_ steps: [(String, String)], ordinal: Int) -> T3JSON {
        F.item("todo", type: "todo_list", ordinal: ordinal, ["planId": "pl", "steps": .array(steps.enumerated().map { n, s in
            ["id": .string("s\(n)"), "text": .string(s.0), "status": .string(s.1)] })])
    }

    @Test func aToDoStepBeatsNarrationBeatsATool() {
        let items = [say("a", "Checking the seeds. Then more.", ordinal: 2), command("c", "ls seeds", ordinal: 3),
                     todo([("Sort", "completed"), ("Label the packets", "running"), ("Water", "pending")], ordinal: 4)]
        let withList = RouterDetail.make(projection(items: items), now: now)
        #expect(withList.working == .init(text: "Label the packets", mono: false, since: withList.working!.since))
        #expect(withList.steps.map(\.state) == [.done, .running, .pending])

        let noList = RouterDetail.make(projection(items: Array(items.prefix(2))), now: now)
        #expect(noList.working?.text == "Checking the seeds.")
        #expect(noList.working?.mono == false)

        let toolOnly = RouterDetail.make(projection(items: [command("c", "ls seeds", ordinal: 3)]), now: now)
        #expect(toolOnly.working?.text == "ls seeds")
    }

    // Shapes of T3's projection (Orchestration V2 `WireProjection`): a Bash call is a command_execution with only its
    // command (the tool's `description` input is not kept); Read carries a title; other tools are dynamic_tool with a summarized input.
    @Test func aToolsOwnDescriptionBeatsNarrationAndACommandIsLast() {
        let say1 = say("a", "Looking at the reader.", ordinal: 1)
        let bash = command("c", "python3 - <<'EOF'\nprint(1)\nEOF", ordinal: 2)
        let read = F.item("r", type: "dynamic_tool", ordinal: 2, status: "running",
                          ["toolName": "Read", "title": "Read /a/RouterDetail.swift", "input": ["file_path": "/a/RouterDetail.swift"]])
        let withDesc = F.item("d", type: "command_execution", ordinal: 2, status: "running",
                              ["input": "grep -n \"projectName(of\" Sources", "description": "Find where project names are read"])
        #expect(RouterDetail.make(projection(items: [say1, read]), now: now).working?.text == "Read /a/RouterDetail.swift")
        #expect(RouterDetail.make(projection(items: [say1, withDesc]), now: now).working?.text == "Find where project names are read")
        let narrated = RouterDetail.make(projection(items: [say1, bash]), now: now).working
        #expect(narrated?.text == "Looking at the reader." && narrated?.mono == false)
        let bare = RouterDetail.make(projection(items: [bash]), now: now).working
        #expect(bare?.text == "python3 - <<'EOF'" && bare?.mono == true)
    }

    @Test func aToolWithNoDescriptionGetsAPlainLabelOverItsInput() {
        let grep = F.item("g", type: "dynamic_tool", ordinal: 1, status: "running",
                          ["toolName": "Grep", "input": ["pattern": "projectName(of", "path": "/a/Sources"]])
        let w = RouterDetail.make(projection(items: [grep]), now: now).working
        #expect(w?.text == "Grep · projectName(of" && w?.mono == false)
        let bare = F.item("t", type: "dynamic_tool", ordinal: 1, status: "running", ["toolName": "Glob", "input": [:]])
        #expect(RouterDetail.make(projection(items: [bare]), now: now).working?.text == "Glob")
    }

    @Test func aCommandIsMonoAndAnEditIsNot() {
        #expect(RouterDetail.make(projection(items: [command("c", "swift test\n--filter X", ordinal: 1)]), now: now).working
            == .init(text: "swift test", mono: true, since: RouterDetail.make(projection(), now: now).working!.since))
        let edit = F.item("e", type: "file_change", ordinal: 1, status: "running", ["fileName": "a/b/c.swift"])
        let w = RouterDetail.make(projection(items: [edit]), now: now).working
        #expect(w?.text == "Editing c.swift")
        #expect(w?.mono == false)
    }

    @Test func aRunWithNoItemIsStarting() {
        let d = RouterDetail.make(projection(), now: now)
        #expect(d.working?.text == "starting")
        #expect(d.steps.isEmpty)
    }

    @Test func aRunStartsWhereT3SaidAndNothingWorksWhenNothingRuns() {
        let run = F.run("r1", status: "running")
        guard case .object(var o) = run else { return }
        o["startedAt"] = "2026-01-02T03:00:00.000Z"
        let d = RouterDetail.make(projection(runs: [.object(o)]), now: now)
        #expect(d.working?.since == AgentThread.date(T3Timestamp("2026-01-02T03:00:00.000Z")))
        #expect(RouterDetail.make(projection(runs: [F.run("r1", status: "completed")], status: "completed"), now: now).working == nil)
    }

    @Test func theFirstSentenceStopsAtASentenceEndNotInsideAWord() {
        #expect(RouterDetail.sentence("Reading file.swift now. Then more.") == "Reading file.swift now.")
        #expect(RouterDetail.sentence("\n\n  Is it there? yes") == "Is it there?")
        #expect(RouterDetail.sentence("No end here") == "No end here")
        #expect(RouterDetail.sentence(String(repeating: "a", count: 300)).count == 120)
        #expect(RouterDetail.sentence("   ") == "")
    }

    @Test func aStreamingMessageSetsWriting() {
        var streaming = F.message("m2", role: "assistant", text: "Half a sen")
        if case .object(var o) = streaming { o["streaming"] = true; streaming = .object(o) }
        let d = RouterDetail.make(projection(messages: [F.message("um1", text: "Go"), streaming]), now: now)
        #expect(d.reply == "Half a sen")
        #expect(d.writing)
        let done = RouterDetail.make(projection(runs: [F.run("r1", status: "completed")], messages: [F.message("m2", role: "assistant", text: "All of it.")], status: "completed"), now: now)
        #expect(done.reply == "All of it.")
        #expect(!done.writing)
    }

    @Test func theDiffSumsTheLatestTurnsCheckpoints() {
        let runs = [F.run("r1", status: "completed"), F.run("r2", status: "completed")]
        let cps = [F.checkpoint("c0", run: "r1", files: [("old.txt", 100, 100)]),
                   F.checkpoint("c1", run: "r2", files: [("a.swift", 3, 1), ("b.swift", 2, 0)]),
                   F.checkpoint("c2", run: "r2", files: [("c.swift", 1, 1)], total: (count: 5, additions: 40, deletions: 6))]
        let d = RouterDetail.make(projection(runs: runs, checkpoints: cps, status: "completed"), now: now)
        #expect(d.diff == .init(files: 7, added: 45, removed: 7))
        #expect(RouterDetail.make(projection(runs: runs, checkpoints: [F.checkpoint("c0", run: "r1", files: [("x", 1, 0)])], status: "completed"), now: now).diff == nil)
    }

    @Test func queuedWordsComeWithTheirRun() {
        var queued = F.run("r2", status: "queued", queuePosition: 1)
        if case .object(var o) = queued { o["userMessageId"] = "um2"; queued = .object(o) }
        let d = RouterDetail.make(projection(runs: [F.run("r1", status: "running"), queued],
                                             messages: [F.message("um1", text: "First"), F.message("um2", text: "Then this")]), now: now)
        #expect(d.queued == [.init(id: "r2", words: "Then this")])
        #expect(d.working != nil)
    }

    @Test func aFailedRunNamesItsLastToolItem() {
        let items = [command("c1", "make build", ordinal: 1, status: "completed"), command("c2", "make test", ordinal: 2, status: "failed"),
                     F.item("r", type: "reasoning", ordinal: 3, ["text": "hmm", "streaming": false])]
        let failed = RouterDetail.make(projection(runs: [F.run("r1", status: "failed")], items: items, status: "failed"), now: now)
        #expect(failed.lastStep == "make test")
        #expect(RouterDetail.make(projection(runs: [F.run("r1", status: "completed")], items: items, status: "completed"), now: now).lastStep == nil)
    }

    @Test func steeringFollowsTheSessionElseTheDriver() {
        #expect(RouterDetail.make(projection(), now: now).steers)
        #expect(!RouterDetail.make(projection(thread: ["providerInstanceId": "opencode"]), now: now).steers)
    }
}
