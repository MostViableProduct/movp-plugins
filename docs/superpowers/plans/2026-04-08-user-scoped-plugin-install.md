# User-Scoped Plugin Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `movp init` to install MoVP as a user-scoped plugin (active in all Claude Code projects) and add lazy `.movp/config.yaml` creation on first `/movp` command use.

**Architecture:** Three changes working together — (1) extend `mergeJsonConfig` to write marketplace registration to `~/.claude/settings.json`, (2) new `registerMarketplace` + `migrateProjectScoped` functions added to `runInit`, which drops project config creation entirely, and (3) MCP server gains lazy config creation via inlined `ensureProjectConfig` called on each JSON-RPC request when `.movp/config.yaml` is absent.

**Tech Stack:** Node.js 18+, `node:test` (no external test framework), `fs`/`path`/`os` stdlib only. Repos: `big-wave` (CLI + MCP server), `mona-lisa` (slash command copy).

**Spec:** `docs/superpowers/specs/2026-04-08-user-scoped-plugin-install-design.md`

---

## File Map

### Created
- `big-wave/packages/cli/lib/project-config.js` — canonical `ensureProjectConfig(root, { log })` + `DEFAULT_PROJECT_CONFIG` + `DEFAULT_LOCAL_CONFIG` constants
- `big-wave/packages/cli/test/project-config.test.js` — golden-fixture contract tests for `ensureProjectConfig` (shared with MCP)
- `big-wave/packages/mcp-server/test/mcp-server.test.js` — root resolution tests + re-run of golden fixtures against inlined copy

### Modified
- `big-wave/packages/cli/lib/helpers.js` — add `extraKnownMarketplaces` + `enabledPlugins` merge handling in `mergeJsonConfig`
- `big-wave/packages/cli/bin/cli.js` — rewrite `runInit`, add `registerMarketplace` + `migrateProjectScoped`, remove `--no-rules`, update help text + top comment
- `big-wave/packages/cli/test/cli.test.js` — add tests for new merge keys, `registerMarketplace`, `migrateProjectScoped`
- `big-wave/packages/mcp-server/index.js` — add inlined `ensureProjectConfig` + root resolution + lazy config check per request
- `mona-lisa/claude-plugin/commands/status.md` — update fallback messaging

---

## Task 1: Extract `project-config.js` module with contract tests

**Files:**
- Create: `big-wave/packages/cli/lib/project-config.js`
- Create: `big-wave/packages/cli/test/project-config.test.js`

- [ ] **Step 1.1: Write failing contract tests**

Create `big-wave/packages/cli/test/project-config.test.js`:

```js
// @movp/cli — project-config contract tests (node --test)
// These same fixtures must pass against the inlined copy in mcp-server/index.js.
"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

// This require will fail until project-config.js is created — that's the point.
const { ensureProjectConfig, DEFAULT_PROJECT_CONFIG } = require("../lib/project-config");

function makeTmpGitRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-pc-test-"));
  fs.mkdirSync(path.join(dir, ".git"));
  return dir;
}

// ─── Golden fixture: empty repo ───────────────────────────────────────────────

test("ensureProjectConfig — creates config.yaml in empty repo", () => {
  const dir = makeTmpGitRepo();
  ensureProjectConfig(dir);
  const configPath = path.join(dir, ".movp", "config.yaml");
  assert.ok(fs.existsSync(configPath), "config.yaml should be created");
  const content = fs.readFileSync(configPath, "utf8");
  assert.ok(content.includes("version: 1"), "should include version: 1");
  assert.ok(content.includes("review:"), "should include review section");
  assert.ok(content.includes("control_plane:"), "should include control_plane section");
  fs.rmSync(dir, { recursive: true });
});

test("ensureProjectConfig — creates .movp/config.local.yaml in empty repo", () => {
  const dir = makeTmpGitRepo();
  ensureProjectConfig(dir);
  const localPath = path.join(dir, ".movp", "config.local.yaml");
  assert.ok(fs.existsSync(localPath), "config.local.yaml should be created");
  const content = fs.readFileSync(localPath, "utf8");
  assert.ok(content.includes("MOVP_FRONTEND_URL"), "should include MOVP_FRONTEND_URL");
  fs.rmSync(dir, { recursive: true });
});

test("ensureProjectConfig — appends gitignore entries in empty repo", () => {
  const dir = makeTmpGitRepo();
  ensureProjectConfig(dir);
  const gitignorePath = path.join(dir, ".gitignore");
  assert.ok(fs.existsSync(gitignorePath), ".gitignore should be created");
  const content = fs.readFileSync(gitignorePath, "utf8");
  assert.ok(content.includes(".movp/config.local.yaml"), "should gitignore local config");
  assert.ok(content.includes(".env.movp"), "should gitignore .env.movp");
  fs.rmSync(dir, { recursive: true });
});

// ─── Golden fixture: partial yaml (additive merge) ────────────────────────────

test("ensureProjectConfig — additive merge preserves existing yaml, adds missing sections", () => {
  const dir = makeTmpGitRepo();
  const movpDir = path.join(dir, ".movp");
  fs.mkdirSync(movpDir, { recursive: true });
  // Write a partial config missing the control_plane section
  fs.writeFileSync(path.join(movpDir, "config.yaml"), [
    "version: 1",
    "review:",
    "  enabled: true",
    "  categories:",
    "    - name: security",
    "      weight: 1",
  ].join("\n") + "\n");
  ensureProjectConfig(dir);
  const content = fs.readFileSync(path.join(movpDir, "config.yaml"), "utf8");
  assert.ok(content.includes("control_plane:"), "should add missing control_plane section");
  assert.ok(content.includes("review:"), "should preserve existing review section");
  assert.ok(content.includes("security"), "should preserve existing categories");
  fs.rmSync(dir, { recursive: true });
});

// ─── Golden fixture: full yaml present (no changes) ───────────────────────────

test("ensureProjectConfig — does not modify fully present config.yaml", () => {
  const dir = makeTmpGitRepo();
  const movpDir = path.join(dir, ".movp");
  fs.mkdirSync(movpDir, { recursive: true });
  fs.writeFileSync(path.join(movpDir, "config.yaml"), DEFAULT_PROJECT_CONFIG);
  ensureProjectConfig(dir);
  const content = fs.readFileSync(path.join(movpDir, "config.yaml"), "utf8");
  assert.equal(content, DEFAULT_PROJECT_CONFIG, "content should be unchanged");
  fs.rmSync(dir, { recursive: true });
});

// ─── Golden fixture: missing .gitignore ───────────────────────────────────────

test("ensureProjectConfig — creates .gitignore when absent", () => {
  const dir = makeTmpGitRepo();
  assert.ok(!fs.existsSync(path.join(dir, ".gitignore")), "precondition: no .gitignore");
  ensureProjectConfig(dir);
  assert.ok(fs.existsSync(path.join(dir, ".gitignore")), ".gitignore should be created");
  fs.rmSync(dir, { recursive: true });
});

// ─── Golden fixture: idempotent gitignore ─────────────────────────────────────

test("ensureProjectConfig — does not duplicate gitignore entries on re-run", () => {
  const dir = makeTmpGitRepo();
  ensureProjectConfig(dir);
  ensureProjectConfig(dir); // second run
  const content = fs.readFileSync(path.join(dir, ".gitignore"), "utf8");
  const lines = content.split("\n").filter(l => l.trim() === ".movp/config.local.yaml");
  assert.equal(lines.length, 1, "should only have one .movp/config.local.yaml entry");
  fs.rmSync(dir, { recursive: true });
});

// ─── Golden fixture: idempotent MOVP_FRONTEND_URL ─────────────────────────────

test("ensureProjectConfig — does not duplicate MOVP_FRONTEND_URL in config.local.yaml", () => {
  const dir = makeTmpGitRepo();
  ensureProjectConfig(dir);
  ensureProjectConfig(dir); // second run
  const content = fs.readFileSync(path.join(dir, ".movp", "config.local.yaml"), "utf8");
  const count = (content.match(/MOVP_FRONTEND_URL/g) || []).length;
  assert.equal(count, 1, "should only have one MOVP_FRONTEND_URL entry");
  fs.rmSync(dir, { recursive: true });
});
```

