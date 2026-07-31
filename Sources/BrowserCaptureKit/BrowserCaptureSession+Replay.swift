import Foundation
import WebKit

@MainActor
extension BrowserCaptureSession {
    /// API-replay: re-send a captured WebSocket payload over the widget's own
    /// live socket retained by the capture hook's private lexical registry. This
    /// is the reliable send path — the spike proved a synthetic UI click is
    /// `isTrusted`-rejected by bot-wary widgets, so we reconstruct and re-issue
    /// the widget's own protocol frame instead. For a widget whose socket lives
    /// in the main frame (e.g. Delta/LivePerson) pass `frame: nil`; for a
    /// cross-origin child-frame socket pass ``latestChildFrame``.
    ///
    /// Returns `true` only if a live (`readyState === OPEN`) socket accepted the
    /// send. This unbound primitive exists for the controlled capture spike;
    /// production copilot actions use `performWebSocketReplay`, which requires
    /// an exact approved vendor socket binding and stamps a fresh request id.
    @discardableResult
    public func replayWebSocketSend(_ payload: String, inFrame frame: WKFrameInfo? = nil) async throws -> Bool {
        guard let webView else {
            throw BrowserCaptureError.noWebView
        }
        let functionNameLiteral = Self.javaScriptStringLiteral(CaptureScript.privilegedWebSocketReplayFunctionName)
        let javaScript = """
            const replay = window[\(functionNameLiteral)];
            if (typeof replay !== "function") { return false; }
            return await replay(bridgeToken, payload, "", "", 0, "", false, false) === "sent";
            """
        let result = try await webView.callAsyncJavaScript(
            javaScript,
            arguments: ["bridgeToken": bridgeToken, "payload": payload],
            in: frame,
            contentWorld: .page
        )
        return (result as? Bool) ?? false
    }

    static func javaScriptStringLiteral(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let text = String(data: data, encoding: .utf8),
            text.hasPrefix("["),
            text.hasSuffix("]")
        else {
            return "\"\""
        }
        return String(text.dropFirst().dropLast())
    }

    // MARK: - Transport-aware send (capture-adapters §5)

    enum WebSocketReplayOutcome: Equatable {
        case acknowledged
        case acknowledgementPending(String)
        case rejected(String)
        case noSocket
        case noTrustedSocket
        case authorizationExpired
        case error(String)
    }

    struct WebSocketURLBinding: Equatable {
        let host: String
        let port: Int
        let path: String
    }

