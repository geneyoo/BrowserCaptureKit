import XCTest

@testable import BrowserCaptureKit

final class BrowserJSONValueTests: XCTestCase {
    func testLargeIntegerSurvivesRoundTrip() throws {
        // Epoch-nanosecond-scale id above 2^53 — corrupted if routed through Double.
        let json = #"{"sequenceId":1751500123456789012}"#

        let decoded = try JSONDecoder().decode(BrowserJSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .object(["sequenceId": .integer(1_751_500_123_456_789_012)]))

        let serialized = try XCTUnwrap(decoded.serializedJSONString())
        XCTAssertEqual(serialized, json)
    }

    func testFractionalNumberStillDecodesAsNumber() throws {
        let json = #"{"score":0.75}"#

        let decoded = try JSONDecoder().decode(BrowserJSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .object(["score": .number(0.75)]))
    }
}
