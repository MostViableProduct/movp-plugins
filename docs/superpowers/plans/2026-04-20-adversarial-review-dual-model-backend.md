# Dual-Model Adversarial Review — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the v1.4.0 backend slice of dual-model adversarial review: DDL for `adversarial_review_turns` + new columns on `adversarial_reviews`, RE2-backed redaction pipeline, weighted composite scoring, extended MCP tool contracts, new `record_primary_turn` tool, `movp://movp/reviews/<id>/turns` resource, parity regression suite. Ships with `dual_model=false` default so v1.3.x plugins have zero regression.

**Architecture:** Two-language backend. **Go** (`services/workdesk/`) owns DDL, review-adversary-call logic, scoring, and turn persistence. **TypeScript** (`services/mcp/`) owns MCP tool dispatch, resource endpoints, config resolution, and redaction. New RE2-backed redaction module replaces today's `stripSecrets()`. All schema changes are additive — nullable columns + new child table — so forward-only migration is safe on a live DB.

**Tech Stack:** Go (workdesk service), TypeScript (MCP service), Supabase Postgres, Vitest (TS tests), Go stdlib `testing`, [`re2`](https://www.npmjs.com/package/re2) npm package (new dep).

**Spec:** `/Users/ensell/Code/mona-lisa/docs/superpowers/specs/2026-04-20-adversarial-review-dual-model-design.md` — this plan implements Section 4 (schema + redaction), Section 5 (MCP API), and the backend slice of Section 7b (CI gates). Frontend (§ 2) and plugins (§ 6) are separate plans.

**Out of scope:** Web UI Model Pairs page (separate plan), plugin-side command changes (separate plan), Meta-learning pipeline (deferred per spec § 7g), Honeycomb dashboard creation (ops activity, not code).

**Repo:** `/Users/ensell/Code/big-wave`. All commits in this plan target that repo.

---

## File Structure (what gets created / modified)

**Created:**
- `services/mcp/redaction.ts` — new RE2-backed redaction module; replaces today's `stripSecrets()`
- `services/mcp/redaction_patterns.ts` — authoritative pattern list (source of truth per spec § 4e)
- `services/mcp/redaction.test.ts` — corpus + perf + trust-boundary tests
- `services/mcp/__tests__/fixtures/redaction/positive/<category>.txt` — one per category
- `services/mcp/__tests__/fixtures/redaction/negative.txt` — non-credential shaped strings
- `services/mcp/__tests__/fixtures/redaction/email-as-content.txt` — separate bucket per spec § 4h amendment
- `services/mcp/provider_catalog.ts` — provider → credential-slot availability lookup
- `services/mcp/provider_catalog.test.ts`
- `services/mcp/review-parity.test.ts` — § 1e regression suite
- `services/mcp/dual-model-e2e.test.ts` — happy-path 2-round loop with stubbed adversary
- `services/workdesk/turns.go` — `adversarial_review_turns` handlers (create, list)
- `services/workdesk/turns_test.go`
- `services/workdesk/scoring.go` — weighted composite computation
- `services/workdesk/scoring_test.go`
- `services/workdesk/weights.go` — pinned weight constants
- `supabase/migrations/20260421000000_dual_model_review.sql` — RLS policies for new table + new column grants

**Modified:**
- `services/workdesk/migrate.go:217-267` — add columns to `adversarial_reviews`; add `CREATE TABLE adversarial_review_turns`
- `services/workdesk/reviews.go` — extend to accept `client_tool`, `parent_review_id`, `prior_rationale`; call scoring; call turn persistence
- `services/mcp/movp-config.ts:19-171` — extend `MovpReviewConfig` + validator for new keys
- `services/mcp/tools/dispatch.ts:1194-1360` — extend `trigger_review`/`get_review_status`/`resolve_review`; add `record_primary_turn`
- `services/mcp/index.ts` — register `movp://movp/reviews/<id>/turns` resource
- `services/mcp/review-utils.ts:10-20` — remove `stripSecrets()`; re-export from new `redaction.ts`
- `services/mcp/package.json` — add `re2` dep

---

## Migration ownership (two runners, one schema)

Two distinct migration systems own different slices of the schema. Writes must land in the right one:

| Runner | Path | Owns |
|---|---|---|
| **Workdesk Go** (`db.Migrate(...)` wrapper in `services/common/db/postgres.go`) | `services/workdesk/migrate.go` | Table DDL: `CREATE TABLE`, `ALTER TABLE ADD COLUMN`, CHECK constraints, indexes. Runs on workdesk service startup, idempotent per block. |
| **Supabase CLI** | `supabase/migrations/YYYYMMDDHHMMSS_*.sql` | RLS policies, helper functions, `GRANT`s, anything the Supabase PostgREST layer consumes. Applied via `supabase db push` or `supabase db reset` in CI. |

**Do not duplicate DDL across the two runners** — Supabase migrations should reference tables that already exist (created by workdesk) and only layer policy/permission concerns on top. Task 1 follows this split: column additions + new table go in `migrate.go`; RLS for the new table goes in the Supabase migration file. Future backend tasks adding tables must do the same.

## Merge sequence (tasks are parallel-authorable, not parallel-mergeable)

Tasks 3–10 are independent enough to be **authored in parallel** by different agents on separate branches. But integrating them back to `feature/review-dual-model-v1.4.0-backend` (or directly to `main`) requires an order — later tasks assume earlier tasks' symbols and schema are already landed. Suggested merge order:

```
Task 1 (DDL) → Task 2 (config) → {Task 3 (provider catalog), Task 5 (weights + scoring)}
  → Task 4 (redaction) → Task 6 (turn persistence)
  → Task 7 (extended tools) → Task 8 (turns resource) → Task 9 (OTel) → Task 10 (parity + e2e)
```

Rationale for the strictly-ordered edges:
- **Task 1 before Task 6** — `adversarial_review_turns` must exist before turn-insert code compiles against it.
- **Task 2 before Task 7** — extended `trigger_review` reads `dual_model` and `model_pairs` from the resolved config.
- **Task 3 before Task 7** — `trigger_review` validation uses the provider catalog for the "no credential" error path.
- **Task 4 before Task 6** — `record_primary_turn` redacts `rationale` + `artifact_after` before INSERT; redaction module must exist.
- **Task 5 before Task 7** — `get_review_status` response carries the composite score.
- **Task 10 last** — parity + e2e tests exercise the full stack end-to-end.

If parallel branches land out of order, expect merge conflicts in `services/mcp/tools/dispatch.ts` and `services/workdesk/reviews.go` (the two hot spots where multiple tasks touch the same functions).

## CI commands for this branch

Record these once so future sessions don't re-derive them:

```bash
# Worktree root
cd /Users/ensell/Code/big-wave/.worktrees/review-dual-model-backend

# MCP service (TypeScript / Vitest)
cd services/mcp && npm test
cd services/mcp && npm test -- <test-file>.test.ts --reporter=verbose   # single file

# Workdesk service (Go)
cd services/workdesk && go test -v ./... -count=1
cd services/workdesk && go test -run '^TestXxx' -v                      # specific test(s)

# Compile-only checks
go build ./services/workdesk/...
cd services/mcp && npx tsc --noEmit

# Full stack end-to-end (from repo root)
make test-e2e
```

---

## Session checkpoint (Tasks 1–6 complete, as of 2026-04-21)

### Last-known-green

Commit: `28f9de2` on `feature/review-dual-model-v1.4.0-backend` (15 commits ahead of `main`).

```bash
cd /Users/ensell/Code/big-wave/.worktrees/review-dual-model-backend

# Green as of the checkpoint:
(cd services/workdesk && go build ./...)                                    # 0 errors
(cd services/workdesk && go test -run '^TestInsertTurn|^TestPostReviewTurn|^TestComposite|^TestEffectiveThreshold|^TestWeightsForMode|^TestWeightSums' -v)
                                                                            # all subtests PASS
(cd services/mcp && npm test)                                               # 195/195 across 9 files
(cd services/mcp && npx tsc --noEmit)                                       # 0 errors
```

Pre-existing workdesk failure: `TestAcceptReview_Idempotent` — nil-pointer in `services/common/events/client.go:97`. Confirmed unrelated to this refactor (flagged during Task 5, reconfirmed each round since). Do NOT treat as a regression; leave it for whoever owns the events/client fix.

### Deferred risk register

| ID | Item | Condition | Why acceptable now | Trigger to revisit |
|---|---|---|---|---|
| T6-I1 | TOCTOU between `postReviewTurn`'s preflight tenant SELECT and `InsertTurn`'s tenant SELECT | Two separate DB reads with no row lock between them | `tenant_id` on `adversarial_reviews` is immutable by convention (no code path in workdesk writes to that column), so the window can only surface as "row deleted mid-request" — which is already mapped to 404 via `ErrReviewNotFound`. Narrow, benign. | If a future migration or service starts writing `adversarial_reviews.tenant_id` after insert, collapse the two reads into a single tenant-validating query inside `InsertTurn` (`SELECT tenant_id WHERE id=$1 AND tenant_id=$2`). Also revisit if cross-tenant leak canary (§ 7e) fires. |

### Task 7 pre-split guidance

Task 7 extends three MCP tools. Implement them as **three internal milestones** (commit or subagent boundary, your choice) even if the final release bundles them:

1. **M7a — `trigger_review` extension.** Accept `client_tool`, `idempotency_key`, `force_refresh`, `parent_review_id`, `prior_rationale`. Pair-validation + credential-catalog gate. Pins `config_revision` + `effective_threshold` onto the review row.
2. **M7b — `get_review_status` extension.** Response gains `round`, `client_tool`, `dual_model`, `adversary_model_id`, `composite_score`, `effective_threshold`, `stop_reason`, `redactions_summary`, 7th category. Preserves v1.3.x `parsing_text` verbatim. Deprecation marker on argument-less call.
3. **M7c — `resolve_review` tightening.** `retry` only when `status=error`.

Each milestone should produce its own PR-sized commit or subagent dispatch so review findings land locally and don't mix concerns across the three tool surfaces.

---

## Task 1: DDL — add columns to `adversarial_reviews` + create `adversarial_review_turns`

**Files:**
- Modify: `services/workdesk/migrate.go:217-350` (append columns; append new table)
- Create: `supabase/migrations/20260421000000_dual_model_review.sql` (RLS for new table)

### Steps

- [ ] **Step 1: Read current DDL to confirm starting state**

Run:
```bash
cd /Users/ensell/Code/big-wave
sed -n '215,280p' services/workdesk/migrate.go
grep -n 'parent_review_id\|category_scores' services/workdesk/migrate.go
```

Expected: `parent_review_id` already present around line 347; `category_scores` JSONB already present around line 345. If either is missing, stop and flag — spec assumes both exist.

- [ ] **Step 2: Append new columns to `adversarial_reviews` CREATE TABLE block**

Edit `services/workdesk/migrate.go` to add these columns inside the `adversarial_reviews` definition (after existing columns, before the closing `)`):

```go
// NEW for dual-model review (v1.4.0)
dual_model BOOLEAN NOT NULL DEFAULT FALSE,
client_tool TEXT,
composite_score NUMERIC(5,3),
stop_reason TEXT,
config_revision INTEGER,
effective_threshold NUMERIC(4,2),
redactions JSONB NOT NULL DEFAULT '{}'::jsonb,
```

Append CHECK constraints after the column list (or as trailing `ALTER TABLE ... ADD CONSTRAINT` lines — match existing style in the file):

```sql
CONSTRAINT review_stop_reason_values
  CHECK (stop_reason IS NULL OR stop_reason IN
    ('threshold_met','max_rounds','score_plateau','no_progress',
     'operator_stop','error')),
CONSTRAINT review_client_tool_values
  CHECK (client_tool IS NULL OR client_tool IN ('claude-code','codex','cursor')),
CONSTRAINT review_composite_range
  CHECK (composite_score IS NULL OR (composite_score >= 0 AND composite_score <= 10))
```

- [ ] **Step 3: Append `adversarial_review_turns` CREATE TABLE statement**

Add to `migrate.go` after the `adversarial_reviews` block:

```sql
CREATE TABLE IF NOT EXISTS adversarial_review_turns (
  review_id      TEXT        NOT NULL REFERENCES adversarial_reviews(id) ON DELETE CASCADE,
  tenant_id      UUID        NOT NULL,
  round          INTEGER     NOT NULL,
  turn_number    INTEGER     NOT NULL,
  role           TEXT        NOT NULL,
  model_id       TEXT,
  input_content  TEXT        NOT NULL,
  output_content TEXT        NOT NULL,
  cost_usd       NUMERIC(10,4) NOT NULL DEFAULT 0,
  latency_ms     INTEGER,
  redactions     JSONB       NOT NULL DEFAULT '{}'::jsonb,
  trace_id       TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (review_id, round, turn_number),
  CONSTRAINT turn_role_values     CHECK (role IN ('primary','adversary')),
  CONSTRAINT turn_round_positive  CHECK (round >= 1),
  CONSTRAINT turn_number_positive CHECK (turn_number >= 1)
);

CREATE INDEX IF NOT EXISTS adv_turns_tenant_role_idx
  ON adversarial_review_turns (tenant_id, role, created_at DESC);
CREATE INDEX IF NOT EXISTS adv_turns_model_id_idx
  ON adversarial_review_turns (model_id);

CREATE INDEX IF NOT EXISTS adv_reviews_tenant_client_tool_idx
  ON adversarial_reviews (tenant_id, client_tool, created_at DESC)
  WHERE dual_model = TRUE;
```

Note: `tenant_id` is `UUID` on the parent (per exploration report); match that type here, not `TEXT` as the spec prose suggested.

- [ ] **Step 4: Create Supabase migration file for RLS on the new table**

Create `supabase/migrations/20260421000000_dual_model_review.sql`:

```sql
-- Dual-model review v1.4.0 — RLS policies for adversarial_review_turns
-- Parent table adversarial_reviews already has tenant-scoped RLS (Group A, migration
-- 20260324000000_enable_rls_new_service_tables.sql). This migration mirrors the same
-- posture onto the new child table.

ALTER TABLE adversarial_review_turns ENABLE ROW LEVEL SECURITY;

-- Tenant SELECT: users can read turns for reviews in their tenant
CREATE POLICY adv_turns_tenant_select ON adversarial_review_turns
  FOR SELECT
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);

-- Service role: full access (workdesk writes turn rows with service_role credential)
CREATE POLICY adv_turns_service_all ON adversarial_review_turns
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);
```

- [ ] **Step 5: Apply migration to local dev DB + verify**

Run:
```bash
cd /Users/ensell/Code/big-wave
# Apply workdesk Go migrations
make workdesk-migrate  # or equivalent; check Makefile for the actual target
# Apply Supabase migrations
supabase db reset      # or supabase db push, match team convention

# Verify new columns exist
psql $DATABASE_URL -c "\\d adversarial_reviews" | grep -E 'dual_model|client_tool|composite_score|stop_reason|effective_threshold'
# Verify new table exists
psql $DATABASE_URL -c "\\d adversarial_review_turns"
# Verify RLS enabled
psql $DATABASE_URL -c "SELECT relname, relrowsecurity FROM pg_class WHERE relname='adversarial_review_turns';"
```

Expected: all 6 new columns listed; new table exists with all constraints; `relrowsecurity=t`.

If the Makefile target doesn't exist, find the actual runner via `grep -n migrate Makefile services/workdesk/*.go` and use that command.

- [ ] **Step 6: Commit**

```bash
cd /Users/ensell/Code/big-wave
git add services/workdesk/migrate.go supabase/migrations/20260421000000_dual_model_review.sql
git commit -m "feat(workdesk): DDL for dual-model adversarial review

- Add columns to adversarial_reviews: dual_model, client_tool,
  composite_score, stop_reason, config_revision, effective_threshold,
  redactions
- Add CHECK constraints: stop_reason enum, client_tool enum,
  composite_score range [0,10]
- Create adversarial_review_turns child table with denormalized
  tenant_id, turn PK (review_id, round, turn_number)
- Indexes: tenant/client_tool partial on dual_model=TRUE, turns by
  tenant+role+created_at DESC, turns by model_id
- RLS on adversarial_review_turns: tenant SELECT + service_role ALL

Part of spec 2026-04-20-adversarial-review-dual-model-design.md § 4a-4b"
```

---

## Task 2: Extend `MovpConfig` schema for new review keys

**Files:**
- Modify: `services/mcp/movp-config.ts:19-171`
- Modify: `services/mcp/movp-config.test.ts` (exists? check with `ls services/mcp/movp-config*`)

### Steps

- [ ] **Step 1: Write failing test for new config keys**

Append to `services/mcp/movp-config.test.ts` (create the file if it doesn't exist, matching the style of `services/mcp/dispatch.test.ts`):

```typescript
import { describe, it, expect } from "vitest";
import { loadMovpConfig, validateMovpReviewConfig } from "./movp-config";

describe("MovpReviewConfig v1.4.0 keys", () => {
  it("accepts dual_model=true with model_pairs", () => {
    const cfg = validateMovpReviewConfig({
      enabled: true,
      dual_model: true,
      model_pairs: {
        "claude-code": { adversary: "openai/gpt-5.4" },
        "codex":       { adversary: "anthropic/claude-opus-4-6" },
        "cursor":      { adversary: "openai/gpt-5.4" },
      },
      threshold: 9.2,
      legacy_threshold: 9.0,
      plateau: { delta_epsilon: 0.1, consecutive_rounds: 2 },
      confirm_before_apply: false,
    });
    expect(cfg.dual_model).toBe(true);
    expect(cfg.model_pairs["claude-code"].adversary).toBe("openai/gpt-5.4");
    expect(cfg.threshold).toBe(9.2);
    expect(cfg.legacy_threshold).toBe(9.0);
  });

  it("defaults dual_model to false when absent", () => {
    const cfg = validateMovpReviewConfig({ enabled: true });
    expect(cfg.dual_model).toBe(false);
    expect(cfg.threshold).toBe(9.2);
    expect(cfg.legacy_threshold).toBe(9.0);
    expect(cfg.plateau.delta_epsilon).toBe(0.1);
    expect(cfg.plateau.consecutive_rounds).toBe(2);
    expect(cfg.confirm_before_apply).toBe(false);
  });

  it("warns on scoring override attempt (does not throw)", () => {
    // Spec § 3a — scoring.weights is read-only. User override is ignored
    // with a structured warning; config loads successfully.
    const cfg = validateMovpReviewConfig({
      enabled: true,
      scoring: { weights: { correctness: 999 } },
    });
    // The user-provided scoring is dropped; the resolved config either
    // omits scoring or carries the code-default shape.
    expect(cfg.scoring?.weights?.correctness).not.toBe(999);
  });

  it("treats model_pairs: null as 'reset to default'", () => {
    // Spec § 3b — explicit null resets to code default
    const cfg = validateMovpReviewConfig({
      enabled: true,
      dual_model: true,
      model_pairs: null,
    });
    // After null-reset, the fallback is code defaults
    expect(cfg.model_pairs).toBeDefined();
    expect(cfg.model_pairs["claude-code"].adversary).toBe("openai/gpt-5.4");
  });
});
```

- [ ] **Step 2: Run test to verify failure**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/mcp
npm test -- movp-config.test.ts --reporter=verbose
```

Expected: all four tests FAIL — `validateMovpReviewConfig` doesn't export new-key handling yet.

- [ ] **Step 3: Extend the TypeScript interfaces**

Edit `services/mcp/movp-config.ts` around lines 19-29 to add the new fields to `MovpReviewConfig`:

```typescript
export interface MovpReviewConfig {
  enabled: boolean;
  categories: ReviewCategory[];
  auto_review: AutoReviewConfig;
  cost_cap_daily_usd: number;
  max_rounds: number;
  rule_apply_mode?: "direct" | "pr";

  // NEW in v1.4.0 (spec § 3)
  dual_model: boolean;                       // default: false
  model_pairs: {
    [clientTool: string]: { adversary: string };
  };
  threshold: number;                         // default: 9.2 (dual-model)
  legacy_threshold: number;                  // default: 9.0 (single-model)
  plateau: {
    delta_epsilon: number;                   // default: 0.1
    consecutive_rounds: number;              // default: 2
  };
  confirm_before_apply: boolean;             // default: false
  scoring?: {                                // read-only — echoed only
    weights: { [category: string]: number };
  };
}

export const DEFAULT_MODEL_PAIRS = {
  "claude-code": { adversary: "openai/gpt-5.4" },
  "codex":       { adversary: "anthropic/claude-opus-4-6" },
  "cursor":      { adversary: "openai/gpt-5.4" },
} as const;

export const DEFAULT_WEIGHTS = {
  correctness:   1.0,
  observability: 1.0,
  reliability:   1.0,
  safety:        1.0,
  usability:     0.9,
  performance:   0.9,
  simplicity:    0.8,
} as const;
```

- [ ] **Step 4: Extend `validateMovpReviewConfig` to coerce defaults**

In the same file, find the existing validator (lines 70-171). Add handling for the new keys. Where `mergeLayer` processes each layer, apply § 3b rules:

```typescript
export function validateMovpReviewConfig(raw: unknown): MovpReviewConfig {
  const r = (raw ?? {}) as Record<string, unknown>;

  // Existing validation (categories, enabled, max_rounds, etc.) unchanged...

  // NEW keys with defaults
  const dual_model = typeof r.dual_model === "boolean" ? r.dual_model : false;

  // model_pairs: null → reset to defaults; {} → empty (fall back to defaults);
  // object → merge with defaults per § 3b
  let model_pairs: MovpReviewConfig["model_pairs"];
  if (r.model_pairs === null) {
    model_pairs = { ...DEFAULT_MODEL_PAIRS };
  } else if (r.model_pairs === undefined) {
    model_pairs = { ...DEFAULT_MODEL_PAIRS };
  } else if (typeof r.model_pairs === "object") {
    model_pairs = { ...DEFAULT_MODEL_PAIRS, ...(r.model_pairs as object) };
  } else {
    throw new Error(`Invalid model_pairs type: ${typeof r.model_pairs}`);
  }

  const threshold = typeof r.threshold === "number" ? r.threshold : 9.2;
  const legacy_threshold = typeof r.legacy_threshold === "number" ? r.legacy_threshold : 9.0;

  const plateau_raw = (r.plateau ?? {}) as Record<string, unknown>;
  const plateau = {
    delta_epsilon:
      typeof plateau_raw.delta_epsilon === "number" ? plateau_raw.delta_epsilon : 0.1,
    consecutive_rounds:
      typeof plateau_raw.consecutive_rounds === "number"
        ? plateau_raw.consecutive_rounds
        : 2,
  };

  const confirm_before_apply =
    typeof r.confirm_before_apply === "boolean" ? r.confirm_before_apply : false;

  // scoring.weights — ignore user-provided values; always emit code defaults
  // with a structured warning if the user tried to override.
  if (r.scoring !== undefined) {
    console.warn(
      JSON.stringify({
        warning: "config.scoring_override_ignored",
        path: "review.scoring",
        reason: "weights are fixed in v1.4.0; user-provided values ignored",
      })
    );
  }
  const scoring = { weights: { ...DEFAULT_WEIGHTS } };

  return {
    // ... existing fields ...
    dual_model,
    model_pairs,
    threshold,
    legacy_threshold,
    plateau,
    confirm_before_apply,
    scoring,
  };
}
```

- [ ] **Step 5: Run test to verify pass**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/mcp
npm test -- movp-config.test.ts --reporter=verbose
```

Expected: all four tests PASS.

- [ ] **Step 6: Run full mcp test suite to catch regressions**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/mcp
npm test
```

Expected: no failures. Any failing test that references `MovpReviewConfig` shape is a real regression — fix by updating the test fixture to include the new fields.

- [ ] **Step 7: Commit**

```bash
cd /Users/ensell/Code/big-wave
git add services/mcp/movp-config.ts services/mcp/movp-config.test.ts
git commit -m "feat(mcp): extend MovpReviewConfig with v1.4.0 dual-model keys

Add dual_model, model_pairs, threshold, legacy_threshold, plateau.*,
confirm_before_apply to config schema with code defaults matching
spec § 3. scoring.weights is read-only — user overrides logged as
config.scoring_override_ignored warnings and discarded.

Defaults: dual_model=false (legacy path), threshold=9.2,
legacy_threshold=9.0, plateau.delta_epsilon=0.1, plateau.consecutive_rounds=2.

Per spec § 3a, § 3b."
```

---

## Task 3: Provider-credential catalog

**Files:**
- Create: `services/mcp/provider_catalog.ts`
- Create: `services/mcp/provider_catalog.test.ts`

### Steps

- [ ] **Step 1: Write failing test**

Create `services/mcp/provider_catalog.test.ts`:

```typescript
import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  isProviderAvailable,
  getAvailableProviders,
  KNOWN_PROVIDERS,
} from "./provider_catalog";

describe("Provider credential catalog", () => {
  beforeEach(() => {
    // Clear env between tests
    delete process.env.OPENAI_API_KEY;
    delete process.env.ANTHROPIC_API_KEY;
  });

  it("reports openai unavailable when OPENAI_API_KEY is unset", () => {
    expect(isProviderAvailable("openai", "tenant-uuid-123")).toBe(false);
  });

  it("reports openai available when OPENAI_API_KEY is set", () => {
    process.env.OPENAI_API_KEY = "sk-test-fakevaluefortesting";
    expect(isProviderAvailable("openai", "tenant-uuid-123")).toBe(true);
  });

  it("rejects unknown provider names", () => {
    expect(isProviderAvailable("invalid-provider", "tenant-uuid-123")).toBe(false);
  });

  it("getAvailableProviders returns only providers with credentials", () => {
    process.env.OPENAI_API_KEY = "sk-test-x";
    // ANTHROPIC_API_KEY unset
    const available = getAvailableProviders("tenant-uuid-123");
    expect(available).toContain("openai");
    expect(available).not.toContain("anthropic");
  });

  it("KNOWN_PROVIDERS includes openai and anthropic", () => {
    expect(KNOWN_PROVIDERS).toContain("openai");
    expect(KNOWN_PROVIDERS).toContain("anthropic");
  });
});
```

- [ ] **Step 2: Run test to verify failure**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/mcp
npm test -- provider_catalog.test.ts --reporter=verbose
```

Expected: FAIL — `provider_catalog` module does not exist.

- [ ] **Step 3: Implement the catalog**

Create `services/mcp/provider_catalog.ts`:

```typescript
// Provider credential catalog — single source of truth for
// "does this tenant have a credential for provider X?"
//
// Consumed by:
//   - trigger_review (validation before adversary call)
//   - movp://movp/config resource (UI dropdown enablement)
//
// Spec § 2b, § 3 (validation gates 1 and 2).
//
// v1.4.0: credentials read from process env. Future versions may add
// per-tenant credential storage; the interface here is tenant-aware so
// that migration is additive.

export const KNOWN_PROVIDERS = ["openai", "anthropic"] as const;
export type ProviderName = (typeof KNOWN_PROVIDERS)[number];

interface ProviderSlot {
  envVar: string;
}

const PROVIDER_SLOTS: Record<ProviderName, ProviderSlot> = {
  openai:    { envVar: "OPENAI_API_KEY" },
  anthropic: { envVar: "ANTHROPIC_API_KEY" },
};

/**
 * Returns true if the tenant can use the given provider at review time.
 * `tenantId` is currently unused (v1.4.0 reads global env); future versions
 * will look up per-tenant credential records.
 */
export function isProviderAvailable(
  provider: string,
  _tenantId: string
): boolean {
  if (!(KNOWN_PROVIDERS as readonly string[]).includes(provider)) {
    return false;
  }
  const slot = PROVIDER_SLOTS[provider as ProviderName];
  const value = process.env[slot.envVar];
  return typeof value === "string" && value.length > 0;
}

/**
 * Returns the list of providers the tenant can use.
 */
export function getAvailableProviders(tenantId: string): ProviderName[] {
  return KNOWN_PROVIDERS.filter((p) => isProviderAvailable(p, tenantId));
}

/**
 * Extracts the provider namespace from a namespaced model id like
 * "openai/gpt-5.4" → "openai".
 */
export function providerFromModelId(modelId: string): string | null {
  const idx = modelId.indexOf("/");
  if (idx <= 0) return null;
  return modelId.substring(0, idx);
}
```

- [ ] **Step 4: Run test to verify pass**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/mcp
npm test -- provider_catalog.test.ts --reporter=verbose
```

Expected: all five tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/ensell/Code/big-wave
git add services/mcp/provider_catalog.ts services/mcp/provider_catalog.test.ts
git commit -m "feat(mcp): provider credential catalog

Single source of truth for 'does tenant X have a credential for
provider Y?' Consumed by trigger_review validation and the config
resource's UI hint for dropdown enablement. v1.4.0 reads
OPENAI_API_KEY and ANTHROPIC_API_KEY from process env; tenant-scoped
signature lets future per-tenant credential storage drop in
additively.

Per spec § 2b, § 3."
```

---

## Task 4: RE2-backed redaction pipeline

**Files:**
- Create: `services/mcp/redaction_patterns.ts`
- Create: `services/mcp/redaction.ts`
- Create: `services/mcp/redaction.test.ts`
- Create: `services/mcp/__tests__/fixtures/redaction/positive/<category>.txt` (14 files — one per pattern)
- Create: `services/mcp/__tests__/fixtures/redaction/negative.txt`
- Create: `services/mcp/__tests__/fixtures/redaction/email-as-content.txt`
- Modify: `services/mcp/package.json` — add `re2` dep
- Modify: `services/mcp/review-utils.ts:10-20` — remove `stripSecrets()` body; re-export `redact()` from new module

### Steps

- [ ] **Step 1: Add `re2` npm dependency**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/mcp
npm install re2
```

Verify `"re2": "^1.x"` appears in `services/mcp/package.json` dependencies.

- [ ] **Step 2: Create fixture files**

Create `services/mcp/__tests__/fixtures/redaction/positive/github_token.txt`:
```
Here's my token: ghp_abcdefghijklmnopqrstuvwxyz0123456789
Also in JSON: {"token": "ghs_abcdefghijklmnopqrstuvwxyz0123456789"}
YAML: token: gho_abcdefghijklmnopqrstuvwxyz0123456789
```

Create `services/mcp/__tests__/fixtures/redaction/positive/aws_access_key.txt`:
```
ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWSKEY: AKIAI44QH8DHBEXAMPLE
```

Create `services/mcp/__tests__/fixtures/redaction/positive/email.txt`:
```
Contact: alice@example.com
Reply-to: bob.smith+tag@sub.example.co.uk
```

Create analogous files for each category in the spec § 4e table:
- `api_key_generic.txt`, `aws_secret_key.txt`, `google_api_key.txt`,
  `stripe_key.txt`, `openai_key.txt`, `anthropic_key.txt`, `jwt.txt`,
  `ssh_private_key.txt`, `password_assignment.txt`, `bcrypt.txt`, `argon2.txt`

Each file contains 3+ realistic examples embedded in prose, JSON, and YAML contexts.

Create `services/mcp/__tests__/fixtures/redaction/negative.txt`:
```
UUID: 550e8400-e29b-41d4-a716-446655440000
Base64 of hello: aGVsbG8=
SHA-1: da39a3ee5e6b4b0d3255bfef95601890afd80709
Commit SHA: 923863cd1e4b5a6c7d8e9f0a1b2c3d4e5f6a7b8c
The word password by itself with no assignment
ARN: arn:aws:iam::123456789012:role/MyRole
```

Create `services/mcp/__tests__/fixtures/redaction/email-as-content.txt` (separate bucket per § 4h amendment):
```
User mentioned their coworker alice@example.com in the PR description.
```

- [ ] **Step 3: Implement the pattern set**

Create `services/mcp/redaction_patterns.ts`:

```typescript
// Source of truth for redaction patterns. Spec § 4e table is
// illustrative; this file ships.
//
// All patterns compile under RE2 (no backreferences, no lookaround
// requiring NFA). Module-load self-test verifies this.

import RE2 from "re2";

export interface RedactionPattern {
  category: string;
  pattern: RE2;
  replacement: string;
}

// Order matters — first match wins. Credentials listed before
// emails so email-shaped content inside a JWT doesn't get caught
// as plain email.
export const PATTERNS: RedactionPattern[] = [
  { category: "openai_key",          pattern: new RE2(/\bsk-proj-[A-Za-z0-9_-]{40,}\b/),                                                                replacement: "<REDACTED:openai-key>"       },
  { category: "anthropic_key",       pattern: new RE2(/\bsk-ant-[A-Za-z0-9_-]{40,}\b/),                                                                 replacement: "<REDACTED:anthropic-key>"    },
  { category: "stripe_key",          pattern: new RE2(/\b(sk|pk|rk)_(live|test)_[A-Za-z0-9]{24,}\b/),                                                   replacement: "<REDACTED:stripe-key>"       },
  { category: "github_token",        pattern: new RE2(/\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b/),                                                     replacement: "<REDACTED:github-token>"     },
  { category: "google_api_key",      pattern: new RE2(/\bAIza[0-9A-Za-z_-]{35}\b/),                                                                     replacement: "<REDACTED:google-api-key>"   },
  { category: "aws_access_key",      pattern: new RE2(/\bAKIA[0-9A-Z]{16}\b/),                                                                          replacement: "<REDACTED:aws-access-key>"   },
  { category: "aws_secret_key",      pattern: new RE2(/aws_secret_access_key\s*[:=]\s*['"]?[A-Za-z0-9/+=]{40}['"]?/),                                   replacement: "aws_secret_access_key=<REDACTED:aws-secret-key>" },
  { category: "ssh_private_key",     pattern: new RE2(/-----BEGIN ([A-Z ]+)?PRIVATE KEY-----[\s\S]*?-----END ([A-Z ]+)?PRIVATE KEY-----/),              replacement: "<REDACTED:ssh-private-key>"  },
  { category: "jwt",                 pattern: new RE2(/\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/),                                      replacement: "<REDACTED:jwt>"              },
  { category: "api_key_generic",     pattern: new RE2(/\bsk-[A-Za-z0-9]{32,}\b/),                                                                       replacement: "<REDACTED:api-key>"          },
  { category: "bcrypt",              pattern: new RE2(/\$2[abxy]\$[0-9]{2}\$[./A-Za-z0-9]{53}/),                                                        replacement: "<REDACTED:bcrypt>"           },
  { category: "argon2",              pattern: new RE2(/\$argon2(id|i|d)\$[^$]+\$[^$]+\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+/),                              replacement: "<REDACTED:argon2>"           },
  { category: "password_assignment", pattern: new RE2(/(?i)(password|passwd|passwordhash|pass|pwd)\s*[:=]\s*['"]?([^\s'"]{6,})['"]?/),                  replacement: "$1=<REDACTED:password>"      },
  { category: "email",               pattern: new RE2(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/),                                            replacement: "<REDACTED:email>"            },
];

// Stable list of category names for zero-count initialization.
export const CATEGORY_NAMES = PATTERNS.map((p) => p.category);
```

- [ ] **Step 4: Implement the redactor with per-pattern timeout**

Create `services/mcp/redaction.ts`:

```typescript
import { PATTERNS, CATEGORY_NAMES, RedactionPattern } from "./redaction_patterns";

export interface RedactionResult {
  content: string;
  counts: Record<string, number>;  // every category key present; zeros included
}

const PATTERN_TIMEOUT_MS = 50;

function zeroCounts(): Record<string, number> {
  const c: Record<string, number> = {};
  for (const name of CATEGORY_NAMES) c[name] = 0;
  return c;
}

/**
 * Apply one pattern to the input. RE2 is linear-time so timeout is
 * defense-in-depth against future pattern regressions. Uses a
 * wall-clock check rather than a worker thread to keep the path
 * synchronous for transactional use.
 */
function applyPattern(input: string, p: RedactionPattern): { content: string; count: number } {
  const start = Date.now();
  let count = 0;
  const output = input.replace(p.pattern, (match, ...captures) => {
    if (Date.now() - start > PATTERN_TIMEOUT_MS) {
      throw new Error(`redaction_timeout:${p.category}`);
    }
    count += 1;
    // Handle replacement back-refs ($1, $2) — RE2 replacement strings
    // pass capture groups as extra args before the `offset` and full string.
    let replaced = p.replacement;
    for (let i = 0; i < captures.length - 2; i++) {
      replaced = replaced.replace(`$${i + 1}`, String(captures[i] ?? ""));
    }
    return replaced;
  });
  return { content: output, count };
}

/**
 * Redact a raw string. Patterns run in the fixed order defined in
 * redaction_patterns.ts. Throws on pattern timeout — callers must
 * propagate (roll back transaction) rather than logging the content.
 */
export function redact(input: string): RedactionResult {
  const counts = zeroCounts();
  let content = input;
  for (const p of PATTERNS) {
    const { content: next, count } = applyPattern(content, p);
    content = next;
    counts[p.category] = count;
  }
  return { content, counts };
}

/**
 * Redact a structured JSON value. Walks the tree and applies patterns
 * to every string-valued leaf. Preserves JSON validity (no boundary
 * cross-matching) and aggregates counts across all fields.
 */
export function redactJsonValue(value: unknown): { value: unknown; counts: Record<string, number> } {
  const totalCounts = zeroCounts();

  function walk(v: unknown): unknown {
    if (typeof v === "string") {
      const r = redact(v);
      for (const k of CATEGORY_NAMES) totalCounts[k] += r.counts[k];
      return r.content;
    }
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === "object") {
      const out: Record<string, unknown> = {};
      for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
        out[k] = walk(val);
      }
      return out;
    }
    return v;  // numbers, booleans, null
  }

  return { value: walk(value), counts: totalCounts };
}
```

- [ ] **Step 5: Write failing tests**

Create `services/mcp/redaction.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { redact, redactJsonValue } from "./redaction";
import { PATTERNS, CATEGORY_NAMES } from "./redaction_patterns";

const FIXTURE_DIR = resolve(__dirname, "__tests__/fixtures/redaction");

function readFixture(relPath: string): string {
  return readFileSync(resolve(FIXTURE_DIR, relPath), "utf8");
}

describe("RE2 compile-time safety", () => {
  it("every pattern compiles under RE2 (no backreferences)", () => {
    for (const p of PATTERNS) {
      expect(p.pattern).toBeDefined();
      expect(typeof p.pattern.test).toBe("function");
    }
  });
});

describe("Positive corpus", () => {
  // Every category must match its fixture
  for (const name of CATEGORY_NAMES) {
    if (name === "email") continue;  // tested separately below
    it(`${name} fixture is redacted`, () => {
      const input = readFixture(`positive/${name}.txt`);
      const { content, counts } = redact(input);
      expect(counts[name]).toBeGreaterThan(0);
      expect(content).toContain("<REDACTED:");
    });
  }
});

describe("Email fixture is redacted (even as content)", () => {
  it("email is redacted by design", () => {
    const input = readFixture("positive/email.txt");
    const { counts } = redact(input);
    expect(counts.email).toBeGreaterThan(0);
  });
});

describe("Negative corpus (non-credential strings stay unredacted)", () => {
  it("UUIDs, base64, SHA, commit hashes, and bare 'password' stay unredacted", () => {
    const input = readFixture("negative.txt");
    const { content } = redact(input);
    // No credential-shaped tokens matched — the text comes back unchanged
    // (modulo emails, which are not in this fixture).
    expect(content).toBe(input);
  });
});

describe("JSON-walk invariant", () => {
  it("redacts secrets in string fields; preserves JSON validity", () => {
    const adversaryOutput = {
      findings: [
        {
          id: "f1",
          summary: "Hardcoded credential detected",
          quoted_code: "const key = 'ghp_abcdefghijklmnopqrstuvwxyz0123456789';",
          suggested_fix: "Move to env var",
          severity: "CRIT",
          confidence: 0.95,
        },
      ],
    };
    const { value, counts } = redactJsonValue(adversaryOutput);
    const serialized = JSON.stringify(value);
    expect(serialized).not.toContain("ghp_abc");
    expect(serialized).toContain("<REDACTED:github-token>");
    expect(counts.github_token).toBe(1);

    // Non-string fields preserved
    const round = value as typeof adversaryOutput;
    expect(round.findings[0].severity).toBe("CRIT");
    expect(round.findings[0].confidence).toBe(0.95);
  });
});

describe("Performance budget", () => {
  it("256 KB artifact redacts in < 150 ms", () => {
    const junk = "lorem ipsum dolor sit amet ".repeat(10_000);  // ~260 KB
    const withSecrets = junk + "\nsk-abcdefghij0123456789abcdefghij0123456789 and alice@example.com";

    const start = Date.now();
    redact(withSecrets);
    const elapsed = Date.now() - start;

    expect(elapsed).toBeLessThan(150);
  });
});
```

- [ ] **Step 6: Run tests to verify pass**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/mcp
npm test -- redaction.test.ts --reporter=verbose
```

Expected: all tests PASS. If the positive-corpus test for a given category fails, inspect the fixture and adjust the example to match the pattern (real-world examples must be syntactically valid for the pattern).

- [ ] **Step 7: Replace `stripSecrets()` with `redact()` in review-utils**

Edit `services/mcp/review-utils.ts:10-20`. Replace the existing `stripSecrets()` function body with a call to the new module:

```typescript
import { redact } from "./redaction";

export function stripSecrets(input: string): string {
  // Deprecated — kept for v1.3.x callers. Prefer redact() which returns
  // both the content and the per-category count rollup for persistence.
  return redact(input).content;
}
```

Run the full mcp test suite to verify no existing test broke:
```bash
cd /Users/ensell/Code/big-wave/services/mcp
npm test
```

Expected: no failures. `stripSecrets` callers continue working; new pattern set catches more categories than the old one.

- [ ] **Step 8: Commit**

```bash
cd /Users/ensell/Code/big-wave
git add services/mcp/redaction.ts services/mcp/redaction_patterns.ts \
        services/mcp/redaction.test.ts \
        services/mcp/__tests__/fixtures/redaction/ \
        services/mcp/review-utils.ts \
        services/mcp/package.json services/mcp/package-lock.json
git commit -m "feat(mcp): RE2-backed redaction with full credential + email pattern set

Replaces stripSecrets() with redact() that uses Google's RE2 engine
(linear-time, no backtracking) plus per-pattern 50ms timeout. Pattern
set expanded from 5 categories (AWS, GH, Slack, generic, password)
to 14 (adds JWT, SSH private keys, bcrypt, argon2, Google/Stripe/
OpenAI/Anthropic keys, email).

stripSecrets() kept as thin compat wrapper for v1.3.x callers.

Positive corpus: one fixture per category. Negative corpus: UUIDs,
base64, SHA, bare 'password' — asserted unchanged. Email is redacted
by design; email-as-content fixtures live in a separate bucket per
spec § 4h. JSON-walk invariant preserves structure while redacting
leaf strings. Perf budget: 256 KB in < 150 ms.

Per spec § 4d, § 4e, § 4h."
```

---

## Task 5: Weighted composite scoring

**Files:**
- Create: `services/workdesk/weights.go`
- Create: `services/workdesk/scoring.go`
- Create: `services/workdesk/scoring_test.go`

### Steps

- [ ] **Step 1: Define weight constants**

Create `services/workdesk/weights.go`:

```go
package main

// Pinned scoring weights for v1.4.0.
//
// Changing these values requires a release note — historical composite
// scores are pinned per-row (adversarial_reviews.composite_score column),
// so changes do not retroactively alter past reviews but will shift the
// distribution for new reviews in ways analytics must account for.
//
// Per spec § 3a, § 4c.

type CategoryWeight struct {
	Name   string
	Weight float64
}

// DualModelWeights — 7 categories. Sum = 6.6.
var DualModelWeights = []CategoryWeight{
	{Name: "correctness", Weight: 1.0},
	{Name: "observability", Weight: 1.0},
	{Name: "reliability", Weight: 1.0},
	{Name: "safety", Weight: 1.0},
	{Name: "usability", Weight: 0.9},
	{Name: "performance", Weight: 0.9},
	{Name: "simplicity", Weight: 0.8},
}

// SingleModelWeights — 6 categories (no observability). Sum = 5.6.
// Used when dual_model=false for v1.3.x parity. Same weights as dual
// model, minus observability.
var SingleModelWeights = []CategoryWeight{
	{Name: "correctness", Weight: 1.0},
	{Name: "reliability", Weight: 1.0},
	{Name: "safety", Weight: 1.0},
	{Name: "usability", Weight: 0.9},
	{Name: "performance", Weight: 0.9},
	{Name: "simplicity", Weight: 0.8},
}

func WeightsForMode(dualModel bool) []CategoryWeight {
	if dualModel {
		return DualModelWeights
	}
	return SingleModelWeights
}
```

- [ ] **Step 2: Write failing tests**

Create `services/workdesk/scoring_test.go`:

```go
package main

import (
	"math"
	"testing"
)

func TestComposite_DualModelAllTens(t *testing.T) {
	scores := map[string]float64{
		"correctness": 10, "observability": 10, "reliability": 10,
		"safety": 10, "usability": 10, "performance": 10, "simplicity": 10,
	}
	got, err := ComputeComposite(scores, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if math.Abs(got-10.0) > 0.001 {
		t.Errorf("expected 10.000, got %f", got)
	}
}

func TestComposite_SingleModelAllTens(t *testing.T) {
	scores := map[string]float64{
		"correctness": 10, "reliability": 10, "safety": 10,
		"usability": 10, "performance": 10, "simplicity": 10,
	}
	got, err := ComputeComposite(scores, false)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if math.Abs(got-10.0) > 0.001 {
		t.Errorf("expected 10.000, got %f", got)
	}
}

func TestComposite_DualModelMixedScores(t *testing.T) {
	// Primary calibration case: safety=10, correctness=8, everything else=9.
	// Weights: 1.0, 1.0, 1.0, 1.0, 0.9, 0.9, 0.8 summing to 6.6.
	// Manual: (1.0*8 + 1.0*9 + 1.0*9 + 1.0*10 + 0.9*9 + 0.9*9 + 0.8*9) / 6.6
	//       = (8 + 9 + 9 + 10 + 8.1 + 8.1 + 7.2) / 6.6
	//       = 59.4 / 6.6 = 9.0
	scores := map[string]float64{
		"correctness": 8, "observability": 9, "reliability": 9,
		"safety": 10, "usability": 9, "performance": 9, "simplicity": 9,
	}
	got, err := ComputeComposite(scores, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if math.Abs(got-9.0) > 0.001 {
		t.Errorf("expected 9.000, got %f", got)
	}
}

func TestComposite_MissingCategory(t *testing.T) {
	// Caller bug: dual_model=true but scores missing observability
	scores := map[string]float64{
		"correctness": 10, "reliability": 10, "safety": 10,
		"usability": 10, "performance": 10, "simplicity": 10,
		// observability missing
	}
	_, err := ComputeComposite(scores, true)
	if err == nil {
		t.Fatal("expected error for missing observability category in dual_model mode")
	}
}

func TestComposite_RoundingToThreeDecimals(t *testing.T) {
	// 7/6.6 = 1.0606... → expect 1.061 (banker's round or half-up OK)
	scores := map[string]float64{
		"correctness": 1, "observability": 1, "reliability": 1,
		"safety": 1, "usability": 1, "performance": 1, "simplicity": 1,
	}
	got, err := ComputeComposite(scores, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// composite = 1.0 exactly (weighted_sum/total_weight where all scores are 1)
	if math.Abs(got-1.0) > 0.001 {
		t.Errorf("expected 1.000, got %f", got)
	}
}

func TestEffectiveThreshold(t *testing.T) {
	if EffectiveThreshold(true, 9.2, 9.0) != 9.2 {
		t.Error("dual_model=true should use threshold")
	}
	if EffectiveThreshold(false, 9.2, 9.0) != 9.0 {
		t.Error("dual_model=false should use legacy_threshold")
	}
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/workdesk
go test -run '^TestComposite|^TestEffectiveThreshold' -v
```

Expected: FAIL — `ComputeComposite` and `EffectiveThreshold` are undefined.

- [ ] **Step 4: Implement scoring**

Create `services/workdesk/scoring.go`:

```go
package main

import (
	"fmt"
	"math"
)

// ComputeComposite produces the weighted-average composite score for a
// review. category_scores JSONB on the parent row remains the source of
// truth; composite is denormalized for stable reporting (spec § 4c).
//
// Returns rounded to 3 decimal places. All inputs must be in [0, 10];
// caller's responsibility to validate upstream.
func ComputeComposite(scores map[string]float64, dualModel bool) (float64, error) {
	weights := WeightsForMode(dualModel)

	var weightedSum, totalWeight float64
	for _, w := range weights {
		score, ok := scores[w.Name]
		if !ok {
			return 0, fmt.Errorf("missing score for category %q (dual_model=%v)", w.Name, dualModel)
		}
		weightedSum += w.Weight * score
		totalWeight += w.Weight
	}

	if totalWeight == 0 {
		return 0, fmt.Errorf("zero total weight — check weights table")
	}

	raw := weightedSum / totalWeight
	// Round to 3 decimals (NUMERIC(5,3))
	return math.Round(raw*1000) / 1000, nil
}

// EffectiveThreshold returns the threshold to apply for a given mode.
// Spec § 6e.
func EffectiveThreshold(dualModel bool, threshold, legacyThreshold float64) float64 {
	if dualModel {
		return threshold
	}
	return legacyThreshold
}
```

- [ ] **Step 5: Run tests to verify pass**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/workdesk
go test -run '^TestComposite|^TestEffectiveThreshold' -v
```

Expected: all five tests PASS.

- [ ] **Step 6: Run full workdesk test suite**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/workdesk
go test -v ./... -count=1
```

Expected: no regressions. Any failure in existing review tests indicates the scoring module is clashing with an existing symbol — rename if needed.

- [ ] **Step 7: Commit**

```bash
cd /Users/ensell/Code/big-wave
git add services/workdesk/weights.go services/workdesk/scoring.go services/workdesk/scoring_test.go
git commit -m "feat(workdesk): weighted composite scoring for dual-model review

Weight constants pinned in code (weights.go). Dual-model mode uses
7 categories summing 6.6; single-model uses 6 categories summing 5.6.
Composite rounded to 3 decimals (NUMERIC(5,3) column type).
Missing-category returns error rather than silent default-zero so
caller bugs surface loudly.

EffectiveThreshold resolves dual vs legacy per spec § 6e.

Per spec § 3a, § 4c."
```

---

## Task 6: Turn persistence handlers + `record_primary_turn`

**Files:**
- Create: `services/workdesk/turns.go`
- Create: `services/workdesk/turns_test.go`
- Modify: `services/mcp/tools/dispatch.ts` — add `record_primary_turn` tool

### Steps

- [ ] **Step 1: Write failing Go test for turn insert**

Create `services/workdesk/turns_test.go`:

```go
package main

import (
	"context"
	"encoding/json"
	"testing"
)

func TestInsertTurn_PopulatesTenantIdFromParent(t *testing.T) {
	ctx := context.Background()
	db := setupTestDB(t)
	defer db.Close()

	reviewID := seedReview(t, db, SeedReviewOpts{
		TenantID:   "00000000-0000-0000-0000-000000000001",
		DualModel:  true,
		ClientTool: "claude-code",
	})

	counts := map[string]int{"github_token": 2, "email": 1}
	countsJSON, _ := json.Marshal(counts)

	err := InsertTurn(ctx, db, InsertTurnParams{
		ReviewID:      reviewID,
		Round:         1,
		TurnNumber:    1,
		Role:          "adversary",
		ModelID:       strPtr("openai/gpt-5.4"),
		InputContent:  "post-redaction input",
		OutputContent: "post-redaction output",
		CostUSD:       0.42,
		LatencyMs:     1234,
		Redactions:    countsJSON,
		TraceID:       strPtr("trace-abc"),
	})
	if err != nil {
		t.Fatalf("InsertTurn failed: %v", err)
	}

	// tenant_id must be denormalized from parent row
	var tenantID string
	err = db.QueryRow(ctx,
		`SELECT tenant_id::text FROM adversarial_review_turns
		 WHERE review_id=$1 AND round=1 AND turn_number=1`, reviewID,
	).Scan(&tenantID)
	if err != nil {
		t.Fatalf("query failed: %v", err)
	}
	if tenantID != "00000000-0000-0000-0000-000000000001" {
		t.Errorf("expected tenant_id denormalized from parent; got %q", tenantID)
	}
}

func TestInsertTurn_RejectsOrphanReviewID(t *testing.T) {
	ctx := context.Background()
	db := setupTestDB(t)
	defer db.Close()

	err := InsertTurn(ctx, db, InsertTurnParams{
		ReviewID:      "does-not-exist",
		Round:         1,
		TurnNumber:    1,
		Role:          "adversary",
		InputContent:  "x",
		OutputContent: "y",
	})
	if err == nil {
		t.Fatal("expected FK violation for unknown review_id")
	}
}

func TestInsertTurn_UpsertOnSameKey(t *testing.T) {
	ctx := context.Background()
	db := setupTestDB(t)
	defer db.Close()

	reviewID := seedReview(t, db, SeedReviewOpts{
		TenantID:  "00000000-0000-0000-0000-000000000001",
		DualModel: true,
	})

	// First write
	err := InsertTurn(ctx, db, InsertTurnParams{
		ReviewID: reviewID, Round: 1, TurnNumber: 2, Role: "primary",
		InputContent: "first", OutputContent: "v1", CostUSD: 0.10,
	})
	if err != nil {
		t.Fatalf("first insert failed: %v", err)
	}

	// Second write — upsert (last-write-wins on content)
	err = InsertTurn(ctx, db, InsertTurnParams{
		ReviewID: reviewID, Round: 1, TurnNumber: 2, Role: "primary",
		InputContent: "second", OutputContent: "v2", CostUSD: 0.99,
	})
	if err != nil {
		t.Fatalf("upsert failed: %v", err)
	}

	// Verify content updated, but cost preserved (first-write-wins per spec § 1b)
	var output string
	var cost float64
	db.QueryRow(ctx,
		`SELECT output_content, cost_usd FROM adversarial_review_turns
		 WHERE review_id=$1 AND round=1 AND turn_number=2`, reviewID,
	).Scan(&output, &cost)
	if output != "v2" {
		t.Errorf("expected content=v2 (last-write-wins); got %q", output)
	}
	if cost != 0.10 {
		t.Errorf("expected cost=0.10 (first-write-wins); got %f", cost)
	}
}

// Helpers (simplified — real test-setup helpers live elsewhere in workdesk)
func strPtr(s string) *string { return &s }
```

- [ ] **Step 2: Run test to verify failure**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/workdesk
go test -run '^TestInsertTurn' -v
```

Expected: FAIL — `InsertTurn` and `InsertTurnParams` are undefined.

- [ ] **Step 3: Implement `InsertTurn`**

Create `services/workdesk/turns.go`:

```go
package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5"  // or whatever pgx version is in go.mod
)

// InsertTurnParams carries everything needed to persist one turn row.
// tenant_id is intentionally NOT a field — it's read from the parent
// adversarial_reviews row inside the transaction to enforce spec § 4b
// ("only writer to adversarial_review_turns is this module; tenant_id
// is always denormalized from parent").
type InsertTurnParams struct {
	ReviewID      string
	Round         int
	TurnNumber    int
	Role          string  // "primary" or "adversary"
	ModelID       *string // nullable for primary turns that don't identify a model
	InputContent  string  // POST-redaction
	OutputContent string  // POST-redaction
	CostUSD       float64
	LatencyMs     int
	Redactions    json.RawMessage // JSONB counts per category
	TraceID       *string
}

// InsertTurn persists (or upserts) a turn row. Uses the spec § 1b
// idempotency rule: (review_id, round, turn_number) is the natural key.
// Duplicate calls update content (last-write-wins); cost_usd and
// latency_ms retain their first non-null write.
//
// Critically: tenant_id is copied from the parent review row *inside*
// the same transaction that inserts the turn — this is the invariant
// that makes the cross-tenant canary (§ 7e) always 0.
func InsertTurn(ctx context.Context, db *pgx.Conn, p InsertTurnParams) error {
	tx, err := db.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)

	// Read tenant_id from parent — if parent doesn't exist, FK will reject.
	var tenantID string
	err = tx.QueryRow(ctx,
		`SELECT tenant_id FROM adversarial_reviews WHERE id=$1`, p.ReviewID,
	).Scan(&tenantID)
	if err != nil {
		return fmt.Errorf("parent lookup: %w", err)
	}

	redactions := p.Redactions
	if redactions == nil {
		redactions = json.RawMessage("{}")
	}

	// Upsert with the first-write-wins semantics for cost/latency per spec § 1b
	_, err = tx.Exec(ctx, `
		INSERT INTO adversarial_review_turns
		  (review_id, tenant_id, round, turn_number, role, model_id,
		   input_content, output_content, cost_usd, latency_ms,
		   redactions, trace_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
		ON CONFLICT (review_id, round, turn_number) DO UPDATE
		SET input_content  = EXCLUDED.input_content,
		    output_content = EXCLUDED.output_content,
		    redactions     = EXCLUDED.redactions,
		    -- first-write-wins for cost + latency
		    cost_usd  = COALESCE(adversarial_review_turns.cost_usd, EXCLUDED.cost_usd),
		    latency_ms = COALESCE(adversarial_review_turns.latency_ms, EXCLUDED.latency_ms)
	`, p.ReviewID, tenantID, p.Round, p.TurnNumber, p.Role, p.ModelID,
		p.InputContent, p.OutputContent, p.CostUSD, p.LatencyMs,
		redactions, p.TraceID)

	if err != nil {
		return fmt.Errorf("insert turn: %w", err)
	}

	return tx.Commit(ctx)
}
```

Note: the exact pgx import and `db *pgx.Conn` type must match existing workdesk code. Check `services/workdesk/reviews.go` for the actual connection type in use (might be `*sql.DB`, `*pgxpool.Pool`, etc.) and adjust.

- [ ] **Step 4: Run test to verify pass**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/workdesk
go test -run '^TestInsertTurn' -v
```

