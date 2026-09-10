# Phone browser runbook

Companion to [PHONE_BROWSER_PLAN.md](PHONE_BROWSER_PLAN.md). This covers the
first implementation slice: one foreground iPhone host (`PhoneBrowser/`), one
relay process (`Relay/`), and remote observe / navigate / tap / fill / events /
command-status through an authenticated outbound WebSocket.

## Components

| Directory | What it is | Tests |
| --- | --- | --- |
| `PhoneBrowser/` | SwiftUI host app: retained `BrowserCaptureSession`, SQLite command journal, evidence collector, command coordinator, relay connection, pairing, takeover/resume | `make phone-browser` (simulator), `make phone-browser-device` |
| `Relay/` | Node service: pairing, device sockets, command ledger, agent HTTP API, counter fixture, MCP adapter | `make relay-test` |

The package boundary is unchanged: `BrowserCaptureKit` gained only a
`onWebContentProcessTerminated` hook (the session bumps `pageEpoch` and drops
frame routes first; the host reloads and rotates its session).

## Running the relay

```bash
cd Relay && npm ci
AGENT_TOKEN='<long random secret>' PORT=8787 DATA_DIR=./data npm start
```

Environment: `PORT`, `HOST`, `AGENT_TOKEN` (required), `DATA_DIR`,
`READINESS_TTL_MS` (45 s), `HEARTBEAT_INTERVAL_MS` (15 s), `PAIRING_TTL_MS`
(10 min), `DEFAULT_COMMAND_TIMEOUT_MS` (45 s), `MAX_COMMAND_TIMEOUT_MS` (120 s).

The relay serves plain HTTP/WS. Put TLS in front of it (a reverse proxy) before
leaving a private network; the app derives `wss://` from an `https://` relay
URL. The `/fixtures/*` routes are unauthenticated test pages: never expose them
on a public relay.

## Pairing a phone

1. Agent side: `POST /v1/pairings` with the agent bearer token returns a
   six-digit single-use code valid for ten minutes.
2. Phone: build and run `PhoneBrowser` (open `PhoneBrowser/PhoneBrowser.xcodeproj`,
   or `make generate` after editing `project.yml`). Enter the relay URL and the
   code in the pairing sheet.
3. The relay returns a device ID and token; the app stores them in the Keychain
   and opens the outbound socket. The status bar shows readiness, relay
   connection, and the controller generation.

Automation hook: launching with `PHONEBROWSER_RELAY_URL` and
`PHONEBROWSER_PAIRING_CODE` in the environment pairs without the sheet
(`xcrun simctl launch` needs the `SIMCTL_CHILD_` prefix).

Revoke with `POST /v1/devices/{deviceId}/revoke`; the app's menu has "Unpair".

## Agent API

All routes below require `Authorization: Bearer <AGENT_TOKEN>`.

| Route | Purpose |
| --- | --- |
| `GET /v1/devices`, `GET /v1/devices/{id}` | Connection, readiness (`ready`, `executing`, `humanControl`, `foregroundRequired`, `recovering`, `stale`, `disconnected`), session ID, controller generation, capabilities |
| `POST /v1/devices/{id}/commands` | `{operation, commandId?, sessionId?, controllerGeneration?, timeoutMs?}`; waits for a terminal result up to the timeout, else `202` with the current state |
| `GET /v1/commands/{id}?waitMs=` | Ledger record: state, receipt, result |
| `DELETE /v1/commands/{id}` | Cancel; only undispatched work can be cancelled |
| `POST /v1/devices/{id}/revoke` | Revoke the device credential |

Operations:

```json
{"kind":"observe","includeImage":true,"maxElements":120}
{"kind":"navigate","url":"https://example.com/"}
{"kind":"act","action":{"kind":"tap","observationId":"…","elementId":"…"}}
{"kind":"act","action":{"kind":"fill","observationId":"…","elementId":"…","text":"…"}}
{"kind":"events","afterSequence":0,"limit":100}
{"kind":"commandStatus","commandId":"…"}
```

