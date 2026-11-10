import Foundation
import Testing
@testable import Fjord

/// Briefs from before T3 (`chan_…`, `local:…`) never show, and are purged once T3 has listed what it has.
@MainActor @Suite struct RouterBriefPurgeTests {
    private let dir = TempDir()

    /// A store whose engine already holds a brief for each of these projects, over a fresh briefs.db.
    private func briefs(_ projects: [String], store: Store, db: BriefStore = MemoryBriefStore()) async -> (RouterBriefs, RouterBriefEngine) {
        let src = FakeBriefSource(), model = FakeBriefModel()
        model.answer = { _ in #"{"now":["Building."],"needs_you":[],"purpose":""}"# }
        for p in projects {
            src.setThreads(p, [briefThread("t1", .working)])
        }
        let engine = makeEngine(src, model, store: db)
        engine.start(); await engine.idle()
        store.routerBriefs.use(engine, log: try! BriefLog(path: dir.path("briefs.db").path))
        return (store.routerBriefs, engine)
    }

    private func synced(_ store: Store, _ threads: [T3JSON], projects: [T3JSON]) {
        var shell = T3Fixture.state(threads, projects: projects)
        shell.apply(.synchronized)
        store.t3.store.seed(shell)
        store.applyShell(nil)
    }

    @Test func thePageHoldsOnlyTheProjectsT3Lists() async {
        let store = Store.reading([T3Fixture.shell("th_1", project: "p1")])
        let (briefs, engine) = await briefs(["p1", "chan_old", "local:folder"], store: store)
        #expect(Set(engine.docs.keys) == ["p1", "chan_old", "local:folder"])
        synced(store, [T3Fixture.shell("th_1", project: "p1")], projects: [T3Fixture.project("p1", root: "/code/app")])
        #expect(Set(briefs.docs.keys) == ["p1"] && Set(engine.docs.keys) == ["p1"])
        #expect(briefs.page().sections.map(\.doc.project) == ["p1"])
    }

    @Test func nothingShowsBeforeT3HasAnswered() async {
        let store = Store()
        store.persists = false
        let (briefs, _) = await briefs(["chan_old"], store: store)
        #expect(briefs.t3Listing() == nil && briefs.docs.isEmpty)
    }

    @Test func aLeadAboutAnOldProjectIsHidden() async {
        let store = Store.reading([T3Fixture.shell("th_1", project: "p1")])
        let db = MemoryBriefStore()
        db.setLead(GeneralBrief(forYou: #"<t id="chan_old/t1">Old</t>"#, worthALook: "", at: 1))
        let (briefs, engine) = await briefs(["p1"], store: store, db: db)
        engine.purge(projects: ["p1"], threads: ["th_1"])  // would clear it
        synced(store, [T3Fixture.shell("th_1", project: "p1")], projects: [T3Fixture.project("p1", root: "/code/app")])
        #expect(!briefs.general.forYou.contains("chan_old"))
    }

    @Test func thePurgeDropsBriefsCursorsMarksAndTheLeadOfOldProjects() async {
        let db = MemoryBriefStore()
        let src = FakeBriefSource(), model = FakeBriefModel()
        for p in ["p1", "chan_old"] { src.setThreads(p, [briefThread("t1", .working)]) }
        model.answer = { _ in #"{"now":["Building."],"needs_you":[],"purpose":""}"# }
        let engine = makeEngine(src, model, store: db)
        engine.start(); await engine.idle()
        engine.setMark(.told, "th_1@5", on: true); engine.setMark(.told, "gone@5", on: true)
        engine.setMark(.notified, "done:th_1@9", on: true); engine.setMark(.notified, "done:gone@9", on: true)
        engine.setMark(.notified, "ask:req1", on: true)
        #expect(db.latest("chan_old") != nil && db.key("chan_old") != nil)
        db.setLead(GeneralBrief(forYou: #"<t id="chan_old/t1">Old</t>"#, worthALook: "", at: 1))

        engine.purge(projects: ["p1"], threads: ["th_1"])
        await engine.idle()
        #expect(db.latest("chan_old") == nil && db.key("chan_old") == nil && db.latest("p1") != nil)
        #expect(engine.docs["chan_old"] == nil && engine.docs["p1"] != nil)
        #expect(db.marks().told == ["th_1@5"] && db.marks().notified == ["done:th_1@9", "ask:req1"])
        #expect(!engine.general.forYou.contains("chan_old") && !(db.lead()?.forYou.contains("chan_old") ?? false))
    }

    @Test func theLogForgetsOldProjectsAndThreads() throws {
        let dir = TempDir()
        let log = try BriefLog(path: dir.path("briefs.db").path)
        for p in ["p1", "chan_old"] { log.append(BriefItem(seq: 0, id: "i-\(p)", at: 1, kind: .message, thread: "t", text: "x"), project: p) }
        let facts = BriefThreadFacts(AgentThread(id: "t", title: "T"))
        log.setSeen("th_1", facts); log.setSeen("old", facts)
        log.purge(keepingProjects: ["p1"], threads: ["th_1"])
        #expect(log.projects() == ["p1"] && Set(log.seen().keys) == ["th_1"])
    }

    @Test func aRelaunchWithoutAnyoneListedPurgesNothing() async {
        let store = Store()
        store.persists = false
        let db = MemoryBriefStore()
        let (briefs, _) = await briefs(["chan_old"], store: store, db: db)
        briefs.threadsChanged(store: store)  // T3 hasn't answered yet
        #expect(db.latest("chan_old") != nil)
        synced(store, [], projects: [])  // T3 answered with nothing at all
        #expect(briefs.t3Listing() == nil && db.latest("chan_old") != nil)
    }

    @Test func decisionsFromClaudeAreDroppedOnLoad() {
        var saved = RouterSaved()
        var old = RouterDecision(at: Date(), trigger: .you("hello"), decision: .init(target: "x"), outcome: .done)
        old.decision.targetID = "session:abc"
        var mixed = RouterDecision(at: Date(), trigger: .you("hi"), decision: .init(target: "y"), outcome: .done)
        mixed.links.threads = ["chan_old/th_1"]
        var fresh = RouterDecision(at: Date(), trigger: .you("yo"), decision: .init(target: "z"), outcome: .done)
        fresh.decision.targetID = "t3-thread:th_1"
        saved.decisions = [old, mixed, fresh]
        saved.dropClaudeEra()
        #expect(saved.decisions.map(\.id) == [fresh.id])
    }
}

@MainActor @Suite struct RouterBriefRewriteTests {
    @Test func aForcedRewriteCallsEachListedProjectOnceWithNothingNewAndThenWritesTheLead() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        for p in ["p1", "p2", "chan_old"] { src.setThreads(p, [briefThread("t1", .working)]) }
        model.answer = { _ in #"{"now":["Building."],"needs_you":[],"purpose":""}"# }
        let store = MemoryBriefStore()
        for p in ["p1", "p2", "chan_old"] { store.setKey(p, RouterBriefEngine.triggerKey(src.boards[p]!)) }
        let engine = makeEngine(src, model, store: store)
        for p in ["p1", "p2", "chan_old"] { engine.boardChanged(p) }
        await engine.idle()
        #expect(model.contexts.isEmpty && model.leadContexts.isEmpty)  // the facts are the ones the prose was written from

        engine.rewrite(projects: ["p1", "p2"])
        #expect(engine.rewriting)
        await engine.idle()
        #expect(!engine.rewriting && model.contexts.count == 2 && model.leadContexts.count == 1)
        #expect(engine.docs["p1"]?.now == ["Building."] && engine.docs["chan_old"]?.now.isEmpty == true)
        #expect(!engine.general.isEmpty)
    }

    @Test func aFailedRewriteLeavesTheOldProseBeingRewritten() async {
        let src = FakeBriefSource(), model = FakeBriefModel()
        src.setThreads("p1", [briefThread("t1", .working)])
        let engine = makeEngine(src, model)
        engine.boardChanged("p1"); await engine.idle()
        model.failing = true
        engine.rewrite(projects: ["p1"]); await engine.idle()
        #expect(engine.docs["p1"]?.proseStale == true && !engine.rewriting)
    }
}
