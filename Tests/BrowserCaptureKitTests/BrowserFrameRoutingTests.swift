import WebKit
import XCTest

@testable import BrowserCaptureKit

/// Cross-frame snapshot/actuation coverage for what is testable without a live
/// WKWebView (the package test target has no host app to drive real pages):
/// element-ID namespacing, the pure snapshot merge, the geometry script, and
/// the session's epoch-scoped elementID→frame routing.
final class BrowserFrameRoutingTests: XCTestCase {
    // MARK: - Namespacing

    func testNamespaceApplyPrefixesStableID() {
        XCTAssertEqual(
            BrowserFrameNamespace.apply("f1", to: "12:button|button|send||body > button|44x44"),
            "f1:12:button|button|send||body > button|44x44"
        )
    }

    func testNamespaceParseSplitsPrefixAndLocalID() {
        let parsed = BrowserFrameNamespace.parse("f2:-1:div|||body > div|10x10")

        XCTAssertEqual(parsed?.namespaceID, "f2")
        XCTAssertEqual(parsed?.localID, "-1:div|||body > div|10x10")
    }

    func testNamespaceParseRejectsMainFrameStableIDs() {
        // Frame-local stableIDs always start with a numeric ordinal, so they can
        // never be mistaken for a namespaced ID.
        XCTAssertNil(BrowserFrameNamespace.parse("12:button|button|send||body > button|44x44"))
        XCTAssertNil(BrowserFrameNamespace.parse("-1:div|||body > div|10x10"))
        XCTAssertNil(BrowserFrameNamespace.parse("frame:anything"))
        XCTAssertNil(BrowserFrameNamespace.parse("f:missing-digits"))
        XCTAssertNil(BrowserFrameNamespace.parse("f1x:not-a-prefix"))
        XCTAssertNil(BrowserFrameNamespace.parse(""))
    }

    // MARK: - Snapshot merge

    func testMergedSnapshotNamespacesChildElementsAndStampsFrameOrigin() {
        let merged = BrowserFrameSnapshotMerger.merged(
            main: pageState(elements: [element(stableID: "0:main-button", x: 10, y: 20)]),
            children: [
                BrowserChildFrameAccessibilityCapture(
                    origin: "https://widget.lpsnmedia.net",
                    namespaceID: "f1",
                    state: pageState(elements: [element(stableID: "3:widget-send", x: 4, y: 8)]),
                    boundsOffset: nil
                )
            ],
            unresponsiveOrigins: []
        )

        XCTAssertEqual(merged.elements.count, 2)
        // Main-frame executable IDs stay bare…
        XCTAssertEqual(merged.elements[0].stableID, "0:main-button")
        XCTAssertNil(merged.elements[0].frameOrigin)
        // …child-frame ones are namespaced (the executable elementId the server
        // round-trips is stableID ?? id, so this IS the elementId namespacing).
        XCTAssertEqual(merged.elements[1].stableID, "f1:3:widget-send")
        XCTAssertEqual(merged.elements[1].frameOrigin, "https://widget.lpsnmedia.net")
        XCTAssertNil(merged.error)
    }

    func testMergedSnapshotSynthesizesNamespacedIDWhenStableIDMissing() {
        var child = element(stableID: "unused", x: 0, y: 0)
        child = BrowserAccessibilityElementSnapshot(
            id: child.id,
            stableID: nil,
            index: child.index,
            tagName: child.tagName,
            role: child.role,
            label: child.label,
            labelSource: child.labelSource,
            text: child.text,
            value: child.value,
            placeholder: child.placeholder,
            href: child.href,
            source: child.source,
            inputType: child.inputType,
            isVisible: child.isVisible,
            isInteractive: child.isInteractive,
            isDisabled: child.isDisabled,
            isEditable: child.isEditable,
            ariaHidden: child.ariaHidden,
            bounds: child.bounds,
            path: child.path,
            selectorFingerprint: child.selectorFingerprint,
            supportedActions: child.supportedActions
        )

        let merged = BrowserFrameSnapshotMerger.merged(
            main: pageState(elements: []),
            children: [
                BrowserChildFrameAccessibilityCapture(
                    origin: "https://widget.lpsnmedia.net",
                    namespaceID: "f1",
                    state: pageState(elements: [child]),
                    boundsOffset: nil
                )
            ],
            unresponsiveOrigins: []
        )

        // Without a stableID the executable elementId would fall back to the
        // bare UUID — unroutable and potentially duplicated across frames — so
        // the merge synthesizes a namespaced one from it.
        XCTAssertEqual(merged.elements[0].stableID, "f1:\(child.id.uuidString)")
    }

