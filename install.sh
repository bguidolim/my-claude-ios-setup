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
INSTALL_DIR="${HOME}/Developer/my-claude-ios-setup"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Prerequisites ---
command -v git >/dev/null 2>&1 || error "git is required. Install Xcode CLT: xcode-select --install"

# --- Clone or update ---
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing repo at $INSTALL_DIR..."
    git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || {
        info "Pull failed (local changes?). Using existing version."
    }
else
    info "Cloning to $INSTALL_DIR..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

# --- Run setup ---
echo ""
echo -e "${BOLD}Running setup...${NC}"
echo ""
# Redirect stdin from terminal so setup.sh can prompt interactively
# (curl pipe consumes stdin, leaving EOF for read calls)
exec "$INSTALL_DIR/setup.sh" "$@" </dev/tty
