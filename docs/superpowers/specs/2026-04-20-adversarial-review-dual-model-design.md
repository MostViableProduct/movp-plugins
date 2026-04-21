# Dual-Model Adversarial Review — Design

**Date:** 2026-04-20
**Status:** Approved for implementation planning (pending founder review of this spec)
**Repos affected:** `big-wave` (MCP server + review service + frontend), `mona-lisa` (claude-plugin, codex-plugin, cursor-plugin)
**Target release:** v1.4.0 (aligned across backend, frontend, and all three plugins)

---

## Context

MoVP's current adversarial review flow (`/movp:review` command + `review-advisor` skill) uses a single model for both artifact production and critique. The founder already runs manual adversarial reviews using a *different* LLM family than the one that produced the artifact, on the premise that cross-family critique surfaces genuine disagreements that same-model critique hides. This refactor formalizes that practice into the product.

The refactor adds:

1. **Model-pair configuration** via the web UI — tenant admins select an Adversary model per client tool.
2. **A 4-turn protocol** — the local coding tool (Primary) generates, a different model (Adversary) reviews, the Primary validates findings with per-finding rationale, the Adversary re-reviews with rationale context. Loop until score ≥ threshold, max_rounds, or plateau.
3. **A 7th scoring category — Observability** — weighted 1.0 alongside correctness/reliability/safety.
4. **Weighted composite scoring** with threshold raised from 9.0 → 9.2 for dual-model mode.
5. **Server-side turn capture** — every Adversary call and Primary response is persisted, with a backend-enforced **redaction hook** for credentials and email addresses. The substrate feeds MoVP's existing rule-suggestion pipeline (`generate_suggestions` / `detect_patterns`) so meta-learning can propose changes to coding-harness rules from the disagreement corpus.

---

## Decisions locked during brainstorming

| # | Decision |
|---|---|
| 1 | **Primary = the local coding tool** (Claude Code / Codex / Cursor session the user is already in). Backend never "re-runs" the Primary. The user's session is the single source of artifact changes. |
| 2 | **Turn 3 is per-finding validate-then-apply.** Primary writes a short rationale (accept/reject + why) per finding. Rejected set is forwarded to the Adversary in Turn 4 so disagreements become visible, not hidden. |
| 3 | **Client-tool identity is an explicit `client_tool` param** on `trigger_review`. Each plugin hardcodes its own identity. The backend uses it to route to the configured Adversary. Not a trust boundary (§ 5i). |
| 4 | **Observability = instrumentation coverage.** For code artifacts: does the code emit useful spans/logs/metrics at meaningful boundaries? For plan files: does the plan name its telemetry? Weight 1.0. |
| 5 | **Loop ceiling: `max_rounds=5` + plateau stop** when |Δscore| < 0.1 for two consecutive rounds. Budget-cap (dollars-per-review) deferred to a later release. |
| 6 | **Web UI scope: tenant defaults + `.movp/config.yaml` override** per repo. Per-user override (`.movp/config.local.yaml`) supported as part of the existing merge order but not surfaced in the UI. |
| 7 | **Rollout: Approach 3 — feature-flagged in-place refactor** gated on `review.dual_model`. `/movp:review` stays the single command; behavior branches on the flag. |
| 8 | **Server-side turn capture** via `adversarial_review_turns` child table. Fuels the meta-learning loop via existing suggestion pipeline. |
| 9 | **Backend redaction hook with fixed pattern set** (API keys, passwords, email addresses only). Not tenant-configurable — the friction is intentional to prevent drift toward a "company-sensitive-data nexus." |

---

## Table of contents

