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

}
