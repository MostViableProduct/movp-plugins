# Changelog

All notable changes to MoVP plugins are documented here. This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.3.2 — 2026-04-19

### Fixed

- **MCP server pinned to `@movp/mcp-server@0.1.15`** — fixes a regression exposed right after v1.3.1 shipped: bare `npx @movp/mcp-server@latest`, Cursor, and Codex invocations exited immediately with `ERROR: MOVP_URL and MOVP_API_KEY are required` even after a successful `npx @movp/cli init`. The CLI's device-auth flow writes `WORKDESK_URL` / `WORKDESK_ACCESS_TOKEN` / `WORKDESK_TENANT` to `~/.config/movp/credentials`, but the shim only looked up `MOVP_*` keys. 0.1.15 aliases the `WORKDESK_*` form into `MOVP_*` when the latter is absent, so any credentials file produced by a current CLI works across all three plugins. Claude Code sessions were unaffected (env injected from `~/.claude.json`).

## 1.3.1 — 2026-04-19

### Fixed

- **MCP server pinned to `@movp/mcp-server@0.1.14`** — closes the Issue A + Issue B pair that together stranded sessions at "1 tool" and dropped the MCP stdio transport on transient errors.
  - **Issue A (warm cache)**: `warmToolsCache` is now retried 3× at 1s/2s/4s, `movp://movp/manifest` lazy-fetches on cache miss with a 2s budget, and a shared `inflightWarm` promise coalesces concurrent reads (shipped upstream in 0.1.13, now reflected in the plugin pin).
  - **Issue B (null-id emit loop)**: every stdout emit site in the shim now routes through a single `writeFrame` helper that drops orphan `error`+`id:null`+no-`method` frames before they trip the MCP client's Zod validator. `mcpPost` threads the inbound request id through every internal HTTP-error path; the parse-error path at the stdin reader no longer emits a null-id response (spec-aligned per JSON-RPC 2.0 §4.2) and logs a structured `parse_error` stderr event instead; notifications short-circuit before forwarding (§4.1). Structured stderr lines now carry `schema:"mcp_stdio/v1"`, `kind`, and `pid`; free-text that could echo secrets (URLs / JWTs / `wdg_`/`sk_`/`pk_` keys / raw CR-LF) is redacted at source.

### Added

- `scripts/mcp-smoke` lockfile regenerated against `@movp/mcp-server@0.1.14`; smoke test validates 8 tools + 6 resources including the three review tools end-to-end.

## 1.2.1 — 2026-04-17

### Fixed

- **`/movp:auto-review` MCP write-tool probe** now checks the session's deferred MCP tool list (authoritative) instead of reading `movp://movp/registry` (which never contains tool definitions). Matches the skill's own tool-vs-resource contract. Operators will see fewer "registry unreachable" errors in the write-ladder fallthrough.

- **`/movp:auto-review on|off` is now idempotent.** A new Step 0 (read-before-write) compares current config to the target state and exits with `[MoVP] Auto-review: already <ON|OFF>. No changes made.` when they match — no cosmetic YAML drift on no-op invocations.

- **`/movp:auto-review on` persists consent alongside the flag flip.** The command now writes `review.auto_review.consent.{schema_version, plugin_version, granted_at}` in the same write as the flag mutation. Explicit command invocation counts as consent — the skill's first-run prompt will not fire after an explicit `on`. Existing v1.2.0 users with flags already on but no consent converge on the next `on` invocation or on `y` to the skill's first-run prompt (whichever comes first).

### Added

- **`scripts/validate.sh` CHECK 11: auto-review spec hygiene.** Three scripted rules guard against regressions:
  - Rule A — any reference to `movp://movp/registry` in the auto-review command or skill must sit within a `do NOT` / `Do NOT` / `DO NOT` context.
  - Rule B — the `yq ... && diff` chain is forbidden (misleading exit-1 display pattern; `diff` exits 1 when files differ, masking successful writes).
  - Rule C — `strenv(VAR)` usage must be paired with `export VAR` in the same file, otherwise `yq` silently serializes `null`.
