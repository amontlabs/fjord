import Foundation
import Testing
@testable import Fjord

/// Slice 2 of the Router's Swift port: Do and Tell, mirroring the pure parts of poc/router/tests/test_do.py, test_tell.py and test_tools.py.
@Suite struct CourierSlice2 {
    static let now = 1_793_706_000.0

    private func thread(_ state: String, _ turn: Int, detail: String = "", _ more: [(String, JSON)] = []) -> JSON {
        var t: JSON = ["id": "t1", "project": "p", "title": "Task", "state": .string(state), "turn": .int(turn), "needs": .null, "detail": .string(detail), "text": ""]
        for (k, v) in more { t[k] = v }
        return t
    }

    private func board(_ threads: JSON...) -> JSON {
        var o = JSONObject()
        for t in threads { o[t["id"]!.asString!] = t }
        return ["threads": .object(o), "projects": [:], "claims": []]
    }

    private func chatBoard(_ rows: [JSON]) -> JSON { ["projects": ["p": ["chat": .array(rows)]], "threads": [:]] }
    private func you(_ key: String, _ text: String, _ index: Int) -> JSON { ["key": .string(key), "from": "you", "text": .string(text), "index": .int(index)] }
    private func claude(_ key: String, _ index: Int) -> JSON { ["key": .string(key), "from": "claude", "text": "x", "index": .int(index)] }

    // MARK: Tell: facts

    @Test func finishedIsKeyedByTheChange() {
        #expect(CourierTell.facts(board(thread("working", 1)), board(thread("idle", 1))).map { $0["key"]! } == ["t1|finished|1"])
    }

    @Test func noChangeNoFactAndANewIdleThreadIsNoFinish() {
        #expect(CourierTell.facts(board(thread("working", 1)), board(thread("working", 1))).isEmpty)
        #expect(CourierTell.facts(board(), board(thread("idle", 1))).isEmpty)
    }

    @Test func needsYouAndANextTurn() {
        #expect(CourierTell.facts(board(thread("working", 1)), board(thread("needs_you", 1)))[0]["key"] == "t1|needs_you|1")
        #expect(CourierTell.facts(board(thread("idle", 1)), board(thread("idle", 2)))[0]["key"] == "t1|finished|2")
    }

    @Test func theKeyIgnoresWording() {
        let a = CourierTell.facts(board(thread("working", 1)), board(thread("idle", 1, detail: "one way")))[0]
        let b = CourierTell.facts(board(thread("working", 1)), board(thread("idle", 1, detail: "another way")))[0]
        #expect(a["key"] == b["key"])
    }

    @Test func aFactFromAnEarlierVisitIsToldWithItsAgeAtTheTimeOfTelling() {
        let f = CourierTell.facts(board(thread("working", 1)), board(thread("needs_you", 1, [("as_of", .double(Self.now - 600))])))[0]
        #expect(CourierTell.plan([f], JSONObject(), [], Self.now).say[0]["text"] == "Task: needs you (as of 10m ago)")
        #expect(CourierTell.plan([f], JSONObject(), [], Self.now + 3600).say[0]["text"] == "Task: needs you (as of 1h ago)")
        #expect(f["key"] == "t1|needs_you|1")
    }

    @Test func aLiveFactIsToldAsItIs() {
        let f = CourierTell.facts(board(thread("working", 1)), board(thread("needs_you", 1, [("as_of", .null)])))[0]
        #expect(CourierTell.plan([f], JSONObject(), [], Self.now).say[0]["text"] == "Task: needs you")
    }

    // MARK: Tell: plan and the lost-process facts

    @Test func toldSuppressesRepeatsAndALaterVersionUpdatesQuietly() {
        let f = CourierTell.facts(board(thread("working", 1)), board(thread("idle", 1, detail: "one")))[0]
        let told = JSONObject([("t1|finished|1", ["key": "t1|finished|1", "at": .double(Self.now), "project": "p", "kind": "finished", "detail": "one", "text": "x"])])
        #expect(CourierTell.plan([f], told, [], Self.now + 1).say.isEmpty && CourierTell.plan([f], told, [], Self.now + 1).quiet.isEmpty)
        let later = CourierTell.facts(board(thread("working", 1)), board(thread("idle", 1, detail: "two")))[0]
        let r = CourierTell.plan([later], told, [], Self.now + 1)
        #expect(r.say.isEmpty && r.quiet.count == 1)
    }

