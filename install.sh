#!/bin/bash
# =============================================================================
# My Claude Setup — One-line installer
# =============================================================================
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/bguidolim/my-claude-setup/main/install.sh | bash
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Check for Homebrew ---
if ! command -v brew >/dev/null 2>&1; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty

    # Add brew to PATH for this session
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# --- Install via Homebrew ---
info "Installing My Claude Setup..."
brew install bguidolim/tap/my-claude-setup 2>&1 || brew upgrade bguidolim/tap/my-claude-setup 2>&1

# --- Run setup ---
echo ""
echo -e "${BOLD}Running mcs install...${NC}"
echo ""
mcs install --all </dev/tty
