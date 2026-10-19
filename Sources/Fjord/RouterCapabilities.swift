import Foundation

// What Fjord's Router can do by itself, with no session: one list. The routing classifier's text (the `change_fjord`
// criteria and `gate_setting`), each run's tool sets and the run's role (the sentences about what it can do, and the
// paragraph for each intent) are all made from it, so a capability added here is named, served and explained everywhere,
// and can't be added in one place and missed in the others.

struct RouterCapability: Equatable {
    var id: String
    /// The run intent that uses it.
    var intent: RouterRun.Intent
    /// What it does, as the routing classifier is told (nil for a capability that only reads, which routing doesn't name).
    var outcome: String?
    var tools: [String]
    /// What the run's role says about it, in the words its tools use.
    var roleSentence: String?
    /// Out of the run's tools, role and text when Triage is off.
    var needsTriage: Bool = false
    /// What a change run changes with it, as a noun phrase for "You change …".
    var scope: String? = nil
    /// What a question run can read through it, as a noun phrase.
    var reads: String? = nil
    /// How the change run goes about it (what to read first, what not to do), added to its role.
    var guidance: String? = nil
}

extension RouterCapability {
    static let all: [RouterCapability] = [
        .init(id: "settings", intent: .changeFjord,
              outcome: "turn a setting on or off, including its notifications",
              tools: ["get_settings", "set_setting"], roleSentence: nil, scope: "Fjord's settings"),
        .init(id: "triage-setup", intent: .changeFjord,
              outcome: "change Triage's inbox categories, rules or groups",
              tools: ["list_categories", "get_category", "create_category", "update_category", "delete_category",
                      "reorder_categories", "list_groups", "create_group", "update_group", "delete_group", "list_known"],
              roleSentence: nil, needsTriage: true, scope: "Triage's inbox categories and groups",
              guidance: "Before changing a category, read it (the category's JSON; list_known for repos and people). Add a category's "
                  + "actions only when asked, and never a GitHub comment on your own."),
        // The next three are only words the routing classifier is told (measured as they are, `Fixtures/router-capabilities-parity.json`):
        // a message like "I'll do the theme one myself" reaches the Router for its dispatcher to act on a card, so no tool of the
        // run does it.
        .init(id: "mark-seen", intent: .changeFjord,
              outcome: "mark a Router card the user has seen or read as seen (a worth-a-look card: \"seen the docs\", \"got it\", \"I read the headlines\")",
              tools: [], roleSentence: nil),
        .init(id: "mark-inbox", intent: .changeFjord,
              outcome: "mark things in the inbox as done or seen",
              tools: ["mark_entries", "list_inbox", "explain_entry"],
              roleSentence: "Triage's inbox things are GitHub PRs, issues and workflows: you mark those with `mark_entries` (`archived` archives "
                  + "them; also seen, unread, restore).",
              needsTriage: true, scope: "Triage's inbox (what is archived or seen)"),
        .init(id: "archive-cards", intent: .changeFjord,
              outcome: "archive a Router card the user will handle themselves or doesn't need (\"I'll do the theme one myself\", \"archive the login card\")",
              tools: [], roleSentence: nil),
        .init(id: "reopen-card", intent: .changeFjord,
              outcome: "reopen a Router card the user archived (\"reopen the docs card\")",
              tools: [], roleSentence: nil),
        // The Brief and the cards are read before a change too ("the docs card" is named by what the board shows).
        .init(id: "change-board", intent: .changeFjord, outcome: nil, tools: ["board"], roleSentence: nil),
        .init(id: "question-board", intent: .question, outcome: nil, tools: ["board", "get_settings"],
              roleSentence: "The Brief is the short written summary of what needs the user, per project: you can read it through `board`.",
              reads: "cards, working sessions, the Brief, settings"),
        .init(id: "question-triage", intent: .question, outcome: nil,
              tools: ["list_categories", "get_category", "list_groups", "list_inbox", "explain_entry", "list_known"],
              roleSentence: nil, needsTriage: true, reads: "the inbox, categories"),
    ]

    /// The capabilities a run of `intent` has, without Triage's when it is off.
    static func available(_ intent: RouterRun.Intent, triage: Bool) -> [RouterCapability] {
        all.filter { $0.intent == intent && (triage || !$0.needsTriage) }
    }

    static func toolNames(_ intent: RouterRun.Intent, triage: Bool) -> Set<String> {
        Set(available(intent, triage: triage).flatMap(\.tools))
    }

    /// Triage's own tools: the ones of the capabilities that need it, offered only while it is on.
    static var triageToolNames: Set<String> {
        Set(all.filter(\.needsTriage).flatMap(\.tools))
    }

    /// The role's sentences about what the Router can do, each with a leading space; every run knows them all, whatever
    /// its tools, so "I've seen it" in a question run is understood too.
    static func roleSentences(triage: Bool) -> String {
        all.filter { triage || !$0.needsTriage }.compactMap(\.roleSentence).map { " " + $0 }.joined()
    }

    /// A list as prose: "a", "a and b", "a, b and c".
    static func prose(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// The change run's role paragraph, made from the capabilities it has.
    static func changeRole(triage: Bool) -> String {
        let scopes = prose(available(.changeFjord, triage: triage).compactMap(\.scope))
        let how = available(.changeFjord, triage: triage).compactMap(\.guidance).map { " " + $0 }.joined()
        return "You change " + scopes + " as the user asks. Read before you change and change what was asked, no more. A change to "
            + (triage ? "settings or Triage" : "settings") + " applies at once and the user gets a card with Open and Revert, so don't repeat it back; if one is "
            + "refused, say the reason in a line. Some changes wait for the user's Apply instead (the tool's answer says so): say in a "
            + "line that it waits for them." + how + " If nothing needs changing, `done` is \"nothing changed\"."
    }

    /// The question run's role paragraph.
    static func questionRole(triage: Bool) -> String {
        let about = prose(available(.question, triage: triage).compactMap(\.reads))
        return "You answer a question about the current state (" + about + ") from the state given and your read tools. You change "
            + "nothing; you have no tool that does. `done` is \"answered\"."
    }

    /// What the routing classifier is told Fjord does itself. It is not told whether Triage is on (the routing questions are
    /// built before the run, and a Triage request with Triage off is refused in the run with a reason), so the full list.
    static var outcomes: String {
        all.filter { $0.intent == .changeFjord }.compactMap(\.outcome).joined(separator: "; ")
    }

    static let notThese = "Not asking a session to build or change code, and not a message for a session to act on (an instruction "
        + "or a reply addressed to it, even one that mentions what the user has seen)"

    /// The `change_fjord` criteria.
    static var changeFjordCriteria: String {
        "Fjord itself does something for the user, without any session: " + outcomes + ". " + notThese
    }

    /// The `gate_setting` question.
    static var settingQuestion: String {
        "Does `message` ask Fjord itself to do something for the user, without any session: " + outcomes
            + "? Not code to be written, and not a message for a session to do or answer something."
    }
}
