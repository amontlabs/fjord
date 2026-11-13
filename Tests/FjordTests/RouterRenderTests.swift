import AppKit
import SwiftUI
import Testing
@testable import Fjord

/// Router v2's rendering (docs/design/router-v2/IMPLEMENTATION.md 2.2, 2.4 "One record"): a change redraws what it
/// changes. The page is hosted in a window off screen; each component counts its body evaluations under test
/// (`RouterBodies`), and a test applies one change and reads which bodies ran.
@MainActor
@Suite(.serialized, .hostsWindows) struct RouterRenderTests {
    private typealias ID = RouterDemo.ID

    /// The demo's page drawn in a window, settled.
    private func hosted() async -> (RouterModel, NSWindow) {
        RouterBodies.reset()
        let model = RouterDemo.records(still: true)
        let hosting = NSHostingView(rootView: RouterScreen(model: model).frame(width: 1280, height: 960))
        let window = AwayWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 960), styleMask: .titled, backing: .buffered,
                                defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFront(nil)
        await waitUntil { RouterBodies["list"] > 0 }
        await settle()
        return (model, window)
    }

    /// Lets the turn's end and SwiftUI's update run until no body runs any more.
    private func settle() async {
        await waitUntilSteady(turns: 6) { RouterBodies.counts }
    }

    /// Runs `change` on the settled page and returns the bodies it ran.
    private func bodies(_ model: RouterModel, _ change: () -> Void) async -> [String: Int] {
        RouterBodies.reset()
        change()
        await settle()
        return RouterBodies.counts
    }

    @Test func onlyTheOpenCardIsBuilt() async {
        // Settings is selected in the demo: its card is the one with a body; every line drew once.
        let (model, window) = await hosted()
        defer { window.close() }
        #expect(RouterBodies["card"] >= 1)
        #expect(RouterBodies["card"] == RouterBodies["card", ID.settings])
        #expect(RouterBodies["line"] >= model.threads.count)
    }

    @Test func anUpsertThatKeepsTheOrderRunsOneLineBodyAndNoListBody() async throws {
        let (model, window) = await hosted()
        defer { window.close() }
        var guide = try #require(model.thread(ID.guide))
        guide.isNew.toggle()
        guide.title = "Rewrite the install guide for Chrome"
        let ran = await bodies(model) { model.apply(.upsert(guide)) }
        #expect(ran["line"] == 1)
        #expect(ran["line:" + ID.guide] == 1)
        #expect(ran["list"] == nil)
    }

    @Test func anUpsertThatMovesALineRunsTheList() async throws {
        let (model, window) = await hosted()
        defer { window.close() }
        var guide = try #require(model.thread(ID.guide))
        guide.state = .working
        guide.sentence = .init(text: "Reading README.md")
        let ran = await bodies(model) { model.apply(.upsert(guide)) }
        #expect((ran["list"] ?? 0) >= 1)
    }

    @Test func aHoverFromOneRowToAnotherRunsTwoLineBodies() async {
        let (model, window) = await hosted()
        defer { window.close() }
        model.hoverRow = ID.guide
        await settle()
        let ran = await bodies(model) { model.hoverRow = ID.bar }
        #expect(ran["line"] == 2)
        #expect(ran["line:" + ID.guide] == 1)
        #expect(ran["line:" + ID.bar] == 1)
        #expect(ran["list"] == nil)
    }

    @Test func selectingAnotherLineRunsTwoLinesAndBuildsOneCard() async {
        let (model, window) = await hosted()
        defer { window.close() }
        #expect(model.selection == .line(ID.settings))
        let ran = await bodies(model) { model.select(.line(ID.guide)) }
        #expect(ran["card"] == 1)
        #expect(ran["card:" + ID.guide] == 1)
        #expect(ran["line:" + ID.settings] ?? 0 >= 1)
        #expect(ran["line:" + ID.guide] ?? 0 >= 1)
        // The two lines whose flags changed, and none other.
        let lines = ran.keys.filter { $0.hasPrefix("line:") }
        #expect(Set(lines) == ["line:" + ID.settings, "line:" + ID.guide], "\(ran)")
        #expect(ran["list"] == nil)
        // The card that closed has no body once its roll has ended: opening it again builds it again.
        let again = await bodies(model) { model.select(.line(ID.settings)) }
        #expect(again["card:" + ID.settings] == 1)
    }

    @Test func wordsRunThatLinesSentenceOnly() async throws {
        let (model, window) = await hosted()
        defer { window.close() }
        let tab = try #require(model.thread(ID.tab))
        let ran = await bodies(model) {
            model.apply(.words(ID.tab, stream: tab.sentence.stream + 1, text: "re-measured the composer", done: true))
        }
        #expect(ran["sentence:" + ID.tab] ?? 0 >= 1)
        #expect(ran["sentence"] == ran["sentence:" + ID.tab])
        #expect(ran["line"] == nil)
        #expect(ran["card"] == nil)
        #expect(ran["list"] == nil)
    }

    @Test func aGrowingReplyRunsItsLastLinesOnly() async throws {
        let (model, window) = await hosted()
        defer { window.close() }
        model.select(.line(ID.tab))
        model.apply(.reply(ID.tab, text: "The draft now survives", writing: true))
        await settle()
        let ran = await bodies(model) { model.apply(.reply(ID.tab, text: "The draft now survives the handover", writing: true)) }
        #expect(ran["lastLines:" + ID.tab] == 1)
        #expect(ran["card"] == nil)
        #expect(ran["line"] == nil)
    }

    @Test func threeWordsForOneThreadInOneTurnFlushOnce() async throws {
        let (model, window) = await hosted()
        defer { window.close() }
        let tab = try #require(model.thread(ID.tab))
        let stream = tab.sentence.stream + 1
        RouterBodies.reset()
        model.post(.words(ID.tab, stream: stream, text: "re-measured", done: false))
        model.post(.words(ID.tab, stream: stream, text: "re-measured the composer", done: false))
        model.post(.words(ID.tab, stream: stream, text: "re-measured the composer against T3", done: true))
        // Kept for the turn's end: nothing applied yet.
        #expect(model.thread(ID.tab)?.sentence.text == tab.sentence.text)
        await waitUntil { model.thread(ID.tab)?.sentence.text == "re-measured the composer against T3" }
        #expect(RouterBodies["flush"] == 1)
        await settle()
        #expect(RouterBodies["line"] == 0)
    }

    @Test func anotherChangeAppliesAfterWhatWasKept() throws {
        let model = RouterDemo.records(still: true)
        let tab = try #require(model.thread(ID.tab))
        model.post(.words(ID.tab, stream: tab.sentence.stream + 1, text: "re-measured", done: true))
        model.post(.remove(ID.tab))
        #expect(model.thread(ID.tab) == nil)
        model.finishTurn()
        #expect(model.thread(ID.tab) == nil)
    }

    @Test func growingWordsKeepTheirLineAndSettleOnlyWhenDone() throws {
        let model = RouterDemo.records(still: true)
        let box = model.box(ID.tab)
        let stream = try #require(model.thread(ID.tab)).sentence.stream + 1
        model.apply(.words(ID.tab, stream: stream, text: "re-measured", done: false))
        let line = box.sentenceID
        model.apply(.words(ID.tab, stream: stream, text: "re-measured the composer", done: false))
        #expect(box.sentenceID == line)
        #expect(!box.complete)
        // Drawn so far, but more are coming: it keeps streaming.
        model.streamed(ID.tab, stream: stream)
        #expect(model.thread(ID.tab)?.sentence.phase == .streaming)
        model.apply(.words(ID.tab, stream: stream, text: "re-measured the composer", done: true))
        #expect(box.complete)
        model.streamed(ID.tab, stream: stream)
        #expect(model.thread(ID.tab)?.sentence.phase == .settled)
        // A new stream is another line of words.
        model.apply(.words(ID.tab, stream: stream + 1, text: "measured again", done: true))
        #expect(box.sentenceID != line)
    }

    @Test func theLayoutAndCountsFollowTheRecords() throws {
        let model = RouterDemo.records(still: true)
        let before = model.layout
        var guide = try #require(model.thread(ID.guide))
        guide.isNew.toggle()
        model.apply(.upsert(guide))
        #expect(model.layout == before)
        let needsYou = model.needsYou
        guide.state = .needsYou(.question)
        model.apply(.upsert(guide))
        #expect(model.needsYou == needsYou + 1)
        #expect(model.layout != before)
        #expect(model.rows().map(\.id) == model.layout.map(\.id))
        #expect(model.shownLines.map(\.id) == model.layout.compactMap { if case .line(let id) = $0.kind { id } else { nil } })
    }
}
