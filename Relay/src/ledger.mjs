import { DatabaseSync } from "node:sqlite";
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync } from "node:fs";
import path from "node:path";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE TABLE IF NOT EXISTS pairings (
  code TEXT PRIMARY KEY NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at INTEGER
);
CREATE TABLE IF NOT EXISTS commands (
  command_id TEXT PRIMARY KEY NOT NULL,
  device_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  controller_generation INTEGER NOT NULL,
  operation_json TEXT NOT NULL,
  digest TEXT NOT NULL,
  state TEXT NOT NULL,
  issued_at INTEGER NOT NULL,
  deadline INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  receipt_json TEXT,
  result_json TEXT
);
CREATE INDEX IF NOT EXISTS commands_device_state ON commands (device_id, state);
`;

export function hashToken(token) {
  return createHash("sha256").update(token).digest("hex");
}

/** Durable service-side ledger: devices, pairing codes, and the command record. */
export class Ledger {
  constructor(filePath) {
    if (filePath !== ":memory:") {
      mkdirSync(path.dirname(filePath), { recursive: true });
    }
    this.db = new DatabaseSync(filePath);
    this.db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL;");
    this.db.exec(SCHEMA);
  }

  close() {
    this.db.close();
  }

  // Pairing

  createPairingCode(ttlMs, now = Date.now()) {
    for (let attempt = 0; attempt < 10; attempt += 1) {
      const code = String(randomBytes(4).readUInt32BE(0) % 1_000_000).padStart(6, "0");
      try {
        this.db
          .prepare("INSERT INTO pairings (code, created_at, expires_at) VALUES (?, ?, ?)")
          .run(code, now, now + ttlMs);
        return { code, expiresAt: new Date(now + ttlMs).toISOString() };
      } catch (error) {
        if (!String(error.message).includes("UNIQUE")) {
          throw error;
        }
      }
    }
    throw new Error("could not allocate a pairing code");
  }

  /** Consumes a code atomically and registers the device. Returns null when the code is invalid. */
  redeemPairingCode(code, name, now = Date.now()) {
    const consumed = this.db
      .prepare("UPDATE pairings SET used_at = ? WHERE code = ? AND used_at IS NULL AND expires_at > ?")
      .run(now, code, now);
    if (consumed.changes !== 1) {
      return null;
    }
    const deviceId = `dev_${randomBytes(6).toString("hex")}`;
    const token = `pbd_${randomBytes(32).toString("base64url")}`;
    this.db
      .prepare("INSERT INTO devices (device_id, name, token_hash, created_at) VALUES (?, ?, ?, ?)")
      .run(deviceId, name, hashToken(token), now);
    return { deviceId, deviceToken: token };
  }

  deviceForToken(token) {
    const row = this.db
      .prepare("SELECT device_id, name, revoked_at FROM devices WHERE token_hash = ?")
      .get(hashToken(token));
    if (!row || row.revoked_at) {
      return null;
    }
    return { deviceId: row.device_id, name: row.name };
  }

  listDevices() {
    return this.db
      .prepare("SELECT device_id, name, created_at, revoked_at FROM devices ORDER BY created_at")
      .all()
      .map((row) => ({
        deviceId: row.device_id,
        name: row.name,
        createdAt: new Date(row.created_at).toISOString(),
        revoked: Boolean(row.revoked_at),
      }));
  }

  revokeDevice(deviceId, now = Date.now()) {
    return this.db.prepare("UPDATE devices SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL").run(now, deviceId)
      .changes === 1;
  }

  // Commands

  insertCommand(command, now = Date.now()) {
    this.db
      .prepare(
        `INSERT INTO commands (command_id, device_id, session_id, controller_generation, operation_json, digest, state,
           issued_at, deadline, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        command.commandId,
        command.deviceId,
        command.sessionId,
        command.controllerGeneration,
        JSON.stringify(command.operation),
        command.digest,
        command.state,
        Date.parse(command.issuedAt),
        Date.parse(command.deadline),
        now,
      );
  }

  updateCommandState(commandId, state, { receipt, result } = {}, now = Date.now()) {
    const sets = ["state = ?", "updated_at = ?"];
    const values = [state, now];
    if (receipt !== undefined) {
      sets.push("receipt_json = ?");
      values.push(JSON.stringify(receipt));
    }
    if (result !== undefined) {
      sets.push("result_json = ?");
      values.push(JSON.stringify(result));
    }
    values.push(commandId);
    return this.db.prepare(`UPDATE commands SET ${sets.join(", ")} WHERE command_id = ?`).run(...values).changes === 1;
  }

  command(commandId) {
    const row = this.db.prepare("SELECT * FROM commands WHERE command_id = ?").get(commandId);
    return row ? rowToCommand(row) : null;
  }

  unresolvedCommands(deviceId) {
    return this.db
      .prepare("SELECT * FROM commands WHERE device_id = ? AND state IN ('sent', 'accepted', 'dispatching') ORDER BY issued_at")
      .all(deviceId)
      .map(rowToCommand);
  }
}

function rowToCommand(row) {
  return {
    commandId: row.command_id,
    deviceId: row.device_id,
    sessionId: row.session_id,
    controllerGeneration: row.controller_generation,
    operation: JSON.parse(row.operation_json),
    digest: row.digest,
    state: row.state,
    issuedAt: new Date(row.issued_at).toISOString(),
    deadline: new Date(row.deadline).toISOString(),
    updatedAt: new Date(row.updated_at).toISOString(),
    receipt: row.receipt_json ? JSON.parse(row.receipt_json) : null,
    result: row.result_json ? JSON.parse(row.result_json) : null,
  };
}
