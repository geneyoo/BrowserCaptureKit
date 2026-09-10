import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { loadConfig } from "../src/config.mjs";
import { createRelay } from "../src/server.mjs";
import { canonicalJSON, digest, normalizeOperation } from "../src/protocol.mjs";

const AGENT_TOKEN = "agent-secret";

function config(overrides = {}) {
  return loadConfig(
    { AGENT_TOKEN, PORT: "0", HOST: "127.0.0.1", READINESS_TTL_MS: "400", HEARTBEAT_INTERVAL_MS: "100", DEFAULT_COMMAND_TIMEOUT_MS: "3000" },
    overrides,
  );
}

async function api(relay, method, path, body, token = AGENT_TOKEN) {
  const response = await fetch(`${relay.url}${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: response.status, body: await response.json().catch(() => null) };
}

/** Minimal simulated phone: speaks the device protocol and lets tests script replies. */
class FakeDevice {
  constructor(relay, token, { sessionId = "session-1", generation = 1, deviceId } = {}) {
    this.relay = relay;
    this.token = token;
    this.deviceId = deviceId;
    this.sessionId = sessionId;
    this.generation = generation;
    this.inbound = [];
    this.waiters = [];
    this.onCommand = null;
    this.journal = new Map();
  }

  async connect({ readiness = "ready" } = {}) {
    const url = this.relay.url.replace("http", "ws") + "/v1/device";
    this.ws = new WebSocket(url, { headers: { authorization: `Bearer ${this.token}` } });
    await new Promise((resolve, reject) => {
      this.ws.addEventListener("open", resolve, { once: true });
      this.ws.addEventListener("error", reject, { once: true });
    });
    this.ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      this.inbound.push(message);
      this.waiters = this.waiters.filter((waiter) => !waiter(message));
      if (message.type === "command" && this.onCommand) {
        this.onCommand(message);
      }
    });
    this.send({
      type: "hello",
      protocolVersion: 1,
      deviceId: this.deviceId,
      sessionId: this.sessionId,
      processInstanceId: "proc-1",
      appVersion: "0.1.0",
      osVersion: "26.0",
      libraryVersion: "0.1.4",
      controllerGeneration: this.generation,
      readiness,
      eventCursor: 0,
      capabilities: { operations: ["observe"] },
    });
    await this.next((message) => message.type === "helloAck");
  }

  send(message) {
    this.ws.send(JSON.stringify(message));
  }

  status(readiness = "ready", extra = {}) {
    this.send({
      type: "status",
      readiness,
      sessionId: this.sessionId,
      controllerGeneration: this.generation,
      humanControl: false,
      foreground: true,
      eventCursor: 0,
      ...extra,
    });
  }

  next(predicate) {
    const found = this.inbound.find(predicate);
    if (found) {
      return Promise.resolve(found);
    }
    return new Promise((resolve) => {
      this.waiters.push((message) => {
        if (predicate(message)) {
          resolve(message);
          return true;
        }
        return false;
      });
    });
  }

  close() {
    return new Promise((resolve) => {
      this.ws.addEventListener("close", () => resolve(), { once: true });
      this.ws.close();
    });
  }
}

async function pairDevice(relay) {
  const { body: pairing } = await api(relay, "POST", "/v1/pairings");
  const { status, body } = await api(relay, "POST", "/v1/pair", { code: pairing.code, deviceName: "Test iPhone" }, null);
  assert.equal(status, 201);
  return body;
}

describe("protocol helpers", () => {
  it("canonicalizes JSON independent of key order", () => {
    assert.equal(canonicalJSON({ b: 1, a: [{ d: 2, c: 3 }] }), '{"a":[{"c":3,"d":2}],"b":1}');
    assert.equal(digest({ b: 1, a: 2 }), digest({ a: 2, b: 1 }));
  });

  it("validates operations", () => {
    assert.deepEqual(normalizeOperation({ kind: "observe" }), { kind: "observe", includeImage: false, maxElements: 120 });
    assert.throws(() => normalizeOperation({ kind: "navigate", url: "javascript:alert(1)" }), /http or https/);
    assert.throws(() => normalizeOperation({ kind: "evaluateJavaScript" }), /unsupported operation/);
    assert.throws(() => normalizeOperation({ kind: "act", action: { kind: "tap", observationId: "o" } }), /elementId/);
    assert.throws(() => normalizeOperation({ kind: "act", action: { kind: "fill", observationId: "o", elementId: "e", text: "x".repeat(5000) } }), /exceeds/);
  });
});

describe("relay", () => {
  let relay;
  before(async () => {
    relay = await createRelay({ config: config(), ledgerPath: ":memory:" });
  });
  after(async () => {
    await relay.close();
  });

  it("requires the agent token and pairs a device with a one-time code", async () => {
    assert.equal((await api(relay, "GET", "/v1/devices", undefined, null)).status, 401);
    const { body: pairing } = await api(relay, "POST", "/v1/pairings");
    assert.match(pairing.code, /^\d{6}$/);
    const first = await api(relay, "POST", "/v1/pair", { code: pairing.code, deviceName: "Phone" }, null);
    assert.equal(first.status, 201);
    assert.match(first.body.deviceToken, /^pbd_/);
    const reuse = await api(relay, "POST", "/v1/pair", { code: pairing.code, deviceName: "Phone" }, null);
    assert.equal(reuse.status, 403, "a pairing code is single use");
    const listed = await api(relay, "GET", "/v1/devices");
    const device = listed.body.devices.find((entry) => entry.deviceId === first.body.deviceId);
    assert.equal(device.connected, false);
    assert.equal(device.readiness, "disconnected");
  });

  it("rejects device sockets without a valid credential", async () => {
    const url = relay.url.replace("http", "ws") + "/v1/device";
    const ws = new WebSocket(url, { headers: { authorization: "Bearer nope" } });
    const outcome = await new Promise((resolve) => {
      ws.addEventListener("error", () => resolve("error"), { once: true });
      ws.addEventListener("open", () => resolve("open"), { once: true });
    });
    assert.equal(outcome, "error");
  });

  it("routes a command to the device, records receipt and result, and dedups by command id", async () => {
    const paired = await pairDevice(relay);
    const device = new FakeDevice(relay, paired.deviceToken, { deviceId: paired.deviceId });
    await device.connect();
    let executions = 0;
    device.onCommand = (command) => {
      executions += 1;
      device.send({ type: "receipt", commandId: command.commandId, accepted: true, state: "accepted" });
      device.send({
        type: "result",
        commandId: command.commandId,
        state: "completed",
        retryClassification: "safe",
        payload: { kind: "observation", observation: { observationId: "obs-1", elements: [] } },
      });
    };

    const listed = await api(relay, "GET", `/v1/devices/${paired.deviceId}`);
    assert.equal(listed.body.readiness, "ready");
    assert.equal(listed.body.sessionId, "session-1");

    const submitted = await api(relay, "POST", `/v1/devices/${paired.deviceId}/commands`, {
      commandId: "cmd-fixed",
      operation: { kind: "observe" },
    });
    assert.equal(submitted.status, 200);
    assert.equal(submitted.body.state, "completed");
    assert.equal(submitted.body.result.payload.observation.observationId, "obs-1");
    assert.equal(submitted.body.sessionId, "session-1");
    assert.equal(submitted.body.controllerGeneration, 1);

    const again = await api(relay, "POST", `/v1/devices/${paired.deviceId}/commands`, {
      commandId: "cmd-fixed",
      operation: { kind: "observe" },
    });
    assert.equal(again.status, 200);
    assert.deepEqual(again.body.result, submitted.body.result);
    assert.equal(executions, 1, "the ledger answers duplicates without re-sending");

    const reused = await api(relay, "POST", `/v1/devices/${paired.deviceId}/commands`, {
      commandId: "cmd-fixed",
      operation: { kind: "navigate", url: "https://example.com" },
    });
    assert.equal(reused.status, 409);

    const status = await api(relay, "GET", "/v1/commands/cmd-fixed");
    assert.equal(status.body.state, "completed");
    await device.close();
  });

  it("refuses commands while the device is not ready and expires readiness without heartbeats", async () => {
    const paired = await pairDevice(relay);
    const device = new FakeDevice(relay, paired.deviceToken, { deviceId: paired.deviceId });
    await device.connect({ readiness: "humanControl" });
    const refused = await api(relay, "POST", `/v1/devices/${paired.deviceId}/commands`, { operation: { kind: "observe" } });
    assert.equal(refused.status, 409);
    assert.match(refused.body.error, /humanControl/);

    device.status("ready");
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal((await api(relay, "GET", `/v1/devices/${paired.deviceId}`)).body.readiness, "ready");

    // Silence the phone: readiness must expire server-side even though the socket is open.
    const connection = relay.hub.connections.get(paired.deviceId);
    connection.lastSeen = Date.now() - 10_000;
    const stale = await api(relay, "GET", `/v1/devices/${paired.deviceId}`);
    assert.equal(stale.body.readiness, "stale");
    const staleRefused = await api(relay, "POST", `/v1/devices/${paired.deviceId}/commands`, { operation: { kind: "observe" } });
    assert.equal(staleRefused.status, 409);
    await device.close();
  });

  it("reconciles unresolved commands on reconnect: unknown becomes notStarted, results are recovered", async () => {
    const paired = await pairDevice(relay);
    const device = new FakeDevice(relay, paired.deviceToken, { deviceId: paired.deviceId });
    await device.connect();
    // Device goes quiet after acceptance: the relay never sees a result.
    device.onCommand = (command) => {
      device.send({ type: "receipt", commandId: command.commandId, accepted: true, state: "accepted" });
    };
    const pending = api(relay, "POST", `/v1/devices/${paired.deviceId}/commands`, {
      commandId: "cmd-lost",
      operation: { kind: "observe" },
      timeoutMs: 1000,
    });
    await device.next((message) => message.type === "command" && message.commandId === "cmd-lost");
    const timedOut = await pending;
    assert.equal(timedOut.status, 202);
    assert.equal(timedOut.body.state, "accepted");
    await device.close();

    // Another command was sent while nobody answered.
    const ghost = new FakeDevice(relay, paired.deviceToken, { deviceId: paired.deviceId });
    await ghost.connect();
    const ack = ghost.inbound.find((message) => message.type === "helloAck");
    assert.deepEqual(ack.unresolvedCommandIds, ["cmd-lost"]);
    ghost.send({
      type: "result",
      commandId: "cmd-lost",
      state: "uncertain",
      retryClassification: "unsafe",
      message: "process restarted after dispatch",
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal((await api(relay, "GET", "/v1/commands/cmd-lost")).body.state, "uncertain");

    const created = await api(relay, "POST", `/v1/devices/${paired.deviceId}/commands`, {
      commandId: "cmd-never-seen",
      operation: { kind: "observe" },
      timeoutMs: 1000,
    });
    assert.equal(created.status, 202);
    await ghost.close();

    const back = new FakeDevice(relay, paired.deviceToken, { deviceId: paired.deviceId });
    await back.connect();
    const ack2 = back.inbound.find((message) => message.type === "helloAck");
    assert.deepEqual(ack2.unresolvedCommandIds, ["cmd-never-seen"]);
    back.send({ type: "receipt", commandId: "cmd-never-seen", accepted: false, state: "rejected", reason: "unknownCommand" });
    await new Promise((resolve) => setTimeout(resolve, 50));
    const final = await api(relay, "GET", "/v1/commands/cmd-never-seen");
    assert.equal(final.body.state, "notStarted");
    assert.equal(final.body.terminal, true);
    await back.close();
  });

  it("forwards cancel, revokes credentials, and serves the counter fixture", async () => {
    const paired = await pairDevice(relay);
    const device = new FakeDevice(relay, paired.deviceToken, { deviceId: paired.deviceId });
    await device.connect();
    device.onCommand = (command) => {
      device.send({ type: "receipt", commandId: command.commandId, accepted: true, state: "accepted" });
    };
    const pending = api(relay, "POST", `/v1/devices/${paired.deviceId}/commands`, {
      commandId: "cmd-cancel",
      operation: { kind: "navigate", url: "https://example.com/" },
      timeoutMs: 2000,
    });
    await device.next((message) => message.type === "command" && message.commandId === "cmd-cancel");
    const cancelled = await api(relay, "DELETE", "/v1/commands/cmd-cancel");
    assert.equal(cancelled.status, 202);
    await device.next((message) => message.type === "cancel" && message.commandId === "cmd-cancel");
    device.send({ type: "result", commandId: "cmd-cancel", state: "cancelled", retryClassification: "notStarted", reason: "cancelled" });
    const settled = await pending;
    assert.equal(settled.body.state, "cancelled");

    const fixture = await fetch(`${relay.url}/fixtures/counter`);
    assert.match(await fixture.text(), /Submissions: 0/);
    const submit = await fetch(`${relay.url}/fixtures/counter/submit`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "note=hello",
      redirect: "manual",
    });
    assert.equal(submit.status, 303);
    const state = await (await fetch(`${relay.url}/fixtures/counter/state`)).json();
    assert.deepEqual(state, { count: 1, lastNote: "hello" });

    const revoked = await api(relay, "POST", `/v1/devices/${paired.deviceId}/revoke`);
    assert.equal(revoked.status, 200);
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal((await api(relay, "GET", `/v1/devices/${paired.deviceId}`)).body.connected, false);
    const retry = new FakeDevice(relay, paired.deviceToken, { deviceId: paired.deviceId });
    await assert.rejects(retry.connect(), "a revoked credential cannot reconnect");
  });
});
