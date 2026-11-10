import Foundation
import Testing
@testable import Fjord

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [PullRequestRef] = []
    private var states: [PullRequestRef: PRState]
    var delay: UInt64 = 0
    init(_ states: [PullRequestRef: PRState]) { self.states = states }
    func set(_ ref: PullRequestRef, _ s: PRState) { lock.withLock { states[ref] = s } }
    func record(_ ref: PullRequestRef) -> PRState? { lock.withLock { log.append(ref); return states[ref] } }
    var count: Int { lock.withLock { log.count } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1000)
    var date: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t.addTimeInterval(s) } }
}

private let a = PullRequestRef(owner: "acme", repo: "app", number: 1)
private let b = PullRequestRef(owner: "acme", repo: "app", number: 2)

@Suite struct PullRequestExtractTests {
    @Test func findsUrlsWithPunctuationAndAnchors() {
        let text = """
        See https://github.com/Acme/App/pull/12. Also (https://github.com/acme/app/pull/13/files), \
        https://github.com/acme/app/pull/14#issuecomment-5 and <https://github.com/acme/app/pull/15>, \
        again https://github.com/acme/app/pull/12 and [x](https://github.com/o/r.js/pull/3?x=1).
        """
        #expect(PullRequestRef.extract(from: text).map(\.number) == [12, 13, 14, 15, 3])
        #expect(PullRequestRef.extract(from: text).first?.owner == "acme")
    }

    @Test func ignoresOtherUrls() {
        let text = "https://github.com/acme/app/issues/4 https://notgithub.com/a/b/pull/1 https://github.com/acme/app/pull/x https://gist.github.com/a/b/pull/2"
        #expect(PullRequestRef.extract(from: text).isEmpty)
    }

    @Test func decodesState() throws {
        func state(_ json: String) throws -> PRState {
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            d.dateDecodingStrategy = .iso8601
            return try d.decode(GHPullState.self, from: Data(json.utf8)).prState
        }
        #expect(try state(#"{"state":"open","merged":false}"#) == .open)
        #expect(try state(#"{"state":"closed","merged":true,"merged_at":"2026-11-09T10:00:00Z"}"#) == .merged)
        #expect(try state(#"{"state":"closed","merged":false,"merged_at":null}"#) == .closed)
        #expect(try state(#"{"state":"weird"}"#) == .unknown)
    }
}

@Suite struct PullRequestStatesTests {
    @Test func finalStatesAreNeverRefetched() async {
        let calls = Calls([a: .merged, b: .open])
        let clock = Clock()
        let store = PullRequestStates(minInterval: 10, now: { clock.date }, fetch: { ref in
            guard let s = calls.record(ref) else { throw GitHubError(message: "x") }
            return s
        })
        await store.refresh([a, b])
        #expect(calls.count == 2)
        clock.advance(60)
        let result = await store.refresh([a, b])
        #expect(calls.count == 3)  // only b
        #expect(result == [a: .merged, b: .open])
    }

    @Test func openIsRecheckedOnlyAfterTheInterval() async {
        let calls = Calls([a: .open])
        let clock = Clock()
        let store = PullRequestStates(minInterval: 30, now: { clock.date }, fetch: { calls.record($0)! })
        await store.refresh([a])
        clock.advance(5)
        await store.refresh([a])
        #expect(calls.count == 1)
        clock.advance(30)
        calls.set(a, .merged)
        let result = await store.refresh([a])
        #expect(calls.count == 2)
        #expect(result[a] == .merged)
    }

    @Test func concurrentAsksShareOneFetch() async {
        let calls = Calls([a: .open])
        let store = PullRequestStates(fetch: { ref in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return calls.record(ref)!
        })
        async let x = store.refresh([a])
        async let y = store.refresh([a, a])
        _ = await (x, y)
        #expect(calls.count == 1)
    }

    @Test func failureKeepsPreviousStateAndReportsChangesOnce() async {
        let calls = Calls([a: .open])
        let clock = Clock()
        let changes = Calls([:])
        let store = PullRequestStates(minInterval: 0, now: { clock.date }, fetch: { ref in
            guard let s = calls.record(ref) else { throw GitHubError(message: "down") }
            return s
        }, onChange: { for (ref, _) in $0 { _ = changes.record(ref) } })
        await store.refresh([a])
        await store.refresh([a])  // same state: no change
        #expect(changes.count == 1)
        calls.set(a, .merged)
        await store.refresh([a])
        #expect(changes.count == 2)
        let unknown = await store.states(for: [b])
        #expect(unknown[b] == .unknown)
    }

    @Test func statesReturnsAtOnceAndReportsLater() async {
        let calls = Calls([a: .open])
        let got = Calls([:])
        let store = PullRequestStates(fetch: { calls.record($0)! }, onChange: { for (r, _) in $0 { _ = got.record(r) } })
        let first = await store.states(for: [a])
        #expect(first[a] == .unknown)
        for _ in 0..<200 where got.count == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(got.count == 1)
        #expect(await store.states(for: [a])[a] == .open)
    }
}
