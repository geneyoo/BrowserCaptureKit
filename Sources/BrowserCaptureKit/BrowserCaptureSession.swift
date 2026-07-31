import Foundation
import Security
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
    /// Shared only with BrowserCaptureKit's document-start privileged closures.
    /// It is intentionally not public API and never enters page-owned state.
    let bridgeToken: String
    private let bridge: ScriptMessageBridge
    public private(set) var pageEpoch = 0
    private var capturedResponseCount = 0
    private var navigationContinuations: [UUID: CheckedContinuation<BrowserPageEvent?, Never>] = [:]
    private var navigationTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    /// A browser navigation is an external operation. Thirty seconds is the
    /// documented hard boundary for an `openURL` action so a stalled merchant
    /// page cannot hold the foreground runner forever.
    private static let navigationReadinessTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000

    /// pageEpoch-scoped elementID→frame map (see `BrowserCaptureSession+Frames`):
    /// the namespace prefix on a child-frame element ID resolves to the owning
    /// frame here. Cleared on every epoch bump, exactly like element IDs.
    var childFrameRoutes: [String: BrowserChildFrameRoute] = [:]
    var childFrameNamespaceByOrigin: [String: String] = [:]
    var nextChildFrameOrdinal = 1

    public init(configuration: BrowserCaptureConfiguration = BrowserCaptureConfiguration()) {
        self.configuration = configuration
        let bridgeToken = Self.makeBridgeToken()
        self.bridgeToken = bridgeToken
        bridge = ScriptMessageBridge(expectedBridgeToken: bridgeToken)
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
                source: CaptureScript.source(
                    configuration: configuration,
                    messageHandlerName: messageHandlerName,
                    bridgeToken: bridgeToken
                ),
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

    private static func makeBridgeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        precondition(status == errSecSuccess, "Unable to create BrowserCaptureKit bridge token.")
        return Data(bytes).base64EncodedString()
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

    /// All child frames the bridge has heard from this page, keyed by origin.
    /// Populated at document start (the capture script posts an install message
    /// from every frame), so widget iframes are known before they emit traffic.
    var childFramesByOrigin: [String: WKFrameInfo] {
        bridge.childFramesByOrigin
    }

    func clearChildFrameRegistry() {
        bridge.clearChildFrames()
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

        let state = await mergedAccessibilityState(from: webView)
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

    /// One frame's accessibility capture. `frame == nil` targets the main frame;
    /// a child `WKFrameInfo` evaluates in that frame's `.page` world, where the
    /// script is same-origin with the widget document.
    func accessibilityState(from webView: WKWebView, frame: WKFrameInfo?) async -> BrowserAccessibilityPageState {
        do {
            let result = try await webView.evaluateJavaScript(
                BrowserAccessibilityScript.source,
                in: frame,
                contentWorld: .page
            )
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
                // The new page's child frames are unknown; a stale route must
                // never actuate into the wrong document.
                invalidateChildFrameRoutes()
            }
            if event.kind == .navigationFinished || event.kind == .navigationFailed {
                completeNavigationWaiters(with: event)
            }
        case .response, .nativeNetwork:
            capturedResponseCount += 1
        case .browserState, .accessibility, .console, .scriptError, .action:
            break
        }
        onEvent?(event)
    }

    private func waitForNavigationCompletion(start: () -> Void) async -> BrowserPageEvent? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                navigationContinuations[waiterID] = continuation
                navigationTimeoutTasks[waiterID] = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: Self.navigationReadinessTimeoutNanoseconds)
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.completeNavigationWaiter(id: waiterID, event: nil)
                }
                start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.completeNavigationWaiter(id: waiterID, event: nil)
            }
        }
    }

    private func completeNavigationWaiters(with event: BrowserPageEvent) {
        let waiterIDs = Array(navigationContinuations.keys)
        for waiterID in waiterIDs {
            completeNavigationWaiter(id: waiterID, event: event)
        }
    }

    private func completeNavigationWaiter(id: UUID, event: BrowserPageEvent?) {
        navigationTimeoutTasks.removeValue(forKey: id)?.cancel()
        navigationContinuations.removeValue(forKey: id)?.resume(returning: event)
    }
}

