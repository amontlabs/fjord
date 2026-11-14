import AppKit
import SwiftUI
import WebKit

// Show me's player (docs/design/router-visuals/SHOWME.md §8): a finished explainer plays in a sandboxed web view, the page
// the creator wrote on the project's kit, made from `ExplainerWeb.configuration(bridge:)` (no network, nothing kept) with
// the navigation policy refusing every load that isn't a file. The page loads as `?embed=1`: the stage alone, no chrome.
// Fjord draws the answer, caption, scene bar, time and Sources natively (RouterShowMePanel.swift), and the two talk over a
// narrow bridge: Fjord calls fixed functions (`__player.play()`, `pause()`, `toggle()`, `seek(t)`, `scene(i)`), and the page
// posts only the film's state (`ExplainerPlayback.State`), checked field by field. Fjord picks the appearance, which the kit
// follows through `prefers-color-scheme`, rebuilding the film where it stands.
//
// Shots, demos and explainers still being made never get a web view (a shot can't capture one): they draw the version's held
// last frame, the poster the renderer saved (the stage alone).

/// The film's state as the page last posted it, and the clock between posts.
@MainActor @Observable final class ExplainerPlayback {
    struct Scene: Equatable {
        var caption: String
        var source: String
        /// Seconds into the film where it starts.
        var start: Double
    }

    struct State: Equatable {
        var t: Double
        var scene: Int
        var playing: Bool
        var total: Double
        var scenes: [Scene]

        static let maxScenes = 24, maxCaption = 200, maxSource = 400, maxSeconds = 3600.0

        /// The page's message, or nil when it's anything but `{t, scene, playing, total, scenes: [{caption, source, start}]}`
        /// with finite times in range, a scene index in the list, and short strings.
        static func parse(_ body: Any) -> State? {
            guard let d = body as? [String: Any], Set(d.keys) == ["t", "scene", "playing", "total", "scenes"],
                  let total = seconds(d["total"]), let t = seconds(d["t"]), t <= total + 0.5,
                  let playing = flag(d["playing"]), let list = d["scenes"] as? [Any],
                  !list.isEmpty, list.count <= maxScenes, let scene = index(d["scene"]), scene < list.count else { return nil }
            var scenes: [Scene] = []
            for item in list {
                guard let e = item as? [String: Any], Set(e.keys) == ["caption", "source", "start"],
                      let caption = e["caption"] as? String, caption.count <= maxCaption,
                      let source = e["source"] as? String, source.count <= maxSource,
                      let start = seconds(e["start"]), start <= total else { return nil }
                scenes.append(Scene(caption: caption, source: source, start: start))
            }
            return State(t: t, scene: scene, playing: playing, total: total, scenes: scenes)
        }

        private static func number(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        }
        private static func seconds(_ v: Any?) -> Double? {
            guard let n = number(v), n.isFinite, n >= 0, n <= maxSeconds else { return nil }
            return n
        }
        private static func index(_ v: Any?) -> Int? {
            guard let n = number(v), n >= 0, n == n.rounded(), n < Double(maxScenes) else { return nil }
            return Int(n)
        }
        private static func flag(_ v: Any?) -> Bool? {
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }

        /// The scene `t` falls in.
        func scene(at t: Double) -> Int { scenes.lastIndex { t >= $0.start - 0.001 } ?? 0 }
        /// Where scene `i` ends: the next one's start, or the film's end.
        func end(of i: Int) -> Double { i + 1 < scenes.count ? scenes[i + 1].start : total }
        /// How much of scene `i` has played at `t`, 0…1.
        func progress(_ i: Int, at t: Double) -> Double {
            let a = scenes[i].start, b = end(of: i)
            return b > a ? min(max((t - a) / (b - a), 0), 1) : (t >= a ? 1 : 0)
        }
        /// The time at `fraction` (0…1) along a bar of equal segments, one per scene.
        func time(along fraction: Double) -> Double {
            let n = Double(scenes.count), x = min(max(fraction, 0), 1) * n
            let i = min(Int(x), scenes.count - 1)
            return scenes[i].start + (x - Double(i)) * (end(of: i) - scenes[i].start)
        }
    }

    private(set) var state: State?
    /// When `state` arrived: while it plays, the time runs on from there.
    @ObservationIgnored private(set) var at = Date()
    /// A page whose web process died twice: it shows its poster from then on.
    var crashed: URL?

    func received(_ new: State) {
        at = Date()
        if new != state { state = new }
    }

    func reset() { if state != nil { state = nil } }

    /// Seconds into the film at `now`.
    func time(_ now: Date) -> Double {
        guard let state else { return 0 }
        return state.playing ? min(state.total, state.t + max(0, now.timeIntervalSince(at))) : state.t
    }
}

