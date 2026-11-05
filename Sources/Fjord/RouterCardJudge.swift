import Foundation

// Jev's typed calls for a local thread's form, read against your words (RouterFormReply.swift): one call, bounded in time,
// and a pick counted only when it is clear.

enum CardJudge {
    /// How long Jev gets for one call.
    static let timeout: Duration = .seconds(10)
    /// An option is picked, or a plan approved, only when Jev finds it at least this likely…
    static let sure = 0.7
    /// …and, for a pick, this much likelier than any other answer.
    static let lead = 0.25

    /// One call, given `timeout`: nil when it fails or takes longer.
    static func ask(_ ask: JevAsker?, _ questions: [String: JevClient.Question], state: [String: String],
                    timeout: Duration = timeout) async -> [String: JevClient.Answer]? {
        guard let ask else { return nil }
        return await withTaskGroup(of: [String: JevClient.Answer]?.self) { group in
            group.addTask { try? await ask(questions, state) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Whether Jev's pick says, clearly enough, that `option` is it.
    static func clearly(_ option: String, _ pick: JevClient.Choice?) -> Bool {
        guard let pick, let p = pick.probabilities[option] else { return false }
        let next = pick.probabilities.filter { $0.key != option }.values.max() ?? 0
        return p >= sure && p - next >= lead
    }
}
