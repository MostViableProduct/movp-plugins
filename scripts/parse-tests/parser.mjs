// Canonical parser for get_review_status completed-body text.
//
// This module is the single source of truth for the Score/Cost regexes and
// the [0,1] internal score normalization. The three SKILL.md files under
// <platform>-plugin/skills/review-advisor/ quote these regexes for human
// readers; check-skill-sync.mjs enforces byte-equality between those quotes
// and the exported constants below on every CI run.

// Authoritative regex source strings. Keep these string-literal exports —
// check-skill-sync.mjs reads them as text, so construction must be a plain
// string literal (no concatenation, no String.raw, no reformatting).
export const SCORE_REGEX_SOURCE = "Quality:\\s*([0-9]+(?:\\.[0-9]+)?)\\s*/\\s*10";
export const COST_REGEX_SOURCE = "Cost:\\s*\\$([0-9]+(?:\\.[0-9]+)?)";

// Emit exactly this string on parse failure. Downstream callers print it
// verbatim — do not fabricate values and do not retry.
export const PARSE_FAILURE_MESSAGE =
  "[MoVP] Auto-review completed; cost/score unavailable (unexpected response format). Run /movp:status to verify backend.";

const RAW_SLICE_MAX = 500;

function sliceRaw(input) {
  if (typeof input !== "string") return "";
  return input.length > RAW_SLICE_MAX ? input.slice(0, RAW_SLICE_MAX) : input;
}

function failure(input) {
  return {
    score_internal: null,
    display_10: null,
    cost_usd: null,
    raw: sliceRaw(input),
    error: "unexpected_response_format",
  };
}

// Parse get_review_status completed-body text.
//
// success shape: { score_internal: [0,1] float, display_10: [0,10] float,
//                  cost_usd: >=0 float, raw: string }
// failure shape: { score_internal: null, display_10: null, cost_usd: null,
//                  raw: string, error: "unexpected_response_format" }
//
// Both regexes must match; a display_10 outside [0,10] is treated as failure
// (no clamping — surface drift per fail-hard-and-loud).
export function parse(input) {
  if (typeof input !== "string") return failure(input);

  const scoreRe = new RegExp(SCORE_REGEX_SOURCE);
  const costRe = new RegExp(COST_REGEX_SOURCE);

  const scoreMatch = input.match(scoreRe);
  const costMatch = input.match(costRe);
  if (!scoreMatch || !costMatch) return failure(input);

  const display_10 = Number.parseFloat(scoreMatch[1]);
  const cost_usd = Number.parseFloat(costMatch[1]);
  if (!Number.isFinite(display_10) || !Number.isFinite(cost_usd)) return failure(input);
  if (display_10 < 0 || display_10 > 10) return failure(input);
  if (cost_usd < 0) return failure(input);

  return {
    score_internal: display_10 / 10,
    display_10,
    cost_usd,
    raw: sliceRaw(input),
  };
}

// Display-side conversion used by the round-trip property test. Mirrors the
// plan's Score contract: display_10 = round(score * 10, 1).
export function toDisplayText({ score_internal, cost_usd }) {
  const display_10 = Math.round(score_internal * 10 * 10) / 10;
  const cost_rendered = cost_usd.toFixed(2);
  return `Quality: ${display_10}/10\n\nCost: $${cost_rendered}\n`;
}
