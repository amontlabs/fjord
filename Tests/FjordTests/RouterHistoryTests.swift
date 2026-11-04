import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fjord

/// The Router page's history in a window: where it sits as lines arrive, open and are asked for.
@MainActor
@Suite(.hostsWindows) struct RouterHistoryTests {
    @Test func atTheBottomMeansWithinTheSlackOfIt() {
        #expect(HistoryPin.atBottom(1000, visibleBottom: 1000))
        #expect(HistoryPin.atBottom(1000, visibleBottom: 1000 - HistoryPin.slack))
        #expect(!HistoryPin.atBottom(1000, visibleBottom: 1000 - HistoryPin.slack - 1))
        // Shorter than its view: at the bottom.
        #expect(HistoryPin.atBottom(200, visibleBottom: 600))
    }

    @Test func onlyAScrollTakesTheHistoryOffItsBottom() {
        // A line arrives, one opens, the composer grows: no scroll, and a pinned history short of its bottom goes back there.
        #expect(HistoryPin.next(pinned: true, scrolling: false, .init(content: 1200, visibleBottom: 1000)) == .stick)
        #expect(HistoryPin.next(pinned: true, scrolling: false, .init(content: 1200, visibleBottom: 1185)) == .stick)
        #expect(HistoryPin.next(pinned: true, scrolling: false, .init(content: 1200, visibleBottom: 1200)) == .stay)
        #expect(HistoryPin.next(pinned: true, scrolling: false, .init(content: 200, visibleBottom: 600)) == .stay)
        // Scrolled up, nothing but a scroll moves it.
        #expect(HistoryPin.next(pinned: false, scrolling: false, .init(content: 1200, visibleBottom: 600)) == .stay)
        // A scroll sets it, either way.
        #expect(HistoryPin.next(pinned: true, scrolling: true, .init(content: 1000, visibleBottom: 700)) == .pin(false))
        #expect(HistoryPin.next(pinned: false, scrolling: true, .init(content: 1000, visibleBottom: 990)) == .pin(true))
    }

    @Test func whatShowsMovingAloneIsAScroll() {
        func reading(content: CGFloat, bottom: CGFloat, inset: CGFloat = 0) -> HistoryPin.Reading {
            .init(geometry: .init(content: content, visibleBottom: bottom),
                  frame: .init(content: CGSize(width: 600, height: content), container: CGSize(width: 600, height: 400),
                               insets: EdgeInsets(top: 0, leading: 0, bottom: inset, trailing: 0)))
        }
        // Moved, all else the same: a scroll, whatever the phase says.
        #expect(HistoryPin.scrolled(from: reading(content: 1000, bottom: 1000), to: reading(content: 1000, bottom: 990)))
        // A line arriving, the composer growing: layout.
        #expect(!HistoryPin.scrolled(from: reading(content: 1000, bottom: 1000), to: reading(content: 1040, bottom: 1000)))
        #expect(!HistoryPin.scrolled(from: reading(content: 1000, bottom: 1000), to: reading(content: 1000, bottom: 960, inset: 40)))
    }

    /// On macOS 26 the composer floats over the history, its height the scroll's bottom inset: the bottom of what shows is
    /// above it, so a history resting with its last lines under the composer is not at its bottom and goes back there.
    @Test func theComposersInsetIsNotWhatShows() {
        let inset: CGFloat = 80
        // Scrolled right to the end: the last line just above the composer.
        let end = HistoryPin.geometry(1200, visibleMaxY: 1200 + inset, bottomInset: inset)
        #expect(end == HistoryPin.Geometry(content: 1200, visibleBottom: 1200))
        #expect(HistoryPin.atBottom(end.content, visibleBottom: end.visibleBottom))
        #expect(HistoryPin.next(pinned: true, scrolling: false, end) == .stay)
        // The last 80 under the composer: pinned, it sticks back to the end; a scroll that stops there unpins it.
        let under = HistoryPin.geometry(1200, visibleMaxY: 1200, bottomInset: inset)
        #expect(HistoryPin.next(pinned: true, scrolling: false, under) == .stick)
        #expect(HistoryPin.next(pinned: true, scrolling: true, under) == .pin(false))
        // No inset (macOS 14 and 15, the composer under the page): as before.
        #expect(HistoryPin.geometry(1200, visibleMaxY: 1000, bottomInset: 0) == HistoryPin.Geometry(content: 1200, visibleBottom: 1000))
    }

