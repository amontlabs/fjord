import Foundation
import Testing
@testable import Fjord

/// The divider is given what the multi-place benchmark measured (evals/router/v2/multi/candidates.py), byte for byte:
/// the instructions, the schema, the prompt and the card and composer lines (Fixtures/router-divider-parity.json, made by
/// evals/router/v2/multi/parity.py), and what it answers is read strictly.
@MainActor
@Suite(.serialized) struct RouterDividing {
    typealias D = RouterDivider

    struct Row: Decodable {
        var key: String
        var target: String
        var description: String
        var session: String?
    }

    struct Tag: Decodable {
        var tag: String
        var target: String
    }

    struct Composer: Decodable {
        var replyTo: String?
        var tags: [Tag]?
        var pills: [String]?
        var pinned: String?
        var notTo: String?
    }

    struct Card: Decodable {
        var id: String
        var session: String
        var kind: String
        var text: String
    }

    struct Case: Decodable {
        var name: String
        var mode: String
        var fixed: [String]
        var message: String
        var places: [Row]
        var board: [Card]
        var composer: Composer
        var cards: [String]
        var context: [String]
        var keys: [String]
        var system: String
        var prompt: String
    }

    private struct Fixture: Decodable {
        var system: [String: String]
        var cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/router-divider-parity.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// The raw JSON of a case's schema, to compare as parsed JSON.
    private func schemas() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/router-divider-parity.json")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: cases.map { ($0["name"] as! String, $0["schema"] as Any) })
    }

    private func places(_ c: Case) -> [D.Place] {
        c.places.map { D.Place(key: $0.key, target: $0.target, description: $0.description, session: $0.session) }
    }

    private func request(_ c: Case) -> D.Request {
        D.Request(message: c.message, places: places(c), cards: c.cards, context: c.context,
                  mode: c.mode == "gates" ? .gates : .tags(fixed: c.fixed))
    }

    // MARK: Parity

    @Test func theInstructionsAreTheMeasuredBytes() throws {
        let f = try fixture()
        #expect(D.system(.gates) == f.system["gates"])
        #expect(D.system(.tags(fixed: [])) == f.system["tags"])
        #expect(D.waitsRule.hasPrefix("\n\nFor each part") && D.routerSystem.hasSuffix("most likely first."))
    }

    @Test func thePromptAndTheKeysAreTheMeasuredOnes() throws {
        for c in try fixture().cases {
            let r = request(c)
            #expect(D.prompt(r) == c.prompt, "\(c.name)")
            #expect(D.keys(r.mode, r.places) == c.keys, "\(c.name)")
            #expect(D.system(r.mode) == c.system, "\(c.name)")
        }
    }

    @Test func theSchemaIsTheMeasuredOneAsJSON() throws {
        let expected = try schemas()
        for c in try fixture().cases {
            let r = request(c)
            let mine = try JSONSerialization.jsonObject(with: Data(D.schema(r).utf8))
            #expect((mine as AnyObject).isEqual(expected[c.name]), "\(c.name)")
        }
    }

    // MARK: The board and the composer in words

    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    /// The fixture's board: the sessions `ci` and `docs`, its cards open (the benchmark's "finished" is a `done` card).
    private func board(_ c: Case) -> Store {
        let s = InboxFixture.store([])
        s.router.enabled = true
        s.claudeSessions = [
            "ci": ClaudeSession(id: "ci", title: "CI watcher", folder: "/code/app", lastActivity: t0, running: true),
            "docs": ClaudeSession(id: "docs", title: "Docs writer", folder: "/code/app", lastActivity: t0, running: false),
        ]
        s.router.cards = c.board.enumerated().map { i, card in
            RouterCard(id: card.id, sessionID: card.session, kind: card.kind == "finished" ? .done : RouterCard.Kind(rawValue: card.kind) ?? .done, title: "T", folder: "/code/app",
                       text: card.text, createdAt: t0.addingTimeInterval(Double(c.board.count - i)))
        }
        return s
    }

    @Test func theCardsAreWordedAsMeasured() throws {
        for c in try fixture().cases {
            #expect(D.cardLines(board(c), places: places(c)) == c.cards, "\(c.name)")
        }
    }

    @Test func theComposerIsWordedAsMeasured() throws {
        for c in try fixture().cases {
            let s = board(c)
            var context = RouterContext(replyTo: c.composer.replyTo, target: c.composer.pinned, notTo: c.composer.notTo)
            var at = 0
            for tag in c.composer.tags ?? [] {
                let name = String(tag.tag.dropFirst())
                context.mentions.append(RouterMention(range: at..<(at + tag.tag.count), pointer: .session(String(tag.target.dropFirst("session:".count))), name: name))
                at += tag.tag.count + 1
            }
            for name in c.composer.pills ?? [] {
                context.mentions.append(RouterMention(range: at..<(at + name.count + 1), pointer: .project("/code/\(name)"), name: name))
                at += name.count + 2
            }
            #expect(D.contextLines(s, context, places: places(c)) == c.context, "\(c.name)")
        }
    }

