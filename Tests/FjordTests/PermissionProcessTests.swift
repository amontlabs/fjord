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

    @Test func aGrandchildCounts() throws {
        let table = [11: (parent: Int32(10), info: Claude.ProcessInfo(startedMs: 2000, arguments: ["sh"])),
                     12: (parent: 11, info: Claude.ProcessInfo(startedMs: 2000, arguments: wrapped("make")))]
        #expect(Claude.commandStarted("make", after: 1000, under: 10, processes: lister(table)))
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
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["31337"]
        try child.run()
        defer { child.terminate() }
        let me = getpid()
        #expect(Claude.ProcessLister.system.children(me).contains(child.processIdentifier))
        let info = try #require(Claude.ProcessLister.system.info(child.processIdentifier))
        #expect(info.arguments == ["/bin/sleep", "31337"] || info.arguments == ["sleep", "31337"])
        #expect(Claude.commandStarted("31337", after: 0, under: me, processes: .system))
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
}
