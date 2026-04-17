---
description: "Show MoVP connection and configuration status"
required_tools: []
required_resources: ["movp://movp/config", "movp://movp/manifest"]
---
Read the MoVP effective config by accessing the `movp://movp/config` MCP resource, then present a clean status summary.

If the config contains a `version_warning` field, show it prominently at the very top before any sections.

Format the output as follows:

```
[MoVP] Status

<if version_warning is present, show: "WARNING: <version_warning>" on its own line here>

MCP Tools
  Registered:  <N> — trigger_review, get_review_status, ... (from live movp://movp/manifest)
  Missing:     <tools declared in required_tools of shipped skills but absent from manifest> or "none"

Connection
  Workdesk:  <WORKDESK_SERVICE_URL or "not configured">
  Tenant:    <tenant ID from WORKDESK_TENANT or "not configured">

Settings
  URL:  <settings_url or "not available">

Review Config
  Enabled:        <yes/no>
  Auto-review:    plan files=<yes/no>  code output=<yes/no>
  Max rounds:     <max_rounds>
  Cost cap/day:   $<cost_cap_daily_usd>

Categories (<N> configured, all weights equal / weights vary)
  <name> (weight: <w>)
  ...

Control Plane
  Health check interval:  <N>s
  Show cost:              <yes/no>
  Show recommendations:   <yes/no>

MCP Version
  Installed:  <mcp_installed_version or "unknown">
  Pinned:     <mcp_pinned_version or "not checked">
  Status:     <if version_warning is present, show the warning text; otherwise "OK">
```

If the config resource returns an error, show the error and note:
- If credentials are missing (no MOVP_API_KEY / MOVP_URL): "run `npx @movp/cli login` to authenticate"
- If full setup is needed: "run `npx @movp/cli init` to configure MoVP globally"
- If only project config is missing: "MoVP will auto-create .movp/config.yaml on the next request — or check directory permissions if this persists"

If WORKDESK_SERVICE_URL or WORKDESK_TENANT environment variables are not set, note that the MCP server is not fully configured.

Read both `movp://movp/config` and `movp://movp/manifest` MCP resources. Do not call any other tools.

The "Missing" field in MCP Tools compares declared `required_tools` from shipped skills against the **live `movp://movp/manifest` resource** (not the committed `claude-plugin/manifest.json`). A non-empty Missing list means the running MCP server is missing tools — run `/movp:doctor` to diagnose. It does NOT mean the plugin release is misconfigured (that's what CI CHECK 11 catches separately).

If `movp://movp/manifest` is unreadable (server not started, credentials wrong, etc.), show in the MCP Tools section: `Registered: 0 — (MCP server unreachable)` and `Missing: unknown — run /movp:doctor`.

After displaying status, emit `MCP_STATUS_OK` or `MCP_STATUS_DEGRADED` telemetry by calling `movp_report_context` (best-effort, do not fail if unavailable) with:
- task_description: "status_check"  
- recent_changes: JSON of {"status": "ok"|"degraded", "missing_count": N}
