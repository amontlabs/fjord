import SwiftUI

// The store's side of the Router: its switch, a message to it, a form's answer, a plan's yes or no, and the working rows the
// bar lists.

extension Store {
    func routerSessionProject(_ sessionID: String) -> (name: String, color: Color?) {
        let folder = threads[sessionID]?.folderKey ?? ""
        return (folderName(folder), projectColor(folder))
    }

    /// The Router's switch: it turns the reading of Claude's sessions, which it works on, on and off with it.
    func switchRouter(_ on: Bool) {
        if on { setAgentsEnabled(true) }
        setRouterEnabled(on)
        if !on {
            setAgentsEnabled(false)
        }
    }

    /// The sessions working now (not those stopped on you), and those whose turn is over with subagents or commands still
    /// running (the tiles count them as working too); the longest running first.
    var routerWorkingRows: [ThreadRow] {
        allAgentRows.filter { ($0.session.running && !$0.waitsForYou) || (!$0.session.running && !$0.tasks.isEmpty) }
            .sorted { (Self.workingStart($0) ?? .distantFuture) < (Self.workingStart($1) ?? .distantFuture) }
    }

    /// Since when a row in the Working list works: its turn, or the oldest thing it left running.
    static func workingStart(_ row: ThreadRow) -> Date? {
        row.session.running ? row.workingSince : row.tasks.map(\.since).min()
    }

    /// The Router's own process must never reach real sessions from a demo or a playground: it answers for itself there.
    var routerIsPretend: Bool { Store.isDemo || !persists }

    /// Your message to the Router, with the thread it replies to and the projects you tagged; in a demo, a canned reply
    /// instead of a real process. Whether it went: an ask-back's target named that is gone since sends nothing.
    @discardableResult
    func sendToRouter(_ text: String, context: RouterContext = RouterContext(), now: Date = Date()) -> Bool {
        let text = RouterComposerModel.sendable(text)
        guard !text.isEmpty else { return false }
        if routerIsPretend {
            var entry = RouterDecision(at: now, trigger: .you(text), decision: .init(intent: "message"), outcome: .done,
                                       links: .init(threads: context.replyTo.map { [$0.key] } ?? []))
            let mentions = RouterDispatcher.mentions(context.mentions, in: text)
            entry.mentions = mentions.isEmpty ? nil : mentions
            entry.reply = "In a demo the Router only says what it would do."
            logDecision(entry)
            return true
        }
        return routerDispatcher.submit(text, context: context) != nil
    }

    /// What T3 says the thread waits on you for now.
    func heldRequest(_ target: BriefTarget) -> ThreadRequest? {
        requests[target.thread]
    }

    /// The last check before an answer goes: the Router is on and the thread still holds that very request (and, for an
    /// answer the Router read, the one it was read against).
    func answerStillValid(_ request: ThreadRequest, target: BriefTarget, snapshot: RequestSnapshot?,
                          alsoValid: (@MainActor () -> Bool)? = nil) -> Bool {
        guard routerOn, alsoValid?() != false, let held = heldRequest(target) else { return false }
        return held.id == request.id && snapshot.map { $0.holds(self) } != false
    }

    /// Sends commands to T3 in order; in a demo nothing is sent.
    private func sendCommands(_ commands: [T3Command]) async throws {
        for command in commands { try await dispatch(command) }
    }

    /// The answer to a question (`runtime-request.respond`): an option's value, several for a multiple choice, or the
    /// words of a custom answer. Only while the thread still holds that request, checked again right before it is sent.
    func answerQuestion(_ request: ThreadRequest, _ answers: [String: T3Answer], target: BriefTarget,
                        snapshot: RequestSnapshot? = nil, alsoValid: (@MainActor () -> Bool)? = nil) async -> Result<Void, Error> {
        do {
            let checked = try request.validate(answers)
            guard request.live else { throw RequestFailure.notLive }
            guard answerStillValid(request, target: target, snapshot: snapshot, alsoValid: alsoValid)
            else { throw RequestFailure.moved }
            try await sendCommands([.respondAnswers(threadId: target.thread, requestId: request.id, answers: checked)])
            logEntryAction("Answered the question", target: target)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// A permission's answer: a button's decision, or a decline carrying your words.
    func answerPermission(_ request: ThreadRequest, _ decision: T3Decision, feedback: String? = nil, target: BriefTarget,
                          snapshot: RequestSnapshot? = nil, alsoValid: (@MainActor () -> Bool)? = nil) async -> Result<Void, Error> {
        do {
            guard case .approval(_, _, let allowed) = request.body else { throw RequestFailure.notAPermission }
            guard request.live else { throw RequestFailure.notLive }
            guard allowed.contains(decision) else { throw RequestFailure.unknownOption(decision.rawValue) }
            if feedback != nil, !request.supportsFeedback { throw RequestFailure.noFeedback }
            guard answerStillValid(request, target: target, snapshot: snapshot, alsoValid: alsoValid)
            else { throw RequestFailure.moved }
            try await sendCommands([.respondDecision(threadId: target.thread, requestId: request.id, decision: decision, feedback: feedback)])
            logEntryAction(decision == .decline ? "Declined the permission" : "Allowed the permission", target: target)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// "Yes" to a plan: the mode it runs in, the default interaction mode, then the message T3's own composer sends to
    /// implement it, naming the plan (S1 f).
    func implementPlan(_ request: ThreadRequest, mode: T3RuntimeMode, target: BriefTarget,
                       snapshot: RequestSnapshot? = nil) async -> Result<Void, Error> {
        do {
            guard let markdown = request.planMarkdown else { throw RequestFailure.notAPlan }
            guard answerStillValid(request, target: target, snapshot: snapshot) else { throw RequestFailure.moved }
            let thread = target.thread
            try await sendCommands([
                .runtimeModeSet(threadId: thread, mode: mode),
                .interactionModeSet(threadId: thread, mode: .default),
                .messageDispatch(threadId: thread, messageId: UUID().uuidString.lowercased(), text: ThreadRequest.implementText(markdown),
                                 dispatch: .startImmediately(intent: .auto), sourcePlan: (thread, request.id)),
            ])
            logEntryAction("Approved the plan (" + (mode == .autoAcceptEdits ? "auto-accept" : "manually") + ")", target: target)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// "No" to a plan: your words as a normal message, the thread still in plan mode.
    func sendBackPlan(_ request: ThreadRequest, words: String, target: BriefTarget,
                      snapshot: RequestSnapshot? = nil) async -> Result<Void, Error> {
        do {
            guard request.isPlan else { throw RequestFailure.notAPlan }
            guard answerStillValid(request, target: target, snapshot: snapshot) else { throw RequestFailure.moved }
            try await sendCommands([.messageDispatch(threadId: target.thread, messageId: UUID().uuidString.lowercased(), text: words,
                                                     dispatch: .startImmediately(intent: .auto))])
            logEntryAction("Sent the plan back", target: target)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
