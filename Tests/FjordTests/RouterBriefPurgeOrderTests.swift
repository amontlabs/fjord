import Foundation
import Testing
@testable import Fjord

/// The purge of briefs from before T3 runs on T3's real stream: the snapshot's parts, then (only when asked for) `synchronized`,
/// whichever of the Router's engine and the shell arrives first.
@MainActor @Suite struct RouterBriefPurgeOrderTests {
    typealias F = T3Fixture
    private let dir = TempDir()

    private func oldRows(_ db: SQLiteBriefStore, _ projects: [String]) {
        for p in projects {
            db.append(BriefVersion(project: p, version: 1, at: 1, prose: BriefDoc.Prose(now: ["Old."]), diff: ""))
            db.setKey(p, "k")
        }
    }

    /// A store with the Router on over a briefs.db that holds old rows; its T3 link is a fake socket.
    private func launch(old: [String]) throws -> (Store, SocketLog, SQLiteBriefStore) {
        let support = dir.path("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appendingPathComponent("briefs.db").path
        oldRows(try SQLiteBriefStore(path: path), old)
        let store = Store()
        store.persists = false
        store.routerPaths = RouterPaths(support: support)
        store.agents.enabled = true
        store.router.enabled = true
        var o = T3Client.Options()
        o.pingInterval = .seconds(60); o.backoff = [.milliseconds(1)]; o.connectTimeout = .seconds(30)
        let log = SocketLog()
        let client = T3Client(options: o,
                              resolve: { T3Endpoint(webSocketRequest: URLRequest(url: URL(string: "ws://127.0.0.1:1/ws")!), environmentId: "env1") },
                              connect: { _ in let s = FakeT3Socket(); await log.made(s); return s })
        store.t3.store.start(client: client)
        return (store, log, try SQLiteBriefStore(path: path))
    }

    /// What T3 v0.1.7 sends: the authoritative snapshot, the same projects again once their repositories are resolved, and
    /// `synchronized` only for a subscription that asked for it (`requestCompletionMarker`).
    private func serve(_ log: SocketLog, snapshot: [T3JSON], projects: [T3JSON], marker: Bool = true) async {
        let sock = await log.next()
        let req = await sock.outbox.request("orchestration.subscribeShell")
        sock.push(.pong)
        var parts = [F.snapshot(threads: snapshot, projects: projects),
                     F.snapshot(threads: [], projects: projects, sequence: 100)]
        if marker && req.payload["requestCompletionMarker"] == .bool(true) { parts.append(["kind": "synchronized"]) }
        for part in parts { sock.push(.chunk(requestId: req.id, values: [part])) }
    }

    @Test func theOldRowsGoOnceT3HasSentItsSnapshotAndTheMarker() async throws {
        let (store, log, db) = try launch(old: ["chan_old", "local:folder", "p1"])
        #expect(store.routerBriefs.engine != nil)
        await serve(log, snapshot: [F.shell("th_1", project: "p1")], projects: [F.project("p1", root: "/code/app")])
        await waitUntil { store.t3.store.shell.threads.count == 1 }
        await waitUntil { db.latest("chan_old") == nil }
        #expect(db.latest("local:folder") == nil && db.latest("p1") != nil)
        #expect(store.routerBriefs.t3Listing()?.projects == ["p1"] && store.routerBriefs.docs["chan_old"] == nil)
    }

    @Test func theOldRowsGoWithoutTheMarkerToo() async throws {
        let (store, log, db) = try launch(old: ["chan_old", "p1"])
        await serve(log, snapshot: [F.shell("th_1", project: "p1")], projects: [F.project("p1", root: "/code/app")], marker: false)
        await waitUntil { store.t3.store.shell.threads.count == 1 }
        await waitUntil { db.latest("chan_old") == nil }
        #expect(db.latest("p1") != nil)
    }

    @Test func aT3WithNothingInItPurgesNothing() async throws {
        let (store, log, db) = try launch(old: ["chan_old"])
        await serve(log, snapshot: [], projects: [])
        await waitUntil { store.t3.store.shell.sequence != nil }
        for _ in 0..<20 { await Task.yield() }
        #expect(store.routerBriefs.t3Listing() == nil && db.latest("chan_old") != nil)
    }
}
