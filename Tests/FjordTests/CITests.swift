import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite struct CI {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func check(_ name: String, _ status: String = "completed", _ conclusion: String? = "success", started: TimeInterval = 0,
                       completed: TimeInterval? = nil, app: String? = "circleci", suite: Int? = nil) -> GHCheckRuns.Run {
        GHCheckRuns.Run(app: GHCheckRuns.App(slug: app), checkSuite: suite.map(GHCheckRuns.Suite.init), name: name, status: status, conclusion: conclusion, headSha: "s",
                        startedAt: t0.addingTimeInterval(started), completedAt: completed.map { t0.addingTimeInterval($0) })
    }

    private func combined(_ statuses: [GHCombinedStatus.Status] = []) -> GHCombinedStatus {
        GHCombinedStatus(state: "success", totalCount: statuses.count, sha: "s", statuses: statuses)
    }

    // MARK: Reading GitHub's answer

    @Test func aWorkflowsExecutionIsItsRunAndAttempt() {
        var run = GHWorkflowRuns.Run(name: "build", workflowId: 1, headSha: "s", displayTitle: "Fix", updatedAt: t0, status: "completed",
                                     conclusion: "failure", checkSuiteId: nil, id: 42, runAttempt: 1)
        let once = Store.readCI(runs: [run], sha: "s", checks: [], combined: combined()).workflows[0]
        run.runAttempt = 2
        let again = Store.readCI(runs: [run], sha: "s", checks: [], combined: combined()).workflows[0]
        #expect(once.run == "ci:s:42#1" && again.run == "ci:s:42#2")
    }

    @Test func aRepoWithOnlyExternalChecksHasAStateNamesAndAChangeTime() {
        let failed = Store.readCI(runs: [], sha: nil, checks: [check("build", "completed", "failure", started: 10, completed: 90),
                                                                check("lint", started: 5, completed: 40)], combined: combined())
        #expect(failed.workflows.map(\.state) == [.failure])
        #expect(failed.workflows.first?.failing == ["build"])
        #expect(failed.changedAt == t0.addingTimeInterval(90))
        let running = Store.readCI(runs: [], sha: nil, checks: [check("build", "in_progress", nil, started: 30)], combined: combined())
        #expect(running.workflows.map(\.state) == [.pending])
        // Still running: it last changed when it started.
        #expect(running.changedAt == t0.addingTimeInterval(30))
    }

    @Test func aRepoWithOnlyLegacyStatusesHasAChangeTime() {
        let status = GHCombinedStatus.Status(context: "ci/jenkins", state: "failure", createdAt: t0, updatedAt: t0.addingTimeInterval(20))
        let reading = Store.readCI(runs: [], sha: nil, checks: [], combined: combined([status]))
        #expect(reading.workflows.map(\.state) == [.failure] && reading.workflows.first?.failing == ["ci/jenkins"])
        #expect(reading.changedAt == t0.addingTimeInterval(20))
        let neverUpdated = GHCombinedStatus.Status(context: "ci/x", state: "success", createdAt: t0, updatedAt: nil)
        #expect(Store.readCI(runs: [], sha: nil, checks: [], combined: combined([neverUpdated])).changedAt == t0)
    }

    @Test func theLatestChangeAmongActionsAndExternalSourcesWins() {
        let run = GHWorkflowRuns.Run(name: "build", workflowId: 1, headSha: "s", displayTitle: "Fix", updatedAt: t0.addingTimeInterval(50),
                                     status: "completed", conclusion: "success", checkSuiteId: 10)
        let other = GHWorkflowRuns.Run(name: "old", workflowId: 2, headSha: "older", displayTitle: nil, updatedAt: t0.addingTimeInterval(500),
                                       status: "completed", conclusion: "failure", checkSuiteId: 20)
        // A github-actions check run is the Actions run again, not an external source.
        let mirror = check("build", started: 0, completed: 900, app: "github-actions")
        let external = check("deploy", started: 10, completed: 70)
        let reading = Store.readCI(runs: [run, other], sha: "s", checks: [mirror, external], combined: combined())
        // The run on another commit is left out, and the mirror adds no failure or change of its own.
        #expect(reading.workflows.map(\.id) == ["1", Store.externalWorkflowID])
        #expect(reading.workflows.map(\.state) == [.success, .success])
        #expect(reading.changedAt == t0.addingTimeInterval(70))
        let nothing = Store.readCI(runs: [], sha: nil, checks: [], combined: combined())
        #expect(nothing.changedAt == nil && nothing.workflows.isEmpty)
    }

    private func workflow(_ name: String, id: Int, suite: Int?, _ conclusion: String?, sha: String = "s",
                          status: String = "completed") -> GHWorkflowRuns.Run {
        GHWorkflowRuns.Run(name: name, workflowId: id, headSha: sha, displayTitle: "Fix", updatedAt: t0, status: status,
                           conclusion: conclusion, checkSuiteId: suite)
    }

    @Test func aFailedWorkflowIsNamedByItsFailedJobs() {
        let ci = workflow("CI", id: 1, suite: 10, "failure")
        let jobs = [check("Linux build", "completed", "failure", app: "github-actions", suite: 10),
                    check("macOS test", "completed", "success", app: "github-actions", suite: 10),
                    check("Windows test", "completed", "timed_out", app: "github-actions", suite: 10)]
        let reading = Store.readCI(runs: [ci], sha: "s", checks: jobs, combined: combined())
        #expect(reading.workflows.map(\.state) == [.failure])
        #expect(reading.workflows.first?.failing == ["Linux build", "Windows test"])
    }

    @Test func aFailedWorkflowWithNoJobsKeepsItsOwnName() {
        let ci = workflow("CI", id: 1, suite: 10, "failure")
        // No job at all, a job of another suite, and a job with no suite known.
        #expect(Store.readCI(runs: [ci], sha: "s", checks: [], combined: combined()).workflows.map(\.failing) == [["CI"]])
        let elsewhere = [check("Other", "completed", "failure", app: "github-actions", suite: 99)]
        #expect(Store.readCI(runs: [ci], sha: "s", checks: elsewhere, combined: combined()).workflows.map(\.failing) == [["CI"]])
        let unknown = workflow("CI", id: 1, suite: nil, "failure")
        let job = [check("Linux build", "completed", "failure", app: "github-actions")]
        #expect(Store.readCI(runs: [unknown], sha: "s", checks: job, combined: combined()).workflows.map(\.failing) == [["CI"]])
    }

    @Test func jobsOfRunsThatDoNotCountAreLeftOut() {
        // A failed job of a workflow run the push's selection didn't take (another trigger, an older run) says nothing.
        let ci = workflow("CI", id: 1, suite: 10, "success")
        let stray = [check("Triage", "completed", "failure", app: "github-actions", suite: 30)]
        let reading = Store.readCI(runs: [ci], sha: "s", checks: stray, combined: combined())
        #expect(reading.workflows.map(\.state) == [.success] && reading.workflows.map(\.failing) == [[]])
    }

    @Test func actionsJobsAndExternalChecksFailEachInTheirOwnWorkflow() {
        let ci = workflow("CI", id: 1, suite: 10, "failure")
        let checks = [check("Linux build", "completed", "failure", app: "github-actions", suite: 10),
                      check("deploy", "completed", "failure")]
        let reading = Store.readCI(runs: [ci], sha: "s", checks: checks, combined: combined())
        #expect(reading.workflows.map(\.id) == ["1", Store.externalWorkflowID])
        #expect(reading.workflows.map(\.failing) == [["Linux build"], ["deploy"]])
    }

    @Test func theSuiteLinksAJobToItsWorkflowRunInGitHubsJSON() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let job = try decoder.decode(GHCheckRuns.Run.self, from: Data(
            #"{"name":"Linux build","status":"completed","conclusion":"failure","head_sha":"s","app":{"slug":"github-actions"},"check_suite":{"id":10}}"#.utf8))
        let run = try decoder.decode(GHWorkflowRuns.Run.self, from: Data(
            #"{"name":"CI","workflow_id":1,"head_sha":"s","status":"completed","conclusion":"failure","check_suite_id":10}"#.utf8))
        #expect(job.checkSuite?.id == 10 && run.checkSuiteId == 10)
    }

    @Test func aCommitsHeadlineIsItsFirstLine() throws {
        let decoder = JSONDecoder()
        let commit = try decoder.decode(GHCommit.self, from: Data(#"{"commit":{"message":"Respect trailing commas (#1042)\n\nLong body"}}"#.utf8))
        #expect(commit.headline == "Respect trailing commas (#1042)")
    }

    // MARK: Per workflow

    @Test func eachWorkflowHasItsOwnStateAndFailedJobs() {
        let ci = workflow("CI", id: 1, suite: 10, "failure")
        let lint = workflow("Lint", id: 2, suite: 20, "success")
        let docs = workflow("Docs", id: 3, suite: 30, nil, status: "in_progress")
        let jobs = [check("Linux build", "completed", "failure", app: "github-actions", suite: 10),
                    check("Windows test", "completed", "failure", app: "github-actions", suite: 10)]
        let reading = Store.readCI(runs: [ci, lint, docs], sha: "s", checks: jobs, combined: combined())
        // By name: CI, Docs, Lint.
        #expect(reading.workflows.map(\.name) == ["CI", "Docs", "Lint"])
        #expect(reading.workflows.map(\.id) == ["1", "3", "2"])
        #expect(reading.workflows.map(\.state) == [.failure, .pending, .success])
        #expect(reading.workflows[0].failing == ["Linux build", "Windows test"])
        #expect(reading.workflows[1].failing.isEmpty && reading.workflows[2].failing.isEmpty)
    }

    @Test func externalChecksAndStatusesAreOneWorkflowOfTheirOwn() {
        let status = GHCombinedStatus.Status(context: "ci/jenkins", state: "failure", createdAt: t0, updatedAt: t0.addingTimeInterval(20))
        let ci = workflow("CI", id: 1, suite: 10, "success")
        let reading = Store.readCI(runs: [ci], sha: "s", checks: [check("deploy", "completed", "failure", started: 1, completed: 30)],
                                   combined: combined([status]))
        #expect(reading.workflows.map(\.id) == ["1", Store.externalWorkflowID])
        let external = reading.workflows[1]
        #expect(external.state == .failure && external.failing == ["deploy", "ci/jenkins"])
        #expect(external.updatedAt == t0.addingTimeInterval(30))
        // Nothing external, nothing to say about it.
        #expect(Store.readCI(runs: [ci], sha: "s", checks: [], combined: combined()).workflows.map(\.id) == ["1"])
    }

    @Test func aBranchIsReadWorkflowByWorkflowFromOneListOfRuns() async throws {
        let store = Store()
        store.persists = false
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        let paths = PathLog()
        store.gh.session = StubbedGitHub.session { request in
            let path = request.url?.path ?? ""
            paths.add(path)
            switch path {
            case "/repos/a/x/branches/main": return .init(200, #"{"commit":{"sha":"s1","commit":{"message":"Fix"}}}"#)
            case "/repos/a/x/actions/runs":
                return .init(200, #"""
                {"workflow_runs":[
                  {"name":"CI","workflow_id":11,"head_sha":"s1","display_title":"Fix","status":"completed","conclusion":"failure","check_suite_id":5,"html_url":"https://github.com/a/x/actions/runs/1"},
                  {"name":"Lint","workflow_id":12,"head_sha":"s1","display_title":"Fix","status":"completed","conclusion":"success","check_suite_id":6},
                  {"name":"CI","workflow_id":11,"head_sha":"s0","display_title":"Older","status":"completed","conclusion":"success","check_suite_id":4}]}
                """#)
            case "/repos/a/x/commits/s1/check-runs":
                return .init(200, #"""
                {"total_count":1,"check_runs":[{"name":"build","status":"completed","conclusion":"failure","head_sha":"s1","app":{"slug":"github-actions"},"check_suite":{"id":5}}]}
                """#)
            case "/repos/a/x/commits/s1/status":
                return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#)
            default:
                return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        let status = try await store.fetchBranchCI("a/x", branch: "main")
        #expect(status.title == "Fix")
        #expect(status.workflows.map(\.name) == ["CI", "Lint"])
        #expect(status.workflows.map(\.state) == [.failure, .success])
        #expect(status.workflows.map(\.failing) == [["build"], []])
        #expect(status.workflows[0].url?.absoluteString == "https://github.com/a/x/actions/runs/1")
        // The branch's head, one list of runs, the commit's checks and statuses: four calls for the repo, however many workflows.
        #expect(paths.all.count == 4)
        let things = InboxSync.workflowThings(repo: "a/x", branch: "main", status: status)
        #expect(things.map(\.id) == ["workflow:a/x:11@main", "workflow:a/x:12@main"])
    }

    @Test func aBranchIsReadAtItsHeadEvenWhenActionsSkippedThatCommit() async throws {
        let store = Store()
        store.persists = false
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        store.gh.session = StubbedGitHub.session { request in
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            switch comps?.path ?? "" {
            // A docs commit on top: Actions' path filters skip it, an external CI runs on it.
            case "/repos/a/x/branches/main": return .init(200, #"{"commit":{"sha":"s2","commit":{"message":"Docs\n\nBody"}}}"#)
            case "/repos/a/x/actions/runs":
                let run = #"{"name":"CI","workflow_id":11,"head_sha":"s1","display_title":"Fix","status":"completed","conclusion":"success","check_suite_id":5}"#
                return .init(200, query["head_sha"].map { $0 == "s1" } ?? true ? #"{"workflow_runs":[\#(run)]}"# : #"{"workflow_runs":[]}"#)
            case "/repos/a/x/commits/s2/check-runs":
                return .init(200, #"{"total_count":1,"check_runs":[{"id":1,"name":"deploy","status":"completed","conclusion":"failure","head_sha":"s2","app":{"slug":"circleci"}}]}"#)
            case "/repos/a/x/commits/s1/check-runs": return .init(200, #"{"total_count":0,"check_runs":[]}"#)
            case "/repos/a/x/commits/s1/status", "/repos/a/x/commits/s2/status":
                return .init(200, #"{"state":"pending","total_count":0,"sha":"x","statuses":[]}"#)
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        let status = try await store.fetchBranchCI("a/x", branch: "main")
        #expect(status.sha == "s2" && status.title == "Docs")
        #expect(status.workflows.map(\.name) == ["Checks"] && status.workflows.map(\.failing) == [["deploy"]])
    }

    @Test func failedChecksPastTheFirstRunsAreReRunToo() async throws {
        // 120 workflows ran on the PR's head commit, the 101st failing; a workflow whose repo ran 60 others since it failed.
        let store = Store()
        store.persists = false
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        let run = { (id: Int, workflow: Int, conclusion: String) in
            #"{"id":\#(id),"name":"W\#(workflow)","workflow_id":\#(workflow),"head_sha":"s1","status":"completed","conclusion":"\#(conclusion)","check_suite_id":\#(id)}"#
        }
        let all = (1...120).map { run($0, $0, $0 == 101 ? "failure" : "success") }
        let others = (200..<260).map { run($0, $0, "success") }
        store.gh.session = StubbedGitHub.session { request in
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let page = Int(query["page"] ?? "1") ?? 1, size = Int(query["per_page"] ?? "30") ?? 30
            let slice = { (runs: [String]) in
                Array(runs.dropFirst((page - 1) * size).prefix(size))
            }
            switch comps?.path ?? "" {
            case "/repos/a/x/actions/runs" where query["head_sha"] == "s1" && query["branch"] == nil:
                return .init(200, #"{"total_count":120,"workflow_runs":[\#(slice(all).joined(separator: ","))]}"#)
            case "/repos/a/x/actions/runs":
                let runs = others + [run(9, 51, "failure")]
                return .init(200, #"{"total_count":61,"workflow_runs":[\#(slice(runs).joined(separator: ","))]}"#)
            case "/repos/a/x/actions/workflows/51/runs" where query["branch"] == "main" && query["head_sha"] == "s1":
                return .init(200, #"{"total_count":1,"workflow_runs":[\#(run(9, 51, "failure"))]}"#)
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        var pr = InboxFixture.pr(1, repo: "a/x")
        pr.headSha = "s1"
        let performer = StoreActionPerformer(store: store)
        #expect(try await performer.failedRuns(for: pr).map(\.id) == [101])
        var workflow = InboxFixture.pr(1, repo: "a/x")
        workflow.id = "workflow:a/x:51@main"
        workflow.kind = .workflow
        workflow.number = nil
        workflow.branch = "main"
        workflow.ciRun = "ci:s1:9#1"
        #expect(try await performer.failedRuns(for: workflow).map(\.id) == [9])
    }

    @Test func aRenamedBranchIsReadAsTheBranchItIsNowActionsAndAll() async throws {
        // master was renamed main: GitHub answers master's head with main's (the redirect followed), and lists Actions runs
        // filtered by main only.
        let store = Store()
        store.persists = false
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        store.gh.session = StubbedGitHub.session { request in
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            switch comps?.path ?? "" {
            case "/repos/a/x": return .init(200, #"{"full_name":"a/x","default_branch":"master"}"#)
            case "/repos/a/x/branches/master", "/repos/a/x/branches/main":
                return .init(200, #"{"name":"main","commit":{"sha":"s1","commit":{"message":"Fix"}}}"#)
            case "/repos/a/x/actions/runs", "/repos/a/x/actions/workflows/11/runs":
                let run = #"{"id":7,"name":"CI","workflow_id":11,"head_sha":"s1","display_title":"Fix","status":"completed","conclusion":"failure","check_suite_id":5}"#
                return .init(200, query["branch"] == "main" ? #"{"workflow_runs":[\#(run)]}"# : #"{"workflow_runs":[]}"#)
            case "/repos/a/x/commits/s1/check-runs": return .init(200, #"{"total_count":0,"check_runs":[]}"#)
            case "/repos/a/x/commits/s1/status": return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#)
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        let asked = try await store.fetchBranchCI("a/x", branch: "master")
        #expect(asked.branch == "main" && asked.workflows.map(\.name) == ["CI"] && asked.workflows.map(\.state) == [.failure])
        // A rule's branch keeps its things as it names them.
        let things = InboxSync.workflowThings(repo: "a/x", branch: "master", status: asked)
        #expect(things.map(\.id) == ["workflow:a/x:11@master"])
        // Named, labeled and re-run by the name it has now.
        let thing = try #require(things.first)
        #expect(thing.branch == "master" && thing.ciBranch == "main")
        #expect(InboxActions.reference(thing) == "a/x · CI on main")
        let rerun = try await StoreActionPerformer(store: store).failedRuns(for: thing)
        #expect(rerun.map(\.name) == ["CI"])
        store.things = [thing.id: thing]
        // The default branch found as master before the rename is main now.
        let main = try await store.fetchCI("a/x")
        #expect(main.branch == "main" && main.workflows.map(\.name) == ["CI"] && store.defaultBranches["a/x"] == "main")
    }

    @Test func anotherDefaultBranchIsFoundDailyAndAtOnceWhenTheOldOneIsGone() async throws {
        // The repo's default is main, then release; main is deleted after.
        final class Repo: @unchecked Sendable {
            private let lock = NSLock()
            private var _main = "main", _gone: Set<String> = []
            var main: String { get { lock.withLock { _main } } set { lock.withLock { _main = newValue } } }
            var gone: Set<String> { get { lock.withLock { _gone } } set { lock.withLock { _gone = newValue } } }
        }
        let repo = Repo()
        let store = Store()
        store.persists = false
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        store.gh.session = StubbedGitHub.session { request in
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let path = comps?.path ?? ""
            let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if path == "/repos/a/x" { return .init(200, #"{"full_name":"a/x","default_branch":"\#(repo.main)"}"#) }
            if path.hasPrefix("/repos/a/x/branches/") {
                let name = String(path.dropFirst("/repos/a/x/branches/".count))
                guard !repo.gone.contains(name) else { return .init(404, #"{"message":"Branch not found"}"#) }
                let sha = name == "main" ? "s1" : "s2"
                return .init(200, #"{"name":"\#(name)","commit":{"sha":"\#(sha)","commit":{"message":"On \#(name)"}}}"#)
            }
            switch path {
            case "/repos/a/x/actions/runs":
                let sha = query["branch"] == "main" ? "s1" : "s2"
                let run = #"{"name":"CI","workflow_id":11,"head_sha":"\#(sha)","display_title":"On \#(query["branch"] ?? "")","status":"completed","conclusion":"success","check_suite_id":5}"#
                return .init(200, #"{"workflow_runs":[\#(run)]}"#)
            case "/repos/a/x/commits/s1/check-runs", "/repos/a/x/commits/s2/check-runs":
                return .init(200, #"{"total_count":0,"check_runs":[]}"#)
            case "/repos/a/x/commits/s1/status", "/repos/a/x/commits/s2/status":
                return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#)
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        let t = Date()
        #expect(try await store.fetchCI("a/x", now: t).branch == "main")
        // release made the default: known as main for the day, then found.
        repo.main = "release"
        #expect(try await store.fetchCI("a/x", now: t.addingTimeInterval(3600)).branch == "main")
        let next = try await store.fetchCI("a/x", now: t.addingTimeInterval(Store.defaultBranchRecheck + 1))
        #expect(next.branch == "release" && next.title == "On release" && next.workflows.map(\.name) == ["CI"])
        // main made the default again, then deleted for release, within the day: its head gone, release is found at once.
        store.defaultBranches["a/x"] = "main"
        repo.main = "release"
        repo.gone = ["main"]
        let found = try await store.fetchCI("a/x", now: t.addingTimeInterval(Store.defaultBranchRecheck + 60))
        #expect(found.branch == "release" && found.workflows.map(\.name) == ["CI"] && store.defaultBranches["a/x"] == "release")
        // A branch a rule names, deleted: no CI of it, so what was read of it goes.
        repo.gone = ["main", "dev"]
        let dev = try await store.fetchBranchCI("a/x", branch: "dev")
        #expect(dev.sha == nil && InboxSync.workflowThings(repo: "a/x", branch: "dev", status: dev).isEmpty)
    }

    @Test func aDeletedBranchsWorkflowsGoFromTheInbox() async {
        final class Gone: @unchecked Sendable {
            private let lock = NSLock()
            private var _dev = false
            var dev: Bool { get { lock.withLock { _dev } } set { lock.withLock { _dev = newValue } } }
        }
        let gone = Gone()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            switch request.url?.path ?? "" {
            case "/repos/a/x": return .init(200, #"{"full_name":"a/x","default_branch":"main"}"#)
            case "/repos/a/x/branches/dev":
                return gone.dev ? .init(404, #"{"message":"Branch not found"}"#) : .init(200, #"{"name":"dev","commit":{"sha":"s1","commit":{"message":"Fix"}}}"#)
            case "/repos/a/x/actions/runs":
                return .init(200, #"{"workflow_runs":[{"name":"CI","workflow_id":11,"head_sha":"s1","display_title":"Fix","status":"completed","conclusion":"failure","check_suite_id":5}]}"#)
            case "/repos/a/x/commits/s1/check-runs": return .init(200, #"{"total_count":0,"check_runs":[]}"#)
            case "/repos/a/x/commits/s1/status": return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#)
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        var ci = InboxStore.ci
        ci.rules = [Rule(scope: Scope(kinds: [.workflow], in: Pick(include: [.repo("a/x")]), on: ["dev"]),
                         conditions: [.workflow([.failing])], createdAt: .distantPast)]
        s.categories = [ci]
        await s.syncInbox()
        #expect(s.things.keys.sorted() == ["workflow:a/x:11@dev"])
        gone.dev = true
        await s.syncInbox()
        #expect(s.things.isEmpty && s.inboxError == nil)
    }

    /// Optimized, the repos' reads came back as nothing (swiftlang/swift#92698): no workflow was taken, and the reads still
    /// running finished into a group already gone, which crashed. Only an optimized build shows it
    /// (`swift test -c release -Xswiftc -enable-testing`).
    @Test func everyRepoOfARefreshIsReadPastTheFourAtATime() async {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/branches/main") { return .init(200, #"{"name":"main","commit":{"sha":"s1","commit":{"message":"Fix"}}}"#) }
            if path.hasSuffix("/actions/runs") {
                return .init(200, #"{"workflow_runs":[{"name":"CI","workflow_id":11,"head_sha":"s1","display_title":"Fix","status":"completed","conclusion":"failure","check_suite_id":5}]}"#)
            }
            if path.hasSuffix("/check-runs") { return .init(200, #"{"total_count":0,"check_runs":[]}"#) }
            if path.hasSuffix("/status") { return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#) }
            return .init(404, #"{"message":"unrouted"}"#)
        }
        let repos = (0..<12).map { "a/r\($0)" }
        var ci = InboxStore.ci
        ci.rules = [Rule(scope: Scope(kinds: [.workflow], in: Pick(include: repos.map { .repo($0) }), on: ["main"]),
                         conditions: [.workflow([.failing])], createdAt: .distantPast)]
        s.categories = [ci]
        await s.syncInbox()
        #expect(s.things.keys.sorted() == repos.map { "workflow:\($0):11@main" }.sorted())
        #expect(s.inboxError == nil)
    }

    @Test func aBranchIsPassingOnlyOnceAllItsChecksAndStatusesAreReadAndDone() async throws {
        let store = Store()
        store.persists = false
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        let total = TotalBox()
        store.gh.session = StubbedGitHub.session { request in
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let page = Int(query["page"] ?? "1") ?? 1
            func check(_ i: Int, _ status: String) -> String {
                #"{"id":\#(i),"name":"c\#(i)","status":"\#(status)","conclusion":\#(status == "completed" ? #""success""# : "null"),"head_sha":"s1","app":{"slug":"circleci"}}"#
            }
            switch comps?.path ?? "" {
            case "/repos/a/x/branches/main": return .init(200, #"{"commit":{"sha":"s1","commit":{"message":"Fix"}}}"#)
            case "/repos/a/x/actions/runs": return .init(200, #"{"workflow_runs":[]}"#)
            case "/repos/a/x/commits/s1/check-runs":
                // A full page of passing checks, the one past it still running; or more of them than are read.
                let n = total.value
                let start = (page - 1) * 100
                let runs = (start..<min(n, start + 100)).map { check($0, $0 == 100 ? "in_progress" : "completed") }
                return .init(200, #"{"total_count":\#(n),"check_runs":[\#(runs.joined(separator: ","))]}"#)
            case "/repos/a/x/commits/s1/status":
                return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#)
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        total.value = 101
        #expect(try await store.fetchBranchCI("a/x", branch: "main").workflows.map(\.state) == [.pending])
        total.value = 1_000
        #expect(try await store.fetchBranchCI("a/x", branch: "main").workflows.map { [$0.state == .pending, $0.running == true] }
                    == [[true, true]])
    }

    @Test func aCommitsActionsRunsAreReadPastTheFirstPageAndCappedOnesKeepWhatWasKnown() async throws {
        let store = Store()
        store.persists = false
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        let total = TotalBox()
        store.gh.session = StubbedGitHub.session { request in
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let page = Int(query["page"] ?? "1") ?? 1
            switch comps?.path ?? "" {
            case "/repos/a/x/branches/main": return .init(200, #"{"commit":{"sha":"s1","commit":{"message":"Fix"}}}"#)
            case "/repos/a/x/actions/runs":
                // One run per workflow on the head commit, the last of them failing.
                let n = total.value, size = Int(query["per_page"] ?? "30") ?? 30
                let start = (page - 1) * size
                let runs = (start..<min(n, start + size)).map { i in
                    #"{"id":\#(i),"name":"w\#(i)","workflow_id":\#(i),"head_sha":"s1","status":"completed","conclusion":"\#(i == n - 1 ? "failure" : "success")"}"#
                }
                return .init(200, #"{"total_count":\#(n),"workflow_runs":[\#(runs.joined(separator: ","))]}"#)
            case "/repos/a/x/commits/s1/check-runs": return .init(200, #"{"total_count":0,"check_runs":[]}"#)
            case "/repos/a/x/commits/s1/status": return .init(200, #"{"state":"pending","total_count":0,"sha":"s1","statuses":[]}"#)
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        // The 31st workflow failing is read, past GitHub's first page of 30.
        total.value = 31
        let all = try await store.fetchBranchCI("a/x", branch: "main")
        #expect(all.workflows.count == 31 && all.workflows.filter { $0.state == .failure }.map(\.name) == ["w30"] && all.runsCapped == nil)
        // More than the pages read: what isn't read may still run, and what was known of the commit stays.
        total.value = 1_000
        let capped = try await store.fetchBranchCI("a/x", branch: "main")
        #expect(capped.runsCapped == true && capped.workflows.count == 301)
        #expect(capped.workflows.first { $0.id == Store.externalWorkflowID }?.state == .pending)
        let read = InboxSync.workflowThings(repo: "a/x", branch: "main", status: capped)
        var failing = InboxSync.workflowThings(repo: "a/x", branch: "main", status: all).first { $0.checks == .failing }!
        failing.id = InboxSync.workflowID(repo: "a/x", workflow: "999", branch: "main")
        var older = failing
        older.id = InboxSync.workflowID(repo: "a/x", workflow: "998", branch: "main")
        older.ciRun = "ci:s0:998#1"
        let known = [failing.id: failing, older.id: older]
        let kept = InboxSync.keepingUnread(read, status: capped, known: known, repo: "a/x", branch: "main")
        #expect(kept.count == read.count + 1 && kept.last?.id == failing.id)
        // All read, what it has is all.
        #expect(InboxSync.keepingUnread(read, status: all, known: known, repo: "a/x", branch: "main").count == read.count)
    }

    @Test func statusesStillPendingByGitHubsOwnStateOrNotAllReadAreRunning() {
        let passed = GHCombinedStatus.Status(context: "ci/jenkins", state: "success", createdAt: t0, updatedAt: t0)
        let pending = GHCombinedStatus(state: "pending", totalCount: 1, sha: "s", statuses: [passed])
        #expect(Store.readCI(runs: [], sha: nil, checks: [], combined: pending).workflows.map(\.state) == [.pending])
        let unread = GHCombinedStatus(state: "success", totalCount: 2, sha: "s", statuses: [passed])
        #expect(Store.readCI(runs: [], sha: nil, checks: [], combined: unread, complete: false).workflows.map(\.state) == [.pending])
        // No statuses at all is "pending" to GitHub: nothing runs.
        let none = GHCombinedStatus(state: "pending", totalCount: 0, sha: "s", statuses: [])
        #expect(Store.readCI(runs: [], sha: nil, checks: [check("lint")], combined: none).workflows.map(\.state) == [.success])
    }
}

/// How many check runs the stub's commit has.
private final class TotalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { get { lock.withLock { n } } set { lock.withLock { n = newValue } } }
}

/// Paths a stub was asked for, from whichever thread it answers on.
private final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.withLock { paths.append(path) } }
    var all: [String] { lock.withLock { paths } }
}
