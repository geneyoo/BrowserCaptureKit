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

    public var onViewportChanged: ((String?) -> Void)? {
        didSet {
            bridge.onViewportChanged = onViewportChanged
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

    public func captureAccessibilitySnapshot(reason: String = "manual") {
        Task { [weak self] in
            guard let self else {
                return
            }

            let snapshot = await makeAccessibilitySnapshot(reason: reason)
            onEvent?(.accessibility(snapshot))
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

    private func makeAccessibilitySnapshot(reason: String) async -> BrowserAccessibilitySnapshot {
        guard let webView else {
            return BrowserAccessibilitySnapshot(
                reason: reason,
                url: nil,
                title: nil,
                viewportWidth: nil,
                viewportHeight: nil,
                elementCount: 0,
                labeledElementCount: 0,
                unlabeledInteractiveElementCount: 0,
                elementsOmitted: 0,
                elements: [],
                javaScriptError: "No WKWebView is attached."
            )
        }

        let state = await accessibilityState(from: webView)
        return BrowserAccessibilitySnapshot(
            reason: reason,
            url: webView.url,
            title: webView.title,
            viewportWidth: state.viewportWidth,
            viewportHeight: state.viewportHeight,
            elementCount: state.elementCount,
            labeledElementCount: state.labeledElementCount,
            unlabeledInteractiveElementCount: state.unlabeledInteractiveElementCount,
            elementsOmitted: state.elementsOmitted,
            elements: state.elements,
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

    private func accessibilityState(from webView: WKWebView) async -> BrowserAccessibilityPageState {
        do {
            let result = try await webView.evaluateJavaScript(BrowserAccessibilityScript.source)
            guard let payload = result as? [String: Any] else {
                return BrowserAccessibilityPageState(error: "Accessibility script returned a non-object result.")
            }

            let elements = (payload["elements"] as? [[String: Any]] ?? [])
                .compactMap(accessibilityElement(from:))

            return BrowserAccessibilityPageState(
                viewportWidth: double(payload["viewportWidth"]),
                viewportHeight: double(payload["viewportHeight"]),
                elementCount: int(payload["elementCount"]) ?? elements.count,
                labeledElementCount: int(payload["labeledElementCount"]) ?? elements.filter { $0.label?.isEmpty == false }.count,
                unlabeledInteractiveElementCount: int(payload["unlabeledInteractiveElementCount"])
                    ?? elements.filter {
                        $0.isInteractive && ($0.label?.isEmpty ?? true)
                    }.count,
                elementsOmitted: int(payload["elementsOmitted"]) ?? 0,
                elements: elements
            )
        } catch {
            return BrowserAccessibilityPageState(error: error.localizedDescription)
        }
    }

    private func accessibilityElement(from payload: [String: Any]) -> BrowserAccessibilityElementSnapshot? {
        guard let index = int(payload["index"]),
            let tagName = string(payload["tagName"])
        else {
            return nil
        }

        let boundsPayload = payload["bounds"] as? [String: Any]
        let bounds = BrowserElementBounds(
            x: double(boundsPayload?["x"]) ?? 0,
            y: double(boundsPayload?["y"]) ?? 0,
            width: double(boundsPayload?["width"]) ?? 0,
            height: double(boundsPayload?["height"]) ?? 0
        )

        return BrowserAccessibilityElementSnapshot(
            index: index,
            tagName: tagName,
            role: string(payload["role"]),
            label: string(payload["label"]),
            labelSource: string(payload["labelSource"]),
            text: string(payload["text"]),
            value: string(payload["value"]),
            placeholder: string(payload["placeholder"]),
            href: string(payload["href"]),
            source: string(payload["source"]),
            inputType: string(payload["inputType"]),
            isVisible: bool(payload["isVisible"]) ?? false,
            isInteractive: bool(payload["isInteractive"]) ?? false,
            isDisabled: bool(payload["isDisabled"]) ?? false,
            ariaHidden: bool(payload["ariaHidden"]) ?? false,
            bounds: bounds,
            path: string(payload["path"]) ?? ""
        )
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

    private func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? String {
            return value.isEmpty ? nil : value
        }
        return String(describing: value)
    }

    private func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return Int(value)
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func double(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return nil
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

private struct BrowserAccessibilityPageState {
    var viewportWidth: Double?
    var viewportHeight: Double?
    var elementCount: Int = 0
    var labeledElementCount: Int = 0
    var unlabeledInteractiveElementCount: Int = 0
    var elementsOmitted: Int = 0
    var elements: [BrowserAccessibilityElementSnapshot] = []
    var error: String?
}
