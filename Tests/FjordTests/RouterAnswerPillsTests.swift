import Foundation
import Testing
@testable import Fjord

/// The composer's item and answer pills (`RouterAnswerPills`), look only: @ finds an item by a word of its sentence and
/// lights its row; ⌘-click's pill; one answer pill per card that follows the card, and the card that follows the pill.
@MainActor
@Suite struct RouterAnswerPillsTests {
    private typealias ID = RouterDemo.ID
    private typealias Pill = RouterDemo.Pill

    private func page() -> RouterModel {
        let model = RouterDemo.records()
        RouterDemo.pills(model)
        return model
    }

    private var trial: String { RouterModel.itemKey(ID.snapshot, Pill.trial) }

    private func answers(_ model: RouterModel) -> [RouterPointer] {
        model.mentions.map(\.pointer).filter { if case .answer = $0 { true } else { false } }
    }

    @Test func atFindsAnItemByAWordOfItsSentenceUnderItsThread() {
        let model = page()
        let rows = model.itemRows("launchd")
        #expect(rows.map(\.id) == ["item:" + RouterModel.itemKey(ID.snapshot, Pill.launchd)])
        #expect(rows.first?.group == "Snapshot API")
        // Never by loose letters.
        #expect(model.itemRows("lnchd").isEmpty)
        model.lightAt(.item(RouterModel.itemKey(ID.snapshot, Pill.launchd)))
        #expect(model.atLit == .row(RouterModel.itemKey(ID.snapshot, Pill.launchd)))
        model.lightAt(nil)
        #expect(model.atLit == nil)
    }

    @Test func commandClickPutsTheItemAfterTheWords() {
        let model = page()
        model.setDraft("look at")
        #expect(model.pillItem(Pill.launchd, of: ID.snapshot))
        #expect(model.draft == "look at " + MentionText.markString + " ")
        #expect(model.mentions.map(\.pointer) == [.item(RouterModel.itemKey(ID.snapshot, Pill.launchd))])
        #expect(model.mentions.first?.name == "launchd agent")
        // Twice is one pill.
        model.pillItem(Pill.launchd, of: ID.snapshot)
        #expect(model.mentions.count == 1)
    }

    @Test func aPickIsOneAnswerPillThatFollowsTheCard() {
        let model = page()
        model.select(.line(ID.snapshot))
        model.focusItem(Pill.trial)
        model.pick(1)
        #expect(answers(model) == [.answer(trial)])
        #expect(model.mentions.first?.name == "trial build → owed live tests")
        #expect(model.draftEmpty)
        // Another option: the same pill, the new answer.
        model.pick(2)
        #expect(answers(model) == [.answer(trial)])
        #expect(model.mentions.first?.name == "trial build → ship it to beta now")
        // Other typed: the words are the answer, the option goes.
        model.typeOther(trial, question: 0, "M1 only")
        #expect(model.mentions.first?.name == "trial build → M1 only")
        #expect(model.picks[trial] == nil)
        model.typeOther(trial, question: 0, "")
        #expect(model.draft.isEmpty && model.mentions.isEmpty)
    }

    /// A thread's ask reads question → answer under the thread's name, as words too: never "@One scrolling page".
    @Test func anAnswerReadsAsItsQuestionThenTheAnswer() {
        let model = page()
        model.select(nil)
        model.picks[ID.settings] = [0: 2]
        #expect(model.mentions.first?.name == "Settings layout → one scrolling page")
        // Not words: the picks go as the card's answer, as before.
        #expect(model.plainDraft.isEmpty)
        #expect(MentionText.plain(model.draft, pointers: [.answer(ID.settings)], name: { _ in "Settings layout → one scrolling page" })
                == "Settings layout → one scrolling page ")
        #expect(RouterModel.spoken("PR first") == "PR first")
    }

    @Test func takingThePillOutUnticksTheCard() {
        let model = page()
        model.select(.line(ID.snapshot))
        model.focusItem(Pill.trial)
        model.pick(1)
        model.edit("", marks: [])
        #expect(model.picks[trial] == nil)
    }

    @Test func answersFromTwoThreadsLeadTheWords() {
        let model = page()
        model.select(.line(ID.bar))
        model.focusItem(RouterDemo.Item.push)
        model.pick(1)
        model.select(.line(ID.snapshot))
        model.focusItem(Pill.trial)
        model.pick(1)
        model.edit(model.draft + "and rebase", marks: model.mentions)
        #expect(answers(model).count == 2)
        #expect(!model.draftEmpty)
        // A pick changed with words in the draft keeps them after the pills.
        model.removeAnswer(RouterModel.itemKey(ID.bar, RouterDemo.Item.push))
        #expect(answers(model) == [.answer(trial)])
        #expect(model.draft == MentionText.markString + " and rebase")
    }

    @Test func clickingAPillOpensItsCard() {
        let model = page()
        model.select(nil)
        model.openPill(.answer(trial))
        #expect(model.selection == .line(ID.snapshot))
        #expect(model.focus == Pill.trial)
    }
}
