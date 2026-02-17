#!/bin/bash
# =============================================================================
# Claude Code iOS Development Setup
# =============================================================================
# Portable, interactive setup script for Claude Code with iOS development tools.
# Installs MCP servers, plugins, skills, hooks, and configuration.
#
# Usage: ./setup.sh                      # Interactive setup (pick components)
#        ./setup.sh --all                 # Install everything (minimal prompts)
#        ./setup.sh --dry-run             # Show what would be installed (no changes)
#        ./setup.sh --all --dry-run       # Preview full install without changes
#        ./setup.sh doctor [--fix]        # Diagnose installation health
#        ./setup.sh configure-project     # Configure CLAUDE.local.md for a project
#        ./setup.sh cleanup               # Find and delete backup files
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SUFFIX="backup.$(date +%Y%m%d_%H%M%S)"
CREATED_BACKUPS=()   # Tracks backups created during this run
CLAUDE_JSON="$HOME/.claude.json"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_HOOKS_DIR="$CLAUDE_DIR/hooks"
CLAUDE_SKILLS_DIR="$CLAUDE_DIR/skills"
SETUP_MANIFEST="$CLAUDE_DIR/.setup-manifest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Track selections (0=no, 1=yes)
# Dependencies
INSTALL_HOMEBREW=0
INSTALL_NODE=0
INSTALL_JQ=0
INSTALL_GH=0
INSTALL_UV=0
INSTALL_OLLAMA=0
INSTALL_CLAUDE_CODE=0

# MCP Servers
INSTALL_MCP_XCODEBUILD=0
INSTALL_MCP_SOSUMI=0
INSTALL_MCP_SERENA=0
INSTALL_MCP_DOCS=0
INSTALL_MCP_OMNISEARCH=0
PERPLEXITY_API_KEY=""

# Plugins
INSTALL_PLUGIN_EXPLANATORY=0
INSTALL_PLUGIN_PR_REVIEW=0
INSTALL_PLUGIN_SIMPLIFIER=0
INSTALL_PLUGIN_RALPH=0
INSTALL_PLUGIN_HUD=0
INSTALL_PLUGIN_CLAUDE_MD=0

# Skills
INSTALL_SKILL_LEARNING=0
INSTALL_SKILL_XCODEBUILD=0

# Commands
INSTALL_CMD_PR=0

# Configuration
INSTALL_HOOKS=0
INSTALL_SETTINGS=0

# Branch prefix (used in commands and project config, e.g. "bruno" or "feature")
BRANCH_PREFIX=""

# Full install mode (--all flag)
INSTALL_ALL=0

# Dry run mode (--dry-run flag)
DRY_RUN=0

# Track what was installed
INSTALLED_ITEMS=()
SKIPPED_ITEMS=()
CLAUDE_FRESH_INSTALL=false

# ---------------------------------------------------------------------------
# Source library modules
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/fixes.sh"
source "$SCRIPT_DIR/lib/configure.sh"
source "$SCRIPT_DIR/lib/phases.sh"
source "$SCRIPT_DIR/lib/doctor.sh"
source "$SCRIPT_DIR/lib/cleanup.sh"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Handle subcommands and flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        doctor|--doctor)
            local_fix="false"
            if [[ "${2:-}" == "--fix" ]]; then
                local_fix="true"
                shift
            fi
            phase_doctor "$local_fix"
            exit 0
            ;;
        --all)
            INSTALL_ALL=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        configure-project|--configure-project)
            header "📱 Configure Project"
            configure_project
            while ask_yn "Configure another project?" "N"; do
                configure_project
            done
            prompt_cleanup_backups
            echo ""
            exit 0
            ;;
        cleanup)
            phase_cleanup
            exit 0
            ;;
        --help|-h)
            echo "Usage: ./setup.sh                      # Interactive setup (pick components)"
            echo "       ./setup.sh --all                 # Install everything (minimal prompts)"
            echo "       ./setup.sh --dry-run             # Show what would be installed (no changes)"
            echo "       ./setup.sh --all --dry-run       # Preview full install without changes"
            echo "       ./setup.sh doctor [--fix]        # Diagnose installation health"
            echo "       ./setup.sh configure-project     # Configure CLAUDE.local.md for a project"
            echo "       ./setup.sh cleanup               # Find and delete backup files"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Run ./setup.sh --help for usage."
            exit 1
            ;;
    esac
    shift
done

main() {
    phase_welcome
    phase_selection
    phase_summary
    if [[ $DRY_RUN -eq 1 ]]; then
        echo ""
        echo -e "${GREEN}${BOLD}Dry run complete.${NC} No changes were made."
        echo ""
        return
    fi
    phase_install
    phase_summary_post
    prompt_cleanup_backups
}

main
