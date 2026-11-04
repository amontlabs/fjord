import Foundation
import Testing
@testable import Fjord

/// The proposal to start a project: revising from your words, what Return makes and in which order, failures, Escape.
@MainActor
@Suite struct RouterProjectProposalTests {
    private let first = RouterProjectFields(name: "fjord-ios-companion", folder: "/Users/x/code/fjord-ios", repo: "amontlabs/fjord-ios", instructions: "An app.")

    private func make(_ engine: RouterProjectFakeEngine? = nil, reviser: RouterProjectFakeReviser? = nil) -> RouterProjectProposal {
        let engine = engine ?? RouterProjectFakeEngine(), reviser = reviser ?? RouterProjectFakeReviser()
        let p = RouterProjectProposal(message: "set up the iOS app", first: first, reviser: reviser, engine: engine)
        p.settleAfter = nil
        return p
    }

    /// A Store that never reaches the saved state (a proposal's changes are saved).
    private func quiet() -> Store {
        let s = Store()
        s.persists = false
        return s
    }

    @Test func yourWordsReviseItAndRepeat() async {
        let p = make()
        p.refine(with: "call it fjord-ios, no repo")
        #expect(p.phase == .revising)
        await p.settled()
        #expect(p.fields.name == "fjord-ios")
        #expect(p.fields.repo == nil)
        #expect(p.changed == ["name", "repo"])
        #expect(p.phase == .proposed)
        p.refine(with: "repo amontlabs/ios")
        p.refine(with: "no folder")
        await p.settled()
        #expect(p.fields.repo == "amontlabs/ios")
        #expect(p.fields.folder == nil)
    }

    @Test func aFailedRevisionKeepsTheProposalAndSaysWhy() async {
        let p = make(reviser: .init(failure: "the model didn't answer"))
        p.refine(with: "call it x")
        await p.settled()
        #expect(p.fields == first)
        #expect(p.reviseNote == "the model didn't answer")
        #expect(p.phase == .proposed)
    }

    @Test func returnMakesTheProjectThenItsPiecesThenSendsTheMessage() async {
        let engine = RouterProjectFakeEngine()
        let p = make(engine)
        var made: RouterProjectFields?
        p.onCreated = { fields, _ in made = fields }
        p.confirm()
        await p.settled()
        #expect(engine.ran.map(\.tool) == [.createProject, .addRepo, .setInstructions, .preapproveFolder])
        #expect(engine.ran[3].args["path"]?.asString == "/Users/x/code/fjord-ios")
        #expect(engine.sent.map(\.project) == ["fjord-ios-companion"])
        #expect(engine.sent.first?.words == "set up the iOS app")
        #expect(p.phase == .created)
        #expect(made == first)
    }

    @Test func piecesTheProposalLacksAreSkipped() async {
        let engine = RouterProjectFakeEngine()
        let p = RouterProjectProposal(message: "m", first: .init(name: "scratch"), reviser: RouterProjectFakeReviser(), engine: engine)
        p.confirm()
        await p.settled()
        #expect(engine.ran.map(\.tool) == [.createProject])
    }

    @Test func returnWhileRevisingWaitsForTheRevision() async {
        let engine = RouterProjectFakeEngine()
        let p = make(engine)
        p.refine(with: "call it fjord-ios")
        p.confirm()
        await p.settled()
        #expect(engine.ran.first?.args["name"]?.asString == "fjord-ios")
        #expect(p.phase == .created)
    }

    @Test func aFailureStopsWithItsCauseAndRetryGoesOnFromThere() async {
        let engine = RouterProjectFakeEngine()
        engine.outcomes[.addRepo] = .failed("no repo option amontlabs/fjord-ios")
        let p = make(engine)
        p.confirm()
        await p.settled()
        #expect(p.phase == .failed("The project exists, but its repo wasn't added: no repo option amontlabs/fjord-ios"))
        #expect(engine.sent.isEmpty)
        engine.outcomes[.addRepo] = nil
        p.confirm()
        await p.settled()
        // The project isn't created twice.
        #expect(engine.ran.map(\.tool) == [.createProject, .addRepo, .addRepo, .setInstructions, .preapproveFolder])
        #expect(p.phase == .created)
    }

