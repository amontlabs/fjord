import Foundation

/// What a computer's agent tools look like to a person. Silo still reports Node.js and Claude Code; Fjord names neither
/// (the T3 server joins them in the port plan's step 19).
enum AgentToolsAdvice {
    static func needsSetup(_ status: SiloWireAgentToolsStatus) -> Bool { status.state != .ready }

    static func actionTitle(_ status: SiloWireAgentToolsStatus) -> String {
        status.state == .outdated ? "Update" : "Set up"
    }

    static func headline(_ status: SiloWireAgentToolsStatus) -> String {
        switch status.state {
        case .ready: "Ready"
        case .missing: "Missing"
        case .outdated: "Update available"
        }
    }

    static func detail(_ status: SiloWireAgentToolsStatus) -> String {
        switch status.state {
        case .ready:
            return "The agent tools are installed in this computer."
        case .missing:
            return "The agent tools aren't installed in this computer."
        case .outdated:
            return "The agent tools in this computer can be updated."
        }
    }
}

enum AgentToolsFailure: LocalizedError, Equatable {
    case setupFailed(String)
    case stillNotReady(String)

    var errorDescription: String? {
        switch self {
        case .setupFailed(let reason): "Setting up the agent tools failed: \(reason)"
        case .stillNotReady(let name): "\(name)'s agent tools still aren't ready after the setup finished. Check its activity log in Computers."
        }
    }
}

/// Checks a computer's agent tools and, when asked, sets them up as an engine job.
@MainActor
struct AgentToolsSetup {
    let engine: any EngineClient
    var pollInterval: Duration = .milliseconds(250)
    var pollLimit = 8_000

    /// Nil when the engine cannot inspect the computer (a stopped Linux computer).
    func status(_ target: GuestReference) async throws -> SiloWireAgentToolsStatus? {
        let status: SiloWireDesktopStatus = try await engine.invoke(SiloGeneratedMethods.desktopStatus(
            SiloWireComputerTargetParams(computerId: target.computerId, deviceId: target.deviceId)))
        return status.agentTools
    }

    /// Runs `setup-agent-tools` and waits for the job; returns the status afterwards.
    @discardableResult
    func setUp(_ target: GuestReference, computerName: String,
               progress: @MainActor (String) async -> Void = { _ in }) async throws -> SiloWireAgentToolsStatus? {
        await progress("Setting up the agent tools in \(computerName)")
        let started: SiloWireJobStartResult = try await engine.invoke(SiloGeneratedMethods.desktopAction(
            SiloWireDesktopActionParams(action: .setupAgentTools, computerId: target.computerId, deviceId: target.deviceId)))
        let began = Date()
        for _ in 0..<pollLimit {
            let snapshot = try await engine.operationsJobGet(jobId: started.jobId, deviceId: target.deviceId)
            if snapshot.state == .finished {
                if let error = snapshot.outcome?.error { throw AgentToolsFailure.setupFailed(error.userMessage) }
                try? await engine.operationsJobAcknowledge(jobId: started.jobId, deviceId: target.deviceId)
                return try await status(target)
            }
            let seconds = Int(Date().timeIntervalSince(began))
            await progress("Setting up the agent tools in \(computerName) (\(seconds) s)")
            try await Task.sleep(for: pollInterval)
        }
        throw AgentToolsFailure.setupFailed("The job didn't finish in time.")
    }
}
