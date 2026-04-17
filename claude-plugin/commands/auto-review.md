---
description: "Toggle MoVP auto-review on/off or show status"
argument-hint: "on | off | status"
---

Toggle the MoVP auto-review skill (`review-advisor`) without editing `.movp/config.yaml` by hand. Operates on `review.auto_review.plan_files` and `review.auto_review.code_output`.

Parse the single positional argument `$ARGUMENTS`:

- `on` → enable auto-review (restore shipped defaults)
- `off` → disable auto-review entirely
- `status` (or no argument / empty) → show the current state

## Action: status

Read `movp://movp/config` and print:

```
[MoVP] Auto-review status
  plan files:  <yes/no>   (review.auto_review.plan_files)
  code output: <yes/no>   (review.auto_review.code_output)
  consent:     <granted <granted_at> by plugin <plugin_version> | not yet granted>

Toggle with: /movp:auto-review on | off
Granular control: edit .movp/config.yaml with yq (review.auto_review.plan_files, .code_output)
```

If the config resource errors, print:

```
[MoVP] Config unreachable. Run /movp:status to diagnose.
```

and exit. Do not attempt disk reads — the MCP resource is the single source of truth.

## Actions: on / off

For `on`: target values are `plan_files=true`, `code_output=false` (shipped defaults — plan files are the primary auto-review target; code output is opt-in).

For `off`: target values are `plan_files=false`, `code_output=false`.

Apply the target values using the **write ladder below**, in priority order. Stop at the first path that succeeds.

### Write ladder

**1. MCP write tool — preferred.**

Inspect `movp://movp/registry` for a config-write tool (e.g. `set_config` or equivalent). If present, call it to set both `review.auto_review.plan_files` and `review.auto_review.code_output` to the target values in one call. Prefer this path — it keeps the MCP resource as single source of truth and avoids any client-side YAML editing.

**2. `yq` — fallback.**

Detect with `command -v yq`. If available and `.movp/config.yaml` exists:

```bash
yq -i '.review.auto_review.plan_files = <true|false> | .review.auto_review.code_output = <true|false>' .movp/config.yaml
```

Preserves comments, structure, and unrelated keys.

**3. `yq` available, config file absent.**

Create a minimal `.movp/config.yaml` with only the two flags populated:

```yaml
review:
  auto_review:
    plan_files: <true|false>
    code_output: <true|false>
```

Do not template the full default config — the MCP server fills defaults for other keys.

**4. `yq` unavailable and config file exists — refuse safely.**

Do NOT attempt shell redirects, `sed`, or line-based edits against an existing file. Print:

```
[MoVP] Cannot safely edit .movp/config.yaml without yq.
Install yq (brew install yq) or edit the file manually:
  review:
    auto_review:
      plan_files: <true|false>
      code_output: <true|false>
```

Exit non-zero. This is the reliability guardrail — better a clear manual instruction than a clobbered file.

## Confirmation messages

On successful `on`:

```
[MoVP] Auto-review: ON (plan files only). Manage granularity by editing .movp/config.yaml.
```

On successful `off`:

```
[MoVP] Auto-review: OFF. Re-enable with /movp:auto-review on.
```

## Unknown argument

If `$ARGUMENTS` is not one of `on`, `off`, `status`, or empty, print:

```
[MoVP] Usage: /movp:auto-review on | off | status
```

Exit without changing config.

## Concurrency note

Writes read-then-write the full document via a single `yq` invocation (or a single MCP tool call). Concurrent `/movp:auto-review` calls from two sessions against the same repo are last-write-wins — rare in practice and observable via `/movp:auto-review status` or `/movp:status`.