- [ ] **Step 1.2: Run tests to confirm they fail**

```bash
cd /path/to/big-wave/packages/cli
node --test test/project-config.test.js
```

Expected: `Cannot find module '../lib/project-config'`

- [ ] **Step 1.3: Create `packages/cli/lib/project-config.js`**

Extract from `writeMovpConfig` in `bin/cli.js` (lines 987–1041). The new module removes `console.log` in favor of an optional `log` function:

```js
"use strict";
// packages/cli/lib/project-config.js
// Canonical implementation of ensureProjectConfig.
// The MCP server inlines a copy of this function in index.js.
// When making changes here, update the inlined copy and bump the sync comment.
// Sync tag: v1.0.7
const fs = require("fs");
const path = require("path");

const DEFAULT_PROJECT_CONFIG = `version: 1
review:
  enabled: true
  categories:
    # Default 8 categories — all scored 1-10 by the adversarial model.
    # All weights are equal by default. Increase a weight to emphasize a category.
    # Weights must be positive integers >= 1.
    - name: security
      weight: 1
    - name: correctness
      weight: 1
    - name: performance
      weight: 1
    - name: stability
      weight: 1
    - name: ux_drift
      weight: 1
    - name: outcome_drift
      weight: 1
    - name: missing_tests
      weight: 1
    - name: scope_creep
      weight: 1
    # Add custom categories:
    # - name: accessibility
    #   description: WCAG 2.1 AA compliance
    #   weight: 1
  auto_review:
    plan_files: true    # auto-trigger review after writing plan files
    code_output: false  # auto-trigger review after significant code output
  cost_cap_daily_usd: 5.0
  max_rounds: 3
  # rule_apply_mode: "direct"  # "direct" = write rules on confirm; "pr" = create branch + PR
control_plane:
  health_check_interval: 20  # seconds between health checks
  show_cost: true
  show_recommendations: true
`;

const DEFAULT_LOCAL_CONFIG = `# .movp/config.local.yaml — personal overrides (gitignored)
# Overrides .movp/config.yaml for your local environment only.
# Example:
# review:
#   enabled: false
`;

// Parse a YAML string into top-level sections.
// A section is an unindented key line (e.g. "review:") and all lines that
// follow it until the next unindented key. Returns [{key, text}].
function parseDefaultSections(yamlText) {
  const lines = yamlText.split("\n");
  const sections = [];
  let current = null;
  for (const line of lines) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):/);
    if (m) {
      if (current) sections.push(current);
      current = { key: m[1], lines: [line] };
    } else if (current) {
      current.lines.push(line);
    }
  }
  if (current) sections.push(current);
  return sections.map(s => ({ key: s.key, text: s.lines.join("\n") }));
}

function sectionExists(existingText, key) {
  return new RegExp("^" + key + ":", "m").test(existingText);
}

/**
 * Ensure .movp/config.yaml, .movp/config.local.yaml, and .gitignore exist
 * in the given project root. Safe to call on every request — all writes are
 * idempotent and additive (never removes or overwrites existing content).
 *
 * @param {string} root  Absolute path to the project root.
 * @param {object} [opts]
 * @param {function} [opts.log]  Called with a message string for each file
 *   created or updated. Defaults to no-op.
 */
function ensureProjectConfig(root, { log = () => {} } = {}) {
  const movpDir = path.join(root, ".movp");
  fs.mkdirSync(movpDir, { recursive: true });

  // config.yaml — create or additive merge
  const configPath = path.join(movpDir, "config.yaml");
  if (!fs.existsSync(configPath)) {
    fs.writeFileSync(configPath, DEFAULT_PROJECT_CONFIG);
    log("Created " + configPath);
  } else {
    const existing = fs.readFileSync(configPath, "utf8");
    const defaultSections = parseDefaultSections(DEFAULT_PROJECT_CONFIG);
    const added = [];
    for (const section of defaultSections) {
      if (!sectionExists(existing, section.key)) {
        const appendBlock = "\n# Added by MoVP — new in schema\n" + section.text;
        fs.appendFileSync(configPath, appendBlock, "utf8");
        added.push(section.key);
      }
    }
    if (added.length > 0) log("Updated " + configPath + " — added sections: " + added.join(", "));
  }

  // config.local.yaml — create or append MOVP_FRONTEND_URL if missing
  const localConfigPath = path.join(movpDir, "config.local.yaml");
  const detectedFrontendUrl = process.env.MOVP_FRONTEND_URL || "https://host.mostviableproduct.com";
  const frontendUrlLine = `\n# Frontend URL — used by the MCP server to construct settings links\nMOVP_FRONTEND_URL: "${detectedFrontendUrl}"\n`;
  if (!fs.existsSync(localConfigPath)) {
    fs.writeFileSync(localConfigPath, DEFAULT_LOCAL_CONFIG + frontendUrlLine);
    log("Created " + localConfigPath);
  } else {
    const existingLocal = fs.readFileSync(localConfigPath, "utf8");
    if (!existingLocal.includes("MOVP_FRONTEND_URL")) {
      fs.appendFileSync(localConfigPath, frontendUrlLine);
    }
  }

  // .gitignore — idempotent append
  const gitignorePath = path.join(root, ".gitignore");
  const gitignoreEntry = ".movp/config.local.yaml";
  try {
    let gitignore = fs.existsSync(gitignorePath) ? fs.readFileSync(gitignorePath, "utf8") : "";
    if (!gitignore.includes(gitignoreEntry)) {
      fs.appendFileSync(gitignorePath, "\n# MoVP local config\n" + gitignoreEntry + "\n.env.movp\n*.bak\n");
    }
  } catch { /* gitignore update is best-effort */ }
}

module.exports = { ensureProjectConfig, DEFAULT_PROJECT_CONFIG, DEFAULT_LOCAL_CONFIG };
```

- [ ] **Step 1.4: Run tests — should pass**

```bash
cd /path/to/big-wave/packages/cli
node --test test/project-config.test.js
```

Expected: all 7 tests pass.

- [ ] **Step 1.5: Commit**

```bash
cd /path/to/big-wave
git add packages/cli/lib/project-config.js packages/cli/test/project-config.test.js
git commit -m "feat(cli): extract ensureProjectConfig to lib/project-config.js with contract tests"
```

---

## Task 2: Extend `mergeJsonConfig` for marketplace registration

**Files:**
- Modify: `big-wave/packages/cli/lib/helpers.js`
- Modify: `big-wave/packages/cli/test/cli.test.js`

- [ ] **Step 2.1: Write failing tests**

Append to `big-wave/packages/cli/test/cli.test.js` after the existing `mergeJsonConfig` tests:

```js
// ─── mergeJsonConfig — extraKnownMarketplaces + enabledPlugins ────────────────

test("mergeJsonConfig — writes extraKnownMarketplaces.movp (fresh file)", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  const snippet = {
    config_file: ".claude/settings.json",
    config_json: {
      extraKnownMarketplaces: {
        movp: { source: { source: "github", repo: "MostViableProduct/movp-plugins", tag: "v1.0.7" } }
      },
      enabledPlugins: { "movp@movp": true }
    }
  };
  mergeJsonConfig(tmpDir, snippet);
  const written = JSON.parse(fs.readFileSync(path.join(tmpDir, ".claude", "settings.json"), "utf8"));
  assert.deepEqual(
    written.extraKnownMarketplaces.movp.source,
    { source: "github", repo: "MostViableProduct/movp-plugins", tag: "v1.0.7" }
  );
  assert.equal(written.enabledPlugins["movp@movp"], true);
  fs.rmSync(tmpDir, { recursive: true });
});

