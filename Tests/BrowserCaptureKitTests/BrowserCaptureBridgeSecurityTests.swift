import WebKit
import XCTest

@testable import BrowserCaptureKit

@MainActor
final class BrowserCaptureBridgeSecurityTests: XCTestCase {
    func testBridgeRejectsMissingAndIncorrectTokens() {
        XCTAssertFalse(
            ScriptMessageBridge.hasValidBridgeToken(
                ["kind": "console"],
                expected: "native-secret"
            )
        )
        XCTAssertFalse(
            ScriptMessageBridge.hasValidBridgeToken(
                ["kind": "console", "bridgeToken": "merchant-guess"],
                expected: "native-secret"
            )
        )
        XCTAssertTrue(
            ScriptMessageBridge.hasValidBridgeToken(
                ["kind": "console", "bridgeToken": "native-secret"],
                expected: "native-secret"
            )
        )
    }

    func testCaptureScriptBindsNativeBridgeAndRequiresTrustedStreamMessages() {
        let source = CaptureScript.source(
            configuration: BrowserCaptureConfiguration(capturesConsole: true),
            messageHandlerName: "browserCapture",
            bridgeToken: "native-secret"
        )

        XCTAssertTrue(source.contains("handler.postMessage.bind(handler)"))
        XCTAssertTrue(source.contains("Function.prototype.call.bind(eventTargetAddEventListener)"))
        XCTAssertTrue(source.contains("event.isTrusted !== true"))
        XCTAssertTrue(source.contains("const trackedWebSockets = [];"))
        XCTAssertTrue(source.contains("const trackedWebSocketSet = new WeakSet();"))
        XCTAssertTrue(source.contains("const trackedWebSocketBindings = new WeakMap();"))
        XCTAssertTrue(source.contains("writable: false"))
        XCTAssertTrue(source.contains("configurable: false"))
        XCTAssertTrue(source.contains("nativeWebSocketSend(socket, wirePayload)"))
        XCTAssertTrue(source.contains("response.type !== \"ms.PublishEventResponse\""))
        XCTAssertTrue(source.contains("response.reqId !== requestID"))
        XCTAssertTrue(source.contains("event.isTrusted !== true"))
        XCTAssertTrue(source.contains("finish(\"acknowledged\")"))
        XCTAssertTrue(source.contains("finish(\"rejected:\""))
        XCTAssertTrue(source.contains("finish(\"acknowledgementTimedOut\")"))
        let waiterRange = try? XCTUnwrap(source.range(of: "acknowledgement = new Promise"))
        let sendRange = try? XCTUnwrap(source.range(of: "nativeWebSocketSend(socket, wirePayload)"))
        if let waiterRange, let sendRange {
            XCTAssertLessThan(waiterRange.lowerBound, sendRange.lowerBound)
        }
        XCTAssertFalse(source.contains("window.__bckSockets"))
        XCTAssertFalse(source.contains("window.__bckLastSocket"))
        XCTAssertFalse(source.contains("window.bridgeToken"))
    }

    func testPageCannotForgeInboundVendorEvidenceThroughPublicHandlerOrSyntheticMessageEvent()
        async throws
    {
        guard ProcessInfo.processInfo.environment["BCK_RUN_UNHOSTED_WEBKIT_TESTS"] == "1" else {
            throw XCTSkip("Live WKWebView tests require an app-hosted conformance target.")
        }
        let session = BrowserCaptureSession(
            configuration: BrowserCaptureConfiguration(
                storageMode: .nonPersistent,
                capturesConsole: true
            )
        )
        let webView = session.makeWebView()
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

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

              console.log("(marker)");
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
        guard ProcessInfo.processInfo.environment["BCK_RUN_UNHOSTED_WEBKIT_TESTS"] == "1" else {
            throw XCTSkip("Live WKWebView tests require an app-hosted conformance target.")
        }
        let session = BrowserCaptureSession(
            configuration: BrowserCaptureConfiguration(storageMode: .nonPersistent)
        )
        let webView = session.makeWebView()
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
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
}
