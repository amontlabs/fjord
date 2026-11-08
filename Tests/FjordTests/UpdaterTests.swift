import CryptoKit
import Foundation
import Observation
import Testing
@testable import Fjord

@Suite struct Updates {
    @Test func versionsCompareNumerically() throws {
        #expect(try #require(Version("0.10.0")) > #require(Version("0.9.3")))
        #expect(try #require(Version("v1.2")) == #require(Version("1.2.0")))
        #expect(try #require(Version("1.2.1")) > #require(Version("1.2")))
        #expect(try #require(Version("0.2.0")) < #require(Version("0.2.1")))
        #expect(Version("0.0.0-dev") != nil)
        #expect(Version("latest") == nil)
        #expect(Version("") == nil)
    }

    @MainActor @Test func devBuildsNeverUpdate() {
        // Tests don't run from a release bundle.
        #expect(!Updater().isRelease)
    }

    @MainActor @Test(arguments: [true, false]) func aReleaseWithoutAChecksumIsNeverStagedAndFailsOnEveryCheck(manual: Bool) async throws {
        let updater = Updater(current: "0.0.1", forceRelease: true)
        let page = URL(string: "https://example.com")!
        updater.latest = { Updater.Release(version: "9.9.9", zip: page, checksum: nil, page: page) }
        await updater.update(manual: manual)
        await waitUntil { updater.phase != .downloading }
        guard case .failed(let message) = updater.phase else { Issue.record("phase \(updater.phase)"); return }
        #expect(message.contains("no checksum") && updater.stagedPath == nil)
        // The next check tries again rather than leaving the failure for good.
        await updater.update(manual: manual)
        await waitUntil { updater.phase != .downloading }
        guard case .failed = updater.phase else { Issue.record("phase \(updater.phase)"); return }
    }

    @Test func checksumMustMatchTheZip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-checksum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("Fjord-1.0.0.zip")
        let contents = Data("zip".utf8)
        try contents.write(to: zip)
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()