    /// macOS 14's history: its scroll view says when you scroll, so scrolling up unpins it (and the lines drawn stay).
    @Test func onMacOS14AScrollUpUnpinsTheHistoryAndLayoutDoesNot() {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let document = Flipped(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        var seen: [(HistoryPin.Geometry, Bool)] = []
        let observer = HistoryScrollObserver(scrollView) { seen.append(($0, $1)) }
        defer { withExtendedLifetime(observer) {} }
        // At the bottom, then scrolled up by you.
        document.scroll(NSPoint(x: 0, y: 700))
        document.scroll(NSPoint(x: 0, y: 200))
        #expect(seen.count == 2)
        #expect(seen.last.map { $0.1 && $0.0 == HistoryPin.Geometry(content: 1000, visibleBottom: 500) } == true)
        #expect(seen.last.map { HistoryPin.next(pinned: true, scrolling: $0.1, $0.0) } == .pin(false))
        // Back to the bottom: pinned again.
        document.scroll(NSPoint(x: 0, y: 700))
        #expect(seen.last.map { HistoryPin.next(pinned: false, scrolling: $0.1, $0.0) } == .pin(true))
        // A line arrives while pinned (the content grows, what shows moves): layout, not a scroll; back to the bottom.
        let before = seen.count
        document.setFrameSize(NSSize(width: 200, height: 1100))
        document.scroll(NSPoint(x: 0, y: 750))
        let layout = seen.dropFirst(before).first
        #expect(layout.map { !$0.1 } == true)
        #expect(layout.map { HistoryPin.next(pinned: true, scrolling: $0.1, $0.0) } == .stick)
    }

    @Test func linesShownEarlierStayWhenTheOldestGoPastWhatIsKept() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let all = (0..<300).map { i in
            RouterPage.Entry.decision(RouterDecision(at: start.addingTimeInterval(Double(i) * 60), trigger: .you("message \(i)")))
        }
        // At the bottom: the newest page.
        #expect(HistoryWindow.drawn(all, from: nil, page: 100).first?.id == all[200].id)
        // Show earlier drew from line 50 on.
        let boundary = HistoryWindow.Boundary(all[50])
        #expect(HistoryWindow.drawn(all, from: boundary, page: 100).startIndex == 50)
        // Retention drops the first 60 lines, the boundary with them: what followed it holds the top, not the newest 100.
        let kept = Array(all.dropFirst(60))
        let drawn = HistoryWindow.drawn(kept, from: boundary, page: 100)
        #expect(drawn.first?.id == all[60].id && drawn.count == 240)
        // Retention drops only the boundary: the line after it.
        let without = all.filter { $0.id != all[50].id }
        #expect(HistoryWindow.drawn(without, from: boundary, page: 100).first?.id == all[51].id)
    }

    /// A store whose history is long (300 runs) and whose Needs you is empty, so the history has the room.
    private func store() -> Store {
        let store = Store()
        Demo.populate(store, .router)
        store.interceptOpen = { _ in }
        var state = store.router
        let start = Date().addingTimeInterval(-3 * 86400)
        for i in 0..<300 {
            state.decisions.append(RouterDecision(at: start.addingTimeInterval(Double(i) * 60), trigger: .you("message \(i)"),
                                                  decision: .init(intent: "message"), outcome: .done))
        }
        state.cards = state.cards.map { var c = $0; if c.isOpen { c.addressedAt = start; c.addressedBy = .you }; return c }
        store.router = state
        return store
    }

    private struct Geometry: Equatable {
        var top: Int
        var fromBottom: Int
        var height: Int
    }

    /// The history: of the page's scrolls, the one holding the most.
    private static func history(in hosting: NSView) -> NSScrollView? {
        func scrolls(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls) }
        return scrolls(hosting).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    /// How far the history's end is below the bottom of what shows, read as its pin reads it (`HistoryPin.geometry`): on
    /// macOS 26 the composer floats over the history, its height the scroll's bottom inset, and what is under it doesn't show.
    /// 0 at the bottom; nil while the history isn't laid out.
    private static func fromBottom(_ hosting: NSView) -> Int? {
        hosting.layoutSubtreeIfNeeded()
        guard let view = history(in: hosting), let doc = view.documentView, doc.frame.height > 0 else { return nil }
        let shown = HistoryPin.geometry(doc.frame.height, visibleMaxY: view.contentView.bounds.maxY,
                                        bottomInset: view.contentInsets.bottom)
        return Int((shown.content - shown.visibleBottom).rounded())
    }

