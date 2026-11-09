import Foundation

// Banners for what happens to a T3 thread (docs/design/t3-port-plan.md, Step 14). Fjord is the only notifier on the Mac (T3
// desktop's own are turned off, Settings says so). A banner fires the moment the shell shows the change, never waiting for
// a model, and is keyed by what it is about (a request, a plan, a run) so it is posted once, kept in briefs.db (`notified`).

struct ThreadNotice: Equatable {
    enum Kind: String { case needsYou, finished, failed, usageLimit }

    var kind: Kind
    /// The told-once key: the request, the plan or the run the banner is about.
    var key: String
    var thread: String
    var project: String
    var title: String
    var body: String

    /// A banner's own heading.
    var heading: String {
        switch kind {
        case .needsYou: "needs you"
        case .finished: "finished"
        case .failed: "failed"
        case .usageLimit: "hit its usage limit"
        }
    }
}

enum ThreadNotices {
    /// How long after it happened a change still gets a banner: a relaunch or a reconnect doesn't tell an old story again.
    static let fresh: TimeInterval = 10 * 60

    /// "resumes by itself at 15:00" (or the plain fact, with no time).
    static func limitBody(_ t: AgentThread, resumesBySelf: Bool, calendar: Calendar = .current) -> String {
        guard let at = t.limitResetAt else { return resumesBySelf ? "It resumes by itself." : "It stopped on its usage limit." }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        let time = f.string(from: at)
        return resumesBySelf ? "It resumes by itself at \(time)." : "It stopped on its usage limit and can go on at \(time)."
    }

    /// What deserves a banner for a thread as the shell shows it now: pure. `request` is its held question, permission or plan
    /// when the projection is open. `sawRunning` is when the caller last saw the thread working: its background work can run
    /// long past the run's end, and the finish it makes is fresh as long as that seeing is (a relaunch, which saw nothing,
    /// keeps the old window on the run's end stamp alone).
    static func notices(_ t: AgentThread, request: ThreadRequest?, now: Date, sawRunning: Date? = nil) -> [ThreadNotice] {
        func make(_ kind: ThreadNotice.Kind, _ key: String, _ body: String) -> ThreadNotice {
            ThreadNotice(kind: kind, key: key, thread: t.id, project: t.projectID, title: t.title, body: body)
        }
        let at = Int(t.lastActivity.timeIntervalSince1970)
        let recent = now.timeIntervalSince(t.lastActivity) <= fresh
        if t.waitsForYou {
            guard recent else { return [] }
            if let request {
                switch request.body {
                case .plan(let markdown): return [make(.needsYou, "plan:\(request.id)", clip(markdown, "A plan to approve."))]
                case .approval(let kind, let prompt, _):
                    return [make(.needsYou, "ask:\(request.id)", prompt.isEmpty ? "It waits for a permission (\(kind))." : clip(prompt, ""))]
                case .question(let questions):
                    return [make(.needsYou, "ask:\(request.id)", clip(questions.map(\.question).joined(separator: "\n"), "It asks you a question."))]
                }
            }
            if let pending = t.pendingRequest {
                return [make(.needsYou, "ask:\(pending.id)", pending.isUserInput ? "It asks you a question." : "It waits for a permission.")]
            }
            return [make(.needsYou, "plan:\(t.id)@\(at)", "A plan to approve.")]
        }
        let seenWorking = sawRunning.map { now.timeIntervalSince($0) <= fresh } ?? false
        guard recent || seenWorking else { return [] }
        if t.usageLimit { return [make(.usageLimit, "limit:\(t.id)@\(at)", limitBody(t, resumesBySelf: !t.limitStopped))] }
        if t.status == .failed { return [make(.failed, "failed:\(t.id)@\(at)", clip(t.lastError ?? "", "It stopped with an error."))] }
        if t.finished, let ended = t.lastRunEndedAt, now.timeIntervalSince(ended) <= fresh || seenWorking {
            return [make(.finished, "done:\(t.id)@\(Int(ended.timeIntervalSince1970))", clip(t.latestMessage ?? "", "It finished."))]
        }
        return []
    }

    private static func clip(_ text: String, _ fallback: String) -> String {
        let one = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if one.isEmpty { return fallback }
        return one.count > 140 ? String(one.prefix(139)) + "…" : one
    }
}
