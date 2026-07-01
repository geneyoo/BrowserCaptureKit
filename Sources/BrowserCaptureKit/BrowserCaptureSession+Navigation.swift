import Foundation
import WebKit

extension BrowserCaptureSession: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        emitNavigationAction(navigationAction)
        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        emitNavigationResponse(navigationResponse)
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        emitPageEvent(kind: .navigationStarted, webView: webView)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        emitPageEvent(kind: .navigationFinished, webView: webView)
        captureBrowserState(reason: "navigationFinished")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        emitPageEvent(kind: .navigationFailed, webView: webView, message: error.localizedDescription)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        emitPageEvent(kind: .navigationFailed, webView: webView, message: error.localizedDescription)
    }

    private func emitNavigationAction(_ navigationAction: WKNavigationAction) {
        let request = navigationAction.request
        emit(
            .nativeNetwork(
                BrowserNativeNetworkEvent(
                    phase: .navigationAction,
                    url: request.url,
                    mainDocumentURL: request.mainDocumentURL,
                    method: request.httpMethod,
                    headers: request.allHTTPHeaderFields ?? [:],
                    isForMainFrame: navigationAction.targetFrame?.isMainFrame,
                    navigationType: navigationTypeString(navigationAction.navigationType)
                )
            )
        )
    }

    private func emitNavigationResponse(_ navigationResponse: WKNavigationResponse) {
        let response = navigationResponse.response
        let httpResponse = response as? HTTPURLResponse
        emit(
            .nativeNetwork(
                BrowserNativeNetworkEvent(
                    phase: .navigationResponse,
                    url: response.url,
                    status: httpResponse?.statusCode,
                    mimeType: response.mimeType,
                    expectedContentLength: response.expectedContentLength,
                    headers: stringHeaders(from: httpResponse?.allHeaderFields ?? [:]),
                    isForMainFrame: navigationResponse.isForMainFrame,
                    canShowMIMEType: navigationResponse.canShowMIMEType
                )
            )
        )
    }

    private func stringHeaders(from headers: [AnyHashable: Any]) -> [String: String] {
        headers.reduce(into: [:]) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
    }

    private func navigationTypeString(_ navigationType: WKNavigationType) -> String {
        switch navigationType {
        case .linkActivated:
            return "linkActivated"
        case .formSubmitted:
            return "formSubmitted"
        case .backForward:
            return "backForward"
        case .reload:
            return "reload"
        case .formResubmitted:
            return "formResubmitted"
        case .other:
            return "other"
        @unknown default:
            return "unknown"
        }
    }
}