    @Test(.disabled("The Router window shows the brief (RouterBriefView); the old Now, history and canvas views go in a later step")) func itOpensAtTheBottomFollowsWhileThereAndHoldsWhileScrolledUp() async throws {
        let store = store()
        let model = RouterModel()
        model.layout = .list
        let hosting = NSHostingView(rootView: RouterCodeView(store: store, model: model, checksClaudeCode: false)
            .frame(width: 1100, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.orderOut(nil) }

        func history() -> NSScrollView? { Self.history(in: hosting) }
        func geometry() -> Geometry {
            guard let fromBottom = Self.fromBottom(hosting), let view = history(), let doc = view.documentView else {
                return Geometry(top: 0, fromBottom: 0, height: 0)
            }
            return Geometry(top: Int(view.contentView.bounds.minY), fromBottom: fromBottom, height: Int(doc.frame.height))
        }
        func settled() async -> Geometry {
            // The scroll to a line is animated (0.12 s) and the lines under it lay out after: a second of no change, not
            // just a few turns, which a stalled machine passes before the animation has moved.
            await waitUntilSteady(turns: 8, quiet: 1) { geometry() }
            return geometry()
        }
        func line(_ text: String) { store.logDecision(RouterDecision(at: Date(), trigger: .you(text), outcome: .done)) }

        await waitUntil { history() != nil }
        let start = await settled()
        #expect(start.height > 0 && abs(start.fromBottom) <= 1, "opens at the bottom: \(start)")
        // Only the newest lines are drawn: far less than 300 lines' worth.
        #expect(start.height < 100 * 40, "\(start)")

        // At the bottom, a new line keeps it there.
        line("arrives at the bottom")
        let followed = await settled()
        #expect(abs(followed.fromBottom) <= 1, "\(followed)")

        // Asked for an old line, it scrolls up to it (drawing the lines down from it); a line arriving then moves nothing.
        let old = store.routerHistory[store.routerHistory.count - 160].id
        model.reveal(old, highlight: false)
        let up = await settled()
        #expect(up.fromBottom > 1000 && up.height > start.height, "\(up)")
        line("arrives while reading")
        let held = await settled()
        #expect(held.top == up.top, "\(up) → \(held)")

        // Back to the bottom (the Router picked), then clicking the newest card's line opens it there.
        model.select(nil, store: store)
        let back = await settled()
        #expect(abs(back.fromBottom) <= 1, "\(back)")
        var card = RouterCard(id: "history#newest", sessionID: store.router.cards[0].sessionID, kind: .done, title: "Newest",
                              folder: nil, text: "What was done.", createdAt: Date())
        card.addressedAt = Date()
        card.addressedBy = .you
        store.router.cards.append(card)
        _ = await settled()
        model.tap(card.id, store: store)
        let opened = await settled()
        #expect(model.expanded.contains(card.id) && opened.height > back.height && abs(opened.fromBottom) <= 1, "\(back) → \(opened)")
    }

    /// A scroll asked for while you scroll (here the Router picking, which goes to the bottom) leaves SwiftUI's scroll phase
    /// idle for the rest of your gesture: each step of it was read as layout leaving the pinned history short of its bottom,
    /// and stuck back there, so the lines stayed put while only the hover moved from line to line under the pointer.
    @Test(.disabled("The Router window shows the brief (RouterBriefView); the old Now, history and canvas views go in a later step")) func yourScrollGoesOnAfterAScrollAskedForDuringIt() async throws {
        let store = store()
        let model = RouterModel()
        model.layout = .list
        let hosting = NSHostingView(rootView: RouterCodeView(store: store, model: model, checksClaudeCode: false)
            .frame(width: 1100, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // A scroll view moves on its display's frames: the window is on a screen by one point at its corner, and unseen.
        let screen = try #require(NSScreen.screens.first).frame
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: screen.minX - 1099, y: screen.minY - 899))
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.orderOut(nil) }

        func history() -> NSScrollView? { Self.history(in: hosting) }
        func fromBottom() -> Int { Self.fromBottom(hosting) ?? .min }
        /// A trackpad's step over the history, `dy` up: an event with no window is placed by its screen point, given as the
        /// window's own.
        func wheel(_ dy: Double, _ phase: CGScrollPhase) async throws {
            let view = try #require(history())
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy),
                                             wheel2: 0, wheel3: 0))
            event.location = CGPoint(x: point.x, y: screen.height - point.y)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            window.sendEvent(try #require(NSEvent(cgEvent: event)))
            // About a frame's time: the scroll view moves on the next one.
            try await Task.sleep(for: .milliseconds(8))
        }

        await waitUntil { history() != nil }
        await waitUntilSteady(turns: 8, quiet: 0.5) { fromBottom() }
        let bottom = fromBottom()
        // A few points up, still within the bottom's slack, and the Router picks (the bottom) as you go on.
        try await wheel(0, .mayBegin)
        try await wheel(4, .began)
        for _ in 0..<2 { try await wheel(4, .changed) }
        model.select(nil, store: store)
        var seen: [Int] = []
        for _ in 0..<40 {
            try await wheel(6, .changed)
            seen.append(fromBottom())
        }
        try await wheel(0, .ended)
        await waitUntilSteady(turns: 8, quiet: 0.5) { fromBottom() }
        #expect(fromBottom() > bottom + 150, "your scroll went up and stayed: \(seen) → \(fromBottom())")
    }

    @Test(.disabled("The Router window shows the brief (RouterBriefView); the old Now, history and canvas views go in a later step")) func aMessageAskedForBeforeThePageShowsIsWhereItOpensAndOnlyThatOnce() async {
        let store = store()
        let model = RouterModel()
        model.layout = .list
        // An action's chip, clicked before the page is drawn: a message far up the log.
        let message = store.router.decisions[store.router.decisions.count - 200].id
        model.show(message: message)
        func render() -> (NSHostingView<some View>, NSWindow) {
            let hosting = NSHostingView(rootView: RouterCodeView(store: store, model: model, checksClaudeCode: false)
                .frame(width: 1100, height: 900))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderFrontRegardless()
            return (hosting, window)
        }
        do {
            let (hosting, window) = render()
            defer { window.contentView = nil; window.orderOut(nil) }
            await waitUntil { (Self.fromBottom(hosting) ?? 0) > 1000 }
            await waitUntilSteady(turns: 8) { Self.fromBottom(hosting) }
            #expect((Self.fromBottom(hosting) ?? 0) > 1000, "the page opened on the message, far above the bottom")
        }
        // The page left and come back to: it opens at the bottom, not on the message it went to before.
        let (hosting, window) = render()
        defer { window.contentView = nil; window.orderOut(nil) }
        await waitUntil { Self.fromBottom(hosting) != nil }
        await waitUntilSteady(turns: 8) { Self.fromBottom(hosting) }
        #expect(Self.fromBottom(hosting).map { abs($0) <= 1 } == true, "opens at the bottom: \(String(describing: Self.fromBottom(hosting)))")
    }

    @Test(.disabled("The Router window shows the brief (RouterBriefView); the old Now, history and canvas views go in a later step")) func aLineAskedForBeforeThePageShowsIsWhereItOpensAndOnlyThatOnce() async {
        let store = store()
        let model = RouterModel()
        model.layout = .list
        // A banner clicked before the page is drawn: a line far up the history, outside the newest drawn.
        model.reveal(store.routerHistory[store.routerHistory.count - 160].id, highlight: false)
        func render() -> (NSHostingView<some View>, NSWindow) {
            let hosting = NSHostingView(rootView: RouterCodeView(store: store, model: model, checksClaudeCode: false)
                .frame(width: 1100, height: 900))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderFrontRegardless()
            return (hosting, window)
        }
        do {
            let (hosting, window) = render()
            defer { window.contentView = nil; window.orderOut(nil) }
            await waitUntil { (Self.fromBottom(hosting) ?? 0) > 1000 }
            await waitUntilSteady(turns: 8) { Self.fromBottom(hosting) }
            #expect((Self.fromBottom(hosting) ?? 0) > 1000, "the page opened on the line, far above the bottom")
        }
        // The page left and come back to: it opens at the bottom, not on the line it went to before.
        let (hosting, window) = render()
        defer { window.contentView = nil; window.orderOut(nil) }
        await waitUntil { Self.fromBottom(hosting) != nil }
        await waitUntilSteady(turns: 8) { Self.fromBottom(hosting) }
        #expect(Self.fromBottom(hosting).map { abs($0) <= 1 } == true, "opens at the bottom: \(String(describing: Self.fromBottom(hosting)))")
    }

    @Test(.disabled("The Router window shows the brief (RouterBriefView); the old Now, history and canvas views go in a later step")) func aCardAskedForBeforeThePageShowsIsScrolledToInNeedsYou() async {
        let store = Store()
        Demo.populate(store, .router)
        store.interceptOpen = { _ in }
        let open = store.router.cards.filter(\.isOpen)
        store.router.cards += (1...5).flatMap { n in open.map { var c = $0; c.id += "#copy\(n)"; return c } }
        let model = RouterModel()
        model.layout = .list
        // The last of Needs you, far below what it shows, asked for before the page is drawn.
        guard let last = store.routerZones.needs.last else { Issue.record("no cards"); return }
        model.reveal(last.id, highlight: false)
        let hosting = NSHostingView(rootView: RouterCodeView(store: store, model: model, checksClaudeCode: false)
            .frame(width: 1100, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.orderOut(nil) }
        func scrolls(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls) }
        /// Needs you: the scroll, under the history, holding the most.
        func needsOffset() -> Int? {
            hosting.layoutSubtreeIfNeeded()
            let all = scrolls(hosting).filter { $0.frame.height > 0 }
            guard let top = all.max(by: { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY }),
                  let needs = all.filter({ $0 !== top }).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
            else { return nil }
            return Int(needs.contentView.bounds.minY)
        }
        await waitUntil { (needsOffset() ?? 0) > 100 }
        await waitUntilSteady(turns: 8) { needsOffset() }
        #expect((needsOffset() ?? 0) > 100, "Needs you scrolled down to the card")
    }

    @Test(.disabled("The Router window shows the brief (RouterBriefView); the old Now, history and canvas views go in a later step")) func aLongNeedsYouLeavesTheHistoryItsFloor() async {
        let store = Store()
        Demo.populate(store, .router)
        store.interceptOpen = { _ in }
        // Every open card six times over: far more than the page holds.
        let open = store.router.cards.filter(\.isOpen)
        store.router.cards += (1...5).flatMap { n in open.map { var c = $0; c.id += "#copy\(n)"; return c } }
        let model = RouterModel()
        model.layout = .list
        let hosting = NSHostingView(rootView: RouterCodeView(store: store, model: model, checksClaudeCode: false)
            .frame(width: 1100, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900), styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.orderOut(nil) }
        func scrolls(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls) }
        /// The history is the topmost scroll; Needs you the one holding the most of the others (an open form and the
        /// composer scroll too).
        func frames() -> (history: NSRect, needs: NSRect, needsContent: CGFloat)? {
            hosting.layoutSubtreeIfNeeded()
            let all = scrolls(hosting).filter { $0.frame.height > 0 }.map { ($0.convert($0.bounds, to: nil), $0.documentView?.frame.height ?? 0) }
            guard let top = all.max(by: { $0.0.maxY < $1.0.maxY }),
                  let low = all.filter({ $0.0 != top.0 }).max(by: { $0.1 < $1.1 }) else { return nil }
            return (top.0, low.0, low.1)
        }
        await waitUntil { frames() != nil }
        await waitUntilSteady(turns: 8) { frames().map { [Int($0.history.height), Int($0.needs.height)] } ?? [] }
        guard let f = frames() else { Issue.record("no scrolls"); return }
        #expect(f.history.height >= 140, "the history keeps a few lines: \(f.history)")
        #expect(f.needsContent > f.needs.height + 100, "Needs you scrolls inside: \(f.needs.height) of \(f.needsContent)")
        #expect(f.needs.height >= 120, "\(f.needs)")
    }
}
