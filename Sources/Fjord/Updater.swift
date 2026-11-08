import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// Updates from GitHub releases: finds a newer release, downloads its zip, checks it (SHA-256, same bundle, and
/// signed by the same certificate as the running app), then swaps the bundle in place and relaunches.
/// Signing every release with one certificate is also what keeps Accessibility access across updates.
@Observable
@MainActor
final class Updater {
    enum Phase: Equatable {
        case idle
        case available
        /// How far along it is is `Updater.fraction`, not part of the phase: the phase changes a few times, the fraction many.
        case downloading
        /// Verified and unpacked, waiting for a restart.
        case ready
        case installing
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Release: Equatable {
        let version: String
        let zip: URL
        let checksum: URL?
        let page: URL
    }

    static let repo = "amontlabs/fjord"
    static let interval: TimeInterval = 3600

    private(set) var phase: Phase = .idle {
        didSet {
            refreshPill()
            if case .failed = phase { failures += 1 }
        }
    }
    private(set) var release: Release? { didSet { refreshPill() } }
    /// The download's progress in whole percents (0...1). Read only by the views that draw it, so the hub, which reads
    /// `showsInPill`, is not redrawn as it moves.
    private(set) var fraction = 0.0
    private(set) var checking = false
    private(set) var lastCheck: Date?
    /// Why the last check failed (only surfaced when you asked for it).
    private(set) var checkError: String?
    /// Every failure that was shown, counted: the same one again (a retry that fails as the last did) is still news to
    /// say, and `shownError` alone does not change.
    private(set) var failures = 0

    /// The failure there is to show, if any: a download or restart that failed, or a check that did. Settings' row
    /// draws it and the hub says it, from wherever the check was asked for.
    var shownError: String? {
        if case .failed(let message) = phase { return message }
        return phase == .idle ? checkError : nil
    }

    /// Asked before each automatic check, and whether a found version was skipped.
    @ObservationIgnored var automatic: () -> Bool = { true }
    @ObservationIgnored var skipped: () -> String? = { nil }
    @ObservationIgnored var onSkip: (String) -> Void = { _ in }
    /// Looks up the newest release; tests swap it for a canned one.
    @ObservationIgnored var latest: () async throws -> Release = Updater.latest
    /// The three places a test stands in for the network and the system: starting the zip's transfer, checking and
    /// unpacking it (to the app it holds), and swapping the app in and quitting.
    @ObservationIgnored var transport: (URL, @escaping @Sendable (URL?, URLResponse?, Error?) -> Void) -> any UpdateTransfer = {
        Network.session.downloadTask(with: $0, completionHandler: $1)
    }
    @ObservationIgnored var prepare: (URL, Release, URL) async throws -> URL = { zip, release, checksum in
        try await Updater.verifyChecksum(of: zip, against: checksum)
        // Unpacking and checking the signature take a while: not on the main thread.
        return try await Task.detached(priority: .utility) { try Updater.unpack(zip, version: release.version) }.value
    }
    @ObservationIgnored var installer: (URL) throws -> Void = Updater.swapIn
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var staged: URL?
    var stagedPath: String? { staged?.path }
    @ObservationIgnored private var progress: NSKeyValueObservation?
    /// The zip in flight, so Skip can stop the transfer and not only the task waiting on it.
    @ObservationIgnored private var transfer: (any UpdateTransfer)?
    @ObservationIgnored private var wake: NSObjectProtocol?
    /// Downloads started by an automatic check fail quietly and are tried again at the next check,
    /// unless the failure says the release can't be trusted (see `UpdateError.untrusted`).
    @ObservationIgnored private var quiet = false { didSet { refreshPill() } }

    let current: String
    private var forceRelease: Bool

    /// `current` and `forceRelease` let `--update` pretend to be an older release.
    init(current: String? = nil, forceRelease: Bool = false) {
        self.current = current ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
        self.forceRelease = forceRelease
    }

    /// Builds from source (`0.0.0-dev`, or not a bundle) never update themselves.
    var isRelease: Bool {
        forceRelease || (Bundle.main.bundleIdentifier != nil && Version(current) != nil && !current.contains("dev"))
    }

    /// Releases download in the background: the pill shows a button once one is ready to restart into, or when
    /// it's left to you (found by a check that doesn't download, or a background download that failed).
    /// Stored and set only when it flips, so what reads it (every layout of the hub) is not invalidated by a phase that
    /// changes without changing it.
    private(set) var showsInPill = false

    private func refreshPill() {
        let shows: Bool
        switch phase {
        case _ where release == nil: shows = false
        case .available, .ready, .installing, .failed: shows = true
        case .downloading: shows = !quiet
        case .idle: shows = false
        }
        if shows != showsInPill { showsInPill = shows }
    }

