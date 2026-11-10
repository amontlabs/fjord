import Foundation
import Testing
@testable import Fjord

/// Not a test of behaviour: with `FJORD_BRIEF_EVAL_DIR` set, it writes the exact system prompts and inputs the brief sends for the
/// boards in `<dir>/scenario-*.json` (threads exported from a T3 database copy), so the prompts can be run and scored outside the app.
/// Once `<dir>/<scenario>/<project>.answer.json` (a project call's output) exist it also writes the lead's input from them, and
/// with `lead.answer.json` the lead as the app would show it. See docs/design/brief-rebuild.md.
@MainActor @Suite struct BriefEvalDump {
    private struct Scenario: Decodable {
        struct Thread: Decodable {
            var id: String, project: String, projectId: String, title: String
            var running: Bool, settled: Bool
            var snoozedUntil: Double?, created: Double?, lastActivity: Double, activity: Double
            var lastRunEnded: Double?, latestMessage: String?, lastUserText: String?, lastUserMessage: Double?
            var prs: [PR]
        }
        struct PR: Decodable { var url: String, number: Int }
        var now: Double
        var threads: [Thread]
        var prStates: [String: String]
    }

    private func date(_ t: Double?) -> Date? { t.map { Date(timeIntervalSince1970: $0) } }

    @Test func dumpsTheBriefInputs() throws {
        guard let dir = ProcessInfo.processInfo.environment["FJORD_BRIEF_EVAL_DIR"] else { return }
        let root = URL(fileURLWithPath: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("scenario-") && $0.hasSuffix(".json") }.sorted()
        for file in files {
            let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: root.appendingPathComponent(file)))
            let name = String(file.dropFirst("scenario-".count).dropLast(".json".count))
            let out = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let now = Date(timeIntervalSince1970: scenario.now)
            var names: [String: String] = [:]
            let threads = scenario.threads.map { t -> AgentThread in
                names[t.projectId] = t.project
                var a = AgentThread(id: t.id, projectID: t.projectId, title: t.title, folder: "/p/" + t.project,
                                    status: t.running ? .running : .completed, settled: t.settled, snoozedUntil: date(t.snoozedUntil),
                                    lastActivity: date(t.lastActivity)!, activityAt: date(t.activity)!, lastUserMessage: date(t.lastUserMessage),
                                    lastRunEndedAt: date(t.lastRunEnded), createdAt: date(t.created), latestMessage: t.latestMessage,
                                    lastUserText: t.lastUserText)
                a.pullRequests = t.prs.map { T3PullRequest(json: T3JSON.parse(#"{"url":"\#($0.url)","number":\#($0.number)}"#)!) }
                return a
            }
            var text: [String: [PullRequestRef]] = [:]
            for t in threads where T3BriefSource.listed(t, now: now) {
                let linked = Set(t.pullRequests.flatMap { PullRequestRef.extract(from: $0.url) })
                let extra = PullRequestRef.extract(from: t.latestMessage ?? "").filter { !linked.contains($0) }
                if !extra.isEmpty { text[t.id] = extra }
            }
            let states = scenario.prStates.compactMapValues { PRState(rawValue: $0) }
            let boards = T3BriefSource.boards(threads: threads, requests: [:], prStates: states, textPRs: text, now: now)
            var docs: [String: BriefDoc] = [:]
            func write(_ name: String, _ s: String) throws { try s.write(to: out.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            for (project, board) in boards.sorted(by: { $0.key < $1.key }) {
                var doc = BriefDoc(project: project)
                RouterBriefEngine.apply(board, to: &doc)
                let label = names[project] ?? project
                try write("\(label).system.txt", RouterStyle.prompt(RouterBriefEngine.rules, style: RouterStyle.defaultText))
                try write("\(label).context.txt", RouterBriefEngine.context(doc, now: scenario.now))
                if let raw = try? String(contentsOf: out.appendingPathComponent("\(label).answer.json"), encoding: .utf8),
                   let answer = try? BriefDoc.parse(raw) {
                    doc.prose = doc.checked(answer, at: scenario.now)
                    let json = try JSONEncoder().encode(doc.prose)
                    try write("\(label).checked.json", String(decoding: json, as: UTF8.self))
                    RouterBriefEngine.apply(board, to: &doc)
                }
                docs[project] = doc
            }
            try write("lead.system.txt", RouterStyle.prompt(RouterBriefEngine.leadRules, style: RouterStyle.defaultText))
            try write("lead.context.txt", "<session-content untrusted=\"true\">\n" + RouterBriefEngine.leadContext(docs, now: scenario.now) + "\n</session-content>")
            if let raw = try? String(contentsOf: out.appendingPathComponent("lead.answer.json"), encoding: .utf8),
               let a = raw.firstIndex(of: "{"), let b = raw.lastIndex(of: "}"),
               let lead = try? JSONDecoder().decode(GeneralBrief.self, from: Data(raw[a...b].utf8)) {
                let checked = RouterBriefEngine.checkedLead(lead, docs: docs, at: scenario.now)
                try write("lead.checked.json", String(decoding: try JSONEncoder().encode(checked), as: UTF8.self))
            }
            try write("projects.json", String(decoding: try JSONEncoder().encode(names), as: UTF8.self))
        }
    }
}
