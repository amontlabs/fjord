import AppKit
import Foundation
import Testing
@testable import Fjord

/// The engine as the preview server sees it: one ticket it knows, and every version it's told of.
@MainActor
final class StubRenderHost: ExplainerRenderHost {
    var tickets: [String: ExplainerTicket] = [:]
    var saved: [ExplainerVersion] = []
    func ticket(_ ticket: String) -> ExplainerTicket? { tickets[ticket] }
    func versionSaved(_ version: ExplainerVersion) { saved.append(version) }
}

/// Show me's preview server without WebKit: the tool's arguments and tickets, the port and token it keeps across runs, the
/// versions on disk and the answer's wording.
@MainActor
@Suite(.serialized) struct ExplainerMCPTests {
    private func project(_ dir: TempDir) -> ExplainerProject {
        ExplainerProject(root: dir.path("Explainers"))
    }

    private func started(_ dir: TempDir, host: StubRenderHost) async throws -> ExplainerMCP {
        let mcp = ExplainerMCP()
        try await mcp.start(project: project(dir), host: host)
        return mcp
    }

    private func runsAreEmpty(_ dir: TempDir) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: project(dir).runs.path)) ?? []).isEmpty
    }

    @Test func aMissingOrUnknownTicketIsAnErrorThatNamesTheFixAndSavesNothing() async throws {
        let dir = TempDir()
        let host = StubRenderHost()
        host.tickets["run-1"] = ExplainerTicket(run: "run-1", ask: "Why?")
        let mcp = try await started(dir, host: host)
        defer { mcp.stop() }

        let missing = try #require(await mcp.call("preview", ["code": "explainer({})"]))
        #expect(missing.isError && missing.text.contains("Missing `ticket`") && missing.text.contains("<ticket>"))
        let blank = try #require(await mcp.call("preview", ["code": "explainer({})", "ticket": "  "]))
        #expect(blank.isError && blank.text.contains("Missing `ticket`"))
        let unknown = try #require(await mcp.call("preview", ["code": "explainer({})", "ticket": "run-2"]))
        #expect(unknown.isError && unknown.text.contains("Unknown ticket") && unknown.text.contains("Copy the ticket exactly"))
        let noCode = try #require(await mcp.call("preview", ["ticket": "run-1"]))
        #expect(noCode.isError && noCode.text.contains("Missing `code`"))
        let badAt = try #require(await mcp.call("preview", ["code": "explainer({})", "ticket": "run-1", "at": ["x"]]))
        #expect(badAt.isError && badAt.text.contains("`at`"))
        #expect(await mcp.call("board", [:]) == nil)
        #expect(host.saved.isEmpty && runsAreEmpty(dir))
    }

    @Test func theToolAsksForCodeAndTicket() throws {
        let tool = try #require(ExplainerMCP.tools.first)
        #expect(tool["name"] as? String == "preview")
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["code", "ticket"])
        #expect(Set(((schema["properties"] as? [String: Any]) ?? [:]).keys) == ["code", "ticket", "at"])
    }

    @Test func theServerKeepsItsPortAndTokenAcrossRunsAndMovesOnlyWhenThePortIsTaken() async throws {
        let dir = TempDir()
        let host = StubRenderHost()
        let first = try await started(dir, host: host)
        let address = try #require(project(dir).server())
        #expect(mode(project(dir).mcpConfig) == 0o600)
        first.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        // The next app run binds the same port with the same token: a live creator's session keeps reaching it.
        let second = try await started(dir, host: host)
        #expect(project(dir).server() == address)

        // The port is held (here by the second server): a third takes another and rewrites `.mcp.json`, same token.
        let third = try await started(dir, host: host)
        let moved = try #require(project(dir).server())
        #expect(moved.port != address.port && moved.token == address.token)
        second.stop()
        third.stop()
    }

    @Test func versionsAreNumberedSavedAndReadBack() throws {
        let dir = TempDir()
        let store = ExplainerVersions(runs: dir.path("runs"))
        #expect(try store.next("abc") == 1)
        try FileManager.default.createDirectory(at: try store.folder("abc"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: store.code("abc", 1))
        var version = ExplainerVersion(run: "abc", number: 1, code: "one", broken: false, note: "Scene 0: a and b overlap.",
                                       title: "T", answer: "A", captions: ["c0", "c1"], length: 12.5)
        try store.save(version)
        // A render that wrote its code and stopped before its line still holds its number.
        try Data("two".utf8).write(to: store.code("abc", 2))
        #expect(try store.next("abc") == 3)
        version.number = 2; version.code = "two"; version.broken = true
        try store.save(version)
        let back = store.versions(of: "abc")
        #expect(back.map(\.number) == [1, 2] && back.map(\.code) == ["one", "two"] && back.map(\.broken) == [false, true])
        #expect(back[0].note == "Scene 0: a and b overlap." && back[0].captions == ["c0", "c1"] && back[0].length == 12.5)
        #expect(back[0].page == nil && back[0].posterLight == nil)
        for bad in ["", "../x", "a/b", ".", "a b"] {
            #expect(throws: ExplainerVersions.BadRun.self) { try store.folder(bad) }
        }
    }

    @Test func theAnswerIsThePythonServersWording() {
        let jpeg = Data([0xff, 0xd8, 0xff])
        let frame = ExplainerRenderer.Frame(label: "End of scene 0 (3.2 s)", file: URL(fileURLWithPath: "/x"), jpeg: jpeg)
        let ok = ExplainerMCP.answer(version: 2, ExplainerRenderer.Result(
            timing: .init(total: 12, scenes: [[0, 3.2], [4.1, 11.95]]), errors: "", broken: false, spec: nil, frames: [frame]))
        #expect(ok.text == "Version 2. Total 12 s. Scenes start at 0: 0 s, 1: 4.1 s\nNo errors, no layout notes.")
        #expect(ok.images == [.init(label: "End of scene 0 (3.2 s)", mime: "image/jpeg", base64: jpeg.base64EncodedString())])
        #expect(!ok.isError)
        let failed = ExplainerMCP.answer(version: 1, ExplainerRenderer.Result(
            timing: nil, errors: "SyntaxError: Unexpected token", broken: true, spec: nil))
        #expect(failed.text == "Version 1. No timing: build() failed.\nErrors and layout notes to fix:\nSyntaxError: Unexpected token")
        #expect(failed.images.isEmpty)
    }

    @Test func aReplyHoldsEightFramesAtFirstAndNamesTheRestAndTooManyAtIsAnError() async throws {
        let timing = ExplainerRenderer.Timing(total: 40, scenes: (0..<10).map { [Double($0 * 4), Double($0 * 4 + 3)] })
        let plain = ExplainerRenderer.plan(timing, at: [])
        #expect(plain.shoot.count == 8 && plain.shoot.first?.label == "End of scene 0 (3 s)")
        #expect(plain.left.map(\.label) == ["End of scene 8 (35 s)", "End of scene 9 (39 s)"])
        let asked = ExplainerRenderer.plan(timing, at: [1.5, 99])
        #expect(asked.shoot.suffix(2).map(\.label) == ["At 1.5 s", "At 99 s"] && asked.shoot.last?.time == 40)
        #expect(asked.shoot.count == 8 && asked.left.count == 4)
        #expect(ExplainerRenderer.plan(.init(total: 5, scenes: [[0, 5]]), at: []).left.isEmpty)

        let frame = ExplainerRenderer.Frame(label: "End of scene 0 (3 s)", file: URL(fileURLWithPath: "/x"), jpeg: Data(count: 300))
        var result = ExplainerRenderer.Result(timing: timing, errors: "", broken: false, spec: nil,
                                              frames: [frame, frame, frame])
        result.left = plain.left.map(\.label)
        let answer = ExplainerMCP.answer(version: 1, result, images: 900)
        #expect(answer.images.count == 2)
        #expect(answer.text.contains("at most 8 frames, so these were left out: End of scene 8 (35 s), End of scene 9 (39 s)."))
        #expect(answer.text.contains("size cap left out these frames: End of scene 0 (3 s)."))

        let dir = TempDir()
        let host = StubRenderHost()
        host.tickets["run-1"] = ExplainerTicket(run: "run-1", ask: "Why?")
        let mcp = try await started(dir, host: host)
        defer { mcp.stop() }
        let many = try #require(await mcp.call("preview", ["code": "explainer({})", "ticket": "run-1", "at": Array(0...8)]))
        #expect(many.isError && many.text.contains("at most 8 seconds"))
        #expect(host.saved.isEmpty && runsAreEmpty(dir))
    }

    @Test func theDeadlineGivesUpOnWorkThatNeverEndsAndCancelsIt() async throws {
        var cancelled = false
        let hung: Int? = try await ExplainerRenderer.within(0.05) {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { cancelled = true; throw error }
            return 1
        }
        #expect(hung == nil)
        await Task.yield(); try await Task.sleep(nanoseconds: 20_000_000)
        #expect(cancelled)
        #expect(try await ExplainerRenderer.within(5) { 7 } == 7)
        await #expect(throws: CocoaError.self) { _ = try await ExplainerRenderer.within(5) { () -> Int in throw CocoaError(.fileWriteUnknown) } }
    }

    @Test func thePageReadsTheProjectsKitAndCannotBeClosedByTheQuestion() {
        let page = ExplainerRenderer.page(player: #"<link href="KIT/player.css"><script>window.ASK = ASK_JSON;</script>"#,
                                          ask: "Why </script><b>?")
        #expect(page.contains(#"href="../../../kit/player.css""#))
        #expect(!page.contains("</script><b>") && page.contains(#"<\/script>"#))
    }
}

