---
description: "Diagnose MoVP MCP server configuration and connectivity"
required_tools: []
required_resources: ["movp://movp/manifest"]
---

Run the following 7 checks in sequence. For each, print `[PASS]` or `[FAIL] <event_code>` followed by the result. After all checks, if any failed, print a summary with the exact remediations needed. Emit a `DOCTOR_RUN` telemetry event via `movp_report_context` at the end (best-effort, do not fail if this tool is unavailable).

## Check 1 — MCP config exists
Use the Bash tool to check: does `~/.claude.json` contain `mcpServers.movp`? Or does `./.mcp.json` exist in the project root with `mcpServers.movp`?

If neither: `[FAIL] MCP_MISSING_CONFIG` — MCP server is not registered. Run `npx @movp/cli init` in your project directory.

## Check 2 — Server command on PATH
From Check 1, extract the `command` field of `mcpServers.movp`. Use Bash to verify it resolves: `which <command>` or check if it's `node`/`npx` (always available).

If command not found: `[FAIL] MCP_COMMAND_NOT_FOUND` — Run `npx @movp/cli init` to reconfigure.

## Check 3 — Server binary path exists
From Check 1, extract the first element of `args`. If it is an absolute path (starts with `/`), use Bash to verify: `test -f <path>`.

If path doesn't exist: `[FAIL] MCP_ARGS_PATH_MISSING` — Path `<the bad path>` does not exist. Run `npx @movp/cli init` to regenerate with the correct path.

If args[0] is not an absolute path (e.g. it's a package name like `@movp/mcp-server` for the npx form) — `[PASS]` this check.

## Check 4 — Credentials present
Use Bash to check: is `MOVP_URL` set in the environment? OR does `~/.config/movp/credentials` exist?

If neither: `[FAIL] MCP_CREDENTIALS_MISSING` — Run `npx @movp/cli init` to authenticate.

## Check 5 — MCP manifest readable
Read the `movp://movp/manifest` MCP resource.

If it fails: `[FAIL] MCP_MANIFEST_READ_FAILED` — print the exact error. Run `npx @movp/cli init` and restart Claude Code.

If it succeeds: `[PASS]`.

## Check 6 — All required tools present
From Check 5 manifest, extract the `tools` array. Collect all `required_tools` declared across the shipped skills (movp-review: trigger_review, get_review_status, resolve_review). Assert each is in the manifest tools list.

If any are missing: `[FAIL] MCP_TOOLSET_INCOMPLETE` — list the missing tool names. Run `npx @movp/cli init` to update.

## Check 7 — MCP server version matches pinned version
From the `movp://movp/config` MCP resource, extract `mcp_installed_version` and `mcp_pinned_version`. If `version_warning` is present, show it.

If versions differ: `[FAIL] MCP_VERSION_DRIFT` — show the installed vs pinned versions. Run `npx @movp/cli init` to update.

If `movp://movp/config` is unreadable (server down), note that and skip this check.

## Output format

After all checks:
```
MoVP Doctor — <N>/7 checks passed

Check 1: [PASS/FAIL MCP_MISSING_CONFIG]  MCP config
Check 2: [PASS/FAIL MCP_COMMAND_NOT_FOUND]  Server command
Check 3: [PASS/FAIL MCP_ARGS_PATH_MISSING]  Server binary path
Check 4: [PASS/FAIL MCP_CREDENTIALS_MISSING]  Credentials
Check 5: [PASS/FAIL MCP_MANIFEST_READ_FAILED]  MCP manifest
Check 6: [PASS/FAIL MCP_TOOLSET_INCOMPLETE]  Required tools
Check 7: [PASS/FAIL MCP_VERSION_DRIFT]  MCP version

<If any FAIL:>
Remediations:
  <Check N> — <exact remediation text>

<For MCP_MISSING_CONFIG or MCP_MANIFEST_READ_FAILED:>
  Run /movp:status for additional diagnostics.
```

Emit DOCTOR_RUN telemetry at the end by calling `movp_report_context` (if available) with:
- task_description: "doctor_run"
- recent_changes: JSON string of failed event codes, e.g. `{"failed_checks":["MCP_MISSING_CONFIG"]}`