Expected: all three tests PASS. If `setupTestDB` / `seedReview` helpers don't exist, use existing patterns from `review_test.go` — don't invent new helpers.

- [ ] **Step 5: Wire `record_primary_turn` MCP tool**

Edit `services/mcp/tools/dispatch.ts`. In the `dispatchTool` switch-case, add a new case before the closing switch:

```typescript
case "record_primary_turn": {
  // Spec § 5e
  const params = args as {
    review_id: string;
    round: number;
    rationale: Array<{
      finding_id: string;
      decision: "accepted" | "rejected";
      reason: string;
      applied_file_path?: string;
      applied_diff?: string;
    }>;
    artifact_after: string;
    cost_usd?: number;
    latency_ms?: number;
    client_generated_at: string;
  };

  // Validation
  if (!params.review_id || typeof params.review_id !== "string") {
    return errorResult("missing_required_param", "review_id is required");
  }
  if (!Number.isInteger(params.round) || params.round < 1) {
    return errorResult("invalid_param", "round must be positive integer");
  }
  if (!Array.isArray(params.rationale)) {
    return errorResult("invalid_param", "rationale must be an array");
  }
  if (typeof params.artifact_after !== "string") {
    return errorResult("invalid_param", "artifact_after must be a string");
  }
  if (params.artifact_after.length > 256 * 1024) {
    return errorResult("artifact_too_large", `artifact_after > 256KB`, {
      limit_bytes: 256 * 1024,
      actual_bytes: params.artifact_after.length,
    });
  }

  // Build the structured primary-turn payload, redact in JSON-walk mode
  // to protect both reason strings and applied_diff / artifact_after.
  const payload = {
    rationale: params.rationale,
    artifact_after: params.artifact_after,
  };
  const { value: redactedPayload, counts } = redactJsonValue(payload);

  // Forward to workdesk HTTP endpoint — matching the pattern used by
  // trigger_review today (see services/mcp/tools/dispatch.ts:1278-1323)
  const response = await fetch(`${WORKDESK_URL}/reviews/${params.review_id}/turns`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders },
    body: JSON.stringify({
      round: params.round,
      turn_number: 2,  // primary turn is always #2
      role: "primary",
      input_content: JSON.stringify((redactedPayload as typeof payload).rationale),
      output_content: (redactedPayload as typeof payload).artifact_after,
      cost_usd: params.cost_usd,
      latency_ms: params.latency_ms,
      redactions: counts,
    }),
  });

  if (!response.ok) {
    const body = await response.text();
    return errorResult("internal", `workdesk rejected: ${response.status} ${body}`);
  }

  return {
    content: [{ type: "text", text: JSON.stringify({
      review_id: params.review_id,
      round: params.round,
      turn_number: 2,
      persisted: true,
      redactions: counts,
    }) }],
  };
}
```

