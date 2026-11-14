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
    /// A whole render, from load to the dark poster, at most: a page that loops forever (in its build or in an onUpdate) is
    /// given up on, and the view is made again.
    static let deadline: TimeInterval = 30
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
        /// The labels of frames the cap on frames left out.
        var left: [String] = []
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
    nonisolated static func page(player: String, ask: String) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: ask, options: [.fragmentsAllowed])).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "\"\""
        return player.replacingOccurrences(of: "KIT/", with: "../../../kit/")
            .replacingOccurrences(of: "ASK_JSON", with: json.replacingOccurrences(of: "</", with: "<\\/"))
    }

    /// Frames for the model in one answer, at most: each costs about 900 input tokens, and the reply has a size cap.
    nonisolated static let maxFrames = 8

    /// One frame to shoot: its label for the model, the film's time and its file in the version's folder.
    struct Job: Equatable {
        var label: String
        var time: Double
        var file: String
    }

    /// The frames one render shoots, at most `maxFrames`: every `at` second asked for (the creator wanted those), then
    /// scene ends in order while there's room. `left` is what didn't fit, named in the answer.
    nonisolated static func plan(_ timing: Timing, at: [Double]) -> (shoot: [Job], left: [Job]) {
        let scenes = timing.scenes.enumerated().map { i, scene in
            let end = scene.count > 1 ? scene[1] : scene.first ?? 0
            return Job(label: "End of scene \(i) (\(number(end)) s)", time: end, file: "f-scene-\(i).jpg")
        }
        let asked = at.map { Job(label: "At \(number($0)) s", time: min(max($0, 0), timing.total), file: "f-t-\(number($0)).jpg") }
        let ats = Array(asked.prefix(maxFrames))
        let room = maxFrames - ats.count
        return (Array(scenes.prefix(room)) + ats, Array(scenes.dropFirst(room)) + Array(asked.dropFirst(maxFrames)))
    }

    /// Writes `code` as the page in `dir` (`index.html`, `explainer.js`) and renders it: a frame at each scene's end and at
    /// each of `at`'s seconds (at most `maxFrames`), then the last scene's held frame in light and dark (the posters). Frames
    /// are JPEG at 1×. The whole render, from load to the dark poster, has `deadline`: past it the view is dropped (its
    /// pending calls fail, so nothing waits on its page) and the next render makes a new one.
    func render(code: String, ask: String, into dir: URL, at: [Double] = []) async throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let player = try String(contentsOf: kit.appendingPathComponent("player.html"), encoding: .utf8)
        try Data(Self.page(player: player, ask: ask).utf8).write(to: dir.appendingPathComponent("index.html"), options: .atomic)
        try Data(code.utf8).write(to: dir.appendingPathComponent("explainer.js"), options: .atomic)

        // WebKit hides a syntax error in another file's script ("Script error."); JavaScriptCore names it and its line.
        if let error = await Task.detached(operation: { Self.syntaxError(code) }).value {
            return Result(timing: nil, errors: error, broken: true, spec: nil)
        }
        let progress = Progress()
        let done = try await Self.within(Self.deadline) { [self] in
            try await self.film(dir: dir, at: at, progress: progress)
        }
        if let done { return done }
        drop()
        let error = progress.ready
            ? "The page got ready but its frames didn't render in \(Int(Self.deadline)) s: an onUpdate that never ends?"
            : "The page didn't get ready in \(Int(Self.deadline)) s: a loop that never ends?"
        return Result(timing: nil, errors: error, broken: true, spec: nil)
    }

    /// How far a render got, for the deadline's message.
    @MainActor private final class Progress { var ready = false }

    /// The render past the syntax check: load, wait for ready, read the state, shoot the frames and the posters.
    private func film(dir: URL, at: [Double], progress: Progress) async throws -> Result {
        let view = try await webView()
        var components = URLComponents(url: dir.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "theme", value: "light"), URLQueryItem(name: "scene", value: "0")]
        await delegate.load(components.url!, in: view, readable: root)
        try Task.checkCancellation()
        _ = try? await js(view, Self.waitReady)
        try Task.checkCancellation()
        progress.ready = true
        let state = try await js(view, Self.readState) as? String ?? "{}"
        var result = Self.parse(state)
        result.errors = shorten(result.errors, page: dir)
        guard let timing = result.timing, !timing.scenes.isEmpty else { return result }

        let plan = Self.plan(timing, at: at)
        result.left = plan.left.map(\.label)
        for job in plan.shoot {
            let file = dir.appendingPathComponent(job.file)
            let jpeg = try await shoot(view, at: job.time, pixelWidth: Int(Self.size.width), to: file)
            result.frames.append(Frame(label: job.label, file: file, jpeg: jpeg))
        }
        if let held = timing.scenes.last.map({ $0.count > 1 ? $0[1] : $0[0] }) {
            let light = dir.appendingPathComponent(Self.posterLight), dark = dir.appendingPathComponent(Self.posterDark)
            // The posters are the stage alone: the panel draws the answer, caption and controls itself.
            let stage = try await stageRect(view)
            _ = try await shoot(view, at: held, rect: stage, to: light)
            // The kit rebuilds the film in the new theme where it stands (`retheme`, a MutationObserver on data-theme).
            _ = try await js(view, #"document.documentElement.dataset.theme = "dark"; await null; await null;"#)
            _ = try await shoot(view, at: held, rect: stage, to: dark)
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

    nonisolated static func parse(_ json: String) -> Result {
        struct State: Decodable { var timing: Timing?; var errors: String?; var broken: Bool?; var spec: Spec? }
        guard let state = try? JSONDecoder().decode(State.self, from: Data(json.utf8)) else {
            return Result(timing: nil, errors: "page did not load", broken: true, spec: nil)
        }
        return Result(timing: state.timing, errors: (state.errors ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                      broken: state.broken ?? true, spec: state.spec)
    }

    /// Whether `code` parses as a script, checked without running it: nil, or the error with its line in `explainer.js`.
    nonisolated static func syntaxError(_ code: String) -> String? {
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
    nonisolated static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(format: "%g", value)
    }

    /// The film at `seconds`, written to `file` as a JPEG: at the screen's scale, or `pixelWidth` pixels wide (the model's
    /// frames are 1×: they cost the same tokens at 2× and say no more). `time()` (not `seek`, which skips callbacks) runs the
    /// player's update, so the caption matches the frame; GSAP applies the state at once, and the snapshot paints after it.
    /// Scaling, encoding and writing run off the main thread.
    private func shoot(_ view: WKWebView, at seconds: Double, pixelWidth: Int? = nil, rect: CGRect? = nil,
                       to file: URL) async throws -> Data {
        _ = try await js(view, "window.__film.timeline.time(t, false); await null;", ["t": seconds])
        let config = WKSnapshotConfiguration()
        if let rect { config.rect = rect }
        config.snapshotWidth = NSNumber(value: Double(rect?.width ?? Self.size.width))
        config.afterScreenUpdates = true
        let image = try await snapshot(view, config)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CocoaError(.fileWriteUnknown) }
        return try await Task.detached {
            guard let jpeg = Self.jpeg(cg, pixelWidth: pixelWidth) else { throw CocoaError(.fileWriteUnknown) }
            try jpeg.write(to: file, options: .atomic)
            return jpeg
        }.value
    }

    /// Where the stage is in the page, in points; nil (the whole view) when it can't be read.
    private func stageRect(_ view: WKWebView) async throws -> CGRect? {
        let box = try await js(view, """
            const r = document.getElementById("stage").getBoundingClientRect();
            return [r.left, r.top, r.width, r.height];
            """) as? [Double]
        guard let box, box.count == 4, box[2] > 1, box[3] > 1 else { return nil }
        return CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
    }

    nonisolated static func jpeg(_ image: NSImage, pixelWidth: Int? = nil, quality: Double = 0.8) -> Data? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { jpeg($0, pixelWidth: pixelWidth, quality: quality) }
    }

    nonisolated static func jpeg(_ image: CGImage, pixelWidth: Int? = nil, quality: Double = 0.8) -> Data? {
        var cg = image
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

    // MARK: Calls into the page

    /// Calls waiting on the page: `drop()` fails them all, so a render whose page hangs ends, and lets its view go.
    private var pending: [UUID: (Error) -> Void] = [:]

    private func js(_ view: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await waited { (done: @escaping (Swift.Result<Any?, Error>) -> Void) in
            view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { done($0.map { $0 as Any? }) }
        }
    }

    private func snapshot(_ view: WKWebView, _ config: WKSnapshotConfiguration) async throws -> NSImage {
        try await waited { (done: @escaping (Swift.Result<NSImage, Error>) -> Void) in
            view.takeSnapshot(with: config) { image, error in
                done(image.map { .success($0) } ?? .failure(error ?? CocoaError(.fileWriteUnknown)))
            }
        }
    }

    private func waited<T>(_ start: (@escaping (Swift.Result<T, Error>) -> Void) -> Void) async throws -> T {
        let id = UUID()
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
            pending[id] = { done.resume(throwing: $0) }
            start { result in
                MainActor.assumeIsolated {
                    guard self.pending.removeValue(forKey: id) != nil else { return }
                    done.resume(with: result)
                }
            }
        }
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

    /// Lets go of a view whose render ran past the deadline: its web content process may still be spinning.
    private func drop() {
        view?.stopLoading()
        delegate.cancel()
        let calls = pending
        pending = [:]
        calls.values.forEach { $0(CancellationError()) }
        window?.contentView = nil
        window?.close()
        view = nil
        window = nil
    }

    /// Releases the view and its window (the next render makes them again).
    func close() { drop() }

    /// Runs `work`: its value, or nil if it hasn't finished within `seconds` (it's cancelled then, and left to end on its own).
    static func within<T>(_ seconds: TimeInterval, _ work: @escaping @MainActor () async throws -> T) async throws -> T? {
        let once = Once()
        var worker: Task<Void, Never>?
        var timer: Task<Void, Never>?
        let out: Swift.Result<T?, Error> = await withCheckedContinuation { done in
            worker = Task { @MainActor in
                do {
                    let value = try await work()
                    once.run { done.resume(returning: .success(value)) }
                } catch {
                    once.run { done.resume(returning: .failure(error)) }
                }
            }
            timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.run { done.resume(returning: .success(nil)) }
            }
        }
        worker?.cancel()
        timer?.cancel()
        return try out.get()
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
