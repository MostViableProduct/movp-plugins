---
description: "Show MoVP connection and configuration status"
required_tools: [movp_report_context]
required_resources: ["movp://movp/config", "movp://movp/manifest"]
---
Read the MoVP effective config by accessing the `movp://movp/config` MCP resource, then present a clean status summary.

If the config contains a `version_warning` field, show it prominently at the very top before any sections.

---

## Step 1 — Collect plugin-version info (Bash preamble)

Before reading MCP resources, collect plugin-version data. Run the following as **one Bash invocation** so variables persist across sub-steps. Do not emit any output during this preamble — the values feed the rendered summary below.

Failure paths set one of these `plugin_check_error_code` values: `OK`, `PLUGIN_JSON_NOT_FOUND`, `PLUGIN_JSON_PARSE_ERROR`, `REGISTRY_PARSE_ERROR`, `NETWORK_FETCH_FAILED`, `LATEST_PARSE_ERROR`, `VERSION_COMPARE_INVALID`. Never silently emit `unknown` — always set a named code. Each code maps to a distinct recovery hint so users are never sent down the wrong path.

```bash
set -o pipefail

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$'

# ── Step 1A — Resolve installed plugin version (registry → $CLAUDE_PLUGIN_ROOT plugin.json fallback) ──
#   The registry (~/.claude/plugins/installed_plugins.json) is authoritative: it stores the
#   version string directly on each entry, so no plugin.json read is needed for the normal path.
#   $CLAUDE_PLUGIN_ROOT is the dev-context fallback (e.g. running the plugin from a worktree).
SOURCES_TRIED=""
INSTALLED_VER=""
INSTALLED_SOURCE=""
INSTALLED_ERROR="OK"

REGISTRY="$HOME/.claude/plugins/installed_plugins.json"
SOURCES_TRIED="registry"
if [[ -f "$REGISTRY" ]]; then
  # Python prints either the resolved version (success), a single sentinel line
  # "__REG_PARSE_ERROR__" (malformed JSON / unexpected shape), or nothing (no
  # movp@movp entry). This split keeps corruption from being misreported as
  # "plugin not installed".
  REG_OUT=$(python3 - "$REGISTRY" "$PWD" <<'PY' 2>/dev/null
import json, os, re, sys
reg_path, cwd = sys.argv[1], sys.argv[2]
SEM = re.compile(r"^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$")
try:
    reg = json.load(open(reg_path))
except Exception:
    print("__REG_PARSE_ERROR__"); sys.exit(0)
if not isinstance(reg, dict):
    print("__REG_PARSE_ERROR__"); sys.exit(0)
plugins = reg.get("plugins", {})
if not isinstance(plugins, dict):
    print("__REG_PARSE_ERROR__"); sys.exit(0)
entries = plugins.get("movp@movp")
if entries is None:
    sys.exit(0)  # not installed — distinct from corruption
if not isinstance(entries, list):
    print("__REG_PARSE_ERROR__"); sys.exit(0)
ranked = []
for e in entries:
    if not isinstance(e, dict):
        continue
    v = e.get("version", "")
    if not SEM.match(v):
        continue
    pp = e.get("projectPath") or ""
    try:
        same_project = pp and os.path.realpath(pp) == os.path.realpath(cwd)
    except Exception:
        same_project = False
    # priority: project-scoped matching cwd < user-scoped < anything else
    if same_project:
        prio = 0
    elif e.get("scope") == "user":
        prio = 1
    else:
        prio = 2
    ranked.append((prio, v))
if ranked:
    ranked.sort()
    print(ranked[0][1])
PY
)
  if [[ "$REG_OUT" == "__REG_PARSE_ERROR__" ]]; then
    INSTALLED_ERROR="REGISTRY_PARSE_ERROR"
  elif [[ -n "$REG_OUT" ]]; then
    INSTALLED_VER="$REG_OUT"
    INSTALLED_SOURCE="registry"
  fi
fi

# Dev-context fallback: $CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json
# Also serves as a recovery path when the registry itself is corrupt.
if [[ -z "$INSTALLED_VER" ]]; then
  SOURCES_TRIED="$SOURCES_TRIED,\$CLAUDE_PLUGIN_ROOT"
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" ]]; then
    INSTALLED_VER=$(python3 -c '
import json, re, sys
try:
    v = json.load(open(sys.argv[1])).get("version", "")
    if re.match(r"^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$", v):
        print(v)
except Exception:
    sys.exit(2)
' "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
    if [[ -n "$INSTALLED_VER" ]]; then
      # Annotate when we recovered via fallback after a registry problem.
      if [[ "$INSTALLED_ERROR" == "REGISTRY_PARSE_ERROR" ]]; then
        INSTALLED_SOURCE="\$CLAUDE_PLUGIN_ROOT (registry malformed)"
      else
        INSTALLED_SOURCE="\$CLAUDE_PLUGIN_ROOT"
      fi
      INSTALLED_ERROR="OK"  # we resolved a version; don't shadow success with the registry error
    else
      INSTALLED_ERROR="PLUGIN_JSON_PARSE_ERROR"
    fi
  fi
fi

# Only downgrade to PLUGIN_JSON_NOT_FOUND if nothing else has flagged an error.
if [[ -z "$INSTALLED_VER" && "$INSTALLED_ERROR" == "OK" ]]; then
  INSTALLED_ERROR="PLUGIN_JSON_NOT_FOUND"
fi

# ── Step 1B — Resolve latest published version (cache → fetch → stale-cache fallback) ──
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/movp"
CACHE_FILE="$CACHE_DIR/latest_version.json"
CACHE_TTL=900  # 15 min
LATEST_URL="${MOVP_STATUS_LATEST_URL:-https://raw.githubusercontent.com/MostViableProduct/movp-plugins/main/.claude-plugin/marketplace.json}"
LATEST_VER=""
LATEST_SOURCE=""
LATEST_CHECKED_AT=""
LATEST_ERROR="OK"
NOW_EPOCH=$(date +%s)
NOW_ISO=$(python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')

CACHED_VER=""
CACHED_EPOCH=0
CACHED_ISO=""
if [[ -f "$CACHE_FILE" ]]; then
  # Read three newline-delimited fields: version, epoch, ISO. Avoids eval/shlex
  # gymnastics that break under macOS bash 3.2.
  { read -r CACHED_VER; read -r CACHED_EPOCH; read -r CACHED_ISO; } < <(python3 - "$CACHE_FILE" <<'PY' 2>/dev/null
import json, re, sys
SEM = re.compile(r"^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$")
try:
    d = json.load(open(sys.argv[1]))
    v = str(d.get("version", ""))
    e = int(d.get("checked_at_epoch", 0) or 0)
    i = str(d.get("checked_at", ""))
    if not SEM.match(v):
        v = ""  # invalidate
    print(v)
    print(e)
    print(i)
except Exception:
    print("")
    print(0)
    print("")
PY
  )
  # Guard against non-integer epoch
  [[ "$CACHED_EPOCH" =~ ^[0-9]+$ ]] || CACHED_EPOCH=0
fi

CACHE_AGE=$(( NOW_EPOCH - CACHED_EPOCH ))

if [[ -n "$CACHED_VER" && $CACHED_EPOCH -gt 0 && $CACHE_AGE -lt $CACHE_TTL ]]; then
  LATEST_VER="$CACHED_VER"
  LATEST_SOURCE="cache"
  LATEST_CHECKED_AT="$CACHED_ISO"
else
  FETCH_BODY=$(curl -fsS --max-time 5 "$LATEST_URL" 2>/dev/null); CURL_RC=$?
  if [[ $CURL_RC -eq 0 && -n "$FETCH_BODY" ]]; then
    PARSED=$(printf '%s' "$FETCH_BODY" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
    v = d["plugins"][0]["version"]
    assert re.match(r"^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$", v)
    print(v)
except Exception:
    sys.exit(2)
' 2>/dev/null)
    if [[ -n "$PARSED" ]]; then
      LATEST_VER="$PARSED"
      LATEST_SOURCE="marketplace.json"
      LATEST_CHECKED_AT="$NOW_ISO"
      mkdir -p "$CACHE_DIR"
      TMP="$CACHE_FILE.tmp.$$"
      if python3 -c '
import json, sys
json.dump({"version": sys.argv[1], "checked_at_epoch": int(sys.argv[2]), "checked_at": sys.argv[3]}, open(sys.argv[4],"w"))
' "$LATEST_VER" "$NOW_EPOCH" "$NOW_ISO" "$TMP" 2>/dev/null; then
        mv "$TMP" "$CACHE_FILE"
      else
        rm -f "$TMP"
      fi
    else
      # Fetch succeeded but the payload was not the expected marketplace.json shape.
      # Distinct from curl failures — don't recommend "retry when network is back."
      LATEST_ERROR="LATEST_PARSE_ERROR"
    fi
  else
    if [[ -n "$CACHED_VER" && $CACHED_EPOCH -gt 0 ]]; then
      LATEST_VER="$CACHED_VER"
      LATEST_SOURCE="cache-stale"
      LATEST_CHECKED_AT="$CACHED_ISO"
      LATEST_ERROR="NETWORK_FETCH_FAILED:curl=$CURL_RC"
    else
      LATEST_ERROR="NETWORK_FETCH_FAILED:curl=$CURL_RC"
    fi
  fi
fi

# ── Step 1C — Compare and derive overall plugin_check_error_code ──
PLUGIN_CMP=""   # one of: current, behind, ahead, invalid
PLUGIN_CHECK_ERROR_CODE="OK"
if [[ "$INSTALLED_ERROR" != "OK" ]]; then
  PLUGIN_CHECK_ERROR_CODE="$INSTALLED_ERROR"
elif [[ -z "$LATEST_VER" ]]; then
  # Preserve the specific latest-side failure code (LATEST_PARSE_ERROR vs NETWORK_FETCH_FAILED:curl=N).
  if [[ "$LATEST_ERROR" == "LATEST_PARSE_ERROR" ]]; then
    PLUGIN_CHECK_ERROR_CODE="LATEST_PARSE_ERROR"
  else
    PLUGIN_CHECK_ERROR_CODE="NETWORK_FETCH_FAILED"
  fi
else
  PLUGIN_CMP=$(python3 -c '
import re, sys
def key(v):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z0-9.-]+))?$", v)
    if not m: return None
    mmp = (int(m[1]), int(m[2]), int(m[3]))
    pre = m[4]
    if pre is None:
        return (mmp, (1,))  # release outranks any prerelease
    ids = []
    for p in pre.split("."):
        ids.append((0, int(p)) if p.isdigit() else (1, p))
    return (mmp, (0, tuple(ids)))
a, b = key(sys.argv[1]), key(sys.argv[2])
if a is None or b is None: print("invalid")
elif a < b: print("behind")
elif a > b: print("ahead")
else: print("current")
' "$INSTALLED_VER" "$LATEST_VER" 2>/dev/null)
  if [[ "$PLUGIN_CMP" == "invalid" ]]; then
    PLUGIN_CHECK_ERROR_CODE="VERSION_COMPARE_INVALID"
  fi
fi

# Human-readable cache-age suffix for the Latest: line
LATEST_SUFFIX=""
if [[ "$LATEST_SOURCE" == "cache" ]]; then
  AGE_MIN=$(( CACHE_AGE / 60 ))
  LATEST_SUFFIX="[cached ${AGE_MIN}m]"
elif [[ "$LATEST_SOURCE" == "cache-stale" ]]; then
  AGE_MIN=$(( CACHE_AGE / 60 ))
  LATEST_SUFFIX="[cached ${AGE_MIN}m, fetch failed]"
fi

# Surface for the render step below
echo "__MOVP_STATUS_VARS__"
printf 'INSTALLED_VER=%s\nLATEST_VER=%s\nLATEST_SUFFIX=%s\nLATEST_SOURCE=%s\nLATEST_CHECKED_AT=%s\nLATEST_ERROR=%s\nPLUGIN_CMP=%s\nPLUGIN_CHECK_ERROR_CODE=%s\nSOURCES_TRIED=%s\nLATEST_URL=%s\n' \
  "$INSTALLED_VER" "$LATEST_VER" "$LATEST_SUFFIX" "$LATEST_SOURCE" "$LATEST_CHECKED_AT" "$LATEST_ERROR" "$PLUGIN_CMP" "$PLUGIN_CHECK_ERROR_CODE" "$SOURCES_TRIED" "$LATEST_URL"
```

