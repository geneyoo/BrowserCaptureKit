import { TERMINAL_STATES, ProtocolError, digest, newCommandId, normalizeOperation } from "./protocol.mjs";

/**
 * Agent-facing HTTP API. Every route except pairing redemption and fixtures
 * requires the agent bearer token. Command submission waits for a terminal
 * result up to the deadline, then returns the current ledger state.
 */
export function createApi({ ledger, hub, config, fixture, log = () => {} }) {
  const waiters = new Map(); // commandId -> Set<resolve>

  hub.on("command:update", (commandId, state) => {
    if (!TERMINAL_STATES.has(state)) {
      return;
    }
    const set = waiters.get(commandId);
    if (set) {
      waiters.delete(commandId);
      for (const resolve of set) {
        resolve();
      }
    }
  });

  function waitForTerminal(commandId, timeoutMs) {
    return new Promise((resolve) => {
      const existing = ledger.command(commandId);
      if (!existing || TERMINAL_STATES.has(existing.state)) {
        resolve();
        return;
      }
      const timer = setTimeout(() => {
        waiters.get(commandId)?.delete(done);
        resolve();
      }, timeoutMs);
      const done = () => {
        clearTimeout(timer);
        resolve();
      };
      if (!waiters.has(commandId)) {
        waiters.set(commandId, new Set());
      }
      waiters.get(commandId).add(done);
    });
  }

  function agentAuthorized(request) {
    const header = request.headers.authorization ?? "";
    return header === `Bearer ${config.agentToken}`;
  }

  function deviceView(row) {
    return { ...row, ...hub.snapshot(row.deviceId) };
  }

  function commandView(command) {
    return {
      commandId: command.commandId,
      deviceId: command.deviceId,
      sessionId: command.sessionId,
      controllerGeneration: command.controllerGeneration,
      operation: command.operation,
      state: command.state,
      terminal: TERMINAL_STATES.has(command.state),
      issuedAt: command.issuedAt,
      deadline: command.deadline,
      updatedAt: command.updatedAt,
      receipt: command.receipt,
      result: command.result,
    };
  }

  async function submitCommand(deviceId, input) {
    const operation = normalizeOperation(input.operation);
    const snapshot = hub.snapshot(deviceId);
    if (!snapshot.connected) {
      throw new ProtocolError(409, "device is not connected");
    }
    if (!["ready", "executing"].includes(snapshot.readiness)) {
      throw new ProtocolError(409, `device is not ready: ${snapshot.readiness}`);
    }
    const sessionId = input.sessionId ?? snapshot.sessionId;
    if (!sessionId) {
      throw new ProtocolError(409, "device session is unknown; wait for hello");
    }
    if (input.sessionId && input.sessionId !== snapshot.sessionId) {
      throw new ProtocolError(409, `session ${input.sessionId} is not the device's live session ${snapshot.sessionId}`);
    }
    const controllerGeneration = input.controllerGeneration ?? snapshot.controllerGeneration;
    const timeoutMs = Math.min(Number(input.timeoutMs ?? config.defaultCommandTimeoutMs), config.maxCommandTimeoutMs);
    if (!Number.isFinite(timeoutMs) || timeoutMs < 1000) {
      throw new ProtocolError(400, "timeoutMs must be at least 1000");
    }
    const commandId = typeof input.commandId === "string" && input.commandId ? input.commandId : newCommandId();
    const existing = ledger.command(commandId);
    const operationDigest = digest(operation);
    if (existing) {
      if (existing.digest !== operationDigest || existing.deviceId !== deviceId) {
        throw new ProtocolError(409, "commandId was already used with a different operation");
      }
      if (!TERMINAL_STATES.has(existing.state)) {
        await waitForTerminal(commandId, timeoutMs);
      }
      return commandView(ledger.command(commandId));
    }
    const now = Date.now();
    const command = {
      commandId,
      deviceId,
      sessionId,
      controllerGeneration,
      operation,
      digest: operationDigest,
      state: "created",
      issuedAt: new Date(now).toISOString(),
      deadline: new Date(now + timeoutMs).toISOString(),
    };
    ledger.insertCommand(command);
    if (!hub.sendCommand(command)) {
      ledger.updateCommandState(commandId, "notStarted", {
        receipt: { commandId, accepted: false, state: "rejected", reason: "notReady", message: "device disconnected before send" },
      });
      throw new ProtocolError(409, "device disconnected before the command could be sent");
    }
    await waitForTerminal(commandId, timeoutMs);
    return commandView(ledger.command(commandId));
  }

  return async function handle(request, response) {
    const url = new URL(request.url, "http://relay.local");
    const body = await readBody(request, config.maxMessageBytes);
    try {
      if (fixture.handle(request, response, url, body)) {
        return;
      }
      if (request.method === "POST" && url.pathname === "/v1/pair") {
        const input = parseJSON(body);
        if (typeof input.code !== "string") {
          throw new ProtocolError(400, "code is required");
        }
        const paired = ledger.redeemPairingCode(input.code.trim(), String(input.deviceName ?? "iPhone").slice(0, 80));
        if (!paired) {
          throw new ProtocolError(403, "invalid or expired pairing code");
        }
        log("paired device", paired.deviceId);
        return json(response, 201, paired);
      }
      if (!agentAuthorized(request)) {
        throw new ProtocolError(401, "agent bearer token required");
      }
      if (request.method === "POST" && url.pathname === "/v1/pairings") {
        return json(response, 201, ledger.createPairingCode(config.pairingTtlMs));
      }
      if (request.method === "GET" && url.pathname === "/v1/devices") {
        return json(response, 200, { devices: ledger.listDevices().map(deviceView) });
      }
      let match = url.pathname.match(/^\/v1\/devices\/([^/]+)$/);
      if (match && request.method === "GET") {
        const row = ledger.listDevices().find((device) => device.deviceId === match[1]);
        if (!row) {
          throw new ProtocolError(404, "unknown device");
        }
        return json(response, 200, deviceView(row));
      }
      match = url.pathname.match(/^\/v1\/devices\/([^/]+)\/revoke$/);
      if (match && request.method === "POST") {
        if (!ledger.revokeDevice(match[1])) {
          throw new ProtocolError(404, "unknown or already revoked device");
        }
        hub.connections.get(match[1])?.ws.close(4002, "credential revoked");
        return json(response, 200, { deviceId: match[1], revoked: true });
      }
      match = url.pathname.match(/^\/v1\/devices\/([^/]+)\/commands$/);
      if (match && request.method === "POST") {
        const view = await submitCommand(match[1], parseJSON(body));
        return json(response, view.terminal ? 200 : 202, view);
      }
      match = url.pathname.match(/^\/v1\/commands\/([^/]+)$/);
      if (match && request.method === "GET") {
        const command = ledger.command(match[1]);
        if (!command) {
          throw new ProtocolError(404, "unknown command");
        }
        const waitMs = Number(url.searchParams.get("waitMs") ?? 0);
        if (waitMs > 0) {
          await waitForTerminal(match[1], Math.min(waitMs, config.maxCommandTimeoutMs));
        }
        return json(response, 200, commandView(ledger.command(match[1])));
      }
      if (match && request.method === "DELETE") {
        const command = ledger.command(match[1]);
        if (!command) {
          throw new ProtocolError(404, "unknown command");
        }
        if (!TERMINAL_STATES.has(command.state)) {
          hub.sendCancel(command.deviceId, command.commandId);
        }
        return json(response, 202, commandView(command));
      }
      throw new ProtocolError(404, "not found");
    } catch (error) {
      if (error instanceof ProtocolError) {
        return json(response, error.status, { error: error.message });
      }
      log("request failed", error);
      return json(response, 500, { error: "internal error" });
    }
  };
}

function json(response, status, value) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(value));
}

function parseJSON(body) {
  if (!body) {
    return {};
  }
  try {
    const value = JSON.parse(body);
    return value && typeof value === "object" ? value : {};
  } catch {
    throw new ProtocolError(400, "invalid JSON body");
  }
}

function readBody(request, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        request.destroy();
        reject(new ProtocolError(413, "body too large"));
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}
