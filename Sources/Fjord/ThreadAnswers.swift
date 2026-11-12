import Foundation

// What picked options and typed words become on a T3 request (a question, a form, a permission, a plan). The rules are
// `RouterBriefs.answerRequest`'s, on `ThreadRequest` and with no brief entry: an option's number through the card is a
// position in the request's own lists, words are never a yes (a permission typed is a decline carrying them, a plan's are
// sent back), and an answer goes only while the thread still holds that very request (`RequestSnapshot`).

enum ThreadAnswers {
    /// What to do on the request.
    enum Answer: Equatable {
        /// A question or form: its answers by question id (`runtime-request.respond`).
        case answers([String: T3Answer])
        /// A permission: a button's decision, or a decline carrying your words.
        case decision(T3Decision, feedback: String?)
        /// A plan's yes, in the runtime mode picked.
        case implement(T3RuntimeMode)
        /// A plan's no: your words as a normal message, the thread still in plan mode.
        case sendBack(String)
    }

    /// The answer for what was picked and typed. `picks`: per question (0 for a single question or a permission or a plan)
    /// the option's number, 1-based through the card (`RouterV2Thread.numbered`: a form's questions one after the other).
    /// `typed`: per question, words in place of an option. Throws why it can't be read (`RequestFailure`).
    static func resolve(_ request: ThreadRequest, picks: [Int: Int], typed: [Int: String]) throws -> Answer {
        let typed = typed.compactMapValues { text -> String? in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        switch request.body {
        case .question(let questions):
            var answers: [String: T3Answer] = [:]
            var first = 0
            for (index, q) in questions.enumerated() {
                defer { first += q.options.count }
                if let words = typed[index] {
                    // Where the question takes a custom answer: the words themselves.
                    guard q.allowCustomAnswer else { throw RequestFailure.unknownOption(words) }
                    answers[q.id] = q.multiSelect ? .many([words]) : .one(words)
                } else if let number = picks[index] {
                    let at = number - first - 1
                    guard q.options.indices.contains(at) else { throw RequestFailure.unknownOption(String(number)) }
                    let value = q.options[at].value
                    answers[q.id] = q.multiSelect ? .many([value]) : .one(value)
                } else if q.required {
                    throw RequestFailure.incomplete
                }
            }
            return .answers(try request.validate(answers))
        case .approval(_, _, let decisions):
            if let number = picks[0] {
                guard decisions.indices.contains(number - 1) else { throw RequestFailure.unknownOption(String(number)) }
                return .decision(decisions[number - 1], feedback: nil)
            }
            // Typed words are never a yes: they decline, and the words go to the agent as the reason.
            guard let words = typed[0] else { throw RequestFailure.incomplete }
            guard request.supportsFeedback else { throw RequestFailure.noFeedback }
            return .decision(.decline, feedback: words)
        case .plan:
            if let number = picks[0] {
                guard ThreadRequest.planModes.indices.contains(number - 1) else { throw RequestFailure.unknownOption(String(number)) }
                return .implement(ThreadRequest.planModes[number - 1])
            }
            guard let words = typed[0] else { throw RequestFailure.incomplete }
            return .sendBack(words)
        }
    }
}

extension Store {
    /// Does `answer` on the request the thread holds, against the snapshot taken when it was read. The commands are the
    /// existing ones (`answerQuestion`, `answerPermission`, `implementPlan`, `sendBackPlan`), which check once more right
    /// before they send and leave their line in History.
    func perform(_ answer: ThreadAnswers.Answer, on request: ThreadRequest, snapshot: RequestSnapshot) async -> Result<Void, Error> {
        let target = snapshot.target
        switch answer {
        case .answers(let answers):
            return await answerQuestion(request, answers, target: target, snapshot: snapshot)
        case .decision(let decision, let feedback):
            return await answerPermission(request, decision, feedback: feedback, target: target, snapshot: snapshot)
        case .implement(let mode):
            return await implementPlan(request, mode: mode, target: target, snapshot: snapshot)
        case .sendBack(let words):
            return await sendBackPlan(request, words: words, target: target, snapshot: snapshot)
        }
    }
}
