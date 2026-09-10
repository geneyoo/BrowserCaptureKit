import { EventEmitter } from "node:events";
import { WebSocketServer } from "ws";
import { PROTOCOL_VERSION, TERMINAL_STATES, parseDeviceMessage } from "./protocol.mjs";

/**
 * Owns device sockets. One active socket per device; a newer connection
 * replaces an older one. Readiness expires server-side when heartbeats stop,
 * so a suspended phone is never listed ready. Command routing runs through
 * `sendCommand`; results and receipts land in the ledger before waiters see them.
 */
export class DeviceHub extends EventEmitter {
  constructor({ ledger, config, log = () => {} }) {
    super();
    this.ledger = ledger;
    this.config = config;
    this.log = log;
    this.connections = new Map(); // deviceId -> connection
    this.wss = new WebSocketServer({ noServer: true, maxPayload: config.maxMessageBytes });
  }

  /** Called from the HTTP upgrade handler after bearer authentication. */
  accept(request, socket, head, device) {
    this.wss.handleUpgrade(request, socket, head, (ws) => this.#attach(ws, device));
  }

  close() {
    for (const connection of this.connections.values()) {
      clearInterval(connection.heartbeat);
      connection.ws.close(1001, "server shutdown");
    }
    this.connections.clear();
    this.wss.close();
  }

  snapshot(deviceId, now = Date.now()) {
    const connection = this.connections.get(deviceId);
    if (!connection) {
      return { connected: false, readiness: "disconnected" };
    }
    const heartbeatFresh = now - connection.lastSeen <= this.config.readinessTtlMs;
    const deviceReadiness = connection.status?.readiness ?? connection.hello?.readiness ?? "connecting";
    return {
      connected: true,
      readiness: heartbeatFresh ? deviceReadiness : "stale",
      sessionId: connection.status?.sessionId ?? connection.hello?.sessionId ?? null,
      controllerGeneration: connection.status?.controllerGeneration ?? connection.hello?.controllerGeneration ?? null,
      humanControl: connection.status?.humanControl ?? null,
      foreground: connection.status?.foreground ?? null,
      activeCommandId: connection.status?.activeCommandId ?? null,
      pageUrl: connection.status?.pageUrl ?? null,
      eventCursor: connection.status?.eventCursor ?? connection.hello?.eventCursor ?? null,
      capabilities: connection.hello?.capabilities ?? null,
      appVersion: connection.hello?.appVersion ?? null,
      osVersion: connection.hello?.osVersion ?? null,
      processInstanceId: connection.hello?.processInstanceId ?? null,
      lastSeenAt: new Date(connection.lastSeen).toISOString(),
    };
  }

  /** Sends a command that is already in the ledger as `created`. */
  sendCommand(command) {
    const connection = this.connections.get(command.deviceId);
    if (!connection || !connection.hello) {
      return false;
    }
    connection.ws.send(
      JSON.stringify({
        type: "command",
        commandId: command.commandId,
        sessionId: command.sessionId,
        controllerGeneration: command.controllerGeneration,
        issuedAt: command.issuedAt,
        deadline: command.deadline,
        operation: command.operation,
      }),
    );
    this.ledger.updateCommandState(command.commandId, "sent");
    return true;
  }

  sendCancel(deviceId, commandId) {
    const connection = this.connections.get(deviceId);
    if (!connection) {
      return false;
    }
    connection.ws.send(JSON.stringify({ type: "cancel", commandId }));
    return true;
  }

  #attach(ws, device) {
    const previous = this.connections.get(device.deviceId);
    if (previous) {
      clearInterval(previous.heartbeat);
      previous.ws.close(4000, "replaced by a newer connection");
    }
    const connection = { ws, device, hello: null, status: null, lastSeen: Date.now(), heartbeat: null };
    this.connections.set(device.deviceId, connection);

    connection.heartbeat = setInterval(() => {
      if (Date.now() - connection.lastSeen > this.config.readinessTtlMs * 2) {
        ws.terminate();
        return;
      }
      if (ws.readyState === ws.OPEN) {
        ws.ping();
      }
    }, this.config.heartbeatIntervalMs);

    ws.on("pong", () => {
      connection.lastSeen = Date.now();
    });
    ws.on("message", (data) => {
      connection.lastSeen = Date.now();
      this.#handle(connection, data.toString());
    });
    ws.on("close", () => {
      clearInterval(connection.heartbeat);
      if (this.connections.get(device.deviceId) === connection) {
        this.connections.delete(device.deviceId);
      }
      this.emit("device:disconnected", device.deviceId);
    });
    ws.on("error", (error) => this.log("socket error", device.deviceId, error.message));
  }

  #handle(connection, text) {
    const message = parseDeviceMessage(text);
    const deviceId = connection.device.deviceId;
    if (!message) {
      this.log("dropping unparseable device message", deviceId);
      return;
    }
    switch (message.type) {
      case "protocolMismatch":
        connection.ws.close(4001, `protocol ${PROTOCOL_VERSION} required`);
        return;
      case "unknown":
        this.log("ignoring unknown device message", deviceId, message.original);
        return;
      case "hello": {
        if (message.deviceId !== deviceId) {
          connection.ws.close(4003, "device id does not match credential");
          return;
        }
        connection.hello = message;
        connection.status = null;
        const unresolved = this.ledger.unresolvedCommands(deviceId);
        connection.ws.send(
          JSON.stringify({
            type: "helloAck",
            serverTime: new Date().toISOString(),
            unresolvedCommandIds: unresolved.map((command) => command.commandId),
          }),
        );
        this.emit("device:hello", deviceId, message);
        return;
      }
      case "status":
        connection.status = message;
        this.emit("device:status", deviceId, message);
        return;
      case "receipt":
        this.#recordReceipt(deviceId, message);
        return;
      case "result":
        this.#recordResult(deviceId, message);
        return;
      default:
        return;
    }
  }

  #recordReceipt(deviceId, receipt) {
    const command = this.ledger.command(receipt.commandId);
    if (!command || command.deviceId !== deviceId) {
      this.log("receipt for unknown command", receipt.commandId);
      return;
    }
    if (TERMINAL_STATES.has(command.state)) {
      return;
    }
    let state;
    if (receipt.accepted) {
      state = receipt.state === "dispatching" ? "dispatching" : "accepted";
    } else if (receipt.reason === "unknownCommand") {
      // The device never accepted it: safe to re-issue under a new command ID.
      state = "notStarted";
    } else {
      state = "rejected";
    }
    this.ledger.updateCommandState(receipt.commandId, state, { receipt });
    this.emit("command:update", receipt.commandId, state);
  }

  #recordResult(deviceId, result) {
    const command = this.ledger.command(result.commandId);
    if (!command || command.deviceId !== deviceId) {
      this.log("result for unknown command", result.commandId);
      return;
    }
    if (TERMINAL_STATES.has(command.state) && command.result) {
      return;
    }
    const state = TERMINAL_STATES.has(result.state) ? result.state : "uncertain";
    this.ledger.updateCommandState(result.commandId, state, { result });
    this.emit("command:update", result.commandId, state);
  }
}
