import Foundation
import WebKit

// The one WebKit configuration Show me's explainers run in: the offscreen renderer that takes `preview`'s frames
// (ExplainerRenderer.swift) and the player in the panel (ExplainerPlayer.swift) both make their web view from it, so a page
// the model wrote is sandboxed the same way wherever it runs. An explainer is a local file reading the local kit: it needs no
// network and nothing kept between loads, so it gets neither. The renderer's view has no way to talk to Fjord; the panel's
// player has one message handler (`bridge`), which takes only the film's state, checked (`ExplainerPlayback.State.parse`).

@MainActor
enum ExplainerWeb {
    /// Every load that isn't a `file:` URL is blocked, subresources included (scripts, styles, images, fetches, sockets).
    static let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},"#
        + #"{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}}]"#
    static let rulesID = "fjord-explainer-local-only"

    /// The player's one message handler: `window.webkit.messageHandlers.fjordPlayer` in the kit (embed mode only).
    static let bridgeName = "fjordPlayer"

    private static var compiled: WKContentRuleList?

    /// A fresh configuration for an explainer's web view: the local-only rule list, no script message handlers but the
    /// player's `bridge` when given, a data store
    /// that keeps nothing, no windows opened by script. Pair the view with `LocalOnly` (or call `policy(for:)` from your own
    /// navigation delegate), which refuses any navigation that isn't to a file.
    static func configuration(bridge: WKScriptMessageHandler? = nil) async throws -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        if let bridge { config.userContentController.add(bridge, contentWorld: .page, name: bridgeName) }
        config.userContentController.add(try await ruleList())
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        return config
    }

    /// The compiled rule list, made once per app run (WebKit keeps it in its own store by id).
    static func ruleList() async throws -> WKContentRuleList {
        if let compiled { return compiled }
        let list = try await withCheckedThrowingContinuation { (done: CheckedContinuation<WKContentRuleList, Error>) in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: rulesID, encodedContentRuleList: rules) { list, error in
                if let list { done.resume(returning: list) } else {
                    done.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
        compiled = list
        return list
    }

    /// Only file URLs may load in an explainer's frames; links, redirects and script navigations elsewhere are cancelled.
    nonisolated static func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.isFileURL || url.absoluteString == "about:blank"
    }

    static func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        allows(action.request.url) ? .allow : .cancel
    }

    /// A navigation delegate that applies `policy(for:)` and opens no new windows, for a view that needs nothing more.
    final class LocalOnly: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            ExplainerWeb.policy(for: action)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
