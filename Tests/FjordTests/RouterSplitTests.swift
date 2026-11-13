import Foundation
import Testing
@testable import Fjord

/// A message split across threads (docs/design/router-v2/SPLIT.md): which targets on the page show what they will receive
/// (a thread, an item it answers, a new thread's ghost line), ⌘1–3 and Tab on the parts the Router isn't sure of, the
/// reader's sends from the decider's parts, and Return sending every one (on a recording source).
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
        // Words to a thread whose T3 question waits answer it: on its request's row.
        let settings = model.box(ID.settings)
        let kept = RouterPending(words: "keep the sidebar icons in the page headers", answer: true)
        #expect(settings.block ? settings.pendingItems[RouterItem.requestID] == kept : settings.pending == kept)
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
        #expect(model.box(ID.settings).pending == nil && model.box(ID.settings).pendingItems.isEmpty)
        #expect(!model.layout.contains { if case .ghost = $0.kind { true } else { false } })
    }

    @Test func aPlaceYouPickYourselfEndsTheSplit() {
        let model = page(text, sends: three)
        model.explicit = .thread(ID.bar)
        model.finishTurn()
        #expect(model.split == nil)
        #expect(model.box(ID.settings).pending == nil && model.box(ID.settings).pendingItems.isEmpty)
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
        // Settings' words answer its T3 question: its request's row.
        #expect(model.splitLit == .row(RouterModel.itemKey(ID.settings, RouterItem.requestID)))
        model.revealSend(1)
        let val = model.box(ID.valCenis)
        #expect(model.splitLit == .row(val.block ? RouterModel.itemKey(ID.valCenis, "i1") : ID.valCenis))
    }

    // MARK: Live

    @Test func theReaderMakesTheDecidersPartsTheSendsAndAPillsItemTheAnswer() {
        let parts: [RouterProjectDecision.Part] = [
            .init(places: [.thread("a")], sure: true, words: "yes", confidence: 0.95),
            .init(places: [.thread("b"), .thread("c")], sure: false, words: "and the spacing", confidence: 0.5),
        ]
        var d = RouterProjectDecision(kind: .thread("a"), confidence: 0.95, decider: .sonnet)
        d.sends = parts
        let pill = RouterMention(range: 0..<1, pointer: .item("a#i2"), name: "trial build")
        let read = RouterReader.read("yes and the spacing", decision: d, selected: nil, mentions: [pill], eligible: { _ in true })
        #expect(read.sends == [RouterSend(places: [.thread("a")], words: "yes", item: "i2"),
                               RouterSend(places: [.thread("b"), .thread("c")], sure: false, words: "and the spacing")])
        // A place that can't be sent to: an unsure part keeps the rest; a part with none left is no split.
        let lessC = RouterReader.read("x", decision: d, selected: nil, eligible: { $0 != RouteTarget.thread("c").targetID })
        #expect(lessC.sends[1].places == [.thread("b")] && !lessC.sends[1].sure)
        let noB = RouterReader.read("x", decision: d, selected: nil,
                                    eligible: { ![RouteTarget.thread("b").targetID, RouteTarget.thread("c").targetID].contains($0) })
        #expect(noB.sends.isEmpty)
        // What the pills point at, for the decider.
        #expect(RouterReader.pointed([pill]) == [DeciderContext.Pointed(thread: "a", item: "trial build", said: pill.pointer.said("trial build"))])
    }

    @Test func tabMovesCmdDigitsAmongTheUnsureParts() {
        let sends = [RouterSend(places: [.thread(ID.tab), .thread(ID.snapshot)], sure: false, words: "the spacing is off"),
                     RouterSend(places: [.thread(ID.settings)], words: "keep the sidebar icons"),
                     RouterSend(places: [.thread(ID.briefs), .thread(ID.updater)], sure: false, words: "copy the rows")]
        let model = page("the spacing is off, keep the sidebar icons, copy the rows", sends: sends)
        #expect(model.splitFocus == 0)
        #expect(model.nextSplitPart())
        #expect(model.splitFocus == 2)
        #expect(model.cmdDigit(1))
        #expect(model.split?[2].place == .thread(ID.updater) && model.split?[0].mine == false)
        #expect(model.nextSplitPart() && model.splitFocus == 0)
        // Nothing unsure: Tab is the row's again.
        #expect(!page(text, sends: three).nextSplitPart())
    }

    private func recorded(_ text: String, sends: [RouterSend]) -> (RouterModel, RouterModelTests.Recorder) {
        let model = page(text, sends: sends)
        let source = RouterModelTests.Recorder()
        model.source = source
        return (model, source)
    }

    @Test func returnSendsEveryDestinationWithOneLogEntry() throws {
        let (model, source) = recorded(text, sends: three)
        let split = try #require(model.split)
        model.send()
        // One entry for all of it, first.
        #expect(source.calls.first == .logSplit(model.plainDraft.isEmpty ? text : text, sends: split))
        // The words that answer Settings' T3 question go as its structured answer (typed: no option is those words).
        let settings = try #require(source.sends.first { $0.thread == ID.settings })
        #expect(settings.kind == .answer(picks: [:], typed: [0: "keep the sidebar icons in the page headers"]))
        #expect(source.sends.contains { $0.thread == ID.valCenis && $0.words == "yes, five" && $0.kind == .words })
        #expect(source.calls.contains { if case .start("minted-1", words: "trim the onboarding copy", project: "fjord", _, _) = $0 { true } else { false } })
        // The parts go without the whole message's read (the log has it once); each line is Sent at once.
        #expect(source.sends.allSatisfy { $0.read == nil })
        #expect(model.thread(ID.valCenis)?.state == .sent && model.thread("minted-1")?.state == .sent)
        #expect(model.draft.isEmpty && model.split == nil)
    }

    @Test func wordsNamingAnOptionPickIt() throws {
        let (model, source) = recorded("one scrolling page. new thread: trim the copy", sends: [
            RouterSend(places: [.thread(ID.settings)], words: "One scrolling page."),
            RouterSend(places: [.newThread(project: "fjord")], words: "trim the copy")])
        model.send()
        let settings = try #require(source.sends.first { $0.thread == ID.settings })
        #expect(settings.kind == .answer(picks: [0: 2], typed: [:]))
    }

    @Test func anUnsurePartGoesWhereItIsLitAndReturnWaitsForTheRead() throws {
        let sends = [RouterSend(places: [.thread(ID.valCenis)], words: "yes, five"),
                     RouterSend(places: [.thread(ID.briefs), .thread(ID.updater)], sure: false, words: "ship it")]
        let (model, source) = recorded("yes, five. ship it", sends: sends)
        model.cmdDigit(1)
        model.send()
        #expect(source.sends.contains { $0.thread == ID.updater && $0.words == "ship it" })
        #expect(!source.sends.contains { $0.thread == ID.briefs })
        // Words typed after the read: Return holds until the read of these words is in.
        let (again, other) = recorded("yes, five. ship it", sends: sends)
        again.setDraft("yes, five. ship it now")
        again.send()
        #expect(again.held && other.sends.isEmpty)
    }
}
