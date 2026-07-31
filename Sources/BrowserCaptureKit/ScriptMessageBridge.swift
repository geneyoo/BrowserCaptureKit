import Foundation
import WebKit

@MainActor
final class ScriptMessageBridge: NSObject, WKScriptMessageHandler {
    private let expectedBridgeToken: String

    var onEvent: ((BrowserCaptureEvent) -> Void)?
    var onViewportChanged: ((String?) -> Void)?

    /// The most recently seen non-main frame (e.g. a cross-origin chat-widget
    /// iframe). Retained so native code can target `evaluateJavaScript(_:in:_:)`
    /// at the child frame that originated the traffic.
    private(set) var lastChildFrame: WKFrameInfo?

    /// Security origin of the frame that most recently carried WebSocket traffic.
    /// Replay uses this to reject a `lastChildFrame` fallback whose origin does not
    /// match — an unrelated iframe (analytics/ads) must never receive the reply.
    private(set) var lastWebSocketSecurityOrigin: String?

    /// Every non-main frame the capture script has spoken from, keyed by security
    /// origin. The capture script is injected `forMainFrameOnly: false` and posts an
    /// install message at document start, so every scriptable frame registers here
    /// as soon as its document loads — this is how the session enumerates child
    /// frames for cross-frame snapshots, actuation, and quiet waits. Latest
    /// `WKFrameInfo` per origin wins, so a re-navigated widget iframe refreshes its
    /// handle. Two same-origin sibling iframes collapse to one entry (best effort;
    /// the money-target chat widgets are all cross-origin).
    private(set) var childFramesByOrigin: [String: WKFrameInfo] = [:]

    init(expectedBridgeToken: String) {
        self.expectedBridgeToken = expectedBridgeToken
        super.init()
    }

    /// Called on main-frame navigation: the old page's child frames are gone.
    func clearChildFrames() {
        childFramesByOrigin = [:]
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            let body = message.body as? [String: Any],
            Self.hasValidBridgeToken(body, expected: expectedBridgeToken)
        else {
            // The page world can see the WK message-handler name and can call it
            // directly. Unauthenticated posts are merchant-page input, not capture
            // evidence, so reject them silently before updating any frame registry.
            return
        }

        let wkFrame = message.frameInfo
        if !wkFrame.isMainFrame {
            lastChildFrame = wkFrame
            if let origin = Self.originString(from: wkFrame.securityOrigin) {
                childFramesByOrigin[origin] = wkFrame
            }
        }
        let frame = capturedFrame(from: wkFrame)

        let capturedAt = date(from: body["capturedAtEpochMS"])

        switch body["kind"] as? String {
        case "response":
            handleResponse(body: body, frame: frame, capturedAt: capturedAt)
        case "socket":
            handleSocket(body: body, frame: frame, capturedAt: capturedAt)
        case "console":
            handleConsole(body: body, capturedAt: capturedAt)
        case "scriptError":
            handleScriptError(body: body, capturedAt: capturedAt)
        case "viewportChanged":
            onViewportChanged?(string(body["reason"]))
        default:
            onEvent?(.scriptError(BrowserScriptError(capturedAt: capturedAt, message: "Received unknown script message kind.")))
        }
    }

    static func hasValidBridgeToken(_ body: [String: Any], expected: String) -> Bool {
        guard !expected.isEmpty, let presented = body["bridgeToken"] as? String else {
            return false
        }
        return presented == expected
    }

    private func capturedFrame(from frameInfo: WKFrameInfo) -> CapturedFrameInfo {
        CapturedFrameInfo(
            isMainFrame: frameInfo.isMainFrame,
            securityOrigin: Self.originString(from: frameInfo.securityOrigin),
            requestURL: frameInfo.request.url?.absoluteString
        )
    }

    static func originString(from origin: WKSecurityOrigin) -> String? {
        if origin.protocol.isEmpty && origin.host.isEmpty {
            return nil
        }
        if origin.port == 0 {
            return "\(origin.protocol)://\(origin.host)"
        }
        return "\(origin.protocol)://\(origin.host):\(origin.port)"
    }

    private func handleResponse(body: [String: Any], frame: CapturedFrameInfo, capturedAt: Date) {
        guard
            let rawSource = body["source"] as? String,
            let source = CapturedResponse.Source(rawValue: rawSource),
            let rawURL = body["url"] as? String,
            let url = URL(string: rawURL)
        else {
            onEvent?(.scriptError(BrowserScriptError(capturedAt: capturedAt, message: "Received malformed response event.")))
            return
        }

        let response = CapturedResponse(
            capturedAt: capturedAt,
            source: source,
            frame: frame,
            method: string(body["method"]) ?? "GET",
            url: url,
            status: int(body["status"]),
            statusText: string(body["statusText"]),
            contentType: string(body["contentType"]),
            requestHeaders: stringDictionary(body["requestHeaders"]),
            requestMetadata: stringDictionary(body["requestMetadata"]),
            requestBodyPreview: string(body["requestBodyPreview"]),
            responseHeaders: stringDictionary(body["responseHeaders"]),
            responseBodyPreview: string(body["responseBodyPreview"]),
            responseBodyTruncated: bool(body["responseBodyTruncated"]) ?? false,
            durationMilliseconds: double(body["durationMilliseconds"]),
            errorDescription: string(body["errorDescription"])
        )
        onEvent?(.response(response))
    }

    private func handleSocket(body: [String: Any], frame: CapturedFrameInfo, capturedAt: Date) {
        guard
            let rawSource = body["source"] as? String,
            let source = CapturedResponse.Source(rawValue: rawSource),
            let rawURL = body["url"] as? String,
            let url = URL(string: rawURL)
        else {
            onEvent?(.scriptError(BrowserScriptError(capturedAt: capturedAt, message: "Received malformed socket event.")))
            return
        }

        if source == .websocket {
            lastWebSocketSecurityOrigin = frame.securityOrigin
        }

        let direction = string(body["direction"]).flatMap(CapturedResponse.Direction.init(rawValue:))
        // A socket frame is one-directional: outbound payloads go in the request
        // slot, inbound payloads in the response slot, so consumers can reuse the
        // existing request/response rendering.
        let bodyPreview = string(body["bodyPreview"])
        let isInbound = direction == .inbound
        let response = CapturedResponse(
            capturedAt: capturedAt,
            source: source,
            direction: direction,
            frame: frame,
            method: source == .beacon ? "BEACON" : "WS",
            url: url,
            requestMetadata: stringDictionary(body["metadata"]),
            requestBodyPreview: isInbound ? nil : bodyPreview,
            responseBodyPreview: isInbound ? bodyPreview : nil,
            errorDescription: direction == .error ? "socket error" : nil
        )
        onEvent?(.response(response))
    }

    private func handleConsole(body: [String: Any], capturedAt: Date) {
        let event = BrowserConsoleEvent(
            capturedAt: capturedAt,
            level: string(body["level"]) ?? "log",
            message: string(body["message"]) ?? ""
        )
        onEvent?(.console(event))
    }

    private func handleScriptError(body: [String: Any], capturedAt: Date) {
        let error = BrowserScriptError(
            capturedAt: capturedAt,
            message: string(body["message"]) ?? "Unknown capture script error.",
            url: string(body["url"]).flatMap(URL.init(string:))
        )
        onEvent?(.scriptError(error))
    }

    private func date(from value: Any?) -> Date {
        guard let milliseconds = double(value) else {
            return Date()
        }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? String {
            return value
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

    private func stringDictionary(_ value: Any?) -> [String: String] {
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
}
