import Foundation
import Testing
@testable import Fjord

/// A line's subagents, background commands and waits, read from T3's projection.
@Suite struct RouterActivityTests {
    typealias F = T3Fixture

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func projection(items: [T3JSON] = [], subagents: [T3JSON] = [], roster: [T3JSON] = [],
                            shell: [T3JSON] = []) -> T3Projection {
        guard case .object(var top) = F.projection(), case .object(var body)? = top["projection"] else { fatalError() }
        body["turnItems"] = .array(items)
        body["subagents"] = .array(subagents)
        body["providerThreads"] = [["id": "pt1", "pendingBackgroundTasks": .array(roster)]]
        body["thread"] = F.thread("t1", status: "running", extra: ["pendingBackgroundTasks": .array(shell)])
        top["projection"] = .object(body)
        guard case .snapshot(_, let p) = T3ThreadItem(json: .object(top)) else { fatalError() }
        return p
    }

    private func subagent(_ id: String, title: String?, model: String?, status: String = "running",
                          startedAt: String = "2026-01-02T03:00:00.000Z") -> T3JSON {
        ["id": .string(id), "threadId": "t1", "status": .string(status), "title": title.map(T3JSON.string) ?? nil,
         "prompt": "Review the diff and report.", "model": model.map(T3JSON.string) ?? nil, "startedAt": .string(startedAt),
         "childThreadId": .string("child-\(id)")]
    }

    private func task(_ id: String, _ kind: String, _ description: String? = nil, awaited: Bool = false) -> T3JSON {
        var o: [String: T3JSON] = ["taskId": .string(id), "kind": .string(kind)]
        if let description { o["description"] = .string(description) }
        if awaited { o["awaited"] = true }
        return .object(o)
    }

    @Test func liveSubagentsCarryTheirNameModelAndStart() {
        let p = projection(subagents: [subagent("s1", title: "Check the seams", model: "claude-opus-5-5"),
                                       subagent("s2", title: nil, model: nil),
                                       subagent("s3", title: "Done already", model: "claude-haiku-5-5", status: "completed")],
                           roster: [task("s1-task", "subagent", "Check the seams")])
        let a = RouterV2Activity.make(p)
        #expect(a.agents.map(\.name) == ["Check the seams", "Review the diff and report."])
        #expect(a.agents[0].model == "claude-opus-5-5")
        #expect(a.agents[0].since == AgentThread.date(T3Timestamp("2026-01-02T03:00:00.000Z")))
        #expect(a.agents[1].model == nil)
    }

    @Test func aRosterSubagentItsRecordCoversIsNotListedTwice() {
        var t = task("x", "subagent", "Check the seams")
        if case .object(var o) = t { o["childThreadId"] = "child-s1"; t = .object(o) }
        let a = RouterV2Activity.make(projection(subagents: [subagent("s1", title: "Check the seams", model: "claude-opus-5-5")], roster: [t]))
        #expect(a.agents.count == 1)
    }

    @Test func aBackgroundCommandShowsItsCommandAndStartFromTheItemThatStartedIt() {
        let bash = F.item("c1", type: "command_execution", ordinal: 3, status: "completed",
                          ["input": "gh run watch 432\n--exit-status", "startedAt": "2026-01-02T03:01:00.000Z",
                           "output": "Command running in background with ID: bmas1r4fq. Output is being written to: /tmp/x"])
        let a = RouterV2Activity.make(projection(items: [bash], roster: [task("bmas1r4fq", "command", "Watch CI")]))
        #expect(a.processes == [.init(id: "bmas1r4fq", command: "gh run watch 432", mono: true,
                                      since: AgentThread.date(T3Timestamp("2026-01-02T03:01:00.000Z")))])
        #expect(a.waits.isEmpty)

        // Not in the projection: T3's description, in sans.
        let bare = RouterV2Activity.make(projection(roster: [task("zz", "command", "Start the dev server")]))
        #expect(bare.processes.first?.command == "Start the dev server")
        #expect(bare.processes.first?.mono == false)
    }

    @Test func workTheAgentAwaitsIsAWait() {
        let wait = F.item("w", type: "dynamic_tool", ordinal: 4, status: "running",
                          ["toolName": "mcp__t3-code__t3_background_wait", "input": ["taskIds": ["b2"]]])
        let a = RouterV2Activity.make(projection(items: [wait], roster: [task("b1", "command", "Build", awaited: true),
                                                                         task("b2", "command", "Test")]))
        #expect(a.processes.isEmpty)
        #expect(a.waits.map(\.kind) == [.command, .command])
        #expect(a.waits.map(\.what) == ["Build", "Test"])
    }

    @Test func monitorsAndThreadWaitsButNotT3sPullRequestWatch() {
        let threadWait = F.item("tw", type: "dynamic_tool", ordinal: 5, status: "running",
                                ["toolName": "mcp__t3-code__t3_thread_wait", "input": ["threadId": "other"],
                                 "startedAt": "2026-01-02T03:02:00.000Z"])
        let monitor = F.item("m", type: "dynamic_tool", ordinal: 6, status: "running",
                             ["toolName": "Monitor", "input": ["description": "the release build", "command": "until …"]])
        let doneWait = F.item("tw2", type: "dynamic_tool", ordinal: 7, status: "completed",
                              ["toolName": "mcp__t3-code__t3_thread_wait", "input": ["threadId": "older"]])
        let a = RouterV2Activity.make(projection(items: [threadWait, monitor, doneWait],
                                                 shell: [task("pull-request-watch:github.com/a/b#41", "monitor", "Watching pull request #41")]))
        #expect(a.waits.map(\.kind) == [.thread, .monitor])
        #expect(a.waits.first?.thread == "other")
        #expect(a.waits.last?.what == "the release build")
    }

    @Test func aForegroundCommandIsNotBackgroundWork() {
        let running = F.item("c", type: "command_execution", ordinal: 2, status: "running", ["input": "swift build", "output": ""])
        #expect(RouterV2Activity.make(projection(items: [running])).isEmpty)
    }

    @Test func workWithNoStartKeepsTheTimeFjordFirstSawIt() {
        let first = RouterV2Activity.make(projection(roster: [task("zz", "command", "Serve")])).stamped(after: nil, now: now)
        #expect(first.processes.first?.since == now)
        let later = RouterV2Activity.make(projection(roster: [task("zz", "command", "Serve"), task("yy", "monitor", "Logs")]))
            .stamped(after: first, now: now + 60)
        #expect(later.processes.first?.since == now)
        #expect(later.waits.first?.since == now + 60)
        // Stamped again with nothing new, it is equal: the record doesn't move.
        #expect(later.stamped(after: later, now: now + 120) == later)
    }

    @Test func modelNames() {
        #expect(RouterV2Activity.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(RouterV2Activity.modelName("claude-haiku-5-5") == "Haiku 5.5")
        #expect(RouterV2Activity.modelName("gpt-6.1-sol") == "gpt-6.1-sol")
        #expect(RouterV2Activity.modelName("judge") == "judge")
    }

    @Test func theDetailCarriesIt() {
        let d = RouterDetail.make(projection(subagents: [subagent("s1", title: "Check", model: "claude-opus-5-5")]), now: now)
        #expect(d.activity.agents.count == 1)
    }
}
