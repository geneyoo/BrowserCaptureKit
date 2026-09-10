import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { after, before, describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { loadConfig } from "../src/config.mjs";
import { createRelay } from "../src/server.mjs";

const AGENT_TOKEN = "agent-secret";
const here = path.dirname(fileURLToPath(import.meta.url));

/** Minimal JSON-RPC client over the adapter's stdio (newline-delimited). */
class StdioClient {
  constructor(child) {
    this.child = child;
    this.nextId = 1;
    this.pending = new Map();
    let buffer = "";
    child.stdout.on("data", (chunk) => {
      buffer += chunk.toString();
      let index;
      while ((index = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (!line) continue;
        const message = JSON.parse(line);
        if (message.id !== undefined && this.pending.has(message.id)) {
          this.pending.get(message.id)(message);
          this.pending.delete(message.id);
        }
      }
    });
  }

  request(method, params) {
    const id = this.nextId++;
    return new Promise((resolve) => {
      this.pending.set(id, resolve);
      this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }

  notify(method, params) {
    this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  }
}

describe("mcp adapter", () => {
  let relay;
  let child;
  let client;

  before(async () => {
    relay = await createRelay({
      config: loadConfig({ AGENT_TOKEN, PORT: "0", HOST: "127.0.0.1" }),
      ledgerPath: ":memory:",
    });
    child = spawn(process.execPath, [path.join(here, "..", "src", "mcp.mjs")], {
      env: { ...process.env, RELAY_URL: relay.url, AGENT_TOKEN },
      stdio: ["pipe", "pipe", "inherit"],
    });
    client = new StdioClient(child);
  });

  after(async () => {
    child.kill();
    await relay.close();
  });

  it("initializes, lists the browser tools, and calls the relay through them", async () => {
    const initialized = await client.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "test", version: "0" },
    });
    assert.equal(initialized.result.serverInfo.name, "phone-browser");
    client.notify("notifications/initialized", {});

    const listed = await client.request("tools/list", {});
    const names = listed.result.tools.map((tool) => tool.name).sort();
    assert.deepEqual(names, [
      "phone_browser_act",
      "phone_browser_command_status",
      "phone_browser_devices",
      "phone_browser_events",
      "phone_browser_navigate",
      "phone_browser_observe",
    ]);
    const act = listed.result.tools.find((tool) => tool.name === "phone_browser_act");
    assert.deepEqual(act.inputSchema.properties.kind.enum, ["tap", "fill"]);
    assert.ok(act.inputSchema.required.includes("observationId"));
    assert.ok(act.inputSchema.required.includes("elementId"));

    const devices = await client.request("tools/call", { name: "phone_browser_devices", arguments: {} });
    assert.equal(devices.result.isError, undefined);
    assert.deepEqual(JSON.parse(devices.result.content[0].text), { devices: [] });

    // No connected device: the adapter reports the relay's refusal instead of inventing a result.
    const observe = await client.request("tools/call", { name: "phone_browser_observe", arguments: {} });
    assert.equal(observe.result.isError, true);
    assert.match(observe.result.content[0].text, /deviceId is required: 0 connected devices/);
  });
});