/// The renderer against real WebKit, opt-in (`FJORD_EXPLAINER_LIVE=1 swift test --filter ExplainerRenderLive`): the
/// example explainer rendered offscreen, no window shown.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FJORD_EXPLAINER_LIVE"] == "1"), .timeLimit(.minutes(2)))
struct ExplainerRenderLive {
    private static let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/design/router-visuals/explainer/examples/lastdrop.js")

    private func project(_ dir: TempDir) throws -> ExplainerProject {
        let project = ExplainerProject(root: dir.path("Explainers"))
        try project.sync()
        return project
    }

    @Test func theExampleRendersEveryScenesFrameAndBothPosters() async throws {
        let dir = TempDir()
        let project = try project(dir)
        let host = StubRenderHost()
        host.tickets["t1"] = ExplainerTicket(run: "run-1", ask: "How does lastdrop pick an account?")
        let mcp = ExplainerMCP()
        try await mcp.start(project: project, host: host)
        defer { mcp.stop() }
        let code = try String(contentsOf: Self.example, encoding: .utf8)
        let started = Date()
        let result = try #require(await mcp.call("preview", ["code": code, "ticket": "t1", "at": [1.5]]))
        print("preview: \(String(format: "%.2f", Date().timeIntervalSince(started))) s\n\(result.text)")
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Version 1. Total "))
        let version = try #require(host.saved.first)
        #expect(!version.broken && version.length ?? 0 > 0 && !version.captions.isEmpty && version.title?.isEmpty == false)
        // A frame per scene and one for `at`, each a JPEG 1000 points wide at 1×.
        #expect(result.images.count == version.captions.count + 1)
        #expect(result.images.last?.label == "At 1.5 s")
        for image in result.images {
            let data = try #require(Data(base64Encoded: image.base64))
            let rep = try #require(NSBitmapImageRep(data: data))
            #expect(image.mime == "image/jpeg" && rep.pixelsWide == 1000)
        }
        let light = try #require(version.posterLight), dark = try #require(version.posterDark)
        #expect(FileManager.default.fileExists(atPath: light.path) && FileManager.default.fileExists(atPath: dark.path))
        #expect(try Data(contentsOf: light) != Data(contentsOf: dark))
        #expect(mcp.versions(of: "run-1").map(\.number) == [1])
        // Keep one look for a person: `FJORD_EXPLAINER_KEEP=<dir>` copies the frames there.
        if let keep = ProcessInfo.processInfo.environment["FJORD_EXPLAINER_KEEP"] {
            try? FileManager.default.removeItem(atPath: keep)
            try FileManager.default.copyItem(at: project.runs, to: URL(fileURLWithPath: keep))
        }
    }

