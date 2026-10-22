import Foundation
import Observation

/// What the Router needs from outside Fjord to work: Claude Code's binary (the copy the Claude app installs). Its runs
/// are one-shot processes of the dispatcher, so there is nothing else to track; Settings, the page's notice and the
/// composer read this.
@Observable @MainActor final class RouterStatus {
    /// Claude Code's bundled binary, if found, and its version ("2.1.293").
    private(set) var claudeCode: (path: String, version: String)?
    /// Where the Claude app keeps its copies of Claude Code; nil in a test unless it gives one.
    @ObservationIgnored var codeRoot: URL? = UnderTest.isRunning ? nil : RouterStatus.defaultRoot

    nonisolated static var defaultRoot: URL { Claude.root.appendingPathComponent("claude-code", isDirectory: true) }

    /// The binary's path, looked up now (off the main thread when called there).
    nonisolated static func findDefault() -> String? { find(in: defaultRoot)?.path }

    init() { refresh() }

    /// The highest version under `root` (`<version>/<hash>/claude.app/Contents/MacOS/claude`) that has the binary.
    nonisolated static func find(in root: URL) -> (path: String, version: String)? {
        let fm = FileManager.default
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0.first?.isNumber == true }
            .sorted { compare($0, $1) == .orderedDescending }
        for version in versions {
            let dir = root.appendingPathComponent(version, isDirectory: true)
            for hash in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where !hash.hasPrefix(".") {
                let path = dir.appendingPathComponent(hash).appendingPathComponent("claude.app/Contents/MacOS/claude").path
                if fm.isExecutableFile(atPath: path) { return (path, version) }
            }
        }
        return nil
    }

    /// Numeric, part by part ("2.1.293" > "2.1.29" > "2.1.3").
    nonisolated private static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        let pb = b.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Looks again off the main thread (the app updates its copy now and then).
    func refresh() {
        guard let root = codeRoot else { return }
        Task { [weak self] in
            let found = await OffMain.run(qos: .utility) { Self.find(in: root) }
            self?.set(found)
        }
    }

    /// The binary as it is now: the one known if it is still there (one stat), else looked for again off the main thread
    /// and kept (nil once none is left), for the Router's notice, Send and every run alike.
    func current() async -> (path: String, version: String)? {
        if let known = claudeCode, FileManager.default.isExecutableFile(atPath: known.path) { return known }
        guard let root = codeRoot else { return claudeCode }
        let found = await OffMain.run(qos: .utility) { Self.find(in: root) }
        set(found)
        return found
    }

    /// The newest binary the Claude app has installed, looked up now: a send runs the app's bundled Claude Code, the version its
    /// sessions run, and not a copy found before the app updated. A few directory reads (the newest version is the first stat),
    /// so cheap enough to ask at every send; the known one when the app's folder can't be read (or in a test with none).
    func latestPath() -> String? {
        if let root = codeRoot, let found = Self.find(in: root) { set(found) }
        return claudeCode?.path
    }

    private func set(_ found: (path: String, version: String)?) {
        if found?.path != claudeCode?.path || found?.version != claudeCode?.version { claudeCode = found }
    }
}