    /// Vendor WebSocket API-replay (docs/copilot-capture-adapters.md §5). Stamps a fresh
    /// per-socket request id onto the reconstructed frame at inject time — the server deliberately
    /// omits the captured id from its replay template — and re-issues it over the widget's own
    /// live socket. Tries the main frame first (e.g. LivePerson/Delta), then the
    /// latest cross-origin child frame (e.g. Salesforce/Amelia iframe widgets). Reports
    /// `.unsupported` when no open socket remains, so the planner can fall back.
    func performWebSocketReplay(
        frame: BrowserJSONValue,
        note: String,
        expectedVendorHint: String?,
        expectedSocketURL: String?,
        context: BrowserActionExecutionContext
    ) async -> BrowserActionResult {
        guard let webView else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .noWebView,
                message: "No WKWebView is attached.",
                urlBefore: context.urlBefore
            )
        }
        guard let allowedHostSuffixes = Self.webSocketHostSuffixes(for: expectedVendorHint) else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .unsupported,
                message: "WebSocket replay requires a recognized vendor destination binding.",
                urlBefore: context.urlBefore,
                urlAfter: webView.url,
                warnings: ["Unbound socket replay is blocked on device."]
            )
        }
        guard let expectedSocketURL,
            let expectedSocketBinding = Self.validatedWebSocketURLBinding(expectedSocketURL),
            Self.host(expectedSocketBinding.host, matchesAny: allowedHostSuffixes),
            Self.isApprovedWebSocketBinding(
                expectedSocketBinding,
                vendorHint: expectedVendorHint
            )
        else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .unsupported,
                message: "WebSocket replay requires an exact approved vendor socket binding.",
                urlBefore: context.urlBefore,
                urlAfter: webView.url,
                warnings: ["Legacy or invalid socket bindings require a fresh capture before sending."]
            )
        }
        guard let payload = frame.serializedJSONString() else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .scriptError,
                message: "Replay frame was not serializable.",
                urlBefore: context.urlBefore,
                urlAfter: webView.url
            )
        }

        var outcome = await replayStampedFrame(
            payload,
            expectedSocketBinding: expectedSocketBinding,
            inFrame: nil,
            context: context
        )
        // Child-frame fallback is origin-gated: `latestChildFrame` is merely the most
        // recently seen non-main frame, so without the check a reply could be handed to
        // an unrelated iframe's socket (analytics/ads) and still report `.sent`.
        if outcome == .noSocket || outcome == .noTrustedSocket,
            let childFrame = latestChildFrame,
            let socketOrigin = latestWebSocketOrigin,
            ScriptMessageBridge.originString(from: childFrame.securityOrigin) == socketOrigin
        {
            outcome = await replayStampedFrame(
                payload,
                expectedSocketBinding: expectedSocketBinding,
                inFrame: childFrame,
                context: context
            )
        }

        return webSocketReplayResult(
            for: outcome,
            note: note,
            context: context,
            urlAfter: webView.url
        )
    }

    private func webSocketReplayResult(
        for outcome: WebSocketReplayOutcome,
        note: String,
        context: BrowserActionExecutionContext,
        urlAfter: URL?
    ) -> BrowserActionResult {
        let detail = note.isEmpty ? "" : " (\(note))"
        switch outcome {
        case .acknowledged:
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .succeeded,
                message: "The merchant acknowledged the reply payload\(detail).",
                urlBefore: context.urlBefore,
                urlAfter: urlAfter,
                warnings: []
            )
        case .acknowledgementPending(let reason):
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .acknowledgementTimedOut,
                message: "The reply was sent, but Palette could not confirm whether the merchant accepted it (\(reason)).",
                urlBefore: context.urlBefore,
                urlAfter: urlAfter,
                warnings: [
                    "Ambiguous transport acknowledgement; never retry automatically.",
                    "Resolve through the confirm-before-retry recovery checkpoint.",
                ]
            )
        case .rejected(let code):
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .scriptError,
                message: "The merchant rejected the reply (code \(code)).",
                urlBefore: context.urlBefore,
                urlAfter: urlAfter
            )
        case .noSocket:
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .unsupported,
                message: "No open widget socket to replay over.",
                urlBefore: context.urlBefore,
                urlAfter: urlAfter
            )
        case .noTrustedSocket:
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .unsupported,
                message: "No open socket matched the approved vendor destination.",
                urlBefore: context.urlBefore,
                urlAfter: urlAfter,
                warnings: ["An unrelated page socket was not used."]
            )
        case .error(let message):
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .scriptError,
                message: message,
                urlBefore: context.urlBefore,
                urlAfter: urlAfter
            )
        case .authorizationExpired:
            return executionAuthorizationFailure(context: context, kind: .wsReplay)
        }
    }

    private func replayStampedFrame(
        _ payload: String,
        expectedSocketBinding: WebSocketURLBinding,
        inFrame frame: WKFrameInfo?,
        context: BrowserActionExecutionContext
    ) async -> WebSocketReplayOutcome {
        guard let webView else {
            return .error("No WKWebView is attached.")
        }
        let functionNameLiteral = Self.javaScriptStringLiteral(CaptureScript.privilegedWebSocketReplayFunctionName)
        let requestID = Self.makeLivePersonReplayRequestID()
        let javaScript = """
            const replay = window[\(functionNameLiteral)];
            if (typeof replay !== "function") { return "unauthorized"; }
            return await replay(
              bridgeToken,
              payload,
              requestID,
              expectedHost,
              expectedPort,
              expectedPath,
              true,
              true
            );
            """
        do {
            guard context.isExecutionAuthorized else {
                return .authorizationExpired
            }
            let result = try await webView.callAsyncJavaScript(
                javaScript,
                arguments: [
                    "bridgeToken": bridgeToken,
                    "payload": payload,
                    "requestID": requestID,
                    "expectedHost": expectedSocketBinding.host,
                    "expectedPort": expectedSocketBinding.port,
                    "expectedPath": expectedSocketBinding.path,
                ],
                in: frame,
                contentWorld: .page
            )
            guard let status = result as? String else {
                return Self.webSocketPostInvocationFailure("the page returned no replay status")
            }
            switch status {
            case "acknowledged":
                return .acknowledged
            case "noSocket":
                return .noSocket
            case "noTrustedSocket":
                return .noTrustedSocket
            case "unauthorized":
                return .error("The authenticated browser replay bridge was unavailable.")
            default:
                if status.hasPrefix("acknowledgementPending:") {
                    return .acknowledgementPending(
                        String(status.dropFirst("acknowledgementPending:".count))
                    )
                }
                if status == "acknowledgementTimedOut" {
                    return .acknowledgementPending("acknowledgement timed out")
                }
                if status.hasPrefix("rejected:") {
                    return .rejected(String(status.dropFirst("rejected:".count)))
                }
                return .error(status.hasPrefix("error:") ? String(status.dropFirst("error:".count)) : status)
            }
        } catch {
            // Native has already invoked the page async function. The socket
            // send can succeed before navigation/process loss prevents WebKit
            // from returning the correlated acknowledgement.
            return Self.webSocketPostInvocationFailure(
                "the page stopped before acknowledgement: \(error.localizedDescription)"
            )
        }
    }

    static func webSocketPostInvocationFailure(_ message: String) -> WebSocketReplayOutcome {
        .acknowledgementPending(message)
    }

    static func webSocketHostSuffixes(for expectedVendorHint: String?) -> [String]? {
        switch expectedVendorHint?.lowercased() {
        case "liveperson":
            return BrowserVendor.livePersonOriginSuffixes
        default:
            return nil
        }
    }

    static func makeLivePersonReplayRequestID() -> String {
        let sessionUnique = UUID().uuidString.lowercased()
        let shapeDigit = Int.random(in: 0...9)
        let numericSuffix = Int.random(in: 10_000...99_999)
        return "\(sessionUnique)\(shapeDigit)-\(numericSuffix)"
    }

    static func isApprovedWebSocketBinding(
        _ binding: WebSocketURLBinding,
        vendorHint: String?
    ) -> Bool {
        guard vendorHint?.lowercased() == "liveperson" else {
            return false
        }
        let components = binding.path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 6,
            components[0].isEmpty,
            components[1] == "ws_api",
            components[2] == "account",
            components[4] == "messaging",
            components[5] == "consumer"
        else {
            return false
        }
        let account = components[3]
        guard !account.isEmpty, account.utf8.count <= 128 else {
            return false
        }
        return account.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
        }
    }

    static func validatedWebSocketURLBinding(_ rawURL: String) -> WebSocketURLBinding? {
        guard let components = URLComponents(string: rawURL),
            components.scheme?.lowercased() == "wss",
            components.user == nil,
            components.password == nil,
            let host = components.host?.lowercased(),
            !host.isEmpty
        else {
            return nil
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return WebSocketURLBinding(host: host, port: components.port ?? 443, path: path)
    }

    static func host(_ host: String, matchesAny suffixes: [String]) -> Bool {
        let host = host.lowercased()
        return suffixes.contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
    }

    /// In-house REST re-issue (docs/copilot-capture-adapters.md §5). Re-POSTs the page's own
    /// send endpoint from inside the authenticated WebView, so the platform's cookies ride
    /// along (`credentials: "include"`) and no auth is ever forwarded to the server. The body
    /// carries redacted message text only.
    func performRestReissue(
        method: String,
        urlTemplate: String,
        body: BrowserJSONValue,
        context: BrowserActionExecutionContext
    ) async -> BrowserActionResult {
        guard let httpMethod = Self.validatedRestReissueMethod(method) else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .restReissue,
                status: .unsupported,
                message: "REST re-issue only permits POST requests.",
                urlBefore: context.urlBefore,
                urlAfter: webView?.url
            )
        }
        guard let webView else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .restReissue,
                status: .noWebView,
                message: "No WKWebView is attached.",
                urlBefore: context.urlBefore
            )
        }
        guard let requestURL = Self.validatedRestReissueURL(urlTemplate, pageURL: webView.url) else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .restReissue,
                status: .unsupported,
                message: "REST re-issue requires an HTTPS endpoint on the current page origin.",
                urlBefore: context.urlBefore,
                urlAfter: webView.url,
                warnings: ["Cross-origin credentialed requests are blocked on device."]
            )
        }

        do {
            guard context.isExecutionAuthorized else {
                return executionAuthorizationFailure(context: context, kind: .restReissue)
            }
            let result = try await webView.callAsyncJavaScript(
                Self.restReissueJavaScript,
                arguments: [
                    "url": requestURL.absoluteString,
                    "httpMethod": httpMethod,
                    "bodyJSON": body.serializedJSONString() ?? "null",
                    "timeoutMilliseconds": configuration.restReissueAckTimeoutMilliseconds,
                ],
                contentWorld: .page
            )
            let payload = result as? [String: Any]
            guard payload?["outcome"] as? String == "response" else {
                let detail = payload?["detail"] as? String ?? "No definitive HTTP response was received."
                return BrowserActionResult(
                    requestID: context.requestID,
                    kind: .restReissue,
                    status: .acknowledgementTimedOut,
                    message: "The REST send may have reached the merchant, but its acknowledgement is uncertain: \(detail)",
                    urlBefore: context.urlBefore,
                    urlAfter: webView.url,
                    warnings: ["Do not retry automatically. Resolve this attempt through recovery."]
                )
            }
            let ok = (payload?["ok"] as? Bool) ?? false
            let statusCode = (payload?["status"] as? Int) ?? (payload?["status"] as? Double).map(Int.init) ?? 0
            if !ok, Self.isAmbiguousMerchantAcknowledgement(statusCode: statusCode) {
                return BrowserActionResult(
                    requestID: context.requestID,
                    kind: .restReissue,
                    status: .acknowledgementTimedOut,
                    message: "The merchant returned HTTP \(statusCode) after the send, so Palette cannot prove whether the action took effect.",
                    urlBefore: context.urlBefore,
                    urlAfter: webView.url,
                    warnings: ["Do not retry automatically. Resolve this attempt through recovery."]
                )
            }
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .restReissue,
                status: ok ? .succeeded : .scriptError,
                message: ok
                    ? "Sent reply via REST re-issue (HTTP \(statusCode))."
                    : "The merchant endpoint rejected the REST send (HTTP \(statusCode)).",
                urlBefore: context.urlBefore,
                urlAfter: webView.url
            )
        } catch {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .restReissue,
                status: .acknowledgementTimedOut,
                message: "The REST send may have reached the merchant, but the page stopped before acknowledgement: \(error.localizedDescription)",
                urlBefore: context.urlBefore,
                urlAfter: webView.url,
                warnings: ["Do not retry automatically. Resolve this attempt through recovery."]
            )
        }
    }

    /// Defense in depth for credentialed in-page fetch. Server policy remains
    /// authoritative, but a malformed/stale proposal cannot send the retained
    /// WebView's cookies to another scheme, host, or port.
    static func validatedRestReissueURL(_ rawURL: String, pageURL: URL?) -> URL? {
        guard let candidate = URL(string: rawURL),
            let pageURL,
            candidate.scheme?.lowercased() == "https",
            pageURL.scheme?.lowercased() == "https",
            candidate.user == nil,
            candidate.password == nil,
            let candidateHost = candidate.host?.lowercased(),
            let pageHost = pageURL.host?.lowercased(),
            candidateHost == pageHost,
            (candidate.port ?? 443) == (pageURL.port ?? 443)
        else {
            return nil
        }
        return candidate
    }

    /// Transport replay is deliberately narrower than the generic HTTP tool.
    /// Capture adapters currently produce send-message POSTs only; accepting
    /// caller-controlled verbs here would turn a stale proposal into an
    /// authenticated mutation primitive inside the retained browser session.
    static func validatedRestReissueMethod(_ rawMethod: String) -> String? {
        let method = rawMethod.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return method == "POST" ? method : nil
    }

    /// Only a clear client-side rejection is definitive after dispatch. Server
    /// errors and retry-oriented statuses can arrive after a merchant mutation
    /// committed, so treating them as safe-to-replan could duplicate it.
    static func isAmbiguousMerchantAcknowledgement(statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 409
            || statusCode == 425
            || statusCode == 429
            || statusCode >= 500
            || !(400..<500).contains(statusCode)
    }

    /// Redirects are rejected instead of followed so same-origin validation
    /// cannot be bypassed by an endpoint that redirects the credentialed POST
    /// to a different origin.
    static var restReissueJavaScript: String {
        """
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), timeoutMilliseconds);
        const requestInit = {
          method: httpMethod,
          credentials: "include",
          redirect: "error",
          headers: { "Content-Type": "application/json" },
          body: bodyJSON,
          signal: controller.signal
        };
        try {
          const response = await fetch(url, requestInit);
          return { outcome: "response", ok: response.ok, status: response.status };
        } catch (error) {
          return {
            outcome: "unknown",
            detail: String(error && error.message ? error.message : error)
          };
        } finally {
          clearTimeout(timeout);
        }
        """
    }
}