test("mergeJsonConfig — replaces extraKnownMarketplaces.movp wholesale (no deep merge)", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  const claudeDir = path.join(tmpDir, ".claude");
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(
    path.join(claudeDir, "settings.json"),
    JSON.stringify({
      extraKnownMarketplaces: {
        movp: { source: { source: "github", repo: "OLD/repo", tag: "v0.1.0" }, staleKey: true }
      }
    })
  );
  const snippet = {
    config_file: ".claude/settings.json",
    config_json: {
      extraKnownMarketplaces: {
        movp: { source: { source: "github", repo: "MostViableProduct/movp-plugins", tag: "v1.0.7" } }
      }
    }
  };
  mergeJsonConfig(tmpDir, snippet);
  const written = JSON.parse(fs.readFileSync(path.join(claudeDir, "settings.json"), "utf8"));
  assert.equal(written.extraKnownMarketplaces.movp.source.repo, "MostViableProduct/movp-plugins");
  assert.equal(written.extraKnownMarketplaces.movp.staleKey, undefined, "stale keys must be removed");
  fs.rmSync(tmpDir, { recursive: true });
});

test("mergeJsonConfig — preserves other extraKnownMarketplaces entries", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  const claudeDir = path.join(tmpDir, ".claude");
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(
    path.join(claudeDir, "settings.json"),
    JSON.stringify({ extraKnownMarketplaces: { other: { source: { source: "github", repo: "other/repo" } } } })
  );
  mergeJsonConfig(tmpDir, {
    config_file: ".claude/settings.json",
    config_json: {
      extraKnownMarketplaces: { movp: { source: { source: "github", repo: "MostViableProduct/movp-plugins", tag: "v1.0.7" } } }
    }
  });
  const written = JSON.parse(fs.readFileSync(path.join(claudeDir, "settings.json"), "utf8"));
  assert.ok(written.extraKnownMarketplaces.other, "should preserve other marketplace entry");
  assert.ok(written.extraKnownMarketplaces.movp, "should have movp entry");
  fs.rmSync(tmpDir, { recursive: true });
});

test("mergeJsonConfig — merges enabledPlugins keys (does not overwrite existing)", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  const claudeDir = path.join(tmpDir, ".claude");
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(
    path.join(claudeDir, "settings.json"),
    JSON.stringify({ enabledPlugins: { "other@marketplace": true } })
  );
  mergeJsonConfig(tmpDir, {
    config_file: ".claude/settings.json",
    config_json: { enabledPlugins: { "movp@movp": true } }
  });
  const written = JSON.parse(fs.readFileSync(path.join(claudeDir, "settings.json"), "utf8"));
  assert.equal(written.enabledPlugins["other@marketplace"], true, "should preserve existing plugin");
  assert.equal(written.enabledPlugins["movp@movp"], true, "should add new plugin");
  fs.rmSync(tmpDir, { recursive: true });
});

test("mergeJsonConfig — blocks prototype pollution via enabledPlugins", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  const snippet = {
    config_file: ".claude/settings.json",
    config_json: {}
  };
  Object.defineProperty(snippet.config_json, "enabledPlugins", {
    value: {},
    enumerable: true,
  });
  Object.defineProperty(snippet.config_json.enabledPlugins, "__proto__", {
    value: { polluted: true },
    enumerable: true,
  });
  mergeJsonConfig(tmpDir, snippet);
  // Round-trip through JSON.stringify to verify no prototype pollution
  const written = JSON.parse(fs.readFileSync(path.join(tmpDir, ".claude", "settings.json"), "utf8"));
  const safe = JSON.parse(JSON.stringify(written));
  assert.equal(safe.__proto__, undefined, "written object should not have __proto__ key");
  assert.equal(({}).polluted, undefined, "Object prototype should not be polluted");
  fs.rmSync(tmpDir, { recursive: true });
});
```

- [ ] **Step 2.2: Run tests to confirm they fail**

```bash
cd /path/to/big-wave/packages/cli
node --test test/cli.test.js 2>&1 | grep -E "(FAIL|pass|fail)"
```

Expected: 5 new tests fail (the existing tests still pass).

- [ ] **Step 2.3: Add `extraKnownMarketplaces` and `enabledPlugins` handling in `mergeJsonConfig`**

In `big-wave/packages/cli/lib/helpers.js`, add two `else if` branches in the `for (const key of Object.keys(configJson))` loop, after the existing `} else if (key === "env") {` block (before the closing `}`):

```js
    } else if (key === "extraKnownMarketplaces") {
      existing.extraKnownMarketplaces = existing.extraKnownMarketplaces || {};
      // Replace movp entry wholesale — same pattern as mcpServers.movp
      if (configJson.extraKnownMarketplaces.movp) {
        existing.extraKnownMarketplaces.movp = configJson.extraKnownMarketplaces.movp;
      }
    } else if (key === "enabledPlugins") {
      existing.enabledPlugins = existing.enabledPlugins || {};
      for (const [k, v] of Object.entries(configJson.enabledPlugins)) {
        if (!BLOCKED.has(k)) existing.enabledPlugins[k] = v;
      }
    }
```

- [ ] **Step 2.4: Run tests — should pass**

```bash
cd /path/to/big-wave/packages/cli
node --test test/cli.test.js
node --test test/project-config.test.js
```

Expected: all tests pass.

- [ ] **Step 2.5: Commit**

```bash
cd /path/to/big-wave
git add packages/cli/lib/helpers.js packages/cli/test/cli.test.js
git commit -m "feat(cli): extend mergeJsonConfig to handle extraKnownMarketplaces and enabledPlugins"
```

---

## Task 3: Add `registerMarketplace()` with tests

**Files:**
- Modify: `big-wave/packages/cli/bin/cli.js`
- Modify: `big-wave/packages/cli/test/cli.test.js`

- [ ] **Step 3.1: Write failing tests**

Append to `big-wave/packages/cli/test/cli.test.js`. Note: `registerMarketplace` is defined in `bin/cli.js` so tests must extract it or we expose it. Best approach: move it to a helper or test via file system. Since `bin/cli.js` requires `helpers.js`, we test `registerMarketplace` by temporarily exporting it during test — but `bin/cli.js` calls `process.exit` at load time. Instead, implement `registerMarketplace` in a new file or in helpers.

**Decision:** implement `registerMarketplace` as a standalone function that takes `(homedir, version, mergeJsonConfigFn)` and put it in `lib/helpers.js` as an export, making it pure and testable.

Add to `big-wave/packages/cli/test/cli.test.js`:

```js
// ─── registerMarketplace tests ────────────────────────────────────────────────

const { registerMarketplace } = require("../lib/helpers");

test("registerMarketplace — fresh install writes marketplace + enabledPlugins", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  registerMarketplace(tmpDir, "1.0.7");
  const written = JSON.parse(fs.readFileSync(path.join(tmpDir, ".claude", "settings.json"), "utf8"));
  assert.equal(
    written.extraKnownMarketplaces.movp.source.tag,
    "v1.0.7",
    "should pin to v<version> tag"
  );
  assert.equal(written.enabledPlugins["movp@movp"], true);
  fs.rmSync(tmpDir, { recursive: true });
});

test("registerMarketplace — pre-release version uses 'main' tag", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  registerMarketplace(tmpDir, "1.1.0-beta.1");
  const written = JSON.parse(fs.readFileSync(path.join(tmpDir, ".claude", "settings.json"), "utf8"));
  assert.equal(written.extraKnownMarketplaces.movp.source.tag, "main", "pre-release should use main");
  fs.rmSync(tmpDir, { recursive: true });
});

