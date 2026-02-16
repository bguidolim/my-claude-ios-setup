#!/bin/bash
# =============================================================================
# Claude Code iOS Setup — One-line installer
# =============================================================================
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/bguidolim/my-claude-ios-setup/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --all
# =============================================================================

set -euo pipefail

REPO_URL="https://github.com/bguidolim/my-claude-ios-setup.git"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Prerequisites ---
command -v git >/dev/null 2>&1 || error "git is required. Install Xcode CLT: xcode-select --install"
[ -c /dev/tty ] || error "No terminal available. This installer must be run interactively."

# --- Clone to temp dir ---
TMPDIR_SETUP=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SETUP"' EXIT

info "Cloning setup repo..."
git clone --depth 1 "$REPO_URL" "$TMPDIR_SETUP" 2>&1 | tail -1

# --- Run setup ---
echo ""
echo -e "${BOLD}Running setup...${NC}"
echo ""
# Redirect stdin from terminal so setup.sh can prompt interactively
# (curl pipe consumes stdin, leaving EOF for read calls)
"$TMPDIR_SETUP/setup.sh" "$@" </dev/tty
