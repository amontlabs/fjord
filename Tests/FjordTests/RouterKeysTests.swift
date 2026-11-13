import AppKit
import Carbon
import Foundation
import Testing
@testable import Fjord

/// Router v2's key map, row by row (docs/design/router-v2/DESIGN.md 5.1) and the order of Esc (5.3): `RouterKeys.handle`
/// with `RouterKey` values on the demo's page, a recording source behind it.
@MainActor
@Suite struct RouterKeysTests {
    private typealias ID = RouterDemo.ID
    private typealias Recorder = RouterModelTests.Recorder

    private func page(select: String? = ID.settings) -> (RouterModel, Recorder) {
        let model = RouterDemo.records()
        let source = Recorder()
        model.source = source
        model.select(select.map { .line($0) })
        // Opening a card tells T3 it was seen: not what these tests are about.
        source.calls = []
        return (model, source)
    }

    @discardableResult
    private func press(_ model: RouterModel, _ code: Int, _ flags: NSEvent.ModifierFlags = [], _ characters: String? = nil,
                       repeating: Bool = false, inField: Bool = false, atStart: Bool = false,
                       composer: RouterComposerHost? = nil) -> Bool {
        var key = RouterKey(code: code, flags: flags, characters: characters, isRepeat: repeating)
        key.caretAtStart = atStart
        return RouterKeys.handle(key, model: model, inField: inField, composer: composer)
    }

    /// A draft read as sure for `place`.
    private func draft(_ model: RouterModel, _ words: String, to place: RouterPlace) {
        model.setDraft(words)
        model.apply(.read(RouterRead(draft: words, places: [place], sure: true)))
    }

    // MARK: Return

    @Test func returnSendsWhatTheRowShowsAndIgnoresARepeat() {
        let (model, source) = page()
        // ⇧2 picks the second option; Return sends it.
        #expect(press(model, kVK_ANSI_2, .shift, "2"))
        #expect(source.sends.isEmpty)
        // A held Return is the handler's and does nothing.
        #expect(press(model, kVK_Return, repeating: true))
        #expect(source.sends.isEmpty)
        #expect(press(model, kVK_Return))
        #expect(source.sends.map(\.words) == ["One scrolling page"])
    }

    @Test func returnNeverSettlesAndSendsNothingOnADoneCard() {
        let (model, source) = page(select: ID.guide)
        #expect(press(model, kVK_Return))
        #expect(source.calls.isEmpty)
        #expect(model.thread(ID.guide) != nil)
    }

    @Test func returnOnAStoppedCardContinues() {
        let (model, source) = page(select: ID.disk)
        #expect(press(model, kVK_Return))
        #expect(source.sends.map(\.kind) == [.continuing])
    }

    @Test func shiftReturnIsANewLineAndOptionReturnQueues() {
        let (model, source) = page(select: nil)
        draft(model, "then the changelog", to: .thread(ID.checkpoint))
        #expect(!press(model, kVK_Return, .shift, inField: true))
        #expect(source.sends.isEmpty)
        #expect(press(model, kVK_Return, .option, inField: true))
        #expect(source.sends.count == 1 && source.sends[0].queue)
    }

    @Test func aReturnBeforeTheReadHoldsTheWordsAndSendsNothing() {
        let (model, source) = page(select: nil)
        model.setDraft("lcu: add a flag")
        #expect(press(model, kVK_Return, inField: true))
        #expect(model.held)
        #expect(source.sends.isEmpty && source.calls.allSatisfy { if case .read = $0 { true } else { false } })
    }

    // MARK: Settle and snooze

    @Test func commandDeleteSettlesOnlyWithNoDraftAndNeverOnARepeat() {
        let (model, source) = page(select: ID.guide)
        #expect(press(model, kVK_Delete, .command, repeating: true))
        #expect(source.calls.isEmpty)
        // With a draft, ⌘⌫ is the text's.
        model.setDraft("also")
        #expect(!press(model, kVK_Delete, .command, inField: true))
        #expect(!source.calls.contains(.settle([ID.guide], on: true)))
        model.setDraft("")
        #expect(press(model, kVK_Delete, .command))
        #expect(source.calls.contains(.settle([ID.guide], on: true)))
    }

