import Foundation
import Testing
@testable import Fjord

private func iso(_ text: String) -> Date? { try? Date.ISO8601FormatStyle().parse(text) }

private func node(_ extra: [String: Any] = [:]) -> [String: Any] {
    var n: [String: Any] = [
        "__typename": "PullRequest", "id": "PR_1", "number": 12, "title": "Add sandbox", "url": "https://github.com/o/r/pull/12",
        "isDraft": false, "state": "OPEN", "merged": false, "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-09T10:00:00Z",
        "body": "Hello @Reviewer and @org/team\n<!-- greptile_confidence_score:3 -->", "mergeable": "CONFLICTING", "mergeStateStatus": "BEHIND",
        "requestEvents": ["nodes": [
            ["createdAt": "2026-10-02T10:00:00Z", "requestedReviewer": ["login": "bob"]],
            ["createdAt": "2026-10-04T10:00:00Z", "requestedReviewer": ["login": "bob"]],
            ["createdAt": "2026-10-03T10:00:00Z", "requestedReviewer": ["combinedSlug": "org/core"]],
            ["createdAt": "2026-10-01T10:00:00Z", "requestedReviewer": ["login": "gone"]],
        ]],
        "repository": ["nameWithOwner": "o/r"],
        "author": ["login": "me", "__typename": "User", "avatarUrl": "https://a/me"], "authorAssociation": "CONTRIBUTOR",
        "labels": ["nodes": [["name": "bug"]]], "assignees": ["nodes": [["login": "alice"]]],
        "reviewRequests": ["nodes": [["requestedReviewer": ["login": "bob"]], ["requestedReviewer": ["combinedSlug": "org/core"]]]],
        "comments": ["nodes": [
            ["id": "c1", "createdAt": "2026-10-05T10:00:00Z", "body": "ping @Me ```@code```", "authorAssociation": "NONE",
             "author": ["login": "greptile-apps", "__typename": "Bot", "avatarUrl": "https://a/g"]],
        ]],
        "latestOpinionatedReviews": ["nodes": [
            ["id": "r1", "state": "APPROVED", "submittedAt": "2026-10-06T10:00:00Z", "body": "", "authorAssociation": "MEMBER",
             "author": ["login": "bob", "__typename": "User", "avatarUrl": ""]],
        ]],
        "reviews": ["nodes": [
            ["id": "r1", "state": "APPROVED", "submittedAt": "2026-10-06T10:00:00Z", "body": "", "authorAssociation": "MEMBER",
             "author": ["login": "bob", "__typename": "User", "avatarUrl": ""]],
            ["id": "r2", "state": "COMMENTED", "submittedAt": "2026-10-07T10:00:00Z", "body": "Looks odd, cc @carol",
             "authorAssociation": "OWNER", "author": ["login": "dave", "__typename": "User", "avatarUrl": ""]],
        ]],
        "reviewThreads": ["nodes": [
            ["id": "t1", "isResolved": true, "path": "a.swift",
             "first": ["nodes": [["id": "x", "createdAt": "2026-10-02T10:00:00Z", "body": "a", "authorAssociation": "MEMBER",
                                 "author": ["login": "bob", "__typename": "User"]]]],
             "last": ["nodes": [["id": "y", "createdAt": "2026-10-03T10:00:00Z", "body": "done", "authorAssociation": "NONE",
                                "author": ["login": "me", "__typename": "User"]]]]],
            ["id": "t2", "isResolved": false, "path": "b.swift",
             "first": ["nodes": [["id": "z", "createdAt": "2026-10-02T10:00:00Z", "body": "why?", "authorAssociation": "NONE",
                                 "author": ["login": "greptile-apps", "__typename": "Bot"]]]],
             "last": ["nodes": [["id": "w", "createdAt": "2026-10-08T10:00:00Z", "body": "still why? @alice", "authorAssociation": "NONE",
                                "author": ["login": "greptile-apps", "__typename": "Bot"]]]]],
        ]],
        "commits": ["nodes": [
            ["commit": ["oid": "abc", "committedDate": "2026-10-08T11:00:00Z", "author": ["user": ["login": "me"]],
                        "statusCheckRollup": ["state": "FAILURE"]]],
        ]],
    ]
    for (k, v) in extra { n[k] = v }
    return n
}

@Suite struct InboxSyncMapping {
    @Test func aPRsCIExecutionIsItsChecksIds() throws {
        func head(_ runs: [(Int, String)], statuses: [(String, String, String)] = [], rollup: String = "FAILURE") -> [String: Any] {
            let contexts: [[String: Any]] = runs.map { ["__typename": "CheckRun", "databaseId": $0.0, "status": $0.1] }
                + statuses.map { ["__typename": "StatusContext", "context": $0.0, "state": $0.1, "createdAt": $0.2] }
            return ["head": ["nodes": [["commit": ["oid": "abc", "statusCheckRollup": [
                "state": rollup, "contexts": ["totalCount": contexts.count, "nodes": contexts]]]]]]]
        }
        let failing = try #require(InboxSync.thing(node(head([(1, "COMPLETED"), (2, "IN_PROGRESS")]))))
        // The rollup already says failing; another check still runs.
        #expect(failing.checks == .failing && failing.ciRunning)
        let done = try #require(InboxSync.thing(node(head([(2, "COMPLETED"), (1, "COMPLETED")]))))
        // The same run, all of it finished: the same execution.
        #expect(!done.ciRunning && done.ciRun == failing.ciRun && done.ciRun?.hasPrefix("ci:abc:") == true)
        // Rerun: new check runs on the same commit.
        let rerun = try #require(InboxSync.thing(node(head([(3, "COMPLETED"), (4, "COMPLETED")]))))
        #expect(rerun.ciRun != done.ciRun)
        // A status still pending runs; posted again, it is another execution.
        let pending = try #require(InboxSync.thing(node(head([(1, "COMPLETED")], statuses: [("ci/ext", "PENDING", "2026-10-08T11:00:00Z")]))))
        #expect(pending.ciRunning)
        let posted = try #require(InboxSync.thing(node(head([(1, "COMPLETED")], statuses: [("ci/ext", "FAILURE", "2026-10-08T12:00:00Z")]))))
        #expect(!posted.ciRunning && posted.ciRun != pending.ciRun)
        // No head read (an older answer): unknown.
        #expect(try #require(InboxSync.thing(node())).ciRun == nil)
    }

    @Test func checksPastTheFirstPageCountFromGitHubsTallies() throws {
        // Two of three check runs read by id; the third, past the page, still runs.
        func head(_ tally: [String: Int]) -> [String: Any] {
            let runs: [[String: Any]] = [["__typename": "CheckRun", "databaseId": 1, "status": "COMPLETED"],
                                         ["__typename": "CheckRun", "databaseId": 2, "status": "COMPLETED"]]
            return ["head": ["nodes": [["commit": ["oid": "abc", "statusCheckRollup": [
                "state": "FAILURE", "contexts": ["totalCount": 3, "nodes": runs,
                                                 "checkRunCountsByState": tally.map { ["state": $0.key, "count": $0.value] },
                                                 "statusContextCountsByState": []]]]]]]]
        }
        let going = try #require(InboxSync.thing(node(head(["FAILURE": 1, "SUCCESS": 1, "IN_PROGRESS": 1]))))
        #expect(going.ciRunning)
        let done = try #require(InboxSync.thing(node(head(["FAILURE": 1, "SUCCESS": 2]))))
        #expect(!done.ciRunning && done.ciRun?.hasPrefix("ci:abc:") == true)
        #expect(try #require(InboxSync.thing(node(head(["SUCCESS": 2, "FAILURE": 1])))).ciRun == done.ciRun)
        // The one past the page rerun, failing where it passed: another outcome, another execution.
        let again = try #require(InboxSync.thing(node(head(["FAILURE": 2, "SUCCESS": 1]))))
        #expect(!again.ciRunning && again.ciRun != done.ciRun)
    }

    @Test func aPullRequestFailingOnlyByCancelledChecksIsCancelled() throws {
        func head(_ tally: [String: Int], statuses: [String: Int] = [:]) -> [String: Any] {
            ["head": ["nodes": [["commit": ["oid": "abc", "statusCheckRollup": [
                "state": "FAILURE", "contexts": ["totalCount": 0, "nodes": [] as [Any],
                                                 "checkRunCountsByState": tally.map { ["state": $0.key, "count": $0.value] },
                                                 "statusContextCountsByState": statuses.map { ["state": $0.key, "count": $0.value] }]]]]]]]
        }
        let cancelled = try #require(InboxSync.thing(node(head(["CANCELLED": 1, "SUCCESS": 2]))))
        #expect(cancelled.checks == .failing && cancelled.ciCancelled)
        // A failure among them, of a check or a status, is the outcome.
        #expect(try #require(InboxSync.thing(node(head(["CANCELLED": 1, "FAILURE": 1])))).ciCancelled == false)
        #expect(try #require(InboxSync.thing(node(head(["CANCELLED": 1], statuses: ["ERROR": 1])))).ciCancelled == false)
        #expect(try #require(InboxSync.thing(node(head(["CANCELLED": 0, "FAILURE": 1])))).ciCancelled == false)
    }

    @Test func aPullRequestBecomesAThing() throws {
        let t = try #require(InboxSync.thing(node()))
        #expect(t.id == "pr:o/r#12")
        #expect(t.kind == .pr && t.repo == "o/r" && t.number == 12)
        #expect(t.status == .open)
        #expect(t.author == Person(login: "me", isBot: false, association: .contributor, avatar: URL(string: "https://a/me")))
        #expect(t.labels == ["bug"] && t.assignees == ["alice"] && t.requestedReviewers == ["bob", "org/core"])
        #expect(t.greptileScore == 3)
        #expect(t.hasConflicts)
        #expect(t.checks == .failing)
        // Teams and code are not mentions; logins are lowercased, from the body, comments, review words and replies.
        #expect(Set(t.mentioned) == ["reviewer", "me", "carol", "alice"])
        #expect(t.commits.map(\.id) == ["abc"] && t.commits.first?.author == "me")
    }

    @Test func botsGetTheirBotSuffixAndAssociationsAreKept() throws {
        let t = try #require(InboxSync.thing(node()))
        let bot = try #require(t.comments.first { $0.id == "c1" }?.author)
        #expect(bot.login == "greptile-apps[bot]" && bot.isBot)
        #expect(t.reviews.first { $0.id == "r1" }?.author.association == .member)
    }

    @Test func reviewsWithWordsAreCommentsAndOpinionsAreReviews() throws {
        let t = try #require(InboxSync.thing(node()))
        let summary = try #require(t.comments.first { $0.id == "r2" })
        #expect(summary.isReview && summary.author.login == "dave" && summary.author.association == .owner)
        // Comments are in time order.
        #expect(t.comments.map(\.id) == ["c1", "r2"])
        // Bob's approval, and dave's comment-only review (he has no opinion).
        #expect(t.reviews.map(\.state) == [.approved, .commented])
    }

