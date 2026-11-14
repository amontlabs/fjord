import Foundation
import Testing
@testable import Fjord

/// Fjord's own T3 project (Show me's explainers) is cut out of the shell where it comes in, so no Router surface lists it,
/// and the two reads that don't go through the shell (T3's search, a thread's snapshot) refuse its threads by hand.
@MainActor
@Suite struct T3ShellHidden {
    private let root = "/Users/me/Library/Application Support/Fjord/Explainers"
    private var projects: [T3JSON] {
        [T3Fixture.project("p1", root: "/code/app"), T3Fixture.project("px", title: "Fjord explainers", root: root)]
    }
    private var threads: [T3JSON] {
        [T3Fixture.shell("ta", title: "Fix the login bug", project: "p1"),
         T3Fixture.shell("tx", title: "Explain the token", status: "running", project: "px"),
         T3Fixture.shell("tx-sub", title: "A subagent", project: "px", extra: [
             "lineage": ["parentThreadId": "tx", "relationshipToParent": "subagent", "rootThreadId": "tx"]])]
    }

    @Test func withoutDropsTheProjectAndEveryThreadInIt() {
        let whole = T3Fixture.state(threads, projects: projects)
        let shell = whole.without(projectRoot: root + "/")
        #expect(Set(shell.projects.keys) == ["p1"])
        #expect(Set(shell.threads.keys) == ["ta"])
        #expect(shell.sequence == whole.sequence && shell.answered == whole.answered)
        #expect(whole.without(projectRoot: nil) == whole)
        #expect(whole.without(projectRoot: "/nowhere") == whole)
    }

    @Test func theStoreKeepsTheWholeShellApartFromTheOneTheRouterReads() {
        let t3 = T3Store()
        var told: [T3ShellItem?] = []
        t3.onShell = { told.append($0) }
        t3.seed(T3Fixture.state(threads, projects: projects), notify: false)
        #expect(t3.shell.threads.count == 3)
        // Hiding filters what's held and says so, once.
        t3.hiddenRoot = root
        #expect(Set(t3.shell.threads.keys) == ["ta"] && t3.shell.projects["px"] == nil && t3.hidden.threads.count == 3)
        #expect(told.count == 1 && told[0] == nil)
        t3.hiddenRoot = root
        #expect(told.count == 1)
        #expect(t3.isHidden(thread: "tx") && !t3.isHidden(thread: "ta") && !t3.isHidden(thread: "nope"))
        #expect(!t3.projects.contains { $0.id == "px" })
        // An update about a hidden thread lands in the whole shell only.
        let before = t3.shell
        t3.apply(T3ShellItem(json: ["kind": "thread.updated", "sequence": 200, "location": "active",
                                    "thread": T3Fixture.shell("tx", title: "Explain the token", project: "px")]))
        #expect(t3.shell.threads == before.threads && t3.shell.projects == before.projects)
        // A new hidden thread too; a new thread elsewhere reaches both.
        t3.apply(T3ShellItem(json: ["kind": "thread.updated", "sequence": 201, "location": "active",
                                    "thread": T3Fixture.shell("ty", project: "px")]))
        t3.apply(T3ShellItem(json: ["kind": "thread.updated", "sequence": 202, "location": "active",
                                    "thread": T3Fixture.shell("tb", project: "p1")]))
        #expect(Set(t3.shell.threads.keys) == ["ta", "tb"] && t3.hidden.threads["ty"] != nil)
        // Seeding while hidden filters too.
        t3.seed(T3Fixture.state(threads, projects: projects), notify: false)
        #expect(Set(t3.shell.threads.keys) == ["ta"])
    }

    @Test func noRouterSurfaceListsTheHiddenProject() async {
        let s = Store.reading(threads, projects: projects)
        s.agents.enabled = true
        #expect(s.threads["tx"] != nil)
        s.t3.store.hiddenRoot = root
        #expect(s.threads["tx"] == nil && s.threads["tx-sub"] == nil && s.threads["ta"] != nil)
        #expect(!s.t3.store.listedThreads.contains { $0.projectId == "px" })
        #expect(s.t3Project(forFolder: root) == nil)
    }

    @Test func searchAndReadRefuseTheHiddenProjectsThreads() async throws {
        let s = Store.reading(threads, projects: projects)
        s.setRouterEnabled(true, now: Date())
        s.t3.store.hiddenRoot = root
        let tools = RouterTools(store: s)
        tools.threadSearch = { _, _ in
            [ThreadMatch(threadId: "tx", projectId: "px", source: "assistant", snippet: "the token"),
             ThreadMatch(threadId: "ta", projectId: "p1", source: "user", snippet: "the token?")]
        }
        let found = try #require(await tools.call("search_threads", ["query": "token"]))
        #expect(!found.isError, "\(found.text)")
        let result = try #require(try JSONSerialization.jsonObject(with: Data(found.text.utf8)) as? [String: Any])
        let hits = try #require(result["matches"] as? [[String: Any]])
        #expect(hits.map { $0["thread"] as? String } == ["ta"])
        tools.threadRead = { id in T3Projection(json: ["thread": T3Fixture.shell(id), "messages": [T3Fixture.message("m1", text: "hi")]]) }
        #expect(await tools.call("read_thread", ["thread": "tx"])?.isError == true)
        #expect(await tools.call("read_thread", ["thread": "ta"])?.isError == false)
    }
}
