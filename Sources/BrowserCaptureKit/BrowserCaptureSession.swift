import Foundation
import WebKit

public enum BrowserCaptureError: Error, Sendable {
    case noWebView
}

@MainActor
public final class BrowserCaptureSession: NSObject {
    public let configuration: BrowserCaptureConfiguration

    public var onEvent: ((BrowserCaptureEvent) -> Void)? {
        didSet {
            bridge.onEvent = { [weak self] event in
                self?.emit(event)
            }
        }
    }

    public var onViewportChanged: ((String?) -> Void)? {
        didSet {
            bridge.onViewportChanged = onViewportChanged
        }
    }

    public private(set) var webView: WKWebView?

    private let messageHandlerName = "browserCapture"
    private let bridge = ScriptMessageBridge()
    private var pageEpoch = 0
    private var capturedResponseCount = 0

    public init(configuration: BrowserCaptureConfiguration = BrowserCaptureConfiguration()) {
        self.configuration = configuration
        super.init()
        bridge.onEvent = { [weak self] event in
            self?.emit(event)
        }
    }

    public func makeWebView() -> WKWebView {
        if let webView {
            return webView
        }

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

    /// The most recently observed non-main frame (e.g. a cross-origin chat-widget
    /// iframe), captured from `WKScriptMessage.frameInfo`. Because our capture
    /// script is injected with `forMainFrameOnly: false`, this is populated as
    /// soon as the child frame emits any traffic. Use it as the target for
    /// ``evaluateJavaScript(_:inChildFrame:)`` to drive the widget's DOM.
    public var latestChildFrame: WKFrameInfo? {
        bridge.lastChildFrame
    }

    /// Security origin of the frame that most recently carried WebSocket traffic,
    /// recorded from the capture hook's socket events. Constrains which child frame
    /// a WebSocket replay may fall back to.
    var latestWebSocketOrigin: String? {
        bridge.lastWebSocketSecurityOrigin
    }

    /// Evaluate JavaScript in a specific frame (defaults to the latest child
    /// frame). This is how native code reaches into a cross-origin child iframe:
    /// the injected in-frame script is same-origin with the child document, so
    /// evaluating there can read/drive the widget's DOM directly.
    @discardableResult
    public func evaluateJavaScript(
        _ javaScript: String,
        inChildFrame frame: WKFrameInfo? = nil
    ) async throws -> Any? {
        guard let webView else {
            throw BrowserCaptureError.noWebView
        }
        let targetFrame = frame ?? bridge.lastChildFrame
        return try await webView.evaluateJavaScript(javaScript, in: targetFrame, contentWorld: .page)
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

            let snapshot = await browserStateSnapshot(reason: reason)
            onEvent?(.browserState(snapshot))
        }
    }

    public func captureAccessibilitySnapshot(reason: String = "manual") {
        Task { [weak self] in
            guard let self else {
                return
            }

            let snapshot = await accessibilitySnapshot(reason: reason)
            onEvent?(.accessibility(snapshot))
        }
    }

    public func browserStateSnapshot(reason: String = "manual") async -> BrowserStateSnapshot {
        await makeBrowserStateSnapshot(reason: reason)
    }

