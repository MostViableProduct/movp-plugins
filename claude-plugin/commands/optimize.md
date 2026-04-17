---
description: "Analyze review data and recommend rule improvements"
required_tools: [get_review_status, dismiss_rule_suggestion, dismiss_recommendation]
required_resources: [movp://control-plane/recommendations]
---
Analyze MoVP's review loop training data and recommend rule improvements based on recurring patterns.

**When to run**: after 3+ dismissed findings in a single category, or when a category score has been consistently below 7 across multiple recent reviews.

**Step 1 — Load data in parallel**

Call all three simultaneously:
1. Read `movp://movp/suggested-rules` resource — recurring pattern suggestions from the pipeline
2. Read `movp://control-plane/recommendations` resource — active control plane recommendations
3. Call `get_review_status()` — recent review context

**Step 2 — Analyze patterns**

From the suggested-rules data, identify:
- Categories with the highest `confirmed_count` (most recurring defects)
- Categories that already have a rule in `.claude/rules/` (skip — already covered)
- Suggestions where `status = "active"` (actionable)

From recommendations, identify any that overlap with review finding patterns.

**Step 3 — Present the analysis**

```
[MoVP] Optimize — Review Loop Analysis

Recurring Defect Patterns
─────────────────────────
<For each active suggestion, sorted by confirmed_count desc:>

  <finding_category> (<artifact_type>) — <confirmed_count> confirmed in 30 days
  Suggested rule: "<first line of rule_markdown name field>"
  
  Preview:
    <first 3 lines of rule body>
    ...

  → Accept (write .claude/rules/movp-<category>.md) or Dismiss

<If no suggestions:>
  No recurring patterns detected yet. Rules are generated when a finding
  category is confirmed more than 3 times in 30 days.

Active Recommendations
──────────────────────
<List top 3 recommendations relevant to current work, or "None active.">

Recent Review Context
─────────────────────
<Quality score, top finding category, last review cost>
```

**Step 4 — Act on developer response**

Wait for the developer to respond for each suggestion.

For **"accept"** / **"yes"** / **"apply"**:
1. Take the full `rule_markdown` from the suggestion
2. Determine the file name: `.claude/rules/movp-<finding_category>.md`
3. Check if the file already exists — if it does, ask before overwriting
4. Write the rule file
5. Call `dismiss_rule_suggestion(suggestion_id=<id>, reason="applied")`
6. Confirm: "✓ Rule written to .claude/rules/movp-<category>.md"

For **"dismiss"** / **"no"** / **"skip"**:
1. Call `dismiss_rule_suggestion(suggestion_id=<id>, reason="dismissed")`
2. Confirm: "Suggestion suppressed for 90 days."

For **"not applicable"** / **"already covered"**:
1. Call `dismiss_rule_suggestion(suggestion_id=<id>, reason="not_applicable")`

**Important rules:**
- Never write rule files without explicit confirmation
- Never dismiss without explicit developer instruction
- Process one suggestion at a time — don't act on all at once
- If the developer asks to "apply all", confirm the full list before writing
