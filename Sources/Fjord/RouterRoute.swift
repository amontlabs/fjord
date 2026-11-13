import Foundation

// The Router's own destinations (its runs), and what you told each session through it: what the project
// decider's context reads.

/// The Router's own runs as targets.
enum RouteLabel: String, CaseIterable {
    case changeFjord = "change_fjord", question
    static func isFjord(_ target: String) -> Bool { RouteLabel(rawValue: target) != nil }
}

extension RouterTools {
    /// The project decider's question to Jev (`RouterProjectDecider.jevRequest`), as measured.
    static let routeQuestion: [String: Any] = [
        "question": "Which place does the user's `message` belong to: one of the existing threads, or a new thread in a project?",
        "focus": "Decide about `message` alone. A message addressed to a thread (\"tell the CI one to…\", \"lcu: …\") goes to that existing thread. A message that starts a task none of the threads has been doing goes to a new thread in its project, even when that project has threads; one that continues, corrects or answers a thread's own work goes to that thread.",
    ]
}

extension Store {
    /// Everything you sent each session, oldest first. 
    func toldAll() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for entry in router.decisions {
            guard case .you(let text) = entry.trigger, let session = entry.links.sessions.last,
                  entry.done.contains(where: \.sendsWords) else { continue }
            out[session, default: []].append(text)
        }
        return out
    }

    /// What you last sent each session, and when: from the decision log, your messages that went to one.
    func lastTold() -> [String: (text: String, at: Date)] {
        var out: [String: (text: String, at: Date)] = [:]
        for entry in router.decisions {
            guard case .you(let text) = entry.trigger, let session = entry.links.sessions.last,
                  entry.done.contains(where: \.sendsWords) else { continue }
            out[session] = (text, entry.at)
        }
        return out
    }
}
