import Foundation

/// What a thread waits on you for, as T3 holds it: a question, a permission, or a plan to approve. Read from the thread's
/// projection (the shell only says that something waits), for every provider alike. Live state, never stored.
struct ThreadRequest: Hashable, Identifiable, Sendable {
    enum Body: Hashable, Sendable {
        case question([T3Question])
        /// `requestKind` (`command`, `file-change`…), what it asks to do, and the decisions it takes.
        case approval(kind: String, prompt: String, decisions: [T3Decision])
        case plan(markdown: String)
    }

    /// The runtime request's id, or the plan's.
    var id: String
    var threadID: String
    var body: Body
    /// T3 can still take an answer (`responseCapability: live`). It can't after T3 restarted: the question is then only
    /// shown, and answered in T3 or with words.
    var live: Bool
    /// A decline can carry your words (`supportsFeedback`).
    var supportsFeedback = true

    var questions: [T3Question] { if case .question(let q) = body { q } else { [] } }
    var isPlan: Bool { if case .plan = body { true } else { false } }
    var planMarkdown: String? { if case .plan(let m) = body { m } else { nil } }
    var decisions: [T3Decision] { if case .approval(_, _, let d) = body { d } else { [] } }

    /// A permission's buttons when the request carries no `options` (Claude's don't, S1 7): the decisions T3 knows, but
    /// not `cancel`, which stops the run rather than answering.
    static let fallbackDecisions: [T3Decision] = [.accept, .acceptForSession, .acceptAlways, .decline]

    /// The words on a decision's button.
    static func label(_ d: T3Decision) -> String {
        switch d {
        case .accept: "Allow"
        case .acceptForSession: "Allow for this session"
        case .acceptAlways: "Always allow"
        case .decline: "Decline"
        case .cancel: "Cancel the run"
        default: d.rawValue
        }
    }

    /// The plan's two ways to a yes.
    static let planChoices = ["Yes, auto-accept", "Yes, manually"]
    static let planModes: [T3RuntimeMode] = [.autoAcceptEdits, .approvalRequired]
    /// The text T3's own composer sends to implement a plan.
    static func implementText(_ markdown: String) -> String {
        "PLEASE IMPLEMENT THIS PLAN:\n" + markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The newest request a projection holds that waits on you (a declined approval the agent retried is a new id, S1 e),
    /// else the proposed plan. Nil when nothing waits.
    init?(_ p: T3Projection) {
        threadID = p.thread.id
        if let r = p.pendingRequests.max(by: { ($0.createdAt?.text ?? "") < ($1.createdAt?.text ?? "") }),
           let body = Self.body(of: r, in: p) {
            id = r.id; self.body = body; live = r.isLive; supportsFeedback = r.supportsFeedback
            return
        }
        guard p.thread.hasActionableProposedPlan,
              let plan = p.plans.last(where: { !$0.markdown.isEmpty }) else { return nil }
        id = plan.id; body = .plan(markdown: plan.markdown); live = true
    }

    private static func body(of r: T3RuntimeRequest, in p: T3Projection) -> Body? {
        for item in p.turnItems.reversed() {
            switch item.detail {
            case .userInputRequest(let id, let questions) where id == r.id:
                return .question(questions)
            case .approvalRequest(let id, let kind, let prompt, let reason, let options) where id == r.id:
                let given = options.map(\.decision)
                return .approval(kind: kind, prompt: [prompt, reason].compactMap { $0 }.first { !$0.isEmpty } ?? "",
                                 decisions: given.isEmpty ? fallbackDecisions : given)
            default: continue
            }
        }
        return nil
    }

    init(id: String, threadID: String, body: Body, live: Bool = true, supportsFeedback: Bool = true) {
        self.id = id; self.threadID = threadID; self.body = body; self.live = live; self.supportsFeedback = supportsFeedback
    }
}

/// The request a judgment was made against: applied only while the thread still holds that very request, when it is made and
/// at the send. One that moved on to another request (a retried permission has a new id) isn't answered.
struct RequestSnapshot: Equatable, Sendable {
    var target: BriefTarget
    var requestID: String

    static let changedWords = "The question changed while your answer was being read, so nothing was answered."

    init(target: BriefTarget, request: ThreadRequest) {
        self.target = target
        requestID = request.id
    }

    @MainActor func holds(_ store: Store) -> Bool { store.heldRequest(target)?.id == requestID }
}

/// What can go wrong sending an answer.
enum RequestFailure: LocalizedError, Equatable {
    case notLive, incomplete, unknownOption(String), notAPlan, notAQuestion, notAPermission, noFeedback, moved
    var errorDescription: String? {
        switch self {
        case .notLive: "T3 restarted since it asked: answer it in T3, or send words instead."
        case .incomplete: "Every question needs an answer."
        case .unknownOption(let o): "“\(o)” isn't one of its options."
        case .notAPlan: "That isn't a plan."
        case .notAQuestion: "That isn't a question."
        case .notAPermission: "That isn't a permission."
        case .noFeedback: "This permission can't take words: use its buttons, or answer in T3."
        case .moved: RequestSnapshot.changedWords
        }
    }
}

extension ThreadRequest {
    /// The answers to a question, checked: every question that is required has one, and an option's value is one it offers
    /// (else it is a custom answer, only where the question takes one).
    func validate(_ answers: [String: T3Answer]) throws -> [String: T3Answer] {
        guard case .question(let questions) = body else { throw RequestFailure.notAQuestion }
        for q in questions {
            guard let a = answers[q.id] else {
                if q.required { throw RequestFailure.incomplete }
                continue
            }
            let values: [String]
            switch a { case .one(let v): values = [v]; case .many(let m): values = m }
            guard !values.isEmpty, !values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { throw RequestFailure.incomplete }
            if case .many = a, !q.multiSelect { throw RequestFailure.incomplete }
            for v in values where !q.options.contains(where: { $0.value == v }) && !q.allowCustomAnswer {
                throw RequestFailure.unknownOption(v)
            }
        }
        return answers
    }
}

extension T3Question {
    /// A single-choice question for demos and tests.
    init(demo header: String, _ question: String, id: String? = nil, multiSelect: Bool = false, allowCustomAnswer: Bool = false,
         options: [(String, String)]) {
        self.id = id ?? question; self.header = header; self.question = question; self.multiSelect = multiSelect
        self.allowCustomAnswer = allowCustomAnswer; required = true
        self.options = options.map { Option(label: $0.0, description: $0.1) }
    }
}

extension T3Question.Option {
    init(label: String, description: String, value: String? = nil) {
        self.label = label; self.description = description; self.value = value ?? label
    }
}