test("registerMarketplace — idempotent re-run (no duplicates)", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  registerMarketplace(tmpDir, "1.0.7");
  registerMarketplace(tmpDir, "1.0.7"); // second run
  const parsed = JSON.parse(fs.readFileSync(path.join(tmpDir, ".claude", "settings.json"), "utf8"));
  // movp@movp key should still be true (not duplicated into an array)
  assert.equal(parsed.enabledPlugins["movp@movp"], true);
  // movp marketplace entry should have the correct tag and repo
  assert.equal(parsed.extraKnownMarketplaces.movp.source.tag, "v1.0.7");
  assert.equal(parsed.extraKnownMarketplaces.movp.source.repo, "MostViableProduct/movp-plugins");
  fs.rmSync(tmpDir, { recursive: true });
});
```

- [ ] **Step 3.2: Run tests to confirm they fail**

```bash
cd /path/to/big-wave/packages/cli
node --test test/cli.test.js 2>&1 | tail -20
```

Expected: 3 new tests fail with `registerMarketplace is not a function`.

- [ ] **Step 3.3: Implement `registerMarketplace` in `lib/helpers.js`**

Add to `big-wave/packages/cli/lib/helpers.js` before `module.exports`:

```js
/**
 * Write extraKnownMarketplaces + enabledPlugins to ~/.claude/settings.json
 * so Claude Code discovers and installs the movp plugin at user scope.
 *
 * @param {string} homeDir  Path to write into (os.homedir() in production; tmp in tests).
 * @param {string} version  CLI package.json version string.
 */
function registerMarketplace(homeDir, version) {
  const tag = version.includes("-") ? "main" : "v" + version;
  return mergeJsonConfig(homeDir, {
    config_file: ".claude/settings.json",
    config_json: {
      extraKnownMarketplaces: {
        movp: {
          source: { source: "github", repo: "MostViableProduct/movp-plugins", tag }
        }
      },
      enabledPlugins: { "movp@movp": true }
    }
  });
}
```

Update `module.exports` to include `registerMarketplace`:

```js
module.exports = { redactSecrets, mergeJsonConfig, registerMarketplace, isTransientGatewayStatus, extractPollErrorMessage };
```

- [ ] **Step 3.4: Run tests — should pass**

```bash
cd /path/to/big-wave/packages/cli
node --test test/cli.test.js
```

Expected: all tests pass.

- [ ] **Step 3.5: Import and wire `registerMarketplace` in `runInit()`**

In `big-wave/packages/cli/bin/cli.js`, update the import on line 31:

```js
const { redactSecrets, mergeJsonConfig, registerMarketplace, isTransientGatewayStatus, extractPollErrorMessage } = require("../lib/helpers");
```

In `runInit()`, replace the `// ── Step 3/3: Project config` block (lines 947–955) with the marketplace registration call. **Note:** `registerMarketplace` always runs regardless of which tools were selected — only API key minting is per-tool. A `marketplaceFailed` flag is tracked independently of `failCount`:

```js
  // ── Marketplace registration (always, independent of selected tools) ──────
  let marketplaceFailed = false;
  const cliVersion = require("../package.json").version;
  const marketplaceOk = registerMarketplace(os.homedir(), cliVersion);
  if (marketplaceOk) {
    console.log("      ~/.claude/settings.json → marketplace registered (movp@" +
      (cliVersion.includes("-") ? "main" : "v" + cliVersion) + ")");
    console.log("      ~/.claude/settings.json → plugin enabled (user-scoped)");
  } else {
    console.error("      marketplace registration failed — check ~/.claude/settings.json");
    marketplaceFailed = true;
  }
```

Then update the success/failure banner at end of `runInit()` (this is done in Task 3.5; Task 5 handles only labels / --no-rules / help):

```js
  if (failCount === 0 && !marketplaceFailed) {
    console.log("\n  ✓ MoVP is now active across all your projects.");
    console.log("    Run /movp status in any repo to verify.\n");
  } else {
    if (marketplaceFailed) {
      console.error("  ✗ Marketplace registration failed — plugin may not load.");
    }
    if (failCount > 0) {
      console.log("  Setup completed with " + failCount + " tool error(s). See above.");
      console.log("  Retry: npx @movp/cli init --force");
    }
    console.log();
  }
  if (failCount > 0 || marketplaceFailed) process.exitCode = 1;
```

- [ ] **Step 3.6: Run full test suite**

```bash
cd /path/to/big-wave/packages/cli
node --test test/cli.test.js
node --test test/project-config.test.js
```

Expected: all tests pass.

- [ ] **Step 3.7: Commit**

```bash
cd /path/to/big-wave
git add packages/cli/lib/helpers.js packages/cli/bin/cli.js packages/cli/test/cli.test.js
git commit -m "feat(cli): add registerMarketplace — writes user-scoped plugin + marketplace to settings.json"
```

---

## Task 4: Add `migrateProjectScoped()` with tests

**Files:**
- Modify: `big-wave/packages/cli/lib/helpers.js`
- Modify: `big-wave/packages/cli/bin/cli.js`
- Modify: `big-wave/packages/cli/test/cli.test.js`

- [ ] **Step 4.1: Write failing tests**

Append to `big-wave/packages/cli/test/cli.test.js`:

```js
// ─── migrateProjectScoped tests ───────────────────────────────────────────────

const { migrateProjectScoped } = require("../lib/helpers");

test("migrateProjectScoped — returns { migrated: false } when no .claude/settings.json", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  const result = migrateProjectScoped(tmpDir);
  assert.equal(result.migrated, false);
  fs.rmSync(tmpDir, { recursive: true });
});

test("migrateProjectScoped — returns { migrated: false } when movp@movp absent from enabledPlugins", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  const claudeDir = path.join(tmpDir, ".claude");
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(path.join(claudeDir, "settings.json"),
    JSON.stringify({ enabledPlugins: { "other@marketplace": true } }));
  const result = migrateProjectScoped(tmpDir);
  assert.equal(result.migrated, false);
  fs.rmSync(tmpDir, { recursive: true });
});

test("migrateProjectScoped — removes movp@movp from enabledPlugins, creates .bak", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  const claudeDir = path.join(tmpDir, ".claude");
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(path.join(claudeDir, "settings.json"),
    JSON.stringify({ enabledPlugins: { "movp@movp": true, "other@marketplace": true } }));
  const result = migrateProjectScoped(tmpDir);
  assert.equal(result.migrated, true);
  const written = JSON.parse(fs.readFileSync(path.join(claudeDir, "settings.json"), "utf8"));
  assert.equal(written.enabledPlugins["movp@movp"], undefined, "movp@movp should be removed");
  assert.equal(written.enabledPlugins["other@marketplace"], true, "other plugin preserved");
  assert.ok(fs.existsSync(path.join(claudeDir, "settings.json.bak")), ".bak should be created");
  fs.rmSync(tmpDir, { recursive: true });
});

test("migrateProjectScoped — removes enabledPlugins key when it becomes empty", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  const claudeDir = path.join(tmpDir, ".claude");
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(path.join(claudeDir, "settings.json"),
    JSON.stringify({ enabledPlugins: { "movp@movp": true } }));
  const result = migrateProjectScoped(tmpDir);
  assert.equal(result.migrated, true);
  const written = JSON.parse(fs.readFileSync(path.join(claudeDir, "settings.json"), "utf8"));
  assert.equal(written.enabledPlugins, undefined, "empty enabledPlugins should be removed");
  fs.rmSync(tmpDir, { recursive: true });
});

test("migrateProjectScoped — returns { migrated: false, error } for invalid JSON", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-test-"));
  const claudeDir = path.join(tmpDir, ".claude");
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(path.join(claudeDir, "settings.json"), "{ not json");
  const result = migrateProjectScoped(tmpDir);
  assert.equal(result.migrated, false);
  assert.ok(result.error, "should include error description");
  fs.rmSync(tmpDir, { recursive: true });
});
```

- [ ] **Step 4.2: Run tests to confirm they fail**

```bash
cd /path/to/big-wave/packages/cli
node --test test/cli.test.js 2>&1 | tail -20
```

Expected: 5 new tests fail with `migrateProjectScoped is not a function`.

- [ ] **Step 4.3: Implement `migrateProjectScoped` in `lib/helpers.js`**

Add to `big-wave/packages/cli/lib/helpers.js` before `module.exports`:

