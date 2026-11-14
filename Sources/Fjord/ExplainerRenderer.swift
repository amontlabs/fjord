import AppKit
import Foundation
import JavaScriptCore
import WebKit

// Show me's offscreen renderer (docs/design/router-visuals/SHOWME.md §2.2, spike B5 in §12): the page a creator wrote, run
// in a WKWebView inside a borderless window that is never ordered in, so nothing shows, nothing takes the focus and there's
// no Dock icon. The shipped app has no headless browser; WebKit paints such a window fully for `takeSnapshot`.
//
// One view, reused, one render at a time (ExplainerMCP serializes them). A render loads the page once, waits for the kit's
// `data-ready` (no polling: a MutationObserver), reads the timing, errors and spec, then seeks the film to each frame it
// shoots. The theme is passed explicitly (`?theme=light`), so the system's appearance never changes a frame.

@MainActor
final class ExplainerRenderer {
    /// The stage's frame, in points: the Python preview server's window, which the prompt and evals were tuned on.
    static let size = CGSize(width: 1000, height: 760)
    /// From load to ready, at most: a page that loops forever is given up on, and the view is made again.
    static let deadline: TimeInterval = 20
    nonisolated static let posterLight = "poster-light.jpg"
    nonisolated static let posterDark = "poster-dark.jpg"

    /// The film's timing, as `window.__timing` gives it.
    struct Timing: Equatable, Decodable {
        var total: Double
        var scenes: [[Double]]
    }

    struct Spec: Equatable, Decodable {
        var title: String
        var answer: String
        var captions: [String]
    }

    struct Frame: Equatable {
        var label: String
        var file: URL
        var jpeg: Data
    }

    /// What one render found.
    struct Result: Equatable {
        var timing: Timing?
        /// `#errors`: errors, then layout notes, one a line; empty when there are none.
        var errors: String
        var broken: Bool
        var spec: Spec?
        var frames: [Frame] = []
        var posterLight: URL?
        var posterDark: URL?
    }

    /// Where the project keeps its kit: a page at `runs/<run>/v<n>/index.html` reads it as `../../../kit/`.
    let root: URL
    let kit: URL

    init(root: URL, kit: URL) {
        self.root = root
        self.kit = kit
    }

    private var window: NSWindow?
    private var view: WKWebView?
    private let delegate = Loads()

