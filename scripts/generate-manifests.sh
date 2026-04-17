#!/usr/bin/env bash
# Regenerates platform manifests and the mcp-smoke package.json from
# scripts/manifest.source.json, the single source of truth for:
#   - pinned_mcp_server_version
#   - tools[]
#   - resources[]
#
# Run this whenever you edit scripts/manifest.source.json. The outputs are
# committed; CHECK 14 in scripts/validate.sh fails if they drift from source.
#
# After a pinned_mcp_server_version bump, also update the lockfile:
#   cd scripts/mcp-smoke && npm install @movp/mcp-server@<version> --save-exact

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SOURCE="scripts/manifest.source.json"
# When OUT_ROOT is set, write generated artifacts there instead of in-tree.
# CHECK 14 uses this to generate into a tmp dir and diff against committed files.
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT}"

if [[ ! -f "$SOURCE" ]]; then
  echo "Error: $SOURCE not found" >&2
  exit 1
fi

PINNED_VER=$(python3 -c "import json; print(json.load(open('$SOURCE'))['pinned_mcp_server_version'])" 2>/dev/null || true)

if [[ -z "$PINNED_VER" ]]; then
  echo "Error: could not parse pinned_mcp_server_version from $SOURCE" >&2
  exit 1
fi

mkdir -p "$OUT_ROOT/claude-plugin" "$OUT_ROOT/cursor-plugin" "$OUT_ROOT/codex-plugin" "$OUT_ROOT/scripts/mcp-smoke"

# Platform manifests are byte-identical copies of the source
for platform in claude cursor codex; do
  cp "$SOURCE" "$OUT_ROOT/${platform}-plugin/manifest.json"
done

# Smoke package.json — version-templated from the source
cat > "$OUT_ROOT/scripts/mcp-smoke/package.json" <<EOF
{
  "name": "mcp-smoke",
  "private": true,
  "description": "MCP server smoke test harness for CI",
  "scripts": {
    "test": "node client.mjs"
  },
  "dependencies": {
    "@movp/mcp-server": "$PINNED_VER"
  }
}
EOF

echo "Generated from $SOURCE:"
echo "  claude-plugin/manifest.json"
echo "  cursor-plugin/manifest.json"
echo "  codex-plugin/manifest.json"
echo "  scripts/mcp-smoke/package.json (pinned to $PINNED_VER)"
