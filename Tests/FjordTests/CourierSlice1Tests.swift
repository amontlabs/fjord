import Foundation
import Testing
@testable import Fjord

/// Slice 1 of the Router's Swift port: JSON, store, page and board, mirroring poc/router/tests/test_board.py and test_page.py.
@Suite struct CourierSlice1 {
    static let now = 1_793_706_000.0

    // MARK: JSON

    @Test func pythonEquality() {
        #expect(JSON.int(1) == .double(1.0))
        #expect(JSON.bool(true) == .int(1))
        #expect(JSON.null != .string(""))
        let a: JSON = ["x": 1, "y": [1, 2.0]]
        let b: JSON = ["y": [1.0, 2], "x": 1.0]
        #expect(a == b)  // key order is no part of equality
        let missing: JSON = ["a": .null]
        #expect(missing.get("a") == nil && missing.get("b") == nil && missing["a"] == .null && missing["b"] == nil)
    }

    @Test func objectsKeepInsertionOrderAndEncodeAsPythonDumps() throws {
        var o: JSON = ["b": 1, "a": "é\"\n\u{01}", "c": [true, .null, 1.5, 2.0]]
        o["b"] = 3  // an existing key keeps its place
        #expect(o.encoded() == "{\"b\": 3, \"a\": \"é\\\"\\n\\u0001\", \"c\": [true, null, 1.5, 2.0]}")
        #expect(o.encoded(asciiOnly: true).contains("\\u00e9"))
        let parsed = try JSON.parse("{\"z\": 1, \"a\": [1, 1.0, \"\\u00e9\\ud83d\\ude00\"], \"n\": null}")
        #expect(parsed.asObject?.keys == ["z", "a", "n"])
        #expect(parsed["a"]?[0] == .int(1) && parsed["a"]?[1] == .double(1.0))
        #expect(parsed["a"]?[2] == .string("é😀"))
        #expect(try JSON.parse(parsed.encoded()) == parsed)
    }

    @Test func pythonStr() {
        #expect(JSON.null.pyStr == "None" && JSON.bool(true).pyStr == "True" && JSON.int(5).pyStr == "5")
        #expect(JSON.array([.string("a"), .null]).pyStr == "['a', None]")
        #expect(JSON.double(0.5).pyStr == "0.5")
    }

    // MARK: Store

