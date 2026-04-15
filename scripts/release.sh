#!/usr/bin/env bash
# release.sh — Transactional plugin release for movp-plugins
#
# Usage:
#   ./scripts/release.sh --dry-run <version>   # preview only, no changes
#   ./scripts/release.sh --execute <version>   # bump, commit, tag, push, verify
#
# Example: ./scripts/release.sh --dry-run 1.2.0

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Parse args ────────────────────────────────────────────────────────────────

MODE="${1:-}"
VERSION="${2:-}"

if [[ "$MODE" != "--dry-run" && "$MODE" != "--execute" ]]; then
  echo "Usage: $0 --dry-run <version> | --execute <version>"
  echo "Example: $0 --dry-run 1.2.0"
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  echo "Error: version argument required (e.g. 1.2.0)"
  exit 1
fi

SEMVER_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
if ! echo "$VERSION" | grep -qE "$SEMVER_PATTERN"; then
  echo "Error: '$VERSION' is not valid stable semver (expected x.y.z, no prerelease suffix)"
  exit 1
fi

TAG="v$VERSION"
DRY_RUN=false
[[ "$MODE" == "--dry-run" ]] && DRY_RUN=true

# ── Step 1: Validate current state ───────────────────────────────────────────

echo "=== Running validation ==="
if ! bash scripts/validate.sh; then
  echo ""
  echo "[BLOCKED] Release blocked: fix validation errors first (./scripts/validate.sh)"
  exit 1
fi

# ── Step 2: Check for dirty git state ─────────────────────────────────────────

if [[ $(git status --porcelain | wc -l | tr -d ' ') -gt 0 ]]; then
  echo ""
  echo "[BLOCKED] Working tree has uncommitted changes. Commit or stash before releasing."
  git status --short
  exit 1
fi

# ── Step 2b: Branch and sync preflight (execute mode only) ────────────────────

if ! $DRY_RUN; then
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo ""
    echo "[BLOCKED] Releases must be cut from main (currently on '$CURRENT_BRANCH')."
    echo "  Switch: git checkout main"
    exit 1
  fi

  echo ""
  echo "=== Syncing with origin/main ==="
  git fetch origin main --quiet
  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git rev-parse origin/main)
  if [[ "$LOCAL" != "$REMOTE" ]]; then
    AHEAD=$(git rev-list origin/main..HEAD --count 2>/dev/null || echo "?")
    BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "?")
    echo ""
    echo "[BLOCKED] Local main is not in sync with origin/main."
    echo "  Ahead by $AHEAD commit(s), behind by $BEHIND commit(s)."
    echo "  Fix: git pull --rebase origin main   (or push pending commits first)"
    exit 1
  fi
  echo "  Local main is in sync with origin."
fi

# ── Step 3: Preview version changes ──────────────────────────────────────────

PLUGIN_JSON_FILES=(
  "claude-plugin/.claude-plugin/plugin.json"
  "cursor-plugin/.cursor-plugin/plugin.json"
  "codex-plugin/.codex-plugin/plugin.json"
)