    @Test func escapePutsTheMessageBackAndNothingIsMade() {
        let store = quiet()
        let model = RouterModel()
        let engine = RouterProjectFakeEngine()
        store.proposeProject(for: "set up the iOS app", first: first, reviser: RouterProjectFakeReviser(), engine: engine)
        model.draft = "call it x"
        #expect(model.dropProposal(store: store))
        #expect(model.draft == "set up the iOS app")
        #expect(store.routerProposal == nil)
        #expect(engine.ran.isEmpty)
        #expect(!model.dropProposal(store: store))
    }

    // 1: Escape cancels the Return queued behind a revision; a dropped proposal never creates.
    @Test func escapeWhileRevisingCancelsTheQueuedReturn() async {
        let engine = RouterProjectFakeEngine()
        let p = make(engine, reviser: .init(delay: .milliseconds(50)))
        p.refine(with: "call it fjord-ios")
        p.confirm()
        _ = p.drop()
        try? await Task.sleep(for: .milliseconds(150))
        await p.settled()
        #expect(engine.ran.isEmpty)
        #expect(engine.sent.isEmpty)
        p.confirm()
        await p.settled()
        #expect(engine.ran.isEmpty)
    }

    // 2: once created, the name stays as made; only what isn't made yet changes.
    @Test func afterTheCreateTheNameAndMadePiecesAreFixed() async {
        let engine = RouterProjectFakeEngine()
        engine.createdID = "chan_A"
        engine.outcomes[.addRepo] = .failed("no repo option")
        let p = make(engine)
        p.confirm()
        await p.settled()
        #expect(p.nameFixed)
        p.refine(with: "call it other, repo amontlabs/other")
        await p.settled()
        #expect(p.fields.name == "fjord-ios-companion")
        #expect(p.fields.repo == "amontlabs/other")
        #expect(p.reviseNote?.contains("name stays as made") == true)
        #expect(RouterProjectProposalPill.title(p) == "Project “fjord-ios-companion”")
        engine.outcomes[.addRepo] = nil
        p.confirm()
        await p.settled()
        #expect(engine.ran.filter { $0.tool == .createProject }.count == 1)
        #expect(engine.ran.last(where: { $0.tool == .addRepo })?.args["project"]?.asString == "chan_A")
        #expect(engine.sent.map(\.project) == ["chan_A"])
    }

    // 3: a second proposal waits its turn; after Escape on the first, it shows only once that message leaves the composer,
    // so a Return there is the message's, not a revision of the next.
    @Test func aSecondProposalWaitsForTheFirstAndItsDroppedMessage() {
        let store = quiet()
        let model = RouterModel()
        let a = store.proposeProject(for: "first", first: first, reviser: RouterProjectFakeReviser(), engine: RouterProjectFakeEngine())
        let b = store.proposeProject(for: "second", first: .init(name: "two"), reviser: RouterProjectFakeReviser(),
                                     engine: RouterProjectFakeEngine())
        #expect(store.routerProposal === a)
        #expect(store.routerProposalQueue.map(\.message) == ["second"])
        #expect(model.dropProposal(store: store))
        #expect(model.draft == "first")
        #expect(store.routerProposal == nil)
        #expect(!model.answerProposal(store: store))
        model.draft = ""
        model.proposalDraftChanged(store: store)
        #expect(store.routerProposal === b)
        #expect(store.routerProposalQueue.isEmpty)
    }

    // 4: a pause is a wait, shown, and the proposal goes on when the engine does.
    @Test func aPauseWaitsAndGoesOn() async {
        let engine = RouterProjectFakeEngine()
        engine.waits[.createProject] = "Chrome isn't connected"
        engine.pause = .milliseconds(80)
        let p = make(engine)
        p.confirm()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(p.phase == .waiting("Chrome isn't connected"))
        #expect(!p.canRevise)
        await p.settled()
        #expect(p.phase == .created)
        #expect(engine.ran.filter { $0.tool == .createProject }.count == 1)
    }

