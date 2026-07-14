import Foundation
import WebKit

/// Quiet-wait script for `waitFor(.quiet(milliseconds:))` (loop-pump contract):
/// the page-side promise resolves on EITHER meaningful DOM activity (added
/// nodes with non-trivial text content or characterData changes — pure
/// attribute churn is ignored), confirmed by a short settle debounce, OR the
/// server-specified quiet deadline. Both outcomes are `.succeeded`; only the
/// result message distinguishes them, so the post-action recapture and
/// action-result upload pump the next turn either way.
///
/// The wait runs in the main frame AND every known child frame (cross-origin
/// widget iframes), raced natively — a MutationObserver cannot see across a
/// frame boundary, so each frame hosts its own observer. A native broadcast of
/// the `__bckQuietWaitCancel` event tears the losing frames' observers down as
/// soon as one frame resolves.
enum BrowserQuietWaitScript {
    /// JS-side debounce confirming a mutation burst has settled before the
    /// promise reports activity. Not a poll — it re-arms only on new mutations.
    static let settleMilliseconds = 400

    /// Window event that resolves the promise as `cancelled` (dispatched by the
    /// session when another frame already resolved the race).
    static let cancelEventName = "__bckQuietWaitCancel"

    /// Function body for `callAsyncJavaScript`; expects `quietMilliseconds`
    /// and `settleMilliseconds` arguments and returns
    /// `{ outcome: "activity" | "quiet" | "cancelled", elapsedMs }`.
    static let functionBody = """
        const startedAt = Date.now();
        return await new Promise((resolve) => {
          let finished = false;
          let activitySeen = false;
          let settleTimer = null;
          let deadlineTimer = null;
          let observer = null;
          const finish = (outcome) => {
            if (finished) { return; }
            finished = true;
            if (observer) { observer.disconnect(); }
            if (settleTimer) { clearTimeout(settleTimer); }
            if (deadlineTimer) { clearTimeout(deadlineTimer); }
            window.removeEventListener("\(cancelEventName)", cancelListener);
            resolve({ outcome: outcome, elapsedMs: Date.now() - startedAt });
          };
          const cancelListener = () => finish("cancelled");
          window.addEventListener("\(cancelEventName)", cancelListener);
          const hasMeaningfulChange = (mutations) => {
            for (const mutation of mutations) {
              if (mutation.type === "characterData") { return true; }
              if (mutation.type !== "childList") { continue; }
              for (const node of mutation.addedNodes) {
                const text = (node.textContent || "").trim();
                if (text.length > 0) { return true; }
              }
            }
            return false;
          };
          observer = new MutationObserver((mutations) => {
            if (finished || !hasMeaningfulChange(mutations)) { return; }
            activitySeen = true;
            if (settleTimer) { clearTimeout(settleTimer); }
            settleTimer = setTimeout(() => finish("activity"), settleMilliseconds);
          });
          observer.observe(document.documentElement, {
            childList: true,
            subtree: true,
            characterData: true,
          });
          // Hard deadline — the server-specified quiet window IS the business
          // rule; a still-settling burst at the deadline reports as activity.
          deadlineTimer = setTimeout(() => finish(activitySeen ? "activity" : "quiet"), quietMilliseconds);
        });
        """

    /// Dispatched into every non-winning frame on first resolution so their
    /// promises resolve immediately instead of waiting out the deadline.
    static let cancelBroadcastSource = """
        window.dispatchEvent(new Event("\(cancelEventName)"));
        """

    static func arguments(quietMilliseconds: Int) -> [String: Any] {
        [
            "quietMilliseconds": quietMilliseconds,
            "settleMilliseconds": settleMilliseconds,
        ]
    }

    /// Result message for an activity resolution. Frame attribution is origin
    /// only — no element detail — and main-frame activity keeps the historical
    /// wording.
    static func activityMessage(frameOrigin: String?, elapsedMilliseconds: Int?) -> String {
        let elapsed = elapsedMilliseconds.map { " after \($0)ms" } ?? ""
        guard let frameOrigin else {
            return "New activity detected\(elapsed)."
        }
        return "New activity detected in frame \(frameOrigin)\(elapsed)."
    }

    static func quietMessage(milliseconds: Int) -> String {
        "No new activity within \(milliseconds)ms."
    }
}

/// Decoded resolution of the quiet-wait promise.
struct BrowserQuietWaitOutcome: Equatable {
    enum Kind: String {
        case activity
        case quiet
        /// Internal only: the session cancelled this frame's wait because
        /// another frame already resolved the race. Never surfaces in results.
        case cancelled
    }

    let kind: Kind
    let elapsedMilliseconds: Int?