    func testMergedSnapshotOffsetsChildBoundsByOwningIframe() {
        let merged = BrowserFrameSnapshotMerger.merged(
            main: pageState(elements: []),
            children: [
                BrowserChildFrameAccessibilityCapture(
                    origin: "https://widget.lpsnmedia.net",
                    namespaceID: "f1",
                    state: pageState(elements: [element(stableID: "0:send", x: 4, y: 8)]),
                    boundsOffset: BrowserElementBounds(x: 100, y: 400, width: 320, height: 240)
                ),
                BrowserChildFrameAccessibilityCapture(
                    origin: "https://other.example.com",
                    namespaceID: "f2",
                    state: pageState(elements: [element(stableID: "0:other", x: 4, y: 8)]),
                    boundsOffset: nil
                ),
            ],
            unresponsiveOrigins: []
        )

        // Offset applied when the owning iframe's bounds are known…
        XCTAssertEqual(merged.elements[0].bounds.x, 104)
        XCTAssertEqual(merged.elements[0].bounds.y, 408)
        XCTAssertEqual(merged.elements[0].bounds.width, 44)
        // …and frame-local coordinates kept (documented limitation) otherwise.
        XCTAssertEqual(merged.elements[1].bounds.x, 4)
        XCTAssertEqual(merged.elements[1].bounds.y, 8)
    }

    func testMergedSnapshotSumsCountsAcrossFrames() {
        var main = pageState(elements: [element(stableID: "0:a", x: 0, y: 0)])
        main.elementCount = 10
        main.labeledElementCount = 4
        main.unlabeledInteractiveElementCount = 2
        main.elementsOmitted = 1
        var child = pageState(elements: [element(stableID: "0:b", x: 0, y: 0)])
        child.elementCount = 7
        child.labeledElementCount = 3
        child.unlabeledInteractiveElementCount = 1
        child.elementsOmitted = 5

        let merged = BrowserFrameSnapshotMerger.merged(
            main: main,
            children: [
                BrowserChildFrameAccessibilityCapture(
                    origin: "https://widget.lpsnmedia.net",
                    namespaceID: "f1",
                    state: child,
                    boundsOffset: nil
                )
            ],
            unresponsiveOrigins: []
        )

        XCTAssertEqual(merged.elementCount, 17)
        XCTAssertEqual(merged.labeledElementCount, 7)
        XCTAssertEqual(merged.unlabeledInteractiveElementCount, 3)
        XCTAssertEqual(merged.elementsOmitted, 6)
    }

    func testMergedSnapshotNotesUnresponsiveFramesWithoutFailing() {
        let merged = BrowserFrameSnapshotMerger.merged(
            main: pageState(elements: [element(stableID: "0:a", x: 0, y: 0)]),
            children: [],
            unresponsiveOrigins: ["https://dead.example.com", "https://also-dead.example.com"]
        )

        // The capture survives — elements intact, drop recorded as a note.
        XCTAssertEqual(merged.elements.count, 1)
        XCTAssertEqual(
            merged.error,
            "Child frame(s) did not respond: https://also-dead.example.com, https://dead.example.com."
        )
    }

    func testMergedSnapshotAppendsUnresponsiveNoteToExistingError() {
        var main = pageState(elements: [])
        main.error = "Main frame hiccup."

        let merged = BrowserFrameSnapshotMerger.merged(
            main: main,
            children: [],
            unresponsiveOrigins: ["https://dead.example.com"]
        )

        XCTAssertEqual(merged.error, "Main frame hiccup. Child frame(s) did not respond: https://dead.example.com.")
    }

    // MARK: - Geometry script

