import BrowserCaptureKit
import Foundation
import UIKit
import WebKit

/// Retains the one visible browser and handles WebKit lifecycle the package
/// leaves to the host: dialogs, popups, foreground transitions, and web
/// content process loss.
@MainActor
final class BrowserOwner: NSObject {
    let session: BrowserCaptureSession
    let webView: WKWebView

    private(set) var isForeground = true
    /// Set when the web content process died and the reload has not finished.
    private(set) var isRecovering = false

    var onCaptureEvent: ((BrowserCaptureEvent) -> Void)?
    var onDialog: ((_ kind: String, _ message: String?) -> Void)?
    var onLifecycle: ((String) -> Void)?
    /// The document and every identity derived from it are gone.
    var onDocumentInvalidated: (() -> Void)?

    init(configuration: BrowserCaptureConfiguration) {
        session = BrowserCaptureSession(configuration: configuration)
        webView = session.makeWebView()
        super.init()
        webView.uiDelegate = self
        session.onEvent = { [weak self] event in
            self?.handle(event)
        }
        session.onWebContentProcessTerminated = { [weak self] in
            self?.recoverFromProcessTermination()
        }
    }

    func setForeground(_ foreground: Bool) {
        guard foreground != isForeground else {
            return
        }
        isForeground = foreground
        onLifecycle?(foreground ? "foreground" : "background")
    }

    /// Browser imagery through WebKit's public snapshot API. The scope is the
    /// web view's viewport, not the device screen.
    func takeSnapshotImage(maxPixelDimension: CGFloat = 1_024) async -> ObservationImage? {
        let pointSize = webView.bounds.size
        guard pointSize.width > 0, pointSize.height > 0 else {
            return nil
        }
        let configuration = WKSnapshotConfiguration()
        let longest = max(pointSize.width, pointSize.height)
        configuration.snapshotWidth = NSNumber(value: Double(min(pointSize.width, pointSize.width * maxPixelDimension / max(longest, 1))))
        let image: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image, let data = image.jpegData(compressionQuality: 0.7) else {
            return nil
        }
        return ObservationImage(
            format: ObservationImage.format,
            scope: ObservationImage.scope,
            base64: data.base64EncodedString(),
            pixelWidth: Int(image.size.width * image.scale),
            pixelHeight: Int(image.size.height * image.scale),
            pointWidth: pointSize.width,
            pointHeight: pointSize.height,
            capturedAt: Date()
        )
    }

    private func handle(_ event: BrowserCaptureEvent) {
        if isRecovering, case .page(let page) = event,
            page.kind == .navigationFinished || page.kind == .navigationFailed
        {
            isRecovering = false
            onLifecycle?("recovered")
        }
        onCaptureEvent?(event)
    }

    private func recoverFromProcessTermination() {
        isRecovering = true
        onLifecycle?("webContentProcessTerminated")
        onDocumentInvalidated?()
        webView.reload()
    }
}

extension BrowserOwner: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // One foreground web view: a popup request navigates in place.
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false {
            onDialog?("popup", navigationAction.request.url?.absoluteString)
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        onDialog?("alert", message)
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        // Page dialogs never get an implicit "yes" from an unattended browser.
        onDialog?("confirm", message)
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        onDialog?("prompt", prompt)
        completionHandler(nil)
    }
}
