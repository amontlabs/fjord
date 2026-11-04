import Foundation

// The Router's own destinations (its runs), and what you told each session through it (the cards' replies): what the project
// decider's context and the brief read.

/// The Router's own runs as targets.
enum RouteLabel: String, CaseIterable {
    case changeFjord = "change_fjord", question
    static func isFjord(_ target: String) -> Bool { RouteLabel(rawValue: target) != nil }
}

extension RouterTools {
    /// The cards that wait on you: what a thread's context lists as waiting.
    static let waitsOnYou: Set<RouterCard.Kind> = [.question, .plan, .asks, .approval, .permission]

    /// The project decider's question to Jev (`RouterProjectDecider.jevRequest`), as measured.
    static let routeQuestion: [String: Any] = [
        "question": "Where does the user's `message` go?",
        "focus": "Decide about `message` alone; `earlier messages` only say what it refers to. A message addressed to a session (\"tell the CI one to…\", \"lcu: …\") goes to that existing session. A question about a session or about what is going on (\"is the CI one done?\") is `question`, not a message to the session. A message that starts a task none of the sessions has been doing goes to a new session in its project, even when that project has sessions; one that continues, corrects or answers a session's own work goes to that session.",
    ]
}

extension Store {
    /// Everything you sent each session, oldest first. A divided message gives each session its own part's words.
    func toldAll() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for entry in router.decisions where entry.generated != true {
            for place in entry.places {
                guard case .you(let text) = place.trigger, let session = place.links.sessions.last,
                      place.done.contains(where: \.sendsWords)
                else { continue }
                out[session, default: []].append(text)
            }
        }
        return out
    }

    /// What you last sent each session, and when: from the decision log, your messages that went to one (a divided message's
    /// part, its own words).
    func lastTold() -> [String: (text: String, at: Date)] {
        var out: [String: (text: String, at: Date)] = [:]
        for entry in router.decisions where entry.generated != true {
            for place in entry.places {
                guard case .you(let text) = place.trigger, let session = place.links.sessions.last,
                      place.done.contains(where: \.sendsWords)
                else { continue }
                out[session] = (text, entry.at)
            }
        }
        return out
    }
}