    @Test func aThreadPostAndTheCoordinatorRepeatAreOneFact() {
        let claim: JSON = ["project": "p", "key": "cmsg_9", "text": "all done", "thread": .null]
        // the coordinator spoke first: the finish is quiet
        let told = JSONObject([("p|claim|cmsg_0", ["key": "p|claim|cmsg_0", "at": .double(Self.now), "project": "p", "kind": "claim", "detail": ""])])
        let f = CourierTell.facts(board(thread("working", 1)), board(thread("idle", 1)))[0]
        #expect(CourierTell.plan([f], told, [], Self.now + 5).quiet.count == 1)
        // the finish first: the claim is quiet; a decision is told anyway; a long gap tells both
        #expect(CourierTell.plan([f], JSONObject(), [claim], Self.now).quiet.map { $0["kind"]! } == ["claim_quiet"])
        var decision = claim
        decision["decision"] = true
        #expect(CourierTell.plan([f], JSONObject(), [decision], Self.now).say.count == 2)
        #expect(CourierTell.plan([f], told, [], Self.now + 500).say.count == 1)
        var baseline = claim
        baseline["baseline"] = true
        #expect(CourierTell.plan([], JSONObject(), [baseline], Self.now).quiet.map { $0["kind"]! } == ["claim"])
    }

    @Test func strandedAndAppClosedFacts() {
        let working = thread("working", 1, [("local", true)])
        let stranded = thread("stranded", 1, detail: "Editing the parser")
        let found = CourierTell.facts(board(working), board(stranded))
        #expect(found.map { $0["text"]! } == ["«Task» lost its process; last: Editing the parser. Reply to continue it in a new thread."])
        #expect(CourierTell.facts(board(thread("idle", 1)), board(thread("stranded", 1))).isEmpty)  // a finished thread losing its process is no news
        #expect(CourierTell.holds(found[0], board(thread("working", 1))) == false && CourierTell.holds(found[0], board(stranded)))
        var before = board(thread("working", 1))
        var after = board(thread("waiting_app", 1), ).self
        after["app"] = false
        after["app_since"] = 7
        before["app"] = true
        #expect(CourierTell.facts(before, after).map { $0["text"]! } == ["Claude app closed; 1 thread waiting"])
        #expect(CourierTell.facts(before, after)[0]["key"] == "app|closed|7")
        #expect(CourierTell.standing(board(stranded, thread("needs_you", 1)).self).count == 1)
    }

    // MARK: Do

    @Test func baselineTailAndAnchor() {
        let rows = (0..<60).map { claude("k\($0)", $0) }
        let board = chatBoard(rows)
        let proof: JSON = ["project": "p", "thread": .null, "words": "hi"]
        let based = CourierDo.baselined(board, proof, known: ["old1", "old2", "k59"])
        let keys = based["baseline"]!.asArray!.map { $0.asString! }
        #expect(keys.count == 52 && keys[0] == "old1" && keys[1] == "old2" && keys.last == "k59")  // the 50 on screen, the known ones first
        #expect(CourierDo.baselined(board, based, known: ["zzz"]) == based)  // already based
        #expect(CourierDo.tail(based)["baseline"]?.asArray?.count == 5)
        let proofB: JSON = ["project": "p", "thread": .null, "words": "hi", "baseline": ["k59"]]
        let more = chatBoard(rows + [claude("k60", 60), you("u1", "hi", 61)])
        let anchored = CourierDo.anchor(more, proofB)
        #expect(anchored["anchors"] == ["k60"])
        #expect(CourierDo.anchor(board, proofB) == proofB)
        #expect(CourierDo.anchored(more, proofB) && !CourierDo.anchored(chatBoard([claude("other", 0)]), proofB))
    }

    @Test func provedNeedsTheSendsOwnWords() {
        let proof: JSON = ["project": "p", "thread": .null, "words": "fix the bug", "baseline": ["k1"]]
        let rows = [claude("k1", 0)]
        #expect(CourierDo.proved(chatBoard(rows), proof) == .init(done: false, cause: nil, key: nil))
        #expect(CourierDo.proved(chatBoard(rows + [you("u1", "Fix the bug", 1)]), proof) == .init(done: true, cause: nil, key: "u1"))
        let other = CourierDo.proved(chatBoard(rows + [you("u1", "something else", 1)]), proof)
        #expect(other.done && other.cause == "a row from you arrived, but its words differ from what was sent" && other.key == nil)
        #expect(CourierDo.proved(chatBoard(rows + [you("u1", "fix the bug", 1)]), proof, ["u1"]).done == false)  // one row proves one send
    }

