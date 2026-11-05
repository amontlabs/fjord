import Foundation
import Testing
@testable import Fjord

/// The engine's side of watching through frames (docs/design/router-watch-and-briefs.md §6, engine rows): events by frame, the log of
/// items and statuses, the wanted set with kept and check slots, owed checks, `home`, the handover grant and `.answer`.
@Suite struct CourierFrames_ {
    final class Box { var t = 1_800_000_000.0; var up = 5_000.0; var sent: [JSON] = [] }

    final class World {
        let path: String
        var core: CourierCore
        let box: Box
        init(path: String? = nil) throws {
            self.path = path ?? NSTemporaryDirectory() + "courier-frames-\(UUID().uuidString).db"
            let box = Box()
            self.box = box
            core = try CourierCore(db: try CourierStore(path: self.path), out: { box.sent.append($0) }, clock: CourierClock(now: { box.t }, uptime: { box.up }))
        }
        func reopen() throws -> World {
            let w = try World(path: path)
            w.box.t = box.t
            return w
        }
        func commands(_ kind: String) -> [JSON] { box.sent.filter { $0["kind"] == .string(kind) } }
        func top(_ event: JSON, thread: String? = nil) -> JSON { var e = event; e["path"] = "/code/project/chan_a"; e["thread"] = JSON(thread); return e }
        func frame(_ event: JSON, _ project: String = "chan_a", _ thread: String? = nil) -> JSON {
            var e = event
            e["frame"] = ["project": .string(project), "thread": JSON(thread), "frameId": 3]
            e["path"] = .string("/code/project/\(project)")
            return e
        }

        /// The top frame on chan_a, settled, the projects listed, frames in use.
        func up(projects: [String] = ["chan_a"], frames: Bool = true) throws {
            try core.connection(true)
            try core.handle(["type": "page", "signed_in": true, "page_ok": true, "loaded": 1, "instance": "top1"])
            try core.handle(["type": "projects", "complete": true, "projects": .array(projects.map { ["id": .string($0), "name": .string($0)] })])
            try core.handle(top(["type": "rows", "side": "project", "full": true, "settled": true, "rows": [], "turning": false]))
            try core.handle(top(["type": "composer", "side": "project", "draft": "", "disabled": false]))
            if frames { try core.handle(["type": "frames", "have": []]) }
        }

        /// The project frame's listed overview read, its rows as given.
        func overview(_ rows: [JSON], project: String = "chan_a", listed: Bool = true) throws {
            try core.handle(frame(["type": "page", "signed_in": true, "page_ok": true, "loaded": 10, "instance": .string("f-\(project)")], project))
            try core.handle(frame(["type": "threads", "listed": .bool(listed), "threads": .array(rows)], project))
        }

        /// A thread frame's settled whole read.
        func threadView(_ thread: String, _ rows: [JSON], stop: Bool = false, project: String = "chan_a", loaded: Int = 20) throws {
            try core.handle(frame(["type": "page", "signed_in": true, "page_ok": true, "loaded": .int(loaded), "instance": .string("tf-\(thread)")], project, thread))
            try core.handle(frame(["type": "rows", "side": "thread", "full": true, "settled": true, "turning": false, "stop": .bool(stop), "rows": .array(rows)], project, thread))
        }

        func status(_ thread: String) -> String? { core.log.status[thread] }
        func statusItems(_ thread: String) -> [String] {
            ((try? core.db.items(project: nil, after: 0, kind: "status")) ?? []).filter { $0.id == thread }.compactMap { $0.content["status"]?.asString }
        }
        func lastWant() -> [JSON] { commands("frames").last?["want"]?.asArray ?? [] }
        func wantsThread(_ t: String) -> Bool { lastWant().contains { $0["thread"] == .string(t) } }
    }

    static func row(_ id: String, _ section: String, _ state: String = "unknown", time: String? = nil) -> JSON {
        var r: JSON = ["thread": .string(id), "title": .string("T \(id)"), "state": .string(state), "section": .string(section)]
        if let time { r["time"] = .string(time) }
        return r
    }
    static let running = { (id: String) in row(id, "running", "working") }
    static let dashed = { (id: String) in row(id, "active", "paused") }
    static func msg(_ key: String, _ index: Int, from: String = "claude", text: String = "hi") -> JSON {
        ["key": .string(key), "index": .int(index), "from": .string(from), "text": .string(text), "pending": false, "streaming": false]
    }
    static func card(_ key: String, _ index: Int, answered: Bool = false) -> JSON {
        var m = msg(key, index, text: "Which one?")
        m["decision"] = true; m["options"] = ["A", "B"]; m["answered"] = .bool(answered)
        return m
    }

