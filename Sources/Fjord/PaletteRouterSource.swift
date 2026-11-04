import Foundation

// The palette's source for Router: the cards waiting on you, the other open cards, every session, their actions, and the
// send-to-the-Router row (docs/design/palette/DESIGN.md, jobs 1–3). Nothing at all while the Router is off.

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

    /// What the palette finds in the Router: one pass over the cards and the sessions, with the lookups the rows share (a
    /// session's open card, a session's linked PR) built once. Runs once per open, on the main actor.
    static func make(_ context: PaletteContext) -> PaletteSourceOutput {
        let store = context.store
        guard store.routerOn else { return PaletteSourceOutput() }
        let page = store.routerZones
        let now = Date()
        let rows = Dictionary(store.allAgentRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let links = Links(store)

        // The Needs-you zone: what stops a session on you first (questions, plans, asks, OKs, a wait that is over), then what
        // is stuck or left to finish; oldest first within each.
        let ready = Set(page.ready.map(\.id))
        let needing = (page.needs + page.ready).sorted {
            let (a, b) = (urgency($0, ready: ready), urgency($1, ready: ready))
            return a != b ? a < b : $0.createdMs < $1.createdMs
        }
        let needingIDs = Set(needing.map(\.id))
        let others = (page.notes + page.waiting).filter { !needingIDs.contains($0.id) }

        let working = Set(page.working.map(\.id))

        // A session's card to show it with: the newest of those on the page.
        var openCard: [String: RouterCard] = [:]
        for card in needing + others where card.createdMs >= (openCard[card.sessionID]?.createdMs ?? .min) {
            openCard[card.sessionID] = card
        }

        var output = PaletteSourceOutput()
        output.needsYou = needing.map { card in
            cardItem(card, needsYou: true, context: context, running: rows[card.sessionID]?.session.running == true, links: links)
        }
        output.items = output.needsYou + others.map { card in
            cardItem(card, needsYou: false, context: context, running: rows[card.sessionID]?.session.running == true, links: links)
        }
        output.items += store.claudeSessions.values.map { session in
            sessionItem(session, row: rows[session.id], card: openCard[session.id], working: working.contains(session.id), now: now,
                        context: context, links: links)
        }
        return output
    }
}

// MARK: - Cards

extension PaletteRouterSource {
    private static func cardItem(_ card: RouterCard, needsYou: Bool, context: PaletteContext, running: Bool,
                                 links: Links) -> PaletteItem {
        let store = context.store
        let model = context.routerModel
        let project = store.routerProject(card).name
        let label = card.kind.label
        var keywords = [label, project]
        if let line = firstLine(card.text) { keywords.append(line) }
        if let brief = card.brief, !brief.isEmpty { keywords.append(brief) }
        if let origin = card.origin { keywords.append(origin.thing) }
        let thing = links.thing(card)
        if let thing { keywords += links.keywords(thing) }

        var actions = [
            PaletteAction(id: "show", title: "Show in Router", symbol: "rectangle.stack") {
                model.select(card.id, store: store)
                context.go(.router)
            },
            PaletteAction(id: "reply", title: "Reply", symbol: "arrowshape.turn.up.left", caps: ["↩"]) {
                model.reply(to: card.id, store: store)
                context.go(.router)
            },
            PaletteAction(id: "open", title: "Open in Claude", symbol: "arrow.up.forward.app") {
                store.openCard(card.id)
            },
        ]
        if let thing { actions.append(linkAction(thing, context)) }
        actions.append(PaletteAction(id: "archive", title: "Archive", symbol: "archivebox", destructive: true) {
            model.address(card.id, store: store)
        })

        return PaletteItem(id: "card:" + card.id, kind: .card, title: store.claudeSessions[card.sessionID]?.title ?? card.title,
                           subtitle: label + " · " + project, keywords: keywords, icon: .session(card.sessionID),
                           dot: needsYou ? .attention : running ? .running : nil, date: card.createdAt,
                           weight: needsYou ? Weight.needsYou : Weight.open, actions: actions)
    }

