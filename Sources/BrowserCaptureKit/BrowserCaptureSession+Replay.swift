import Foundation
import WebKit

@MainActor
extension BrowserCaptureSession {
    /// API-replay: re-send a captured WebSocket payload over the widget's own
    /// live socket (`window.__bckLastSocket`, stashed by the capture hook). This
    /// is the reliable send path — the spike proved a synthetic UI click is
    /// `isTrusted`-rejected by bot-wary widgets, so we reconstruct and re-issue
    /// the widget's own protocol frame instead. For a widget whose socket lives
    /// in the main frame (e.g. Delta/LivePerson) pass `frame: nil`; for a
    /// cross-origin child-frame socket pass ``latestChildFrame``.
    ///
    /// Returns `true` only if a live (`readyState === OPEN`) socket accepted the
    /// send. The caller is responsible for reproducing any per-message sequence
    /// ids the vendor protocol expects (LivePerson UMS is id/sequence-bearing).
    @discardableResult
    public func replayWebSocketSend(_ payload: String, inFrame frame: WKFrameInfo? = nil) async throws -> Bool {
        guard let webView else {
            throw BrowserCaptureError.noWebView
        }
        let literal = Self.javaScriptStringLiteral(payload)
        let javaScript = """
            (() => {
              const socket = window.__bckLastSocket;
              if (!socket || socket.readyState !== 1) { return false; }
              try { socket.send(\(literal)); return true; } catch (_) { return false; }
            })()
            """
        let result = try await webView.evaluateJavaScript(javaScript, in: frame, contentWorld: .page)
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
        case sent
        case noSocket
        case error(String)
    }

    /// Vendor WebSocket API-replay (docs/copilot-capture-adapters.md §5). Stamps a fresh
    /// per-socket request id onto the reconstructed frame at inject time — the captured frame
    /// carries no id (verified on the LivePerson/Delta fixture) — and re-issues it over the
    /// widget's own live socket. Tries the main frame first (e.g. LivePerson/Delta), then the
    /// latest cross-origin child frame (e.g. Salesforce/Amelia iframe widgets). Reports
    /// `.unsupported` when no open socket remains, so the planner can fall back.
    func performWebSocketReplay(
        frame: BrowserJSONValue,
        note: String,
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

        var outcome = await replayStampedFrame(payload, inFrame: nil)
        // Child-frame fallback is origin-gated: `latestChildFrame` is merely the most
        // recently seen non-main frame, so without the check a reply could be handed to
        // an unrelated iframe's socket (analytics/ads) and still report `.sent`.
        if outcome == .noSocket,
            let childFrame = latestChildFrame,
            let socketOrigin = latestWebSocketOrigin,
            ScriptMessageBridge.originString(from: childFrame.securityOrigin) == socketOrigin
        {
            outcome = await replayStampedFrame(payload, inFrame: childFrame)
        }

        let detail = note.isEmpty ? "" : " (\(note))"
        switch outcome {
        case .sent:
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .succeeded,
                message: "Sent reply via WebSocket replay\(detail).",
                urlBefore: context.urlBefore,
                urlAfter: webView.url
            )
        case .noSocket:
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .unsupported,
                message: "No open widget socket to replay over.",
                urlBefore: context.urlBefore,
                urlAfter: webView.url
            )
        case .error(let message):
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .wsReplay,
                status: .scriptError,
                message: message,
                urlBefore: context.urlBefore,
                urlAfter: webView.url
            )
        }
    }

    private func replayStampedFrame(_ payload: String, inFrame frame: WKFrameInfo?) async -> WebSocketReplayOutcome {
        guard let webView else {
            return .error("No WKWebView is attached.")
        }
        let literal = Self.javaScriptStringLiteral(payload)
        let javaScript = """
            (() => {
              const socket = window.__bckLastSocket;
              if (!socket || socket.readyState !== 1) { return "noSocket"; }
              try {
                const frame = JSON.parse(\(literal));
                if (frame && typeof frame === "object" && !Array.isArray(frame)) {
                  // Stamp a fresh per-socket request id. Seeded high to avoid colliding with
                  // the widget's own low-numbered request ids on the same socket.
                  window.__bckReqSeq = (window.__bckReqSeq || 90000) + 1;
                  frame.id = String(window.__bckReqSeq);
                }
                socket.send(JSON.stringify(frame));
                return "sent";
              } catch (e) {
                return "error:" + (e && e.message ? e.message : "send failed");
              }
            })()
            """
        do {
            let result = try await webView.evaluateJavaScript(javaScript, in: frame, contentWorld: .page)
            guard let status = result as? String else {
                return .error("Replay script returned no status.")
            }
            switch status {
            case "sent":
                return .sent
            case "noSocket":
                return .noSocket
            default:
                return .error(status.hasPrefix("error:") ? String(status.dropFirst("error:".count)) : status)
            }
        } catch {
            return .error(error.localizedDescription)
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
        guard let webView else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .restReissue,
                status: .noWebView,
                message: "No WKWebView is attached.",
                urlBefore: context.urlBefore
            )
        }

        let functionBody = """
            const httpVerb = (httpMethod || "POST").toUpperCase();
            const requestInit = { method: httpVerb, credentials: "include", headers: { "Content-Type": "application/json" } };
            if (httpVerb !== "GET" && httpVerb !== "HEAD") { requestInit.body = bodyJSON; }
            const response = await fetch(url, requestInit);
            return { ok: response.ok, status: response.status };
            """
        do {
            let result = try await webView.callAsyncJavaScript(
                functionBody,
                arguments: [
                    "url": urlTemplate,
                    "httpMethod": method,
                    "bodyJSON": body.serializedJSONString() ?? "null",
                ],
                contentWorld: .page
            )
            let payload = result as? [String: Any]
            let ok = (payload?["ok"] as? Bool) ?? false
            let statusCode = (payload?["status"] as? Int) ?? (payload?["status"] as? Double).map(Int.init) ?? 0
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .restReissue,
                status: ok ? .succeeded : .scriptError,
                message: ok ? "Sent reply via REST re-issue (HTTP \(statusCode))." : "REST re-issue failed (HTTP \(statusCode)).",
                urlBefore: context.urlBefore,
                urlAfter: webView.url
            )
        } catch {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .restReissue,
                status: .scriptError,
                message: "REST re-issue failed: \(error.localizedDescription)",
                urlBefore: context.urlBefore,
                urlAfter: webView.url
            )
        }
    }
}
