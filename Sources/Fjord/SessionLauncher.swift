import Foundation

// The model and effort a session may start with (an inbox action's, or asked for in words: "…with opus, high effort"), and
// how a started session is marked. The model and effort ride inside the signed first message and the session's plugin sets
// them for that session (a plugin too old to is sent none, and the log says so).

// MARK: - Settings an action may carry

enum ActionSettings {
    /// What the editor offers as a model.
    static let models = ["opus", "sonnet", "haiku"]
    /// What the editor offers as an effort.
    static let efforts = ["low", "medium", "high", "max"]
    /// What a session's plugin is asked to set with `/model` and `/effort`: the aliases (with the 1M suffix) or a full id, and
    /// the five efforts.
    static let acceptedModels = ["opus", "sonnet", "haiku", "fable"]
    static let acceptedEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// `value` as `/model` takes it: an alias, with or without `[1m]`, or a full `claude-…` id.
    static func cleanModel(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty, value.count <= 64 else { return nil }
        let base = value.hasSuffix("[1m]") ? String(value.dropLast(4)) : value
        if acceptedModels.contains(base) { return value }
        let id = base.dropFirst("claude-".count)
        guard base.hasPrefix("claude-"), !id.isEmpty, id.first?.isLetter == true || id.first?.isNumber == true,
              id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        return value
    }

    /// `value` if it is one of `allowed`; anything else (nothing, a value saved by a newer version) is the default.
    static func clean(_ value: String?, in allowed: [String]) -> String? {
        guard let value, allowed.contains(value) else { return nil }
        return value
    }
}

// MARK: - Model and effort for a session

/// The model and effort a new session should run with (nil: your Claude Code defaults). Values are allowlisted
/// (`ActionSettings`) before they go anywhere; they travel inside the signed message (`RelaySigner`) and the session's
/// plugin sets them for that session alone before its first prompt (`/model`, then `/effort`).
struct SessionSettings: Equatable, Sendable {
    var model: String?
    var effort: String?

    /// nil when neither value is one the plugin takes.
    init?(model: String?, effort: String?) {
        let model = ActionSettings.cleanModel(model), effort = ActionSettings.clean(effort, in: ActionSettings.acceptedEfforts)
        guard model != nil || effort != nil else { return nil }
        self.model = model
        self.effort = effort
    }
}