Element actions bind to an `observationId` and an `elementId` from that
observation. The phone rejects unknown, stale (page epoch changed), or
pre-resume observations and unknown elements before dispatch, and the in-page
matcher receives identity only, so a label match can never activate a
replacement element.

Result states: `completed`, `rejected` (with `reason`), `cancelled`,
`uncertain`, and on the relay side `notStarted` (the device never accepted the
command) and `expired`. `retryClassification` is `notStarted`, `safe`, or
`unsafe`. `uncertain` and `unsafe` mean re-observe before doing anything
else; nothing is retried automatically.

### MCP

```bash
cd Relay && RELAY_URL=http://127.0.0.1:8787 AGENT_TOKEN='…' npm run mcp
```

Tools: `phone_browser_devices`, `phone_browser_observe`,
`phone_browser_navigate`, `phone_browser_act`, `phone_browser_events`,
`phone_browser_command_status`. With Claude Code:

```bash
claude mcp add phone-browser -e RELAY_URL=http://127.0.0.1:8787 -e AGENT_TOKEN='…' -- node /path/to/Relay/src/mcp.mjs
```

## Controlled workflow (counter fixture)

`GET /fixtures/counter` is a form with a server-side submission counter;
`GET /fixtures/counter/state` returns `{count, lastNote}` and
`POST /fixtures/counter/reset` clears it. The intended loop:

1. `navigate` to the fixture.
2. `observe`; pick the `textbox` and the `Submit note` button by ID.
3. `fill` the textbox, `tap` the button.
4. `observe` again and read the server counter. A duplicate of the tap's
   command ID returns the saved result and the counter stays at 1.

A tap that submits a form returns as soon as the click is dispatched; the
resulting navigation is separate evidence. An observation taken while
`documentLoading` is true may still describe the outgoing document, so observe
again once it is false (or after `page.navigationFinished` appears in events).

`make phone-browser-e2e` automates this on the simulator: it builds a signed
app (an unsigned build has no entitlements and the Keychain save fails),
starts a relay on `PORT` (8787), pairs through the launch environment, and
runs `Relay/scripts/e2e.mjs`, which asserts every step above plus export
redaction and ledger reconciliation. The same script runs against a physical
phone once it is paired: `RELAY_URL=… AGENT_TOKEN=… node Relay/scripts/e2e.mjs`
with `FIXTURE_URL` pointing at the relay address the phone can reach.

## Human control and recovery

- "Take control" rejects queued work (`humanControl`), lets a dispatching
  command finish, and pauses capture export. "Return control to agent" starts a
  new controller generation; element actions need a fresh observation.
- Backgrounding the app reports `foregroundRequired`; commands are refused
  until it is active again.
- Web content process loss reloads the page and rotates the session ID; every
  earlier observation and command binding is invalid.
- On reconnect the relay lists commands without a terminal result; the phone
  answers each from its journal (`uncertain` for work that was dispatching when
  the process died, `expired` for work never dispatched, `unknownCommand` for
  commands it never received, which the relay records as `notStarted`).

## Gate 0 on a physical iPhone

Not yet run. Requirements and steps:

1. iPhone on iOS 17+, developer mode on, signed with team `H32EKFDL92`
   (`BCK_DEVELOPMENT_TEAM` overrides). Free-provisioning signatures expire
   weekly; note the install date.
2. Run the relay on a host reachable from the phone (LAN IP, or a TLS proxy for
   cellular). On the phone, iOS asks for local-network permission on first use.
3. Pair, then run the counter workflow above over Wi-Fi and over cellular with
   the Mac disconnected.
4. Record: whether commands complete with no Mac attached, screenshot scope,
   the local-network and signing prompts hit, and how long the app stays
   foreground before the phone locks (auto-lock must be disabled for the
   foreground deployment posture).

`make phone-browser-device` runs the hosted tests on the attached phone.
