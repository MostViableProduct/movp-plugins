---
name: review-advisor
description: >
  Automatic post-artifact reviewer. After Claude writes a plan file or a
  significant code change (3+ files, new module, migration), this skill
  triggers a single adversarial review without operator input and presents
  findings.

  For an operator-initiated multi-round loop that auto-fixes findings and
  drives score to 9.0, use /movp:review instead.

  COST: Each auto-review consumes MoVP review credits.
  Disable with /movp:auto-review off. Status via /movp:status.

  Skip for trivial edits, file reads, git commands, and config-only changes.
---

# MoVP Review Advisor

> Scope: plan files and significant code output
> MCP tools: `get_review_status`, `trigger_review`, `resolve_review`

This skill runs a single adversarial review after Claude writes a plan file or a significant code change. It is **passive** — Claude invokes it automatically based on the trigger rules below. For an **interactive** multi-round loop, use the `/movp:review` command.

## When to trigger

Trigger `trigger_review` automatically when Claude has just:

- Written or significantly modified a plan file (`.md` planning documents, architecture docs, PRDs)
- Completed a multi-file code change (3+ files, or any new service/module)
- Produced a significant new code output in a single response (functions, handlers, migrations)

Do **not** trigger for: reading files, running tests, git commands, grep/search, single-line edits, config-only changes.

## Step 0 — Check auto-review config and consent

Before any MCP call, run these checks in order. Each exit case must be **visible** to the operator — never exit silently.

**0.1 Read resolved config.**

Read `movp://movp/config` (the MCP resource — the single source of truth). Do NOT read `.movp/config.yaml` directly; the MCP server resolves tenant overlay, defaults, and schema.

If the resource errors or is unavailable, emit:

```
[MoVP] Config unreachable — auto-review skipped. Check /movp:status.
```

Exit. Do NOT call `trigger_review`.

**0.2 Honor the per-artifact flag.**

- `plan_file` artifact → honor `review.auto_review.plan_files`
- `code_output` artifact → honor `review.auto_review.code_output`

If the relevant flag is `false`, emit:

```
[MoVP] Auto-review skipped (review.auto_review.<flag> is false). Re-enable with /movp:auto-review on.
```

Exit. Do NOT call `trigger_review`. (Non-silent skip — operators must see why nothing happened.)

**0.3 First-run consent.**

If the resolved config does not contain `review.auto_review.consent` (see "Consent record schema" below), pause and ask:

> **MoVP auto-review will run once now. Each auto-review consumes review credits. Continue? [y / N / always-off]**
>
> - `y` — proceed this time, persist consent (see "Consent write path").
> - `N` — skip this artifact only (no config write, no consent record).
> - `always-off` — mutate flags to `plan_files=false` AND `code_output=false`, skip this artifact. Platform-dependent write path:
>   - **Claude plugin** — invoke `/movp:auto-review off` (the command handles the write ladder).
>   - **Codex / Cursor** — apply the "Consent write path" ladder inline. Do NOT call `trigger_review` regardless of whether the mutation succeeded.

**0.4 Prompt-completion rules.**

- No reply / session end / abort / Ctrl-C → treat as `N` (skip once, no MCP call, no charge, no consent record). The safe default — do not infer consent from timeout.
- Any unrecognized reply → re-ask once, then fall back to `N` on the second non-match.

### Consent record schema

Stored inside the resolved config under `review.auto_review.consent` (no separate dotfile):

```yaml
review:
  auto_review:
    consent:
      schema_version: 1
      plugin_version: "1.2.1"
      granted_at: "2026-04-16T12:34:56Z"
```

Future plugin versions with material behavior changes may bump a minimum consent schema and re-prompt without surprising existing repos.

### Consent write path

After a `y` reply, persist the consent record using the following ladder, in order:

