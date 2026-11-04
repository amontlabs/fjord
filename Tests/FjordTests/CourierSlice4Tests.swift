import Foundation
import Testing
@testable import Fjord

/// Slice 4: the Router's tools (set_goal, set_instructions, preapprove_folder) driven through the Core with hand-built page events,
/// and a store error failing a run instead of crashing.
@Suite struct CourierSlice4 {
    final class Box { var t = 1_800_000_000.0; var up = 5_000.0; var sent: [JSON] = [] }
    struct StoreFailure: Error {}

    final class World {
        let path: String
        let core: CourierCore
        let box: Box
        init() throws {
            path = NSTemporaryDirectory() + "courier-tools-\(UUID().uuidString).db"
            let box = Box()
            self.box = box
            core = try CourierCore(db: try CourierStore(path: path), out: { box.sent.append($0) }, clock: CourierClock(now: { box.t }, uptime: { box.up }))
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }
        func commands(_ kind: String) -> [JSON] { box.sent.filter { $0["kind"] == .string(kind) } }
        func stamp(_ event: JSON) -> JSON { var e = event; e["path"] = "/code/project/chan_a"; e["thread"] = .null; return e }

        /// A page with project chan_a open and settled on an empty chat.
        func pageUp() throws {
            try core.connection(true)
            try core.handle(["type": "page", "signed_in": true, "page_ok": true])
            try core.handle(["type": "projects", "complete": true, "projects": [["id": "chan_a", "name": "alpha"]]])
            try core.handle(stamp(["type": "rows", "side": "project", "full": true, "settled": true, "rows": [], "turning": false]))
            try core.handle(stamp(["type": "composer", "side": "project", "draft": "", "disabled": false]))
        }
    }

    @Test func aGoalIsConfirmedByTheStatusOfItsSave() throws {
        let w = try World()
        try w.pageUp()
        var finished: JSON?
        try w.core.tool("set_goal", args: [("project", "alpha"), ("text", "ship it")], finished: { finished = $0 })
        let act = try #require(w.commands("set_field").last)
        #expect(act["project"] == "chan_a" && act["field"] == "goal" && act["text"] == "ship it")
        try w.core.handle(["type": "done", "id": act["id"]!, "ok": true, "before": "old goal", "saved": 200])
        #expect(finished?["status"] == "confirmed")
        let result = try #require(finished?["result"])
        #expect(result["acted"] == true && result["provable"] == true && result["before"] == "old goal")
        #expect(w.core.runs.isEmpty && w.core.staleGoal.isEmpty)
    }

    @Test func aGoalWithNoAnswerToItsSaveFailsAndIsMarked() throws {
        let w = try World()
        try w.pageUp()
        var finished: JSON?
        try w.core.tool("set_goal", args: [("project", "alpha"), ("text", "ship it")], finished: { finished = $0 })
        let act = try #require(w.commands("set_field").last)
        try w.core.handle(["type": "done", "id": act["id"]!, "ok": true, "before": "old goal"])
        #expect(finished?["status"] == "failed" && finished?["cause"] == "done, but not confirmed: the page reported no answer to the save")
        #expect(w.core.staleGoal.has("chan_a"))
    }

    @Test func instructionsAreProvedByALaterRead() throws {
        let w = try World()
        try w.pageUp()
        var finished: JSON?
        try w.core.tool("set_instructions", args: [("project", "alpha"), ("text", "be brief\r\nplease")], finished: { finished = $0 })
        let act = try #require(w.commands("set_field").last)
        #expect(act["field"] == "instructions" && act["text"] == "be brief\nplease")  // line ends as the page's fields hold them
        try w.core.handle(["type": "done", "id": act["id"]!, "ok": true])  // committed, no answer to the save: a read decides
        #expect(finished == nil && w.core.runs[1]?.str("stage") == "prove")
        try w.core.handle(w.stamp(["type": "settings", "project": "chan_a", "goal": "g", "instructions": "be brief\nplease", "repos": [], "folders": [], "offered_folders": .null]))
        #expect(finished?["status"] == "confirmed")
    }

    @Test func aFolderGrantWaitsForConfirm() throws {
        let w = try World()
        try w.pageUp()
        var finished: JSON?
        var decision: JSON?
        try w.core.tool("preapprove_folder", args: [("project", "alpha"), ("path", "/tmp/x")], reply: { decision = $0 }, finished: { finished = $0 })
        #expect(decision?["intent"]?["status"] == "awaiting" && finished?["status"] == "awaiting")
        #expect(w.commands("preapprove_folder").isEmpty && w.core.runs.isEmpty)
        var done: JSON?
        try w.core.confirm(1, finished: { done = $0 })
        let act = try #require(w.commands("preapprove_folder").last)
        #expect(act["path"] == "/tmp/x" && w.core.runs.has(1))
        try w.core.handle(["type": "done", "id": act["id"]!, "ok": true, "before": [], "saved": 200])
        #expect(done?["status"] == "confirmed")
    }

    @Test func aToolWithBadArgumentsIsRefusedAndSendsNothing() throws {
        let w = try World()
        try w.pageUp()
        var finished: JSON?
        try w.core.tool("add_repo", args: [("project", "alpha"), ("repo", "nope")], finished: { finished = $0 })
        #expect(finished?["status"] == "refused" && finished?["cause"] == "a repository is owner/name")
        try w.core.tool("set_goal", args: [("project", "ghost"), ("text", "x")], finished: { finished = $0 })
        #expect(finished?["cause"] == "no project named ghost on the page")
        #expect(w.commands("set_field").isEmpty)
    }

    @Test func aStoreErrorFailsTheRunInsteadOfCrashing() throws {
        let w = try World()
        try w.pageUp()
        var finished: JSON?
        try w.core.say("hello there", project: "alpha", finished: { finished = $0 })
        #expect(w.core.runs.has(1))
        var armed = true
        w.core.db.beforeStatement = { sql in
            if armed && sql.hasPrefix("select * from intents where id") { armed = false; return StoreFailure() }
            return nil
        }
        try w.core.handle(w.stamp(["type": "composer", "side": "project", "draft": "", "disabled": false]))  // advances the run: its first read fails
        #expect(!armed)
        #expect(finished?["status"] == "failed")
        #expect((finished?["cause"]?.asString ?? "").hasPrefix("routerd error: "))
        #expect(w.core.runs.isEmpty)
    }

    @Test func aStoreErrorOutsideARunThrowsToTheCaller() throws {
        let w = try World()
        try w.pageUp()
        w.core.db.beforeStatement = { sql in sql.hasPrefix("insert into seen") ? StoreFailure() : nil }
        #expect(throws: StoreFailure.self) { try w.core.handle(w.stamp(["type": "composer", "side": "project", "draft": "x", "disabled": false])) }
    }
}
