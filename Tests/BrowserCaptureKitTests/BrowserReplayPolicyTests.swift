import Foundation
import XCTest

@testable import BrowserCaptureKit

@MainActor
final class BrowserReplayPolicyTests: XCTestCase {
    func testRestReissueAllowsHTTPSOnCurrentOrigin() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://support.example.com/chat"))

        let validated = BrowserCaptureSession.validatedRestReissueURL(
            "https://support.example.com/api/messages",
            pageURL: pageURL
        )

        XCTAssertEqual(validated?.absoluteString, "https://support.example.com/api/messages")
    }

    func testRestReissueRejectsInsecureOrCrossOriginDestinations() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://support.example.com/chat"))
        let denied = [
            "http://support.example.com/api/messages",
            "https://evil.example/api/messages",
            "https://widget.support.example.com/api/messages",
            "https://support.example.com:8443/api/messages",
            "https://attacker@support.example.com/api/messages",
            "/api/messages",
        ]

        for candidate in denied {
            XCTAssertNil(
                BrowserCaptureSession.validatedRestReissueURL(candidate, pageURL: pageURL),
                "Expected to reject \(candidate)"
            )
        }
    }

    func testRestReissueRequiresMatchingExplicitPort() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://support.example.com:8443/chat"))

        XCTAssertNotNil(
            BrowserCaptureSession.validatedRestReissueURL(
                "https://support.example.com:8443/api/messages",
                pageURL: pageURL
            )
        )
        XCTAssertNil(
            BrowserCaptureSession.validatedRestReissueURL(
                "https://support.example.com/api/messages",
                pageURL: pageURL
            )
        )
    }

    func testRestReissueMethodAllowlistAcceptsOnlyPost() {
        XCTAssertEqual(BrowserCaptureSession.validatedRestReissueMethod("POST"), "POST")
        XCTAssertEqual(BrowserCaptureSession.validatedRestReissueMethod(" post \n"), "POST")

        for method in ["", "GET", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE"] {
            XCTAssertNil(
                BrowserCaptureSession.validatedRestReissueMethod(method),
                "Expected to reject \(method)"
            )
        }
    }

    func testRestReissueRejectsRedirectsInPageJavaScript() {
        let source = BrowserCaptureSession.restReissueJavaScript

        XCTAssertTrue(source.contains(#"redirect: "error""#))
        XCTAssertFalse(source.contains(#"redirect: "follow""#))
    }

    func testRestReissueTreatsPostDispatchFailuresAsUncertain() {
        let source = BrowserCaptureSession.restReissueJavaScript

        XCTAssertTrue(source.contains(#"outcome: "response""#))
        XCTAssertTrue(source.contains(#"outcome: "unknown""#))
        XCTAssertTrue(source.contains("AbortController"))
        XCTAssertTrue(source.contains("controller.abort()"))
    }

    func testMerchantServerErrorsAndRetryStatusesAreAmbiguousAfterDispatch() {
        for status in [0, 200, 301, 408, 409, 425, 429, 500, 503] {
            XCTAssertTrue(BrowserCaptureSession.isAmbiguousMerchantAcknowledgement(statusCode: status))
        }
        for status in [400, 401, 403, 404, 422] {
            XCTAssertFalse(BrowserCaptureSession.isAmbiguousMerchantAcknowledgement(statusCode: status))
        }
    }

    func testWebSocketServerErrorAcknowledgementIsNeverDefinitive() {
        let source = CaptureScript.source(
            configuration: BrowserCaptureConfiguration(),
            messageHandlerName: "browserCapture",
            bridgeToken: "native-secret"
        )

        XCTAssertTrue(source.contains("code !== 408 && code !== 409 && code !== 425 && code !== 429"))
        XCTAssertTrue(source.contains("acknowledgementPending:serverResponse:"))
    }

    func testWebSocketNativeReplyLossAfterPageInvocationIsUncertain() {
        XCTAssertEqual(
            BrowserCaptureSession.webSocketPostInvocationFailure("web content process ended"),
            .acknowledgementPending("web content process ended")
        )
    }

    func testFillAndSubmitReplyLossAfterScriptInvocationIsUncertain() {
        let source = BrowserActionScript.fillSource(
            target: .label("Complaint", role: "textbox"),
            text: "Please resolve this complaint.",
            submit: true
        )

        XCTAssertTrue(source.contains("const shouldSubmit = true"))
        XCTAssertEqual(
            BrowserCaptureSession.postInvocationFailureStatus(for: .fill),
            .processInterruptedAfterClaim
        )
        XCTAssertEqual(
            BrowserCaptureSession.postInvocationFailureStatus(for: .waitFor),
            .scriptError
        )
    }

    func testRestReissueAcknowledgementTimeoutIsClamped() {
        XCTAssertEqual(
            BrowserCaptureConfiguration(restReissueAckTimeoutMilliseconds: 1)
                .restReissueAckTimeoutMilliseconds,
            100
        )
        XCTAssertEqual(
            BrowserCaptureConfiguration(restReissueAckTimeoutMilliseconds: 60_000)
                .restReissueAckTimeoutMilliseconds,
            30_000
        )
    }

    func testTapDispatchesExactlyOneClickActivation() {
        let source = BrowserActionScript.actionProgramSource

        XCTAssertEqual(source.components(separatedBy: #"new MouseEvent("click""#).count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "element.click();").count - 1, 1)
        XCTAssertTrue(source.contains(#"if (typeof element.click === "function")"#))
    }

    func testWebSocketReplayRecognizesOnlyExplicitVendorBinding() {
        XCTAssertEqual(
            BrowserCaptureSession.webSocketHostSuffixes(for: "livePerson"),
            BrowserVendor.livePersonOriginSuffixes
        )
        XCTAssertNil(BrowserCaptureSession.webSocketHostSuffixes(for: nil))
        XCTAssertNil(BrowserCaptureSession.webSocketHostSuffixes(for: "generic"))
    }

    func testWebSocketVendorFamilyMatchingUsesDNSLabelBoundaries() {
        let suffixes = BrowserVendor.livePersonOriginSuffixes

        XCTAssertTrue(BrowserCaptureSession.host("liveperson.net", matchesAny: suffixes))
        XCTAssertTrue(BrowserCaptureSession.host("va2.msg.liveperson.net", matchesAny: suffixes))
        XCTAssertTrue(BrowserCaptureSession.host("widget.lpsnmedia.net", matchesAny: suffixes))
        XCTAssertTrue(BrowserCaptureSession.host("api.liveperson.com", matchesAny: suffixes))
        XCTAssertFalse(BrowserCaptureSession.host("api.livepersonk.net", matchesAny: suffixes))
        XCTAssertFalse(BrowserCaptureSession.host("evil-liveperson.net", matchesAny: suffixes))
        XCTAssertFalse(BrowserCaptureSession.host("liveperson.net.attacker.example", matchesAny: suffixes))
    }

    func testLivePersonReplayRequiresApprovedUMSConsumerPathAndSafeAccount() throws {
        let valid = try XCTUnwrap(
            BrowserCaptureSession.validatedWebSocketURLBinding(
                "wss://va2.msg.liveperson.net/ws_api/account/29060121/messaging/consumer"
            )
        )
        XCTAssertTrue(
            BrowserCaptureSession.isApprovedWebSocketBinding(valid, vendorHint: "livePerson")
        )

        for rawURL in [
            "wss://va2.msg.liveperson.net/ws_api/account/29060121/messaging/producer",
            "wss://va2.msg.liveperson.net/ws_api/account//messaging/consumer",
            "wss://va2.msg.liveperson.net/ws_api/account/acct%2Fescape/messaging/consumer",
            "wss://va2.msg.liveperson.net/unrelated/socket",
        ] {
            let binding = try XCTUnwrap(
                BrowserCaptureSession.validatedWebSocketURLBinding(rawURL),
                rawURL
            )
            XCTAssertFalse(
                BrowserCaptureSession.isApprovedWebSocketBinding(binding, vendorHint: "livePerson"),
                rawURL
            )
        }
        XCTAssertFalse(
            BrowserCaptureSession.isApprovedWebSocketBinding(valid, vendorHint: nil)
        )
    }

    func testWebSocketExactBindingIgnoresQueryAndHashButKeepsPathAndPort() {
        XCTAssertEqual(
            BrowserCaptureSession.validatedWebSocketURLBinding(
                "wss://VA2.MSG.LIVEPERSON.NET:8443/ws_api/account/123?token=secret#fragment"
            ),
            BrowserCaptureSession.WebSocketURLBinding(
                host: "va2.msg.liveperson.net",
                port: 8443,
                path: "/ws_api/account/123"
            )
        )
        XCTAssertNil(BrowserCaptureSession.validatedWebSocketURLBinding("ws://va2.msg.liveperson.net/ws"))
        XCTAssertNil(BrowserCaptureSession.validatedWebSocketURLBinding("wss://user@va2.msg.liveperson.net/ws"))
    }

    func testLivePersonReplayRequestIDsMatchCapturedShapeAndAreUnique() throws {
        let ids = (0..<200).map { _ in BrowserCaptureSession.makeLivePersonReplayRequestID() }
        XCTAssertEqual(Set(ids).count, ids.count)

        let pattern = try NSRegularExpression(
            pattern: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{13}-[0-9]{5}$"#
        )
        for id in ids {
            XCTAssertNotNil(
                pattern.firstMatch(
                    in: id,
                    range: NSRange(id.startIndex..., in: id)
                ),
                id
            )
        }
    }
}