    // 4 / round 3 B: a create the engine took but didn't confirm is asked again by its intent; once the engine's proof gives
    // it a project, that project is this one. Never by a name.
    @Test func anUnconfirmedCreateIsAdoptedOnlyByItsOwnProof() async throws {
        let engine = RouterProjectFakeEngine()
        engine.outcomes[.createProject] = .init(ok: false, cause: "the create wasn't confirmed", unsure: true)
        let p = make(engine)
        p.confirm()
        await p.settled()
        #expect(p.nameFixed)
        let create = try #require(engine.ran.first?.intent)
        // Still unconfirmed: a new create is tried (the engine refuses a taken name itself).
        engine.outcomes[.createProject] = .init(ok: false, cause: "a project named fjord-ios-companion already exists")
        p.confirm()
        await p.settled()
        #expect(engine.sent.isEmpty)
        // The engine proves the first one later: it is adopted, with no create run again.
        engine.statuses[create] = CourierIntentStatus(state: .toolDone, project: "chan_A")
        let runs = engine.ran.count
        p.confirm()
        await p.settled()
        #expect(p.phase == .created)
        #expect(engine.ran.count == runs + 3)
        #expect(!engine.ran.dropFirst(runs).contains { $0.tool == .createProject })
        #expect(engine.sent.map(\.project) == ["chan_A"])
    }

    // Round 3 B: a create that surely failed (or wasn't taken) proves nothing: the name is free again.
    @Test func aSurelyFailedCreateIsNotOurs() async {
        let engine = RouterProjectFakeEngine()
        engine.outcomes[.createProject] = .init(ok: false, cause: "a project named fjord-ios-companion already exists")
        let p = make(engine)
        p.confirm()
        await p.settled()
        #expect(!p.nameFixed)
        #expect(engine.sent.isEmpty)
        #expect(p.phase == .failed("The project wasn't created: a project named fjord-ios-companion already exists"))
    }

    // Round 3 B: while an earlier create is still with the engine, no second one is issued.
    @Test func anEarlierCreateStillUnderWayIsWaitedFor() async throws {
        let engine = RouterProjectFakeEngine()
        engine.outcomes[.createProject] = .init(ok: false, cause: "stopped", unsure: true)
        let p = make(engine)
        p.confirm()
        await p.settled()
        let create = try #require(engine.ran.first?.intent)
        engine.statuses[create] = CourierIntentStatus(state: .paused)
        p.confirm()
        await p.settled()
        #expect(engine.ran.count == 1)
        guard case .failed(let why) = p.phase else { Issue.record("went on: \(p.phase)"); return }
        #expect(why.contains("still with the engine"))
    }

    // The message not taken by the engine fails visibly; Try again sends it without redoing anything.
    @Test func aMessageNotTakenFailsAndRetrySendsIt() async {
        let engine = RouterProjectFakeEngine()
        engine.takes = false
        let p = make(engine)
        p.confirm()
        await p.settled()
        guard case .failed(let why) = p.phase else { Issue.record("not failed: \(p.phase)"); return }
        #expect(why.contains("message wasn't sent"))
        engine.takes = true
        p.confirm()
        await p.settled()
        #expect(p.phase == .created)
        #expect(engine.ran.count == 4)
        #expect(engine.sent.count == 1)
    }

    // 5: every part of the reviser's input is redacted.
    @Test func theRevisersInputIsRedacted() {
        let secret = "sk-ant-api03-" + String(repeating: "a", count: 40)
        let f = RouterProjectFields(name: "n", folder: "/p/\(secret)", repo: "o/r", instructions: "use \(secret)")
        var redactor = RouterProjectModelReviser.Redactor()
        let prompt = RouterProjectModelReviser.prompt(f, with: "w \(secret)", message: "m \(secret)", redactor: &redactor)
        #expect(!prompt.contains(secret))
        #expect(prompt.contains("[redacted-1]"))
        #expect(redactor.secrets == [secret])
    }