    @Test func aReviewThatOnlyCommentsAfterAnOpinionIsAReviewAndTheOpinionStands() throws {
        let bob: [String: Any] = ["login": "bob", "__typename": "User", "avatarUrl": ""]
        let changes: [String: Any] = ["id": "r1", "state": "CHANGES_REQUESTED", "submittedAt": "2026-10-06T10:00:00Z", "body": "fix it",
                                      "authorAssociation": "MEMBER", "author": bob]
        let followUp: [String: Any] = ["id": "r3", "state": "COMMENTED", "submittedAt": "2026-10-08T10:00:00Z", "body": "",
                                       "authorAssociation": "MEMBER", "author": bob, "commit": ["oid": "mid"]]
        let commit: [String: Any] = ["commit": ["oid": "mid", "committedDate": "2026-10-07T10:00:00Z", "author": ["user": ["login": "me"]]]]
        let t = try #require(InboxSync.thing(node(["latestOpinionatedReviews": ["nodes": [changes]],
                                                   "reviews": ["nodes": [changes, followUp]], "commits": ["nodes": [commit]]])))
        #expect(t.reviews.map(\.id) == ["r1", "r3"])
        // What each review was of.
        #expect(t.reviews.map(\.commitID) == [nil, "mid"])
        var marks = EntryMarks()
        marks.doneAt = iso("2026-10-07T00:00:00Z")
        func keys(_ condition: Condition, me: String = "me") -> [String]? {
            InboxEngine.facts(Rule(scope: Scope(kinds: [.pr]), conditions: [condition], createdAt: .distantPast), t, marks: marks,
                              context: InboxContext(me: me))?.map(\.key)
        }
        // Bob's follow-up is a new review since Done, and his changes requested still stand.
        #expect(keys(.newReview(by: Pick())) == ["review:r3"])
        #expect(keys(.changesRequested(by: Pick())) == ["changes:r1"])
        // For bob, his last review is the follow-up: the commit before it isn't new since.
        #expect(keys(.newCommits(by: Pick(), since: .myLastReview), me: "bob") == nil)
    }

    @Test func aDismissedReviewTakesBackTheOpinionBeforeIt() throws {
        let bob: [String: Any] = ["login": "bob", "__typename": "User", "avatarUrl": ""]
        let approved: [String: Any] = ["id": "r1", "state": "APPROVED", "submittedAt": "2026-10-06T10:00:00Z", "body": "",
                                       "authorAssociation": "MEMBER", "author": bob]
        let dismissed: [String: Any] = ["id": "r3", "state": "DISMISSED", "submittedAt": "2026-10-08T10:00:00Z", "body": "",
                                        "authorAssociation": "MEMBER", "author": bob]
        let t = try #require(InboxSync.thing(node(["latestOpinionatedReviews": ["nodes": [dismissed]],
                                                   "reviews": ["nodes": [approved, dismissed]]])))
        let rule = Rule(scope: Scope(kinds: [.pr]), conditions: [.approved(by: Pick())], createdAt: .distantPast)
        #expect(InboxEngine.facts(rule, t, marks: nil, context: InboxContext(me: "me")) == nil)
    }

    @Test func threadsKeepWhoStartedWhoRepliedAndWhetherTheyAreResolved() throws {
        let t = try #require(InboxSync.thing(node()))
        #expect(t.threads.map(\.isResolved) == [true, false])
        let open = t.threads[1]
        #expect(open.startedBy.login == "greptile-apps[bot]" && open.lastReplyID == "w" && open.path == "b.swift")
    }

    @Test func anAnswerInTheMiddleOfAThreadIsYourLatestWordThere() throws {
        func comment(_ id: String, _ who: String, _ at: String) -> [String: Any] {
            ["id": id, "createdAt": at, "body": "…", "authorAssociation": "NONE", "author": ["login": who, "__typename": "User"]]
        }
        // Bob asked in a thread, you answered at noon, Carol replied after you: the thread's tail is hers.
        let thread: [String: Any] = ["id": "t9", "isResolved": false, "path": "a.swift",
                                     "first": ["nodes": [comment("q", "bob", "2026-10-07T10:00:00Z")]],
                                     "last": ["nodes": [comment("q", "bob", "2026-10-07T10:00:00Z"), comment("a", "Me", "2026-10-07T12:00:00Z"),
                                                        comment("c", "carol", "2026-10-07T13:00:00Z")]]]
        let thing = try #require(InboxSync.thing(node([
            "comments": ["nodes": [comment("d", "dave", "2026-10-07T11:00:00Z")]], "reviews": ["nodes": []],
            "latestOpinionatedReviews": ["nodes": []], "reviewThreads": ["nodes": [thread]]])))
        #expect(thing.threads.first?.lastReplyID == "c" && thing.threads.first?.lastReplyBy.login == "carol")
        // Dave's comment came before your answer: nothing new since your last comment.
        let rule = Rule(scope: Scope(kinds: [.pr]), conditions: [.newComment(by: Pick(), since: .myLastComment)], createdAt: .distantPast)
        #expect(InboxEngine.facts(rule, thing, marks: nil, context: InboxContext(me: "me")) == nil)
        // And it is kept as your latest word there.
        var kept = thing
        InboxJev.carry(nil, into: &kept, me: "me")
        #expect(kept.signals?.answeredAt == iso("2026-10-07T12:00:00Z"))
    }

    @Test func aQuestionInAThreadStillAsksWhenSomeoneElseRepliesAfterIt() throws {
        func comment(_ id: String, _ who: String, _ at: String) -> [String: Any] {
            ["id": id, "createdAt": at, "body": id == "q" ? "@me can you check this?" : "…", "authorAssociation": "NONE",
             "author": ["login": who, "__typename": "User"]]
        }
        func fetched(_ replies: [[String: Any]]) throws -> Thing {
            let thread: [String: Any] = ["id": "t9", "isResolved": false, "path": "a.swift",
                                         "first": ["nodes": [replies[0]]], "last": ["nodes": replies]]
            return try #require(InboxSync.thing(node([
                "comments": ["nodes": []], "reviews": ["nodes": []], "latestOpinionatedReviews": ["nodes": []],
                "reviewThreads": ["nodes": [thread]]])))
        }
        let rule = Rule(scope: Scope(kinds: [.pr]), conditions: [.commentLabel([.asks, .todo])], createdAt: .distantPast)
        let context = InboxContext(me: "me", now: iso("2026-10-07T14:00:00Z")!)
        func keys(_ thing: Thing, marks: EntryMarks? = nil) -> [String]? {
            InboxEngine.facts(rule, thing, marks: marks, context: context)?.map(\.key)
        }
        // Bob asks you in a thread, and Jev reads it as asking you.
        let question = comment("q", "bob", "2026-10-07T10:00:00Z")
        var asked = try fetched([question])
        asked.signals = ThingSignals(messages: ["q": MessageSignal(label: .asks)], viewer: "me")
        #expect(keys(asked) == ["asks:q"])
        // Carol replies after him: his question is still among the thread's messages, Jev's verdict on it kept.
        var later = try fetched([question, comment("c", "carol", "2026-10-07T13:00:00Z")])
        #expect(later.threads.first?.lastReplyID == "c")
        #expect(InboxEngine.messages(later).map(\.id) == ["q", "c"])
        InboxJev.carry(asked.signals, into: &later, me: "me")
        #expect(later.signals?.messages["q"]?.label == .asks)
        #expect(keys(later) == ["asks:q"])
        #expect(InboxSync.isEvent("asks:q", of: later))
        // Done after it: it no longer asks; nor once you answer in the thread.
        #expect(keys(later, marks: EntryMarks(doneAt: iso("2026-10-07T13:30:00Z")!)) == nil)
        var answered = try fetched([question, comment("a", "Me", "2026-10-07T12:00:00Z"), comment("c", "carol", "2026-10-07T13:00:00Z")])
        InboxJev.carry(later.signals, into: &answered, me: "me")
        #expect(keys(answered) == nil)
    }

    @Test func aThreadsOpenerStillAsksOnceTenRepliesFollowIt() throws {
        func comment(_ id: String, _ who: String, _ at: String) -> [String: Any] {
            ["id": id, "createdAt": at, "body": id == "q" ? "@me can you check this?" : "…", "authorAssociation": "NONE",
             "author": ["login": who, "__typename": "User"]]
        }
        // Bob opens the thread asking you, and ten replies from others follow: its last ten no longer hold his question.
        let question = comment("q", "bob", "2026-10-07T10:00:00Z")
        let replies = (0..<10).map { comment("r\($0)", "carol", "2026-10-07T11:0\($0):00Z") }
        let thread: [String: Any] = ["id": "t9", "isResolved": false, "path": "a.swift",
                                     "first": ["nodes": [question]], "last": ["nodes": replies]]
        var thing = try #require(InboxSync.thing(node([
            "comments": ["nodes": []], "reviews": ["nodes": []], "latestOpinionatedReviews": ["nodes": []],
            "reviewThreads": ["nodes": [thread]]])))
        #expect(thing.threads.first?.lastReplyID == "r9")
        #expect(InboxEngine.messages(thing).map(\.id).filter { $0 == "q" } == ["q"])
        thing.signals = ThingSignals(messages: ["q": MessageSignal(label: .asks)], viewer: "me")
        let rule = Rule(scope: Scope(kinds: [.pr]), conditions: [.commentLabel([.asks, .todo])], createdAt: .distantPast)
        let context = InboxContext(me: "me", now: iso("2026-10-07T14:00:00Z")!)
        #expect(InboxEngine.facts(rule, thing, marks: nil, context: context)?.map(\.key) == ["asks:q"])
    }

    @Test func statusesAndAnIssue() throws {
        #expect(InboxSync.thing(node(["isDraft": true]))?.status == .draft)
        #expect(InboxSync.thing(node(["merged": true, "state": "MERGED"]))?.status == .merged)
        #expect(InboxSync.thing(node(["state": "CLOSED"]))?.status == .closed)
        #expect(InboxSync.thing(node(["mergeable": "MERGEABLE", "body": "none"]))?.hasConflicts == false)
        let issue = try #require(InboxSync.thing(["__typename": "Issue", "number": 3, "title": "Bug", "url": "https://github.com/o/r/issues/3",
                                                  "state": "CLOSED", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00Z",
                                                  "repository": ["nameWithOwner": "o/r"], "author": NSNull()]))
        #expect(issue.id == "issue:o/r#3" && issue.status == .closed && issue.author?.login == "ghost")
    }

    @Test func eachWorkflowOfABranchIsAThingOfItsOwn() {
        let status = CIStatus(branch: "main", sha: "abc", url: URL(string: "https://github.com/o/r/commit/abc"),
                              checkedAt: Date(), title: "Fix", updatedAt: Date(timeIntervalSince1970: 100),
                              workflows: [
                                  CIStatus.Workflow(id: "11", name: "CI", state: .failure, failing: ["build"],
                                                    url: URL(string: "https://github.com/o/r/actions/runs/5"),
                                                    updatedAt: Date(timeIntervalSince1970: 90)),
                                  CIStatus.Workflow(id: "12", name: "Lint", state: .failure, failing: ["lint"], url: nil, updatedAt: nil),
                                  CIStatus.Workflow(id: "13", name: "Docs", state: .success, failing: [], url: nil, updatedAt: nil),
                              ])
        let things = InboxSync.workflowThings(repo: "o/r", branch: "main", status: status)
        #expect(things.map(\.id) == ["workflow:o/r:11@main", "workflow:o/r:12@main", "workflow:o/r:13@main"])
        #expect(things.map(\.workflowName) == ["CI", "Lint", "Docs"])
        #expect(things.map(\.checks) == [.failing, .failing, .passing])
        #expect(things[0].failingJobs == ["build"] && things[1].failingJobs == ["lint"] && things[2].failingJobs.isEmpty)
        #expect(things.allSatisfy { $0.branch == "main" && $0.kind == .workflow && $0.title == "Fix" })
        #expect(things[0].url.path.hasSuffix("/runs/5") && things[1].url.path == "/o/r/commit/abc")
        #expect(things[1].updatedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func aMovedRepoReadUnderItsOldNameIsTheSameThingsAsUnderItsNewOne() {
        let status = CIStatus(branch: "main", sha: "abc", checkedAt: Date(), title: "Fix",
                              workflows: [CIStatus.Workflow(id: "11", name: "Test", state: .failure, failing: ["test"],
                                                            url: URL(string: "https://github.com/org/r/actions/runs/5"), updatedAt: nil)])
        let old = InboxSync.workflowThings(repo: "me/r", branch: "main", status: status)
        let new = InboxSync.workflowThings(repo: "org/r", branch: "main", status: status)
        #expect(old.map(\.id) == ["workflow:org/r:11@main"] && old.map(\.id) == new.map(\.id) && old[0].repo == "org/r")
        // Only the case differs: the name stays as asked, so nothing known of it moves.
        #expect(InboxSync.workflowThings(repo: "Org/R", branch: "main", status: status)[0].id == "workflow:Org/R:11@main")
    }
}

extension InboxSyncMapping {
    @Test func aMentionInAReviewThreadMatchesMentionsMeAfterTheCutoff() throws {
        let threads: [String: Any] = ["nodes": [
            ["id": "t1", "isResolved": false, "path": "a.swift",
             "first": ["nodes": [["id": "x", "createdAt": "2026-10-02T10:00:00Z", "body": "a", "authorAssociation": "MEMBER",
                                 "author": ["login": "bob", "__typename": "User"]]]],
             "last": ["nodes": [
                ["id": "m1", "createdAt": "2026-10-03T10:00:00Z", "body": "@me what do you think?", "authorAssociation": "MEMBER",
                 "author": ["login": "bob", "__typename": "User"]],
                ["id": "y", "createdAt": "2026-10-04T10:00:00Z", "body": "agreed", "authorAssociation": "NONE",
                 "author": ["login": "carol", "__typename": "User"]]]]],
        ]]
        let thing = try #require(InboxSync.thing(node(["author": ["login": "alice", "__typename": "User"], "body": "",
                                                       "comments": ["nodes": []], "reviewThreads": threads])))
        let rule = Rule(scope: Scope(kinds: [.pr]), conditions: [.mentions(Pick(include: [.me]))], createdAt: .distantPast)
        let context = InboxContext(me: "me", now: iso("2026-10-10T10:00:00Z")!)
        let keys = InboxEngine.facts(rule, thing, marks: nil, context: context)?.map(\.key)
        #expect(keys == ["mention:m1"])
        #expect(InboxSync.isEvent("mention:m1", of: thing))
        // Kept as the thing is, and only what is after the cutoff counts.
        let saved = try JSONDecoder().decode(Thing.self, from: JSONEncoder().encode(thing))
        #expect(InboxEngine.facts(rule, saved, marks: EntryMarks(doneAt: iso("2026-10-03T12:00:00Z")!), context: context) == nil)
    }

    @Test func aMentionEarlierInAReviewThreadIsToMeMentionedOnTheFirstPageAndPastIt() throws {
        func threads(_ id: String) -> [String: Any] {
            ["nodes": [
                ["id": id, "isResolved": false, "path": "a.swift",
                 "first": ["nodes": [["id": "\(id)x", "createdAt": "2026-10-02T10:00:00Z", "body": "a", "authorAssociation": "MEMBER",
                                     "author": ["login": "bob", "__typename": "User"]]]],
                 "last": ["nodes": [
                    ["id": "\(id)m", "createdAt": "2026-10-03T10:00:00Z", "body": "@me what do you think?", "authorAssociation": "MEMBER",
                     "author": ["login": "bob", "__typename": "User"]],
                    ["id": "\(id)y", "createdAt": "2026-10-04T10:00:00Z", "body": "agreed", "authorAssociation": "NONE",
                     "author": ["login": "carol", "__typename": "User"]]]]],
            ], "pageInfo": ["hasNextPage": false]]
        }
        let bare: [String: Any] = ["author": ["login": "alice", "__typename": "User"], "body": "", "comments": ["nodes": []]]
        var extra = bare
        extra["reviewThreads"] = threads("t1")
        let rule = Rule(scope: Scope(kinds: [.pr], to: Pick(include: [.me]), toRoles: [.mentioned]), createdAt: .distantPast)
        let context = InboxContext(me: "me", now: iso("2026-10-10T10:00:00Z")!)
        // On the first page.
        let thing = try #require(InboxSync.thing(node(extra)))
        #expect(thing.mentioned.contains("me") && InboxEngine.facts(rule, thing, marks: nil, context: context) != nil)
        // On a page past it.
        extra["reviewThreads"] = ["nodes": []]
        var paged = try #require(InboxSync.thing(node(extra)))
        #expect(InboxEngine.facts(rule, paged, marks: nil, context: context) == nil)
        #expect(InboxSync.addThreads(threads("t2"), to: &paged) == ["me"])
        #expect(InboxEngine.facts(rule, paged, marks: nil, context: context) != nil)
        // A tail taken as read before, its mentions noted from its latest replies only: its threads still say them.
        var old = paged
        old.threadsTail = ThreadsTail(total: 1, updatedAt: old.updatedAt, readAt: old.updatedAt, mentions: [])
        var again = try #require(InboxSync.thing(node(extra)))
        InboxSync.takeTail(of: old, into: &again)
        #expect(InboxEngine.facts(rule, again, marks: nil, context: context) != nil)
    }
}

@Suite struct InboxSyncQueries {
    private func rule(_ scope: Scope, _ conditions: [Condition] = []) -> InboxCategory {
        InboxCategory(name: "x", symbol: "star", color: .blue, rules: [Rule(scope: scope, conditions: conditions)])
    }

    private func searches(_ categories: [InboxCategory], groups: [InboxGroup] = []) -> [String] {
        InboxSync.searches(categories: categories, groups: groups, me: "me", contributed: ["o/c"],
                           now: Date(timeIntervalSince1970: 1_791_000_000))
    }

    @Test func scopesBecomeQualifiers() {
        let q = searches([rule(Scope(kinds: [.pr], by: Pick(include: [.me]), in: Pick(include: [.repo("o/r"), .owner("org")])))])
        #expect(q.count == 1)
        #expect(["is:pr", "repo:o/r", "user:org", "author:me", "is:open"].allSatisfy { q[0].contains($0) })
    }

    @Test func toRolesMakeOneQueryEach() {
        let q = searches([rule(Scope(kinds: [.pr], to: Pick(include: [.me]), toRoles: [.assigned, .reviewRequested]))])
        #expect(q.count == 2)
        #expect(q.contains { $0.contains("assignee:me") } && q.contains { $0.contains("review-requested:me") })
        // An issue has no review requests.
        let issues = searches([rule(Scope(kinds: [.issue], to: Pick(include: [.me]), toRoles: [.reviewRequested, .mentioned]))])
        #expect(issues.count == 1 && issues[0].contains("mentions:me") && issues[0].contains("is:issue"))
    }

    @Test func involvedUsesInvolvesAndWhatSearchCantSayIsOverFetched() {
        let q = searches([rule(Scope(kinds: [.pr], by: Pick(include: [.maintainers]), in: Pick(include: [.involved])))])
        #expect(q.count == 3 && q[0].contains("involves:me") && !q.contains { $0.contains("author:") })
        // Nothing narrowing at all is what involves you, not every PR on GitHub.
        #expect(searches([rule(Scope(kinds: [.pr]))]) == q)
    }

    @Test func involvedPRsAreAlsoThoseYoureAskedToReviewOrReviewed() {
        // `involves:` leaves out review requests (a first one is all of yours there) and reviews.
        let q = searches([rule(Scope(kinds: [.pr, .issue], in: Pick(include: [.involved])))])
        #expect(q.count == 3 && q[0].contains("involves:me") && !q[0].contains("is:pr") && !q[0].contains("is:issue"))
        #expect(q.contains { $0.contains("is:pr") && $0.contains("review-requested:me") && !$0.contains("involves:") })
        #expect(q.contains { $0.contains("is:pr") && $0.contains("reviewed-by:me") && !$0.contains("involves:") })
        let issues = searches([rule(Scope(kinds: [.issue], in: Pick(include: [.involved])))])
        #expect(issues.count == 1 && issues[0].contains("involves:me"))
    }

    @Test func groupsOwnedAndContributedExpand() {
        let people = InboxGroup(name: "Team", kind: .people, members: ["alice", "greptile-apps[bot]"])
        let repos = InboxGroup(name: "Mine", kind: .repos, members: ["a/b", "c/*"])
        let q = searches([rule(Scope(kinds: [.pr], by: Pick(include: [.group(people.id)]),
                                     in: Pick(include: [.group(repos.id), .owned, .contributed])))], groups: [people, repos])
        #expect(q.count == 2)
        #expect(["repo:a/b", "user:c", "user:me", "repo:o/c"].allSatisfy { q[0].contains($0) })
        #expect(q[0].contains("author:alice") && q[1].contains("author:app/greptile-apps"))
    }

