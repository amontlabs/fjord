import Foundation
import Testing
@testable import Fjord

/// Router v2's seam (docs/design/router-v2/IMPLEMENTATION.md 1.2): the page takes whole records through `apply`, and
/// every act that leaves the page reaches its source once, with what it needs.
@MainActor
@Suite struct RouterModelTests {
    private typealias ID = RouterDemo.ID

    /// The demo's page at t = 0, with every change's curve recorded.
    private func page() -> (RouterModel, Trace) {
        let model = RouterDemo.records()
        let trace = Trace()
        model.trace = { curve, animated in trace.entries.append((curve, animated)) }
        return (model, trace)
    }

    final class Trace {
        var entries: [(RouterCurve, Bool)] = []
        var curves: [RouterCurve] { entries.map(\.0) }
        var animated: [Bool] { entries.map(\.1) }
    }

    // MARK: apply

    @Test func aRecordEqualToTheOneHeldChangesNothing() throws {
        let (model, trace) = page()
        let before = model.threads
        for t in before { model.apply(.upsert(t)) }
        model.apply(.older(model.older))
        model.apply(.connection(lost: false))
        let guide = try #require(model.thread(ID.guide))
        model.apply(.reply(ID.guide, text: guide.lastLines, writing: guide.writing))
        model.apply(.named(ID.guide, guide.name))
        #expect(model.threads == before)
        #expect(trace.entries.isEmpty)
    }

    @Test func aRecordThatChangesSectionMovesAndTheSelectionFollows() throws {
        let (model, trace) = page()
        #expect(model.selection == .line(ID.settings))
        var settings = try #require(model.thread(ID.settings))
        let order = settings.order
        settings.state = .working
        settings.sentence = .init(text: "Reading SettingsView.swift")
        model.apply(.upsert(settings))
        #expect(model.thread(ID.settings)?.section == .working)
        #expect(model.thread(ID.settings)?.order != order)
        #expect(trace.curves.first == .lineMove)
        #expect(trace.animated.first == true)
        // The next line of its old section: asks, longest waiting first.
        #expect(model.selection == .line(ID.valCenis))
    }

    @Test func aMoveWithinASectionLeavesTheSelection() throws {
        let (model, trace) = page()
        model.select(.line(ID.guide))
        trace.entries = []
        var guide = try #require(model.thread(ID.guide))
        guide.worth = .quiet
        model.apply(.upsert(guide))
        #expect(trace.curves.first == .lineMove)
        #expect(model.selection == .line(ID.guide))
    }

    @Test func aRecordThatKeepsItsPlaceKeepsOrderPicksAndStream() throws {
        let (model, trace) = page()
        model.pick(2)
        model.apply(.words(ID.settings, stream: 3, text: "sidebar, one page, or tabs", done: true))
        let held = try #require(model.thread(ID.settings))
        trace.entries = []
        // The store's record: its own order and stream count, a new line from the code.
        var record = held
        record.order = 0
        record.sentence = .init(text: "which layout for Settings?", stream: 1)
        model.apply(.upsert(record))
        let now = try #require(model.thread(ID.settings))
        #expect(now.order == held.order)
        #expect(now.sentence.stream == 3)
        #expect(now.sentence.text == "which layout for Settings?")
        #expect(model.picks[ID.settings] == [0: 2])
        #expect(trace.curves == [.fade])
    }

    @Test func aStreamingLineKeepsStreamingWhenItsRecordSaysItIsAllThere() throws {
        let (model, _) = page()
        model.apply(.words(ID.bar, stream: 1, text: "pushed; PR #60", done: true))
        var record = try #require(model.thread(ID.bar))
        record.sentence.phase = .settled
        model.apply(.upsert(record))
        #expect(model.thread(ID.bar)?.sentence.phase == .streaming)
        model.streamed(ID.bar, stream: 1)
        #expect(model.thread(ID.bar)?.sentence.phase == .settled)
    }

