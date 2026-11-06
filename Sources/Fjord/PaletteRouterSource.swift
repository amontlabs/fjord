import Foundation

// The palette's source for Router: the brief's entries waiting on you, then the threads touched in the last 24 hours, every
// session and their actions, and the send-to-the-Router row (docs/design/palette/DESIGN.md, jobs 1–3). Nothing at all while
// the Router is off.

@MainActor
enum PaletteRouterSource {
    /// How much a source vouches for each kind of row among equal matches (`PaletteItem.weight`).
    private enum Weight {
        static let needsYou = 1.3
        static let open = 1.1
        static let today = 1.1
        static let thisWeek = 1.0
        static let older = 0.8
    }

    /// What the palette finds in the Router: one pass over the brief and the sessions, with the lookups the rows share (a
    /// session's linked PR) built once. Runs once per open, on the main actor.
    static func make(_ context: PaletteContext) -> PaletteSourceOutput {
        let store = context.store
        guard store.routerOn else { return PaletteSourceOutput() }
        let page = store.routerBriefs.page()
        let now = Date()
        let rows = Dictionary(store.allAgentRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let links = Links(store)

        var output = PaletteSourceOutput()
        output.needsYou = page.sections.flatMap { s in s.entries.map { entryItem($0, section: s, context: context) } }
        let recent = page.sections.flatMap { s in s.recent.map { threadItem($0, section: s, context: context) } }
        output.items = output.needsYou + recent
        output.items += store.claudeSessions.values.map { session in
            sessionItem(session, row: rows[session.id], now: now, context: context, links: links)
        }
        return output
    }
}

// MARK: - Entries and threads

extension PaletteRouterSource {
    private static func entryItem(_ e: BriefEntry, section: BriefPage.Section, context: PaletteContext) -> PaletteItem {
        let store = context.store
        let briefs = store.routerBriefs
        let t = e.target
        let label = BriefEntryText.kindLabel(e)
        var keywords = [label, section.name]
        if let q = e.question, !q.isEmpty { keywords.append(String(q.prefix(200))) }
        let actions = [
            PaletteAction(id: "show", title: "Show in Router", symbol: "rectangle.stack") {
                briefs.focus(t)
                context.go(.router)
            },
            PaletteAction(id: "reply", title: "Reply", symbol: "arrowshape.turn.up.left", caps: ["↩"]) {
                briefs.focus(t)
                context.routerModel.reply()
                context.go(.router)
            },
            PaletteAction(id: "open", title: "Open in Claude", symbol: ClaudeMark.openSymbol) {
                briefs.open(t, store: store)
            },
            PaletteAction(id: "read", title: "Mark read", symbol: "checkmark.circle") { briefs.markRead(t, store: store) },
            PaletteAction(id: "archive", title: "Archive", symbol: "archivebox", destructive: true) { briefs.archive(t, store: store) },
        ]
        return PaletteItem(id: "thread:" + t.key, kind: .thread, title: briefs.title(t), subtitle: label + " · " + section.name,
                           keywords: keywords, icon: .symbol(BriefEntryText.symbol(e.kind)), dot: .attention,
                           date: Date(timeIntervalSince1970: e.since), weight: Weight.needsYou, actions: actions)
    }

