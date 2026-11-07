import Foundation
import Testing
@testable import Fjord

/// What a working thread shows of itself, read from its projection; the subscriptions held for it; Open in T3.
@MainActor
@Suite struct ThreadDetail {
    typealias F = T3Fixture

    private func projection(_ items: [T3JSON], run: String = "running") -> T3Projection {
        guard case .object(var top) = F.projection(), case .object(var body)? = top["projection"] else { fatalError() }
        body["runs"] = [F.run("r1", status: run)]
        body["turnItems"] = .array(items)
        top["projection"] = .object(body)
        guard case .snapshot(_, let p) = T3ThreadItem(json: .object(top)) else { fatalError() }
        return p
    }

    @Test func theCurrentItemIsTheOneStillRunningAndSaysItInItsOwnWords() throws {
        let p = projection([
            F.item("i1", type: "user_message", ordinal: 1, ["messageId": "um1", "text": "Please sort."]),
            F.item("i2", type: "assistant_message", ordinal: 2, ["messageId": "m2", "text": "Checking the seeds.", "streaming": false]),
            F.item("i3", type: "file_change", ordinal: 3, ["fileName": "src/seeds/list.txt", "additions": 3, "deletions": 1]),
            F.item("i4", type: "command_execution", ordinal: 4, status: "running", ["input": "ls seeds\nmore", "output": "a"]),
            F.item("i5", type: "todo_list", ordinal: 5, ["planId": "pl", "steps": [["id": "a", "text": "Sort", "status": "completed"],
                                                                              ["id": "b", "text": "Label", "status": "running"],
                                                                              ["id": "c", "text": "Water", "status": "pending"]]]),
        ])
        let w = try #require(ThreadWork(p))
        #expect(w.text == "ls seeds")
        #expect(w.todo == .init(done: 1, total: 3, active: "Label"))
        #expect(w.narration == "Checking the seeds.")
        #expect(w.files == 1)
        #expect(w.detail(branch: "fix/seeds", pullRequests: [])?.contains("1 of 3 done · Label") == true)
        #expect(w.detail(branch: "fix/seeds", pullRequests: [])?.contains("Branch fix/seeds") == true)
    }

    @Test func withNothingRunningTheLastToolItemAndTheOtherKindsReadByType() throws {
        #expect(try #require(ThreadWork(projection([F.item("a", type: "file_change", ordinal: 1, ["fileName": "a/b/c.swift"])]))).text == "Editing c.swift")
        #expect(try #require(ThreadWork(projection([F.item("a", type: "web_search", ordinal: 1, ["query": "swift actors"])]))).text == "swift actors")
        #expect(try #require(ThreadWork(projection([F.item("a", type: "dynamic_tool", ordinal: 1, ["toolName": "browser"])]))).text == "browser")
        #expect(try #require(ThreadWork(projection([F.item("a", type: "reasoning", ordinal: 1, ["text": "x", "streaming": true])]))).text == "Thinking")
        #expect(try #require(ThreadWork(projection([]))).text == "Working")
    }

    @Test func aThreadWithNoLiveRunHasNoWork() {
        #expect(ThreadWork(projection([F.item("a", type: "reasoning", ordinal: 1)], run: "completed")) == nil)
    }

    @Test func aProjectionEventUpdatesTheRowsActivityAndASettledThreadLosesIt() throws {
        let s = Store.reading([F.shell("t1", status: "running", extra: ["activityRunStatus": "running"])])
        #expect(s.t3.store.watchedThreads.isEmpty)  // no link, so nothing opens; the wanted set is what counts
        s.t3.store.seed(projection([F.item("a", type: "command_execution", ordinal: 1, status: "running", ["input": "swift test"])]), for: "t1")
        #expect(s.threadWork["t1"]?.text == "swift test")
        #expect(s.allAgentRows.first { $0.id == "t1" }?.activity?.text == "swift test")
        s.update(F.shell("t1", status: "completed", unseen: true))
        #expect(s.threadWork["t1"] == nil)
        #expect(s.t3.store.projections["t1"] == nil)
    }

    @Test func onlyWorkingListedThreadsAreWatched() {
        let s = Store.reading([F.shell("run", status: "running"), F.shell("done", status: "completed", unseen: true),
                               F.shell("settledRun", status: "running", extra: ["settledAt": "2026-01-01T00:00:00.000Z"])])
        s.t3.store.seed(projection([]), for: "done")
        s.syncThreadDetail()
        #expect(s.t3.store.projections["done"] == nil)
        #expect(s.threadWork["done"] == nil)
    }

    @Test func aThreadOpensThroughItsDeepLinkOnceTheEnvironmentIsKnown() {
        let s = Store.reading([F.shell("t1")])
        #expect(s.t3.store.deepLink("t1") == nil)
        #expect(!s.openThread("t1"))
        s.t3.store.setEnvironment("env-1")
        #expect(s.t3.store.deepLink("t1")?.absoluteString == "t3code://threads/env-1/t1")
    }

    @Test func anInterceptedOpenNamesTheThreadInT3() {
        let s = Store.reading([F.shell("t1", title: "Garden")])
        var opened: [String] = []
        s.interceptOpen = { opened.append($0) }
        s.openThread("t1")
        #expect(opened == ["Open in T3 · Garden"])
    }

    @Test func theFirstThingYouAskedComesFromTheProjection() {
        let p = projection([F.item("i1", type: "user_message", ordinal: 1, ["messageId": "um1", "text": "x"])])
        #expect(T3Store.firstUserMessage(in: p) == "Please sort the seed packets.")
    }

    @Test func theOpenGlyphDrawsInsideItsBox() {
        let box = OpenInT3Shape().path(in: CGRect(x: 0, y: 0, width: 20, height: 20)).boundingRect
        #expect(!box.isEmpty && CGRect(x: 0, y: 0, width: 20, height: 20).contains(box))
    }
}