    public func accessibilitySnapshot(reason: String = "manual") async -> BrowserAccessibilitySnapshot {
        await makeAccessibilitySnapshot(reason: reason)
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
                websiteDataRecords: [],
                javaScriptError: "No WKWebView is attached."
            )
        }

        async let nativeCookies = cookies(from: webView.configuration.websiteDataStore.httpCookieStore)
        async let websiteRecords = websiteDataRecords(from: webView.configuration.websiteDataStore)
        async let javaScriptState = pageState(from: webView)
        let (cookies, records, state) = await (nativeCookies, websiteRecords, javaScriptState)

        return BrowserStateSnapshot(
            reason: reason,
            url: webView.url,
            title: webView.title,
            userAgent: state.userAgent,
            documentCookie: state.documentCookie,
            localStorage: state.localStorage,
            sessionStorage: state.sessionStorage,
            cookies: cookies,
            websiteDataRecords: records,
            javaScriptError: state.error
        )
    }

    private func makeAccessibilitySnapshot(reason: String) async -> BrowserAccessibilitySnapshot {
        guard let webView else {
            return BrowserAccessibilitySnapshot(
                reason: reason,
                pageEpoch: pageEpoch,
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
            pageEpoch: pageEpoch,
            url: webView.url,
            title: webView.title,
            scrollX: state.scrollX,
            scrollY: state.scrollY,
            viewportOffsetX: state.viewportOffsetX,
            viewportOffsetY: state.viewportOffsetY,
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

    private func websiteDataRecords(from dataStore: WKWebsiteDataStore) async -> [BrowserWebsiteDataRecordSnapshot] {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                continuation.resume(returning: records)
            }
        }

        return
            records
            .sorted { lhs, rhs in
                lhs.displayName < rhs.displayName
            }
            .map { record in
                BrowserWebsiteDataRecordSnapshot(
                    displayName: record.displayName,
                    dataTypes: Array(record.dataTypes).sorted()
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
                scrollX: double(payload["scrollX"]),
                scrollY: double(payload["scrollY"]),
                viewportOffsetX: double(payload["viewportOffsetX"]),
                viewportOffsetY: double(payload["viewportOffsetY"]),
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
            stableID: string(payload["stableID"]),
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
            isEditable: bool(payload["isEditable"]) ?? false,
            isObscuredAtCenter: bool(payload["isObscuredAtCenter"]) ?? false,
            ariaHidden: bool(payload["ariaHidden"]) ?? false,
            bounds: bounds,
            path: string(payload["path"]) ?? "",
            selectorFingerprint: string(payload["selectorFingerprint"]),
            supportedActions: (payload["supportedActions"] as? [String] ?? [])
                .compactMap(BrowserActionKind.init(rawValue:))
        )
    }

    private func resolvedElement(from value: Any?) -> BrowserResolvedElement? {
        guard let payload = value as? [String: Any] else {
            return nil
        }

        let bounds: BrowserElementBounds?
        if let boundsPayload = payload["bounds"] as? [String: Any] {
            bounds = BrowserElementBounds(
                x: double(boundsPayload["x"]) ?? 0,
                y: double(boundsPayload["y"]) ?? 0,
                width: double(boundsPayload["width"]) ?? 0,
                height: double(boundsPayload["height"]) ?? 0
            )
        } else {
            bounds = nil
        }

        return BrowserResolvedElement(
            score: double(payload["score"]) ?? 0,
            index: int(payload["index"]),
            tagName: string(payload["tagName"]),
            role: string(payload["role"]),
            label: string(payload["label"]),
            text: string(payload["text"]),
            path: string(payload["path"]),
            selectorFingerprint: string(payload["selectorFingerprint"]),
            bounds: bounds,
            isVisible: bool(payload["isVisible"]) ?? false,
            isInteractive: bool(payload["isInteractive"]) ?? false,
            isDisabled: bool(payload["isDisabled"]) ?? false,
            isEditable: bool(payload["isEditable"]) ?? false,
            isObscuredAtCenter: bool(payload["isObscuredAtCenter"]) ?? false
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

    func emitPageEvent(kind: BrowserPageEvent.Kind, webView: WKWebView?, message: String? = nil) {
        emit(
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

    func emit(_ event: BrowserCaptureEvent) {
        switch event {
        case .page(let event):
            if event.kind == .navigationStarted {
                pageEpoch += 1
            }
        case .response, .nativeNetwork:
            capturedResponseCount += 1
        case .browserState, .accessibility, .console, .scriptError, .action:
            break
        }
        onEvent?(event)
    }
}

extension BrowserCaptureSession {
    @discardableResult
    public func perform(_ action: BrowserActionRequest) async -> BrowserActionResult {
        let context = BrowserActionExecutionContext(
            requestID: UUID(),
            responseCountBefore: capturedResponseCount,
            urlBefore: webView?.url
        )
        let result = await perform(action, context: context)
        emit(.action(result))
        return result
    }

    @discardableResult
    public func clickElement(label: String, role: String? = nil) async -> BrowserActionResult {
        await perform(.tap(target: .label(label, role: role)))
    }

    @discardableResult
    public func scrollBy(deltaX: Double = 0, deltaY: Double) -> BrowserActionResult {
        let context = BrowserActionExecutionContext(
            requestID: UUID(),
            responseCountBefore: capturedResponseCount,
            urlBefore: webView?.url
        )
        let result = makeScrollResult(context: context, deltaX: deltaX, deltaY: deltaY)
        emit(.action(result))
        captureAccessibilitySnapshot(reason: "action:scroll")
        return result
    }

    /// The `pageEpoch` a target was captured against, if it is snapshot-bound.
    /// `nil` for label-only / epoch-less targets (never stale-rejected).
    private func targetPageEpoch(for action: BrowserActionRequest) -> Int? {
        switch action {
        case .tap(let target), .clear(let target):
            return target.pageEpoch
        case .fill(let target, _, _):
            return target.pageEpoch
        case .pressEnter(let target), .swipe(let target, _):
            return target?.pageEpoch
        case .waitFor(.element(let target)):
            return target.pageEpoch
        default:
            return nil
        }
    }

    private func perform(
        _ action: BrowserActionRequest,
        context: BrowserActionExecutionContext
    ) async -> BrowserActionResult {
        // Stale-epoch rejection (WS-TGT): a target captured against an earlier
        // page (navigation/reload bumped pageEpoch) must not act on the new DOM.
        if let targetEpoch = targetPageEpoch(for: action), targetEpoch != pageEpoch {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: action.kind,
                status: .staleSnapshot,
                message: "Rejected: target pageEpoch \(targetEpoch) != current \(pageEpoch) (page changed since capture).",
                urlBefore: context.urlBefore,
                urlAfter: webView?.url
            )
        }

        switch action {
        case .observe(let reason):
            return await performObserve(reason: reason, context: context)
        case .tap(let target):
            return await performScriptedAction(context: context, kind: .tap, source: BrowserActionScript.tapSource(target: target))
        case .fill(let target, let text, let submit):
            return await performScriptedAction(
                context: context,
                kind: .fill,
                source: BrowserActionScript.fillSource(target: target, text: text, submit: submit),
                redactionWarnings: ["Filled text is redacted from action traces."]
            )
        case .clear(let target):
            return await performScriptedAction(context: context, kind: .clear, source: BrowserActionScript.clearSource(target: target))
        case .pressEnter(let target):
            return await performScriptedAction(
                context: context,
                kind: .pressEnter,
                source: BrowserActionScript.pressEnterSource(target: target)
            )
        case .scroll(let deltaX, let deltaY):
            return await performScroll(context: context, deltaX: deltaX, deltaY: deltaY)
        case .swipe(let target, let direction):
            return await performSwipe(context: context, target: target, direction: direction)
        case .openURL(let url):
            load(url)
            return navigationResult(context: context, kind: .openURL, message: "Opened \(url.absoluteString).")
        case .back:
            goBack()
            return navigationResult(context: context, kind: .back, message: "Requested browser back navigation.")
        case .forward:
            goForward()
            return navigationResult(context: context, kind: .forward, message: "Requested browser forward navigation.")
        case .reload:
            reload()
            return navigationResult(context: context, kind: .reload, message: "Requested browser reload.")
        case .waitFor(let condition):
            return await performImmediateWait(context: context, condition: condition)
        case .wsReplay(let frame, let note):
            return await performWebSocketReplay(frame: frame, note: note, context: context)
        case .restReissue(let method, let urlTemplate, let body):
            return await performRestReissue(method: method, urlTemplate: urlTemplate, body: body, context: context)
        }
    }

    private func performObserve(reason: String, context: BrowserActionExecutionContext) async -> BrowserActionResult {
        let snapshot = await makeAccessibilitySnapshot(reason: reason)
        emit(.accessibility(snapshot))
        return BrowserActionResult(
            requestID: context.requestID,
            kind: .observe,
            status: .succeeded,
            message: "Captured \(snapshot.elements.count) action candidates.",
            matchedElementCount: snapshot.elements.count,
            afterSnapshotID: snapshot.id,
            urlBefore: context.urlBefore,
            urlAfter: webView?.url,
            networkEventCountDelta: networkDelta(since: context)
        )
    }

    private func navigationResult(
        context: BrowserActionExecutionContext,
        kind: BrowserActionKind,
        message: String
    ) -> BrowserActionResult {
        BrowserActionResult(
            requestID: context.requestID,
            kind: kind,
            status: .succeeded,
            message: message,
            urlBefore: context.urlBefore,
            urlAfter: webView?.url,
            networkEventCountDelta: networkDelta(since: context)
        )
    }

    private func performScriptedAction(
        context: BrowserActionExecutionContext,
        kind: BrowserActionKind,
        source: String,
        redactionWarnings: [String] = []
    ) async -> BrowserActionResult {
        guard let webView else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: kind,
                status: .noWebView,
                message: "No WKWebView is attached.",
                urlBefore: context.urlBefore,
                networkEventCountDelta: networkDelta(since: context)
            )
        }

        do {
            let result = try await webView.evaluateJavaScript(source)
            guard let payload = result as? [String: Any] else {
                return BrowserActionResult(
                    requestID: context.requestID,
                    kind: kind,
                    status: .scriptError,
                    message: "Action script returned a non-object result.",
                    urlBefore: context.urlBefore,
                    urlAfter: webView.url,
                    networkEventCountDelta: networkDelta(since: context)
                )
            }

            return await scriptedActionResult(
                payload: payload,
                context: context,
                kind: kind,
                webViewURL: webView.url,
                redactionWarnings: redactionWarnings
            )
        } catch {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: kind,
                status: .scriptError,
                message: error.localizedDescription,
                urlBefore: context.urlBefore,
                urlAfter: webView.url,
                networkEventCountDelta: networkDelta(since: context)
            )
        }
    }

    private func scriptedActionResult(
        payload: [String: Any],
        context: BrowserActionExecutionContext,
        kind: BrowserActionKind,
        webViewURL: URL?,
        redactionWarnings: [String]
    ) async -> BrowserActionResult {
        let afterSnapshot = await makeAccessibilitySnapshot(reason: "action:\(kind.rawValue)")
        emit(.accessibility(afterSnapshot))
        let statusText = string(payload["status"]) ?? "scriptError"
        let status = BrowserActionStatus(rawValue: statusText) ?? .scriptError
        let selectedElement = resolvedElement(from: payload["selectedElement"])
        let candidates = (payload["candidates"] as? [[String: Any]] ?? [])
            .compactMap { resolvedElement(from: $0) }

        return BrowserActionResult(
            requestID: context.requestID,
            kind: kind,
            status: status,
            message: string(payload["message"]) ?? "Action finished.",
            matchedElementCount: int(payload["matchedElementCount"]) ?? candidates.count,
            selectedElement: selectedElement,
            candidateSummaries: candidates,
            afterSnapshotID: afterSnapshot.id,
            urlBefore: context.urlBefore,
            urlAfter: webViewURL,
            networkEventCountDelta: networkDelta(since: context),
            warnings: redactionWarnings + (payload["warnings"] as? [String] ?? []),
            label: selectedElement?.label,
            role: selectedElement?.role,
            path: selectedElement?.path
        )
    }

    private func performScroll(
        context: BrowserActionExecutionContext,
        deltaX: Double,
        deltaY: Double
    ) async -> BrowserActionResult {
        let result = makeScrollResult(context: context, deltaX: deltaX, deltaY: deltaY)
        guard result.succeeded else {
            return result
        }

        let snapshot = await makeAccessibilitySnapshot(reason: "action:scroll")
        emit(.accessibility(snapshot))
        return result.withAfterSnapshotID(snapshot.id)
    }

    private func performSwipe(
        context: BrowserActionExecutionContext,
        target: BrowserElementTarget?,
        direction: BrowserSwipeDirection
    ) async -> BrowserActionResult {
        guard target == nil else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .swipe,
                status: .unsupported,
                message: "Targeted swipe is not implemented yet; use page-level swipe.",
                urlBefore: context.urlBefore,
                urlAfter: webView?.url,
                networkEventCountDelta: networkDelta(since: context)
            )
        }

        let distance = max(160, (webView?.bounds.height ?? 600) * 0.72)
        let width = max(160, (webView?.bounds.width ?? 400) * 0.72)
        switch direction {
        case .up:
            return await performScroll(context: context, deltaX: 0, deltaY: distance)
        case .down:
            return await performScroll(context: context, deltaX: 0, deltaY: -distance)
        case .left:
            return await performScroll(context: context, deltaX: width, deltaY: 0)
        case .right:
            return await performScroll(context: context, deltaX: -width, deltaY: 0)
        }
    }

    private func performImmediateWait(
        context: BrowserActionExecutionContext,
        condition: BrowserWaitCondition
    ) async -> BrowserActionResult {
        switch condition {
        case .urlContains(let text):
            let currentURL = webView?.url?.absoluteString ?? ""
            let succeeded = currentURL.localizedCaseInsensitiveContains(text)
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .waitFor,
                status: succeeded ? .succeeded : .timedOut,
                message: succeeded ? "URL matched '\(text)'." : "URL did not match '\(text)'.",
                urlBefore: context.urlBefore,
                urlAfter: webView?.url,
                networkEventCountDelta: networkDelta(since: context)
            )
        case .element(let target):
            return await performScriptedAction(
                context: context,
                kind: .waitFor,
                source: BrowserActionScript.waitForElementSource(target: target)
            )
        case .quiet:
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .waitFor,
                status: .unsupported,
                message: "Quiet wait needs mutation/network-backed waiting and is not implemented yet.",
                urlBefore: context.urlBefore,
                urlAfter: webView?.url,
                networkEventCountDelta: networkDelta(since: context)
            )
        }
    }

    private func makeScrollResult(
        context: BrowserActionExecutionContext,
        deltaX: Double,
        deltaY: Double
    ) -> BrowserActionResult {
        guard let scrollView = webView?.scrollView else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .scroll,
                status: .noWebView,
                message: "No WKWebView is attached.",
                urlBefore: context.urlBefore,
                networkEventCountDelta: networkDelta(since: context)
            )
        }

        let inset = scrollView.adjustedContentInset
        let minimumX = -inset.left
        let minimumY = -inset.top
        let maximumX = max(minimumX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
        let maximumY = max(minimumY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let target = CGPoint(
            x: min(max(scrollView.contentOffset.x + deltaX, minimumX), maximumX),
            y: min(max(scrollView.contentOffset.y + deltaY, minimumY), maximumY)
        )

        scrollView.setContentOffset(target, animated: true)
        return BrowserActionResult(
            requestID: context.requestID,
            kind: .scroll,
            status: .succeeded,
            message: "Scrolled to x=\(Int(target.x)) y=\(Int(target.y)).",
            urlBefore: context.urlBefore,
            urlAfter: webView?.url,
            networkEventCountDelta: networkDelta(since: context)
        )
    }

    private func networkDelta(since context: BrowserActionExecutionContext) -> Int {
        capturedResponseCount - context.responseCountBefore
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
    var scrollX: Double?
    var scrollY: Double?
    var viewportOffsetX: Double?
    var viewportOffsetY: Double?
    var viewportWidth: Double?
    var viewportHeight: Double?
    var elementCount: Int = 0
    var labeledElementCount: Int = 0
    var unlabeledInteractiveElementCount: Int = 0
    var elementsOmitted: Int = 0
    var elements: [BrowserAccessibilityElementSnapshot] = []
    var error: String?
}

struct BrowserActionExecutionContext {
    let requestID: UUID
    let responseCountBefore: Int
    let urlBefore: URL?
}

private extension BrowserActionResult {
    func withAfterSnapshotID(_ afterSnapshotID: UUID) -> BrowserActionResult {
        BrowserActionResult(
            id: id,
            capturedAt: capturedAt,
            requestID: requestID,
            schemaVersion: schemaVersion,
            kind: kind,
            status: status,
            message: message,
            matchedElementCount: matchedElementCount,
            selectedElement: selectedElement,
            candidateSummaries: candidateSummaries,
            beforeSnapshotID: beforeSnapshotID,
            afterSnapshotID: afterSnapshotID,
            urlBefore: urlBefore,
            urlAfter: urlAfter,
            networkEventCountDelta: networkEventCountDelta,
            warnings: warnings,
            label: label,
            role: role,
            path: path
        )
    }
}
