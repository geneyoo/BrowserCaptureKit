# Conformance gates

BrowserCaptureKit has two complementary test surfaces.

| Gate | Command | Coverage |
| --- | --- | --- |
| Package | `make test` | Codable contracts, parsing, routing, waits, replay policy, and pure bridge invariants |
| App-hosted | `make conformance` | Live `WKWebView`, authenticated bridge isolation, and post-dispatch uncertainty |
| Physical device | `make conformance-device` | The app-hosted gate on shipping iOS/WebKit and device process boundaries |

`make verify` runs the package and app-hosted simulator gates. GitHub Actions
runs this command on every pull request and `main` push.

The device gate selects the first connected iPhone reported as an available
destination by Xcode and fails fast when that iPhone is locked. Override
selection or signing when needed:

```bash
BCK_CONFORMANCE_DESTINATION='platform=iOS,id=<device-udid>' \
BCK_DEVELOPMENT_TEAM='<team-id>' \
make conformance-device
```

Run the device gate before releasing changes involving:

- `WKWebView` creation, retention, navigation, or process lifecycle
- script worlds, message handlers, bridge tokens, or hostile-page isolation
- action dispatch, user activation, submission, replay, or acknowledgement
- frame traversal or routing

A release gate fails on any skip. Tests that require `UIApplication` or a live
WebKit process belong in `Conformance/Tests`, not the bare Swift package suite.
