import Foundation
import Testing
@testable import Fjord

/// Slice 3: the Core driven by hand-built page events (a send confirmed, a send failed and watched, a look).
@Suite struct CourierSlice3 {
    final class World {
        let path: String
        let core: CourierCore
        let box: Box
        init() throws {
            path = NSTemporaryDirectory() + "courier-core-\(UUID().uuidString).db"
            let store = try CourierStore(path: path)
            let box = Box()
            self.box = box
            core = try CourierCore(db: store, out: { box.sent.append($0) }, clock: CourierClock(now: { box.t }, uptime: { box.up }))
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        var sends: [JSON] { box.sent.filter { $0["kind"] == "send" } }
        var opens: [JSON] { box.sent.filter { $0["kind"] == "open" } }
        func later(_ seconds: Double) { box.t += seconds; box.up += seconds }
        func stamp(_ event: JSON) -> JSON { var e = event; e["path"] = "/code/project/chan_a"; e["thread"] = .null; return e }

        /// A page with project chan_a open and settled on an empty chat.
        func pageUp() throws {
            try core.connection(true)
            try core.handle(["type": "page", "signed_in": true, "page_ok": true])
            try core.handle(["type": "projects", "complete": true, "projects": [["id": "chan_a", "name": "alpha"]]])
            try core.handle(stamp(["type": "rows", "side": "project", "full": true, "settled": true, "rows": [], "turning": false]))
            try core.handle(stamp(["type": "composer", "side": "project", "draft": "", "disabled": false]))
        }

        func youRow(_ text: String) -> JSON {
            stamp(["type": "rows", "side": "project", "turning": false, "rows": [["key": "cmsg_1", "index": 0, "from": "you", "text": .string(text)]]])
        }
    }
    final class Box { var t = 1_800_000_000.0; var up = 5_000.0; var sent: [JSON] = [] }

    @Test func aSendIsConfirmedByARowFromYou() throws {
        let w = try World()
        try w.pageUp()
        var finished: JSON?
        var decision: JSON?
        try w.core.say("hello there", project: "alpha", reply: { decision = $0 }, finished: { finished = $0 })
        #expect(decision?["event"] == "decision")
        let send = try #require(w.sends.last)
        #expect(send["text"] == "hello there" && send["side"] == "project" && send["project"] == "chan_a")
        try w.core.handle(["type": "done", "id": send["id"]!, "ok": true])
        try w.core.handle(w.stamp(["type": "composer", "side": "project", "draft": "", "disabled": false]))  // the page took the words
        #expect(finished == nil)
        try w.core.handle(w.youRow("hello there"))
        #expect(finished?["status"] == "confirmed")
        #expect(finished?["result"]?["row"] == "cmsg_1")
        #expect(w.core.runs.isEmpty)
    }

    @Test func aSendThePageTookButNeverShowedFailsAndIsWatchedThenConfirmedLate() throws {
        let w = try World()
        try w.pageUp()
        var finished: JSON?
        try w.core.say("hello there", project: "alpha", finished: { finished = $0 })
        let send = try #require(w.sends.last)
        try w.core.handle(["type": "done", "id": send["id"]!, "ok": true])
        try w.core.handle(w.stamp(["type": "composer", "side": "project", "draft": "", "disabled": false]))
        let run = try #require(w.core.runs[1])
        #expect(run.flag("taken") && w.core.nextDeadline() != nil)
        w.later(301)
        try w.core.tick()  // the wait is over: the place is opened once to read it
        #expect(!w.opens.isEmpty && run.flag("looking"))
        w.later(21)
        try w.core.tick()  // the look ends with no row from you
        #expect(finished?["status"] == "failed" && finished?["cause"] == "the page took the words but never confirmed them")
        #expect(w.core.watched.has(1))
        // a later row of yours with the words confirms it late
        try w.core.handle(w.youRow("hello there"))
        let intent = try CourierSQL(w.core.db).intent(1)
        #expect(intent["status"] == "confirmed" && (intent["cause"]?.asString ?? "").hasPrefix("confirmed late"))
        #expect(!w.core.watched.has(1))
    }

    @Test func aPausedSendWaitsForThePageAndGoesOnWhenItIsBack() throws {
        let w = try World()
        try w.core.connection(true)
        try w.core.handle(["type": "page", "signed_in": false, "page_ok": true])
        try w.core.handle(["type": "projects", "complete": true, "projects": [["id": "chan_a", "name": "alpha"]]])
        try w.core.say("hello", project: "alpha")
        #expect(try CourierSQL(w.core.db).intent(1)["status"] == "paused")
        #expect(w.sends.isEmpty)
        try w.core.handle(["type": "page", "signed_in": true, "page_ok": true])
        try w.core.handle(w.stamp(["type": "rows", "side": "project", "full": true, "settled": true, "rows": [], "turning": false]))
        try w.core.handle(w.stamp(["type": "composer", "side": "project", "draft": "", "disabled": false]))
        #expect(w.sends.count == 1)
        #expect(try CourierSQL(w.core.db).intent(1)["status"] == "pending")
    }

    @Test func aRefusedTargetFinishesAtOnceAndTellReportsAFinishedThread() throws {
        let w = try World()
        var finished: JSON?
        try w.core.say("hi", project: "nope", finished: { finished = $0 })
        #expect(finished?["status"] == "refused" && finished?["cause"] == "no project named nope")
        try w.core.handle(w.stamp(["type": "threads", "threads": [["thread": "cmsg_1", "title": "T", "state": "working"]]]))
        _ = try w.core.tell()
        try w.core.handle(w.stamp(["type": "threads", "threads": [["thread": "cmsg_1", "title": "T", "state": "idle"]]]))
        #expect(try w.core.tell() == ["T: finished"])
        #expect(try w.core.tell().isEmpty)
    }
}
