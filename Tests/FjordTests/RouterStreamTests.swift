import Foundation
import Testing
@testable import Fjord

/// What the Router needs from Claude Code, as far as it can be tested without running it: finding the binary, the gate
/// for deliveries, and what stream-json lines turn into.
@MainActor
@Suite struct RouterStreamTests {
    private func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    // MARK: Finding Claude Code

    @Test func theNewestBundledCopyIsUsed() throws {
        let dir = TempDir()
        func install(_ version: String, _ hash: String, executable: Bool = true) {
            let bin = dir.url.appendingPathComponent("\(version)/\(hash)/claude.app/Contents/MacOS")
            try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let file = bin.appendingPathComponent("claude")
            FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        }
        #expect(RouterStatus.find(in: dir.url) == nil)
        install("2.1.29", "aaa")
        install("2.1.293", "bbb")
        install("2.1.3", "ccc")
        install("2.2.0", "ddd", executable: false)
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("3.0.0"), withIntermediateDirectories: true)
        let found = try #require(RouterStatus.find(in: dir.url))
        #expect(found.version == "2.1.293")
        #expect(found.path == dir.url.appendingPathComponent("2.1.293/bbb/claude.app/Contents/MacOS/claude").path)
    }

    @Test func aSendRunsTheNewestCopyTheAppHasInstalledEvenAfterAnUpdate() throws {
        let dir = TempDir()
        func install(_ version: String) {
            let bin = dir.url.appendingPathComponent("\(version)/hash/claude.app/Contents/MacOS")
            try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: bin.appendingPathComponent("claude").path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        let status = RouterStatus()
        status.codeRoot = dir.url
        // Nothing installed: nothing found (never a `claude` from the PATH).
        #expect(status.latestPath() == nil)
        install("2.1.299")
        #expect(status.latestPath()?.contains("/2.1.299/") == true)
        // The app updates: the next send runs the new copy, with no restart of Fjord.
        install("2.1.304")
        let updated = status.latestPath()
        #expect(updated?.contains("/2.1.304/") == true)
        // The app's folder unreadable: the last one known stays.
        try FileManager.default.removeItem(at: dir.url.appendingPathComponent("2.1.304"))
        try FileManager.default.removeItem(at: dir.url.appendingPathComponent("2.1.299"))
        #expect(status.latestPath() == updated)
    }

    @Test func everySendMessageAsksAndTheAnswerGoesBackOnStdin() throws {
        let settings = try #require(try JSONSerialization.jsonObject(with: RouterAgent.gateSettings()) as? [String: Any])
        #expect((settings["permissions"] as? [String: Any])?["ask"] as? [String] == ["SendMessage"])
        let request = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": "r-1", "request": [
            "subtype": "can_use_tool", "tool_name": "SendMessage",
            "input": ["to": "a", "message": "hi", "notify_when_idle": true]]])
        #expect(RouterStream.parse(request) == [.permission(id: "r-1", tool: "SendMessage", input: ["to": "a", "message": "hi"],
                                                            otherFields: ["notify_when_idle"])])
        let allow = try #require(try JSONSerialization.jsonObject(with: RouterStream.permissionLine(id: "r-1", allow: ["to": "a", "message": "hi"])) as? [String: Any])
        let response = try #require(allow["response"] as? [String: Any])
        #expect(allow["type"] as? String == "control_response" && response["request_id"] as? String == "r-1")
        #expect(response["response"] as? NSDictionary == ["behavior": "allow", "updatedInput": ["to": "a", "message": "hi"]] as NSDictionary)
        let deny = try #require(try JSONSerialization.jsonObject(with: RouterStream.permissionLine(id: "r-2", allow: nil, deny: "No")) as? [String: Any])
        #expect((deny["response"] as? [String: Any])?["response"] as? [String: String] == ["behavior": "deny", "message": "No"])
    }

    // MARK: stream-json

    @Test func stdinLinesAreOneJSONObjectEach() throws {
        let user = RouterStream.userLine("hi \"there\"\nsecond line")
        #expect(user.last == 0x0A && user.dropLast().firstIndex(of: 0x0A) == nil)
        let obj = try #require(try JSONSerialization.jsonObject(with: user) as? [String: Any])
        #expect(obj["type"] as? String == "user")
        #expect((obj["message"] as? [String: Any])?["content"] as? String == "hi \"there\"\nsecond line")
    }

    @Test func outputIsCutIntoLines() {
        var buffer = Data("{\"a\":1}\n\n{\"b\"".utf8)
        #expect(RouterStream.lines(&buffer) == [Data("{\"a\":1}".utf8)])
        #expect(buffer == Data("{\"b\"".utf8))
        buffer.append(Data(":2}\n".utf8))
        #expect(RouterStream.lines(&buffer) == [Data("{\"b\":2}".utf8)] && buffer.isEmpty)
    }

    @Test func eventsAreReadFromTheLinesThatMatter() {
        #expect(RouterStream.parse(line(["type": "system", "subtype": "init", "session_id": "s1", "tools": ["SendMessage"]]))
            == [.started(sessionID: "s1")])
        #expect(RouterStream.parse(line(["type": "system", "subtype": "post_turn_summary", "session_id": "s1"])).isEmpty)
        #expect(RouterStream.parse(line(["type": "rate_limit_event"])).isEmpty)
        #expect(RouterStream.parse(Data("not json".utf8)).isEmpty)
        let assistant = line(["type": "assistant", "message": ["content": [
            ["type": "text", "text": " Sent. \n"],
            ["type": "thinking", "thinking": "hmm"],
            ["type": "tool_use", "id": "t1", "name": "SendMessage", "input": ["to": "lookout", "message": "run the tests", "n": 3]],
            ["type": "tool_use", "id": "t2", "name": "mcp__fjord__mark", "input": ["card": "c1", "addressed": false]],
        ]]])
        #expect(RouterStream.parse(assistant) == [
            .text("Sent."),
            .toolUse(id: "t1", name: "SendMessage", input: ["to": "lookout", "message": "run the tests"]),
            .toolUse(id: "t2", name: "mcp__fjord__mark", input: ["card": "c1", "addressed": "false"]),
        ])
        let results = line(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "Sent", "is_error": false],
            ["type": "tool_result", "tool_use_id": "t2", "content": [["type": "text", "text": "No card c1"]], "is_error": true],
            ["type": "text", "text": "[Request interrupted by user]"],
        ]]])
        #expect(RouterStream.parse(results) == [.toolResult(id: "t1", isError: false, text: "Sent"),
                                                .toolResult(id: "t2", isError: true, text: "No card c1")])
        #expect(RouterStream.parse(line(["type": "result", "subtype": "success", "is_error": false, "result": "Sent."]))
            == [.result(isError: false, text: "Sent.")])
        #expect(RouterStream.parse(line(["type": "result", "subtype": "error_during_execution", "is_error": true,
                                         "errors": ["[ede_diagnostic] result_type=user", "No conversation found"]]))
            == [.result(isError: true, text: "No conversation found")])
    }

    @Test func aSessionWritingBackIsAPeerLine() {
        let text = "<cross-session-message from=\"uds:/tmp/x.sock\" from-name=\"Fix the login bug\">\nTests pass now.\n</cross-session-message>"
        #expect(RouterStream.parse(line(["type": "user", "message": ["role": "user", "content": text]]))
            == [.peer(from: "Fix the login bug", text: "Tests pass now.")])
        #expect(RouterStream.peer("<cross-session-message from=\"abc\">hi</cross-session-message>") == .peer(from: "abc", text: "hi"))
        #expect(RouterStream.peer("plain text") == nil)
    }

    // MARK: Peers

    /// A store with the Router on, its files in `dir`, two sessions and a card each. Peers: `local_a` runs as "Lookout dev"

    @Test func peerNamesResolveOnlyWhenCertain() {
        let peers: [String: ClaudePeers.Peer] = [
            "local_a": .init(name: "Lookout dev", pid: 10),
            "local_b": .init(name: "Twin", pid: 11),
            "local_c": .init(name: "Twin", pid: 12),
            "local_d": .init(name: "Odd [x]", pid: 13),
        ]
        #expect(ClaudePeers.session(named: "Lookout dev", peers: peers) == "local_a")
        #expect(ClaudePeers.session(named: "Lookout dev [10]", peers: peers) == "local_a")
        #expect(ClaudePeers.session(named: "Twin", peers: peers) == nil)
        #expect(ClaudePeers.session(named: "Twin [12]", peers: peers) == "local_c")
        #expect(ClaudePeers.session(named: "Twin [99]", peers: peers) == nil)
        #expect(ClaudePeers.session(named: "Odd [x]", peers: peers) == "local_d")
        #expect(ClaudePeers.session(named: "lookout dev", peers: peers) == nil)
        #expect(ClaudePeers.session(named: "Nobody", peers: peers) == nil)
    }
}