    @Test func aPageThatNeverBuildsSaysSoAndDoesNotHang() async throws {
        let dir = TempDir()
        let project = try project(dir)
        let host = StubRenderHost()
        host.tickets["t1"] = ExplainerTicket(run: "run-1", ask: "?")
        let mcp = ExplainerMCP()
        try await mcp.start(project: project, host: host)
        defer { mcp.stop() }
        let cases = [
            ("explainer({ title: \n", "SyntaxError"),                                // doesn't parse: named, with its line
            ("console.log(1)", "explainer.js never called explainer({...})"),       // never calls the kit
            ("nope()", "explainer.js threw an error before explainer() ran"),       // throws before it can
            ("explainer({ title: 'x', answer: 'y' })", "TypeError"),               // the kit can't build it
        ]
        for (n, (code, says)) in cases.enumerated() {
            let result = try #require(await mcp.call("preview", ["code": code, "ticket": "t1"]))
            print(result.text)
            #expect(result.text.hasPrefix("Version \(n + 1). No timing: build() failed.\nErrors and layout notes to fix:\n"))
            #expect(result.text.contains(says))
            #expect(!result.text.contains("file://"))
            #expect(host.saved.last?.broken == true)
        }
        // The final's render, through the engine's path, takes the next number.
        let final = try await mcp.render("explainer({", ticket: ExplainerTicket(run: "run-1", ask: "?"))
        #expect(final.number == 5 && final.broken)
    }
}