/// The page's web view, made once while the panel is open and kept across selections and sizes (a new page is a `load`, a
/// new size is the same view in another place): owned by the page model (`RouterModel.showMeHost`), let go when the panel
/// closes. At rest it runs nothing: the kit's timeline only plays when asked.
@MainActor
final class ExplainerWebHost {
    /// What SwiftUI places (`ExplainerWebView` adopts it wherever the player is drawn); rounded by its layer.
    let container = NSView()
    private(set) var view: ExplainerPlayerWebView?
    let playback = ExplainerPlayback()
    private let delegate = Delegate()
    private let bridge = Bridge()
    private var page: URL?
    private var dark = false
    private var making: Task<Void, Never>?
    private var closed = false
    private var crashes = Crashes()
    /// The view takes the keyboard once it's in a window (the player grew to fill the page or the window).
    var wantsFocus = false

    /// A page's web content process may die once and be loaded again; the second time it stays down. A new page starts over.
    struct Crashes {
        private(set) var page: URL?
        private var count = 0
        /// Whether to load `page` again after its process died.
        mutating func died(_ page: URL?) -> Bool {
            if page != self.page { self.page = page; count = 0 }
            count += 1
            return count <= 1
        }
    }

    /// What Fjord may ask of the page: fixed calls, numbers formatted here.
    enum Command: Equatable {
        case play, pause, toggle, seek(Double), scene(Int)

        var script: String {
            let call: String
            switch self {
            case .play: call = "play()"
            case .pause: call = "pause()"
            case .toggle: call = "toggle()"
            case .seek(let t): call = "seek(\(String(format: "%.3f", t.isFinite ? max(0, t) : 0)))"
            case .scene(let i): call = "scene(\(max(0, i)))"
            }
            return "window.__player && window.__player.\(call); void 0"
        }
    }

    init() {
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        bridge.playback = playback
        making = Task { @MainActor [weak self] in
            guard let bridge = self?.bridge, let config = try? await ExplainerWeb.configuration(bridge: bridge),
                  let self, !self.closed else { return }
            let view = ExplainerPlayerWebView(frame: self.container.bounds, configuration: config)
            view.autoresizingMask = [.width, .height]
            view.navigationDelegate = self.delegate
            view.uiDelegate = self.delegate
            self.delegate.terminated = { [weak self] view in self?.terminated(view) }
            view.allowsBackForwardNavigationGestures = false
            view.allowsMagnification = false
            // No white flash while a page loads: the poster under it shows through until the film's first state.
            view.setValue(false, forKey: "drawsBackground")
            self.container.addSubview(view)
            self.view = view
            self.apply(view, load: true)
        }
    }

    /// Waits until the view exists (its configuration compiles once per run).
    func ready() async { await making?.value }

    /// The page to play and the appearance to play it in. The same page again only changes the appearance.
    func show(_ page: URL, dark: Bool) {
        let load = page != self.page
        self.page = page
        self.dark = dark
        if load { playback.reset() }
        if let view { apply(view, load: load) }
    }

    /// The stage's corners: the panel's card radius, none when it fills the window.
    func round(_ radius: CGFloat) {
        if container.layer?.cornerRadius != radius { container.layer?.cornerRadius = radius }
    }

    func send(_ command: Command) {
        guard let view, playback.state != nil else { return }
        view.evaluateJavaScript(command.script, completionHandler: nil)
    }

    /// Gives the view the keyboard (← → Space reach the player through the Router's keys).
    func focus() {
        guard let view, let window = view.window else { wantsFocus = true; return }
        wantsFocus = false
        window.makeFirstResponder(view)
    }

    /// The URL the panel loads: the version's page in embed mode.
    static func embedded(_ page: URL) -> URL {
        var parts = URLComponents(url: page, resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "embed", value: "1")]
        return parts?.url ?? page
    }

    /// What the page may read: the project's folder, which holds the kit (`runs/<run>/v<n>/index.html` → `Explainers/`).
    static func readable(_ page: URL) -> URL {
        (0..<4).reduce(page) { url, _ in url.deletingLastPathComponent() }
    }

    private func apply(_ view: WKWebView, load: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        guard load, let page else { return }
        view.loadFileURL(Self.embedded(page), allowingReadAccessTo: Self.readable(page))
    }

    private func terminated(_ view: WKWebView) {
        playback.reset()
        if crashes.died(page) {
            view.reload()
        } else if let page {
            delegate.finish()
            playback.crashed = page
        }
    }

    /// Waits for the page `show` last asked for to finish loading (or fail). Call it right after `show`.
    func loaded() async {
        guard view?.isLoading == true else { return }
        await withCheckedContinuation { delegate.waiting.append($0) }
    }

    /// Stops the page and lets the view go.
    func close() {
        closed = true
        delegate.finish()
        making?.cancel()
        view?.configuration.userContentController.removeScriptMessageHandler(forName: ExplainerWeb.bridgeName, contentWorld: .page)
        view?.stopLoading()
        view?.removeFromSuperview()
        view = nil
        container.removeFromSuperview()
    }

    /// The bridge's one way in: the film's state, from the main frame, checked; anything else is dropped. Weak, so the
    /// content controller doesn't keep the host.
    @MainActor private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var playback: ExplainerPlayback?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == ExplainerWeb.bridgeName, message.frameInfo.isMainFrame,
                  let state = ExplainerPlayback.State.parse(message.body) else { return }
            playback?.received(state)
        }
    }

    /// `ExplainerWeb`'s file-only policy and no new windows (as `ExplainerWeb.LocalOnly`), and a crashed page handed to the
    /// host (loaded again once, then given up for the poster).
    @MainActor private final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate {
        var waiting: [CheckedContinuation<Void, Never>] = []
        var terminated: ((WKWebView) -> Void)?
        func finish() {
            let done = waiting
            waiting = []
            done.forEach { $0.resume() }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish()
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            ExplainerWeb.policy(for: action)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { terminated?(webView) }
    }
}