```js
/**
 * Remove "movp@movp" from project-level .claude/settings.json enabledPlugins.
 * Scoped to cwd only — never walks the directory tree.
 * Creates a .bak backup before modifying.
 *
 * @param {string} cwd  Project directory containing .claude/settings.json.
 * @returns {{ migrated: boolean, path?: string, error?: string }}
 */
function migrateProjectScoped(cwd) {
  const settingsPath = path.join(cwd, ".claude", "settings.json");
  if (!fs.existsSync(settingsPath)) return { migrated: false };

  let settings;
  try {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  } catch (e) {
    return { migrated: false, error: "invalid JSON: " + e.message };
  }

  if (!settings.enabledPlugins || !settings.enabledPlugins["movp@movp"]) {
    return { migrated: false };
  }

  // Backup
  fs.writeFileSync(settingsPath + ".bak", fs.readFileSync(settingsPath));
  try { fs.chmodSync(settingsPath + ".bak", 0o600); } catch { /* Windows */ }

  delete settings.enabledPlugins["movp@movp"];
  if (Object.keys(settings.enabledPlugins).length === 0) {
    delete settings.enabledPlugins;
  }

  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
  return { migrated: true, path: settingsPath };
}
```

Update `module.exports`:

```js
module.exports = { redactSecrets, mergeJsonConfig, registerMarketplace, migrateProjectScoped, isTransientGatewayStatus, extractPollErrorMessage };
```

- [ ] **Step 4.4: Run tests — should pass**

```bash
cd /path/to/big-wave/packages/cli
node --test test/cli.test.js
```

Expected: all tests pass.

- [ ] **Step 4.5: Import and wire `migrateProjectScoped` in `runInit()`**

In `big-wave/packages/cli/bin/cli.js`, update the import:

```js
const { redactSecrets, mergeJsonConfig, registerMarketplace, migrateProjectScoped, isTransientGatewayStatus, extractPollErrorMessage } = require("../lib/helpers");
```

In `runInit()`, after the `registerMarketplace` call, add:

```js
  // ── Migration: remove project-scoped plugin entry from cwd ───────────────
  const migration = migrateProjectScoped(cwd);
  if (migration.migrated) {
    console.log("    Migrated to user-scoped install:");
    console.log("      ./.claude/settings.json → removed movp@movp from enabledPlugins");
    console.log("      ./.claude/settings.json.bak → backup created");
  }
```

- [ ] **Step 4.6: Commit**

```bash
cd /path/to/big-wave
git add packages/cli/lib/helpers.js packages/cli/bin/cli.js packages/cli/test/cli.test.js
git commit -m "feat(cli): add migrateProjectScoped — removes project-scoped plugin entry from cwd"
```

---

## Task 5: Rewrite `runInit()` — remove project config, update UX

**Files:**
- Modify: `big-wave/packages/cli/bin/cli.js`

This task is a surgical edit — no new tests needed (existing tests cover the helpers; the init UX is CLI output only).

**Note:** The `writeMovpConfig` call and success/failure banner were already replaced in Task 3.5. This task handles only: step labels, `--no-rules` removal, and help text.

- [ ] **Step 5.1: Update step labels in `runInit()`**

Change:
```js
  console.log("  Step 1/3: Authentication");
```
to:
```js
  console.log("  Step 1/2: Authentication");
```

Change:
```js
  console.log("\n  Step 2/3: Configure tools\n");
```
to:
```js
  console.log("\n  Step 2/2: Configuring tools\n");
```

**Note:** Success/failure banner is handled in Task 3.5. The old banner at end of `runInit()` is removed as part of Task 3.5's replacement of the Step 3/3 block.

- [ ] **Step 5.2: Remove `--no-rules` from arg parsing**

In the `} else if (command === "init") {` block (around line 79), remove:

```js
  const noRules = args.includes("--no-rules");
```

Update the `runInit` call from:

```js
  runInit(forcedTool, { noRules, urlOnly, force }).catch((e) => { console.error(e.message); process.exit(1); });
```

to:

```js
  runInit(forcedTool, { urlOnly, force }).catch((e) => { console.error(e.message); process.exit(1); });
```

Update `runInit` signature from:

```js
async function runInit(forcedTool, { noRules = false, urlOnly = false, force = false } = {}) {
```

to:

```js
async function runInit(forcedTool, { urlOnly = false, force = false } = {}) {
```

- [ ] **Step 5.3: Update `printInitHelp()` — remove `--no-rules`, update description**

Replace the body of `printInitHelp()`:

```js
function printInitHelp() {
  console.log(`
  npx @movp/cli init [options]

  Authenticate and configure AI coding tools (user-scoped, all projects).

  Options:
    --cursor       Configure Cursor only (skip interactive prompt)
    --codex        Configure Codex only (requires \`codex\` on PATH; skip prompt)
    --url-only     Print setup URL to stdout instead of opening browser
    --force        Reconfigure, creating new API keys
                   (TTY: prompts for confirmation; non-TTY: requires MOVP_INIT_FORCE=1)
    -h, --help     Show this help text

  Environment:
    MOVP_INIT_FORCE=1   Required for --force in non-interactive (CI/piped) mode

  Notes:
    MoVP is configured at user level — active in all Claude Code projects.
    Project config (.movp/config.yaml) is auto-created on first /movp command use.
    In non-interactive mode (piped/CI), auto-detects .claude/ and .cursor/.
    Codex is never auto-selected; use --codex or interactive mode.
    Install Codex: npm i -g @openai/codex
`);
}
```

- [ ] **Step 5.4: Update top-of-file comment in `bin/cli.js`**

Remove the `--no-rules` line from the usage comment block at the top of the file (around line 12):

```js
//   npx @movp/cli init --no-rules   — skip writing movp-review rule (use when loading the plugin)
```

- [ ] **Step 5.5: Run full test suite**

```bash
cd /path/to/big-wave/packages/cli
node --test test/cli.test.js
node --test test/project-config.test.js
```

Expected: all tests pass.

- [ ] **Step 5.6: Commit**

```bash
cd /path/to/big-wave
git add packages/cli/bin/cli.js
git commit -m "feat(cli): rewrite runInit as 2-step global setup — remove project config, drop --no-rules"
```

---

## Task 6: MCP server — project root resolution + lazy config creation

**Files:**
- Modify: `big-wave/packages/mcp-server/index.js`
- Create: `big-wave/packages/mcp-server/test/mcp-server.test.js`

- [ ] **Step 6.1: Write failing tests**

Create `big-wave/packages/mcp-server/test/mcp-server.test.js`:

```js
// @movp/mcp-server — tests (node --test)
// Run: node --test test/mcp-server.test.js
"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

// ─── Helper: extract testable functions from index.js ────────────────────────
// index.js is not a module — it starts the server at load time.
// We pull the pure functions out for testing by reading + eval'ing the relevant
// section, OR we duplicate the logic here for contract testing.
//
// For golden fixtures, we test the INLINED ensureProjectConfig directly.
// For root resolution, we test findGitRoot + validateProjectRoot helpers.
//
// These are extracted by re-requiring a test-only export added to index.js.
const { ensureProjectConfig, findGitRoot, validateProjectRoot, DEFAULT_PROJECT_CONFIG } = require("../test-helpers");

function makeTmpGitRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-mcp-test-"));
  fs.mkdirSync(path.join(dir, ".git"));
  return dir;
}

// ─── Root resolution: findGitRoot ─────────────────────────────────────────────

test("findGitRoot — finds .git dir in cwd", () => {
  const dir = makeTmpGitRepo();
  assert.equal(findGitRoot(dir), dir);
  fs.rmSync(dir, { recursive: true });
});

test("findGitRoot — finds .git in parent directory", () => {
  const root = makeTmpGitRepo();
  const child = path.join(root, "packages", "cli");
  fs.mkdirSync(child, { recursive: true });
  assert.equal(findGitRoot(child), root);
  fs.rmSync(root, { recursive: true });
});

