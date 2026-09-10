import BrowserCaptureKit
import Foundation
import XCTest

@testable import PhoneBrowser

final class RemoteProtocolTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func testUnknownOperationKindDecodesAsUnsupportedSoItCanBeRejectedByID() throws {
        let json = """
            {"type":"command","commandId":"c1","sessionId":"s1","controllerGeneration":1,
             "issuedAt":"2026-09-10T00:00:00Z","deadline":"2026-09-10T00:01:00Z",
             "operation":{"kind":"evaluateJavaScript","source":"alert(1)"}}
            """
        let message = try decoder.decode(RelayInboundMessage.self, from: Data(json.utf8))
        guard case .command(let command) = message else {
            return XCTFail("Expected a command, got \(message)")
        }
        XCTAssertEqual(command.commandID, "c1")
        XCTAssertEqual(command.operation, .unsupported(kind: "evaluateJavaScript", detail: "Unknown operation kind."))
    }

    func testMalformedKnownOperationDecodesAsUnsupportedWithDetail() throws {
        let json = """
            {"type":"command","commandId":"c2","sessionId":"s1","controllerGeneration":1,
             "issuedAt":"2026-09-10T00:00:00Z","deadline":"2026-09-10T00:01:00Z",
             "operation":{"kind":"navigate"}}
            """
        let message = try decoder.decode(RelayInboundMessage.self, from: Data(json.utf8))
        guard case .command(let command) = message, case .unsupported(let kind, let detail) = command.operation else {
            return XCTFail("Expected an unsupported navigate operation")
        }
        XCTAssertEqual(kind, "navigate")
        XCTAssertTrue(detail.contains("url"))
    }

    func testUnknownMessageTypeIsSurfacedNotExecuted() throws {
        let message = try decoder.decode(RelayInboundMessage.self, from: Data(#"{"type":"reboot"}"#.utf8))
        XCTAssertEqual(message, .unknown(type: "reboot"))
    }

    func testObserveAndEventsBoundsAreClamped() throws {
        let observe = try decoder.decode(
            RemoteOperation.self,
            from: Data(#"{"kind":"observe","includeImage":true,"maxElements":99999}"#.utf8)
        )
        XCTAssertEqual(observe, .observe(includeImage: true, maxElements: RemoteOperation.maxElementsCeiling))
        let events = try decoder.decode(RemoteOperation.self, from: Data(#"{"kind":"events","limit":0}"#.utf8))
        XCTAssertEqual(events, .events(afterSequence: 0, limit: 1))
    }

    func testOperationDigestIsIndependentOfKeyOrder() throws {
        let first = try decoder.decode(
            RemoteOperation.self,
            from: Data(#"{"kind":"act","action":{"kind":"fill","observationId":"o","elementId":"3:input","text":"hi"}}"#.utf8)
        )
        let second = try decoder.decode(
            RemoteOperation.self,
            from: Data(#"{"action":{"text":"hi","elementId":"3:input","kind":"fill","observationId":"o"},"kind":"act"}"#.utf8)
        )
        let third = try decoder.decode(
            RemoteOperation.self,
            from: Data(#"{"kind":"act","action":{"kind":"fill","observationId":"o","elementId":"3:input","text":"bye"}}"#.utf8)
        )
        let encoder = JSONEncoder()
        XCTAssertEqual(try CommandCoordinator.digest(of: first, encoder: encoder), try CommandCoordinator.digest(of: second, encoder: encoder))
        XCTAssertNotEqual(try CommandCoordinator.digest(of: first, encoder: encoder), try CommandCoordinator.digest(of: third, encoder: encoder))
    }

    func testOutboundMessagesCarryTypeDiscriminator() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let receipt = RelayOutboundMessage.receipt(.rejected("c9", .humanControl, "paused"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(receipt)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "receipt")
        XCTAssertEqual(object["commandId"] as? String, "c9")
        XCTAssertEqual(object["reason"] as? String, "humanControl")
        XCTAssertEqual(object["accepted"] as? Bool, false)
    }

    func testResultPayloadRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let page = EventPage(events: [], fromSequence: 1, toSequence: 0, latestSequence: 0, droppedThrough: nil, truncated: false)
        let result = CommandResultMessage(
            commandID: "c1",
            state: .completed,
            startedAt: Date(timeIntervalSince1970: 1_000),
            completedAt: Date(timeIntervalSince1970: 1_001),
            retryClassification: .safe,
            reason: nil,
            message: nil,
            payload: .events(page)
        )
        let decoded = try decoder.decode(CommandResultMessage.self, from: try encoder.encode(result))
        XCTAssertEqual(decoded, result)
    }

    func testSanitizerStripsCredentialsQueryAndFragment() {
        XCTAssertEqual(
            ExportSanitizer.url(URL(string: "https://user:pw@shop.example:8443/cart/checkout?token=abc#step2")),
            "https://shop.example:8443/cart/checkout"
        )
        XCTAssertEqual(ExportSanitizer.url(URL(string: "about:blank")), "about:blank")
        XCTAssertEqual(ExportSanitizer.url(URL(string: "data:text/html;base64,QUJD")), "data:")
        XCTAssertNil(ExportSanitizer.url(nil as URL?))
    }

    func testCapabilitiesAdvertiseOnlyImplementedOperations() {
        let capabilities = DeviceCapabilities.current(configuration: BrowserCaptureConfiguration())
        XCTAssertEqual(capabilities.operations, ["observe", "navigate", "act", "events", "commandStatus"])
        XCTAssertEqual(capabilities.actions, ["tap", "fill"])
        XCTAssertFalse(capabilities.operations.contains("wsReplay"))
        XCTAssertTrue(capabilities.requiresForeground)
        XCTAssertFalse(capabilities.controlsOtherApps)
    }
}
