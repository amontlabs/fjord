import Foundation
import Observation

/// What the Router needs from outside Fjord to work: the `claude` command (Claude Code), found on the login shell's PATH as
/// T3 finds its provider CLIs. Its runs are one-shot processes of the dispatcher, so there is nothing else to track;
/// Settings, the composer and the briefs read this.
@Observable @MainActor final class RouterStatus {
    /// The `claude` binary, if found.
    private(set) var claudeCode: String?
    /// How the binary is looked for (blocking: called off the main thread unless it must be); nil in a test unless it gives one.
    @ObservationIgnored var lookup: (@Sendable () -> String?)?

    init() {
        if !UnderTest.isRunning { lookup = { RouterStatus.findDefault() } }
        refresh()
    }

    /// `command -v claude` in the user's login shell, so the PATH is the one a terminal has (Homebrew, npm, `~/.local/bin`).
    nonisolated static func findDefault() -> String? {
        if let known = known.withLock({ $0 }), FileManager.default.isExecutableFile(atPath: known) { return known }
        let found = runShell()
        known.withLock { $0 = found }
        return found
    }

    nonisolated private static let known = NSLockedBox()

    nonisolated private static func runShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // The last line: a profile may print before the command does.
        let path = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Looks again off the main thread.
    func refresh() {
        guard let lookup else { return }
        Task { [weak self] in
            let found = await OffMain.run(qos: .utility) { lookup() }
            self?.set(found)
        }
    }

    /// The binary as it is now: the one known if it is still there (one stat), else looked for again off the main thread
    /// and kept (nil once none is left), for the Router's notice, Send and every run alike.
    func current() async -> String? {
        if let known = claudeCode, FileManager.default.isExecutableFile(atPath: known) { return known }
        guard let lookup else { return claudeCode }
        let found = await OffMain.run(qos: .utility) { lookup() }
        set(found)
        return found
    }

    /// The binary known, if it is still there; else looked for now (a send that finds it missing asks the login shell once).
    func latestPath() -> String? {
        if let known = claudeCode, FileManager.default.isExecutableFile(atPath: known) { return known }
        if let lookup { set(lookup()) }
        return claudeCode
    }

    private func set(_ found: String?) { if found != claudeCode { claudeCode = found } }
}

/// A path kept between threads.
final class NSLockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func withLock<T>(_ body: (inout String?) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
