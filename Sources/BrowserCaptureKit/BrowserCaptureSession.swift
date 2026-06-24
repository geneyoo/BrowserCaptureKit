import Foundation
import WebKit

@MainActor
public final class BrowserCaptureSession: NSObject {
    public let configuration: BrowserCaptureConfiguration

    public var onEvent: ((BrowserCaptureEvent) -> Void)? {
        didSet {
            bridge.onEvent = onEvent
        }
    }

    public private(set) weak var webView: WKWebView?

    private let messageHandlerName = "browserCapture"
    private let bridge = ScriptMessageBridge()

    public init(configuration: BrowserCaptureConfiguration = BrowserCaptureConfiguration()) {
        self.configuration = configuration
        super.init()
        bridge.onEvent = { [weak self] event in
            self?.onEvent?(event)
        }
    }

    public func makeWebView() -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(bridge, contentWorld: .page, name: messageHandlerName)
        userContentController.addUserScript(
            WKUserScript(
                source: CaptureScript.source(configuration: configuration, messageHandlerName: messageHandlerName),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
        )

        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.userContentController = userContentController
        webViewConfiguration.websiteDataStore = websiteDataStore()
        webViewConfiguration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        self.webView = webView

        return webView
    }

    public func loadInitialURL() {
        load(configuration.initialURL)
    }

    public func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    public func reload() {
        webView?.reload()
    }

    public func goBack() {
        webView?.goBack()
    }

    public func goForward() {
        webView?.goForward()
    }

    public func clearWebsiteData() async {
        let dataStore = webView?.configuration.websiteDataStore ?? websiteDataStore()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast)
    }

    public func captureBrowserState(reason: String = "manual") {
        Task { [weak self] in
            guard let self else {
                return
            }

            let snapshot = await makeBrowserStateSnapshot(reason: reason)
            onEvent?(.browserState(snapshot))
        }
    }

    private func websiteDataStore() -> WKWebsiteDataStore {
        switch configuration.storageMode {
        case .nonPersistent:
            return .nonPersistent()
        case .persistent(let identifier):
            return WKWebsiteDataStore(forIdentifier: identifier)
        }
    }

    private func makeBrowserStateSnapshot(reason: String) async -> BrowserStateSnapshot {
        guard let webView else {
            return BrowserStateSnapshot(
                reason: reason,
                url: nil,
                title: nil,
                userAgent: nil,
                documentCookie: nil,
                localStorage: [:],
                sessionStorage: [:],
                cookies: [],
                javaScriptError: "No WKWebView is attached."
            )
        }

        async let nativeCookies = cookies(from: webView.configuration.websiteDataStore.httpCookieStore)
        async let javaScriptState = pageState(from: webView)
        let (cookies, state) = await (nativeCookies, javaScriptState)

        return BrowserStateSnapshot(
            reason: reason,
            url: webView.url,
            title: webView.title,
            userAgent: state.userAgent,
            documentCookie: state.documentCookie,
            localStorage: state.localStorage,
            sessionStorage: state.sessionStorage,
            cookies: cookies,
            javaScriptError: state.error
        )
    }

    private func cookies(from cookieStore: WKHTTPCookieStore) async -> [BrowserCookieSnapshot] {
        let cookies = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }

        return
            cookies
            .sorted { lhs, rhs in
                if lhs.domain == rhs.domain {
                    return lhs.name < rhs.name
                }
                return lhs.domain < rhs.domain
            }
            .map { cookie in
                BrowserCookieSnapshot(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain,
                    path: cookie.path,
                    expiresDate: cookie.expiresDate,
                    isSessionOnly: cookie.isSessionOnly,
                    isSecure: cookie.isSecure,
                    isHTTPOnly: cookie.isHTTPOnly
                )
            }
    }

    private func pageState(from webView: WKWebView) async -> BrowserPageState {
        let script = """
            (() => {
              const readStorage = (storage) => {
                const values = {};
                if (!storage) {
                  return values;
                }
                for (let index = 0; index < storage.length; index += 1) {
                  const key = storage.key(index);
                  if (key !== null) {
                    values[key] = storage.getItem(key);
                  }
                }
                return values;
              };

              const safe = (read) => {
                try {
                  return { value: read(), error: null };
                } catch (error) {
                  return { value: null, error: String(error && error.message ? error.message : error) };
                }
              };

              const cookie = safe(() => document.cookie);
              const local = safe(() => readStorage(window.localStorage));
              const session = safe(() => readStorage(window.sessionStorage));
              return {
                url: window.location.href,
                title: document.title,
                userAgent: navigator.userAgent,
                documentCookie: cookie.value,
                localStorage: local.value || {},
                sessionStorage: session.value || {},
                errors: {
                  documentCookie: cookie.error,
                  localStorage: local.error,
                  sessionStorage: session.error
                }
              };
            })();
            """

        do {
            let result = try await webView.evaluateJavaScript(script)
            guard let payload = result as? [String: Any] else {
                return BrowserPageState(error: "Browser state script returned a non-object result.")
            }

            let errors = payload["errors"] as? [String: Any]
            let errorText = errors?
                .compactMap { key, value -> String? in
                    guard !(value is NSNull), let value = value as? String, !value.isEmpty else {
                        return nil
                    }
                    return "\(key): \(value)"
                }
                .sorted()
                .joined(separator: "; ")

            return BrowserPageState(
                userAgent: payload["userAgent"] as? String,
                documentCookie: payload["documentCookie"] as? String,
                localStorage: stringDictionary(from: payload["localStorage"]),
                sessionStorage: stringDictionary(from: payload["sessionStorage"]),
                error: errorText?.isEmpty == false ? errorText : nil
            )
        } catch {
            return BrowserPageState(error: error.localizedDescription)
        }
    }

    private func stringDictionary(from value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else {
            return [:]
        }

        return dictionary.reduce(into: [:]) { result, entry in
            guard !(entry.value is NSNull) else {
                return
            }
            if let value = entry.value as? String {
                result[entry.key] = value
            } else {
                result[entry.key] = String(describing: entry.value)
            }
        }
    }

    private func emitPageEvent(kind: BrowserPageEvent.Kind, webView: WKWebView?, message: String? = nil) {
        onEvent?(
            .page(
                BrowserPageEvent(
                    kind: kind,
                    url: webView?.url,
                    title: webView?.title,
                    message: message
                )
            )
        )
    }
}

extension BrowserCaptureSession: WKNavigationDelegate {
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
}

private struct BrowserPageState {
    var userAgent: String?
    var documentCookie: String?
    var localStorage: [String: String] = [:]
    var sessionStorage: [String: String] = [:]
    var error: String?
}
