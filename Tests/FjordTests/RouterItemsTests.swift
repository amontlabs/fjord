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
        #expect(t.ledger.single?.id == "k")
        t.ledger.items.append(RouterItem(id: "s", kind: .stuck, sentence: "s", since: .now))
        #expect(t.section == .needsYou)
        #expect(t.ledger.block)
        #expect(t.ledger.top == .stuck)
        // A real stop stays a stop.
        t.state = .stopped
        #expect(t.look.label == "Stopped")
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
        // Past the block: the next line (Bar count, whose one item is its line and its card).
        #expect(model.selection == .line(ID.bar))
        #expect(model.focus == nil)
        #expect(model.selectedItem?.item.id == Item.push)
        model.step(down: false)
        #expect(model.selection == .line(ID.checkpoint))
        #expect(model.focus == Item.smaller)
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
}
