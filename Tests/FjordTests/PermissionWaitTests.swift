import Foundation
import Testing
@testable import Fjord

/// An ordinary tool's permission prompt, noted by Fjord's hook, makes the session wait on you until the call's result
/// reaches the transcript.
@Suite struct PermissionWaitTests {
    private func line(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self) + "\n"
    }

    private func use(_ id: String, _ name: String, _ input: [String: Any], at time: String = "2026-10-21T10:00:00.000Z") -> String {
        line(["type": "assistant", "timestamp": time, "message": ["role": "assistant", "stop_reason": "tool_use", "content": [
            ["type": "tool_use", "id": id, "name": name, "input": input],
        ]]])
    }

    private func result(_ id: String, error: Bool = false) -> String {
        line(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": id, "content": error ? "rejected" : "ok", "is_error": error],
        ]]])
    }

    private func note(_ dir: TempDir, tool: String, input: [String: Any], id: String? = nil, ms: Int64 = 1) throws -> URL {
        var obj: [String: Any] = ["key": "k", "session_id": "cli-1", "tool_name": tool, "tool_input": input, "created_at": ms]
        if let id { obj["tool_use_id"] = id }
        let url = dir.path("permissions/cli-1-\(ms)-1.json")
        try PrivateFile.write(JSONSerialization.data(withJSONObject: obj), to: url)
        return url
    }

    private func merged(_ transcript: String, _ dir: TempDir) -> ClaudeActivity? {
        let tail = Data(transcript.utf8)
        return Claude.mergingPermission(Claude.activity(tail: tail), calls: Claude.tailCalls(tail: tail),
                                        notes: Claude.PermissionNote.read(in: dir.path("permissions"), session: "cli-1"))
    }

    @Test func anOpenCallWithANoteWaitsOnYou() throws {
        let dir = TempDir()
        _ = try note(dir, tool: "Bash", input: ["command": "git push"])
        let activity = try #require(merged(use("t1", "Bash", ["command": "git push"]), dir))
        #expect(activity.waitsForYou && activity.tool == "Bash" && activity.toolUseID == "t1")
        #expect(activity.text == "Asks your OK to run `git push`")
        #expect(activity.since == Date(timeIntervalSince1970: 1_792_576_800))
    }

    @Test func aCallWithoutANoteIsStillWorking() throws {
        let dir = TempDir()
        let activity = try #require(merged(use("t1", "Bash", ["command": "sleep 600"]), dir))
        #expect(!activity.waitsForYou)
    }

    @Test func theWaitEndsWithTheResultAndTheNoteGoes() throws {
        let dir = TempDir()
        let url = try note(dir, tool: "Edit", input: ["file_path": "/a/b.swift"])
        let open = use("t1", "Edit", ["file_path": "/a/b.swift"])
        #expect(merged(open, dir)?.waitsForYou == true)
        #expect(merged(open + result("t1"), dir)?.waitsForYou == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aDenialEndsTheWaitToo() throws {
        let dir = TempDir()
        let url = try note(dir, tool: "Write", input: ["file_path": "/a/c.txt", "content": "x"], id: "t9")
        let text = use("t9", "Write", ["file_path": "/a/c.txt", "content": "x"]) + result("t9", error: true)
        #expect(merged(text, dir)?.waitsForYou == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aRepeatedIdenticalCallWaitsOnlyForTheLatest() throws {
        let dir = TempDir()
        _ = try note(dir, tool: "Bash", input: ["command": "make"])
        let text = use("t1", "Bash", ["command": "make"]) + result("t1") + use("t2", "Bash", ["command": "make"])
        #expect(merged(text, dir)?.toolUseID == "t2")
    }

    @Test func aCallLargerThanTheTailIsFoundAndItsResultEndsTheWait() throws {
        let dir = TempDir()
        let url = try note(dir, tool: "Write", input: ["file_path": "/a/big.txt", "content": String(repeating: "x", count: 300_000)], id: "t1")
        let transcript = dir.path("t.jsonl")
        let call = use("t1", "Write", ["file_path": "/a/big.txt", "content": String(repeating: "x", count: 300_000)])
        try Data((result("t0") + call).utf8).write(to: transcript)
        let notes = Claude.PermissionNote.read(in: dir.path("permissions"), session: "cli-1")
        let tail = Claude.tail(of: transcript)
        #expect(Claude.tailCalls(tail: tail).all.isEmpty)
        let calls = Claude.locating(notes, in: transcript, calls: Claude.tailCalls(tail: tail))
        #expect(Claude.mergingPermission(Claude.activity(tail: tail), calls: calls, notes: notes)?.waitsForYou == true)
        try Data((result("t0") + call + result("t1")).utf8).write(to: transcript)
        let after = Claude.locating(notes, in: transcript, calls: Claude.tailCalls(tail: Claude.tail(of: transcript)))
        #expect(Claude.mergingPermission(nil, calls: after, notes: notes)?.waitsForYou != true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aQuestionKeepsItsOwnWait() throws {
        let dir = TempDir()
        _ = try note(dir, tool: "Bash", input: ["command": "ls"])
        let q = ["questions": [["question": "Which?", "header": "h", "multiSelect": false, "options": []]]]
        let activity = try #require(merged(use("q1", "AskUserQuestion", q), dir))
        #expect(activity.tool == "AskUserQuestion" && activity.text == "Which?")
    }

    @Test func theTextSaysWhatItAsks() {
        #expect(Claude.permissionText(tool: "Edit", input: ["file_path": "/a/b.swift"]) == "Asks your OK to edit b.swift")
        #expect(Claude.permissionText(tool: "mcp__github__create_issue", input: [:]) == "Asks your OK to use create_issue from github")
        #expect(Claude.permissionText(tool: "Skill", input: [:]) == "Asks your OK to use Skill")
    }

    @Test func aRowWithAPermissionPromptNeedsYou() throws {
        let activity = ClaudeActivity(text: Claude.permissionText(tool: "Bash", input: ["command": "git push"]),
                                      since: Date(timeIntervalSince1970: 1_792_576_800), waitsForYou: true, tool: "Bash", toolUseID: "t1")
        var row = AgentRow(session: ClaudeSession(id: "s", title: "T", lastActivity: Date(), running: true),
                           entry: AgentEntry(id: "s"), label: "T")
        row.activity = activity
        #expect(row.waitsForYou && row.group == .needsYou)
    }

    @Test func readerReadsTheNotesOfItsSessionOnly() throws {
        let dir = TempDir()
        _ = try note(dir, tool: "Bash", input: ["command": "a"])
        #expect(Claude.PermissionNote.read(in: dir.path("permissions"), session: "cli-1").count == 1)
        #expect(Claude.PermissionNote.read(in: dir.path("permissions"), session: "cli-2").isEmpty)
    }
}
