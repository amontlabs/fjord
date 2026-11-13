import Foundation

// What code alone says of a T3 thread for the Router v2 page (docs/design/router-v2/IMPLEMENTATION.md 1.3): its state, its
// line and since when, whether it has a line at all, and the fingerprint its verdict is kept under. Pure functions of T3's
// shell row (`AgentThread`) and, when held, the thread's projection read (`RouterDetail`): no formatter, no regex, dates
// parsed once per row by `AgentThread`.

/// A thread's code state: the page's state, its code line and the time its age counts from, before any model.
struct RouterCodeState: Equatable {
    /// What the verdict engine is asked for this state.
    enum Wants: Equatable {
        /// Nothing: Working, Stopped, Sent, a run you stopped.
        case nothing
        /// A finished turn: `needs_you` or `done`, worth a look or quiet, the line.
        case finished
        /// An ask T3 holds (question, form, plan, permission): the line only.
        case ask
    }

    var state: RouterThread.State
    var line: String
    /// The line is a command (a permission's).
    var mono = false
    var since: Date
    /// Paused at a usage limit it resumes from by itself: Working, the dots still.
    var paused = false
    /// Waits on you, but the projection that says for what hasn't come yet: the card shows its skeleton.
    var loading = false
    var wants: Wants

    /// Whether the thread has a line of its own, is one of the housekeeping line's, or isn't on the page.
    enum Scope: Equatable { case line, older, out }

    /// How long a finished thread keeps a line of its own, and how long it then stays on the housekeeping line.
    static let lineWindow: TimeInterval = 86_400
    static let olderWindow: TimeInterval = 7 * 86_400

    /// The first row of the table that matches (IMPLEMENTATION.md 1.3): a request or a plan, a live run, a usage limit, a
    /// failure, a stop you asked for, any other end.
    static func make(thread t: AgentThread, detail: RouterDetail?, now: Date) -> RouterCodeState {
        let ended = t.lastRunEndedAt ?? t.lastActivity
        // The projection's request counts while the shell still shows one (the shell is T3's word that it was answered);
        // its plan while the shell still offers one.
        let request = detail?.request
        let since = t.pendingRequest?.createdAt.flatMap(AgentThread.date) ?? ended
        if let r = request, !r.isPlan, t.pendingRequest != nil { return ask(r, since: since) }
        if let pending = t.pendingRequest, pending.blocking {
            let kind: RouterThread.Ask = pending.isUserInput ? .question : .permission
            return RouterCodeState(state: .needsYou(kind), line: pending.isUserInput ? Copy.asks : Copy.permission,
                                   since: since, loading: true, wants: .ask)
        }
        if t.hasPlan {
            if let r = request, r.isPlan { return ask(r, since: ended) }
            return RouterCodeState(state: .needsYou(.plan), line: Copy.planReady, since: ended, loading: true, wants: .ask)
        }
        if t.running {
            let since = detail?.working?.since ?? t.runStartedAt ?? ended
            let line = detail?.working?.text ?? t.backgroundStep ?? Router.Copy.starting
            return RouterCodeState(state: .working, line: line, mono: detail?.working?.mono ?? false, since: since, wants: .nothing)
        }
        if t.usageLimit, !t.limitStopped {
            return RouterCodeState(state: .working, line: pausedLine(t.limitResetAt), since: t.runStartedAt ?? ended, paused: true,
                                   wants: .nothing)
        }
        if t.limitStopped {
            return RouterCodeState(state: .stopped, line: Copy.usageLimit, since: ended, wants: .nothing)
        }
        if t.status == .failed || t.status == .interrupted && !t.stopRequested {
            let line = t.status == .failed ? Copy.failed + (firstLine(t.lastError) ?? Copy.unknownError) : Router.Copy.interrupted
            return RouterCodeState(state: .stopped, line: line, since: ended, wants: .nothing)
        }
        if t.status == .interrupted {
            return RouterCodeState(state: .done, line: Router.Copy.stoppedByYou, since: ended, wants: .nothing)
        }
        return RouterCodeState(state: .done, line: Router.Copy.finished, since: ended, wants: .finished)
    }

    /// A request T3 holds, in its kind, with T3's words: a question verbatim, a form's count and first question, a plan's
    /// first line, a permission's command (mono).
    private static func ask(_ r: ThreadRequest, since: Date) -> RouterCodeState {
        switch r.body {
        case .plan(let markdown):
            let first = firstLine(markdown.split(whereSeparator: \.isNewline).lazy.map(planLine).first { !$0.isEmpty }) ?? ""
            return RouterCodeState(state: .needsYou(.plan), line: first.isEmpty ? Copy.planReady : Copy.planReady + ": " + first,
                                   since: since, wants: .ask)
        case .approval(let kind, let prompt, _):
            let command = firstLine(prompt) ?? kind
            return RouterCodeState(state: .needsYou(.permission), line: command, mono: true, since: since, wants: .ask)
        case .question(let questions):
            let first = questions.first.map { firstLine($0.question) ?? $0.header } ?? ""
            if questions.count > 1 {
                return RouterCodeState(state: .needsYou(.form), line: "\(questions.count) questions: " + first, since: since, wants: .ask)
            }
            return RouterCodeState(state: .needsYou(.question), line: first.isEmpty ? Copy.asks : first, since: since, wants: .ask)
        }
    }