1. **MCP write tool** (e.g. `set_config`) — preferred. Check the session's **deferred MCP tool list** for `set_config` (bare) or `mcp__movp__set_config`. Do NOT read `movp://movp/registry` to detect tools — MCP tools and MCP resources are separate; resource listings never contain tool definitions.
2. **`yq` v4+** (Mike Farah's Go yq) if installed — detect via `command -v yq` and confirm `yq --version` reports `v4.x`. Python `yq` and older versions lack the pipeline / `strenv()` syntax and must fall through to step 3. When using `yq`, note that `-i` reserializes the full document — content and semantics preserved, but inline-comment whitespace may normalize and unrelated sections' formatting may shift. Long-term fix is the MCP write tool (step 1).
3. **Neither available** — emit:

   ```
   [MoVP] Consent recorded for this session only — cannot persist to .movp/config.yaml without yq v4+ or MCP write tool. Install yq (brew install yq) or add the consent record manually.
   ```

   Then **proceed with the current auto-review this session** (the operator said yes). The next session will re-prompt.

This preserves immediate intent without failing the review, while surfacing the persistence gap visibly.

**Note:** If the operator has already run `/movp:auto-review on` in this repo, `review.auto_review.consent` will already be present at the correct `schema_version`, and Step 0.3 of this skill is a no-op for them — they will not see the consent prompt.

## Step 1 — Trigger the review

Call `trigger_review(artifact_type="plan_file"|"code_output", content=<artifact>, session_id=<current session>)` — returns `review_id`.

## Step 2 — Poll for completion

Call `get_review_status(review_id=<id>)` until `review_status` is `"completed"` or `"error"`.

Always pass `review_id` explicitly — do NOT call `get_review_status` without it when multiple reviews may be in flight (returns most recent tenant review otherwise).

## Step 3 — Present findings

Format as structured output with severity badges. After findings, always ask:

> **Reply with:** implement fixes, dismiss (false positive / not applicable / deferred), or accept as-is.

> **Full review loop:** Use `/movp:review` for an interactive multi-round loop where findings are implemented between rounds and the score tracked to 9.0.

## Step 4 — Cost echo

Always append, after the findings block and the reply prompt:

```
[MoVP] Auto-review cost: $<cost>
To disable: /movp:auto-review off    |    Status: /movp:status
```

### Parsing spec (authoritative — referenced by `/movp:review`)

Both this skill and `/movp:review` parse `get_review_status` output using the following spec. Do not inline regex elsewhere.

- **Source:** the text body returned by `get_review_status(review_id=<id>)` when `review_status == "completed"`.
- **Score:** regex `Quality:\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*10` → capture as float.
- **Cost:** regex `Cost:\s*\$([0-9]+(?:\.[0-9]+)?)` → capture as float.
- **Parse failure policy:** if either regex fails to match, emit:

  ```
  [MoVP] Auto-review completed; cost/score unavailable (unexpected response format). Run /movp:status to verify backend.
  ```

  Do NOT fabricate values and do NOT retry — surface the drift.

## Step 5 — Resolve

| Developer says | Action to call | Notes |
|---|---|---|
| "accept", "looks good", "ship it" | `resolve_review(action="accept")` | Idempotent — safe to call twice |
| "dismiss", "false positive", "not applicable" | `resolve_review(action="dismiss", reason="false_positive" \| "not_applicable" \| "deferred")` | |
| "escalate", "create a ticket" | `resolve_review(action="escalate", target="todo")` | |
| "retry", "run it again" | `resolve_review(action="retry")` | **Only valid when review_status is "error"** — do not call on completed reviews |

## Do not pre-flight-check tool availability

**Call `trigger_review` directly.** Do NOT:

- Run `movp:status` before triggering a review
- Call `listMcpResources` to verify tools exist
- Do NOT read `movp://movp/registry` to confirm tool registration — MCP tools live in the session's deferred tool list, not in resource listings (see "Consent write path" step 1 for the correct probe)
- Conclude tools are unavailable based on resource listings

MCP tools and MCP resources are separate. Tools appear in the session's deferred tool list, not in resource listings. If `trigger_review` fails, report the error — do not substitute a manual or simulated review.

**Never fabricate a review.** If the tool call fails, stop and report the error.

## Rate and cost awareness

Reviews consume LLM budget. Do not trigger multiple reviews in a single session for the same artifact. If `trigger_review` returns a rate limit error (429), inform the developer and do not retry automatically. For multi-round loop behavior, see the `/movp:review` command.
