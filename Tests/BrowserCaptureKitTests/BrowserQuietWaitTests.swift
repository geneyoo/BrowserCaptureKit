import XCTest

@testable import BrowserCaptureKit

/// Quiet-wait coverage for what is testable without a live WKWebView (the
/// package test target has no host app to drive real pages): script
/// generation and promise-payload decoding.
final class BrowserQuietWaitTests: XCTestCase {
    func testFunctionBodyObservesMeaningfulMutationsOnly() {
        let body = BrowserQuietWaitScript.functionBody

        XCTAssertTrue(body.contains("MutationObserver"))
        XCTAssertTrue(body.contains("characterData"))
        XCTAssertTrue(body.contains("childList"))
        XCTAssertTrue(body.contains("subtree"))
        // Pure attribute churn must not count as activity.
        XCTAssertFalse(body.contains("attributes: true"))
        // Added nodes need non-trivial text content.
        XCTAssertTrue(body.contains("textContent"))
        XCTAssertTrue(body.contains("trim()"))
    }

    func testFunctionBodyResolvesOnSettleDebounceAndHardDeadline() {
        let body = BrowserQuietWaitScript.functionBody

        XCTAssertTrue(body.contains("settleMilliseconds"))
        XCTAssertTrue(body.contains("quietMilliseconds"))
        // The observer must be disconnected on every resolution path.
        XCTAssertTrue(body.contains("observer.disconnect()"))
        XCTAssertTrue(body.contains("clearTimeout(settleTimer)"))
        XCTAssertTrue(body.contains("clearTimeout(deadlineTimer)"))
        // A burst still settling at the deadline reports as activity.
        XCTAssertTrue(body.contains(#"activitySeen ? "activity" : "quiet""#))
    }

    func testFunctionBodySupportsNativeCancelBroadcast() {
        let body = BrowserQuietWaitScript.functionBody

        // Multi-frame race: losing frames are stood down via an in-page event so
        // their promises resolve immediately instead of waiting out the deadline.
        XCTAssertTrue(body.contains(#"window.addEventListener("__bckQuietWaitCancel", cancelListener)"#))
        XCTAssertTrue(body.contains(#"window.removeEventListener("__bckQuietWaitCancel", cancelListener)"#))
        XCTAssertTrue(body.contains(#"finish("cancelled")"#))
        XCTAssertTrue(
            BrowserQuietWaitScript.cancelBroadcastSource.contains(
                #"window.dispatchEvent(new Event("__bckQuietWaitCancel"))"#
            )
        )
    }

    func testActivityMessageAttributesChildFrameByOriginOnly() {
        // Main-frame activity keeps the historical wording…
        XCTAssertEqual(
            BrowserQuietWaitScript.activityMessage(frameOrigin: nil, elapsedMilliseconds: 812),
            "New activity detected after 812ms."
        )
        XCTAssertEqual(
            BrowserQuietWaitScript.activityMessage(frameOrigin: nil, elapsedMilliseconds: nil),
            "New activity detected."
        )
        // …child-frame activity names the frame by origin only (no element detail).
        XCTAssertEqual(
            BrowserQuietWaitScript.activityMessage(
                frameOrigin: "https://widget.lpsnmedia.net",
                elapsedMilliseconds: 812
            ),
            "New activity detected in frame https://widget.lpsnmedia.net after 812ms."
        )
    }

    func testQuietMessageKeepsHistoricalWording() {
        XCTAssertEqual(
            BrowserQuietWaitScript.quietMessage(milliseconds: 30000),
            "No new activity within 30000ms."
        )
    }

    func testArgumentsCarryQuietWindowAndSettleDebounce() {
        let arguments = BrowserQuietWaitScript.arguments(quietMilliseconds: 30000)

        XCTAssertEqual(arguments["quietMilliseconds"] as? Int, 30000)
        XCTAssertEqual(
            arguments["settleMilliseconds"] as? Int,
            BrowserQuietWaitScript.settleMilliseconds
        )
    }

    func testOutcomeDecodesActivityPayload() {
        let outcome = BrowserQuietWaitOutcome(
            scriptResult: ["outcome": "activity", "elapsedMs": 812]
        )

        XCTAssertEqual(outcome?.kind, .activity)
        XCTAssertEqual(outcome?.elapsedMilliseconds, 812)
    }

    func testOutcomeDecodesQuietPayloadWithDoubleElapsed() {
        // JavaScriptCore bridges numbers as Double in some paths.
        let outcome = BrowserQuietWaitOutcome(
            scriptResult: ["outcome": "quiet", "elapsedMs": 30000.0]
        )

        XCTAssertEqual(outcome?.kind, .quiet)
        XCTAssertEqual(outcome?.elapsedMilliseconds, 30000)
    }

    func testOutcomeDecodesCancelledPayload() {
        let outcome = BrowserQuietWaitOutcome(
            scriptResult: ["outcome": "cancelled", "elapsedMs": 5]
        )

        XCTAssertEqual(outcome?.kind, .cancelled)
        XCTAssertEqual(outcome?.elapsedMilliseconds, 5)
    }

    func testOutcomeToleratesMissingElapsed() {
        let outcome = BrowserQuietWaitOutcome(scriptResult: ["outcome": "quiet"])

        XCTAssertEqual(outcome?.kind, .quiet)
        XCTAssertNil(outcome?.elapsedMilliseconds)
    }

    func testOutcomeRejectsUnknownPayloads() {
        XCTAssertNil(BrowserQuietWaitOutcome(scriptResult: nil))
        XCTAssertNil(BrowserQuietWaitOutcome(scriptResult: "activity"))
        XCTAssertNil(BrowserQuietWaitOutcome(scriptResult: ["outcome": "later"]))
        XCTAssertNil(BrowserQuietWaitOutcome(scriptResult: ["elapsedMs": 12]))
    }
}