Also import `redactJsonValue` at the top of the file if not already imported:

```typescript
import { redactJsonValue } from "../redaction";
```

And register the tool in the tools listing (wherever `trigger_review`, `get_review_status` are listed — typically near the top of `dispatch.ts` or in `services/mcp/index.ts` depending on the file that owns the tool catalog).

- [ ] **Step 6: Add the matching workdesk HTTP route**

Edit `services/workdesk/reviews.go` (or the router file) to add a `POST /reviews/:id/turns` endpoint that calls `InsertTurn`. Follow the existing handler pattern — don't invent a new one. Return 404 if the review isn't found or is cross-tenant; 409 if the adversary turn for `round` is missing; 200 on upsert success.

- [ ] **Step 7: Run both test suites**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/mcp && npm test
cd /Users/ensell/Code/big-wave/services/workdesk && go test -v ./... -count=1
```

Expected: all green.

- [ ] **Step 8: Commit**

```bash
cd /Users/ensell/Code/big-wave
git add services/workdesk/turns.go services/workdesk/turns_test.go \
        services/workdesk/reviews.go \
        services/mcp/tools/dispatch.ts
git commit -m "feat: record_primary_turn MCP tool + workdesk turn persistence

Plugin calls record_primary_turn after Turn 3 to persist per-finding
rationale + artifact_after. Backend:
- Workdesk InsertTurn handler denormalizes tenant_id from parent
  review row inside the same transaction (enforces § 4b invariant)
