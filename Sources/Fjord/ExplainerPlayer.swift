import AppKit
import SwiftUI
import WebKit

// Show me's player (docs/design/router-visuals/SHOWME.md §8): a finished explainer plays in a sandboxed web view, the page
// the creator wrote on the project's kit, made from `ExplainerWeb.configuration()` (no network, no script handlers, nothing
// kept) with `ExplainerWeb.LocalOnly` refusing every navigation that isn't to a file. The page draws its own answer,
// stage, caption, scene bar, time and Sources (`?embed=1` trims it to the panel); Fjord only picks its appearance, which the
// kit follows through `prefers-color-scheme`, rebuilding the film where it stands. There's no bridge: nothing in Fjord knows
// the page's time.
//
// Shots, demos and explainers still being made never get a web view (a shot can't capture one): they draw the version's held
// last frame, the poster the renderer saved, with the draft's tag over it while it's made.

/// One web view for the panel, kept across selections (a new page is a `load`, not a new view) and let go when the panel
/// closes. At rest it runs nothing: the kit's timeline only plays when asked.
@MainActor
final class ExplainerWebHost {
    let container = NSView()
    private(set) var view: WKWebView?
    private let delegate = Delegate()
    private var page: URL?
    private var dark = false
    private var making: Task<Void, Never>?
    private var closed = false
    private var crashes = Crashes()
    /// The page's web content process died again after its one reload: the panel shows the poster instead.
    var onGaveUp: (@MainActor (URL) -> Void)?

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

    init() {
        making = Task { @MainActor [weak self] in
            guard let config = try? await ExplainerWeb.configuration(), let self, !self.closed else { return }
            let view = WKWebView(frame: self.container.bounds, configuration: config)
            view.autoresizingMask = [.width, .height]
            view.navigationDelegate = self.delegate
            view.uiDelegate = self.delegate
            self.delegate.terminated = { [weak self] view in self?.terminated(view) }
            view.allowsBackForwardNavigationGestures = false
            view.allowsMagnification = false
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
        if let view { apply(view, load: load) }
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
        if crashes.died(page) {
            view.reload()
        } else if let page {
            delegate.finish()
            onGaveUp?(page)
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
        view?.stopLoading()
        view?.removeFromSuperview()
        view = nil
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

/// The player in SwiftUI: the page for a ready explainer, at the panel's width.
struct ExplainerWebView: NSViewRepresentable {
    /// `runs/<run>/v<n>/index.html`.
    let page: URL
    /// The page crashed twice: show the poster.
    var gaveUp: (URL) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme

    /// The page's own chrome, in points, at the panel's width: the answer (two lines), the caption and the scene bar. The
    /// stage is 16:9 of the width.
    static let chrome: CGFloat = 132

    static func height(width: CGFloat) -> CGFloat { (width * 9 / 16).rounded() + chrome }

    func makeCoordinator() -> ExplainerWebHost { ExplainerWebHost() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onGaveUp = gaveUp
        context.coordinator.show(page, dark: scheme == .dark)
        return context.coordinator.container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onGaveUp = gaveUp
        context.coordinator.show(page, dark: scheme == .dark)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ExplainerWebHost) {
        coordinator.close()
    }
}

/// An explainer's stage: the playing page when it's ready in the real app, else its held frame. The page brings its own
/// answer, caption and scene bar, so a panel showing the web view draws none of its own (`mode(…) == .web`); the still is
/// the stage alone, 16:9.
struct ExplainerStage: View {
    /// The version's page; nil while there's none yet.
    var page: URL?
    /// The held last frame in each appearance (`poster-light.jpg`, `poster-dark.jpg`).
    var posterLight: URL?
    var posterDark: URL?
    /// The draft on show while the explainer is made; nil once it's ready.
    var draft: Int?
    var ready: Bool
    /// A page whose web process died twice: it shows its poster from then on.
    @State private var crashed: URL?
    @Environment(\.colorScheme) private var scheme

    enum Mode: Equatable { case web(URL), still }

    /// The web view only for a ready explainer with a page, never in a demo or a shot, nor for a page that crashed twice.
    static func mode(page: URL?, ready: Bool, crashed: URL? = nil, demo: Bool = Store.isDemo) -> Mode {
        if !demo, ready, let page, page != crashed { return .web(page) }
        return .still
    }

    var body: some View {
        switch Self.mode(page: page, ready: ready && draft == nil, crashed: crashed) {
        case .web(let page):
            WidthHeld(page: page) { crashed = $0 }
        case .still:
            still
        }
    }

    /// The held frame, at full opacity, with the draft's tag while it's made.
    private var still: some View {
        let shape = RoundedRectangle(cornerRadius: Router.Surface.card, style: .continuous)
        return ZStack(alignment: .topLeading) {
            if let poster = ExplainerPosters.image(scheme == .dark ? posterDark ?? posterLight : posterLight ?? posterDark) {
                Image(nsImage: poster).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit).clipped()
            } else {
                Rectangle().fill(Router.Surface.quiet).aspectRatio(16 / 9, contentMode: .fit)
            }
            if let draft {
                HStack(spacing: 6) {
                    RouterThinking(tint: CDS.Text.secondary, size: 12, label: "Correcting")
                    Text("Draft \(draft) · correcting").font(CDS.sans(12)).foregroundStyle(CDS.Text.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Router.Surface.control, style: .continuous).fill(CDS.Surface.s3.opacity(0.94)))
                .padding(10)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(CDS.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(draft.map { "Draft \($0), being corrected" } ?? "Explainer")
    }
}

/// The web view at the width it's given and the height that width needs.
private struct WidthHeld: View {
    let page: URL
    let gaveUp: (URL) -> Void
    @State private var width: CGFloat = 0

    var body: some View {
        ExplainerWebView(page: page, gaveUp: gaveUp)
            .frame(height: width > 0 ? ExplainerWebView.height(width: width) : 0)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, new in width = new }
            })
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
