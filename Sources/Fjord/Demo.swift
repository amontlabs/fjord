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
        // The Router: cards of each kind (a question with its form) and a chat with receipts; and the Router switched off.
        case router, routerCanvas, routerOff
    }

    static func populate(_ store: Store, _ scenario: Scenario = .busy) {
        store.persists = false
        // A demo's state isn't news for the Brief.
        store.routerDigester.suspended = true
        defer {
            store.routerDigester.suspended = false
            store.routerDigester.baseline(store: store)
        }
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
        case .router, .routerCanvas:
            agents(store, now)
            router(store, now)
            briefs(store, now: now)
        case .routerOff:
            agents(store, now)
        }
    }

    /// The Router on, over the `agents` sessions: the one that asks is stopped on its question (whose form
    /// Fjord holds), a plan and a stuck turn wait, a turn is done, older cards are addressed; a short chat
    /// with what the Router did.
    /// The demo's claude.ai projects and their threads, as the engine's Board would share them: where the Router sends.
    static func claudeProjects(_ store: Store, now: Date = Date()) {
        func thread(_ id: String, _ title: String, _ state: String, minutes: Double) -> CourierPlace.Thread {
            .init(id: id, title: title, state: state, touched: now.addingTimeInterval(-minutes * 60).timeIntervalSince1970)
        }
        var snapshot = CourierSnapshot()
        snapshot.health = CourierSetupHealth(tabConnected: true, signedIn: true)
        snapshot.places = [
            CourierPlace(id: "chan_demo_lookout", name: "lookout", purpose: "Fjord, the macOS app", threads: [
                thread("thr_demo_notify", "Agent completion notifications", "working", minutes: 3),
                thread("thr_demo_ci", "CI failure diagnosis", "idle", minutes: 4),
            ]),
            CourierPlace(id: "chan_demo_lcu", name: "lcu", purpose: "Computer use for agents", threads: [
                thread("thr_demo_updates", "Update notifications", "needs_you", minutes: 2),
            ]),
            CourierPlace(id: "chan_demo_sandbox", name: "microsandbox", purpose: "Sandboxes for untrusted code", threads: [
                thread("thr_demo_transfer", "Repository ownership transfer setup", "idle", minutes: 12),
                thread("thr_demo_linux", "Linux sandbox in a Firecracker microVM", "needs_you", minutes: 9),
            ]),
            CourierPlace(id: "chan_demo_zig", name: "zig", purpose: "", threads: []),
        ]
        store.routerCourierLink.take(snapshot)
    }

    private static func router(_ store: Store, _ now: Date) {
        claudeProjects(store, now: now)
        let lcu = blockedAgentID
        store.claudeSessions[lcu]?.running = true
        store.claudeSessions[lcu]?.cliID = "cli-demo-lcu"
        store.claudeActivity[lcu] = ClaudeActivity(text: "Should updates install silently, or ask first each time?",
                                                   since: now.addingTimeInterval(-120), waitsForYou: true, tool: "AskUserQuestion",
                                                   toolUseID: "toolu_demo_lcu")
        let question = "Should updates install silently, or ask first each time?"
        store.pendingForms["cli-demo-lcu"] = PendingForm(
            id: "cli-demo-lcu-1-1", cliSessionID: "cli-demo-lcu", transcriptPath: "",
            questions: [PendingForm.Question(question: question, header: "Updates", multiSelect: false, options: [
                PendingForm.Option(label: "Install silently", description: "Download and install in the background"),
                PendingForm.Option(label: "Ask first", description: "Show a prompt before each update"),
            ])],
            createdAt: now.addingTimeInterval(-60), pid: 0, toolUseID: "toolu_demo_lcu")
        // The Linux sandbox's plan, held the same way: its card shows it, to approve or send back.
        let linux = "local_demo-linux"
        store.claudeSessions[linux]?.cliID = "cli-demo-linux"
        store.pendingForms["cli-demo-linux"] = PendingForm(
            id: "cli-demo-linux-1-1", cliSessionID: "cli-demo-linux", transcriptPath: "", questions: [],
            createdAt: now.addingTimeInterval(-540), pid: 0, toolUseID: "toolu_demo_linux", plan: """
            # Run the JavaScript sandbox in a Firecracker microVM on Linux

            1. Add a `firecracker` backend next to the macOS one, behind the same `Sandbox` protocol.
            2. Boot a minimal kernel and rootfs with the JS runtime baked in; talk to it over vsock.
            3. Run the existing sandbox tests against both backends in CI (Linux runner with KVM).
            """)
        func card(_ session: String, _ kind: RouterCard.Kind, _ text: String, minutes: Double, addressed: RouterCard.Addressed? = nil)
            -> RouterCard {
            let s = store.claudeSessions[session]
            let at = now.addingTimeInterval(-minutes * 60)
            // Ids as the feed makes them: a wait by when it began, a turn by its number.
            let id = kind.isTurn ? "\(session)#t\(s?.completedTurns ?? 0)" : "\(session)#w\(RouterFeed.Stamp.ms(at))"
            return RouterCard(id: id, sessionID: session, kind: kind,
                              title: s?.title ?? session, folder: s?.folder, text: text, createdAt: at,
                              addressedAt: addressed == nil ? nil : at.addingTimeInterval(120), addressedBy: addressed)
        }
        var state = RouterState()
        state.enabled = true
        state.enabledAt = now.addingTimeInterval(-86400)
        state.cards = [
            card("local_demo-transfer", .done, "Transfer is done; both remotes point at the new org.", minutes: 12, addressed: .router),
            card("local_demo-games", .question, "Single-player immersion or online squads?", minutes: 30, addressed: .answered),
            card("local_demo-ci", .done, "Fixed the flaky sandbox test; **CI is green** on the branch.", minutes: 4),
            card("local_demo-linux", .plan, "Run the JavaScript sandbox in a Firecracker microVM on Linux", minutes: 9),
            card("local_demo-calc", .stuck, "Can't reach the staging database: the VPN is down.", minutes: 6),
            card(lcu, .question, question, minutes: 2),
        ]
        state.cards[state.cards.count - 1].toolUseID = "toolu_demo_lcu"
        let fromAction = SessionOrigin(category: "Contributing", thing: "lcu#41 Update notifications", actionID: "a", runID: "r")
        if let i = state.cards.firstIndex(where: { $0.sessionID == "local_demo-calc" }) { state.cards[i].origin = fromAction }
        state.cards[state.cards.count - 1].origin = fromAction
        if let i = state.cards.firstIndex(where: { $0.sessionID == linux }) { state.cards[i].toolUseID = "toolu_demo_linux" }
        // The question is the wait the session is on now, so its form shows on its card.
        state.waits[lcu] = state.cards.last?.waitMs
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
        sentToThread.decision.targetID = RouterCourier.Target.thread(project: "microsandbox", thread: "thr_demo_transfer").targetID
        sentToThread.decision.target = "thread “Repository ownership transfer setup” in claude.ai project microsandbox"
        sentToThread.decision.decider = "jev"
        var asked = entry(5, .you("what needs me?"), "question", [])
        asked.reply = "**3 need you**: *LCU update notifications* asks how updates install; the Linux sandbox has a plan to approve; "
            + "*Calculator display reading* is stuck on the VPN.\nDone: CI failure diagnosis."
        asked.note = "answered"
        var undelivered = entry(0.2, .you("rebase the games branch on main"), "reply",
                                [.failed("Not delivered to microsandbox: Fjord's tab in Chrome isn't connected")])
        undelivered.decision.targetID = RouterCourier.Target.project("microsandbox").targetID
        undelivered.decision.decider = "sonnet"
        // A category's "Then" sent its prompt with the thing tagged; the Router sent it to its claude.ai project.
        let pill = "@ziglang/zig#1"
        let prompt = "Address what \(pill) is waiting on."
        var sentByThen = entry(0.3, .you(prompt), "message", [.sent(to: "zig", text: prompt, original: nil)])
        sentByThen.decision.targetID = RouterCourier.Target.project("zig").targetID
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
        state.summaries = [
            RouterSummary(at: now.addingTimeInterval(-420), text: "Lookout is mid-way through its test suite after wiring the "
                          + "completion notifications; nothing has failed so far.", sessionID: "local_demo-lookout",
                          title: "Agent completion notifications"),
            RouterSummary(at: now.addingTimeInterval(-180), text: "The flaky sandbox test is fixed and CI is green; two "
                          + "subagents are still reviewing the sandbox changes and the other jobs.", sessionID: "local_demo-ci",
                          title: "CI failure diagnosis"),
        ]
        // A message the Router couldn't place: asks where it goes (its run's entry waits for the pick), and one run under way.
        var asking = RouterDecision(at: now.addingTimeInterval(-15), trigger: .you("ship it tomorrow morning"), decision: .init(intent: "message", label: "unclear", confidence: 0.48))
        asking.decision.decider = "sonnet"
        asking.add(.asked(["CI failure diagnosis", "Repository ownership transfer setup", "lcu"]))
        var running = RouterDecision(at: now.addingTimeInterval(-4), trigger: .you("archive the old fork once the transfer is done"), decision: .init(intent: "message"))
        state.decisions += [asking, running]
        store.router = state
        let ci = RouterCourier.Target.thread(project: "lookout", thread: "thr_demo_ci").targetID
        let places = [ci, RouterCourier.Target.thread(project: "microsandbox", thread: "thr_demo_transfer").targetID,
                      RouterCourier.Target.project("lcu").targetID]
        let options = places.compactMap { store.routerDispatcher.option($0, store: store) }
            + [.init(target: RouterAskBack.newProject, title: "New project…", detail: "on claude.ai")]
        store.routerDispatcher.preview(
            ask: RouterAskBack(id: asking.id, message: "ship it tomorrow morning", context: RouterContext(),
                               options: options, suggestion: ci, at: now.addingTimeInterval(-15)),
            progress: [running.id: RouterProjectDecider.Stage.sonnet.words])
    }

    /// What Jev's triage makes of finished turns, on top of the Router's demo: a turn asking your OK, one asking two
    /// questions, chips on the finished ones, and sessions waiting on CI and on another session (one of them ready to go on).
    static func routerTriage(_ store: Store, now: Date = Date()) {
        let added = [
            (session("local_demo-release", "Release 2.4 to the App Store", "lookout", minutes: 3,
                     detail: "The build and the release notes are ready."), "shippingbox"),
            (session("local_demo-api", "Rate limiter for the public API", "microsandbox", minutes: 8,
                     detail: "The limiter works; two choices are left to you."), "gauge.with.needle"),
            (session("local_demo-docs", "Docs site redesign", "lcu", minutes: 14, detail: "The new layout is in place."), "doc.richtext"),
            (session("local_demo-login", "Fix the login redirect", "lookout", minutes: 6,
                     detail: "Pushed the fix; waiting for CI on the PR."), "arrow.uturn.right"),
            (session("local_demo-schema", "Schema migration", "microsandbox", minutes: 11,
                     detail: "Waiting for the migration session to finish."), "cylinder.split.1x2"),
            (session("local_demo-bump", "Bump the SDK", "lcu", minutes: 20, detail: "Opened the PR; CI is running."), "arrow.up.circle"),
            (session("local_demo-theme", "Router theme fix", "lookout", minutes: 1,
                     detail: "PR #88 is green and ready to merge."), "paintpalette"),
            (session("local_demo-icons", "Fjord icon set", "lookout", minutes: 9,
                     detail: "All 24 icons exported, committed and pushed."), "square.grid.3x3"),
        ]
        for (session, icon) in added {
            store.claudeSessions[session.id] = session
            store.agents.entries.append(AgentEntry(id: session.id, seen: session.activity, focusedAt: session.lastFocused, icon: icon))
        }
        func card(_ session: ClaudeSession, _ triage: RouterTriage, asks: [RouterAsk]? = nil, minutes: Double) -> RouterCard {
            var c = RouterCard(id: "\(session.id)#t\(session.completedTurns)", sessionID: session.id,
                               kind: RouterTriage.kind(blocked: false, triage: triage), title: session.title, folder: session.folder,
                               text: session.summary?.detail ?? "", createdAt: now.addingTimeInterval(-minutes * 60))
            c.triage = triage
            c.asks = asks
            return c
        }
        let s = { (id: String) in store.claudeSessions[id]! }
        var ready = RouterTriage(state: .waiting, urgency: 1, work: .pr, waitingOn: .ci,
                                 watch: .init(target: .ci(thing: "pr:me/lookout#212"), label: "CI on me/lookout#212", ref: "me/lookout#212"))
        ready.ready = .init(result: "passing", at: now.addingTimeInterval(-40))
        store.router.cards += [
            card(s("local_demo-release"), RouterTriage(state: .approval, urgency: 4, work: .committed),
                 asks: [RouterAsk(question: "OK to publish 2.4 to the App Store and push the `v2.4.0` tag?")], minutes: 3),
            card(s("local_demo-api"), RouterTriage(state: .asks, urgency: 3, work: .uncommitted),
                 asks: [RouterAsk(question: "Should the limit be **per API key** or per IP?", options: ["Per API key", "Per IP"]),
                        RouterAsk(question: "Is 100 requests a minute the right default?")], minutes: 8),
            card(s("local_demo-docs"), RouterTriage(state: .done, urgency: 0, unverified: true, work: .committed), minutes: 14),
            card(s("local_demo-login"), ready, minutes: 6),
            card(s("local_demo-schema"), RouterTriage(state: .waiting, urgency: 1, work: .none, waitingOn: .session,
                                                      watch: .init(target: .session(id: "local_demo-lookout", turns: 4),
                                                                   label: "session “Agent completion notifications”")), minutes: 11),
            card(s("local_demo-bump"), RouterTriage(state: .waiting, urgency: 1, work: .pr, waitingOn: .ci), minutes: 20),
        ]
        // A last step left to you, and a turn with nothing in it for you, gone to the history unread (RouterTiers.swift).
        var finish = RouterTriage(state: .done, urgency: 2, work: .pr)
        finish.next = .you
        var settled = RouterTriage(state: .done, urgency: 0, work: .pushed)
        settled.next = .nothing
        var icons = card(s("local_demo-icons"), settled, minutes: 9)
        icons.addressedAt = now.addingTimeInterval(-8 * 60)
        icons.addressedBy = .settled
        icons.unread = true
        icons.brief = "All 24 icons are exported, committed and pushed; nothing left to do."
        var theme = card(s("local_demo-theme"), finish, minutes: 1)
        theme.brief = "PR #88 is green: merge it, then relaunch Fjord to check light mode."
        store.router.cards += [icons, theme]
        if let i = store.router.cards.firstIndex(where: { $0.sessionID == "local_demo-docs" }) {
            store.router.cards[i].brief = "The new docs layout is in, but it wasn't checked on mobile widths."
        }
        // The finished CI turn opened a PR, which its chip says.
        if let i = store.router.cards.firstIndex(where: { $0.sessionID == "local_demo-ci" && $0.isOpen }) {
            store.router.cards[i].triage = RouterTriage(state: .done, urgency: 0, work: .pr)
        }
    }

    /// A day with more projects on top of the triage's: seven projects, some asking, some only running, one quiet. What
    /// the Brief and the busy canvas shots are made on.
    static func routerBusyDay(_ store: Store, now: Date = Date()) {
        routerTriage(store, now: now)
        let added = [
            (session("local_demo-silo-ckpt", "Checkpoint restore over vsock", "silo", minutes: 1, running: true), "externaldrive"),
            (session("local_demo-silo-guest", "Rebase the guest agent branch", "silo", minutes: 5,
                     detail: "Rebased on main; 3 conflicts resolved."), "arrow.triangle.branch"),
            (session("local_demo-silo-rel", "Release v0.9", "silo", minutes: 16,
                     detail: "Tagged; waiting for the release workflow."), "shippingbox"),
            (session("local_demo-site-copy", "Landing page copy", "fjord-site", minutes: 22,
                     detail: "Three headline options drafted."), "text.quote"),
            (session("local_demo-site-og", "Social preview images", "fjord-site", minutes: 1, running: true), "photo"),
            (session("local_demo-zig", "std.fs: walk symlinks", "zig", minutes: 41,
                     detail: "Upstream asks for a test before merging."), "z.circle"),
            (session("local_demo-dots", "Ghostty config cleanup", "dotfiles", minutes: 1, running: true), "terminal"),
        ]
        for (session, icon) in added {
            store.claudeSessions[session.id] = session
            store.agents.entries.append(AgentEntry(id: session.id, seen: session.activity, focusedAt: session.lastFocused, icon: icon))
            if let folder = session.folder { store.agents.assignColor(folder) }
        }
        store.claudeActivity["local_demo-silo-ckpt"] = ClaudeActivity(text: "Running cargo test -p silo-checkpoint",
            since: now.addingTimeInterval(-40), todo: .init(done: 2, total: 5, active: "Restoring a snapshot over vsock"))
        store.claudeActivity["local_demo-site-og"] = ClaudeActivity(text: "Rendering og-image.png", since: now.addingTimeInterval(-15))
        store.claudeActivity["local_demo-dots"] = ClaudeActivity(text: "Editing ghostty/config", since: now.addingTimeInterval(-8))
        let s = { (id: String) in store.claudeSessions[id]! }
        func card(_ session: ClaudeSession, _ triage: RouterTriage, asks: [RouterAsk]? = nil, minutes: Double) -> RouterCard {
            var c = RouterCard(id: "\(session.id)#t\(session.completedTurns)", sessionID: session.id,
                               kind: RouterTriage.kind(blocked: false, triage: triage), title: session.title, folder: session.folder,
                               text: session.summary?.detail ?? "", createdAt: now.addingTimeInterval(-minutes * 60))
            c.triage = triage
            c.asks = asks
            return c
        }
        var copy = card(s("local_demo-site-copy"), RouterTriage(state: .done, urgency: 1, work: .uncommitted), minutes: 22)
        copy.brief = "Three headline options for the landing page; pick one and it ships the page."
        store.router.cards += [
            card(s("local_demo-silo-guest"), RouterTriage(state: .approval, urgency: 4, work: .committed),
                 asks: [RouterAsk(question: "OK to **force-push** the rebased `guest-agent` branch?")], minutes: 5),
            card(s("local_demo-silo-rel"), RouterTriage(state: .waiting, urgency: 1, work: .pushed, waitingOn: .ci), minutes: 16),
            copy,
            card(s("local_demo-zig"), RouterTriage(state: .asks, urgency: 2, work: .pr),
                 asks: [RouterAsk(question: "Add the test to `std/fs/test.zig` or a new file?", options: ["fs/test.zig", "New file"])],
                 minutes: 41),
        ]
        store.router.summaries += [
            RouterSummary(at: now.addingTimeInterval(-60), text: "Restore works for small guests; the 2 GB case is still slow.",
                          sessionID: "local_demo-silo-ckpt", title: "Checkpoint restore over vsock"),
        ]
    }

    /// The Brief over the busy day, as its agent would write it: what's for you, what's worth a look, then each project;
    /// and the five rewrites that led to it (sessions finishing, an answer of yours, a new project), each paragraph's text
    /// chaining from one to the next.
    static func routerDigest(_ store: Store, now: Date = Date()) {
        routerBusyDay(store, now: now)
        func need(_ s: String, _ t: String) -> String { "<need s=\"local_demo-\(s)\">\(t)</need>" }
        func look(_ s: String, _ t: String) -> String { "<look s=\"local_demo-\(s)\">\(t)</look>" }
        func run(_ s: String, _ t: String) -> String { "<run s=\"local_demo-\(s)\">\(t)</run>" }
        func folder(_ name: String) -> String { "/Users/me/code/\(name)" }

        // For you, as each rewrite left it.
        let answers = "\(need("lcu", "how lcu updates install")), \(need("api", "two rate-limit settings")), "
            + "\(need("zig", "where the zig test goes")), and \(need("linux", "a sandbox plan")) to approve."
        let pr = "\(need("theme", "PR #88")) is green"
        let stuck = "\(need("calc", "lcu-research is stuck")) until the VPN is back."
        let twoOKs = "Two OKs first: \(need("release", "publish Fjord 2.4")) and \(need("silo-guest", "force-push silo's guest branch")). "
        let youA = "Quick answers: where sandbox storage lives, \(answers) \(pr). \(stuck)"
        let youB = "Quick answers: \(answers) \(pr). \(stuck)"
        let youC = "One OK first: \(need("silo-guest", "force-push silo's guest branch")). Then quick answers: \(answers) \(pr). \(stuck)"
        let youD = "\(twoOKs)Then quick answers: \(answers) \(pr). \(stuck)"
        let you = "\(twoOKs)Then quick answers: \(answers) \(pr) and \(need("login", "the login fix")) can go on. \(stuck)"

        let lookA = "\(look("docs", "The new lcu docs")) weren't checked on mobile."
        let lookNow = "\(look("docs", "The new lcu docs")) weren't checked on mobile, and "
            + "\(look("site-copy", "three landing-page headlines")) are ready to pick from."

        let tests = "\(run("lookout", "The test suite is running")), nothing has failed so far. The icon set is pushed."
        let theme = "\(need("theme", "PR #88 is green")): merge it, then relaunch to check light mode."
        let lookoutA = "Release 2.4 is building. The login fix waits on CI, and \(theme) \(tests)"
        let lookoutB = "\(need("release", "2.4 is built with its notes")), waiting for your OK to publish and tag it. "
            + "The login fix waits on CI, and \(theme) \(tests)"
        let lookout = "\(need("release", "2.4 is built with its notes")), waiting for your OK to publish and tag it. "
            + "\(need("login", "The login fix passed CI")) and can carry on, and \(theme) \(tests)"

        let sandbox = "\(need("linux", "A plan to run the sandbox in a Firecracker microVM")) is ready for review. "
            + "\(need("api", "The rate limiter")) needs two choices: per API key or per IP, and whether 100 a minute is right. "
            + "\(run("ci", "CI is green")), with two reviewers still reading the changes; "
            + "\(run("schema", "the schema migration")) waits for lookout's tests."
        let sandboxA = "Sandbox storage asks where its cache should live: per project, or shared. \(sandbox)"

        let siloRest = "\(run("silo-ckpt", "Checkpoint restore works")), but the 2 GB case is still slow. "
            + "\(run("silo-rel", "v0.9 is tagged")); its release workflow is running."
        let siloA = "\(run("silo-guest", "Rebasing the guest-agent branch on main.")) \(siloRest)"
        let silo = "\(need("silo-guest", "The guest-agent branch is rebased")) and needs your OK to force-push. \(siloRest)"

        let siteA = "\(run("site-og", "Social previews")) are rendering."
        let site = "\(look("site-copy", "Three headline options")) for the landing page are drafted; picking one ships the page. "
            + siteA

        var digest = RouterDigest(
            forYou: you, worthALook: lookNow,
            projects: [
                .init(folder: folder("lookout"), text: lookout),
                .init(folder: folder("microsandbox"), text: sandbox),
                .init(folder: folder("lcu"), text: "\(need("lcu", "Should updates install silently, or ask first?")) "
                      + "\(look("docs", "The docs redesign is in")), not yet checked on mobile widths. "
                      + "\(run("bump", "The SDK bump")) waits on CI."),
                .init(folder: folder("silo"), text: silo),
                .init(folder: folder("lcu-research"),
                      text: need("calc", "Stuck: the staging database is unreachable while the VPN is down.")),
                .init(folder: folder("zig"), text: "Upstream wants a test before merging the symlink walk: "
                      + need("zig", "in fs/test.zig, or a new file?")),
                .init(folder: folder("fjord-site"), text: site),
                .init(folder: folder("dotfiles"), text: run("dots", "Cleaning up the Ghostty config.")),
            ],
            at: now.addingTimeInterval(-40))
        typealias Change = RouterDigest.Revision.Change
        digest.history = [
            .init(at: now.addingTimeInterval(-40), trigger: .session("local_demo-login"),
                  label: "The login fix passed CI and can go on",
                  why: "CI on me/lookout#212 finished green. The session stopped to wait for it, so it's yours to tell it to go on.",
                  changes: [Change(key: "lead-you", before: youD, after: you),
                            Change(key: folder("lookout"), before: lookoutB, after: lookout)]),
            .init(at: now.addingTimeInterval(-180), trigger: .session("local_demo-release"),
                  label: "Fjord 2.4 is ready to publish",
                  why: "The release session built 2.4 and its notes, and asks your OK before it publishes to the App Store and "
                    + "pushes the v2.4.0 tag. Publishing can't be taken back, so it leads For you.",
                  changes: [Change(key: "lead-you", before: youC, after: youD),
                            Change(key: folder("lookout"), before: lookoutA, after: lookoutB)]),
            .init(at: now.addingTimeInterval(-300), trigger: .session("local_demo-silo-guest"),
                  label: "silo wants an OK to force-push its rebased branch",
                  why: "The rebase on main is done with 3 conflicts resolved. A force-push rewrites the branch others may "
                    + "have pulled, so it asks first.",
                  changes: [Change(key: "lead-you", before: youB, after: youC),
                            Change(key: folder("silo"), before: siloA, after: silo)]),
            .init(at: now.addingTimeInterval(-420), trigger: .you("per project"),
                  label: "You answered where sandbox storage lives",
                  why: "You told the storage session to keep its cache per project. It went on with that, so the question "
                    + "left the brief.",
                  changes: [Change(key: "lead-you", before: youA, after: youB),
                            Change(key: folder("microsandbox"), before: sandboxA, after: sandbox)]),
            .init(at: now.addingTimeInterval(-1320), trigger: .session("local_demo-site-copy"),
                  label: "Three landing-page headlines to pick from",
                  why: "The copy session drafted three headline options. Nothing waits on them, so they're worth a look "
                    + "rather than for you.",
                  changes: [Change(key: "lead-look", before: lookA, after: lookNow),
                            Change(key: folder("fjord-site"), before: siteA, after: site)]),
        ]
        // You last looked four minutes ago: the last two rewrites are new.
        digest.seenAt = now.addingTimeInterval(-240)
        store.routerDigest = digest
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

    /// A session as the Claude app reports it: a finished turn with a summary, or (`running`) mid-turn.
    private static func session(_ id: String, _ title: String, _ folder: String?, minutes: Double, turns: Int = 4,
                                blocked: Bool = false, detail: String = "", running: Bool = false) -> ClaudeSession {
        let at = Date().addingTimeInterval(-minutes * 60)
        return ClaudeSession(id: id, title: title, folder: folder.map { "/Users/me/code/\($0)" }, completedTurns: turns,
                             lastActivity: at, lastFocused: at.addingTimeInterval(-600), lastUserMessage: at.addingTimeInterval(-90),
                             summary: running ? nil : ClaudeSession.Summary(blocked: blocked, detail: detail), running: running)
    }

    /// A session and how Fjord lists it: read or not, with the label or icon it was given.
    private struct Listed {
        var session: ClaudeSession
        var unread = false
        var label: String?
        var icon: String?

        init(_ session: ClaudeSession, unread: Bool = false, label: String? = nil, icon: String? = nil) {
            self.session = session
            self.unread = unread
            self.label = label
            self.icon = icon
        }
    }

    /// The Router's reading of Claude's sessions, on, with these sessions. `colors` pins each project's colour; the others get the
    /// least used one, in listing order. `unlisted` are known to the app but without an entry: only found by search.
    private static func sessions(_ store: Store, _ now: Date, _ listed: [Listed], activity: [String: ClaudeActivity] = [:],
                                 tasks: [String: [ClaudeTask]] = [:], colors: [String: Int] = [:],
                                 unlisted: [ClaudeSession] = []) {
        store.claudeSessions = Dictionary(uniqueKeysWithValues: (listed.map(\.session) + unlisted).map { ($0.id, $0) })
        store.claudeLink = .ok
        store.claudeActivity = activity
        store.claudeTasks = tasks
        var state = AgentsState()
        state.folderColors = colors
        for folder in listed.compactMap(\.session.folder) { state.assignColor(folder) }
        state.enabled = true
        state.enabledAt = now.addingTimeInterval(-86400)
        state.seeded = true
        state.iconsEnabled = true
        state.entries = listed.map { l in
            AgentEntry(id: l.session.id, label: l.label, unread: l.unread, seen: l.session.activity,
                       focusedAt: l.session.lastFocused, icon: l.icon)
        }
        store.agents = state
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
        sessions(store, now, listed, activity: ["local_demo-lookout": ClaudeActivity(
                    text: "Running swift test", since: now.addingTimeInterval(-20),
                    todo: .init(done: 3, total: 7, active: "Running the test suite"))],
                 tasks: ["local_demo-ci": [
                    ClaudeTask(id: "a1", kind: .agent, title: "Review the sandbox changes", since: now.addingTimeInterval(-190),
                               activity: ClaudeActivity(text: "Reading sandbox.rs", since: now.addingTimeInterval(-5))),
                    ClaudeTask(id: "a2", kind: .agent, title: "Check the other CI jobs", since: now.addingTimeInterval(-70),
                               activity: ClaudeActivity(text: "Thinking", since: now.addingTimeInterval(-2))),
                    ClaudeTask(id: "b1", kind: .command, title: "Run the full test suite", since: now.addingTimeInterval(-370)),
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

/// `--claude`: what the Router reads of Claude's sessions from the desktop app right now.
@MainActor
enum ClaudeCheck {
    static func run() {
        var start = Date()
        let result = Claude.SessionReader().read()
        let sessionsMS = Int(Date().timeIntervalSince(start) * 1000)
        start = Date()
        let unread = Claude.unreadIDs()
        print("installed:", Claude.isInstalled, "running:", Claude.isRunning, "sessions read in", sessionsMS, "ms, dots in",
              Int(Date().timeIntervalSince(start) * 1000), "ms")
        switch result {
        case .failure(let error): print("sessions:", error)
        case .success(let sessions):
            print("sessions:", sessions.count, "archived:", sessions.filter(\.isArchived).count)
            for s in sessions.filter({ !$0.isArchived }).sorted(by: { $0.lastActivity > $1.lastActivity }).prefix(12) {
                let state = s.running ? "running" : s.summary?.blocked == true ? "blocked" : s.summary == nil ? "-" : "done"
                print(String(format: "%-8@ %-7@ %-5@ turns=%-4d %@ · %@", state, shortAgo(s.lastActivity),
                             unread?.contains(s.id) == true ? "dot" : "", s.completedTurns, s.title, s.folderName))
            }
        }
        print("unread dots:", unread.map { "\($0.count)" } ?? "unreadable")
        if case .success(let sessions) = result {
            let reader = Claude.ActivityReader()
            for s in sessions where s.running {
                print("  working:", s.title, "→", s.cliID.flatMap { reader.activity(for: $0) }.map { "\($0.text) (since \(shortAgo($0.since)))" } ?? "no transcript")
            }
            let folders = Claude.taskFolders()
            let open = Claude.openTaskOutputs()
            let tasks = Claude.TaskReader()
            for s in sessions where !s.running && !s.isArchived {
                guard let cli = s.cliID, let folder = folders[cli] else { continue }
                for t in tasks.tasks(in: folder, transcript: reader.transcript(cli), openOutputs: open) {
                    print("  background:", s.title, "→", t.kind == .agent ? "agent" : "command", t.title,
                          t.activity.map { "(\($0.text))" } ?? "", "since \(shortAgo(t.since))")
                }
            }
        }
        if CommandLine.arguments.contains("--watch") { watch(); return }
        if case .success(let sessions) = result, let unread {
            for s in sessions where unread.contains(s.id) { print("  dot:", s.title, s.isArchived ? "(archived)" : "", shortAgo(s.lastActivity)) }
        }
        exit(0)
    }

    /// `--claude --watch`: the extension live against the real app, nothing saved; prints every change.
    private static var watchers: [FolderWatcher] = []

    private static func watch() {
        let store = Store()
        store.persists = false
        store.agents.enabled = true
        store.agents.enabledAt = Date()
        var last = ""
        func dump(_ reason: String) {
            store.refreshClaude()
            let lines = store.allAgentRows.map { r in
                "\(r.label) \(r.unread ? "UNREAD" : "read  ") \(String(describing: r.group).padding(toLength: 8, withPad: " ", startingAt: 0)) \(r.session.title)"
            }
            let text = lines.joined(separator: "\n")
            guard text != last else { return }
            last = text
            print("--- \(Date().formatted(date: .omitted, time: .standard)) (\(reason))\n" + text)
            fflush(stdout)
        }
        dump("start")
        // Held for the life of the process (the run loop never returns), so the stream keeps delivering.
        watchers.append(FolderWatcher([Claude.sessionsDir, Claude.localStorageDir]) { MainActor.assumeIsolated { dump("files") } })
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { dump("timer") } }
    }
}
