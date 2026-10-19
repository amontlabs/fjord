import SwiftUI

// The Router's search: the inbox's field (`InboxSearchField` on an `InboxSearch` of the Router's own) in the page's header,
// filtering Now and History as you type. ⌘F gives it the keyboard; typing elsewhere still writes to the composer. An item
// is listed when its text holds every word typed, in any case: a card by its session's title, project, kind, text, brief
// and asks; a message waiting for where it goes by its words and the targets offered; a working session by its title,
// project, what it is doing and its summary; a history line by what it shows.

enum RouterSearch {
    /// The words of a query, lowercased; none is no search.
    static func words(_ query: String) -> [Substring] {
        query.lowercased().split(whereSeparator: \.isWhitespace)
    }

    /// Whether a lowercased search text holds every word.
    static func matches(_ key: String, _ words: [Substring]) -> Bool {
        words.allSatisfy { key.contains($0) }
    }

    /// What a card is found by (in the zones and in the history), lowercased. `project`: its project's name, as listed.
    static func key(_ card: RouterCard, project: String) -> String {
        var parts = [card.title, project, card.kind.label, card.text]
        if let brief = card.brief { parts.append(brief) }
        for ask in card.asks ?? [] { parts.append(ask.question); parts += ask.options }
        if let origin = card.origin { parts += [origin.category, origin.thing] }
        if let watch = card.triage?.watch { parts.append(watch.label) }
        if let triage = card.triage, let message = RouterWaits.message(triage) { parts.append(message) }
        if !card.isOpen {
            if let by = card.addressedBy { parts.append(by.label) }
            if let note = card.addressedNote { parts.append(note) }
        }
        return parts.joined(separator: " ").lowercased()
    }

    /// A message waiting for you to say where it goes: its words, why it asks, the targets offered.
    static func key(_ ask: RouterAskBack) -> String {
        ([ask.message, ask.note ?? ""] + ask.options.flatMap { [$0.title, $0.detail] }).joined(separator: " ").lowercased()
    }

    /// A working session's row: its title, project, what it is doing, and the summary under it.
    static func key(_ row: AgentRow, doing: String?, summary: RouterSummary?) -> String {
        [row.session.title, row.projectName, doing ?? "", row.activity?.text ?? "", row.tasksText ?? "", summary?.text ?? ""]
            .joined(separator: " ").lowercased()
    }

    /// A history line: a card as above; a run by what set it off, what was done and what it said back (each part of a divided one
    /// by its own words and outcome); a summary by its
    /// session and its text.
    static func key(_ entry: RouterPage.Entry, project: (RouterCard) -> String) -> String {
        switch entry {
        case .card(let card): return key(card, project: project(card))
        case .decision(let d):
            var parts = [d.triggerText, d.summary] + d.doneLines
            parts += [d.reply ?? "", d.note ?? "", d.decision.target ?? "", d.decision.label ?? ""]
            parts += (d.mentions ?? []).map(\.name)
            // A message that went to several places is found by each part's words, place and outcome.
            if d.isDivided {
                for place in d.places {
                    parts += [place.triggerText, place.summary] + place.doneLines
                    parts += [place.reply ?? "", place.note ?? "", place.decision.target ?? "", place.decision.label ?? ""]
                    parts += (place.mentions ?? []).map(\.name)
                }
            }
            return parts.joined(separator: " ").lowercased()
        case .summary(let s): return [s.title ?? "", s.text].joined(separator: " ").lowercased()
        }
    }

    /// The history lines holding every word of `query`, in order; all of them with none.
    static func history(_ entries: [RouterPage.Entry], query: String, project: (RouterCard) -> String) -> [RouterPage.Entry] {
        let words = words(query)
        guard !words.isEmpty else { return entries }
        return history(entries, keys: entries.map { key($0, project: project) }, words: words)
    }

    /// The lines whose search text (`keys`, one per line, in order) holds every word, in order.
    static func history(_ entries: [RouterPage.Entry], keys: [String], words: [Substring]) -> [RouterPage.Entry] {
        zip(entries, keys).compactMap { matches($1, words) ? $0 : nil }
    }
}

extension Store {
    /// Each history line's search text (`RouterSearch.key`), in the history's order. Made on the first search after the
    /// history or the projects' names change (`routerSearchRevision`) and kept for the searches after it: a keystroke
    /// then only matches the words, and lowercases nothing.
    func routerHistorySearchKeys() -> [String] {
        if let kept = routerHistoryKeys, kept.revision == routerSearchRevision { return kept.keys }
        let keys = routerHistory.map { RouterSearch.key($0, project: { routerProject($0).name }) }
        routerHistoryKeys = (routerSearchRevision, keys)
        return keys
    }
}

