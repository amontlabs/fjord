import AppKit
import Carbon
import Foundation
import Testing
@testable import Fjord

/// The Router's search: what it matches, what it leaves on the page and in the history, and the keys over it.
@MainActor
@Suite struct RouterSearchTests {
    private func demo() -> Store {
        let store = Store()
        Demo.populate(store, .router)
        store.interceptOpen = { _ in }
        return store
    }

    private func key(_ code: Int, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    /// A word of `text` long enough to stand out.
    private func word(_ text: String) -> String {
        text.split(whereSeparator: { !$0.isLetter }).map(String.init).max { $0.count < $1.count } ?? text
    }

    @Test func everyWordMustMatchInAnyCase() {
        var card = RouterCard(id: "s#t1", sessionID: "s", kind: .question, title: "Fix the login flow", folder: "/code/web",
                              text: "Which provider?", createdAt: Date())
        card.brief = "Asks which OAuth provider to use"
        card.asks = [RouterAsk(question: "Which provider?", options: ["Google", "GitHub"])]
        let key = RouterSearch.key(card, project: "web")
        #expect(RouterSearch.matches(key, RouterSearch.words("LOGIN web")))
        #expect(RouterSearch.matches(key, RouterSearch.words("oauth github")))
        #expect(RouterSearch.matches(key, RouterSearch.words("question")))
        #expect(!RouterSearch.matches(key, RouterSearch.words("login billing")))
        #expect(RouterSearch.words("  \t ").isEmpty)
    }

    @Test func aSearchFiltersEachSectionOfNowAndTheHistory() throws {
        let store = demo()
        Demo.routerTriage(store)
        let model = RouterModel()
        let all = store.routerZones
        let need = try #require(all.needs.first)
        // The session's title and its project, typed in another case: the card stays, and only what matches both.
        model.search.query = word(need.title).uppercased() + " " + store.routerProject(need).name.lowercased()
        let page = model.zones(store)
        #expect(page.needs.contains(need))
        let words = RouterSearch.words(model.search.query)
        for card in page.needs + page.ready + page.notes + page.waiting {
            #expect(RouterSearch.matches(RouterSearch.key(card, project: store.routerProject(card).name), words))
        }
        #expect(page.count(.needs) + page.count(.notes) + page.count(.waiting) + page.count(.working)
                < all.count(.needs) + all.count(.notes) + all.count(.waiting) + all.count(.working))
        // A word nothing holds: Now and the history are empty.
        model.search.query = "zzqxv"
        let none = model.zones(store)
        #expect(RouterZone.allCases.allSatisfy { none.count($0) == 0 })
        #expect(model.history(store).isEmpty && model.cards(store).isEmpty)
        // A working session is found by its title.
        let row = try #require(all.working.first)
        model.search.query = row.session.title
        #expect(model.zones(store).working.contains { $0.id == row.id })
        // No words: everything.
        model.search.query = "   "
        #expect(!model.searching && model.zones(store) == all && model.history(store) == store.routerHistory)
    }

    @Test func historyLinesAreFoundByWhatTheyShow() throws {
        let store = demo()
        let model = RouterModel()
        let history = store.routerHistory
        let run = try #require(history.first { if case .decision(let d) = $0, case .you = d.trigger { true } else { false } })
        guard case .decision(let decision) = run else { return }
        model.search.query = word(decision.triggerText)
        let found = model.history(store)
        #expect(found.contains(run) && found.count <= history.count)
        let addressed = try #require(history.first { if case .card = $0 { true } else { false } })
        guard case .card(let card) = addressed else { return }
        model.search.query = card.title
        #expect(model.history(store).contains(addressed))
    }

