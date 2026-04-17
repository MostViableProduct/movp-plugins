#!/usr/bin/env bash
# validate.sh — Pre-publish validation for movp-plugins
# Exits 1 if any check fails.
# Usage: bash scripts/validate.sh [--json]
# In CI: set GITHUB_STEP_SUMMARY to get a Markdown summary written to the Actions UI.

set -euo pipefail

# MOVP_VALIDATE_ROOT overrides working directory — used by test-validate.sh fixtures
REPO_ROOT="${MOVP_VALIDATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_ROOT"

JSON_MODE=false
if [[ "${1:-}" == "--json" ]]; then
  JSON_MODE=true
fi

SKILLS=(review-advisor movp-control-plane)
REQUIRED_COMMANDS=(review.md review-status.md review-stop.md review-summarize.md optimize.md status.md settings.md auto-review.md doctor.md)
ALLOWLIST_FILE="scripts/SECRET_SCAN_ALLOWLIST"

PASS=0
FAIL=0
FAILURES=()
RESULTS=()  # array of "check|status|detail" for JSON/summary output

# ── helpers ──────────────────────────────────────────────────────────────────

pass() {
  local check="$1"
  PASS=$((PASS + 1))
  echo "[PASS] $check"
  RESULTS+=("$check|pass|")
}

fail() {
  local check="$1"
  local msg="$2"
  local fix="${3:-}"
  FAIL=$((FAIL + 1))
  echo "[FAIL] $msg"
  [[ -n "$fix" ]] && echo "       $fix"
  FAILURES+=("$msg")
  RESULTS+=("$check|fail|$msg")
}