echo ""
echo "=== Version changes (${TAG}) ==="
for f in "${PLUGIN_JSON_FILES[@]}" ".claude-plugin/marketplace.json"; do
  current=$(python3 -c "
import json
d = json.load(open('$f'))
# marketplace.json has versions in two places
if 'plugins' in d:
    versions = set([d.get('version','?')] + [p.get('version','?') for p in d.get('plugins',[])])
    print(', '.join(sorted(versions)))
else:
    print(d.get('version','?'))
" 2>/dev/null)
  echo "  $f: $current → $VERSION"
done

FORMULA_FILE="scripts/homebrew/movp.rb"
if [[ -f "$FORMULA_FILE" ]]; then
  CURRENT_FORMULA_VER=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$FORMULA_FILE" | head -1 | sed 's/^v//' || echo "?")
  echo "  $FORMULA_FILE: url $CURRENT_FORMULA_VER → $VERSION (sha256 updated in tap via Step 9)"
fi

echo ""
echo "  git commit: chore: release $TAG"
echo "  git tag:    $TAG"

if $DRY_RUN; then
  echo ""
  echo "=== Homebrew tap update (Step 9, after tag push) ==="
  echo "  Tap:    MostViableProduct/homebrew-movp"
  echo "  url    \"https://github.com/MostViableProduct/movp-plugins/archive/$TAG.tar.gz\""
  echo "  sha256  <computed from tarball after tag exists>"
  echo ""
  echo "[DRY RUN] No changes made. Re-run with --execute to apply."
  exit 0
fi

# ── Step 4: Apply version bumps ───────────────────────────────────────────────

echo ""
echo "=== Applying version bumps ==="

for f in "${PLUGIN_JSON_FILES[@]}"; do
  python3 -c "
import json
with open('$f') as fh:
    d = json.load(fh)
d['version'] = '$VERSION'
with open('$f', 'w') as fh:
    json.dump(d, fh, indent=2)
    fh.write('\n')
"
  echo "  Updated $f"
done

MKT_FILE=".claude-plugin/marketplace.json"
python3 -c "
import json
with open('$MKT_FILE') as fh:
    d = json.load(fh)
d['version'] = '$VERSION'
for p in d.get('plugins', []):
    p['version'] = '$VERSION'
with open('$MKT_FILE', 'w') as fh:
    json.dump(d, fh, indent=2)
    fh.write('\n')
"
echo "  Updated $MKT_FILE"

# Update formula url to new version (sha256 stays PLACEHOLDER; Step 9 pushes real SHA to tap)
if [[ -f "$FORMULA_FILE" ]]; then
  sed -i.bak -E "s|(archive/)v[0-9]+\.[0-9]+\.[0-9]+(\.tar\.gz)|\1$TAG\2|" "$FORMULA_FILE"
  rm -f "${FORMULA_FILE}.bak"
  echo "  Updated $FORMULA_FILE (url → $TAG)"
fi

# ── Step 5: Commit and tag ─────────────────────────────────────────────────────

echo ""
echo "=== Committing ==="
git add "${PLUGIN_JSON_FILES[@]}" "$MKT_FILE"
[[ -f "$FORMULA_FILE" ]] && git add "$FORMULA_FILE"
git commit -m "chore: release $TAG"
git tag "$TAG"
echo "  Committed and tagged $TAG"

# ── Step 6: Push ──────────────────────────────────────────────────────────────

echo ""
read -rp "Push commit and tag to origin? [y/N] " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
  echo "Aborted. To push manually: git push && git push --tags"
  echo "To roll back the local commit and tag:"
  echo "  git tag -d $TAG"
  echo "  git reset --hard HEAD~1"
  exit 0
fi

echo ""
echo "=== Pushing ==="
git push
git push --tags
echo "  Pushed commit and tag $TAG"

# ── Step 7: Post-push verification ────────────────────────────────────────────

echo ""
echo "=== Verifying remote tag ==="
sleep 2  # give GitHub a moment

REMOTE_TAG=$(git ls-remote --tags origin "$TAG" 2>/dev/null | head -1)
if [[ -z "$REMOTE_TAG" ]]; then
  cat <<EOF

[FAIL] Post-push verification: tag $TAG not found on remote.
  Remote may need more time, or the push may have failed.

  To verify manually: git ls-remote --tags origin $TAG

  Recommended recovery (safe for shared repos):
    git revert HEAD        # creates a new undo commit
    git push
    git push origin --delete $TAG
    git tag -d $TAG

  Emergency only — destructive, confirm with team first:
    (use ONLY if you are certain no one has pulled this tag)
    git tag -d $TAG
    git push origin --delete $TAG
    git reset --hard HEAD~1
    git push --force-with-lease
EOF
  exit 1
fi
echo "  [PASS] Tag $TAG exists on remote"

# Verify tarball URL with retry (GitHub can take a moment to generate archives)
TARBALL_URL="https://github.com/MostViableProduct/movp-plugins/archive/$TAG.tar.gz"
echo "  Checking tarball URL (up to 3 attempts)..."
TARBALL_OK=false
for attempt in 1 2 3; do
  HTTP_STATUS=$(curl -sI -o /dev/null -w "%{http_code}" "$TARBALL_URL" 2>/dev/null || echo "000")
  if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "302" ]]; then
    echo "  [PASS] Tarball URL is reachable (HTTP $HTTP_STATUS, attempt $attempt)"
    TARBALL_OK=true
    break
  fi
  [[ $attempt -lt 3 ]] && echo "  [WARN] Attempt $attempt: HTTP $HTTP_STATUS — retrying in 5s..." && sleep 5