    /// 0 for what stops a session on you (a question, a plan, asks, an OK, a wait that is over), 1 for stuck turns and last
    /// steps.
    private static func urgency(_ card: RouterCard, ready: Set<String>) -> Int {
        switch card.kind {
        case .stuck, .finish, .done: 1
        case .waiting: ready.contains(card.id) ? 0 : 1
        default: 0
        }
    }

    /// The first line of a card's text with something in it, cut to what a keyword needs.
    private static func firstLine(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return String(line.prefix(200))
    }
}

// MARK: - Sessions

extension PaletteRouterSource {
    private static func sessionItem(_ session: ClaudeSession, row: AgentRow?, card: RouterCard?, working: Bool, now: Date,
                                    context: PaletteContext, links: Links) -> PaletteItem {
        let store = context.store
        let model = context.routerModel
        let id = session.id
        let project = row?.projectName ?? session.folderName
        var keywords = [project]
        if project != session.folderName { keywords.append(session.folderName) }
        if let folder = session.folder, !folder.isEmpty { keywords.append(folder) }
        let thing = links.thing(session: id)
        if let thing { keywords += links.keywords(thing) }

        let open = PaletteAction(id: "open", title: "Open in Claude", symbol: "arrow.up.forward.app") { store.openAgent(id) }
        // On the Router's page (a card, or a Working row) it is shown there first; elsewhere, opening it in Claude is it.
        var actions: [PaletteAction] = []
        if card != nil || working {
            actions.append(PaletteAction(id: "show", title: "Show in Router", symbol: "rectangle.stack") { showSession(id, context) })
        }
        actions.append(open)
        if session.running {
            actions.append(PaletteAction(id: "summary", title: "Summary", symbol: "text.alignleft") {
                model.summarizer.request(id, store: store)
            })
        }
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

// MARK: - Showing a session

extension PaletteRouterSource {
    /// Shows a session in the window as the Router has it: its newest card if the page draws one (picked, as a click does);
    /// else its Working row, with the page brought to where it is seen; else opens it in Claude. Works out what is drawn
    /// now, not when the palette opened.
    static func showSession(_ sessionID: String, _ context: PaletteContext) {
        let store = context.store
        let model = context.routerModel
        let page = store.routerZones
        let drawn = (page.needs + page.ready + page.notes + page.waiting).filter { $0.sessionID == sessionID }
        if let card = drawn.max(by: { $0.createdMs < $1.createdMs }) {
            model.select(card.id, store: store)
            context.go(.router)
        } else if page.working.contains(where: { $0.id == sessionID }) {
            // Seen only on Now, with its state chip on, its section open and no search leaving it out.
            if model.searching, !model.zones(store).working.contains(where: { $0.id == sessionID }) { model.endSearch() }
            model.show(.now)
            model.filter.reveal(.working)
            model.setFolded(.working, false)
            context.go(.router)
            model.reveal(RouterModel.workingID(sessionID))
        } else {
            store.openAgent(sessionID)
        }
    }
}

// MARK: - Items and sessions that belong together

extension PaletteRouterSource {
    /// Which inbox thing each session belongs with, from what Fjord knows: a Triage action that handed the thing to the
    /// session (`ActionLedger`), a waiting card whose watch is the thing's CI. Built once per open; a thing no longer
    /// fetched links nothing.
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
            for card in store.router.cards where card.isOpen {
                if case .ci(let thing)? = card.triage?.watch?.target { bySession[card.sessionID] = thing }
            }
        }

        func thing(session: String) -> Thing? { bySession[session].flatMap { store.things[$0] } }

        /// The card's own watch first, else the session's link.
        func thing(_ card: RouterCard) -> Thing? {
            if case .ci(let id)? = card.triage?.watch?.target, let thing = store.things[id] { return thing }
            return thing(session: card.sessionID)
        }

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
