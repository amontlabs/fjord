import Foundation

// The Router v2 page on T3's threads (docs/design/router-v2/IMPLEMENTATION.md, track 9a): the record store, the verdict
// engine, the reader, the acts, the launch feed and the pull requests, made once per app run and wired to each other and
// to the page model. T3's events reach the records first (`wireThreads`), and the records hand the page what changed.

extension Store {
    // MARK: Making them

    /// Where the page's files go: a test's own folder, or none in a test that named none (it never reaches the user's).
    var routerPageFiles: RouterPaths? { routerPaths ?? (UnderTest.isRunning ? nil : routerFiles) }

    func makeRouterRecords() -> RouterRecords {
        routerRecordsMade = true
        let file = routerPageFiles.map { RouterVerdictFile.live($0.support) }
        // A small file, read once before the first record is composed.
        let saved = file.flatMap { try? Data(contentsOf: $0.url) }.map(RouterVerdictFile.decode) ?? [:]
        let records = RouterRecords(saved: saved, file: file, gate: motionGate)
        records.rows = { [weak self] in self?.t3.store.shell ?? T3ShellState() }
        records.projectName = { [weak self] t in
            guard let self, t.folder != nil else { return nil }
            return self.projectName(of: t)
        }
        records.firstAsk = { [weak self] id in self?.firstMessages[id] }
        records.pullRequests = { [weak self] t, reply in self?.routerPullRequests.states(for: t, reply: reply) ?? RouterRecords.linked(t) }
        // The model calls run only with the Router on, and never in a demo.
        records.canAsk = { [weak self] in self.map { $0.routerOn && !$0.routerIsPretend } ?? false }
        records.ask = { [weak self] request in
            guard let self, self.routerOn, !self.routerIsPretend else { return }
            self.routerVerdicts.ask(request)
        }
        records.cancel = { [weak self] thread in self?.routerVerdicts.cancel(thread) }
        records.cancelSummary = { [weak self] thread in self?.routerVerdicts.cancelSummary(thread) }
        records.fetch = { [weak self] thread, key in self?.routerTurnReads.read(thread, key: key) }
        records.onNeedsYou = { [weak self] n in if self?.routerNeedsYou != n { self?.routerNeedsYou = n } }
        records.emit = { [weak self] change in self?.routerPage.post(change) }
        let notifier = RouterNotifier()
        notifier.post = { [weak self] n in
            guard let self else { return }
            self.notifyRouter(id: Self.routerNotice(n), title: "\(self.routerProjectName(n.project)) · \(n.heading)", subtitle: n.title, body: n.body)
        }
        notifier.postMany = { [weak self] all in
            guard let self, let first = all.first else { return }
            self.notifyRouter(id: Self.routerNotice(first), title: "\(all.count) threads have news",
                              subtitle: Set(all.map { self.routerProjectName($0.project) }).sorted().joined(separator: ", "), body: "")
        }
        records.notifier = notifier
        return records
    }

    func makeRouterPage() -> RouterModel {
        let page = RouterModel()
        // The real clock, not the demo's 14:02.
        page.clockStart = page.made
        page.source = routerActs
        page.apply(routerRecords.snapshot())
        return page
    }

    func makeRouterTurnReads() -> RouterTurnReads {
        let reads = RouterTurnReads(read: { [weak self] id in await self?.t3.store.readSnapshot(id) })
        reads.done = { [weak self] id, key, projection in
            self?.routerRecords.read(id, key: key, projection.map { RouterDetail.make($0, now: Date()) })
        }
        return reads
    }

    func makeRouterVerdicts() -> RouterVerdicts {
        let verdicts = RouterVerdicts(binary: { [weak self] in
            guard let self else { return nil }
            if let binary = self.routerClaudeBinary { return binary() }
            return self.routerStatus.latestPath()
        })
        verdicts.onEvent = { [weak self] thread, fingerprint, event in
            self?.routerRecords.verdict(thread, fingerprint: fingerprint, event)
        }
        verdicts.onSummary = { [weak self] thread, fingerprint, event in
            self?.routerRecords.summary(thread, fingerprint: fingerprint, event)
        }
        return verdicts
    }

    func makeRouterReader() -> RouterReader {
        let reader = RouterReader()
        // Each pause, start, skip and cancel, counts only (no text), into the decision log: what the pauses are tuned from.
        reader.log = Store.isDemo ? nil : routerDispatcher.decisionLog
        reader.jev = { [weak self] text, tagged in await self?.readDraft(text, tagged: tagged) }
        reader.decide = { [weak self] text, tagged, selected, reuse in
            await self?.decideDraft(text, tagged: tagged, notTo: nil, reuse: reuse, open: selected)
        }
        reader.search = { [weak self] text in await self?.searchDraft(text) ?? [] }
        reader.boardKey = { [weak self] in self?.deciderBoardKey() ?? "" }
        reader.eligible = { [weak self] target in self.map { $0.routerDispatcher.eligible(target, store: $0) } ?? false }
        reader.allowed = { [weak self] in self?.previewsDrafts == true }
        reader.tagged = { [weak self] mentions in self.flatMap { RouterPointers.context(mentions, store: $0) } }
        reader.onRead = { [weak self] read, decision in
            guard let self else { return }
            self.routerLastDecision = decision.map { (read.draft, $0) }
            self.routerPage.post(.read(self.routerNamed(read)))
        }
        return reader
    }

