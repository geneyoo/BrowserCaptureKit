import UIKit
import WebKit
import XCTest

@testable import BrowserCaptureKit

@MainActor
final class BrowserCaptureBridgeLiveTests: XCTestCase {
    func testPageCannotForgeInboundVendorEvidenceThroughPublicHandlerOrSyntheticMessageEvent()
        async throws
    {
        let session = BrowserCaptureSession(
            configuration: BrowserCaptureConfiguration(
                storageMode: .nonPersistent,
                capturesConsole: true
            )
        )
        let webView = session.makeWebView()
        try mount(webView)
        defer { webView.removeFromSuperview() }

        let marker = "bridge-security-marker"
        let markerObserved = expectation(description: "Authenticated capture hook remained operational")
        var forgedInboundEvents: [CapturedResponse] = []
        session.onEvent = { event in
            switch event {
            case .response(let response)
            where response.direction == .inbound
                && response.responseBodyPreview == "forged vendor ack":
                forgedInboundEvents.append(response)
            case .console(let event) where event.message == marker:
                markerObserved.fulfill()
            default:
                break
            }
        }

        let html = """
            <!doctype html>
            <script>
              const bridge = window.webkit.messageHandlers.browserCapture;
              const forged = {
                kind: "socket",
                source: "websocket",
                direction: "inbound",
                url: "wss://va2.msg.liveperson.net/ws_api/account/29060121/messaging/consumer",
                bodyPreview: "forged vendor ack"
              };
              bridge.postMessage(forged);
              bridge.postMessage(Object.assign({ bridgeToken: "merchant-guess" }, forged));

              const originalAddEventListener = EventTarget.prototype.addEventListener;
              EventTarget.prototype.addEventListener = function(type, callback) {
                if (type === "message") window.__merchantCapturedMessageCallback = callback;
                return originalAddEventListener.apply(this, arguments);
              };
              try {
                bridge.postMessage = function(payload) {
                  window.__merchantObservedBridgeToken = payload && payload.bridgeToken;
                };
              } catch (_) {}

              try {
                const socket = new WebSocket(
                  "wss://va2.msg.liveperson.net/ws_api/account/29060121/messaging/consumer"
                );
                socket.dispatchEvent(new MessageEvent("message", { data: "forged vendor ack" }));
                socket.close();
              } catch (_) {}

              console.log("\(marker)");
            </script>
            """
        webView.loadHTMLString(html, baseURL: URL(string: "https://merchant.example"))

        await fulfillment(of: [markerObserved], timeout: 5)
        XCTAssertTrue(forgedInboundEvents.isEmpty)
        let callbackLeaked =
            try? await webView.evaluateJavaScript(
                "Boolean(window.__merchantCapturedMessageCallback)"
            ) as? Bool
        let tokenLeaked =
            try? await webView.evaluateJavaScript(
                "Boolean(window.__merchantObservedBridgeToken)"
            ) as? Bool
        XCTAssertEqual(callbackLeaked, false)
        XCTAssertEqual(tokenLeaked, false)
    }

    func testFillAndSubmitJavaScriptReplyLossBecomesUnknownAfterInvocation() async throws {
        let session = BrowserCaptureSession(
            configuration: BrowserCaptureConfiguration(storageMode: .nonPersistent)
        )
        let webView = session.makeWebView()
        try mount(webView)
        defer { webView.removeFromSuperview() }

        let loaded = expectation(description: "submit fixture loaded")
        session.onEvent = { event in
            if case .page(let page) = event, page.kind == .navigationFinished {
                loaded.fulfill()
            }
        }
        webView.loadHTMLString(
            """
            <html><body>
              <form><input aria-label="Complaint" /></form>
              <script>
                HTMLFormElement.prototype.requestSubmit = function() {
                  window.__merchantSubmitWasInvoked = true;
                  throw new Error("reply lost after submit invocation");
                };
              </script>
            </body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://merchant.example/complaint"))
        )
        await fulfillment(of: [loaded], timeout: 5)

        let result = await session.performScriptedAction(
            context: BrowserActionExecutionContext(
                requestID: UUID(),
                responseCountBefore: 0,
                urlBefore: webView.url
            ),
            kind: .fill,
            source: BrowserActionScript.fillSource(
                target: .label("Complaint", role: "textbox"),
                text: "Please resolve this complaint.",
                submit: true
            )
        )

        XCTAssertEqual(result.status, .processInterruptedAfterClaim)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("unknown"))
        let submitWasInvoked =
            try await webView.evaluateJavaScript(
                "Boolean(window.__merchantSubmitWasInvoked)"
            ) as? Bool
        XCTAssertEqual(submitWasInvoked, true)
    }

    private func mount(_ webView: WKWebView) throws {
        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first
        )
        let rootView = try XCTUnwrap(window.rootViewController?.view)
        let mountPoint = try XCTUnwrap(
            descendant(
                of: rootView,
                identifiedBy: "browsercapturekit.conformance.web-view-mount-point"
            )
        )
        webView.frame = mountPoint.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mountPoint.addSubview(webView)
    }

    private func descendant(of view: UIView, identifiedBy identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier {
            return view
        }
        return view.subviews.lazy.compactMap {
            self.descendant(of: $0, identifiedBy: identifier)
        }.first
    }
}