test("findGitRoot — finds .git file (worktree)", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-mcp-test-"));
  // Worktrees have .git as a file, not a directory
  fs.writeFileSync(path.join(dir, ".git"), "gitdir: /some/repo/.git/worktrees/wt1\n");
  assert.equal(findGitRoot(dir), dir, "should find .git file as valid marker");
  fs.rmSync(dir, { recursive: true });
});

test("findGitRoot — returns null when no .git found before home", () => {
  // Use a temp dir that is NOT under a git repo
  // (os.tmpdir() is typically not in a git repo)
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-mcp-test-"));
  // Ensure no .git in tmpdir itself
  const result = findGitRoot(dir);
  // result may be null or may find a git root if tmpdir is inside one; just assert type
  assert.ok(result === null || typeof result === "string");
  fs.rmSync(dir, { recursive: true });
});

// ─── Root resolution: validateProjectRoot ─────────────────────────────────────

test("validateProjectRoot — valid absolute directory returns realpath", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-mcp-test-"));
  const result = validateProjectRoot(dir);
  assert.equal(typeof result, "string");
  assert.ok(path.isAbsolute(result));
  fs.rmSync(dir, { recursive: true });
});

test("validateProjectRoot — non-absolute path throws", () => {
  assert.throws(() => validateProjectRoot("relative/path"), /not an absolute path/);
});

test("validateProjectRoot — non-existent path throws", () => {
  assert.throws(() => validateProjectRoot("/absolutely/does/not/exist/xyz123"), /does not exist/);
});

test("validateProjectRoot — file (not directory) throws", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "movp-mcp-test-"));
  const filePath = path.join(dir, "afile.txt");
  fs.writeFileSync(filePath, "content");
  assert.throws(() => validateProjectRoot(filePath), /not a directory/);
  fs.rmSync(dir, { recursive: true });
});

// ─── Golden fixture contract tests (same fixtures as project-config.test.js) ──

test("ensureProjectConfig (MCP inline) — creates config.yaml in empty repo", () => {
  const dir = makeTmpGitRepo();
  ensureProjectConfig(dir);
  const configPath = path.join(dir, ".movp", "config.yaml");
  assert.ok(fs.existsSync(configPath));
  const content = fs.readFileSync(configPath, "utf8");
  assert.ok(content.includes("version: 1"));
  assert.ok(content.includes("review:"));
  assert.ok(content.includes("control_plane:"));
  fs.rmSync(dir, { recursive: true });
});

test("ensureProjectConfig (MCP inline) — creates config.local.yaml with MOVP_FRONTEND_URL", () => {
  const dir = makeTmpGitRepo();
  ensureProjectConfig(dir);
  const localPath = path.join(dir, ".movp", "config.local.yaml");
  assert.ok(fs.existsSync(localPath));
  assert.ok(fs.readFileSync(localPath, "utf8").includes("MOVP_FRONTEND_URL"));
  fs.rmSync(dir, { recursive: true });
});

test("ensureProjectConfig (MCP inline) — additive merge adds missing sections", () => {
  const dir = makeTmpGitRepo();
  const movpDir = path.join(dir, ".movp");
  fs.mkdirSync(movpDir, { recursive: true });
  fs.writeFileSync(path.join(movpDir, "config.yaml"), "version: 1\nreview:\n  enabled: true\n");
  ensureProjectConfig(dir);
  const content = fs.readFileSync(path.join(movpDir, "config.yaml"), "utf8");
  assert.ok(content.includes("control_plane:"));
  assert.ok(content.includes("review:"));
  fs.rmSync(dir, { recursive: true });
});

test("ensureProjectConfig (MCP inline) — idempotent: no duplicate gitignore entries", () => {
  const dir = makeTmpGitRepo();
  ensureProjectConfig(dir);
  ensureProjectConfig(dir);
  const content = fs.readFileSync(path.join(dir, ".gitignore"), "utf8");
  const lines = content.split("\n").filter(l => l.trim() === ".movp/config.local.yaml");
  assert.equal(lines.length, 1);
  fs.rmSync(dir, { recursive: true });
});

test("ensureProjectConfig (MCP inline) — does not change fully present config.yaml", () => {
  const dir = makeTmpGitRepo();
  const movpDir = path.join(dir, ".movp");
  fs.mkdirSync(movpDir, { recursive: true });
  fs.writeFileSync(path.join(movpDir, "config.yaml"), DEFAULT_PROJECT_CONFIG);
  ensureProjectConfig(dir);
  const content = fs.readFileSync(path.join(movpDir, "config.yaml"), "utf8");
  assert.equal(content, DEFAULT_PROJECT_CONFIG);
  fs.rmSync(dir, { recursive: true });
});
```

- [ ] **Step 6.2: Run tests to confirm they fail**

```bash
cd /path/to/big-wave/packages/mcp-server
mkdir -p test
node --test test/mcp-server.test.js 2>&1 | head -20
```

Expected: `Cannot find module '../test-helpers'`

- [ ] **Step 6.3: Create `big-wave/packages/mcp-server/test-helpers.js`**

This file exports the pure functions that will be added to `index.js`, allowing them to be tested without starting the server.

**Note:** The contract tests here verify the `test-helpers.js` copy of `ensureProjectConfig`, not the inlined copy in `index.js` directly. `index.js` parity is enforced by code review + the sync comment, not CI.

```js
"use strict";
// test-helpers.js — exports pure functions from index.js for unit testing.
// Not required at runtime; only used by test/mcp-server.test.js.
const fs = require("fs");
const os = require("os");
const path = require("path");

// ─── Inlined ensureProjectConfig ──────────────────────────────────────────────
// Exact copy from packages/cli/lib/project-config.js — keep in sync.
// Last synced: v1.0.7
const DEFAULT_PROJECT_CONFIG = `version: 1
review:
  enabled: true
  categories:
    # Default 8 categories — all scored 1-10 by the adversarial model.
    # All weights are equal by default. Increase a weight to emphasize a category.
    # Weights must be positive integers >= 1.
    - name: security
      weight: 1
    - name: correctness
      weight: 1
    - name: performance
      weight: 1
    - name: stability
      weight: 1
    - name: ux_drift
      weight: 1
    - name: outcome_drift
      weight: 1
    - name: missing_tests
      weight: 1
    - name: scope_creep
      weight: 1
    # Add custom categories:
    # - name: accessibility
    #   description: WCAG 2.1 AA compliance
    #   weight: 1
  auto_review:
    plan_files: true    # auto-trigger review after writing plan files
    code_output: false  # auto-trigger review after significant code output
  cost_cap_daily_usd: 5.0
  max_rounds: 3
  # rule_apply_mode: "direct"  # "direct" = write rules on confirm; "pr" = create branch + PR
control_plane:
  health_check_interval: 20  # seconds between health checks
  show_cost: true
  show_recommendations: true
`;

const DEFAULT_LOCAL_CONFIG = `# .movp/config.local.yaml — personal overrides (gitignored)
# Overrides .movp/config.yaml for your local environment only.
# Example:
# review:
#   enabled: false
`;

function parseDefaultSections(yamlText) {
  const lines = yamlText.split("\n");
  const sections = [];
  let current = null;
  for (const line of lines) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):/);
    if (m) {
      if (current) sections.push(current);
      current = { key: m[1], lines: [line] };
    } else if (current) {
      current.lines.push(line);
    }
  }
  if (current) sections.push(current);
  return sections.map(s => ({ key: s.key, text: s.lines.join("\n") }));
}

function sectionExists(existingText, key) {
  return new RegExp("^" + key + ":", "m").test(existingText);
}