    // 6: a proposal stopped after its create is saved and restored, and goes on without creating again.
    @Test func aRestoredProposalGoesOnFromItsMadeSteps() async throws {
        let engine = RouterProjectFakeEngine()
        engine.createdID = "chan_A"
        engine.outcomes[.addRepo] = .failed("no repo option")
        let store = quiet()
        let p = store.proposeProject(for: "m", first: first, reviser: RouterProjectFakeReviser(), engine: engine)
        p.confirm()
        await p.settled()
        let saved = store.routerProposalsSaved
        #expect(saved.first?.made == [.create])
        #expect(saved.first?.project == "chan_A")
        let data = try JSONEncoder().encode(PersistedState(settings: AppSettings(), routerProposals: saved))
        let read = try JSONDecoder().decode(PersistedState.self, from: data)
        let again = quiet()
        let engine2 = RouterProjectFakeEngine()
        again.restoreProposals(read.routerProposals ?? [], reviser: RouterProjectFakeReviser(), engine: engine2)
        let q = try #require(again.routerProposal)
        q.settleAfter = nil
        #expect(q.fields == first)
        #expect(q.nameFixed)
        guard case .failed = q.phase else { Issue.record("not stopped: \(q.phase)"); return }
        q.confirm()
        await q.settled()
        #expect(engine2.ran.map(\.tool) == [.addRepo, .setInstructions, .preapproveFolder])
        #expect(engine2.sent.map(\.project) == ["chan_A"])
    }

    // Round 2 / 3 C: a delivery handed over before a quit is reconciled with the engine's record, never sent twice.
    @Test func aRestoredDeliveryIsReconciledNotResent() async throws {
        func restored(_ state: CourierState?, up: Bool = true) async throws -> (RouterProjectProposal, RouterProjectFakeEngine) {
            let engine = RouterProjectFakeEngine()
            engine.up = up
            if let state { engine.statuses[7] = CourierIntentStatus(state: state) }
            let store = quiet()
            store.restoreProposals([.init(message: "m", fields: first, made: [.create, .repo, .instructions, .folder], project: "chan_A",
                                          stopped: "Fjord quit as your message went", sent: 7)],
                                   reviser: RouterProjectFakeReviser(), engine: engine)
            let p = try #require(store.routerProposal)
            p.settleAfter = nil
            await store.reconciling?.value
            return (p, engine)
        }
        // Delivered or under way: made at relaunch, without a Return, and nothing is sent.
        let (delivered, e1) = try await restored(.delivered)
        #expect(delivered.phase == .created && e1.sent.isEmpty && e1.ran.isEmpty)
        let (pending, e2) = try await restored(.taken)
        #expect(pending.phase == .created && e2.sent.isEmpty)
        // The engine can't say: it stays stopped, and Return doesn't send.
        let (unknown, e3) = try await restored(nil, up: false)
        unknown.confirm()
        await unknown.settled()
        #expect(e3.sent.isEmpty)
        guard case .failed = unknown.phase else { Issue.record("not stopped: \(unknown.phase)"); return }
        // Failed: Return sends it.
        let (failed, e4) = try await restored(.failed)
        failed.confirm()
        await failed.settled()
        #expect(failed.phase == .created && e4.sent.map(\.project) == ["chan_A"])
    }

    // Round 3 C: words being handed over when the app quit (no id yet) are looked up by the engine before anything is sent.
    @Test func aSendWithoutItsIdIsLookedUpFirst() async throws {
        let marker = RouterProjectProposal.Sending(words: "m", project: "chan_A", at: Date())
        func restored(found: Bool) async throws -> (RouterProjectProposal, RouterProjectFakeEngine) {
            let engine = RouterProjectFakeEngine()
            if found { engine.byWords["m"] = 9; engine.statuses[9] = CourierIntentStatus(state: .delivered) }
            let store = quiet()
            store.restoreProposals([.init(message: "m", fields: first, made: [.create, .repo, .instructions, .folder], project: "chan_A",
                                          stopped: "Fjord quit as your message went", sending: marker)],
                                   reviser: RouterProjectFakeReviser(), engine: engine)
            let p = try #require(store.routerProposal)
            p.settleAfter = nil
            await store.reconciling?.value
            return (p, engine)
        }
        let (went, e1) = try await restored(found: true)
        #expect(went.phase == .created && e1.sent.isEmpty && went.sentIntent == 9)
        let (none, e2) = try await restored(found: false)
        #expect(none.sending == nil)
        none.confirm()
        await none.settled()
        #expect(e2.sent.count == 1)
    }

