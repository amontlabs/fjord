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

    /// A working summary's input and the working peek's rows: the tool running now, the ones before it newest first, and
    /// the agent's latest whole words (one still being written isn't news yet).
    @Test func aLiveRunsRawDetailAndLatestWholeWords() {
        var streaming = say("b", "Half a sen", ordinal: 5, status: "running")
        if case .object(var o) = streaming { o["streaming"] = true; streaming = .object(o) }
        let items = [say("a", "Found the gap. Moving the copy.", ordinal: 1),
                     command("c1", "rg -n caret Sources", ordinal: 2, status: "completed"),
                     F.item("e", type: "file_change", ordinal: 3, status: "completed", ["fileName": "/a/Composer.swift"]),
                     F.item("r", type: "dynamic_tool", ordinal: 4, status: "completed",
                            ["toolName": "Read", "title": "Read /a/Tab.swift", "input": ["file_path": "/a/Tab.swift"]]),
                     streaming,
                     command("c2", "swift test --filter Tab\nmore", ordinal: 6)]
        let d = RouterDetail.make(projection(items: items), now: now)
        #expect(d.said == "Found the gap. Moving the copy.")
        #expect(d.saidID == "m-a")
        #expect(d.toolKind == "command")
        #expect(d.workNow?.text == "swift test --filter Tab" && d.workNow?.mono == true && d.workNow?.id == 6)
        #expect(d.workRecent.map(\.text) == ["Read /a/Tab.swift", "Edited Composer.swift", "rg -n caret Sources"])
        // Nothing running now: no current step, the last ones are the recent ones; no run, no detail.
        let idle = RouterDetail.make(projection(items: Array(items.prefix(4))), now: now)
        #expect(idle.workNow == nil && idle.toolKind == nil)
        #expect(idle.workRecent.first?.text == "Read /a/Tab.swift")
        let over = RouterDetail.make(projection(runs: [F.run("r1", status: "completed")], items: items, status: "completed"), now: now)
        #expect(over.said == nil && over.workNow == nil && over.workRecent.isEmpty)
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

    /// T3 queues a finished delegated task's report into its parent as a user-role message it wrote itself
    /// (`createdBy: "agent"`, `creationSource: "server"`, `delegatedCompletion`), shaped as read from a real projection.
    @Test func onlyYourOwnQueuedWordsShow() {
        func queued(_ id: String, message: String, position: Int) -> T3JSON {
            var r = F.run(id, status: "queued", queuePosition: position)
            if case .object(var o) = r { o["userMessageId"] = .string(message); r = .object(o) }
            return r
        }
        var report = F.message("um-task", text: "Delegated task node:delegated-task:command%3Amcp%3A2ec7cca6%3Adelegate-task%3A7591 (Probe) [completed]:\nDone.")
        if case .object(var o) = report {
            o["createdBy"] = "agent"; o["creationSource"] = "server"
            o["delegatedCompletion"] = ["parentRunId": "r1"]
            report = .object(o)
        }
        var compact = F.message("um-compact", text: "/compact")
        if case .object(var o) = compact { o["createdBy"] = "agent"; o["creationSource"] = "server"; o["idleCompaction"] = "beforeCacheExpires"; compact = .object(o) }
        var phone = F.message("um-phone", text: "and from the phone")
        if case .object(var o) = phone { o["creationSource"] = "mobile"; phone = .object(o) }
        let p = projection(runs: [F.run("r1", status: "running"), queued("r-task", message: "um-task", position: 1),
                                  queued("r-mine", message: "um2", position: 2), queued("r-compact", message: "um-compact", position: 3),
                                  queued("r-phone", message: "um-phone", position: 4)],
                           messages: [F.message("um1", text: "First"), report, F.message("um2", text: "Then this"), compact, phone])
        #expect(RouterDetail.make(p, now: now).queued == [.init(id: "r-mine", words: "Then this"), .init(id: "r-phone", words: "and from the phone")])
        // Cancel's "your newest queued run" never lands on T3's own.
        #expect(p.ownQueuedRuns.map(\.id) == ["r-mine", "r-phone"])
        let onlyTask = projection(runs: [F.run("r1", status: "running"), queued("r-task", message: "um-task", position: 1)],
                                  messages: [F.message("um1", text: "First"), report])
        #expect(RouterDetail.make(onlyTask, now: now).queued.isEmpty)
        #expect(onlyTask.ownQueuedRuns.isEmpty)
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

    /// Each run's start, from its message's fields as T3 sets them (R6): your words; a delegated completion or a subagent's
    /// notification (the subagent's title); a background command's notification (its command); T3's own "continue" after
    /// a usage limit (stamped as yours, `server`, the recovery's id); anything else T3 queued: resumed by itself.
    @Test func runStarts() {
        func run(_ id: String, _ message: String, ordinal: Int) -> T3JSON {
            guard case .object(var o) = F.run(id, status: "completed") else { fatalError() }
            o["userMessageId"] = .string(message); o["ordinal"] = .number(Double(ordinal))
            return .object(o)
        }
        func message(_ id: String, _ text: String, _ extra: [String: T3JSON]) -> T3JSON {
            guard case .object(var o) = F.message(id, text: text) else { fatalError() }
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        let agent: [String: T3JSON] = ["createdBy": "agent", "creationSource": "server"]
        let messages = [
            message("m1", "  fix the   draft\n", [:]),
            message("m2", "Delegated task finished", agent.merging(["delegatedCompletion": ["parentRunId": "r1", "generation": 1, "taskIds": ["n1"]]]) { $1 }),
            message("m3", "Command finished", agent.merging(["notification": ["source": ["kind": "command"], "outcome": "completed",
                                                                                "summary": "Command \"swift test --filter X\" finished (exit 0)"]]) { $1 }),
            message("limit-resume:t1:r3:q1", "Continue where you left off.", ["createdBy": "user", "creationSource": "server"]),
            message("m5", "/compact", agent.merging(["idleCompaction": "beforeCacheExpires"]) { $1 }),
            message("m6", "Subagent finished", ["createdBy": "agent", "creationSource": "provider",
                                                "notification": ["source": ["kind": "subagent", "childThreadId": "c2"], "outcome": "completed",
                                                                 "summary": "Subagent finished"]]),
            message("m7", "Monitor reported", agent.merging(["notification": ["source": ["kind": "monitor"], "outcome": "updated",
                                                                              "summary": "Monitor reported new output"]]) { $1 }),
            message("m8", "", [:]),
        ]
        let runs = (1...8).map { run("r\($0)", "m\($0)", ordinal: $0) }.enumerated().map { i, r -> T3JSON in
            i == 3 ? run("r4", "limit-resume:t1:r3:q1", ordinal: 4) : r
        }
        var p = projection(runs: runs, messages: messages, status: "completed")
        p.others["subagents"] = [["id": "n1", "title": "Review the diff", "prompt": "Look at it", "childThreadId": "c1"],
                                 ["id": "n2", "title": nil, "prompt": "Check scroll restore\nthen report", "childThreadId": "c2"]]
        let starts = RouterDetail.starts(p)
        #expect(starts["r1"] == .asked("fix the   draft"))
        #expect(starts["r2"] == .subagents(["Review the diff"]))
        #expect(starts["r3"] == .command("swift test --filter X"))
        #expect(starts["r4"] == .usageLimit)
        #expect(starts["r5"] == .woken)
        #expect(starts["r6"] == .subagents(["Check scroll restore"]))
        #expect(starts["r7"] == .woken)
        #expect(starts["r8"] == nil)
        #expect(RouterDetail.commandLabel("2 commands finished") == nil)
        #expect(RouterDetail.commandLabel("Command \"a\", command \"b\" finished") == nil)
    }
}

