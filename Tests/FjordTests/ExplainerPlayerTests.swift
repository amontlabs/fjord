import AppKit
import Foundation
import Testing
import WebKit
@testable import Fjord

/// Show me's player: when it's a web view and when a held frame, and what the page it loads may reach.
@MainActor
@Suite struct ExplainerPlayerTests {
    private let page = URL(fileURLWithPath: "/S/Fjord/Explainers/runs/run-1/v3/index.html")

    @Test func theWebViewIsOnlyForAReadyExplainerOutsideDemosAndShots() {
        #expect(ExplainerStage.mode(page: page, ready: true, demo: false) == .web(page))
        #expect(ExplainerStage.mode(page: page, ready: false, demo: false) == .still)
        #expect(ExplainerStage.mode(page: nil, ready: true, demo: false) == .still)
        #expect(ExplainerStage.mode(page: page, ready: true, demo: true) == .still)
    }

    @Test func aPageThatCrashesReloadsOnceThenShowsItsPoster() {
        var crashes = ExplainerWebHost.Crashes()
        let first = crashes.died(page), second = crashes.died(page), third = crashes.died(page)
        #expect(first && !second && !third)
        let other = page.deletingLastPathComponent().appendingPathComponent("../v4/index.html").standardizedFileURL
        let fresh = crashes.died(other)
        #expect(fresh)
        #expect(ExplainerStage.mode(page: page, ready: true, crashed: page, demo: false) == .still)
        #expect(ExplainerStage.mode(page: page, ready: true, crashed: other, demo: false) == .web(page))
    }

    @Test func thePageLoadsEmbeddedAndReadsOnlyTheProjectFolder() {
        #expect(ExplainerWebHost.embedded(page).absoluteString == "file:///S/Fjord/Explainers/runs/run-1/v3/index.html?embed=1")
        #expect(ExplainerWebHost.readable(page).path == "/S/Fjord/Explainers")
    }

    @Test func theHeightFollowsTheWidth() {
        #expect(ExplainerWebView.height(width: 480) == 270 + ExplainerWebView.chrome)
    }

    @Test func aPosterIsDecodedOnceAndAMissingOneIsNil() throws {
        let dir = TempDir()
        let url = dir.path("poster-light.jpg")
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        try #require(ExplainerRenderer.jpeg(image)).write(to: url)
        let first = try #require(ExplainerPosters.image(url))
        #expect(ExplainerPosters.image(url) === first)
        #expect(ExplainerPosters.image(dir.path("none.jpg")) == nil && ExplainerPosters.image(nil) == nil)
    }
}

/// The player against real WebKit, opt-in (`FJORD_EXPLAINER_LIVE=1 swift test --filter ExplainerPlayerLive`): the example
/// rendered, then played in the panel's host offscreen, never shown.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FJORD_EXPLAINER_LIVE"] == "1"), .timeLimit(.minutes(1)))
struct ExplainerPlayerLive {
    private static let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/design/router-visuals/explainer/examples/lastdrop.js")

    private func loaded(_ host: ExplainerWebHost, _ view: WKWebView) async throws {
        await host.loaded()
        _ = try await view.callAsyncJavaScript(ExplainerRenderer.waitReady, contentWorld: .page)
    }

    private func js(_ view: WKWebView, _ body: String) async throws -> Any? {
        try await view.callAsyncJavaScript(body, contentWorld: .page)
    }

    @Test func thePagePlaysEmbeddedFollowsTheAppearanceAndUsesTheSandbox() async throws {
        let dir = TempDir()
        let project = ExplainerProject(root: dir.path("Explainers"))
        try project.sync()
        let renderer = ExplainerRenderer(root: project.root, kit: project.kit)
        defer { renderer.close() }
        let versionDir = project.runs.appendingPathComponent("run-1/v1", isDirectory: true)
        _ = try await renderer.render(code: String(contentsOf: Self.example, encoding: .utf8), ask: "How?", into: versionDir)
        let page = versionDir.appendingPathComponent("index.html")

        let host = ExplainerWebHost()
        defer { host.close() }
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 560, height: 450), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host.container
        defer { window.close() }
        await host.ready()
        let view = try #require(host.view)

        host.show(page, dark: true)
        try await loaded(host, view)
        #expect(try await js(view, "return document.body.dataset.ready") as? String == "1")
        #expect(try await js(view, "return document.documentElement.classList.contains('embed')") as? Bool == true)
        #expect(try await js(view, "return getComputedStyle(document.querySelector('.ask')).display") as? String == "none")
        #expect(try await js(view, "return document.documentElement.style.colorScheme") as? String == "dark")

        // The same page in light: no reload, and the page's media query turns. (The kit's rebuild on its `change` event
        // waits for a rendering update, which a window that's never shown doesn't get: it isn't checked here.)
        host.show(page, dark: false)
        #expect(!view.isLoading)
        #expect(try await js(view, "return matchMedia('(prefers-color-scheme: dark)').matches") as? Bool == false)

        // Made from the sandbox configuration (ExplainerWeb.swift): nothing kept, no windows from script. (Its local-only rule
        // list can't be probed here: a blocked fetch never settles, and timers don't run in a window that's never shown.)
        #expect(!view.configuration.websiteDataStore.isPersistent)
        #expect(!view.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    }
}
