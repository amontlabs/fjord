import AppKit
import SwiftUI
import Testing
@testable import Fjord

@MainActor
@Suite(.hostsWindows) struct RouterCanvasFlightViewTests {
    @Test(.disabled("The Router window shows the brief (RouterBriefView); the old Now, history and canvas views go in a later step")) func theCanvasRegistersCameraTransformedTargetsAndOnePillAboveTheComposer() async throws {
        _ = NSApplication.shared
        let store = Store()
        Demo.populate(store, .router)
        let model = RouterModel()
        model.pickCanvas()
        let runs = store.routerDispatcher.progress
        let id = try #require(runs.keys.first)
        store.routerDispatcher.preview(progress: runs, flying: [id])
        model.canvas.camera.moved = true
        model.canvas.camera.transform = CanvasTransform(origin: CGPoint(x: 100, y: 120), scale: 0.5)
        let host = NSHostingView(rootView: RouterCodeView(store: store, model: model, checksClaudeCode: false))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = AwayWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(UnderTest.away)
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let node = try #require(model.zones(store).needs.first?.id)
        await waitUntil(within: 5) {
            model.canvas.nodeRects[node] != nil && model.flights.frames["canvas:\(node)"] != nil
                && model.flights.frames["pill:\(id)"] != nil
        }
        #expect(model.flights.pills.map(\.id) == [id])
        let pill = try #require(model.flights.frames["pill:\(id)"])
        let composer = try #require(model.flights.frames["composer"])
        #expect(pill.height == 34 && pill.maxY <= composer.minY)
        #expect(composer.minY - pill.maxY <= 16)
        func checkProjection() throws {
            let content = try #require(model.canvas.nodeRects[node])
            let page = try #require(model.flights.frames["canvas:\(node)"])
            let t = model.canvas.camera.transform
            let viewport = model.canvas.viewportFrame
            #expect(abs(page.minX - (viewport.minX + t.origin.x + content.minX * t.scale)) < 1)
            #expect(abs(page.minY - (viewport.minY + t.origin.y + content.minY * t.scale)) < 1)
            #expect(abs(page.width - content.width * t.scale) < 1)
        }
        try checkProjection()
        let old = model.flights.frames["canvas:\(node)"]
        model.canvas.camera.transform = CanvasTransform(origin: CGPoint(x: -200, y: 60), scale: 0.75)
        await waitUntil { model.flights.frames["canvas:\(node)"] != old }
        try checkProjection()
        model.layout = .list
        await waitUntil { model.flights.resolvePlace == nil }
        #expect(model.flights.pills.map(\.id) == [id], "switching layouts keeps the pending send")
    }
}
