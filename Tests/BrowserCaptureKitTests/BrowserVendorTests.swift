import XCTest

@testable import BrowserCaptureKit

final class BrowserVendorTests: XCTestCase {
    func testLivePersonOriginVariants() {
        XCTAssertEqual(BrowserVendor(origin: "https://x.liveperson.net"), .livePerson)
        XCTAssertEqual(BrowserVendor(origin: "https://lptag.liveperson.net:443"), .livePerson)
        XCTAssertEqual(BrowserVendor(origin: "https://cdn.lpsnmedia.net/foo"), .livePerson)
        XCTAssertEqual(BrowserVendor(origin: "liveperson.com"), .livePerson)
    }

    func testWebSocketSchemeAndDeltaMainFrameCase() {
        // Real Delta opens the LivePerson socket from its own main frame, so the
        // vendor must be recoverable from the wss:// destination host itself.
        XCTAssertEqual(BrowserVendor(origin: "wss://va2.msg.liveperson.net/ws_api/account/29060121/messaging/consumer"), .livePerson)
    }

    func testOtherKnownVendors() {
        XCTAssertEqual(BrowserVendor(origin: "https://widget.zopim.com"), .zendesk)
        XCTAssertEqual(BrowserVendor(origin: "https://foo.zendesk.com"), .zendesk)
        XCTAssertEqual(BrowserVendor(origin: "https://acme.my.connect.aws"), .amazonConnect)
        XCTAssertEqual(BrowserVendor(origin: "https://js.intercomcdn.com"), .intercom)
        XCTAssertEqual(BrowserVendor(origin: "https://d.la1.salesforceliveagent.com"), .salesforce)
        XCTAssertEqual(BrowserVendor(origin: "https://apps.mypurecloud.com"), .genesys)
    }

    func testLabelBoundarySuffixDoesNotOvermatch() {
        // Must not match a lookalike registrable domain.
        XCTAssertNil(BrowserVendor(origin: "https://notliveperson.net"))
        XCTAssertNil(BrowserVendor(origin: "https://liveperson.net.evil.com"))
    }

    func testUnknownAndMalformedOrigins() {
        XCTAssertNil(BrowserVendor(origin: nil))
        XCTAssertNil(BrowserVendor(origin: ""))
        XCTAssertNil(BrowserVendor(origin: "https://delta.com"))
        XCTAssertNil(BrowserVendor(origin: "not a url"))
    }

    func testHostExtraction() {
        XCTAssertEqual(BrowserVendor.host(from: "https://x.liveperson.net:443/path?q=1"), "x.liveperson.net")
        XCTAssertEqual(BrowserVendor.host(from: "X.LivePerson.NET"), "x.liveperson.net")
        XCTAssertNil(BrowserVendor.host(from: nil))
    }

    func testCapturedFrameInfoAutoDerivesVendorHint() {
        let widget = CapturedFrameInfo(isMainFrame: false, securityOrigin: "https://x.liveperson.net")
        XCTAssertEqual(widget.vendorHint, .livePerson)

        // Falls back to the request URL host when origin is opaque/nil.
        let viaRequest = CapturedFrameInfo(isMainFrame: false, securityOrigin: nil, requestURL: "https://foo.zendesk.com/widget")
        XCTAssertEqual(viaRequest.vendorHint, .zendesk)

        let mainPage = CapturedFrameInfo(isMainFrame: true, securityOrigin: "https://www.delta.com")
        XCTAssertNil(mainPage.vendorHint)
    }
}
