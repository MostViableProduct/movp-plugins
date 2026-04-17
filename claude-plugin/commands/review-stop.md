---
description: "Stop the current running adversarial review"
required_tools: [get_review_status, resolve_review]
required_resources: []
---
Stop the current running adversarial review by sending the operator acceptance signal.

**Step 1 — Find the active review**

Call `get_review_status()` without arguments.

- If `review_status` is not "running", say: "No review is currently running." and stop.
- Note the `review_id`.

**Step 2 — Send acceptance signal**

Call `resolve_review(review_id=<id>, action="accept")`.

**Step 3 — Confirm**

Report:
```
[MoVP] Review <review_id> accepted — loop stopped.
  The review has been accepted and will not continue to the next round.
```

If `resolve_review` returns an error (e.g., status 409), explain the conflict:
- "already accepted" → "Review was already accepted."
- "already dismissed" → "Cannot accept a dismissed review."
- other → show the error message.
