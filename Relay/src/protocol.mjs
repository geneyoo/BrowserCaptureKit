import { createHash, randomUUID } from "node:crypto";

export const PROTOCOL_VERSION = 1;

export const TERMINAL_STATES = new Set(["completed", "rejected", "cancelled", "uncertain", "notStarted", "expired"]);
export const ACT_KINDS = new Set(["tap", "fill"]);
const MAX_FILL_TEXT = 4096;

export class ProtocolError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/** Stable JSON: sorted keys, no whitespace. Used for payload digests. */
export function canonicalJSON(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJSON).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function digest(value) {
  return createHash("sha256").update(canonicalJSON(value)).digest("hex");
}

export function newCommandId() {
  return `cmd_${randomUUID()}`;
}

/** Validates an agent-supplied operation into the typed shape the device accepts. */
export function normalizeOperation(input) {
  if (!input || typeof input !== "object" || typeof input.kind !== "string") {
    throw new ProtocolError(400, "operation.kind is required");
  }
  switch (input.kind) {
    case "observe": {
      const maxElements = input.maxElements === undefined ? 120 : Number(input.maxElements);
      if (!Number.isInteger(maxElements) || maxElements < 1 || maxElements > 500) {
        throw new ProtocolError(400, "observe.maxElements must be an integer in 1..500");
      }
      return { kind: "observe", includeImage: Boolean(input.includeImage), maxElements };
    }
    case "navigate": {
      let url;
      try {
        url = new URL(String(input.url));
      } catch {
        throw new ProtocolError(400, "navigate.url must be an absolute URL");
      }
      if (url.protocol !== "http:" && url.protocol !== "https:") {
        throw new ProtocolError(400, "navigate.url must use http or https");
      }
      return { kind: "navigate", url: url.toString() };
    }
    case "act": {
      const action = input.action ?? {};
      if (!ACT_KINDS.has(action.kind)) {
        throw new ProtocolError(400, `act.action.kind must be one of ${[...ACT_KINDS].join(", ")}`);
      }
      if (typeof action.observationId !== "string" || !action.observationId) {
        throw new ProtocolError(400, "act.action.observationId is required");
      }
      if (typeof action.elementId !== "string" || !action.elementId) {
        throw new ProtocolError(400, "act.action.elementId is required");
      }
      const normalized = { kind: action.kind, observationId: action.observationId, elementId: action.elementId };
      if (action.kind === "fill") {
        if (typeof action.text !== "string") {
          throw new ProtocolError(400, "act.action.text is required for fill");
        }
        if (action.text.length > MAX_FILL_TEXT) {
          throw new ProtocolError(413, `act.action.text exceeds ${MAX_FILL_TEXT} characters`);
        }
        normalized.text = action.text;
      }
      return { kind: "act", action: normalized };
    }
    case "events": {
      const afterSequence = input.afterSequence === undefined ? 0 : Number(input.afterSequence);
      const limit = input.limit === undefined ? 100 : Number(input.limit);
      if (!Number.isInteger(afterSequence) || afterSequence < 0) {
        throw new ProtocolError(400, "events.afterSequence must be a non-negative integer");
      }
      if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
        throw new ProtocolError(400, "events.limit must be an integer in 1..500");
      }
      return { kind: "events", afterSequence, limit };
    }
    case "commandStatus": {
      if (typeof input.commandId !== "string" || !input.commandId) {
        throw new ProtocolError(400, "commandStatus.commandId is required");
      }
      return { kind: "commandStatus", commandId: input.commandId };
    }
    default:
      throw new ProtocolError(400, `unsupported operation kind '${input.kind}'`);
  }
}

/** Validates a device → service message. Returns null for anything unusable. */
export function parseDeviceMessage(text) {
  let message;
  try {
    message = JSON.parse(text);
  } catch {
    return null;
  }
  if (!message || typeof message !== "object" || typeof message.type !== "string") {
    return null;
  }
  switch (message.type) {
    case "hello":
      if (message.protocolVersion !== PROTOCOL_VERSION) {
        return { type: "protocolMismatch", protocolVersion: message.protocolVersion };
      }
      if (typeof message.deviceId !== "string" || typeof message.sessionId !== "string") {
        return null;
      }
      return message;
    case "receipt":
    case "result":
      if (typeof message.commandId !== "string") {
        return null;
      }
      return message;
    case "status":
      if (typeof message.sessionId !== "string") {
        return null;
      }
      return message;
    default:
      return { type: "unknown", original: message.type };
  }
}
