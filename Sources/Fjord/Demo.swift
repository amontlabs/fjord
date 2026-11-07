import AppKit
import Foundation
import SwiftUI

/// `--demo [scenario]`: fake data for trying the UI without touching GitHub or the saved state.
@MainActor
enum Demo {
    /// `busy` to `agents` are the plain `--demo` sets. The rest are the states that empty a list or break the sync, each on
    /// top of the `agents` data (the bar with everything on it) unless noted, so a shot shows the state in a realistic bar.
    enum Scenario: String, CaseIterable {
        case busy, botsOnly, allClear, snoozed, error, empty, agents
        // Inbox and sync causes.
        case signedOut, inboxFailed, rateLimited, contributionsEmpty, botChatterEmpty, doneEmpty, firstSync, syncFault
        // An inbox longer than any list shows; a category hidden; Jev's own category on top.
        case inboxMany, hiddenCategory, jev, sections
        // CI.
        case noCI, allPassing, manyCI, ciRunning
        // The update tile.
        case updateAvailable, updateDownloading, updateReady
        // The Router: the brief over its demo projects, local forms the hook holds and a decision log; and the Router off.
        case router, routerOff
    }

    static func populate(_ store: Store, _ scenario: Scenario = .busy) {
        store.persists = false
        // Both tools, picked: the demo shows everything.
        store.settings.triage = true
        store.settings.toolsPicked = true
        let now = Date()
        store.me = GHUser(login: "0xpolarzero", avatarUrl: URL(string: "https://avatars.githubusercontent.com/u/0?v=4"), type: "User")
        store.tokenSource = .ghCLI
        store.lastSync = now.addingTimeInterval(-20)
        store.rateRemaining = 4812
        inbox(store, now)
        store.snippets = Snippet.demo

        switch scenario {
        case .busy:
            break
        case .botsOnly:
            nothingForYou(store)
            empty(store, category: "Contributions")
            empty(store, category: "Reviews for you")
            passing(store)
        case .allClear:
            for entry in store.entries where !entry.isDone { store.things[entry.id] = nil }
            passing(store)
        case .snoozed:
            store.settings.snoozeUntil = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: now)
                .map { $0 > now ? $0 : now.addingTimeInterval(3600) }
        case .error:
            store.rateRemaining = 312
            let ci = "workflow:amontlabs/fjord:\(ciWorkflowID)@main"
            store.things[ci]?.checks = .failing
            store.things[ci]?.failingJobs = ["test (macos-15)"]
            store.things[ci]?.title = "Drag the pill from anywhere"
        case .agents:
            agents(store, now)
        case .empty:
            store.things = [:]
        case .signedOut:
            agents(store, now)
            store.me = nil
            store.tokenSource = nil
            store.lastSync = nil
            store.rateRemaining = nil
            store.authError = "No GitHub token found"
        case .inboxFailed:
            agents(store, now)
            store.inboxError = "Something went wrong with GitHub's search (HTTP 502)"
        case .rateLimited:
            agents(store, now)
            store.rateRemaining = 0
        case .contributionsEmpty:
            // Nothing on your PRs, CI healthy, the other categories still unread: all caught up here.
            agents(store, now)
            nothingForYou(store)
            empty(store, category: "Contributions")
            passing(store)
        case .botChatterEmpty:
            agents(store, now)
            empty(store, category: "Bot chatter")
        case .doneEmpty:
            agents(store, now)
            store.marks = [:]
        case .jev:
            agents(store, now)
            // What asks you, and the review requests Jev rates high, before the rest.
            store.categories.insert(InboxCategory(id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, name: "Asks me",
                symbol: "exclamationmark.bubble", color: .clay,
                rules: [Rule(scope: Scope(kinds: [.pr, .issue], in: Pick(include: [.involved])), match: .any,
                             conditions: [.commentLabel([.asks, .todo]), .importance(.high)], createdAt: now.addingTimeInterval(-60 * 86400))]), at: 0)
        case .sections:
            // Two sections: GitHub's, and CI (its failures) in a section of its own, folded.
            agents(store, now)
            let builds = store.createSection(name: "Builds")
            for c in store.categories where c.isCI { store.moveCategory(c.id, toSection: builds.id) }
            // Folded: its icon alone, CI's failures on it.
            store.toggleCollapsed(builds.id)
        case .hiddenCategory:
            // Bot chatter hidden: collecting, with no icon in the bar and no tab.
            agents(store, now)
            if let id = store.categories.first(where: { $0.name == "Bot chatter" })?.id { store.setHidden(id, true) }
        case .firstSync:
            agents(store, now)
            store.lastSync = nil
            store.isSyncing = true
            store.things = [:]
            store.rateRemaining = nil
        case .syncFault:
            // Several poll intervals old: the sync status reads "Not syncing".
            agents(store, now)
            store.lastSync = now.addingTimeInterval(-3600)
        case .inboxMany:
            agents(store, now)
            let titles = ["Cache the avatar lookups", "Dark mode for the Settings window", "Snooze until Monday", "Open the right repo on click",
                          "Hide read items after a day", "Keyboard shortcut for Mark all read", "Tab order in the footer", "Menu bar icon option",
                          "Group by repository", "Notifications repeat after wake", "Sort the archive by repository", "Search inside snippets"]
            let me = person("0xpolarzero")
            for (index, title) in titles.enumerated() {
                let n = 30 + index
                let reviewer = person(["kylef", "mattt", "allevato"][index % 3])
                let thing = Thing(id: "pr:amontlabs/fjord#\(n)", kind: .pr, repo: "amontlabs/fjord", number: n, title: title,
                                  url: URL(string: "https://github.com/amontlabs/fjord/pull/\(n)")!, author: me,
                                  createdAt: now.addingTimeInterval(-86400),
                                  updatedAt: now.addingTimeInterval(-Double(130 + index * 40) * 60),
                                  comments: [ThingComment(id: "many-\(n)", author: reviewer, at: now.addingTimeInterval(-Double(130 + index * 40) * 60),
                                                          snippet: "Looks good, one nit.")],
                                  checks: .passing, greptileScore: 3 + index % 3)
                store.things[thing.id] = thing
            }
        case .noCI:
            agents(store, now)
            store.things = store.things.filter { $0.value.kind != .workflow }
        case .allPassing:
            agents(store, now)
            passing(store)
        case .manyCI:
            agents(store, now)
            manyCI(store, now)
        case .ciRunning:
            // Nothing failing: what was running stays running.
            agents(store, now)
            for key in store.things.keys where store.things[key]?.checks == .failing && store.things[key]?.kind == .workflow {
                store.things[key]?.checks = .pending
            }
        case .updateAvailable:
            agents(store, now)
            store.updater.preview(.available, version: "0.5.0")
        case .updateDownloading:
            agents(store, now)
            store.updater.preview(.downloading, version: "0.5.0", fraction: 0.42)
        case .updateReady:
            agents(store, now)
            store.updater.preview(.ready, version: "0.5.0")
        case .router:
            agents(store, now)
            router(store, now)
            briefs(store, now: now)
        case .routerOff:
            agents(store, now)
        }
    }

    /// The Router on, over the `agents` sessions: the one that asks is stopped on its question and the Linux sandbox on its
    /// plan (requests T3 holds), with the decision log of what you said and what the Router did.
    private static func router(_ store: Store, _ now: Date) {
        let lcu = blockedAgentID
        store.threadWork[lcu] = ThreadWork(text: "Should updates install silently, or ask first each time?",
                                           since: now.addingTimeInterval(-120))
        let question = "Should updates install silently, or ask first each time?"
        store.requests[lcu] = ThreadRequest(
            id: "demo-request-\(lcu)", threadID: lcu,
            body: .question([T3Question(demo: "Updates", question, options: [
                ("Install silently", "Download and install in the background"),
                ("Ask first", "Show a prompt before each update"),
            ])]))
        // The Linux sandbox's plan, held the same way: its entry shows it, to approve or send back.
        store.requests["local_demo-linux"] = ThreadRequest(id: "demo-plan-linux", threadID: "local_demo-linux", body: .plan(markdown: """
            # Run the JavaScript sandbox in a Firecracker microVM on Linux

            1. Add a `firecracker` backend next to the macOS one, behind the same `Sandbox` protocol.
            2. Boot a minimal kernel and rootfs with the JS runtime baked in; talk to it over vsock.
            3. Run the existing sandbox tests against both backends in CI (Linux runner with KVM).
            """))
        // A permission, asked by a thread that is mid-run: its buttons are T3's decisions.
        store.requests["local_demo-ci"] = ThreadRequest(
            id: "demo-permission-ci", threadID: "local_demo-ci",
            body: .approval(kind: "command", prompt: "git push --force-with-lease origin fix/flaky-sandbox-test",
                            decisions: ThreadRequest.fallbackDecisions))
        var state = RouterSaved()
        state.enabled = true
        state.enabledAt = now.addingTimeInterval(-86400)
        state.changes = fjordChanges(store, now)
        // The decision log behind the same story: what you said and what the Router did with it.
        func entry(_ minutes: Double, _ trigger: RouterDecision.Trigger, _ intent: String, _ done: [RouterDecision.Done],
                   outcome: RouterDecision.Outcome = .done) -> RouterDecision {
            var d = RouterDecision(at: now.addingTimeInterval(-minutes * 60), trigger: trigger, decision: .init(intent: intent), outcome: outcome)
            for item in done {
                switch item {
                case .changed: d.add(item)
                default: d.add(item)
                }
            }
            return d
        }
        let changes = state.changes
        var sentToThread = entry(3.3, .you("remove the old remote"), "message",
                                 [.sent(to: "microsandbox · Repository ownership transfer setup", text: "remove the old remote", original: nil)])
        sentToThread.decision.targetID = RouteTarget.thread("local_demo-transfer").targetID
        sentToThread.decision.target = "thread “Repository ownership transfer setup” in microsandbox"
        sentToThread.decision.decider = "jev"
        var asked = entry(5, .you("what needs me?"), "question", [])
        asked.reply = "**3 need you**: *LCU update notifications* asks how updates install; the Linux sandbox has a plan to approve; "
            + "*Calculator display reading* is stuck on the VPN.\nDone: CI failure diagnosis."
        asked.note = "answered"
        var undelivered = entry(0.2, .you("rebase the games branch on main"), "reply",
                                [.failed("That thread isn't in T3 anymore: nothing was sent")])
        undelivered.decision.targetID = RouteTarget.newThread(project: "demo-project-microsandbox").targetID
        undelivered.decision.decider = "sonnet"
        // A category's "Then" sent its prompt with the thing tagged; the Router started a thread for it.
        let pill = "@ziglang/zig#1"
        let prompt = "Address what \(pill) is waiting on."
        var sentByThen = entry(0.3, .you(prompt), "message", [.sent(to: "zig", text: prompt, original: nil)])
        sentByThen.decision.targetID = RouteTarget.newThread(project: "demo-project-lookout").targetID
        sentByThen.decision.decider = "jev"
        sentByThen.fromAction = SessionOrigin(category: "Contributions", thing: "ziglang/zig#1", actionID: "demo", runID: "demo")
        sentByThen.mentions = [RouterMention(range: 13..<(13 + pill.count), pointer: .notification("pr:ziglang/zig#1"), name: "ziglang/zig#1")]
        state.decisions = [
            asked,
            sentToThread,
            entry(0.5, .you("bump the version for the release"), "message", [.failed("Stopped")]),
            undelivered,
            sentByThen,
            entry(9, .you("add a category for my contributions that need a look, and snooze banners for an hour"), "change",
                  changes.prefix(2).map { .changed($0.id) }),
            entry(3, .you("archive the bot chatter, and mute reviews for you"), "change",
                  changes.dropFirst(2).map { .changed($0.id) }, outcome: .done),
        ]
        if let last = state.decisions.indices.last, changes.last?.isReverted == true {
            state.decisions[last].outcome = .reverted
        }
        // A message the Router couldn't place: asks where it goes (its run's entry waits for the pick), and one run under way.
        var asking = RouterDecision(at: now.addingTimeInterval(-15), trigger: .you("ship it tomorrow morning"), decision: .init(intent: "message", label: "unclear", confidence: 0.48))
        asking.decision.decider = "sonnet"
        asking.add(.asked(["CI failure diagnosis", "Repository ownership transfer setup", "lcu"]))
        let running = RouterDecision(at: now.addingTimeInterval(-4), trigger: .you("archive the old fork once the transfer is done"), decision: .init(intent: "message"))
        state.decisions += [asking, running]
        store.router = state
        let ci = RouteTarget.thread("local_demo-ci").targetID
        let places = [ci, RouteTarget.thread("local_demo-transfer").targetID,
                      RouteTarget.newThread(project: "demo-project-lcu-research").targetID]
        let options = places.compactMap { store.routerDispatcher.option($0, store: store) }
        store.routerDispatcher.preview(
            ask: RouterAskBack(id: asking.id, message: "ship it tomorrow morning", context: RouterContext(),
                               options: options, suggestion: ci, at: now.addingTimeInterval(-15)),
            progress: [running.id: RouterProjectDecider.Stage.sonnet.words])
    }

    /// The Router changing Fjord itself: a record for each change (one taken back).
    private static func fjordChanges(_ store: Store, _ now: Date) -> [FjordChange] {
        let look = InboxCategory(
            name: "Needs a look", symbol: "eye", color: .aqua,
            rules: [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.maintainers], except: [.bots]), in: Pick(include: [.contributed])),
                         match: .any,
                         conditions: [.checks([.failing]), .unresolvedThreads(startedBy: nil, lastReplyBy: nil),
                                      .newReview(by: Pick(include: [.maintainers]), since: .myLastReview)],
                         createdAt: now)],
            actions: ActionList([CategoryAction.make(.askRouter(prompt: "Look at it and tell me what is left"))]))
        let reviews = store.categories.first { $0.name == "Reviews for you" }
        var quiet = reviews
        quiet?.notifies = false
        quiet?.hidden = true
        func message(_ title: String, _ patch: FjordChange.Patch, minutes: Double, reverted: Bool = false) -> FjordChange {
            var change = FjordChange(date: now.addingTimeInterval(-minutes * 60), title: title, patch: patch)
            if reverted {
                change.revertedAt = now.addingTimeInterval(-60)
                change.revertNote = "Reverted"
            }
            return change
        }
        let doneThings = store.entries.prefix(3).map { EntryChange(thing: $0.id, before: nil, after: EntryMarks(doneAt: now)) }
        var out = [
            message(FjordChange.title(forCategory: nil, look), .category(index: 1, before: nil, after: look), minutes: 8),
            message("Changed snooze to 1 hour",
                    .setting(key: "snooze", before: .date(nil), after: .date(now.addingTimeInterval(3600))), minutes: 8),
            message("Archived \(doneThings.count)", .marks(state: "done", doneThings), minutes: 2),
        ]
        if let reviews, let quiet {
            out.append(message(FjordChange.title(forCategory: reviews, quiet), .category(index: 1, before: reviews, after: quiet),
                               minutes: 2, reverted: true))
        }
        return out
    }

    /// Only the bots' things and the finished ones left: nothing is for you.
    private static func nothingForYou(_ store: Store) {
        for category in ["Contributions", "Reviews for you"] { empty(store, category: category) }
    }

    // MARK: Inbox

    /// The demo's categories, in their order: ids fixed, so a shot can name them.
    private static func categories(ciRepos: [String]) -> [InboxCategory] {
        func id(_ n: Int) -> UUID { UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")! }
        let longAgo = Date().addingTimeInterval(-60 * 86400)
        // What needs you on your own PRs: Greptile short of 5, threads still open, someone else having the last word,
        // a review that decides, conflicts.
        let contributions = InboxCategory(
            id: id(1), name: "Contributions", symbol: "hammer", color: .violet,
            rules: [Rule(scope: Scope(kinds: [.pr], by: Pick(include: [.me]), in: Pick(include: [.contributed])),
                         match: .any,
                         conditions: [.greptileBelow(5), .unresolvedThreads(startedBy: nil, lastReplyBy: nil),
                                      .lastComment(by: Pick(except: [.me])), .changesRequested(by: Pick()), .approved(by: Pick()),
                                      .hasConflicts],
                         createdAt: longAgo)])
        let reviews = InboxCategory(
            id: id(2), name: "Reviews for you", symbol: "eye.circle", color: .amber,
            rules: [Rule(scope: Scope(kinds: [.pr], to: Pick(include: [.me]), toRoles: [.reviewRequested]), createdAt: longAgo)])
        let bots = InboxCategory(
            id: id(3), name: "Bot chatter", symbol: "cpu", color: .gray,
            rules: [Rule(scope: Scope(kinds: [.pr], in: Pick(include: [.involved])), match: .any,
                         conditions: [.newComment(by: Pick(include: [.bots]))], createdAt: longAgo)],
            notifies: false)
        var ci = InboxStore.ci
        ci.id = id(4)
        ci.rules = [Rule(scope: Scope(kinds: [.workflow], in: Pick(include: ciRepos.map { .repo($0) })), conditions: [.workflow([.failing])],
                         createdAt: longAgo)]
        return [contributions, reviews, bots, ci]
    }

    /// GitHub's ids for the demo's workflows (a workflow thing is `workflow:<repo>:<id>@<branch>`).
    private static let ciWorkflowID = 1001
    private static let workflowIDs = ["CI": ciWorkflowID, "Sandbox tests": 1002, "Release": 1003]

    private static let ciRepoNames = ["amontlabs/fjord", "apple/swift-format", "ziglang/zig", "amontlabs/lcu",
                                      "superradcompany/microsandbox"]

    /// The inbox on the demo data: things fetched from GitHub, in the categories above, some seen, some done.
    private static func inbox(_ store: Store, _ now: Date) {
        store.categories = categories(ciRepos: ciRepoNames)
        store.contributedRepos = ["ziglang/zig", "apple/swift-format", "amontlabs/fjord", "amontlabs/lcu"]
        let me = person("0xpolarzero")
        var things: [Thing] = []

        func pr(_ repo: String, _ n: Int, _ title: String, by author: Person, minutes: Double, greptile: Int? = nil,
                checks: CheckState? = .passing, requested: [String] = [], assignees: [String] = [], mentioned: [String] = [],
                status: ThingStatus = .open, conflicts: Bool = false, comments: [ThingComment] = [], reviews: [ThingReview] = [],
                threads: [ThingThread] = []) -> Thing {
            Thing(id: "pr:\(repo)#\(n)", kind: .pr, repo: repo, number: n, title: title,
                  url: URL(string: "https://github.com/\(repo)/pull/\(n)")!, author: author, status: status,
                  assignees: assignees, requestedReviewers: requested, mentioned: mentioned,
                  createdAt: now.addingTimeInterval(-86400 * 3), updatedAt: now.addingTimeInterval(-minutes * 60),
                  comments: comments, reviews: reviews, threads: threads, checks: checks, hasConflicts: conflicts,
                  greptileScore: greptile)
        }
        func comment(_ key: String, _ author: Person, _ text: String, minutes: Double, mentions: [String] = []) -> ThingComment {
            ThingComment(id: key, author: author, at: now.addingTimeInterval(-minutes * 60), snippet: text, mentions: mentions)
        }
        func thread(_ key: String, by: Person, reply: Person, minutes: Double, path: String, _ text: String,
                    resolved: Bool = false) -> ThingThread {
            ThingThread(id: key, isResolved: resolved, startedBy: by, lastReplyBy: reply, lastReplyID: key + "-r",
                        lastReplyAt: now.addingTimeInterval(-minutes * 60), path: path, snippet: text)
        }

        // Contributions: your PRs.
        let toks = person("toksdotdev", assoc: .collaborator)
        let andrew = person("andrewrk", assoc: .owner)
        let allevato = person("allevato", assoc: .member)
        let greptile = person("greptile-apps[bot]", bot: true)
        things.append(pr("amontlabs/fjord", 15, "Add GitHub Enterprise host setting", by: me, minutes: 12, greptile: 4,
                         comments: [comment("c15-1", greptile, "Confidence 4/5: one path still uses the fixed host.", minutes: 95),
                                    comment("c15-2", toks, "Can the host be validated before we save it?", minutes: 12)],
                         threads: [thread("t15-1", by: toks, reply: toks, minutes: 12, path: "Sources/Fjord/GitHub.swift",
                                          "Can the host be validated before we save it?"),
                                   thread("t15-2", by: toks, reply: me, minutes: 80, path: "Sources/Fjord/SettingsView.swift",
                                          "Placeholder text says github.com.")]))
        things.append(pr("ziglang/zig", 21877, "std.Io: add vectored reads to File", by: me, minutes: 3, greptile: 3, checks: .pending,
                         comments: [comment("c21877-1", andrew, "This should take the buffer by slice instead.", minutes: 3)],
                         reviews: [ThingReview(id: "r21877-1", author: andrew, state: .changesRequested,
                                               at: now.addingTimeInterval(-180))],
                         threads: [thread("t21877-1", by: andrew, reply: andrew, minutes: 3, path: "lib/std/Io/File.zig",
                                          "This should take the buffer by slice instead.")]))
        things.append(pr("apple/swift-format", 1042, "Respect trailing comma config in collection literals", by: me, minutes: 18,
                         greptile: 5,
                         comments: [comment("c1042-1", allevato, "Thanks! Could you add a test for the nested array case?", minutes: 18)],
                         reviews: [ThingReview(id: "r1042-1", author: allevato, state: .approved, at: now.addingTimeInterval(-1100))]))
        things.append(pr("amontlabs/lcu", 31, "Bump the Swift tools version", by: me, minutes: 240, greptile: 5, checks: .failing,
                         conflicts: true))

        // Reviews for you: asked of you.
        let ahoppen = person("ahoppen", assoc: .member)
        let mlugg = person("mlugg", assoc: .collaborator)
        let cbrewster = person("cbrewster")
        things.append(pr("apple/swift-format", 1051, "Add --lines option to format a range", by: ahoppen, minutes: 65,
                         requested: ["0xpolarzero"]))
        things.append(pr("ziglang/zig", 21840, "Sema: fix comptime int overflow in @shlExact", by: mlugg, minutes: 1500,
                         requested: ["0xpolarzero"]))
        things.append(pr("superradcompany/microsandbox", 412, "Mount host directories read-only", by: cbrewster, minutes: 400,
                         checks: .pending, requested: ["0xpolarzero"], status: .draft))

        // Bot chatter: PRs of others you're in, where a bot spoke.
        let kylef = person("kylef")
        let vercel = person("vercel[bot]", bot: true)
        let rabbit = person("coderabbitai[bot]", bot: true)
        let codecov = person("codecov[bot]", bot: true)
        things.append(pr("amontlabs/fjord", 14, "Group notifications by repo", by: kylef, minutes: 6, assignees: ["0xpolarzero"],
                         comments: [comment("c14-1", vercel, "Deployment ready. Preview: lookout-git-group.vercel.app", minutes: 6)]))
        things.append(pr("apple/swift-format", 1047, "Fix a crash on an empty file", by: allevato, minutes: 22, mentioned: ["0xpolarzero"],
                         comments: [comment("c1047-1", rabbit, "Consider extracting this into a helper.", minutes: 22),
                                    comment("c1047-2", codecov, "Coverage 87.2% (+0.4%) compared to base.", minutes: 25)]))
        things.append(pr("ziglang/zig", 21901, "Linker: skip empty sections", by: person("squeek502"), minutes: 700,
                         assignees: ["0xpolarzero"],
                         comments: [comment("c21901-1", person("github-actions[bot]", bot: true), "Benchmarks are within noise.",
                                            minutes: 700)]))

        // CI: workflows, the failing ones in the category.
        func workflow(_ repo: String, _ name: String, branch: String = "main", state: CheckState, title: String, minutes: Double,
                      jobs: [String] = []) -> Thing {
            Thing(id: "workflow:\(repo):\(workflowIDs[name] ?? 1000)@\(branch)", kind: .workflow, repo: repo, number: nil, title: title,
                  url: URL(string: "https://github.com/\(repo)/actions")!, createdAt: now.addingTimeInterval(-minutes * 60),
                  updatedAt: now.addingTimeInterval(-minutes * 60), checks: state, workflowName: name, branch: branch,
                  failingJobs: jobs)
        }
        things.append(workflow("apple/swift-format", "CI", state: .failing, title: "Respect trailing comma config (#1042)", minutes: 45,
                               jobs: ["Linux / build", "Windows / test"]))
        things.append(workflow("superradcompany/microsandbox", "Sandbox tests", state: .failing,
                               title: "Mount host directories read-only (#412)", minutes: 380, jobs: ["Linux / integration"]))
        things.append(workflow("amontlabs/fjord", "CI", state: .passing, title: "Compact, draggable repo cards", minutes: 25))
        things.append(workflow("ziglang/zig", "CI", branch: "master", state: .pending, title: "std.Io: add vectored reads to File",
                               minutes: 4))
        things.append(workflow("amontlabs/lcu", "Release", state: .passing, title: "Release 0.4.2", minutes: 1440))

        // What Jev made of them: the comments that ask you something or for a change, the bots' noise, FYI for the rest,
        // and how much each review asked of you matters.
        let context = InboxContext(me: me.login)
        func jev(_ id: String, asks: [String] = [], todo: [String] = [], noise: [String] = [], importance: Importance? = nil) {
            guard let i = things.firstIndex(where: { $0.id == id }) else { return }
            var signals = ThingSignals(viewer: InboxEngine.viewer(me.login))
            for m in InboxEngine.messages(things[i]) where m.author.login != me.login {
                signals.messages[m.id] = MessageSignal(label: asks.contains(m.id) ? .asks : todo.contains(m.id) ? .todo
                                                       : noise.contains(m.id) ? .noise : .fyi)
            }
            if let importance, let stamp = InboxEngine.importanceStamp(things[i], context: context) {
                signals.importance = ImportanceSignal(level: importance, stamp: stamp)
            }
            things[i].signals = signals
        }
        jev("pr:amontlabs/fjord#15", asks: ["c15-2"], todo: ["t15-1-r"])
        jev("pr:apple/swift-format#1042", todo: ["c1042-1"])
        jev("pr:ziglang/zig#21877", todo: ["c21877-1"])
        jev("pr:apple/swift-format#1051", importance: .urgent)
        jev("pr:ziglang/zig#21840", importance: .high)
        jev("pr:superradcompany/microsandbox#412", importance: .low)
        jev("pr:amontlabs/fjord#14", noise: ["c14-1"], importance: .normal)
        jev("pr:apple/swift-format#1047", noise: ["c1047-2"])

        store.things = Dictionary(uniqueKeysWithValues: things.map { ($0.id, $0) })
        store.marks = [:]
        // Some seen; some done (they come back when something new happens).
        for entry in store.entries {
            switch entry.id {
            case "pr:ziglang/zig#21877", "pr:apple/swift-format#1047": store.markSeen(entry)
            case "pr:ziglang/zig#21840", "pr:ziglang/zig#21901": store.markDone(entry)
            default: break
            }
        }
        CategoriesDemo.seedActions(store, categories: CategoriesDemo.demoActions)
    }

    private static func person(_ login: String, bot: Bool = false, assoc: Association = .none) -> Person {
        Person(login: login, isBot: bot, association: assoc,
               avatar: URL(string: "https://github.com/\(login.replacingOccurrences(of: "[bot]", with: "")).png"))
    }

    /// Takes the open things of a category away: nothing for you there.
    private static func empty(_ store: Store, category name: String) {
        guard let id = store.categories.first(where: { $0.name == name })?.id else { return }
        let gone = Set(store.entries.filter { $0.categoryID == id && !$0.isDone }.map(\.id))
        store.things = store.things.filter { !gone.contains($0.key) }
    }

    /// Every CI repo green.
    private static func passing(_ store: Store) {
        for key in store.things.keys where store.things[key]?.kind == .workflow { store.things[key]?.checks = .passing }
    }

    /// 15 repositories with CI: nine failing, two running, four passing; more than the list shows.
    private static func manyCI(_ store: Store, _ now: Date) {
        let names = ["amontlabs/fjord", "apple/swift-format", "ziglang/zig", "amontlabs/lcu", "e2b-dev/runtime",
                     "superradcompany/microsandbox", "apple/swift-argument-parser", "pointfreeco/swift-composable-architecture",
                     "vapor/vapor", "swiftlang/swift-package-manager", "tuist/tuist", "realm/SwiftLint", "Alamofire/Alamofire",
                     "hummingbird-project/hummingbird", "apple/swift-nio"]
        store.categories = categories(ciRepos: names)
        let failing: [String: [String]] = [
            "apple/swift-format": ["Linux / build", "Windows / test"], "vapor/vapor": ["Unit tests (5.10)"],
            "tuist/tuist": ["Acceptance"], "realm/SwiftLint": ["Plugin tests"], "Alamofire/Alamofire": ["macOS", "tvOS"],
            "swiftlang/swift-package-manager": ["Build"], "pointfreeco/swift-composable-architecture": ["Library evolution"],
            "e2b-dev/runtime": ["Integration"], "amontlabs/lcu": ["Desktop"],
        ]
        let running: Set<String> = ["ziglang/zig", "apple/swift-nio"]
        store.things = store.things.filter { $0.value.kind != .workflow }
        for (index, name) in names.enumerated() {
            let state: CheckState = failing[name] != nil ? .failing : running.contains(name) ? .pending : .passing
            let thing = Thing(id: "workflow:\(name):\(ciWorkflowID)@main", kind: .workflow, repo: name, number: nil, title: "Commit headline \(index + 1)",
                              url: URL(string: "https://github.com/\(name)/actions")!,
                              createdAt: now.addingTimeInterval(-Double(index + 1) * 2300),
                              updatedAt: now.addingTimeInterval(-Double(index + 1) * 2300), checks: state, workflowName: "CI",
                              branch: "main", failingJobs: failing[name] ?? [])
            store.things[thing.id] = thing
        }
    }

    static let blockedAgentID = "local_demo-lcu"

    /// A thread as T3's shell reports it: a finished run with its last message, waiting on a question (`blocked`), or mid-run.
    private static func session(_ id: String, _ title: String, _ folder: String?, minutes: Double,
                                blocked: Bool = false, detail: String = "", running: Bool = false) -> T3ThreadShell {
        let at = Date().addingTimeInterval(-minutes * 60)
        let stamp = T3JSON.string(T3Timestamp.format(at))
        let pending: T3JSON = blocked ? ["id": .string("demo-request-\(id)"), "kind": "user_input", "createdAt": stamp, "blocking": true] : .null
        let message: T3JSON = detail.isEmpty ? .null : ["id": .string("demo-message-\(id)"), "role": "assistant", "text": .string(detail), "updatedAt": stamp]
        return T3ThreadShell(json: [
            "id": .string(id), "projectId": .string(projectID(folder)), "title": .string(title), "providerInstanceId": "claudeAgent",
            "status": running || blocked ? "running" : "completed", "activityRunStatus": running || blocked ? "running" : .null,
            "pendingRuntimeRequest": pending, "latestVisibleMessage": message,
            "latestUserMessageAt": .string(T3Timestamp.format(at.addingTimeInterval(-90))),
            "latestRunCompletedAt": running || blocked ? .null : stamp, "lineage": ["rootThreadId": .string(id)],
            "createdAt": .string(T3Timestamp.format(at.addingTimeInterval(-3600))), "updatedAt": stamp,
        ])
    }

    private static func projectID(_ folder: String?) -> String { "demo-project-\(folder ?? "scratch")" }

    /// A thread and how Fjord lists it: seen or not, with the label or icon it was given.
    private struct Listed {
        var session: T3ThreadShell
        var unread = false
        var label: String?
        var icon: String?

        init(_ session: T3ThreadShell, unread: Bool = false, label: String? = nil, icon: String? = nil) {
            self.session = session
            self.unread = unread
            self.label = label
            self.icon = icon
        }
    }

    /// The Router's reading of T3's threads, on, with these threads (fed through T3's store, as the shell stream would).
    /// `colors` pins each project's colour; the others get the least used one, in listing order. `unlisted` are in T3 but
    /// quiet: only found by search.
    private static func sessions(_ store: Store, _ now: Date, _ listed: [Listed], activity: [String: ThreadWork] = [:],
                                 tasks: [String: [BackgroundWork]] = [:], colors: [String: Int] = [:],
                                 unlisted: [T3ThreadShell] = []) {
        var shell = T3ShellState()
        for l in listed {
            var t = l.session
            // Seen: visited at its last update; unseen: never visited.
            if !l.unread, let updated = t.updatedAt { t.lastVisitedAt = updated }
            shell.threads[t.id] = t
        }
        for t in unlisted {
            var t = t
            t.lastVisitedAt = t.updatedAt
            shell.threads[t.id] = t
        }
        for t in shell.threads.values where shell.projects[t.projectId] == nil {
            let folder = t.projectId.hasSuffix("-scratch") ? nil : "/Users/me/code/" + t.projectId.replacingOccurrences(of: "demo-project-", with: "")
            shell.projects[t.projectId] = T3Project(json: ["id": .string(t.projectId), "title": .string(folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No project"),
                                                           "workspaceRoot": .string(folder ?? AgentThread.scratchRoot)])
        }
        shell.synchronized = true
        var state = ThreadsState()
        state.folderColors = colors
        state.enabled = true
        state.iconsEnabled = true
        state.entries = listed.compactMap { l in
            l.label == nil && l.icon == nil ? nil : ThreadEntry(id: l.session.id, label: l.label, icon: l.icon)
        }
        store.agents = state
        store.t3.store.seed(shell)
        store.t3.demoStatus = .connected(threads: store.threads.count)
        store.threadWork = activity
        // What subagents are on comes with each thread's detail, in a later step: the demo says it already.
        store.backgroundWork = store.backgroundWork.merging(tasks) { _, demo in demo }
    }

    /// The sessions in every state: a waiting one, a working one, finished ones (unread and read), new activity.
    static func agents(_ store: Store, _ now: Date) {
        let listed = [
            Listed(session(blockedAgentID, "LCU update notifications", "lcu", minutes: 2, blocked: true,
                           detail: "Should updates install silently, or ask first each time?"), unread: true, icon: "bell.badge"),
            Listed(session("local_demo-ci", "CI failure diagnosis", "microsandbox", minutes: 4,
                           detail: "Fixed the flaky sandbox test; CI is green on the branch."), unread: true, icon: "ladybug"),
            Listed(session("local_demo-lookout", "Agent completion notifications", "lookout", minutes: 1, running: true)),
            Listed(session("local_demo-transfer", "Repository ownership transfer setup", "microsandbox", minutes: 180,
                           detail: "Transfer is done; both remotes point at the new org."), icon: "key"),
            Listed(session("local_demo-linux", "LCU JavaScript sandbox on Linux", "microsandbox", minutes: 1500,
                           detail: "Sandbox runs on Linux; two follow-ups listed."), label: "\u{1F427}"),
            Listed(session("local_demo-calc", "Calculator display reading", "lcu-research", minutes: 1,
                           detail: "The display reads 1,234.5; the screenshot is attached."), unread: true),
            Listed(session("local_demo-games", "Game recommendations", nil, minutes: 25,
                           detail: "Single-player immersion or online squads?")),
        ]
        let hidden = session("local_demo-storage", "Sandbox storage directory customization", "microsandbox", minutes: 2900,
                             detail: "Storage path is configurable through the CLI and the env.")
        sessions(store, now, listed, activity: ["local_demo-lookout": ThreadWork(
                    text: "Running swift test", since: now.addingTimeInterval(-20),
                    todo: .init(done: 3, total: 7, active: "Running the test suite"))],
                 tasks: ["local_demo-ci": [
                    BackgroundWork(id: "a1", kind: .agent, title: "Review the sandbox changes", since: now.addingTimeInterval(-190),
                               activity: ThreadWork(text: "Reading sandbox.rs", since: now.addingTimeInterval(-5))),
                    BackgroundWork(id: "a2", kind: .agent, title: "Check the other CI jobs", since: now.addingTimeInterval(-70),
                               activity: ThreadWork(text: "Thinking", since: now.addingTimeInterval(-2))),
                    BackgroundWork(id: "b1", kind: .command, title: "Run the full test suite", since: now.addingTimeInterval(-370)),
                 ]],
                 colors: ["/Users/me/code/lcu": 0, "/Users/me/code/microsandbox": 1, "/Users/me/code/lookout": 2,
                          "/Users/me/code/lcu-research": 3],
                 unlisted: [hidden])
    }

}

/// `--check owner/repo`: headless refresh against live GitHub, prints what the inbox would contain for the repo's PRs, issues
/// and workflows.
@MainActor
enum Check {
    static func run(store: Store, repo: String) {
        store.persists = false
        Task {
            await store.authenticate()
            print("auth:", store.me?.login ?? "nil", store.tokenSource?.rawValue ?? "", store.authError ?? "")
            let scope = Pick<RepoRef>(include: [.repo(repo)])
            store.categories = [
                InboxCategory(name: "PRs", symbol: "arrow.triangle.pull", color: .violet,
                              rules: [Rule(scope: Scope(kinds: [.pr], in: scope), createdAt: .distantPast)]),
                InboxCategory(name: "Issues", symbol: "smallcircle.filled.circle", color: .green,
                              rules: [Rule(scope: Scope(kinds: [.issue], in: scope), createdAt: .distantPast)]),
                InboxCategory(name: "CI", symbol: "xmark.seal", color: .red,
                              rules: [Rule(scope: Scope(kinds: [.workflow], in: scope), conditions: [.workflow([.failing, .pending, .passing])],
                                           createdAt: .distantPast)]),
            ]
            await store.pollAll()
            for entry in store.entries.sorted(by: { $0.thing.updatedAt > $1.thing.updatedAt }).prefix(25) {
                let category = store.categories.first { $0.id == entry.categoryID }?.name ?? ""
                print(String(format: "%-7@ %@ %@  %@  [%@]", category, shortAgo(entry.thing.updatedAt), entry.id,
                             String(entry.thing.title.prefix(50)), entry.facts.map(\.label).joined(separator: " · ")))
            }
            print("things:", store.things.count, "error:", store.inboxError ?? "none")
            print("rate:", store.gh.rateRemaining ?? -1, "graphql:", store.gh.graphqlRemaining ?? -1)
            exit(0)
        }
    }
}

/// `--t3`: what the Router reads of T3 right now (its link, its threads by group, what waits on you), read-only; `--watch`
/// keeps reading and prints every change. Nothing is saved and no command is sent.
@MainActor
enum T3Check {
    private static var store: Store?

    static func run() {
        let store = Store()
        Self.store = store
        store.persists = false
        store.agents.enabled = true
        let watching = CommandLine.arguments.contains("--watch")
        var last = ""
        var started = Date()
        store.t3.store.onShell = { item in
            store.shellChanged(item)
            guard store.t3.store.shell.sequence != nil else { return }
            let text = dump(store)
            guard text != last else { return }
            if last.isEmpty { print("first shell in \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
            last = text
            print("--- \(Date().formatted(date: .omitted, time: .standard))\n" + text)
            fflush(stdout)
            if !watching { exit(0) }
        }
        store.t3.store.onThread = { store.threadDetailChanged($0) }
        store.t3.store.onConnection = { state in
            store.t3ConnectionChanged(state)
            if store.t3.status.isProblem || store.t3.status == .notLinked {
                print("link:", store.t3.status.text)
                if !watching { exit(1) }
            }
        }
        guard store.t3.installed else { print("link:", store.t3.status.text); exit(1) }
        started = Date()
        store.t3.start()
    }

    private static func dump(_ store: Store) -> String {
        var lines = ["link: \(store.t3.status.text)", "threads: \(store.threads.count), listed: \(store.allAgentRows.count)"]
        for group in ThreadGroup.allCases {
            let rows = store.allAgentRows.filter { $0.group == group }
            guard !rows.isEmpty else { continue }
            lines.append("\(group): \(rows.count)")
            for r in rows {
                var line = "  \(r.label) \(r.session.status.rawValue) \(r.session.title) · \(r.projectName)"
                if let p = r.session.pendingRequest { line += " · waits on \(p.kind)" }
                if r.session.hasPlan { line += " · plan" }
                if let t = r.tasksText { line += " · \(t)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}
