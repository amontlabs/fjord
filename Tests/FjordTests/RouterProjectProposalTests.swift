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
        p.onCreated = { made = $0 }
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

    // 3: a second proposal waits its turn and shows when the first ends; neither message is orphaned.
    @Test func aSecondProposalWaitsForTheFirst() {
        let store = quiet()
        let model = RouterModel()
        let a = store.proposeProject(for: "first", first: first, reviser: RouterProjectFakeReviser(), engine: RouterProjectFakeEngine())
        let b = store.proposeProject(for: "second", first: .init(name: "two"), reviser: RouterProjectFakeReviser(),
                                     engine: RouterProjectFakeEngine())
        #expect(store.routerProposal === a)
        #expect(store.routerProposalQueue.map(\.message) == ["second"])
        #expect(model.dropProposal(store: store))
        #expect(model.draft == "first")
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

    // 4: "name taken" for a create this proposal issued (unconfirmed) is its own project: it goes on with its id.
    @Test func nameTakenByItsOwnEarlierCreateGoesOn() async {
        let engine = RouterProjectFakeEngine()
        engine.outcomes[.createProject] = .init(ok: false, cause: "the create wasn't confirmed")
        let p = make(engine)
        p.confirm()
        await p.settled()
        #expect(p.nameFixed)
        engine.outcomes[.createProject] = .init(ok: false, cause: "a project named fjord-ios-companion already exists",
                                                project: "chan_A", refused: true)
        p.confirm()
        await p.settled()
        #expect(p.phase == .created)
        #expect(engine.sent.map(\.project) == ["chan_A"])
    }

    // 4: a name someone else's project has (refused at once) is not adopted.
    @Test func aNameTakenBeforeIsNotAdopted() async {
        let engine = RouterProjectFakeEngine()
        engine.outcomes[.createProject] = .init(ok: false, cause: "a project named fjord-ios-companion already exists",
                                                project: "chan_other", refused: true)
        let p = make(engine)
        p.confirm()
        await p.settled()
        p.confirm()
        await p.settled()
        #expect(!p.nameFixed)
        #expect(engine.sent.isEmpty)
        #expect(p.phase == .failed("The project wasn't created: a project named fjord-ios-companion already exists"))
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

    // 5: every proposal field the reviser sends is redacted.
    @Test func theRevisersInputIsRedacted() {
        let secret = "sk-ant-api03-" + String(repeating: "a", count: 40)
        let f = RouterProjectFields(name: "n", folder: "/p/\(secret)", repo: "o/r", instructions: "use \(secret)")
        let prompt = RouterProjectModelReviser.prompt(f, with: "w", message: "m")
        #expect(!prompt.contains(secret))
        #expect(RouterTools.redacted(secret) != secret)
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
