# User-Scoped Plugin Installation Design

**Date:** 2026-04-08  
**Status:** Approved for implementation planning  
**Repos affected:** `big-wave` (CLI + MCP server), `mona-lisa` (slash command copy)

---

## Context

Today, `movp init` installs the MoVP plugin as project-scoped — creating `.movp/config.yaml` in the current directory and requiring users to run `movp init` in every repository. Users with multiple repos face repeated manual setup.

This design changes the install flow so MoVP is installed once, globally, covering all current and future Claude Code projects.

---

## Goals

1. **User-scoped plugin** — the marketplace plugin (skills, slash commands) loads in every repo without per-repo action.
2. **Lazy project config** — `.movp/config.yaml` is auto-created on first `/movp` command use in a new repo, with the same defaults as today.
3. **One-command setup** — `movp init` authenticates and configures everything globally in two steps.
4. **Backward compatibility** — existing project-level configs are preserved; existing project-scoped installs are migrated.

**Known limitation:** Lazy config creation requires `.git` present (file or directory) in the project tree (or `MOVP_PROJECT_ROOT` set explicitly). Non-git workspaces (Mercurial, tarball-only, etc.) will not get auto-created `.movp/config.yaml` without the env override.

---

## Architecture

Claude Code manages `installed_plugins.json` automatically. The scope (`"user"` vs `"project"`) is determined by which `settings.json` file contains the `enabledPlugins` entry:

- `~/.claude/settings.json` → `scope: "user"` (loads in all projects)
- `<project>/.claude/settings.json` → `scope: "project"` (loads in that project only)

No code needs to write to `installed_plugins.json` directly. The CLI only needs to write `extraKnownMarketplaces` and `enabledPlugins` to `~/.claude/settings.json`.

---

## Section 1: Rewritten `movp init`

### New user experience

```
$ npx @movp/cli init

  MoVP CLI v1.0.0

  Step 1/2: Authentication
    ✓ Already authenticated (tenant: abc123...)
    — or —
    Opening browser for device login...
    ✓ Credentials saved

  Step 2/2: Configuring tools
    Claude Code:
      ~/.claude/settings.json → MCP server configured
      ~/.claude/settings.json → marketplace registered (movp@v1.0.0)
      ~/.claude/settings.json → plugin enabled (user-scoped)
    Cursor:
      ~/.cursor/mcp.json → MCP server configured
    Codex:
      ~/.codex/config.toml → MCP server added via codex mcp add

  ✓ MoVP is now active across all your projects.
    Run /movp status in any repo to verify.
```

### Migration output (existing users)

```
  Step 2/2: Configuring tools
    Claude Code: already configured (use --force to create new keys)
    Migrating to user-scoped install...
      ~/.claude/settings.json → marketplace registered (movp@v1.0.0)
      ~/.claude/settings.json → plugin enabled (user-scoped)
      ./Code/my-repo/.claude/settings.json → removed movp@movp from enabledPlugins
      ./Code/my-repo/.claude/settings.json.bak → backup created

  ✓ MoVP is now active across all your projects.
```

### Step ordering

1. Per-tool API setup (unchanged from today — mints keys, writes MCP config)
2. `registerMarketplace()` — writes `extraKnownMarketplaces` + `enabledPlugins` to `~/.claude/settings.json`
3. `migrateProjectScoped()` — removes `movp@movp` from project-level `enabledPlugins` in `cwd/.claude/settings.json`

Register before migrate: user-level config is established first. Each file gets a single read-modify-write.

### `registerMarketplace()` — new function in `bin/cli.js`

Calls `mergeJsonConfig(os.homedir(), snippet)` where `snippet.config_json` is:

```json
{
  "extraKnownMarketplaces": {
    "movp": {
      "source": { "source": "github", "repo": "MostViableProduct/movp-plugins", "tag": "v1.0.0" }
    }
  },
  "enabledPlugins": { "movp@movp": true }
}
```

Tag is derived from CLI `package.json` version as `"v" + version`. Pre-release versions (containing `-`) require `--channel=dev` to be passed to `movp init`. Without the flag, `init` exits with an error:

    Error: pre-release CLI versions require --channel=dev to install.
    This prevents accidentally pinning your MoVP plugin to the floating 'main' branch.
    Re-run: npx @movp/cli@<version> init --channel=dev

With `--channel=dev`, the tag is `"main"` and a loud warning banner is printed:

    ⚠ Channel: dev — plugin pinned to 'main' (pre-release build, not for production use)

`registerMarketplace()` itself is unchanged — it derives `tag = version.includes("-") ? "main" : "v" + version`. The gate lives in `runInit()`: check version before calling `registerMarketplace`.

### `migrateProjectScoped()` — new function in `bin/cli.js`

Scope: **only** `cwd/.claude/settings.json`. No tree walking, no home directory scan.

