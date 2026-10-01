import SwiftUI
import WebKit

/// Bandcamp's own login page. When the sign-in cookie appears, it is checked and kept, and the sheet closes.
/// The page runs in a private store, so nothing of the session stays in the app except that cookie.
struct BandcampLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Shown when Bandcamp does not accept the sign-in cookie.
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            LoginWebView { identity in
                // Bandcamp sets the cookie only after a sign-in.
                do {
                    try await BandcampAccount.shared.signIn(identity: identity)
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
            }
            Divider()
            HStack {
                Text(error ?? "Your password goes to Bandcamp only.")
                    .font(.footnote)
                    .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 640)
    }
}

private struct LoginWebView: NSViewRepresentable {
    let onIdentity: @MainActor (String) async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onIdentity: onIdentity) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://bandcamp.com/login")!))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate {
        let onIdentity: @MainActor (String) async -> Void
        /// The last cookie value tried, so each one is checked once.
        private var tried: String?

        init(onIdentity: @escaping @MainActor (String) async -> Void) {
            self.onIdentity = onIdentity
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            check(cookieStore)
        }

        // The cookie notice did not come after a sign-in, so each loaded page checks too.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            check(webView.configuration.websiteDataStore.httpCookieStore)
        }

        private func check(_ cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { cookies in
                guard let identity = cookies.first(where: { $0.name == "identity" && $0.domain.hasSuffix("bandcamp.com") })?.value,
                      !identity.isEmpty, identity != self.tried else { return }
                self.tried = identity
                Task { @MainActor in await self.onIdentity(identity) }
            }
        }
    }
}
