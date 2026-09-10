export function loadConfig(env = process.env, overrides = {}) {
  const config = {
    port: Number(env.PORT ?? 8787),
    host: env.HOST ?? "0.0.0.0",
    agentToken: env.AGENT_TOKEN ?? "",
    dataDir: env.DATA_DIR ?? "./data",
    readinessTtlMs: Number(env.READINESS_TTL_MS ?? 45_000),
    heartbeatIntervalMs: Number(env.HEARTBEAT_INTERVAL_MS ?? 15_000),
    pairingTtlMs: Number(env.PAIRING_TTL_MS ?? 10 * 60_000),
    defaultCommandTimeoutMs: Number(env.DEFAULT_COMMAND_TIMEOUT_MS ?? 45_000),
    maxCommandTimeoutMs: Number(env.MAX_COMMAND_TIMEOUT_MS ?? 120_000),
    maxMessageBytes: Number(env.MAX_MESSAGE_BYTES ?? 8 * 1024 * 1024),
    ...overrides,
  };
  if (!config.agentToken) {
    throw new Error("AGENT_TOKEN is required: agents authenticate with it and it must not be empty.");
  }
  return config;
}
