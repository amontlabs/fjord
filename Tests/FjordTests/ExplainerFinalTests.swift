import Foundation
import Testing
@testable import Fjord

/// The final is the last ```js block of the explainer thread's last reply (SHOWME.md §2.4).
@MainActor
@Suite struct ExplainerFinalTests {
    static func v(_ n: Int, _ code: String, broken: Bool = false) -> ExplainerVersion {
        ExplainerVersion(run: "x", number: n, code: code, broken: broken, title: "V\(n)")
    }

    @Test func theLastBlockEqualToTheLastPreviewIsThatVersion() {
        let reply = "Draft:\n```js\nold()\n```\nFinal:\n```javascript\nexplainer()\n```\n"
        #expect(ExplainerFinal.codeBlock(in: reply) == "explainer()\n")
        #expect(ExplainerFinal.decide(lastReply: reply, versions: [Self.v(1, "x()"), Self.v(2, "  explainer()  \n")]) == .version(2))
    }

    @Test func aDifferentBlockIsRenderedAsTheNextVersion() {
        #expect(ExplainerFinal.decide(lastReply: "```js\nnew()\n```", versions: [Self.v(1, "old()")]) == .render("new()\n"))
        #expect(ExplainerFinal.decide(lastReply: "```js\nnew()\n```", versions: []) == .render("new()\n"))
    }

    @Test func noBlockFallsBackToTheLastUnbrokenDraftOrFails() {
        let versions = [Self.v(1, "a()"), Self.v(2, "b()"), Self.v(3, "c()", broken: true)]
        #expect(ExplainerFinal.decide(lastReply: "I ran out of time.", versions: versions) == .draft(2))
        #expect(ExplainerFinal.decide(lastReply: nil, versions: versions) == .draft(2))
        #expect(ExplainerFinal.decide(lastReply: "```python\nx\n```", versions: [Self.v(1, "a()", broken: true)]) == .failed)
        #expect(ExplainerFinal.decide(lastReply: nil, versions: []) == .failed)
    }

    // MARK: Through the engine

    /// A launched explainer whose run the test can end.
    func launched(_ rig: Rig) async throws -> String {
        let engine = rig.engine
        engine.start()
        rig.whole = T3Fixture.state([ExplainerQueueTests.row("t1", completed: ExplainerQueueTests.sent - 60)], projects: rig.projects)
        engine.shell(.synchronized)
        engine.requested(reply: "t1")
        await settle()
        return try #require(rig.launches.first?.threadId)
    }

    func end(_ rig: Rig, _ id: String, at seconds: Double = 100, status: String = "completed") async {
        rig.whole = T3Fixture.state([ExplainerQueueTests.row("t1", completed: ExplainerQueueTests.sent - 60),
                                     ExplainerQueueTests.row(id, status: status, completed: ExplainerQueueTests.sent + seconds, project: "px")],
                                    projects: rig.projects + [T3Fixture.project("px", root: rig.project.root.path)])
        rig.engine.shell(.threadUpdated(sequence: 2, location: .active, thread: T3ThreadShell(json: .null)))
        await settle()
    }

    /// A preview saved, as the renderer would: on its disk and told to the engine.
    func save(_ rig: Rig, _ v: ExplainerVersion) {
        rig.renderer.saved[v.run, default: []].append(v)
        rig.engine.versionSaved(v)
    }

