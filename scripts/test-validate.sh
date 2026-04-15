#!/usr/bin/env bash
# test-validate.sh — Fixture-based regression tests for validate.sh
#
# Creates minimal git repo fixtures in temp dirs, runs validate.sh against them,
# and asserts expected exit codes and output messages.
#
# Usage: bash scripts/test-validate.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATE="$REPO_ROOT/scripts/validate.sh"

PASS=0
FAIL=0
TMPDIR_LIST=()

cleanup() {
  for d in "${TMPDIR_LIST[@]+"${TMPDIR_LIST[@]}"}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

# ── Assertions ────────────────────────────────────────────────────────────────

assert_exit_code() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "[PASS] $name (exit $actual)"
    PASS=$((PASS+1))
  else
    echo "[FAIL] $name — expected exit $expected, got $actual"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local name="$1" expected="$2" output="$3"
  if echo "$output" | grep -qF "$expected"; then
    echo "[PASS] $name (output contains '$expected')"
    PASS=$((PASS+1))
  else
    echo "[FAIL] $name — expected output to contain: $expected"
    echo "       Output was: $(echo "$output" | tail -5)"
    FAIL=$((FAIL+1))
  fi
}

assert_not_contains() {
  local name="$1" unexpected="$2" output="$3"
  if ! echo "$output" | grep -qF "$unexpected"; then
    echo "[PASS] $name (output does not contain '$unexpected')"
    PASS=$((PASS+1))
  else
    echo "[FAIL] $name — output should NOT contain: $unexpected"
    FAIL=$((FAIL+1))
  fi
}

# ── Fixture builder ───────────────────────────────────────────────────────────

VALID_PLUGIN_JSON='{
  "name": "movp",
  "version": "1.0.0",
  "description": "Test plugin",
  "author": { "name": "MoVP" },
  "repository": "https://github.com/test/test",
  "license": "MIT"
}'

VALID_SKILL_MD='---
name: test-skill
description: Use when testing the validator fixture
---

# Test Skill

Test content.
'

VALID_COMMAND_MD='---
description: Test command
---

# Test command
'

VALID_FORMULA_RB='class Movp < Formula
  desc "MoVP control plane plugins for AI coding tools"
  homepage "https://github.com/test/test"
  url "https://github.com/test/test/archive/v1.0.0.tar.gz"
  sha256 "PLACEHOLDER_UPDATE_AFTER_TAGGING"
  license "MIT"
end'

VALID_MARKETPLACE_JSON='{
  "name": "movp",
  "version": "1.0.0",
  "plugins": [
    {
      "name": "movp",
      "source": "./claude-plugin",
      "description": "Test",
      "version": "1.0.0",
      "author": { "name": "MoVP" }
    }
  ]
}'

build_fixture() {
  local dir
  dir=$(mktemp -d)
  TMPDIR_LIST+=("$dir")

  # Initialize git repo
  git -C "$dir" init -q
  git -C "$dir" config user.email "fixture@test.local"
  git -C "$dir" config user.name "Fixture"

  # scripts/ — symlink validate.sh so CHECK 8 finds an executable script
  mkdir -p "$dir/scripts"
  ln -sf "$VALIDATE" "$dir/scripts/validate.sh"
  # Minimal allowlist with proper format (# owner: @handle — reason: ...)
  cat > "$dir/scripts/SECRET_SCAN_ALLOWLIST" <<'EOF'
# owner: @pipeline — reason: this file is the allowlist itself; entries are path strings not credentials
scripts/SECRET_SCAN_ALLOWLIST
# owner: @pipeline — reason: validate.sh contains literal scan pattern strings used in grep calls
scripts/validate.sh
EOF

  # marketplace.json
  mkdir -p "$dir/.claude-plugin"
  echo "$VALID_MARKETPLACE_JSON" > "$dir/.claude-plugin/marketplace.json"

  # Three plugins
  for platform in claude cursor codex; do
    local pdir="$dir/${platform}-plugin"
    mkdir -p "$pdir/.${platform}-plugin"
    mkdir -p "$pdir/skills/movp-review"
    mkdir -p "$pdir/skills/movp-control-plane"
    echo "$VALID_PLUGIN_JSON" > "$pdir/.${platform}-plugin/plugin.json"
    echo "$VALID_SKILL_MD" > "$pdir/skills/movp-review/SKILL.md"
    echo "$VALID_SKILL_MD" > "$pdir/skills/movp-control-plane/SKILL.md"
    echo '{"mcpServers": {}}' > "$pdir/.mcp.json.example"
  done

  # 7 command files in claude-plugin
  mkdir -p "$dir/claude-plugin/commands"
  for cmd in review review-status review-stop review-summarize optimize status settings; do
    echo "$VALID_COMMAND_MD" > "$dir/claude-plugin/commands/$cmd.md"
  done

  # Homebrew formula template (sha256 stays PLACEHOLDER — Option B: tap owns truth)
  mkdir -p "$dir/scripts/homebrew"
  echo "$VALID_FORMULA_RB" > "$dir/scripts/homebrew/movp.rb"

  # git add + commit so git ls-files works
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fixture"

  echo "$dir"
}