- Three matching fixture tests in `scripts/test-validate.sh` verify CHECK 11 catches each rule violation.

### Changed

- Command and skill specs now document `yq v4+` (Mike Farah's Go yq) as required; older versions and Python `yq` fall through to the refuse-safely path. Python `yq` lacks the pipeline and `strenv()` syntax used in the consent write.
- Honest blast-radius note added for `yq -i`: it reserializes the full document, which can normalize inline-comment whitespace and shift unrelated sections' formatting. Content and semantics are preserved; cosmetic drift is possible. MCP `set_config` remains the long-term fix.
- Write-once semantics pinned: `consent.granted_at` is set once and never refreshed on subsequent `on` invocations; `consent.plugin_version` records the version that originally obtained consent and only bumps on future consent-schema changes.

### Migration

Operators upgrading from v1.2.0 with flags already `on` and no consent record will either (a) see one prompt on the next auto-review (answer `y`, persisted), or (b) clear state by running `/movp:auto-review on` once (writes consent in-place without prompting). Both paths converge in a single action. No migration script needed.

## 1.2.0 — 2026-04-16

### Changed

- **Skill renamed:** `movp-review` → `review-advisor`. Resolves a UX collision in the Claude Code slash picker where the auto-trigger skill and the `/movp:review` command rendered with near-identical descriptions. Any saved prompts, `CLAUDE.md` references, or external docs that invoked the skill by name must be updated. Review behavior is unchanged when auto-review is enabled.

- **Auto-review now honors `.movp/config.yaml`.** The `review-advisor` skill reads `movp://movp/config` before every run and respects `review.auto_review.plan_files` and `review.auto_review.code_output`. Prior versions ignored these flags.

- **Visible skip lines.** When auto-review is disabled, the skill emits a single line naming the flag and the re-enable command. No more silent no-ops.

- **Parsing spec centralized.** Score/cost regex used to be inlined in `claude-plugin/commands/review.md`. It now lives once in `skills/review-advisor/SKILL.md` §Parsing spec; the command references it. Prevents drift between the auto-trigger and loop paths.

### Added

- **`/movp:auto-review` command** (Claude plugin only). Slash-native toggle for auto-review state:
  - `/movp:auto-review on` — restore shipped defaults (plan files on, code output off)
  - `/movp:auto-review off` — disable auto-review entirely
  - `/movp:auto-review status` — show current flags and consent state
  - Writes use a priority ladder: MCP `set_config` tool (if present) → `yq` → refuse safely with manual-edit instructions. Never attempts shell redirects or `sed` against existing YAML files.

- **First-run consent.** On first auto-trigger per repo, the skill pauses and asks the operator:
  ```
  MoVP auto-review will run once now. Each auto-review consumes review credits. Continue? [y / N / always-off]
  ```
  - `y` → proceed and persist consent (via the same write ladder)
  - `N` → skip this artifact only
  - `always-off` → set both auto-review flags to false and skip
  - No reply / abort / session-end → treated as `N` (safe default; no charge, no consent written)

  Consent record schema lives under `review.auto_review.consent` in config (no separate dotfiles); includes `schema_version`, `plugin_version`, `granted_at`.

- **Cost echo on every auto-review.** Output now ends with:
  ```
  [MoVP] Auto-review cost: $<cost>
  To disable: /movp:auto-review off    |    Status: /movp:status
  ```

### Migration

Existing repos with `review.auto_review.plan_files: true` will see a one-time consent prompt before the next auto-review. Answering `y` persists consent and restores the passive behavior you had before. Answering `always-off` turns auto-review off durably.

## 1.1.0

- Homebrew formula drift prevention (validate + release).
- Plugin directory structure checks + tag smoke test.

## 1.0.0

- Initial release: three-platform MoVP plugins (Claude / Codex / Cursor) with install scripts, MCP integration, adversarial review command and skill, control-plane skill, and supporting commands.
