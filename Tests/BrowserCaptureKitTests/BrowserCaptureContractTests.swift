import Foundation
import XCTest

@testable import BrowserCaptureKit

final class BrowserCaptureContractTests: XCTestCase {
    func testCommandRoundTripsAndValidates() throws {
        let command = BrowserActionCommand(
            browserSessionID: "session-1",
            action: .tap(target: .label("Send", role: "button"))
        )

        try command.validate()
        let decoded = try JSONDecoder().decode(
            BrowserActionCommand.self,
            from: JSONEncoder().encode(command)
        )

        XCTAssertEqual(decoded, command)
    }

    func testCommandRejectsUnknownSchemaAndMissingSession() {
        XCTAssertThrowsError(
            try BrowserActionCommand(
                schemaVersion: BrowserCaptureContract.currentSchemaVersion + 1,
                browserSessionID: "session-1",
                action: .observe(reason: "test")
            ).validate()
        )
        XCTAssertThrowsError(
            try BrowserActionCommand(
                browserSessionID: "  ",
                action: .observe(reason: "test")
            ).validate()
        )
    }

    func testEventRoundTripsWithStableKindAndPayloadEnvelope() throws {
        let event = BrowserCaptureEvent.page(
            BrowserPageEvent(
                kind: .navigationFinished,
                url: URL(string: "https://example.com"),
                title: "Example"
            )
        )
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["kind"] as? String, "page")
        XCTAssertNotNil(object["payload"])
        XCTAssertEqual(try JSONDecoder().decode(BrowserCaptureEvent.self, from: data), event)
    }

    func testSafeRedactionRemovesBrowserSecretsAndBodies() throws {
        let snapshot = BrowserStateSnapshot(
            reason: "test",
            url: URL(string: "https://example.com"),
            title: "Example",
            userAgent: "Browser",
            documentCookie: "session=secret",
            localStorage: ["token": "secret"],
            sessionStorage: ["draft": "private"],
            cookies: [
                BrowserCookieSnapshot(
                    name: "session",
                    value: "secret",
                    domain: "example.com",
                    path: "/",
                    expiresDate: nil,
                    isSessionOnly: true,
                    isSecure: true,
                    isHTTPOnly: true
                )
            ]
        ).redacted()

        XCTAssertEqual(snapshot.documentCookie, "[REDACTED]")
        XCTAssertEqual(snapshot.localStorage["token"], "[REDACTED]")
        XCTAssertEqual(snapshot.sessionStorage["draft"], "[REDACTED]")
        XCTAssertEqual(snapshot.cookies.first?.value, "[REDACTED]")

        let response = CapturedResponse(
            source: .fetch,
            method: "POST",
            url: try XCTUnwrap(URL(string: "https://example.com/messages")),
            requestHeaders: ["Authorization": "Bearer secret", "Accept": "application/json"],
            requestMetadata: ["csrf": "secret"],
            requestBodyPreview: "private request",
            responseHeaders: ["Set-Cookie": "session=secret"],
            responseBodyPreview: "private response"
        ).redacted()

        XCTAssertEqual(response.requestHeaders["Authorization"], "[REDACTED]")
        XCTAssertEqual(response.requestHeaders["Accept"], "application/json")
        XCTAssertEqual(response.requestMetadata["csrf"], "[REDACTED]")
        XCTAssertEqual(response.requestBodyPreview, "[REDACTED]")
        XCTAssertEqual(response.responseHeaders["Set-Cookie"], "[REDACTED]")
        XCTAssertEqual(response.responseBodyPreview, "[REDACTED]")
    }

    func testCapabilitiesReflectConfiguration() {
        let capabilities = BrowserCaptureCapabilities(
            configuration: BrowserCaptureConfiguration(
                capturesFetch: true,
                capturesXHR: false,
                capturesWebSocket: true
            )
        )

        XCTAssertEqual(capabilities.schemaVersion, BrowserCaptureContract.currentSchemaVersion)
        XCTAssertTrue(capabilities.supportedActions.contains(.tap))
        XCTAssertEqual(capabilities.captureSources, [.fetch, .websocket, .eventsource, .beacon])
        XCTAssertTrue(capabilities.requiresVisibleBrowser)
        XCTAssertFalse(capabilities.controlsOtherApps)
    }
}