    @Test func prsAndIssuesShareTheQueriesTheyCan() {
        // The same query finds both without is:pr or is:issue; review requests are a PR's alone.
        let q = searches([rule(Scope(kinds: [.pr, .issue], to: Pick(include: [.me]), toRoles: [.assigned, .reviewRequested],
                                     in: Pick(include: [.owned])))])
        #expect(q == ["archived:false user:me assignee:me sort:updated-desc is:open",
                      "is:pr archived:false user:me review-requested:me sort:updated-desc is:open"])
    }

    @Test func everyRuleGetsSearchesPastTheCap() {
        // A hundred named repos make a rule of many queries; the rule after it still gets its turn.
        let many = Pick<RepoRef>(include: (0..<100).map { .repo("owner/repository-\($0)") })
        let q = searches([InboxCategory(name: "x", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], in: many)), Rule(scope: Scope(kinds: [.issue], in: Pick(include: [.owned, .owner("org")]))),
        ])])
        #expect(q.count == InboxSync.maxSearches)
        #expect(q.filter { $0.contains("is:issue") } == ["is:issue archived:false user:me user:org sort:updated-desc is:open"])
    }

    @Test func pastTheCapTheWindowMovesSoEveryQueryGetsATurn() {
        let rules = (0..<17).map { Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.user("u\($0)")]))) }
        let categories = [InboxCategory(name: "x", symbol: "star", color: .blue, rules: rules)]
        let first = InboxSync.searchPlan(categories: categories, groups: [], me: "me", contributed: [])
        #expect(first.all.count == 17 && first.searches.count == InboxSync.maxSearches && first.next == 16)
        let second = InboxSync.searchPlan(categories: categories, groups: [], me: "me", contributed: [], cursor: first.next)
        #expect(Set(first.searches).union(second.searches) == first.all)
        #expect(second.searches.first?.contains("author:u16") == true)
        // Under the cap: all of them, each time.
        let few = InboxSync.searchPlan(categories: [InboxCategory(name: "x", symbol: "star", color: .blue, rules: Array(rules.prefix(3)))],
                                       groups: [], me: "me", contributed: [], cursor: 5)
        #expect(few.searches.count == 3 && few.next == 0)
        // Sixteen first queries and more after them: the window still reaches the later ones.
        let two = (0..<16).map { Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.user("u\($0)"), .user("v\($0)")]))) }
        let crowded = [InboxCategory(name: "x", symbol: "star", color: .blue, rules: two)]
        var cursor = 0, asked = Set<String>()
        let all = InboxSync.searchPlan(categories: crowded, groups: [], me: "me", contributed: []).all
        for _ in 0..<4 {
            let plan = InboxSync.searchPlan(categories: crowded, groups: [], me: "me", contributed: [], cursor: cursor)
            #expect(plan.searches.count == InboxSync.maxSearches)
            asked.formUnion(plan.searches)
            cursor = plan.next
        }
        #expect(all.count > InboxSync.maxSearches && asked == all)
        #expect(InboxSync.pageSizes(searches: 1, budget: 150) == InboxSync.pageSize)
        #expect(InboxSync.pageSizes(searches: 16, budget: 150) == 9 && InboxSync.pageSizes(searches: 4, budget: 3) == 1)
    }

    @Test func closedThingsAreOnlyFetchedWhenAskedForAndRecent() {
        let plain = searches([rule(Scope(kinds: [.pr], by: Pick(include: [.me])))])
        #expect(plain.count == 1)
        let merged = searches([rule(Scope(kinds: [.pr], by: Pick(include: [.me])), [.status([.merged])])])
        #expect(merged.count == 2 && merged[1].contains("is:closed updated:>=2026-"))
    }

    @Test func workflowsAreRepoTargets() {
        let c = rule(Scope(kinds: [.workflow], in: Pick(include: [.repo("o/r"), .owned], except: [.repo("me/own")]), on: ["main", "dev"]))
        let t = InboxSync.workflowTargets(categories: [c], groups: [], owned: ["me/own"], contributed: [])
        #expect(t.map { "\($0.repo)@\($0.branch ?? "")" } == ["o/r@main", "o/r@dev"])
        let none = InboxSync.workflowTargets(categories: [InboxStore.ci], groups: [], owned: [], contributed: [])
        #expect(none.isEmpty)
        // Wildcards are their owner's repos, as known; an empty `on` (or blank names in it) is the default branch.
        let group = InboxGroup(name: "G", kind: .repos, members: ["b/*"])
        let wild = rule(Scope(kinds: [.workflow], in: Pick(include: [.owner("A"), .group(group.id)], except: [.repo("a/skip")]), on: ["", " "]))
        let owners = InboxSync.workflowOwners(categories: [wild], groups: [group])
        #expect(owners == ["a", "b"])
        let found = InboxSync.workflowTargets(categories: [wild], groups: [group], owned: [], contributed: [],
                                              ownerRepos: ["a": ["a/one", "a/skip"], "b": ["b/two"]])
        #expect(found.map { "\($0.repo)@\($0.branch ?? "")" } == ["a/one@", "b/two@"])
        let notB = rule(Scope(kinds: [.workflow], in: Pick(include: [.owner("a"), .owner("b")], except: [.owner("B")])))
        #expect(InboxSync.workflowTargets(categories: [notB], groups: [], owned: [], contributed: [],
                                          ownerRepos: ["a": ["a/one"], "b": ["b/two"]]).map(\.repo) == ["a/one"])
    }
}

@MainActor
@Suite struct InboxSyncRefresh {
    final class Log: @unchecked Sendable {
        var queries: [String] = []
        var posted: [String] = []
        var score = 3
        /// The GraphQL points the answers say are left, and when they come back.
        var remaining = 4000
        var resetAt = "2030-01-01T00:00:00Z"
    }