    func testFrameGeometryScriptReportsIframeBoundsByOrigin() {
        let source = BrowserFrameGeometryScript.source

        XCTAssertTrue(source.contains(#"querySelectorAll("iframe")"#))
        XCTAssertTrue(source.contains("getBoundingClientRect"))
        // Origin derives from src relative to the parent document.
        XCTAssertTrue(source.contains("new URL(src, window.location.href).origin"))
        // Sandboxed/srcdoc frames report the literal "null" origin — skipped.
        XCTAssertTrue(source.contains(#"origin === "null""#))
    }

    // MARK: - Session routing (epoch-scoped elementID→frame map)
    //
    // NOTE: `WKFrameInfo` cannot be instantiated standalone (WebKit API objects
    // crash outside a live web view), so the `.child` dictionary lookup itself
    // is exercised on-device only. Everything around it — namespace bookkeeping,
    // target localization, invalidation — is covered here.

    @MainActor
    func testNamespaceBookkeepingIsMonotonicAndStablePerOrigin() {
        let session = BrowserCaptureSession()

        XCTAssertEqual(session.namespaceID(forChildFrameOrigin: "https://a.example.com"), "f1")
        XCTAssertEqual(session.namespaceID(forChildFrameOrigin: "https://b.example.com"), "f2")
        // A re-seen origin keeps its namespace, so IDs already handed to the
        // planner never re-point at another frame within the same pageEpoch.
        XCTAssertEqual(session.namespaceID(forChildFrameOrigin: "https://a.example.com"), "f1")
    }

    func testLocalizedTargetRewritesNamespacedElementIDs() {
        let localized = BrowserFrameNamespace.localized(
            BrowserElementTarget(stableID: "f1:12:button|send", label: "Send")
        )

        XCTAssertEqual(localized?.namespaceID, "f1")
        // The in-frame matcher's exact-match key is the un-namespaced stableID.
        XCTAssertEqual(localized?.localTarget.stableID, "12:button|send")
        XCTAssertEqual(localized?.localTarget.label, "Send")
    }

    func testLocalizedTargetHandlesServerRoundTripShape() {
        // The REAL wire shape: `iosActionFromCanonicalAction` maps the planner's
        // elementId -> snapshotElementID and stableId -> selectorFingerprint,
        // and never sets stableID.
        let localized = BrowserFrameNamespace.localized(
            BrowserElementTarget(
                snapshotElementID: "f1:e5",
                selectorFingerprint: "f1:12:button|send"
            )
        )

        XCTAssertEqual(localized?.namespaceID, "f1")
        XCTAssertNil(localized?.localTarget.stableID)
        // BOTH scored identifier fields are stripped to their frame-local forms
        // (an un-stripped fingerprint would forfeit the +350 fingerprint match).
        XCTAssertEqual(localized?.localTarget.snapshotElementID, "e5")
        XCTAssertEqual(localized?.localTarget.selectorFingerprint, "12:button|send")
    }

    func testLocalizedTargetRoutesOnSnapshotElementIDAlone() {
        // The model may send only elementId.
        let localized = BrowserFrameNamespace.localized(
            BrowserElementTarget(snapshotElementID: "f1:e5")
        )

        XCTAssertEqual(localized?.namespaceID, "f1")
        XCTAssertEqual(localized?.localTarget.snapshotElementID, "e5")
    }

    func testLocalizedTargetReturnsNilForMainFrameTargets() {
        XCTAssertNil(BrowserFrameNamespace.localized(BrowserElementTarget(stableID: "12:button|send")))
        XCTAssertNil(BrowserFrameNamespace.localized(BrowserElementTarget(snapshotElementID: "e5")))
        XCTAssertNil(BrowserFrameNamespace.localized(.label("Send")))
        // A genuine frame-local fingerprint never parses as a namespace (its
        // first colon, if any, is inside the path component after a "|").
        XCTAssertNil(
            BrowserFrameNamespace.localized(
                BrowserElementTarget(selectorFingerprint: "f1|button|send||body > f1:nth-of-type(2)|44x44")
            )
        )
    }

    func testLocalizedTargetRejectsDisagreeingNamespaces() {
        // Conflicting frames means the target is corrupt: fall back to the main
        // frame rather than guessing which frame to actuate into.
        XCTAssertNil(
            BrowserFrameNamespace.localized(
                BrowserElementTarget(snapshotElementID: "f1:e5", selectorFingerprint: "f2:12:button|send")
            )
        )
    }

    @MainActor
    func testFrameRoutingDefaultsToMainFrame() {
        let session = BrowserCaptureSession()

        // Targetless actions (e.g. typeText/pressEnter with no element ID) and
        // label-only or main-frame targets all stay on the main frame.
        guard case .main = session.frameRouting(for: nil) else {
            return XCTFail("Targetless action must stay main-frame")
        }
        guard case .main = session.frameRouting(for: .label("Send")) else {
            return XCTFail("Label-only target must stay main-frame")
        }
        guard case .main = session.frameRouting(for: BrowserElementTarget(stableID: "12:button|send")) else {
            return XCTFail("Un-namespaced stableID must stay main-frame")
        }
    }

    @MainActor
    func testFrameRoutingReportsVanishedFrame() {
        let session = BrowserCaptureSession()

        let routing = session.frameRouting(for: BrowserElementTarget(stableID: "f9:12:button|send"))

        guard case .vanished = routing else {
            return XCTFail("Unknown namespace must report a vanished frame, got \(routing)")
        }
    }

    @MainActor
    func testFrameRoutingDetectsNamespaceFromServerShapedTarget() {
        let session = BrowserCaptureSession()

        // Server-shaped target (no stableID) must drive frame routing: with the
        // namespace detected but no live route it reports vanished, not main.
        let serverShaped = BrowserElementTarget(
            snapshotElementID: "f1:e5",
            selectorFingerprint: "f1:12:button|send"
        )
        guard case .vanished = session.frameRouting(for: serverShaped) else {
            return XCTFail("Server-shaped namespaced target must route by frame")
        }
        // A bare elementId stays main-frame.
        guard case .main = session.frameRouting(for: BrowserElementTarget(snapshotElementID: "e5")) else {
            return XCTFail("Bare snapshotElementID must stay main-frame")
        }
    }

    @MainActor
    func testNavigationEpochBumpInvalidatesFrameRoutes() {
        let session = BrowserCaptureSession()
        XCTAssertEqual(session.namespaceID(forChildFrameOrigin: "https://widget.lpsnmedia.net"), "f1")
        let epochBefore = session.pageEpoch

        session.emit(
            .page(BrowserPageEvent(kind: .navigationStarted, url: nil, title: nil, message: nil))
        )

        XCTAssertEqual(session.pageEpoch, epochBefore + 1)
        XCTAssertTrue(session.childFrameRoutes.isEmpty)
        XCTAssertTrue(session.childFrameNamespaceByOrigin.isEmpty)
        guard case .vanished = session.frameRouting(for: BrowserElementTarget(stableID: "f1:12:button|send")) else {
            return XCTFail("Routes must be invalidated by the epoch bump")
        }
        // The next page's frames start numbering fresh.
        XCTAssertEqual(session.namespaceID(forChildFrameOrigin: "https://new.example.com"), "f1")
    }

    // MARK: - Fixtures

    private func pageState(elements: [BrowserAccessibilityElementSnapshot]) -> BrowserAccessibilityPageState {
        var state = BrowserAccessibilityPageState()
        state.elements = elements
        state.elementCount = elements.count
        return state
    }

    private func element(stableID: String, x: Double, y: Double) -> BrowserAccessibilityElementSnapshot {
        BrowserAccessibilityElementSnapshot(
            stableID: stableID,
            index: 0,
            tagName: "button",
            role: "button",
            label: "Send",
            labelSource: "text",
            text: "Send",
            value: nil,
            placeholder: nil,
            href: nil,
            source: nil,
            inputType: nil,
            isVisible: true,
            isInteractive: true,
            isDisabled: false,
            isEditable: false,
            ariaHidden: false,
            bounds: BrowserElementBounds(x: x, y: y, width: 44, height: 44),
            path: "body > button",
            selectorFingerprint: "button|button|send||body > button|44x44",
            supportedActions: [.tap]
        )
    }
}
