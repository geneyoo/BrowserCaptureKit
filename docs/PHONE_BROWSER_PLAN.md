# Phone browser: product vision and implementation plan

Updated: 2026-09-10. Status: design record. The first slice from section 12
(foreground host, relay, remote observe/navigate/tap/fill/events/status) is
implemented in `PhoneBrowser/` and `Relay/`; see
[PHONE_BROWSER_RUNBOOK.md](PHONE_BROWSER_RUNBOOK.md) for what is verified,
including the Gate 0 run on a physical iPhone over Wi-Fi (cellular untested).

## 1. Product outcome

Turn a spare iPhone into a remotely usable browser device for any agent, with
persistent website sessions, structured page inspection, and evidence of what
actions actually did. The agent runs elsewhere; browsing happens on the phone.

The intended experience:

1. Install the browser, pair the device, and leave it powered with the app open.
2. Log into websites locally. Authentication state stays in the phone's WebKit store.
3. Connect an agent through MCP or an SDK; mobile-use is one prospective client.
4. Observe the browser, inspect relevant traffic, act, and verify the outcome.
5. Watch locally and take control when needed; explicitly return control to the agent.
6. Reconnect after network loss without silently repeating side effects.

The value is real iOS WebKit execution, real device networking including cellular,
existing authenticated sessions, and richer evidence than pixels alone. Reusing old
phones is a deployment benefit. Device identity or cellular traffic does not promise
avoidance of rate limits or anti-abuse checks.

Longer term, this can become a phone execution endpoint with multiple capability
providers. Browser v1 does not depend on solving arbitrary native-app control.

## 2. Scope and constraints

V1 uses public APIs, one foreground WKWebView, one persistent browser profile, and
one active controller per device. It supports a dedicated phone without a Mac
attached during browser operation. Installation, signing renewal, and development
are separate lifecycle requirements that must be tested and documented.

This is a small WebKit browser, not Safari feature parity. Its website data is its
own; do not assume access to Safari's existing cookies or tabs.

Explicitly outside the first release:

- Guaranteed operation while locked, backgrounded, terminated, or after reboot.
- Root access, arbitrary filesystem access, shell execution, or iMessage control.
- Generic native touch injection or system-wide screenshots through the browser API.
- Complete Chrome DevTools Protocol or Playwright compatibility.
- Complete network interception, worker coverage, or access to every DOM surface.
- Vendor transport replay and raw JavaScript as ordinary agent tools.

