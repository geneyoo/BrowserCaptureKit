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
}
