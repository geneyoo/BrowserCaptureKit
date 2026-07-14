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
/// Main-frame only for now: the MutationObserver cannot see cross-origin
/// iframe churn (iframe actuation is a later work package).
enum BrowserQuietWaitScript {
    /// JS-side debounce confirming a mutation burst has settled before the
    /// promise reports activity. Not a poll — it re-arms only on new mutations.
    static let settleMilliseconds = 400

    /// Function body for `callAsyncJavaScript`; expects `quietMilliseconds`
    /// and `settleMilliseconds` arguments and returns
    /// `{ outcome: "activity" | "quiet", elapsedMs }`.
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
            resolve({ outcome: outcome, elapsedMs: Date.now() - startedAt });
          };
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

    static func arguments(quietMilliseconds: Int) -> [String: Any] {
        [
            "quietMilliseconds": quietMilliseconds,
            "settleMilliseconds": settleMilliseconds,
        ]
    }
}

/// Decoded resolution of the quiet-wait promise.
struct BrowserQuietWaitOutcome: Equatable {
    enum Kind: String {
        case activity
        case quiet
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

@MainActor
extension BrowserCaptureSession {
    /// Genuine `.quiet` wait (loop-pump contract): completes `.succeeded` BOTH
    /// when new activity is observed AND when the quiet deadline elapses; the
    /// message distinguishes ("New activity detected …" vs "No new activity
    /// within <N>ms"). A navigation that tears down the JS context mid-wait is
    /// itself new activity; a vanished web view resolves `.noWebView` rather
    /// than crashing, matching every other session JS call.
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
        do {
            let scriptResult = try await webView.callAsyncJavaScript(
                BrowserQuietWaitScript.functionBody,
                arguments: BrowserQuietWaitScript.arguments(quietMilliseconds: milliseconds),
                contentWorld: .page
            )
            guard let outcome = BrowserQuietWaitOutcome(scriptResult: scriptResult) else {
                return quietWaitResult(
                    context: context,
                    status: .scriptError,
                    message: "Quiet wait script returned an unrecognized payload."
                )
            }

            switch outcome.kind {
            case .activity:
                let elapsed = outcome.elapsedMilliseconds.map { " after \($0)ms" } ?? ""
                return quietWaitResult(
                    context: context,
                    status: .succeeded,
                    message: "New activity detected\(elapsed)."
                )
            case .quiet:
                return quietWaitResult(
                    context: context,
                    status: .succeeded,
                    message: "No new activity within \(milliseconds)ms."
                )
            }
        } catch {
            // A navigation mid-wait destroys the page's JS context and rejects
            // the promise — that teardown IS new activity, not a failure.
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
                message: "Quiet wait failed: \(error.localizedDescription)"
            )
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