iOS background execution is limited; a socket is not an execution entitlement.
See [Apple's background execution guidance](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).
First deployment posture: powered, unlocked, foreground browser. Measure actual
availability before making service-level promises.

## 3. Architecture and ownership

```text
Agent / mobile-use
       |
MCP adapter or SDK
       |
Command service + evidence adapter
       |
Authenticated outbound WebSocket initiated by iPhone
       |
iPhone host app: connection, execution journal, controller ownership
       |
BrowserCaptureKit: observations, actions, capture, lifecycle events
       |
Retained WKWebView + persistent website data store
```

The relay can run on Linux. No inbound connection to the phone is required, so
cellular NAT is not a blocker. Website traffic remains on the phone's network;
the relay carries commands and selected evidence, not proxied website requests.

| Component | Owns | Does not own |
| --- | --- | --- |
| BrowserCaptureKit | WebKit mechanics, target identity, observations, typed action results | Accounts, agent planning, device pairing, command journal |
| iPhone host | Visible browser, pairing credentials, lifecycle, execution serialization, local persistence, takeover | Model calls and vendor business interpretation |
| Command service | Device routing, authenticated authorization, controller lease, command/result ledger | Direct DOM execution |
| Evidence adapter | Bounded context, provenance, event selection, sanitized summaries | Inventing causal certainty or changing permissions from page text |
| Agent adapters | Framework-specific tool schemas and result mapping | Separate implementations of browser mechanics |

Start with one service deployment containing routing, ledger, and evidence assembly.
Do not create separate microservices or a general plugin framework in advance.

## 4. Reuse and replacement decisions

Current code is a foundation, not proof that all advertised invariants hold.

| Existing area | Decision | Required work |
| --- | --- | --- |
| `BrowserCaptureSession` and `BrowserCaptureWebView` | Keep | Add lifecycle recovery and supported browser screenshot wrapper |
| Persistent `WKWebsiteDataStore` selection | Keep | Host assigns and persists explicit profile identity |
| Codable command/result types | Reuse concepts | Add remote lifecycle fields outside the package; explicitly version incompatible changes |
| Semantic traversal and element actions | Harden | Enforce snapshot/document identity and reject retargeting |
| Frame registry and routing | Reshape | Distinguish frame instances, including identical origins |
| Capture hooks and event types | Keep, verify coverage | Stamp provenance at event time, bound buffers, expose missing coverage |
| Redaction | Harden before remote export | Cover URLs, element/action text, screenshots, and derived summaries |
| Quiet waits | Reshape semantics | Distinguish activity, condition satisfaction, quiet, cancellation, and deadline |
| Vendor replay | Separate from ordinary API | Keep existing callers working until an explicit migration is approved |
| HUD | Keep optional | Useful for local inspection; not a prerequisite for machine observations |
| Package and app-hosted conformance tests | Keep | Extend with failure-oriented browser and host tests |

Concrete source findings to resolve:

- `BrowserElementTarget` accepts optional snapshot and epoch fields. The executor
  checks a supplied epoch; the action matcher uses weighted identity/label matching.
  A remote action needs stricter binding than this convenience interface provides.
- `BrowserCaptureSession` and the bridge track child frames by origin; origin is
  not sufficient to distinguish two sibling frames from the same site.
- Generic observation/action evaluation runs in the page content world. Audit
  page-owned globals and separate trusted bookkeeping from untrusted capture data.
- `BrowserRedactionPolicy` masks bodies by default but passes accessibility/action
  events through its default branch and retains URLs. It is not yet a complete
  remote export boundary.
- The existing quiet wait intentionally succeeds for both new activity and its
  quiet deadline. A remote protocol must expose distinct structured outcomes.
- `BrowserCaptureCapabilities` advertises all action enum cases, including replay.
  Remote capabilities must instead reflect enabled, permitted, verified operations.

Related local reuse candidates, not dependencies of this package:

- `~/palette-agent-copilot-ios/apps/ios/Palette/Features/Browser/PaletteBrowserModel.swift`:
  retained browser host pattern.
- `~/palette-agent-copilot-ios/apps/ios/Palette/Core/Models/BrowserCopilotContext.swift`:
  combined page, network, element, and action context.
- `~/palette-agent-copilot-ios/apps/ios/Palette/Core/Models/BrowserCaptureEnvelope.swift`:
  normalized wire evidence. It currently stamps a supplied capture-time epoch;
  do not copy that as event-time attribution.
- `~/sharingan`: optional structured native control geometry and semantics. Its HUD
  visualizes evidence. It does not inspect arbitrary other iOS apps; its explicit
  URLSession capture does not replace WKWebView traffic hooks.

Prefer extracting the useful patterns over depending on Palette's customer-service
models, case IDs, vendor parsers, and server policy code.

## 5. Proposed host implementation

Use Swift concurrency with all WebKit interaction on the main actor. A host-owned
coordinator serializes mutations; remote transport must never evaluate arbitrary
commands directly from a socket callback. Persistence and encoding can run outside
the main actor, with durable writes awaited before dispatch.

Logical responsibilities, initially ordinary types in one app target:

- Browser owner: retains the view/session and handles dialogs, popups, navigation,
  app foreground transitions, and WebKit process termination.
- Connection owner: authentication, protocol negotiation, reconnect and resumption.
- Command coordinator: validates binding, controller lease, deadline and capability;
  journals execution; dispatches typed operations; records terminal results.
- Evidence collector: assigns sequence numbers, bounds buffers, redacts exports,
  and assembles observation bundles.
- Local controls: pairing, connection status, pause/takeover, and explicit resume.

Suggested device states: disconnected, connecting, ready, executing, human-control,
foreground-required, and recovering. Connectivity and execution readiness are
separate fields: a recently connected socket is not proof the browser can act.

On takeover, invalidate controller ownership and reject queued actions. An already
dispatched operation may still finish; report its actual or uncertain result.
On resume, require a new observation before element actions.

Use WebKit's browser snapshot API for browser imagery. Label its scope and viewport;
do not call it a full-device screenshot. Snapshot and DOM capture are asynchronous:
include capture start/end and revision information, and flag navigation or material
changes between them rather than claiming atomic capture.
See [WKWebView snapshots](https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(with:completionhandler:)).

## 6. Remote protocol sketch

Use TLS WebSocket with Codable JSON messages for the first implementation, backed
by [URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask).
Pair using a short-lived one-time code confirmed by the device owner. Store the
resulting device credential in Keychain; support revocation. Agent credentials
remain separate and scoped to permitted devices and operations.

Proposed message families:

| Message | Essential fields / behavior |
| --- | --- |
| Hello / resume | Protocol version, device ID, app/runtime versions, process instance ID, session ID, capabilities, event cursor |
| Command | Command ID, session ID, controller generation, deadline, typed operation, observation/target binding |
| Command receipt | Durably accepted or rejected; acceptance is not execution success |
| Result | Command ID, execution status, evidence references, timestamps, retry classification |
| Event batch | Stream ID, ordered sequence range, bounded events, gap/truncation metadata |
| Status | Readiness, foreground state, active operation, takeover state |
| Cancel | Stops undispatched work or cancellable waits; cannot undo a dispatched side effect |

Negotiate versions explicitly. Reject unknown operations, mismatched sessions,
expired commands, oversized inputs, and unsupported capabilities. Do not silently
downgrade an element action into a coordinate tap.

Use receive callbacks and lifecycle events. Reconnect uses bounded, cancellable
backoff; liveness uses explicit heartbeat deadlines. Neither mechanism polls the DOM.
Readiness has a server-side expiry so suspended devices do not remain listed ready.

On reconnect, reconcile command IDs and event cursors before accepting new mutation
work. Bound event memory/disk usage; emit explicit gaps when evidence is discarded.
Keep result/control delivery separate from bulk evidence scheduling so a traffic
burst cannot starve command acknowledgements. Large sanitized artifacts can use
authenticated, expiring references when inline transfer becomes insufficient.

## 7. Execution, deduplication, and recovery

The device is the authority on whether local dispatch began. The service's record
of sending a command cannot establish that fact.

Proposed durable lifecycle:

```text
received -> accepted -> dispatching -> completed
                    \-> rejected / cancelled-before-dispatch
                         dispatching -> uncertain (interruption / lost acknowledgement)
```

Persist acceptance and the dispatching marker before invoking any potentially
side-effecting browser operation. Persist the result before acknowledging it as
terminal. Bind the command ID to its canonical payload digest; reject reuse with
different content.

- Duplicate terminal command: return the saved result, never execute again.
- Duplicate active command: return status or await that same execution.
- Restart with a dispatching record but no terminal result: mark uncertain.
- Accepted but undispatched work: revalidate lease, deadline, session and page;
  conservatively expire old work after process/session changes.
- Network loss after completion: resend the saved result on reconnection.

The crash window between the durable marker and actual dispatch can produce a
conservative uncertain result even if nothing happened. That is preferable to a
duplicate submission. This is not a claim of exactly-once website execution.

Allow only one mutation at a time, with a controller generation checked locally
immediately before dispatch. A service lease alone is insufficient after a network
partition. Local pause/revocation always wins for undispatched work.

Use a transactional local journal (evaluate native SQLite first) with uniqueness
on command ID and atomic state changes. Persist minimal redacted metadata/results;
do not retain input secrets simply to compute deduplication. Distinguish:

- Website persistence: cookies and supported site storage in the WebKit profile.
- Execution persistence: command journal, profile mapping, and resumable event cursor.
- Live page state: DOM, JavaScript heap, sockets and in-memory site state, which do
  not survive process loss merely because cookies do.

No automatic resubmission after recovery. Re-observe and let the agent/human
reconcile the website outcome with available evidence.

## 8. Observation and action contracts

The remote target should be an opaque reference bound to a known observation,
document, and frame instance. Keep labels/fingerprints as descriptive evidence,
not fallback permission to activate a replacement element.

Proposed target identity: session ID, process/document generation, frame instance
ID and frame document generation, snapshot ID, element handle. Runtime maps handles
to elements, verifies they remain attached and actionable, and rejects stale or
ambiguous bindings. Prototype frame identity and isolated-world handle storage on
a physical device before fixing the final wire shape.

Perform final validation and DOM action in the same in-frame execution where
possible. If a future native controller executes a coordinate tap, validate fresh
geometry but acknowledge the cross-process race; it cannot inherit atomic DOM
target guarantees.

Proposed browser tools, names provisional:

| Tool | Contract |
| --- | --- |
| `browser.observe` | Page/viewport, bounded elements, optional image, capabilities, event cursor and coverage |
| `browser.navigate` | URL plus explicit readiness criterion and deadline |
| `browser.act` | Typed action and bound target where applicable |
| `browser.events` | Filtered evidence after cursor; explicit gaps and truncation |
| `browser.inspect` | Sanitized detail for an already referenced evidence item |
| `browser.wait` | Observable condition with deadline and structured outcome |
| `browser.command_status` | Reconcile a prior command without executing it again |

Navigation waits should bind to the intended navigation. Element waits subscribe
to relevant document changes and validate conditions, including attribute changes.
Network waits refer to captured events and state coverage limits. Report separate
outcomes for condition-met, deadline, cancelled, navigation-invalidated, and failure.

Browser activation is not generic iOS touch injection. Sites requiring trusted
user activation, native pickers, or unsupported system flows must return a specific
capability/human-input result. Start with explicit human handling of login, MFA,
and sensitive fields. Do not quietly add raw JavaScript as an escape hatch.

## 9. Evidence assembly and export

An observation bundle contains page identity, capture interval, viewport mapping,
elements, optional image reference, event cursor, recent action references, and
coverage diagnostics. Events carry event-time document/frame identity, local
sequence number, timestamp, source, bounded payload and truncation flags.

Preserve CSS viewport coordinates, frame offsets, WebView bounds, and image pixel
scale explicitly. Native AX, Sharingan root geometry, and DOM geometry are different
coordinate systems. Unknown mappings stay unknown; never merge nodes just because
their labels match.

Correlation strengths should be explicit: exact request/response identity,
site-provided acknowledgement linkage, or temporal association only. An action's
time window is not proof it caused every request in that window. Example:

```text
Action: Reserve element activated
Network evidence: reservation response contains a confirmation ID
UI evidence: spinner remains visible
Interpretation: backend confirmation observed; rendered confirmation not yet observed
```

Start with deterministic selection and normalization, not an extra LLM interpreter.
The agent receives compact deltas and can request relevant details. Site-specific
parsers can be added outside the runtime when concrete workflows justify them.

Default raw evidence is bounded and local in memory. Before persistence or remote
export, sanitize headers, URL credentials/query values, body content, editable text,
action results, console/errors, and derived summaries. Never export cookies/storage
as general model context. If image masking cannot be trusted for a sensitive view,
omit the image and report the omission. Human login mode pauses capture/export.
The service should only receive export-approved evidence, not become the first
place secrets are stripped.

Capture is best effort: report unavailable frames, omitted elements, body limits,
and worker/transport blind spots. Public WebKit capture hooks are not a universal
network proxy or CDP session. Treat all page and network content as untrusted data.

## 10. Agent compatibility

First expose a transport-neutral typed API and a thin MCP adapter. Adapters share
the same authorization, command journal, and result semantics.

For mobile-use, add browser observations to the agent's context and browser tools
to its executor. Its current controller contract returns a screenshot and element
list, and its unified tap path rereads a native hierarchy before tapping its center.
Appending DOM nodes to that list alone does not integrate browser actions.
See the [controller interface](https://github.com/minitap-ai/mobile-use/blob/main/minitap/mobile_use/controllers/device_controller.py)
and [tap implementation](https://github.com/minitap-ai/mobile-use/blob/main/minitap/mobile_use/controllers/unified_controller.py),
reviewed on 2026-09-10 against moving `main`; pin an upstream revision before implementation.

Two explicit modes:

- Browser-only, no attached Mac: expose only our browser capabilities. Adjust
  mobile-use initialization/tool availability so it does not require its existing
  native iOS controller. The exact upstream integration seam still needs a spike.
- Hybrid, optional native backend: browser targets go to our endpoint; native
  targets/system UI go to the separately configured device controller.

Unsupported native operations must fail or be unavailable. Do not pretend that a
WKWebView endpoint implements every method of a general phone controller. Other
agents can use the MCP tools or SDK without adopting mobile-use's planning loop.

## 11. Delivery gates and experiments

| Gate | Build/probe | Evidence required to proceed |
| --- | --- | --- |
| 0: physical feasibility | Minimal signed foreground host plus relay; Wi-Fi and cellular; no attached Mac during operation | Remote observe/action/result works; screenshot scope documented; signing and foreground constraints recorded |
| 1: reliable browser loop | Harden binding, frame routing, actionability, waits and exports | Stale/replaced targets rejected; same-origin sibling frames distinguished; unsupported activation reported; sensitive fixtures stay out of exports |
| 2: recovery | Durable journal, ownership, reconnect and foreground handling | Disconnect before/after dispatch and app/process interruption never cause automatic duplicate submission; gaps and uncertainty visible |
| 3: agent integration | MCP client and mobile-use browser mode | Both complete the same controlled workflow through the same API; native setup is optional for browser-only mode |
| 4: measured usefulness | Compare available observation modes on repeatable tasks | Report completion, wrong-target actions, duplicate submissions, latency, evidence coverage, and context size |

Controlled fixtures should include a form with an authoritative submission counter,
replaced DOM elements, duplicate labels, same-origin sibling iframes, SPA navigation,
streaming responses, sensitive fields, and explicit user-activation requirements.
Use server counters to check duplicates; a success-looking screenshot is insufficient.

After controlled fixtures pass, run representative real-site flows with human
authentication and known expected outcomes. Compare screenshot/native AX and
combined browser evidence under equivalent conditions; a native baseline may use
separate infrastructure and is not required for the Mac-free product path.

Availability experiments: extended foreground use, network changes, background/lock,
WebKit process loss, app restart, and signing expiry/renewal. Document required human
recovery. Decide later whether operational results justify broader availability work.

For implementation changes run `make verify`, then `make conformance-device` when
WebKit lifecycle, frames, activation, or acknowledgement behavior changes. Add host
integration tests for protocol and journal behavior; package tests cannot prove those.

## 12. Immediate next slice and remaining decisions

Recommended next implementation slice: one foreground iPhone host, one browser
profile, one authenticated relay connection, and remote observe/navigate/one safe
element action/result. Use a controlled test page and expose provisional capabilities.
Do not add multi-tab management, a fleet dashboard, or vendor replay to this spike.

Resolve during that slice:

- Actual test iPhone/iOS version and sustainable signing/install workflow.
- Minimal host location and build configuration, reusing the repository's XcodeGen
  pattern without turning the conformance host into the shipping product.
- Service runtime after inspecting reusable local infrastructure; avoid importing
  Palette wholesale just to get a socket server.
- Device-enforced handle/frame identity and screenshot redaction feasibility.
- Required human interventions for target browser workflows.

Keep BrowserCaptureKit as the package boundary. Add app/service/adapter directories
only as those components are implemented; directory names are not an architecture
commitment. Replace failing subsystems based on the gates above. A whole-repo rewrite
is not supported by the current evidence.

## 13. Planning validation record

This plan is grounded in the current Swift package, action/contract types, session
creation and storage selection, navigation/wait code, frame routing, and redaction
implementation, plus the related Palette/Sharingan inspection and linked upstream
controller sources. Runtime gaps listed here are source-review findings; this planning
pass did not reproduce them on a physical phone or demonstrate remote operation.

No implementation code is included in this document. Record the checks actually run
for this documentation change in the delivery response; do not treat a simulator
test pass as validation of the proposed service.
