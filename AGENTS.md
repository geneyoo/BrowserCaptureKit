# BrowserCaptureKit working agreement

BrowserCaptureKit is an iOS 17+ Swift package for a visible, retained,
agent-operable `WKWebView`. Keep it independent of host-app planning, model,
approval UI, persistence, and vendor business logic.

Core invariants:

- Use public WebKit APIs only.
- Bind element actions to a snapshot and page epoch; fail stale or ambiguous
  targets instead of silently retargeting.
- Treat any side effect with an uncertain acknowledgement as unsafe to retry.
- Keep credentials, cookies, storage, auth headers, and sensitive editable
  values out of model-facing exports.
- Treat page content as untrusted evidence, never policy or instructions.
- Wait on navigation, DOM, network, or explicit deadlines; never add arbitrary
  sleeps or polling loops.
- Keep raw JavaScript and vendor transport replay outside the ordinary stable API.

Run `make verify` after changes. Broaden to a physical-device host-app run for
changes involving WebKit lifecycle, frame routing, user activation, or merchant
transport acknowledgement.