    // MARK: Events by frame

    @Test func aFramesPageNoticeAndSignInLeaveTheTopFramesStateAlone() throws {
        let w = try World()
        try w.up()
        let (pages, loaded, instance, health) = (w.core.pages, w.core.loaded, w.core.instance, w.core.board()["health"])
        try w.core.handle(w.frame(["type": "page", "signed_in": false, "page_ok": true, "loaded": 99, "instance": "other"]))
        try w.core.handle(w.frame(["type": "notice", "text": "Too many requests"]))
        #expect(w.core.pages == pages && w.core.loaded == loaded && w.core.instance == instance)
        #expect(w.core.board()["health"] == health && w.core.notice.text == "")
        #expect(w.core.watch("chan_a") == .stale(since: w.box.t))  // a frame signed out is stale, nothing else
    }

    @Test func aFramesWholeRowsReadMergesAndReplacesNoRows() throws {
        let w = try World()
        try w.up()
        try w.core.handle(w.top(["type": "rows", "side": "project", "full": true, "settled": true, "turning": false, "rows": [Self.msg("k1", 1, from: "you")]]))
        try w.core.handle(w.frame(["type": "rows", "side": "project", "full": true, "settled": true, "turning": false, "rows": [Self.msg("k2", 2)]]))
        let keys = (w.core.board()["projects"]?["chan_a"]?["chat"]?.asArray ?? []).compactMap { $0["key"]?.asString }
        #expect(keys == ["k1", "k2"])
    }

