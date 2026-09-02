import SwiftUI
import UIKit

private struct ConformanceWebViewMountPoint: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.accessibilityIdentifier = "browsercapturekit.conformance.web-view-mount-point"
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

@main
struct BrowserCaptureKitConformanceHost: App {
    var body: some Scene {
        WindowGroup {
            ConformanceWebViewMountPoint()
                .ignoresSafeArea()
        }
    }
}
