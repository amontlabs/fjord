import Foundation
import Observation
import Security

// Fjord's link to the T3 Code on this Mac: finding it, the token Fjord holds for it, and what the Settings and the hub say.
// The wire work is `T3Client`; this decides when it runs and why it isn't.

// MARK: - Install and token

enum T3Install {
    static let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/bin/t3")
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: cli.path) }
}

extension T3Discovery {
    private static var tokenQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: tokenService]
    }

    /// Whether the Keychain kept it. An item already there is updated in place.
    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        guard !UnderTest.refuses("the Keychain, writing the T3 token") else { return false }
        let data = Data(token.utf8)
        let status = SecItemUpdate(tokenQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var q = tokenQuery
        q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken() {
        guard !UnderTest.refuses("the Keychain, deleting the T3 token") else { return }
        SecItemDelete(tokenQuery as CFDictionary)
    }
}

/// Mints Fjord's token with T3's own CLI (it writes T3's auth database; the owner approved that). The token is only ever
/// returned to the caller: nothing here logs it, and a failure says what the CLI complained about, never what it printed.
struct T3TokenMinter: Sendable {
    struct Output: Sendable { var status: Int32; var stdout: String; var stderr: String }
    typealias Runner = @Sendable (_ executable: URL, _ arguments: [String]) async throws -> Output

    struct Failure: Error, Equatable, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static let arguments = ["auth", "session", "issue", "--scope", "orchestration:read", "--scope", "orchestration:operate",
                            "--label", "Fjord", "--ttl", "365d", "--token-only"]

    var executable: URL = T3Install.cli
    var run: Runner = T3TokenMinter.process

    func mint() async throws -> String {
        let out: Output
        do { out = try await run(executable, Self.arguments) }
        catch { throw Failure(message: "Couldn't run T3's command line: \(error.localizedDescription)") }
        guard out.status == 0 else {
            let why = out.stderr.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            throw Failure(message: why.isEmpty ? "T3's command line failed (\(out.status))" : "T3's command line failed: \(why)")
        }
        let token = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { throw Failure(message: "T3 gave no token") }
        return token
    }

    static let process: Runner = { executable, arguments in
        guard !UnderTest.refuses("T3's command line") else { throw Failure(message: "refused under test") }
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }
        let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
        let status: Int32 = try await withCheckedThrowingContinuation { k in
            p.terminationHandler = { k.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { k.resume(throwing: error) }
        }
        return Output(status: status, stdout: String(decoding: await stdout.value, as: UTF8.self),
                      stderr: String(decoding: await stderr.value, as: UTF8.self))
    }
}

// MARK: - Status

enum T3LinkStatus: Equatable {
    case notInstalled
    case notLinked
    case linking
    case connecting
    case serverNotRunning
    case incompatible(String)
    case tokenRejected
    case mintFailed(String)
    case connected(threads: Int)

    var isConnected: Bool { if case .connected = self { true } else { false } }
    /// Something the owner should see in the hub, as opposed to a state on its way somewhere.
    var isProblem: Bool {
        switch self {
        case .serverNotRunning, .incompatible, .tokenRejected, .mintFailed: true
        default: false
        }
    }

    /// The line the Settings and the hub show.
    var text: String {
        switch self {
        case .notInstalled: "T3 Code isn't installed"
        case .notLinked: "Not linked to T3 Code"
        case .linking: "Linking to T3 Code…"
        case .connecting: "Connecting to T3 Code…"
        case .serverNotRunning: "T3 Code isn't running"
        case .incompatible(let why): "Fjord can't talk to this T3 Code: \(why)"
        case .tokenRejected: "T3 Code refused Fjord's link"
        case .mintFailed(let why): "Couldn't link to T3 Code: \(why)"
        case .connected(let n): "Linked to T3 Code: \(n) \(n == 1 ? "thread" : "threads")"
        }
    }

    /// The state as the pieces report it. A halted connection (one that can't go on without a change) outranks the live one.
    static func from(installed: Bool, started: Bool, minting: Bool, mintError: String?, halted: T3ConnectionState?,
                     connection: T3ConnectionState, threads: Int) -> T3LinkStatus {
        if !installed { return .notInstalled }
        if minting { return .linking }
        if let mintError { return .mintFailed(mintError) }
        switch halted ?? connection {
        case .noToken: return .notLinked
        case .noServer: return .serverNotRunning
        case .incompatible(let why): return .incompatible(why)
        case .tokenRejected: return .tokenRejected
        case .connected: return .connected(threads: threads)
        case .connecting, .reconnecting: return .connecting
        case .idle: return started ? .connecting : .notLinked
        }
    }
}