        func checksum(_ text: String) throws -> URL {
            let file = dir.appendingPathComponent(UUID().uuidString + ".sha256")
            try Data(text.utf8).write(to: file)
            return file
        }
        try await Updater.verifyChecksum(of: zip, against: checksum("\(digest.uppercased())  Fjord-1.0.0.zip\n"))
        await #expect(throws: UpdateError.self) { try await Updater.verifyChecksum(of: zip, against: checksum(String(repeating: "0", count: 64))) }
        await #expect(throws: UpdateError.self) { try await Updater.verifyChecksum(of: zip, against: checksum("")) }
        await #expect(throws: UpdateError.self) { try await Updater.verifyChecksum(of: zip, against: dir.appendingPathComponent("missing.sha256")) }
    }

    /// Whether anything read inside `read` is invalidated by `change`.
    @MainActor private func invalidates(reading read: () -> Void, by change: () -> Void) -> Bool {
        final class Flag: @unchecked Sendable { var set = false }
        let flag = Flag()
        withObservationTracking(read) { flag.set = true }
        change()
        return flag.set
    }

    @MainActor @Test func aDownloadsProgressRedrawsOnlyWhatDrawsIt() {
        // A download from a check is silent but its progress arrives many times a second: the hub reads whether
        // the update shows and what phase it is in, not how far along it is.
        let updater = Updater()
        updater.preview(.downloading, version: "0.5.0")
        let hub = invalidates(reading: { _ = updater.showsInPill; _ = updater.phase; _ = updater.release }) {
            for completed in stride(from: 0.0, through: 1.0, by: 0.013) { updater.report(completed) }
        }
        #expect(!hub)
        #expect(updater.fraction == 0.98)
        // The update cell and Settings do read it.
        #expect(invalidates(reading: { _ = updater.fraction }) { updater.report(0.99) })
        // The phase changing is another matter: the cell turns into a restart button.
        #expect(invalidates(reading: { _ = updater.showsInPill; _ = updater.phase }) { updater.preview(.ready, version: "0.5.0") })
    }

    @MainActor @Test func theUpdateShowsInThePillOnceThereIsOneToActOn() {
        let updater = Updater()
        #expect(!updater.showsInPill)
        updater.preview(.available)
        #expect(updater.showsInPill)
        updater.preview(.idle)
        #expect(!updater.showsInPill)
        updater.preview(.failed("The download didn't finish"))
        #expect(updater.showsInPill)
    }

    @MainActor @Test(arguments: [Updater.Phase.available, .downloading, .ready, .failed("Can't write to /Applications")])
    func skippingAVersionClearsItWhereverItStood(phase: Updater.Phase) {
        let updater = Updater()
        var skipped: String?
        updater.onSkip = { skipped = $0 }
        updater.preview(phase, version: "0.5.0", fraction: 0.4)
        updater.skip()
        #expect(skipped == "0.5.0")
        #expect(updater.release == nil)
        #expect(updater.phase == .idle)
        #expect(!updater.showsInPill)
    }

    @MainActor @Test func aCheckThatFailsTheSameWayTwiceIsCountedTwice() async {
        let updater = Updater(current: "0.0.1", forceRelease: true)
        updater.latest = { throw UpdateError("GitHub didn't answer (502)") }
        await updater.check(manual: false)
        #expect(updater.failures == 0)
        #expect(updater.shownError == nil)
        await updater.check(manual: true)
        let first = updater.failures
        #expect(first == 1)
        #expect(updater.shownError == "GitHub didn't answer (502)")
        // Same words, still a new failure for whoever says it.
        await updater.check(manual: true)
        #expect(updater.failures == first + 1)
        #expect(updater.shownError == "GitHub didn't answer (502)")
    }

    @MainActor @Test func aFailedDownloadOrRestartIsTheErrorShownAndCountedEachTime() {
        let updater = Updater()
        updater.preview(.idle)
        #expect(updater.shownError == nil)
        updater.preview(.failed("The download didn't finish"))
        let first = updater.failures
        #expect(updater.shownError == "The download didn't finish")
        updater.preview(.downloading)
        updater.preview(.failed("The download didn't finish"))
        #expect(updater.failures == first + 1)
    }

    // MARK: Download, Skip and restart, with the network and the system stood in for

    /// A zip's transfer that does nothing until the test says so (`resume()` finishes at once when `delivers`).
    private final class FakeTransfer: UpdateTransfer, @unchecked Sendable {
        let progress = Progress(totalUnitCount: 100)
        let finish: @Sendable (URL?, URLResponse?, Error?) -> Void
        let delivers: Bool
        /// A real transfer reports its cancellation to its handler; one that had finished already does not.
        let reportsCancel: Bool
        private(set) var cancelled = false
        init(delivers: Bool, reportsCancel: Bool, finish: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void) {
            self.delivers = delivers
            self.reportsCancel = reportsCancel
            self.finish = finish
        }
        func resume() { if delivers { deliver() } }
        func cancel() {
            cancelled = true
            if reportsCancel { finish(nil, nil, URLError(.cancelled)) }
        }
        func deliver() {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).zip")
            try? Data("zip".utf8).write(to: file)
            let url = URL(string: "https://example.com/Fjord-9.9.9.zip")!
            finish(file, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }
    }

    /// An updater that has found 9.9.9 and whose zip, checking and unpacking, and restart are the test's.
    @MainActor private final class Rig {
        let updater = Updater(current: "0.0.1", forceRelease: true)
        private(set) var transfers: [FakeTransfer] = []
        private(set) var prepared = 0
        private(set) var installed: [URL] = []
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-fake-\(UUID().uuidString)/Fjord.app")
        var installFailures: [String] = []

        init(delivers: Bool, reportsCancel: Bool = true) {
            let page = URL(string: "https://example.com")!
            updater.latest = { Updater.Release(version: "9.9.9", zip: page, checksum: page, page: page) }
            updater.transport = { [unowned self] _, finish in
                let transfer = FakeTransfer(delivers: delivers, reportsCancel: reportsCancel, finish: finish)
                transfers.append(transfer)
                return transfer
            }
            updater.prepare = { [unowned self] _, _, _ in
                prepared += 1
                return app
            }
            updater.installer = { [unowned self] app in
                installed.append(app)
                if !installFailures.isEmpty { throw UpdateError(installFailures.removeFirst()) }
            }
        }

        /// Waits for what runs in the background (see `waitUntil`).
        func settle(_ done: () -> Bool) async throws {
            await waitUntil(done)
        }
    }

    @MainActor @Test func skipStopsTheTransferAndNothingItDoesLaterIsStaged() async throws {
        let rig = Rig(delivers: false)
        await rig.updater.check(manual: true)
        rig.updater.download()
        try await rig.settle { !rig.transfers.isEmpty }
        let transfer = try #require(rig.transfers.first)
        #expect(rig.updater.phase == .downloading)

        rig.updater.skip()
        #expect(transfer.cancelled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.updater.phase == .idle)
        #expect(rig.updater.release == nil)
        #expect(rig.updater.stagedPath == nil)
        #expect(rig.prepared == 0)
    }

    @MainActor @Test func aTransferThatFinishesJustAfterSkipIsNotVerifiedOrStaged() async throws {
        // The zip had arrived as Skip was clicked: its completion is delivered after, and must change nothing.
        let rig = Rig(delivers: false, reportsCancel: false)
        await rig.updater.check(manual: true)
        rig.updater.download()
        try await rig.settle { !rig.transfers.isEmpty }
        let transfer = try #require(rig.transfers.first)

        rig.updater.skip()
        transfer.deliver()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.prepared == 0)
        #expect(rig.updater.phase == .idle)
        #expect(rig.updater.stagedPath == nil)
        #expect(!rig.updater.showsInPill)
        // And the next release is free to download: nothing of the skipped one is left holding the slot.
        await rig.updater.check(manual: true)
        rig.updater.download()
        try await rig.settle { rig.transfers.count == 2 }
        #expect(rig.transfers.count == 2)
    }

    @MainActor @Test func aFailedRestartIsRetriedWithTheVerifiedAppNotDownloadedAgain() async throws {
        let rig = Rig(delivers: true)
        rig.installFailures = ["Can't write to /Applications"]
        await rig.updater.check(manual: true)
        rig.updater.download()
        try await rig.settle { rig.updater.phase == .ready }
        #expect(rig.updater.stagedPath == rig.app.path)

        rig.updater.install()
        #expect(rig.updater.phase == .failed("Can't write to /Applications"))
        #expect(rig.updater.stagedPath == rig.app.path)

        // "Try again" on the failed phase restarts into the same app.
        rig.updater.advance()
        #expect(rig.updater.phase == .installing)
        #expect(rig.installed == [rig.app, rig.app])
        #expect(rig.transfers.count == 1)
        #expect(rig.prepared == 1)
    }
}