    func makeRouterLaunch() -> RouterLaunchFeed {
        let feed = RouterLaunchFeed(config: { [weak self] in
            guard let self else { throw ThreadLaunchFailure("Fjord isn't ready") }
            return try await self.launchSupport.config()
        })
        feed.emit = { [weak self] change in
            guard let self else { return }
            if case .launch(_, let models) = change { self.routerActs.models = models }
            self.routerPage.post(change)
        }
        return feed
    }

    func makeRouterPullRequests() -> RouterPullRequests {
        let link: RouterPullRequests.Link = { [weak self] thread, url in
            guard let self else { throw ThreadSendFailure("Fjord isn't ready") }
            try await self.dispatch(.pullRequestLink(threadId: thread, url: url))
        }
        let github = UnderTest.isRunning || Store.isDemo ? nil : PullRequestStates(client: gh)
        let prs = RouterPullRequests(link: link, github: github)
        prs.onChange = { [weak self] id in
            guard let self, let t = self.threads[id] else { return }
            self.routerRecords.put(t)
        }
        return prs
    }

    // MARK: Wiring

    /// Ties the page's parts together, once: the acts' reader and decision log, the project purposes. The page model
    /// itself is made on first use (`routerPage`) with the records' snapshot.
    func wireRouter() {
        let acts = routerActs
        acts.reader = { [weak self] draft, selected, mentions in
            self?.routerReader.read(draft, selected: selected, mentions: mentions)
        }
        acts.decision = { [weak self] draft in
            guard let last = self?.routerLastDecision, last.draft == draft else { return nil }
            return last.decision
        }
        if routerPurposes == nil, !Store.isDemo {
            routerPurposes = ProjectPurposes(verdicts: routerVerdicts, url: ProjectPurposes.live(routerPageFiles))
        }
    }

    /// A shell change reaches the records first (one row, at most one change for the page), then the rest of the app.
    func routerShellChanged(_ item: T3ShellItem?) {
        if agents.enabled { routerRecords.shell(item) }
        if case .synchronized? = item {
            routerPurposes?.keep(only: Set(t3.store.shell.projects.keys))
        }
    }

    /// A watched thread's projection changed: its detail for its record, and a steer that landed in a run ends.
    func routerThreadChanged(_ id: String) {
        guard agents.enabled else { return }
        guard let projection = t3.store.projections[id] else {
            routerRecords.detail(id, nil)
            return
        }
        // A cancel waiting for its queued run hides it before the record shows it.
        routerActs.threadChanged(id)
        routerRecords.detail(id, RouterDetail.make(projection, now: Date()))
        // The newest message sent into a run of this thread's: it is in the run now (or the run is over).
        if let sent = router.decisions.last(where: { $0.delivered?.thread == id })?.delivered, sent.outcome == .steered {
            switch delivery(sent) {
            case .working, .over: routerRecords.delivered(id, sentAt: sent.at)
            case .queued, .unknown: break
            }
        }
    }

    func routerConnectionChanged(_ state: T3ConnectionState) {
        routerRecords.connection(state)
        switch state {
        case .connected: routerLaunch.connected()
        case .connecting, .idle: break
        default: routerLaunch.disconnected()
        }
    }

    /// History's "write to this thread", a banner, the bar's "open this entry": the thread's line, selected (its card
    /// open), when it has one.
    func routerFocus(_ thread: String) {
        let page = RouterDemo.model ?? routerPage
        guard page.thread(thread) != nil else { return }
        page.select(.line(thread))
    }

    // MARK: Helpers

    /// Router banners' ids: `router:<target key>`, so a click opens the thread's line (`onOpenRouterLine`).
    nonisolated static let routerNoticePrefix = "router:"

    static func routerNotice(_ n: ThreadNotice) -> String {
        routerNoticePrefix + ThreadTarget(project: n.project, thread: n.thread).key
    }

    /// A read as the page shows it: a new thread's project by the name its lines and pills have, not T3's id.
    func routerNamed(_ read: RouterRead) -> RouterRead {
        var read = read
        read.places = read.places.map { place in
            guard case .newThread(let project) = place, t3.store.shell.projects[project] != nil else { return place }
            return .newThread(project: routerProjectName(project))
        }
        return read
    }

    /// A project as a banner names it: T3's title, else its folder's name.
    func routerProjectName(_ project: String) -> String {
        if let p = t3.store.shell.projects[project] {
            return p.title.nonEmpty ?? folderName(p.workspaceRoot)
        }
        return project
    }

    /// A thread's project as the owner named it in T3, which can differ from its folder's name; the folder's name only
    /// when T3 doesn't give one.
    func projectName(of t: AgentThread) -> String {
        t3.store.shell.projects[t.projectID]?.title.nonEmpty ?? folderName(t.folderKey)
    }
}