function ensureProjectConfig(root, { log = () => {} } = {}) {
  const movpDir = path.join(root, ".movp");
  fs.mkdirSync(movpDir, { recursive: true });

  const configPath = path.join(movpDir, "config.yaml");
  if (!fs.existsSync(configPath)) {
    fs.writeFileSync(configPath, DEFAULT_PROJECT_CONFIG);
    log("Created " + configPath);
  } else {
    const existing = fs.readFileSync(configPath, "utf8");
    const defaultSections = parseDefaultSections(DEFAULT_PROJECT_CONFIG);
    const added = [];
    for (const section of defaultSections) {
      if (!sectionExists(existing, section.key)) {
        fs.appendFileSync(configPath, "\n# Added by MoVP — new in schema\n" + section.text, "utf8");
        added.push(section.key);
      }
    }
    if (added.length > 0) log("Updated " + configPath + " — added sections: " + added.join(", "));
  }

  const localConfigPath = path.join(movpDir, "config.local.yaml");
  const detectedFrontendUrl = process.env.MOVP_FRONTEND_URL || "https://host.mostviableproduct.com";
  const frontendUrlLine = `\n# Frontend URL — used by the MCP server to construct settings links\nMOVP_FRONTEND_URL: "${detectedFrontendUrl}"\n`;
  if (!fs.existsSync(localConfigPath)) {
    fs.writeFileSync(localConfigPath, DEFAULT_LOCAL_CONFIG + frontendUrlLine);
    log("Created " + localConfigPath);
  } else {
    const existingLocal = fs.readFileSync(localConfigPath, "utf8");
    if (!existingLocal.includes("MOVP_FRONTEND_URL")) {
      fs.appendFileSync(localConfigPath, frontendUrlLine);
    }
  }

  const gitignorePath = path.join(root, ".gitignore");
  const gitignoreEntry = ".movp/config.local.yaml";
  try {
    let gitignore = fs.existsSync(gitignorePath) ? fs.readFileSync(gitignorePath, "utf8") : "";
    if (!gitignore.includes(gitignoreEntry)) {
      fs.appendFileSync(gitignorePath, "\n# MoVP local config\n" + gitignoreEntry + "\n.env.movp\n*.bak\n");
    }
  } catch { /* best-effort */ }
}

// ─── Project root resolution ──────────────────────────────────────────────────

function findGitRoot(startDir) {
  const home = os.homedir();
  let dir = path.resolve(startDir);
  while (true) {
    if (fs.existsSync(path.join(dir, ".git"))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir || dir === home) return null;
    dir = parent;
  }
}

function validateProjectRoot(override) {
  if (!path.isAbsolute(override)) {
    throw new Error(`MOVP_PROJECT_ROOT is invalid: "${override}" is not an absolute path.`);
  }
  let resolved;
  try {
    resolved = fs.realpathSync(override);
  } catch {
    throw new Error(`MOVP_PROJECT_ROOT is invalid: "${override}" does not exist.`);
  }
  try {
    if (!fs.statSync(resolved).isDirectory()) {
      throw new Error(`MOVP_PROJECT_ROOT is invalid: "${override}" is not a directory.`);
    }
  } catch (e) {
    if (e.message.includes("not a directory")) throw e;
    throw new Error(`MOVP_PROJECT_ROOT is invalid: "${override}" — must be an existing directory.`);
  }
  return resolved;
}

module.exports = { ensureProjectConfig, findGitRoot, validateProjectRoot, DEFAULT_PROJECT_CONFIG };
```

- [ ] **Step 6.4: Run tests — should pass**

```bash
cd /path/to/big-wave/packages/mcp-server
node --test test/mcp-server.test.js
```

Expected: all tests pass (the `findGitRoot` null test may vary by environment — that's acceptable).

- [ ] **Step 6.5: Add the same functions + lazy check to `index.js`**

In `big-wave/packages/mcp-server/index.js`, after the `frontendBase` constant (around line 70), add:

```js
// ─── Project root resolution + lazy config ────────────────────────────────────

// ensureProjectConfig — keep in sync with packages/cli/lib/project-config.js
// Last synced: v1.0.7
// IMPORTANT: this string must be byte-for-byte identical to DEFAULT_PROJECT_CONFIG
// in packages/cli/lib/project-config.js. The contract tests enforce this.
const DEFAULT_PROJECT_CONFIG = `version: 1
review:
  enabled: true
  categories:
    # Default 8 categories — all scored 1-10 by the adversarial model.
    # All weights are equal by default. Increase a weight to emphasize a category.
    # Weights must be positive integers >= 1.
    - name: security
      weight: 1
    - name: correctness
      weight: 1
    - name: performance
      weight: 1
    - name: stability
      weight: 1
    - name: ux_drift
      weight: 1
    - name: outcome_drift
      weight: 1
    - name: missing_tests
      weight: 1
    - name: scope_creep
      weight: 1
    # Add custom categories:
    # - name: accessibility
    #   description: WCAG 2.1 AA compliance
    #   weight: 1
  auto_review:
    plan_files: true    # auto-trigger review after writing plan files
    code_output: false  # auto-trigger review after significant code output
  cost_cap_daily_usd: 5.0
  max_rounds: 3
  # rule_apply_mode: "direct"  # "direct" = write rules on confirm; "pr" = create branch + PR
control_plane:
  health_check_interval: 20  # seconds between health checks
  show_cost: true
  show_recommendations: true
`;

const DEFAULT_LOCAL_CONFIG = `# .movp/config.local.yaml — personal overrides (gitignored)
# Overrides .movp/config.yaml for your local environment only.
# Example:
# review:
#   enabled: false
`;

function parseDefaultSections(yamlText) {
  const lines = yamlText.split("\n");
  const sections = [];
  let current = null;
  for (const line of lines) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):/);
    if (m) {
      if (current) sections.push(current);
      current = { key: m[1], lines: [line] };
    } else if (current) {
      current.lines.push(line);
    }
  }
  if (current) sections.push(current);
  return sections.map(s => ({ key: s.key, text: s.lines.join("\n") }));
}

function sectionExists(existingText, key) {
  return new RegExp("^" + key + ":", "m").test(existingText);
}

function mcpEnsureProjectConfig(root) {
  const movpDir = path.join(root, ".movp");
  try {
    fs.mkdirSync(movpDir, { recursive: true });

    const configPath = path.join(movpDir, "config.yaml");
    if (!fs.existsSync(configPath)) {
      fs.writeFileSync(configPath, DEFAULT_PROJECT_CONFIG);
      process.stderr.write("[movp-mcp] Created " + configPath + " with defaults\n");
    } else {
      const existing = fs.readFileSync(configPath, "utf8");
      const defaultSections = parseDefaultSections(DEFAULT_PROJECT_CONFIG);
      const added = [];
      for (const section of defaultSections) {
        if (!sectionExists(existing, section.key)) {
          fs.appendFileSync(configPath, "\n# Added by MoVP — new in schema\n" + section.text, "utf8");
          added.push(section.key);
        }
      }
      if (added.length > 0) {
        process.stderr.write("[movp-mcp] Updated " + configPath + " — added sections: " + added.join(", ") + "\n");
      }
    }

    const localConfigPath = path.join(movpDir, "config.local.yaml");
    const detectedFrontendUrl = process.env.MOVP_FRONTEND_URL || stored.MOVP_FRONTEND_URL || "https://host.mostviableproduct.com";
    const frontendUrlLine = `\n# Frontend URL — used by the MCP server to construct settings links\nMOVP_FRONTEND_URL: "${detectedFrontendUrl}"\n`;
    if (!fs.existsSync(localConfigPath)) {
      fs.writeFileSync(localConfigPath, DEFAULT_LOCAL_CONFIG + frontendUrlLine);
    } else {
      const existingLocal = fs.readFileSync(localConfigPath, "utf8");
      if (!existingLocal.includes("MOVP_FRONTEND_URL")) {
        fs.appendFileSync(localConfigPath, frontendUrlLine);
      }
    }

    const gitignorePath = path.join(root, ".gitignore");
    const gitignoreEntry = ".movp/config.local.yaml";
    let gitignore = fs.existsSync(gitignorePath) ? fs.readFileSync(gitignorePath, "utf8") : "";
    if (!gitignore.includes(gitignoreEntry)) {
      fs.appendFileSync(gitignorePath, "\n# MoVP local config\n" + gitignoreEntry + "\n.env.movp\n*.bak\n");
    }
  } catch (e) {
    process.stderr.write("[movp-mcp] Warning: could not create .movp/config.yaml: " + e.message + "\n");
    process.stderr.write("[movp-mcp] To fix: check directory permissions, or set MOVP_PROJECT_ROOT to a writable project directory.\n");
  }
}