    nonisolated static func body(_ request: URLRequest) -> String {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer[..<n])
            }
            stream.close()
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func store(_ log: Log, notifies: Bool = true) -> (Store, UUID) {
        let s = Store()
        s.persists = false
        s.settings.triage = true
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            let text = Self.body(request)
            log.queries.append(text)
            let pr = node(["body": "<!-- greptile_confidence_score:\(log.score) -->"])
            let reply: [String: Any] = ["data": ["rateLimit": ["cost": 3, "remaining": log.remaining, "resetAt": log.resetAt],
                                                  "s0": ["pageInfo": ["hasNextPage": false], "nodes": [pr]]]]
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
        var category = InboxCategory(name: "Mine", symbol: "star", color: .blue, notifies: notifies)
        category.rules = [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])), conditions: [.greptileBelow(5)])]
        s.categories = [category]
        s.notifier.onPost = { log.posted.append($0.identifier) }
        return (s, category.id)
    }

    @Test func aRefreshFillsThingsAndTheFirstEvaluationIsSilent() async {
        let log = Log()
        let (s, category) = store(log)
        await s.syncInbox()
        #expect(s.things.keys.sorted() == ["pr:o/r#12"])
        #expect(s.entries(in: category).map(\.id) == ["pr:o/r#12"])
        #expect(log.queries.count == 1 && log.queries[0].contains("author:me"))
        #expect(log.posted.isEmpty)
        #expect(s.marks["pr:o/r#12"]?.notified == ["greptile:3"])
        // The baseline is a field of its own, by the rules it was taken for; marks are marks of things only.
        #expect(s.categoryBaselines == [category: Set(s.categories[0].rules.map(\.id))])
        #expect(s.marks.keys.sorted() == ["pr:o/r#12"])
    }

    @Test func aChangedRuleSetIsANewBaselineAndADeletedCategoryTakesItsBaselineWithIt() async {
        let log = Log()
        let (s, category) = store(log)
        await s.syncInbox()
        log.score = 2
        // The rule changes at the same time as the fact: what is there under the new rule is noted, not announced.
        s.categories[0].rules = [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])), conditions: [.greptileBelow(4)])]
        await s.syncInbox()
        #expect(log.posted.isEmpty && s.categoryBaselines[category] == Set(s.categories[0].rules.map(\.id)))
        s.categories = []
        await s.syncInbox()
        #expect(s.categoryBaselines.isEmpty)
    }

    @Test func aNewFactNotifiesOnceAndAGoneFactIsForgotten() async {
        let log = Log()
        let (s, _) = store(log)
        await s.syncInbox()
        await s.syncInbox()
        #expect(log.posted.isEmpty)
        log.score = 2
        await s.syncInbox()
        #expect(log.posted == ["inbox:pr:o/r#12"])
        #expect(s.marks["pr:o/r#12"]?.notified == ["greptile:2"])
        await s.syncInbox()
        #expect(log.posted.count == 1)
        // Back above the bar and below again: the same fact is new again.
        log.score = 5
        await s.syncInbox()
        #expect(s.marks["pr:o/r#12"]?.notified == [])
        log.score = 2
        await s.syncInbox()
        #expect(log.posted.count == 2)
    }

    @Test func aCategoryThatDoesNotNotifyStaysQuiet() async {
        let log = Log()
        let (s, _) = store(log, notifies: false)
        await s.syncInbox()
        log.score = 2
        await s.syncInbox()
        #expect(log.posted.isEmpty)
        #expect(s.marks["pr:o/r#12"]?.notified == ["greptile:2"])
    }

    @Test func spentPointsWaitForTheirResetAndARefreshByHandTriesAnyway() async {
        let log = Log()
        let (s, _) = store(log)
        log.remaining = 50
        await s.syncInbox()
        #expect(s.gh.graphqlRemaining == 50 && s.gh.graphqlResetsAt == iso("2030-01-01T00:00:00Z"))
        await s.syncInbox()
        #expect(log.queries.count == 1)
        // By hand: asked anyway, and the answer says the points come back an hour ago.
        log.resetAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        await s.syncInbox(manual: true)
        #expect(log.queries.count == 2)
        // Past the reset, polls search again even though the last answer still said 50.
        await s.syncInbox()
        #expect(log.queries.count == 3)
        let now = Date()
        #expect(InboxSync.waitsForPoints(remaining: 50, resetsAt: now.addingTimeInterval(60), manual: false, now: now))
        #expect(!InboxSync.waitsForPoints(remaining: 50, resetsAt: now.addingTimeInterval(60), manual: true, now: now))
        #expect(!InboxSync.waitsForPoints(remaining: 50, resetsAt: now.addingTimeInterval(-1), manual: false, now: now))
        #expect(!InboxSync.waitsForPoints(remaining: 50, resetsAt: nil, manual: false, now: now))
        #expect(!InboxSync.waitsForPoints(remaining: 500, resetsAt: now.addingTimeInterval(60), manual: false, now: now))
    }

    @Test func anAnswerGivenInPartKeepsWhatItLeftOutAndSaysSo() async {
        final class Phase: @unchecked Sendable { var partial = false }
        let phase = Phase()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { _ in
            let other = node(["id": "PR_2", "number": 13, "url": "https://github.com/o/r/pull/13"])
            var reply: [String: Any] = ["data": ["rateLimit": ["cost": 1, "remaining": 4000],
                                                  "s0": ["pageInfo": ["hasNextPage": false], "nodes": [node(), other]]]]
            if phase.partial {
                // #12 without its comments, #13 not at all: GitHub's errors say where.
                reply = ["data": ["rateLimit": ["cost": 1, "remaining": 4000],
                                  "s0": ["pageInfo": ["hasNextPage": false], "nodes": [node(["comments": NSNull()]), NSNull()]]],
                         "errors": [["message": "Something went wrong", "path": ["s0", "nodes", 0, "comments"]],
                                    ["message": "Something went wrong", "path": ["s0", "nodes", 1]]]]
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
        var category = InboxCategory(name: "Mine", symbol: "star", color: .blue)
        category.rules = [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])), conditions: [.lastComment(by: Pick())])]
        s.categories = [category]
        var posted: [String] = []
        s.notifier.onPost = { posted.append($0.identifier) }
        await s.syncInbox()
        #expect(s.things.keys.sorted() == ["pr:o/r#12", "pr:o/r#13"] && s.inboxError == nil)
        phase.partial = true
        await s.syncInbox()
        #expect(s.inboxError == "Something went wrong")
        #expect(s.things.keys.sorted() == ["pr:o/r#12", "pr:o/r#13"])
        #expect(s.things["pr:o/r#12"]?.comments.map(\.id) == ["c1", "r2"])
        // Whole again: nothing is new.
        phase.partial = false
        await s.syncInbox()
        #expect(s.inboxError == nil && posted.isEmpty)
    }

    @Test func aThreadYouStartedKeepsYourWordThoughTenOthersRepliedSince() {
        func comment(_ id: String, _ who: String, _ at: String) -> [String: Any] {
            ["id": id, "createdAt": at, "body": "x", "author": ["login": who], "authorAssociation": "NONE"]
        }
        let replies = (0..<InboxSync.threadReplies).map { comment("c\($0 + 1)", "bob", "2026-01-0\($0 < 9 ? 2 : 3)T00:00:0\($0 % 10)Z") }
        let connection: [String: Any] = ["nodes": [["id": "t1", "isResolved": false, "path": "a.swift",
                                                    "first": ["nodes": [comment("c0", "Me", "2026-01-01T00:00:00Z")]],
                                                    "last": ["nodes": replies]]]]
        var thing = InboxFixture.pr(1)
        InboxSync.addThreads(connection, to: &thing)
        #expect(thing.threads.first?.latestBy?["me"] == (try? Date.ISO8601FormatStyle().parse("2026-01-01T00:00:00Z")))
    }

    @Test func reviewThreadsPastTheFirstPageAreReadAndOneThatCantBeKeepsWhatWasKnown() async {
        final class Phase: @unchecked Sendable {
            var fails = false; var pages: [String] = []; var updatedAt = "2026-10-09T10:00:00Z"; var total: Int?
        }
        let phase = Phase()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        nonisolated func thread(_ id: String, resolved: Bool) -> [String: Any] {
            let comment: [String: Any] = ["id": id + "c", "createdAt": "2026-10-08T10:00:00Z", "body": "why? @carol", "authorAssociation": "NONE",
                                          "author": ["login": "bob", "__typename": "User"]]
            return ["id": id, "isResolved": resolved, "path": "a.swift", "first": ["nodes": [comment]], "last": ["nodes": [comment]]]
        }
        s.gh.session = StubbedGitHub.session { request in
            let body = InboxSyncRefresh.body(request)
            let reply: [String: Any]
            if body.contains("node(id:") {
                phase.pages.append(body)
                if phase.fails {
                    reply = ["data": ["p0": NSNull()], "errors": [["message": "Something went wrong", "path": ["p0"]]]]
                } else if body.contains("c2") {
                    reply = ["data": ["p0": ["reviewThreads": ["pageInfo": ["hasNextPage": false], "nodes": [thread("t22", resolved: true)]]]]]
                } else {
                    reply = ["data": ["p0": ["reviewThreads": ["pageInfo": ["hasNextPage": true, "endCursor": "c2"],
                                                               "nodes": [thread("t21", resolved: false)]]]]]
                }
            } else {
                // The first twenty threads, all resolved, and more to come.
                let first = (1...20).map { thread("t\($0)", resolved: true) }
                var threads: [String: Any] = ["pageInfo": ["hasNextPage": true, "endCursor": "c1"], "nodes": first]
                if let total = phase.total { threads["totalCount"] = total }
                let pr = node(["reviewThreads": threads, "updatedAt": phase.updatedAt])
                reply = ["data": ["s0": ["pageInfo": ["hasNextPage": false], "nodes": [pr]]]]
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
        var category = InboxCategory(name: "Mine", symbol: "star", color: .blue)
        category.rules = [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])), conditions: [.unresolvedThreads(startedBy: nil, lastReplyBy: nil)])]
        s.categories = [category]
        await s.syncInbox()
        // The 21st thread, unresolved, is there; the pages were read on from where each ended.
        #expect(s.things["pr:o/r#12"]?.threads.count == 22)
        #expect(s.things["pr:o/r#12"]?.threads.contains { $0.id == "t21" && !$0.isResolved } == true)
        #expect(s.things["pr:o/r#12"]?.mentioned.contains("carol") == true)
        #expect(phase.pages.count == 2 && phase.pages[0].contains("PR_1") && phase.pages[0].contains("c1"))
        #expect(s.entries.contains { $0.thing.id == "pr:o/r#12" })
        // The PR unchanged, the threads read a moment ago stand: they aren't read again, mentions and all.
        await s.syncInbox()
        #expect(phase.pages.count == 2 && s.things["pr:o/r#12"]?.threads.count == 22)
        #expect(s.things["pr:o/r#12"]?.mentioned.contains("carol") == true && s.entries.contains { $0.thing.id == "pr:o/r#12" })
        // Updated since, they are read again, a page sized by what it says it has (22 threads, 20 read).
        phase.updatedAt = "2026-10-09T11:00:00Z"
        phase.total = 22
        await s.syncInbox()
        #expect(phase.pages.count == 4 && phase.pages[2].contains("reviewThreads(first: 2, after:"))
        // Read a while ago, they are read again too.
        s.things["pr:o/r#12"]?.threadsTail?.readAt = Date().addingTimeInterval(-InboxSync.threadsTailAge - 60)
        await s.syncInbox()
        #expect(phase.pages.count == 6)
        // The next page can't be read: the PR keeps the threads it had, and it is said.
        phase.fails = true
        phase.updatedAt = "2026-10-09T12:00:00Z"
        await s.syncInbox()
        #expect(s.things["pr:o/r#12"]?.threads.contains { $0.id == "t21" } == true && s.inboxError == "Something went wrong")
    }

    @Test func threadsPastTheFirstPageAsReadStandWhileGitHubsPointsAreLow() {
        let now = Date()
        var old = InboxSync.thing(node())!
        old.threadsTail = ThreadsTail(total: 30, updatedAt: old.updatedAt, readAt: now.addingTimeInterval(-3600))
        // Changed, and read long ago: read again, unless the points are running low.
        #expect(!InboxSync.keepsTail(old, total: 31, updatedAt: now, now: now, remaining: 4000))
        #expect(InboxSync.keepsTail(old, total: 31, updatedAt: now, now: now, remaining: InboxSync.tailPoints - 1))
        // Never read: read, whatever the points.
        #expect(!InboxSync.keepsTail(InboxSync.thing(node()), total: 30, updatedAt: now, now: now, remaining: 10))
        #expect(InboxSync.threadsPageSize(read: 20, total: 245) == 100 && InboxSync.threadsPageSize(read: 200, total: 245) == 20)
    }

    @Test func whatYourInvolvesSearchFoundStaysInvolvedOnceYourCommentIsPastWhatIsFetched() async {
        final class Phase: @unchecked Sendable { var queries: [String] = [] }
        let phase = Phase()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            let body = InboxSyncRefresh.body(request)
            phase.queries.append(body)
            // Someone else's PR, with nothing of yours among the comments fetched: ten newer ones pushed yours out.
            let pr = node(["author": ["login": "alice", "__typename": "User"], "body": "", "assignees": ["nodes": []],
                           "reviewRequests": ["nodes": []], "comments": ["nodes": []], "reviews": ["nodes": []],
                           "latestOpinionatedReviews": ["nodes": []], "reviewThreads": ["nodes": []]])
            let reply: [String: Any] = ["data": ["s0": ["pageInfo": ["hasNextPage": false], "nodes": [pr]]]]
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
        var category = InboxCategory(name: "Involved", symbol: "star", color: .blue)
        category.rules = [Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.involved])), conditions: [])]
        s.categories = [category]
        await s.syncInbox()
        #expect(phase.queries.first?.contains("involves:me") == true)
        // GitHub says you're involved: it is, and stays so across refreshes.
        #expect(s.entries.contains { $0.thing.id == "pr:o/r#12" })
        await s.syncInbox()
        #expect(s.entries.contains { $0.thing.id == "pr:o/r#12" })
        // Kept as the thing is: written and read back, it still says so.
        let saved = try? JSONDecoder().decode(Thing.self, from: JSONEncoder().encode(s.things["pr:o/r#12"]!))
        #expect(saved?.signals?.involved == true)
        // For you only: signed in as someone else, it isn't theirs.
        var other = s.inboxContext
        other.me = "someone"
        let thing = s.things["pr:o/r#12"]!
        #expect(InboxEngine.evaluate(things: [thing], categories: [category], marks: [:], context: other).isEmpty)
    }

    @Test func reassignedAwayAWholeInvolvesSearchWithoutItTakesBackThatYoureInvolvedButOneCutShortDoesNot() async {
        final class Phase: @unchecked Sendable { var involves = "found" }
        let phase = Phase()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            let body = InboxSyncRefresh.body(request)
            // Someone else's PR, with nothing of yours fetched: only your involves: search ties it to you.
            let pr = node(["author": ["login": "alice", "__typename": "User"], "body": "", "assignees": ["nodes": []],
                           "reviewRequests": ["nodes": []], "comments": ["nodes": []], "reviews": ["nodes": []],
                           "latestOpinionatedReviews": ["nodes": []], "reviewThreads": ["nodes": []]])
            var data: [String: Any] = [:]
            for i in 0..<8 {
                guard let start = body.range(of: "s\(i): search(") else { continue }
                let query = body[start.upperBound...].prefix { $0 != ")" }
                if query.contains("involves:me") {
                    switch phase.involves {
                    case "found": data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": [pr]]
                    case "more": data["s\(i)"] = ["pageInfo": ["hasNextPage": true, "endCursor": "c"], "nodes": []]
                    default: data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": []]
                    }
                } else if query.contains("repo:o") {
                    data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": [pr]]
                } else {
                    data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": []]
                }
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        var involved = InboxCategory(name: "Involved", symbol: "star", color: .blue)
        involved.rules = [Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.involved])), conditions: [])]
        var repo = InboxCategory(name: "Repo", symbol: "star", color: .blue)
        repo.rules = [Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.repo("o/r")])), conditions: [])]
        s.categories = [involved, repo]
        func category() -> UUID? { s.entries.first { $0.thing.id == "pr:o/r#12" }?.categoryID }
        await s.syncInbox()
        #expect(category() == involved.id)
        // Your involves: search, cut short (more pages than were read), says nothing: it stays involved.
        phase.involves = "more"
        await s.syncInbox()
        #expect(category() == involved.id)
        // Read whole, without it (you were reassigned away) while the repo's search still brings it: no longer involved.
        phase.involves = "gone"
        await s.syncInbox()
        #expect(s.things["pr:o/r#12"]?.signals?.involved == nil)
        #expect(category() == repo.id)
    }

    @Test func aConversationYourMentionsSearchFindsStaysToYouMentionedPastTenNewerCommentsUntilAWholeSearchNoLongerDoes() async {
        final class Phase: @unchecked Sendable { var mentions = "found" }
        let phase = Phase()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            let body = InboxSyncRefresh.body(request)
            // Someone else's PR whose mention of you came before the ten comments fetched, none of which mentions you.
            let comments = (0..<10).map { n -> [String: Any] in
                ["id": "c\(n)", "createdAt": "2026-10-0\(n % 9 + 1)T10:00:00Z", "body": "more", "authorAssociation": "NONE",
                 "author": ["login": "alice", "__typename": "User", "avatarUrl": ""]]
            }
            let pr = node(["author": ["login": "alice", "__typename": "User"], "body": "", "assignees": ["nodes": []],
                           "reviewRequests": ["nodes": []], "comments": ["nodes": comments], "reviews": ["nodes": []],
                           "latestOpinionatedReviews": ["nodes": []], "reviewThreads": ["nodes": []]])
            var data: [String: Any] = [:]
            for i in 0..<8 {
                guard let start = body.range(of: "s\(i): search(") else { continue }
                let query = body[start.upperBound...].prefix { $0 != ")" }
                if query.contains("mentions:me") {
                    switch phase.mentions {
                    case "found": data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": [pr]]
                    case "more": data["s\(i)"] = ["pageInfo": ["hasNextPage": true, "endCursor": "c"], "nodes": []]
                    default: data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": []]
                    }
                } else if query.contains("repo:o") {
                    data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": [pr]]
                } else {
                    data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": []]
                }
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        var mentioned = InboxCategory(name: "Mentioned", symbol: "star", color: .blue)
        mentioned.rules = [Rule(scope: Scope(kinds: [.pr], to: Pick(include: [.me]), toRoles: [.mentioned]), conditions: [])]
        var repo = InboxCategory(name: "Repo", symbol: "star", color: .blue)
        repo.rules = [Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.repo("o/r")])), conditions: [])]
        s.categories = [mentioned, repo]
        func category() -> UUID? { s.entries.first { $0.thing.id == "pr:o/r#12" }?.categoryID }
        await s.syncInbox()
        #expect(s.things["pr:o/r#12"]?.mentioned.isEmpty == true)
        #expect(category() == mentioned.id)
        // Your mentions: search, cut short, says nothing: it is still to you (mentioned).
        phase.mentions = "more"
        await s.syncInbox()
        #expect(category() == mentioned.id)
        // Read whole, without it, while the repo's search still brings it: no longer.
        phase.mentions = "gone"
        await s.syncInbox()
        #expect(category() == repo.id)
    }

    @Test func aConversationSomeonesMentionsSearchFindsStaysToThemMentionedPastTenNewerCommentsUntilAWholeSearchNoLongerDoes() async {
        final class Phase: @unchecked Sendable { var mentions = "found" }
        let phase = Phase()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            let body = InboxSyncRefresh.body(request)
            // Bob's PR whose mention of alice came before the ten comments fetched, none of which mentions her.
            let comments = (0..<10).map { n -> [String: Any] in
                ["id": "c\(n)", "createdAt": "2026-10-0\(n % 9 + 1)T10:00:00Z", "body": "more", "authorAssociation": "NONE",
                 "author": ["login": "alice", "__typename": "User", "avatarUrl": ""]]
            }
            let pr = node(["author": ["login": "bob", "__typename": "User"], "body": "", "assignees": ["nodes": []],
                           "reviewRequests": ["nodes": []], "comments": ["nodes": comments], "reviews": ["nodes": []],
                           "latestOpinionatedReviews": ["nodes": []], "reviewThreads": ["nodes": []]])
            var data: [String: Any] = [:]
            for i in 0..<8 {
                guard let start = body.range(of: "s\(i): search(") else { continue }
                let query = body[start.upperBound...].prefix { $0 != ")" }
                if query.contains("mentions:alice") {
                    switch phase.mentions {
                    case "found": data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": [pr]]
                    case "more": data["s\(i)"] = ["pageInfo": ["hasNextPage": true, "endCursor": "c"], "nodes": []]
                    default: data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": []]
                    }
                } else if query.contains("repo:o") {
                    data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": [pr]]
                } else {
                    data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": []]
                }
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        var mentioned = InboxCategory(name: "Mentioned", symbol: "star", color: .blue)
        mentioned.rules = [Rule(scope: Scope(kinds: [.pr], to: Pick(include: [.user("alice")]), toRoles: [.mentioned]), conditions: [])]
        var repo = InboxCategory(name: "Repo", symbol: "star", color: .blue)
        repo.rules = [Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.repo("o/r")])), conditions: [])]
        s.categories = [mentioned, repo]
        func category() -> UUID? { s.entries.first { $0.thing.id == "pr:o/r#12" }?.categoryID }
        await s.syncInbox()
        #expect(s.things["pr:o/r#12"]?.mentioned.isEmpty == true)
        #expect(category() == mentioned.id)
        // Kept across refreshes, and as the thing is: written and read back, it still says so.
        await s.syncInbox()
        #expect(category() == mentioned.id)
        let saved = try? JSONDecoder().decode(Thing.self, from: JSONEncoder().encode(s.things["pr:o/r#12"]!))
        #expect(saved?.mentionedBySearch == ["alice": true])
        // Her mentions: search, cut short, says nothing: it is still to her (mentioned).
        phase.mentions = "more"
        await s.syncInbox()
        #expect(category() == mentioned.id)
        // Read whole, without it, while the repo's search still brings it: no longer.
        phase.mentions = "gone"
        await s.syncInbox()
        #expect(category() == repo.id)
    }

    @Test func mentionsSearchEvidenceIsKeptPerPersonAndBounded() {
        var pr = InboxFixture.pr(12, repo: "o/r", by: Person(login: "bob"))
        let found = "is:pr archived:false mentions:Alice repo:o/r is:open"
        let whole = "is:pr archived:false mentions:carol is:open"
        InboxSync.markMentioned(&pr, foundBy: [found], complete: [found, whole])
        #expect(pr.mentionedBySearch == ["alice": true, "carol": false])
        // Over what was kept: carol's whole search without it takes hers back; dave's, not run, stays.
        InboxSync.carryMentions(["carol": true, "dave": true], into: &pr)
        #expect(pr.mentionedBySearch == ["alice": true, "dave": true])
        // At most so many people: those found this time first.
        var many = pr
        many.mentionedBySearch = ["zed": true]
        let old = Dictionary(uniqueKeysWithValues: (0..<30).map { ("p\($0)", true) })
        InboxSync.carryMentions(old, into: &many)
        #expect(many.mentionedBySearch?.count == InboxSync.maxSearchMentions && many.mentionedBySearch?["zed"] == true)
    }

    @Test func aDraftIsOpenToAnInvolvesSearchSoUnassignedFromOneItIsNoLongerInvolved() {
        var draft = InboxFixture.pr(12, repo: "o/r", by: Person(login: "alice"))
        draft.status = .draft
        draft.signals = ThingSignals(viewer: "me", involved: true)
        let query = "is:pr archived:false involves:me is:open sort:updated-desc"
        #expect(InboxSync.wouldFind(query, draft, me: "me"))
        InboxSync.markInvolved(&draft, foundBy: [], complete: [query], me: "me")
        #expect(draft.signals?.involved == false)
    }

    @Test func aSearchInTheThingsRepoOrOwnerWouldFindItAndOneOfSeveralIsEnough() {
        var pr = InboxFixture.pr(12, repo: "o/r", by: Person(login: "alice"))
        pr.signals = ThingSignals(viewer: "me", involvedBy: ["mentions": true])
        #expect(InboxSync.wouldFind("is:pr archived:false mentions:me repo:O/R is:open", pr, me: "me"))
        #expect(InboxSync.wouldFind("is:pr archived:false mentions:me user:o is:open", pr, me: "me"))
        #expect(InboxSync.wouldFind("is:pr archived:false mentions:me repo:x/y repo:o/r is:open", pr, me: "me"))
        #expect(InboxSync.wouldFind("is:pr archived:false mentions:me repo:x/y org:o is:open", pr, me: "me"))
        #expect(!InboxSync.wouldFind("is:pr archived:false mentions:me repo:x/y user:z is:open", pr, me: "me"))
        // A repo's mentions search read whole without it: no longer mentioned there.
        InboxSync.markInvolved(&pr, foundBy: [], complete: ["is:pr archived:false mentions:me repo:o/r is:open"], me: "me")
        #expect(pr.signals?.involvedBy?["mentions"] == false)
    }

    @Test func aBotsPRIsLeftOutByTheBotsAuthorQualifierAsTheQueryWritesIt() {
        var pr = InboxFixture.pr(12, repo: "o/r", by: Person(login: "renovate[bot]"))
        pr.signals = ThingSignals(viewer: "me", involved: true)
        // A search leaving the bot out never returns its PR: its absence there says nothing, and it stays involved.
        let query = "is:pr archived:false involves:me -author:app/renovate is:open sort:updated-desc"
        #expect(!InboxSync.wouldFind(query, pr, me: "me"))
        InboxSync.markInvolved(&pr, foundBy: [], complete: [query], me: "me")
        #expect(pr.signals?.involved == true)
        #expect(InboxSync.wouldFind("is:pr involves:me author:app/renovate", pr, me: "me"))
    }

    @Test func aReviewSearchOfYoursKeepsYouInvolvedUntilItsOwnWholeSearchNoLongerFindsIt() async {
        final class Phase: @unchecked Sendable { var requested = true; var reviewed = false }
        let phase = Phase()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            let body = InboxSyncRefresh.body(request)
            // Someone else's PR asked of your team only, with nothing of yours fetched (your review is past those fetched):
            // only your review searches tie it to you; your involves: search, read whole, never finds it.
            let pr = node(["author": ["login": "alice", "__typename": "User"], "body": "", "assignees": ["nodes": []],
                           "reviewRequests": ["nodes": [["requestedReviewer": ["combinedSlug": "org/core"]]]],
                           "comments": ["nodes": []], "reviews": ["nodes": []],
                           "latestOpinionatedReviews": ["nodes": []], "reviewThreads": ["nodes": []]])
            var data: [String: Any] = [:]
            for i in 0..<8 {
                guard let start = body.range(of: "s\(i): search(") else { continue }
                let query = body[start.upperBound...].prefix { $0 != ")" }
                let found = query.contains("repo:o") || (query.contains("review-requested:me") && phase.requested)
                    || (query.contains("reviewed-by:me") && phase.reviewed)
                data["s\(i)"] = ["pageInfo": ["hasNextPage": false], "nodes": found ? [pr] : []]
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        var involved = InboxCategory(name: "Involved", symbol: "star", color: .blue)
        involved.rules = [Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.involved])), conditions: [])]
        var repo = InboxCategory(name: "Repo", symbol: "star", color: .blue)
        repo.rules = [Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.repo("o/r")])), conditions: [])]
        s.categories = [involved, repo]
        func category() -> UUID? { s.entries.first { $0.thing.id == "pr:o/r#12" }?.categoryID }
        await s.syncInbox()
        #expect(category() == involved.id)
        let saved = try? JSONDecoder().decode(Thing.self, from: JSONEncoder().encode(s.things["pr:o/r#12"]!))
        #expect(saved?.signals?.involvedBy == ["review-requested": true])
        // Reviewed: the request is gone, and your reviewed-by: search holds it.
        phase.requested = false
        phase.reviewed = true
        await s.syncInbox()
        #expect(category() == involved.id)
        // Neither finds it any more, read whole: no longer involved.
        phase.reviewed = false
        await s.syncInbox()
        #expect(s.things["pr:o/r#12"]?.signals?.involvedBy == nil)
        #expect(category() == repo.id)
    }

    @Test func anEventAnnouncedOnceStaysAnnouncedThoughTheRuleStopsMatchingForAWhile() async {
        final class Checks: @unchecked Sendable { var state = "SUCCESS" }
        let checks = Checks()
        let s = Store()
        s.persists = false
        s.settings.triage = true
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { _ in
            let pr = node(["commits": ["nodes": [["commit": ["oid": "abc", "committedDate": "2026-10-08T11:00:00Z",
                                                             "author": ["user": ["login": "me"]],
                                                             "statusCheckRollup": ["state": checks.state]]]]]])
            let reply: [String: Any] = ["data": ["rateLimit": ["cost": 1, "remaining": 4000],
                                                  "s0": ["pageInfo": ["hasNextPage": false], "nodes": [pr]]]]
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
        var category = InboxCategory(name: "Mine", symbol: "star", color: .blue)
        category.rules = [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])), match: .all,
                               conditions: [.newComment(by: Pick()), .checks([.failing])], createdAt: .distantPast)]
        s.categories = [category]
        var bodies: [String] = []
        s.notifier.onPost = { bodies.append($0.content.body) }
        await s.syncInbox()
        checks.state = "FAILURE"
        await s.syncInbox()
        #expect(bodies.count == 1 && bodies[0].contains("comment by @greptile-apps[bot]"))
        // Passing, then failing again: the failure is new, the comment isn't.
        checks.state = "SUCCESS"
        await s.syncInbox()
        #expect(s.marks["pr:o/r#12"]?.notified.contains("comment:c1") == true)
        #expect(s.marks["pr:o/r#12"]?.notified.contains("checks:failing") == false)
        checks.state = "FAILURE"
        await s.syncInbox()
        #expect(bodies.count == 2 && !bodies[1].contains("comment"))
        // Not an event once the thing no longer has it.
        let t = try! #require(InboxSync.thing(node()))
        #expect(InboxSync.isEvent("comment:c1", of: t) && !InboxSync.isEvent("comment:gone", of: t))
        let asked = Int(ISO8601DateFormatter().date(from: "2026-10-04T10:00:00Z")!.timeIntervalSince1970)
        #expect(InboxSync.isEvent("requested:bob:\(asked)", of: t) && !InboxSync.isEvent("checks:failing", of: t))
        // An older request of the same reviewer (reviewed since, then asked again) is gone: only the current one stays.
        #expect(!InboxSync.isEvent("requested:bob:1", of: t))
    }

    @Test func withNothingToAskForTheThingsGoAndTheirMarksStartTheirMonth() async {
        let s = InboxFixture.store([InboxFixture.pr(1)])
        s.marks["pr:a/one#1"] = EntryMarks(seen: ["greptile:3"])
        s.categories = []
        await s.syncInbox()
        #expect(s.things.isEmpty)
        #expect(s.marks["pr:a/one#1"]?.goneSince != nil)
    }

    @Test func aThreadReopenedIsNewAgain() {
        var thing = InboxFixture.pr(3)
        let alice = Person(login: "alice")
        thing.threads = [ThingThread(id: "t1", isResolved: false, startedBy: alice, lastReplyBy: alice, lastReplyID: "r1",
                                     lastReplyAt: Date().addingTimeInterval(-60), snippet: "why?")]
        let category = InboxCategory(name: "Threads", symbol: "star", color: .blue,
                                     rules: [Rule(scope: Scope(kinds: [.pr]), conditions: [.unresolvedThreads(startedBy: Pick(), lastReplyBy: Pick())],
                                                  createdAt: .distantPast)])
        let s = InboxFixture.store([thing], category: category)
        var posted: [String] = []
        s.notifier.onPost = { posted.append($0.content.body) }
        s.announceInbox()
        s.markDone(s.entries[0])
        #expect(s.marks[thing.id]?.notified.contains("thread:t1:r1") == true)
        // Resolved: the fact is gone, and so are its marks.
        thing.threads[0].isResolved = true
        s.things[thing.id] = thing
        s.announceInbox()
        #expect(s.marks[thing.id]?.notified.contains("thread:t1:r1") != true && s.marks[thing.id]?.acked.contains("thread:t1:r1") != true)
        // Reopened with no new reply: it asks again.
        thing.threads[0].isResolved = false
        s.things[thing.id] = thing
        s.announceInbox()
        #expect(posted == ["1 unresolved"])
        #expect(s.entries.first?.isDone == false)
    }

    @Test func pastTheCapTheSearchesTakeTurnsAndWhatTheOthersFoundStays() async {
        final class Box: @unchecked Sendable { var asked: [String] = []; var hidden: Set<Int> = []; var firsts: Set<String> = [] }
        let box = Box()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        // Seventeen rules of one search each: one more than a refresh makes.
        s.categories = [InboxCategory(name: "People", symbol: "star", color: .blue, rules: (0..<17).map {
            Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.user("u\($0)")])))
        })]
        let pattern = try! NSRegularExpression(pattern: #"(s\d+): search\(query: \"[^"]*author:u(\d+) [^"]*\", type: ISSUE, first: (\d+)"#)
        s.gh.session = StubbedGitHub.session { request in
            let body = try JSONSerialization.jsonObject(with: Data(InboxSyncRefresh.body(request).utf8)) as? [String: Any]
            let text = body?["query"] as? String ?? ""
            var data: [String: Any] = ["rateLimit": ["cost": 1, "remaining": 4000]]
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let part = { (i: Int) in String(text[Range(m.range(at: i), in: text)!]) }
                let n = Int(part(2))!
                box.asked.append("u\(n)")
                box.firsts.insert(part(3))
                let found = box.hidden.contains(n) ? [] : [node(["id": "PR_\(n)", "number": n, "url": "https://github.com/o/r/pull/\(n)"])]
                data[part(1)] = ["pageInfo": ["hasNextPage": false], "nodes": found]
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        await s.syncInbox()
        #expect(box.asked.count == 16 && !box.asked.contains("u16") && s.things.count == 16)
        // What the sixteen searches ask for is within the cap before they are made.
        #expect(box.firsts == ["\(InboxSync.maxThings / 16)"])
        box.asked = []
        await s.syncInbox()
        // The seventeenth gets its turn; the one left out this time keeps what it found.
        #expect(box.asked.contains("u16") && !box.asked.contains("u15"))
        #expect(s.things.count == 17 && s.things["pr:o/r#15"] != nil)
        // A search that ran and didn't find it again: gone.
        box.hidden = [0]
        await s.syncInbox()
        #expect(s.things["pr:o/r#0"] == nil && s.things.count == 16)
    }

    @Test func aSearchCutShortAtTheCapsKeepsWhatItDidntReach() async {
        final class Box: @unchecked Sendable { var shown: [Int] = [1, 2]; var more = false }
        let box = Box()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.categories = [InboxCategory(name: "Repo", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.user("u")])))
        ])]
        s.gh.session = StubbedGitHub.session { request in
            let text = InboxSyncRefresh.body(request)
            // Its first page has what is shown; the pages after it, none of them (they are past the caps).
            let first = !text.contains("after:")
            let nodes = first ? box.shown.map { node(["id": "PR_\($0)", "number": $0, "url": "https://github.com/o/r/pull/\($0)"]) } : []
            let info: [String: Any] = box.more ? ["hasNextPage": true, "endCursor": "c"] : ["hasNextPage": false]
            let reply: [String: Any] = ["data": ["rateLimit": ["cost": 1, "remaining": 4000], "s0": ["pageInfo": info, "nodes": nodes]]]
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
        await s.syncInbox()
        #expect(s.things["pr:o/r#1"] != nil && s.things["pr:o/r#2"] != nil)
        // The repo has more PRs than are fetched: #2 falls past the caps, and the search has pages left.
        box.shown = [1]
        box.more = true
        await s.syncInbox()
        #expect(s.things["pr:o/r#2"] != nil)
        // Read to its end without it: gone.
        box.more = false
        await s.syncInbox()
        #expect(s.things["pr:o/r#2"] == nil && s.things["pr:o/r#1"] != nil)
    }

    @Test func aPRKeptPastTheCapsIsLookedAtAgainAndLeavesOnceMerged() async {
        final class Box: @unchecked Sendable { var shown: [Int] = [1, 2]; var more = false; var merged: Set<Int> = []; var looked: [String] = [] }
        let box = Box()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.categories = [InboxCategory(name: "Repo", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.user("u")])))
        ])]
        s.gh.session = StubbedGitHub.session { request in
            let text = InboxSyncRefresh.body(request)
            func pr(_ n: Int) -> [String: Any] {
                box.merged.contains(n)
                    ? node(["id": "PR_\(n)", "number": n, "url": "https://github.com/o/r/pull/\(n)", "state": "MERGED", "merged": true,
                            "updatedAt": "2026-10-10T10:00:00Z"])
                    : node(["id": "PR_\(n)", "number": n, "url": "https://github.com/o/r/pull/\(n)"])
            }
            var data: [String: Any] = ["rateLimit": ["cost": 1, "remaining": 4000]]
            if text.contains("nodes(ids:") {
                let ids = (1...2).filter { text.contains("PR_\($0)") }
                box.looked.append(text.contains("...P") ? "whole" : "states")
                data["nodes"] = ids.map { n -> [String: Any] in
                    let whole = pr(n)
                    return text.contains("...P") ? whole
                        : ["__typename": "PullRequest", "id": "PR_\(n)", "state": whole["state"]!, "merged": whole["merged"]!,
                           "isDraft": false, "updatedAt": whole["updatedAt"]!]
                }
            } else {
                // Its first page has what is shown; the pages after it, none of them (they are past the caps).
                let first = !text.contains("after:")
                let info: [String: Any] = box.more ? ["hasNextPage": true, "endCursor": "c"] : ["hasNextPage": false]
                data["s0"] = ["pageInfo": info, "nodes": first ? box.shown.map(pr) : []]
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        await s.syncInbox()
        #expect(s.things["pr:o/r#2"] != nil)
        // #2 falls past the caps: kept, and looked at again; as it was, it stays as it was.
        box.shown = [1]
        box.more = true
        await s.syncInbox()
        #expect(s.things["pr:o/r#2"]?.status == .open && box.looked == ["states"])
        // Merged meanwhile: the look tells, it is read whole, and it goes.
        box.merged = [2]
        box.looked = []
        await s.syncInbox()
        #expect(box.looked == ["states", "whole"])
        #expect(s.things["pr:o/r#2"] == nil && s.things["pr:o/r#1"] != nil)
    }

    @Test func aKeptPRGitHubGivesInPartWhenLookedAtAgainStaysAsItWasAndIsLookedAtAgain() async {
        final class Box: @unchecked Sendable { var shown: [Int] = [1, 2]; var updated = "2026-10-09T10:00:00Z"; var broken = false; var looked: [String] = [] }
        let box = Box()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.categories = [InboxCategory(name: "Repo", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.user("u")])))
        ])]
        s.gh.session = StubbedGitHub.session { request in
            let text = InboxSyncRefresh.body(request)
            func pr(_ n: Int) -> [String: Any] {
                let updated: String = n == 2 ? box.updated : "2026-10-09T10:00:00Z"
                return node(["id": "PR_\(n)", "number": n, "url": "https://github.com/o/r/pull/\(n)", "updatedAt": updated])
            }
            var data: [String: Any] = ["rateLimit": ["cost": 1, "remaining": 4000]]
            var errors: [[String: Any]] = []
            if text.contains("nodes(ids:") {
                let whole = text.contains("...P")
                box.looked.append(whole ? "whole" : "states")
                var full = pr(2)
                // Its review requests GitHub couldn't give: null, with an error on them.
                if box.broken { full["reviewRequests"] = NSNull() }
                let state: [String: Any] = ["__typename": "PullRequest", "id": "PR_2", "state": "OPEN", "merged": false,
                                            "isDraft": false, "updatedAt": box.updated]
                data["nodes"] = [whole ? full : state]
                if whole, box.broken { errors = [["message": "Something went wrong", "path": ["nodes", 0, "reviewRequests"]]] }
            } else {
                let first = !text.contains("after:")
                let info: [String: Any] = box.shown.count == 1 ? ["hasNextPage": true, "endCursor": "c"] : ["hasNextPage": false]
                data["s0"] = ["pageInfo": info, "nodes": first ? box.shown.map(pr) : []]
            }
            var reply: [String: Any] = ["data": data]
            if !errors.isEmpty { reply["errors"] = errors }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
        await s.syncInbox()
        #expect(s.things["pr:o/r#2"]?.requestedReviewers.contains("bob") == true)
        let before = s.things["pr:o/r#2"]?.updatedAt
        // #2 falls past the caps, then changes; the look at it whole comes without its review requests.
        box.shown = [1]
        box.updated = "2026-10-10T10:00:00Z"
        box.broken = true
        await s.syncInbox()
        #expect(box.looked == ["states", "whole"])
        // It stays as it was (its request to bob still pending, its time unchanged), and the failure is said.
        #expect(s.things["pr:o/r#2"]?.requestedReviewers.contains("bob") == true)
        #expect(s.things["pr:o/r#2"]?.updatedAt == before)
        #expect(s.inboxError != nil)
        // Looked at again at the next refresh: still changed since what is kept, it is read whole, and taken.
        box.broken = false
        box.looked = []
        await s.syncInbox()
        #expect(box.looked == ["states", "whole"])
        #expect(s.things["pr:o/r#2"]?.updatedAt != before && s.things["pr:o/r#2"]?.requestedReviewers.contains("bob") == true)
        #expect(s.inboxError == nil)
    }

    @Test func aKeptPRLookedAtAgainReadsOnItsReviewThreadsAsASearchDoes() async {
        final class Box: @unchecked Sendable {
            var shown: [Int] = [1, 2]; var updated = "2026-10-09T10:00:00Z"; var tail = "t21"; var pages = 0
        }
        let box = Box()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.categories = [InboxCategory(name: "Repo", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.user("u")])))
        ])]
        s.gh.session = StubbedGitHub.session { request in
            let text = InboxSyncRefresh.body(request)
            func thread(_ id: String) -> [String: Any] {
                let comment: [String: Any] = ["id": id + "c", "createdAt": "2026-10-08T10:00:00Z", "body": "why?", "authorAssociation": "NONE",
                                              "author": ["login": "bob", "__typename": "User"]]
                return ["id": id, "isResolved": false, "path": "a.swift", "first": ["nodes": [comment]], "last": ["nodes": [comment]]]
            }
            func pr(_ n: Int) -> [String: Any] {
                guard n == 2 else { return node(["id": "PR_1", "number": 1, "url": "https://github.com/o/r/pull/1"]) }
                // Twenty threads on its first page, and more past it.
                let threads: [String: Any] = ["totalCount": 21, "pageInfo": ["hasNextPage": true, "endCursor": "c1"],
                                              "nodes": (1...20).map { thread("t\($0)") }]
                return node(["id": "PR_2", "number": 2, "url": "https://github.com/o/r/pull/2", "updatedAt": box.updated,
                             "reviewThreads": threads])
            }
            var data: [String: Any] = ["rateLimit": ["cost": 1, "remaining": 4000]]
            if text.contains("node(id:") {
                box.pages += 1
                data["p0"] = ["reviewThreads": ["pageInfo": ["hasNextPage": false], "nodes": [thread(box.tail)]]]
            } else if text.contains("nodes(ids:") {
                let state: [String: Any] = ["__typename": "PullRequest", "id": "PR_2", "state": "OPEN", "merged": false,
                                            "isDraft": false, "updatedAt": box.updated]
                data["nodes"] = [text.contains("...P") ? pr(2) : state]
            } else {
                let first = !text.contains("after:")
                let info: [String: Any] = box.shown.count == 1 ? ["hasNextPage": true, "endCursor": "c"] : ["hasNextPage": false]
                data["s0"] = ["pageInfo": info, "nodes": first ? box.shown.map(pr) : []]
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        await s.syncInbox()
        #expect(s.things["pr:o/r#2"]?.threads.contains { $0.id == "t21" } == true && box.pages == 1)
        // #2 falls past the caps, then changes: the thread past its first page is another now.
        box.shown = [1]
        box.updated = "2026-10-10T10:00:00Z"
        box.tail = "t22"
        await s.syncInbox()
        // What is past its first page is read again, as it is now, not taken as read before.
        #expect(box.pages == 2)
        #expect(s.things["pr:o/r#2"]?.threads.contains { $0.id == "t22" } == true)
        #expect(s.things["pr:o/r#2"]?.threads.contains { $0.id == "t21" } == false)
        #expect(s.things["pr:o/r#2"]?.threadsTail?.updatedAt == s.things["pr:o/r#2"]?.updatedAt)
    }

    @Test func aSearchGitHubDidntAnswerHasntRunAndWhatItFoundStaysUntilItDoes() async {
        final class Box: @unchecked Sendable { var asked: [String] = []; var hidden: Set<Int> = []; var failing: Set<Int> = [] }
        let box = Box()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.categories = [InboxCategory(name: "People", symbol: "star", color: .blue, rules: (0..<17).map {
            Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.user("u\($0)")])))
        })]
        let pattern = try! NSRegularExpression(pattern: #"(s\d+): search\(query: \"[^"]*author:u(\d+) "#)
        s.gh.session = StubbedGitHub.session { request in
            let body = try JSONSerialization.jsonObject(with: Data(InboxSyncRefresh.body(request).utf8)) as? [String: Any]
            let text = body?["query"] as? String ?? ""
            var data: [String: Any] = [:]
            var errors: [[String: Any]] = []
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let part = { (i: Int) in String(text[Range(m.range(at: i), in: text)!]) }
                let n = Int(part(2))!
                box.asked.append("u\(n)")
                if box.failing.contains(n) {
                    data[part(1)] = NSNull()
                    errors.append(["path": [part(1)], "message": "Something went wrong"])
                    continue
                }
                let found = box.hidden.contains(n) ? [] : [node(["id": "PR_\(n)", "number": n, "url": "https://github.com/o/r/pull/\(n)"])]
                data[part(1)] = ["pageInfo": ["hasNextPage": false], "nodes": found]
            }
            let reply: [String: Any] = errors.isEmpty ? ["data": data] : ["data": data, "errors": errors]
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
        await s.syncInbox()
        #expect(s.things.count == 16 && s.things["pr:o/r#14"] != nil)
        // u14's search fails in its turn: what it found stays, as one GitHub didn't answer.
        box.failing = [14]
        box.asked = []
        await s.syncInbox()
        #expect(box.asked.contains("u14") && s.things["pr:o/r#14"] != nil)
        // Its turn passes without it: it still hasn't run, so what it found still stays.
        box.failing = []
        box.asked = []
        await s.syncInbox()
        #expect(!box.asked.contains("u14") && s.things["pr:o/r#14"] != nil)
        // It runs and doesn't find it: gone.
        box.hidden = [14]
        box.asked = []
        await s.syncInbox()
        #expect(box.asked.contains("u14") && s.things["pr:o/r#14"] == nil)
    }

    @Test func seenFactsThatAreGoneAreForgottenAsNotifiedAndAckedOnesAre() throws {
        let s = InboxFixture.store([InboxFixture.pr(1)])
        let entry = try #require(s.entries(in: s.categories[0].id).first)
        let current = Set(entry.facts.map(\.key))
        #expect(!current.isEmpty)
        s.marks[entry.id] = EntryMarks(seen: current.union(["checks:failing", "comment:gone"]))
        s.announceInbox()
        #expect(s.marks[entry.id]?.seen == current)
    }

    @Test func marksOfThingsGoneForAMonthAreForgotten() {
        let (s, _) = store(Log())
        s.marks = ["pr:o/r#9": EntryMarks(seen: ["x"])]
        let now = Date()
        s.applyThings([:], now: now)
        #expect(s.marks["pr:o/r#9"] != nil)
        s.applyThings([:], now: now.addingTimeInterval(31 * 86400))
        #expect(s.marks["pr:o/r#9"] == nil)
    }

    @Test func aThingsMonthGoneGoesOnAcrossARestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let now = Date()
        let first = Store()
        first.stateFile = file
        first.marks = ["pr:o/r#9": EntryMarks(seen: ["x"]), "pr:o/r#1": EntryMarks(seen: ["y"])]
        first.applyThings(["pr:o/r#1": InboxFixture.pr(1, repo: "o/r")], now: now)
        first.flushSave()

        let second = Store()
        second.stateFile = file
        second.load()
        second.persists = false
        #expect(second.marks["pr:o/r#9"]?.goneSince != nil && second.marks["pr:o/r#1"]?.goneSince == nil)
        // A month after it went (not after the restart), it is forgotten; the one still there stays.
        second.applyThings(["pr:o/r#1": InboxFixture.pr(1, repo: "o/r")], now: now.addingTimeInterval(31 * 86400))
        #expect(second.marks["pr:o/r#9"] == nil && second.marks["pr:o/r#1"] != nil)
        // Back before the month is out: the count starts again.
        second.marks["pr:o/r#1"]?.goneSince = now
        second.applyThings(["pr:o/r#1": InboxFixture.pr(1, repo: "o/r")], now: now)
        #expect(second.marks["pr:o/r#1"]?.goneSince == nil)
    }

    @Test func aNewCategoryForARepoNotYetReadTakesInItsOpenPRsOnceTheyAreFetchedAndActsOnlyOnWhatComesAfter() async {
        final class Box: @unchecked Sendable { var shown: [Int] = [1] }
        let box = Box()
        let s = Store()
        s.persists = false
        s.settings.triage = true
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        let performer = FakePerformer()
        s.actionPerformer = performer
        s.categories = [InboxCategory(name: "Mine", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])))
        ])]
        let pattern = try! NSRegularExpression(pattern: #"(s\d+): search\(query: \"([^"]*)\""#)
        s.gh.session = StubbedGitHub.session { request in
            let body = try JSONSerialization.jsonObject(with: Data(InboxSyncRefresh.body(request).utf8)) as? [String: Any]
            let text = body?["query"] as? String ?? ""
            var data: [String: Any] = ["rateLimit": ["cost": 1, "remaining": 4000]]
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let part = { (i: Int) in String(text[Range(m.range(at: i), in: text)!]) }
                // Only the new repo has PRs: open ones, there before the category was made.
                let nodes = part(2).contains("repo:o/new") ? box.shown.map {
                    node(["id": "PR_\($0)", "number": $0, "url": "https://github.com/o/new/pull/\($0)",
                          "repository": ["nameWithOwner": "o/new"], "author": ["login": "alice", "__typename": "User"]])
                } : []
                data[part(1)] = ["pageInfo": ["hasNextPage": false], "nodes": nodes]
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        await s.syncInbox()
        #expect(s.things.isEmpty)
        // A category with a comment action for a repo not read yet: its pause passes before any refresh has read it.
        var made = InboxCategory(name: "New", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.repo("o/new")])), conditions: [.greptileBelow(5)])
        ])
        made.actions = ActionList([CategoryAction.make(.comment("Thanks"))])
        s.categories.append(made)
        s.categoriesEdited(delay: .milliseconds(10))
        await s.baselineTask?.value
        await s.runActions()
        #expect(s.baselinePending)
        // The refresh that reads it brings its open PR: there already, it is taken in, not acted on.
        await s.syncInbox()
        await s.runActions()
        #expect(s.things["pr:o/new#1"] != nil && !s.baselinePending)
        #expect(performer.comments.isEmpty)
        // A PR opened after is acted on.
        box.shown = [1, 2]
        await s.syncInbox()
        await s.runActions()
        #expect(performer.comments.map(\.number) == [2])
    }

    @Test func aNewCategoryForARepoNotYetReadStillWaitsForItsFetchAfterARestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        final class Box: @unchecked Sendable { var shown: [Int] = [1] }
        let box = Box()
        let pattern = try! NSRegularExpression(pattern: #"(s\d+): search\(query: \"([^"]*)\""#)
        let session = StubbedGitHub.session { request in
            let body = try JSONSerialization.jsonObject(with: Data(InboxSyncRefresh.body(request).utf8)) as? [String: Any]
            let text = body?["query"] as? String ?? ""
            var data: [String: Any] = ["rateLimit": ["cost": 1, "remaining": 4000]]
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let part = { (i: Int) in String(text[Range(m.range(at: i), in: text)!]) }
                let nodes = part(2).contains("repo:o/new") ? box.shown.map {
                    node(["id": "PR_\($0)", "number": $0, "url": "https://github.com/o/new/pull/\($0)",
                          "repository": ["nameWithOwner": "o/new"], "author": ["login": "alice", "__typename": "User"]])
                } : []
                data[part(1)] = ["pageInfo": ["hasNextPage": false], "nodes": nodes]
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        let first = Store()
        first.stateFile = file
        first.settings.triage = true
        first.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        first.actionPerformer = FakePerformer()
        first.categories = [InboxCategory(name: "Mine", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])))
        ])]
        first.gh.session = session
        await first.syncInbox()
        // A category with a comment action for a repo not read yet, then a quit before any refresh has read it.
        var made = InboxCategory(name: "New", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.repo("o/new")])), conditions: [.greptileBelow(5)])
        ])
        made.actions = ActionList([CategoryAction.make(.comment("Thanks"))])
        first.categories.append(made)
        first.categoriesEdited(delay: .milliseconds(10))
        await first.baselineTask?.value
        #expect(first.baselinePending)
        first.flushSave()

        let second = Store()
        second.stateFile = file
        second.load()
        second.persists = false
        second.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        let performer = FakePerformer()
        second.actionPerformer = performer
        second.gh.session = session
        // Relaunched: the repo still isn't read, so nothing is taken in yet.
        await second.runActions()
        #expect(second.baselinePending)
        // The refresh that reads it brings its open PR: there already, it is taken in, not acted on.
        await second.syncInbox()
        await second.runActions()
        #expect(second.things["pr:o/new#1"] != nil && !second.baselinePending)
        #expect(performer.comments.isEmpty)
        box.shown = [1, 2]
        await second.syncInbox()
        await second.runActions()
        #expect(performer.comments.map(\.number) == [2])
    }
}


