// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BrowserCaptureKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "BrowserCaptureKit",
            targets: ["BrowserCaptureKit"]
        )
    ],
    targets: [
        .target(
            name: "BrowserCaptureKit"
        )
    ]
)
