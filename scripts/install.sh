#!/usr/bin/env bash
set -euo pipefail

# MoVP plugin installer for Mac and Linux
# Usage: curl -fsSL https://get.movp.dev/install.sh | sh
#        bash install.sh [--dir <path>] [--tool claude|cursor|codex] [--version <tag>]

MOVP_VERSION="${MOVP_VERSION:-}"
MOVP_INSTALL_DIR="${MOVP_INSTALL_DIR:-$HOME/.movp/plugins}"
MOVP_TOOL="${MOVP_TOOL:-}"
MOVP_REPO="https://github.com/MostViableProduct/movp-plugins"
MOVP_ALLOW_PRERELEASE=false

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)              MOVP_INSTALL_DIR="$2"; shift 2 ;;
    --tool)             MOVP_TOOL="$2"; shift 2 ;;
    --version)          MOVP_VERSION="$2"; shift 2 ;;
    --allow-prerelease) MOVP_ALLOW_PRERELEASE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Resolve version: default to latest stable semver tag (not main)
if [[ -z "$MOVP_VERSION" ]]; then
  if $MOVP_ALLOW_PRERELEASE; then
    TAG_PATTERN='refs/tags/v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*'
  else
    TAG_PATTERN='refs/tags/v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$'
  fi
  MOVP_VERSION=$(git ls-remote --tags --sort=-version:refname "$MOVP_REPO" \
    | grep -E "$TAG_PATTERN" \
    | head -1 \
    | sed 's|.*refs/tags/||') || true

  if [[ -z "$MOVP_VERSION" ]]; then
    echo "Error: no stable release tags found in $MOVP_REPO."
    echo "  To install from main (development, not recommended for production):"
    echo "    $0 --version main"
    echo "  To include prerelease tags:"
    echo "    $0 --allow-prerelease"
    exit 1
  fi
fi

# Color output (suppressed when NO_COLOR is set or stdout is not a tty)
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  GREEN='\033[0;32m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  GREEN='' BOLD='' RESET=''
fi

info()    { echo "${BOLD}$*${RESET}"; }
success() { echo "${GREEN}✓${RESET} $*"; }

info "Installing MoVP plugins${MOVP_VERSION:+ (${MOVP_VERSION})}..."
echo

# Check prerequisites
check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: $1 is required but not installed."
    echo "$2"
    exit 1
  fi
}

check_cmd node "Install Node.js 18+ from https://nodejs.org"
check_cmd git  "Install git from https://git-scm.com or your system package manager"

# Validate node version (>=18)
NODE_MAJOR=$(node -e "process.stdout.write(process.versions.node.split('.')[0])")
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  echo "Error: Node.js 18+ is required (found v$(node --version | tr -d v))."
  echo "Install from https://nodejs.org"
  exit 1
fi

# Create install directory
mkdir -p "$MOVP_INSTALL_DIR"

# Download plugins
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if [[ -n "${MOVP_RELEASE_URL:-}" ]]; then
  # Prefer release tarball if URL provided
  info "Downloading release tarball..."
  curl -fsSL "$MOVP_RELEASE_URL" | tar -xz -C "$TMPDIR" --strip-components=1
  SRC="$TMPDIR"
else
  # Fall back to shallow git clone
  info "Cloning repository..."
  CLONE_REF="${MOVP_VERSION:-HEAD}"
  git clone --depth 1 --filter=blob:none --quiet \
    ${MOVP_VERSION:+--branch "$MOVP_VERSION"} \
    "$MOVP_REPO" "$TMPDIR/repo"
  SRC="$TMPDIR/repo"
fi

# Determine which plugins to install
if [[ -n "$MOVP_TOOL" ]]; then
  PLUGINS=("${MOVP_TOOL}-plugin")
else
  PLUGINS=("claude-plugin" "codex-plugin" "cursor-plugin")
fi

for plugin in "${PLUGINS[@]}"; do
  if [[ -d "$SRC/$plugin" ]]; then
    rm -rf "$MOVP_INSTALL_DIR/$plugin"
    cp -r "$SRC/$plugin" "$MOVP_INSTALL_DIR/$plugin"
  else
    echo "Warning: $plugin not found in repository — skipping"
  fi
done

echo
success "MoVP plugins installed to $MOVP_INSTALL_DIR/"
echo

# Auto-detect installed tools
DETECTED=()
command -v claude >/dev/null 2>&1 && DETECTED+=("claude")
command -v cursor >/dev/null 2>&1 && DETECTED+=("cursor")
command -v codex  >/dev/null 2>&1 && DETECTED+=("codex")

if [[ ${#DETECTED[@]} -gt 0 ]]; then
  echo "Detected tools: ${DETECTED[*]}"
  echo
fi

# Print next steps
echo "${BOLD}Next steps:${RESET}"
echo

print_steps() {
  local tool="$1" flag="$2" dir="$3"
  printf "  %s:\n" "$tool"
  printf "    cd your-project\n"
  printf "    npx @movp/cli init%s\n" "$flag"
  printf "    %s --plugin-dir %s/%s\n" "$tool" "$MOVP_INSTALL_DIR" "$dir"
  echo
}

if [[ -z "$MOVP_TOOL" ]] || [[ "$MOVP_TOOL" == "claude" ]]; then
  print_steps "claude" "" "claude-plugin"
fi
if [[ -z "$MOVP_TOOL" ]] || [[ "$MOVP_TOOL" == "cursor" ]]; then
  print_steps "cursor" " --cursor" "cursor-plugin"
fi
if [[ -z "$MOVP_TOOL" ]] || [[ "$MOVP_TOOL" == "codex" ]]; then
  print_steps "codex" " --codex" "codex-plugin"
fi

echo "Need help? $MOVP_REPO#troubleshooting"