// MARK: - The link

/// Owns the T3 client and store for this Mac's T3 server. Starts when T3 is installed and a token is in the Keychain; a
/// connection that can't go on (no token, a refused token, another protocol, no server) stops instead of retrying: the
/// token is minted again once by itself, a server coming up is noticed from its runtime file, and the rest waits for you.
@MainActor @Observable
final class T3Link {
    struct Dependencies {
        var installed: @Sendable () -> Bool = { T3Install.isInstalled }
        var readToken: @Sendable () -> String? = { T3Discovery.keychainToken() }
        var saveToken: @Sendable (String) -> Bool = { T3Discovery.saveToken($0) }
        var deleteToken: @Sendable () -> Void = { T3Discovery.deleteToken() }
        var minter = T3TokenMinter()
        var makeClient: @Sendable (_ token: @escaping @Sendable () -> String?) -> T3Client = { T3Client.local(token: $0) }
        /// Calls back when T3's runtime file changes (the server started or moved). The returned object stops the watch.
        var watchRuntime: @MainActor (_ changed: @escaping () -> Void) -> AnyObject? = { changed in
            guard !UnderTest.isRunning else { return nil }
            let file = T3Discovery.runtimeFile
            return FolderWatcher([file.deletingLastPathComponent()], relevant: { $0.contains { $0.hasSuffix("server-runtime.json") } },
                                 handler: changed)
        }
    }

    let store = T3Store()
    private let deps: Dependencies
    private(set) var started = false
    private(set) var minting = false
    private(set) var mintError: String?
    /// Why the connection stopped by itself, until something changes it.
    private(set) var halted: T3ConnectionState?

    @ObservationIgnored private var client: T3Client?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var runtimeWatch: AnyObject?
    @ObservationIgnored private var remintedSinceConnected = false

    init(_ deps: Dependencies = Dependencies()) { self.deps = deps }

    var installed: Bool { deps.installed() }

    /// Demo data and shots show a state without a server behind it.
    @ObservationIgnored var demoStatus: T3LinkStatus?

    var status: T3LinkStatus {
        if let demoStatus { return demoStatus }
        return .from(installed: installed, started: started, minting: minting, mintError: mintError, halted: halted,
              connection: store.connection, threads: store.listedThreads.count)
    }

    /// Connects, when T3 is there. With no token it stops at "not linked" until you press Link.
    func start() {
        guard installed else { return }
        connect()
    }

    /// The Settings button: mints a token, keeps it in the Keychain and connects.
    func link() async {
        guard installed, !minting else { return }
        remintedSinceConnected = false
        guard await mintAndSave() else { return }
        connect()
    }

    /// Forgets the token and disconnects. The session stays listed in T3's own settings, where it can be revoked.
    func unlink() {
        disconnect()
        deps.deleteToken()
        mintError = nil
        halted = .noToken
    }

    func stop() { disconnect() }

    // MARK: Private

    private func mintAndSave() async -> Bool {
        minting = true
        mintError = nil
        defer { minting = false }
        do {
            let token = try await deps.minter.mint()
            guard deps.saveToken(token) else { mintError = "the Keychain refused the token"; return false }
            return true
        } catch {
            mintError = error.localizedDescription
            return false
        }
    }

    private func connect() {
        disconnect()
        started = true
        halted = nil
        let client = deps.makeClient(deps.readToken)
        self.client = client
        store.start(client: client)
        watchTask = Task { [weak self] in
            for await state in await client.connectionStates() {
                guard let self else { return }
                await self.observe(state, of: client)
            }
        }
    }

    private func disconnect() {
        watchTask?.cancel(); watchTask = nil
        runtimeWatch = nil
        store.stop()
        if let client { Task { await client.shutdown() } }
        client = nil
        started = false
    }

    private func observe(_ state: T3ConnectionState, of source: T3Client) async {
        guard source === client else { return }
        switch state {
        case .connected:
            remintedSinceConnected = false
        case .tokenRejected:
            // Once per connection: a token minted and refused again is not going to be fixed by minting a third.
            if installed, !remintedSinceConnected {
                remintedSinceConnected = true
                if await mintAndSave() { connect(); return }
            }
            halt(state)
        case .noToken, .incompatible:
            halt(state)
        case .noServer:
            halt(state)
            runtimeWatch = deps.watchRuntime { [weak self] in
                guard let self, self.halted == .noServer else { return }
                self.connect()
            }
        default: break
        }
    }

    private func halt(_ state: T3ConnectionState) {
        halted = state
        if let client { Task { await client.shutdown() } }
    }
}