    /// Checks shortly after launch, every hour and on wake from sleep.
    func start() {
        guard isRelease, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                if let self, self.automatic() { await self.update(manual: false) }
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                 queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                if let self, self.automatic() { await self.update(manual: false) }
            }
        }
    }

    /// Checks, then fetches and verifies anything new in the background.
    func update(manual: Bool) async {
        await check(manual: manual)
        // A download that failed without a staged app is tried again, as a quiet one was before it was shown.
        if case .failed = phase, staged == nil, release != nil { phase = .available }
        guard phase == .available else { return }
        quiet = !manual
        download()
    }

    // MARK: Check

    func check(manual: Bool) async {
        guard isRelease, !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let found = try await latest()
            lastCheck = Date()
            checkError = nil
            guard let new = Version(found.version), let old = Version(current), new > old else {
                if case .available = phase { phase = .idle }
                if phase == .idle { release = nil }
                return
            }
            // Don't drop a download in progress or a staged update for the same release.
            if release == found, phase != .idle, phase != .available { return }
            if !manual, skipped() == found.version { return }
            release = found
            phase = .available
        } catch {
            if manual {
                checkError = error.localizedDescription
                failures += 1
            }
        }
    }

    private static func latest() async throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Network.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub didn't answer (\((response as? HTTPURLResponse)?.statusCode ?? 0))") }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let zip = payload.assets.first(where: { $0.name.hasPrefix("Fjord-") && $0.name.hasSuffix(".zip") }) else {
            throw UpdateError("The latest release has no app to download")
        }
        let checksum = payload.assets.first { $0.name == zip.name + ".sha256" }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, zip: zip.browser_download_url, checksum: checksum?.browser_download_url, page: payload.html_url)
    }

    // MARK: Download

    /// Downloads and verifies the release; the pill then offers a restart.
    func download() {
        guard let release, work == nil else { return }
        fraction = 0
        // Whatever was verified for an older release is not this one.
        staged = nil
        phase = .downloading
        work = Task {
            // Skipped meanwhile (`skip()` has cleared `work` and said where things stand): nothing here may publish.
            defer { if !Task.isCancelled { work = nil; progress = nil } }
            do {
                // Without a checksum there's nothing to trust the download against: don't even fetch it.
                guard let checksum = release.checksum else { throw UpdateError("The release has no checksum to verify the download", untrusted: true) }
                let zip = try await fetch(release.zip)
                defer { try? FileManager.default.removeItem(at: zip) }
                // Skipped while the transfer's completion was on its way: nothing more of it may be verified or staged.
                try Task.checkCancellation()
                let app = try await prepare(zip, release, checksum)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                    return
                }
                staged = app
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                phase = quiet && (error as? UpdateError)?.untrusted != true ? .available : .failed(error.localizedDescription)
            }
            quiet = false
        }
    }

    /// The `.sha256` asset holds `<hex digest>  <file name>`; the zip must hash to that digest.
    nonisolated static func verifyChecksum(of zip: URL, against checksum: URL) async throws {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Network.session.data(from: checksum)
        } catch {
            throw UpdateError("Couldn't read the release checksum", untrusted: true)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError("Couldn't read the release checksum", untrusted: true) }
        let expected = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
        let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard expected == actual else { throw UpdateError("The download is corrupted (checksum mismatch)", untrusted: true) }
    }

    /// The download's progress as it is reported (many times a second): kept in whole percents, which is all that is drawn, and
    /// each change redraws only the views that read `fraction`.
    func report(_ completed: Double) {
        let percent = (completed * 100).rounded(.down) / 100
        guard phase == .downloading, fraction != percent else { return }
        fraction = percent
    }

    private func fetch(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let task = transport(url) { file, response, error in
                if let error { return continuation.resume(throwing: error) }
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return continuation.resume(throwing: UpdateError("The download failed"))
                }
                // The file is deleted when this handler returns.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("Fjord-\(UUID().uuidString).zip")
                do {
                    try FileManager.default.moveItem(at: file, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progress = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                let completed = p.fractionCompleted
                Task { @MainActor in self?.report(completed) }
            }
            transfer = task
            task.resume()
        }
    }

    /// Unzips the release and checks it's this app, at that version, signed like the running one.
    nonisolated static func unpack(_ zip: URL, version: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Fjord-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let app = dir.appendingPathComponent("Fjord.app")
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download isn't Fjord")
        }
        guard bundle.infoDictionary?["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("The download isn't version \(version)")
        }
        try verifySignature(app)
        return app
    }

    /// The new app must satisfy the running app's designated requirement, i.e. be signed by the same certificate.
    /// An ad-hoc signed app has no certificate to compare (its requirement is its own hash): it only checks the
    /// new signature is intact, so older ad-hoc releases can still move to signed ones.
    nonisolated private static func verifySignature(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The download isn't signed")
        }
        var requirement: SecRequirement?
        var me: SecCode?
        var meStatic: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess,
           let meStatic, SecCodeCopySigningInformation(meStatic, [], &info) == errSecSuccess,
           let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32,
           flags & SecCodeSignatureFlags.adhoc.rawValue == 0 {
            SecCodeCopyDesignatedRequirement(meStatic, [], &requirement)
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode)), requirement)
        guard status == errSecSuccess else {
            throw UpdateError(requirement == nil ? "The download's signature is invalid" : "The download isn't signed by Fjord's certificate")
        }
    }

    // MARK: Install

    /// Quits, swaps the bundle (keeping the old one if that fails) and opens the new one.
    func install() {
        // Failed: the restart itself did, so the verified app is still here to try again with.
        guard phase == .ready || phase.isFailed, let staged else { return }
        phase = .installing
        do {
            try installer(staged)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func swapIn(_ staged: URL) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        if target.path.contains("/AppTranslocation/") {
            throw UpdateError("Move Fjord to Applications (and clear its quarantine) to update it")
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError("Can't write to \(parent.path)") }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        backup="$2.previous"
        rm -rf "$backup"
        if mv "$2" "$backup"; then
          if mv "$3" "$2"; then rm -rf "$backup"; else mv "$backup" "$2"; fi
        fi
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
        open "$2"
        """
        guard !UnderTest.refuses("the update swap (it replaces the app and quits)") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path]
        try process.run()
        NSApp.terminate(nil)
    }

    /// Screenshots and demos: show a release in a given phase without touching the network.
    func preview(_ phase: Phase, version: String = "0.3.0", fraction: Double = 0) {
        let page = URL(string: "https://github.com/\(Self.repo)/releases/tag/v\(version)")!
        forceRelease = true
        release = Release(version: version, zip: page, checksum: nil, page: page)
        lastCheck = Date().addingTimeInterval(-600)
        self.phase = phase
        self.fraction = fraction
    }

    // MARK: Pill actions

    /// The one thing to do next: download, retry, or restart.
    func advance() {
        switch phase {
        case .available: quiet = false; download()
        case .failed: quiet = false; staged == nil ? download() : install()
        case .ready: install()
        case .idle, .downloading, .installing: break
        }
    }

    func skip() {
        guard let release else { return }
        work?.cancel()
        transfer?.cancel()
        work = nil
        progress = nil
        quiet = false
        onSkip(release.version)
        self.release = nil
        phase = .idle
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("Couldn't unpack the download") }
    }
}

/// `--update <version>`: pretends to be that version, then checks, downloads and verifies the latest release
/// (without installing it). Run it from the app bundle so the bundle and signature checks apply.
enum UpdateCheck {
    @MainActor static func run(as version: String) {
        let updater = Updater(current: version, forceRelease: true)
        Task {
            await updater.check(manual: true)
            print("current:", version, "latest:", updater.release?.version ?? "-", "phase:", updater.phase, updater.checkError ?? "")
            guard updater.phase == .available else { exit(updater.checkError == nil ? 0 : 1) }
            updater.download()
            var shown = -1
            while updater.phase == .downloading {
                let fraction = updater.fraction
                if Int(fraction * 10) != shown { shown = Int(fraction * 10); print("downloading", "\(shown * 10)%") }
                try? await Task.sleep(for: .milliseconds(100))
            }
            print("phase:", updater.phase, updater.stagedPath ?? "")
            exit(updater.phase == .ready ? 0 : 1)
        }
    }
}

/// What `Updater` needs of a zip's transfer (a `URLSessionDownloadTask`, or a test's stand-in).
protocol UpdateTransfer: AnyObject {
    var progress: Progress { get }
    func resume()
    func cancel()
}
extension URLSessionDownloadTask: UpdateTransfer {}

struct UpdateError: LocalizedError {
    let message: String
    /// The release failed its checksum: shown even when a check started the download, not retried in silence.
    let untrusted: Bool
    init(_ message: String, untrusted: Bool = false) {
        self.message = message
        self.untrusted = untrusted
    }
    var errorDescription: String? { message }
}

/// `1.2.3` style versions, compared numerically (a leading `v` is ignored).
struct Version: Comparable {
    let parts: [Int]

    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}
