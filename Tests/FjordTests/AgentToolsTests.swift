import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite(.serialized) struct AgentToolsTests {
    private let computerID = MockEngineClient.linuxID
    private var target: GuestReference { GuestReference(deviceId: nil, computerId: computerID) }

    private func engine(_ state: SiloWireAgentToolsState) -> MockEngineClient {
        let engine = MockEngineClient()
        engine.mockAgentTools[computerID] = MockEngineClient.agentTools(state)
        return engine
    }

    @Test func statusWordsNameTheStateAndTheButton() {
        let missing = MockEngineClient.agentTools(.missing)
        #expect(AgentToolsAdvice.actionTitle(missing) == "Set up")
        #expect(AgentToolsAdvice.detail(missing) == "The agent tools aren't installed in this computer.")
        let outdated = MockEngineClient.agentTools(.outdated)
        #expect(AgentToolsAdvice.actionTitle(outdated) == "Update")
        #expect(AgentToolsAdvice.headline(outdated) == "Update available")
        #expect(AgentToolsAdvice.detail(outdated) == "The agent tools in this computer can be updated.")
        #expect(!AgentToolsAdvice.needsSetup(MockEngineClient.readyAgentTools))
    }

    @Test func computersShowsTheStatusAndSetUpRunsTheActionAsAJob() async {
        let engine = engine(.missing)
        let model = ComputersModel(client: engine, initialInventory: engine.inventory)
        await model.loadAgentTools(target)
        #expect(model.agentTools(for: target)?.state == .missing)

        await model.setUpAgentTools(target, computerName: "linux-1")
        #expect(engine.agentToolsSetupRequests == [computerID])
        #expect(model.agentTools(for: target)?.state == .ready)
        #expect(model.agentToolsSetupMessage[target.key] == nil)
        #expect(model.agentToolsError[target.key] == nil)
    }

    @Test func updateRunsTheSameActionForOutdatedTools() async {
        let engine = engine(.outdated)
        let model = ComputersModel(client: engine, initialInventory: engine.inventory)
        await model.loadAgentTools(target)
        #expect(model.agentTools(for: target).map(AgentToolsAdvice.actionTitle) == "Update")
        await model.setUpAgentTools(target, computerName: "linux-1")
        #expect(model.agentTools(for: target)?.state == .ready)
    }

    @Test func aFailedSetupKeepsTheStatusAndSaysWhy() async {
        let engine = engine(.missing)
        engine.nextJobFailure = OperationJobError(code: "internal", message: "download failed")
        let model = ComputersModel(client: engine, initialInventory: engine.inventory)
        await model.loadAgentTools(target)
        await model.setUpAgentTools(target, computerName: "linux-1")
        #expect(model.agentTools(for: target)?.state == .missing)
        #expect(model.agentToolsError[target.key]?.contains("download failed") == true)
    }

    @Test func setUpReportsProgressAndEndsReady() async throws {
        let engine = engine(.missing)
        var messages: [String] = []
        try await AgentToolsSetup(engine: engine).setUp(target, computerName: "linux-1") { messages.append($0) }
        #expect(engine.agentToolsSetupRequests == [computerID])
        #expect(messages.first == "Setting up the agent tools in linux-1")
        #expect(try await AgentToolsSetup(engine: engine).status(target)?.state == .ready)
    }

    @Test func credentialAccessDeniedHasAClearMessage() {
        let expected = "After this update, Silo's engine needs your permission to use its saved credentials. Use Allow access on the Computers page or in Settings."
        #expect(EngineErrorText.message(code: "credential_access_denied", fallback: "internal") == expected)
        #expect(OperationJobError(code: "credential_access_denied", message: "x").userMessage == expected)
        #expect(EngineClientError.coded(code: "credential_access_denied", message: "x").errorDescription == expected)
        #expect(EngineErrorText.known.contains("credential_access_denied"))
        #expect(SiloWireErrorCode.credentialAccessDenied.rawValue == "credential_access_denied")
    }
}
