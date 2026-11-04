import Darwin
import Foundation
import Testing
@testable import Fjord

/// Slice 7: `CourierHost` on a temp socket and a temp database, driven by a client that writes the page's events as a native host does.
@Suite(.serialized) struct CourierHostTests {
    final class Box: @unchecked Sendable { var t = 1_800_000_000.0; var up = 5_000.0 }

    /// A sleeper a test releases by hand: each sleep is recorded and waits until `fire`, or until its task is cancelled.
    final class Sleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [(seconds: Double, release: AsyncStream<Void>.Continuation)] = []
        var requests: [Double] { lock.lock(); defer { lock.unlock() }; return waiting.map(\.seconds) }

        func sleep(_ seconds: Double) async throws {
            var release: AsyncStream<Void>.Continuation!
            let stream = AsyncStream<Void> { release = $0 }
            add(seconds, release)
            for await _ in stream { break }
            try Task.checkCancellation()
        }

        private func add(_ seconds: Double, _ release: AsyncStream<Void>.Continuation) { lock.lock(); waiting.append((seconds, release)); lock.unlock() }

        /// Releases the newest sleep that is still waiting.
        func fire() { lock.lock(); let last = waiting.popLast(); lock.unlock(); last?.release.yield(()) }
    }

    /// A line-oriented client of the socket.
    final class Client {
        let fd: Int32
        private var buffer = Data()
        init(_ path: String) throws {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                for (i, b) in Array(path.utf8).enumerated() { raw[i] = b }
            }
            let ok = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } == 0
            }
            if !ok { close(fd); throw CourierHost.Failure(message: "connect: \(String(cString: strerror(errno)))") }
        }
        deinit { close(fd) }

        func send(_ json: JSON) { _ = NativeHost.writeAll(fd, Data((json.encoded() + "\n").utf8)) }
        func hangUp() { shutdown(fd, SHUT_RDWR) }

        /// The next line, or nil after `seconds`.
        func line(_ seconds: Double = 5) -> JSON? {
            let deadline = Date().addingTimeInterval(seconds)
            while true {
                if let end = buffer.firstIndex(of: 0x0A) {
                    let text = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...end)
                    return try? JSON.parse(text)
                }
                let left = deadline.timeIntervalSinceNow
                if left <= 0 { return nil }
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, Int32(left * 1000)) <= 0 { return nil }
                var chunk = [UInt8](repeating: 0, count: 65536)
                let got = read(fd, &chunk, chunk.count)
                if got <= 0 { return nil }
                buffer.append(contentsOf: chunk[0..<got])
            }
        }

        /// The next line whose `kind` (a command) or `event` is `name`; others are skipped.
        func command(_ kind: String, _ seconds: Double = 5) -> JSON? {
            while let l = line(seconds) { if l["kind"] == .string(kind) { return l } }
            return nil
        }

        /// Sends an op and reads its one reply.
        func ask(_ op: JSON) -> JSON? { send(op); return line() }
    }

    final class World {
        let dir: String
        let socket: String
        let box = Box()
        let sleeper = Sleeper()
        var host: CourierHost
        init(dir: String? = nil) throws {
            self.dir = dir ?? NSTemporaryDirectory() + "ch-\(UUID().uuidString.prefix(8))"
            socket = self.dir + "/router.sock"
            host = Self.make(socket, box, sleeper)
        }
        static func make(_ socket: String, _ box: Box, _ sleeper: Sleeper) -> CourierHost {
            CourierHost(socketPath: socket, clock: CourierClock(now: { box.t }, uptime: { box.up }), sleeper: { try await sleeper.sleep($0) }, devWait: 0.2, log: { _ in })
        }
        func restart() async throws {
            await host.stop()
            host = Self.make(socket, box, sleeper)
            try await host.start()
        }
        deinit { try? FileManager.default.removeItem(atPath: dir) }

        func later(_ seconds: Double) { box.t += seconds; box.up += seconds }
        func stamp(_ event: JSON) -> JSON { var e = event; e["path"] = "/code/project/chan_a"; e["thread"] = .null; return e }

        /// A native host linked and a page with project chan_a open, settled on an empty chat.
        func pageUp(_ client: Client, signedIn: Bool = true) {
            client.send(["type": "page", "signed_in": .bool(signedIn), "page_ok": true])
            client.send(["type": "projects", "complete": true, "projects": [["id": "chan_a", "name": "alpha"]]])
            client.send(stamp(["type": "rows", "side": "project", "full": true, "settled": true, "rows": [], "turning": false]))
            client.send(stamp(["type": "composer", "side": "project", "draft": "", "disabled": false]))
        }
    }

    static func eventually(_ what: String = "", _ body: () async -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if await body() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    func started(_ w: World) async throws -> World {
        try await w.host.start()
        return w
    }

    // MARK: Socket

    @Test func aHostLineLinksAndEOFUnlinks() async throws {
        let w = try await started(World())
        defer { Task { await w.host.stop() } }
        let client = try Client(w.socket)
        #expect(await w.host.linkedHosts == 0)
        client.send(["type": "page", "signed_in": true, "page_ok": true])
        #expect(await Self.eventually { await w.host.linkedHosts == 1 })
        let attrs = try FileManager.default.attributesOfItem(atPath: w.socket)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        client.hangUp()
        #expect(await Self.eventually { await w.host.linkedHosts == 0 })
        let debug = try Client(w.socket)  // an op line is not a host
        #expect(debug.ask(["op": "reload_tab"])?["error"] == "no host linked")
        #expect(await w.host.linkedHosts == 0)
    }

    @Test func aSecondListenerIsRefusedAndAStaleSocketIsReplaced() async throws {
        let w = try await started(World())
        let second = World.make(w.socket, w.box, w.sleeper)
        await #expect(throws: CourierHost.Failure.self) { try await second.start() }
        #expect(try Client(w.socket).fd >= 0)  // the first still answers
        await w.host.stop()
        #expect(!FileManager.default.fileExists(atPath: w.socket))
        // a leftover socket file nobody listens on goes
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in for (i, b) in Array(w.socket.utf8).enumerated() { raw[i] = b } }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(stale)
        #expect(FileManager.default.fileExists(atPath: w.socket))
        try await second.start()
        #expect(try Client(w.socket).fd >= 0)
        await second.stop()
    }

    // MARK: Timer

    @Test func theTimerIsArmedToTheNextDeadlineAndTicksWhenItFires() async throws {
        let w = try await started(World())
        defer { Task { await w.host.stop() } }
        let client = try Client(w.socket)
        w.pageUp(client)
        #expect(await Self.eventually { await w.host.board()["projects"]?["chan_a"] != nil })
        client.send(["type": "wake_me", "after": 1500])
        #expect(await Self.eventually { !w.sleeper.requests.isEmpty })
        let delay = try #require(w.sleeper.requests.last)
        #expect(abs(delay - 1.5) < 0.06)
        w.later(1.6)
        w.sleeper.fire()
        let wake = try #require(client.command("wake"))  // the tick answered the page's wake_me
        #expect(wake["id"] == nil)
    }

    // MARK: A send, and its updates

    @Test func aSendGoesThroughTheSocketAndItsUpdatesReportSendingThenDelivered() async throws {
        let w = try await started(World())
        defer { Task { await w.host.stop() } }
        let client = try Client(w.socket)
        w.pageUp(client)
        #expect(await Self.eventually { await w.host.board()["projects"]?["chan_a"] != nil })
        var seen: [CourierState] = []
        let reader = Task { var out: [CourierState] = []; for await u in w.host.updates { out.append(u.state); if u.state == .delivered { break } }; return out }
        let id = await w.host.submit(.send(words: "hello there", project: "alpha", thread: nil))
        #expect(id == 1)
        let send = try #require(client.command("send"))
        #expect(send["text"] == "hello there" && send["project"] == "chan_a")
        client.send(["type": "done", "id": send["id"]!, "ok": true])
        client.send(w.stamp(["type": "composer", "side": "project", "draft": "", "disabled": false]))
        client.send(w.stamp(["type": "rows", "side": "project", "turning": false, "rows": [["key": "cmsg_1", "index": 0, "from": "you", "text": "hello there"]]]))
        seen = await reader.value
        #expect(seen.first == .sending && seen.last == .delivered)
        let row = try CourierStore(path: w.dir + "/router.db").intent(1)
        #expect(row?["status"] == "confirmed")
        // the same words inside the duplicate window are the same intent
        #expect(await w.host.submit(.send(words: "hello there", project: "alpha", thread: nil)) == 2)
    }

    @Test func aSendToAnUnknownProjectIsRefusedAndReported() async throws {
        let w = try await started(World())
        defer { Task { await w.host.stop() } }
        let reader = Task { () -> CourierUpdate? in for await u in w.host.updates { return u }; return nil }
        let id = await w.host.submit(.send(words: "hi", project: "nope", thread: nil))
        let update = await reader.value
        #expect(update?.intentID == id && update?.state == .refused && update?.cause == "no project named nope")
    }

    @Test func aPausedSendsUpdateCarriesWhyAsACodeAgainAfterARestart() async throws {
        let w = try await started(World())
        let client = try Client(w.socket)
        w.pageUp(client, signedIn: false)
        #expect(await Self.eventually { await w.host.board()["projects"]?["chan_a"] != nil })
        let reader = Task { () -> CourierUpdate? in for await u in w.host.updates where u.state == .paused { return u }; return nil }
        let id = await w.host.submit(.send(words: "later", project: "alpha", thread: nil))
        let paused = await reader.value
        #expect(paused?.intentID == id && paused?.pause == .signedOut && paused?.cause == CourierDo.sentence(.signedOut))
        try await w.restart()
        let again = Task { () -> CourierUpdate? in for await u in w.host.updates where u.intentID == id { return u }; return nil }
        // the restart's own pause ("routerd restarted") has no code; the page back, still signed out, gives it again
        let back = try Client(w.socket)
        back.send(["type": "page", "signed_in": false, "page_ok": true])
        let update = await again.value
        #expect(update?.state == .paused && update?.pause == .signedOut)
        await w.host.stop()
    }

    // MARK: Restart

    @Test func aRestartReplaysThePendingIntentsOfAnExistingDatabase() async throws {
        let w = try await started(World())
        let client = try Client(w.socket)
        w.pageUp(client, signedIn: false)
        #expect(await Self.eventually { await w.host.board()["projects"]?["chan_a"] != nil })
        let id = await w.host.submit(.send(words: "later", project: "alpha", thread: nil))
        #expect(try CourierStore(path: w.dir + "/router.db").intent(id)?["status"] == "paused")
        try await w.restart()
        let row = try CourierStore(path: w.dir + "/router.db").intent(id)
        #expect(row?["status"] == "paused" && row?["cause"] == "routerd restarted")
        let again = try Client(w.socket)  // the run is back: the page returns and the send goes out
        w.pageUp(again)
        let send = try #require(again.command("send"))
        #expect(send["text"] == "later")
        await w.host.stop()
    }

    /// Round 3 A/C: after a relaunch the engine's own record says where a proposal's delivery is, and it isn't sent again.
    @MainActor @Test func aProposalsDeliveryIsReadFromTheEngineAfterARelaunchAndNotResent() async throws {
        let w = try await started(World())
        let client = try Client(w.socket)
        w.pageUp(client, signedIn: false)
        #expect(await Self.eventually { await w.host.board()["projects"]?["chan_a"] != nil })
        let id = await w.host.submit(.send(words: "ship it", project: "chan_a", thread: nil))
        #expect(id > 0)
        try await w.restart()
        let since = Date(timeIntervalSince1970: w.box.t - 60)
        #expect(await w.host.status(of: id)?.state == .paused)
        #expect(await w.host.intent(matching: "ship it", project: "chan_a", since: since) == .found(id))
        #expect(await w.host.intent(matching: "ship it", project: nil, since: since) == .found(id))
        #expect(await w.host.intent(matching: "something else", project: "chan_a", since: since) == CourierLookup.none)
        let pills = RouterCourierPills()
        pills.attach(.host(w.host))
        let engine = RouterProjectPillsEngine(pills: pills)
        let store = Store()
        store.persists = false
        store.restoreProposals([.init(message: "ship it", fields: .init(name: "alpha"), made: [.create], project: "chan_a",
                                      stopped: "Fjord quit as your message went", sent: id),
                                .init(message: "ship it", fields: .init(name: "alpha"), made: [.create], project: "chan_a",
                                      stopped: "Fjord quit as your message went",
                                      sending: .init(words: "ship it", project: "chan_a", at: since))],
                               reviser: RouterProjectFakeReviser(), engine: engine)
        let p = try #require(store.routerProposal)
        p.settleAfter = nil
        let q = try #require(store.routerProposalQueue.first)
        await store.reconciling?.value
        #expect(p.phase == .created)
        #expect(q.phase == .created && q.sentIntent == id)
        // Nothing new reached the engine.
        #expect(await w.host.status(of: id + 1) == nil)
        await w.host.stop()
    }

    /// Round 3 A: a confirmed create's status carries the project its proof found.
    @Test func aConfirmedCreatesStatusCarriesItsProject() async throws {
        let w = try await started(World())
        let client = try Client(w.socket)
        w.pageUp(client)
        #expect(await Self.eventually { await w.host.board()["projects"]?["chan_a"] != nil })
        let id = await w.host.submit(.tool(name: .createProject, args: ["name": "beta"]))
        #expect(id > 0)
        try CourierStore(path: w.dir + "/router.db").updateIntent(w.box.t, id, [("status", "confirmed"), ("project", "chan_b")])
        let status = await w.host.status(of: id)
        #expect(status?.state == .toolDone && status?.project == "chan_b")
        await w.host.stop()
    }

    // MARK: Debug ops

    @Test func debugOpsAreAnswered() async throws {
        let w = try await started(World())
        defer { Task { await w.host.stop() } }
        let debug = try Client(w.socket)
        #expect(debug.ask(["op": "board"])?["board"] != nil)
        #expect(debug.ask(["op": "nonsense"])?["error"] == "unknown op nonsense")
        #expect(debug.ask(["op": "dev_command", "kind": "remove_folder"]) == ["ok": false, "error": "no host linked"])
        #expect(debug.ask(["op": "reload_extension"])?["error"] == "no host linked")

        let page = try Client(w.socket)
        w.pageUp(page)
        #expect(await Self.eventually { await w.host.linkedHosts == 1 })
        #expect(debug.ask(["op": "reload_tab"]) == ["ok": true])
        #expect(page.command("reload_tab") != nil)

        debug.send(["op": "dev_command", "kind": "remove_folder", "path": "/x"])
        let command = try #require(page.command("remove_folder"))
        #expect(command["path"] == "/x")
        page.send(["type": "done", "id": command["id"]!, "ok": true])
        #expect(debug.line()?["ok"] == true)

        // the page never answers: the wait ends with an error and the command is cancelled
        debug.send(["op": "dev_command", "kind": "remove_folder"])
        let silent = try #require(page.command("remove_folder"))
        let timeout = try #require(debug.line())
        #expect(timeout["ok"] == false && (timeout["error"]?.asString ?? "").hasPrefix("the page didn't answer"))
        #expect(page.command("cancel")?["target"] == silent["id"])

        // say streams its decision, then the outcome
        debug.send(["op": "say", "message": "hi", "project": "nope"])
        #expect(debug.line()?["event"] == "decision")
        #expect(debug.line()?["event"] == "outcome")
    }
}
