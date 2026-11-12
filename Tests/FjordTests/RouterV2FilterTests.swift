import AppKit
import SwiftUI
import Testing
@testable import Fjord

/// The filter bar's state tokens filter the page (docs/design/router-v2/DESIGN.md 1.2, 4): one project × one state, the
/// counts faceted. Pressed as the drawn pointer and a click press them: the token's own registered action.
@MainActor
@Suite(.serialized, .hostsWindows) struct RouterV2FilterTests {
    private func hosted() async -> (RouterV2Model, NSWindow) {
        RouterV2Bodies.reset()
        let model = RouterV2Demo.records(still: true)
        model.select(nil)
        let hosting = NSHostingView(rootView: RouterV2Screen(model: model).frame(width: 1280, height: 960))
        let window = AwayWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 960), styleMask: .titled, backing: .buffered,
                                defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFront(nil)
        await waitUntil { RouterV2Bodies["list"] > 0 }
        await waitUntilSteady(turns: 6) { RouterV2Bodies.counts }
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
        await waitUntilSteady(turns: 4) { RouterV2Bodies.counts }
        let again = try #require(model.targets.actions[.state(.done)])
        again()
        #expect(model.section == nil)
        #expect(model.project == "fjord")
    }
}
