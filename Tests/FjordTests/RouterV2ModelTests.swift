import Foundation
import Testing
@testable import Fjord

/// Router v2's seam (docs/design/router-v2/IMPLEMENTATION.md 1.2): the page takes whole records through `apply`, and
/// every act that leaves the page reaches its source once, with what it needs.
@MainActor
@Suite struct RouterV2ModelTests {
    private typealias ID = RouterV2Demo.ID

    /// The demo's page at t = 0, with every change's curve recorded.
    private func page() -> (RouterV2Model, Trace) {
        let model = RouterV2Demo.records()
        let trace = Trace()
        model.trace = { curve, animated in trace.entries.append((curve, animated)) }
        return (model, trace)
    }

    final class Trace {
        var entries: [(RouterV2Curve, Bool)] = []
        var curves: [RouterV2Curve] { entries.map(\.0) }
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
        let t = RouterV2Thread(id: "fresh", name: "Fresh", title: "Fresh", project: "fjord", state: .working,
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
        let t = RouterV2Thread(id: "fresh", name: "Fresh", title: "Fresh", project: nil, state: .working,
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
        model.apply(.read(RouterV2Read(draft: "bar count: push it", places: [.thread(ID.bar)], sure: true)))
        #expect(!model.reading)
        #expect(model.destinationThread == ID.bar)
    }
}
