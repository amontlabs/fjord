import Foundation
import Testing
@testable import Fjord

/// The app's view of the local Claude sessions as the engine's `local` input, and a thread pill's title.
@MainActor
@Suite(.serialized) struct RouterCourierLocalTests {
    private func folder() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func theSessionFilesAndTheRegistryBecomeTheEnginesInput() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let places = CourierLocal.Places(sessions: dir.appendingPathComponent("s"), registry: dir.appendingPathComponent("r"),
                                         transcripts: dir.appendingPathComponent("t"), home: "/Users/nobody")
        let user = places.sessions.appendingPathComponent("u/o")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: places.registry, withIntermediateDirectories: true)
        let project = URL(fileURLWithPath: "/code/lookout")  // not a temp folder, which is scratch
        let now = 1_800_000_000.0
        func write(_ name: String, _ object: [String: Any], to: URL) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: to.appendingPathComponent(name))
        }
        try write("local_a.json", ["cliSessionId": "cli-a", "title": "Fix it", "cwd": project.path, "lastActivityAt": (now - 60) * 1000,
                                   "bridgeSessionIds": ["session_abc"],
                                   "postTurnSummary": ["status_category": "blocked", "status_detail": "waits", "needs_action": "approve"]], to: user)
        try write("local_b.json", ["cliSessionId": "cli-b", "cwd": "/tmp/x", "lastActivityAt": (now - 60) * 1000], to: user)  // scratch
        try write("local_c.json", ["cliSessionId": "cli-c", "cwd": project.path, "lastActivityAt": (now - 60) * 1000, "isArchived": true], to: user)
        try write("1.json", ["pid": 4242, "sessionId": "cli-a", "status": "busy"], to: places.registry)

        let json = CourierLocal.read(places, appRunning: false, now: now, alive: { $0 == 4242 })
        #expect(json["app"] == false)
        #expect(json["processes"]?["cli-a"] == true && json["statuses"]?["cli-a"] == "busy")
        let sessions = try #require(json["sessions"]?.asObject)
        #expect(sessions.count == 1)
        let a = try #require(sessions["cse_abc"])
        #expect(a["cli"] == "cli-a" && a["title"] == "Fix it" && a["needs"] == "approve" && a["category"] == "blocked" && a["child"] == false)
        #expect(a["purpose"] == "")
        try "# Lookout\n\nA [Mac](x) app.\n- no\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(CourierLocal.purpose(dir.path) == "A Mac app.")
        // The engine reads it as a local thread, in a project of its folder.
        let rows = CourierLook.localRows(["threads": [:], "projects": [:]], json, [], now)
        #expect(rows.contains { $0["kind"] == "thread" && $0["subject"] == "local:cli-a" })
        #expect(rows.last?["kind"] == "app" && rows.last?["fields"]?["running"] == false)
    }

    @Test func aLocalThreadWaitsForTheClaudeAppAndGoesWhenItIsBack() throws {
        let path = NSTemporaryDirectory() + "local-core-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var sent: [JSON] = []
        let core = try CourierCore(db: try CourierStore(path: path), out: { sent.append($0) }, clock: CourierClock(now: { 1_800_000_000 }, uptime: { 5_000 }))
        try core.connection(true)
        try core.handle(["type": "page", "signed_in": true, "page_ok": true])
        try core.handle(["type": "projects", "complete": true, "projects": [["id": "chan_a", "name": "alpha"]]])
        func local(app: Bool) -> JSON {
            let session: JSON = ["cli": "cli-a", "folder": "/code/alpha", "title": "Fix it", "active": .double(1_800_000_000 - 60), "category": "review_ready"]
            return ["sessions": ["cse_1": session], "processes": ["cli-a": true], "statuses": [:], "app": .bool(app)]
        }
        try core.local(local(app: false))
        var finished: JSON?
        try core.say("go on", thread: "local:cli-a", finished: { finished = $0 })
        let intent = try #require(core.sql.intents().first)
        #expect(intent.str("status") == "paused" && intent.str("cause") == CourierDo.appClosed)
        #expect(finished?["status"] == "paused")
        try core.local(local(app: true))
        try core.recheckPauses()
        #expect(try core.sql.intents().first?.str("status") != "paused")
    }

    @Test func aThreadPillShowsTheThreadsTitleAndTheIdWhenUnknown() async {
        let pills = RouterCourierPills()
        pills.settleAfter = nil
        final class Count { var n = 0 }
        let count = Count()
        pills.attach(RouterCourierSource(submit: { _ in count.n += 1; return count.n }, updates: AsyncStream { _ in }))
        let target = RouterCourier.Target.thread(project: "lookout", thread: "cmsg_9")
        pills.threadTitle = { $0 == target ? "Fix the login redirect" : nil }
        await pills.send("yes", to: target)
        #expect(pills.items.max { $0.id < $1.id }.map(RouterCourierPills.face)?.status == "Sending to lookout · Fix the login redirect")
        pills.threadTitle = { _ in nil }
        await pills.send("yes", to: target)
        #expect(pills.items.max { $0.id < $1.id }.map(RouterCourierPills.face)?.status == "Sending to lookout · cmsg_9")
    }
}
