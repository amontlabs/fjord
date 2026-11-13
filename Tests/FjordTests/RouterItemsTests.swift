import Foundation
import Testing
@testable import Fjord

/// Open items per thread (OPEN-ITEMS.md): where a thread with items is placed, how a read changes them, and what the page
/// does with them (↑↓, your words, Done).
@MainActor
@Suite struct RouterItemsTests {
    private typealias ID = RouterDemo.ID
    private typealias Item = RouterDemo.Item

    private func model() -> RouterModel {
        let model = RouterDemo.records(still: true)
        RouterDemo.items(model)
        return model
    }

    @Test func aThreadGoesToTheSectionOfItsMostUrgentItem() {
        var t = RouterThread(id: "t", name: "T", title: "T", project: nil, state: .working, sentence: .init(text: "x"), since: .now)
        #expect(t.section == .working)
        t.ledger.items = [RouterItem(id: "k", kind: .know, sentence: "k", since: .now)]
        #expect(t.section == .done)
        // One item is the list shape already: the line, its item under it.
        #expect(t.ledger.block)
        #expect(RouterBlockLayout.rows(t).map(\.id) == ["header", "k"])
        t.ledger.items.append(RouterItem(id: "s", kind: .stuck, sentence: "s", since: .now))
        #expect(t.section == .needsYou)
        #expect(t.ledger.block)
        #expect(t.ledger.top == .stuck)
        // A real stop stays a stop: last in Needs you, its name in Stuck's colour.
        t.state = .stopped
        #expect(t.orderClass == .stopped)
        #expect(t.look.label == "Stuck")
    }

    @Test func t3sRequestsAndStopsAreItemsOfTheirThread() {
        let model = model()
        // A question: the line with nothing of its own, the question its Decide row; selecting the thread opens that row.
        guard let settings = model.thread(ID.settings), let ask = settings.ledger.request else { Issue.record("no request"); return }
        #expect(ask.kind == .decide && ask.request == .ask(.question) && ask.sentence == settings.sentence.text)
        #expect(settings.ledger.block && RouterBlockHeader.words(settings).isEmpty)
        model.select(.line(ID.settings))
        #expect(model.focus == RouterItem.requestID)
        // Its options and Return are the thread's own, as T3 has them: no item of the reads' picks it.
        #expect(model.selectedItem == nil)
        // T3 holds a question: its Done is off and changes nothing.
        model.itemDone(ID.settings, RouterItem.requestID)
        #expect(model.thread(ID.settings)?.ledger.request != nil)
        // Answered, it goes with the request.
        model.update(ID.settings) { $0.state = .working }
        #expect(model.thread(ID.settings)?.ledger.request == nil)
        // A real stop is a Stuck row.
        model.update(ID.settings) { $0.state = .stopped }
        #expect(model.thread(ID.settings)?.ledger.request?.kind == .stuck)
        // Your words to a thread whose only item is its request aren't a read of items: no "sent" row.
        var t = model.thread(ID.settings)!
        t.ledger.sent("again")
        #expect(t.ledger.read == nil)
    }

    @Test func aReadClosesMergesAndAddsThenSettles() {
        let then = Date(timeIntervalSince1970: 0), now = Date(timeIntervalSince1970: 600)
        var ledger = RouterLedger(items: [RouterItem(id: "a", kind: .decide, sentence: "a?", since: then),
                                          RouterItem(id: "b", kind: .stuck, sentence: "b", since: then),
                                          RouterItem(id: "c", kind: .know, sentence: "c", since: then)])
        ledger.sent("do a")
        #expect(ledger.read == .message("do a"))
        #expect(ledger.items.allSatisfy { $0.state == .checking })
        ledger.land(RouterLedgerRead(close: ["a": "answered by your message"], merge: ["b"],
                                     add: [RouterItem(id: "d", kind: .do, sentence: "d", since: now)]), at: now)
        #expect(ledger.read == nil)
        #expect(ledger.items.map(\.state) == [.closing("answered by your message"), .open, .open, .new])
        #expect(ledger.items[1].since == now)
        #expect(ledger.items[2].since == then)
        #expect(ledger.live.map(\.id) == ["b", "c", "d"])
        ledger.settle()
        #expect(ledger.items.map(\.id) == ["b", "c", "d"])
        #expect(ledger.items.allSatisfy { $0.state == .open })
        // A new turn: the header pulses once, a placeholder waits.
        ledger.turnEnded()
        #expect(ledger.read == .turn)
        #expect(ledger.pulse == 1)
    }

    @Test func theArrowsWalkABlocksItems() {
        let model = model()
        model.select(nil)
        #expect(model.shownLines.first?.id == ID.checkpoint)
        model.step(down: true)
        #expect(model.selection == .line(ID.checkpoint))
        #expect(model.focus == nil)
        model.step(down: true)
        #expect(model.focus == Item.stuck)
        model.step(down: true)
        #expect(model.focus == Item.keep)
        #expect(model.selectedItem?.item.id == Item.keep)
        model.step(down: true)
        model.step(down: true)
        // Past the block: the next line (Bar count), its header first, then its one item, as any block's.
        #expect(model.selection == .line(ID.bar))
        #expect(model.focus == nil)
        #expect(model.selectedItem == nil)
        model.step(down: true)
        #expect(model.focus == Item.push)
        #expect(model.selectedItem?.item.id == Item.push)
        model.step(down: false)
        model.step(down: false)
        #expect(model.selection == .line(ID.checkpoint))
        #expect(model.focus == Item.smaller)
    }