run_validate() {
  local dir="$1"
  shift
  MOVP_VALIDATE_ROOT="$dir" bash "$VALIDATE" "$@" 2>&1 || true
}

run_validate_exit() {
  local dir="$1"
  shift
  MOVP_VALIDATE_ROOT="$dir" bash "$VALIDATE" "$@" 2>&1; echo "EXIT:$?"
}

# ── TEST 1: Valid fixture passes cleanly ──────────────────────────────────────

echo ""
echo "=== TEST 1: Valid fixture ==="
FIXTURE=$(build_fixture)
output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "valid fixture" 0 "$exit_code"
assert_contains "valid fixture: all pass message" "checks passed" "$output_clean"
assert_not_contains "valid fixture: no FAIL lines" "[FAIL]" "$output_clean"

# ── TEST 2: CHECK 2 — missing author.name ─────────────────────────────────────

echo ""
echo "=== TEST 2: CHECK 2 — missing author.name ==="
FIXTURE=$(build_fixture)
# Remove author from claude-plugin
python3 -c "
import json
path = '$FIXTURE/claude-plugin/.claude-plugin/plugin.json'
d = json.load(open(path))
del d['author']
json.dump(d, open(path,'w'), indent=2)
"
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "remove author"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "CHECK 2 missing author.name: exits 1" 1 "$exit_code"
assert_contains "CHECK 2 missing author.name: message" "author.name" "$output_clean"

# ── TEST 3: CHECK 2 — non-semver version ─────────────────────────────────────

echo ""
echo "=== TEST 3: CHECK 2 — prerelease version ==="
FIXTURE=$(build_fixture)
for platform in claude cursor codex; do
  python3 -c "
import json
path = '$FIXTURE/${platform}-plugin/.${platform}-plugin/plugin.json'
d = json.load(open(path))
d['version'] = '1.0.0-beta'
json.dump(d, open(path,'w'), indent=2)
"
done
# Also update marketplace to avoid version skew masking the schema error
python3 -c "
import json
path = '$FIXTURE/.claude-plugin/marketplace.json'
d = json.load(open(path))
d['version'] = '1.0.0-beta'
for p in d.get('plugins',[]): p['version'] = '1.0.0-beta'
json.dump(d, open(path,'w'), indent=2)
"
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "bad semver"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "CHECK 2 bad semver: exits 1" 1 "$exit_code"
assert_contains "CHECK 2 bad semver: message" "not stable semver" "$output_clean"

# ── TEST 4: CHECK 3 — version skew ───────────────────────────────────────────

echo ""
echo "=== TEST 4: CHECK 3 — version skew ==="
FIXTURE=$(build_fixture)
python3 -c "
import json
path = '$FIXTURE/cursor-plugin/.cursor-plugin/plugin.json'
d = json.load(open(path))
d['version'] = '0.9.0'
json.dump(d, open(path,'w'), indent=2)
"
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "version skew"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "CHECK 3 version skew: exits 1" 1 "$exit_code"
assert_contains "CHECK 3 version skew: message" "Version skew" "$output_clean"

# ── TEST 5: CHECK 1 — SKILL.md sync drift ────────────────────────────────────

echo ""
echo "=== TEST 5: CHECK 1 — SKILL.md sync drift ==="
FIXTURE=$(build_fixture)
echo "extra line" >> "$FIXTURE/cursor-plugin/skills/movp-review/SKILL.md"
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "drift"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "CHECK 1 drift: exits 1" 1 "$exit_code"
assert_contains "CHECK 1 drift: message" "SKILL.md sync" "$output_clean"

# ── TEST 6: CHECK 9 — credential detected ────────────────────────────────────

echo ""
echo "=== TEST 6: CHECK 9 — credential in file ==="
FIXTURE=$(build_fixture)
echo 'WORKDESK_API_KEY=abc123realkey' > "$FIXTURE/leaked.txt"
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "leak"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "CHECK 9 credential: exits 1" 1 "$exit_code"
assert_contains "CHECK 9 credential: message" "Credential leak" "$output_clean"
assert_contains "CHECK 9 credential: names file" "leaked.txt" "$output_clean"

