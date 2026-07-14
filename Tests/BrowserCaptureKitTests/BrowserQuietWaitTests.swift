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