function findGitRoot(startDir) {
  const home = os.homedir();
  let dir = path.resolve(startDir);
  while (true) {
    if (fs.existsSync(path.join(dir, ".git"))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir || dir === home) return null;
    dir = parent;
  }
}

// Validate MOVP_PROJECT_ROOT at startup — fail fast if set but invalid.
// Per-request: root = validatedOverrideRoot || findGitRoot(process.cwd())
let validatedOverrideRoot = null;
const rootOverride = process.env.MOVP_PROJECT_ROOT;
if (rootOverride) {
  if (!path.isAbsolute(rootOverride)) {
    process.stderr.write("[movp-mcp] MOVP_PROJECT_ROOT is invalid: \"" + rootOverride + "\" is not an absolute path.\n");
    process.exit(1);
  }
  let resolved;
  try { resolved = fs.realpathSync(rootOverride); } catch {
    process.stderr.write("[movp-mcp] MOVP_PROJECT_ROOT is invalid: \"" + rootOverride + "\" does not exist.\n");
    process.exit(1);
  }
  try {
    if (!fs.statSync(resolved).isDirectory()) {
      process.stderr.write("[movp-mcp] MOVP_PROJECT_ROOT is invalid: \"" + rootOverride + "\" is not a directory.\n");
      process.exit(1);
    }
  } catch {
    process.stderr.write("[movp-mcp] MOVP_PROJECT_ROOT is invalid: \"" + rootOverride + "\" — must be an existing directory.\n");
    process.exit(1);
  }
  validatedOverrideRoot = resolved;
}
```

Add at module scope (after the `validatedOverrideRoot` block, before `rl.on`):

```js
// Suppress repeated "no root" warnings — log once per server run.
let noRootWarningLogged = false;
```

Then replace the existing `rl.on("line", async (line) => {` handler's opening with:

```js
rl.on("line", async (line) => {
  // Lazy project config — resolve root per request, create .movp/config.yaml if missing
  const root = validatedOverrideRoot || findGitRoot(process.cwd());
  if (root && !fs.existsSync(path.join(root, ".movp", "config.yaml"))) {
    mcpEnsureProjectConfig(root);
  } else if (!root && !noRootWarningLogged) {
    noRootWarningLogged = true;
    process.stderr.write("[movp-mcp] Could not determine project root — skipping .movp/config.yaml creation.\n");
    process.stderr.write("[movp-mcp] Set MOVP_PROJECT_ROOT to your project directory if needed.\n");
  }

  const trimmed = line.trim();
  // ... rest of existing handler unchanged
```

- [ ] **Step 6.6: Run all tests**

```bash
cd /path/to/big-wave/packages/mcp-server
node --test test/mcp-server.test.js
cd /path/to/big-wave/packages/cli
node --test test/cli.test.js
node --test test/project-config.test.js
```

Expected: all tests pass.

- [ ] **Step 6.7: Commit**

```bash
cd /path/to/big-wave
git add packages/mcp-server/index.js packages/mcp-server/test-helpers.js packages/mcp-server/test/mcp-server.test.js
git commit -m "feat(mcp-server): add lazy .movp/config.yaml creation with project root resolution"
```

---

## Task 7: Update slash command copy

**Files:**
- Modify: `mona-lisa/claude-plugin/commands/status.md`

- [ ] **Step 7.1: Update fallback messaging in `status.md`**

In `mona-lisa/claude-plugin/commands/status.md`, replace line 31–32:

```
If the config resource returns an error, show the error and note that the user should run `npx @movp/cli init` to configure MoVP.
```

with:

```
If the config resource returns an error, show the error and note:
- If credentials are missing (no MOVP_API_KEY / MOVP_URL): "run `npx @movp/cli login` to authenticate"
- If full setup is needed: "run `npx @movp/cli init` to configure MoVP globally"
- If only project config is missing: "MoVP will auto-create .movp/config.yaml on the next request — or check directory permissions if this persists"
```

- [ ] **Step 7.2: Commit**

```bash
cd /path/to/mona-lisa
git add claude-plugin/commands/status.md
git commit -m "fix(commands): update status.md fallback messaging for new init flow"
```

---

## Task 8: Final cleanup and verification

**Files:**
- Modify: `big-wave/packages/cli/bin/cli.js` (if any `noRules` references missed)

- [ ] **Step 8.1: Grep for stale `--no-rules` and `noRules` references**

```bash
cd /path/to/big-wave
grep -rn "no-rules\|noRules" packages/cli/ --include="*.js" --include="*.md"
```

```bash
cd /path/to/mona-lisa
grep -rn "no-rules\|noRules" . --include="*.js" --include="*.md" --exclude-dir=node_modules
```

Expected: zero matches. If any found, remove them.

- [ ] **Step 8.2: Grep for stale `writeMovpConfig` references**

```bash
cd /path/to/big-wave
grep -rn "writeMovpConfig" packages/ --include="*.js"
```

Expected: zero matches (the function no longer exists in `bin/cli.js`; it became `ensureProjectConfig` in `lib/project-config.js`).

- [ ] **Step 8.3: Run complete test suite**

```bash
cd /path/to/big-wave/packages/cli && node --test
cd /path/to/big-wave/packages/mcp-server && node --test test/mcp-server.test.js
```

Expected: all pass, zero failures.

- [ ] **Step 8.4: Manual smoke test — fresh install**

```bash
# In a new temp directory
mkdir /tmp/smoke-test && cd /tmp/smoke-test
git init
# Run init (will prompt for auth if no credentials exist)
npx @movp/cli init
# Verify ~/.claude/settings.json has extraKnownMarketplaces + enabledPlugins
cat ~/.claude/settings.json | grep -A5 "extraKnownMarketplaces"
cat ~/.claude/settings.json | grep "movp@movp"
# Verify no .movp/ was created in the project
ls -la .movp 2>/dev/null && echo "UNEXPECTED: .movp created" || echo "OK: no .movp during init"
```

- [ ] **Step 8.5: Manual smoke test — lazy config creation**

```bash
# Start the MCP server in the smoke-test repo and send an initialize request
cd /tmp/smoke-test
echo '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}},"id":1}' | \
  MOVP_URL=https://host.mostviableproduct.com MOVP_API_KEY=test node /path/to/big-wave/packages/mcp-server/index.js
# Verify .movp/config.yaml was created
ls -la .movp/config.yaml && echo "OK: config.yaml created" || echo "FAIL: config.yaml missing"
```

- [ ] **Step 8.6: Final commit if any cleanup was needed**

```bash
cd /path/to/big-wave
git add -p  # stage only cleanup changes
git commit -m "chore(cli): remove stale --no-rules / writeMovpConfig references"
```

---

## Verification Summary

| Scenario | Command | Expected |
|----------|---------|----------|
| Unit tests (CLI) | `cd packages/cli && node --test` | All pass |
| Unit tests (MCP) | `cd packages/mcp-server && node --test test/mcp-server.test.js` | All pass |
| Fresh init | `npx @movp/cli init` in new git repo | 2-step output, marketplace registered, no .movp/ created |
| Idempotent init | Run init twice | No duplicates in settings.json |
| Migration | Add movp@movp to project settings.json, run init | Entry removed, .bak created |
| Lazy config | Start MCP server in repo without .movp/ | config.yaml auto-created |
| Fail-open | `chmod 000 .movp/` then send MCP request | Server continues, stderr warning |
| MOVP_PROJECT_ROOT | `MOVP_PROJECT_ROOT=/tmp/smoke claude` | config.yaml created at specified path |
| Pre-release tag | init with CLI version `1.1.0-beta.1` | marketplace pinned to `main` |