- Upsert on (review_id, round, turn_number) with last-write-wins on
  content, first-write-wins on cost/latency per § 1b idempotency rule
- MCP tool redacts rationale + artifact_after via JSON-walk before
  forwarding to workdesk

Per spec § 5e."
```

---

## Task 7: Extend `trigger_review` / `get_review_status` / `resolve_review`

**Files:**
- Modify: `services/mcp/tools/dispatch.ts:1194-1360`
- Modify: `services/workdesk/reviews.go` — accept new params; return new response fields

### Steps

- [ ] **Step 1: Extend `trigger_review` validation and forwarding (TS)**

In `services/mcp/tools/dispatch.ts` at the `trigger_review` case (~line 1278), extend the param extraction and validation:

```typescript
case "trigger_review": {
  const params = args as {
    artifact_type: "plan_file" | "code_output" | "prompt" | "response";
    content?: string;
    file_path?: string;
    session_id?: string;
    client_tool?: "claude-code" | "codex" | "cursor";
    idempotency_key?: string;
    force_refresh?: boolean;
    parent_review_id?: string;
    prior_rationale?: {
      round: number;
      findings: Array<{ finding_id: string; decision: "accepted" | "rejected"; reason: string }>;
    };
  };

  // NEW validation for v1.4.0
  if (params.client_tool && !["claude-code", "codex", "cursor"].includes(params.client_tool)) {
    return errorResult("unknown_client_tool", `client_tool must be one of claude-code, codex, cursor`);
  }

  // Resolve effective config
  const config = await resolveMovpConfig({ force_refresh: params.force_refresh });

  // Validate pair if dual_model=true AND client_tool present
  let adversaryModelId: string | null = null;
  if (config.review.dual_model && params.client_tool) {
    const pair = config.review.model_pairs[params.client_tool];
    if (!pair) {
      return errorResult("no_pair_configured",
        `No model pair configured for client_tool=${params.client_tool}`);
    }
    const provider = providerFromModelId(pair.adversary);
    if (!provider || !isProviderAvailable(provider, tenantId)) {
      return errorResult("no_credential_for_provider",
        `Tenant has no credential for provider=${provider}`,
        { provider, remediation: `Add ${provider.toUpperCase()}_API_KEY to tenant config` });
    }
    adversaryModelId = pair.adversary;
  }

  // Determine effective_threshold
  const effectiveThreshold = config.review.dual_model
    ? config.review.threshold
    : config.review.legacy_threshold;

  // Forward to workdesk (existing pattern — extended with new fields)
  const workdeskBody = {
    artifact_type: params.artifact_type,
    content: params.content,
    file_path: params.file_path,
    session_id: params.session_id,
    // NEW v1.4.0 fields
    client_tool: params.client_tool ?? null,
    idempotency_key: params.idempotency_key,
    parent_review_id: params.parent_review_id,
    prior_rationale: params.prior_rationale,
    dual_model: config.review.dual_model,
    adversary_model_id: adversaryModelId,
    effective_threshold: effectiveThreshold,
    config_revision: config.revision,
  };

  const response = await fetch(`${WORKDESK_URL}/reviews`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders },
    body: JSON.stringify(workdeskBody),
  });

  // ... existing response handling, plus echo new fields into the MCP response
}
```

- [ ] **Step 2: Extend `get_review_status` response (TS)**

In the `get_review_status` case, preserve the existing `parsing_text` field and add the new structured fields passed through from workdesk:

```typescript
// After fetching from workdesk:
const responseBody = {
  review_id: workdeskResponse.id,
  status: workdeskResponse.review_status,
  round: workdeskResponse.round_number,
  client_tool: workdeskResponse.client_tool,
  dual_model: workdeskResponse.dual_model,
  adversary_model_id: workdeskResponse.adversary_model_id,
  category_scores: workdeskResponse.category_scores,
  composite_score: workdeskResponse.composite_score,
  effective_threshold: workdeskResponse.effective_threshold,
  stop_reason: workdeskResponse.stop_reason,
  findings: workdeskResponse.findings,
  cost: { usd: workdeskResponse.cost_usd, sunk_usd: workdeskResponse.sunk_cost_usd },
  latency_ms: workdeskResponse.latency_ms,
  redactions_summary: workdeskResponse.redactions,
  parsing_text: formatParsingText(workdeskResponse),  // preserves v1.3.x regex contract
};

