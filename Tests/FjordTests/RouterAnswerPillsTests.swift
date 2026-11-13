import Foundation
import Testing
@testable import Fjord

/// The composer's item and answer pills (`RouterAnswerPills`): @ finds an item by a word of its sentence and lights its
/// row; ⌘-click's pill; one answer pill per card that follows the card, and the card that follows the pill; what the split
/// router gets (`pillContext`) and what Return sends by code, on a recording source.
@MainActor
@Suite struct RouterAnswerPillsTests {
    private typealias ID = RouterDemo.ID
    private typealias Pill = RouterDemo.Pill
    private typealias Recorder = RouterModelTests.Recorder

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

    // MARK: Live: what the field draws, what the router gets, what Return sends

    /// The live field names and draws a pill through the store: the @ list's rows note theirs.
    @Test func anItemPickedInTheLiveFieldHasItsName() {
        let model = page()
        let key = RouterModel.itemKey(ID.snapshot, Pill.launchd)
        RouterPillLooks.names[.item(key)] = nil
        _ = model.itemRows("launchd")
        #expect(RouterPillLooks.names[.item(key)] == "launchd agent")
        #expect(RouterPillLooks.looks[.item(key)]?.item == true)
    }

    @Test func thePillsAreStructuredContextForTheRouter() {
        let model = page()
        model.select(.line(ID.snapshot))
        model.focusItem(Pill.trial)
        model.typeOther(trial, question: 0, "M1 only")
        model.select(nil)
        model.picks[ID.settings] = [0: 2]
        model.edit(model.draft + "check ", marks: model.mentions)
        model.pillItem(Pill.launchd, of: ID.snapshot)
        let context = model.pillContext
        #expect(context.map(\.kind) == [.answer, .answer, .item])
        let settings = context.first { $0.thread == ID.settings }
        #expect(settings?.item == nil && settings?.request == true)
        #expect(settings?.picks == [0: 2])
        #expect(settings?.answer == "One scrolling page")
        let other = context.first { $0.item == Pill.trial }
        #expect(other?.typed == [0: "M1 only"] && other?.answer == "M1 only" && other?.request == false)
        #expect(context.last == RouterPillContext(kind: .item, thread: ID.snapshot, item: Pill.launchd, name: "launchd agent"))
        // The answers never reach the free text; the item says "@name" where it stands.
        #expect(!model.plainDraft.contains("M1") && !model.plainDraft.contains("scrolling"))
        #expect(model.answerSends.map(\.item) == context.prefix(2).map(\.item))
    }

    private func recorded() -> (RouterModel, Recorder) {
        let model = page()
        let source = Recorder()
        source.model = model
        model.source = source
        return (model, source)
    }

    /// Only answers, nothing selected: Return sends each by code, a request's structured, an item's as words.
    @Test func returnSendsEveryAnswerByCode() {
        let (model, source) = recorded()
        withExtendedLifetime(source) {
            model.select(.line(ID.snapshot))
            model.focusItem(Pill.trial)
            model.pick(1)
            model.select(nil)
            model.picks[ID.settings] = [0: 2]
            #expect(model.draftEmpty && model.canSend)
            source.calls = []
            model.send()
            let sends = source.sends
            #expect(sends.count == 2)
            #expect(sends.first { $0.thread == ID.settings }?.kind == .answer(picks: [0: 2], typed: [:]))
            let item = sends.first { $0.thread == ID.snapshot }
            #expect(item?.kind == .words && item?.words == "Owed live tests")
            #expect(model.picks[trial] == nil && model.picks[ID.settings] == nil)
            #expect(model.draft.isEmpty && model.mentions.isEmpty)
            // Nothing went through the read.
            #expect(!source.calls.contains { if case .read = $0 { true } else { false } })
        }
    }

    /// Words going to an answered item's thread are led by its answer, as one message; another thread's answer goes alone.
    @Test func wordsToAnAnsweredThreadAreOneMessage() {
        let (model, source) = recorded()
        withExtendedLifetime(source) {
            model.select(.line(ID.bar))
            model.focusItem(RouterDemo.Item.push)
            model.pick(1)
            model.select(.line(ID.snapshot))
            model.focusItem(Pill.trial)
            model.pick(2)
            model.select(nil)
            model.edit(model.draft + "and rebase", marks: model.mentions)
            #expect(model.plainDraft == "and rebase")
            model.apply(.read(RouterRead(draft: model.plainDraft, places: [.thread(ID.snapshot)], sure: true)))
            source.calls = []
            model.send()
            let sends = source.sends
            #expect(sends.count == 2)
            #expect(sends.first { $0.thread == ID.snapshot }?.words == "Ship it to beta now\n\nand rebase")
            #expect(sends.first { $0.thread == ID.bar }?.words == "Open a PR first")
            #expect(model.draft.isEmpty && model.picks.isEmpty)
        }
    }

    /// A request's answer goes first and structured, so words to the same thread can't answer it in its place.
    @Test func aRequestsAnswerGoesBeforeWordsToItsThread() {
        let (model, source) = recorded()
        withExtendedLifetime(source) {
            model.select(nil)
            model.picks[ID.settings] = [0: 1]
            model.edit(model.draft + "keep the icons", marks: model.mentions)
            model.apply(.read(RouterRead(draft: model.plainDraft, places: [.thread(ID.settings)], sure: true)))
            source.calls = []
            model.send()
            let sends = source.sends.filter { $0.thread == ID.settings }
            #expect(sends.map(\.kind) == [.answer(picks: [0: 1], typed: [:]), .words])
            #expect(sends.last?.words == "keep the icons")
        }
    }

    /// Two answered items of one thread: one message, each answer after its item's name.
    @Test func twoAnswersToOneThreadAreOneMessage() {
        let (model, source) = recorded()
        withExtendedLifetime(source) {
            model.select(.line(ID.snapshot))
            model.focusItem(Pill.trial)
            model.pick(1)
            model.typeOther(RouterModel.itemKey(ID.snapshot, Pill.launchd), question: 0, "done already")
            model.select(nil)
            source.calls = []
            model.send()
            #expect(source.sends.map(\.words) == ["trial build → Owed live tests\nlaunchd agent → done already"])
        }
    }

    /// A form still owed an answer keeps its pill when the others go.
    @Test func aFormOwedAnAnswerKeepsItsPill() {
        let (model, source) = recorded()
        withExtendedLifetime(source) {
            model.select(nil)
            model.picks[ID.updater] = [0: 1]
            model.picks[ID.settings] = [0: 2]
            source.calls = []
            model.send()
            #expect(source.sends.map(\.thread) == [ID.settings])
            #expect(model.picks[ID.updater] == [0: 1])
            #expect(answers(model) == [.answer(ID.updater)])
        }
    }

    /// Taking out one of several pills unticks only its card.
    @Test func takingOneOfSeveralOutUnticksOnlyItsCard() {
        let model = page()
        model.select(nil)
        model.picks[ID.settings] = [0: 2]
        model.picks[trial] = [0: 1]
        #expect(answers(model).count == 2)
        let kept = model.mentions.filter { $0.pointer == .answer(trial) }
        let text = MentionText.markString + " "
        model.edit(text, marks: RouterMentions.marks(text, pointers: kept.map(\.pointer), name: { _ in kept[0].name }))
        #expect(model.picks[ID.settings] == nil)
        #expect(model.picks[trial] == [0: 1])
    }
}