/// The player's web view: its own class so the Router's keys know the player has the keyboard (RouterKeys.swift).
final class ExplainerPlayerWebView: WKWebView {}

/// The host's view placed in SwiftUI. Each placement adopts the one container (the view moves; the page, its time and its
/// state stay), and lets it go only if it still holds it, so a placement that leaves after the next one came keeps it there.
struct ExplainerWebView: NSViewRepresentable {
    let host: ExplainerWebHost
    /// `runs/<run>/v<n>/index.html`.
    let page: URL
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    final class Holder: NSView {
        weak var host: ExplainerWebHost?
        func adopt() {
            guard let container = host?.container else { return }
            if container.superview !== self {
                container.frame = bounds
                container.autoresizingMask = [.width, .height]
                addSubview(container)
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, host?.wantsFocus == true { host?.focus() }
        }
    }

    func makeNSView(context: Context) -> Holder {
        let holder = Holder()
        holder.host = host
        update(holder)
        return holder
    }

    func updateNSView(_ holder: Holder, context: Context) { update(holder) }

    private func update(_ holder: Holder) {
        holder.host = host
        holder.adopt()
        host.round(radius)
        host.show(page, dark: scheme == .dark)
        if host.wantsFocus, holder.window != nil { host.focus() }
    }

    static func dismantleNSView(_ holder: Holder, coordinator: ()) {
        if let container = holder.host?.container, container.superview === holder { container.removeFromSuperview() }
    }
}

/// An explainer's stage, 16:9: the playing page when it's ready in the real app (over its poster until the film's first
/// state), else its held frame. Only the picture: the panel draws everything else.
struct ExplainerStage: View {
    /// The version's page; nil while there's none yet.
    var page: URL?
    /// The held last frame in each appearance (`poster-light.jpg`, `poster-dark.jpg`).
    var posterLight: URL?
    var posterDark: URL?
    /// The draft on show while the explainer is made; nil once it's ready.
    var draft: Int?
    var ready: Bool
    /// The page's web view (nil in demos, shots and tests).
    var host: ExplainerWebHost?
    var radius: CGFloat = Router.Surface.card
    @Environment(\.colorScheme) private var scheme

    enum Mode: Equatable { case web(URL), still }

    /// The web view only for a ready explainer with a page, never in a demo or a shot, nor for a page that crashed twice.
    static func mode(page: URL?, ready: Bool, crashed: URL? = nil, demo: Bool = Store.isDemo) -> Mode {
        if !demo, ready, let page, page != crashed { return .web(page) }
        return .still
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .topLeading) {
            still
            if let host, case .web(let page) = Self.mode(page: page, ready: ready && draft == nil, crashed: host.playback.crashed) {
                ExplainerWebView(host: host, page: page, radius: radius)
                    .opacity(host.playback.state == nil ? 0 : 1)
            }
            if let draft {
                Text("Draft \(draft)").font(CDS.sans(12)).foregroundStyle(CDS.Text.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: Router.Surface.control, style: .continuous).fill(CDS.Surface.s3.opacity(0.94)))
                    .padding(10)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(shape)
        .overlay { if radius > 0 { shape.strokeBorder(CDS.border, lineWidth: 1).allowsHitTesting(false) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(draft.map { "Draft \($0), being corrected" } ?? "Explainer")
    }

    /// The held frame, at full opacity.
    @ViewBuilder private var still: some View {
        if let poster = ExplainerPosters.image(scheme == .dark ? posterDark ?? posterLight : posterLight ?? posterDark) {
            Image(nsImage: poster).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        } else {
            Rectangle().fill(Router.Surface.quiet)
        }
    }
}

/// Posters decoded once: a version's files never change once written.
@MainActor
enum ExplainerPosters {
    private static var cache: [URL: NSImage] = [:]
    private static var order: [URL] = []

    static func image(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let image = cache[url] { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[url] = image
        order.append(url)
        if order.count > 12 { cache[order.removeFirst()] = nil }
        return image
    }
}
