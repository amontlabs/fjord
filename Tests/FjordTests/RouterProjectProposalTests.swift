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
        let store = Store()
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

    @Test func returnInTheComposerRevisesWithWordsAndCreatesWithout() async {
        let store = Store()
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