    @Test func onlyAListedWholeThreadsReadMakesDepartures() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1"), Self.running("t2")])
        #expect(w.status("t1") == "working" && w.status("t2") == "working")
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.running("t1")]]))  // a partial read: says nothing of t2
        #expect(w.status("t2") == "working")
        try w.core.handle(w.frame(["type": "threads", "threads": []]))  // nor does a frame's empty partial read
        #expect(w.status("t1") == "working")
        try w.core.handle(w.frame(["type": "threads", "listed": true, "threads": [Self.running("t1")]]))
        #expect(w.status("t2") == "done" && w.status("t1") == "working")
        #expect(w.core.board()["threads"]?["t2"]?["state"] == "done")
    }

    @Test func aDepartureAmongOthersRecordsDone() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1"), Self.running("t2")])
        try w.core.handle(w.frame(["type": "threads", "threads": [["thread": "t2", "gone": true]]]))
        #expect(w.status("t2") == "done" && w.status("t1") == "working")
        #expect(w.core.board()["threads"]?["t2"]?["title"] == "T t2")  // a departure row is no thread row
    }

    // MARK: The log

    @Test func reReadsAddNothingAndChangedContentIsStoredOnce() throws {
        let w = try World()
        try w.up()
        let rows: JSON = [Self.msg("k1", 1)]
        try w.core.handle(w.top(["type": "rows", "side": "project", "full": true, "settled": true, "turning": false, "rows": rows]))
        try w.core.handle(w.frame(["type": "rows", "side": "project", "full": true, "settled": true, "turning": false, "rows": rows]))
        try w.core.handle(w.top(["type": "rows", "side": "project", "full": true, "settled": true, "turning": false, "rows": rows]))
        var items = try w.core.db.items(project: "chan_a", after: 0, kind: "row")
        #expect(items.count == 1)
        try w.core.handle(w.top(["type": "rows", "side": "project", "full": true, "settled": true, "turning": false, "rows": [Self.msg("k1", 1, text: "hi, edited")]]))
        try w.core.handle(w.top(["type": "rows", "side": "project", "full": true, "settled": true, "turning": false, "rows": [Self.msg("k1", 1, text: "hi, edited")]]))
        items = try w.core.db.items(project: "chan_a", after: 0, kind: "row")
        #expect(items.map { $0.content["text"]?.asString } == ["hi", "hi, edited"])
        let cursor = items[0].seq
        #expect(try w.core.db.items(project: "chan_a", after: cursor).map(\.kind) == ["row"])
        var streaming = Self.msg("k9", 9); streaming["streaming"] = true
        try w.core.handle(w.top(["type": "rows", "side": "project", "full": false, "settled": true, "turning": true, "rows": [streaming]]))
        #expect(try w.core.db.items(project: "chan_a", after: 0, kind: "row").count == 2)  // a streaming row isn't an item yet
    }

    @Test func aStatusIsRecordedOncePerChange() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1")])
        try w.overview([Self.running("t1")])
        try w.core.handle(w.top(["type": "threads", "threads": [Self.running("t1")]]))
        #expect(w.statusItems("t1") == ["working"])
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.row("t1", "done", "done")]]))
        #expect(w.statusItems("t1") == ["working", "done"])
        try w.core.handle(w.frame(["type": "threads", "listed": true, "threads": []]))  // the oldest done row dropping out records nothing
        #expect(w.statusItems("t1") == ["working", "done"])
    }

    @Test func aPendingCardWithADashedRowIsNeedsYouNeverDone() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1")])
        #expect(w.wantsThread("t1"))  // a kept frame for a working cloud thread
        try w.threadView("t1", [Self.msg("m1", 1), Self.card("c1", 2)])
        #expect(w.status("t1") == "needs you")
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.dashed("t1")]]))  // the row, 12 s later, looks idle
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.row("t1", "done", "done")]]))
        #expect(w.statusItems("t1") == ["working", "needs you"])
        let cards = try w.core.db.items(project: "chan_a", after: 0, kind: "card")
        #expect(cards.count == 1 && cards[0].id == "c1" && cards[0].content["options"] == ["A", "B"] && cards[0].thread == "t1")
    }

    @Test func pausedBecomesDoneOnlyAfterANoCardRead() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1")])
        try w.threadView("t1", [Self.msg("m1", 1)])
        #expect(w.status("t1") == "working")  // a no-card read while working finishes nothing
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.dashed("t1")]]))
        #expect(w.statusItems("t1") == ["working", "paused", "done"])  // its kept frame's settled read confirms idle
        #expect(!w.wantsThread("t1"))
        try w.core.handle(w.frame(["type": "threads", "listed": true, "threads": []]))  // the row leaving later adds nothing
        #expect(w.statusItems("t1") == ["working", "paused", "done"])
    }

    /// Measured live 2026-11-05: every frame load read finished threads, left in `active + dashed`, as paused, and they went done again.
    @Test func aFinishedThreadsUnchangedDashedRowAtEachLoadAddsNothing() throws {
        let w = try World()
        try w.up()
        let old = "2026-01-01T00:00:00Z"
        try w.overview([Self.row("t1", "running", "working", time: old)])
        try w.threadView("t1", [Self.msg("m1", 1)])
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.row("t1", "active", "paused", time: old)]]))
        #expect(w.statusItems("t1") == ["working", "paused", "done"])
        let w2 = try w.reopen()
        try w2.up()
        try w2.overview([Self.row("t1", "active", "paused", time: old)], listed: false)
        #expect(w2.statusItems("t1") == ["working", "paused", "done"])  // the same row at the next load: no change
        w2.box.t += 60
        try w2.core.handle(w2.frame(["type": "threads", "threads": [Self.row("t1", "active", "paused", time: "2030-01-01T00:00:00Z")]]))
        #expect(w2.status("t1") == "paused")  // the row moved on: it counts
    }

    @Test func aWaitingCardsIdleRowAfterARestartKeepsNeedsYou() throws {
        let w = try World()
        try w.up()
        let old = "2026-01-01T00:00:00Z"
        try w.overview([Self.row("t1", "running", "working", time: old)])
        try w.threadView("t1", [Self.msg("m1", 1), Self.card("c1", 2)])
        #expect(w.status("t1") == "needs you")
        let w2 = try w.reopen()
        try w2.up()
        try w2.overview([Self.row("t1", "active", "paused", time: old)], listed: false)
        #expect(w2.statusItems("t1") == ["working", "needs you"])
    }

    @Test func aPlainWordsRequestIsOneNeedsYou() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1")])
        try w.threadView("t1", [Self.msg("m1", 1, text: "May I push?")], stop: true)
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.row("t1", "needs", "needs_you")]]))
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.row("t1", "needs", "needs_you")]]))
        #expect(w.statusItems("t1") == ["working", "needs you"])
        #expect(!w.wantsThread("t1"))  // its frame went after the read
    }

    @Test func underAStaleProjectFrameALingeringStopWithholdsDone() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.dashed("t1")])
        #expect(w.status("t1") == "paused" && w.wantsThread("t1"))  // owed: paused, never read
        try w.core.handle(w.frame(["type": "frame_stuck"]))
        try w.core.handle(w.frame(["type": "frame_stuck"]))
        #expect(w.core.watch("chan_a") == .stale(since: w.box.t))
        try w.threadView("t1", [Self.msg("m1", 1)], stop: true)
        #expect(w.status("t1") == "paused")
        try w.threadView("t1", [Self.msg("m1", 1)], stop: false, loaded: 21)  // the next load clears it
        #expect(w.status("t1") == "done")
    }

    @Test func aStandInArchivesTheProjectAndAnApprovalSlotIsNeedsYou() throws {
        let w = try World()
        try w.up(projects: ["chan_a", "chan_b"])
        try w.overview([Self.running("t1")])
        var e = w.frame(["type": "rows", "side": "thread", "full": true, "settled": true, "turning": false, "stop": true, "approval": "Allow Bash?",
                         "rows": [Self.msg("m1", 1)]], "chan_a", "t1")
        try w.core.handle(e)
        #expect(w.status("t1") == "needs you" && w.core.log.statuses(project: "chan_a")["t1"] == "needs you")
        let last = try w.core.db.items(project: "chan_a", after: 0, kind: "status").last
        #expect(last?.content["needs"] == "permission")
        e = w.frame(["type": "page", "signed_in": true, "page_ok": true, "loaded": 11, "instance": "f-b", "stand_in": true], "chan_b")
        try w.core.handle(e)
        #expect(!w.lastWant().contains { $0["project"] == "chan_b" })
    }

    @Test func aStuckFrameIsReloadedByTheEngineThenStale() throws {
        let w = try World()
        try w.up()
        try w.core.handle(w.frame(["type": "frame_stuck"]))
        #expect(w.commands("reload").count == 1 && w.core.watch("chan_a") == .none)
        try w.core.handle(w.frame(["type": "frame_stuck"]))
        #expect(w.commands("reload").count == 1 && w.core.watch("chan_a") == .stale(since: w.box.t))
    }

    // MARK: Slots and owed checks

    @Test func threeKeptFramesThenTheLRUCardFrameIsEvicted() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1"), Self.running("t2"), Self.running("t3"), Self.running("t4")])
        #expect(w.core.watching.kept.map(\.thread) == ["t1", "t2", "t3"] && w.core.watching.overCap == ["t4"])
        try w.threadView("t1", [Self.card("c1", 1)])
        w.box.t += 1
        try w.threadView("t2", [Self.card("c2", 1)])
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.row("t5", "running", "working")]]))
        #expect(w.core.watching.kept.map(\.thread) == ["t2", "t3", "t5"])  // t1's card frame was the least recently used
        #expect(w.status("t1") == "needs you")
    }

    @Test func aFourthThreadsCardIsFoundThroughTheCheckSlot() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1"), Self.running("t2"), Self.running("t3")])
        for t in ["t1", "t2", "t3"] { try w.threadView(t, [Self.card("c-\(t)", 1)]) }
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.dashed("t4")]]))
        #expect(w.core.watching.check?.thread == "t4")
        try w.threadView("t4", [Self.card("c-t4", 1)])
        #expect(w.status("t4") == "needs you" && w.core.watching.check == nil)
    }

    @Test func owedChecksAreServedNeedsFirstThenNewestAndSurviveARestart() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.dashed("t1"), Self.row("t2", "active", "paused", time: "2027-01-15T08:00:00Z"), Self.row("t3", "needs", "needs_you")])
        let owed = w.core.checks().values.filter(\.owed).map(\.thread).sorted()
        #expect(owed == ["t1", "t2", "t3"])
        #expect(w.core.watching.check?.thread == "t3")  // needs-you first
        let w2 = try w.reopen()
        #expect(w2.core.checks().values.filter(\.owed).map(\.thread).sorted() == ["t1", "t2", "t3"])
        try w.threadView("t3", [Self.msg("m", 1)])
        #expect(w.core.watching.check?.thread == "t2")  // then the newest row time
    }

    @Test func aHandoverRequeuesTheCheckInFlight() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.dashed("t1")])
        #expect(w.core.watching.check?.thread == "t1")
        try w.core.handle(["type": "handover_wanted", "budget": 6])
        #expect(w.commands("handover").count == 1)
        #expect(w.core.watching.check == nil && w.core.checks()["t1"]?.owed == true)
        try w.core.handle(["type": "handover_done", "tabId": 7, "instance": "top2"])
        let base = try #require(w.commands("frames").last)
        #expect(base["base"] == true && base["want"]?.asArray?.contains { $0["thread"] == "t1" } == true)
        try w.overview([Self.dashed("t1")])
        #expect(w.core.watching.check?.thread == "t1")
    }

    @Test func afterARestartAWorkingThreadGetsItsKeptFrameAndAPausedOneItsCheck() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1"), Self.running("t2")])
        let w2 = try w.reopen()
        try w2.up()
        #expect(w2.status("t1") == "working")  // the log keeps statuses across a restart
        try w2.overview([Self.running("t1"), Self.dashed("t2")])
        #expect(w2.core.watching.kept.map(\.thread) == ["t1"] && w2.core.watching.check?.thread == "t2")
        #expect(w2.statusItems("t1") == ["working"])
    }

    // MARK: home

    @Test func homeIsIssuedOnlyWithNoRunLeft() throws {
        let w = try World()
        try w.up(frames: false)
        try w.core.handle(["type": "frames", "have": []])
        let home = try #require(w.commands("open").last)
        #expect(home["home"] == true && home["project"] == .null)
        try w.core.handle(["type": "done", "id": home["id"]!, "ok": true])
        #expect(w.core.watching.homeID == nil)
        // a send: no home while it runs
        try w.core.say("hello", project: "chan_a")
        let before = w.commands("open").filter { $0["home"] == true }.count
        #expect(w.core.runs.count == 1 && w.core.watching.homeID == nil)
        #expect(w.commands("open").filter { $0["home"] == true }.count == before)
    }

    @Test func aStaleFrameIsReloadedThreeTimesAcrossHomeStepsThenOnlyOnAnEvent() throws {
        let w = try World()
        try w.up(projects: ["chan_a", "chan_b"])
        try w.core.handle(["type": "done", "id": w.commands("open").last!["id"]!, "ok": true])
        try w.core.handle(w.frame(["type": "frame_blank"], "chan_b"))
        try w.core.handle(w.frame(["type": "frame_blank"], "chan_b"))  // reload once, then stale
        #expect(w.core.watch("chan_b") == .stale(since: w.box.t))
        let reloads = { w.commands("reload").filter { $0["frame"]?["project"] == "chan_b" }.count }
        #expect(reloads() == 1)
        for _ in 0..<5 {
            w.core.watching.homeWanted = true
            w.core.maybeHome()
            if let h = w.core.watching.homeID { try w.core.handle(["type": "done", "id": .string(h), "ok": true]) }
        }
        #expect(reloads() == 4)
        try w.core.handle(["type": "projects", "complete": true, "projects": [["id": "chan_a", "name": "a"], ["id": "chan_b", "name": "b"]]])
        w.core.watching.homeWanted = true
        w.core.maybeHome()
        #expect(reloads() == 5)  // a complete projects read reset its count
    }

    @Test func aFrameWithNoPageIsInjectedOnceThenBlank() throws {
        let w = try World()
        try w.up()
        try w.core.handle(w.frame(["type": "frame_loaded", "frameId": 3]))
        w.box.t += 21
        try w.core.tick()
        #expect(w.commands("frame_inject").count == 1)
        w.box.t += 21
        try w.core.tick()
        #expect(w.commands("reload").count == 1)  // blank: reloaded once
    }

    // MARK: The handover and answers

    @Test func aHandoverWaitsForAnAnswerInFlightAndAbortsAtItsDeadline() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.dashed("t1")])
        try w.threadView("t1", [Self.card("c1", 1)])
        try w.core.answer("chan_a", "t1", card: "c1", option: 1)
        let answer = try #require(w.commands("answer").last)
        #expect(answer["card"] == "c1" && answer["option"] == 1 && answer["frame"]?["thread"] == "t1")
        try w.core.handle(["type": "handover_wanted", "budget": 12])
        #expect(w.commands("handover").isEmpty)
        try w.core.handle(w.frame(["type": "done", "id": answer["id"]!, "ok": true], "chan_a", "t1"))
        #expect(w.commands("handover").count == 1)
        w.box.t += 21
        try w.core.tick()
        #expect(w.commands("handover_abort").count == 1)
    }

    @Test func anAnswerIsProvedByTheCardAnsweredThenTheRowWorking() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.dashed("t1")])
        try w.threadView("t1", [Self.card("c1", 1)])
        var finished: JSON?
        try w.core.answer("chan_a", "t1", card: "c1", option: 1, finished: { finished = $0 })
        let answer = try #require(w.commands("answer").last)
        try w.core.handle(w.frame(["type": "done", "id": answer["id"]!, "ok": true], "chan_a", "t1"))
        try w.threadView("t1", [Self.card("c1", 1, answered: true)])
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.dashed("t1")]]))  // the lagging row: no finish
        #expect(finished == nil && w.status("t1") == "needs you")
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.running("t1")]]))
        #expect(finished?["status"] == "confirmed" && w.status("t1") == "working")
    }

    @Test func anAnswerRetriesOnceThenFailsAndARefusalEndsIt() throws {
        let w = try World()
        try w.up()
        var finished: JSON?
        try w.core.answer("chan_a", "t1", card: "c1", option: 1, finished: { finished = $0 })
        #expect(w.wantsThread("t1"))  // no frame: one opened on demand
        w.box.t += 21
        try w.core.tick()
        #expect(w.commands("answer").count == 2)
        w.box.t += 21
        try w.core.tick()
        #expect(finished?["status"] == "failed" && w.commands("answer").count == 2)
        var refused: JSON?
        try w.core.answer("chan_a", "t1", card: "c2", option: 1, finished: { refused = $0 })
        let a = try #require(w.commands("answer").last)
        try w.core.handle(w.frame(["type": "done", "id": a["id"]!, "ok": true, "refused": true, "error": "already answered"], "chan_a", "t1"))
        #expect(refused?["status"] == "refused" && refused?["cause"] == "already answered")
    }

    @Test func anAnswerCutOffByFrameGoneIsReissuedOnceAfterTheReplay() throws {
        let w = try World()
        try w.up()
        try w.core.answer("chan_a", "t1", card: "c1", option: 1)
        let first = try #require(w.commands("answer").last)
        try w.core.handle(w.frame(["type": "frame_gone"], "chan_a", "t1"))
        try w.core.handle(["type": "handover_wanted", "budget": 6])
        #expect(w.commands("handover").count == 1)  // a lost answer is not in flight
        try w.core.handle(w.frame(["type": "commands", "waiting": [], "done": []], "chan_a", "t1"))
        let second = try #require(w.commands("answer").last)
        #expect(second["id"] != first["id"] && w.commands("answer").count == 2)
    }

    @Test func threeWorkingKeptFramesAndAnAnswerTakesTheCheckSlotAtOnce() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1"), Self.running("t2"), Self.running("t3"), Self.dashed("t4")])
        #expect(w.core.watching.check?.thread == "t4")
        try w.core.answer("chan_a", "t9", card: "c9", option: 1)
        #expect(w.core.watching.check?.thread == "t9" && w.core.watching.checkAnswer)
        #expect(w.core.checks()["t4"]?.owed == true)
    }

    // MARK: Review fixes: deltas, loads, drops, pins, the handover, checks, the log

    /// A thread frame's delta after its settled read: rows by key only, with its dock.
    static func delta(_ rows: [JSON], stop: Bool = false) -> JSON {
        ["type": "rows", "side": "thread", "full": false, "turning": false, "stop": .bool(stop), "approval": .null, "rows": .array(rows)]
    }

    @Test func aCardAskedInADeltaIsNeedsYouAndItsAnswerFromADeltaIsProved() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1")])
        try w.threadView("t1", [Self.msg("m1", 1)])
        try w.core.handle(w.frame(Self.delta([], stop: true), "chan_a", "t1"))
        #expect(w.core.watching.states[CourierFrame(project: "chan_a", thread: "t1")]?.stop == true)  // the dock from a delta
        try w.core.handle(w.frame(Self.delta([Self.card("c1", 2)]), "chan_a", "t1"))
        #expect(w.status("t1") == "needs you" && w.core.watching.pendingCard["t1"] == "c1")
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.dashed("t1")]]))
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.row("t1", "done", "done")]]))
        #expect(w.statusItems("t1") == ["working", "needs you"])  // never done past a pending card
        var finished: JSON?
        try w.core.answer("chan_a", "t1", card: "c1", option: 1, finished: { finished = $0 })
        let answer = try #require(w.commands("answer").last)
        try w.core.handle(w.frame(["type": "done", "id": answer["id"]!, "ok": true, "clicked": true], "chan_a", "t1"))
        try w.core.handle(w.frame(Self.delta([Self.card("c1", 2, answered: true)]), "chan_a", "t1"))
        #expect(w.core.watching.pendingCard["t1"] == nil)
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.running("t1")]]))
        #expect(finished?["status"] == "confirmed" && w.status("t1") == "working")
    }

    @Test func aPageBeforeItsFrameLoadedWaitsForNothing() throws {
        let w = try World()
        try w.up()
        try w.core.handle(w.frame(["type": "page", "signed_in": true, "page_ok": true, "loaded": 10, "instance": "f1", "documentId": "d1"]))
        try w.core.handle(w.frame(["type": "frame_loaded", "frameId": 3, "documentId": "d1"]))
        w.box.t += 21
        try w.core.tick()
        w.box.t += 21
        try w.core.tick()
        #expect(w.commands("frame_inject").isEmpty && w.commands("reload").isEmpty)
    }

    @Test func theDropAfterTheEnginesReloadOrTheTopsIsNoFailure() throws {
        let w = try World()
        try w.up(projects: ["chan_a", "chan_b"])
        try w.core.handle(w.frame(["type": "frame_stuck"]))
        #expect(w.commands("reload").count == 1)
        try w.core.handle(w.frame(["type": "frame_gone"]))  // the old document of the engine's own reload
        #expect(w.commands("reload").count == 1 && w.core.watch("chan_a") == .none)
        try w.core.handle(w.frame(["type": "page", "signed_in": true, "page_ok": true, "loaded": 11, "instance": "f2"]))
        w.box.t += 50
        try w.core.tick()
        #expect(w.commands("frame_inject").isEmpty && w.commands("reload").count == 1)
        try w.core.handle(["type": "page", "signed_in": .null, "page_ok": false, "gone": true])  // the top document went
        try w.core.handle(w.frame(["type": "frame_gone"], "chan_b"))
        #expect(w.commands("reload").count == 1 && w.core.watch("chan_b") == .none)
    }

    @Test func anAnswersFrameIsPinnedAndItsRetryWantsItAgain() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.running("t1"), Self.running("t2"), Self.running("t3")])
        for t in ["t1", "t2", "t3"] { try w.threadView(t, [Self.card("c-\(t)", 1)]); w.box.t += 1 }
        try w.core.answer("chan_a", "t1", card: "c-t1", option: 1)
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.running("t5")]]))
        #expect(w.core.watching.kept.map(\.thread).contains("t1"))  // the LRU card frame, but pinned: t2's went
        try w.core.handle(["type": "page", "signed_in": true, "page_ok": true, "loaded": 2, "instance": "top2"])  // a new top document
        #expect(w.core.watching.kept.map(\.thread).contains("t1") && w.wantsThread("t1"))
        w.core.watching.kept.removeAll { $0.thread == "t1" }  // gone anyway
        w.box.t += 21
        try w.core.tick()
        #expect(w.commands("answer").count == 2 && w.wantsThread("t1"))  // the retry wants it again
    }

    @Test func alreadyAnsweredAfterOurOwnClickIsProofPending() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.dashed("t1")])
        try w.threadView("t1", [Self.card("c1", 1)])
        var finished: JSON?
        try w.core.answer("chan_a", "t1", card: "c1", option: 1, finished: { finished = $0 })
        let first = try #require(w.commands("answer").last)
        try w.core.handle(w.frame(["type": "done", "id": first["id"]!, "ok": true, "clicked": true], "chan_a", "t1"))
        try w.threadView("t1", [Self.card("c1", 1)], loaded: 21)  // the answer's frame, opened again: its settled read, then deltas
        w.box.t += 21
        try w.core.tick()
        let second = try #require(w.commands("answer").last)
        try w.core.handle(w.frame(["type": "done", "id": second["id"]!, "ok": false, "refused": true, "error": "already answered"], "chan_a", "t1"))
        #expect(finished == nil)
        try w.core.handle(w.frame(Self.delta([Self.card("c1", 1, answered: true)]), "chan_a", "t1"))
        try w.core.handle(w.frame(["type": "threads", "threads": [Self.running("t1")]]))
        #expect(finished?["status"] == "confirmed")
    }

    @Test func oneHandoverAtATimeAndItsBaseSetOnce() throws {
        let w = try World()
        try w.up()
        try w.core.handle(["type": "handover_wanted", "budget": 6])
        try w.core.handle(["type": "handover_wanted", "budget": 7])
        #expect(w.commands("handover").count == 1)
        let bases = { w.commands("frames").filter { $0["base"] == true }.count }
        let before = bases()
        try w.core.handle(["type": "handover_done", "tabId": 8, "instance": "top2"])
        try w.core.handle(["type": "page", "signed_in": true, "page_ok": true, "loaded": 2, "instance": "top2"])
        #expect(bases() == before + 1)
        try w.core.handle(["type": "done", "id": "x", "ok": true])
        try w.core.tick()
        #expect(w.commands("handover").count == 1 && w.core.watching.handoverBudget == nil)
    }

    @Test func aFrameIsLiveOnlyAfterASettledWholeRead() throws {
        let w = try World()
        try w.up()
        try w.core.handle(w.frame(["type": "commands", "waiting": [], "done": []]))
        #expect(w.core.watch("chan_a") == .none)
        try w.overview([])
        #expect(w.core.watch("chan_a") == .live)
    }

    @Test func departuresCountOnlyAfterAListedReadAndKeepOwedChecks() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.dashed("t1")], listed: false)
        try w.core.handle(w.frame(["type": "threads", "threads": [["thread": "t1", "gone": true]]]))
        #expect(w.status("t1") == "paused")  // no listed read of this document yet
        try w.overview([Self.dashed("t1")])
        try w.core.handle(w.frame(["type": "threads", "threads": [["thread": "t1", "gone": true]]]))
        #expect(w.status("t1") == "done" && w.core.checks()["t1"]?.owed == true)
    }

    @Test func aCheckThatNeverSettlesIsRequeuedThenUnchecked() throws {
        let w = try World()
        try w.up()
        try w.overview([Self.dashed("t1")])
        #expect(w.core.watching.check?.thread == "t1")
        w.box.t += 61
        try w.core.tick()
        #expect(w.core.watching.check?.thread == "t1" && w.core.checks()["t1"]?.owed == true)  // requeued
        w.box.t += 61
        try w.core.tick()
        #expect(w.core.watching.check == nil && w.core.checks()["t1"]?.owed == false)
        #expect(w.core.checks()["t1"]?.why?.hasPrefix("unchecked") == true)
    }

    @Test func aRenumberingOrARowsClockAddsNoItem() throws {
        let w = try World()
        try w.up()
        try w.core.handle(w.top(["type": "rows", "side": "project", "full": true, "settled": true, "turning": false, "rows": [Self.msg("k1", 1)]]))
        try w.core.handle(w.top(["type": "rows", "side": "project", "full": true, "settled": true, "turning": false, "rows": [Self.msg("k1", 7)]]))
        #expect(try w.core.db.items(project: "chan_a", after: 0, kind: "row").count == 1)
        var r = Self.running("t1"); r["text"] = "T t1 now"
        try w.overview([r])
        r["text"] = "T t1 1m"
        try w.overview([r])
        #expect(try w.core.db.items(project: "chan_a", after: 0, kind: "thread").count == 1)
        let w2 = try w.reopen()
        try w2.core.handle(w2.top(["type": "rows", "side": "project", "full": true, "settled": true, "turning": false, "rows": [Self.msg("k1", 9)]]))
        #expect(try w2.core.db.items(project: "chan_a", after: 0, kind: "row").count == 1)  // after a restart too
    }

    @Test func noFramesNoHomeUntilTheTopFrameReportsThem() throws {
        let w = try World()
        try w.up(frames: false)
        try w.core.say("hello", project: "chan_a")
        #expect(w.commands("frames").isEmpty && w.commands("open").allSatisfy { $0["home"] == nil })
    }
}
