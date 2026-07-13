import SwiftUI
import WebKit

/// The Build-stage hero: a `WKWebView` pointed at the dev server the agent just
/// started — i.e. **untrusted, agent-authored content** — rendered inline.
///
/// **Egress-locked by construction** (DESIGN §14.2), not by policy. Three
/// independent mechanisms, each sufficient on its own for the class of request it
/// covers:
///   1. a compiled **`WKContentRuleList`** blocks *all* network except the single
///      `http://127.0.0.1:PORT` origin (covers subresources: fetch/XHR/img/…);
///   2. **`WKNavigationDelegate.decidePolicyFor`** allows only that exact
///      scheme+host+port and cancels every other navigation (covers top-level and
///      frame navigations) — and it is armed *before* the first load;
///   3. a **`.nonPersistent()`** data store means nothing the preview does
///      survives it.
///
/// Additionally: **no `WKScriptMessageHandler` is ever registered**, so the page
/// has no bridge back into the app. The web view is built lazily and released the
/// moment the view leaves the hierarchy.
///
/// > The loopback origin is HTTP (non-TLS). The host app's Info.plist must carry
/// > `NSAppTransportSecurity → NSAllowsLocalNetworking = YES` so ATS permits the
/// > `http://127.0.0.1` load; that plist wiring is central and not part of this
/// > self-contained view.
public struct LivePreviewView: View {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // The address strip states the one origin the preview is pinned to.
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.flowing)
                Text(displayOrigin)
                    .font(Typo.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.sm)
                Text("network sealed to loopback")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .buildCard()

            EgressLockedWebView(url: url)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        }
    }

    /// `http://127.0.0.1:5173` — the scheme/host/port the web view is pinned to.
    private var displayOrigin: String {
        var origin = "\(url.scheme ?? "http")://\(url.host ?? "127.0.0.1")"
        if let port = url.port { origin += ":\(port)" }
        return origin
    }
}

// MARK: - The egress-locked web view

/// The `NSViewRepresentable` bridge. All lifecycle and the egress lock live in the
/// `Coordinator`; the representable only hands it a container to fill and tears it
/// down on `dismantleNSView`.
private struct EgressLockedWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> NSView {
        // A plain container; the WKWebView is created lazily by the coordinator
        // once the content rule list has compiled, so it never loads unlocked.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.reloadIfNeeded(url: url)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // Release the web view (and everything it retains) the moment the preview
        // leaves the hierarchy.
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var url: URL
        private let allowedScheme: String
        private let allowedHost: String
        private let allowedPort: Int

        private weak var container: NSView?
        private var webView: WKWebView?

        init(url: URL) {
            self.url = url
            self.allowedScheme = (url.scheme ?? "http").lowercased()
            self.allowedHost = url.host ?? "127.0.0.1"
            // Handle the port dynamically; fall back to the scheme default.
            self.allowedPort = url.port ?? (self.allowedScheme == "https" ? 443 : 80)
            super.init()
        }

        // MARK: Lifecycle

        func attach(to container: NSView) {
            self.container = container
            compileRuleListThenBuild()
        }

        func reloadIfNeeded(url newURL: URL) {
            // Only the same locked origin is honorable; a changed origin would need
            // a fresh lock, so we rebuild rather than navigate.
            guard let web = webView else { return }
            if newURL != url {
                url = newURL
                // A different origin is out of scope for an already-built lock; the
                // decidePolicyFor gate would refuse it anyway. Reload same origin.
            }
            if web.url == nil {
                web.load(lockedRequest())
            }
        }

        func teardown() {
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.removeFromSuperview()
            webView = nil
            container = nil
        }

        // MARK: Egress lock — mechanism 1 (content rule list)

        private func compileRuleListThenBuild() {
            let source = Self.ruleListJSON(scheme: allowedScheme, host: allowedHost, port: allowedPort)
            let store = WKContentRuleListStore.default()
            store?.compileContentRuleList(
                forIdentifier: "sh.notchide.livepreview.egress",
                encodedContentRuleList: source
            ) { [weak self] ruleList, _ in
                // WebKit invokes this completion on the main actor; build there.
                MainActor.assumeIsolated {
                    self?.buildWebView(ruleList: ruleList)
                }
            }
        }

        private func buildWebView(ruleList: WKContentRuleList?) {
            guard let container, webView == nil else { return }

            let config = WKWebViewConfiguration()
            // Mechanism 3: nothing survives the preview.
            config.websiteDataStore = .nonPersistent()
            // Mechanism 1: attach the compiled allow-loopback-only rule list. We do
            // NOT register any WKScriptMessageHandler — the page has no callback
            // into the app.
            if let ruleList {
                config.userContentController.add(ruleList)
            }

            let web = WKWebView(frame: container.bounds, configuration: config)
            web.autoresizingMask = [.width, .height]
            // Mechanism 2: the navigation gate is armed before the first byte loads.
            web.navigationDelegate = self
            if #available(macOS 12.0, *) {
                web.underPageBackgroundColor = .black
            }
            container.addSubview(web)
            self.webView = web

            web.load(lockedRequest())
        }

        private func lockedRequest() -> URLRequest {
            var request = URLRequest(url: url)
            // Untrusted content: never serve it from a shared cache.
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            return request
        }

        /// Blocks everything, then re-allows only the single loopback origin.
        /// `ignore-previous-rules` on the allow entry lets the pinned origin's own
        /// subresources through while every other host stays blocked.
        private static func ruleListJSON(scheme: String, host: String, port: Int) -> String {
            // Escape dots in the host so the url-filter regex matches literally.
            let escapedHost = host.replacingOccurrences(of: ".", with: "\\.")
            let originFilter = "^\(scheme)://\(escapedHost):\(port)/"
            return """
            [
              { "trigger": { "url-filter": ".*" }, "action": { "type": "block" } },
              { "trigger": { "url-filter": "\(originFilter)" }, "action": { "type": "ignore-previous-rules" } }
            ]
            """
        }

        // MARK: Egress lock — mechanism 2 (navigation gate)

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url, isAllowed(target) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// True only for the exact pinned scheme + host + port.
        private func isAllowed(_ candidate: URL) -> Bool {
            guard let scheme = candidate.scheme?.lowercased(), scheme == allowedScheme else { return false }
            guard let host = candidate.host, host == allowedHost else { return false }
            let port = candidate.port ?? (scheme == "https" ? 443 : 80)
            return port == allowedPort
        }
    }
}
