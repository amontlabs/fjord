import AppKit
import SwiftUI
import Testing
@testable import Fjord

/// The filter bar's state tokens filter the page (docs/design/router-v2/DESIGN.md 1.2, 4): one project × one state, the
/// counts faceted. Pressed as the drawn pointer and a click press them: the token's own registered action.
@MainActor
@Suite(.serialized, .hostsWindows) struct RouterFilterTests {
    private func hosted() async -> (RouterModel, NSWindow) {
        RouterBodies.reset()
        let model = RouterDemo.records(still: true)
        model.select(nil)
        let hosting = NSHostingView(rootView: RouterScreen(model: model).frame(width: 1280, height: 960))
        let window = AwayWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 960), styleMask: .titled, backing: .buffered,
                                defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFront(nil)
        await waitUntil { RouterBodies["list"] > 0 }
        await waitUntilSteady(turns: 6) { RouterBodies.counts }
        return (model, window)
    }

    @Test func pressingAStateTokenFiltersByThatState() async throws {
        let (model, window) = await hosted()
        defer { window.close() }
        let done = model.count(section: .done)
        let press = try #require(model.targets.actions[.state(.done)])
        press()
        #expect(model.section == .done)
        #expect(!model.shownLines.isEmpty)
        #expect(model.shownLines.allSatisfy { $0.section == .done })
        #expect(model.shownLines.count == done)
        // Faceted: All counts its lines under the state; the other tokens keep their own counts.
        #expect(model.count(project: nil) == done)
        #expect(model.count(section: .needsYou) > 0)
        // With a project: one project × one state.
        model.toggle(project: "fjord")
        #expect(model.shownLines.allSatisfy { $0.section == .done && $0.project == "fjord" })
        // Pressed again: the state is cleared, the project stays.
        await waitUntilSteady(turns: 4) { RouterBodies.counts }
        let again = try #require(model.targets.actions[.state(.done)])
        again()
        #expect(model.section == nil)
        #expect(model.project == "fjord")
    }
}

/// A cold launch (docs/design/router-v2/LIVE-CHECK.md, problem 1): finished threads whose verdicts are pending are being
/// read, in a group of their own, and the page never says "Nothing needs you" while one is.
@MainActor
@Suite struct RouterReadingTests {
    private typealias ID = RouterDemo.ID

    @Test func finishedThreadsBeingReadWaitUnderReadingAndNotInDone() throws {
        let model = RouterDemo.records()
        model.select(nil)
        RouterDemo.coldReading(model)
        let first = try #require(model.layout.first)
        #expect(first.id == RouterModel.firstRow)
        #expect(first.kind == .reading(2))
        #expect(!model.layout.contains { if case .sentence(let w, _) = $0.kind { w.hasPrefix("Nothing needs you") } else { false } })
        #expect(!model.layout.contains { $0.kind == .header(.done, 2) || $0.id == "header-\(RouterSection.done.rawValue)" })
        // Not counted as Done, nor as needing you; still on the pills.
        #expect(model.count(section: .done) == 0)
        #expect(model.count(section: .needsYou) == 0)
        #expect(model.needsYou == 0)
        #expect(model.count(project: "docs-site") == 1)
        // A Working filter hides them; a Done filter keeps them.
        model.toggle(section: .working)
        #expect(!model.layout.contains { $0.kind == .reading(2) })
        model.toggle(section: .done)
        #expect(model.layout.first?.kind == .reading(2))
        model.clearFilters()

        // The guide's verdict: it needs you. It leaves the group, under its own header; the other is still read.
        var guide = try #require(model.thread(ID.guide))
        guide.judging = false
        guide.state = .needsYou(.step)
        model.apply(.upsert(guide))
        #expect(model.layout.first?.kind == .header(.needsYou, 1))
        #expect(model.layout.contains { $0.id == RouterModel.readingRow && $0.kind == .reading(1) })

        // The bar's verdict: quiet. Done, and nothing is read any more.
        var bar = try #require(model.thread(ID.bar))
        bar.judging = false
        model.apply(.upsert(bar))
        #expect(!model.layout.contains { if case .reading = $0.kind { true } else { false } })
        #expect(model.count(section: .done) == 1)
    }
}
