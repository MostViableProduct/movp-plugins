#!/usr/bin/env node
/**
 * MCP smoke test — spawns @movp/mcp-server with MOVP_FAKE_GATEWAY=1,
 * asserts tool set and resource set ⊇ claude-plugin/manifest.json.
 * Uses NDJSON transport to match the server's own readline-based protocol.
 */
import { spawn } from "child_process";
import { createInterface } from "readline";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { resolve, dirname } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const MANIFEST = JSON.parse(
  readFileSync(resolve(__dirname, "../../claude-plugin/manifest.json"), "utf8")
);
const SERVER_PATH = resolve(__dirname, "node_modules/@movp/mcp-server/index.js");
const TIMEOUT_MS = 15_000;
const MAX_RETRIES = 2;
const RETRY_DELAY_MS = 1_000;

const timer = setTimeout(() => {
  console.error("[mcp-smoke] FAIL: timed out after 15s");
  process.exit(1);
}, TIMEOUT_MS);
timer.unref();

function sleep(ms) {
  return new Promise((res) => setTimeout(res, ms));
}

function makeClient(child) {
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
    } catch { /* ignore non-JSON */ }
  });

  function send(method, params = {}) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }

  function close() {
    try { child.kill(); } catch { /* ignore */ }
    rl.close();
  }

  return { send, close };
}

async function connect() {
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    let child;
    try {
      child = spawn("node", [SERVER_PATH], {
        env: { ...process.env, MOVP_FAKE_GATEWAY: "1" },
        stdio: ["pipe", "pipe", "ignore"],
      });
      const client = makeClient(child);
      await client.send("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "mcp-smoke", version: "1.0.0" },
      });
      return client;
    } catch (err) {
      try { child?.kill(); } catch { /* ignore */ }
      if (attempt === MAX_RETRIES) {
        console.error(
          `[mcp-smoke] FAIL: could not connect after ${MAX_RETRIES + 1} attempt(s): ${err.message}`
        );
        process.exit(1);
      }
      console.error(
        `[mcp-smoke] connect failed (attempt ${attempt + 1}), retrying in ${RETRY_DELAY_MS}ms...`
      );
      await sleep(RETRY_DELAY_MS);
    }
  }
}

async function run() {
  const client = await connect();
  const failures = [];

  const toolsResult = await client.send("tools/list");
  const serverToolNames = new Set(toolsResult.tools.map((t) => t.name));

  for (const expected of MANIFEST.tools) {
    if (!serverToolNames.has(expected)) {
      failures.push(`missing tool: ${expected}`);
    }
  }

  for (const tool of toolsResult.tools) {
    if (!tool.name) {
      failures.push(`tool missing name: ${JSON.stringify(tool)}`);
    } else if (!tool.inputSchema || tool.inputSchema.type !== "object") {
      failures.push(
        `tool ${tool.name}: inputSchema.type !== "object" (got ${tool.inputSchema?.type})`
      );
    }
  }

  const resourcesResult = await client.send("resources/list");
  const serverResourceUris = new Set(resourcesResult.resources.map((r) => r.uri));

  for (const expected of MANIFEST.resources) {
    if (!serverResourceUris.has(expected)) {
      failures.push(`missing resource: ${expected}`);
    }
  }

  client.close();
  clearTimeout(timer);

  if (failures.length === 0) {
    console.log(
      `[mcp-smoke] PASS: ${serverToolNames.size} tools, ${serverResourceUris.size} resources`
    );
    console.log(`  tools:     ${[...serverToolNames].join(", ")}`);
    console.log(`  resources: ${[...serverResourceUris].join(", ")}`);
    process.exit(0);
  } else {
    console.error("[mcp-smoke] FAIL:");
    for (const f of failures) console.error(`  - ${f}`);
    console.error(`\nServer tools:     ${[...serverToolNames].join(", ")}`);
    console.error(`Expected tools:   ${MANIFEST.tools.join(", ")}`);
    process.exit(1);
  }
}

run().catch((err) => {
  console.error("[mcp-smoke] FAIL: unexpected error:", err.message);
  process.exit(1);
});