    @Test func schemaIsByteEqualToThePythonStores() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("poc/router/store.py")
        let text = try String(contentsOf: source, encoding: .utf8)
        let open = try #require(text.range(of: "SCHEMA = \"\"\""))
        let close = try #require(text.range(of: "\"\"\"", range: open.upperBound..<text.endIndex))
        #expect(CourierStore.schema == String(text[open.upperBound..<close.lowerBound]))
    }

    private func temporaryStore() throws -> (CourierStore, String) {
        let path = NSTemporaryDirectory() + "courier-\(UUID().uuidString).db"
        return (try CourierStore(path: path), path)
    }

    @Test func seenIsAppendOnlyAndRoundTrips() throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rows = try store.addSeen(Self.now, [CourierPage.row("health", "page", [("connected", true), ("note", "é")])])
        #expect(rows[0]["id"] == 1 && rows[0]["at"] == .double(Self.now))
        let read = try store.seen()
        #expect(read.count == 1 && read[0]["fields"] == ["connected": true, "note": "é"])
        #expect(throws: (any Error).self) { try store.query("delete from seen") }
        #expect(throws: (any Error).self) { try store.query("update seen set kind = 'x'") }
        #expect(try store.lastSeenId() == 1)
        #expect(try store.seen(last: 0).isEmpty)
    }

    @Test func intentsKeepTheirJSONColumnsAndDeduplicate() throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (first, created) = try store.addIntent(Self.now, "send_to_project", words: "hi", project: "chan_a", proof: ["baseline": ["k1"]])
        #expect(created && first["status"] == "pending" && first["proof"] == ["baseline": ["k1"]] && first["args"] == .null)
        let (again, second) = try store.addIntent(Self.now + 5, "send_to_project", words: "hi", project: "chan_a")
        #expect(!second && again["id"] == first["id"])
        let (_, afterWindow) = try store.addIntent(Self.now + 500, "send_to_project", words: "hi", project: "chan_a")
        #expect(afterWindow)
        let updated = try store.updateIntent(Self.now + 1, 1, [("status", "failed"), ("result", ["acted": false, "n": 2]), ("cause", "x")])
        #expect(updated?["status"] == "failed" && updated?["result"] == ["acted": false, "n": 2] && updated?["updated"] == .double(Self.now + 1))
        #expect(try store.intents(status: "failed").count == 1 && (try store.intents(columns: CourierStore.lean))[0]["proof"] == nil)
        #expect(try store.longProofs(kept: 0).count == 1 && (try store.longProofs(kept: 1)).isEmpty)
        #expect(try store.chatProjects() == ["chan_a"])
    }

    @Test func toldMarkAndNotes() throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try store.setTold(Self.now, "k", "chan_a", "claim", "d", "t")
        try store.setMark(7)
        #expect(try store.mark() == 7 && (try store.told()).keys == ["k"])
        try store.setNote(Self.now, "b", "two")
        try store.setNote(Self.now, "a", "one")
        #expect((try store.notes()).keys == ["a", "b"])
    }

    @Test func compactKeepsTheNewestOfEachSubject() throws {
        let (store, path) = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let chat: (Double, [JSON]) -> JSON = { _, messages in CourierPage.row("chat", "chan_a", [("messages", .array(messages)), ("full", false)]) }
        for t in 0..<3 { _ = try store.addSeen(Self.now + Double(t), [chat(0, [])]) }
        try store.compact(before: Self.now + 10)
        #expect(try store.seen().count == 1)
        #expect(throws: (any Error).self) { try store.query("delete from seen") }  // the trigger is back
    }

    // MARK: Page

    private func stamp(_ event: JSON, path: String = "/code/project/chan_a", thread: String? = nil) -> JSON {
        var e = event
        e["path"] = .string(path)
        e["thread"] = JSON(thread)
        return e
    }

    @Test func theProjectComesFromTheAddress() {
        #expect(CourierPage.place(stamp([:])) == ("chan_a", nil))
        #expect(CourierPage.place(stamp([:], thread: "cmsg_1")) == ("chan_a", "cmsg_1"))
        #expect(CourierPage.place(stamp([:], path: "/code")) == (nil, nil))
        #expect(CourierPage.place([:]) == (nil, nil))
        #expect(CourierPage.place(stamp([:], path: "/code/project/chan_pending_1")) == (nil, nil))
    }

    @Test func rowsAreShapedAndUnknownAuthorsStayUnknown() {
        let rows = CourierPage.seenRows(stamp(["type": "rows", "side": "project", "rows": [
            ["key": "cmsg_1", "index": 1, "from": "you", "text": "hi"], ["key": "cmsg_2", "index": 2, "from": "robot", "text": "x", "decision": true, "streaming": true],
            ["key": "cmsg_3", "index": "3", "text": "bad"], ["key": "cmsg_4", "from": "you", "text": "no index"], ["index": 5, "from": "you", "text": "no key"]]]))
        #expect(rows.map { [$0["kind"]!, $0["subject"]!] } == [["chat", "chan_a"]])
        #expect(rows[0]["fields"]?["messages"] == [["key": "cmsg_1", "index": 1, "streaming": false, "decision": false, "from": "you", "text": "hi"],
                                                   ["key": "cmsg_2", "index": 2, "streaming": true, "decision": true, "from": "unknown", "text": "x"]])
    }

    @Test func pendingRowsAreNotMessagesAndFullIsKept() {
        let rows = CourierPage.seenRows(stamp(["type": "rows", "side": "project", "full": true, "rows": [
            ["key": "cmsg_pending_1", "pending": true, "index": 1, "from": "you", "text": "hi"], ["key": "provisional:2", "pending": true, "index": 2, "from": "claude", "text": "…"],
            ["key": "cmsg_3", "index": 3, "from": "claude", "text": "done"]]]))
        #expect(rows[0]["fields"]?["messages"]?.asArray?.map { $0["key"]! } == ["cmsg_3"])
        #expect(rows[0]["fields"]?["full"] == true)
    }

    @Test func rowsWhoseKeysNameAnotherProjectAreDropped() {
        let own = "chan_" + String(repeating: "a", count: 24), other = String(repeating: "b", count: 24)
        let rows = CourierPage.seenRows(stamp(["type": "rows", "side": "project", "rows": [
            ["key": .string("cmsg_\(String(repeating: "a", count: 24))x"), "index": 0, "from": "you", "text": "mine"],
            ["key": .string("cmsg_\(other)x"), "index": 1, "from": "you", "text": "stale"]]], path: "/code/project/\(own)"))
        #expect(rows[0]["fields"]?["messages"]?.asArray?.map { $0["text"]! } == ["mine"])
    }

    @Test func threadRowsBelongToTheThread() {
        let rows = CourierPage.seenRows(stamp(["type": "rows", "side": "thread", "rows": [["index": 0, "from": "claude", "text": "a"]]], thread: "cmsg_1"))
        #expect(rows[0]["kind"] == "messages" && rows[0]["subject"] == "cmsg_1")
        #expect(CourierPage.seenRows(stamp(["type": "rows", "side": "thread", "rows": []])).isEmpty)  // no thread in the address
    }

    @Test func aThreadOfAnotherProjectIsDropped() {
        let a = "01ALdwr3Azauc1mNNjYZvRME", b = "01G6g7NmUd2MSNGcfuecVcNy"
        let rows = CourierPage.seenRows(stamp(["type": "threads", "threads": [["thread": .string("cmsg_\(a)x1"), "state": "idle"], ["thread": .string("cmsg_\(b)x2"), "state": "idle"]]],
                                              path: "/code/project/chan_\(a)"))
        #expect(rows.map { $0["subject"]! } == [.string("cmsg_\(a)x1")])
    }

    @Test func threadsKeepKnownStatesOnly() {
        let rows = CourierPage.seenRows(stamp(["type": "threads", "threads": [
            ["thread": "cmsg_1", "title": "T", "state": "needs_you", "needs": "a choice", "text": "x"], ["thread": "cmsg_2", "state": "dancing", "needs": ""], ["title": "no id"]]]))
        let got = rows.map { [$0["subject"]!, $0["fields"]!["state"]!, $0["fields"]!["needs"]!, $0["fields"]!["project"]!] }
        #expect(got == [["cmsg_1", "needs_you", "a choice", "chan_a"], ["cmsg_2", "unknown", .null, "chan_a"]])
    }

    @Test func projectsKeepOnlyProjectIds() {
        let rows = CourierPage.seenRows(["type": "projects", "projects": [["id": "chan_a", "name": "alpha"], ["id": "other", "name": "x"], ["id": "chan_pending_1", "name": "new"]]])
        #expect(rows.map { [$0["subject"]!, $0["fields"]!["name"]!, $0["fields"]!["where"]!] } == [["chan_a", "alpha", "cloud"]])
    }

    @Test func theProjectsPageListDropsProjectsItLeavesOut() {
        let partial = CourierPage.seenRows(["type": "projects", "projects": [["id": "chan_a", "name": "alpha"], ["id": "chan_b", "name": "beta"]]])
        #expect(partial.map { $0["kind"]! } == ["project", "project"])
        let full = CourierPage.seenRows(["type": "projects", "complete": true, "projects": [["id": "chan_a", "name": "alpha"]]])
        #expect(full.last?["fields"] == ["ids": ["chan_a"]])
        let rows: [JSON] = (partial + full).enumerated().map { i, r in
            var r = r
            r["id"] = .int(i + 1)
            r["at"] = .double(Self.now + Double(i + 1))
            return r
        }
        #expect(CourierBoard.fold(rows)["projects"]?.asObject?.keys == ["chan_a"])
        #expect(CourierBoard.fold(Array(rows[..<2]))["projects"]?.asObject?.keys == ["chan_a", "chan_b"])
    }

    @Test func aSettingsReadIsASeenRowForItsProjectAndUnreadablePartsAreUnknown() {
        let out = CourierPage.seenRows(stamp(["type": "settings", "project": "chan_a", "goal": "g", "instructions": "i", "repos": ["a/b", 3], "folders": "no", "offered_folders": .null]))
        #expect(out[0]["kind"] == "settings" && out[0]["subject"] == "chan_a")
        #expect(out[0]["fields"] == ["goal": "g", "instructions": "i", "repos": ["a/b"], "folders": .null, "offered_folders": .null])
        #expect(CourierPage.seenRows(stamp(["type": "settings", "goal": "g"], path: "/code")).isEmpty)
    }

    @Test func composerAndPageEvents() {
        var rows = CourierPage.seenRows(stamp(["type": "composer", "side": "project", "draft": "words", "disabled": true]))
        #expect(rows[0]["kind"] == "chat" && rows[0]["fields"]?["draft"] == "words" && rows[0]["fields"]?["disabled"] == true)
        rows = CourierPage.seenRows(["type": "page", "signed_in": false, "page_ok": .null])
        #expect(rows[0]["kind"] == "health" && rows[0]["fields"] == ["connected": true, "signed_in": false, "page_ok": .null, "away": .null])
    }

    @Test func otherEventsMakeNoRows() {
        #expect(CourierPage.seenRows(["type": "done", "id": "c1", "ok": true]).isEmpty)
        #expect(CourierPage.seenRows(["type": "nonsense"]).isEmpty)
    }

    // MARK: Board

    private func rows(_ items: (Double, String, String, String, JSON)...) -> [JSON] {
        items.enumerated().map { i, r in ["id": .int(i + 1), "at": .double(r.0), "source": .string(r.1), "kind": .string(r.2), "subject": .string(r.3), "fields": r.4] }
    }

    @Test func sameRowsSameBoard() {
        let data = rows((1, "page", "thread", "t1", ["project": "p", "state": "working"]), (2, "page", "thread", "t1", ["project": "p", "state": "idle"]))
        #expect(CourierBoard.fold(data) == CourierBoard.fold(data.reversed()))
    }

    @Test func theProjectCarriesItsLastSettingsRead() {
        let read: (JSON) -> JSON = { goal in ["goal": goal, "instructions": "i", "repos": [], "folders": [], "offered_folders": .null] }
        let board = CourierBoard.fold(rows((Self.now, "page", "project", "chan_a", ["name": "alpha"]), (Self.now + 1, "page", "settings", "chan_a", read("one")),
                                           (Self.now + 2, "page", "settings", "chan_a", read("two"))))
        #expect(board.path("projects", "chan_a", "settings", "goal") == "two")
        #expect(CourierBoard.fold(rows((Self.now, "page", "project", "chan_a", ["name": "alpha"]))).path("projects", "chan_a", "settings") == .null)
    }

    @Test func aProjectNewAfterAFullListStaysButAKnownOneTheListLeftOutGoes() {
        let cloud: (String) -> JSON = { ["name": .string($0), "where": "cloud"] }
        let board = CourierBoard.fold(rows((Self.now, "page", "project", "chan_a", cloud("a")), (Self.now + 1, "page", "project", "chan_b", cloud("b")),
                                           (Self.now + 2, "page", "listing", "projects", ["ids": ["chan_a"]]), (Self.now + 3, "page", "project", "chan_c", cloud("c")),
                                           (Self.now + 4, "page", "project", "chan_b", cloud("b"))))
        #expect(pySorted(board["projects"]!.asObject!.keys) == ["chan_a", "chan_c"])
    }

    @Test func unknownStaysUnknown() {
        let board = CourierBoard.fold(rows((1, "page", "thread", "t1", ["project": "p", "state": "unknown", "needs": .null])))
        #expect(board.path("threads", "t1", "state") == "unknown" && board.path("threads", "t1", "needs") == .null)
    }

    @Test func filesOutrankPageAndUnknownFromATrustedSourceHidesNothing() {
        var board = CourierBoard.fold(rows((1, "files", "thread", "t1", ["project": "p", "state": "needs_you"]), (2, "page", "thread", "t1", ["state": "idle"])))
        #expect(board.path("threads", "t1", "state") == "needs_you")
        board = CourierBoard.fold(rows((1, "files", "thread", "t1", ["state": .null]), (2, "page", "thread", "t1", ["state": "idle"])))
        #expect(board.path("threads", "t1", "state") == "idle")
    }

    @Test func turnCountsEachTimeItStartsWorking() {
        let states = ["working", "idle", "working", "unknown", "working", "idle"]
        let board = CourierBoard.fold(states.enumerated().map { i, s in rows((Double(i), "page", "thread", "t1", ["state": .string(s)]))[0] }.enumerated().map { i, r in
            var r = r
            r["id"] = .int(i + 1)
            return r
        })
        #expect(board.path("threads", "t1", "turn") == 2)
    }

    @Test func aGoneProcessThatIsNotFinishedIsStranded() {
        for (state, expect) in [("working", "stranded"), ("needs_you", "stranded"), ("idle", "idle"), ("resolved", "resolved")] {
            let board = CourierBoard.fold(rows((1, "files", "thread", "t1", ["alive": false]), (2, "page", "thread", "t1", ["state": .string(state)])))
            #expect(board.path("threads", "t1", "state") == .string(expect))
        }
    }

    @Test func aChangedRowReplacesItsOldSelfByKeyAndAFullScanReplacesAll() {
        let old: [JSON] = [["key": "k1", "index": 1, "text": "a"], ["key": "k2", "index": 2, "text": "b"]]
        var merged = CourierBoard.mergeRows(old, [["key": "k2", "index": 3, "text": "b!"], ["key": "k3", "index": 2, "text": "c"]])
        #expect(merged.map { $0["text"]! } == ["a", "c", "b!"])  // k2 moved: ordered by index, never twice
        merged = CourierBoard.mergeRows(old, [["key": "k2", "index": 0, "text": "b"]], full: true)
        #expect(merged.map { $0["key"]! } == ["k2"])
    }

    @Test func rowsFoldIntoTheBoardAndATurningOnlyDeltaBeforeAWholeReadLeavesThemUnread() {
        let acc = CourierBoard.start()
        let chat: (Bool, [JSON]) -> JSON = { full, messages in ["id": 1, "at": 1.0, "source": "page", "kind": "chat", "subject": "chan_a",
                                                                 "fields": ["messages": .array(messages), "full": .bool(full), "turning": false]] }
        CourierBoard.step(acc, chat(false, []))
        #expect(CourierBoard.finish(acc).path("projects", "chan_a", "chat") == .null)
        CourierBoard.step(acc, chat(true, [["key": "k1", "index": 0, "from": "you", "text": "hi", "streaming": false, "decision": false]]))
        let board = CourierBoard.finish(acc)
        #expect(board.path("projects", "chan_a", "chat")?.asArray?.count == 1 && board.path("projects", "chan_a", "turning") == false)
    }

    @Test func proofNeedsARowAfterTheLastOneTheBaselineKnew() {
        let rows: [JSON] = [["key": "k1", "from": "claude", "text": "x", "index": 0], ["key": "k2", "from": "you", "text": "hi", "index": 1]]
        let board: JSON = ["projects": ["p": ["chat": .array(rows)]], "threads": [:]]
        let proof: JSON = ["project": "p", "thread": .null, "words": "hi", "baseline": ["k1", "k2"]]
        func with(_ baseline: [String]) -> JSON { var p = proof; p["baseline"] = .strings(baseline); return p }
        #expect(CourierBoard.proofHolds(board, proof) == false)
        #expect(CourierBoard.proofHolds(board, with(["k1"])) == true)
        #expect(CourierBoard.proofHolds(board, with(["gone"])) == false)  // rows that hold none of its keys can't be placed: none is new
        #expect(CourierBoard.proofHolds(board, with([])) == true)  // an empty chat's baseline: all are new
    }

    @Test func aRenumberedRowIsNotNew() {
        let board: JSON = ["projects": ["p": ["chat": [["key": "k1", "from": "you", "text": "hi", "index": 0]]]], "threads": [:]]
        #expect(CourierBoard.proofHolds(board, ["project": "p", "thread": .null, "words": "hi", "baseline": ["k1"]]) == false)
    }

    @Test func wordsAreComparedLooselyBecauseThePageRendersMarkdown() {
        let board: JSON = ["projects": ["p": ["chat": [["from": "you", "text": "Fix the bug in parse_url, then run the tests", "index": 3, "key": "k"]]]], "threads": [:]]
        let words = "fix the **bug** in `parse_url`,\nthen run the *tests*"
        #expect(CourierBoard.proofHolds(board, ["project": "p", "thread": .null, "words": .string(words), "baseline": []]) == true)
        #expect(CourierBoard.proofHolds(board, ["project": "p", "thread": .null, "words": "something else", "baseline": []]) == false)
    }

    @Test func anUnreadablePlaceProvesNothing() {
        let board: JSON = ["projects": ["p": ["chat": .null]], "threads": [:]]
        #expect(CourierBoard.proofHolds(board, ["project": "p", "thread": .null, "words": "hi", "baseline": []]) == nil)
    }

    @Test func assignGivesEachRowToTheSendWhoseWordsItIs() {
        let rows: [JSON] = [["key": "k1", "from": "you", "text": "yes", "index": 0], ["key": "k2", "from": "you", "text": "yes please, go on", "index": 1],
                            ["key": "k3", "from": "you", "text": "go on", "index": 2]]
        let board: JSON = ["projects": ["p": ["chat": .array(rows)]], "threads": [:]]
        let proof: (String) -> JSON = { ["project": "p", "thread": .null, "words": .string($0), "baseline": []] }
        let taken = CourierBoard.assign(board, [(.int(1), proof("yes")), (.int(2), proof("yes please, go on")), (.int(3), proof("go on"))])
        #expect(taken == [.int(1): "k1", .int(2): "k2", .int(3): "k3"])
        let claimed = CourierBoard.assign(board, [(.int(1), proof("yes"))], ["k1"])
        #expect(claimed.isEmpty)  // "yes" is no prefix of the longer row's words that ends shortly, and k1 is claimed
    }

    @Test func tokensAndLooseWordsFollowPython() {
        #expect(CourierBoard.tokens("Yesterday's build, 42!") == ["yesterday", "s", "build", "42"])
        #expect(!CourierBoard.startsWith("Yesterday's build broke", "yes"))
        #expect(CourierBoard.endsShortly("ok", "ok") && !CourierBoard.endsShortly("ok then", "ok"))
        #expect(CourierBoard.loose("Straße") == "strasse")
        #expect(CourierBoard.loose("**!!**") == "**!!**")  // no letters or digits: the squashed text
        #expect(CourierBoard.squash("  a \n b\t") == "a b")
    }

    @Test func agesOfCloudThreadsFollowTheOpenPlace() {
        let build: ((String, String?)?) -> JSON = { here in
            let acc = CourierBoard.foldInto(CourierBoard.start(), rows(
                (Self.now, "page", "thread", "cmsg_1", ["project": "chan_a", "state": "working"]), (Self.now + 50, "page", "chat", "chan_a", ["messages": []]),
                (Self.now + 90, "page", "thread", "cmsg_2", ["project": "chan_b", "state": "idle"]),
                (Self.now + 95, "files", "thread", "local:x", ["project": "local:x", "state": "working", "alive": true])))
            acc.here = here.map { [JSON($0.0), JSON($0.1)] } ?? .null
            return CourierBoard.finish(acc)
        }
        let elsewhere = build(("chan_b", nil))
        #expect(elsewhere.path("threads", "cmsg_1", "as_of") == .double(Self.now + 50) && elsewhere.path("projects", "chan_a", "seen") == .double(Self.now + 50))
        #expect(build(("chan_a", nil)).path("threads", "cmsg_1", "as_of") == .null && build(("chan_a", "cmsg_1")).path("threads", "cmsg_1", "as_of") == .null)
        #expect(build(nil).path("threads", "local:x", "as_of") == .null)
    }

    @Test func testOpsNameEveryPythonFunction() {
        #expect(CourierBoard.testOps["board.assign"] != nil && CourierPage.testOps["page.seen_rows"] != nil && CourierStore.testOps["store.add_intent"] != nil)
    }
}
