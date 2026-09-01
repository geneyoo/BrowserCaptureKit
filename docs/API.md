# API contract

## Stable boundary

The durable integration boundary is Codable data, not a raw `WKWebView` handle:

- `BrowserActionCommand`
- `BrowserActionRequest`
- `BrowserActionResult`
- `BrowserAccessibilitySnapshot`
- `BrowserCaptureEvent`
- `BrowserCaptureCapabilities`

Every transport should reject unsupported schema versions. Date encoding and
framing are transport decisions; JSON examples should use ISO-8601 dates and
sorted keys for reviewable fixtures.

## Identity and staleness

`snapshotID` identifies one observation. `pageEpoch` changes when navigation
invalidates the document. `stableID` is executable only within the observation
and frame namespace that produced it. A host must never reinterpret a stale ID
as permission to search for a similar current element.

Target resolution prefers exact identity and fingerprint evidence before role,
label, text, or explicitly authorized bounds fallback. Multiple plausible
targets return `ambiguousMatch`.

## Results

`succeeded` means the local action completed and the result captured the browser
state afterward. It does not by itself prove that a remote merchant committed a
business effect. `acknowledgementTimedOut` and
`processInterruptedAfterClaim` are uncertain outcomes and are unsafe to retry
without fresh evidence and explicit user authorization.

## Capture events

`BrowserCaptureEvent` encodes as:

```json
{
  "kind": "page",
  "payload": {}
}
```

The `kind` discriminator is stable within schema version 1. Unknown kinds or
schemas fail decoding so a consumer cannot silently discard security-relevant
evidence.

## Experimental surface

Raw JavaScript evaluation, vendor protocol interpretation, WebSocket replay,
and REST reissue are not the ordinary generic action contract. They must remain
behind host policy and explicit destination/session bindings until promoted by
conformance evidence.