    @Test func provedAllGivesEachRowToTheSendWhoseWordsItIs() {
        let rows = [claude("k1", 0), you("u1", "yes", 1), you("u2", "go on", 2)]
        let p: (String) -> JSON = { ["project": "p", "thread": .null, "words": .string($0), "baseline": ["k1"]] }
        let r = CourierDo.provedAll(chatBoard(rows), [(.int(1), p("go on")), (.int(2), p("yes")), (.int(3), p("never sent"))])
        #expect(r[.int(1)]?.key == "u2" && r[.int(2)]?.key == "u1")
        #expect(r[.int(3)]?.done == false)  // the rows are other sends' (their words equal), so none says anything of this one
    }

    @Test func blockedSaysWhyAndNullIsNotAReason() {
        CourierDo.chromeRunning = { false }
        #expect(CourierDo.blocked(["connected": .null]) == "Chrome isn't running")
        CourierDo.chromeRunning = { true }
        #expect(CourierDo.blocked(["connected": false]) == CourierDo.chromeOpen)
        #expect(CourierDo.blocked(["connected": true, "signed_in": false]) == "signed out of claude.ai")
        #expect(CourierDo.blocked(["connected": true, "signed_in": .null, "away": true]) == "Fjord's tab has left the Claude Code page")
        #expect(CourierDo.blocked(["connected": true, "page_ok": false]) == "the page can't be read")
        #expect(CourierDo.blocked(["connected": true, "signed_in": .null, "page_ok": .null]) == nil)
    }

    @Test func refusalNamesWhatIsMissing() {
        let b: JSON = ["projects": ["chan_a": [:]], "threads": ["cmsg_1": [:]]]
        #expect(CourierDo.refusal(b, ["project": "local:x", "thread": .null]) == "this folder has no Claude project yet")
        #expect(CourierDo.refusal(b, ["project": "chan_a", "thread": "cmsg_9"]) == "that thread isn't on the board")
        #expect(CourierDo.refusal(b, ["project": "chan_z", "thread": .null]) == "no such project on the page")
        #expect(CourierDo.refusal(b, ["project": "chan_a", "thread": "cmsg_1"]) == nil && CourierDo.refusal(b, ["project": "chan_a", "thread": .null]) == nil)
    }

    @Test func strandedThreadsAndHandoff() {
        let b: JSON = ["threads": ["cmsg_1": ["state": "stranded", "local": true], "cmsg_2": ["state": "working", "local": true]], "app": false]
        #expect(CourierDo.stranded(b, ["thread": "cmsg_1"]) != nil && CourierDo.stranded(b, ["thread": "cmsg_2"]) == nil)
        #expect(CourierDo.appWait(b, ["thread": "cmsg_2"]) == CourierDo.appClosed)
        #expect(CourierDo.warning(b, ["thread": "cmsg_2", "args": .null]) == "the Claude app isn't running; the reply waits for it")
        #expect(CourierDo.warning(b, ["thread": .null, "args": ["continues": "cmsg_1"]])?.contains("coordinator") == true)
        let t: JSON = ["id": "cmsg_1", "title": .null, "detail": .string(String(repeating: "x ", count: 400)), "text": .null, "result": .null]
        let (words, args) = CourierDo.handoff(t, "go on")
        let last = words.components(separatedBy: "Last state: ")[1].components(separatedBy: ". Message:")[0]
        #expect(last.count == CourierDo.last && words.hasPrefix("Thread «cmsg_1»") && args == ["continues": "cmsg_1", "message": "go on"])
    }