    @Test func aPreviewedFinalIsReadyAndUnseenUntilWatched() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let id = try await launched(rig)
        let v1 = ExplainerVersion(run: id, number: 1, code: "explainer()", broken: false, title: "The cache", answer: "It misses.",
                                  captions: ["One"], length: 11.6)
        save(rig, v1)
        #expect(rig.engine.items.first?.stage == .making(draft: 1, fixing: ""))
        rig.replies[id] = "Done.\n```js\nexplainer()\n```"
        await end(rig, id)
        let run = try #require(rig.engine.runs[id])
        #expect(run.final == 1 && !run.draft && run.unseen)
        let item = try #require(rig.engine.items.first)
        #expect(item.stage == .ready && item.title == "The cache" && item.length == 12 && item.unseen)
        #expect(rig.renderer.rendered.isEmpty)
        rig.engine.watched(id)
        #expect(rig.engine.items.first?.unseen == false)
        // The same completion read again changes nothing; a follow-up's later run is read again.
        rig.replies[id] = "```js\nexplainer(2)\n```"
        await end(rig, id)
        #expect(rig.renderer.rendered.isEmpty)
        await end(rig, id, at: 200)
        #expect(rig.renderer.rendered == ["explainer(2)\n"] && rig.engine.runs[id]?.final == 2)
    }

    @Test func aRunThatStoppedKeepsItsLastGoodDraft() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let id = try await launched(rig)
        save(rig, ExplainerVersion(run: id, number: 1, code: "a()", broken: false))
        save(rig, ExplainerVersion(run: id, number: 2, code: "b(", broken: true, note: "Unexpected end"))
        #expect(rig.engine.items.first?.stage == .making(draft: 2, fixing: "Unexpected end"))
        rig.replies[id] = "The usage limit stopped me."
        await end(rig, id, status: "interrupted")
        #expect(rig.engine.runs[id]?.final == 1 && rig.engine.runs[id]?.draft == true)
        #expect(rig.engine.items.first?.stage == .ready && rig.engine.items.first?.draft == true)
    }

    @Test func aRunIsFinalizedOnceAndAStoppedFollowUpIsADraft() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let id = try await launched(rig)
        save(rig, ExplainerVersion(run: id, number: 1, code: "a()", broken: false))
        rig.replies[id] = "```js\na()\n```"
        func row(_ run: String, status: String = "completed", updated: Double) {
            rig.whole = T3Fixture.state([ExplainerQueueTests.row("t1", completed: ExplainerQueueTests.sent - 60),
                                         T3Fixture.thread(id, status: status, project: "px", extra: [
                                             "latestRunId": .string(run),
                                             "updatedAt": .string(T3Timestamp.format(ExplainerQueueTests.sent + updated))])],
                                        projects: rig.projects + [T3Fixture.project("px", root: rig.project.root.path)])
            rig.engine.shell(nil)
        }
        row("r1", status: "interrupted", updated: 10)
        await settle()
        let finalAt = try #require(rig.engine.runs[id]?.finalAt)
        rig.engine.watched(id)
        // A later change to the row (no new run) reads nothing again.
        row("r1", status: "interrupted", updated: 50)
        await settle()
        #expect(rig.engine.runs[id]?.finalAt == finalAt && rig.engine.items.first?.unseen == false)
        // A follow-up stopped before replying: the earlier reply's code isn't its final.
        save(rig, ExplainerVersion(run: id, number: 2, code: "b()", broken: false))
        let p = ExplainerInputTests.projection([
            ExplainerInputTests.message("i", "user", "<ticket>x</ticket>", at: ExplainerInputTests.at("10:00")),
            ExplainerInputTests.message("r", "assistant", "```js\nold()\n```", at: ExplainerInputTests.at("10:01")),
            ExplainerInputTests.message("f", "user", "Slower", at: ExplainerInputTests.at("10:02")),
        ])
        #expect(ExplainerEngine.lastReply(p) == nil)
        rig.replies[id] = nil
        row("r2", status: "interrupted", updated: 90)
        await settle()
        #expect(rig.renderer.rendered.isEmpty && rig.engine.runs[id]?.final == 2 && rig.engine.runs[id]?.draft == true)
    }

    @Test func aRunWithNothingToShowFails() async throws {
        let rig = Rig()
        defer { rig.clean() }
        let id = try await launched(rig)
        rig.renderer.fails = true
        rig.replies[id] = "```js\nbroken(\n```"
        await end(rig, id)
        #expect(rig.engine.items.first?.stage == .failed("The explainer didn't finish"))
    }
}