    /// Owner, 2026-11-13: a second click on an open item opened the block's header card. A click opens the row clicked,
    /// and a second click on it closes it.
    @Test func aClickOpensTheRowClickedAndASecondClickClosesIt() {
        let model = model()
        model.select(nil)
        model.click(item: Item.keep, of: ID.checkpoint)
        #expect(model.selection == .line(ID.checkpoint))
        #expect(model.focus == Item.keep)
        model.click(item: Item.keep, of: ID.checkpoint)
        #expect(model.selection == nil)
        #expect(model.focus == nil)
        // Another item, then the header: each opens its own card.
        model.click(item: Item.keep, of: ID.checkpoint)
        model.click(item: Item.stuck, of: ID.checkpoint)
        #expect(model.focus == Item.stuck)
        model.click(row: ID.checkpoint)
        #expect(model.selection == .line(ID.checkpoint))
        #expect(model.focus == nil)
        model.click(row: ID.checkpoint)
        #expect(model.selection == nil)
    }

    @Test func aPickOnAnItemsCardIsWhatReturnSends() {
        let model = model()
        model.select(.line(ID.checkpoint))
        model.focusItem(Item.keep)
        model.pick(1)
        #expect(model.destination == .picked(thread: ID.checkpoint, words: "Keep it as a fallback"))
    }

    @Test func yourWordsShowInTheBlockAndItsItemsAreChecked() {
        let model = model()
        model.select(.line(ID.checkpoint))
        model.setDraft(Item.reply)
        model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.checkpoint)], sure: true)))
        let since = model.thread(ID.checkpoint)?.since
        model.send()
        let t = model.thread(ID.checkpoint)
        #expect(t?.ledger.read == .message(Item.reply))
        #expect(t?.ledger.items.allSatisfy { $0.state == .checking } == true)
        // Still in Needs you with what it has open; the header keeps how long it has run.
        #expect(t?.section == .needsYou)
        #expect(t?.since == since)
        // Counted as running, faintly, under Working.
        #expect(model.tally.runningElsewhere["silo"] == 1)
    }

    @Test func doneClosesAnItemAndRevertPutsItBack() {
        let model = model()
        model.select(.line(ID.checkpoint))
        model.focusItem(Item.keep)
        model.settleSelected()
        let closing = model.thread(ID.checkpoint)?.ledger.items.first { $0.id == Item.keep }
        #expect(closing?.state == .closing(Router.Items.Copy.doneByYou))
        #expect(model.toast?.before == "Done:")
        if let id = model.toast?.id { model.revert(id) }
        #expect(model.thread(ID.checkpoint)?.ledger.items.first { $0.id == Item.keep }?.state == .open)
        #expect(model.focus == Item.keep)
    }

    /// REVIEW-items 1.8: a struck item (a read closed it) and a read's preview have no Done: no strike, no toast.
    @Test func aStruckItemOrAPreviewHasNoDone() {
        let model = model()
        model.update(ID.checkpoint) { t in
            t.ledger.items[0].state = .closing(Router.Items.Copy.answered)
            var p = RouterItem(id: "i9", kind: .do, sentence: "found", since: .now, state: .new)
            p.preview = true
            t.ledger.items.append(p)
        }
        let first = model.thread(ID.checkpoint)?.ledger.items[0].id ?? ""
        model.itemDone(ID.checkpoint, first)
        model.itemDone(ID.checkpoint, "i9")
        #expect(model.toast == nil)
        #expect(model.thread(ID.checkpoint)?.ledger.items.last?.state == .new)
    }

    /// Always the list shape: a thread with one item is a block through a read too (your words, a new turn), its
    /// words and the placeholder rows under the item, so nothing turns from a line into a block and back.
    @Test func aOneItemThreadIsABlockThroughARead() {
        var ledger = RouterLedger(items: [RouterItem(id: "i1", kind: .decide, sentence: "keep it?", since: .now)])
        #expect(ledger.block)
        ledger.sent("keep it")
        #expect(ledger.block && ledger.rows == ["i1", "sent"] && ledger.read == .message("keep it"))
        ledger.read = .turn
        #expect(ledger.block && ledger.rows == ["i1", "reading"])
        ledger.items = []
        #expect(!ledger.block)
    }

    /// A thread's line in the list shape says the thread's own sentence: Done's outcome, the run's newest summary, or
    /// nothing while it waits on you (its items say it).
    @Test func theHeaderSaysTheThreadsOwnSentence() {
        var t = RouterThread(id: "t", name: "T", title: "T", project: nil, state: .done, sentence: .init(text: "released"), since: .now)
        t.ledger.items = [RouterItem(id: "d", kind: .do, sentence: "install it", since: .now)]
        #expect(RouterBlockHeader.words(t) == "released")
        t.judging = true
        #expect(RouterBlockHeader.words(t) == "")
        t.judging = false
        t.state = .needsYou(.question)
        #expect(RouterBlockHeader.words(t) == "")
    }

    /// Done's check is grey; blue is for Know and for a line worth a look.
    @Test func doneIsGreyUnlessWorthALook() {
        var t = RouterThread(id: "t", name: "T", title: "T", project: nil, state: .done, sentence: .init(text: "x"), since: .now)
        #expect(t.look.tint == CDS.Text.muted && RouterSection.done.tint == CDS.Text.muted)
        t.worth = .look
        #expect(t.look.tint == CDS.Text.accent)
    }
}
