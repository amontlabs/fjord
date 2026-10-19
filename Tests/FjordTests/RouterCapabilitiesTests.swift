import Foundation
import Testing
@testable import Fjord

/// The Router's capability list is the one source of the routing text, the run's tools and its role.
@MainActor
struct RouterCapabilitiesTests {
    /// The two texts as `capabilities-o` measured them (Fixtures/router-capabilities-parity.json, made by
    /// `python3 evals/router/parity.py capabilities`), and spelled out here.
    @Test func routingTextIsTheMeasuredWording() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/router-capabilities-parity.json")
        let fixture = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        let change = "Fjord itself does something for the user, without any session: turn a setting on or off, including its notifications; change Triage's inbox categories, rules or groups; mark a Router card the user has seen or read as seen (a worth-a-look card: \"seen the docs\", \"got it\", \"I read the headlines\"); mark things in the inbox as done or seen; archive a Router card the user will handle themselves or doesn't need (\"I'll do the theme one myself\", \"archive the login card\"); reopen a Router card the user archived (\"reopen the docs card\"). Not asking a session to build or change code, and not a message for a session to act on (an instruction or a reply addressed to it, even one that mentions what the user has seen)"
        let gate = "Does `message` ask Fjord itself to do something for the user, without any session: turn a setting on or off, including its notifications; change Triage's inbox categories, rules or groups; mark a Router card the user has seen or read as seen (a worth-a-look card: \"seen the docs\", \"got it\", \"I read the headlines\"); mark things in the inbox as done or seen; archive a Router card the user will handle themselves or doesn't need (\"I'll do the theme one myself\", \"archive the login card\"); reopen a Router card the user archived (\"reopen the docs card\")? Not code to be written, and not a message for a session to do or answer something."
        #expect(RouterCapability.changeFjordCriteria == change && fixture["change_fjord"] == change)
        #expect(RouterCapability.settingQuestion == gate && fixture["gate_setting"] == gate)
        #expect(RouterTools.intentCriteria.first { $0.name == "change_fjord" }?.criteria == change)
        let shown = gate.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "'", with: "\\'")
        #expect(String(describing: RouterTools.gates["gate_setting"]).contains(shown))
    }

    /// The routing text keeps the card-action clauses it was measured with (the next stage decides about them); the run itself
    /// has no tool for a card, a project or a session.
    @Test func theRoutingTextKeepsTheMeasuredCardClausesWhileTheRunHasNoCardTools() {
        let text = RouterCapability.changeFjordCriteria
        #expect(text.contains("archive a Router card") && text.contains("reopen a Router card") && text.contains("as seen"))
        #expect(!text.contains("mute or unmute a project") && !text.contains("stop a running session"))
        let tools = RouterCapability.toolNames(.changeFjord, triage: true)
        for gone in ["mark_seen", "archive_cards", "reopen_card", "mute_project", "stop_session"] { #expect(!tools.contains(gone), "\(gone)") }
        // The Brief (the role says it is read through `board`) is readable in a change run too, as in a question run.
        #expect(tools.contains("board"))
        let specs = Set(RouterTools.specs.compactMap { $0["name"] as? String })
        for gone in ["mark_seen", "archive_cards", "reopen_card", "mute_project", "stop_session"] { #expect(!specs.contains(gone), "\(gone)") }
        for intent in RouterRun.Intent.allCases {
            let role = RouterRun.role(intent)
            for gone in ["mark_seen", "archive_cards", "reopen_card", "mute_project", "stop_session", "canMarkSeen"] { #expect(!role.contains(gone), "\(gone)") }
        }
    }

    @Test func theRolesAreMadeFromTheCapabilities() {
        for triage in [true, false] {
            let change = RouterRun.role(.changeFjord, triage: triage)
            for capability in RouterCapability.available(.changeFjord, triage: triage) {
                #expect(capability.scope.map(change.contains) ?? true, "\(capability.id) is in the change role")
                #expect(capability.guidance.map(change.contains) ?? true)
            }
            #expect(change.contains("Triage's inbox categories") == triage)
            let question = RouterRun.role(.question, triage: triage)
            #expect(question.contains("cards, working sessions, the Brief, settings") && question.contains("the inbox, categories") == triage)
        }
        #expect(FjordTools.triageNames == RouterCapability.triageToolNames && FjordTools.triageNames.contains("mark_entries"))
    }

    @Test func toolSetsAreTheCapabilitiesTools() {
        let readNames = Set(FjordTools.tools.filter(\.reads).map(\.name))
        for triage in [true, false] {
            let all = FjordTools.names.subtracting(triage ? [] : FjordTools.triageNames)
            let reads = readNames.union(["board"]).subtracting(triage ? [] : FjordTools.triageNames)
            #expect(RouterRun.toolNames(.changeFjord, triage: triage) == all.union(["board"]))
            #expect(RouterRun.toolNames(.question, triage: triage) == reads)
        }
    }

    @Test func everyToolIsInACapabilityAndEveryCapabilityToolExists() {
        let named = Set(RouterCapability.all.flatMap(\.tools))
        #expect(named.subtracting(["board"]).isSubset(of: FjordTools.names))
        #expect(FjordTools.names.isSubset(of: named))
        #expect(named.isSubset(of: Set(RouterTools.specs.compactMap { $0["name"] as? String })))
        // The tools of Triage's capabilities are FjordTools' Triage tools, and no other is.
        let triage = Set(RouterCapability.all.filter(\.needsTriage).flatMap(\.tools))
        let plain = Set(RouterCapability.all.filter { !$0.needsTriage }.flatMap(\.tools))
        #expect(triage.isDisjoint(with: plain))
        #expect(triage == FjordTools.triageNames)
    }

    @Test func roleNamesWhatTheRouterCanDo() {
        for intent in RouterRun.Intent.allCases {
            let on = RouterRun.role(intent, triage: true), off = RouterRun.role(intent, triage: false)
            #expect(on.contains("The Brief is the short written summary") && off.contains("The Brief is the short written summary"))
            #expect(on.contains("`mark_entries`") && !off.contains("`mark_entries`"))
        }
    }
}