    /// A plan's line without its markdown marks: "# Title" → "Title", "- step" → "step".
    private static func planLine(_ s: Substring) -> String {
        var line = s.drop { $0 == "#" || $0 == "-" || $0 == "*" || $0 == ">" || $0.isWhitespace }
        while line.last?.isWhitespace == true { line = line.dropLast() }
        return String(line)
    }

    /// The text's first non-empty line, trimmed; nil for none.
    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// "paused at the usage limit, resumes 15:00", read with the calendar (no formatter on this path).
    static func pausedLine(_ at: Date?, calendar: Calendar = .current) -> String {
        guard let at else { return Copy.paused }
        let c = calendar.dateComponents([.hour, .minute], from: at)
        let hh = c.hour ?? 0, mm = c.minute ?? 0
        return Copy.paused + ", resumes " + (hh < 10 ? "0" : "") + String(hh) + ":" + (mm < 10 ? "0" : "") + String(mm)
    }

    enum Copy {
        static let asks = "asks you a question"
        static let permission = "waits for a permission"
        static let planReady = "plan ready"
        static let usageLimit = "hit the usage limit"
        static let paused = "paused at the usage limit"
        static let failed = "failed: "
        static let unknownError = "an error T3 didn't name"
    }

    // MARK: Scope

    /// Where a thread is on the page (the brief rebuild's rule): in play (`AgentThread.inPlay`) and working, waiting on you,
    /// stopped, or finished under a day ago → a line; finished a day to a week ago → the housekeeping line; older, or never
    /// run → nothing. A stopped thread keeps its line for the week too: it needs you.
    static func scope(_ t: AgentThread, state: RouterCodeState, now: Date) -> Scope {
        guard t.inPlay(now: now) else { return .out }
        switch state.state {
        case .needsYou, .working, .sent: return .line
        case .stopped:
            return now.timeIntervalSince(state.since) <= olderWindow ? .line : .out
        case .done:
            // Never run: nothing to say about it.
            guard t.lastRunEndedAt != nil else { return .out }
            let age = now.timeIntervalSince(state.since)
            return age <= lineWindow ? .line : age <= olderWindow ? .older : .out
        }
    }

    /// The row is off the page whatever its state (out of play, or ended more than a week ago with nothing live or waiting):
    /// `scope` would say `.out`, read without making the state. Most of a shell is this.
    static func plainlyOut(_ t: AgentThread, inPlay: Bool, now: Date) -> Bool {
        if !inPlay { return true }
        if t.pendingRequest != nil || t.hasPlan || t.usageLimit && !t.limitStopped || t.running { return false }
        return now.timeIntervalSince(t.lastRunEndedAt ?? t.lastActivity) > olderWindow
    }

    /// The next time this thread's scope changes by the clock alone (a day after it finished, a week after, the end of a
    /// snooze): the store keeps one one-shot timer for the earliest of them.
    static func boundary(_ t: AgentThread, state: RouterCodeState, now: Date) -> Date? {
        if let until = t.snoozedUntil, until > now { return until }
        guard t.inPlay(now: now) else { return nil }
        switch state.state {
        case .done where t.lastRunEndedAt != nil:
            let day = state.since.addingTimeInterval(lineWindow), week = state.since.addingTimeInterval(olderWindow)
            return day > now ? day : week > now ? week : nil
        case .stopped:
            let week = state.since.addingTimeInterval(olderWindow)
            return week > now ? week : nil
        default: return nil
        }
    }

    // MARK: Fingerprint

    /// The verdict's cache key, from the shell row alone: the latest run, the pending request, the plan, every pull
    /// request's `url:state` (sorted), your last words there. A move of any of them asks for a new verdict.
    static func fingerprint(_ t: AgentThread) -> String {
        var out = (t.latestRunID ?? "-") + "|" + (t.pendingRequest?.id ?? "-") + "|" + (t.hasPlan ? "plan" : "-") + "|"
        if !t.pullRequests.isEmpty {
            let prs = t.pullRequests.map { $0.url + ":" + ($0.state ?? "") }
            out += (prs.count == 1 ? prs : prs.sorted()).joined(separator: ",")
        }
        out += "|" + (t.lastAuthoredAt.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "-")
        return out
    }

    /// The new dot: T3's `unseen`, or a request made after you last opened the thread.
    static func isNew(_ t: AgentThread) -> Bool {
        if t.unseen { return true }
        guard let pending = t.pendingRequest, pending.blocking, let made = pending.createdAt.flatMap(AgentThread.date) else { return false }
        guard let visited = t.lastVisitedAt else { return true }
        return made > visited
    }
}
