import Foundation
@testable import Fjord

/// Synthetic T3 payloads: shapes copied from docs/design/t3-research/S1-spikes.md, text invented.
enum T3Fixture {
    static func thread(_ id: String, title: String = "Tidy the garden notes", status: String = "idle", project: String = "p1",
                       updatedAt: String = "2026-01-02T03:04:05.000Z", lastVisitedAt: String? = nil,
                       relationship: String? = nil, pending: T3JSON = .null, extra: [String: T3JSON] = [:]) -> T3JSON {
        var o: [String: T3JSON] = [
            "createdBy": "user", "creationSource": "web", "id": .string(id), "projectId": .string(project), "title": .string(title),
            "providerInstanceId": "claudeAgent", "modelSelection": ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"],
            "runtimeMode": "full-access", "interactionMode": "default", "branch": nil, "worktreePath": "/tmp/x", "pullRequests": [],
            "lineage": ["parentThreadId": nil, "relationshipToParent": relationship.map(T3JSON.string) ?? nil, "rootThreadId": .string(id)],
            "latestRunId": nil, "activeRunId": nil, "status": .string(status), "pendingRuntimeRequest": pending,
            "latestVisibleMessage": ["id": "m0", "role": "assistant", "text": "Done with the beds.", "updatedAt": .string(updatedAt)],
            "latestUserMessageAt": .string(updatedAt), "hasActionableProposedPlan": false, "pendingBackgroundTasks": [],
            "itemCount": 3, "visibleItemCount": 3, "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": .string(updatedAt),
            "archivedAt": nil, "settledOverride": nil, "settledAt": nil, "deletedAt": nil, "tags": ["garden"],
        ]
        if let lastVisitedAt { o["lastVisitedAt"] = .string(lastVisitedAt) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func project(_ id: String, title: String = "Garden") -> T3JSON {
        ["id": .string(id), "title": .string(title), "workspaceRoot": "/tmp/garden", "repositoryIdentity": ["owner": "acme", "name": "garden"],
         "scripts": [], "pinnedAt": nil, "archivedAt": nil, "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z"]
    }

    static func snapshot(threads: [T3JSON], projects: [T3JSON] = [], sequence: Int = 100) -> T3JSON {
        ["kind": "snapshot", "snapshot": ["schemaVersion": 2, "snapshotSequence": .number(Double(sequence)), "threads": .array(threads),
                                          "archivedThreads": [], "projects": .array(projects)]]
    }

    static func run(_ id: String, status: String, queuePosition: Int? = nil) -> T3JSON {
        ["id": .string(id), "threadId": "t1", "ordinal": 1, "status": .string(status), "queuePosition": queuePosition.map { .number(Double($0)) } ?? nil,
         "userMessageId": "um1", "requestedAt": "2026-01-02T03:04:05.000Z", "startedAt": nil, "completedAt": nil]
    }

    static func message(_ id: String, role: String = "user", text: String) -> T3JSON {
        ["createdBy": .string(role == "user" ? "user" : "agent"), "creationSource": "web", "id": .string(id), "threadId": "t1", "runId": "r1",
         "role": .string(role), "text": .string(text), "attachments": [], "streaming": false,
         "createdAt": "2026-01-02T03:04:05.000Z", "updatedAt": "2026-01-02T03:04:05.000Z"]
    }

    static func item(_ id: String, type: String, ordinal: Int, status: String = "completed", _ extra: [String: T3JSON] = [:]) -> T3JSON {
        var o: [String: T3JSON] = ["id": .string(id), "threadId": "t1", "runId": "r1", "nodeId": "n1", "ordinal": .number(Double(ordinal)),
                                   "status": .string(status), "title": nil, "updatedAt": "2026-01-02T03:04:06.000Z", "type": .string(type)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func event(_ type: String, _ seq: Int, payload: T3JSON, thread: String = "t1") -> T3JSON {
        ["kind": "event", "sequence": .number(Double(seq)),
         "event": ["id": .string("e\(seq)"), "threadId": .string(thread), "runId": "r1", "occurredAt": "2026-01-02T03:04:07.000Z", "type": .string(type), "payload": payload]]
    }

    static func projection() -> T3JSON {
        ["kind": "snapshot", "snapshotSequence": 500, "projection": [
            "thread": thread("t1", status: "running"), "runs": [run("r1", status: "running")],
            "attempts": [["id": "a1", "runId": "r1", "status": "running"]], "nodes": [], "subagents": [],
            "providerSessions": [], "providerThreads": [], "providerTurns": [], "runtimeRequests": [],
            "messages": [message("um1", text: "Please sort the seed packets.")], "plans": [],
            "turnItems": [item("i1", type: "user_message", ordinal: 1, ["messageId": "um1", "text": "Please sort the seed packets."])],
            "checkpointScopes": [], "checkpoints": [], "contextHandoffs": [], "contextTransfers": [], "visibleTurnItems": [],
            "updatedAt": "2026-01-02T03:04:05.000Z"]]
    }
}