    @Test func wordsStartGrowOrAreLate() {
        let (model, trace) = page()
        model.apply(.words(ID.guide, stream: 1, text: "rewritten", done: false))
        #expect(model.thread(ID.guide)?.sentence == .init(text: "rewritten", phase: .streaming, stream: 1))
        model.apply(.words(ID.guide, stream: 1, text: "rewritten for Chrome", done: true))
        #expect(model.thread(ID.guide)?.sentence.text == "rewritten for Chrome")
        model.apply(.words(ID.guide, stream: 0, text: "late", done: true))
        #expect(model.thread(ID.guide)?.sentence.text == "rewritten for Chrome")
        #expect(trace.entries.isEmpty)
    }

    @Test func aPullRequestFlipChangesUnanimatedSoItsWordPopsOnItsOwn() throws {
        let (model, trace) = page()
        var guide = try #require(model.thread(ID.guide))
        guide.prs = [.init(number: 41, state: .merged)]
        guide.sentence.phase = .reassessing
        model.apply(.upsert(guide))
        #expect(model.thread(ID.guide)?.prs.first?.state == .merged)
        #expect(trace.entries.isEmpty)
    }

    @Test func aNewRecordGrowsInAndARemovedOneLeaves() throws {
        let (model, trace) = page()
        let t = RouterThread(id: "fresh", name: "Fresh", title: "Fresh", project: "fjord", state: .working,
                               sentence: .init(text: "starting"), since: model.now)
        model.apply(.upsert(t))
        #expect(model.thread("fresh") != nil)
        #expect(trace.curves == [.spatial])
        model.select(.line(ID.settings))
        model.apply(.remove(ID.settings))
        #expect(model.thread(ID.settings) == nil)
        #expect(model.selection == .line(ID.valCenis))
    }

    @Test func aBatchAnimatesNothing() throws {
        let (model, trace) = page()
        var settings = try #require(model.thread(ID.settings))
        settings.state = .done
        let t = RouterThread(id: "fresh", name: "Fresh", title: "Fresh", project: nil, state: .working,
                               sentence: .init(text: "starting"), since: model.now)
        model.apply(.batch([.upsert(settings), .upsert(t), .remove(ID.bar), .connection(lost: true), .older([])]))
        #expect(!trace.entries.isEmpty)
        #expect(trace.animated.allSatisfy { !$0 })
        #expect(model.connectionLost)
        #expect(model.older.isEmpty)
        #expect(model.thread(ID.bar) == nil)
        // After it, changes animate again.
        model.apply(.connection(lost: false))
        #expect(trace.entries.last.map { $0.1 } == true)
    }

    @Test func aReadLandsThroughApply() {
        let (model, _) = page()
        model.select(nil)
        model.setDraft("bar count: push it")
        #expect(model.reading)
        model.apply(.read(RouterRead(draft: "bar count: push it", places: [.thread(ID.bar)], sure: true)))
        #expect(!model.reading)
        #expect(model.destinationThread == ID.bar)
    }

    // MARK: Acts reach the source

    /// A source that keeps every call.
    final class Recorder: RouterSource {
        enum Call: Equatable {
            case read(String, selected: String?, mentions: [RouterMention])
            case send(RouterOutgoing)
            case cancelQueued(String)
            case mint
            case start(String, words: String, project: String, launch: RouterLaunch, read: RouterRead?)
            case stop(String), visit(String), open(String)
            case settle([String], on: Bool)
            case snooze(String, until: Date?)
            case logSplit(String, sends: [RouterSend])
        }

        var calls: [Call] = []
        var sends: [RouterOutgoing] { calls.compactMap { if case .send(let out) = $0 { out } else { nil } } }

