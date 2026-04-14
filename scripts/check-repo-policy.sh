#!/usr/bin/env bash
# check-repo-policy.sh — Assert GitHub branch protection is properly configured
#
# Usage: bash scripts/check-repo-policy.sh
# Requires: gh CLI (pre-installed on GitHub-hosted runners; brew install gh locally)
# Auth: GITHUB_TOKEN env var (set automatically in CI) or gh auth login (local)
#
# Run once after initial setup to confirm protection is active.
# Run on a schedule (see .github/workflows/repo-policy.yml) to catch drift.
#
# IMPORTANT: Before deploying, verify the required check name used in GitHub's
# branch protection UI. The string is typically "<Workflow Name> / <job-id>"
# (e.g. "Validate / validate"). After validate.yml runs for the first time:
#   1. Go to Settings → Branches → edit main rule
#   2. In "Require status checks", search and find the exact autocomplete string
#   3. Update REQUIRED_CHECK_NAME below to match

set -euo pipefail

REPO="MostViableProduct/movp-plugins"
BRANCH="main"

# The exact check run title GitHub uses for the required status check.
# Verify this after validate.yml runs at least once — see note above.
REQUIRED_CHECK_NAME="Validate / validate"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; [[ -n "${2:-}" ]] && echo "       $2"; FAIL=$((FAIL+1)); }

echo "=== Checking branch protection on $REPO ($BRANCH) ==="
echo ""

# Verify gh is available
if ! command -v gh &>/dev/null; then
  echo "[ERROR] gh CLI not found. Install with: brew install gh"
  echo "        In CI, gh is pre-installed on ubuntu-latest runners."
  exit 1
fi

# Fetch branch protection settings — 10s timeout, 3 retries
# NOTE: The JSON shape has changed across GitHub API versions. The assertion below
# checks both the newer 'checks[].context' field and the older 'contexts[]' field.
# Confirmed field path for this repo: .required_status_checks.checks[].context
# (verified against live API output 2026-04-14 — re-verify if GitHub changes the API)
PROTECTION=""
for _attempt in 1 2 3; do
  PROTECTION=$(gh api --method GET --silent \
    -H "Accept: application/vnd.github+json" \
    "repos/$REPO/branches/$BRANCH/protection" 2>&1) && break
  [[ $_attempt -lt 3 ]] && sleep 3
done
[[ -z "$PROTECTION" ]] && {
  echo "[ERROR] Could not fetch branch protection. Check that:"
  echo "  - The repo name is correct: $REPO"
  echo "  - You are authenticated: gh auth status"
  echo "  - Branch protection is enabled (it may not exist yet)"
  echo ""
  echo "  To enable: https://github.com/$REPO/settings/branches"
  exit 1
}

# CHECK 1: Branch protection exists (we got here without error)
pass "Branch protection rule exists for $BRANCH"

# CHECK 2: Required status checks enabled
RSC=$(echo "$PROTECTION" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('required_status_checks') or {}))" 2>/dev/null)
if [[ "$RSC" == "null" || "$RSC" == "{}" ]]; then
  fail "Required status checks" \
    "Fix: Settings → Branches → edit main → enable 'Require status checks to pass'"
else
  pass "Required status checks enabled"
fi

# CHECK 3: 'validate' job listed as required
CONTEXTS=$(echo "$PROTECTION" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rsc = d.get('required_status_checks') or {}
# Newer API: checks[].context
checks_new = [c.get('context','') for c in rsc.get('checks') or []]
# Older API: contexts[]
checks_old = rsc.get('contexts') or []
all_checks = checks_new + checks_old
print('\n'.join(all_checks))
" 2>/dev/null)

if echo "$CONTEXTS" | grep -qF "$REQUIRED_CHECK_NAME"; then
  pass "Required check '$REQUIRED_CHECK_NAME' is listed"
else
  fail "Required check '$REQUIRED_CHECK_NAME' not found in required status checks" \
    "Found checks: $(echo "$CONTEXTS" | tr '\n' ', ' | sed 's/,$//')
       Fix: https://github.com/$REPO/settings/branches
            Add '$REQUIRED_CHECK_NAME' to required status checks
       Note: Run validate.yml at least once first so GitHub can autocomplete the check name."
fi

# CHECK 4: Direct push restriction (require PR reviews OR restrict pushes)
ALLOW_FORCE=$(echo "$PROTECTION" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('allow_force_pushes',{}).get('enabled', False))
" 2>/dev/null)
RESTRICTIONS=$(echo "$PROTECTION" | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('restrictions')
print('none' if r is None else 'set')
" 2>/dev/null)
PR_REVIEWS=$(echo "$PROTECTION" | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('required_pull_request_reviews')
print('none' if r is None else 'set')
" 2>/dev/null)

if [[ "$ALLOW_FORCE" == "True" ]]; then
  fail "Force pushes are allowed on $BRANCH" \
    "Fix: Settings → Branches → edit main → uncheck 'Allow force pushes'"
else
  pass "Force pushes blocked on $BRANCH"
fi

if [[ "$RESTRICTIONS" == "none" && "$PR_REVIEWS" == "none" ]]; then
  echo "[WARN] No push restrictions and no required PR reviews — direct pushes to main are possible."
  echo "       Consider enabling 'Require a pull request before merging' on main."
else
  pass "Push restrictions or PR reviews configured"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo "All $TOTAL policy checks passed. Branch protection is correctly configured."
  exit 0
else
  echo "$FAIL of $TOTAL policy checks failed."
  echo "Fix the issues above, then re-run: bash scripts/check-repo-policy.sh"
  exit 1
fi