    // Round 3 C: the marker is kept while the send is being handed over, and gives way to the intent.
    @Test func theSendingMarkerIsSavedBeforeTheSendReturns() async throws {
        let store = quiet()
        let engine = SlowSendEngine()
        let p = store.proposeProject(for: "m", first: .init(name: "s"), reviser: RouterProjectFakeReviser(), engine: engine)
        p.settleAfter = nil
        p.confirm()
        await waitUntil { engine.asked }
        #expect(store.routerProposalsSaved.first?.sending?.words == "m")
        engine.release()
        await p.settled()
        #expect(p.sending == nil && p.sentIntent == 5)
    }

    // Round 3 C: Escape on a restored proposal whose message went doesn't put it back as unsent.
    @Test func escapeAfterAReconcileThatSaysItWentKeepsTheComposerEmpty() async throws {
        let engine = RouterProjectFakeEngine()
        engine.statuses[7] = CourierIntentStatus(state: .taken)
        let store = quiet()
        store.restoreProposals([.init(message: "m", fields: first, made: [.create, .repo, .instructions, .folder], project: "chan_A",
                                      stopped: "x", sent: 7)], reviser: RouterProjectFakeReviser(), engine: engine)
        let p = try #require(store.routerProposal)
        p.settleAfter = .seconds(30)
        await store.reconciling?.value
        let model = RouterModel()
        if store.routerProposal != nil { _ = model.dropProposal(store: store) }
        #expect(model.draft.isEmpty)
        #expect(engine.sent.isEmpty)
        // Not yet reconciled (the engine couldn't say): the message comes back, with a warning in the history.
        let q = RouterProjectProposal(saved: .init(message: "n", fields: first, made: [.create], project: "chan_A", stopped: "x", sent: 8),
                                      reviser: RouterProjectFakeReviser(), engine: engine)
        #expect(q.drop() == "n")
        #expect(q.endNote?.contains("can't tell") == true)
    }

    // Round 2, 4: words a revision hadn't taken in when the app quit come back in the composer.
    @Test func pendingRevisionsAreSavedAndComeBackInTheComposer() async throws {
        let store = quiet()
        let p = store.proposeProject(for: "m", first: first, reviser: RouterProjectFakeReviser(delay: .seconds(5)),
                                     engine: RouterProjectFakeEngine())
        p.refine(with: "call it x")
        p.refine(with: "no repo")
        await Task.yield()
        let saved = store.routerProposalsSaved
        #expect(saved.first?.words == ["call it x", "no repo"])
        _ = p.drop()
        let again = quiet()
        again.restoreProposals(saved, reviser: RouterProjectFakeReviser(), engine: RouterProjectFakeEngine())
        let model = RouterModel()
        model.proposalDraftChanged(store: again)
        #expect(model.draft == "call it x no repo")
        #expect(again.routerProposalsSaved.first?.words == nil)
    }

    // Round 2, 5 / round 3 E: placeholders map back from every input of the call; one that maps to nothing leaves its field.
    @Test func redactionRoundTripsThroughTheReviser() async throws {
        let secret = "sk-ant-api03-" + String(repeating: "a", count: 40)
        let other = "ghp_" + String(repeating: "b", count: 36)
        let f = RouterProjectFields(name: "n", folder: "/p/\(secret)/x", repo: "o/r", instructions: "use \(secret) now")
        let reviser = RouterProjectModelReviser(ask: { _, prompt, _ in
            #expect(!prompt.contains(secret) && !prompt.contains(other))
            // The folder unchanged, the instructions naming the secret from your words, the repo a placeholder it never got.
            return ["name": "n", "folder": "/p/[redacted-1]/x", "repo": "[redacted-9]", "instructions": "token [redacted-2]"]
        })
        let out = try await reviser.revise(f, with: "set instructions to token \(other)", message: "m")
        #expect(out.fields.folder == f.folder)
        #expect(out.fields.instructions == "token \(other)")
        #expect(out.fields.repo == "o/r")
        #expect(out.unapplied == ["repo"])
        // Applied: the field stays, and the pill says it couldn't apply that part.
        let p = RouterProjectProposal(message: "m", first: f, reviser: StubReviser(revision: out), engine: RouterProjectFakeEngine())
        p.refine(with: "x")
        await p.settled()
        #expect(p.fields.repo == "o/r")
        #expect(p.reviseNote?.contains("Couldn't apply that part") == true)
    }

