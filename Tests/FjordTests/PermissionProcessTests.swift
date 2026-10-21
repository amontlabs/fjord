import Foundation
import Testing
@testable import Fjord

/// A Bash prompt is over when the approved command starts under the session's Claude Code process.
@Suite struct PermissionProcessTests {
    private func lister(_ table: [Int: (parent: Int32, info: Claude.ProcessInfo)]) -> Claude.ProcessLister {
        .init(children: { pid in table.filter { $0.value.parent == pid }.map { Int32($0.key) }.sorted() }, info: { table[Int($0)]?.info })
    }

    private func wrapped(_ command: String) -> [String] {
        ["/bin/zsh", "-c", "source /x/snapshot.sh && eval '" + command.replacingOccurrences(of: "'", with: "'\"'\"'") + "' < /dev/null && pwd -P"]
    }

    private func note(_ dir: TempDir, _ command: String, tool: String = "Bash", ms: Int64 = 1000) throws -> Claude.PermissionNote {
        let url = dir.path("n.json")
        try Data("{}".utf8).write(to: url)
        return .init(file: url, tool: tool, input: ["command": command], toolUseID: nil, createdMs: ms)
    }

    @Test func aChildRunningTheCommandAfterTheNoteEndsTheWait() throws {
        let dir = TempDir()
        let n = try note(dir, "cargo test")
        let table = [10: (parent: Int32(1), info: Claude.ProcessInfo(startedMs: 0, arguments: ["claude"])),
                     11: (parent: 10, info: Claude.ProcessInfo(startedMs: 2000, arguments: wrapped("cargo test")))]
        #expect(Claude.clearingStartedCommands([n], pid: 10, processes: lister(table)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: n.file.path))
    }

    @Test func aCommandWithSingleQuotesIsFoundThroughTheShellQuoting() throws {
        let command = "echo 'it'\"s\" && sleep 600"
        let dir = TempDir()
        let n = try note(dir, command)
        let table = [11: (parent: Int32(10), info: Claude.ProcessInfo(startedMs: 2000, arguments: wrapped(command)))]
        #expect(Claude.commandStarted(command, after: n.createdMs, under: 10, processes: lister(table)))
    }

    @Test func aGrandchildOrAMentionOfTheCommandDoesNotCount() throws {
        let table = [11: (parent: Int32(10), info: Claude.ProcessInfo(startedMs: 2000, arguments: ["sh"])),
                     12: (parent: 11, info: Claude.ProcessInfo(startedMs: 2000, arguments: wrapped("make"))),
                     13: (parent: 10, info: Claude.ProcessInfo(startedMs: 2000, arguments: ["/bin/zsh", "-c", "echo 'make'"])),
                     14: (parent: 10, info: Claude.ProcessInfo(startedMs: 2000, arguments: ["echo", "make"])),
                     15: (parent: 10, info: Claude.ProcessInfo(startedMs: 2000, arguments: ["/bin/zsh", "-c", "source /x && echo eval 'make' && eval 'make2'"]))]
        #expect(!Claude.commandStarted("make", after: 1000, under: 10, processes: lister(table)))
    }

    @Test func aBackgroundChildEchoingAPendingCommandDoesNotClearItsPrompt() throws {
        let dir = TempDir()
        let n = try note(dir, "git push")
        let table = [11: (parent: Int32(10), info: Claude.ProcessInfo(startedMs: 2000, arguments: wrapped("echo 'git push'")))]
        #expect(Claude.clearingStartedCommands([n], pid: 10, processes: lister(table)).count == 1)
    }

    @Test func aProcessFromBeforeTheNoteDoesNotCount() throws {
        let dir = TempDir()
        let n = try note(dir, "cargo test")
        let table = [11: (parent: Int32(10), info: Claude.ProcessInfo(startedMs: 500, arguments: wrapped("cargo test")))]
        #expect(Claude.clearingStartedCommands([n], pid: 10, processes: lister(table)).count == 1)
        #expect(FileManager.default.fileExists(atPath: n.file.path))
    }

