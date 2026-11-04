import Foundation
import Observation

// A message that fits no project can start one: the pill under the composer proposes it, live (no modal). You change it by
// typing ("call it fjord-ios, no repo"), the pill shows the revised proposal, and Return creates it through the engine's tools
// (create_project, then add_repo, set_instructions, preapprove_folder as the proposal has them) and delivers the message there.
// Escape drops it and the message goes back in the composer, unsent. The folder grant is yours: it is asked of the engine only
// on that Return.
//
// The seams: `RouterProjectReviser` (the decider agent's model-backed one revises a proposal from your words) and
// `RouterProjectEngine` (the pills' engine in the app, a fake in shots and tests). The views are RouterProjectProposalPill.swift.

/// What would be made: the project's name, the folder it may use, the repo (nil: none), and one line of instructions.
struct RouterProjectFields: Equatable, Sendable {
    var name: String
    /// The Mac folder the project may use (preapproved on Return); nil: none.
    var folder: String?
    /// `owner/name`; nil: none.
    var repo: String?
    var instructions: String

    init(name: String, folder: String? = nil, repo: String? = nil, instructions: String = "") {
        self.name = name
        self.folder = folder
        self.repo = repo
        self.instructions = instructions
    }

    /// The fields that differ from `other`, by their names ("name", "repo").
    func changes(from other: RouterProjectFields) -> [String] {
        var out: [String] = []
        if name != other.name { out.append("name") }
        if folder != other.folder { out.append("folder") }
        if repo != other.repo { out.append("repo") }
        if instructions != other.instructions { out.append("instructions") }
        return out
    }
}

/// Revises a proposal from your words. The model-backed one is the decider's; `RouterProjectFakeReviser` is the deterministic one.
@MainActor protocol RouterProjectReviser {
    /// The proposal as `text` asks it changed. Throws a plain sentence when it can't (the pill shows it, the proposal stays).
    func revise(_ current: RouterProjectFields, with text: String, message: String) async throws -> RouterProjectFields
}

/// What a tool did.
struct RouterProjectOutcome: Equatable, Sendable {
    var ok: Bool
    var cause: String?
    static let done = RouterProjectOutcome(ok: true)
    static func failed(_ cause: String) -> RouterProjectOutcome { .init(ok: false, cause: cause) }
}

/// Where the proposal's tools run and its message goes: the pills' engine in the app.
@MainActor protocol RouterProjectEngine {
    /// Runs one tool and says how it ended (a grant is confirmed on the way: its Return was the owner's).
    func run(_ tool: CourierTool, _ args: [String: JSON]) async -> RouterProjectOutcome
    /// Hands the original message to the project once it exists.
    func send(_ words: String, to project: String) async
}

/// One proposal to start a project for `message`. Observable: the pill follows `fields` and `phase`.
@Observable @MainActor final class RouterProjectProposal {
    enum Phase: Equatable {
        /// Shown, waiting for Return (create) or your words (revise).
        case proposed
        /// A model is revising it from your words.
        case revising
        /// Under way: what is being done now ("Creating the project").
        case creating(String)
        /// Made, and the message delivered.
        case created
        /// Stopped at a step; Return tries again, Escape drops it.
        case failed(String)
    }

    /// The step that makes each piece, in the order they run.
    enum Step: String, CaseIterable { case create, repo, instructions, folder }

    /// The message that started it; it goes to the project, and back in the composer if you drop this.
    let message: String
    private(set) var fields: RouterProjectFields
    internal(set) var phase: Phase = .proposed
    /// What the last revision changed ("name, repo"); empty before one.
    private(set) var changed: [String] = []
    /// Why the last revision didn't happen.
    private(set) var reviseNote: String?

    @ObservationIgnored private let reviser: RouterProjectReviser
    @ObservationIgnored private let engine: RouterProjectEngine
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var confirmAfter = false
    @ObservationIgnored private var done: Set<Step> = []
    @ObservationIgnored private var making: Task<Void, Never>?
    /// How long the made pill stays; nil keeps it (a shot, a test).
    @ObservationIgnored var settleAfter: Duration? = .seconds(2)
    /// The proposal is over (made and settled, or dropped): whoever holds it lets go.
    @ObservationIgnored var onEnd: () -> Void = {}
    /// The project exists and the message is on its way (`fields`, as made): the history's entry.
    @ObservationIgnored var onCreated: (RouterProjectFields) -> Void = { _ in }

    init(message: String, first fields: RouterProjectFields, reviser: RouterProjectReviser, engine: RouterProjectEngine) {
        self.message = message
        self.fields = fields
        self.reviser = reviser
        self.engine = engine
    }

    // MARK: Revising

