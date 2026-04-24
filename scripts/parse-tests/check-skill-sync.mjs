#!/usr/bin/env node
// Verifies that the Score/Cost regex strings quoted in every review-advisor
// SKILL.md match the canonical constants exported from parser.mjs byte-for-byte.
// Exits non-zero on any divergence. Fails hard and loud.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { SCORE_REGEX_SOURCE, COST_REGEX_SOURCE, PARSE_FAILURE_MESSAGE } from "./parser.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..", "..");

const SKILLS = [
  "claude-plugin/skills/review-advisor/SKILL.md",
  "codex-plugin/skills/review-advisor/SKILL.md",
  "cursor-plugin/skills/review-advisor/SKILL.md",
];

// parser.mjs exports are JS string values (single backslashes once evaluated).
// SKILL.md quotes them between single backticks with single backslashes.
// The two must match exactly.
const EXPECTED = {
  score: SCORE_REGEX_SOURCE,
  cost: COST_REGEX_SOURCE,
  failureMessage: PARSE_FAILURE_MESSAGE,
};

// Match `- **Score:** regex \`<pattern>\` ...` and `- **Cost:** regex \`<pattern>\` ...`
const SCORE_LINE_RE = /^-\s+\*\*Score:\*\*\s+regex\s+`([^`]+)`/m;
const COST_LINE_RE = /^-\s+\*\*Cost:\*\*\s+regex\s+`([^`]+)`/m;

function extract(skillText, label, re) {
  const m = skillText.match(re);
  if (!m) throw new Error(`could not find ${label} regex line`);
  return m[1];
}

function findFailureMessage(skillText) {
  // The failure message appears in a fenced code block following the
  // "Parse failure policy" bullet. Find by exact-substring membership; any
  // alteration, even whitespace, counts as divergence.
  if (!skillText.includes(EXPECTED.failureMessage)) {
    throw new Error("canonical PARSE_FAILURE_MESSAGE not found verbatim in SKILL.md");
  }
}

let failed = 0;
const results = [];

for (const rel of SKILLS) {
  const path = resolve(REPO_ROOT, rel);
  try {
    const text = readFileSync(path, "utf8");
    const score = extract(text, "Score", SCORE_LINE_RE);
    const cost = extract(text, "Cost", COST_LINE_RE);
    findFailureMessage(text);

    const errors = [];
    if (score !== EXPECTED.score) {
      errors.push(`  Score: SKILL.md has  ${JSON.stringify(score)}\n         parser.mjs has ${JSON.stringify(EXPECTED.score)}`);
    }
    if (cost !== EXPECTED.cost) {
      errors.push(`  Cost:  SKILL.md has  ${JSON.stringify(cost)}\n         parser.mjs has ${JSON.stringify(EXPECTED.cost)}`);
    }

    if (errors.length > 0) {
      failed += 1;
      results.push(`FAIL ${rel}\n${errors.join("\n")}`);
    } else {
      results.push(`ok   ${rel}`);
    }
  } catch (err) {
    failed += 1;
    results.push(`FAIL ${rel}: ${err.message}`);
  }
}

for (const line of results) console.log(line);

if (failed > 0) {
  console.error(`\n${failed} SKILL.md file(s) out of sync with parser.mjs.`);
  console.error("Canonical source of truth: scripts/parse-tests/parser.mjs");
  console.error("Fix: edit one side so both match, or update both deliberately.");
  process.exit(1);
}

console.log(`\nAll ${SKILLS.length} SKILL.md files in sync with parser.mjs.`);
