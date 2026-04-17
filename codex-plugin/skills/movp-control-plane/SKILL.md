---
name: movp-control-plane
description: >
  MoVP control plane — health scores, recommendations, anomalies, cost
  awareness, and constraint checks. Invoke at the start of every working
  session and when the user mentions project health, cost, stability,
  recommendations, anomalies, or constraints.
required_tools: [check_constraints, get_cost_summary]
required_resources: [movp://control-plane/health-scores, movp://control-plane/recommendations, movp://control-plane/anomalies]
---

# MoVP Control Plane

## At Session Start

When starting a new working session, read the control plane snapshot to establish context:

1. Read `movp://control-plane/health-scores` — note any dimension below 0.7 (maps to <7/10)
2. Read `movp://control-plane/recommendations` — identify recommendations relevant to the current task
3. Read `movp://control-plane/anomalies` — note any active HIGH or CRITICAL severity anomalies

Each read is independent — proceed with whichever succeed. If any of the three fails (MCP error, server unreachable, empty contents), silently skip that category for this session; do not block the user. Only surface degraded context to the user if **all three** reads fail: `[MoVP] Control-plane context unavailable — proceeding without health/recommendations/anomalies context. Run /movp:doctor to diagnose.`

Present this context **concisely and only when relevant**. Do not dump raw JSON. Do not interrupt if the user has already stated their task — weave context into the first substantive response.

Example:
```
Before we begin — project health is 8.7/10 (30d). There's an active recommendation 
about cache efficiency in auth service queries, which is directly relevant to this 
refactor. I'll factor that in.
```

Do NOT present health context if:
- Health is above 0.85 overall and there are no relevant recommendations
- The task is a minor operation (single file read, git command, question)
- The user has already explicitly read control plane data this session

## During Work

- When the user mentions a concern (performance, cost, stability), check `movp://control-plane/recommendations` for matching active recommendations before proposing solutions.
- When working in an area with an active anomaly, mention it once: "There's an active anomaly in this area — [summary]. Proceed with extra care."
- Do NOT read control plane resources more than once every 20 tool uses unless the user explicitly asks.

## Cost Awareness

- If the user asks about session cost or AI spend, use the `get_cost_summary` tool (not the resource snapshot) to get a fresh parameterized breakdown.
- Surface cost data only when relevant — not as ambient noise on every response.

## Recommendations

- When a recommendation is directly applicable to the current task, mention it and offer to factor it in.
- After the user acts on a recommendation, offer to dismiss it: "Want me to mark that recommendation as resolved?"
- Use `dismiss_recommendation` only when the user explicitly confirms.

## Constraint Checks

- For significant changes (new dependencies, architecture decisions, API changes), use `check_constraints` to run a heuristic check.
- Always include `"confidence": "heuristic"` framing when presenting results — these are advisory, not formal gates.
- Example: "Quick constraint check: this change may touch the budget constraint on external API calls. Worth reviewing before committing."

## What NOT to Do

- Do not read all 4 control plane resources on every message — that is excessive token use.
- Do not present raw JSON payloads to the user.
- Do not block progress on heuristic constraint warnings — they are advisory.
- Do not conflate control plane context with review findings (those come from `get_review_status`).
