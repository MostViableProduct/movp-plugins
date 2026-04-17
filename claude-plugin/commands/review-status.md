---
description: "Check current adversarial review status"
required_tools: [get_review_status]
required_resources: []
---
Check the current adversarial review status for this session.

Call `get_review_status()` without arguments to get the most recent review for this tenant.

Present the output concisely based on the review status:

**If `review_status` is "running":**
```
[MoVP] Review in progress
  ID:     <review_id>
  Round:  <round_number>
  Status: running — check back shortly or run /movp review status again
```

**If `review_status` is "completed":**
```
[MoVP] Review <review_id>  (completed)
  Quality: <X>/10  |  Alignment: <Y>/10  |  Cost: $<Z>

  Category Scores:
    security: <n>  correctness: <n>  performance: <n>  stability: <n>
    ux_drift: <n>  outcome_drift: <n>  missing_tests: <n>  scope_creep: <n>

  Findings: <total> (<critical_count> critical, <high_count> high, <med_count> medium, <low_count> low)
  Resolution: <user_resolution or "pending">
```

**If `review_status` is "error":**
```
[MoVP] Review <review_id> failed
  Error: <error_reason>
  → Run /movp review to retry
```

**If no reviews found:**
Say: "No reviews found for this session. Run `/movp:review` to start one."

Do not call any additional tools. Only call `get_review_status()` once.
