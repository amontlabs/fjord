import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite(.serialized) struct EngineLauncherTests {
    @Test func inspectingComputersNeverRegistersTheAgent() async {
        let service = MockEngineAgentService(status: .notRegistered)
        let connector = MockEngineConnector([.failure(.notRunning)])
        let launcher = EngineLauncher(candidateVersion: "1.2.0", service: service, connector: connector)

        await launcher.inspect()

        #expect(launcher.state == .enableRequired)
        #expect(service.registerCalls == 0)
    }

    @Test func anAgentMacOSHasNeverSeenIsOneToEnableWhenItsPlistIsInTheBundle() {
        #expect(SystemEngineAgentService.status(.notFound, plistInBundle: true) == .notRegistered)
        #expect(SystemEngineAgentService.status(.notFound, plistInBundle: false) == .notFound)
        #expect(SystemEngineAgentService.status(.enabled, plistInBundle: true) == .enabled)
        #expect(SystemEngineAgentService.status(.requiresApproval, plistInBundle: true) == .requiresApproval)
    }

    @Test func explicitEnableRegistersThenConnectsTheSocketClient() async {
        let service = MockEngineAgentService(status: .notRegistered, statusAfterRegister: .enabled)
        let connector = MockEngineConnector([
            .failure(.notRunning),
            .success(connection(version: "1.2.0", build: "silo-abc")),
        ])
        let launcher = EngineLauncher(candidateVersion: "1.2.0", candidateBuild: "silo-abc",
                                      service: service, connector: connector)

        await launcher.enable()

        #expect(service.registerCalls == 1)
        #expect(launcher.isConnected)
        #expect(launcher.client != nil)
        #expect(launcher.state == .connected(version: "1.2.0", source: .fjordAgent))
    }

    @Test func approvalStateDoesNotRetryRegistrationAndOpensSettingsOnlyOnRequest() async {
        let service = MockEngineAgentService(status: .requiresApproval)
        let connector = MockEngineConnector([.failure(.notRunning)])
        let launcher = EngineLauncher(candidateVersion: "1.2.0", service: service, connector: connector)

        await launcher.inspect()
        #expect(launcher.state == .awaitingApproval)
        #expect(service.registerCalls == 0)
        #expect(service.openSettingsCalls == 0)

        launcher.openApprovalSettings()
        #expect(service.openSettingsCalls == 1)
    }

    @Test func approvalReturnedByRegisterIsSurfacedWithoutPolling() async {
        let service = MockEngineAgentService(status: .notRegistered, statusAfterRegister: .requiresApproval)
        let connector = MockEngineConnector([.failure(.notRunning)])
        let launcher = EngineLauncher(candidateVersion: "1.2.0", service: service, connector: connector)

        await launcher.enable()

        #expect(service.registerCalls == 1)
        #expect(connector.calls == 1)
        #expect(launcher.state == .awaitingApproval)
    }

    @Test func alreadyRunningNewerSharedEngineWinsWithoutRegisteringFjordAgent() async {
        let service = MockEngineAgentService(status: .notRegistered)
        let connector = MockEngineConnector([.success(connection(version: "2.0.0", build: "silo-new", source: .sharedEngine))])
        let launcher = EngineLauncher(candidateVersion: "1.2.0", service: service, connector: connector)

        await launcher.inspect()

        #expect(service.registerCalls == 0)
        #expect(launcher.state == .connected(version: "2.0.0", source: .sharedEngine))
    }

    @Test func newerBundledEngineIsOfferedAsAnUpdateWhileTheOldOneKeepsServing() async {
        let service = MockEngineAgentService(status: .notRegistered)
        let connector = MockEngineConnector([.success(connection(version: "1.1.0", build: "silo-old"))])
        let launcher = EngineLauncher(candidateVersion: "1.2.0", candidateBuild: "silo-new",
                                      service: service, connector: connector)

        await launcher.inspect()

        #expect(service.registerCalls == 0)
        #expect(launcher.client != nil)
        #expect(launcher.state == .connected(version: "1.1.0", source: .fjordAgent))
        #expect(launcher.update == .available(current: "1.1.0", bundled: "1.2.0"))
        // Fjord's agent isn't registered (Silo.app owns the engine): replacing it waits for the user.
        #expect(!launcher.updateStartsAutomatically)
    }

    @Test func sameVersionDifferentBuildIsRejected() async {
        let service = MockEngineAgentService(status: .notRegistered)
        let connector = MockEngineConnector([.success(connection(version: "1.2.0", build: "silo-previous"))])
        let launcher = EngineLauncher(candidateVersion: "1.2.0", candidateBuild: "silo-current",
                                      service: service, connector: connector)

        await launcher.inspect()

        #expect(service.registerCalls == 0)
        if case .updateBlocked = launcher.state {} else {
            Issue.record("Equal SemVer with a different engine build must be refused.")
        }
    }

    @Test func enabledAgentIsPolledUntilItsHandshakeAndVersionAreReady() async {
        let service = MockEngineAgentService(status: .enabled)
        let connector = MockEngineConnector([
            .failure(.notRunning),
            .failure(.notRunning),
            .success(connection(version: "1.2.0", build: "silo-current")),
        ])
        let launcher = EngineLauncher(candidateVersion: "1.2.0", candidateBuild: "silo-current",
                                      service: service, connector: connector,
                                      pollDelaysNanoseconds: [0, 0])

        await launcher.inspect()

        #expect(connector.calls == 3)
        #expect(launcher.isConnected)
    }

    @Test func semanticVersionOrderingUsesPrereleaseAndIgnoresBuildMetadata() {
        #expect(EngineVersion("1.2.3-alpha.2")! < EngineVersion("1.2.3-alpha.10")!)
        #expect(EngineVersion("1.2.3-rc.1")! < EngineVersion("1.2.3")!)
        #expect(EngineVersion("1.2.3+first") == EngineVersion("1.2.3+second"))
        #expect(EngineVersion("01.2.3") == nil)
    }

    private func connection(version: String, build: String?, source: EngineConnectionSource = .fjordAgent) -> EngineConnection {
        EngineConnection(client: UnavailableEngineClient(), version: version, build: build, source: source)
    }
}

@MainActor
private final class MockEngineAgentService: EngineAgentServicing {
    private(set) var currentStatus: EngineAgentStatus
    private let statusAfterRegister: EngineAgentStatus
    private(set) var registerCalls = 0
    private(set) var openSettingsCalls = 0

    init(status: EngineAgentStatus, statusAfterRegister: EngineAgentStatus = .enabled) {
        currentStatus = status
        self.statusAfterRegister = statusAfterRegister
    }

    func status() -> EngineAgentStatus { currentStatus }

    func register() throws {
        registerCalls += 1
        currentStatus = statusAfterRegister
    }

    func unregister() async throws { currentStatus = .notRegistered }

    func openSystemSettings() { openSettingsCalls += 1 }
}

@MainActor
private final class MockEngineConnector: EngineSocketConnecting {
    private var results: [Result<EngineConnection, EngineConnectorFailure>]
    private(set) var calls = 0

    init(_ results: [Result<EngineConnection, EngineConnectorFailure>]) { self.results = results }

    func connect() async throws -> EngineConnection {
        calls += 1
        guard !results.isEmpty else { throw EngineConnectorFailure.notRunning }
        switch results.removeFirst() {
        case .success(let connection): return connection
        case .failure(let error): throw error
        }
    }

}

private enum EngineConnectorFailure: Error { case notRunning }
