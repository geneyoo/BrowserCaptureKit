/**
 * Controlled-workflow check against a paired, ready device: navigate to the
 * counter fixture, observe, fill, tap, re-observe, and verify the server
 * counter, duplicate suppression, stale-observation rejection, and export
 * redaction. Exits non-zero on the first failed check.
 *
 * Usage: RELAY_URL=http://127.0.0.1:8787 AGENT_TOKEN=… [DEVICE_ID=…] node scripts/e2e.mjs
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const relayUrl = (process.env.RELAY_URL ?? "http://127.0.0.1:8787").replace(/\/$/, "");
const agentToken = process.env.AGENT_TOKEN;
const fixtureUrl = process.env.FIXTURE_URL ?? `${relayUrl}/fixtures/counter`;
const readyTimeoutMs = Number(process.env.READY_TIMEOUT_MS ?? 60_000);
assert.ok(agentToken, "AGENT_TOKEN is required");

async function api(method, path, body, auth = true) {
  const response = await fetch(`${relayUrl}${path}`, {
    method,
    headers: { ...(auth ? { authorization: `Bearer ${agentToken}` } : {}), "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: response.status, body: await response.json().catch(() => null) };
}

function step(name, value) {
  console.log(`✔ ${name}${value === undefined ? "" : `: ${value}`}`);
}

// Device readiness: bounded retry on the read-only listing while the phone pairs and connects.
const deadline = Date.now() + readyTimeoutMs;
let device = null;
while (Date.now() < deadline) {
  const { body } = await api("GET", "/v1/devices");
  device = body.devices.find(
    (candidate) => candidate.connected && candidate.readiness === "ready" && (!process.env.DEVICE_ID || candidate.deviceId === process.env.DEVICE_ID),
  );
  if (device) break;
  await new Promise((resolve) => setTimeout(resolve, 1000));
}
assert.ok(device, "no ready device within the timeout");
step("device ready", `${device.deviceId} session=${device.sessionId} generation=${device.controllerGeneration}`);
assert.deepEqual(device.capabilities.actions, ["tap", "fill"]);

const command = async (operation, extra = {}) => {
  const { status, body } = await api("POST", `/v1/devices/${device.deviceId}/commands`, { operation, ...extra });
  assert.equal(status, 200, `command ${operation.kind} did not complete: ${JSON.stringify(body)}`);
  return body;
};

await api("POST", "/fixtures/counter/reset", undefined, false);

const navigate = await command({ kind: "navigate", url: fixtureUrl });
assert.equal(navigate.result.payload.navigation.status, "succeeded");
step("navigate", navigate.result.payload.navigation.urlAfter);

const observe = await command({ kind: "observe", includeImage: true, maxElements: 50 });
const observation = observe.result.payload.observation;
assert.equal(observation.documentLoading, false);
assert.equal(observation.image?.scope, "webViewViewport");
const note = observation.elements.find((element) => element.role === "textbox");
const submit = observation.elements.find((element) => element.role === "button");
assert.ok(note && submit, "fixture elements not observed");
step("observe", `${observation.elements.length} elements, image ${observation.image.pixelWidth}x${observation.image.pixelHeight}`);

const fillText = `note-${randomUUID()}`;
const fill = await command({ kind: "act", action: { kind: "fill", observationId: observation.observationId, elementId: note.id, text: fillText } });
assert.equal(fill.result.payload.action.status, "succeeded");
step("fill");

const tapId = `tap-${randomUUID()}`;
const tap = await command({ kind: "act", action: { kind: "tap", observationId: observation.observationId, elementId: submit.id } }, { commandId: tapId });
assert.equal(tap.result.payload.action.status, "succeeded");
assert.equal(tap.result.retryClassification, "unsafe");
step("tap");

// The form POST is a navigation; observe until the document settles.
let settled = null;
for (let attempt = 0; attempt < 10 && !settled; attempt += 1) {
  const again = await command({ kind: "observe", includeImage: false, maxElements: 50 });
  if (!again.result.payload.observation.documentLoading) settled = again.result.payload.observation;
}
assert.ok(settled, "document never settled");
const counterText = settled.elements.find((element) => element.tagName === "p" && element.label?.startsWith("Submissions"))?.label;
assert.equal(counterText, "Submissions: 1");
step("observe after submit", counterText);

const { body: state } = await api("GET", "/fixtures/counter/state", undefined, false);
assert.deepEqual(state, { count: 1, lastNote: fillText });
step("server counter", JSON.stringify(state));

const duplicate = await command({ kind: "act", action: { kind: "tap", observationId: observation.observationId, elementId: submit.id } }, { commandId: tapId });
assert.deepEqual(duplicate.result, tap.result);
const { body: afterDuplicate } = await api("GET", "/fixtures/counter/state", undefined, false);
assert.equal(afterDuplicate.count, 1, "duplicate command must not submit again");
step("duplicate command id returns the saved result; counter unchanged");

const stale = await api("POST", `/v1/devices/${device.deviceId}/commands`, {
  operation: { kind: "act", action: { kind: "tap", observationId: observation.observationId, elementId: submit.id } },
});
assert.equal(stale.body.state, "rejected");
assert.equal(stale.body.receipt.reason, "staleObservation");
step("stale observation rejected before dispatch");

const events = await command({ kind: "events", afterSequence: 0, limit: 500 });
const page = events.result.payload.events;
const serialized = JSON.stringify(page);
assert.ok(!serialized.includes(fillText), "fill text leaked into exported events");
assert.ok(page.events.some((event) => event.kind === "nativeNetwork.navigationAction" && event.method === "POST"), "form POST evidence missing");
step("events", `${page.events.length} exported, latest ${page.latestSequence}, no fill text`);

const status = await api("GET", `/v1/commands/${tapId}`);
assert.equal(status.body.state, "completed");
step("command status reconciled from the ledger");
console.log("PASS");
