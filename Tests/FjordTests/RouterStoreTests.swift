import Foundation
import Testing
@testable import Fjord

/// The Router as the store runs it: the switch, which leaves Claude Code's folder alone (questions come from T3).
@MainActor
@Suite struct RouterStore {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// Threads and Router on, the Router's files in `dir`.
    private func store(_ dir: TempDir, _ threads: [String]) -> Store {
        let s = Store.reading(threads.map { T3Fixture.shell($0) })
        s.routerPaths = RouterPaths(support: dir.path("support"))
        s.interceptOpen = { _ in }
        s.setRouterEnabled(true, now: now)
        return s
    }

    @Test func switchingItOnAndOffWritesNothingOutsideFjordsOwnFolder() async throws {
        let dir = TempDir()
        let s = store(dir, ["local_a"])
        let paths = try #require(s.routerPaths)
        #expect(!FileManager.default.fileExists(atPath: paths.support.appendingPathComponent("claude-plugin").path))
        #expect(!FileManager.default.fileExists(atPath: paths.support.appendingPathComponent("relay.key").path))
        s.setRouterEnabled(false)
        #expect(!s.router.enabled)
    }

    /// FINAL-REVIEW #18: the reader writes its pauses, starts and cancels into the decision log.
    @Test func theReadersTypingLogGoesToTheDecisionLog() throws {
        let dir = TempDir()
        let s = store(dir, ["local_a"])
        // This store's dispatcher was made before its folder was set: its log is made as the app's is.
        s.routerDispatcher.decisionLog = DeciderLog.live(s.routerPaths)
        let log = try #require(s.routerReader.log)
        #expect(log === s.routerDispatcher.decisionLog)
        #expect(log.url.path.hasPrefix(dir.path("support").path))
    }
}
