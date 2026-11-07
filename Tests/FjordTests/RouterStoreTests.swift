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
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.interceptOpen = { _ in }
        s.setRouterEnabled(true, now: now)
        return s
    }

    @Test func switchingItOnWritesNothingForFormsIntoClaudesFolder() async throws {
        let dir = TempDir()
        let s = store(dir, ["local_a"])
        await s.routerInstallWork?.value
        let paths = try #require(s.routerPaths)
        let claude = (try? FileManager.default.contentsOfDirectory(atPath: paths.claudeDir.path)) ?? []
        #expect(!claude.contains("settings.json") && !claude.contains("hooks"))
        #expect(!FileManager.default.fileExists(atPath: paths.support.appendingPathComponent("forms").path))
        s.setRouterEnabled(false)
        await s.routerInstallWork?.value
        #expect(!FileManager.default.fileExists(atPath: paths.claudeDir.appendingPathComponent("hooks").path))
    }
}
