import Foundation

// The one Haiku call the briefs make (RouterBriefEngine.swift), and how the Router writes to you (Settings), which they follow.

extension Store {
    /// How the Router writes to you: yours, else the default.
    var routerStyle: String { router.style ?? RouterStyle.defaultText }

    /// Empty, or the default's words, is the default.
    func setRouterStyle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let style: String? = trimmed.isEmpty || trimmed == RouterStyle.defaultText ? nil : trimmed
        if router.style != style { router.style = style }
    }
}

/// Haiku through Claude Code: no tools, no settings, no session kept. Tests and shots answer for it (`Runner`).
enum RouterBriefer {
    /// Given a schema, the answer is that JSON.
    typealias Runner = @Sendable (_ system: String, _ context: String, _ schema: String?) async throws -> String
    static let model = "claude-haiku-5-5"
    static let timeout: TimeInterval = 30

    @MainActor static func haiku(store: Store, model: String = model, timeout: TimeInterval = timeout) -> Runner {
        let find = store.routerClaudeBinary ?? { RouterStatus.findDefault() }
        let home = store.routerFiles?.routerHome
        return { system, context, schema in
            guard let binary = find(), let home else { throw RouterTools.Failure("Claude Code wasn't found") }
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let typed = schema.map { ["--json-schema", $0] } ?? []
            let output = try await OneShot.run(binary, ["-p", "--model", model, "--tools", "", "--setting-sources", "", "--strict-mcp-config",
                                                        "--no-session-persistence", "--output-format", "json"] + typed + ["--system-prompt", system],
                                               cwd: home, input: Data(context.utf8), timeout: timeout)
            if let parsed = try? ClaudePrint.parse(output) { ModelUsageLog.shared?.record(role: .brief, model: model, parsed.usage) }
            else if let obj = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any], let u = obj["usage"] as? [String: Any] {
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                ModelUsageLog.shared?.record(role: .brief, model: model, ModelUsage(
                    inputTokens: n("input_tokens"), outputTokens: n("output_tokens"), cacheReadTokens: n("cache_read_input_tokens"),
                    cacheCreationTokens: n("cache_creation_input_tokens"), costUSD: (obj["total_cost_usd"] as? NSNumber)?.doubleValue))
            }
            // The typed answer as JSON; without it (an older Claude Code), its text, which `read` checks all the same.
            if schema != nil, let obj = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any],
               obj["is_error"] as? Bool != true, let typed = obj["structured_output"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: typed) {
                return String(decoding: data, as: UTF8.self)
            }
            return try OneShot.result(output)
        }
    }
}
