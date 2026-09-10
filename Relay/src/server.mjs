import { createServer as createHttpServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig } from "./config.mjs";
import { Ledger } from "./ledger.mjs";
import { DeviceHub } from "./deviceHub.mjs";
import { createApi } from "./api.mjs";
import { createCounterFixture } from "./fixtures.mjs";

/** One process: device routing, ledger, agent API, and the counter fixture. */
export async function createRelay({ config, ledgerPath, log = () => {} }) {
  const ledger = new Ledger(ledgerPath ?? path.join(config.dataDir, "relay.sqlite"));
  const hub = new DeviceHub({ ledger, config, log });
  const fixture = createCounterFixture();
  const api = createApi({ ledger, hub, config, fixture, log });
  const server = createHttpServer((request, response) => {
    api(request, response).catch((error) => {
      log("unhandled", error);
      if (!response.headersSent) {
        response.writeHead(500);
      }
      response.end();
    });
  });

  server.on("upgrade", (request, socket, head) => {
    const url = new URL(request.url, "http://relay.local");
    if (url.pathname !== "/v1/device") {
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }
    const header = request.headers.authorization ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : null;
    const device = token ? ledger.deviceForToken(token) : null;
    if (!device) {
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }
    hub.accept(request, socket, head, device);
  });

  await new Promise((resolve) => server.listen(config.port, config.host, resolve));
  const address = server.address();

  return {
    server,
    hub,
    ledger,
    port: address.port,
    url: `http://${config.host === "0.0.0.0" ? "127.0.0.1" : config.host}:${address.port}`,
    async close() {
      hub.close();
      await new Promise((resolve) => server.close(resolve));
      ledger.close();
    },
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const config = loadConfig();
  const relay = await createRelay({ config, log: (...args) => console.error(new Date().toISOString(), ...args) });
  console.error(`phone-browser relay listening on ${relay.url} (device socket: /v1/device)`);
  const shutdown = async () => {
    await relay.close();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}