Steps:
1. Read `cwd/.claude/settings.json`. If absent, return.
2. Check `enabledPlugins["movp@movp"]`. If absent, return.
3. Write backup to `cwd/.claude/settings.json.bak`.
4. Remove only the `"movp@movp"` key from `enabledPlugins`. If `enabledPlugins` is now empty, remove the key.
5. Write updated JSON. Log the relative path and backup path.

Users with project-scoped entries in other repos: those entries are harmless (they won't conflict with the user-level entry). Users can clean them up manually or re-run `movp init` from each repo — one run per repo, scoped to that repo's `cwd/.claude/settings.json`.

### Extended `mergeJsonConfig()` in `lib/helpers.js`

Add `extraKnownMarketplaces` and `enabledPlugins` as allow-listed merge keys. Semantics:

- `extraKnownMarketplaces`: replace the `movp` sub-key wholesale (same pattern as `mcpServers.movp`). Do not deep-merge arbitrary nested keys.
- `enabledPlugins`: merge keys from incoming snippet into existing object.
- Same `.bak` creation, `0o600` chmod, and `BLOCKED` key guard as today.

Unit tests: add cases mirroring existing `mergeJsonConfig` coverage for these new key types.

### What's added to `runInit()`

- `--channel=dev` flag — required when running `movp init` with a pre-release CLI version. Add to arg parsing in the `command === "init"` block; pass as `{ channel }` option to `runInit()`. Gate: if `version.includes("-")` and `channel !== "dev"`, exit with error (see pre-release pinning above). If `channel === "dev"`, print a loud `⚠ Channel: dev` banner before calling `registerMarketplace()`.

### What's removed from `runInit()`

- `writeMovpConfig(cwd, noRules)` call (line 949)
- `--no-rules` flag — no longer relevant; remove from arg parsing, help text, and all docs

Grep before shipping: `--no-rules`, `noRules`, `--channel` across both repos and README.

### What's removed from `runInit()` Step 2 label

Changes "Step 1/3 … 2/3 … 3/3" to "Step 1/2 … 2/2".

### `isAlreadyConfigured()` behavior

The "already configured" check only gates API key minting. `registerMarketplace()` and `migrateProjectScoped()` always run, regardless of whether the tool was already configured.

### Partial-failure messaging

If any tool setup fails (`failCount > 0`) or marketplace registration failed, report auth status, marketplace status, and per-tool status independently. Do not print the "active across all projects" success line if failCount > 0 or marketplace registration failed. Print targeted retry guidance instead.

### Messaging accuracy

- "MoVP is now active across all your projects" applies to Claude Code and Cursor (global MCP config). Codex is also machine-wide but via its own config mechanism — copy is accurate for all three.
- Status messages print the actual target file per tool: `~/.claude/settings.json` (Claude Code), `~/.cursor/mcp.json` (Cursor), `~/.codex/config.toml` (Codex).

---

## Section 2: Lazy Project Config Creation

### Problem

With `movp init` no longer creating `.movp/config.yaml`, new repos need project config on first use.

### Trigger

On each inbound JSON-RPC request, the MCP server checks whether `.movp/config.yaml` exists in the resolved project root. If it is missing, it calls `ensureProjectConfig(root)` before forwarding the request to the BFF. Once created, the file exists and subsequent checks are cheap `existsSync` calls that return immediately.

### Project root resolution

Priority order:
1. `MOVP_PROJECT_ROOT` env var — **must be an absolute path to an existing directory**. Validated via `fs.realpathSync` (resolves symlinks; trailing slashes stripped). If set but invalid (not absolute, not a directory, does not exist), fail fast:
   ```
   [movp-mcp] MOVP_PROJECT_ROOT is invalid: "/bad/path" — must be an existing directory.
   ```
2. `process.cwd()` — **only if a `.git` present (file or directory) in `cwd` or any ancestor up to `os.homedir()`**

If neither yields a valid project root (no `.git` found, no env override), skip lazy config creation and log to stderr:

```
[movp-mcp] Could not determine project root — skipping .movp/config.yaml creation.
[movp-mcp] Run MoVP from a git checkout, or set MOVP_PROJECT_ROOT=/path/to/project
[movp-mcp] before starting Claude to enable automatic config creation.
```

Git root detection uses two methods in order:

1. **`execFileSync("git", ["rev-parse", "--show-toplevel"], ...)`** (primary) — uses `child_process.execFileSync` with an explicit argument array (no shell invocation, no injection surface). Options: `{ cwd: startDir, timeout: 500, encoding: "utf8" }`. If this succeeds, use the trimmed result as the project root. Correctly handles git worktrees, nested submodule layouts, and repos with non-standard structures.

2. **`existsSync` walk** (fallback) — used when `execFileSync` throws (non-git directory, `git` not on PATH) or times out. Walk from `startDir` upward checking for a `.git` entry (matches both `.git` **directory** and `.git` **file** for worktrees), stopping at `os.homedir()` or filesystem root.

This ensures worktrees and nested layouts resolve correctly while remaining safe in environments where `git` is unavailable.

### Check per request (no caching flag)

Use `fs.existsSync(path.join(root, ".movp", "config.yaml"))` on each request. No `configEnsured` boolean. The stat call is negligible cost; caching by resolved path introduces fragility if cwd is wrong on the first request.

### `ensureProjectConfig(root)` — new module

Location: `packages/cli/lib/project-config.js`

**Rationale:** `lib/helpers.js` is side-effect-free (no FS writes, no logging). `ensureProjectConfig` does both. A separate module preserves that contract.

Exports: `ensureProjectConfig(root)` and the `DEFAULT_PROJECT_CONFIG` / `DEFAULT_LOCAL_CONFIG` constants.

Logic: identical to today's `writeMovpConfig()` minus the `noRules` parameter:
- Create `.movp/config.yaml` if absent (full default content)
- Additive section merge if file exists
- Create `.movp/config.local.yaml` if absent; append `MOVP_FRONTEND_URL` if missing from existing file
- Append `.gitignore` entries idempotently

**Not** in `lib/helpers.js`. The canonical implementation lives only in `packages/cli/lib/project-config.js`. The MCP server inlines a copy directly in `index.js` — it does not import from this module and does not ship `project-config.js` as a separate file in the `mcp-server` package.

### Package dependency

`packages/mcp-server` does not depend on `packages/cli` today. Rather than adding that cross-dependency, inline `ensureProjectConfig` directly in `mcp-server/index.js` with the `DEFAULT_PROJECT_CONFIG` constant. The function is ~50 lines of `fs` operations with no CLI-specific imports.

To guard against drift, the MCP server copy must include a sync comment:

```js
// ensureProjectConfig — keep in sync with packages/cli/lib/project-config.js
// Last synced: v<cli-version>
```

And the test suite must include **shared golden-fixture contract tests** run against both implementations:
- Empty repo (no `.movp/`): verify `config.yaml` created with full default content
- Partial yaml (missing one top-level section): verify additive merge adds only the missing section
- Full `config.yaml` already present: verify no changes
- Missing `.gitignore`: verify entries appended
- `.gitignore` already contains entries: verify idempotent (no duplicates)

These fixture tests live in `packages/cli/test/project-config.test.js` and are re-run against the inlined MCP copy via a shared test helper. If both implementations pass the same fixtures, drift is caught automatically.

### Failure behavior

Fail open. If `ensureProjectConfig` throws (permissions error, full disk, invalid YAML during additive merge), log the error to stderr and proceed with the BFF request. Missing `.movp/config.yaml` is a degraded state — the BFF may serve defaults or return an error to the client, but the MCP server itself does not block the request. The stderr warning surfaces the issue.

**BFF contract when `.movp/config.yaml` is absent:** Before shipping, the BFF's behavior in this case must be verified and documented. Add a contract test in `packages/mcp-server/test/mcp-server.test.js` (Task 8, Step 8.7) that:
1. Sends a minimal JSON-RPC request through the MCP server with no `.movp/config.yaml` present.
2. Asserts the MCP server forwards the request without blocking.
3. Documents and asserts the actual BFF response — either "serves config defaults" (HTTP 200 with a config payload) or "returns a structured error" — locking down the behavior so it cannot silently change.

The test must be written against the real BFF (staging or local), not mocked. This closes the correctness gap identified in the adversarial review of the deferred scope.

```
[movp-mcp] Warning: could not create .movp/config.yaml: EACCES: permission denied
[movp-mcp] Proceeding without project config. To fix: check directory permissions, or set
[movp-mcp] MOVP_PROJECT_ROOT to a writable project directory.
```

Do not reference `npx @movp/cli init` in this message — `init` no longer creates `.movp/config.yaml`.

### Slash command copy update

In `claude-plugin/commands/status.md` (line 31):
- If credentials are missing: "run `npx @movp/cli login` to authenticate"
- If full setup is needed: "run `npx @movp/cli init` to configure MoVP"

---

## Files Modified

### `big-wave/packages/cli/bin/cli.js`
- Rewrite `runInit()`: remove `writeMovpConfig` call, add `registerMarketplace()` + `migrateProjectScoped()` calls, update step numbering and success messaging
- Add `registerMarketplace()` function
- Add `migrateProjectScoped()` function
- Add `--channel=dev` flag to arg parsing; add pre-release gate in `runInit()` before calling `registerMarketplace()`; print `⚠ Channel: dev` banner when `--channel=dev` is active
- Remove `--no-rules` flag from arg parsing and help text
- Import `ensureProjectConfig` from `lib/project-config.js` (for any CLI code that still uses it, e.g. `--project` flag if added later)

### `big-wave/packages/cli/lib/helpers.js`
- Extend `mergeJsonConfig()`: add `extraKnownMarketplaces` and `enabledPlugins` merge keys

### `big-wave/packages/cli/lib/project-config.js` *(new file)*
- Export `ensureProjectConfig(root)`, `DEFAULT_PROJECT_CONFIG`, `DEFAULT_LOCAL_CONFIG`
- Extracted from `writeMovpConfig()` in `bin/cli.js`

### `big-wave/packages/cli/test/cli.test.js`
- Add `mergeJsonConfig` tests for `extraKnownMarketplaces` and `enabledPlugins`
- Add `migrateProjectScoped` tests: absent file, key present, empty `enabledPlugins` after removal
- Add `registerMarketplace` tests: fresh install, idempotent re-run, pre-release tag handling

### `big-wave/packages/cli/test/project-config.test.js` *(new file)*
- Golden-fixture contract tests for `ensureProjectConfig`: empty repo, partial yaml, full yaml present, missing gitignore, idempotent gitignore
- Test helper exports a shared fixture runner so `mcp-server` tests can re-run the same cases against the inlined copy

### `big-wave/packages/mcp-server/index.js`
- Add inlined `ensureProjectConfig` (copied from `lib/project-config.js`) with sync comment: `// keep in sync with packages/cli/lib/project-config.js — last synced: v<version>`
- Add inlined `DEFAULT_PROJECT_CONFIG` constant
- Add `MOVP_PROJECT_ROOT` validation: absolute path, existing directory, `fs.realpathSync`; fail fast with clear stderr if invalid
- Add git root detection: `execFileSync("git", ["rev-parse", "--show-toplevel"], ...)` primary; `existsSync` walk fallback
- Call `ensureProjectConfig` when `config.yaml` is absent before forwarding each request; fail open on error
- Update fail-open stderr copy: no reference to `npx @movp/cli init`
- Update "no root" stderr to 3-line actionable message (run from git checkout or set `MOVP_PROJECT_ROOT`)

### `big-wave/packages/mcp-server/test/mcp-server.test.js` *(new or extend)*
- Re-run golden-fixture contract tests against inlined `ensureProjectConfig` using shared test helper
- Add project root resolution tests: valid env override, invalid env (bad path, not a directory), `git rev-parse` succeeds, `git rev-parse` fails → fallback to `existsSync` walk, no `.git` found (skip + log)
- Add BFF contract test: send minimal JSON-RPC with no `.movp/config.yaml`; assert MCP server forwards without blocking; document and assert actual BFF response shape

### `mona-lisa/claude-plugin/commands/status.md`
- Update fallback messaging: distinguish `login` vs `init` based on what's missing

---

## Verification

1. **Fresh install path:**
   ```
   npx @movp/cli init
   # Verify ~/.claude/settings.json has extraKnownMarketplaces + enabledPlugins
   # Verify ~/.config/movp/credentials exists
   # Start claude in a new repo — verify /movp status loads and .movp/config.yaml is created
   ```

2. **Idempotency:**
   ```
   npx @movp/cli init  # run twice
   # Verify settings.json not corrupted, no duplicate marketplace entries
   ```

3. **Migration:**
   ```
   # Manually add movp@movp to <project>/.claude/settings.json enabledPlugins
   npx @movp/cli init
   # Verify movp@movp removed from project settings, .bak created
   # Verify user-level settings unchanged
   ```

4. **Lazy config:**
   ```
   # Delete .movp/config.yaml from any repo
   # Run /movp review
   # Verify .movp/config.yaml recreated with correct defaults
   # Verify .gitignore updated
   ```

5. **Fail-open:**
   ```
   chmod 000 <project>/.movp/
   # Run /movp review
   # Verify MCP still forwards request, stderr shows warning
   ```

6. **MOVP_PROJECT_ROOT override:**
   ```
   MOVP_PROJECT_ROOT=/path/to/project claude
   # Run /movp status
   # Verify .movp/config.yaml created at /path/to/project/.movp/config.yaml
   ```

7. **Pre-release gate:**
   ```
   # Simulate pre-release CLI version by temporarily changing package.json version to "1.1.0-beta.1"
   node bin/cli.js init
   # Verify exits with error message referencing --channel=dev
   node bin/cli.js init --channel=dev
   # Verify "⚠ Channel: dev" banner printed, marketplace pinned to 'main'
   ```

8. **BFF contract (no .movp/config.yaml):**
   ```
   # Delete .movp/config.yaml, send JSON-RPC request via MCP server
   # Verify MCP forwards request without blocking
   # Document actual BFF response shape in this section after first run
   ```