# ── TEST 7: CHECK 9 — allowlist suppresses false positive ────────────────────

echo ""
echo "=== TEST 7: CHECK 9 — allowlisted file skipped ==="
FIXTURE=$(build_fixture)
mkdir -p "$FIXTURE/docs"
echo 'WORKDESK_API_KEY=abc123realkey' > "$FIXTURE/docs/example.txt"
cat >> "$FIXTURE/scripts/SECRET_SCAN_ALLOWLIST" <<'EOF'
# owner: @test — reason: example tokens only, not real credentials
docs/example.txt
EOF
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "allowlisted"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "CHECK 9 allowlisted: exits 0" 0 "$exit_code"
assert_not_contains "CHECK 9 allowlisted: no leak message" "Credential leak" "$output_clean"

# ── TEST 8: Allowlist governance — entry missing justification ────────────────

echo ""
echo "=== TEST 8: Allowlist governance — missing comment ==="
FIXTURE=$(build_fixture)
# Add an entry without a comment above it
printf '\ndocs/undocumented.txt\n' >> "$FIXTURE/scripts/SECRET_SCAN_ALLOWLIST"
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "bad allowlist"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "allowlist governance: exits 1" 1 "$exit_code"
assert_contains "allowlist governance: justification message" "justification comment" "$output_clean"

# ── TEST 9: CHECK 7 — missing plugin top-level directory ─────────────────────

echo ""
echo "=== TEST 9: CHECK 7 — missing plugin directory ==="
FIXTURE=$(build_fixture)
rm -rf "$FIXTURE/cursor-plugin"
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "remove cursor-plugin"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "CHECK 7 missing plugin dir: exits 1" 1 "$exit_code"
assert_contains "CHECK 7 missing plugin dir: names platform" "cursor-plugin" "$output_clean"
assert_contains "CHECK 7 missing plugin dir: says missing directory" "missing directory" "$output_clean"

# ── TEST 10: CHECK 7 — missing skills directory ───────────────────────────────

echo ""
echo "=== TEST 10: CHECK 7 — missing skills directory ==="
FIXTURE=$(build_fixture)
rm -rf "$FIXTURE/claude-plugin/skills"
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "remove skills dir"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "CHECK 7 missing skills dir: exits 1" 1 "$exit_code"
assert_contains "CHECK 7 missing skills dir: names platform" "claude-plugin" "$output_clean"
assert_contains "CHECK 7 missing skills dir: names dir" "skills" "$output_clean"

# ── TEST 11: CHECK 10 — formula url/homepage points to wrong repo ─────────────

echo ""
echo "=== TEST 11: CHECK 10 — formula references wrong repo ==="
FIXTURE=$(build_fixture)
cat > "$FIXTURE/scripts/homebrew/movp.rb" <<'EOF'
class Movp < Formula
  desc "MoVP control plane plugins for AI coding tools"
  homepage "https://github.com/wrong-org/wrong-repo"
  url "https://github.com/wrong-org/wrong-repo/archive/v1.0.0.tar.gz"
  sha256 "PLACEHOLDER_UPDATE_AFTER_TAGGING"
  license "MIT"
end
EOF
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "wrong repo"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "CHECK 10 wrong repo: exits 1" 1 "$exit_code"
assert_contains "CHECK 10 wrong repo: url message" "url does not reference" "$output_clean"

# ── TEST 12: CHECK 10 — formula url version skew ──────────────────────────────

echo ""
echo "=== TEST 12: CHECK 10 — formula version skew ==="
FIXTURE=$(build_fixture)
cat > "$FIXTURE/scripts/homebrew/movp.rb" <<'EOF'
class Movp < Formula
  desc "MoVP control plane plugins for AI coding tools"
  homepage "https://github.com/test/test"
  url "https://github.com/test/test/archive/v0.9.0.tar.gz"
  sha256 "PLACEHOLDER_UPDATE_AFTER_TAGGING"
  license "MIT"
end
EOF
git -C "$FIXTURE" add -A && git -C "$FIXTURE" commit -q -m "version skew"

output=$(run_validate_exit "$FIXTURE")
exit_code=$(echo "$output" | grep '^EXIT:' | sed 's/EXIT://')
output_clean=$(echo "$output" | grep -v '^EXIT:')

assert_exit_code "CHECK 10 version skew: exits 1" 1 "$exit_code"
assert_contains "CHECK 10 version skew: message" "url version" "$output_clean"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo "All $TOTAL fixture tests passed."
  exit 0
else
  echo "$FAIL of $TOTAL fixture tests failed."
  exit 1
fi