done

if ! $TARBALL_OK; then
  echo ""
  echo "  [FAIL] Tarball URL not reachable after 3 attempts (last: HTTP $HTTP_STATUS)"
  echo "  URL: $TARBALL_URL"
  echo ""
  echo "  GitHub may still be processing the archive. Verify before updating Homebrew:"
  echo "    curl -sI $TARBALL_URL"
  echo ""
  echo "  ⚠️  Do NOT update the Homebrew formula until this URL returns 200."
  exit 1
fi

# ── Step 8: Compute Homebrew SHA256 ───────────────────────────────────────────

echo ""
echo "=== Computing Homebrew SHA256 ==="
SHA256=$(curl -sL "$TARBALL_URL" | shasum -a 256 | awk '{print $1}')
echo "  SHA256: $SHA256"

# ── Step 9: Push updated formula to homebrew-movp tap ─────────────────────────

TAP_REPO="MostViableProduct/homebrew-movp"
TAP_FORMULA="Formula/movp.rb"

echo ""
echo "=== Updating Homebrew tap ($TAP_REPO) ==="

_tap_manual_instructions() {
  echo "  Manual update required:"
  echo "    https://github.com/$TAP_REPO/blob/main/$TAP_FORMULA"
  echo "    url    \"$TARBALL_URL\""
  echo "    sha256 \"$SHA256\""
}

if ! command -v gh >/dev/null 2>&1; then
  echo "  [SKIP] gh CLI not found — update tap manually"
  _tap_manual_instructions
elif ! gh auth status >/dev/null 2>&1; then
  echo "  [SKIP] gh CLI not authenticated — update tap manually"
  _tap_manual_instructions
else
  TAP_API_RESPONSE=$(gh api "repos/$TAP_REPO/contents/$TAP_FORMULA" 2>/dev/null || echo "")

  if [[ -z "$TAP_API_RESPONSE" ]]; then
    echo "  [WARN] Could not read tap formula (repo may be private or path may differ)"
    _tap_manual_instructions
  else
    EXISTING_VERSION=$(echo "$TAP_API_RESPONSE" | python3 -c "
import json, sys, base64, re
d = json.load(sys.stdin)
content = base64.b64decode(d['content']).decode()
m = re.search(r'v([0-9]+\.[0-9]+\.[0-9]+)', content)
print(m.group(1) if m else '')
" 2>/dev/null || echo "")

    if [[ "$EXISTING_VERSION" == "$VERSION" ]]; then
      echo "  [SKIP] Tap already at $TAG — no update needed"
    else
      TAP_FILE_SHA=$(echo "$TAP_API_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['sha'])" 2>/dev/null || echo "")

      # Build new formula content from local template, substituting url and sha256
      NEW_CONTENT=$(sed -E \
        -e "s|(archive/)v[0-9]+\.[0-9]+\.[0-9]+(\.tar\.gz)|\1$TAG\2|" \
        -e "s|sha256 \"[^\"]*\"|sha256 \"$SHA256\"|" \
        "$FORMULA_FILE")
      ENCODED=$(echo "$NEW_CONTENT" | python3 -c "
import sys, base64
print(base64.b64encode(sys.stdin.buffer.read()).decode())
")

      if gh api --method PUT "repos/$TAP_REPO/contents/$TAP_FORMULA" \
          --field message="chore: release $TAG" \
          --field content="$ENCODED" \
          --field sha="$TAP_FILE_SHA" > /dev/null 2>&1; then
        echo "  [PASS] Tap updated: $TAP_REPO/$TAP_FORMULA → $TAG"
      else
        echo "  [FAIL] gh api PUT failed (check token has write access to $TAP_REPO)"
        _tap_manual_instructions
      fi
    fi
  fi
fi

echo ""
echo "[PASS] Release $TAG complete."
echo ""
echo "To verify SHA256 locally:"
echo "  curl -sL $TARBALL_URL | shasum -a 256"