    /// Your words change the proposal. They go one after the other, each on the last one's result; the pill says "revising"
    /// meanwhile and shows each result at once.
    func refine(with text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, canRevise else { return }
        queue.append(words)
        phase = .revising
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                do {
                    let revised = try await self.reviser.revise(self.fields, with: next, message: self.message)
                    self.changed = revised.changes(from: self.fields)
                    self.fields = Self.cleaned(revised)
                    self.reviseNote = nil
                } catch {
                    self.reviseNote = (error as? LocalizedError)?.errorDescription ?? "Couldn't revise that: \(error)"
                }
            }
            self?.worker = nil
            self?.revisingEnded()
        }
    }

    /// Whether your words can still change it.
    var canRevise: Bool {
        switch phase {
        case .proposed, .revising, .failed: true
        case .creating, .created: false
        }
    }

    /// Waits for the revisions under way (a test's).
    func settled() async {
        await worker?.value
        await making?.value
    }

    private func revisingEnded() {
        if case .revising = phase { phase = .proposed }
        if confirmAfter { confirmAfter = false; confirm() }
    }

    private static func cleaned(_ f: RouterProjectFields) -> RouterProjectFields {
        var f = f
        f.name = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
        f.folder = f.folder?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        f.repo = f.repo?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        f.instructions = f.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return f
    }

    // MARK: Making

    /// Return with nothing typed. While a revision is under way it waits for it (what you typed counts).
    func confirm() {
        switch phase {
        case .revising: confirmAfter = true
        case .proposed, .failed:
            guard !fields.name.isEmpty else { return }
            make()
        case .creating, .created: break
        }
    }

    /// The tools, in order, each only if it isn't done (a retry goes on from where it stopped), then the message.
    private func make() {
        let fields = fields
        phase = .creating("Creating the project")
        making = Task { [weak self] in
            guard let self else { return }
            for step in Step.allCases where !self.done.contains(step) {
                guard let (tool, args, doing) = Self.call(step, fields) else { self.done.insert(step); continue }
                self.phase = .creating(doing)
                let outcome = await self.engine.run(tool, args)
                guard outcome.ok else {
                    self.phase = .failed("\(Self.failure(step)): \(outcome.cause ?? "the engine gave no reason")")
                    return
                }
                self.done.insert(step)
            }
            self.phase = .creating("Sending your message")
            await self.engine.send(self.message, to: fields.name)
            self.phase = .created
            self.onCreated(fields)
            self.making = nil
            self.settle()
        }
    }

    private func settle() {
        guard let settleAfter else { return }
        Task { [weak self] in
            try? await Task.sleep(for: settleAfter)
            self?.onEnd()
        }
    }

    /// The tool a step is, its arguments, and what the pill says while it runs; nil when the proposal has nothing for it.
    static func call(_ step: Step, _ f: RouterProjectFields) -> (CourierTool, [String: JSON], String)? {
        switch step {
        case .create: (.createProject, ["name": .string(f.name)], "Creating the project")
        case .repo: f.repo.map { (.addRepo, ["project": .string(f.name), "repo": .string($0)], "Adding the repo") }
        case .instructions:
            f.instructions.isEmpty ? nil : (.setInstructions, ["project": .string(f.name), "text": .string(f.instructions)], "Setting the instructions")
        case .folder: f.folder.map { (.preapproveFolder, ["project": .string(f.name), "path": .string($0)], "Allowing the folder") }
        }
    }

    private static func failure(_ step: Step) -> String {
        switch step {
        case .create: "The project wasn't created"
        case .repo: "The project exists, but its repo wasn't added"
        case .instructions: "The project exists, but its instructions weren't set"
        case .folder: "The project exists, but its folder wasn't allowed"
        }
    }

    // MARK: Dropping

    /// Escape: nothing more is done, and the message is yours again. A project already made stays made.
    func drop() -> String {
        worker?.cancel(); worker = nil
        making?.cancel(); making = nil
        queue = []
        onEnd()
        return message
    }

    /// A shot's or a test's way to a given state.
    func show(_ fields: RouterProjectFields? = nil, phase: Phase, changed: [String] = [], note: String? = nil) {
        if let fields { self.fields = fields }
        self.phase = phase
        self.changed = changed
        reviseNote = note
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - The app's engine

/// The pills' engine for the proposal: each tool is an intent whose pill the proposal's own replaces (it is dismissed once the
/// tool ended); the message is an ordinary delivery with its own pill.
@MainActor struct RouterProjectPillsEngine: RouterProjectEngine {
    let pills: RouterCourierPills

    func run(_ tool: CourierTool, _ args: [String: JSON]) async -> RouterProjectOutcome {
        let id = await pills.tool(tool, args: args)
        guard id > 0 else { return .failed("Fjord's engine for claude.ai isn't running") }
        var update = await pills.next(id) { $0 != .sending && $0 != .taken }
        // The grant: its Return was this one.
        if update.state == .awaiting {
            pills.perform(.allow, on: id)
            update = await pills.next(id) { $0 != .sending && $0 != .taken && $0 != .awaiting }
        }
        pills.dismiss(id)
        switch update.state {
        case .toolDone, .delivered, .deliveredLate: return .done
        case .paused: return .failed(update.cause ?? "the engine is waiting on claude.ai")
        default: return .failed(update.cause ?? "the engine couldn't do it")
        }
    }

    func send(_ words: String, to project: String) async {
        await pills.send(words, to: .project(project))
    }
}

extension RouterCourierPills {
    /// The first update of intent `id` (as it is now, or the next) whose state `matches`.
    func next(_ id: Int, where matches: @escaping (CourierState) -> Bool) async -> CourierUpdate {
        if let last = lastUpdates[id], matches(last.state) { return last }
        return await withCheckedContinuation { continuation in
            waiters[id, default: []].append((matches, continuation))
        }
    }
}

// MARK: - A fake for shots and tests

/// A deterministic reviser: it reads a few plain phrasings ("call it X", "no repo", "repo a/b", "folder /p", "no folder",
/// "instructions: …"). Only for shots and tests; the app's reviser is the decider's model.
@MainActor struct RouterProjectFakeReviser: RouterProjectReviser {
    var delay: Duration?
    var failure: String?

    func revise(_ current: RouterProjectFields, with text: String, message: String) async throws -> RouterProjectFields {
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw FakeFailure(errorDescription: failure) }
        var f = current
        let lower = text.lowercased()
        let words = text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        func after(_ keys: [String]) -> String? {
            for (i, w) in words.enumerated() where keys.contains(w.lowercased()) && i + 1 < words.count { return words[i + 1] }
            return nil
        }
        if let name = after(["call", "name", "named", "rename"]) {
            f.name = name == "it" || name == "to" ? (words.drop { $0.lowercased() != name.lowercased() }.dropFirst().first ?? f.name) : name
        }
        if lower.contains("no repo") { f.repo = nil } else if let repo = words.first(where: { $0.contains("/") && !$0.hasPrefix("/") && !$0.hasPrefix("~") }) { f.repo = repo }
        if lower.contains("no folder") { f.folder = nil } else if let path = words.first(where: { $0.hasPrefix("/") || $0.hasPrefix("~") }) { f.folder = path }
        if let range = lower.range(of: "instructions:") { f.instructions = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
        return f
    }

    struct FakeFailure: LocalizedError { var errorDescription: String? }
}

/// A fake engine: every tool ends as `outcomes[tool]` (done by default), after `delay`; what ran and what was sent is kept.
@MainActor final class RouterProjectFakeEngine: RouterProjectEngine {
    var outcomes: [CourierTool: RouterProjectOutcome] = [:]
    var delay: Duration?
    private(set) var ran: [(tool: CourierTool, args: [String: JSON])] = []
    private(set) var sent: [(words: String, project: String)] = []

    func run(_ tool: CourierTool, _ args: [String: JSON]) async -> RouterProjectOutcome {
        ran.append((tool, args))
        if let delay { try? await Task.sleep(for: delay) }
        return outcomes[tool] ?? .done
    }

    func send(_ words: String, to project: String) async {
        sent.append((words, project))
    }
}

// MARK: - The seam for the dispatcher and the keys

extension Store {
    /// Starts a proposal to make a project for `message` (the one the dispatcher found no project for), `first` being the decider's
    /// first proposal. The pill shows at once. The engine is the app's unless one is given. Replaces any proposal already up.
    @discardableResult
    func proposeProject(for message: String, first: RouterProjectFields, reviser: RouterProjectReviser,
                        engine: RouterProjectEngine? = nil) -> RouterProjectProposal {
        let proposal = RouterProjectProposal(message: message, first: first, reviser: reviser,
                                             engine: engine ?? RouterProjectPillsEngine(pills: routerCourier))
        proposal.onEnd = { [weak self, weak proposal] in
            if self?.routerProposal === proposal { self?.routerProposal = nil }
        }
        routerProposal = proposal
        return proposal
    }
}

extension RouterModel {
    /// Return in the composer while a proposal is up: your words revise it, nothing typed creates it. False when none is up
    /// (or it is made already), and Return goes on as a message.
    func answerProposal(store: Store) -> Bool {
        guard let proposal = store.routerProposal, proposal.phase != .created else { return false }
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty {
            proposal.confirm()
        } else if proposal.canRevise {
            proposal.refine(with: words)
            draft = ""
            caret = nil
            pointers = []
        }
        return true
    }

    /// Escape while a proposal is up: it is dropped and the message is in the composer again, unsent.
    func dropProposal(store: Store) -> Bool {
        guard let proposal = store.routerProposal, proposal.phase != .created else { return false }
        // Under way it can't be taken back: Escape waits for it.
        if case .creating = proposal.phase { return true }
        draft = proposal.drop()
        caret = nil
        store.routerProposal = nil
        focusRequest &+= 1
        return true
    }
}
