import SwiftUI
import WebKit

public struct BrowserCaptureWebView: UIViewRepresentable {
    private let session: BrowserCaptureSession
    private let initialURL: URL

    public init(session: BrowserCaptureSession, initialURL: URL? = nil) {
        self.session = session
        self.initialURL = initialURL ?? session.configuration.initialURL
    }

    public func makeUIView(context: Context) -> WKWebView {
        let webView = session.makeWebView()
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        if webView.url == nil {
            webView.load(URLRequest(url: initialURL))
        }
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}