is_allowlisted() {
  local file="$1"
  [[ ! -f "$ALLOWLIST_FILE" ]] && return 1
  while IFS= read -r prefix || [[ -n "$prefix" ]]; do
    [[ -z "$prefix" || "$prefix" == \#* ]] && continue
    [[ "$file" == $prefix* ]] && return 0
  done < "$ALLOWLIST_FILE"
  return 1
}

# ── CHECK 1: SKILL.md sync ────────────────────────────────────────────────────

for skill in "${SKILLS[@]}"; do
  for platform in cursor codex; do
    src="claude-plugin/skills/$skill/SKILL.md"
    dst="${platform}-plugin/skills/$skill/SKILL.md"
    if ! diff -q "$src" "$dst" > /dev/null 2>&1; then
      fail "SKILL sync: $skill claude vs $platform" \
        "SKILL.md sync: $skill differs between claude and $platform" \
        "Fix: copy changes to all three platforms, then re-run validate.sh
       Diff: diff $src $dst"
    else
      pass "SKILL sync: $skill claude vs $platform"
    fi
  done
done

# Also verify manifest.json is in sync across platforms
for platform in cursor codex; do
  src="claude-plugin/manifest.json"
  dst="${platform}-plugin/manifest.json"
  if [[ ! -f "$src" ]]; then
    fail "manifest.json sync: claude vs $platform" \
      "$src not found" \
      "Fix: create $src with pinned_mcp_server_version, tools, resources"
  elif [[ ! -f "$dst" ]]; then
    fail "manifest.json sync: claude vs $platform" \
      "$dst not found" \
      "Fix: copy $src to $dst"
  elif ! diff -q "$src" "$dst" > /dev/null 2>&1; then
    fail "manifest.json sync: claude vs $platform" \
      "manifest.json differs between claude and $platform" \
      "Fix: copy $src to $dst
       Diff: diff $src $dst"
  else
    pass "manifest.json sync: claude vs $platform"
  fi
done

# ── CHECK 2: plugin.json parse + schema ───────────────────────────────────────

PLUGIN_JSON_FILES=(
  "claude-plugin/.claude-plugin/plugin.json"
  "cursor-plugin/.cursor-plugin/plugin.json"
  "codex-plugin/.codex-plugin/plugin.json"
)
REQUIRED_FIELDS=(name version description repository license)
SEMVER_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

PLUGIN_VERSION=""
SCHEMA_OK=true

for f in "${PLUGIN_JSON_FILES[@]}"; do
  # Valid JSON
  if ! python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null; then
    fail "plugin.json schema: $f" "$f: invalid JSON" \
      "Fix: run 'python3 -m json.tool $f' to see the parse error"
    SCHEMA_OK=false
    continue
  fi

  # Required fields (including nested author.name) + semver — single python3 call per file
  SCHEMA_ERRORS=$(python3 - "$f" <<'PYEOF'
import json, re, sys
path = sys.argv[1]
d = json.load(open(path))
for field in ['name', 'version', 'description', 'repository', 'license']:
    if not d.get(field):
        print(f'MISSING:{field}')
if not (d.get('author') or {}).get('name'):
    print('MISSING:author.name')
ver = d.get('version', '')
if not re.match(r'^[0-9]+\.[0-9]+\.[0-9]+$', ver):
    print(f'BAD_VERSION:{ver}')
PYEOF
)

  if [[ -n "$SCHEMA_ERRORS" ]]; then
    while IFS= read -r issue; do
      [[ -z "$issue" ]] && continue
      if [[ "$issue" == MISSING:* ]]; then
        field="${issue#MISSING:}"
        fail "plugin.json schema: $f" "$f: missing required field '$field'" \
          "Fix: add the '$field' field to $f"
        SCHEMA_OK=false
      elif [[ "$issue" == BAD_VERSION:* ]]; then
        ver="${issue#BAD_VERSION:}"
        fail "plugin.json schema: $f" "$f: version '$ver' is not stable semver (x.y.z)" \
          "Fix: use a version like 1.2.0 — no prerelease suffixes in released plugins"
        SCHEMA_OK=false
      fi
    done <<< "$SCHEMA_ERRORS"
  fi

  ver=$(python3 -c "import json; print(json.load(open('$f')).get('version',''))" 2>/dev/null)
  [[ -z "$PLUGIN_VERSION" ]] && PLUGIN_VERSION="$ver"
done

$SCHEMA_OK && pass "plugin.json schema (all three)"

# ── CHECK 3: version consistency ──────────────────────────────────────────────

VERSIONS=()
for f in "${PLUGIN_JSON_FILES[@]}"; do
  v=$(python3 -c "import json; print(json.load(open('$f')).get('version',''))" 2>/dev/null || echo "")
  VERSIONS+=("$v")
done

if [[ "${VERSIONS[0]}" == "${VERSIONS[1]}" && "${VERSIONS[1]}" == "${VERSIONS[2]}" ]]; then
  pass "plugin.json version consistency"
else
  CLAUDE_V="${VERSIONS[0]}" CURSOR_V="${VERSIONS[1]}" CODEX_V="${VERSIONS[2]}"
  fail "plugin.json version consistency" \
    "Version skew: claude=${CLAUDE_V} cursor=${CURSOR_V} codex=${CODEX_V}" \
    "Fix: run ./scripts/release.sh --dry-run <version> to bump all together"
fi

# ── CHECK 4: marketplace.json version ─────────────────────────────────────────

MKT_FILE=".claude-plugin/marketplace.json"
if [[ -f "$MKT_FILE" ]]; then
  MKT_TOP=$(python3 -c "import json; print(json.load(open('$MKT_FILE')).get('version',''))" 2>/dev/null)
  MKT_PLUGIN=$(python3 -c "import json; d=json.load(open('$MKT_FILE')); print(d['plugins'][0].get('version','') if d.get('plugins') else '')" 2>/dev/null)

  MKT_OK=true
  if [[ "$MKT_TOP" != "$PLUGIN_VERSION" ]]; then
    fail "marketplace.json version" \
      "marketplace.json top-level version ($MKT_TOP) != plugin version ($PLUGIN_VERSION)" \
      "Fix: update \"version\" in $MKT_FILE"
    MKT_OK=false
  fi
  if [[ -n "$MKT_PLUGIN" && "$MKT_PLUGIN" != "$PLUGIN_VERSION" ]]; then
    fail "marketplace.json plugin version" \
      "marketplace.json plugins[0].version ($MKT_PLUGIN) != plugin version ($PLUGIN_VERSION)" \
      "Fix: update plugins[0].version in $MKT_FILE"
    MKT_OK=false
  fi
  $MKT_OK && pass "marketplace.json version"
else
  fail "marketplace.json version" "$MKT_FILE not found" "Fix: ensure $MKT_FILE exists"
fi

# ── CHECK 5: SKILL.md frontmatter ─────────────────────────────────────────────

FRONTMATTER_OK=true
for platform in claude cursor codex; do
  for skill in "${SKILLS[@]}"; do
    f="${platform}-plugin/skills/$skill/SKILL.md"
    [[ ! -f "$f" ]] && continue

    content=$(cat "$f")
    if ! echo "$content" | grep -q '^name:'; then
      fail "SKILL.md frontmatter: $f" "$f: missing 'name' in frontmatter" \
        "Fix: add 'name: $skill' to the YAML frontmatter block"
      FRONTMATTER_OK=false
    fi
    if ! echo "$content" | grep -q '^description:'; then
      fail "SKILL.md frontmatter: $f" "$f: missing 'description' in frontmatter" \
        "Fix: add a 'description:' field to the YAML frontmatter block"
      FRONTMATTER_OK=false
    fi

    # Description length check — extract between first --- markers
    desc_len=$(python3 -c "
import sys
content = open('$f').read()
parts = content.split('---')
if len(parts) >= 3:
    fm = parts[1]
    for line in fm.split('\n'):
        if line.startswith('description:'):
            # Handle inline and multi-line (>) descriptions
            rest = line[len('description:'):].strip()
            if rest.startswith('>'):
                # Multi-line: collect continuation lines
                idx = fm.split('\n').index(line)
                lines = fm.split('\n')[idx+1:]
                text = ' '.join(l.strip() for l in lines if l.startswith(' '))
            else:
                text = rest
            print(len(text))
            sys.exit()
print(0)
" 2>/dev/null || echo 0)
    if [[ "$desc_len" -gt 1024 ]]; then
      fail "SKILL.md frontmatter: $f" \
        "$f: description exceeds 1024 chars ($desc_len)" \
        "Fix: shorten the 'description' field in the frontmatter"
      FRONTMATTER_OK=false
    fi
  done
done
$FRONTMATTER_OK && pass "SKILL.md frontmatter"

# ── CHECK 6: command file completeness ────────────────────────────────────────

CMD_DIR="claude-plugin/commands"
CMD_OK=true
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  f="$CMD_DIR/$cmd"
  if [[ ! -f "$f" ]]; then
    fail "command files: $cmd" \
      "claude-plugin/commands/: missing file '$cmd'" \
      "Fix: create $f with valid YAML frontmatter"
    CMD_OK=false
  else
    # Check for YAML frontmatter (must start with ---)
    first_line=$(head -1 "$f")
    if [[ "$first_line" != "---" ]]; then
      fail "command files: $cmd frontmatter" \
        "$f: no YAML frontmatter found (file must start with '---')" \
        "Fix: add YAML frontmatter with at minimum a 'description' field"
      CMD_OK=false
    fi
  fi
done
# Check for unexpected extra files
actual_count=$(ls "$CMD_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
expected_count="${#REQUIRED_COMMANDS[@]}"
if [[ "$actual_count" -gt "$expected_count" ]]; then
  extra=$(comm -23 <(ls "$CMD_DIR"/*.md | xargs -n1 basename | sort) <(printf '%s\n' "${REQUIRED_COMMANDS[@]}" | sort))
  fail "command files: unexpected" \
    "claude-plugin/commands/: unexpected file(s): $extra" \
    "Fix: add new command files to REQUIRED_COMMANDS in validate.sh"
  CMD_OK=false
fi
$CMD_OK && pass "command file completeness"

# ── CHECK 7: required directories and files per plugin ───────────────────────
# Directory checks run first so a missing dir produces a clear "missing directory"
# error rather than cascading "file not found" errors for every file inside it.

FILES_OK=true
for platform in claude cursor codex; do
  required_dirs=(
    "${platform}-plugin"
    "${platform}-plugin/.${platform}-plugin"
    "${platform}-plugin/skills"
    "${platform}-plugin/skills/review-advisor"
    "${platform}-plugin/skills/movp-control-plane"
  )
  [[ "$platform" == "claude" ]] && required_dirs+=("claude-plugin/commands")

  for d in "${required_dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
      fail "required files: $platform" \
        "${platform}-plugin: missing directory '$d'" \
        "Fix: create $d/"
      FILES_OK=false
    fi
  done

  required_files=(
    "${platform}-plugin/.${platform}-plugin/plugin.json"
    "${platform}-plugin/skills/review-advisor/SKILL.md"
    "${platform}-plugin/skills/movp-control-plane/SKILL.md"
    "${platform}-plugin/manifest.json"
  )
  for f in "${required_files[@]}"; do
    if [[ ! -f "$f" ]]; then
      fail "required files: $platform" \
        "${platform}-plugin: missing $f" \
        "Fix: create $f"
      FILES_OK=false
    fi
  done
done
$FILES_OK && pass "required files per plugin"

# ── CHECK 8: executable bits and shebangs ─────────────────────────────────────

EXEC_OK=true
EXEC_SCRIPTS=(scripts/validate.sh scripts/install.sh)
[[ -f scripts/release.sh ]] && EXEC_SCRIPTS+=(scripts/release.sh)
[[ -f scripts/check-repo-policy.sh ]] && EXEC_SCRIPTS+=(scripts/check-repo-policy.sh)

for f in "${EXEC_SCRIPTS[@]}"; do
  [[ ! -f "$f" ]] && continue
  if [[ ! -x "$f" ]]; then
    fail "executable bits: $f" \
      "$f is not executable" \
      "Fix: chmod +x $f"
    EXEC_OK=false
  fi
  first_line=$(head -1 "$f")
  if [[ "$first_line" != "#!/usr/bin/env bash" && "$first_line" != "#!/bin/bash" ]]; then
    fail "shebang: $f" \
      "$f: missing or incorrect shebang (found: '$first_line')" \
      "Fix: first line must be '#!/usr/bin/env bash'"
    EXEC_OK=false
  fi
done
$EXEC_OK && pass "executable bits and shebangs"

# ── CHECK 9: secret scan ──────────────────────────────────────────────────────

SECRET_PATTERNS=(
  'WORKDESK_API_KEY=[^$][^{]'
  'ghp_[A-Za-z0-9]{36}'
  'sk_live_[A-Za-z0-9]+'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
  'ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
)

SECRET_OK=true

# Validate allowlist format before scanning
# Required justification format: # owner: @handle — reason: <why safe>
# Any preceding comment line not matching this format is rejected so that
# placeholder comments (# TODO, # temp) cannot silently bypass the check.
JUSTIFICATION_PATTERN='^# owner: @[A-Za-z0-9_-].* reason: .+'
if [[ -f "$ALLOWLIST_FILE" ]]; then
  prev_comment=""
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    [[ -z "$line" ]] && prev_comment="" && continue
    if [[ "$line" == \#* ]]; then
      prev_comment="$line"
      continue
    fi
    # Path entry — preceding comment must match the justification format
    if [[ -z "$prev_comment" ]]; then
      fail "allowlist governance: $ALLOWLIST_FILE:$lineno" \
        "$ALLOWLIST_FILE line $lineno: '$line' has no justification comment above it" \
        "Fix: add '# owner: @you — reason: why this is safe' on the line before '$line'"
      SECRET_OK=false
    elif ! echo "$prev_comment" | grep -qE "$JUSTIFICATION_PATTERN"; then
      fail "allowlist governance: $ALLOWLIST_FILE:$lineno" \
        "$ALLOWLIST_FILE line $lineno: comment '$prev_comment' does not match required format" \
        "Fix: use '# owner: @handle — reason: <why safe>' (e.g. '# owner: @you — reason: example tokens only')"
      SECRET_OK=false
    fi
    # Reject broad patterns (directory prefixes, *.ext wildcards)
    if [[ "$line" == */ || "$line" == \*.* ]]; then
      fail "allowlist governance: $ALLOWLIST_FILE:$lineno" \
        "$ALLOWLIST_FILE line $lineno: '$line' is a broad wildcard — use a specific file path" \
        "Fix: allowlist specific files (e.g. docs/example.md), not directories or glob patterns"
      SECRET_OK=false
    fi
    prev_comment=""
  done < "$ALLOWLIST_FILE"
fi

# Build list of files to scan (non-gitignored, non-.example)
SCAN_FILES=()
while IFS= read -r f; do
  SCAN_FILES+=("$f")
done < <(git ls-files --cached --others --exclude-standard | grep -v '\.example$' | grep -v '\.gitignore$')

for f in "${SCAN_FILES[@]}"; do
  [[ ! -f "$f" ]] && continue
  is_allowlisted "$f" && continue

  # Collect all matching patterns for this file (one fail per file, all patterns listed)
  MATCHED=()
  for pat in "${SECRET_PATTERNS[@]}"; do
    grep -qE "$pat" "$f" 2>/dev/null && MATCHED+=("$pat")
  done

  if [[ ${#MATCHED[@]} -gt 0 ]]; then
    pattern_list=$(printf "'%s' " "${MATCHED[@]}")
    fail "secret scan: $f" \
      "Credential leak: $f matches ${#MATCHED[@]} secret pattern(s): $pattern_list" \
      "Fix: remove credential from $f; if intentional (docs/examples), add '$f' to $ALLOWLIST_FILE"
    SECRET_OK=false
  fi
done
$SECRET_OK && pass "secret scan"

# ── CHECK 10: Homebrew formula consistency ────────────────────────────────────
# Verifies scripts/homebrew/movp.rb url and homepage reference the same GitHub
# owner/repo as plugin.json's 'repository' field, and the url version matches
# the current plugin version.
# sha256 is NOT checked — the local file is a non-authoritative template;
# the tap repo (MostViableProduct/homebrew-movp) owns the published formula.

FORMULA_FILE="scripts/homebrew/movp.rb"
BREW_OK=true

if [[ ! -f "$FORMULA_FILE" ]]; then
  fail "homebrew formula" \
    "$FORMULA_FILE not found" \
    "Fix: ensure $FORMULA_FILE exists (sha256 PLACEHOLDER is fine between releases)"
  BREW_OK=false
else
  # Extract expected owner/repo from plugin.json's repository field
  EXPECTED_SLUG=$(python3 -c "
import json, re
d = json.load(open('claude-plugin/.claude-plugin/plugin.json'))
repo = d.get('repository', '')
m = re.match(r'https://github\.com/([^/]+/[^/]+)', repo)
if m:
    slug = m.group(1)
    print(slug[:-4] if slug.endswith('.git') else slug)
" 2>/dev/null || echo "")

  if [[ -z "$EXPECTED_SLUG" ]]; then
    fail "homebrew formula: expected repo" \
      "Could not extract owner/repo from plugin.json 'repository' field" \
      "Fix: set 'repository' in claude-plugin/.claude-plugin/plugin.json to a full GitHub URL"
    BREW_OK=false
  else
    FORMULA_URL_LINE=$(grep -E '^\s+url\s+' "$FORMULA_FILE" | head -1 || echo "")
    FORMULA_HP_LINE=$(grep -E '^\s+homepage\s+' "$FORMULA_FILE" | head -1 || echo "")

    if ! echo "$FORMULA_URL_LINE" | grep -qF "$EXPECTED_SLUG"; then
      fail "homebrew formula: url repo" \
        "$FORMULA_FILE: url does not reference $EXPECTED_SLUG" \
        "Fix: update url to https://github.com/$EXPECTED_SLUG/archive/v<version>.tar.gz"
      BREW_OK=false
    fi

    if ! echo "$FORMULA_HP_LINE" | grep -qF "$EXPECTED_SLUG"; then
      fail "homebrew formula: homepage repo" \
        "$FORMULA_FILE: homepage does not reference $EXPECTED_SLUG" \
        "Fix: update homepage to https://github.com/$EXPECTED_SLUG"
      BREW_OK=false
    fi

    if [[ -n "$PLUGIN_VERSION" ]]; then
      FORMULA_VERSION=$(echo "$FORMULA_URL_LINE" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^v//' | head -1 || echo "")
      if [[ -z "$FORMULA_VERSION" ]]; then
        fail "homebrew formula: version in url" \
          "$FORMULA_FILE: url line contains no semver tag (expected v$PLUGIN_VERSION)" \
          "Fix: url must contain a version like v$PLUGIN_VERSION"
        BREW_OK=false
      elif [[ "$FORMULA_VERSION" != "$PLUGIN_VERSION" ]]; then
        fail "homebrew formula: version skew" \
          "$FORMULA_FILE: url version ($FORMULA_VERSION) != plugin version ($PLUGIN_VERSION)" \
          "Fix: update url in $FORMULA_FILE to reference v$PLUGIN_VERSION"
        BREW_OK=false
      fi
    fi
  fi
fi
$BREW_OK && pass "homebrew formula consistency"

# ── CHECK 11: auto-review spec hygiene ────────────────────────────────────────
# Guards against regressions of v1.2.0/1.2.1 findings:
#   A. Registry-probe bug — movp://movp/registry must not be cited as a tool probe
#      (MCP tools and MCP resources are separate). Any reference must sit within a
#      "do NOT" / "Do NOT" / "DO NOT" window so the spec frames it as a negative rule.
#   B. Exit-1 display trap — 'yq ... && diff' chains make successful writes look
#      like failures because diff exits 1 when files differ.
#   C. strenv() without export — yq serializes null if the env var isn't exported.

HYGIENE_OK=true
HYGIENE_FILES=(
  claude-plugin/commands/auto-review.md
  claude-plugin/skills/review-advisor/SKILL.md
  codex-plugin/skills/review-advisor/SKILL.md
  cursor-plugin/skills/review-advisor/SKILL.md
)

for f in "${HYGIENE_FILES[@]}"; do
  [[ ! -f "$f" ]] && continue

  # Rule A: references to movp://movp/registry must sit within a "do NOT" window.
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    lineno="${hit%%:*}"
    start=$((lineno - 1))
    end=$((lineno + 1))
    [[ $start -lt 1 ]] && start=1
    window=$(sed -n "${start},${end}p" "$f")
    if ! echo "$window" | grep -qE 'do NOT|Do NOT|DO NOT'; then
      fail "spec hygiene: $f:$lineno" \
        "$f:$lineno references movp://movp/registry without an adjacent 'do NOT' warning" \
        "Fix: either remove the reference or frame it explicitly as a negative rule (include 'do NOT' within 1 line)"
      HYGIENE_OK=false
    fi
  done < <(grep -n 'movp://movp/registry' "$f" 2>/dev/null || true)

  # Rule B: forbid 'yq ... && diff' on a single line.
  if grep -nE 'yq[^#]*&&[[:space:]]*diff' "$f" > /dev/null 2>&1; then
    fail "spec hygiene: $f" \
      "$f: chained 'yq ... && diff' — diff exits 1 when files differ, making successful writes look like failures" \
      "Fix: use ';' between yq and diff, or 'diff ... || true'"
    HYGIENE_OK=false
  fi

  # Rule C: strenv(VAR) must be accompanied by 'export VAR' somewhere in the file.
  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    if ! grep -qE "export[[:space:]]+$var" "$f"; then
      fail "spec hygiene: $f" \
        "$f: uses strenv($var) but never documents 'export $var' — yq will serialize null" \
        "Fix: add 'export $var' before the yq example"
      HYGIENE_OK=false
    fi
  done < <(grep -oE 'strenv\([A-Z_][A-Z0-9_]*\)' "$f" 2>/dev/null | sed -E 's/strenv\((.*)\)/\1/' | sort -u)
done

$HYGIENE_OK && pass "auto-review spec hygiene"

# ── CHECK 12: declared deps match committed manifest ─────────────────────────
# For each SKILL.md and command .md that declares required_tools or
# required_resources, assert every entry appears in claude-plugin/manifest.json.
# This check runs against the COMMITTED SNAPSHOT — its purpose is to catch
# "skill added a tool reference without updating manifest.json".
# Run-time drift (server missing a declared tool) is caught by the mcp-smoke
# job (live server) and by /movp:status (live manifest resource).

MANIFEST_FILE="claude-plugin/manifest.json"
DEPS_OK=true

if [[ ! -f "$MANIFEST_FILE" ]]; then
  fail "declared deps: manifest" \
    "$MANIFEST_FILE not found" \
    "Fix: create $MANIFEST_FILE with tools and resources arrays"
  DEPS_OK=false
else
  MANIFEST_TOOLS=$(python3 -c "import json; d=json.load(open('$MANIFEST_FILE')); print(' '.join(d.get('tools',[])))" 2>/dev/null || echo "")
  MANIFEST_RESOURCES=$(python3 -c "import json; d=json.load(open('$MANIFEST_FILE')); print(' '.join(d.get('resources',[])))" 2>/dev/null || echo "")

  check_deps_file() {
    local f="$1"
    [[ ! -f "$f" ]] && return

    local req_tools req_resources
    req_tools=$(python3 - "$f" <<'PYEOF'
import sys
content = open(sys.argv[1]).read()
parts = content.split('---')
if len(parts) < 3:
    sys.exit()
fm = parts[1]
for line in fm.split('\n'):
    if line.strip().startswith('required_tools:'):
        rest = line.split(':', 1)[1].strip().strip('[]')
        if rest:
            for item in rest.split(','):
                item = item.strip().strip("\"'")
                if item:
                    print(item)
PYEOF
)
    req_resources=$(python3 - "$f" <<'PYEOF'
import sys
content = open(sys.argv[1]).read()
parts = content.split('---')
if len(parts) < 3:
    sys.exit()
fm = parts[1]
for line in fm.split('\n'):
    if line.strip().startswith('required_resources:'):
        rest = line.split(':', 1)[1].strip().strip('[]')
        if rest:
            for item in rest.split(','):
                item = item.strip().strip("\"'")
                if item:
                    print(item)
PYEOF
)

    while IFS= read -r tool || [[ -n "$tool" ]]; do
      [[ -z "$tool" ]] && continue
      if ! echo " $MANIFEST_TOOLS " | grep -qF " $tool "; then
        fail "declared deps: $f" \
          "$f: required_tool '$tool' not found in $MANIFEST_FILE" \
          "Fix: add '$tool' to the tools array in $MANIFEST_FILE, or remove it from $f"
        DEPS_OK=false
      fi
    done <<< "$req_tools"

    while IFS= read -r res || [[ -n "$res" ]]; do
      [[ -z "$res" ]] && continue
      if ! echo " $MANIFEST_RESOURCES " | grep -qF " $res "; then
        fail "declared deps: $f" \
          "$f: required_resource '$res' not found in $MANIFEST_FILE" \
          "Fix: add '$res' to the resources array in $MANIFEST_FILE, or remove it from $f"
        DEPS_OK=false
      fi
    done <<< "$req_resources"
  }

  # Check all skills (claude-plugin only — cursor/codex are synced from claude)
  for skill in "${SKILLS[@]}"; do
    check_deps_file "claude-plugin/skills/$skill/SKILL.md"
  done

  # Check all commands
  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    check_deps_file "claude-plugin/commands/$cmd"
  done
fi

$DEPS_OK && pass "declared deps match manifest"

# ── CHECK 13: MCP server version parity ──────────────────────────────────────
# Compares manifest.json.pinned_mcp_server_version against the version recorded
# in scripts/mcp-smoke/package-lock.json. The lockfile is the authoritative
# version contract — npm ci in CI installs exactly what it pins.

LOCKFILE="scripts/mcp-smoke/package-lock.json"
VER_OK=true

if [[ ! -f "$LOCKFILE" ]]; then
  fail "MCP version parity" \
    "$LOCKFILE not found" \
    "Fix: run 'npm install @movp/mcp-server@<version> --save-exact' in scripts/mcp-smoke/"
  VER_OK=false
else
  PINNED_VER=$(python3 -c "import json; print(json.load(open('$MANIFEST_FILE')).get('pinned_mcp_server_version',''))" 2>/dev/null || echo "")
  LOCKFILE_VER=$(python3 -c "
import json
d = json.load(open('$LOCKFILE'))
pkgs = d.get('packages', {})
key = 'node_modules/@movp/mcp-server'
if key in pkgs:
    print(pkgs[key].get('version', ''))
else:
    deps = d.get('dependencies', {})
    print(deps.get('@movp/mcp-server', {}).get('version', ''))
" 2>/dev/null || echo "")

  if [[ -z "$PINNED_VER" ]]; then
    fail "MCP version parity" \
      "$MANIFEST_FILE: pinned_mcp_server_version is missing or empty" \
      "Fix: add 'pinned_mcp_server_version' to $MANIFEST_FILE"
    VER_OK=false
  elif [[ -z "$LOCKFILE_VER" ]]; then
    fail "MCP version parity" \
      "$LOCKFILE: could not find @movp/mcp-server version" \
      "Fix: run 'npm install @movp/mcp-server@$PINNED_VER --save-exact' in scripts/mcp-smoke/"
    VER_OK=false
  elif [[ "$PINNED_VER" != "$LOCKFILE_VER" ]]; then
    fail "MCP version parity" \
      "Version skew: manifest.json pins $PINNED_VER but lockfile has $LOCKFILE_VER" \
      "Fix: run 'npm install @movp/mcp-server@$PINNED_VER --save-exact' in scripts/mcp-smoke/, or update pinned_mcp_server_version in manifest.json"
    VER_OK=false
  fi
fi

$VER_OK && pass "MCP server version parity"

# ── Summary ───────────────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL))

if $JSON_MODE; then
  _JSON_TMP=$(mktemp)
  printf '%s\n' "${RESULTS[@]+"${RESULTS[@]}"}" > "$_JSON_TMP"
  echo ""
  python3 - "$PASS" "$FAIL" "$TOTAL" "$_JSON_TMP" <<'PYEOF'
import json, sys
pass_n, fail_n, total_n = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
with open(sys.argv[4]) as f:
    lines = [l.rstrip('\n') for l in f if l.strip()]
checks = []
for line in lines:
    parts = line.split('|', 2)
    checks.append({
        'check':  parts[0] if len(parts) > 0 else '',
        'status': parts[1] if len(parts) > 1 else '',
        'detail': parts[2] if len(parts) > 2 else ''
    })
print(json.dumps({'pass': pass_n, 'fail': fail_n, 'total': total_n, 'checks': checks}, indent=2))
PYEOF
  rm -f "$_JSON_TMP"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Plugin Validation"
    echo ""
    echo "| Check | Status | Detail |"
    echo "|---|---|---|"
    for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do
      IFS='|' read -r check status detail <<< "$r"
      icon=$( [[ "$status" == "pass" ]] && echo "✅" || echo "❌" )
      echo "| $check | $icon $(tr '[:lower:]' '[:upper:]' <<< "${status:0:1}")${status:1} | $detail |"
    done
    echo ""
    if [[ $FAIL -gt 0 ]]; then
      echo "**$FAIL of $TOTAL checks failed.** Fix issues above then re-run \`bash scripts/validate.sh\`."
    else
      echo "**All $TOTAL checks passed.**"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "All $TOTAL checks passed."
  exit 0
else
  echo "$FAIL of $TOTAL checks failed."
  echo "Run ./scripts/validate.sh --json for machine-readable output."
  exit 1
fi
