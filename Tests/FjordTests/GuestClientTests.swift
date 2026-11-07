import Foundation
import Testing
@testable import Fjord

@Suite struct GuestClientTests {
    private let computer = GuestReference(deviceId: "owner-1", computerId: "computer-1")

    @Test func readsRangesWithMetadataAndListReturnsOnlyDirectChildren() async throws {
        let guest = MockGuestClient()
        try await guest.seed(computer: computer, path: "/home/guest/forms/a.json", data: Data("abcdef".utf8))
        try await guest.seed(computer: computer, path: "/home/guest/forms/nested/b.json", data: Data("b".utf8))
        let read = try await guest.filesRead(computer: computer, path: "/home/guest/forms/a.json", offset: 2, length: 3)
        let entries = try await guest.filesList(computer: computer, path: "/home/guest/forms")

        #expect(read.data == Data("cde".utf8))
        #expect(read.size == 6)
        #expect(read.mode == 0o600)
        #expect(entries.map(\.name) == ["a.json", "nested"])
        #expect(entries.last?.type == .directory)
    }

    @Test func guestRootsAreNotHostFilesAndPathsMustBeAbsolute() async throws {
        let guest = MockGuestClient()
        let path = "/home/guest/.local/share/fjord/test.txt"
        try await guest.seed(computer: computer, path: path, data: Data("guest".utf8))

        #expect(FileManager.default.fileExists(atPath: path) == false)
        #expect(throws: GuestFolderPath.Failure.absolutePathRequired) {
            try GuestFolderPath.validate("relative")
        }
    }

    @Test func codeFolderScannerReadsWorktreeConfigWithoutNormalizingAgainstHost() async throws {
        let guest = MockGuestClient()
        try await guest.seed(computer: computer, path: "/workspace/repo/.git/config",
                             data: Data("[remote \"origin\"]\nurl = git@github.com:acme/widget.git\n".utf8))
        let scan = try await GuestCodeFolders(client: guest).scan(computer: computer, roots: ["/workspace"])

        #expect(scan.repos["/workspace/repo"] == ["acme/widget"])
        #expect(scan.cutShort == false)
        #expect(GuestCodeFolders.resolveGuest("../common", from: "/home/guest/repo/.git/worktrees/wt") == "/home/guest/repo/.git/worktrees/common")
        #expect(FileManager.default.fileExists(atPath: "/workspace/repo/.git/config") == false)
    }
}
