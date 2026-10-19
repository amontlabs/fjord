import Foundation
import Darwin
import Observation
import ServiceManagement

enum EngineAgentStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

@MainActor
protocol EngineAgentServicing {
    func status() -> EngineAgentStatus
    func register() throws
    /// Stops the agent and forgets the registration, so the next `register()` points it at the bundle as it is now.
    func unregister() async throws
    func openSystemSettings()
}

@MainActor
struct SystemEngineAgentService: EngineAgentServicing {
    private let plistName = AppIdentity.engineAgentPlistName()

    func status() -> EngineAgentStatus {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
        return Self.status(SMAppService.agent(plistName: plistName).status,
                           plistInBundle: FileManager.default.fileExists(atPath: plist.path))
    }

    /// macOS answers `.notFound` for an agent that was never registered, its plist in the bundle or not; only a plist
    /// that isn't there is missing.
    nonisolated static func status(_ status: SMAppService.Status, plistInBundle: Bool) -> EngineAgentStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: plistInBundle ? .notRegistered : .notFound
        @unknown default: .unknown
        }
    }

    func register() throws {
        try SMAppService.agent(plistName: plistName).register()
    }

    func unregister() async throws {
        try await SMAppService.agent(plistName: plistName).unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct EngineConnection {
    let client: any EngineClient
    let version: String
    let build: String?
    let source: EngineConnectionSource
}

@MainActor
protocol EngineSocketConnecting {
    func connect() async throws -> EngineConnection
}

@MainActor
struct SocketEngineConnector: EngineSocketConnecting {
    private let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func connect() async throws -> EngineConnection {
        let client = SocketEngineClient(path: socketPath)
        _ = try await client.connect()
        let engineState: SiloWireEngineState = try await client.invoke(
            SiloGeneratedMethods.engineState(SiloWireEmptyParams()))
        guard !engineState.sessionEnding, !engineState.shuttingDown else {
            throw EngineClientError.unavailable
        }
        let update = try await client.updatesState()
        let recordURL = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            .appendingPathComponent("engine-owner.json")
        let record = try? JSONDecoder().decode(EngineOwnerRecord.self, from: Data(contentsOf: recordURL))
        return EngineConnection(client: client, version: update.currentVersion, build: record?.engineBuild,
                                source: Self.source(record: record, mainBundleURL: Bundle.main.bundleURL))
    }

    private struct EngineOwnerRecord: Decodable {
        let channelIdentifier: String
        let engineBuild: String
        let pid: Int32
    }

    private static func source(record: EngineOwnerRecord?, mainBundleURL: URL) -> EngineConnectionSource {
        guard let record, record.pid > 0 else { return .sharedEngine }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid_t(record.pid), pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0, let executable = buffer.withUnsafeBufferPointer({ pointer in
            pointer.baseAddress.map(String.init(cString:))
        }) else { return .sharedEngine }

        let bundlePath = mainBundleURL.standardizedFileURL.path
        let executablePath = URL(fileURLWithPath: executable).standardizedFileURL.path
        return executablePath.hasPrefix(bundlePath + "/") ? .fjordAgent : .sharedEngine
    }
}

struct EngineVersion: Comparable, Equatable {
    private enum Identifier: Equatable {
        case numeric(UInt64)
        case text(String)
    }

    private let major: UInt64
    private let minor: UInt64
    private let patch: UInt64
    private let prerelease: [Identifier]

    init?(_ value: String) {
        let parts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count <= 2, let versionText = parts.first, !versionText.isEmpty else { return nil }
        if parts.count == 2, !Self.validIdentifiers(String(parts[1]), allowLeadingZeroes: true) { return nil }

        let versionParts = versionText.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let coreText = versionParts.first else { return nil }
        let core = coreText.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.number(core[0]),
              let minor = Self.number(core[1]),
              let patch = Self.number(core[2]) else { return nil }

        var prerelease: [Identifier] = []
        if versionParts.count == 2 {
            let values = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !values.isEmpty else { return nil }
            for value in values {
                guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
                if value.allSatisfy(\.isNumber) {
                    guard value == "0" || value.first != "0", let number = UInt64(value) else { return nil }
                    prerelease.append(.numeric(number))
                } else {
                    prerelease.append(.text(String(value)))
                }
            }
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func < (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (left, right) {
            case (.numeric(let a), .numeric(let b)): return a < b
            case (.numeric, .text): return true
            case (.text, .numeric): return false
            case (.text(let a), .text(let b)): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func number(_ value: Substring) -> UInt64? {
        guard !value.isEmpty, value == "0" || value.first != "0",
              value.allSatisfy(\.isNumber) else { return nil }
        return UInt64(value)
    }

    private static func validIdentifiers(_ value: String, allowLeadingZeroes: Bool) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
            !identifier.isEmpty
                && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                && (allowLeadingZeroes || !identifier.allSatisfy(\.isNumber) || identifier == "0" || identifier.first != "0")
        }
    }
}

enum EngineConnectionSource: Equatable {
    case fjordAgent
    case sharedEngine
}

enum EngineLaunchState: Equatable {
    case unchecked
    case checking
    case enableRequired
    case registering
    case awaitingApproval
    case waitingForEngine
    case connected(version: String, source: EngineConnectionSource)
    /// Same version, different build: not an update Fjord may make.
    case updateBlocked(current: String, bundled: String, reason: String)
    case missingBundle
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .registering, .waitingForEngine: true
        default: false
        }
    }

    var message: String {
        switch self {
        case .unchecked, .checking: "Checking for the Silo engine…"
        case .enableRequired: "Enable the Silo engine to manage computers on this Mac. Fjord will register its LaunchAgent only after you choose Enable."
        case .registering: "Registering the Silo engine with macOS…"
        case .awaitingApproval: "macOS needs your approval before the Silo engine can run. Open Login Items in System Settings and allow it."
        case .waitingForEngine: "Waiting for the Silo engine to start…"
        case .connected(let version, let source):
            source == .sharedEngine
                ? "Connected to the shared Silo engine, version \(version)."
                : "Connected to the Silo engine, version \(version)."
        case .updateBlocked(_, _, let reason), .failed(let reason): reason
        case .missingBundle: "The Silo engine bundle is missing. Reinstall Fjord to add it."
        }
    }
}

/// The engine update the Computers tool shows. The running engine keeps serving through every state but `failed`.
enum EngineUpdateStatus: Equatable {
    case none
    /// The bundled engine is newer than the running one.
    case available(current: String, bundled: String)
    case running(EngineHandoffPhase)
    /// Stopped before the old engine left; it still serves, its computers untouched.
    case blocked(String)
    /// The old engine left and the new one didn't come up cleanly.
    case failed(String)
    case completed(resumed: [String], missing: [String])

    var message: String? {
        switch self {
        case .none: nil
        case .available(let current, let bundled):
            "Fjord includes Silo engine \(bundled), and \(current) is running. Updating saves running computers and resumes them."
        case .running(let phase): phase.message
        case .blocked(let reason): "The Silo engine wasn't updated. Your computers are untouched. \(reason)"
        case .failed(let reason): reason
        case .completed(let resumed, let missing):
            if !missing.isEmpty { "The Silo engine was updated. Still resuming: \(missing.joined(separator: ", "))." }
            else if resumed.isEmpty { "The Silo engine was updated." }
            else { "The Silo engine was updated and resumed \(resumed.joined(separator: ", "))." }
        }
    }
}

@MainActor
@Observable
final class EngineLauncher {
    @ObservationIgnored private let service: any EngineAgentServicing
    @ObservationIgnored private let connector: any EngineSocketConnecting
    @ObservationIgnored private let candidateVersion: String?
    @ObservationIgnored private let candidateBuild: String?
    @ObservationIgnored private let pollDelaysNanoseconds: [UInt64]
    @ObservationIgnored private var operationInFlight = false
    @ObservationIgnored private let handoff: EngineHandoff?
    @ObservationIgnored private var handoffTask: Task<Void, Never>?
    private(set) var update: EngineUpdateStatus = .none
    @ObservationIgnored private(set) var client: (any EngineClient)?
    private(set) var state: EngineLaunchState = .unchecked

    var isConnected: Bool {
        if case .connected = state { return client != nil }
        return false
    }

    convenience init(socketPath: String) {
        let candidate = Self.embeddedCandidate()
        let service = SystemEngineAgentService()
        let connector = SocketEngineConnector(socketPath: socketPath)
        let engineDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().appendingPathComponent("engine")
        self.init(candidateVersion: candidate?.version, candidateBuild: candidate?.build,
                  service: service, connector: connector,
                  pollDelaysNanoseconds: [0, 250_000_000, 500_000_000, 1_000_000_000, 1_000_000_000],
                  handoff: EngineHandoff(engineDirectory: engineDirectory, lock: FlockEngineInstallLock(), service: service,
                                         connector: connector, probe: SocketEngineProbe(socketPath: socketPath)))
    }

    convenience init(candidateVersion: String, candidateBuild: String = "test-build",
                     service: any EngineAgentServicing, connector: any EngineSocketConnecting,
                     pollDelaysNanoseconds: [UInt64] = [0], handoff: EngineHandoff? = nil) {
        self.init(candidateVersion: Optional(candidateVersion), candidateBuild: Optional(candidateBuild),
                  service: service, connector: connector, pollDelaysNanoseconds: pollDelaysNanoseconds, handoff: handoff)
    }

    private init(candidateVersion: String?, candidateBuild: String?, service: any EngineAgentServicing,
                 connector: any EngineSocketConnecting, pollDelaysNanoseconds: [UInt64], handoff: EngineHandoff?) {
        self.handoff = handoff
        self.candidateVersion = candidateVersion
        self.candidateBuild = candidateBuild
        self.service = service
        self.connector = connector
        self.pollDelaysNanoseconds = pollDelaysNanoseconds
    }

    func inspect() async {
        guard !operationInFlight else { return }
        operationInFlight = true
        defer { operationInFlight = false }
        guard candidateVersion != nil else { state = .missingBundle; return }

        state = .checking
        if let running = try? await connector.connect() {
            adopt(running)
            return
        }
        switch service.status() {
        case .notRegistered: state = .enableRequired
        case .requiresApproval: state = .awaitingApproval
        case .notFound: state = .missingBundle
        case .enabled: await waitForEngine()
        case .unknown: state = .failed("macOS returned an unknown LaunchAgent status.")
        }
    }

    /// Called only from the visible Enable button. `inspect()` never registers the service.
    func enable() async {
        guard !operationInFlight else { return }
        operationInFlight = true
        defer { operationInFlight = false }
        guard candidateVersion != nil else { state = .missingBundle; return }

        state = .checking
        if let running = try? await connector.connect() {
            adopt(running)
            return
        }

        switch service.status() {
        case .requiresApproval:
            state = .awaitingApproval
            return
        case .notFound:
            state = .missingBundle
            return
        case .unknown:
            state = .failed("macOS returned an unknown LaunchAgent status.")
            return
        case .notRegistered:
            state = .registering
            do {
                try service.register()
            } catch {
                switch service.status() {
                case .requiresApproval: state = .awaitingApproval
                case .enabled: await waitForEngine()
                case .notFound: state = .missingBundle
                case .unknown: state = .failed(error.localizedDescription)
                case .notRegistered: state = .failed(error.localizedDescription)
                }
                return
            }
        case .enabled:
            break
        }

        switch service.status() {
        case .requiresApproval: state = .awaitingApproval
        case .notFound: state = .missingBundle
        case .unknown: state = .failed("macOS returned an unknown LaunchAgent status.")
        case .notRegistered: state = .failed("macOS did not register the Silo LaunchAgent.")
        case .enabled: await waitForEngine()
        }
    }

    func openApprovalSettings() {
        guard state == .awaitingApproval else { return }
        service.openSystemSettings()
    }

    private func waitForEngine() async {
        state = .waitingForEngine
        var lastFailure = "macOS enabled the LaunchAgent, but the engine did not complete its socket handshake."
        for delay in pollDelaysNanoseconds {
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: delay) }
                catch { state = .enableRequired; return }
            }
            do {
                let running = try await connector.connect()
                adopt(running)
                return
            } catch {
                lastFailure = error.localizedDescription
            }
        }
        state = .failed(lastFailure)
    }

    private func adopt(_ running: EngineConnection) {
        guard let candidateVersion, let candidate = EngineVersion(candidateVersion),
              let current = EngineVersion(running.version) else {
            client = nil
            state = .failed("The bundled or running engine reported an invalid SemVer version.")
            return
        }
        if current < candidate {
            // The old engine keeps serving until the handoff swaps it (`updateEngine`).
            client = running.client
            state = .connected(version: running.version, source: running.source)
            switch update {
            case .running, .blocked: break
            default: update = .available(current: running.version, bundled: candidateVersion)
            }
            return
        }
        if current == candidate, let candidateBuild,
           running.build.map({ $0 != candidateBuild }) ?? true {
            client = nil
            state = .updateBlocked(current: running.version, bundled: candidateVersion,
                                   reason: "A different build of Silo \(candidateVersion) already owns this Mac. Fjord left it running to protect its computers.")
            return
        }
        client = running.client
        state = .connected(version: running.version, source: running.source)
        switch update {
        case .running, .completed, .blocked: break
        default: update = .none
        }
    }

    /// Whether the update goes ahead without being asked: Fjord's LaunchAgent is already registered (the user enabled the
    /// engine here, or this is the first launch after a Fjord update), so replacing its engine registers nothing new.
    /// Otherwise (Silo.app owns the engine) the user presses Update, as `enable()` registers only on request.
    var updateStartsAutomatically: Bool {
        if case .available = update { return service.status() == .enabled }
        return false
    }

    /// The handoff to the bundled engine: lock, save, stop, re-register, start, verify. One at a time, and not tied to the
    /// caller's task: leaving the Computers page doesn't cancel it halfway.
    func updateEngine() async {
        if let handoffTask { await handoffTask.value; return }
        switch update {
        case .available, .blocked: break
        default: return
        }
        guard let handoff, let candidateVersion else { return }
        update = .running(.locking)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await handoff.run(bundledVersion: candidateVersion, phase: { self.update = .running($0) },
                                            engineStopped: { self.client = nil })
            await self.finishHandoff(outcome)
        }
        handoffTask = task
        await task.value
        handoffTask = nil
    }

    /// Runs the update when it needs no consent.
    func continueUpdateIfAutomatic() async {
        if updateStartsAutomatically { await updateEngine() }
    }

    private func finishHandoff(_ outcome: EngineHandoffOutcome) async {
        switch outcome {
        case .completed(_, let resumed, let missing):
            update = .none
            if let fresh = try? await connector.connect() { adopt(fresh) }
            update = .completed(resumed: resumed, missing: missing)
        case .notNeeded(let reason):
            update = .none
            if let fresh = try? await connector.connect() { adopt(fresh) }
            if case .available = update { update = .blocked(reason) }
        case .blocked(let reason):
            update = .blocked(reason)
        case .failed(let reason):
            client = nil
            state = .failed(reason)
            update = .failed(reason)
        }
    }

    private static func embeddedCandidate() -> (version: String, build: String)? {
        let path = "Contents/Resources/SiloEngineDistribution/Silo Engine.app/Contents/Resources/engine-manifest.json"
        let url = Bundle.main.bundleURL.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(EngineManifest.self, from: data) else { return nil }
        return (manifest.engineVersion, manifest.engineBuild)
    }

    private struct EngineManifest: Decodable {
        let engineVersion: String
        let engineBuild: String
    }
}
