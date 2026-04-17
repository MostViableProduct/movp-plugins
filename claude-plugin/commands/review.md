---
description: "Run an adversarial review loop of the most recent artifact"
---
Run an adversarial review loop. You will trigger a review, implement all findings, then re-review until the score reaches 9.0 or the operator stops. Track `previous_score` and `round` across iterations.

**Step 1 — Identify the artifact**

Look at the most recent significant output in this conversation:
- If a plan file was just written: use artifact_type="plan_file" with the plan content
- If significant code was just written (new feature, multi-file change, migration): use artifact_type="code_output" with the code
- If neither, ask the user what to review before proceeding

---

**Step 2 — Begin the review loop**

Set `round = 1`, `previous_score = null`.

Read `.movp/config.yaml` if it exists in the project and extract `review.max_rounds`; if the file is absent or the key is not set, use `max_rounds = 3`.

Track these variables across the loop:
- `round` (integer, starts at 1)
- `previous_score` (float | null, starts as null)
- `current_score` (float | null, set each round from the review text)
- `total_cost` (float, accumulated across rounds, starts at 0)

Repeat until auto-stopped or operator stops:

### 2a — Trigger review

Call `trigger_review` with:
- `artifact_type`: "plan_file" or "code_output"
- `content`: the current artifact text (updated after each round with any fixes applied)
- `session_id`: current session ID if available

Note the `review_id` returned.

### 2b — Poll for completion

Call `get_review_status(review_id=<id>)` every few seconds until `review_status` is "completed" or "error".

If `review_status` is "error": stop the loop, show the error, and call `resolve_review(review_id=<id>, action="retry")`. If retry is unavailable, restart from step 2a for the current round (preserving `round` and `previous_score`).

### 2c — Present results

Format output as:

```
[MoVP] Review Loop — Round <N>

Score: <X>/10  <if round > 1: "(was <previous_score>/10)">
Cost: $<Z>

Category Scores:
  correctness: <n>  performance: <n>  reliability: <n>
  safety: <n>       simplicity: <n>   usability: <n>

Findings (<total>):

[CRIT] <category> (<confidence>)
  <summary> — <file_path>:<line_number>
  Fix: <suggested_fix>

[HIGH] <category> (<confidence>)
  <summary> — <file_path>:<line_number>
  Fix: <suggested_fix>

[MED] ...

[LOW] ...
```

Parse the score and cost from the `get_review_status` text using the authoritative spec in `skills/review-advisor/SKILL.md` → "Parsing spec". Store the score as `current_score` and add the round's cost to `total_cost`. Follow the spec's parse-failure policy (visible drift message, no fabricated values).

On round 1 (previous_score is null), show "Initial score: X/10" instead of a delta.

### 2d — Auto-stop check

If `current_score >= 9.0` AND there are no `[CRIT]` or `[HIGH]` findings:
→ Show:
```
[MoVP] Score threshold reached (9.0). Loop complete.
  Final score: <X>/10  Rounds: <N>  Total cost: $<total_cost>
```
→ Proceed to Step 3.

If `current_score == previous_score` and round > 1:
→ Note: "Score unchanged from previous round (<X>/10). Fixes may not be landing — review findings carefully."

If round >= max_rounds (from .movp/config.yaml, default 3):
→ Show: "Max review rounds reached (<N>). Last score: <X>/10."
→ Proceed to Step 3.

### 2e — Implement fixes

Without asking the operator, implement all critical and high severity findings (shown as `[CRIT]` / `[HIGH]` in tool output). Use judgment on medium and low (`[MED]` / `[LOW]`).

After implementing, show a file-level summary:
```
Changes made this round:
  - Modified: <file1>, <file2> (brief description of fix)
  - ...
```

If no files could be changed (e.g. read-only, artifact was plan text), note which fixes were skipped.

If the artifact is a plan file and you modified it, re-read it from disk before the next round. Pass the updated file content as `content` in the next `trigger_review` call.

### 2e-guard — No-op check

If no changes were made this round (fixes could not be applied or no actionable findings):
  → Show: "No changes applied this round. Stopping loop to avoid a no-op re-review."
  → Proceed to Step 3 (post-loop).

Note: if only `[MED]`/`[LOW]` findings were skipped by judgment and nothing was modified, this guard still fires — stopping is intentional to avoid re-reviewing unchanged content.

### 2f — Ask to continue

Ask:
> **Continue to next review round, or stop?**

- "continue" → set `previous_score = current_score`, increment `round`, go to 2a with updated artifact
- "stop" → proceed to Step 3

---

**Step 3 — Post-loop**

Ask:
> **Continue with implementation, or something else?**

Based on the operator's reply:
- "implement" / "continue" / "proceed" → begin implementing the reviewed artifact (code the plan, or continue with next development steps)
- "stop" / "done" / "exit" or any other response → confirm: "Understood. Review complete. Score: <final_score>/10 after <N> rounds."
