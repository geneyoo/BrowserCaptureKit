import Foundation
import WebKit

/// Element-ID namespacing for cross-frame snapshots. Child-frame stableIDs get a
/// per-frame prefix (`"f1:"`, `"f2:"`, …) so element IDs stay unique across the
/// merged list, and the prefix itself routes an action back to its owning frame.
/// Frame-local stableIDs always start with a numeric ordinal (`"<index>:<fp>"`,
/// `stableID` contract v1), so an `f<digits>:` prefix can never collide with an
/// un-namespaced main-frame ID.
enum BrowserFrameNamespace {
    static func apply(_ namespaceID: String, to stableID: String) -> String {
        "\(namespaceID):\(stableID)"
    }

    /// Splits `"f1:12:button|…"` into `("f1", "12:button|…")`. Returns `nil` for
    /// main-frame (un-namespaced) element IDs.
    static func parse(_ elementID: String) -> (namespaceID: String, localID: String)? {
        guard elementID.hasPrefix("f"), let colon = elementID.firstIndex(of: ":") else {
            return nil
        }
        let digits = elementID[elementID.index(after: elementID.startIndex)..<colon]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            return nil
        }
        return (String(elementID[..<colon]), String(elementID[elementID.index(after: colon)...]))
    }

    /// Resolves a target's owning namespace and rewrites its element IDs to the
    /// frame-local form the in-frame matcher computes. Returns `nil` for
    /// main-frame targets.
    ///
    /// The namespace may arrive in ANY identifier field: the server round-trip
    /// (`iosActionFromCanonicalAction`) maps the planner's `elementId` into
    /// `snapshotElementID` and its `stableId` into `selectorFingerprint`, and
    /// never populates `stableID` — so detection inspects all three, and ALL of
    /// them are stripped so the in-frame matcher's exact-match (+500 stableID,
    /// +350 fingerprint) scores against frame-local values. Every namespaced
    /// field present must agree on the same frame; a conflict falls back to
    /// main-frame rather than guessing.
    static func localized(_ target: BrowserElementTarget) -> (namespaceID: String, localTarget: BrowserElementTarget)? {
        let stableParse = target.stableID.flatMap(parse)
        let snapshotParse = target.snapshotElementID.flatMap(parse)
        let fingerprintParse = target.selectorFingerprint.flatMap(parse)
        let namespaces = Set([stableParse, snapshotParse, fingerprintParse].compactMap { $0?.namespaceID })
        guard namespaces.count == 1, let namespaceID = namespaces.first else {
            return nil
        }
        let localTarget = BrowserElementTarget(
            snapshotID: target.snapshotID,
            pageEpoch: target.pageEpoch,
            stableID: stableParse.map(\.localID) ?? target.stableID,
            snapshotElementID: snapshotParse.map(\.localID) ?? target.snapshotElementID,
            path: target.path,
            selectorFingerprint: fingerprintParse.map(\.localID) ?? target.selectorFingerprint,
            role: target.role,
            label: target.label,
            text: target.text,
            bounds: target.bounds
        )
        return (namespaceID, localTarget)
    }
}

/// One entry of the pageEpoch-scoped elementID→frame map: the namespace prefix
/// carried by every child-frame element ID resolves to the `WKFrameInfo` that
/// owns those elements.
struct BrowserChildFrameRoute {
    let namespaceID: String
    let origin: String
    let frame: WKFrameInfo
}

/// Where a scripted action should execute, resolved from the target's element ID.
enum BrowserFrameRouting {
    /// Main frame; also the default for label-only and targetless actions.
    case main
    /// A known child frame, with the target rewritten to frame-local IDs.
    case child(WKFrameInfo, BrowserElementTarget)
    /// The element ID names a frame that is no longer present (navigated away or
    /// invalidated by an epoch bump).
    case vanished(origin: String?)
}

/// Main-frame helper that reports each `<iframe>`'s viewport bounds keyed by the
/// child document's origin (derived from `src`). Best effort: `origins` lists
/// every iframe origin seen; `bounds` only keeps origins with exactly ONE iframe,
/// since two same-origin iframes make the offset ambiguous.
enum BrowserFrameGeometryScript {
    static let source = """
        (() => {
          const frames = [];
          document.querySelectorAll("iframe").forEach((element) => {
            let origin = null;
            try {
              const src = element.getAttribute("src");
              if (src) { origin = new URL(src, window.location.href).origin; }
            } catch (_) {}
            if (!origin || origin === "null") { return; }
            const rect = element.getBoundingClientRect();
            frames.push({ origin, x: rect.left, y: rect.top, width: rect.width, height: rect.height });
          });
          return frames;
        })();
        """
}