Capture the `__MOVP_STATUS_VARS__` block; do not print it to the user. Parse the key=value lines to feed the render step.

---

## Step 2 — Render the status summary

Format the output as follows:

```
[MoVP] Status

<if version_warning is present, show: "WARNING: <version_warning>" on its own line here>

MCP Tools
  Registered:  <N> — trigger_review, get_review_status, ... (from live movp://movp/manifest)
  Missing:     <tools declared in required_tools of shipped skills but absent from manifest> or "none"

Plugin Version
  Installed:  <INSTALLED_VER or "unknown (<PLUGIN_CHECK_ERROR_CODE>)">
  Latest:     <LATEST_VER or "unknown (<PLUGIN_CHECK_ERROR_CODE>)"> <LATEST_SUFFIX if any>
  Status:     <see rules below>

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

**Plugin Version → Status line rules:**

- `PLUGIN_CHECK_ERROR_CODE != "OK"` → `could not check (<PLUGIN_CHECK_ERROR_CODE>)` and, on the next indented line, a one-line recovery hint:
  - `PLUGIN_JSON_NOT_FOUND` → `Searched: <SOURCES_TRIED>. Run /plugin marketplace update to (re)install, or set $CLAUDE_PLUGIN_ROOT if running from a worktree.`
  - `PLUGIN_JSON_PARSE_ERROR` → `plugin.json at $CLAUDE_PLUGIN_ROOT has no valid semver "version" field.`
  - `REGISTRY_PARSE_ERROR` → `Registry at ~/.claude/plugins/installed_plugins.json is malformed or has an unexpected shape. Recover with /plugin marketplace update, or set $CLAUDE_PLUGIN_ROOT to bypass.`
  - `NETWORK_FETCH_FAILED` → `URL: <LATEST_URL>  curl exit: <code from LATEST_ERROR>. Retry once network is back.`
  - `LATEST_PARSE_ERROR` → `Fetched <LATEST_URL> but could not extract .plugins[0].version. Check the URL response manually.`
  - `VERSION_COMPARE_INVALID` → `Could not compare "<INSTALLED_VER>" vs "<LATEST_VER>".`
- `PLUGIN_CMP == "current"` → `OK (up to date)`
- `PLUGIN_CMP == "behind"` → `UPDATE AVAILABLE — <LATEST_VER>`, then on the next indented line:
  `Run: /plugin marketplace update  (or: brew upgrade movp  if installed via Homebrew)`
- `PLUGIN_CMP == "ahead"` → `ahead of main (dev build)`

---

## Step 3 — Error handling and absent MCP resources

If the `movp://movp/config` resource returns an error, show the error and note:
- If credentials are missing (no MOVP_API_KEY / MOVP_URL): "run `npx @movp/cli login` to authenticate"
- If full setup is needed: "run `npx @movp/cli init` to configure MoVP globally"
- If only project config is missing: "MoVP will auto-create .movp/config.yaml on the next request — or check directory permissions if this persists"

