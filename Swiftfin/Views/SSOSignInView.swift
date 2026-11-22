//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//

import SwiftUI
import WebKit

struct SSOSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var errorMessage: String?

    let serverURL: URL
    let serverID: String
    let onSignIn: (URL, String, String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    Text(verbatim: errorMessage).padding()
                } else {
                    SSOLoginBrowser(
                        serverURL: serverURL,
                        serverID: serverID,
                        showHost: { host = $0 },
                        failed: { errorMessage = $0 },
                        onSignIn: onSignIn
                    )
                }
            }
            .navigationTitle(host.isEmpty ? serverURL.host ?? "" : host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) { dismiss() }
                }
            }
        }
    }
}

private struct SSOLoginBrowser: UIViewRepresentable {
    let serverURL: URL
    let serverID: String
    let showHost: (String) -> Void
    let failed: (String) -> Void
    let onSignIn: (URL, String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(browser: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: serverURL))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let browser: SSOLoginBrowser
        var active = true

        init(browser: SSOLoginBrowser) { self.browser = browser }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.targetFrame?.isMainFrame == true, action.request.url?.scheme?.lowercased() != "https" {
                decisionHandler(.cancel)
                if active { browser.failed("SSO requires a secure HTTPS connection.") }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if active { browser.showHost(webView.url?.host ?? "") }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let index = browser.serverURL.appendingPathComponent("web/index.html")
            guard active, let url = webView.url, url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == index.host?.lowercased(), (url.port ?? 443) == (index.port ?? 443),
                  url.path == index.path else { return }

            // SSO-Auth writes its credentials before navigating the top frame back to Jellyfin.
            // Recheck the live document in WebKit in case another navigation began after didFinish.
            webView.callAsyncJavaScript(
                """
                const index = new URL(expectedIndex);
                if (location.origin !== index.origin || location.pathname !== index.pathname) return null;
                const session = JSON.parse(localStorage.getItem("jellyfin_credentials"));
                const entry = session?.Servers?.find(s => s.Id === serverID && s.UserId && s.AccessToken);
                return entry ? {user: entry.UserId, token: entry.AccessToken} : null;
                """,
                arguments: ["expectedIndex": index.absoluteString, "serverID": browser.serverID],
                in: nil, in: .defaultClient
            ) { [weak self] result in
                guard let self, active else { return }
                switch result {
                case let .success(value):
                    guard let entry = value as? [String: String],
                          let user = entry["user"], let token = entry["token"] else { return }
                    active = false
                    browser.onSignIn(browser.serverURL, user, token)
                case .failure:
                    browser.failed("Unable to read the Jellyfin sign-in response.")
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            guard active, (error as NSError).code != NSURLErrorCancelled else { return }
            browser.failed(error.localizedDescription)
        }
    }
}