    /// The page's `index.html`: the kit's player with its links pointed at the project's kit and the question in
    /// `window.ASK`, `</` escaped so the question can't close the script (as `render.sh` does).
    static func page(player: String, ask: String) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: ask, options: [.fragmentsAllowed])).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "\"\""
        return player.replacingOccurrences(of: "KIT/", with: "../../../kit/")
            .replacingOccurrences(of: "ASK_JSON", with: json.replacingOccurrences(of: "</", with: "<\\/"))
    }

    /// Writes `code` as the page in `dir` (`index.html`, `explainer.js`) and renders it: a frame at each scene's end and at
    /// each of `at`'s seconds, then the last scene's held frame in light and dark (the posters). Frames are JPEG at 1×.
    func render(code: String, ask: String, into dir: URL, at: [Double] = []) async throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let player = try String(contentsOf: kit.appendingPathComponent("player.html"), encoding: .utf8)
        try Data(Self.page(player: player, ask: ask).utf8).write(to: dir.appendingPathComponent("index.html"), options: .atomic)
        try Data(code.utf8).write(to: dir.appendingPathComponent("explainer.js"), options: .atomic)

        // WebKit hides a syntax error in another file's script ("Script error."); JavaScriptCore names it and its line.
        if let error = Self.syntaxError(code) {
            return Result(timing: nil, errors: error, broken: true, spec: nil)
        }
        let view = try await webView()
        var components = URLComponents(url: dir.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "theme", value: "light"), URLQueryItem(name: "scene", value: "0")]
        let ready = await within(Self.deadline) { [delegate] in
            await delegate.load(components.url!, in: view, readable: self.root)
            _ = try? await view.callAsyncJavaScript(Self.waitReady, contentWorld: .page)
        }
        guard ready else {
            drop()
            return Result(timing: nil, errors: "The page didn't get ready in \(Int(Self.deadline)) s: a loop that never ends?",
                          broken: true, spec: nil)
        }
        let state = try await view.callAsyncJavaScript(Self.readState, contentWorld: .page) as? String ?? "{}"
        var result = Self.parse(state)
        result.errors = shorten(result.errors, page: dir)
        guard let timing = result.timing, !timing.scenes.isEmpty else { return result }

        var jobs = timing.scenes.enumerated().map { i, scene in
            (label: "End of scene \(i) (\(Self.number(scene.count > 1 ? scene[1] : scene[0])) s)",
             time: scene.count > 1 ? scene[1] : scene[0], file: "f-scene-\(i).jpg")
        }
        jobs += at.map { (label: "At \(Self.number($0)) s", time: min(max($0, 0), timing.total), file: "f-t-\(Self.number($0)).jpg") }
        for job in jobs {
            let jpeg = try await shoot(view, at: job.time, pixelWidth: Int(Self.size.width))
            let file = dir.appendingPathComponent(job.file)
            try jpeg.write(to: file, options: .atomic)
            result.frames.append(Frame(label: job.label, file: file, jpeg: jpeg))
        }
        if let held = timing.scenes.last.map({ $0.count > 1 ? $0[1] : $0[0] }) {
            let light = dir.appendingPathComponent(Self.posterLight), dark = dir.appendingPathComponent(Self.posterDark)
            try await shoot(view, at: held).write(to: light, options: .atomic)
            // The kit rebuilds the film in the new theme where it stands (`retheme`, a MutationObserver on data-theme).
            _ = try await view.callAsyncJavaScript(#"document.documentElement.dataset.theme = "dark"; await null; await null;"#,
                                                   contentWorld: .page)
            try await shoot(view, at: held).write(to: dark, options: .atomic)
            result.posterLight = light
            result.posterDark = dark
        }
        return result
    }

    /// Resolves once the kit says the page is built or never will be.
    static let waitReady = """
        await new Promise(r => document.body.dataset.ready ? r() : new MutationObserver((_, o) => {
          if (document.body.dataset.ready) { o.disconnect(); r(); } }).observe(document.body, { attributes: true }));
        """

    static let readState = """
        const errors = document.getElementById("errors");
        return JSON.stringify({ timing: window.__timing || null, errors: errors ? errors.textContent : "page did not load",
          broken: document.body.classList.contains("broken") || document.body.dataset.ready !== "1", spec: window.__spec || null });
        """

    static func parse(_ json: String) -> Result {
        struct State: Decodable { var timing: Timing?; var errors: String?; var broken: Bool?; var spec: Spec? }
        guard let state = try? JSONDecoder().decode(State.self, from: Data(json.utf8)) else {
            return Result(timing: nil, errors: "page did not load", broken: true, spec: nil)
        }
        return Result(timing: state.timing, errors: (state.errors ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                      broken: state.broken ?? true, spec: state.spec)
    }

    /// Whether `code` parses as a script, checked without running it: nil, or the error with its line in `explainer.js`.
    static func syntaxError(_ code: String) -> String? {
        guard let context = JSContext() else { return nil }
        var exception: JSValueRef?
        let script = JSStringCreateWithCFString(code as CFString), url = JSStringCreateWithCFString("explainer.js" as CFString)
        defer { JSStringRelease(script); JSStringRelease(url) }
        guard !JSCheckScriptSyntax(context.jsGlobalContextRef, script, url, 1, &exception), let exception,
              let value = JSValue(jsValueRef: exception, in: context) else { return nil }
        let line = value.forProperty("line").flatMap { $0.isUndefined ? nil : $0.toInt32() }
        return (value.toString() ?? "SyntaxError") + (line.map { " (explainer.js line \($0))" } ?? "")
    }

    /// Stack lines name files by their full URL: shorten them to the version's own (`explainer.js`) and the kit's (`kit/…`).
    func shorten(_ errors: String, page dir: URL) -> String {
        var out = errors
        for base in [dir, dir.resolvingSymlinksInPath()] {
            out = out.replacingOccurrences(of: base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/", with: "")
        }
        for base in [root, root.resolvingSymlinksInPath()] {
            out = out.replacingOccurrences(of: base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/", with: "")
        }
        return out
    }

    /// Seconds as the Python server printed them: `12`, `3.2`.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(format: "%g", value)
    }

    /// The film at `seconds`, as a JPEG: at the screen's scale, or `pixelWidth` pixels wide (the model's frames are 1×: they
    /// cost the same tokens at 2× and say no more). `time()` (not `seek`, which skips callbacks) runs the player's update, so the
    /// caption matches the frame; GSAP applies the state at once, and the snapshot paints after it.
    private func shoot(_ view: WKWebView, at seconds: Double, pixelWidth: Int? = nil) async throws -> Data {
        _ = try await view.callAsyncJavaScript("window.__film.timeline.time(t, false); await null;",
                                               arguments: ["t": seconds], contentWorld: .page)
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(Self.size.width))
        config.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: config)
        guard let jpeg = Self.jpeg(image, pixelWidth: pixelWidth) else { throw CocoaError(.fileWriteUnknown) }
        return jpeg
    }

    static func jpeg(_ image: NSImage, pixelWidth: Int? = nil, quality: Double = 0.8) -> Data? {
        guard var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        if let pixelWidth, cg.width > pixelWidth {
            let height = Int((Double(cg.height) * Double(pixelWidth) / Double(cg.width)).rounded())
            guard let context = CGContext(data: nil, width: pixelWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: pixelWidth, height: height))
            guard let scaled = context.makeImage() else { return nil }
            cg = scaled
        }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    // MARK: The view

    private func webView() async throws -> WKWebView {
        if let view { return view }
        let config = try await ExplainerWeb.configuration()
        let view = WKWebView(frame: CGRect(origin: .zero, size: Self.size), configuration: config)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: Self.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        self.window = window
        self.view = view
        return view
    }

    /// Lets go of a view whose page never got ready: its web content process may still be spinning.
    private func drop() {
        view?.stopLoading()
        delegate.cancel()
        window?.contentView = nil
        window?.close()
        view = nil
        window = nil
    }

    /// Releases the view and its window (the next render makes them again).
    func close() { drop() }

    /// Runs `work`; false if it hasn't finished within `seconds` (it's left to finish on its own, unawaited).
    private func within(_ seconds: TimeInterval, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                await work()
                once.run { done.resume(returning: true) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.run { done.resume(returning: false) }
            }
        }
    }

    @MainActor private final class Once {
        private var done = false
        func run(_ body: () -> Void) {
            guard !done else { return }
            done = true
            body()
        }
    }

    /// The renderer's navigation and UI delegate: `ExplainerWeb`'s file-only policy, no windows, and a load that resolves
    /// when the main frame finishes or fails.
    @MainActor private final class Loads: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var waiting: CheckedContinuation<Void, Never>?

        func load(_ url: URL, in view: WKWebView, readable: URL) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                cancel()
                waiting = done
                view.loadFileURL(url, allowingReadAccessTo: readable)
            }
        }

        /// Ends a load that is waited on.
        func cancel() {
            waiting?.resume()
            waiting = nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            ExplainerWeb.policy(for: action)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { cancel() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { cancel() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            cancel()
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { cancel() }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
