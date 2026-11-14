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

    private static func message(_ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var m: [String: Any] = ["t": 3.5, "scene": 1, "playing": true, "total": 12.0,
                                "scenes": [["caption": "One", "source": "", "start": 0.0],
                                           ["caption": "Two", "source": "the reply's words", "start": 5.0]]]
        change(&m)
        return m
    }

    @Test func theBridgeTakesOnlyTheFilmsState() throws {
        let state = try #require(ExplainerPlayback.State.parse(Self.message()))
        #expect(state.t == 3.5 && state.scene == 1 && state.playing && state.total == 12 && state.scenes[1].source == "the reply's words")
        let bad: [(inout [String: Any]) -> Void] = [
            { $0["extra"] = 1 },                                  // nothing but the five fields
            { $0["t"] = "3" },                                    // numbers are numbers
            { $0["t"] = Double.nan },
            { $0["t"] = 40.0 },                                   // within the film
            { $0["total"] = -1.0 },
            { $0["scene"] = 2 },                                  // a scene in the list
            { $0["scene"] = 0.5 },
            { $0["playing"] = 1 },                                // a flag is a boolean
            { $0["scene"] = true },
            { $0["scenes"] = [] },
            { $0["scenes"] = Array(repeating: ["caption": "", "source": "", "start": 0.0], count: 25) },
            { $0["scenes"] = [["caption": String(repeating: "x", count: 201), "source": "", "start": 0.0]] },
            { $0["scenes"] = [["caption": "One", "source": "", "start": 0.0, "html": "<b>"]] },
            { $0["scenes"] = [["caption": 1, "source": "", "start": 0.0]] },
        ]
        for change in bad { #expect(ExplainerPlayback.State.parse(Self.message(change)) == nil) }
        #expect(ExplainerPlayback.State.parse("{}") == nil)
    }

    @Test func theSceneBarMapsTimeAndScenes() throws {
        let state = try #require(ExplainerPlayback.State.parse(Self.message()))
        #expect(state.scene(at: 4.9) == 0 && state.scene(at: 5) == 1)
        #expect(state.progress(0, at: 2.5) == 0.5 && state.progress(1, at: 2.5) == 0)
        #expect(state.time(along: 0.25) == 2.5 && state.time(along: 0.75) == 8.5)
    }

    @Test func fjordsCallsAreFixed() {
        typealias C = ExplainerWebHost.Command
        #expect(C.play.script == "window.__player && window.__player.play(); void 0")
        #expect(C.seek(2.5).script == "window.__player && window.__player.seek(2.500); void 0")
        #expect(C.seek(.infinity).script.contains("seek(0.000)") && C.seek(-3).script.contains("seek(0.000)"))
        #expect(C.scene(-1).script.contains("scene(0)") && C.scene(3).script.contains("scene(3)"))
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

    /// The playback state once `ok` holds (the page posts it through the bridge), or the last one after 2 s.
    private func arrived(_ host: ExplainerWebHost, _ ok: (ExplainerPlayback.State?) -> Bool) async throws -> ExplainerPlayback.State? {
        for _ in 0..<100 where !ok(host.playback.state) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ok(host.playback.state))
        return host.playback.state
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
        #expect(try await js(view, "return document.documentElement.style.colorScheme") as? String == "dark")
        // Embedded, the page is the stage alone: none of its chrome shows, the stage fills the view, nothing scrolls.
        for chrome in [".ask", ".answer", ".caption", ".source", "nav", "#errors"] {
            #expect(try await js(view, "return getComputedStyle(document.querySelector('\(chrome)')).display") as? String == "none")
        }
        let fills = try await js(view, """
            const r = document.getElementById("stage").getBoundingClientRect(), e = document.scrollingElement;
            return [r.left, r.top, r.width - innerWidth, r.height - innerHeight, e.scrollHeight - e.clientHeight, e.scrollWidth - e.clientWidth];
            """) as? [Double]
        #expect(fills == [0, 0, 0, 0, 0, 0])

        // The bridge: the film's state arrives once it's built, and Fjord's fixed calls move it.
        let film = try await arrived(host) { $0 != nil }
        #expect(film?.scenes.count == 5 && film?.total ?? 0 > 10 && film?.scenes.first?.start == 0)
        host.send(.pause)
        _ = try await arrived(host) { $0?.playing == false }
        host.send(.seek(6))
        let moved = try await arrived(host) { $0.map { abs($0.t - 6) < 0.01 } == true }
        #expect(moved?.playing == false && moved?.scene == moved?.scene(at: 6))
        host.send(.scene(3))
        let scene = try await arrived(host) { $0?.scene == 3 }
        #expect(scene.map { abs($0.t - $0.scenes[3].start) < 0.05 } == true)
        // The page's own keys are off: Fjord handles them.
        _ = try await js(view, "dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }))")
        #expect(try await js(view, "return Math.round(window.__film.timeline.time() * 100)") as? Int == Int((scene!.t * 100).rounded()))
        // Anything else the page posts is dropped.
        _ = try await js(view, "window.webkit.messageHandlers.fjordPlayer.postMessage({ t: 0, scene: 0, playing: false, total: 1, scenes: [], x: 1 })")
        _ = try await js(view, "await null")
        #expect(host.playback.state?.scene == 3)

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
