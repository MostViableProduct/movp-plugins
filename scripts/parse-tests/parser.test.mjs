import { test } from "node:test";
import assert from "node:assert/strict";
import fc from "fast-check";
import {
  parse,
  toDisplayText,
  SCORE_REGEX_SOURCE,
  COST_REGEX_SOURCE,
  PARSE_FAILURE_MESSAGE,
} from "./parser.mjs";

const SCORE_RE = new RegExp(SCORE_REGEX_SOURCE);
const COST_RE = new RegExp(COST_REGEX_SOURCE);
const ESC = String.fromCharCode(0x1b);

test("failure shape for strings missing both Quality and Cost", () => {
  fc.assert(
    fc.property(fc.string(), (s) => {
      fc.pre(!SCORE_RE.test(s) && !COST_RE.test(s));
      const r = parse(s);
      assert.equal(r.score_internal, null);
      assert.equal(r.display_10, null);
      assert.equal(r.cost_usd, null);
      assert.equal(r.error, "unexpected_response_format");
      assert.equal(typeof r.raw, "string");
    }),
    { numRuns: 500 },
  );
});

test("failure shape when only one of Score/Cost is present", () => {
  const onlyScore = "Quality: 8.5/10 but no cost line here";
  const r1 = parse(onlyScore);
  assert.equal(r1.error, "unexpected_response_format");
  assert.equal(r1.score_internal, null);

  const onlyCost = "Cost: $0.42 but no quality line";
  const r2 = parse(onlyCost);
  assert.equal(r2.error, "unexpected_response_format");
  assert.equal(r2.cost_usd, null);
});

test("parse failure message constant matches SKILL.md spec", () => {
  assert.equal(
    PARSE_FAILURE_MESSAGE,
    "[MoVP] Auto-review completed; cost/score unavailable (unexpected response format). Run /movp:status to verify backend.",
  );
});

test("valid Quality X/10 with X in [0,10] extracts display_10 and normalizes to score_internal = X/10", () => {
  fc.assert(
    fc.property(
      fc.double({ min: 0, max: 10, noNaN: true }),
      fc.double({ min: 0, max: 100, noNaN: true }),
      (score, cost) => {
        const scoreStr = score.toFixed(2);
        const costStr = cost.toFixed(2);
        const body = `Header\nQuality: ${scoreStr}/10\nCost: $${costStr}\nFooter`;
        const r = parse(body);
        assert.equal(r.error, undefined, `expected success, got ${JSON.stringify(r)}`);
        assert.equal(r.display_10, Number.parseFloat(scoreStr));
        assert.ok(
          Math.abs(r.score_internal - r.display_10 / 10) < 1e-9,
          `score_internal ${r.score_internal} != display_10/10 ${r.display_10 / 10}`,
        );
        assert.ok(
          r.score_internal >= 0 && r.score_internal <= 1,
          `score_internal ${r.score_internal} must be in [0,1]`,
        );
      },
    ),
    { numRuns: 500 },
  );
});

test("display_10 outside [0,10] fails — no clamping", () => {
  const overRange = "Quality: 15/10\nCost: $0.50";
  const r = parse(overRange);
  assert.equal(r.error, "unexpected_response_format", "display_10 > 10 must be rejected, not clamped");
  assert.equal(r.score_internal, null);
});

test("surrounding whitespace, newlines, and ANSI escapes do not alter capture", () => {
  // Invariant scope: noise *around* the complete Quality:X/10 and Cost:$X
  // patterns does not break the match. ANSI codes injected *inside* those
  // patterns legitimately change the regex match and are out of scope.
  const cases = [
    "Quality:    8.5   /   10\n\nCost: $0.42\n",
    `${ESC}[1mprefix${ESC}[0m Quality: 8.5/10 ${ESC}[31mmid${ESC}[0m Cost: $0.42 ${ESC}[0msuffix`,
    "\n\n\nQuality: 8.5/10\n\n\n\nCost: $0.42\n\n\n",
    "before\tQuality: 8.5/10\tmiddle\tCost: $0.42\tafter",
  ];
  for (const body of cases) {
    const r = parse(body);
    assert.equal(r.error, undefined, `failed on: ${JSON.stringify(body)}`);
    assert.equal(r.display_10, 8.5);
    assert.equal(r.cost_usd, 0.42);
  }
});

test("round-trip invariant: backend score -> display text -> parse -> score_internal within ±0.05", () => {
  fc.assert(
    fc.property(
      fc.double({ min: 0, max: 1, noNaN: true }),
      fc.double({ min: 0, max: 100, noNaN: true }),
      (score_internal, cost_usd) => {
        const body = toDisplayText({ score_internal, cost_usd });
        const r = parse(body);
        assert.equal(r.error, undefined, `round-trip failed: ${body} -> ${JSON.stringify(r)}`);
        assert.ok(
          Math.abs(r.score_internal - score_internal) <= 0.05,
          `round-trip drift: input ${score_internal}, got ${r.score_internal}`,
        );
      },
    ),
    { numRuns: 500 },
  );
});

test("non-string input returns failure", () => {
  for (const v of [null, undefined, 123, {}, [], true]) {
    const r = parse(v);
    assert.equal(r.error, "unexpected_response_format");
    assert.equal(r.score_internal, null);
  }
});

test("raw field is present and bounded", () => {
  const huge = "x".repeat(10_000) + "\nQuality: 8/10\nCost: $0.10\n";
  const r = parse(huge);
  assert.equal(typeof r.raw, "string");
  assert.ok(r.raw.length <= 500, `raw length ${r.raw.length} exceeds 500`);
});