    init(kind: Kind, elapsedMilliseconds: Int?) {
        self.kind = kind
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    init?(scriptResult: Any?) {
        guard
            let payload = scriptResult as? [String: Any],
            let rawOutcome = payload["outcome"] as? String,
            let kind = Kind(rawValue: rawOutcome)
        else {
            return nil
        }

        self.kind = kind
        elapsedMilliseconds =
            (payload["elapsedMs"] as? Int)
            ?? (payload["elapsedMs"] as? Double).map(Int.init)
    }
}

/// One frame's resolution inside the quiet-wait race.
private enum BrowserQuietWaitFrameResolution {
    case resolved(frameOrigin: String?, BrowserQuietWaitOutcome)
    case failed(frameOrigin: String?, message: String)
}

@MainActor
extension BrowserCaptureSession {
    /// Genuine `.quiet` wait (loop-pump contract): completes `.succeeded` BOTH
    /// when new activity is observed AND when the quiet deadline elapses; the
    /// message distinguishes ("New activity detected [in frame <origin>] …" vs
    /// "No new activity within <N>ms"). The wait observes the main frame and
    /// every known child frame, so conversation churn inside a cross-origin
    /// widget iframe counts as activity. Per-frame waits are raced against the
    /// single shared quiet deadline; the first resolution wins and the losers
    /// are cancelled via an in-page event broadcast. A frame that cannot host
    /// the script degrades silently to the remaining frames (its own promise
    /// still self-resolves at the shared deadline, so teardown stays bounded
    /// even if the cancel broadcast cannot reach it). A navigation that tears
    /// down the JS context mid-wait is itself new activity; a vanished web view
    /// resolves `.noWebView` rather than crashing, matching every other
    /// session JS call.
    func performQuietWait(
        context: BrowserActionExecutionContext,
        milliseconds: Int
    ) async -> BrowserActionResult {
        guard let webView else {
            return BrowserActionResult(
                requestID: context.requestID,
                kind: .waitFor,
                status: .noWebView,
                message: "No WKWebView is attached.",
                urlBefore: context.urlBefore,
                networkEventCountDelta: networkDelta(since: context)
            )
        }

        let epochBefore = pageEpoch
        let frames: [(origin: String?, frame: WKFrameInfo?)] =
            [(nil, nil)] + knownChildFrames.map { (origin: $0.origin, frame: $0.frame) }
        let arguments = BrowserQuietWaitScript.arguments(quietMilliseconds: milliseconds)

        var winner: (frameOrigin: String?, outcome: BrowserQuietWaitOutcome)?
        var mainFrameFailure: String?

        await withTaskGroup(of: BrowserQuietWaitFrameResolution.self) { group in
            for entry in frames {
                group.addTask { @MainActor in
                    await Self.quietWaitResolution(
                        webView: webView,
                        frameOrigin: entry.origin,
                        frame: entry.frame,
                        arguments: arguments
                    )
                }
            }

            for await resolution in group {
                switch resolution {
                case .resolved(_, let outcome) where outcome.kind == .cancelled:
                    continue
                case .resolved(let frameOrigin, let outcome):
                    winner = (frameOrigin, outcome)
                case .failed(let frameOrigin, let message):
                    // A frame that cannot host the script (sandboxed, navigated
                    // away) degrades silently; only the main frame's failure is
                    // meaningful if nobody else resolves.
                    if frameOrigin == nil {
                        mainFrameFailure = message
                    }
                    continue
                }
                break
            }

            // First resolution wins: stand the losing frames' observers down so
            // the group drains now instead of at the deadline.
            for entry in frames {
                _ = try? await webView.evaluateJavaScript(
                    BrowserQuietWaitScript.cancelBroadcastSource,
                    in: entry.frame,
                    contentWorld: .page
                )
            }
            group.cancelAll()
            for await _ in group {}
        }

        if let winner {
            switch winner.outcome.kind {
            case .activity, .cancelled:
                return quietWaitResult(
                    context: context,
                    status: .succeeded,
                    message: BrowserQuietWaitScript.activityMessage(
                        frameOrigin: winner.frameOrigin,
                        elapsedMilliseconds: winner.outcome.elapsedMilliseconds
                    )
                )
            case .quiet:
                return quietWaitResult(
                    context: context,
                    status: .succeeded,
                    message: BrowserQuietWaitScript.quietMessage(milliseconds: milliseconds)
                )
            }
        }

        // A navigation mid-wait destroys the page's JS context and rejects
        // every pending promise — that teardown IS new activity, not a failure.
        if pageEpoch != epochBefore {
            return quietWaitResult(
                context: context,
                status: .succeeded,
                message: "New activity detected (navigation interrupted the wait)."
            )
        }
        return quietWaitResult(
            context: context,
            status: .scriptError,
            message: mainFrameFailure ?? "Quiet wait failed in every frame."
        )
    }

    private static func quietWaitResolution(
        webView: WKWebView,
        frameOrigin: String?,
        frame: WKFrameInfo?,
        arguments: [String: Any]
    ) async -> BrowserQuietWaitFrameResolution {
        do {
            let scriptResult = try await webView.callAsyncJavaScript(
                BrowserQuietWaitScript.functionBody,
                arguments: arguments,
                in: frame,
                contentWorld: .page
            )
            guard let outcome = BrowserQuietWaitOutcome(scriptResult: scriptResult) else {
                return .failed(
                    frameOrigin: frameOrigin,
                    message: "Quiet wait script returned an unrecognized payload."
                )
            }
            return .resolved(frameOrigin: frameOrigin, outcome)
        } catch {
            return .failed(frameOrigin: frameOrigin, message: "Quiet wait failed: \(error.localizedDescription)")
        }
    }

    private func quietWaitResult(
        context: BrowserActionExecutionContext,
        status: BrowserActionStatus,
        message: String
    ) -> BrowserActionResult {
        BrowserActionResult(
            requestID: context.requestID,
            kind: .waitFor,
            status: status,
            message: message,
            urlBefore: context.urlBefore,
            urlAfter: webView?.url,
            networkEventCountDelta: networkDelta(since: context)
        )
    }
}