/// One child frame's decoded accessibility capture, ready to merge.
struct BrowserChildFrameAccessibilityCapture {
    let origin: String
    let namespaceID: String
    let state: BrowserAccessibilityPageState
    /// Owning `<iframe>`'s bounds in the parent viewport, when uniquely
    /// determined; `nil` keeps the child's frame-local coordinates.
    let boundsOffset: BrowserElementBounds?
}

/// Pure merge of per-frame accessibility captures into the single element list
/// the planner sees: frames are invisible except for `frameOrigin` on each
/// child element. Kept side-effect free so it is unit-testable without WebKit.
enum BrowserFrameSnapshotMerger {
    static func merged(
        main: BrowserAccessibilityPageState,
        children: [BrowserChildFrameAccessibilityCapture],
        unresponsiveOrigins: [String]
    ) -> BrowserAccessibilityPageState {
        var state = main
        for child in children {
            state.elements += child.state.elements.map {
                $0.inChildFrame(
                    namespaceID: child.namespaceID,
                    frameOrigin: child.origin,
                    boundsOffset: child.boundsOffset
                )
            }
            state.elementCount += child.state.elementCount
            state.labeledElementCount += child.state.labeledElementCount
            state.unlabeledInteractiveElementCount += child.state.unlabeledInteractiveElementCount
            state.elementsOmitted += child.state.elementsOmitted
        }
        if !unresponsiveOrigins.isEmpty {
            let note = "Child frame(s) did not respond: \(unresponsiveOrigins.sorted().joined(separator: ", "))."
            state.error = [state.error, note].compactMap { $0 }.joined(separator: " ")
        }
        return state
    }
}

@MainActor
extension BrowserCaptureSession {
    /// Child frames the session currently knows about (every frame that loaded
    /// the capture script this page), sorted by origin for deterministic
    /// namespace assignment.
    var knownChildFrames: [(origin: String, frame: WKFrameInfo)] {
        childFramesByOrigin
            .sorted { $0.key < $1.key }
            .map { (origin: $0.key, frame: $0.value) }
    }

    /// Clears the epoch-scoped elementID→frame map. A main-frame navigation
    /// invalidates child frames exactly like it invalidates element IDs.
    func invalidateChildFrameRoutes() {
        childFrameRoutes = [:]
        childFrameNamespaceByOrigin = [:]
        nextChildFrameOrdinal = 1
        clearChildFrameRegistry()
    }

    /// Namespace bookkeeping, separated from `WKFrameInfo` handling so it is
    /// unit-testable: assignment is monotonic within a pageEpoch and stable per
    /// origin, so an ID handed to the planner never silently re-points at
    /// another frame.
    func namespaceID(forChildFrameOrigin origin: String) -> String {
        if let existing = childFrameNamespaceByOrigin[origin] {
            return existing
        }
        let namespaceID = "f\(nextChildFrameOrdinal)"
        nextChildFrameOrdinal += 1
        childFrameNamespaceByOrigin[origin] = namespaceID
        return namespaceID
    }

    /// Registers (or refreshes) the route for a child frame and returns its
    /// namespace prefix.
    func registerChildFrameRoute(origin: String, frame: WKFrameInfo) -> String {
        let namespaceID = namespaceID(forChildFrameOrigin: origin)
        childFrameRoutes[namespaceID] = BrowserChildFrameRoute(namespaceID: namespaceID, origin: origin, frame: frame)
        return namespaceID
    }

    func removeChildFrameRoute(origin: String) {
        guard let namespaceID = childFrameNamespaceByOrigin[origin] else {
            return
        }
        childFrameRoutes[namespaceID] = nil
    }

    /// Resolves the frame that owns an action's target element. Targets without
    /// a namespaced element ID (label-only, targetless pressEnter, legacy) stay
    /// on the main frame — the pinned contract's "targetless stays main-frame".
    func frameRouting(for target: BrowserElementTarget?) -> BrowserFrameRouting {
        guard let target, let localized = BrowserFrameNamespace.localized(target) else {
            return .main
        }
        guard let route = childFrameRoutes[localized.namespaceID] else {
            return .vanished(origin: nil)
        }
        return .child(route.frame, localized.localTarget)
    }