        func read(_ draft: String, selected: String?, mentions: [RouterMention]) {
            calls.append(.read(draft, selected: selected, mentions: mentions))
        }
        func send(_ out: RouterOutgoing) { calls.append(.send(out)) }
        func cancelQueued(_ thread: String) { calls.append(.cancelQueued(thread)) }
        func logSplit(_ draft: String, sends: [RouterSend]) { calls.append(.logSplit(draft, sends: sends)) }
        func mintThread() -> String {
            calls.append(.mint)
            return "minted-1"
        }
        func start(_ thread: String, words: String, project: String, launch: RouterLaunch, read: RouterRead?) {
            calls.append(.start(thread, words: words, project: project, launch: launch, read: read))
        }
        func stop(_ thread: String) { calls.append(.stop(thread)) }
        func visit(_ thread: String) { calls.append(.visit(thread)) }
        func open(_ thread: String) { calls.append(.open(thread)) }
        func settle(_ threads: [String], on: Bool) {
            calls.append(.settle(threads, on: on))
            if !on { threads.forEach(putBack) }
        }
        func snooze(_ thread: String, until: Date?) {
            calls.append(.snooze(thread, until: until))
            if until == nil { putBack(thread) }
        }

        /// A store that still has the thread: its record comes back on a Revert (`gone`: it has none).
        weak var model: RouterModel?
        var gone: Set<String> = []
        private func putBack(_ id: String) {
            guard !gone.contains(id), let model, let t = model.parked[id] else { return }
            model.apply(.upsert(t))
        }
    }

    private func recorded() -> (RouterModel, Recorder) {
        let model = RouterDemo.records()
        let source = Recorder()
        source.model = model
        model.source = source
        return (model, source)
    }

    /// The draft typed with nothing selected, and the read that lands sure for `place`.
    private func typed(_ model: RouterModel, _ words: String, to place: RouterPlace) -> RouterRead {
        model.setDraft(words)
        let read = RouterRead(draft: words, places: [place], sure: true)
        model.apply(.read(read))
        return read
    }