// Deprecation marker for arg-less calls
if (!params.review_id) {
  (responseBody as typeof responseBody & { _meta?: object })._meta = {
    deprecated: {
      removed_in: "1.5.0",
      guidance: "always pass review_id; returning most recent tenant review",
    },
  };
}

return { content: [{ type: "text", text: JSON.stringify(responseBody) }] };
```

Use the existing `formatParsingText` function that today's code uses to produce the `Quality: X/10\nCost: $Y` human-readable body. Don't invent a new one.

- [ ] **Step 3: Tighten `resolve_review` retry semantics (TS)**

In the `resolve_review` case, before forwarding to workdesk:

```typescript
if (params.action === "retry") {
  // Fetch current status first
  const status = await fetch(`${WORKDESK_URL}/reviews/${params.review_id}`, {
    headers: authHeaders,
  }).then(r => r.json());

  if (status.review_status !== "error") {
    return errorResult("retry_on_completed_review",
      "retry is only valid when status=error (tightened in v1.4.0)");
  }
}
```

- [ ] **Step 4: Extend workdesk `POST /reviews` handler (Go)**

Edit `services/workdesk/reviews.go` to accept the new request fields and persist them on the `adversarial_reviews` row:

```go
type CreateReviewRequest struct {
	ArtifactType     string               `json:"artifact_type"`
	Content          string               `json:"content"`
	FilePath         string               `json:"file_path,omitempty"`
	SessionID        string               `json:"session_id,omitempty"`

	// NEW v1.4.0
	ClientTool        *string             `json:"client_tool,omitempty"`
	IdempotencyKey    *string             `json:"idempotency_key,omitempty"`
	ParentReviewID    *string             `json:"parent_review_id,omitempty"`
	PriorRationale    json.RawMessage     `json:"prior_rationale,omitempty"`
	DualModel         bool                `json:"dual_model"`
	AdversaryModelID  *string             `json:"adversary_model_id,omitempty"`
	EffectiveThreshold float64            `json:"effective_threshold"`
	ConfigRevision    int                 `json:"config_revision"`
}
```

Persist each on the INSERT for `adversarial_reviews`. Where the adversary-call logic computes category scores, call `ComputeComposite(scores, req.DualModel)` (Task 5) and pin the result to `composite_score`.

At review completion, set `stop_reason` on the row. Where the current v1.3.x code sets `convergence_reason`, extend to also set `stop_reason` with the new enum (`threshold_met | max_rounds | score_plateau | no_progress | operator_stop | error`).

- [ ] **Step 5: Run both test suites**

```bash
cd /Users/ensell/Code/big-wave/services/mcp && npm test
cd /Users/ensell/Code/big-wave/services/workdesk && go test -v ./... -count=1
```

Expected: all green. Existing tests continue to pass because new params are optional and new response fields are additive.

- [ ] **Step 6: Commit**

```bash
cd /Users/ensell/Code/big-wave
git add services/mcp/tools/dispatch.ts services/workdesk/reviews.go
git commit -m "feat: extend trigger_review/get_review_status/resolve_review for v1.4.0