    /// Routes a scripted action to the target element's owning frame via the
    /// epoch-scoped map. A vanished frame reports `.staleSnapshot` — the same
    /// signal a navigation-invalidated element ID produces today, so the planner
    /// recaptures instead of dead-ending.
    func performRoutedScriptedAction(
        context: BrowserActionExecutionContext,
        kind: BrowserActionKind,
        target: BrowserElementTarget?,
        redactionWarnings: [String] = [],
        makeSource: (BrowserElementTarget?) -> String
    ) async -> BrowserActionResult {
        switch frameRouting(for: target) {
        case .main:
            return await performScriptedAction(
                context: context,
                kind: kind,
                source: makeSource(target),
                redactionWarnings: redactionWarnings
            )
        case .child(let frame, let localTarget):
            return await performScriptedAction(
                context: context,
                kind: kind,
                source: makeSource(localTarget),
                frame: frame,
                redactionWarnings: redactionWarnings
            )
        case .vanished:
            return BrowserActionResult(
                requestID: context.requestID,
                kind: kind,
                status: .staleSnapshot,
                message: "Rejected: the target element's frame is no longer present (page or widget changed since capture).",
                urlBefore: context.urlBefore,
                urlAfter: webView?.url,
                networkEventCountDelta: networkDelta(since: context)
            )
        }
    }

    /// Runs the accessibility capture in the main frame AND every known child
    /// frame, merging into one element list. A frame that fails to respond
    /// (navigated away, sandboxed) is dropped from the capture and its route is
    /// removed so later actions get `.staleSnapshot` instead of a wrong-frame
    /// evaluation; the drop is noted in the snapshot's error string.
    func mergedAccessibilityState(from webView: WKWebView) async -> BrowserAccessibilityPageState {
        let main = await accessibilityState(from: webView, frame: nil)
        let childFrames = knownChildFrames
        guard !childFrames.isEmpty else {
            return main
        }

        let iframeBounds = await iframeBoundsByOrigin(from: webView)
        var children: [BrowserChildFrameAccessibilityCapture] = []
        var unresponsiveOrigins: [String] = []
        for (origin, frame) in childFrames {
            let state = await accessibilityState(from: webView, frame: frame)
            guard state.error == nil else {
                removeChildFrameRoute(origin: origin)
                unresponsiveOrigins.append(origin)
                continue
            }
            let namespaceID = registerChildFrameRoute(origin: origin, frame: frame)
            children.append(
                BrowserChildFrameAccessibilityCapture(
                    origin: origin,
                    namespaceID: namespaceID,
                    state: state,
                    boundsOffset: iframeBounds[origin]
                )
            )
        }
        return BrowserFrameSnapshotMerger.merged(
            main: main,
            children: children,
            unresponsiveOrigins: unresponsiveOrigins
        )
    }

    /// Best-effort iframe geometry from the parent document: an origin maps to
    /// bounds only when exactly one iframe hosts it. Limitations (documented):
    /// nested (grandchild) frames and multi-iframe origins keep frame-local
    /// coordinates, and `getBoundingClientRect` uses the layout viewport while
    /// element bounds use the visual viewport, so offsets can drift by the
    /// pinch-zoom inset.
    private func iframeBoundsByOrigin(from webView: WKWebView) async -> [String: BrowserElementBounds] {
        guard
            let result = try? await webView.evaluateJavaScript(
                BrowserFrameGeometryScript.source,
                in: nil,
                contentWorld: .page
            ),
            let payloads = result as? [[String: Any]]
        else {
            return [:]
        }

        var boundsByOrigin: [String: BrowserElementBounds] = [:]
        var ambiguousOrigins: Set<String> = []
        for payload in payloads {
            guard let origin = string(payload["origin"]) else {
                continue
            }
            guard boundsByOrigin[origin] == nil, !ambiguousOrigins.contains(origin) else {
                ambiguousOrigins.insert(origin)
                boundsByOrigin[origin] = nil
                continue
            }
            boundsByOrigin[origin] = BrowserElementBounds(
                x: double(payload["x"]) ?? 0,
                y: double(payload["y"]) ?? 0,
                width: double(payload["width"]) ?? 0,
                height: double(payload["height"]) ?? 0
            )
        }
        return boundsByOrigin
    }
}
