---
name: movp-review
description: >
  Adversarial review for plan files and significant code output.
  Invoke after writing a plan file, completing a multi-file code change,
  or when the user asks for a review. Do not invoke for trivial edits,
  file reads, or git commands.
required_tools: [trigger_review, get_review_status, resolve_review]
required_resources: []
---

# MoVP Adversarial Review

> Scope: plan files and significant code output  
> MCP tools: `get_review_status`, `trigger_review`, `resolve_review`

After writing a plan file or producing a significant code change (new feature, refactor, migration, or multi-file edit), trigger an adversarial review using the MoVP tools. Do not trigger for trivial operations: file reads, git status/log, search queries, single-line fixes, or tool calls with no code output.

## When to trigger

Trigger `trigger_review` automatically when you:

- Write or significantly modify a plan file (`.md` planning documents, architecture docs, PRDs)
- Complete a multi-file code change (3+ files, or any new service/module)
- Produce a significant new code output in a single response (functions, handlers, migrations)

Do **not** trigger for: reading files, running tests, git commands, grep/search, single-line edits, config-only changes.

## How to run a review

```
1. Call trigger_review(artifact_type="plan_file"|"code_output", content=<artifact>, session_id=<current session>)
   → returns review_id

2. Poll get_review_status(review_id=<id>) until review_status is "completed" or "error"
   Always use the review_id from step 1 — do NOT call get_review_status without review_id
   when multiple reviews may be in flight (returns most recent tenant review otherwise).

3. Ask the developer: implement fixes, dismiss findings, or accept as-is

4. Call resolve_review(review_id=<id>, action="accept"|"dismiss"|"escalate"|"retry") based on their choice
```

## Tool availability

Call `trigger_review` directly — do not pre-flight-check availability via resource listings.

If `trigger_review` (or any review tool) returns an error indicating the tool is not registered — such as `tool not found`, `unknown tool`, or `method not found` — stop immediately, tell the developer, and suggest running `/movp:doctor` to diagnose the MCP setup.

**Never fabricate a review.** If the tool call fails for any reason, stop and report the error.

## Presenting findings

Format findings as structured output with severity badges. After showing findings, always ask:

> **Reply with:** implement fixes, dismiss (false positive / not applicable / deferred), or accept as-is

> **Full review loop:** Use `/movp:review` for an interactive multi-round loop where findings are implemented between rounds and the score tracked to 9.0.

## Resolve actions

| Developer says | Action to call | Notes |
|---|---|---|
| "accept", "looks good", "ship it" | `resolve_review(action="accept")` | Idempotent — safe to call twice |
| "dismiss", "false positive", "not applicable" | `resolve_review(action="dismiss", reason="false_positive"\|"not_applicable"\|"deferred")` | |
| "escalate", "create a ticket" | `resolve_review(action="escalate", target="todo")` | |
| "retry", "run it again" | `resolve_review(action="retry")` | **Only valid when review_status is "error"** — do not call on completed reviews |

## Rate and cost awareness

Reviews consume LLM budget. Do not trigger multiple reviews in a single session for the same artifact. If `trigger_review` returns a rate limit error (429), inform the developer and do not retry automatically. For multi-round loop behavior, see the `/movp:review` command.