    @Test func aPickedOptionGoesAsAnAnswer() {
        let (model, source) = recorded()
        model.pick(2)
        model.send()
        #expect(source.calls == [.send(RouterOutgoing(thread: ID.settings, words: "One scrolling page",
                                                         kind: .answer(picks: [0: 2], typed: [:]), steering: false, queue: false))])
    }

    @Test func aFormGoesWithEveryPickAndTypedAnswer() {
        let (model, source) = recorded()
        model.select(.line(ID.updater))
        model.pick(1)
        model.setDraft("beta, but only on my machine")
        // The read is of the words: the answer's pill leading them is the card's picks, not words.
        model.apply(.read(RouterRead(draft: model.plainDraft, places: [.thread(ID.updater)], sure: true)))
        model.send()
        model.send()
        #expect(source.sends == [RouterOutgoing(thread: ID.updater, words: "Silently · beta, but only on my machine",
                                                  kind: .answer(picks: [0: 1], typed: [1: "beta, but only on my machine"]),
                                                  steering: false, queue: false)])
    }

    @Test func aStepsOptionGoesAsWords() {
        let (model, source) = recorded()
        model.select(.line(ID.valCenis))
        model.focusItem("i1")
        model.pick(1)
        model.send()
        #expect(source.sends.map(\.kind) == [.words])
        #expect(source.sends.first?.words == "Reserve for five (+€62)")
    }

    @Test func typedWordsGoWithTheReadTheRowShowedAndTheReadWithTheMentions() {
        let (model, source) = recorded()
        model.select(nil)
        // A project pill in the text: the read gets "@fjord" in the words and the pill by its place in them.
        let pill = RouterMention(range: 0..<1, pointer: .project("/code/fjord"), name: "fjord")
        model.edit(MentionText.markString + " push it and open the PR", marks: [pill])
        let words = "@fjord push it and open the PR"
        let mention = RouterMention(range: 0..<6, pointer: .project("/code/fjord"), name: "fjord")
        #expect(source.calls.contains(.read(words, selected: nil, mentions: [mention])))
        let read = RouterRead(draft: words, places: [.thread(ID.bar)], sure: true)
        model.apply(.read(read))
        model.send()
        #expect(source.sends == [RouterOutgoing(thread: ID.bar, words: words, kind: .words,
                                                  steering: false, queue: false, read: read)])
    }

    @Test func aRunningThreadIsSteeredOrQueuedAndAQueueCanBeCancelled() {
        let (model, source) = recorded()
        model.select(nil)
        _ = typed(model, "also check the log", to: .thread(ID.tab))
        model.send()
        #expect(source.sends.last?.steering == true)
        #expect(source.sends.last?.queue == false)
        _ = typed(model, "then the README", to: .thread(ID.snapshot))
        model.send(queue: true)
        #expect(source.sends.last?.thread == ID.snapshot)
        #expect(source.sends.last?.steering == false)
        #expect(source.sends.last?.queue == true)
        model.cancelQueued(ID.snapshot)
        // The words are back in the composer, so they are read again.
        #expect(source.calls.suffix(2) == [.cancelQueued(ID.snapshot), .read("then the README", selected: nil, mentions: [])])
        #expect(source.sends.count == 2)
    }

    @Test func continueOnAStoppedCard() {
        let (model, source) = recorded()
        model.select(.line(ID.disk))
        model.send()
        #expect(source.sends == [RouterOutgoing(thread: ID.disk, words: Router.Copy.continueWords, kind: .continuing,
                                                  steering: false, queue: false)])
    }

    @Test func aNewThreadTakesTheSourcesIdAndTheSettingsTheRowShowed() {
        let (model, source) = recorded()
        model.select(nil)
        let read = typed(model, "silo: write the changelog", to: .newThread(project: "silo"))
        let launch = model.launch
        model.send()
        #expect(source.calls.suffix(2) == [.mint, .start("minted-1", words: "silo: write the changelog", project: "silo",
                                                         launch: launch, read: read)])
        #expect(model.thread("minted-1")?.state == .sent)
    }

    @Test func aSendAgainKeepsWhatTheSendWas() throws {
        let (model, source) = recorded()
        model.pick(2)
        model.send()
        model.apply(.refused(ID.settings, reason: "T3 Code isn't reachable.", offline: true))
        let failure = try #require(model.failures.first)
        #expect(failure.kind == .answer(picks: [0: 2], typed: [:]))
        #expect(model.picks[ID.settings] == [0: 2])
        model.sendAgain(failure.id)
        #expect(source.sends.count == 2)
        #expect(source.sends.last == source.sends.first)
    }

    @Test func settleAndItsRevert() {
        let (model, source) = recorded()
        model.settle(ID.guide)
        #expect(source.calls == [.settle([ID.guide], on: true)])
        model.undo()
        #expect(source.calls.last == .settle([ID.guide], on: false))
        #expect(model.thread(ID.guide) != nil)
    }

    @Test func aRefusedSettleSaysWhyAndLeavesNothingToUndo() throws {
        let (model, source) = recorded()
        let line = try #require(model.thread(ID.guide))
        model.settle(ID.guide)
        // T3 refused it: the store puts the line back, the port says why.
        model.apply(.upsert(line))
        model.apply(.actRefused(ID.guide, reason: "Thread 3f2a-9c is waiting on an approval or question."))
        let toast = try #require(model.toast)
        #expect(!toast.revertible)
        // T3's own words, and the id in them, are never shown (FINAL-REVIEW #5).
        #expect(!toast.after.contains("3f2a") && !toast.after.contains("approval"))
        #expect(toast.after == "· " + Router.Copy.t3KeptIt)
        #expect(!model.canUndo)
        model.undo()
        #expect(source.calls == [.settle([ID.guide], on: true)])
        #expect(model.thread(ID.guide) != nil)
    }

    @Test func snoozeAndItsRevert() throws {
        let (model, source) = recorded()
        model.snooze(ID.valCenis, choice: 1)
        guard case .snooze(let id, let until)? = source.calls.first else { Issue.record("no snooze"); return }
        #expect(id == ID.valCenis)
        let end = try #require(until)
        #expect(abs(end.timeIntervalSinceNow - 3 * 3_600) < 60)
        model.undo()
        #expect(source.calls.last == .snooze(ID.valCenis, until: nil))
        #expect(source.calls.count == 2)
    }

    @Test func theLastSnoozeChoiceEndsTomorrowAtNine() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 23, minute: 30)))
        let end = RouterModel.snoozeEnd(2, from: now, calendar: calendar)
        #expect(calendar.dateComponents([.day, .hour, .minute], from: end) == DateComponents(day: 13, hour: 9, minute: 0))
    }

    @Test func settleAllAndItsRevert() {
        let (model, source) = recorded()
        let ids = model.older.map(\.id)
        model.settleAll()
        #expect(source.calls == [.settle(ids, on: true)])
        model.undo()
        #expect(source.calls.last == .settle(ids, on: false))
        #expect(model.older.map(\.id) == ids)
    }

    @Test func stopVisitAndOpen() {
        let (model, source) = recorded()
        model.select(.line(ID.tab))
        model.stop(ID.tab)
        model.open(ID.tab)
        // Not new: T3 isn't told of a visit (FINAL-REVIEW #17).
        #expect(source.calls == [.stop(ID.tab), .open(ID.tab)])
    }

    // MARK: A new thread's settings are T3's lists

    @Test func theChipsOfferWhatTheRowsModelTakes() {
        let (model, trace) = page()
        let codex = RouterLaunchModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", provider: "Codex", instance: "codex",
                                        efforts: [.init(rawValue: "minimal"), .low, .high], defaultEffort: .low,
                                        access: [.supervised, .full])
        model.apply(.launch(defaults: RouterLaunch.demoDefault, models: RouterLaunch.demoModels + [codex]))
        #expect(trace.curves == [.fade])
        model.select(nil)
        model.setDraft("silo: write the changelog")
        model.apply(.read(RouterRead(draft: model.draft, places: [.newThread(project: "silo")], sure: true)))
        #expect(model.launchChoices(.effort).map(\.label) == ["Low", "Medium", "High", "Extra high", "Max"])
        model.setLaunch(.model, RouterLaunch.demoModels.count)
        // Its own efforts and default; T3's default access isn't one of its modes: its first.
        #expect(model.launch == RouterLaunch(model: "gpt-6.1-sol", effort: .low, access: .supervised))
        #expect(model.launchChoices(.effort).map(\.label) == ["Minimal", "Low", "High"])
        #expect(model.launchChoices(.access).map(\.label) == ["Supervised", "Full access"])
        model.setLaunch(.effort, 2)
        #expect(model.launch.effort == .high)
        #expect(model.launchLabel(.effort) == "High")
    }

    @Test func aNameWithNoLabelIsShownAsItsWords() {
        #expect(RouterLaunch.Access(rawValue: "on-request").label == "On request")
        #expect(RouterLaunch.Effort(rawValue: "xhigh").label == "Extra high")
    }

    // MARK: Picks belong to one ask (FINAL-REVIEW #1)

    @Test func aPickKeptFromAnAskAnsweredElsewhereNeitherCrashesNorCarriesOver() throws {
        let (model, _) = page()
        var settings = try #require(model.thread(ID.settings))
        settings.askID = "q1"
        model.apply(.upsert(settings))
        model.select(.line(ID.settings))
        model.pick(2)
        #expect(model.destination == .picked(thread: ID.settings, words: "One scrolling page"))
        // Answered in T3 instead: the line works on, its options gone. The pick goes with the ask.
        var working = settings
        working.state = .working
        working.options = []
        working.askID = nil
        model.apply(.upsert(working))
        #expect(model.picks[ID.settings] == nil)
        model.select(.line(ID.settings))
        #expect(model.destination == nil)
        // A second ask on the same card: nothing is picked for it.
        var again = settings
        again.askID = "q2"
        again.options = ["Allow once"]
        model.apply(.upsert(settings))
        model.select(.line(ID.settings))
        model.pick(3)
        model.apply(.upsert(again))
        #expect(model.picks[ID.settings] == nil)
        #expect(model.destination == nil)
        // A pick past the card's options (kept by any other path) reads as no pick, never an index out of range.
        model.picks[ID.settings] = [0: 3]
        #expect(model.answerWords(try #require(model.thread(ID.settings))) == nil)
    }

    @Test func aLineThatLeavesTakesItsPicksWithIt() throws {
        let (model, _) = page()
        model.select(.line(ID.settings))
        model.pick(1)
        model.apply(.remove(ID.settings))
        #expect(model.picks[ID.settings] == nil)
        #expect(model.typed[ID.settings] == nil)
    }

    // MARK: A place that sends nothing keeps the words (FINAL-REVIEW #3)

    @Test func returnOnAPlaceThatSendsNothingKeepsTheDraft() {
        let (model, _) = page()
        model.select(nil)
        model.setDraft("what runs now?")
        model.apply(.read(RouterRead(draft: model.draft, places: [.here], sure: true)))
        model.send()
        #expect(model.draft == "what runs now?")
    }

    // MARK: Settle and Snooze where T3 refuses them (FINAL-REVIEW #5)

    @Test func aRequestOrARunningLineIsNeitherSettledNorSnoozedAndCmdBackspaceOnlySaysWhy() throws {
        let (model, source) = recorded()
        let settings = try #require(model.thread(ID.settings))
        #expect(settings.state == .needsYou(.question))
        #expect(model.holdReason(settings) == Router.Copy.answerOrStopFirst)
        model.select(.line(ID.settings))
        model.settleSelected()
        #expect(model.thread(ID.settings) != nil)
        #expect(source.calls.isEmpty)
        #expect(model.toast?.revertible == false)
        #expect(model.toast?.after == "· " + Router.Copy.answerOrStopFirst)
        #expect(!model.canUndo)
        model.settle(ID.settings)
        model.snooze(ID.settings, choice: 0)
        model.openSnooze()
        #expect(model.snoozeMenu == nil)
        #expect(source.calls.isEmpty)
        let working = try #require(model.threads.first { $0.state == .working })
        #expect(model.holdReason(working) != nil)
        // A step Fjord found, a Done line: free to go.
        #expect(model.holdReason(try #require(model.thread(ID.valCenis))) == nil)
    }

    // MARK: A Revert goes through the store, ⌘Z only while its toast is up (FINAL-REVIEW #13)

    @Test func aRevertOfAThreadTheStoreNoLongerHasBringsNoGhostLine() {
        let (model, source) = recorded()
        source.gone = [ID.guide]
        model.settle(ID.guide)
        model.undo()
        #expect(source.calls.last == .settle([ID.guide], on: false))
        #expect(model.thread(ID.guide) == nil)
        #expect(model.threads.filter { $0.id == ID.guide }.isEmpty)
    }

    @Test func cmdZReachesOnlyTheActWhoseToastIsUp() {
        let (model, source) = recorded()
        model.settle(ID.guide)
        #expect(model.canUndo)
        model.dismissToast()
        #expect(!model.canUndo)
        model.undo()
        #expect(source.calls == [.settle([ID.guide], on: true)])
        #expect(model.thread(ID.guide) == nil)
    }

    // MARK: Words to a line still Sent are a message, not a steer (FINAL-REVIEW #14)

    @Test func aSecondMessageToAThreadJustSentToIsNoSteer() throws {
        let (model, source) = recorded()
        let guide = try #require(model.thread(ID.guide))
        model.dispatch("first", to: guide, kind: .words)
        let sent = try #require(model.thread(ID.guide))
        #expect(sent.state == .sent)
        model.dispatch("second", to: sent, kind: .words)
        #expect(source.sends.map(\.steering) == [false, false])
        #expect(model.thread(ID.guide)?.sent?.status == .sending)
        // Into a run under way, a steer.
        let working = try #require(model.threads.first { $0.state == .working })
        model.dispatch("faster", to: working, kind: .words)
        #expect(source.sends.last?.steering == true)
    }

    // MARK: A refusal after the record moved still shows (FINAL-REVIEW #15)

    @Test func aRefusalThatComesAfterTheRecordMovedStillShowsItsFailureLine() throws {
        let (model, _) = recorded()
        let guide = try #require(model.thread(ID.guide))
        model.dispatch("merge it", to: guide, kind: .words)
        // A shell event ends the pending send first: the record is back to Done, no Sent words on it.
        model.apply(.upsert(guide))
        #expect(model.thread(ID.guide)?.sent == nil)
        model.apply(.refused(ID.guide, reason: "T3 isn't reachable", offline: false))
        #expect(model.failures.map(\.words) == ["merge it"])
        #expect(model.failures.first?.thread == ID.guide)
    }
}