extension BrowserCaptureSession {
    @discardableResult
    public func perform(
        _ action: BrowserActionRequest,
        authorizationGate: (@MainActor () -> Bool)? = nil
    ) async -> BrowserActionResult {
        let context = BrowserActionExecutionContext(
            requestID: UUID(),
            responseCountBefore: capturedResponseCount,
            urlBefore: webView?.url,
            authorizationGate: authorizationGate
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
        guard context.isExecutionAuthorized else {
            return executionAuthorizationFailure(context: context, kind: action.kind)
        }
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
            return await performRoutedScriptedAction(context: context, kind: .tap, target: target) {
                BrowserActionScript.tapSource(target: $0 ?? target)
            }
        case .fill(let target, let text, let submit):
            return await performRoutedScriptedAction(
                context: context,
                kind: .fill,
                target: target,
                redactionWarnings: ["Filled text is redacted from action traces."]
            ) {
                BrowserActionScript.fillSource(target: $0 ?? target, text: text, submit: submit)
            }
        case .clear(let target):
            return await performRoutedScriptedAction(context: context, kind: .clear, target: target) {
                BrowserActionScript.clearSource(target: $0 ?? target)
            }
        case .pressEnter(let target):
            // Targetless pressEnter (no element ID) stays main-frame by contract.
            return await performRoutedScriptedAction(context: context, kind: .pressEnter, target: target) {
                BrowserActionScript.pressEnterSource(target: $0)
            }
        case .scroll(let deltaX, let deltaY):
            return await performScroll(context: context, deltaX: deltaX, deltaY: deltaY)
        case .swipe(let target, let direction):
            return await performSwipe(context: context, target: target, direction: direction)
        case .openURL(let url):
            return await performOpenURL(url, context: context)
        case .back, .forward, .reload:
            return performNavigationControl(action, context: context)
        case .waitFor(let condition):
            return await performWait(context: context, condition: condition)
        case .wsReplay(let frame, let note, let expectedVendorHint, let expectedSocketURL, _):
            return await performWebSocketReplay(
                frame: frame,
                note: note,
                expectedVendorHint: expectedVendorHint,
                expectedSocketURL: expectedSocketURL,
                context: context
            )
        case .restReissue(let method, let urlTemplate, let body, _):
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

    private func performNavigationControl(
        _ action: BrowserActionRequest,
        context: BrowserActionExecutionContext
    ) -> BrowserActionResult {
        switch action {
        case .back:
            goBack()
            return navigationResult(context: context, kind: .back, message: "Requested browser back navigation.")
        case .forward:
            goForward()
            return navigationResult(context: context, kind: .forward, message: "Requested browser forward navigation.")
        case .reload:
            reload()
            return navigationResult(context: context, kind: .reload, message: "Requested browser reload.")
        default:
            preconditionFailure("Expected a browser navigation-control action.")
        }
    }

    private func performOpenURL(
        _ url: URL,
        context: BrowserActionExecutionContext
    ) async -> BrowserActionResult {
        guard let webView else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .openURL,
                status: .noWebView,
                message: "No WKWebView is attached.",
                urlBefore: context.urlBefore,
                networkEventCountDelta: networkDelta(since: context)
            )
        }

        var authorizationExpired = false
        let completion = await waitForNavigationCompletion {
            guard context.isExecutionAuthorized else {
                authorizationExpired = true
                return
            }
            webView.load(URLRequest(url: url))
        }
        if authorizationExpired {
            return executionAuthorizationFailure(context: context, kind: .openURL)
        }
        guard let completion else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .openURL,
                status: .timedOut,
                message: "The merchant page did not finish loading within 30 seconds.",
                urlBefore: context.urlBefore,
                urlAfter: webView.url,
                networkEventCountDelta: networkDelta(since: context)
            )
        }
        guard completion.kind == .navigationFinished else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .openURL,
                status: .scriptError,
                message: completion.message ?? "The merchant page failed to load.",
                urlBefore: context.urlBefore,
                urlAfter: completion.url ?? webView.url,
                networkEventCountDelta: networkDelta(since: context)
            )
        }

        return BrowserActionResult(
            requestID: context.requestID,
            kind: .openURL,
            status: .succeeded,
            message: "Opened \((completion.url ?? url).absoluteString).",
            urlBefore: context.urlBefore,
            urlAfter: completion.url ?? webView.url,
            networkEventCountDelta: networkDelta(since: context)
        )
    }

    /// `frame == nil` evaluates in the main frame; a child frame is targeted via
    /// the routing map (`performRoutedScriptedAction`).
    func performScriptedAction(
        context: BrowserActionExecutionContext,
        kind: BrowserActionKind,
        source: String,
        frame: WKFrameInfo? = nil,
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
            guard context.isExecutionAuthorized else {
                return executionAuthorizationFailure(context: context, kind: kind)
            }
            let result = try await webView.evaluateJavaScript(source, in: frame, contentWorld: .page)
            guard let payload = result as? [String: Any] else {
                return postInvocationScriptFailureResult(
                    context: context,
                    kind: kind,
                    message: "Action script returned a non-object result.",
                    webViewURL: webView.url
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
            return postInvocationScriptFailureResult(
                context: context,
                kind: kind,
                message: error.localizedDescription,
                webViewURL: webView.url
            )
        }
    }

    private func postInvocationScriptFailureResult(
        context: BrowserActionExecutionContext,
        kind: BrowserActionKind,
        message: String,
        webViewURL: URL?
    ) -> BrowserActionResult {
        let merchantStateMayHaveChanged = Self.isMutatingScriptedAction(kind)
        return BrowserActionResult(
            requestID: context.requestID,
            kind: kind,
            status: Self.postInvocationFailureStatus(for: kind),
            message: merchantStateMayHaveChanged
                ? "The page stopped responding after Palette invoked the action, so the merchant outcome is unknown: \(message)"
                : message,
            urlBefore: context.urlBefore,
            urlAfter: webViewURL,
            networkEventCountDelta: networkDelta(since: context),
            warnings: merchantStateMayHaveChanged
                ? ["Do not retry automatically. Resolve this claimed action through recovery."]
                : []
        )
    }

    static func isMutatingScriptedAction(_ kind: BrowserActionKind) -> Bool {
        switch kind {
        case .tap, .fill, .clear, .pressEnter:
            true
        case .observe, .scroll, .swipe, .openURL, .back, .forward, .reload, .waitFor, .wsReplay, .restReissue:
            false
        }
    }

    static func postInvocationFailureStatus(for kind: BrowserActionKind) -> BrowserActionStatus {
        isMutatingScriptedAction(kind) ? .processInterruptedAfterClaim : .scriptError
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
        let statusText = string(payload["status"])
        guard let statusText,
            let status = BrowserActionStatus(rawValue: statusText)
        else {
            return postInvocationScriptFailureResult(
                context: context,
                kind: kind,
                message: "Action script returned an invalid status.",
                webViewURL: webViewURL
            )
        }
        if status == .scriptError, Self.isMutatingScriptedAction(kind) {
            return postInvocationScriptFailureResult(
                context: context,
                kind: kind,
                message: string(payload["message"]) ?? "The action script reported an error after invocation.",
                webViewURL: webViewURL
            )
        }
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

    /// `.urlContains` / `.element` stay instantaneous checks; `.quiet` is a
    /// genuine wait (see ``performQuietWait(context:milliseconds:)``).
    private func performWait(
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
            return await performRoutedScriptedAction(context: context, kind: .waitFor, target: target) {
                BrowserActionScript.waitForElementSource(target: $0 ?? target)
            }
        case .quiet(let milliseconds):
            return await performQuietWait(context: context, milliseconds: milliseconds)
        }
    }

    private func makeScrollResult(
        context: BrowserActionExecutionContext,
        deltaX: Double,
        deltaY: Double
    ) -> BrowserActionResult {
        guard context.isExecutionAuthorized else {
            return executionAuthorizationFailure(context: context, kind: .scroll)
        }
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

    func networkDelta(since context: BrowserActionExecutionContext) -> Int {
        capturedResponseCount - context.responseCountBefore
    }

    func executionAuthorizationFailure(
        context: BrowserActionExecutionContext,
        kind: BrowserActionKind
    ) -> BrowserActionResult {
        BrowserActionResult(
            requestID: context.requestID,
            kind: kind,
            status: .staleSnapshot,
            message: "Execution authorization expired before the merchant action could safely start.",
            urlBefore: context.urlBefore,
            urlAfter: webView?.url,
            networkEventCountDelta: networkDelta(since: context),
            warnings: ["No merchant side effect was started."]
        )
    }

}

struct BrowserAccessibilityPageState {
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
    let authorizationGate: (@MainActor () -> Bool)?

    init(
        requestID: UUID,
        responseCountBefore: Int,
        urlBefore: URL?,
        authorizationGate: (@MainActor () -> Bool)? = nil
    ) {
        self.requestID = requestID
        self.responseCountBefore = responseCountBefore
        self.urlBefore = urlBefore
        self.authorizationGate = authorizationGate
    }

    @MainActor
    var isExecutionAuthorized: Bool {
        authorizationGate?() ?? true
    }
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