    @Test func optionCommandDeleteOpensTheSnoozeMenuAndShiftDigitsChooseAtOnce() {
        let (model, source) = page(select: ID.valCenis)
        #expect(press(model, kVK_Delete, [.command, .option]))
        #expect(model.snoozeMenu != nil)
        // ↓ Return would choose the second; ⇧1 chooses the first, at once, with a Revert.
        #expect(press(model, kVK_ANSI_1, .shift, "1"))
        #expect(model.snoozeMenu == nil)
        guard case .snooze(let id, let until)? = source.calls.last else { Issue.record("no snooze"); return }
        #expect(id == ID.valCenis && until != nil)
        #expect(model.toast != nil)
    }

    @Test func aBareDigitInTheSnoozeMenuIsNotAChoice() {
        let (model, source) = page(select: ID.valCenis)
        press(model, kVK_Delete, [.command, .option])
        // The digit-row key with no ⇧ types: not handled by the menu, and the page types it into the composer.
        #expect(press(model, kVK_ANSI_1, [], "&"))
        #expect(!source.calls.contains { if case .snooze = $0 { true } else { false } })
        #expect(model.draft == "&")
    }

    // MARK: Walking and the card

    @Test func arrowsWalkTheRowsOnlyWithAnEmptyDraftAndWrap() {
        let (model, _) = page(select: nil)
        #expect(press(model, kVK_DownArrow))
        let first = model.selection
        #expect(first != nil)
        #expect(press(model, kVK_DownArrow))
        #expect(model.selection != first)
        #expect(press(model, kVK_UpArrow))
        #expect(model.selection == first)
        // Up from the first wraps to the last row.
        #expect(press(model, kVK_UpArrow))
        #expect(model.selection != first && model.selection != nil)
        // With a draft the arrows are the text's.
        model.setDraft("hello")
        let at = model.selection
        #expect(!press(model, kVK_DownArrow, inField: true))
        #expect(!press(model, kVK_LeftArrow, inField: true))
        #expect(model.selection == at)
    }

    @Test func optionArrowsJumpSections() {
        let (model, _) = page()
        let before = model.selectedThread?.section
        #expect(press(model, kVK_DownArrow, .option))
        #expect(model.selectedThread?.section != before)
        #expect(press(model, kVK_UpArrow, .option))
        #expect(model.selectedThread?.section == before)
    }

    @Test func shiftDigitsPickByKeyPositionAndAgainUnpick() {
        let (model, _) = page()
        // The digit row by position: AZERTY's é is the 2 key, and ⇧ gives the digit.
        #expect(press(model, kVK_ANSI_3, .shift, "3"))
        #expect(model.picks[ID.settings] == [0: 3])
        #expect(press(model, kVK_ANSI_3, .shift, "3"))
        #expect(model.picks[ID.settings] == nil)
        // Past the options: nothing picked (and the character goes to the composer, as any other).
        #expect(press(model, kVK_ANSI_9, .shift, "9", inField: true) == false)
        #expect(model.picks[ID.settings] == nil)
    }

    @Test func aBareDigitRowKeyAlwaysTypes() {
        let (model, _) = page()
        // No field focused: the page types it into the composer. In the field: the field's.
        #expect(press(model, kVK_ANSI_2, [], "é"))
        #expect(model.picks[ID.settings] == nil && model.draft == "é")
        let (inField, _) = page()
        #expect(!press(inField, kVK_ANSI_2, [], "é", inField: true))
        #expect(inField.picks[ID.settings] == nil)
    }

    @Test func shiftDigitsWithADraftAreTheTextsOwn() {
        let (model, _) = page()
        model.setDraft("x")
        #expect(!press(model, kVK_ANSI_2, .shift, "2", inField: true))
        #expect(model.picks[ID.settings] == nil)
    }

    @Test func arrowsOpenAndCloseTheLongText() {
        let (model, _) = page(select: ID.briefs)
        #expect(!model.expanded.contains(ID.briefs))
        #expect(press(model, kVK_RightArrow))
        #expect(model.expanded.contains(ID.briefs))
        #expect(press(model, kVK_LeftArrow))
        #expect(!model.expanded.contains(ID.briefs))
    }

    @Test func tabMovesThroughAFormsQuestions() {
        let (model, _) = page(select: ID.updater)
        #expect(model.formAt[ID.updater] ?? 0 == 0)
        #expect(press(model, kVK_Tab))
        #expect(model.formAt[ID.updater] == 1)
        #expect(press(model, kVK_Tab, .shift))
        #expect(model.formAt[ID.updater] == 0)
    }