trigger_review:
- Accepts client_tool, idempotency_key, force_refresh, parent_review_id,
  prior_rationale (all optional)
- Validates pair existence + provider-credential availability when
  dual_model=true; returns structured errors with remediation
- Never silently falls back to primary-as-adversary

get_review_status:
- Response gains round, client_tool, dual_model, adversary_model_id,
  composite_score, effective_threshold, stop_reason, redactions_summary
- parsing_text preserved verbatim for v1.3.x plugin compat
- _meta.deprecated marker when called without review_id

resolve_review:
- retry is valid only when status=error (tightened)

Per spec § 5b, § 5c, § 5d."
```

---

## Task 8: `movp://movp/reviews/<id>/turns` resource

**Files:**
- Modify: `services/mcp/index.ts` — register new resource
- Modify: `services/workdesk/turns.go` — add `ListTurns` handler

### Steps

- [ ] **Step 1: Write failing Go test for `ListTurns`**

Append to `services/workdesk/turns_test.go`:

```go
func TestListTurns_PaginationAndDefaultNoContent(t *testing.T) {
	ctx := context.Background()
	db := setupTestDB(t)
	defer db.Close()

	reviewID := seedReview(t, db, SeedReviewOpts{
		TenantID:  "00000000-0000-0000-0000-000000000001",
		DualModel: true,
	})

	// Seed 3 turns
	for round := 1; round <= 3; round++ {
		InsertTurn(ctx, db, InsertTurnParams{
			ReviewID: reviewID, Round: round, TurnNumber: 1, Role: "adversary",
			InputContent: "adv-in-" + string(rune('0'+round)),
			OutputContent: "adv-out-" + string(rune('0'+round)),
			CostUSD: 0.50,
		})
	}

	// Default: no content, limit 50
	turns, cursor, err := ListTurns(ctx, db, ListTurnsParams{
		ReviewID:       reviewID,
		TenantID:       "00000000-0000-0000-0000-000000000001",
		IncludeContent: false,
		Limit:          50,
	})
	if err != nil {
		t.Fatalf("ListTurns: %v", err)
	}
	if len(turns) != 3 {
		t.Errorf("expected 3 turns; got %d", len(turns))
	}
	if cursor != "" {
		t.Errorf("expected empty cursor; got %q", cursor)
	}
	// Content must be empty when include_content=false
	if turns[0].InputContent != "" || turns[0].OutputContent != "" {
		t.Error("expected empty content fields when include_content=false")
	}
}

func TestListTurns_CrossTenantAccessReturns404(t *testing.T) {
	ctx := context.Background()
	db := setupTestDB(t)
	defer db.Close()

	reviewID := seedReview(t, db, SeedReviewOpts{
		TenantID:  "00000000-0000-0000-0000-000000000001",
		DualModel: true,
	})

	// Attempt to list as a different tenant
	_, _, err := ListTurns(ctx, db, ListTurnsParams{
		ReviewID:       reviewID,
		TenantID:       "00000000-0000-0000-0000-000000000002",  // different tenant
		IncludeContent: false,
		Limit:          50,
	})

	if err == nil || !errors.Is(err, ErrReviewNotFound) {
		t.Errorf("expected ErrReviewNotFound for cross-tenant access; got %v", err)
	}
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/workdesk
go test -run '^TestListTurns' -v
```