    @Test func anotherCommandOrAnotherSessionDoesNotCount() throws {
        let dir = TempDir()
        let n = try note(dir, "cargo test")
        let table = [11: (parent: Int32(10), info: Claude.ProcessInfo(startedMs: 2000, arguments: wrapped("cargo build"))),
                     21: (parent: Int32(20), info: Claude.ProcessInfo(startedMs: 2000, arguments: wrapped("cargo test")))]
        #expect(Claude.clearingStartedCommands([n], pid: 10, processes: lister(table)).count == 1)
        #expect(Claude.clearingStartedCommands([n], pid: nil, processes: lister(table)).count == 1)
    }

    @Test func otherToolsAreUnaffected() throws {
        let dir = TempDir()
        let n = try note(dir, "cargo test", tool: "mcp__x__y")
        let table = [11: (parent: Int32(10), info: Claude.ProcessInfo(startedMs: 2000, arguments: wrapped("cargo test")))]
        #expect(Claude.clearingStartedCommands([n], pid: 10, processes: lister(table)).count == 1)
    }

    @Test func theSystemListerSeesAChildAndItsArguments() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "eval 'sleep 31337' < /dev/null && true"]
        try child.run()
        defer { child.terminate() }
        let me = getpid()
        #expect(Claude.ProcessLister.system.children(me).contains(child.processIdentifier))
        let info = try #require(Claude.ProcessLister.system.info(child.processIdentifier))
        #expect(info.arguments.last == "eval 'sleep 31337' < /dev/null && true")
        #expect(Claude.commandStarted("sleep 31337", after: 0, under: me, processes: .system))
    }

    @Test func notesOfSessionsWithoutALiveProcessAreRemoved() throws {
        let dir = TempDir()
        let me = getpid()
        try FileManager.default.createDirectory(at: dir.path("sessions"), withIntermediateDirectories: true)
        try Data(#"{"pid":\#(me),"sessionId":"live-1-a"}"#.utf8).write(to: dir.path("sessions/\(me).json"), options: [])
        let live = dir.path("permissions/live-1-a-5-9.json"), gone = dir.path("permissions/gone-2-b-5-9.json")
        try PrivateFile.write(Data("{}".utf8), to: live)
        try PrivateFile.write(Data("{}".utf8), to: gone)
        let reader = Claude.ActivityReader()
        reader.setPermissions(dir.path("permissions"), registry: dir.path("sessions"))
        reader.pruneNotes()
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func aWatchFollowsTheSessionToItsNewProcessAndEndsWithTheSession() throws {
        let dir = TempDir()
        let sessions = dir.path("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let me = getpid(), parent = getppid()
        try Data(#"{"pid":\#(me),"sessionId":"s-1-a","startedAt":1}"#.utf8).write(to: sessions.appendingPathComponent("\(me).json"))
        let reader = Claude.ActivityReader()
        reader.setPermissions(dir.path("permissions"), registry: sessions)
        let n = try note(dir, "make")
        reader.watchForTesting("s-1-a", [n])
        #expect(reader.watchedPIDs == ["s-1-a": me])
        // Resumed under another process.
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(me).json"))
        try Data(#"{"pid":\#(parent),"sessionId":"s-1-a","startedAt":2}"#.utf8).write(to: sessions.appendingPathComponent("\(parent).json"))
        reader.watchForTesting("s-1-a", [n])
        #expect(reader.watchedPIDs == ["s-1-a": parent])
        // The session ends.
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(parent).json"))
        try Data(#"{"pid":\#(me),"sessionId":"other-1-b"}"#.utf8).write(to: sessions.appendingPathComponent("\(me).json"))
        reader.pruneNotes()
        #expect(reader.watchedPIDs.isEmpty)
    }

    @Test func aSpawnedChildRunningTheCommandWakesTheWatch() async throws {
        let fired = Fired()
        let me = getpid()
        let watch = Claude.CommandWatch(pid: me) {
            if Claude.commandStarted("sleep 31338", after: 0, under: me, processes: .system) { fired.set() }
        }
        defer { watch.cancel() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "eval 'sleep 31338' < /dev/null && true"]
        try child.run()
        defer { child.terminate() }
        for _ in 0..<100 where !fired.value { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(fired.value)
    }
}

private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set() { lock.lock(); on = true; lock.unlock() }
}
