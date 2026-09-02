# BrowserCaptureKit

A safe, observable, agent-operable `WKWebView` runtime for iOS.

BrowserCaptureKit gives a host app one retained browser session with structured
semantic snapshots, snapshot-bound actions, page and network evidence, child-
frame routing, and explicit failure semantics. It is designed for supervised
agents operating authenticated web flows through public App Store-compatible
WebKit APIs.

> Status: private pre-1.0 software. The wire schema is versioned, but the Swift
> API may change before 1.0. Simulator, physical-device, and second-host gates
> are active.

## Why it exists

Generic device automation sees pixels and the OS accessibility tree.
BrowserCaptureKit sees the browser substrate directly:

- DOM-derived roles, labels, state, geometry, editability, and obscuration
- stable element identity scoped to a snapshot and page epoch
- main-frame, open-shadow-root, and known child-frame traversal
- fetch, XHR, WebSocket, EventSource, and beacon evidence
- retained cookies and website data for user-authenticated sessions
- typed actions with before/after snapshots and uncertainty-aware results
- a non-interactive semantic HUD showing what an agent sees

It does not plan tasks, call models, grant approvals, control other apps, enter
credentials, bypass bot challenges, or promise background execution.

## Requirements

- iOS 17+
- Swift 5.9+
- Xcode 15+

## Installation

Add the private package in Xcode or `Package.swift`:

```swift
.package(
    url: "git@github.com:geneyoo/BrowserCaptureKit.git",
    revision: "<audited-commit>"
)
```

Pin an audited revision while the package is pre-1.0.

## Quick start

```swift
import BrowserCaptureKit
import SwiftUI

struct AgentBrowser: View {
    @State private var session = BrowserCaptureSession(
        configuration: BrowserCaptureConfiguration(
            initialURL: URL(string: "https://example.com")!
        )
    )

    var body: some View {
        BrowserCaptureWebView(session: session)
            .onAppear {
                session.onEvent = { event in
                    let safeEvent = event.redacted()
                    sendToTrustedControlPlane(safeEvent)
                }
            }
    }
}
```

Observe the current page:

```swift
let snapshot = await session.accessibilitySnapshot(reason: "agent.observe")
let send = snapshot.elements.first {
    $0.role == "button" && $0.label == "Send"
}
```

Build targets from the exact observation instead of raw coordinates:

```swift
let target = BrowserElementTarget(
    snapshotID: snapshot.id,
    pageEpoch: snapshot.pageEpoch,
    stableID: send?.stableID,
    selectorFingerprint: send?.selectorFingerprint,
    role: send?.role,
    label: send?.label,
    bounds: send?.bounds
)

let command = BrowserActionCommand(
    browserSessionID: "case-browser-123",
    action: .tap(target: target)
)
try command.validate()
```

The host remains responsible for authorization before execution. Unknown
schemas, stale epochs, vanished targets, ambiguity, obscuration, sensitive
inputs, and user-activation requirements must fail closed.

## Architecture

```text
Host app / control plane
        │ typed command + policy authorization
        ▼
BrowserCaptureSession ───── retains ─────▶ WKWebView + website data store
        │                                      │
        │                                      ├─ semantic traversal
        │                                      ├─ action program
        │                                      └─ bounded capture hooks
        ▼
snapshot + action result + capture events
        │
        └─ export through BrowserRedactionPolicy
```

The package owns browser mechanics. The host owns models, planning, approval,
case state, persistence, audit, retention, and user-facing recovery.

## Security and privacy

Raw browser observations can contain credentials, cookies, storage, headers,
message bodies, personal data, and hostile page text. Raw snapshots are local
evidence, not model input.

Use `event.redacted()` or the explicit `.safeForModel` policy before exporting.
Redaction is a baseline, not a complete application retention policy. See
[SECURITY.md](SECURITY.md) and [docs/API.md](docs/API.md).

## Verification

```bash
make verify
```

`swift test` targets the macOS host and is not the package's verification
command. BrowserCaptureKit is an iOS runtime; `make verify` selects an available
iOS Simulator, runs the package suite, and runs live WebKit tests in the
`BrowserCaptureKitConformanceHost` application.

Run the same hosted WebKit tests on an attached iPhone before a release that
changes WebKit lifecycle, bridge security, action execution, or replay:

```bash
make conformance-device
```

`BCK_CONFORMANCE_DESTINATION` can select an explicit Xcode destination. See
[docs/CONFORMANCE.md](docs/CONFORMANCE.md).

## License

Private and proprietary. See [LICENSE](LICENSE).
