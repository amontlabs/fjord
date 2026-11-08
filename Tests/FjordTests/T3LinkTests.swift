import Foundation
import Observation
import Testing
@testable import Fjord

/// Answers the T3 server's two HTTP checks from a table.
final class T3HTTPStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String)?)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (status, body) = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("T3 link", .serialized, .timeLimit(.minutes(1)))
struct T3LinkTests {
    // MARK: Discovery

    private func check(protocol version: Int = 2, authenticated: Bool = true, reachable: Bool = true) async throws -> T3Endpoint {
        T3HTTPStub.handler = { req in
            guard reachable else { return nil }
            switch req.url?.path {
            case "/.well-known/t3/environment": return (200, #"{"environmentId":"env1","orchestrationProtocolVersion":\#(version)}"#)
            case "/api/auth/session":
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
                return (200, #"{"authenticated":\#(authenticated)}"#)
            default: return (404, "")
            }
        }
        defer { T3HTTPStub.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [T3HTTPStub.self]
        let session = URLSession(configuration: config)
        return try await T3Discovery.endpoint(origin: URL(string: "http://127.0.0.1:3773")!, token: "tok", session: session, timeout: 30)
    }

    @Test func aCompatibleServerAndAGoodTokenGiveTheSocketRequest() async throws {
        let e = try await check()
        #expect(e.environmentId == "env1")
        #expect(e.webSocketRequest.url?.absoluteString == "ws://127.0.0.1:3773/ws?orchestrationProtocol=2")
        #expect(e.webSocketRequest.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func anotherProtocolIsIncompatible() async {
        await #expect(throws: T3Error.self) { _ = try await check(protocol: 3) }
        do { _ = try await check(protocol: 3) } catch let e as T3Error { #expect(e.kind == .incompatible) } catch {}
    }

    @Test func aRefusedTokenIsSaidAsSuch() async {
        do { _ = try await check(authenticated: false); Issue.record("accepted") } catch let e as T3Error { #expect(e.kind == .tokenRejected) } catch {}
    }

    @Test func noAnswerMeansNoServer() async {
        do { _ = try await check(reachable: false); Issue.record("reached") } catch let e as T3Error { #expect(e.kind == .noServer) } catch {}
    }

    // MARK: Minting

    private func minter(_ out: T3TokenMinter.Output, record: Recorder? = nil) -> T3TokenMinter {
        T3TokenMinter(executable: URL(fileURLWithPath: "/fake/t3"), run: { exe, args in
            record?.add(exe.path, args)
            return out
        })
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(String, [String])] = []
        func add(_ e: String, _ a: [String]) { lock.withLock { calls.append((e, a)) } }
        var all: [(String, [String])] { lock.withLock { calls } }
    }

    @Test func mintingRunsTheCLIWithBothScopesAndReturnsTheTrimmedToken() async throws {
        let rec = Recorder()
        let token = try await minter(.init(status: 0, stdout: "abc.def\n", stderr: ""), record: rec).mint()
        #expect(token == "abc.def")
        #expect(rec.all.first?.0 == "/fake/t3")
        #expect(rec.all.first?.1 == ["auth", "session", "issue", "--scope", "orchestration:read", "--scope", "orchestration:operate",
                                     "--label", "Fjord", "--ttl", "365d", "--token-only"])
    }

    @Test func aFailedMintSaysWhyWithoutTheOutput() async {
        do {
            _ = try await minter(.init(status: 1, stdout: "secret-looking", stderr: "warn\nno database\n")).mint()
            Issue.record("minted")
        } catch let e as T3TokenMinter.Failure {
            #expect(e.message == "T3's command line failed: no database")
            #expect(!e.message.contains("secret-looking"))
        } catch {}
        do { _ = try await minter(.init(status: 0, stdout: "two words", stderr: "")).mint(); Issue.record("minted") }
        catch let e as T3TokenMinter.Failure { #expect(e.message == "T3 gave no token") } catch {}
    }

    // MARK: Status

    @Test func theStatusFollowsTheConnection() {
        func s(installed: Bool = true, started: Bool = true, minting: Bool = false, mintError: String? = nil,
               halted: T3ConnectionState? = nil, connection: T3ConnectionState = .connected, threads: Int = 5) -> T3LinkStatus {
            .from(installed: installed, started: started, minting: minting, mintError: mintError, halted: halted, connection: connection, threads: threads)
        }
        #expect(s(installed: false) == .notInstalled)
        #expect(s(minting: true) == .linking)
        #expect(s(mintError: "x") == .mintFailed("x"))
        #expect(s(halted: .noToken) == .notLinked)
        #expect(s(halted: .noServer) == .serverNotRunning)
        #expect(s(halted: .incompatible("p3")) == .incompatible("p3"))
        #expect(s(halted: .tokenRejected) == .tokenRejected)
        #expect(s() == .connected(threads: 5))
        #expect(s(connection: .reconnecting(attempt: 2)) == .connecting)
        #expect(s(started: false, connection: .idle) == .notLinked)
        #expect(T3LinkStatus.connected(threads: 1).text == "Linked to T3 Code: 1 thread")
    }

    // MARK: The link

    @MainActor private func waitFor(_ link: T3Link, _ done: @escaping (T3LinkStatus) -> Bool) async {
        while !done(link.status) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                withObservationTracking({ _ = link.status }, onChange: { c.resume() })
            }
        }
    }

    final class Keychain: @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        var minted = 0
        init(_ token: String? = nil) { self.token = token }
        var value: String? { get { lock.withLock { token } } set { lock.withLock { token = newValue } } }
    }

    private func deps(_ kc: Keychain, mint: String = "fresh", client: @escaping @Sendable () -> T3Client) -> T3Link.Dependencies {
        var d = T3Link.Dependencies()
        d.installed = { true }
        d.readToken = { kc.value }
        d.saveToken = { kc.value = $0; return true }
        d.deleteToken = { kc.value = nil }
        d.minter = T3TokenMinter(executable: URL(fileURLWithPath: "/fake/t3"), run: { _, _ in
            kc.minted += 1
            return .init(status: 0, stdout: mint, stderr: "")
        })
        d.makeClient = { _ in client() }
        d.watchRuntime = { _ in nil }
        return d
    }

    private func failing(_ kind: T3Error.Kind) -> T3Client {
        T3Client(resolve: { throw T3Error(kind: kind, message: "x") })
    }

    @Test @MainActor func aRefusedTokenIsMintedAgainOnceThenSaidOnTheStatus() async {
        let kc = Keychain("old")
        let link = T3Link(deps(kc) { failing(.tokenRejected) })
        link.start()
        await waitFor(link) { $0 == .tokenRejected }
        #expect(kc.minted == 1, "one mint for the connection, not a loop")
        #expect(kc.value == "fresh")
        link.stop()
    }

    @Test @MainActor func noTokenStopsAtNotLinkedWithoutMinting() async {
        let kc = Keychain()
        let link = T3Link(deps(kc) { failing(.noToken) })
        link.start()
        await waitFor(link) { $0 == .notLinked }
        #expect(kc.minted == 0)
        link.stop()
    }

    @Test @MainActor func noServerIsSaidAndWaitsForTheRuntimeFile() async {
        let kc = Keychain("t")
        let changed = Box()
        var d = deps(kc) { failing(.noServer) }
        d.watchRuntime = { c in changed.fire = c; return NSObject() }
        let link = T3Link(d)
        link.start()
        await waitFor(link) { $0 == .serverNotRunning }
        #expect(changed.fire != nil)
        link.stop()
    }
    @MainActor final class Box { var fire: (() -> Void)? }

    @Test @MainActor func linkingMintsKeepsTheTokenAndConnects() async {
        let kc = Keychain()
        let used = Recorder()
        let link = T3Link(deps(kc, mint: "tok-1") {
            T3Client(resolve: {
                used.add("resolve", [])
                return T3Endpoint(webSocketRequest: URLRequest(url: URL(string: "ws://127.0.0.1:1/ws")!), environmentId: "env1")
            }, connect: { _ in let s = FakeT3Socket(); s.push(.pong); return s })
        })
        await link.link()
        #expect(kc.value == "tok-1")
        await waitFor(link) { $0 == .connected(threads: 0) }
        link.stop()
    }

    @Test @MainActor func aFailedMintLeavesTheTokenAndSaysWhy() async {
        let kc = Keychain()
        var d = deps(kc) { failing(.noToken) }
        d.minter = T3TokenMinter(executable: URL(fileURLWithPath: "/fake/t3"), run: { _, _ in .init(status: 2, stdout: "", stderr: "boom") })
        let link = T3Link(d)
        await link.link()
        #expect(link.status == .mintFailed("T3's command line failed: boom"))
        #expect(kc.value == nil)
    }

    @Test @MainActor func unlinkingForgetsTheToken() async {
        let kc = Keychain("t")
        let link = T3Link(deps(kc) { failing(.noToken) })
        link.unlink()
        #expect(kc.value == nil)
        #expect(link.status == .notLinked)
    }

    @Test @MainActor func notInstalledSaysSoAndDoesNothing() {
        var d = deps(Keychain()) { failing(.noToken) }
        d.installed = { false }
        let link = T3Link(d)
        link.start()
        #expect(link.status == .notInstalled)
    }
}