    // Round 3 E: a redacted name that matches several projects asks.
    @Test func aRedactedNameMatchingSeveralProjectsAsks() {
        let secret = "sk-ant-api03-" + String(repeating: "a", count: 40)
        let context = RouterProjectContext(projects: [
            .init(id: "chan_1", name: "x \(secret)"),
            .init(id: "chan_2", name: "x sk-ant-api03-" + String(repeating: "c", count: 40)),
        ], routings: [])
        let decider = RouterProjectDecider(jev: nil, sonnet: { _, _, _ in throw RouterTools.Failure("unused") })
        #expect(decider.resolve(RouterTools.redacted("x \(secret)"), in: context) == nil)
        #expect(decider.resolve("x \(secret)", in: context)?.id == "chan_1")
    }

    // Round 2, 6: Escape while waiting on claude.ai drops it: the message is back, and the history can say what may still happen.
    @Test func escapeWhileWaitingDropsIt() async {
        let store = quiet()
        let model = RouterModel()
        let engine = RouterProjectFakeEngine()
        engine.waits[.createProject] = "Chrome isn't connected"
        engine.pause = .milliseconds(150)
        let p = store.proposeProject(for: "set up the iOS app", first: first, reviser: RouterProjectFakeReviser(), engine: engine)
        p.settleAfter = nil
        p.confirm()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(p.phase == .waiting("Chrome isn't connected"))
        #expect(model.dropProposal(store: store))
        #expect(model.draft == "set up the iOS app")
        #expect(store.routerProposal == nil)
        #expect(p.endNote?.contains("may still create") == true)
        await p.settled()
        #expect(engine.sent.isEmpty)
        #expect(engine.ran.count == 1)
    }

    // The message's tags go after your words to the engine.
    @Test func whatTheMessageTagsGoesAfterIt() async {
        let engine = RouterProjectFakeEngine()
        let p = RouterProjectProposal(message: "look at it", tagged: "@CI: a category", first: .init(name: "s"),
                                      reviser: RouterProjectFakeReviser(), engine: engine)
        p.settleAfter = nil
        p.confirm()
        await p.settled()
        #expect(engine.sent.first?.words == "look at it")
        #expect(engine.delivered == ["look at it\n\n@CI: a category"])
    }

    @Test func returnInTheComposerRevisesWithWordsAndCreatesWithout() async {
        let store = quiet()
        let model = RouterModel()
        let engine = RouterProjectFakeEngine()
        let p = store.proposeProject(for: "m", first: first, reviser: RouterProjectFakeReviser(), engine: engine)
        p.settleAfter = nil
        model.draft = "call it fjord-ios"
        #expect(model.answerProposal(store: store))
        #expect(model.draft.isEmpty)
        #expect(engine.ran.isEmpty)
        #expect(model.answerProposal(store: store))
        await p.settled()
        #expect(engine.ran.first?.args["name"]?.asString == "fjord-ios")
    }
}

/// A reviser that answers `revision`.
@MainActor private struct StubReviser: RouterProjectReviser {
    var revision: RouterProjectRevision
    func revise(_ current: RouterProjectFields, with text: String, message: String) async throws -> RouterProjectRevision { revision }
}

/// An engine whose send waits until released (the window between handing over and the id coming back).
@MainActor private final class SlowSendEngine: RouterProjectEngine {
    private(set) var asked = false
    private var gate: CheckedContinuation<Void, Never>?
    func release() { gate?.resume(); gate = nil }
    func run(_ tool: CourierTool, _ args: [String: JSON], waiting: @escaping @MainActor (String?) -> Void) async -> RouterProjectOutcome {
        .init(ok: true, intent: 1)
    }
    func send(_ words: String, display: String, to project: String, named name: String) async -> Int {
        asked = true
        await withCheckedContinuation { gate = $0 }
        return 5
    }
    func status(of id: Int) async -> CourierIntentStatus? { nil }
    func intent(matching words: String, project: String?, since: Date) async -> CourierLookup { .none }
}
