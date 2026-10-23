import Foundation
import Testing
@testable import Fjord

/// The folder the Router's runs of Claude Code start in is made off the main thread. A message is delivered with no run of Claude
/// Code (`RouterCarry`), so the send paths make no folder of it at all.
@MainActor @Suite struct PrivateFolderTests {
    @Test func theFolderIsMadeForYouAloneWithItsParents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("private-folder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("a/b", isDirectory: true)
        await PrivateFile.makeFolder(folder)
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        // Already there: nothing to do, and no error.
        await PrivateFile.makeFolder(folder)
    }

    @Test func theSendAndPreparePathsDontMakeItOnTheMainThread() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Fjord")
        for file in ["RouterWaiting.swift", "RouterDispatcher.swift", "RouterMCP.swift", "RouterRun.swift", "RouterCarry.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("FileManager.default.createDirectory(at: home"), "\(file) makes the Router's folder on the main thread")
        }
    }
}
