# MoVP Telemetry Events

Events emitted by the MoVP plugin's diagnostic surfaces. All events use the `movp_report_context` MCP tool (the existing telemetry sink exposed by `@movp/mcp-server`).

## Event Schema

```json
{
  "event_code": "MCP_STATUS_OK",
  "source": "status" | "doctor" | "session_probe",
  "step": 3,
  "mcp_server_version": "0.1.7",
  "plugin_version": "1.1.0",
  "session_id": "<session>"
}
```

`step` is only present for doctor events. `mcp_server_version` is omitted when the manifest resource is unreachable.

Events never contain user prompts, file contents, or code output — only diagnostic metadata.

## Events by Surface

### `/movp:status`

| Event code | Emitted when |
|---|---|
| `MCP_STATUS_OK` | All declared tools present in live manifest |
| `MCP_STATUS_DEGRADED` | One or more declared tools absent from live manifest |

`MCP_STATUS_DEGRADED` includes `missing_tools_count: N` in the payload.

### SessionStart hook

| Event code | Emitted when |
|---|---|
| `MCP_PROBE_OK` | Manifest resource readable and `tools[]` non-empty |
| `MCP_PROBE_FAILED` | Manifest read failed or `tools[]` empty |

`MCP_PROBE_FAILED` includes `reason: "read_error" | "empty_tools"`. If the probe itself throws (permission denied, timeout > 2s), no event is emitted — the session starts normally with no output.

### `/movp:doctor`

One event per check that fails, plus a terminal summary:

| Event code | Check | Payload extras |
|---|---|---|
| `MCP_MISSING_CONFIG` | 1 — `.mcp.json` with `mcpServers.movp` | — |
| `MCP_COMMAND_NOT_FOUND` | 2 — `command` resolves on PATH | `command: "<value>"` |
| `MCP_ARGS_PATH_MISSING` | 3 — `args[0]` path exists | `path: "<value>"` |
| `MCP_CREDENTIALS_MISSING` | 4 — `MOVP_URL` + `MOVP_API_KEY` set or `~/.config/movp/credentials` exists | — |
| `MCP_MANIFEST_READ_FAILED` | 5 — `movp://movp/manifest` readable | `error: "<message>"` |
| `MCP_TOOLSET_INCOMPLETE` | 6 — Declared tools ⊆ manifest tools | `missing_tools: [...]` |
| `MCP_VERSION_DRIFT` | 7 — Installed version matches `manifest.pinned_mcp_server_version` | `installed: "X"`, `pinned: "Y"` |
| `DOCTOR_RUN` | Terminal — always emitted at end of doctor run | `failed_checks: [codes]` (empty array on full pass) |

## Alert Thresholds

Thresholds are calibrated to current fleet size. Confirm and commit final values before enabling alerts.

| Event | Owner | Paging threshold | Non-paging alert |
|---|---|---|---|
| `MCP_PROBE_FAILED` | MoVP platform oncall | ≥5% of distinct sessions in any rolling 1h window | >1% for 24h |
| `MCP_VERSION_DRIFT` | MoVP platform oncall | Any paying tenant >1 pinned minor version behind | Any tenant >0 pinned patch versions behind for 7d |
| `MCP_MANIFEST_READ_FAILED` (from `/movp:status`) | MoVP platform oncall | ≥10 distinct tenants in 1h | ≥3 distinct tenants in 24h |
| `DOCTOR_RUN{failed_checks!=[]}` | MoVP onboarding / support | None (diagnostic only) | >20 runs/day with `MCP_MISSING_CONFIG` → docs/onboarding regression |

Events without a defined alert are still emitted but never page.

## Sink

Events are written via `movp_report_context`. If the telemetry sink is unavailable (user skipped `npx @movp/cli init`), events are dropped silently — acceptable because the same user has bigger problems that `/movp:doctor` already surfaces.
