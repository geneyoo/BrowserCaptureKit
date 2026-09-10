import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

/**
 * Thin MCP adapter over the relay HTTP API. It maps tool calls one-to-one
 * onto typed operations and never reinterprets results.
 */
const relayUrl = (process.env.RELAY_URL ?? "http://127.0.0.1:8787").replace(/\/$/, "");
const agentToken = process.env.AGENT_TOKEN;
const defaultDeviceId = process.env.DEVICE_ID;
if (!agentToken) {
  console.error("AGENT_TOKEN is required");
  process.exit(2);
}

async function relay(method, path, body) {
  const response = await fetch(`${relayUrl}${path}`, {
    method,
    headers: { authorization: `Bearer ${agentToken}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    value = { error: text };
  }
  if (!response.ok && !(response.status === 202)) {
    throw new Error(`${response.status}: ${value.error ?? text}`);
  }
  return value;
}

async function resolveDeviceId(deviceId) {
  if (deviceId) {
    return deviceId;
  }
  if (defaultDeviceId) {
    return defaultDeviceId;
  }
  const { devices } = await relay("GET", "/v1/devices");
  const ready = devices.filter((device) => device.connected && !device.revoked);
  if (ready.length !== 1) {
    throw new Error(`deviceId is required: ${ready.length} connected devices`);
  }
  return ready[0].deviceId;
}

async function command(deviceId, operation, timeoutMs) {
  const id = await resolveDeviceId(deviceId);
  return relay("POST", `/v1/devices/${encodeURIComponent(id)}/commands`, { operation, timeoutMs });
}

function textResult(value) {
  return { content: [{ type: "text", text: JSON.stringify(value, null, 2) }] };
}

function observationResult(view) {
  const observation = view.result?.payload?.observation;
  const content = [];
  if (observation?.image?.base64) {
    content.push({ type: "image", data: observation.image.base64, mimeType: "image/jpeg" });
    observation.image = { ...observation.image, base64: `[${observation.image.base64.length} base64 chars, returned as image content]` };
  }
  content.push({ type: "text", text: JSON.stringify(view, null, 2) });
  return { content };
}

const server = new McpServer({ name: "phone-browser", version: "0.1.0" });
const deviceIdSchema = z.string().optional().describe("Paired device ID; optional when exactly one device is connected.");
const timeoutSchema = z.number().int().min(1000).max(120000).optional().describe("Command deadline in milliseconds.");

server.registerTool(
  "phone_browser_devices",
  { description: "List paired phones with connection, readiness, session, controller generation, and capabilities.", inputSchema: {} },
  async () => textResult(await relay("GET", "/v1/devices")),
);

server.registerTool(
  "phone_browser_observe",
  {
    description:
      "Observe the phone's current page: sanitized URL/title, bounded elements with stable IDs, optional viewport image, event cursor, and coverage notes. Element actions must reference the returned observationId.",
    inputSchema: {
      deviceId: deviceIdSchema,
      includeImage: z.boolean().optional().describe("Include a JPEG of the web view viewport (omitted when a sensitive field is visible)."),
      maxElements: z.number().int().min(1).max(500).optional(),
      timeoutMs: timeoutSchema,
    },
  },
  async ({ deviceId, includeImage, maxElements, timeoutMs }) =>
    observationResult(await command(deviceId, { kind: "observe", includeImage: includeImage ?? false, maxElements: maxElements ?? 120 }, timeoutMs)),
);

server.registerTool(
  "phone_browser_navigate",
  {
    description: "Navigate the phone browser to an http(s) URL and wait for the navigation to finish (30 s cap on the device).",
    inputSchema: { deviceId: deviceIdSchema, url: z.string().url(), timeoutMs: timeoutSchema },
  },
  async ({ deviceId, url, timeoutMs }) => textResult(await command(deviceId, { kind: "navigate", url }, timeoutMs)),
);

server.registerTool(
  "phone_browser_act",
  {
    description:
      "Tap or fill one element bound to a prior observation. Stale, replaced, ambiguous, obscured, sensitive, or activation-gated targets fail closed; an 'uncertain' state means re-observe before retrying.",
    inputSchema: {
      deviceId: deviceIdSchema,
      kind: z.enum(["tap", "fill"]),
      observationId: z.string(),
      elementId: z.string(),
      text: z.string().max(4096).optional().describe("Text for fill."),
      timeoutMs: timeoutSchema,
    },
  },
  async ({ deviceId, kind, observationId, elementId, text, timeoutMs }) =>
    textResult(await command(deviceId, { kind: "act", action: { kind, observationId, elementId, text } }, timeoutMs)),
);

server.registerTool(
  "phone_browser_events",
  {
    description: "Fetch sanitized evidence events (page, network metadata, actions, dialogs, lifecycle) after a cursor, with explicit gap and truncation flags.",
    inputSchema: {
      deviceId: deviceIdSchema,
      afterSequence: z.number().int().min(0).optional(),
      limit: z.number().int().min(1).max(500).optional(),
      timeoutMs: timeoutSchema,
    },
  },
  async ({ deviceId, afterSequence, limit, timeoutMs }) =>
    textResult(await command(deviceId, { kind: "events", afterSequence: afterSequence ?? 0, limit: limit ?? 100 }, timeoutMs)),
);

server.registerTool(
  "phone_browser_command_status",
  {
    description: "Reconcile a prior command from the relay ledger without executing anything.",
    inputSchema: { commandId: z.string() },
  },
  async ({ commandId }) => textResult(await relay("GET", `/v1/commands/${encodeURIComponent(commandId)}`)),
);

await server.connect(new StdioServerTransport());
