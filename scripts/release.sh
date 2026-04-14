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

echo ""
echo "  git commit: chore: release $TAG"
echo "  git tag:    $TAG"

if $DRY_RUN; then
  echo ""
  echo "=== Homebrew update (after pushing tag) ==="
  echo "  URL:    https://github.com/MostViableProduct/movp-plugins/archive/$TAG.tar.gz"
  echo "  SHA256: <run after tag is pushed: curl -sL https://github.com/MostViableProduct/movp-plugins/archive/$TAG.tar.gz | shasum -a 256>"
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

# ── Step 5: Commit and tag ─────────────────────────────────────────────────────

echo ""
echo "=== Committing ==="
git add "${PLUGIN_JSON_FILES[@]}" "$MKT_FILE"
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

  To roll back (SAFE only if no one has pulled the tag yet):
    git tag -d $TAG
    git push origin --delete $TAG
    git reset --hard HEAD~1
    git push --force-with-lease

  WARNING: If others may have pulled the tag, prefer:
    git revert HEAD && git push
    Then send an advisory before deleting the remote tag.
EOF
  exit 1
fi
echo "  [PASS] Tag $TAG exists on remote"

TARBALL_URL="https://github.com/MostViableProduct/movp-plugins/archive/$TAG.tar.gz"
echo "  Checking tarball URL..."
HTTP_STATUS=$(curl -sI -o /dev/null -w "%{http_code}" "$TARBALL_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_STATUS" != "200" && "$HTTP_STATUS" != "302" ]]; then
  echo "  [WARN] Tarball URL returned HTTP $HTTP_STATUS — GitHub may need more time to generate it."
  echo "  Verify manually: curl -sI $TARBALL_URL"
else
  echo "  [PASS] Tarball URL is reachable (HTTP $HTTP_STATUS)"
fi

# ── Step 8: Homebrew instructions ─────────────────────────────────────────────

echo ""
echo "=== Computing Homebrew SHA256 ==="
SHA256=$(curl -sL "$TARBALL_URL" | shasum -a 256 | awk '{print $1}')

cat <<EOF

[PASS] Release $TAG complete.

Update Homebrew formula in MostViableProduct/homebrew-movp:
  url    "https://github.com/MostViableProduct/movp-plugins/archive/$TAG.tar.gz"
  sha256 "$SHA256"

To verify SHA256 locally:
  curl -sL $TARBALL_URL | shasum -a 256
EOF
