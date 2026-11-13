import Foundation
import Testing
@testable import Fjord

/// A message split across threads (docs/design/router-v2/SPLIT.md), look only: which targets on the page show what they
/// will receive (a thread, an item it answers, a new thread's ghost line), and ⌘1–3 on the part the Router isn't sure of.
@MainActor
@Suite struct RouterSplitTests {
    private typealias ID = RouterDemo.ID

    private func page(_ text: String, sends: [RouterSend]) -> RouterModel {
        let model = RouterDemo.records()
        model.select(nil)
        model.setDraft(text)
        model.apply(.read(RouterRead(draft: model.plainDraft, places: [sends[0].place], sure: sends[0].sure, sends: sends)))
        model.finishTurn()
        return model
    }

    private let text = "keep the sidebar icons in the page headers. val cenis: yes, five. new thread: trim the onboarding copy"
    private var three: [RouterSend] {
        [RouterSend(places: [.thread(ID.settings)], words: "keep the sidebar icons in the page headers"),
         RouterSend(places: [.thread(ID.valCenis)], words: "yes, five", item: "i1"),
         RouterSend(places: [.newThread(project: "fjord")], words: "trim the onboarding copy")]
    }

    @Test func eachTargetShowsWhatItWillReceive() {
        let model = page(text, sends: three)
        #expect(model.box(ID.settings).pending == RouterPending(words: "keep the sidebar icons in the page headers"))
        // An item it answers: on the item's row in a block, said as the answer; on the line when it is the line's one item.
        let val = model.box(ID.valCenis)
        let answer = RouterPending(words: "yes, five", answer: true)
        #expect(val.block ? val.pendingItems["i1"] == answer && val.pending == nil : val.pending == answer)
        #expect(model.ghosts == [RouterGhost(project: "fjord", words: "trim the onboarding copy")])
        #expect(model.layout.contains { $0.kind == .ghost(RouterGhost(project: "fjord", words: "trim the onboarding copy")) })
        #expect(model.splitRows.rows == [0, 1, 2] && model.splitRows.more == 0)
        // The split marks its own targets: no other line is marked.
        #expect(model.marked == nil)
    }

    @Test func thePendingWordsGoWhenTheDraftDoes() {
        let model = page(text, sends: three)
        model.setDraft("")
        model.finishTurn()
        #expect(model.box(ID.settings).pending == nil)
        #expect(!model.layout.contains { if case .ghost = $0.kind { true } else { false } })
    }

    @Test func aPlaceYouPickYourselfEndsTheSplit() {
        let model = page(text, sends: three)
        model.explicit = .thread(ID.bar)
        model.finishTurn()
        #expect(model.split == nil)
        #expect(model.box(ID.settings).pending == nil)
    }

    @Test func cmdDigitsMoveAnUnsurePartToAnotherPlace() throws {
        let sends = [RouterSend(places: [.thread(ID.settings)], words: "keep the sidebar icons"),
                     RouterSend(places: [.thread(ID.tab), .thread(ID.snapshot)], sure: false, words: "the spacing is off",
                                part: "the spacing")]
        let model = page("keep the sidebar icons, and the spacing is off", sends: sends)
        #expect(model.splitFocus == 1)
        #expect(model.box(ID.tab).pending?.guess == true)
        #expect(model.cmdDigit(1))
        model.finishTurn()
        let send = try #require(model.split?[1])
        #expect(send.place == .thread(ID.snapshot) && send.mine)
        #expect(model.box(ID.tab).pending == nil)
        #expect(model.box(ID.snapshot).pending?.words == "the spacing is off")
        // The sure part is untouched, and a key past its places does nothing.
        #expect(model.split?[0].place == .thread(ID.settings))
        #expect(!model.lightPart(2))
    }

    @Test func pastFourRowsTheRestIsCountedAndTheUnsurePartStaysShown() {
        var sends = three + [RouterSend(places: [.thread(ID.briefs)], words: "copy the old rows first"),
                             RouterSend(places: [.thread(ID.updater)], words: "ship it")]
        #expect(page(text, sends: sends).splitRows == ([0, 1, 2, 3], 1))
        sends.append(RouterSend(places: [.thread(ID.tab), .thread(ID.snapshot)], sure: false, words: "the spacing is off"))
        let model = page(text, sends: sends)
        #expect(model.splitRows.rows == [0, 1, 2, 5] && model.splitRows.more == 2)
    }

    @Test func aClickOnARowLightsItsTargetOnThePage() {
        let model = page(text, sends: three)
        model.revealSend(0)
        #expect(model.splitLit == .row(ID.settings))
        model.revealSend(1)
        let val = model.box(ID.valCenis)
        #expect(model.splitLit == .row(val.block ? RouterModel.itemKey(ID.valCenis, "i1") : ID.valCenis))
    }
}