    @Test func returnOnAFormWithQuestionsLeftGoesToTheNextOne() {
        let (model, source) = page(select: ID.updater)
        press(model, kVK_ANSI_1, .shift, "1")
        #expect(press(model, kVK_Return))
        #expect(source.sends.isEmpty)
        #expect(model.formAt[ID.updater] == 1)
    }

    // MARK: Places

    @Test func commandDigitsNeverFallThroughWithADraft() {
        let (model, _) = page(select: nil)
        // Without a draft they are the Go menu's.
        #expect(!press(model, kVK_ANSI_1, .command, "1"))
        // While the places are still being read, the digit is kept and lit when the read lands unsure.
        model.setDraft("the spacing is off again")
        #expect(press(model, kVK_ANSI_2, .command, "2", inField: true))
        model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.settings), .thread(ID.tab), .newThread(project: "fjord")],
                                      sure: false)))
        #expect(model.explicit == .thread(ID.tab))
        // With the places shown, ⌘3 lights the third.
        #expect(press(model, kVK_ANSI_3, .command, "3", inField: true))
        #expect(model.explicit == .newThread(project: "fjord"))
    }

    @Test func tabOpensThePlacesWhenTheRowAsksAndReturnPicks() {
        let (model, source) = page(select: nil)
        model.setDraft("that one test again")
        model.apply(.read(RouterRead(draft: model.draft, places: [], sure: false)))
        #expect(model.destination == .noGuess)
        #expect(press(model, kVK_Tab, inField: true))
        #expect(model.placesMenu)
        #expect(press(model, kVK_DownArrow, inField: true))
        #expect(press(model, kVK_Return, inField: true))
        #expect(!model.placesMenu && model.explicit != nil)
        #expect(source.sends.isEmpty)
    }

    @Test func tabIntoANewThreadsSettingsAndBackOut() {
        let (model, _) = page(select: nil)
        draft(model, "silo: write the changelog", to: .newThread(project: "silo"))
        #expect(model.launchShown)
        #expect(press(model, kVK_Tab, inField: true))
        #expect(model.launchFocus != nil)
        #expect(press(model, kVK_RightArrow, inField: true))
        // A character is the words' again: the keyboard leaves the settings.
        #expect(!press(model, kVK_ANSI_A, [], "a", inField: true))
        #expect(model.launchFocus == nil)
    }

    // MARK: Esc, in order

    @Test func escStepsOutOneThingAtATimeInTheDesignsOrder() {
        let (model, _) = page(select: ID.settings)
        model.toggle(project: "fjord")
        model.setDraft("go ahead")
        model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.settings)], sure: true)))
        model.choose(.thread(ID.settings))
        model.openPlaces()
        model.pick(1)
        model.draft = ""
        model.setDraft("go ahead")
        model.placesMenu = true
        // 2: the places menu first.
        #expect(press(model, kVK_Escape, inField: true))
        #expect(!model.placesMenu && model.explicit != nil)
        // 6: your place; 7: the picked options (none with a draft, so the guess is waved off next).
        #expect(press(model, kVK_Escape, inField: true))
        #expect(model.explicit == nil)
        #expect(press(model, kVK_Escape, inField: true))
        #expect(model.waved)
        // The draft stays through all of it, and the last Esc is the field's (it never closes the window).
        #expect(model.draft == "go ahead")
        model.setDraft("")
        #expect(press(model, kVK_Escape))
        #expect(model.selection == nil)
        #expect(press(model, kVK_Escape))
        #expect(!model.filtered)
        #expect(!press(model, kVK_Escape))
        #expect(press(model, kVK_Escape, inField: true))
    }

    @Test func escLeavesAHeldReturnBeforeThePlaceAndTheSettingsBeforeThePlace() {
        let (model, _) = page(select: nil)
        draft(model, "silo: write the changelog", to: .newThread(project: "silo"))
        model.moveLaunchFocus(forward: true, leaves: true)
        model.explicit = .newThread(project: "silo")
        #expect(press(model, kVK_Escape, inField: true))
        #expect(model.launchFocus == nil)
        #expect(model.explicit != nil)
        #expect(press(model, kVK_Escape, inField: true))
        #expect(model.explicit == nil)
    }

    @Test func escInFilterModeReturnsToTheListAndKeepsTheFilter() {
        let (model, _) = page()
        model.toggle(project: "silo")
        model.enterFilterMode()
        #expect(press(model, kVK_Escape))
        #expect(!model.filterMode && model.project == "silo")
    }

    // MARK: Elsewhere

    @Test func commandOOpensTheSelectedThreadInT3AndCommandFTheFilter() {
        let (model, source) = page(select: ID.guide)
        #expect(press(model, kVK_ANSI_O, .command, "o"))
        #expect(source.calls == [.open(ID.guide)])
        #expect(press(model, kVK_ANSI_F, .command, "f"))
        #expect(model.filterMode)
    }

    @Test func commandZUndoesTheActWhileItIsTheNewestAndIsTheTextsWithADraft() {
        let (model, source) = page(select: ID.guide)
        press(model, kVK_Delete, .command)
        #expect(source.calls.last == .settle([ID.guide], on: true))
        model.setDraft("typing")
        #expect(!press(model, kVK_ANSI_Z, .command, "z", inField: true))
        model.setDraft("")
        #expect(press(model, kVK_ANSI_Z, .command, "z", inField: true))
        #expect(source.calls.last == .settle([ID.guide], on: false))
    }

    @Test func aCharacterWithNoFieldFocusedGoesToTheComposer() {
        let (model, _) = page(select: nil)
        #expect(press(model, kVK_ANSI_F, [], "f"))
        #expect(model.draft == "f")
        // An unrelated chord is not handled.
        #expect(!press(model, kVK_ANSI_G, .control, "g"))
    }

    @Test func aFailureLineTakesReturnAsSendAgainAndCommandDeleteAsEdit() throws {
        let (model, source) = page(select: ID.bar)
        model.setDraft("also bump the version")
        model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.bar)], sure: true)))
        model.send()
        model.apply(.refused(ID.bar, reason: "T3 Code isn't reachable.", offline: true))
        model.apply(.connection(lost: false))
        let failure = try #require(model.failures.first)
        model.selection = .failure(failure.id)
        let sent = source.sends.count
        #expect(press(model, kVK_Return))
        #expect(source.sends.count == sent + 1)
    }

    // MARK: The @ list

    private func triage() -> RouterComposerHost {
        let store = InboxFixture.store([InboxFixture.pr(12, repo: "octo/app", title: "Fix it")])
        return (store, RouterComposerModel())
    }

    @Test func theMentionListHasTheKeysFirst() {
        let (model, source) = page(select: nil)
        let host = triage()
        host.text.draft = "ask @octo"
        model.setDraft(host.text.draft)
        #expect(!host.text.suggestions(host.store).isEmpty)
        // Return picks the suggestion: it does not send.
        #expect(press(model, kVK_Return, inField: true, composer: host))
        #expect(host.text.pointers == [.notification("pr:octo/app#12")])
        #expect(source.sends.isEmpty)
        // Tab picks as well, and Esc closes the list without leaving the draft.
        host.text.pointers = []
        host.text.draft = "ask @octo"
        #expect(press(model, kVK_Tab, inField: true, composer: host))
        #expect(host.text.pointers.count == 1)
        host.text.pointers = []
        host.text.draft = "ask @octo"
        #expect(press(model, kVK_Escape, inField: true, composer: host))
        #expect(host.text.mention == nil && host.text.draft == "ask @octo")
        #expect(model.selection == nil)
    }

    @Test func withoutAListReturnSendsAsEver() {
        let (model, source) = page(select: nil)
        let host = triage()
        draft(model, "push it and open the PR", to: .thread(ID.bar))
        host.text.draft = "push it and open the PR"
        #expect(press(model, kVK_Return, inField: true, composer: host))
        #expect(source.sends.count == 1)
    }

    // MARK: The settings' lists

    @Test func theEffortAndAccessMenusAreTheChosenModelsOwnLists() {
        let (model, _) = page(select: nil)
        let slim = RouterLaunchModel(id: "slim", name: "Slim", provider: "T3", instance: "slim",
                                       efforts: [.low, .high], defaultEffort: .low, access: [.supervised, .full])
        model.apply(.launch(defaults: RouterLaunch(model: "slim", effort: .low, access: .supervised, plan: false), models: [slim]))
        draft(model, "silo: write the changelog", to: .newThread(project: "silo"))
        #expect(model.launchChoices(.effort).map(\.label) == ["Low", "High"])
        #expect(model.launchChoices(.access).count == 2)
        #expect(model.launchChoices(.model).map(\.label) == ["Slim"])
    }
}
