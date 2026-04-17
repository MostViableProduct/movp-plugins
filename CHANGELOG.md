# Changelog

All notable changes to MoVP plugins are documented here. This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
