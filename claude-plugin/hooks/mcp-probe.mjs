#!/usr/bin/env node
/**
 * MCP connectivity probe for the MoVP SessionStart hook.
 * Uses NDJSON transport (one JSON object per line) to match @movp/mcp-server.
 *
 * Exit codes:
 *   0 — MCP healthy (tools registered)
 *   1 — timeout or internal error (caller treats as "unknown", emits nothing)
 *   2 — MCP not configured or tools list empty (caller emits warning)
 */

import { spawn } from "child_process";
import { createInterface } from "readline";
import { readFileSync, existsSync } from "fs";
import { join } from "path";

const TIMEOUT_MS = 1800;

function readConfig() {
  const projectDir = process.argv[2] || process.cwd();
  const cfgPath = join(projectDir, ".mcp.json");
  if (!existsSync(cfgPath)) return null;
  try {
    const cfg = JSON.parse(readFileSync(cfgPath, "utf8"));
    const srv = cfg.mcpServers?.movp;
    return srv?.command ? srv : null;
  } catch {
    return null;
  }
}

const srv = readConfig();
if (!srv) process.exit(2);

let child;
try {
  child = spawn(srv.command, srv.args || [], {
    env: { ...process.env, ...(srv.env || {}), MOVP_FAKE_GATEWAY: "1" },
    stdio: ["pipe", "pipe", "ignore"],
  });
} catch {
  process.exit(1);
}

const timer = setTimeout(() => {
  try { child.kill(); } catch { /* ignore */ }
  process.exit(1);
}, TIMEOUT_MS);

child.on("error", () => {
  clearTimeout(timer);
  process.exit(1);
});

const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });
const pending = new Map();
let nextId = 1;

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  try {
    const msg = JSON.parse(trimmed);
    const handler = pending.get(msg.id);
    if (handler) {
      pending.delete(msg.id);
      if (msg.error) handler.reject(new Error(msg.error.message));
      else handler.resolve(msg.result);
    }
  } catch { /* ignore */ }
});

function send(method, params = {}) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}

async function probe() {
  await send("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "movp-session-probe", version: "1.0.0" },
  });
  const result = await send("tools/list");
  clearTimeout(timer);
  try { child.kill(); } catch { /* ignore */ }
  process.exit(result.tools.length === 0 ? 2 : 0);
}

probe().catch(() => {
  clearTimeout(timer);
  try { child.kill(); } catch { /* ignore */ }
  process.exit(1);
});
