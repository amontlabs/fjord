import Foundation
import Testing
@testable import Fjord

/// The creator's input, built from a thread's projection (SHOWME.md §4): the Python's layout byte for byte, the eval
/// moments' `user.md` as golden files when they're on this Mac.
@Suite struct ExplainerInputTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let day = "2026-11-10T"

    static func at(_ hm: String, _ second: Double = 0) -> String {
        let whole = Int(second), ms = Int(((second - Double(whole)) * 1000).rounded())
        return day + hm + String(format: ":%02d.%03dZ", whole, ms)
    }

    static func message(_ id: String, _ role: String, _ text: String, at: String, createdBy: String? = nil,
                        extra: [String: T3JSON] = [:]) -> T3JSON {
        var o: [String: T3JSON] = ["id": .string(id), "role": .string(role), "text": .string(text),
                                   "createdBy": .string(createdBy ?? (role == "user" ? "user" : "agent")),
                                   "creationSource": "web", "createdAt": .string(at), "updatedAt": .string(at), "streaming": false]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func tool(_ id: String, _ type: String, at: String, _ extra: [String: T3JSON]) -> T3JSON {
        var o: [String: T3JSON] = ["id": .string(id), "type": .string(type), "status": "completed", "ordinal": 1,
                                   "startedAt": .string(at), "updatedAt": .string(at)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func projection(_ messages: [T3JSON], items: [T3JSON] = [], subagents: [T3JSON] = [],
                           title: String = "Fix the login bug") -> T3Projection {
        T3Projection(json: ["thread": T3Fixture.thread("t1", title: title), "messages": .array(messages),
                            "turnItems": .array(items), "subagents": .array(subagents)])
    }

    static func make(_ p: T3Projection, ask: String? = nil) -> ExplainerInput.Input? {
        ExplainerInput.make(p, project: "app", ask: ask, zone: utc, user: "nobody")
    }

    @Test func theLayoutIsThePythons() throws {
        let p = Self.projection([
            Self.message("u1", "user", "Why is it slow?", at: Self.at("10:00")),
            Self.message("a1", "assistant", "The cache misses.", at: Self.at("10:01")),
            Self.message("u2", "user", "  And the fix?\n", at: Self.at("10:02")),
            Self.message("a2", "assistant", "Warm it at launch.", at: Self.at("10:03")),
        ], items: [Self.tool("i1", "command_execution", at: Self.at("10:02", 30), ["input": "ls -la\nmore"])])
        let input = try #require(Self.make(p, ask: "u2"))
        #expect(input.askText == "And the fix?")
        #expect(input.text == """
        <ask>And the fix?</ask>
        <thread name="Fix the login bug" project="app">
          <turn by="you" at="10:00">Why is it slow?</turn>
          <turn by="agent" at="10:01">The cache misses.</turn>
          <turn by="you" at="10:02" ask="true">And the fix?</turn>
          <turn by="agent" at="10:03" focus="true">Warm it at launch.</turn>
          <activity>
            10:02 Bash ls -la
          </activity>
        </thread>

        """)
    }

    @Test func theAgentsMessagesMergeAndT3sOwnArentYours() throws {
        let p = Self.projection([
            Self.message("u1", "user", "Ship it", at: Self.at("10:00")),
            Self.message("a1", "assistant", "Starting.", at: Self.at("10:01")),
            Self.message("n1", "user", "A subagent finished", at: Self.at("10:02"), createdBy: "agent",
                         extra: ["notification": ["source": ["kind": "subagent"], "summary": "done"]]),
            Self.message("d1", "user", "Delegated work done", at: Self.at("10:03"), extra: ["delegatedCompletion": ["taskIds": ["x"]]]),
            Self.message("a2", "assistant", "Shipped.", at: Self.at("10:04")),
        ])
        let input = try #require(Self.make(p, ask: "u1"))
        #expect(input.text.contains("<turn by=\"agent\" at=\"10:01\" focus=\"true\">Starting.\n\nShipped.</turn>"))
        #expect(!input.text.contains("subagent finished") && !input.text.contains("Delegated"))
        // T3's own message isn't an ask.
        #expect(Self.make(p, ask: "n1") == nil)
    }

    @Test func aSteeredMessageEndsTheAnswer() throws {
        let p = Self.projection([
            Self.message("u1", "user", "Explain the queue", at: Self.at("10:00")),
            Self.message("a1", "assistant", "It holds requests.", at: Self.at("10:01")),
            Self.message("u2", "user", "Shorter please", at: Self.at("10:02")),
            Self.message("a2", "assistant", "Requests wait.", at: Self.at("10:03")),
        ])
        let input = try #require(Self.make(p, ask: "u1"))
        #expect(input.text.contains("focus=\"true\">It holds requests.</turn>"))
        #expect(!input.text.contains("Shorter") && !input.text.contains("Requests wait"))
    }

    @Test func aCardExplainsItsLatestReply() throws {
        let p = Self.projection([
            Self.message("u1", "user", "First", at: Self.at("10:00")),
            Self.message("a1", "assistant", "One", at: Self.at("10:01")),
            Self.message("u2", "user", "Second", at: Self.at("10:02")),
            Self.message("a2", "assistant", "Two", at: Self.at("10:03")),
        ])
        let input = try #require(Self.make(p))
        #expect(input.askText == "Second")
        #expect(input.text.contains("ask=\"true\">Second</turn>") && input.text.contains("focus=\"true\">Two</turn>"))
        #expect(Self.make(Self.projection([Self.message("u1", "user", "Hi", at: Self.at("10:00"))])) == nil)
    }

    @Test func activityIsWindowedAndCutPastForty() throws {
        var items: [T3JSON] = [Self.tool("old", "command_execution", at: Self.at("09:50"), ["input": "echo old"])]
        for i in 0..<45 {
            items.append(Self.tool("c\(i)", "command_execution", at: Self.at("10:01", Double(i)), ["input": .string("echo \(i)")]))
        }
        items.append(Self.tool("late", "command_execution", at: Self.at("10:09"), ["input": "echo late"]))
        let p = Self.projection([
            Self.message("u1", "user", "Go", at: Self.at("10:00")),
            Self.message("a1", "assistant", "Done", at: Self.at("10:02")),
        ], items: items)
        let input = try #require(Self.make(p, ask: "u1"))
        let lines = input.text.split(separator: "\n").map(String.init)
        let act = Array(lines[(lines.firstIndex(of: "  <activity>")! + 1)..<lines.firstIndex(of: "  </activity>")!])
        #expect(act.count == 33)
        #expect(act[0] == "    10:01 Bash echo 0" && act[11] == "    10:01 Bash echo 11")
        #expect(act[12] == "    … 13 more …" && act.last == "    10:01 Bash echo 44")
        #expect(!input.text.contains("echo old") && !input.text.contains("echo late"))
    }

    @Test func toolsFilesAndSubagentsReadAsThePythonsLines() throws {
        let p = Self.projection([
            Self.message("u1", "user", "Go", at: Self.at("10:00")),
            Self.message("a1", "assistant", "Done", at: Self.at("10:05")),
        ], items: [
            Self.tool("t1", "dynamic_tool", at: Self.at("10:01"), ["toolName": "ToolSearch", "input": ["query": "select:é", "max_results": 1]]),
            Self.tool("t2", "dynamic_tool", at: Self.at("10:01", 1), ["toolName": "mcp__x__read", "input": [:]]),
            Self.tool("t3", "file_change", at: Self.at("10:02"), ["fileName": "/code/app/Sources/Main.swift"]),
            Self.tool("t4", "web_search", at: Self.at("10:03"), [:]),
            Self.tool("t5", "reasoning", at: Self.at("10:03"), [:]),
        ], subagents: [
            ["title": "Find the cache", "model": "claude-sonnet-5-5", "startedAt": .string(Self.at("10:01", 2)),
             "completedAt": .string(Self.at("10:04"))],
            ["title": "Still at it", "model": "claude-haiku-5-5", "startedAt": .string(Self.at("10:04", 30))],
        ])
        let input = try #require(Self.make(p, ask: "u1"))
        #expect(input.text.contains([
            "  <activity>",
            "    10:01 ToolSearch {\"max_results\": 1, \"query\": \"select:\\u00e9\"}",
            "    10:01 mcp__x__read ",
            "    10:01 subagent \"Find the cache\" · claude-sonnet-5-5 · 10:01 → 10:04",
            "    10:02 Edit Main.swift",
            "    10:03 Web search",
            "    10:04 subagent \"Still at it\" · claude-haiku-5-5 · 10:04 (still running)",
            "  </activity>",
        ].joined(separator: "\n")))
    }

    @Test func secretsHomeFoldersAndTagsAreKeptOut() throws {
        let p = Self.projection([
            Self.message("u1", "user", "Use sk-abcdefghijkl and token=hunter22 from /Users/jane/notes, mail jane@example.com, ask nobody <now>",
                         at: Self.at("10:00")),
            Self.message("a1", "assistant", "Fine", at: Self.at("10:01")),
        ])
        let input = try #require(Self.make(p, ask: "u1"))
        #expect(input.askText == "Use <token> and token=<redacted> from ~/notes, mail <email>, ask user <now>")
        #expect(input.text.hasPrefix("<ask>Use ‹token› and token=‹redacted› from ~/notes, mail ‹email›, ask user ‹now›</ask>"))
    }

    @Test func longTurnsAreCut() throws {
        let long = String(repeating: "a", count: 1_600), longer = String(repeating: "b", count: 7_100)
        let p = Self.projection([
            Self.message("u1", "user", long, at: Self.at("10:00")),
            Self.message("a1", "assistant", longer, at: Self.at("10:01")),
        ])
        let input = try #require(Self.make(p, ask: "u1"))
        #expect(input.text.contains("ask=\"true\">" + String(repeating: "a", count: 1_500) + " …</turn>"))
        #expect(input.text.contains("focus=\"true\">" + String(repeating: "b", count: 7_000) + " …</turn>"))
        // The question itself is whole.
        #expect(input.text.hasPrefix("<ask>" + long + "</ask>"))
    }

    // MARK: Golden files

    /// The eval moments (`EX/cases2/*/user.md`, gitignored): each is read back into a projection of the same thread and
    /// built again. A tool's input brief is the one thing that can't round-trip when the Python cut it (T3's JSON keeps no
    /// key order), so those lines are compared up to the tool's name. Skipped where the files aren't.
    @Test func theEvalMomentsBuildAgain() throws {
        let cases = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/design/router-visuals/explainer/cases2")
        let folders = ((try? FileManager.default.contentsOfDirectory(at: cases, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("user.md").path) }
            .sorted { $0.path < $1.path }
        guard !folders.isEmpty else { return }
        var compared = 0
        for folder in folders {
            let golden = try String(contentsOf: folder.appendingPathComponent("user.md"), encoding: .utf8)
            guard let (p, ask, project, loose) = Self.readBack(golden) else { continue }
            let built = try #require(ExplainerInput.make(p, project: project, ask: ask, zone: Self.utc, user: "nobody"),
                                     "\(folder.lastPathComponent)")
            let want = golden.components(separatedBy: "\n"), got = built.text.components(separatedBy: "\n")
            #expect(want.count == got.count, "\(folder.lastPathComponent)")
            for (i, (w, g)) in zip(want, got).enumerated() {
                if let name = loose[i] { #expect(g.hasPrefix(name), "\(folder.lastPathComponent):\(i + 1)") }
                else { #expect(w == g, "\(folder.lastPathComponent):\(i + 1)") }
            }
            compared += 1
        }
        #expect(compared > 0)
    }

    /// A projection that builds into `golden`, the ask's message id, the project's name, and the lines to compare only up
    /// to a prefix (by line index).
    static func readBack(_ golden: String) -> (T3Projection, String, String, [Int: String])? {
        guard !golden.contains("more …\n"),
              let askEnd = golden.range(of: "</ask>\n<thread name=\"") else { return nil }
        let ask = String(golden[golden.index(golden.startIndex, offsetBy: 5)..<askEnd.lowerBound])
        let header = golden[askEnd.upperBound...].prefix { $0 != "\n" }
        let parts = header.components(separatedBy: "\" project=\"")
        guard parts.count == 2 else { return nil }
        let title = parts[0], project = String(parts[1].dropLast(2))
        let turnPattern = try! NSRegularExpression(pattern: #"  <turn by="(you|agent)" at="(\d\d:\d\d)"( focus="true"| ask="true")?>(.*?)</turn>\n"#,
                                                   options: [.dotMatchesLineSeparators])
        let ns = golden as NSString
        let turns = turnPattern.matches(in: golden, range: NSRange(location: 0, length: ns.length))
        var messages: [T3JSON] = []
        var askID = ""
        for (i, m) in turns.enumerated() {
            let who = ns.substring(with: m.range(at: 1)), hm = ns.substring(with: m.range(at: 2))
            let mark = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
            var text = ns.substring(with: m.range(at: 4))
            let id = "m\(i)"
            if mark == " ask=\"true\"" { askID = id; text = ask }
            // The last reply ends the answer: late in its minute, so the minute's activity falls inside.
            let second = i == turns.count - 1 ? 59.0 : Double(i)
            messages.append(message(id, who == "you" ? "user" : "assistant", text, at: at(hm, second)))
        }
        guard !askID.isEmpty else { return nil }
        let lines = golden.components(separatedBy: "\n")
        guard let open = lines.firstIndex(of: "  <activity>"), let close = lines.firstIndex(of: "  </activity>") else { return nil }
        var items: [T3JSON] = [], subagents: [T3JSON] = [], loose: [Int: String] = [:]
        var perMinute: [String: Double] = [:]
        let sub = try! NSRegularExpression(pattern: #"^subagent "(.*)" · (.*) · \d\d:\d\d (?:→ (\d\d:\d\d)|\(still running\))$"#)
        for index in (open + 1)..<close {
            let line = String(lines[index].dropFirst(4))
            let hm = String(line.prefix(5)), rest = String(line.dropFirst(6))
            let second = perMinute[hm, default: 0]
            perMinute[hm] = second + 0.5
            let when = at(hm, second), id = "i\(index)"
            if rest.hasPrefix("Bash ") {
                // A second line, so a cut line keeps a trailing space the Python's strip would take off a whole input.
                items.append(tool(id, "command_execution", at: when, ["input": .string(String(rest.dropFirst(5)) + "\nmore")]))
            } else if rest.hasPrefix("Edit ") {
                items.append(tool(id, "file_change", at: when, ["fileName": .string(String(rest.dropFirst(5)))]))
            } else if rest == "Web search" {
                items.append(tool(id, "web_search", at: when, [:]))
            } else if let m = sub.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                let r = rest as NSString
                var s: [String: T3JSON] = ["title": .string(r.substring(with: m.range(at: 1))),
                                           "model": .string(r.substring(with: m.range(at: 2))), "startedAt": .string(when)]
                if m.range(at: 3).location != NSNotFound { s["completedAt"] = .string(at(r.substring(with: m.range(at: 3)))) }
                subagents.append(.object(s))
            } else {
                let name = String(rest.prefix { $0 != " " })
                let brief = String(rest.dropFirst(name.count + 1))
                let input = T3JSON.parse(Data(brief.utf8)) ?? .null
                if ExplainerInput.pythonJSON(input) != brief { loose[index] = "    \(hm) \(name) " }
                items.append(tool(id, "dynamic_tool", at: when, ["toolName": .string(name), "input": input]))
            }
        }
        // The answer ended with T3's own message after the activity (a notification): the Python's end is the last message.
        if let last = lines[(open + 1)..<close].last.map({ String($0.dropFirst(4).prefix(5)) }) {
            messages.append(message("end", "user", "A task finished", at: at(last, 59.5), createdBy: "agent",
                                    extra: ["notification": ["source": ["kind": "subagent"], "summary": "done"]]))
        }
        return (projection(messages, items: items, subagents: subagents, title: title), askID, project, loose)
    }
}