/// CI as workflow things: each failing workflow is one entry and one notification, until it is green.
@MainActor
@Suite struct InboxWorkflowRefresh {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _failing: Set<Int> = [11, 12]
        var failing: Set<Int> {
            get { lock.withLock { _failing } }
            set { lock.withLock { _failing = newValue } }
        }
    }

    nonisolated private static func runs(_ failing: Set<Int>) -> String {
        let all = [(11, "CI"), (12, "Lint"), (13, "Docs")].map { id, name in
            """
            {"name":"\(name)","workflow_id":\(id),"head_sha":"s1","display_title":"Fix","status":"completed",\
            "conclusion":"\(failing.contains(id) ? "failure" : "success")","check_suite_id":\(id)}
            """
        }
        return #"{"workflow_runs":[\#(all.joined(separator: ","))]}"#
    }

    /// Every branch's head, the commit the runs are on.
    nonisolated private static let branch = #"{"commit":{"sha":"s1","commit":{"message":"Fix"}}}"#

    private func store(_ state: State, posted: @escaping (String) -> Void) -> (Store, UUID) {
        let s = Store()
        s.persists = false
        s.settings.triage = true
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            switch request.url?.path ?? "" {
            case "/repos/a/x": return .init(200, #"{"full_name":"a/x","default_branch":"main"}"#)
            case "/repos/a/x/branches/main", "/repos/a/x/branches/dev": return .init(200, Self.branch)
            case "/repos/a/x/actions/runs": return .init(200, Self.runs(state.failing))
            case "/repos/a/x/commits/s1/check-runs": return .init(200, #"{"total_count":0,"check_runs":[]}"#)
            case "/repos/a/x/commits/s1/status": return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#)
            // The repos of an owner a rule names with a wildcard.
            case "/graphql": return .init(200, #"{"data":{"o0":{"repositories":{"nodes":[{"nameWithOwner":"a/x"}]}}}}"#)
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        var ci = InboxStore.ci
        ci.rules = [Rule(scope: Scope(kinds: [.workflow], in: Pick(include: [.repo("a/x")])), conditions: [.workflow([.failing])],
                         createdAt: .distantPast)]
        s.categories = [ci]
        s.notifier.onPost = { posted($0.identifier) }
        return (s, ci.id)
    }

    @Test func everyFailingWorkflowIsAnEntryAndNotifiesOnceUntilItIsGreen() async {
        let state = State()
        var posted: [String] = []
        let (s, ci) = store(state) { posted.append($0) }
        await s.syncInbox()
        // One thing per workflow (the passing one too), the failing ones in CI; the first look is silent.
        #expect(s.things.keys.sorted() == ["workflow:a/x:11@main", "workflow:a/x:12@main", "workflow:a/x:13@main"])
        #expect(s.entries(in: ci).map(\.id).sorted() == ["workflow:a/x:11@main", "workflow:a/x:12@main"] && s.count(ci) == 2)
        #expect(posted.isEmpty)
        // Docs fails: a third entry and one notification, for that workflow alone.
        state.failing.insert(13)
        await s.syncInbox()
        #expect(s.count(ci) == 3 && posted == ["inbox:workflow:a/x:13@main"])
        await s.syncInbox()
        #expect(posted.count == 1)
        // Lint goes green and fails again: that failure is new.
        state.failing.remove(12)
        await s.syncInbox()
        #expect(s.count(ci) == 2)
        state.failing.insert(12)
        await s.syncInbox()
        #expect(s.count(ci) == 3 && posted == ["inbox:workflow:a/x:13@main", "inbox:workflow:a/x:12@main"])
    }

    @Test func spentPointsHoldTheSearchesButTheWorkflowsStillRefresh() async {
        final class Count: @unchecked Sendable { var searches = 0 }
        let state = State(), count = Count()
        let (s, ci) = store(state) { _ in }
        s.gh.session = StubbedGitHub.session { request in
            switch request.url?.path ?? "" {
            case "/repos/a/x": return .init(200, #"{"full_name":"a/x","default_branch":"main"}"#)
            case "/repos/a/x/branches/main", "/repos/a/x/branches/dev": return .init(200, Self.branch)
            case "/repos/a/x/actions/runs": return .init(200, Self.runs(state.failing))
            case "/repos/a/x/commits/s1/check-runs": return .init(200, #"{"total_count":0,"check_runs":[]}"#)
            case "/repos/a/x/commits/s1/status": return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#)
            case "/graphql":
                count.searches += 1
                let reply: [String: Any] = ["data": ["rateLimit": ["cost": 3, "remaining": 50, "resetAt": "2030-01-01T00:00:00Z"],
                                                      "s0": ["pageInfo": ["hasNextPage": false], "nodes": [node()]]]]
                return .init(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        s.categories.append(InboxCategory(name: "Mine", symbol: "star", color: .blue,
                                          rules: [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])))]))
        await s.syncInbox()
        #expect(count.searches == 1 && s.things["pr:o/r#12"] != nil && s.count(ci) == 2)
        // The points are nearly spent: no search until they come back, the PR stays, and the CI still says what failed.
        state.failing.insert(13)
        await s.syncInbox()
        #expect(count.searches == 1 && s.things["pr:o/r#12"] != nil && s.count(ci) == 3)
    }

    @Test func whatARefreshIsAnsweredAfterAnotherAccountSignsInIsntTakenSaidOrWaitedOn() async {
        final class Ref: @unchecked Sendable { var store: Store?; var switches = false }
        let ref = Ref()
        let (s, ci) = store(State()) { _ in }
        ref.store = s
        // Another account signs in while GitHub answers (as Categories' suggestions may).
        nonisolated func switched() {
            guard ref.switches else { return }
            ref.switches = false
            DispatchQueue.main.sync { MainActor.assumeIsolated { ref.store?.me = GHUser(login: "someone", avatarUrl: nil, type: "User") } }
        }
        s.gh.session = StubbedGitHub.session { request in
            let path = request.url?.path ?? ""
            if path == "/graphql" {
                switched()
                if InboxSyncRefresh.body(request).contains("organizations") { return .init(502, #"{"message":"Server Error"}"#) }
                let reply: [String: Any] = ["data": ["s0": ["pageInfo": ["hasNextPage": false], "nodes": [node()]]]]
                return .init(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
            }
            if path.hasPrefix("/repos/a/x/branches/") { return .init(200, Self.branch) }
            if path == "/repos/a/x/actions/runs" { switched(); return .init(200, Self.runs([11])) }
            if path.hasSuffix("/check-runs") { return .init(200, #"{"total_count":0,"check_runs":[]}"#) }
            if path.hasSuffix("/status") { return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#) }
            return .init(404, #"{"message":"unrouted"}"#)
        }
        func signIn() { s.me = GHUser(login: "me", avatarUrl: nil, type: "User"); ref.switches = true }
        // The searches' answer.
        s.categories = [InboxCategory(name: "Mine", symbol: "star", color: .blue, rules: [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])))])]
        signIn()
        await s.syncInbox()
        #expect(s.things.isEmpty && s.marks.isEmpty && s.categoryBaselines.isEmpty)
        #expect(s.inboxSyncState.foundBy.isEmpty && s.inboxSyncState.searchCursor == 0 && s.inboxError == nil)
        // A workflow's.
        var workflows = InboxStore.ci
        workflows.rules = [Rule(scope: Scope(kinds: [.workflow], in: Pick(include: [.repo("a/x")]), on: ["main"]),
                                conditions: [.workflow([.failing])], createdAt: .distantPast)]
        s.categories = [workflows]
        signIn()
        await s.syncInbox()
        #expect(s.things.isEmpty && s.count(ci) == 0 && s.categoryBaselines.isEmpty)
        // The teams' failure: the new account's teams aren't held back by it.
        s.categories = [InboxCategory(name: "Team", symbol: "eye", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], to: Pick(include: [.myTeams]), toRoles: [.reviewRequested])),
        ])]
        signIn()
        await s.syncInbox()
        #expect(s.inboxSyncState.teamsFailedAt == nil && s.inboxError == nil)
    }

    @Test func workflowTargetsTakingTurnsAreAnsweredUnchangedOnceEachHadItsTurn() async {
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func add() { lock.withLock { n += 1 } }
            var value: Int { lock.withLock { n } }
        }
        let full = Count()
        let (s, _) = store(State()) { _ in }
        s.gh.session = StubbedGitHub.session { request in
            let path = request.url?.path ?? ""
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 4, parts[0] == "repos" else { return .init(404, #"{"message":"unrouted"}"#) }
            let etag = "\"\(path)\""
            if request.value(forHTTPHeaderField: "If-None-Match") == etag { return .init(304, headers: ["ETag": etag]) }
            full.add()
            switch parts.dropFirst(3).joined(separator: "/") {
            case "branches/main": return .init(200, Self.branch, headers: ["ETag": etag])
            case "actions/runs": return .init(200, Self.runs([11]), headers: ["ETag": etag])
            case "commits/s1/check-runs": return .init(200, #"{"total_count":0,"check_runs":[]}"#, headers: ["ETag": etag])
            case "commits/s1/status":
                return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#, headers: ["ETag": etag])
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        // Many more repos than a refresh checks: each refresh asks a window of them, in turn.
        let repos = (0..<100).map { "a/x\($0)" }
        s.categories[0].rules[0].scope = Scope(kinds: [.workflow], in: Pick(include: repos.map { .repo($0) }), on: ["main"])
        for _ in 0..<4 { await s.syncInbox() }
        #expect(full.value == repos.count * 4)
        // Once every repo had its turn, nothing changed: every answer is a 304, the ones of repos asked a turn ago included.
        for _ in 0..<4 { await s.syncInbox() }
        #expect(full.value == repos.count * 4)
    }

    @Test func pastTheCapTheWorkflowTargetsTakeTurnsAndThoseWaitingKeepTheirThings() async {
        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var _repos: Set<String> = []
            var repos: Set<String> {
                get { lock.withLock { _repos } }
                set { lock.withLock { _repos = newValue } }
            }
        }
        let asked = Asked()
        let (s, ci) = store(State()) { _ in }
        s.gh.session = StubbedGitHub.session { request in
            let parts = (request.url?.path ?? "").split(separator: "/").map(String.init)
            guard parts.count >= 4, parts[0] == "repos" else { return .init(404, #"{"message":"unrouted"}"#) }
            switch parts.dropFirst(3).joined(separator: "/") {
            case "branches/main": return .init(200, Self.branch)
            case "actions/runs":
                asked.repos.insert(parts[2])
                return .init(200, Self.runs([11]))
            case "commits/s1/check-runs": return .init(200, #"{"total_count":0,"check_runs":[]}"#)
            case "commits/s1/status": return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#)
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        // One repo more than a refresh checks.
        let repos = (0...InboxSync.maxWorkflows).map { "a/x\($0)" }
        s.categories[0].rules[0].scope = Scope(kinds: [.workflow], in: Pick(include: repos.map { .repo($0) }), on: ["main"])
        await s.syncInbox()
        #expect(asked.repos.count == InboxSync.maxWorkflows && !asked.repos.contains("x30") && s.count(ci) == InboxSync.maxWorkflows)
        // The last one gets its turn; the one left out this time keeps its things.
        asked.repos = []
        await s.syncInbox()
        #expect(asked.repos.contains("x30") && !asked.repos.contains("x29"))
        #expect(s.count(ci) == repos.count && s.things["workflow:a/x29:11@main"] != nil)
    }

    @Test func aFailedSearchKeepsThePullRequestsAndTheWorkflowsStillRefresh() async {
        final class Phase: @unchecked Sendable { var fails = false }
        let state = State(), phase = Phase()
        let (s, ci) = store(state) { _ in }
        s.gh.session = StubbedGitHub.session { request in
            switch request.url?.path ?? "" {
            case "/repos/a/x": return .init(200, #"{"full_name":"a/x","default_branch":"main"}"#)
            case "/repos/a/x/branches/main", "/repos/a/x/branches/dev": return .init(200, Self.branch)
            case "/repos/a/x/actions/runs": return .init(200, Self.runs(state.failing))
            case "/repos/a/x/commits/s1/check-runs": return .init(200, #"{"total_count":0,"check_runs":[]}"#)
            case "/repos/a/x/commits/s1/status": return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#)
            case "/graphql":
                if phase.fails { return .init(502, #"{"message":"Server Error"}"#) }
                let reply: [String: Any] = ["data": ["s0": ["pageInfo": ["hasNextPage": false], "nodes": [node()]]]]
                return .init(200, String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        s.categories.append(InboxCategory(name: "Mine", symbol: "star", color: .blue,
                                          rules: [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])))]))
        await s.syncInbox()
        #expect(s.things["pr:o/r#12"] != nil && s.count(ci) == 2)
        // The search fails: the PR stays, it is said, and the CI read with REST still says what failed.
        phase.fails = true
        state.failing.insert(13)
        await s.syncInbox()
        #expect(s.things["pr:o/r#12"] != nil && s.count(ci) == 3 && s.inboxError != nil)
    }

    @Test func aRuleThatNamesNoBranchTakesOnlyTheDefaultBranchsRuns() async {
        let (s, ci) = store(State()) { _ in }
        // Another category watches dev: its failures are fetched too, and are not the default branch's.
        let dev = InboxCategory(name: "Dev", symbol: "star", color: .blue,
                                rules: [Rule(scope: Scope(kinds: [.workflow], in: Pick(include: [.repo("a/x")]), on: ["dev"]),
                                             conditions: [.workflow([.failing])], createdAt: .distantPast)])
        s.categories.append(dev)
        await s.syncInbox()
        #expect(s.things["workflow:a/x:11@dev"]?.defaultBranch == "main")
        #expect(s.entries(in: ci).map(\.id).sorted() == ["workflow:a/x:11@main", "workflow:a/x:12@main"])
        #expect(s.entries(in: dev.id).map(\.id).sorted() == ["workflow:a/x:11@dev", "workflow:a/x:12@dev"])
    }

    @Test func anOwnerWhoseReposCouldntBeLookedUpKeepsItsWorkflowsAndSaysSo() async {
        final class Phase: @unchecked Sendable { var fails = true }
        let state = State(), phase = Phase()
        let (s, ci) = store(state) { _ in }
        s.gh.session = StubbedGitHub.session { request in
            switch request.url?.path ?? "" {
            case "/repos/a/x": return .init(200, #"{"full_name":"a/x","default_branch":"main"}"#)
            case "/repos/a/x/branches/main", "/repos/a/x/branches/dev": return .init(200, Self.branch)
            case "/repos/a/x/actions/runs": return .init(200, Self.runs(state.failing))
            case "/repos/a/x/commits/s1/check-runs": return .init(200, #"{"total_count":0,"check_runs":[]}"#)
            case "/repos/a/x/commits/s1/status": return .init(200, #"{"state":"success","total_count":0,"sha":"s1","statuses":[]}"#)
            case "/graphql":
                // Owner a's part fails; zz is no one GitHub knows.
                if phase.fails {
                    return .init(200, #"{"data":{"o0":null,"o1":null},"errors":[{"type":"FORBIDDEN","path":["o0"],"message":"Resource protected"}]}"#)
                }
                return .init(200, #"{"data":{"o0":{"repositories":{"nodes":[{"nameWithOwner":"a/x"}]}},"o1":null}}"#)
            default: return .init(404, #"{"message":"unrouted"}"#)
            }
        }
        s.categories[0].rules[0].scope = Scope(kinds: [.workflow], in: Pick(include: [.owner("A"), .owner("zz")]))
        // Kept from the last session: its owner's repos aren't known yet.
        var kept = InboxSync.workflowThings(repo: "a/x", branch: "main", status: CIStatus(branch: "main", checkedAt: Date(),
            workflows: [.init(id: "11", name: "CI", state: .failure, failing: ["build"])]))[0]
        kept.defaultBranch = "main"
        s.things = [kept.id: kept]
        await s.syncInbox()
        #expect(s.things.keys.sorted() == [kept.id] && s.entries(in: ci).map(\.id) == [kept.id])
        #expect(s.inboxSyncState.ownerRepos == ["zz": []] && s.inboxSyncState.ownerReposAt["a"] == nil)
        #expect(s.inboxError?.contains("Resource protected") == true)
        // Asked again at the next refresh, and now known.
        phase.fails = false
        await s.syncInbox()
        #expect(s.inboxSyncState.ownerRepos == ["a": ["a/x"], "zz": []] && s.inboxError == nil)
        #expect(s.entries(in: ci).map(\.id).sorted() == ["workflow:a/x:11@main", "workflow:a/x:12@main"])
    }

    @Test func anOwnersWildcardIsItsReposAndEmptySlotsAreTheirDefaults() async {
        let (s, ci) = store(State()) { _ in }
        // `on` and `named` added and left empty: the default branch, every workflow.
        s.categories[0].rules[0].scope = Scope(kinds: [.workflow], in: Pick(include: [.owner("A")]), on: [], named: [" "])
        await s.syncInbox()
        #expect(s.inboxSyncState.ownerRepos == ["a": ["a/x"]])
        #expect(s.entries(in: ci).map(\.id).sorted() == ["workflow:a/x:11@main", "workflow:a/x:12@main"])
    }

    @Test func aRuleCanNameTheWorkflowsItWants() async {
        let state = State()
        let (s, _) = store(state) { _ in }
        s.categories[0].rules[0].scope.named = ["lint"]
        await s.syncInbox()
        #expect(s.entries.map(\.id) == ["workflow:a/x:12@main"])
    }
}


@Suite struct InboxSyncRequestsAndTeams {
    private func rule(_ scope: Scope) -> InboxCategory {
        InboxCategory(name: "T", symbol: "eye", color: .blue, rules: [Rule(scope: scope)])
    }

    private func searches(_ categories: [InboxCategory]) -> [String] {
        InboxSync.searches(categories: categories, groups: [], me: "me", contributed: [])
    }

    // MARK: Review requests, behind base, teams, contributed

    @Test func reviewRequestsKeepWhenEachWasMadeAndTheLatestOfARepeatedOneWins() throws {
        let t = try #require(InboxSync.thing(node()))
        let at = Dictionary(uniqueKeysWithValues: t.reviewRequests.map { ($0.reviewer, $0.at) })
        #expect(at["bob"] == iso("2026-10-04T10:00:00Z"))
        #expect(at["org/core"] == iso("2026-10-03T10:00:00Z"))
        // Requests no longer pending (gone) aren't kept.
        #expect(at["gone"] == nil && t.reviewRequests.count == 2)
    }

    @Test func everyPendingRequestIsAskedForAndOneStillPendingKeepsWhenItWasMade() throws {
        #expect(InboxSync.fragments.contains("reviewRequests(first: 100)"))
        let old = try #require(InboxSync.thing(node()))
        // Later requests pushed bob's event out of the ones fetched: he is still asked, since the same time.
        let later = (0..<50).map { ["createdAt": "2026-10-05T10:00:00Z", "requestedReviewer": ["login": "r\($0)"]] as [String: Any] }
        let fetched = try #require(InboxSync.thing(node(["requestEvents": ["nodes": later]])))
        #expect(fetched.reviewRequests.isEmpty)
        let kept = InboxSync.keepingRequestTimes(fetched, from: old)
        #expect(kept.reviewRequests.first { $0.reviewer == "bob" }?.at == iso("2026-10-04T10:00:00Z"))
        // An event fetched is the truth: asked again later is a new request.
        let again = try #require(InboxSync.thing(node(["requestEvents": ["nodes": [
            ["createdAt": "2026-10-09T10:00:00Z", "requestedReviewer": ["login": "bob"]]]]])))
        #expect(InboxSync.keepingRequestTimes(again, from: old).reviewRequests.first { $0.reviewer == "bob" }?.at == iso("2026-10-09T10:00:00Z"))
        // No longer pending before: nothing to keep.
        var gone = old
        gone.requestedReviewers = []
        #expect(InboxSync.keepingRequestTimes(fetched, from: gone).reviewRequests.isEmpty)
    }

    @Test func anAssignmentIsRatedByWhenItWasMadeSoAssignedAgainIsNew() throws {
        #expect(InboxSync.fragments.contains("ASSIGNED_EVENT") && InboxSync.fragments.contains("assignees(first: 10)"))
        let events: [[String: Any]] = [
            ["createdAt": "2026-10-02T10:00:00Z", "assignee": ["login": "Me"]],
            ["createdAt": "2026-10-03T10:00:00Z", "assignee": ["login": "gone"]],
        ]
        let first = try #require(InboxSync.thing(node(["assignees": ["nodes": [["login": "Me"]]], "reviewRequests": ["nodes": []],
                                                        "assignEvents": ["nodes": events]])))
        #expect(first.assignedAt == ["me": try #require(iso("2026-10-02T10:00:00Z"))])
        let context = InboxContext(me: "me")
        let stamp = InboxEngine.importanceStamp(first, context: context)
        #expect(stamp == "assigned:\(Int(try #require(iso("2026-10-02T10:00:00Z")).timeIntervalSince1970))")
        // Taken off and assigned again: another stamp, so Jev's rating of the first doesn't count for it.
        let again = try #require(InboxSync.thing(node(["assignees": ["nodes": [["login": "Me"]]], "reviewRequests": ["nodes": []],
                                                        "assignEvents": ["nodes": [["createdAt": "2026-10-08T10:00:00Z",
                                                                                     "assignee": ["login": "Me"]]]]])))
        #expect(InboxEngine.importanceStamp(again, context: context) != stamp)
        // Still assigned, its event past the ones fetched: the time is kept.
        let later = try #require(InboxSync.thing(node(["assignees": ["nodes": [["login": "Me"]]], "reviewRequests": ["nodes": []]])))
        #expect(InboxEngine.importanceStamp(InboxSync.keepingRequestTimes(later, from: first), context: context) == stamp)
    }

    @Test func behindBaseAndTheHeadCommitAreRead() throws {
        let t = try #require(InboxSync.thing(node()))
        #expect(t.behindBase && t.headSha == "abc")
        #expect(try #require(InboxSync.thing(node(["mergeStateStatus": "CLEAN"]))).behindBase == false)
    }

    @Test func teamsInToBecomeTeamReviewRequestedQueries() {
        let mixed = searches([rule(Scope(kinds: [.pr], to: Pick(include: [.me, .team("@acme/core")]), toRoles: [.reviewRequested]))])
        #expect(mixed.count == 2)
        #expect(mixed.contains { $0.contains("review-requested:me") } && mixed.contains { $0.contains("team-review-requested:acme/core") })
        let mine = InboxSync.searches(categories: [rule(Scope(kinds: [.pr], to: Pick(include: [.myTeams]), toRoles: [.reviewRequested]))],
                                      groups: [], me: "me", contributed: [], myTeams: ["a/x", "a/y"])
        #expect(mine.count == 2 && mine.allSatisfy { $0.contains("team-review-requested:a/") })
        // Not resolved yet (or in none): nothing to search, rather than every PR on GitHub.
        #expect(searches([rule(Scope(kinds: [.pr], to: Pick(include: [.myTeams]), toRoles: [.reviewRequested]))]).isEmpty)
        // Teams only count for review requests.
        #expect(searches([rule(Scope(kinds: [.pr], to: Pick(include: [.team("a/x")]), toRoles: [.assigned]))]).isEmpty)
    }

    @Test @MainActor func teamsAreResolvedWhenJevRatesReviewRequestsEvenWithNoRuleNamingThem() async {
        let none = [InboxCategory(name: "Mine", symbol: "star", color: .blue,
                                  rules: [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])))])]
        #expect(!InboxSync.needsTeams(categories: none, jevReads: false))
        #expect(InboxSync.needsTeams(categories: none, jevReads: true))
        // Left out is named too: "to me except My teams" needs them known to leave them out.
        let except = [InboxCategory(name: "Mine", symbol: "star", color: .blue,
                                    rules: [Rule(scope: Scope(kinds: [.pr], to: Pick(include: [.me], except: [.myTeams]),
                                                              toRoles: [.reviewRequested]))])]
        #expect(InboxSync.needsTeams(categories: except, jevReads: false))
        let s = Store()
        s.persists = false
        s.settings.triage = true
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.categories = none
        s.gh.session = StubbedGitHub.session { request in
            let data: [String: Any] = InboxSyncRefresh.body(request).contains("organizations")
                ? ["viewer": ["organizations": ["nodes": [["teams": ["nodes": [["combinedSlug": "acme/core"]]]]]]]]
                : ["rateLimit": ["cost": 1, "remaining": 4000], "s0": ["pageInfo": ["hasNextPage": false], "nodes": []]]
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        // Jev switched off: not asked.
        s.settings.jevReadsInbox = false
        s.inboxAsker = { _, _ in [:] }
        await s.syncInbox()
        #expect(s.myTeams.isEmpty)
        s.settings.jevReadsInbox = true
        await s.syncInbox()
        #expect(s.myTeams == ["acme/core"])
    }

    @Test @MainActor func aFailedTeamsLookupIsSaidKeepsTheThingsAndIsAskedAgainSoon() async throws {
        final class Box: @unchecked Sendable { var fails = true; var teamAsks = 0; var searches = 0 }
        let box = Box()
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.categories = [InboxCategory(name: "Team", symbol: "star", color: .blue, rules: [
            Rule(scope: Scope(kinds: [.pr], to: Pick(include: [.myTeams]), toRoles: [.reviewRequested]))])]
        s.settings.jevReadsInbox = false
        s.gh.session = StubbedGitHub.session { request in
            if InboxSyncRefresh.body(request).contains("organizations") {
                box.teamAsks += 1
                if box.fails { return StubbedGitHub.Reply(502, #"{"message":"Server Error"}"#) }
                let data = ["viewer": ["organizations": ["nodes": [["teams": ["nodes": [["combinedSlug": "acme/core"]]]]]]]]
                return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
            }
            box.searches += 1
            let data: [String: Any] = ["rateLimit": ["cost": 1, "remaining": 4000], "s0": ["pageInfo": ["hasNextPage": false], "nodes": [node()]]]
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        let kept = try #require(InboxSync.thing(node()))
        s.things = [kept.id: kept]
        await s.syncInbox()
        #expect(s.inboxError?.contains("teams") == true && s.things.keys.sorted() == [kept.id])
        #expect(s.teamsResolvedAt == nil && box.searches == 0)
        // Not asked again at every poll, and the things still stay.
        await s.syncInbox()
        #expect(box.teamAsks == 1 && s.things.keys.sorted() == [kept.id] && s.inboxError != nil)
        // A quarter of an hour later it is.
        s.inboxSyncState.teamsFailedAt = Date().addingTimeInterval(-InboxSync.teamsRetry - 1)
        box.fails = false
        await s.syncInbox()
        #expect(box.teamAsks == 2 && s.myTeams == ["acme/core"] && box.searches == 1 && s.inboxError == nil)
        #expect(s.inboxSyncState.teamsFailedAt == nil && s.teamsResolvedAt != nil)
    }

    @Test @MainActor func teamsGivenInPartAreAddedToWhatWasKnownAndAskedAgainSoon() async throws {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.myTeams = ["other/old"]
        s.gh.session = StubbedGitHub.session { _ in
            .init(200, #"{"data":{"viewer":{"organizations":{"nodes":[{"teams":{"nodes":[{"combinedSlug":"acme/core"}]}},{"teams":null}]}}},"errors":[{"type":"FORBIDDEN","path":["viewer","organizations","nodes",1,"teams"],"message":"SAML enforcement"}]}"#)
        }
        let failure = await s.resolveTeams(me: "me")
        #expect(failure == "SAML enforcement")
        #expect(s.myTeams == ["other/old", "acme/core"] && s.teamsResolvedAt == nil && s.inboxSyncState.teamsFailedAt != nil)
        // Without read:org, GitHub's answer of none is an answer.
        s.gh.session = StubbedGitHub.session { _ in
            .init(200, #"{"data":{"viewer":{"organizations":null}},"errors":[{"type":"INSUFFICIENT_SCOPES","message":"read:org"}]}"#)
        }
        #expect(await s.resolveTeams(me: "me") == nil)
        #expect(s.myTeams.isEmpty && s.teamsResolvedAt != nil)
    }

    @Test @MainActor func anotherAccountStartsWithoutTheLastOnesReposAndTeams() async throws {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.ownedRepos = ["me/own"]
        s.contributedRepos = ["o/merged"]
        s.myTeams = ["acme/core"]
        s.reposResolvedAt = Date()
        s.teamsResolvedAt = Date()
        s.inboxSyncState.ownerRepos = ["acme": ["acme/x"]]
        // The same account, however written: kept.
        s.me = GHUser(login: "Me", avatarUrl: nil, type: "User")
        #expect(s.contributedRepos == ["o/merged"] && s.myTeams == ["acme/core"])
        s.me = GHUser(login: "someone", avatarUrl: nil, type: "User")
        #expect(s.ownedRepos.isEmpty && s.contributedRepos.isEmpty && s.myTeams.isEmpty)
        #expect(s.reposResolvedAt == nil && s.teamsResolvedAt == nil && s.inboxSyncState.ownerRepos.isEmpty)
        // An answer asked for the last account, landing now, isn't taken.
        s.gh.session = StubbedGitHub.session { _ in
            let data = ["viewer": ["organizations": ["nodes": [["teams": ["nodes": [["combinedSlug": "acme/core"]]]]]]]]
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        await s.resolveTeams(me: "me")
        #expect(s.myTeams.isEmpty && s.teamsResolvedAt == nil)
        // Nor are an owner's repos asked for while the last account was signed in and landing after the switch.
        final class Ref: @unchecked Sendable { var store: Store?; var answered = false }
        let ref = Ref()
        ref.store = s
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { _ in
            DispatchQueue.main.sync { MainActor.assumeIsolated { ref.store?.me = GHUser(login: "someone", avatarUrl: nil, type: "User") } }
            ref.answered = true
            return .init(200, #"{"data":{"o0":{"repositories":{"nodes":[{"nameWithOwner":"acme/x"}]}}}}"#)
        }
        await s.resolveOwnerRepos(["acme"])
        #expect(ref.answered && s.inboxSyncState.ownerRepos.isEmpty && s.inboxSyncState.ownerReposAt.isEmpty)
    }

    @Test @MainActor func reposGivenInPartKeepWhatDidntComeAndAreAskedAgainAndSaid() async throws {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        let dayAgo = Date().addingTimeInterval(-2 * 86400)
        s.ownedRepos = ["me/own"]
        s.contributedRepos = ["o/old"]
        s.reposResolvedAt = dayAgo
        s.categories = [rule(Scope(kinds: [.pr], in: Pick(include: [.owned])))]
        s.gh.session = StubbedGitHub.session { request in
            if InboxSyncRefresh.body(request).contains("ownerAffiliations") {
                return .init(200, #"{"data":{"viewer":{"repositories":null},"merged":{"nodes":[{"repository":{"nameWithOwner":"o/new"}}]},"open":{"nodes":[]}},"errors":[{"path":["viewer","repositories"],"message":"Something went wrong"}]}"#)
            }
            return .init(200, #"{"data":{"s0":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}"#)
        }
        await s.syncInbox()
        // The owned repos that didn't come stay, the merged ones that did are taken, and it isn't a day's answer.
        #expect(s.ownedRepos == ["me/own"] && s.contributedRepos == ["o/old", "o/new"])
        #expect(s.reposResolvedAt == dayAgo && s.inboxError?.contains("Something went wrong") == true)
    }

    @Test @MainActor func reposLeftOutByARuleAreLookedUpToLeaveThemOut() async throws {
        let s = Store()
        s.persists = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.categories = [rule(Scope(kinds: [.pr], in: Pick(include: [.owner("acme")], except: [.contributed])))]
        s.gh.session = StubbedGitHub.session { request in
            if InboxSyncRefresh.body(request).contains("ownerAffiliations") {
                return .init(200, #"{"data":{"viewer":{"repositories":{"nodes":[]}},"merged":{"nodes":[{"repository":{"nameWithOwner":"acme/mine"}}]},"open":{"nodes":[]}}}"#)
            }
            return .init(200, #"{"data":{"s0":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}"#)
        }
        await s.syncInbox()
        // "acme/* except Repos I contribute to" knows which those are.
        #expect(s.contributedRepos == ["acme/mine"] && s.reposResolvedAt != nil)
    }

    @Test @MainActor func contributedReposAreMergedAndOpenPRsAndTeamsAreKept() async throws {
        let s = Store()
        s.persists = false
        s.gh.session = StubbedGitHub.session { request in
            let text = InboxSyncRefresh.body(request)
            let data: [String: Any]
            if text.contains("organizations") {
                data = ["viewer": ["organizations": ["nodes": [["teams": ["nodes": [["combinedSlug": "acme/core"]]]]]]]]
            } else {
                data = ["viewer": ["repositories": ["nodes": [["nameWithOwner": "me/own"]]]],
                        "merged": ["nodes": [["repository": ["nameWithOwner": "o/merged"]]]],
                        "open": ["nodes": [["repository": ["nameWithOwner": "o/open"]]]]]
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        try await s.resolveRepos(me: "me")
        #expect(s.ownedRepos == ["me/own"] && s.contributedRepos == ["o/merged", "o/open"])
        await s.resolveTeams(me: "me")
        #expect(s.myTeams == ["acme/core"])
        // The context hands both to the engine.
        #expect(s.inboxContext.myTeams == ["acme/core"] && s.inboxContext.contributedRepos.contains("o/open"))
    }
}

/// Past the caps, the list reads on as it is scrolled to its end: what comes stays, and is never announced.
@MainActor
@Suite(.serialized) struct InboxSyncLoadMore {
    final class Log: @unchecked Sendable {
        var searches: [(first: Int, after: Int)] = []
        var total = 100
        var remaining = 4000
    }

    /// A search with `log.total` PRs, `#1` newest, each with a Greptile score of 3; cursors are offsets (`c60`).
    private func store(_ log: Log) -> (Store, UUID) {
        let s = Store()
        s.persists = false
        s.settings.triage = true
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        s.gh.session = StubbedGitHub.session { request in
            let text = InboxSyncRefresh.body(request)
            let rate: [String: Any] = ["cost": 1, "remaining": log.remaining, "resetAt": "2030-01-01T00:00:00Z"]
            func number(after marker: String) -> Int? {
                guard let range = text.range(of: marker) else { return nil }
                return Int(text[range.upperBound...].prefix { $0.isNumber })
            }
            var data: [String: Any] = ["rateLimit": rate]
            if text.contains("s0: search") {
                let first = number(after: "first: ") ?? 0
                let after = number(after: "after: \\\"c") ?? 0
                log.searches.append((first, after))
                let end = min(log.total, after + first)
                let nodes = (after..<end).map { i in
                    node(["id": "PR_\(i + 1)", "number": i + 1, "url": "https://github.com/o/r/pull/\(i + 1)",
                          "updatedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 2_000_000_000 - Double(i) * 60))])
                }
                data["s0"] = ["pageInfo": ["hasNextPage": end < log.total, "endCursor": "c\(end)"], "nodes": nodes]
            } else {
                // Things kept unseen, looked at again: none answered, so none changed.
                data["nodes"] = []
            }
            return StubbedGitHub.Reply(200, String(decoding: try JSONSerialization.data(withJSONObject: ["data": data]), as: UTF8.self))
        }
        var category = InboxCategory(name: "Mine", symbol: "star", color: .blue)
        category.rules = [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me])), conditions: [.greptileBelow(5)])]
        s.categories = [category]
        return (s, category.id)
    }

    private func loadMore(_ s: Store) async {
        s.loadMoreInbox()
        await s.inboxSyncState.loadingMore?.value
    }

    @Test func theListReadsOnPastTheCapsKeepsWhatItReadAndAnnouncesNothing() async {
        let log = Log()
        var posted: [String] = []
        let (s, category) = store(log)
        s.notifier.onPost = { posted.append($0.identifier) }
        await s.syncInbox()
        // The refresh stops at its caps: three pages of twenty.
        #expect(s.things.count == 60 && log.searches.map(\.after) == [0, 20, 40])
        #expect(s.inboxSyncState.more.values.map(\.read) == [60])
        // A second refresh, past the baseline: what is there is old.
        await s.syncInbox()
        log.searches = []
        await loadMore(s)
        #expect(log.searches.map(\.after) == [60] && log.searches[0].first == InboxSync.pageSize)
        #expect(s.things.count == 80 && s.entries(in: category).count == 80)
        #expect(posted.isEmpty)
        #expect(s.marks["pr:o/r#70"]?.notified == ["greptile:3"])
        // The next refresh reads its sixty again: the twenty past them stay, and nothing is announced.
        log.searches = []
        await s.syncInbox()
        #expect(log.searches.map(\.after) == [0, 20, 40])
        #expect(s.things.count == 80 && posted.isEmpty)
        // Reading on goes from where the list was read to, not where the refresh stopped, until GitHub has no more.
        log.searches = []
        await loadMore(s)
        #expect(log.searches.map(\.after) == [80] && s.things.count == 100)
        #expect(s.inboxSyncState.more.isEmpty)
        await loadMore(s)
        #expect(log.searches.count == 1)
        await s.syncInbox()
        #expect(s.things.count == 100 && posted.isEmpty)
    }

    @Test func noReadingOnWithPointsLowNorDuringARefresh() async {
        let log = Log()
        let (s, _) = store(log)
        await s.syncInbox()
        log.searches = []
        log.remaining = InboxSync.tailPoints - 1
        // The answer said the points are low: the list's end reads nothing.
        await s.syncInbox()
        log.searches = []
        await loadMore(s)
        #expect(log.searches.isEmpty && s.things.count == 60)
        log.remaining = 4000
        await s.syncInbox()
        log.searches = []
        // Reached during a refresh: read on once it is done.
        s.inboxSyncState.refreshing = 1
        s.loadMoreInbox()
        #expect(s.inboxSyncState.loadingMore == nil && s.inboxSyncState.loadMoreAfterRefresh)
        s.inboxSyncState.refreshing = 0
        await s.syncInbox()
        await s.inboxSyncState.loadingMore?.value
        #expect(log.searches.map(\.after) == [0, 20, 40, 60] && s.things.count == 80)
    }

    @Test func onlyOneOfTheLastRowsReadsOn() async {
        let log = Log()
        let (s, category) = store(log)
        await s.syncInbox()
        log.searches = []
        let rows = s.entries(in: category)
        s.rowAppeared(rows[0].id, in: rows)
        #expect(s.inboxSyncState.loadingMore == nil)
        s.rowAppeared(rows[rows.count - 3].id, in: rows)
        await s.inboxSyncState.loadingMore?.value
        #expect(log.searches.map(\.after) == [60])
    }

    @Test func whereSearchesStandAfterARefreshAndAfterReadingOn() {
        typealias M = InboxSync.SearchMore
        let stored = ["a": M(cursor: "c120", read: 120), "b": M(cursor: "c60", read: 60), "c": M(cursor: "c60", read: 60),
                      "gone": M(cursor: "c60", read: 60), "notRun": M(cursor: "c80", read: 80)]
        let fetched = ["a": M(cursor: "c60", read: 60), "b": M(cursor: "c60", read: 60), "new": M(cursor: "c60", read: 60)]
        let refreshed = InboxSync.refreshedMore(stored, fetched: fetched, ran: ["a", "b", "c", "new"], complete: ["c"],
                                                all: ["a", "b", "c", "new", "notRun"])
        // Read further already: stays further. Read whole: no more. No longer asked: gone. Not run: where it was.
        #expect(refreshed == ["a": M(cursor: "c120", read: 120), "b": M(cursor: "c60", read: 60),
                              "new": M(cursor: "c60", read: 60), "notRun": M(cursor: "c80", read: 80)])
        let advanced = InboxSync.advancedMore(refreshed, asked: ["a", "b", "new"], fetched: ["a": M(cursor: "c140", read: 20)],
                                              complete: ["b"], failed: ["new"])
        #expect(advanced == ["a": M(cursor: "c140", read: 140), "new": M(cursor: "c60", read: 60), "notRun": M(cursor: "c80", read: 80)])
    }

    @Test func entriesReadOnAreOldForTheActions() {
        var category = InboxFixture.category()
        let action = CategoryAction.make(.askRouter(prompt: "Look"))
        category.actions = ActionList([action])
        let entries = InboxEngine.evaluate(things: [InboxFixture.pr(1)], categories: [category], marks: [:],
                                           context: InboxFixture.store([]).inboxContext)
        #expect(!entries.isEmpty)
        var ledger = ActionLedger()
        InboxActions.takeAsOld(entries, categories: [category], ledger: &ledger)
        #expect(!ledger.runs.isEmpty && ledger.runs.values.allSatisfy { $0.state == .baselined })
        #expect(ledger.run(category.id, entries[0].id, action.id, "enter") != nil)
        var held = ActionLedger()
        InboxActions.takeAsOld(entries, categories: [category], ledger: &held, held: { _ in true })
        #expect(held.runs.isEmpty)
    }
}