    @Test func toolArgsCleanAndRefuse() {
        #expect(CourierDo.toolArgs("nope", [:]).cause == "no such tool: nope")
        #expect(CourierDo.toolArgs("add_repo", "x").cause == "the arguments aren't an object")
        #expect(CourierDo.toolArgs("add_repo", ["project": "p", "repo": "a/b", "z": "1", "y": "2"]).cause == "unexpected arguments: y, z")
        #expect(CourierDo.toolArgs("add_repo", ["project": "p", "repo": 3]).cause == "repo must be text")
        #expect(CourierDo.toolArgs("add_repo", ["project": "p"]).cause == "missing: repo")
        #expect(CourierDo.toolArgs("add_repo", ["project": "p", "repo": "  "]).cause == "repo is empty")
        #expect(CourierDo.toolArgs("add_repo", ["project": "p", "repo": "ab"]).cause == "a repository is owner/name")
        #expect(CourierDo.toolArgs("add_repo", ["project": "p", "repo": " a/b "]).args?["repo"] == "a/b")
        #expect(CourierDo.toolArgs("create_project", ["name": "a\nb"]).cause == "the name must be one line of at most 200 characters")
        #expect(CourierDo.toolArgs("create_project", ["name": "n", "goal": .null]).args == ["name": "n"])
        #expect(CourierDo.toolArgs("set_goal", ["project": "p", "text": "a\r\nb\rc"]).args?["text"] == "a\nb\nc")
        #expect(CourierDo.toolArgs("set_goal", ["project": "p", "text": .string(String(repeating: "x", count: 8001))]).cause == "text is over 8000 characters")
        #expect(CourierDo.toolArgs("set_instructions", ["project": "p", "text": .string(String(repeating: "x", count: 8001))]).args != nil)
        let home = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()).replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        #expect(CourierDo.toolArgs("preapprove_folder", ["project": "alpha", "path": .string(home + "/code/")]).args?["path"] == "~/code")
        #expect(CourierDo.toolArgs("preapprove_folder", ["project": "alpha", "path": "/tmp/x"]).args?["path"] == "/tmp/x")
    }

    @Test func toolProofAndWhatTheyShow() {
        let board: JSON = ["projects": ["chan_a": ["id": "chan_a", "name": "alpha", "settings": ["goal": "g", "repos": ["a/b"], "folders": .null]], "local:x": ["id": "local:x", "name": "x"]]]
        #expect(CourierDo.nameTaken(board, "alpha") != nil && CourierDo.nameTaken(board, "x") == nil)
        let proof = CourierDo.toolProof("create_project", ["name": "new"], board)
        #expect(proof == ["name": "new", "known": ["chan_a", "local:x"]])
        var after = board
        after["projects"]?["chan_n"] = ["id": "chan_n", "name": "new"]
        #expect(CourierDo.created(after, proof) == ["chan_n"])
        #expect(CourierDo.toolProved(after, ["tool": "create_project", "proof": proof]).holds)
        let goal = CourierDo.toolProof("set_goal", ["text": "g"], board)
        #expect(goal == ["field": "goal", "equals": "g"] && CourierDo.toolProved(board, ["tool": "set_goal", "project": "chan_a", "proof": goal]).holds)
        let repo = CourierDo.toolProof("add_repo", ["repo": "a/b"], board)
        #expect(CourierDo.toolProved(board, ["tool": "add_repo", "project": "chan_a", "proof": repo]).holds)
        #expect(!CourierDo.toolProved(board, ["tool": "preapprove_folder", "project": "chan_a", "proof": CourierDo.toolProof("preapprove_folder", ["path": "~/x"], board)]).holds)
        #expect(CourierDo.before(["a", 3], ["proof": ["field": "repos"]]) == ["a"] && CourierDo.before(3, ["proof": ["field": "goal"]]) == .null)
        let act = CourierDo.actCommand(["tool": "set_goal", "project": "chan_a", "args": ["text": "g"], "proof": goal])
        #expect(act.kind == "set_field" && act.fields == ["project": "chan_a", "field": "goal", "text": "g"])
    }

    @Test func testOpsExist() {
        #expect(CourierDo.testOps["do.proved_all"] != nil && CourierTell.testOps["tell.plan"] != nil)
        #expect(CourierRunSmoke.ok)
    }
}

private enum CourierRunSmoke {
    static var ok: Bool {
        let run = Run(JSONObject([("id", 4), ("stage", "start")]))
        run["stage"] = "proving"
        return run.id == 4 && run.get("stage") == "proving" && CourierCommand(id: "c1", kind: "wake").json == ["id": "c1", "kind": "wake"]
    }
}