extension RouterPage {
    /// The page less what doesn't hold every word of `query` (all of it with none): each section's cards, the messages
    /// waiting for a target, the working sessions and the history lines. `doing`: what a working session's row says it does.
    func matching(_ query: String, project: (RouterCard) -> String, doing: (AgentRow) -> String? = { _ in nil }) -> RouterPage {
        let words = RouterSearch.words(query)
        guard !words.isEmpty else { return self }
        let card = { (c: RouterCard) in RouterSearch.matches(RouterSearch.key(c, project: project(c)), words) }
        var page = self
        page.needs = needs.filter(card)
        page.ready = ready.filter(card)
        page.notes = notes.filter(card)
        page.waiting = waiting.filter(card)
        page.asks = asks.filter { RouterSearch.matches(RouterSearch.key($0), words) }
        page.working = working.filter {
            RouterSearch.matches(RouterSearch.key($0, doing: doing($0), summary: summaries[$0.id]), words)
        }
        page.history = RouterSearch.history(history, query: query, project: project)
        return page
    }
}

extension RouterModel {
    /// Whether a search filters the page: the field holds a word.
    var searching: Bool { !RouterSearch.words(search.query).isEmpty }

    /// The page's zones as the search leaves them.
    func zones(_ store: Store) -> RouterPage {
        let query = search.query
        guard searching else { return store.routerZones }
        return store.routerZones.matching(query, project: { store.routerProject($0).name },
                                          doing: { store.liveExplanation($0) })
    }

    /// The history lines holding every word of the search, in order (all of them with none). The page reads it on every
    /// redraw and the keys on every press: it is worked out again only as the words or the history change (the store's
    /// `routerSearchRevision`: its lines, the projects' names), over the search texts the store keeps, so a redraw between
    /// keystrokes costs nothing and a keystroke only the matching.
    func searchedHistory(_ store: Store) -> [RouterPage.Entry] {
        guard searching else { return store.routerHistory }
        let query = search.query, revision = store.routerSearchRevision
        if let memo = searchedHistoryMemo, memo.query == query, memo.revision == revision { return memo.entries }
        let entries = RouterSearch.history(store.routerHistory, keys: store.routerHistorySearchKeys(), words: RouterSearch.words(query))
        searchedHistoryMemo = (query, revision, entries)
        return entries
    }

    /// The history as the search and the Unread filter leave it.
    func history(_ store: Store) -> [RouterPage.Entry] {
        let entries = searchedHistory(store)
        guard unreadOnly else { return entries }
        return entries.filter { entry in
            guard case .card(let card) = entry else { return false }
            if card.unread == true { unreadKept.insert(card.id) }
            return !filtersOut(card)
        }
    }

    /// Whether the Unread filter leaves a history line's card out: read, and not since the filter went on.
    func filtersOut(_ card: RouterCard) -> Bool {
        unreadOnly && !card.isOpen && card.unread != true && !unreadKept.contains(card.id)
    }

    /// Mark all read: every unread line of the history seen; under the filter they go too, as it lists only what is unread.
    func markAllRead(_ store: Store) {
        unreadKept = []
        store.acknowledgeAllRouterCards()
    }

    /// Whether a card is listed under the search (any card with none).
    func matchesSearch(_ card: RouterCard, store: Store) -> Bool {
        let words = RouterSearch.words(search.query)
        return words.isEmpty || RouterSearch.matches(RouterSearch.key(card, project: store.routerProject(card).name), words)
    }

    /// The folds the page shows: yours, or while a search is on, the search's own (none at first, so every section with a
    /// match shows it); yours are back as it ends.
    var shownFolds: Set<RouterZone> { searching ? searchFolds : folded }

    /// The search's words changed: a pick it filtered out is dropped (a reply on it goes with it while nothing is written to
    /// it), rather than staying picked out of sight; the search's folds go once it is over.
    func searchChanged(store: Store) {
        if !searching { searchFolds = [] }
        guard let id = selection, let card = store.router.cards.first(where: { $0.id == id }), !matchesSearch(card, store: store)
        else { return }
        selection = nil
        if replyTo == id, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { replyTo = nil }
    }

    /// Esc on the search, or the page left: its words and its folds go, and the field gives up the keyboard.
    func endSearch() {
        search.end()
        searchFolds = []
    }
}

/// A search that left nothing on a side of the page: one quiet line, as the inbox says it.
struct RouterNothingFound: View {
    var text = "Nothing found"
    var symbol = "magnifyingglass"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            Text(text).cdsText((13, 18), .regular, CDS.Text.muted)
        }
        .foregroundStyle(CDS.Text.muted)
        .padding(.leading, 2)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