    // MARK: The places

    @Test func placesAreKeyedAndDescribedAsJevsOptionsAre() throws {
        let s = InboxFixture.store([])
        s.router.enabled = true
        s.claudeSessions = [
            "ci": ClaudeSession(id: "ci", title: "CI \"watcher\"", folder: "/code/app", lastActivity: t0, running: true),
            "docs": ClaudeSession(id: "docs", title: "Docs", folder: "/code/app", lastActivity: t0.addingTimeInterval(-60), running: false),
        ]
        let destinations = RouterTools(store: s).destinations(s, now: t0.addingTimeInterval(120))
        let places = D.places(destinations)
        let keys = places.map(\.key)
        #expect(keys.prefix(2) == ["S1", "S2"] && keys.suffix(2) == ["fjord-change", "fjord-question"])
        #expect(!keys.contains("compound") && !keys.contains("unclear") && Set(keys).count == keys.count)
        #expect(places[0].session == "ci" && places[0].target == "session:ci")
        #expect(places[0].description == #"{"title": "CI \"watcher\"", "kind": "Claude Code session", "project": "app", "now": "working"}"#)
        #expect(places[1].description.hasPrefix(#"{"title": "Docs", "kind": "Claude Code session", "project": "app", "now": "finished"#))
        let new = try #require(places.first { $0.target.hasPrefix("new:") })
        #expect(new.key == "new:app" && new.description == #"{"kind": "new session", "project": "app"}"#)
        let change = try #require(places.first { $0.key == "fjord-change" })
        #expect(change.target == "change_fjord" && change.description.hasPrefix("Fjord itself: ") && change.session == nil)
        #expect(places.last?.target == "question")
    }

    @Test func aSessionWithAnOpenCardIsOnePlaceWhoseTargetIsTheCard() throws {
        let s = InboxFixture.store([])
        s.router.enabled = true
        s.claudeSessions = ["ci": ClaudeSession(id: "ci", title: "CI", folder: "/code/app", lastActivity: t0, running: false)]
        s.router.cards = [RouterCard(id: "ci#t1", sessionID: "ci", kind: .question, title: "Q", folder: "/code/app", text: "Which one?", createdAt: t0)]
        let places = D.places(RouterTools(store: s).destinations(s, now: t0))
        let ci = try #require(places.first)
        #expect(ci.key == "S1" && ci.target == "answer:ci#t1" && ci.session == "ci" && ci.description.contains("Which one?"))
        // A pin on the session or a pill for it names the same place, and the pills fix it by session.
        let fixed = D.Mode.tags(fixed: ["session:ci"])
        #expect(D.keys(fixed, places) == ["S1"])
        #expect(D.cardLines(s, places: places) == [#"card ci#t1 from S1 (question): "Which one?""#])
    }

    @Test func twoNewSessionsInProjectsOfOneNameGetKeysOfTheirOwn() {
        let places = D.places([
            .init(target: "new:/a/app", name: "new session in app", criteria: ["kind": "new session", "project": "app"]),
            .init(target: "new:/b/app", name: "new session in app'", criteria: ["kind": "new session", "project": "app"]),
        ])
        #expect(places.map(\.key) == ["new:app", "new:app'"])
    }

    // MARK: Reading the answer

    private let book: [D.Place] = [
        .init(key: "S1", target: "session:ci", description: "", session: "ci"),
        .init(key: "S2", target: "session:docs", description: "", session: "docs"),
        .init(key: "fjord-change", target: "change_fjord", description: "", session: nil),
        .init(key: "fjord-question", target: "question", description: "", session: nil),
    ]

    private func read(_ json: String, mode: D.Mode = .gates) throws -> D.Answer {
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try D.read(object, D.Request(message: "m", places: book, cards: [], context: [], mode: mode))
    }

