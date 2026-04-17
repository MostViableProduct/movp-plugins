---
description: "Toggle MoVP auto-review on/off or show status"
argument-hint: "on | off | status"
---

Toggle the MoVP auto-review skill (`review-advisor`) without editing `.movp/config.yaml` by hand. Operates on `review.auto_review.plan_files`, `review.auto_review.code_output`, and (for `on`) `review.auto_review.consent`.

Parse the single positional argument `$ARGUMENTS`:

- `on` → enable auto-review (restore shipped defaults) AND persist consent if absent
- `off` → disable auto-review entirely (consent record preserved as-is)
- `status` (or no argument / empty) → show current state

## Action: status

Read `movp://movp/config` and print:

```
[MoVP] Auto-review status
  plan files:  <yes/no>   (review.auto_review.plan_files)
  code output: <yes/no>   (review.auto_review.code_output)
  consent:     <granted <granted_at> by plugin <plugin_version> (schema v<N>) | not yet granted>

Toggle with: /movp:auto-review on | off
Granular control: edit .movp/config.yaml with yq (review.auto_review.plan_files, .code_output)
```

If the config resource errors, print:

```
[MoVP] Config unreachable. Run /movp:status to diagnose.
```

and exit. Do not attempt disk reads — the MCP resource is the single source of truth.

## Actions: on / off

### Step 0 — Read-before-write (idempotency gate)

Read `movp://movp/config`. Extract:

- `review.auto_review.plan_files` (missing = treat as `false`)
- `review.auto_review.code_output` (missing = treat as `false`)
- `review.auto_review.consent` (presence + `schema_version` only — see Idempotency equality rules below)

For `on`, targets are `plan_files=true`, `code_output=false` (shipped defaults — plan files are the primary auto-review target; code output is opt-in).

For `off`, targets are `plan_files=false`, `code_output=false`.

**If current state already matches the target state AND the consent check passes**, emit:

```
[MoVP] Auto-review: already <ON|OFF>. No changes made.
```

and exit 0. Do NOT invoke the write ladder. This is the idempotency guard introduced in v1.2.1 to avoid cosmetic YAML drift on no-op invocations.

Otherwise, proceed to the write ladder with the full target state.

#### Idempotency equality rules

| Key | Missing-value treatment | Target match rule |
|---|---|---|
| `review.auto_review.plan_files` | Treat as `false` | Must equal target boolean exactly |
| `review.auto_review.code_output` | Treat as `false` | Must equal target boolean exactly |
| `review.auto_review.consent` (for `on`) | Treat as absent | Must exist AND have `schema_version == 1`. **Do NOT compare `plugin_version` or `granted_at`** — those drift intentionally and must not force rewrites |
| `review.auto_review.consent` (for `off`) | N/A | Consent record is ignored for `off`. Neither required nor mutated |

**Consent-present, flags-mismatched case:** if consent exists at the correct schema but flags disagree with target, Step 0 does NOT short-circuit — proceed to write. The write mutates flags only; consent is preserved byte-for-byte (no `granted_at` refresh — see "Write-once semantics" below).

**Plugin version policy:** `consent.plugin_version` reflects the plugin version that **originally** obtained consent. Do NOT bump it on every `on`. It only changes when a future plugin version introduces a consent-schema bump requiring re-prompt.

**Write-once `granted_at` policy:** `consent.granted_at` is set **once**, on the first `on` in this repo (or the first-run `y` in the skill). Subsequent `on` invocations do NOT refresh it — preserves original consent timestamp for audit and keeps the write path idempotent.

### Write ladder

Applied only when Step 0 does not short-circuit. Stop at the first path that succeeds.

**Step 1 — MCP write tool (preferred).**

Check the session's **deferred MCP tool list**. Do NOT consult the `movp://movp/registry` resource — MCP tools and MCP resources are separate; resource listings never contain tool definitions. This matches the skill's normative rule.

Canonical search phrase: *search the active session's deferred tool list for `set_config` (bare name or `mcp__movp__` prefixed). Do NOT read the registry resource. Do NOT call `listMcpResources` to detect tools.*

Per-host expectations:

| Host | Where deferred tools surface | Expected tool name |
|---|---|---|
| Claude Code | Session-start system-reminder + `ToolSearch` at runtime | `mcp__movp__set_config` or bare `set_config` |
| Cursor | Active session tool list (UI exposes under MCP servers) | Same as Claude |
| Codex | Active session tool list per Codex harness conventions | Same naming if `@movp/cli` registered with prefix; else bare |

If such a tool is available, call it with all target values in a single invocation:

- For `on` with absent/incomplete consent: set `plan_files`, `code_output`, AND `consent.{schema_version=1, plugin_version="<current>", granted_at=<now RFC3339>}`.
- For `on` with consent already complete: set `plan_files` and `code_output` only.
- For `off`: set `plan_files` and `code_output` only. Never touch consent.

