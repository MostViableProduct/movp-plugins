---
description: "Summarize the completed adversarial review"
required_tools: [get_review_status]
required_resources: []
---
Summarize the completed adversarial review loop for the most recent review.

**Step 1 — Get review data**

Call `get_review_status()` without arguments. If a `review_id` was provided by the user, pass it explicitly.

**Step 2 — Present summary**

Format the output as:

```
[MoVP] Review Summary — <review_id>

  Status:   <review_status>
  Rounds:   <round_number> (<convergence_reason or "in progress">)
  Cost:     $<review_cost_usd>

  Scores
    Overall quality:    <quality>/10
    Overall alignment:  <alignment>/10
    
    Category breakdown:
      correctness:   <n>/10
      performance:   <n>/10
      reliability:   <n>/10
      safety:        <n>/10
      simplicity:    <n>/10
      usability:     <n>/10

  Findings (<total>)
    Critical: <n>   High: <n>   Medium: <n>   Low: <n>

  Resolution: <user_resolution or "pending — use /movp:review to act on findings">
```

Omit category scores if not present (review still running or pre-Phase 3).

If review status is "running", note: "Review is still in progress. Scores and findings may be incomplete."

If no review is found, say: "No review found. Run `/movp:review` to start one."

Do not call any additional tools. Only call `get_review_status()` once.
