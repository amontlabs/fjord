import Foundation
import Testing
@testable import Fjord

/// The Router as the store runs it: the switch with its hook, and the forms folder.
@MainActor
@Suite struct RouterStore {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// Threads and Router on, the Router's files in `dir`.
    private func store(_ dir: TempDir, _ threads: [String]) -> Store {
        let s = Store.reading(threads.map { T3Fixture.shell($0) })
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.routerExecutable = "/Applications/Fjord.app/Contents/MacOS/Fjord"
        s.interceptOpen = { _ in }
        s.setRouterEnabled(true, now: now)
        return s
    }

    @Test func switchingItOnInstallsTheHookAndOffRemovesIt() async throws {
        let dir = TempDir()
        let s = store(dir, ["local_a"])
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        let installer = FormHookInstaller(claudeDir: paths.claudeDir)
        #expect(s.routerHookStatus == .installed && s.routerHookError == nil)
        #expect(installer.status(executable: "/Applications/Fjord.app/Contents/MacOS/Fjord") == .installed)
        #expect(FileManager.default.fileExists(atPath: paths.forms.appendingPathComponent(".enabled").path))

        s.setRouterEnabled(false)
        await s.routerHookWork?.value
        #expect(s.routerHookStatus == .notInstalled && s.routerHookError == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.forms.appendingPathComponent(".enabled").path))
        #expect(!FileManager.default.fileExists(atPath: installer.script.path))
    }

    @Test func aHookThatCantBeInstalledSaysWhy() async throws {
        let dir = TempDir()
        try FileManager.default.createDirectory(at: dir.path("claude"), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: dir.path("claude/settings.json"))
        let s = store(dir, [])
        await s.routerHookWork?.value
        #expect(s.routerHookError != nil)
        #expect(s.routerHookStatus == .notInstalled)
        #expect(try Data(contentsOf: dir.path("claude/settings.json")) == Data("{ nope".utf8))
    }

    @Test func atLaunchAnOutdatedHookIsInstalledAgain() async throws {
        let dir = TempDir()
        let s = store(dir, [])
        await s.routerHookWork?.value
        let installer = FormHookInstaller(claudeDir: dir.path("claude"))
        // The app moved.
        let moved = Store()
        moved.persists = false
        moved.routerPaths = s.routerPaths
        moved.routerExecutable = "/Users/me/Applications/Fjord.app/Contents/MacOS/Fjord"
        moved.router.enabled = true
        moved.startRouter()
        await moved.routerHookWork?.value
        #expect(installer.status(executable: "/Users/me/Applications/Fjord.app/Contents/MacOS/Fjord") == .installed)
        #expect(moved.routerHookStatus == .installed)

        // Not installed (you took it out yourself): launch leaves it so.
        try installer.uninstall()
        let again = Store()
        again.persists = false
        again.routerPaths = s.routerPaths
        again.routerExecutable = moved.routerExecutable
        again.router.enabled = true
        again.startRouter()
        await again.routerHookWork?.value
        #expect(again.routerHookStatus == .notInstalled)
    }
}