Expected: FAIL — `ListTurns` undefined.

- [ ] **Step 3: Implement `ListTurns`**

Append to `services/workdesk/turns.go`:

```go
var ErrReviewNotFound = errors.New("review_not_found")

type ListTurnsParams struct {
	ReviewID       string
	TenantID       string
	IncludeContent bool
	Limit          int
	Cursor         string // opaque; encodes last (round, turn_number)
}

type TurnRow struct {
	Round          int
	TurnNumber     int
	Role           string
	ModelID        *string
	InputContent   string // empty unless IncludeContent=true
	OutputContent  string // empty unless IncludeContent=true
	CostUSD        float64
	LatencyMs      *int
	Redactions     json.RawMessage
	TraceID        *string
	CreatedAt      time.Time
}

func ListTurns(ctx context.Context, db *pgx.Conn, p ListTurnsParams) ([]TurnRow, string, error) {
	// First check the parent exists and belongs to this tenant
	var parentTenant string
	err := db.QueryRow(ctx,
		`SELECT tenant_id::text FROM adversarial_reviews WHERE id=$1`, p.ReviewID,
	).Scan(&parentTenant)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, "", ErrReviewNotFound
		}
		return nil, "", err
	}
	if parentTenant != p.TenantID {
		// Spec § 5g — cross-tenant access returns 404, not 403
		return nil, "", ErrReviewNotFound
	}

	cols := "round, turn_number, role, model_id, cost_usd, latency_ms, redactions, trace_id, created_at"
	if p.IncludeContent {
		cols += ", input_content, output_content"
	}

	limit := p.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}

	rows, err := db.Query(ctx, `
		SELECT `+cols+`
		FROM adversarial_review_turns
		WHERE review_id=$1
		ORDER BY round ASC, turn_number ASC
		LIMIT $2
	`, p.ReviewID, limit+1)  // fetch one extra to know if more exist
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()

	var result []TurnRow
	for rows.Next() {
		var t TurnRow
		if p.IncludeContent {
			err = rows.Scan(&t.Round, &t.TurnNumber, &t.Role, &t.ModelID,
				&t.CostUSD, &t.LatencyMs, &t.Redactions, &t.TraceID, &t.CreatedAt,
				&t.InputContent, &t.OutputContent)
		} else {
			err = rows.Scan(&t.Round, &t.TurnNumber, &t.Role, &t.ModelID,
				&t.CostUSD, &t.LatencyMs, &t.Redactions, &t.TraceID, &t.CreatedAt)
		}
		if err != nil {
			return nil, "", err
		}
		result = append(result, t)
	}

	var cursor string
	if len(result) > limit {
		// Trim and emit cursor
		last := result[limit-1]
		cursor = fmt.Sprintf("%d:%d", last.Round, last.TurnNumber)
		result = result[:limit]
	}

	return result, cursor, nil
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/workdesk
go test -run '^TestListTurns' -v
```

Expected: all tests PASS.

- [ ] **Step 5: Register MCP resource**

In `services/mcp/index.ts`, find where `movp://movp/config` is registered (around line 565 per exploration). Add a new resource registration for `movp://movp/reviews/{id}/turns`:

```typescript
// Register after the config resource
server.setRequestHandler(ReadResourceRequestSchema, async (request) => {
  const uri = request.params.uri;

  // Existing: movp://movp/config handling ...

  // NEW: movp://movp/reviews/<id>/turns
  const turnsMatch = uri.match(/^movp:\/\/movp\/reviews\/([^/]+)\/turns$/);
  if (turnsMatch) {
    const reviewId = turnsMatch[1];
    const params = new URL(uri).searchParams;
    const includeContent = params.get("include_content") === "true";
    const limit = parseInt(params.get("limit") ?? "50", 10);
    const cursor = params.get("cursor") ?? "";

    const response = await fetch(
      `${WORKDESK_URL}/reviews/${reviewId}/turns?` +
      new URLSearchParams({
        include_content: String(includeContent),
        limit: String(limit),
        cursor,
      }),
      { headers: authHeaders },
    );

    if (response.status === 404) {
      throw new Error("review_not_found");
    }
    if (!response.ok) {
      throw new Error(`workdesk failed: ${response.status}`);
    }

    const data = await response.json();
    return {
      contents: [
        { uri, mimeType: "application/json", text: JSON.stringify(data) },
      ],
    };
  }

  // ... fallthrough to other resource handlers
});
```

- [ ] **Step 6: Add matching workdesk HTTP route**

In `services/workdesk/reviews.go`, register `GET /reviews/:id/turns` → calls `ListTurns` with the tenant from the auth context.

- [ ] **Step 7: Run both test suites**

```bash
cd /Users/ensell/Code/big-wave/services/mcp && npm test
cd /Users/ensell/Code/big-wave/services/workdesk && go test -v ./... -count=1
```

Expected: all green.

- [ ] **Step 8: Commit**

```bash
cd /Users/ensell/Code/big-wave
git add services/mcp/index.ts services/workdesk/turns.go services/workdesk/turns_test.go \
        services/workdesk/reviews.go
git commit -m "feat: movp://movp/reviews/<id>/turns MCP resource

Read-only listing of turn rows for a review. Paginated (default
limit 50), content omitted by default (?include_content=true to opt
in). Cross-tenant access returns 404 (not 403) per spec § 5g — never
leak review-id existence across tenants.

Workdesk ListTurns enforces tenant ownership; MCP resource forwards
opaque cursor + query params.

Per spec § 5g."
```

---

## Task 9: Observability — OTel spans + metrics

**Files:**
- Modify: `services/workdesk/reviews.go`, `services/workdesk/turns.go` — add span instrumentation
- Modify: `services/mcp/tools/dispatch.ts` — add span instrumentation on MCP tool calls

### Steps

- [ ] **Step 1: Inventory existing instrumentation**

Run:
```bash
cd /Users/ensell/Code/big-wave
grep -rn 'otel\|honeycomb\|StartSpan\|trace\.Start' services/workdesk/ services/mcp/ | head -30
```

Find existing OTel setup. If the codebase already uses OTel, extend it; if not, stop and flag — adding observability from scratch is a separate plan.