    @Test func theKeysWalkOnlyWhatTheSearchListsAndAPickItHidesIsDropped() throws {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model)
        let open = model.cards(store).filter(\.isOpen)
        try #require(open.count >= 2)
        let kept = open[1], hidden = open[0]
        // Picked and replied to, then a search that leaves it out: the pick goes, and the reply with it.
        model.select(hidden.id, store: store)
        #expect(model.selection == hidden.id && model.replyTo == hidden.id)
        model.search.query = kept.title
        try #require(!model.matchesSearch(hidden, store: store))
        model.searchChanged(store: store)
        #expect(model.selection == nil && model.replyTo == nil)
        // The arrows walk only what is listed.
        let listed = model.cards(store).map(\.id)
        #expect(listed.contains(kept.id) && !listed.contains(hidden.id))
        for _ in 0..<(listed.count + 1) {
            #expect(keys.key(key(kVK_DownArrow), responder: nil))
            #expect(listed.contains(model.selection ?? ""))
        }
        // A card the search hides, picked from elsewhere (a banner): the search ends so it shows.
        model.select(hidden.id, store: store)
        #expect(model.search.query.isEmpty && model.selection == hidden.id)
    }

    @Test func theUnreadFilterListsWhatIsUnreadAndKeepsALineReadUnderIt() throws {
        let store = demo()
        let model = RouterModel()
        var state = store.router
        // Three cards in the history: one more addressed.
        if let i = state.cards.firstIndex(where: \.isOpen) { state.cards[i].addressedAt = Date() }
        let addressed = state.cards.indices.filter { !state.cards[$0].isOpen }
        try #require(addressed.count >= 3)
        for i in addressed { state.cards[i].unread = nil }
        state.cards[addressed[0]].unread = true
        state.cards[addressed[1]].unread = true
        store.router = state
        let a = state.cards[addressed[0]].id, b = state.cards[addressed[1]].id, read = state.cards[addressed[2]].id
        let ids = { model.history(store).map(\.id) }
        #expect(ids() == store.routerHistory.map(\.id))
        // On: the unread cards only, no runs or summaries; the keys walk only those.
        model.unreadOnly = true
        #expect(ids() == store.routerHistory.map(\.id).filter { $0 == a || $0 == b })
        #expect(model.cards(store).filter { !$0.isOpen }.map(\.id) == ids())
        // A line read under it stays until the filter goes off.
        store.acknowledgeRouterCard(a)
        #expect(ids().contains(a) && store.routerUnread.map(\.id) == [b])
        model.unreadOnly = false
        model.unreadOnly = true
        #expect(ids() == [b])
        // A read card picked from elsewhere (a banner): the filter goes off so it shows.
        model.select(read, store: store)
        #expect(!model.unreadOnly && ids().contains(read))
        // Mark all read under the filter: nothing is left listed.
        model.unreadOnly = true
        model.markAllRead(store)
        #expect(store.routerUnread.isEmpty && ids().isEmpty)
        // A message asked for: the filter goes off.
        model.show(message: UUID())
        #expect(!model.unreadOnly)
    }

    @Test func aSearchOpensEverySectionAndYourFoldsComeBack() {
        let model = RouterModel()
        #expect(model.shownFolds == RouterZone.foldedAtFirst)
        model.search.query = "fix"
        #expect(model.shownFolds.isEmpty)
        model.setFolded(.notes, true)
        #expect(model.shownFolds == [.notes] && model.folded == RouterZone.foldedAtFirst)
        model.endSearch()
        #expect(model.shownFolds == RouterZone.foldedAtFirst && model.searchFolds.isEmpty)
    }

    @Test func commandFOpensThePaletteEscEndsASearchAndTypingStillGoesToTheComposer() {
        let store = demo()
        let model = RouterModel()
        var opened = 0
        let keys = RouterKeys(store: store, model: model)
        keys.openPalette = { opened += 1 }
        let request = model.search.focusRequest
        #expect(keys.key(key(kVK_ANSI_F, "f", .command), responder: nil))
        #expect(opened == 1 && model.search.focusRequest == request)
        // In the field: ↑ and ↓ pick, everything else is the field's.
        let field = NSTextView()
        model.search.focused = true
        model.search.query = "a"
        #expect(!keys.key(key(kVK_ANSI_B, "b"), responder: field))
        #expect(keys.key(key(kVK_DownArrow), responder: field) && model.selection != nil)
        // Esc there ends the search, and doesn't close the window.
        #expect(keys.key(key(kVK_Escape), responder: field))
        #expect(model.search.query.isEmpty && !model.search.focused)
        // Off any field, a letter goes to the composer, not the search.
        let composer = model.focusRequest
        #expect(keys.key(key(kVK_ANSI_B, "b"), responder: nil))
        #expect(model.focusRequest == composer + 1 && model.search.query.isEmpty)
        // A search left on with the field let go: Esc ends it before the pick's reply goes.
        model.search.query = "a"
        model.search.focused = false
        let reply = model.replyTo
        #expect(keys.key(key(kVK_Escape), responder: nil))
        #expect(model.search.query.isEmpty && model.replyTo == reply)
    }

    /// The searched history is worked out once per change of the words or the history, and follows every change that could
    /// alter it: a line's text, the project names, a card leaving the history or coming back, lines arriving.
    @Test func theSearchedHistoryIsKeptBetweenRedrawsAndFollowsEveryChange() throws {
        let store = demo()
        let model = RouterModel()
        var state = store.router
        let i = try #require(state.cards.firstIndex { !$0.isOpen && $0.folder != nil })
        let card = state.cards[i]
        model.search.query = "zzqxv"
        #expect(model.history(store).isEmpty)
        // Read again (a redraw): nothing is made again.
        let revision = store.routerSearchRevision
        #expect(store.routerHistoryKeys?.revision == revision && model.searchedHistoryMemo?.revision == revision)
        _ = model.history(store)
        #expect(store.routerSearchRevision == revision && model.searchedHistoryMemo?.query == "zzqxv")
        // An addressed card's brief comes in with the word: found at once. Its asks too.
        state.cards[i].brief = "Says zzqxv now"
        store.router = state
        #expect(model.history(store).map(\.id) == [card.id])
        state.cards[i].brief = nil
        state.cards[i].asks = [RouterAsk(question: "Which?", options: ["ZZQXV"])]
        store.router = state
        #expect(model.history(store).map(\.id) == [card.id])
        // Reopened, it leaves the history and so the search; archived again, it is back.
        store.setCardAddressed(card.id, false)
        #expect(model.history(store).isEmpty)
        store.setCardAddressed(card.id, true)
        #expect(model.history(store).map(\.id) == [card.id])
        // A card addressed, a run logged and a summary made since: each listed as it comes.
        state = store.router
        state.cards.append(RouterCard(id: "n#t1", sessionID: "n", kind: .done, title: "Zzqxv landed", folder: card.folder,
                                      text: "Done", createdAt: Date(), addressedAt: Date(), addressedBy: .you))
        state.decisions.append(RouterDecision(trigger: .you("Ship zzqxv")))
        state.summaries.append(RouterSummary(at: Date(), text: "Working on zzqxv", sessionID: "n", title: "N"))
        store.router = state
        #expect(model.history(store).count == 4)
        // A project's name changes: its cards are found by the new one.
        model.search.query = "qqwwee"
        #expect(model.history(store).isEmpty)
        store.folderNames[card.folder!] = "qqwwee"
        #expect(model.history(store).contains { $0.id == card.id })
        // No words: the history as stored.
        model.search.query = ""
        #expect(model.history(store) == store.routerHistory)
    }

    /// The folded Working section's line counts what the search leaves in it, as its chip does; off the search, every
    /// working session.
    @Test func theFoldedWorkingLineCountsOnlyWhatTheSearchLeaves() throws {
        let store = demo()
        let model = RouterModel()
        let all = store.routerZones
        try #require(all.working.count >= 2)
        model.search.query = all.working[0].session.title
        let page = model.zones(store)
        try #require(page.working.contains { $0.id == all.working[0].id } && page.working.count < all.working.count)
        let items = store.overviewItems(page.working)
        #expect(items.count == page.working.count)
        #expect(RouterOverviewLine.text(items)?.hasPrefix("\(page.working.count) working") == true)
        #expect(store.overviewItems().count == all.working.count)
    }
}