**Step 2 — `yq` (fallback).**

Detect with `command -v yq`. Required: **Mike Farah's Go yq v4+** (`yq --version` reports `v4.x`). Older versions and Python `yq` do NOT support the `|` pipeline / `strenv()` syntax below — they must fall through to Step 4 (refuse-safely).

If available and `.movp/config.yaml` exists, build a dynamic `yq` expression per §Write-once semantics. Example for `on` with absent consent:

```bash
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
export NOW   # strenv(NOW) requires NOW to be exported; without export, yq serializes null
yq -i '
  .review.auto_review.plan_files = true |
  .review.auto_review.code_output = false |
  .review.auto_review.consent.schema_version = 1 |
  (.review.auto_review.consent.plugin_version = "1.2.1") tag="!!str" |
  (.review.auto_review.consent.granted_at = strenv(NOW)) tag="!!str"
' .movp/config.yaml
```

**Write-once semantics:** if `review.auto_review.consent.granted_at` already exists (even when Step 0 did not short-circuit because flags still mismatched), **skip** the `consent.*` mutations entirely. Only flip the flags. Build the `yq` pipeline dynamically — append consent mutations only when consent is absent or incomplete.

**Honest `yq -i` blast-radius note.** `yq -i` reserializes the full document. It can:
- normalize inline-comment whitespace (e.g. `value  # note` → `value # note`),
- shift indentation of comment-only lines attached to array items,
- touch unrelated sections' formatting.

Content and semantics are preserved; cosmetic drift is possible. The MCP `set_config` path (Step 1) avoids this entirely and is the long-term solution.

**Step 3 — `yq` available, config file absent.**

Create a minimal `.movp/config.yaml` with only the keys for this action:

For `on`:
```yaml
review:
  auto_review:
    plan_files: true
    code_output: false
    consent:
      schema_version: 1
      plugin_version: "1.2.1"
      granted_at: "<now RFC3339>"
```

For `off`:
```yaml
review:
  auto_review:
    plan_files: false
    code_output: false
```

Do NOT template the full default config — the MCP server fills defaults for other keys.

**Step 4 — `yq` unavailable or wrong version, config file exists (refuse safely).**

Do NOT attempt shell redirects, `sed`, or line-based edits against an existing file. Print:

```
[MoVP] Cannot safely edit .movp/config.yaml — requires Mike Farah's yq v4+ (Go).
Install:    brew install yq
Verify:     yq --version  (must report v4.x)
Or edit manually:
  review:
    auto_review:
      plan_files: <true|false>
      code_output: <true|false>
      consent:           # only for `on`, if absent
        schema_version: 1
        plugin_version: "1.2.1"
        granted_at: "<now RFC3339>"
```

Exit non-zero. Reliability guardrail — better a clear manual instruction than a clobbered file.

## Confirmation messages

On successful `on`:

```
[MoVP] Auto-review: ON (plan files only). Consent persisted. Manage granularity by editing .movp/config.yaml.
```

(Omit "Consent persisted" if Step 0 detected consent was already present and only flags were written.)

On successful `off`:

```
[MoVP] Auto-review: OFF. Re-enable with /movp:auto-review on.
```

## Verification-pattern gotcha (do NOT copy into operator scripts)

When testing a successful `yq -i`, do NOT chain an AND operator followed by a `diff` call. Rationale: `diff` exits 1 when files differ — which is the success case for a write — so the chain surfaces as a script error even though the write succeeded. Use a semicolon separator (`; diff ...`) or the OR-true idiom (`diff ... || true`) if you want to inspect the change. CI check `CHECK 11: auto-review spec hygiene` (in `scripts/validate.sh`) will fail if this spec re-introduces the forbidden pattern.

## Unknown argument

If `$ARGUMENTS` is not one of `on`, `off`, `status`, or empty, print:

```
[MoVP] Usage: /movp:auto-review on | off | status
```

Exit without changing config.

## Concurrency note

Writes read-then-write the full document via a single `yq` invocation (or a single MCP tool call). Concurrent `/movp:auto-review` calls from two sessions against the same repo are last-write-wins — rare in practice and observable via `/movp:auto-review status` or `/movp:status`.

## Trust boundary

Any actor with write access to `.movp/config.yaml` can enable/disable auto-review and manufacture a consent record. Auto-review runs under the operator's MoVP credentials (`MOVP_API_KEY` env, not stored in config) — a forged consent record cannot escalate privilege; it only affects whether reviews auto-trigger. The consent record is an **intent signal for the skill**, not a security boundary. CI/automation treating `.movp/config.yaml` as trusted policy should layer their own signing/verification.
