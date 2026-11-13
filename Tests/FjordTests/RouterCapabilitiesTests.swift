import Foundation
import Testing
@testable import Fjord

/// The Router's capability list is the one source of the run's tools and its role.
@MainActor
struct RouterCapabilitiesTests {

    /// The run has no tool for a card, a project or a session.
    @Test func theRunHasNoCardOrSessionTools() {
        let tools = RouterCapability.toolNames(.changeFjord, triage: true)
        for gone in ["mark_seen", "archive_cards", "reopen_card", "mute_project", "stop_session"] { #expect(!tools.contains(gone), "\(gone)") }
        // The Router page (the role says it is read through `board`) is readable in a change run too, as in a question run.
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
            #expect(question.contains("the Router page's lines, working sessions, settings") && question.contains("the inbox, categories") == triage)
        }
        #expect(FjordTools.triageNames == RouterCapability.triageToolNames && FjordTools.triageNames.contains("mark_entries"))
    }

    @Test func toolSetsAreTheCapabilitiesTools() {
        let readNames = Set(FjordTools.tools.filter(\.reads).map(\.name))
        for triage in [true, false] {
            let all = FjordTools.names.subtracting(triage ? [] : FjordTools.triageNames)
            let reads = readNames.union(["board", "search_threads", "read_thread"]).subtracting(triage ? [] : FjordTools.triageNames)
            #expect(RouterRun.toolNames(.changeFjord, triage: triage) == all.union(["board", "answer", "search_threads", "read_thread"]))
            #expect(RouterRun.toolNames(.question, triage: triage) == reads)
        }
    }

    @Test func everyToolIsInACapabilityAndEveryCapabilityToolExists() {
        let named = Set(RouterCapability.all.flatMap(\.tools))
        #expect(named.subtracting(["board", "answer", "search_threads", "read_thread"]).isSubset(of: FjordTools.names))
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
            #expect(on.contains("The Router page lists every thread") && off.contains("The Router page lists every thread"))
            #expect(on.contains("`mark_entries`") && !off.contains("`mark_entries`"))
        }
    }
}