    @Test func partsBecomeTargetsWithTheirWordsAndWaits() throws {
        let a = try read("""
        {"parts": [{"place": "S1", "text": "ask which version", "waits_for": "none"},
                   {"place": "S2", "text": "use it", "waits_for": "S1"}], "sure": true, "alternatives": ["fjord-change", "S1", "nope"]}
        """)
        #expect(a.parts == [.init(target: "session:ci", text: "ask which version", waitsFor: nil),
                            .init(target: "session:docs", text: "use it", waitsFor: "session:ci")])
        #expect(a.sure && a.alternatives == ["change_fjord", "session:ci"])
    }

    @Test func aPartForAnUnknownPlaceOrWithNoWordsIsDropped() throws {
        let a = try read("""
        {"parts": [{"place": "S9", "text": "lost"}, {"place": "S1", "text": "  \\n"}, {"place": "S2", "text": "kept"}], "sure": false, "alternatives": []}
        """)
        #expect(a.parts == [.init(target: "session:docs", text: "kept", waitsFor: nil)] && !a.sure)
    }

    @Test func twoPartsForOnePlaceAreOneInMessageOrder() throws {
        let a = try read("""
        {"parts": [{"place": "S1", "text": "one"}, {"place": "S2", "text": "two"}, {"place": "S1", "text": "three"}], "sure": true, "alternatives": []}
        """)
        #expect(a.parts.map(\.text) == ["one\nthree", "two"] && a.parts.map(\.target) == ["session:ci", "session:docs"])
    }

    @Test func fjordsTwoPlacesAreOnePlace() throws {
        let a = try read("""
        {"parts": [{"place": "fjord-change", "text": "mute it"}, {"place": "fjord-question", "text": "what is waiting?"}], "sure": true, "alternatives": []}
        """)
        #expect(a.parts == [.init(target: "change_fjord", text: "mute it\nwhat is waiting?", waitsFor: nil)])
    }

    @Test func aWaitOnItsOwnPlaceOrOnAPlaceThatIsNotThereIsDropped() throws {
        let a = try read("""
        {"parts": [{"place": "S1", "text": "a", "waits_for": "S1"}, {"place": "S2", "text": "b", "waits_for": "S7"},
                   {"place": "fjord-change", "text": "c", "waits_for": "fjord-question"}], "sure": true, "alternatives": []}
        """)
        #expect(a.parts.map(\.waitsFor) == [nil, nil, nil])
    }

    @Test func inTheTagsModeOnlyTheFixedPlacesCanBeNamed() throws {
        let a = try read("""
        {"parts": [{"place": "S1", "text": "a"}, {"place": "S2", "text": "b"}], "sure": true, "alternatives": ["S1", "S2"]}
        """, mode: .tags(fixed: ["session:docs", "change_fjord"]))
        #expect(a.parts.map(\.target) == ["session:docs"] && a.alternatives == ["session:docs"])
    }

    @Test func anAnswerWithNoPartLeftThrows() {
        for json in [#"{"parts": [], "sure": true, "alternatives": []}"#,
                     #"{"parts": [{"place": "S5", "text": "x"}, {"place": "S1", "text": ""}], "sure": true, "alternatives": []}"#,
                     #"{"sure": true}"#] {
            #expect(throws: RouterTools.Failure.self) { try read(json) }
        }
    }

    // MARK: The run

    /// A program that records its arguments and input and answers `reply`; returns it, the folder and the record's paths.
    private func program(reply: String) throws -> (binary: String, home: URL, args: URL, input: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("divider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let (args, input, script) = (home.appendingPathComponent("args"), home.appendingPathComponent("input"), home.appendingPathComponent("claude"))
        try """
        #!/bin/sh
        for a in "$@"; do printf '%s\\0' "$a"; done > '\(args.path)'
        cat > '\(input.path)'
        printf '%s' '\(reply)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, home, args, input)
    }

    private func gatesRequest() -> D.Request {
        D.Request(message: "rerun, and docs add the page", places: book, cards: [], context: [], mode: .gates)
    }

    @Test func theRunAsksHaikuOnceWithTheMeasuredInstructionsAndSchema() async throws {
        let p = try program(reply: #"{"is_error": false, "structured_output": {"parts": [{"place": "S1", "text": "rerun", "waits_for": "none"}, {"place": "S2", "text": "add the page", "waits_for": "S1"}], "sure": true, "alternatives": []}}"#)
        defer { try? FileManager.default.removeItem(at: p.home) }
        let r = gatesRequest()
        let tools = RouterTools(store: InboxFixture.store([]))
        let a = try await D.run(r, tools: tools, binary: p.binary, home: p.home)
        #expect(a.parts == [.init(target: "session:ci", text: "rerun", waitsFor: nil), .init(target: "session:docs", text: "add the page", waitsFor: "session:ci")])
        let args = try String(contentsOf: p.args, encoding: .utf8).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(args.starts(with: ["-p", "--model", RouterRun.model, "--tools", ""]) && value(after: "--output-format") == "json")
        #expect(value(after: "--setting-sources") == "" && args.contains("--strict-mcp-config") && args.contains("--no-session-persistence"))
        #expect(value(after: "--system-prompt") == D.system(.gates) && value(after: "--json-schema") == D.schema(r))
        #expect(try String(contentsOf: p.input, encoding: .utf8) == D.prompt(r))
    }

    @Test func aRunWithoutATypedAnswerOrWithAnErrorThrows() async throws {
        for reply in [#"{"is_error": false, "result": "sorry"}"#, #"{"is_error": true, "result": "rate limited"}"#, "not json",
                      #"{"is_error": false, "structured_output": {"parts": [], "sure": true, "alternatives": []}}"#] {
            let p = try program(reply: reply)
            defer { try? FileManager.default.removeItem(at: p.home) }
            let tools = RouterTools(store: InboxFixture.store([]))
            await #expect(throws: RouterTools.Failure.self) { _ = try await D.run(gatesRequest(), tools: tools, binary: p.binary, home: p.home) }
        }
    }

    @Test func stoppingTheTurnEndsTheRun() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("divider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("claude")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let tools = RouterTools(store: InboxFixture.store([]))
        let started = Date()
        let task = Task { try await D.run(gatesRequest(), tools: tools, binary: script.path, home: home) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