    private static func threadItem(_ th: BriefThread, section: BriefPage.Section, context: PaletteContext) -> PaletteItem {
        let store = context.store
        let briefs = store.routerBriefs
        let t = BriefTarget(project: section.id, thread: th.id)
        let word = BriefThreadWord.word(th.status)
        let actions = [
            PaletteAction(id: "open", title: "Open in Claude", symbol: ClaudeMark.openSymbol) {
                briefs.open(t, store: store)
            },
            PaletteAction(id: "reply", title: "Reply", symbol: "arrowshape.turn.up.left") {
                briefs.focus(t)
                context.routerModel.reply()
                context.go(.router)
            },
        ]
        return PaletteItem(id: "thread:" + t.key, kind: .thread, title: th.title.nonEmpty ?? "Untitled thread",
                           subtitle: word + " · " + section.name, keywords: [word, section.name], icon: .symbol("bubble.left"),
                           dot: th.status == .working ? .running : nil, date: Date(timeIntervalSince1970: th.age),
                           weight: Weight.open, actions: actions)
    }
}

// MARK: - Sessions

extension PaletteRouterSource {
    private static func sessionItem(_ session: ClaudeSession, row: AgentRow?, now: Date, context: PaletteContext,
                                    links: Links) -> PaletteItem {
        let store = context.store
        let id = session.id
        let project = row?.projectName ?? session.folderName
        var keywords = [project]
        if project != session.folderName { keywords.append(session.folderName) }
        if let folder = session.folder, !folder.isEmpty { keywords.append(folder) }
        let thing = links.thing(session: id)
        if let thing { keywords += links.keywords(thing) }

        var actions = [PaletteAction(id: "open", title: "Open in Claude", symbol: ClaudeMark.openSymbol) { store.openAgent(id) }]
        if let thing { actions.append(linkAction(thing, context)) }

        var subtitle = project
        if session.running { subtitle += " · Working" }

        let age = now.timeIntervalSince(session.lastActivity)
        let weight = age < 86_400 ? Weight.today : age < 7 * 86_400 ? Weight.thisWeek : Weight.older
        return PaletteItem(id: "session:" + id, kind: .session, title: session.title, subtitle: subtitle, keywords: keywords,
                           icon: .session(id), dot: row?.waitsForYou == true ? .attention : session.running ? .running : nil,
                           date: session.lastActivity, weight: weight, actions: actions)
    }
}

// MARK: - Items and sessions that belong together

extension PaletteRouterSource {
    /// Which inbox thing each session belongs with, from what Fjord knows: a Triage action that handed the thing to the
    /// session (`ActionLedger`). Built once per open; a thing no longer fetched links nothing.
    @MainActor
    private struct Links {
        private let store: Store
        private var bySession: [String: String] = [:]

        init(_ store: Store) {
            self.store = store
            var latest: [String: Date] = [:]
            for run in store.actionLedger.runs.values {
                guard let session = run.sessionID, !run.thing.isEmpty, run.at >= (latest[session] ?? .distantPast) else { continue }
                latest[session] = run.at
                bySession[session] = run.thing
            }
        }

        func thing(session: String) -> Thing? { bySession[session].flatMap { store.things[$0] } }

        /// What typing the PR's number finds the session by: `owner/repo#482` and `#482`.
        func keywords(_ thing: Thing) -> [String] {
            guard let number = thing.number else { return [thing.repo] }
            return ["\(thing.repo)#\(number)", "#\(number)"]
        }
    }

    /// Shows the thing in the window, on its category (the archive if it is archived); where it can't be (Triage is off or
    /// its category hidden) it opens on GitHub.
    private static func linkAction(_ thing: Thing, _ context: PaletteContext) -> PaletteAction {
        let store = context.store
        let hub = context.hub
        let title: String
        let symbol: String
        switch thing.kind {
        case .pr: (title, symbol) = ("Open the PR", "arrow.triangle.pull")
        case .issue: (title, symbol) = ("Open the issue", "exclamationmark.circle")
        case .workflow: (title, symbol) = ("Show the workflow", "bolt.circle")
        }
        return PaletteAction(id: "thing", title: title, symbol: symbol) {
            guard let entry = store.entries.first(where: { $0.id == thing.id }) else { return Link.open(thing.url) }
            let shown = store.triageOn && (entry.isDone || store.categories.first { $0.id == entry.categoryID }?.hidden == false)
            guard shown else { return store.open(entry) }
            hub.selection = "i:" + entry.id
            context.go(entry.isDone ? .done : .category(entry.categoryID))
            hub.requestScroll("i:" + entry.id)
        }
    }
}

// MARK: - Send

extension PaletteRouterSource {
    /// The last row while typing: send what is typed to the Router, which picks the session. Nil when the Router can't
    /// send (off, Claude Code not found) or the query is blank.
    static func send(_ query: String, _ context: PaletteContext) -> PaletteItem? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, context.routerModel.canSend(context.store) else { return nil }
        let shown = text.count > 80 ? String(text.prefix(80)).trimmingCharacters(in: .whitespaces) + "…" : text
        let store = context.store
        return PaletteItem(id: "send:router", kind: .send, title: "Send to the Router", subtitle: "“" + shown + "”",
                           icon: .symbol("arrow.up.circle"),
                           actions: [PaletteAction(id: "send", title: "Send to the Router", symbol: "arrow.up.circle") {
                               store.sendToRouter(text)
                               context.go(.router)
                           }])
    }
}