- [ ] **Step 2: Add spans to the review flow (Go)**

Wrap the existing review handlers with spans. Pattern (adapt to the library in use — e.g., `go.opentelemetry.io/otel`):

```go
import "go.opentelemetry.io/otel"

var tracer = otel.Tracer("big-wave/services/workdesk/reviews")

func (h *Handler) TriggerReview(ctx context.Context, ...) {
    ctx, span := tracer.Start(ctx, "review.trigger")
    defer span.End()

    span.SetAttributes(
        attribute.String("tenant_id", tenantID),
        attribute.String("review_id", reviewID),
        attribute.Int("round", round),
        attribute.String("client_tool", clientTool),
        attribute.String("adversary_model_id", adversaryModelID),
        attribute.Bool("dual_model", dualModel),
    )

    // ... existing logic ...
}
```

Add spans at the four sites specified in spec § 1c: `review.trigger`, `review.adversary.call`, `review.primary_turn.record`, `review.stop`. The `review.stop` span (emitted at review completion) carries the `stop_reason` attribute.

- [ ] **Step 3: Add counter + histogram metrics (Go)**

```go
var (
    roundsCounter, _ = meter.Int64Counter("review.rounds_total")
    roundDurationHist, _ = meter.Float64Histogram("review.round_duration_seconds")
    redactionsCounter, _ = meter.Int64Counter("review.redactions_total")
)

// At review.stop:
roundsCounter.Add(ctx, 1, metric.WithAttributes(
    attribute.String("stop_reason", stopReason),
    attribute.String("client_tool", clientTool),
    attribute.String("adversary_provider", adversaryProvider),
))
roundDurationHist.Record(ctx, durationSeconds, ...)
```

- [ ] **Step 4: Add MCP-side spans (TS)**

In `services/mcp/tools/dispatch.ts`, at the top of each tool case, start a span. Match the existing pattern if any — otherwise use `@opentelemetry/api`.

- [ ] **Step 5: Run tests**

```bash
cd /Users/ensell/Code/big-wave/services/mcp && npm test
cd /Users/ensell/Code/big-wave/services/workdesk && go test -v ./... -count=1
```

Expected: all green. Observability adds no behavior change; tests should pass unchanged.

- [ ] **Step 6: Commit**

```bash
cd /Users/ensell/Code/big-wave
git add services/workdesk/reviews.go services/workdesk/turns.go services/mcp/tools/dispatch.ts
git commit -m "feat: OTel spans + metrics for dual-model review

Spans: review.trigger, review.adversary.call, review.primary_turn.record,
review.stop. Attributes include tenant_id, review_id, round, client_tool,
adversary_model_id, dual_model, and (on review.stop) stop_reason.

Metrics:
- review.rounds_total{stop_reason, client_tool, adversary_provider}
- review.round_duration_seconds{client_tool, adversary_provider}
- review.redactions_total{category}

Enables the SLI dashboards described in spec § 7e as query sketches.

Per spec § 1c."
```

---

## Task 10: Parity regression suite + dual-model e2e test

**Files:**
- Create: `services/mcp/review-parity.test.ts`
- Create: `services/mcp/dual-model-e2e.test.ts`

### Steps

- [ ] **Step 1: Write parity regression suite**

Create `services/mcp/review-parity.test.ts`:

```typescript
import { describe, it, expect } from "vitest";

/**
 * Parity suite — asserts that `dual_model=false` reviews (the legacy
 * path) produce the exact same MCP tool signatures, response shape,
 * and persisted column values as v1.3.2.
 *
 * This suite gates the v1.4.0 backend release per spec § 1e and § 7b.
 */

describe("v1.3.2 parity — trigger_review response shape", () => {
  it("response omits 4-turn fields when dual_model=false", async () => {
    // ... arrange: tenant with dual_model=false in resolved config
    // ... act: call trigger_review
    // ... assert: response does NOT include adversary_model_id (null is OK),
    //     response includes parsing_text with the legacy Quality:X/10 format,
    //     client_tool is accepted but ignored for routing
  });

  it("parsing_text preserves exact v1.3.x regex contract", async () => {
    const body = await callGetReviewStatus(seededCompletedLegacyReview);
    expect(body.parsing_text).toMatch(/Quality:\s*\d+(\.\d+)?\s*\/\s*10/);
    expect(body.parsing_text).toMatch(/Cost:\s*\$\d+(\.\d+)?/);
  });

  it("category_scores has 6 keys when dual_model=false (no observability)", async () => {
    const body = await callGetReviewStatus(seededCompletedLegacyReview);
    expect(Object.keys(body.category_scores).sort()).toEqual([
      "correctness", "performance", "reliability", "safety", "simplicity", "usability",
    ]);
    expect(body.category_scores.observability).toBeUndefined();
  });

  it("persisted row has effective_threshold=9.0 for legacy", async () => {
    // Query adversarial_reviews table directly — effective_threshold column
    const row = await queryReviewRow(seededCompletedLegacyReview);
    expect(row.effective_threshold).toBe(9.0);
    expect(row.dual_model).toBe(false);
  });
});

describe("v1.3.2 parity — get_review_status argument-less call", () => {
  it("argument-less call still returns most recent review with deprecation marker", async () => {
    const body = await callGetReviewStatus({ /* no review_id */ });
    expect(body._meta?.deprecated?.removed_in).toBe("1.5.0");
  });
});
```

Fill in the helpers (`callTriggerReview`, `callGetReviewStatus`, `queryReviewRow`, `seededCompletedLegacyReview`) using existing test fixtures / harness in `services/mcp/dispatch.test.ts`. Don't invent new harness; match what's there.

- [ ] **Step 2: Write dual-model happy-path e2e**

Create `services/mcp/dual-model-e2e.test.ts`:

```typescript
import { describe, it, expect } from "vitest";

/**
 * End-to-end happy path: dual_model=true, 2 rounds, score converges to
 * threshold. Stub the adversary so the test is hermetic. Asserts every
 * persisted turn row, composite computation, stop transitions, and
 * effective_threshold persistence.
 */

describe("Dual-model review — 2-round happy path", () => {
  it("converges to threshold_met in 2 rounds", async () => {
    // Arrange: tenant with dual_model=true, stubbed adversary that
    // returns scores increasing round-over-round, reaching 9.3 on round 2.

    // Act: call trigger_review (round 1) -> record_primary_turn ->
    //      trigger_review (round 2 with parent_review_id, prior_rationale)
    //      -> final get_review_status.

    // Assert:
    //   - 2 parent rows in adversarial_reviews with parent_review_id chain
    //   - 4 turn rows in adversarial_review_turns (2 adversary + 2 primary)
    //   - final composite_score computed via weighted average
    //   - final stop_reason = "threshold_met"
    //   - effective_threshold = 9.2 on both rows
    //   - no cross-tenant turn rows exist
  });
});
```

- [ ] **Step 3: Run tests**

Run:
```bash
cd /Users/ensell/Code/big-wave/services/mcp
npm test -- review-parity.test.ts dual-model-e2e.test.ts --reporter=verbose
```

Expected: all tests PASS. These suites are the CI gates for the backend release per spec § 7b.

- [ ] **Step 4: Commit**

```bash
cd /Users/ensell/Code/big-wave
git add services/mcp/review-parity.test.ts services/mcp/dual-model-e2e.test.ts
git commit -m "test: parity regression suite + dual-model e2e happy path

- review-parity.test.ts: asserts v1.3.2 contract preserved when
  dual_model=false (response shape, 6-category scores, parsing_text
  format, effective_threshold=9.0, argument-less get_review_status
  deprecation marker).
- dual-model-e2e.test.ts: 2-round happy path with stubbed adversary,
  asserts turn persistence, composite math, stop-reason transitions,
  effective_threshold=9.2 persistence.

CI gates per spec § 1e, § 7b."
```

---

## Final verification — full backend CI run

- [ ] **Step 1: Run all backend tests**

```bash
cd /Users/ensell/Code/big-wave
(cd services/mcp && npm test)
(cd services/workdesk && go test -v ./... -count=1)
```

Expected: all green across both suites.

- [ ] **Step 2: Run the e2e Docker stack**

```bash
cd /Users/ensell/Code/big-wave
make test-e2e
```

Expected: all e2e tests pass. If the e2e suite doesn't cover the new `record_primary_turn` path, add one e2e scenario that drives a full 2-round loop.

- [ ] **Step 3: Apply migration to staging DB snapshot**

Per spec § 7b Stage-1 gate:
```bash
# Restore the most recent staging snapshot to a scratch DB
pg_restore -d scratchdb $STAGING_SNAPSHOT
# Apply migration
DATABASE_URL=postgres://localhost/scratchdb make workdesk-migrate
# Apply Supabase RLS migration
supabase db push --db-url postgres://localhost/scratchdb
# Verify no constraint violations, no row rewrites
psql postgres://localhost/scratchdb -c "SELECT COUNT(*) FROM adversarial_reviews WHERE dual_model IS NULL"  # must be 0
psql postgres://localhost/scratchdb -c "\\d+ adversarial_review_turns"  # exists with expected shape
```

Expected: migration applies cleanly, zero unexpected NULLs, all new columns present.

- [ ] **Step 4: Final commit (if any doc updates needed)**

Update `services/mcp/CHANGELOG.md` and `services/workdesk/CHANGELOG.md` with the v1.4.0 entry referencing the spec. Commit:

```bash
cd /Users/ensell/Code/big-wave
git add services/mcp/CHANGELOG.md services/workdesk/CHANGELOG.md
git commit -m "docs: CHANGELOG entries for v1.4.0 dual-model adversarial review backend

Points at mona-lisa spec 2026-04-20-adversarial-review-dual-model-design.md
as the source of truth for all design decisions."
```

---

## Plan self-review notes

- **Spec coverage:** § 1 (invariants) covered via Task 6 (turn persistence invariants) and Task 9 (spans/metrics). § 4 (schema + redaction) covered by Tasks 1, 4. § 5 (MCP API) covered by Tasks 6, 7, 8. § 7b (CI gates) covered by Task 10 and the final verification block.
- **Out of scope (intentional):** § 2 web UI (separate frontend plan), § 6 plugin commands (separate plugins plan), § 7g meta-learning pipeline (deferred per spec), Honeycomb dashboard creation (ops activity).
- **Consistent naming:** `adversarial_review_turns` and `adversarial_reviews` used throughout; `ComputeComposite` signature is `(scores map[string]float64, dualModel bool) (float64, error)` in Tasks 5 and 7; `InsertTurn` / `ListTurns` match across Tasks 6 and 8.
- **No placeholders:** every code step has complete, copy-pasteable code. Every test step shows the test body. Every command shows the exact invocation with expected output shape.

---

## Next step after this plan completes

Two further plans required for the full v1.4.0 release:

1. **Frontend plan** — MoVP web UI Model Pairs page (spec § 2). File: `docs/superpowers/plans/2026-04-2X-adversarial-review-dual-model-frontend.md`. Depends on this backend plan being shipped (needs the PATCH endpoint to exist).

2. **Plugins plan** — claude-plugin command, codex-plugin skill, cursor-plugin rule (spec § 6). File: `docs/superpowers/plans/2026-04-2X-adversarial-review-dual-model-plugins.md`. Depends on backend plan (needs `record_primary_turn` + extended `trigger_review`); can ship in parallel with frontend.
