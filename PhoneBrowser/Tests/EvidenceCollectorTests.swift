import BrowserCaptureKit
import Foundation
import XCTest

@testable import PhoneBrowser

@MainActor
final class EvidenceCollectorTests: XCTestCase {
    func testExportsAreSanitizedBoundedAndStampedWithEventTimeEpoch() throws {
        let collector = EvidenceCollector(capacity: 10)
        let response = CapturedResponse(
            source: .fetch,
            frame: CapturedFrameInfo(isMainFrame: true, securityOrigin: "https://shop.example"),
            method: "POST",
            url: try XCTUnwrap(URL(string: "https://shop.example/api/order?session=SECRET")),
            status: 201,
            contentType: "application/json",
            requestHeaders: ["Authorization": "Bearer abc"],
            requestBodyPreview: "{\"card\":\"4111\"}",
            responseBodyPreview: "{\"confirmation\":\"Z9\"}"
        )
        collector.record(.capture(.response(response)), pageEpoch: 3)
        collector.record(.capture(.console(BrowserConsoleEvent(level: "log", message: "token=abc"))), pageEpoch: 3)
        collector.record(.capture(.browserState(BrowserStateSnapshot(
            reason: "test", url: nil, title: nil, userAgent: nil, documentCookie: "a=b",
            localStorage: [:], sessionStorage: [:], cookies: []
        ))), pageEpoch: 3)
        collector.record(.lifecycle("humanControl.begin"), pageEpoch: 4)

        let page = collector.page(after: 0, limit: 10)
        XCTAssertEqual(page.events.count, 3, "browser state is never buffered")
        let network = page.events[0]
        XCTAssertEqual(network.kind, "network")
        XCTAssertEqual(network.url, "https://shop.example/api/order")
        XCTAssertEqual(network.status, 201)
        XCTAssertEqual(network.pageEpoch, 3)
        XCTAssertTrue(network.bodiesOmitted)
        let encoded = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SECRET"))
        XCTAssertFalse(encoded.contains("4111"))
        XCTAssertFalse(encoded.contains("Bearer"))
        XCTAssertFalse(encoded.contains("token=abc"))
        XCTAssertFalse(encoded.contains("a=b"))
        XCTAssertEqual(page.events[2].kind, "lifecycle.humanControl.begin")
        XCTAssertEqual(page.events[2].pageEpoch, 4)
    }

    func testBoundedBufferReportsGapsAndTruncation() {
        let collector = EvidenceCollector(capacity: 3)
        for index in 1...5 {
            collector.record(.lifecycle("e\(index)"), pageEpoch: 1)
        }
        let page = collector.page(after: 0, limit: 2)
        XCTAssertEqual(page.droppedThrough, 2)
        XCTAssertEqual(page.fromSequence, 3)
        XCTAssertEqual(page.toSequence, 4)
        XCTAssertEqual(page.latestSequence, 5)
        XCTAssertTrue(page.truncated)

        let tail = collector.page(after: 4, limit: 10)
        XCTAssertNil(tail.droppedThrough, "No gap inside the requested range")
        XCTAssertEqual(tail.events.map(\.sequence), [5])
        XCTAssertFalse(tail.truncated)
    }
}