If WORKDESK_SERVICE_URL or WORKDESK_TENANT environment variables are not set, note that the MCP server is not fully configured.

Read both `movp://movp/config` and `movp://movp/manifest` MCP resources. Do not call any other tools except `movp_report_context` at the end.

The "Missing" field in MCP Tools compares declared `required_tools` from shipped skills against the **live `movp://movp/manifest` resource** (not the committed `claude-plugin/manifest.json`). A non-empty Missing list means the running MCP server is missing tools — run `/movp:doctor` to diagnose. It does NOT mean the plugin release is misconfigured (that's what CI CHECK 12 catches separately).

If `movp://movp/manifest` is unreadable (server not started, credentials wrong, etc.), show in the MCP Tools section: `Registered: 0 — (MCP server unreachable)` and `Missing: unknown — run /movp:doctor`.

A failure in the Plugin Version section must never block the rest of the summary from rendering.

---

## Step 4 — Telemetry

After displaying the status, emit `MCP_STATUS_OK` or `MCP_STATUS_DEGRADED` telemetry by calling `movp_report_context` (best-effort; do not fail if unavailable) with:

- `task_description`: `"status_check"`
- `recent_changes`: JSON string of:

```json
{
  "status": "ok" | "degraded",
  "missing_count": N,
  "plugin_installed": "<x.y.z>" | null,
  "plugin_latest": "<x.y.z>" | null,
  "plugin_stale": true | false | null,
  "plugin_check_error_code": "OK" | "PLUGIN_JSON_NOT_FOUND" | "PLUGIN_JSON_PARSE_ERROR" | "REGISTRY_PARSE_ERROR" | "NETWORK_FETCH_FAILED" | "LATEST_PARSE_ERROR" | "VERSION_COMPARE_INVALID",
  "plugin_latest_source": "marketplace.json" | "cache" | "cache-stale" | null,
  "plugin_latest_checked_at": "<ISO-8601 UTC>" | null
}
```

Field semantics:
- `null` means "field not applicable" (e.g., `plugin_latest=null` when the fetch failed and no cache existed). Never emit string literals like `"unknown"` — `null` is the unambiguous signal for fleet aggregation.
- `plugin_stale` is `null` whenever either version is `null` or `plugin_check_error_code != "OK"`; it is `true` iff `installed < latest` strictly. `"ahead"` maps to `false`.
- `plugin_check_error_code` is an extendable enum — add values, never redefine existing ones.
- `plugin_latest_checked_at` reflects **when the value in `plugin_latest` was produced**, so `cache` and `cache-stale` carry the original fetch time.
- `status` is `"degraded"` if the MCP manifest is unreachable OR any required tool is missing. A Plugin Version error alone does not mark the session degraded.