1. [Architecture overview](#section-17--architecture-overview)
2. [Web UI: Model Pairs](#section-27--web-ui-model-pairs)
3. [Config schema](#section-37--config-schema)
4. [Backend schema + redaction](#section-47--backend-schema--redaction)
5. [MCP API surface](#section-57--mcp-api-surface)
6. [Plugin command refactor](#section-67--plugin-command-refactor)
7. [Rollout & dogfood path](#section-77--rollout--dogfood-path)

Cross-references use the form *"Section N/7 § `<letter>`"* (e.g. "Section 4/7 § 4b"). The `§`-prefix markers are the authoritative anchor names for implementers.

---

## Section 1/7 — Architecture overview

### Shape of a dual-model review cycle (one iteration of the loop)

```
┌──────────────────────────┐        ┌──────────────────────────────┐
│ Local coding tool        │        │ Big Wave backend             │
│ (Claude Code/Codex/Cursor)│       │ (services/mcp + review svc)  │
└──────────────────────────┘        └──────────────────────────────┘
        │                                           │
Turn 1  │  artifact produced in-session             │
(pre-   │  (already happened by /movp:review time)  │
review) │                                           │
        │                                           │
Turn 2  │ ── trigger_review(client_tool, artifact) ─▶
        │                                           │ resolve pair → Adversary model
        │                                           │ run redaction → persist review row
        │                                           │ call Adversary → capture turn row
        │ ◀── get_review_status → findings+scores ──│
        │                                           │
Turn 3  │  per-finding: accept/reject + rationale   │
        │  apply accepted diffs to artifact         │
        │ ── record_primary_turn(rationale[],       │
        │      applied_diff, artifact_after) ──────▶│
        │                                           │ redact + persist turn row
        │                                           │
Turn 4  │ ── trigger_review (round=2, carries       │
        │    rationale from prev round) ────────────▶
        │                                           │ call Adversary with Primary's
        │                                           │ rejection reasons as context
        │                                           │ → capture turn row
        │ ◀── get_review_status → new scores ───────│
        │                                           │
        ▼                                           ▼
    stop conditions: score≥9.2 AND no CRIT/HIGH; OR max_rounds=5;
    OR plateau (|Δscore|<0.1 for 2 consecutive rounds); OR operator stop;
    OR no_progress (no findings / no accepted changes)
```

### § 1a. Glossary

- **Turn** — a single client↔server interaction in the protocol diagram (`trigger_review` call, `get_review_status` poll, `record_primary_turn` call). The numbering in Turn 1/2/3/4 names the *roles* at each step.
- **Round** — one complete Adversary invocation iteration. Round 1 = the first Adversary pass (Turn 2). Round 2 = Turn 4. Round N = the N-th Adversary pass.
- **`adversarial_review_turns` rows** are keyed by `(review_id, round, turn_number)`. Within a round, `turn_number=1` is the Adversary call, `turn_number=2` is the Primary's `record_primary_turn`.
- `max_rounds=5` means up to 5 Adversary calls per review. Stop rules operate on **round** granularity.

### Key invariants

1. **Primary never runs server-side.** The local session is always Primary. The backend never "re-runs" the local tool.
2. **Every turn is a persisted row** in `adversarial_review_turns` with model id, content, cost, latency. This is the substrate for the rule-suggestion pipeline; it is not optional UI data.
3. **`dual_model=false` is a strict subset.** When the flag is off, the code path degenerates to Turn-2-only (single adversarial pass, no Turn-3 rationale capture, no Turn-4). See § 1e for the parity definition.
4. **Rationale is the Turn-3 → Turn-4 payload.** The Adversary in Turn 4 sees "Primary applied these fixes and rejected these others *because …*." Without this, Turn 4 is just Turn 2 again on slightly different text.
5. **Redaction runs exactly once per turn**, on the backend, pre-INSERT. Never re-run; never skipped. On redaction-function failure, the INSERT fails and the transaction rolls back — we do not store un-redacted content under any failure mode.

### § 1b. Idempotency & retry semantics

- `trigger_review` accepts an optional `idempotency_key` header. Same key within a 10-minute review window → returns the existing `review_id` instead of creating a new row.
- `get_review_status(review_id)` is a pure read; any number of calls returns the same result for a given state.
- `record_primary_turn` uses `(review_id, round)` as the natural idempotency key; duplicate calls **upsert** the turn row (last-write-wins on content; cost/latency fields accept only the first non-null write).
- **Partial-failure rule:** if persistence after an Adversary call fails (DB down mid-INSERT), the review row is marked `error` with `retry_safe=true`; client calls `resolve_review(action="retry")` to restart the current round. Adversary-call cost already spent is recorded in a `sunk_cost_usd` field.
- **Delivery guarantee:** `record_primary_turn` is at-least-once from the plugin's side; the backend's upsert key provides effective exactly-once.

### § 1c. Runtime observability

- One W3C trace per **round**, parented on the plugin's outer `/movp:review` span.
- Spans: `review.trigger`, `review.adversary.call`, `review.primary_turn.record`, `review.stop`. Attributes on all spans: `tenant_id`, `review_id`, `round`, `client_tool`, `adversary_model_id`, `dual_model`. On `review.stop`: also `stop_reason ∈ {threshold_met, max_rounds, score_plateau, no_progress, operator_stop, error}`.
- Metrics: counter `review.rounds_total{stop_reason, client_tool, adversary_provider}`; histogram `review.round_duration_seconds{client_tool, adversary_provider}`; counter `review.redactions_total{category}`.

### § 1d. Performance envelope

- Artifact size cap: **256 KB** per `trigger_review.content` payload. Oversized artifacts rejected with `{"reason": "artifact_too_large", "limit_bytes": 262144, "remediation": "Split or trim the artifact; adversarial review operates on 256KB segments."}`.
- Per-round SLO: p95 ≤ 45 s from `trigger_review` to first `get_review_status` returning `completed`.
- Fan-out: at most `max_rounds` (default 5) Adversary calls per `review_id`.
- Concurrency: one in-flight review per `(tenant, client_tool, repo)` tuple; additional `trigger_review` calls while one is running return `409 concurrent_review_in_flight` with the live `review_id`.

### § 1e. Parity definition for invariant 3 (`dual_model=false` preserves today's behavior)

Parity means **all three** of:

1. Same MCP tool signatures for `trigger_review`, `get_review_status`, `resolve_review` (no required new params; `client_tool` optional in this mode).
2. Same 6-category score shape in `category_scores` JSONB — `observability` key **absent** when `dual_model=false`.
3. Regression test suite at `big-wave/services/mcp/__tests__/review-parity.spec.ts` (new in v1.4.0) exercises the legacy path end-to-end: same input → same output schema as v1.3.2. CI gates the release on this.

---

## Section 2/7 — Web UI: Model Pairs

**Location.** New sub-page under the existing MoVP frontend Settings area (the URL opened by `/movp:settings`). Route: `/settings/review/model-pairs` (nominal; frontend team owns the final path).

**Access.** Tenant-admin role (reuse existing gate). Non-admins see a read-only view; the PATCH endpoint returns `403` for non-admin callers regardless of UI state.

### Page contents (one screen)

1. **Page header.**
   - Title: "Adversarial Review — Model Pairs"
   - Subtext: "The Adversary reviews your Primary's output. Different model families reduce groupthink and surface genuine disagreements. When dual-model review is off, the Adversary is the same model as the Primary (legacy behavior)."

2. **Master toggle — "Enable dual-model review".**
   - Writes: `review.dual_model` (boolean) on tenant config
   - Off: pairs table rendered but disabled/greyed; defaults pre-filled so flipping on immediately produces a working config
   - On with no pairs saved: shows the defaults inline and a "Save defaults" button rather than auto-saving (explicit action)

3. **Pairs table — one row per canonical client tool** (fixed set).

   | Primary | Adversary | Provider credential |
   |---|---|---|
   | Claude Code | `<dropdown>` — default `openai/gpt-5.4` | ✓ / ⚠ |
   | Codex | `<dropdown>` — default `anthropic/claude-opus-4-6` | ✓ / ⚠ |
   | Cursor | `<dropdown>` — default `openai/gpt-5.4` | ✓ / ⚠ |

   - Dropdown options = intersection of "supported adversary models" and "providers for which the tenant has a credential slot registered" (§ 2b).
   - Model identifiers are namespaced `provider/model-id`.
   - Credential column: green ✓ / yellow ⚠ driven by the same catalog used at review time, so UI and backend cannot drift.

4. **Override notice** (footer).
   > *These are tenant defaults. Any repo can override per-pair by setting `review.model_pairs.<client_tool>` in `.movp/config.yaml`. To see the effective pair for a specific repo, run `/movp:status` in that repo.*

### What this page intentionally does NOT expose

- Scoring weights (fixed in v1.4.0; § 3a)
- Threshold / `legacy_threshold`, `max_rounds`, plateau delta (config-file-only, operator-level knobs)
- Redaction pattern list (backend-only — intentional friction)

### § 2a. Server contract (GET + PATCH)

- `GET /api/tenants/<tenant>/config/review` returns the **resolved** config: tenant-saved values merged with backend defaults, plus `_meta.source` (§ 3d) so the UI can render "default" vs "saved" state honestly. Never leaks other tenants.
- `PATCH /api/tenants/<tenant>/config/review` — tenant-admin role required; non-admin returns `403`. Body validated against a JSON schema; unknown keys → `400` with `path` + `reason` rather than silent drop. Response echoes the same resolved shape as GET.
- `If-Match: <etag>` optional header for concurrent-admin protection; absent header = last-write-wins (disclosed in the UI footer). Mismatch → `409 etag_mismatch` with current etag for retry.
- Server-side enforcement mirrors UI gates: admin role checked on PATCH, schema validation on body, pair membership validated against the provider-credential catalog (§ 2b).

### § 2b. Key-status source of truth

Provider credential availability is read from the **same catalog the review pipeline consults at `trigger_review` time** — a single `provider → credential_slot → available?` map maintained next to the secrets resolver. Tooltips are generated from that map (e.g. *"Tenant has no credential registered for `openai`"*) rather than naming env-var strings. If the catalog says unavailable, the dropdown option is rendered disabled; validation at review time uses the same check, preventing UI/backend drift.

### § 2c. Groupthink guardrail (non-blocking)

When `dual_model=true` and the selected adversary's namespace prefix (`provider/`) matches the known primary's provider for that `client_tool` (e.g. Cursor primary resolves to an Anthropic model and the user picks `anthropic/...` as adversary), the row shows a yellow banner: *"Same provider as Primary — dual-model review will reduce groupthink less effectively."* Does not block save. Purely advisory.

### § 2d. Reliability UX

- Save button disabled until form dirty; pressing save runs PATCH with inline spinner, then a toast on success (`"Model pairs saved."`) or error (`"Save failed: <reason>. Retry?"`). Error state leaves the form dirty so retry is one click.
- On `409 etag_mismatch`, toast: `"Another admin saved changes. Reload to see latest, then re-apply yours."` with a "Reload" button that re-fetches the resolved config.
- Initial load renders a skeleton table (same row count as the fixed client-tool set) for no layout shift.

### § 2e. Audit event

On successful PATCH, backend emits a structured event on the existing audit channel: `{event: "review.config.updated", tenant_id, actor_id, actor_email, dual_model, pairs: {...}, timestamp, request_id}`. No secrets in the payload. Consumed by the existing audit viewer; also summarized in `/movp:status`.

### PATCH payload (what the UI writes)

```json
{
  "review": {
    "dual_model": true,
    "model_pairs": {
      "claude-code": { "adversary": "openai/gpt-5.4" },
      "codex":       { "adversary": "anthropic/claude-opus-4-6" },
      "cursor":      { "adversary": "openai/gpt-5.4" }
    }
  }
}
```

Empty pairs map is valid (`dual_model` can be on with pairs unset → backend falls back to per-client defaults). Missing `dual_model` is treated as `false`.

### § 2f. Acceptance test

Single Playwright case `admin-can-configure-pairs.spec.ts`: admin logs in, toggles `dual_model` on, changes Claude Code's adversary from the default to an alternative, clicks Save, observes success toast, reloads page, observes saved value persisted; then logs in as non-admin and verifies the Save button is hidden and a direct PATCH returns `403`.

### Empty-state / first-visit UX

Toggle off, table pre-filled with defaults but greyed. *"Turn on dual-model review to activate the defaults shown below, or pick different pairs before enabling."*

---

## Section 3/7 — Config schema

All config keys use the **canonical identifiers** — `claude-code`, `codex`, `cursor` — not display names. Display names are a web-UI concern only. Plugin code, backend routing, and config files all use the canonical form. Section 2 § 2a PATCH JSON and this section's YAML use the same key tree.

### Full shape

```yaml
review:
  # Existing — unchanged
  auto_review:
    plan_files: true
    code_output: false
    consent:
      schema_version: 1
      plugin_version: "1.4.0"
      granted_at: "2026-04-20T00:00:00Z"

  # New in v1.4.0 — feature flag + pair map
  dual_model: true                       # default: false
  model_pairs:
    claude-code:
      adversary: "openai/gpt-5.4"
    codex:
      adversary: "anthropic/claude-opus-4-6"
    cursor:
      adversary: "openai/gpt-5.4"

  # New — loop controls (operator-level, config-file only)
  max_rounds: 5                          # default: 5
  threshold: 9.2                         # dual-model threshold; default 9.2
  legacy_threshold: 9.0                  # single-model threshold; default 9.0
  plateau:
    delta_epsilon: 0.1                   # default: 0.1
    consecutive_rounds: 2                # default: 2

  # New — Turn 3 auto-accept opt-out (§ 6d)
  confirm_before_apply: false            # default: false (v1.3.x parity)

  # Read-only — echoed for transparency; not merge-able (§ 3a)
  scoring:
    weights:
      correctness: 1.0
      observability: 1.0
      reliability: 1.0
      safety: 1.0
      usability: 0.9
      performance: 0.9
      simplicity: 0.8
```

Keys not listed here are not valid for v1.4.0. Unknown keys at any merge layer produce a warning in `/movp:status` (`Unrecognized config key 'review.foo' in '.movp/config.yaml:12' — ignored`) rather than a hard error, so future versions can add keys without breaking older plugins.

### Merge order

Most-specific wins; matches existing pattern:

```
code defaults  <  tenant DB (web UI)  <  .movp/config.yaml  <  .movp/config.local.yaml
```

Merging is **deep** per-key — setting `review.model_pairs.cursor.adversary` in `.movp/config.yaml` overrides *only* that pair, not the whole `model_pairs` map. `dual_model` is a scalar and is replaced wholesale.

### § 3a. Weights semantics — fixed constants in v1.4.0

`scoring.weights` is **read-only, echoed for transparency** — it appears in the resolved config but is **not** part of the merge surface. The backend ignores any user-provided values for `review.scoring.*` at any merge layer and emits a structured warning (`config.scoring_override_ignored` — counted per path, surfaced in `/movp:status`). Weights live in code (`big-wave/services/review/weights.ts`); changing them is a code change with a release note, not a config change. JSON-Schema marks the subtree with `x-readOnly: true` so the web UI renders it as static.

Weights do not need to sum to any specific value — the scoring engine computes `Σ(weight_i × score_i) / Σ(weight_i)` to produce the composite. This makes weights freely adjustable by the MoVP team without invalidating historical scores (historical composites are pinned per-row per § 4c).

### § 3b. Merge edge cases — absent / null / explicit

Per-layer rules, applied left-to-right through the merge order:

| Layer content for a key | Effect on that layer's contribution |
|---|---|
| **Absent** (key not present) | Inherit — layer contributes nothing; lower-priority layer's value (or default) survives |
| **Explicit value** (scalar or non-empty map) | Wins at this layer and all lower-priority ones for that path |
| **Explicit `null`** (YAML `~` or `null`) | Reset to **code default** at this layer; does not propagate upward — a higher-priority layer can still override |
| **Empty map `{}`** | Empty map wins at this layer (equivalent to "no pairs configured") — triggers per-client defaults via the fallback path, not inherited from below |

Concrete: `model_pairs: null` in `.movp/config.local.yaml` discards any repo or tenant pair map and falls back to code defaults for that repo's local session. `model_pairs: {}` yields the same *effective* result but produces a different `/movp:status` readout (`repo (empty map)` vs `local (null reset)`) — both valid, semantically distinct for provenance.

For scalars (`dual_model`, `max_rounds`, `threshold`, `legacy_threshold`, `plateau.*`, `confirm_before_apply`) with no value at any layer → the code default wins.

### Validation — three gates, same rules

1. **Web UI PATCH** (§ 2a) — JSON-schema validates shape; catalog lookup validates that the chosen adversary is a known model AND the tenant has the credential for its provider.
2. **`trigger_review` call** — resolves effective config for `(tenant, repo, client_tool)` and re-validates: pair exists, adversary model is in the catalog, provider credential is available. On failure: `400` with `reason` + `remediation` (e.g. `{"reason": "no_credential_for_provider", "provider": "openai", "remediation": "Add OpenAI API key in Settings → Providers"}`). **Never silently falls back** to a different model.
3. **Plugin-side** (`/movp:review` command, § 6a) — reads `movp://movp/config`, reports the effective pair to the operator before the first `trigger_review` call.

### `dual_model=true` with no pairs configured

Falls back to *per-client defaults* (same defaults the web UI pre-fills). Defaults live in code so a new tenant with `dual_model: true` in their repo-level `.movp/config.yaml` but no tenant-level config still has a working review.

### `dual_model=false`

Ignores `model_pairs` entirely; the Adversary is the Primary (today's behavior preserved exactly per § 1e). Effective threshold becomes `legacy_threshold` (default 9.0) — see § 6e for the threshold selection logic.

### § 3c. Reliability — revision, caching, fetch-failure behavior

- PATCH response (§ 2a) includes `etag: "<hash>"` and `revision: <monotonic int>` in the resolved-config envelope.
- `movp://movp/config` resource includes the current revision in its payload. Plugin caches the resolved config in-process for 30 s, keyed by revision.
- **Fetch failure before `trigger_review`:** plugin does **not** call `trigger_review`. Prints `[MoVP] Config unreachable — review aborted to avoid spending credits on an unverified adversary. Retry after checking /movp:status.` Fail-closed is deliberate for review triggers because stale adversary selection costs real money.
- **Fetch failure for non-review commands** (`/movp:status`, `/movp:auto-review status`): last-known-good cache is usable with a visible staleness indicator (`(cached <N>s ago)`).
- **Cache coherency after PATCH:** worst-case visibility lag = 30 s (plugin TTL). Operators can force immediate uptake via `trigger_review` with `force_refresh=true` (§ 5b; dev-mode convenience, not for automation).

### § 3d. Config-resolution provenance

`/movp:status` adds a `review.config_resolution` subsection listing the source per key:

```
review.config_resolution:
  dual_model:                  tenant
  model_pairs.claude-code:     repo (.movp/config.yaml:14)
  model_pairs.codex:           tenant
  model_pairs.cursor:          default
  max_rounds:                  default
  threshold:                   default
  legacy_threshold:            default
  plateau.delta_epsilon:       local (.movp/config.local.yaml:3)
  plateau.consecutive_rounds:  default
  confirm_before_apply:        default
```

Sources: `default | tenant | repo | local`. The resolved config endpoint returns this provenance map in the response envelope (`_meta.source` per § 2a), so UI and CLI draw from the same signal.

### Schema versioning

No top-level schema version bump. The existing `review.auto_review.consent.schema_version` is about consent, not the whole review config. New keys are additive; unknown-key warnings handle forward compatibility. A future breaking change would introduce `review.schema_version` at that point.

### § 3e. Cross-reference convention

All section references use the form *"Section N/7 § `<letter>`"* (e.g. "Section 2/7 § 2a"). The `§`-prefix markers are the authoritative anchors for implementers grepping this doc.

---

## Section 4/7 — Backend schema + redaction

All DDL targets the existing Postgres instance served by `big-wave/services/mcp`. No new services.

### § 4a. Changes to `adversarial_reviews`

New columns are all **nullable or defaulted** — migration is forward-only and safe on a live table.

```sql
ALTER TABLE adversarial_reviews
  ADD COLUMN dual_model          BOOLEAN      NOT NULL DEFAULT FALSE,
  ADD COLUMN client_tool         TEXT,
  ADD COLUMN composite_score     NUMERIC(5,3),           -- max 99.999 accommodates 10.000 safely
  ADD COLUMN stop_reason         TEXT,                   -- NULL while running; terminal enum on completion
  ADD COLUMN config_revision     INT,
  ADD COLUMN effective_threshold NUMERIC(4,2),           -- § 6e — threshold used for this review
  ADD COLUMN redactions          JSONB        NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS parent_review_id TEXT
    REFERENCES adversarial_reviews(id) ON DELETE SET NULL;

ALTER TABLE adversarial_reviews
  ADD CONSTRAINT review_stop_reason_values
    CHECK (stop_reason IS NULL OR stop_reason IN
      ('threshold_met','max_rounds','score_plateau','no_progress',
       'operator_stop','error')),
  ADD CONSTRAINT review_client_tool_values
    CHECK (client_tool IS NULL OR client_tool IN ('claude-code','codex','cursor')),
  ADD CONSTRAINT review_composite_range
    CHECK (composite_score IS NULL OR (composite_score >= 0 AND composite_score <= 10));

CREATE INDEX IF NOT EXISTS adv_reviews_parent_idx
  ON adversarial_reviews (parent_review_id)
  WHERE parent_review_id IS NOT NULL;

CREATE INDEX adv_reviews_tenant_client_tool_idx
  ON adversarial_reviews (tenant_id, client_tool, created_at DESC)
  WHERE dual_model = TRUE;
```

- `dual_model` — mirrors the effective `review.dual_model` at `trigger_review` time. Enables tenant-wide queries without joining turn rows.
- `client_tool` — canonical value; legacy rows stay `NULL`.
- `composite_score` — precomputed weighted average; pinned per row for stable reporting. `category_scores` JSONB remains authoritative.
- `stop_reason` — `NULL` while in progress; set to exactly one terminal enum value on completion.
- `config_revision` — `revision` value (§ 3c) in effect when the review ran.
- `effective_threshold` — the threshold actually applied (9.2 for dual-model, 9.0 for single-model by default). Persisted so analytics doesn't need to re-derive from mode.
- `redactions` — roll-up counts across all turn rows (§ 4f).
- `parent_review_id` — lineage threading for loop rounds. `IF NOT EXISTS` handles the case where Phase 1 already added it; idempotent either way. First review in a loop has `parent_review_id=NULL` and `round=1`; each subsequent round sets it to the prior round's `review_id`.

### § 4b. New `adversarial_review_turns` table

```sql
CREATE TABLE adversarial_review_turns (
  review_id      TEXT          NOT NULL REFERENCES adversarial_reviews(id) ON DELETE CASCADE,
  tenant_id      TEXT          NOT NULL,                  -- denormalized from parent
  round          INT           NOT NULL,
  turn_number    INT           NOT NULL,
  role           TEXT          NOT NULL,
  model_id       TEXT,
  input_content  TEXT          NOT NULL,                  -- post-redaction
  output_content TEXT          NOT NULL,                  -- post-redaction
  cost_usd       NUMERIC(10,4) NOT NULL DEFAULT 0,
  latency_ms     INT,
  redactions     JSONB         NOT NULL DEFAULT '{}'::jsonb,
  trace_id       TEXT,
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  PRIMARY KEY (review_id, round, turn_number),
  CONSTRAINT turn_role_values     CHECK (role IN ('primary','adversary')),
  CONSTRAINT turn_round_positive  CHECK (round >= 1),
  CONSTRAINT turn_number_positive CHECK (turn_number >= 1)
);

CREATE INDEX adv_turns_tenant_role_idx ON adversarial_review_turns (tenant_id, role, created_at DESC);
CREATE INDEX adv_turns_model_id_idx    ON adversarial_review_turns (model_id);
```

- **Child table, not JSONB on parent.** The rule-suggestion pipeline queries *across* reviews by role/model/category — a relational query that wants an index, not a JSONB scan.
- **`tenant_id` denormalized** at insert time by the MCP handlers. A single persistence module is the only writer to this table, enforcing the invariant. No Postgres trigger.
- **Indexes.** `(tenant_id, role, created_at DESC)` covers "all primary rejections for tenant X, recent first" (the main rule-suggestion query); `model_id` covers "compare adversary-model effectiveness."
- **ON DELETE CASCADE** — if a review is expunged for compliance, its turns go with it.
- **Retention.** Indefinite at v1.4.0. If/when storage pressure emerges: TTL by tenant tier, move cold rows to an archive table. Not in this refactor.

### § 4c. Composite score computation

Computed server-side after `category_scores` is written; pinned to `composite_score` on the parent row.

```
composite = Σ(weight_i × score_i) / Σ(weight_i)
```

summed over categories present on that review — 7 when `dual_model=true` (weights sum 6.6) and 6 when `dual_model=false` (weights sum 5.6, no `observability`). Rounded to 3 decimal places (matches `NUMERIC(5,3)`).

The scoring engine reads weights from code (§ 3a), not from config and not from `category_scores`. Weight changes post-v1.4.0 do not retroactively alter pinned composites.

**Comparability.** Dual-model and single-model composites use different denominators. UIs must group by `dual_model` or show the `category_scores` breakdown — never compare composites across modes directly. This is a backend invariant, not just a UI convention.

### § 4d. Redaction pipeline

**Location.** `big-wave/services/review/redaction.ts`. Called from the persistence path on every write that inserts content into `adversarial_reviews.content` or `adversarial_review_turns.{input,output}_content`. No caller bypass; no "skip redaction" flag.

**When.**

```
plugin → MCP handler → validate → call adversary → REDACT → INSERT → response
                                                    ^^^^^^
                                                    only site
```

**Trust boundary.** Redaction runs **pre-INSERT, post-adversary-call**. The Adversary LLM receives full unredacted content (same as today — the LLM input has always included the artifact). MoVP's own storage is what redaction protects. Failing to distinguish these is how systems end up storing credentials they shouldn't.

- Before adversary call: unredacted content transits to the provider's API. Same behavior and trust model as v1.3.x — the tenant already accepted this when enabling review.
- Before INSERT: redacted. MoVP stores tokens, not secrets.
- On the primary side: the local session sees whatever the Adversary returned, which may quote redacted tokens. The Primary is not re-exposed to secrets — output is redacted before leaving the backend.

**Execution.** Redaction runs **within the same transaction** as the INSERT. One `BEGIN`, redact fields in memory, `INSERT ... RETURNING`, `COMMIT`. If the redaction function throws, the transaction rolls back; the MCP tool returns `redaction_engine_failure`. The error path logs the failure category but **never logs the content** that failed to redact.

**Structured content.** The Adversary's output is JSON. Redaction walks the parsed JSON and applies patterns to every string-valued field (`summary`, `suggested_fix`, `quoted_code`, etc.), then serializes back. Preserves JSON validity and avoids pattern/boundary edge cases. Raw `input_content` for adversarial turns is redacted as a single string.

**Legacy rows.** Pre-v1.4.0 `adversarial_reviews.content` rows are not retro-redacted. Retrofit is out of scope; if a compliance need demands backfill, it's a separate migration.

**ReDoS defense — required.** Two layers:

1. **RE2 engine, not PCRE.** Redaction uses the [`re2`](https://www.npmjs.com/package/re2) Node package — linear-time guarantee, no backtracking, no catastrophic cases. Patterns that won't compile under RE2 (e.g. backreferences) are rejected at module load; redaction module self-test covers this.
2. **Per-pattern execution timeout.** Each pattern is wrapped in a 50 ms timeout. Timeout fires → redaction throws → transaction rolls back.

The CI perf test (§ 4h) is the regression gate; the RE2 engine choice is the structural guarantee that makes the perf budget achievable.

### § 4e. Redaction pattern set (illustrative)

Compiled, tested, shipped patterns live in `big-wave/services/review/redaction_patterns.ts` — **that file is the single source of truth**. The table below describes intent; any discrepancy is a doc bug, never a behavior bug. Markdown `|` inside table-cell regexes is escaped as `\|`; implementers copy from `redaction_patterns.ts`, not from this table.

| Category | Pattern intent | Replacement token |
|---|---|---|
| `api_key_generic` | `sk-` followed by 32+ alphanumerics | `<REDACTED:api-key>` |
| `aws_access_key` | `AKIA` + 16 uppercase alphanumerics | `<REDACTED:aws-access-key>` |
| `aws_secret_key` | 40-char base64ish after `aws_secret_access_key=` | `<REDACTED:aws-secret-key>` |
| `github_token` | `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_` + 36 alphanumerics | `<REDACTED:github-token>` |
| `google_api_key` | `AIza` + 35 alphanumerics | `<REDACTED:google-api-key>` |
| `stripe_key` | `sk_`/`pk_`/`rk_` + `live_`/`test_` + 24+ alphanumerics | `<REDACTED:stripe-key>` |
| `openai_key` | `sk-proj-` + 40+ alphanumerics | `<REDACTED:openai-key>` |
| `anthropic_key` | `sk-ant-` + 40+ alphanumerics | `<REDACTED:anthropic-key>` |
| `jwt` | `eyJ...` three-part base64url | `<REDACTED:jwt>` |
| `ssh_private_key` | `-----BEGIN ... PRIVATE KEY-----` block | `<REDACTED:ssh-private-key>` |
| `password_assignment` | `password=`, `PASS=`, etc. followed by 6+ non-space | `<key>=<REDACTED:password>` |
| `bcrypt` | `$2[abxy]$` + cost + 53-char hash | `<REDACTED:bcrypt>` |
| `argon2` | `$argon2(id\|i\|d)$` + params + hash | `<REDACTED:argon2>` |
| `email` | RFC-5322-ish local@domain.tld | `<REDACTED:email>` |

Patterns run in fixed order. A substring matching multiple patterns is redacted by the first-matching one only.

**Explicit non-targets.** IP addresses, phone numbers, credit-card numbers, SSNs, free-form customer identifiers. Scope is strictly "credentials + obvious PII (email)" — not a company-sensitive-data nexus.

### § 4f. Redaction metadata + observability

Per turn row, `redactions JSONB`:

```json
{"api_key_generic": 0, "aws_access_key": 0, "github_token": 2, "email": 1, ...}
```

Zero-count keys included for stable analytics shape. Parent `adversarial_reviews.redactions` carries the same shape summed across all turn rows.

Observability hookups (§ 1c):
- Counter `review.redactions_total{category, client_tool}` incremented per match.
- Span attribute `redactions.total` (integer sum across categories) on `review.adversary.call` and `review.primary_turn.record`. Enables trace-based investigation without pulling content.

### § 4g. Migration plan

Single file: `big-wave/services/mcp/migrations/20260421000000_dual_model_review.sql`.

Steps, all in a single transaction:

1. `ALTER TABLE adversarial_reviews` — add columns per § 4a.
2. Add `CHECK` constraints.
3. `CREATE TABLE adversarial_review_turns` per § 4b.
4. Create indexes.

**Rollback:** forward-only. `migrations/down/` scripts exist for catastrophic recovery but lose captured turn data. Pre-release dogfood (§ 7c) catches issues before rollback would be needed. Pre-deploy: full DB snapshot.

**Backfill:** none. Legacy rows keep `dual_model=FALSE`, `client_tool=NULL`, `composite_score=NULL`, `effective_threshold=NULL`, `parent_review_id=NULL`. Analytics wanting composite on legacy rows computes on-the-fly from `category_scores`.

### § 4h. Test corpus

`big-wave/services/review/__tests__/redaction.spec.ts`:

- **Positive corpus** — one fixture file per category under `__tests__/fixtures/redaction/positive/<category>.txt` with realistic examples (in prose, JSON, YAML, code comments). Asserts every example redacted.
- **Negative corpus** — `__tests__/fixtures/redaction/negative.txt`. Strings resembling credentials but aren't (UUIDs, base64 of non-secret data, SHA hashes, the word "password" without assignment). Asserts these stay unredacted.
- **JSON-walk invariant** — adversary-output JSON with secrets embedded → redact → parse; parse must succeed; all secrets replaced.
- **Trust-boundary test** — spy on the HTTP client to the Adversary API (asserts it sees unredacted content); spy on the DB layer (asserts only post-redaction content); locks in § 4d trust boundary against regression.
- **Perf budget** — redacting a 256 KB artifact completes in < 150 ms p95 on CI.
- **`tenant_id` invariant** — the persistence module's `insert_turn()` is the only writer. Unit test asserts NULL/mismatched `tenant_id` is impossible through that path; integration test attempts a direct DB insert without `tenant_id` and asserts `NOT NULL` rejects it.
- **RE2 compile-time check** — every pattern compiles under RE2 at module load; adding a backreference-using pattern fails the suite before shipping.

CI gates v1.4.0 release on these passing; also required for future pattern additions.

---

## Section 5/7 — MCP API surface

All changes in the existing MCP server at `big-wave/services/mcp/index.ts` — no new server.

### § 5a. Tool catalog

| Tool | Status | v1.4.0 changes |
|---|---|---|
| `trigger_review` | Extended | Optional `client_tool`, `idempotency_key`, `force_refresh`, `parent_review_id`, `prior_rationale` |
| `get_review_status` | Extended | Response gains `round`, `composite_score`, `stop_reason`, 7th category when `dual_model=true` |
| `resolve_review` | Extended | `retry` valid only when `status=error` (tightened) |
| `record_primary_turn` | **New** | Plugin calls in Turn 3 to persist per-finding rationale + applied diff |

| Resource | Status | v1.4.0 changes |
|---|---|---|
| `movp://movp/config` | Extended | Returns `_meta.source` provenance, `etag`, `revision`, new keys under `review.*` |
| `movp://movp/reviews/<id>/turns` | **New** | Read-only listing of `adversarial_review_turns` for a review, paginated |

All new tool parameters are **optional**. v1.3.x plugins calling `trigger_review` without `client_tool` get single-model behavior exactly as before (§ 1e).

### § 5b. `trigger_review` contract

**Parameters:**

```ts
{
  artifact_type: "plan_file" | "code_output";
  content: string;                                    // ≤256KB (§ 1d)
  session_id?: string;
  client_tool?: "claude-code" | "codex" | "cursor";
  idempotency_key?: string;
  force_refresh?: boolean;                            // bypass 30s config cache (§ 3c)
  parent_review_id?: string;                          // lineage threading; if set,
                                                      // backend sets round = parent.round + 1
  prior_rationale?: {
    round: number;
    findings: Array<{
      finding_id: string;
      decision: "accepted" | "rejected";
      reason: string;                                 // ≤500 chars
    }>;
  };
}
```

**Response:**

```ts
{
  review_id: string;
  round: number;
  status: "pending";
  client_tool: string | null;
  adversary_model_id: string | null;                  // null when dual_model=false
  config_revision: number;
}
```

**Behavior:**

1. If `idempotency_key` matches an existing review within the 10-minute window, return that `review_id` without creating a new row.
2. Resolve effective config. Pin `config_revision` and `effective_threshold` to the parent row.
3. If `dual_model=true` AND `client_tool` present, look up adversary from `model_pairs`. Missing pair or unavailable credential → `400` per § 5h — never silently fall back.
4. If `dual_model=false` OR `client_tool` absent, set `adversary_model_id=null` and run the legacy path.
5. `prior_rationale` is appended to the Adversary's prompt context; rejected findings surface to the Adversary with Primary's reasons.
6. Concurrency gate: one in-flight review per `(tenant, client_tool, repo)` (§ 1d) — otherwise `409 concurrent_review_in_flight`.
7. Redaction runs on `content` pre-INSERT.

**`round` semantics.** Fresh review = `round=1`. Subsequent `trigger_review` with `parent_review_id` set increments round from the parent. Explicit `parent_review_id` is the supported lineage path; `idempotency_key` handles duplicate delivery of a single call, `parent_review_id` threads distinct calls into a lineage.

### § 5c. `get_review_status` contract

**Parameters:** `{review_id: string}` — required in v1.5.0+. In v1.4.0, omitting `review_id` is **deprecated but still works** (returns the most recent tenant review) with a `_meta.deprecated` marker in the response envelope pointing to the v1.5.0 removal. This preserves v1.3.x behavior exactly through the v1.4.0 release.

**Response:**

```ts
{
  review_id: string;
  status: "pending" | "completed" | "error";
  round: number;
  client_tool: string | null;
  dual_model: boolean;
  adversary_model_id: string | null;
  category_scores: {
    correctness: number;
    reliability: number;
    safety: number;
    usability: number;
    performance: number;
    simplicity: number;
    observability?: number;                           // present iff dual_model=true
  };
  composite_score: number | null;                     // null while pending
  effective_threshold: number;
  stop_reason: null | "threshold_met" | "max_rounds" | "score_plateau"
               | "no_progress" | "operator_stop" | "error";
  findings: Array<{
    finding_id: string;                               // stable id for prior_rationale round-trip
    severity: "CRIT" | "HIGH" | "MED" | "LOW";
    category: string;
    confidence: number;                               // 0.0–1.0
    summary: string;
    file_path: string | null;
    line_number: number | null;
    quoted_code: string | null;                       // post-redaction
    suggested_fix: string;                            // post-redaction
  }>;
  cost: { usd: number; sunk_usd?: number; };
  latency_ms: number | null;
  redactions_summary: { [category: string]: number };
  parsing_text: string;                               // preserves v1.3.x regex contract
  _meta?: { deprecated?: { removed_in: string; guidance: string } };
}
```

`parsing_text` is the existing string body today's plugins parse with `Quality:\s*.../\s*10` regex. v1.4.0 preserves it exactly so v1.3.x plugins remain functional. New clients prefer structured fields.

Pure read; idempotent (§ 1b).

### § 5d. `resolve_review` contract

```ts
{
  review_id: string;
  action: "accept" | "dismiss" | "escalate" | "retry";
  reason?: "false_positive" | "not_applicable" | "deferred";  // required when action=dismiss
  target?: "todo";                                            // required when action=escalate
}
```

**Tightened rule (v1.4.0):** `action="retry"` valid **only** when current `status=error`. Calling retry on a completed review returns `400 retry_on_completed_review`. v1.3.x was loose here; tightened because retry on completed is almost always an operator mistake.

### § 5e. `record_primary_turn` **(new)**

Called by the plugin after Turn 3.

**Parameters:**

```ts
{
  review_id: string;
  round: number;
  rationale: Array<{
    finding_id: string;                               // must match get_review_status finding_id
    decision: "accepted" | "rejected";
    reason: string;                                   // ≤500 chars; mandatory for both decisions
    applied_file_path?: string;                       // when decision=accepted
    applied_diff?: string;                            // when decision=accepted; ≤64KB
  }>;
  artifact_after: string;                             // ≤256KB (§ 1d)
  cost_usd?: number;                                  // plugin's local-reasoning cost estimate
  latency_ms?: number;
  client_generated_at: string;                        // RFC3339; clock-skew diagnostics only
}
```

**Response:**

```ts
{
  review_id: string;
  round: number;
  turn_number: number;                                // always 2 in v1.4.0; widened for future turns
  persisted: true;
  redactions: { [category: string]: number };
}
```

**Behavior:**

1. Validates `review_id` tenant ownership; validates `round` exists with a completed adversary turn. Otherwise `404 review_not_found` / `409`.
2. Validates every `finding_id` matches a finding from that `(review_id, round)` adversary output. Unknown → `400 unknown_finding_id`.
3. Idempotency: upsert on `(review_id, round, turn_number=2)`. Duplicate calls update content (last-write-wins); `cost_usd`/`latency_ms` accept only first non-null writes.
4. Redaction runs on `reason`, `applied_diff`, `artifact_after`. Rollup returned in response so plugin can surface to operator.
5. Does **not** trigger the next round — plugin explicitly calls `trigger_review` with `prior_rationale` after `record_primary_turn` succeeds. Keeps control flow explicit and testable.

### § 5f. `movp://movp/config` resource

```ts
{
  revision: number;
  etag: string;
  review: { ... };                                    // full shape from § 3
  settings_url: string;
  _meta: {
    source: { [dotted_path: string]: "default" | "tenant" | "repo" | "local" };
  };
}
```

Server returns only server-owned fields. Client-side cache metadata (`cached_at`, `ttl_seconds`) is plugin-side concern documented in § 6 — not part of this envelope.

Authenticated by `MOVP_API_KEY`; scoped to calling tenant. Plugins cache 30 s keyed on `revision`; PATCH worst-case visibility lag = 30 s. Any `revision` change → cache invalidated.

### § 5g. `movp://movp/reviews/<id>/turns` **(new)**

Read-only listing of turns for a review.

```ts
{
  review_id: string;
  turns: Array<{
    round: number;
    turn_number: number;
    role: "adversary" | "primary";
    model_id: string | null;
    cost_usd: number;
    latency_ms: number | null;
    redactions: { [category: string]: number };
    created_at: string;
    // input_content / output_content NOT returned by default (size).
    // Fetch ?include_content=true if needed.
  }>;
  total_cost_usd: number;
  cursor: string | null;
}
```

Query params: `?cursor=<opaque>&limit=<N>&include_content=<bool>`. Default limit 50. Authorization: `MOVP_API_KEY` + tenant check on `adversarial_reviews.tenant_id`. Cross-tenant access → `404` (not `403` — don't leak review-id existence across tenants).

### § 5h. Error taxonomy (split by transport)

**MCP tool errors.** Returned as JSON-RPC error objects with structured body `{error: {code, message, remediation?, details?}}`:

| Code | When |
|---|---|
| `invalid_artifact_type` | `artifact_type` not in enum |
| `artifact_too_large` | `content` > 256KB; details include `limit_bytes`, `actual_bytes` |
| `unknown_client_tool` | `client_tool` not in canonical set |
| `no_pair_configured` | `dual_model=true` but no pair for this client_tool at any layer |
| `no_credential_for_provider` | pair points at a provider with no credential; details include `provider` |
| `unknown_finding_id` | `record_primary_turn.rationale` references ids not in the prior adversary turn |
| `unknown_parent_review` | `parent_review_id` passed but not found or not owned |
| `retry_on_completed_review` | § 5d tightened rule |
| `missing_review_id` | v1.5.0+ only — argument-less `get_review_status` |
| `forbidden` | tenant mismatch on a resolvable id |
| `review_not_found` | unknown `review_id` for this tenant |
| `concurrent_review_in_flight` | § 1d gate; details include live `review_id` |
| `config_unreachable` | backend config store down; plugin prints fail-closed (§ 3c) |
| `redaction_engine_failure` | regex engine threw/timed out; details include `pattern_category` only, never content |
| `internal` | everything else; details omitted |

**HTTP API errors** (config management endpoints at § 2a):

| Code | HTTP status | When |
|---|---|---|
| `schema_validation_failed` | 400 | PATCH body failed JSON-schema validation |
| `scoring_override_ignored` | 200 + `_meta.warnings` | request tried to write `review.scoring.*` (§ 3a) |
| `forbidden` | 403 | non-admin PATCH |
| `etag_mismatch` | 409 | `If-Match` stale against current revision |
| `internal` | 500 | unexpected server error |

**Content safety.** No error message or `details` field ever echoes user-supplied content. A `content: "sk-live_abcd..."` that fails redaction returns `redaction_engine_failure` with `details: {pattern_category: "stripe_key"}` — offending input never serialized into responses or logs.

### § 5i. Authentication & scoping

Unchanged from v1.3.x. `MOVP_API_KEY` env var identifies the tenant. No per-user identity. New tools/resources inherit existing auth middleware.

**`client_tool` is not a trust boundary.** Backend treats it as a routing input, not an authz signal. A malicious plugin claiming `client_tool: "cursor"` from a Claude Code session gets Cursor's adversary model — annoying, wastes credits, not a privilege escalation. Same posture as the existing `.movp/config.yaml` trust boundary.

### § 5j. Backward compatibility matrix

| Caller | Backend | Result |
|---|---|---|
| v1.3.x plugin | v1.4.0 backend | `dual_model` implicitly false; no `client_tool`; new response fields unconsumed; `parsing_text` preserved. Argument-less `get_review_status` still works (deprecation marker in response). Zero regression. |
| v1.4.0 plugin | v1.4.0 backend, `dual_model=false` | Plugin reads flag, falls through to v1.3.x protocol internally. Same as above. |
| v1.4.0 plugin | v1.4.0 backend, `dual_model=true` + pair configured | New 4-turn protocol active. |
| v1.4.0 plugin | v1.3.x backend | Plugin detects missing `record_primary_turn` in deferred tool list; surfaces *"dual-model review requires backend ≥1.4.0; running in legacy single-model mode"*; runs v1.3.x protocol. Graceful degradation. |

Plugins requiring v1.4.0 backend (automation scripts) can check `revision` key presence on `movp://movp/config` — absent on v1.3.x — and hard-fail with a version mismatch message.

---

## Section 6/7 — Plugin command refactor

Applies to all three plugin surfaces. The prose is authoritative; each plugin ports the same state machine into its native mechanism (§ 6k).

### § 6a. Command invocation & effective-config disclosure

**Step 0.** Read `movp://movp/config`. If unreachable, emit fail-closed message (§ 3c) and exit.

**Step 0a.** Extract effective values:

| Variable | Source |
|---|---|
| `dual_model` | `review.dual_model` |
| `client_tool` | **plugin-hardcoded** per § 6k |
| `adversary_model` | `review.model_pairs[client_tool].adversary` when `dual_model=true`; else `null` |
| `effective_threshold` | `review.threshold` when `dual_model=true`; `review.legacy_threshold` otherwise |
| `max_rounds` | `review.max_rounds` |
| `plateau_epsilon` | `review.plateau.delta_epsilon` |
| `plateau_n` | `review.plateau.consecutive_rounds` |
| `confirm_before_apply` | `review.confirm_before_apply` |
| `config_revision` | `revision` from resource envelope |

**Step 0b — disclosure** (before first `trigger_review`):

```
[MoVP] Adversarial review — effective config
  Primary:    <client_tool>
  Adversary:  <adversary_model or "(same as primary — dual-model review disabled)">
  Threshold:  <effective_threshold>/10
  Max rounds: <max_rounds>
  Plateau:    stop if |Δscore| < <plateau_epsilon> for <plateau_n> consecutive rounds
  Revision:   <config_revision>
```

No y/n gate — `/movp:review` is already explicit intent. (Contrast with `review-advisor` skill's first-run consent prompt, which is auto-invoked.)

### § 6b. State machine

```
round            = 1
parent_review_id = null
previous_score   = null
current_score    = null
total_cost_usd   = 0.0
plateau_streak   = 0
active_review_id = null
```

Per-round flow:

```
┌─────────────────────────────────────────────────────────────────┐
│ round N                                                         │
├─────────────────────────────────────────────────────────────────┤
│ 6c  Turn 2 — call trigger_review, poll get_review_status        │
│ 6e  evaluate stop conditions                                    │
│        if stop: → post-loop                                     │
│ 6d  Turn 3 — per-finding rationale + apply + record_primary_turn│
│ 6f  setup Turn 4 (next iteration)                               │
│        parent_review_id = active_review_id                      │
│        previous_score = current_score                           │
│        round += 1                                               │
└─────────────────────────────────────────────────────────────────┘
```

Linear; no hidden goto's. Errors abort with `stop_reason="error"`.

### § 6c. Turn 2 — adversary call

1. Build `trigger_review` params:
   ```ts
   {
     artifact_type: <"plan_file" | "code_output">,
     content: <current artifact text>,
     session_id: <session id>,
     client_tool: <hardcoded; § 6k>,
     idempotency_key: "<session_id>:<artifact_sha>:<round>",
     parent_review_id: <null on round 1; previous round's review_id otherwise>,
     prior_rationale: <null on round 1; § 6d output on round ≥ 2>,
   }
   ```
2. Store returned `review_id` as `active_review_id`.
3. Poll `get_review_status(review_id=active_review_id)` every 2 s until `status ∈ {completed, error}`. Honor `Retry-After`.
4. On `status=error`: print `message` + `remediation`; set `stop_reason=error`; exit. Do not auto-retry.
5. On `status=completed`: parse structured fields (`composite_score`, `category_scores`, `findings`, `cost`, `redactions_summary`). Fall back to `parsing_text` only if structured fields absent (pre-1.4.0 backend).
6. Update state: `current_score = composite_score`; `total_cost_usd += cost.usd`.

### § 6d. Turn 3 — per-finding rationale + apply

Runs only when `dual_model=true` AND `findings.length > 0`.

**Per finding** (order: CRIT → HIGH → MED → LOW):

1. **Decide.**
   - If `confirm_before_apply=true`: prompt operator `Accept? [y/N]` for every finding; record decision + operator's optional rationale.
   - Otherwise (v1.3.x parity default):
     - CRIT/HIGH with `confidence ≥ 0.8`: **accept** unless the finding contradicts a verified project invariant.
     - MED: judgment — accept when fix is low-cost (≤10 LOC) and benefit is clear.
     - LOW: default reject unless the finding flags a correctness issue misjudged by severity.

2. **Accepted:**
   - Apply the fix. For `plan_file`: edit the plan markdown. For `code_output`: edit the code file(s) at `file_path`.
   - Capture applied diff (unified, ≤64KB) and `file_path`.
   - Record: `{finding_id, decision: "accepted", reason, applied_file_path, applied_diff}`.

3. **Rejected:**
   - Record: `{finding_id, decision: "rejected", reason}`. Reason is required; "disagree" alone is not acceptable — name the invariant or falsification.

**After all decisions:**

4. Regenerate updated artifact text.
5. Call `record_primary_turn` with all rationale + `artifact_after` + cost/latency estimates.
6. Print summary:
   ```
   Turn 3 — Primary response (round <N>)
     Accepted: <count> findings (<sev breakdown>)
     Rejected: <count> findings (<sev breakdown>)
     Modified: <file1>, <file2> (brief description of fix)
   ```
7. Forward `rationale` to Turn 4 via `prior_rationale` on the next `trigger_review`.

**No-op guard.** If zero findings were accepted AND no artifact change was made: set `stop_reason="no_progress"` and exit. Nothing for Turn 4 to re-review.

### § 6e. Stop conditions (consolidated)

After Turn 2 of round N, evaluate in order. First match wins:

| Condition | `stop_reason` | Message |
|---|---|---|
| `findings.length === 0` AND `current_score >= effective_threshold` | `threshold_met` | *No findings and score at threshold (<score>/10). Loop complete.* |
| `findings.length === 0` AND `current_score < effective_threshold` | `no_progress` | *No findings produced but score is below threshold. Adversary had nothing actionable — review the artifact manually.* |
| `current_score >= effective_threshold` AND no CRIT/HIGH findings | `threshold_met` | *Score threshold reached (<threshold>/10). Loop complete.* |
| `round == max_rounds` | `max_rounds` | *Max review rounds reached (<max_rounds>). Last score: <current>/10.* |
| `previous_score != null` AND `\|current - previous\| < plateau_epsilon`: increment `plateau_streak`; if `plateau_streak >= plateau_n` | `score_plateau` | *Score plateau (<plateau_n> rounds with \|Δ\| < <epsilon>). Loop complete.* |
| Turn 2 returned error | `error` | *Review error: <message>.* |
| Operator typed "stop" at inter-round prompt | `operator_stop` | *Operator stopped the review loop.* |

If `|current - previous| >= plateau_epsilon`, reset `plateau_streak = 0`.

**Post-loop:**

```
[MoVP] Adversarial review complete
  Final score:   <current>/10
  Stop reason:   <stop_reason>
  Rounds:        <round>
  Total cost:    $<total_cost_usd>
  Review lineage: <active_review_id> (root: <root_review_id>)
```

Then: `Continue with implementation, or something else?` — operator drives.

### § 6f. Inter-round operator gate

After § 6g output block:

- **Interactive TTY:** `Continue to next review round, or stop? [continue]`. Block on stdin. Default (empty/Enter) = continue. `stop` = `operator_stop`. No timeout. Other input → re-prompt once; second non-match = stop.
- **Non-interactive (CI / no tty):** auto-continue. Loop bounded by `max_rounds`, `threshold`, `plateau`, `no_progress` — all deterministic.
- **Force non-interactive:** env var `MOVP_REVIEW_NONINTERACTIVE=1`.

Gate runs only between rounds — never between Turn 2 and Turn 3 within a round.

### § 6g. Inter-round output formatting

```
[MoVP] Review Loop — Round <N>

Score: <current>/10  (Δ +<delta> vs round <N-1>)
Cost this round: $<round_cost>   Running total: $<total_cost_usd>

Category Scores:
  correctness: <n>   observability: <n>   reliability: <n>
  safety: <n>        usability: <n>       performance: <n>
  simplicity: <n>

Redactions this round: <category: count, ...> (or "none")

Findings (<total>):

[CRIT] <category> (conf <confidence>)
  <summary> — <file_path>:<line_number>
  Fix: <suggested_fix>

[HIGH] ...
[MED]  ...
[LOW]  ...
```

Round 1 shows `Initial score: <current>/10` instead of delta. When `dual_model=false`, the `observability` cell is omitted — the grid is 6-wide.

### § 6h. `review-advisor` skill updates (passive single-shot)

Outer contract unchanged: post-artifact, auto-triggered, single Adversary pass, no loop. Internal changes:

1. When `dual_model=true`, the adversary is the configured pair model; otherwise legacy primary-as-adversary.
2. Response includes the 7th `observability` category when `dual_model=true`.
3. Skill does **not** call `record_primary_turn` — passive by design. Turn table gets one row (adversary only). Operator choices (accept/dismiss/escalate via `resolve_review`) captured on the parent row.
4. First-run consent prompt and parsing spec unchanged.
5. SKILL.md gains a "Relationship to `/movp:review`" section pointing to this spec for the rationale-producing loop.

### § 6i. `dual_model=false` fallback

Clean strict subset of the dual-model path:

1. `trigger_review` sends `client_tool` (advisory); omits `prior_rationale`, `parent_review_id`.
2. No Turn 3 rationale capture. Round ends with auto-accept/auto-apply per § 6d (v1.3.x parity); no `record_primary_turn`.
3. `effective_threshold = review.legacy_threshold` (default 9.0).
4. Post-loop output omits the "Review lineage" line.
5. First-line banner:
   ```
   [MoVP] Single-model review mode (dual_model=false).
          Enable model pairs in /movp:settings for 4-turn dual-model protocol.
   ```

All deltas flagged by persisted columns (`dual_model`, `effective_threshold`, `parent_review_id IS NULL`) — parity test suite (§ 1e) asserts structural equivalence with v1.3.x.

### § 6j. Error handling map

| Backend error (§ 5h) | Command behavior |
|---|---|
| `config_unreachable` | Print § 6a fail-closed message; exit |
| `no_pair_configured`, `no_credential_for_provider` | Print error `remediation` verbatim; exit |
| `artifact_too_large` | Print size + limit + remediation; exit. Do not auto-split — chunks lose context |
| `concurrent_review_in_flight` | Offer (a) poll live review and continue from there, or (b) cancel + `resolve_review(action=dismiss, reason=deferred)` on the live id. Default on no reply: (a) |
| `unknown_finding_id` | Plugin-side bug — print finding id list, file as plugin bug |
| `redaction_engine_failure` | Print *"Backend issue; this round was not persisted. Retry after a short wait or check /movp:status."* Exit. Do not auto-retry |
| `retry_on_completed_review` | Command-logic bug — print + exit |
| `internal` | Print generic *"Backend error — check /movp:status"*; exit |
| Any other `4xx` | Print `message`; exit |

### § 6k. Client-tool identity hardcoding + mechanism per plugin

| Surface | Mechanism | File path | Identity constant |
|---|---|---|---|
| Claude Code | Slash command | `claude-plugin/commands/review.md` | `claude-code` |
| Codex | Skill | `codex-plugin/skills/review/SKILL.md` | `codex` |
| Cursor | Rule + MCP tool chain | `cursor-plugin/rules/movp-review.mdc` | `cursor` |

The identity is a compile-time constant per plugin — not read from config, not derived from User-Agent, not inferred from MCP transport.

*Rejected alternatives:* Codex-as-command (no command primitive exists in Codex plugin format today). Cursor-as-rule-only-no-tools (without MCP tools, rule can't reach `trigger_review`). Cursor-as-MCP-only (no canonical trigger phrase).

### § 6l. `.movp/config.yaml` override UX

An operator overriding the adversary per-repo sees provenance in § 6a disclosure:

```
Adversary: openai/gpt-4.9  (from .movp/config.yaml:14 — overrides tenant default openai/gpt-5.4)
```

Provenance string driven by `_meta.source` from the resolved config (§ 3d).

---

## Section 7/7 — Rollout & dogfood path

### § 7a. Artifacts, release trains, stages

- **Artifacts (5):** `backend (big-wave/services/mcp + review service)`, `frontend (web UI)`, `claude-plugin`, `codex-plugin`, `cursor-plugin`.
- **Release trains (3):** `backend-release`, `frontend-release`, `plugins-aligned-release` (three plugins ship in lock-step per § 7b).
- **Stages (6):** Stages 1–3 deploy trains in dependency order; stages 4–6 are post-deployment tenant-exposure stages.

```
Stage                          Artifact                             Depends on
─────────────────────────────  ───────────────────────────────────  ──────────────
1. Backend release (v1.4.0)    big-wave/services/mcp + review svc   —
2. Frontend release            MoVP web UI — Model Pairs page        Backend (PATCH endpoint)
3. Plugin releases (3×)        claude-plugin, codex-plugin,          Backend (record_primary_turn +
                               cursor-plugin — bumped to v1.4.0      extended config)
                               in lock-step
4. Mona Lisa dogfood           Founder's tenant flipped on           Stages 1–3 complete
5. Early-access rollout        Opt-in tenants enabled                Stage 4 exit criteria
6. GA                          Default-on for new tenants            Stage 5 exit criteria
```

**Inter-stage invariant.** At every boundary, older clients work unmodified per § 5j. Argument-less `get_review_status` still works in v1.4.0 (deprecation marker); strict removal waits for v1.5.0.

### § 7b. CI gates per stage

**Stage 1 — Backend:**
- `big-wave/services/mcp/__tests__/review-parity.spec.ts` — § 1e regression suite
- `big-wave/services/review/__tests__/redaction.spec.ts` — § 4h full suite
- `big-wave/services/review/__tests__/dual-model-e2e.spec.ts` — happy-path 2-round loop with stubbed adversary; asserts every persisted turn row, composite computation, stop transitions, `effective_threshold` persistence
- DDL migration applied to staging snapshot; zero constraint violations, zero unexpected NULLs, zero row rewrites

**Stage 2 — Frontend:**
- `admin-can-configure-pairs.spec.ts` Playwright (§ 2f)
- Non-admin read-only + 403 regression
- Visual regression on Settings area

**Stage 3 — Plugins (all three must pass before any ships):**
- `scripts/validate.sh` — existing CI hygiene
- Plugin smoke: local MCP fixture + `/movp:review` (or equivalent per § 6k) drives a 2-round loop end-to-end, asserts stdout sequence (disclosure, round banners, post-loop)
- `.movp/config.local.yaml` fixture tests for merge semantics (§ 3b cases)
- Parity smoke against v1.3.x-shaped backend fixture — asserts graceful-degradation banner and legacy loop completion

Lock-step requirement prevents asymmetric deployment where one plugin surface has the new protocol and another doesn't.

### § 7c. Mona Lisa dogfood plan

First user of dual-model flow = the founder. Matches existing practice (*"the founder will run adversarial reviews against plans before approving"*).

**Setup:**
1. Backend + plugins at v1.4.0 deployed.
2. Founder resolves slug `mostviableproduct` → canonical `tenant_id` UUID via `GET /auth/tenants`. Pastes UUID into the ops-dashboard query template.
3. Founder opens web UI Model Pairs, enables `dual_model`, accepts defaults.
4. Verifies via `/movp:status` that effective config shows `dual_model: tenant` + expected pair.
5. Dogfood window opens.

**Window: 14 calendar days.**

Founder uses `/movp:review` on normal work — plan files for future phases, significant code changes, anything manually adversarially-reviewed today.

**Exit criteria (all must hold):**

| Criterion | Measure |
|---|---|
| ≥ 10 dual-model reviews on MoVP tenant | `SELECT COUNT(*) FROM adversarial_reviews WHERE dual_model=TRUE AND tenant_id=<MoVP UUID>` |
| Zero `redaction_engine_failure` errors | § 1c counter at zero for MoVP tenant |
| Review-service error rate ≤ 0.5% over 14 days | `error_code="internal"` OR `stop_reason="error"` / total reviews, scoped to `dual_model=TRUE AND tenant_id=<UUID>` |
| `review.round_duration_seconds` p95 ≤ 45 s | § 1d SLO held |
| Composite in [0, 10] always | Range CHECK constraint; alert on any violation |
| Founder subjective thumbs-up on loop UX | One-line confirmation in changelog entry |
| No data-shape surprises in `adversarial_review_turns` | Manual spot-check of 5 random reviews |

**Abort criteria (any → rollback):**
- Any `redaction_engine_failure` in production (unsafe pattern set against real content)
- Any cross-tenant leak (§ 7e canary non-zero)
- p99 `review.round_duration_seconds` > 120 s
- Composite-score outside [0, 10]
- Per-day error rate > 2% on any single day

### § 7d. Tenant rollout stages

| Stage | Who | Exit gate |
|---|---|---|
| 4. Mona Lisa dogfood | `mostviableproduct` tenant only | § 7c exit criteria |
| 5a. Early-access (opt-in) | Tenants who flip `dual_model=true` in their own UI | 14 days, no P0/P1 reports; ≥ 5 tenants active |
| 5b. Default-pre-fill | New tenants have `dual_model=true` pre-filled in UI defaults; toggle still starts **off** (discoverable, not forced) | 30 days, no P0/P1 |
| 6. GA (default-on) | New tenants have `dual_model=true` **enabled** by default + pairs pre-saved; existing tenants unchanged | Soft — re-evaluate 60 days after 5b |

**Existing tenants' flag is never auto-flipped.** Dual-model is a credit-spend event; silent enablement is not acceptable.

### § 7e. Rollout SLIs

*Queries below are sketches against the field names emitted by § 1c instrumentation. Before saving alerts, verify field presence in the `big-wave-mcp` dataset in Honeycomb.*

| SLI | Query sketch | Threshold |
|---|---|---|
| Review success rate | `COUNT_DISTINCT(review_id) WHERE stop_reason IN (threshold_met, max_rounds, score_plateau, no_progress, operator_stop) / COUNT_DISTINCT(review_id)` grouped by `client_tool`, `dual_model` | ≥ 99.0% (error-state excluded) |
| Round p95 | `P95(review.round_duration_seconds)` by `adversary_provider` | ≤ 45 s |
| Redaction fire rate | `SUM(review.redactions_total)` by `category` | Monitor; alert at 10× baseline |
| Composite distribution | `HEATMAP(composite_score)` by `dual_model`, `client_tool` | Bimodal/reasonable; spike at 0 or 10 = red flag |
| Cost per review p95 | `P95(total_cost_usd)` per review | Monitor; alert at 2× projection |
| Plateau/no_progress rate | `COUNT(*) WHERE stop_reason IN (score_plateau, no_progress) / COUNT(*)` | Expected 10–20%; alert at > 40% |
| Cross-tenant leak canary | `SELECT COUNT(*) FROM adversarial_review_turns t JOIN adversarial_reviews r ON r.id=t.review_id WHERE t.tenant_id != r.tenant_id` | **Always 0** — any non-zero → pager + rollback |

Canary uses the denormalized `tenant_id` column added in § 4b. Invariant enforced at write time; canary is belt-and-suspenders runtime assertion.

All SLIs carry § 1c span attributes — one-click drill-down from any alert.

### § 7f. Rollback strategy per stage

| Stage | Rollback mechanism |
|---|---|
| 1. Backend | Revert services binary; schema stays (harmless — additive migration). Catastrophic: `migrations/down/` (loses turn data). Pre-deploy DB snapshot required |
| 2. Frontend | Revert frontend binary. Saved configs remain; just no UI. Backend tolerates configs without UI presence |
| 3. Plugins | Users pin to prior version via `installed_plugins.json` (reference memory). Auto-update users roll back automatically |
| 4. Dogfood | Founder flips `dual_model=false` via UI. Immediate. No deploy. Captured turn data stays for post-mortem |
| 5–6. Wider rollout | Tenant-level flag flip. No global kill switch — reserved for catastrophic backend failure via Stage 1 rollback |

### § 7g. Meta-learning pipeline activation

v1.4.0 delivers the *data substrate* (`adversarial_review_turns`). The pipeline itself is **out of v1.4.0 scope**.

1. **v1.4.0:** turn rows populated with rationale from every dual-model review.
2. **v1.4.1 or v1.5.0:** rule-suggestion pipeline reads from the turn table; hooks into existing `generate_suggestions` / `detect_patterns` / `dismiss_rule_suggestion` tools per project memory Phase 3.
3. **Activation threshold:** pipeline starts producing suggestions once a tenant has ≥ 50 dual-model reviews with rationale entries. Below that, sample size is too small. Threshold is a backend constant, not config.

No rollout stage is blocked on pipeline readiness — data accumulates from v1.4.0 deploy day.

### § 7h. Documentation & communications

| Surface | File/channel | What changes |
|---|---|---|
| Mona Lisa repo | `CHANGELOG.md` | v1.4.0 entry |
| Mona Lisa repo | `README.md` | "Adversarial review" section updated |
| Big Wave repo | `big-wave/services/mcp/CHANGELOG.md` | Backend changes, migration instructions |
| Frontend repo | Frontend changelog | Settings / Model Pairs page |
| `docs/superpowers/specs/` | This file | Source of truth |
| Plugin manifests | 3× `manifest.json` | Version bump to `1.4.0`; `mcp_server_pin` bumped |
| Homebrew formula | `scripts/homebrew/*` | New release tag |
| Customer comms | Blog / release notes | Opt-in call-to-action; no forced migration; explicit cost language |

**Credential provisioning docs** (new, in `docs/`): how to register an OpenAI API key for a MoVP tenant, analog for Anthropic. Required for cross-provider adversary routing.

### § 7i. Version pinning across repos

v1.4.0 is an **aligned release**: backend, frontend, and all three plugins bump 1.3.x → 1.4.0 in the same release window. Any mismatch falls under the § 5j graceful-degradation matrix and is surfaced via mode banner.

`plugin-manifest.json` validation gains a check: *plugin version must match `mcp_server_pin` minor version* — prevents shipping a 1.4.0 plugin against a 1.3.x server-pin by mistake.

### § 7j. Known risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Adversary provider outage during review | Medium | `trigger_review` returns `500 internal` with provider detail; operator re-runs. Provider-diversified tenants unaffected |
| Redaction misses a credential in the wild | Low-Medium | Point-release adds patterns; observability counter surfaces "redacted token in output but not input" as leak signal |
| Weight change causes score incomparability | Low | Weights pinned in code (§ 3a); historical composites pinned per-row (§ 4c) — retroactive immutability |
| Rule-suggestion pipeline hallucinates bad rules | Medium | Out-of-scope; mitigated when pipeline ships via `dismiss_rule_suggestion` + founder approval |
| Graceful-degradation banner confuses operators | Low | Explicit banner text + `/movp:status` makes mismatch clear |
| Config cache staleness after PATCH | Low | § 3c 30 s TTL; `/movp:status` shows `cached_at`; `force_refresh=true` escape hatch |

---

## Appendix — Rejected alternatives (consolidated)

- **Backend-hosted Primary** — running the Primary model server-side (Q1 option B/C). Rejected: violates the "native-to-tool only" UX philosophy; doubles backend cost surface; the user's local session is already the authoritative source of artifact changes.
- **Infer `client_tool` from MCP transport / User-Agent** (Q3 option B). Rejected: fragile, invisible on misfire.
- **Per-session `client_tool` state** (Q3 option C). Rejected: adds session state for no payoff over explicit param.
- **Single adversary per tenant, no per-client-tool pairing** (Q3 option D). Rejected: loses the cross-family groupthink reduction that motivates the refactor.
- **Rename-only "validate" step** (Q2 option A). Rejected: doesn't operationalize "if valuable"; no auditable rationale.
- **User-in-the-loop per finding** (Q2 option C) — as the default. Rejected as default (breaks auto-loop UX); kept as opt-in via `confirm_before_apply`.
- **Budget-cap (dollars-per-review) loop ceiling** (Q5 option B). Deferred to a later release; requires cost-estimate plumbing backend doesn't have today.
- **Tenant-only model pairs, no `.movp/config.yaml` override** (Q6 option A). Rejected: blocks per-repo experimentation without admin approval.
- **Per-user `.movp/config.local.yaml` override surfaced in UI** (Q6 option C). Deferred; niche use case.
- **Atomic replace of `/movp:review`** (Approach 1). Rejected: invasive cost increase for every existing user on upgrade day.
- **Parallel `/movp:dual-review` command** (Approach 2). Rejected: dual codepaths + awkward sunset.
- **Tenant-configurable redaction patterns.** Rejected: slope toward company-sensitive-data nexus; intentional friction.
- **JSONB `turns` on parent table** instead of child table (§ 4b). Rejected: breaks indexable cross-review queries the rule-suggestion pipeline needs.
- **Postgres trigger for `tenant_id` denormalization on turns** (§ 4b). Rejected: single-writer app invariant is simpler and test-covered.
- **User-editable scoring weights** (§ 3a). Rejected for v1.4.0: cross-tenant comparability requires fixed weights; revisit if demand emerges.
- **Model-family enum** (`chatgpt`, `claude`) instead of namespaced id (§ 3). Rejected: forecloses future models from the same provider; obscures version drift.
- **Codex-as-command** (§ 6k). Rejected: no command primitive in Codex plugin format.
- **Cursor-as-rule-only-no-tools** (§ 6k). Rejected: rule can't reach `trigger_review` without MCP tools.
- **Retro-redaction of pre-v1.4.0 rows** (§ 4d). Out of scope; separate migration if compliance requires.
- **Loader mapping `threshold` 9.2 → 9.0 when `dual_model=false`** (earlier § 6i draft). Rejected: implicit and hard to reason about; replaced by explicit `legacy_threshold` config key (§ 3, § 6e).
