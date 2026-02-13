#!/bin/bash
# =============================================================================
# Claude Code iOS Development Setup
# =============================================================================
# Portable, interactive setup script for Claude Code with iOS development tools.
# Installs MCP servers, plugins, skills, hooks, and configuration.
#
# Usage: ./setup.sh                      # Full interactive setup
#        ./setup.sh --configure-project   # Configure CLAUDE.local.md for a project
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SUFFIX="backup.$(date +%Y%m%d_%H%M%S)"
CLAUDE_JSON="$HOME/.claude.json"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_HOOKS_DIR="$CLAUDE_DIR/hooks"
CLAUDE_SKILLS_DIR="$CLAUDE_DIR/skills"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# User identity (used in commands and project config)
USER_NAME=""

# Track what was installed
INSTALLED_ITEMS=()
SKIPPED_ITEMS=()
CLAUDE_FRESH_INSTALL=false

# ---------------------------------------------------------------------------
# Utility Functions
# ---------------------------------------------------------------------------
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

header() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

step() {
    local current=$1
    local total=$2
    local msg=$3
    echo ""
    echo -e "${BOLD}[${current}/${total}] ${msg}${NC}"
    echo -e "${DIM}──────────────────────────────────────────${NC}"
}

ask_yn() {
    local prompt=$1
    local default=${2:-Y}
    local yn_hint
    if [[ "$default" == "Y" ]]; then
        yn_hint="[Y/n]"
    else
        yn_hint="[y/N]"
    fi
    while true; do
        echo -ne "  ${prompt} ${yn_hint}: "
        read -r answer
        answer=${answer:-$default}
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "  Please answer y or n." ;;
        esac
    done
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

backup_file() {
    local file=$1
    if [[ -f "$file" ]]; then
        local backup="${file}.${BACKUP_SUFFIX}"
        cp "$file" "$backup"
        info "Backed up $(basename "$file") → $(basename "$backup")"
    fi
}

detect_brew_path() {
    if [[ "$(uname -m)" == "arm64" ]]; then
        echo "/opt/homebrew/bin/brew"
    else
        echo "/usr/local/bin/brew"
    fi
}

ensure_brew_in_path() {
    if ! check_command brew; then
        local brew_path
        brew_path=$(detect_brew_path)
        if [[ -f "$brew_path" ]]; then
            eval "$("$brew_path" shellenv)"
        fi
    fi
}

# Run claude CLI without nesting check
claude_cli() {
    CLAUDECODE="" claude "$@"
}

# ---------------------------------------------------------------------------
# Configure CLAUDE.local.md for a project
# ---------------------------------------------------------------------------
configure_project() {
    echo ""
    echo -e "  ${BOLD}Enter the path to your iOS project:${NC}"
    echo -ne "  > "
    read -e -r project_path
    # Expand ~ to $HOME
    project_path="${project_path/#\~/$HOME}"
    # Remove trailing slash
    project_path="${project_path%/}"

    if [[ ! -d "$project_path" ]]; then
        error "Directory not found: $project_path"
        return 1
    fi

    # --- Auto-detect Xcode project/workspace ---
    local xcode_files=()

    # Find .xcworkspace at root (skip internal ones inside .xcodeproj bundles)
    while IFS= read -r -d '' f; do
        xcode_files+=("$(basename "$f")")
    done < <(find "$project_path" -maxdepth 1 -name "*.xcworkspace" -not -path "*.xcodeproj/*" -print0 2>/dev/null)

    # Find .xcodeproj at root
    while IFS= read -r -d '' f; do
        xcode_files+=("$(basename "$f")")
    done < <(find "$project_path" -maxdepth 1 -name "*.xcodeproj" -print0 2>/dev/null)

    local xcode_project=""
    if [[ ${#xcode_files[@]} -eq 0 ]]; then
        warn "No .xcodeproj or .xcworkspace found in $project_path"
        echo -ne "  Enter project file name (e.g. MyApp.xcodeproj): "
        read -r xcode_project
    elif [[ ${#xcode_files[@]} -eq 1 ]]; then
        xcode_project="${xcode_files[0]}"
        echo -e "  Found: ${BOLD}${xcode_project}${NC}"
        if ! ask_yn "Use this?"; then
            echo -ne "  Enter project file name: "
            read -r xcode_project
        fi
    else
        echo -e "  Found multiple Xcode projects:"
        for i in "${!xcode_files[@]}"; do
            echo -e "    $((i+1)). ${xcode_files[$i]}"
        done
        local selection
        echo -ne "  Select [1-${#xcode_files[@]}]: "
        read -r selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#xcode_files[@]} )); then
            xcode_project="${xcode_files[$((selection-1))]}"
        else
            error "Invalid selection."
            return 1
        fi
    fi
    echo ""

    # --- Ask for user name (branch naming) — reuse if already provided ---
    local user_name="$USER_NAME"
    if [[ -n "$user_name" ]]; then
        echo -e "  Branch naming prefix: ${BOLD}${user_name}${NC}"
    else
        echo -e "  ${BOLD}Your name for branch naming${NC} (e.g. ${DIM}bruno${NC}):"
        echo -ne "  > "
        read -r user_name
        if [[ -z "$user_name" ]]; then
            warn "No name entered — template will keep the placeholder."
            user_name='<your-name>'
        else
            # Store globally for subsequent project configs
            USER_NAME="$user_name"
        fi
    fi
    echo ""

    # --- Detect CLAUDE.md → AGENTS.md symlink ---
    local has_symlink=false
    if [[ -L "$project_path/CLAUDE.md" ]]; then
        local link_target
        link_target="$(readlink "$project_path/CLAUDE.md")"
        if [[ "$link_target" == *"AGENTS.md"* ]]; then
            has_symlink=true
            info "Detected CLAUDE.md → AGENTS.md symlink"
        fi
    fi

    # --- Copy template ---
    local dest="$project_path/CLAUDE.local.md"
    if [[ -f "$dest" ]]; then
        if ask_yn "CLAUDE.local.md already exists. Overwrite?" "N"; then
            backup_file "$dest"
        else
            warn "Skipped project configuration."
            return 0
        fi
    fi

    cp "$SCRIPT_DIR/templates/CLAUDE.local.md" "$dest"

    # --- Apply edits ---

    # 1. Xcode project: remove EDIT comment, replace placeholder
    sed -i '' '/<!-- EDIT: Set your .xcodeproj and default scheme below -->/d' "$dest"
    # Escape dots in xcode_project for sed replacement (e.g. MyApp.xcodeproj)
    local xcode_escaped="${xcode_project//./\\.}"
    sed -i '' "s/__PROJECT__\.xcodeproj/${xcode_escaped}/g" "$dest"

    # 2. Branch naming: remove EDIT comment, replace placeholder
    sed -i '' '/<!-- EDIT: Set your branch naming convention below -->/d' "$dest"
    sed -i '' "s/<your-name>/${user_name}/g" "$dest"

    # 3. CLAUDE.md symlink
    if [[ "$has_symlink" == true ]]; then
        # Remove the EDIT comment line
        sed -i '' '/<!-- EDIT: If your project has CLAUDE.md as a symlink/d' "$dest"
        # Uncomment the note: remove leading "<!-- " and trailing " -->"
        sed -i '' 's/^<!-- \(> \*\*Note:\*\*.*\) -->$/\1/' "$dest"
    else
        # Remove both the EDIT comment and the commented-out note
        sed -i '' '/<!-- EDIT: If your project has CLAUDE.md as a symlink/d' "$dest"
        sed -i '' '/<!-- > \*\*Note:\*\* .CLAUDE\.md. is a symlink/d' "$dest"
    fi

    echo ""
    success "Created ${dest}"
    echo -e "    Xcode project: ${BOLD}${xcode_project}${NC}"
    echo -e "    Branch prefix:  ${BOLD}${user_name}/{ticket-and-small-title}${NC}"
    if [[ "$has_symlink" == true ]]; then
        echo -e "    Symlink note:   ${GREEN}enabled${NC} (CLAUDE.md → AGENTS.md)"
    fi
}

# ---------------------------------------------------------------------------
# Phase 1: Welcome & System Check
# ---------------------------------------------------------------------------
phase_welcome() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                                                          ║${NC}"
    echo -e "${BOLD}║   🛠️  Claude Code iOS Development Setup                  ║${NC}"
    echo -e "${BOLD}║                                                          ║${NC}"
    echo -e "${BOLD}║   Configures Claude Code with MCP servers, plugins,      ║${NC}"
    echo -e "${BOLD}║   skills, and hooks for iOS development.                 ║${NC}"
    echo -e "${BOLD}║                                                          ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # System checks
    if [[ "$(uname -s)" != "Darwin" ]]; then
        error "This script requires macOS. Detected: $(uname -s)"
        exit 1
    fi

    if [[ "$(id -u)" -eq 0 ]]; then
        error "Do not run this script as root."
        exit 1
    fi

    local arch
    arch=$(uname -m)
    info "Detected macOS on ${arch}"

    if xcode-select -p >/dev/null 2>&1; then
        info "Xcode Command Line Tools: installed"
    else
        warn "Xcode Command Line Tools not found."
        echo "  Install them with: xcode-select --install"
        echo "  Then re-run this script."
        exit 1
    fi

    echo ""
    info "Let's configure your setup. For each item, choose whether to install."
    info "Required dependencies are auto-selected based on your choices."
}

# ---------------------------------------------------------------------------
# Phase 2: Interactive Selection
# ---------------------------------------------------------------------------
phase_selection() {

    # === Category A: MCP Servers ===
    header "🔌 MCP Servers"
    echo -e "  ${DIM}MCP (Model Context Protocol) servers give Claude specialized capabilities.${NC}"
    echo ""

    echo -e "  ${BOLD}1. XcodeBuildMCP${NC}"
    echo -e "     Build, test, and run iOS/macOS apps directly from Claude via Xcode."
    if ask_yn "Install XcodeBuildMCP?"; then
        INSTALL_MCP_XCODEBUILD=1
    fi
    echo ""

    echo -e "  ${BOLD}2. Sosumi${NC}"
    echo -e "     Search and fetch Apple Developer documentation in real-time."
    if ask_yn "Install Sosumi?"; then
        INSTALL_MCP_SOSUMI=1
    fi
    echo ""

    echo -e "  ${BOLD}3. Serena${NC}"
    echo -e "     Semantic code navigation, symbol editing, and persistent memory via LSP."
    if ask_yn "Install Serena?"; then
        INSTALL_MCP_SERENA=1
    fi
    echo ""

    echo -e "  ${BOLD}4. docs-mcp-server${NC}"
    echo -e "     Semantic search over documentation and Serena memories using local Ollama embeddings."
    if ask_yn "Install docs-mcp-server?"; then
        INSTALL_MCP_DOCS=1
    fi
    echo ""

    echo -e "  ${BOLD}5. mcp-omnisearch${NC}"
    echo -e "     AI-powered web search via Perplexity. Requires a Perplexity API key."
    if ask_yn "Install mcp-omnisearch?"; then
        INSTALL_MCP_OMNISEARCH=1
        echo -ne "     Enter your Perplexity API key (or press Enter to add later): "
        read -r PERPLEXITY_API_KEY
        if [[ -z "$PERPLEXITY_API_KEY" ]]; then
            warn "No API key provided. You can add it later in ~/.claude.json"
            PERPLEXITY_API_KEY="__ADD_YOUR_PERPLEXITY_API_KEY__"
        fi
    fi

    # === Category B: Plugins ===
    header "🧩 Plugins"
    echo -e "  ${DIM}Plugins extend Claude Code with specialized capabilities.${NC}"
    echo ""

    echo -e "  ${BOLD}1. explanatory-output-style${NC}"
    echo -e "     Enhanced output with educational insights and structured formatting."
    if ask_yn "Install explanatory-output-style?"; then
        INSTALL_PLUGIN_EXPLANATORY=1
    fi
    echo ""

    echo -e "  ${BOLD}2. pr-review-toolkit${NC}"
    echo -e "     Specialized PR review agents: code-reviewer, silent-failure-hunter, type-design-analyzer."
    if ask_yn "Install pr-review-toolkit?"; then
        INSTALL_PLUGIN_PR_REVIEW=1
    fi
    echo ""

    echo -e "  ${BOLD}3. code-simplifier${NC}"
    echo -e "     Simplifies and refines code for clarity, consistency, and maintainability."
    if ask_yn "Install code-simplifier?"; then
        INSTALL_PLUGIN_SIMPLIFIER=1
    fi
    echo ""

    echo -e "  ${BOLD}4. ralph-loop${NC}"
    echo -e "     Iterative refinement loop for complex multi-step tasks."
    if ask_yn "Install ralph-loop?"; then
        INSTALL_PLUGIN_RALPH=1
    fi
    echo ""

    echo -e "  ${BOLD}5. claude-hud${NC}"
    echo -e "     Status line HUD showing real-time session info (cost, tokens, etc.)."
    if ask_yn "Install claude-hud?"; then
        INSTALL_PLUGIN_HUD=1
    fi
    echo ""

    echo -e "  ${BOLD}6. claude-md-management${NC}"
    echo -e "     Audit and improve CLAUDE.md files across your repositories."
    if ask_yn "Install claude-md-management?"; then
        INSTALL_PLUGIN_CLAUDE_MD=1
    fi

    # === Category C: Skills ===
    header "📚 Skills"
    echo -e "  ${DIM}Skills provide specialized knowledge and workflows.${NC}"
    echo ""

    echo -e "  ${BOLD}1. continuous-learning${NC} ${DIM}(custom)${NC}"
    echo -e "     Automatically extracts learnings and decisions from sessions into Serena memory."
    if ask_yn "Install continuous-learning?"; then
        INSTALL_SKILL_LEARNING=1
    fi
    echo ""

    echo -e "  ${BOLD}2. xcodebuildmcp${NC}"
    echo -e "     Official XcodeBuildMCP skill with guidance for 190+ iOS/macOS dev tools."
    if ask_yn "Install xcodebuildmcp skill?"; then
        INSTALL_SKILL_XCODEBUILD=1
    fi
    echo ""

    # === Category D: Commands ===
    header "⌨️  Commands"
    echo -e "  ${DIM}Custom slash commands for Claude Code (installed to ~/.claude/commands/).${NC}"
    echo ""

    echo -e "  ${BOLD}1. /pr${NC} — Create Pull Request"
    echo -e "     Automates stage → commit → push → PR creation with ticket extraction."
    if ask_yn "Install /pr command?"; then
        INSTALL_CMD_PR=1
    fi

    # === Category E: Configuration ===
    header "⚙️  Configuration"
    echo -e "  ${DIM}Hooks and settings that enhance every Claude Code session.${NC}"
    echo ""

    echo -e "  ${BOLD}1. Session hooks${NC}"
    echo -e "     On session start: shows git status, branch protection, simulator, Ollama status, open PRs."
    echo -e "     On each prompt: reminds to evaluate learnings for continuous-learning memory."
    if ask_yn "Install session hooks?"; then
        INSTALL_HOOKS=1
    fi
    echo ""

    echo -e "  ${BOLD}2. Settings${NC}"
    echo -e "     Plan mode by default, always-thinking enabled, MCP timeouts, Haiku→Sonnet override."
    if ask_yn "Apply recommended settings?"; then
        INSTALL_SETTINGS=1
    fi

    # === Ask for user name if needed by commands or project config ===
    if [[ $INSTALL_CMD_PR -eq 1 ]]; then
        echo ""
        echo -e "  ${BOLD}Your name${NC} (used for branch naming in commands, e.g. ${DIM}bruno${NC}):"
        echo -ne "  > "
        read -r USER_NAME
        if [[ -z "$USER_NAME" ]]; then
            warn "No name entered — you can set it later in the command files."
        fi
    fi

    # === Resolve dependencies ===
    resolve_dependencies

    # === Optional: Claude Code ===
    header "📦 Claude Code"
    if check_command claude; then
        info "Claude Code is already installed."
        INSTALL_CLAUDE_CODE=0
    else
        echo -e "  ${BOLD}Claude Code${NC} is not installed."
        if ask_yn "Install Claude Code via Homebrew?"; then
            INSTALL_CLAUDE_CODE=1
        else
            warn "Claude Code is required for MCP servers and plugins."
            warn "Install it manually: brew install --cask claude-code"
        fi
    fi
}

resolve_dependencies() {
    # Auto-determine required dependencies based on selections
    local needs_node=false
    local needs_uv=false
    local needs_ollama=false
    local needs_jq=false

    # Node.js is needed for any npx-based MCP server or skill
    if [[ $INSTALL_MCP_XCODEBUILD -eq 1 || $INSTALL_MCP_DOCS -eq 1 || \
          $INSTALL_MCP_OMNISEARCH -eq 1 || $INSTALL_SKILL_XCODEBUILD -eq 1 ]]; then
        needs_node=true
    fi

    # uv is needed for Serena
    if [[ $INSTALL_MCP_SERENA -eq 1 ]]; then
        needs_uv=true
    fi

    # Ollama is needed for docs-mcp-server
    if [[ $INSTALL_MCP_DOCS -eq 1 ]]; then
        needs_ollama=true
    fi

    # jq is needed for settings merge
    if [[ $INSTALL_SETTINGS -eq 1 ]]; then
        needs_jq=true
    fi

    # Check what's already installed
    if $needs_node && ! check_command node; then
        INSTALL_NODE=1
    fi
    if $needs_uv && ! check_command uvx; then
        INSTALL_UV=1
    fi
    if $needs_ollama && ! check_command ollama; then
        INSTALL_OLLAMA=1
    fi
    if $needs_jq && ! check_command jq; then
        INSTALL_JQ=1
    fi

    # Homebrew is needed if any brew package needs installing
    if [[ $INSTALL_NODE -eq 1 || $INSTALL_UV -eq 1 || $INSTALL_OLLAMA -eq 1 || \
          $INSTALL_JQ -eq 1 || $INSTALL_CLAUDE_CODE -eq 1 ]]; then
        if ! check_command brew; then
            INSTALL_HOMEBREW=1
        fi
    fi

    # Also install gh if not present (optional but useful)
    if ! check_command gh; then
        INSTALL_GH=1
    fi
}

# ---------------------------------------------------------------------------
# Phase 3: Summary & Confirmation
# ---------------------------------------------------------------------------
phase_summary() {
    header "📋 Installation Summary"

    local has_deps=false
    local has_mcps=false
    local has_plugins=false
    local has_skills=false
    local has_commands=false
    local has_config=false

    # Dependencies
    if [[ $INSTALL_HOMEBREW -eq 1 || $INSTALL_NODE -eq 1 || $INSTALL_JQ -eq 1 || \
          $INSTALL_GH -eq 1 || $INSTALL_UV -eq 1 || $INSTALL_OLLAMA -eq 1 || \
          $INSTALL_CLAUDE_CODE -eq 1 ]]; then
        has_deps=true
        echo ""
        echo -e "  ${BOLD}Dependencies:${NC}"
        [[ $INSTALL_HOMEBREW -eq 1 ]]    && echo -e "    ✅ Homebrew (package manager)"
        [[ $INSTALL_NODE -eq 1 ]]        && echo -e "    ✅ Node.js (for npx-based MCP servers)"
        [[ $INSTALL_JQ -eq 1 ]]          && echo -e "    ✅ jq (JSON processor)"
        [[ $INSTALL_GH -eq 1 ]]          && echo -e "    ✅ gh (GitHub CLI)"
        [[ $INSTALL_UV -eq 1 ]]          && echo -e "    ✅ uv (Python package manager, for Serena)"
        [[ $INSTALL_OLLAMA -eq 1 ]]      && echo -e "    ✅ Ollama + mxbai-embed-large model"
        [[ $INSTALL_CLAUDE_CODE -eq 1 ]] && echo -e "    ✅ Claude Code"
    fi

    # MCP Servers
    if [[ $INSTALL_MCP_XCODEBUILD -eq 1 || $INSTALL_MCP_SOSUMI -eq 1 || \
          $INSTALL_MCP_SERENA -eq 1 || $INSTALL_MCP_DOCS -eq 1 || \
          $INSTALL_MCP_OMNISEARCH -eq 1 ]]; then
        has_mcps=true
        echo ""
        echo -e "  ${BOLD}MCP Servers:${NC}"
        [[ $INSTALL_MCP_XCODEBUILD -eq 1 ]] && echo -e "    ✅ XcodeBuildMCP"
        [[ $INSTALL_MCP_SOSUMI -eq 1 ]]     && echo -e "    ✅ Sosumi (Apple docs)"
        [[ $INSTALL_MCP_SERENA -eq 1 ]]     && echo -e "    ✅ Serena (code intelligence)"
        [[ $INSTALL_MCP_DOCS -eq 1 ]]       && echo -e "    ✅ docs-mcp-server (semantic search)"
        [[ $INSTALL_MCP_OMNISEARCH -eq 1 ]] && echo -e "    ✅ mcp-omnisearch (Perplexity)"
    fi

    # Plugins
    if [[ $INSTALL_PLUGIN_EXPLANATORY -eq 1 || $INSTALL_PLUGIN_PR_REVIEW -eq 1 || \
          $INSTALL_PLUGIN_SIMPLIFIER -eq 1 || $INSTALL_PLUGIN_RALPH -eq 1 || \
          $INSTALL_PLUGIN_HUD -eq 1 || $INSTALL_PLUGIN_CLAUDE_MD -eq 1 ]]; then
        has_plugins=true
        echo ""
        echo -e "  ${BOLD}Plugins:${NC}"
        [[ $INSTALL_PLUGIN_EXPLANATORY -eq 1 ]] && echo -e "    ✅ explanatory-output-style"
        [[ $INSTALL_PLUGIN_PR_REVIEW -eq 1 ]]   && echo -e "    ✅ pr-review-toolkit"
        [[ $INSTALL_PLUGIN_SIMPLIFIER -eq 1 ]]  && echo -e "    ✅ code-simplifier"
        [[ $INSTALL_PLUGIN_RALPH -eq 1 ]]       && echo -e "    ✅ ralph-loop"
        [[ $INSTALL_PLUGIN_HUD -eq 1 ]]         && echo -e "    ✅ claude-hud"
        [[ $INSTALL_PLUGIN_CLAUDE_MD -eq 1 ]]   && echo -e "    ✅ claude-md-management"
    fi

    # Skills
    if [[ $INSTALL_SKILL_LEARNING -eq 1 || $INSTALL_SKILL_XCODEBUILD -eq 1 ]]; then
        has_skills=true
        echo ""
        echo -e "  ${BOLD}Skills:${NC}"
        [[ $INSTALL_SKILL_LEARNING -eq 1 ]]    && echo -e "    ✅ continuous-learning (custom)"
        [[ $INSTALL_SKILL_XCODEBUILD -eq 1 ]]  && echo -e "    ✅ xcodebuildmcp"
    fi

    # Commands
    if [[ $INSTALL_CMD_PR -eq 1 ]]; then
        has_commands=true
        echo ""
        echo -e "  ${BOLD}Commands:${NC}"
        [[ $INSTALL_CMD_PR -eq 1 ]] && echo -e "    ✅ /pr (create pull request)"
    fi

    # Configuration
    if [[ $INSTALL_HOOKS -eq 1 || $INSTALL_SETTINGS -eq 1 ]]; then
        has_config=true
        echo ""
        echo -e "  ${BOLD}Configuration:${NC}"
        [[ $INSTALL_HOOKS -eq 1 ]]    && echo -e "    ✅ Session hooks (session_start + continuous-learning-activator)"
        [[ $INSTALL_SETTINGS -eq 1 ]] && echo -e "    ✅ Settings (plan mode, always-thinking, env vars, timeouts)"
    fi

    if ! $has_deps && ! $has_mcps && ! $has_plugins && ! $has_skills && ! $has_commands && ! $has_config; then
        warn "Nothing selected to install."
        exit 0
    fi

    echo ""
    echo -e "${DIM}──────────────────────────────────────────${NC}"
    if ! ask_yn "Proceed with installation?" "Y"; then
        info "Installation cancelled."
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Phase 4: Installation
# ---------------------------------------------------------------------------
phase_install() {
    local total_steps=0
    local current_step=0

    # Count total steps
    [[ $INSTALL_HOMEBREW -eq 1 ]] && ((total_steps++))
    [[ $INSTALL_NODE -eq 1 || $INSTALL_JQ -eq 1 || $INSTALL_GH -eq 1 || $INSTALL_UV -eq 1 ]] && ((total_steps++))
    [[ $INSTALL_OLLAMA -eq 1 ]] && ((total_steps++))
    [[ $INSTALL_CLAUDE_CODE -eq 1 ]] && ((total_steps++))
    [[ $INSTALL_MCP_XCODEBUILD -eq 1 || $INSTALL_MCP_SOSUMI -eq 1 || $INSTALL_MCP_SERENA -eq 1 || \
       $INSTALL_MCP_DOCS -eq 1 || $INSTALL_MCP_OMNISEARCH -eq 1 ]] && ((total_steps++))
    [[ $INSTALL_PLUGIN_EXPLANATORY -eq 1 || $INSTALL_PLUGIN_PR_REVIEW -eq 1 || \
       $INSTALL_PLUGIN_SIMPLIFIER -eq 1 || $INSTALL_PLUGIN_RALPH -eq 1 || \
       $INSTALL_PLUGIN_HUD -eq 1 || $INSTALL_PLUGIN_CLAUDE_MD -eq 1 ]] && ((total_steps++))
    [[ $INSTALL_SKILL_LEARNING -eq 1 || $INSTALL_SKILL_XCODEBUILD -eq 1 ]] && ((total_steps++))
    [[ $INSTALL_CMD_PR -eq 1 ]] && ((total_steps++))
    [[ $INSTALL_HOOKS -eq 1 ]] && ((total_steps++))
    [[ $INSTALL_SETTINGS -eq 1 ]] && ((total_steps++))

    header "🚀 Installing..."

    # --- Homebrew ---
    if [[ $INSTALL_HOMEBREW -eq 1 ]]; then
        ((current_step++))
        step $current_step $total_steps "Installing Homebrew"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        ensure_brew_in_path
        INSTALLED_ITEMS+=("Homebrew")
        success "Homebrew installed"
    else
        ensure_brew_in_path
    fi

    # --- Brew packages ---
    if [[ $INSTALL_NODE -eq 1 || $INSTALL_JQ -eq 1 || $INSTALL_GH -eq 1 || $INSTALL_UV -eq 1 ]]; then
        ((current_step++))
        step $current_step $total_steps "Installing Homebrew packages"

        if [[ $INSTALL_NODE -eq 1 ]]; then
            info "Installing Node.js..."
            brew install node
            INSTALLED_ITEMS+=("Node.js")
            success "Node.js installed"
        fi

        if [[ $INSTALL_JQ -eq 1 ]]; then
            info "Installing jq..."
            brew install jq
            INSTALLED_ITEMS+=("jq")
            success "jq installed"
        fi

        if [[ $INSTALL_GH -eq 1 ]]; then
            info "Installing GitHub CLI..."
            brew install gh
            INSTALLED_ITEMS+=("gh")
            success "GitHub CLI installed"
        fi

        if [[ $INSTALL_UV -eq 1 ]]; then
            info "Installing uv..."
            brew install uv
            INSTALLED_ITEMS+=("uv")
            success "uv installed"
        fi
    fi

    # --- Ollama ---
    if [[ $INSTALL_OLLAMA -eq 1 ]]; then
        ((current_step++))
        step $current_step $total_steps "Setting up Ollama"

        if ! check_command ollama; then
            info "Installing Ollama..."
            brew install ollama
            INSTALLED_ITEMS+=("Ollama")
            success "Ollama installed"
        fi

        # Register Ollama as a brew service (auto-starts on login)
        if ! brew services list 2>/dev/null | grep -q "ollama.*started"; then
            info "Starting Ollama as a brew service..."
            brew services start ollama
        fi

        # Wait for Ollama to be ready
        if ! curl -s --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
            local attempts=0
            while ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; do
                ((attempts++))
                if [[ $attempts -ge 30 ]]; then
                    warn "Ollama did not start in time. Check with: brew services info ollama"
                    break
                fi
                sleep 1
            done
        fi

        # Pull embedding model
        info "Pulling mxbai-embed-large model (this may take a few minutes)..."
        ollama pull mxbai-embed-large
        INSTALLED_ITEMS+=("mxbai-embed-large model")
        success "Ollama ready with mxbai-embed-large"
    fi

    # --- Claude Code ---
    if [[ $INSTALL_CLAUDE_CODE -eq 1 ]]; then
        ((current_step++))
        step $current_step $total_steps "Installing Claude Code"
        brew install --cask claude-code
        CLAUDE_FRESH_INSTALL=true
        INSTALLED_ITEMS+=("Claude Code")
        success "Claude Code installed"
    fi

    # Ensure Claude directories exist
    mkdir -p "$CLAUDE_DIR" "$CLAUDE_HOOKS_DIR" "$CLAUDE_SKILLS_DIR"

    # --- MCP Servers ---
    if [[ $INSTALL_MCP_XCODEBUILD -eq 1 || $INSTALL_MCP_SOSUMI -eq 1 || \
          $INSTALL_MCP_SERENA -eq 1 || $INSTALL_MCP_DOCS -eq 1 || \
          $INSTALL_MCP_OMNISEARCH -eq 1 ]]; then
        ((current_step++))
        step $current_step $total_steps "Configuring MCP Servers"

        # Check if claude CLI is available
        if ! check_command claude; then
            warn "Claude Code CLI not found. Skipping MCP server configuration."
            warn "Install Claude Code and re-run, or configure MCP servers manually."
        else
            # Backup claude.json before MCP changes (unless fresh install)
            if [[ "$CLAUDE_FRESH_INSTALL" == "false" ]] && [[ -f "$CLAUDE_JSON" ]]; then
                backup_file "$CLAUDE_JSON"
            fi

            if [[ $INSTALL_MCP_XCODEBUILD -eq 1 ]]; then
                info "Adding XcodeBuildMCP..."
                claude_cli mcp add -s user \
                    -e XCODEBUILDMCP_SENTRY_DISABLED=1 \
                    XcodeBuildMCP -- npx -y xcodebuildmcp@latest mcp 2>/dev/null || true
                INSTALLED_ITEMS+=("MCP: XcodeBuildMCP")
                success "XcodeBuildMCP configured"
            fi

            if [[ $INSTALL_MCP_SOSUMI -eq 1 ]]; then
                info "Adding Sosumi..."
                claude_cli mcp add -s user \
                    --transport http \
                    sosumi https://sosumi.ai/mcp 2>/dev/null || true
                INSTALLED_ITEMS+=("MCP: Sosumi")
                success "Sosumi configured"
            fi

            if [[ $INSTALL_MCP_SERENA -eq 1 ]]; then
                info "Adding Serena..."
                claude_cli mcp add -s user \
                    serena -- uvx --from "git+https://github.com/oraios/serena" \
                    serena start-mcp-server --context=claude-code --project-from-cwd 2>/dev/null || true
                INSTALLED_ITEMS+=("MCP: Serena")
                success "Serena configured"
            fi

            if [[ $INSTALL_MCP_DOCS -eq 1 ]]; then
                info "Adding docs-mcp-server..."
                claude_cli mcp add -s user \
                    -e OPENAI_API_KEY=ollama \
                    -e OPENAI_API_BASE=http://localhost:11434/v1 \
                    -e DOCS_MCP_EMBEDDING_MODEL=openai:mxbai-embed-large \
                    docs-mcp-server -- npx -y @arabold/docs-mcp-server@latest --read-only --telemetry=false 2>/dev/null || true
                INSTALLED_ITEMS+=("MCP: docs-mcp-server")
                success "docs-mcp-server configured"
            fi

            if [[ $INSTALL_MCP_OMNISEARCH -eq 1 ]]; then
                info "Adding mcp-omnisearch..."
                claude_cli mcp add -s user \
                    -e "PERPLEXITY_API_KEY=${PERPLEXITY_API_KEY}" \
                    mcp-omnisearch -- npx -y mcp-omnisearch 2>/dev/null || true
                INSTALLED_ITEMS+=("MCP: mcp-omnisearch")
                success "mcp-omnisearch configured"
            fi
        fi
    fi

    # --- Plugins ---
    if [[ $INSTALL_PLUGIN_EXPLANATORY -eq 1 || $INSTALL_PLUGIN_PR_REVIEW -eq 1 || \
          $INSTALL_PLUGIN_SIMPLIFIER -eq 1 || $INSTALL_PLUGIN_RALPH -eq 1 || \
          $INSTALL_PLUGIN_HUD -eq 1 || $INSTALL_PLUGIN_CLAUDE_MD -eq 1 ]]; then
        ((current_step++))
        step $current_step $total_steps "Installing Plugins"

        if ! check_command claude; then
            warn "Claude Code CLI not found. Skipping plugin installation."
        else
            # Add required marketplaces
            info "Adding plugin marketplaces..."
            claude_cli plugin marketplace add anthropics/claude-plugins-official 2>/dev/null || true

            if [[ $INSTALL_PLUGIN_HUD -eq 1 ]]; then
                claude_cli plugin marketplace add jarrodwatts/claude-hud 2>/dev/null || true
            fi

            if [[ $INSTALL_PLUGIN_EXPLANATORY -eq 1 ]]; then
                info "Installing explanatory-output-style..."
                claude_cli plugin install explanatory-output-style@claude-plugins-official 2>/dev/null || true
                INSTALLED_ITEMS+=("Plugin: explanatory-output-style")
                success "explanatory-output-style installed"
            fi

            if [[ $INSTALL_PLUGIN_PR_REVIEW -eq 1 ]]; then
                info "Installing pr-review-toolkit..."
                claude_cli plugin install pr-review-toolkit@claude-plugins-official 2>/dev/null || true
                INSTALLED_ITEMS+=("Plugin: pr-review-toolkit")
                success "pr-review-toolkit installed"
            fi

            if [[ $INSTALL_PLUGIN_SIMPLIFIER -eq 1 ]]; then
                info "Installing code-simplifier..."
                claude_cli plugin install code-simplifier@claude-plugins-official 2>/dev/null || true
                INSTALLED_ITEMS+=("Plugin: code-simplifier")
                success "code-simplifier installed"
            fi

            if [[ $INSTALL_PLUGIN_RALPH -eq 1 ]]; then
                info "Installing ralph-loop..."
                claude_cli plugin install ralph-loop@claude-plugins-official 2>/dev/null || true
                INSTALLED_ITEMS+=("Plugin: ralph-loop")
                success "ralph-loop installed"
            fi

            if [[ $INSTALL_PLUGIN_HUD -eq 1 ]]; then
                info "Installing claude-hud..."
                claude_cli plugin install claude-hud@claude-hud 2>/dev/null || true
                INSTALLED_ITEMS+=("Plugin: claude-hud")
                success "claude-hud installed"
            fi

            if [[ $INSTALL_PLUGIN_CLAUDE_MD -eq 1 ]]; then
                info "Installing claude-md-management..."
                claude_cli plugin install claude-md-management@claude-plugins-official 2>/dev/null || true
                INSTALLED_ITEMS+=("Plugin: claude-md-management")
                success "claude-md-management installed"
            fi
        fi
    fi

    # --- Skills ---
    if [[ $INSTALL_SKILL_LEARNING -eq 1 || $INSTALL_SKILL_XCODEBUILD -eq 1 ]]; then
        ((current_step++))
        step $current_step $total_steps "Installing Skills"

        if [[ $INSTALL_SKILL_LEARNING -eq 1 ]]; then
            info "Installing continuous-learning skill..."
            mkdir -p "$CLAUDE_SKILLS_DIR/continuous-learning/references"
            cp "$SCRIPT_DIR/skills/continuous-learning/SKILL.md" \
               "$CLAUDE_SKILLS_DIR/continuous-learning/SKILL.md"
            cp "$SCRIPT_DIR/skills/continuous-learning/references/templates.md" \
               "$CLAUDE_SKILLS_DIR/continuous-learning/references/templates.md"
            INSTALLED_ITEMS+=("Skill: continuous-learning")
            success "continuous-learning skill installed"
        fi

        if [[ $INSTALL_SKILL_XCODEBUILD -eq 1 ]]; then
            info "Installing xcodebuildmcp skill..."
            npx skills add cameroncooke/xcodebuildmcp 2>/dev/null || {
                warn "Failed to install xcodebuildmcp skill via npx. You can try manually: npx skills add cameroncooke/xcodebuildmcp"
            }
            # Symlink into claude skills if installed in ~/.agents/skills
            if [[ -d "$HOME/.agents/skills/xcodebuildmcp" ]] && [[ ! -e "$CLAUDE_SKILLS_DIR/xcodebuildmcp" ]]; then
                ln -sf "$HOME/.agents/skills/xcodebuildmcp" "$CLAUDE_SKILLS_DIR/xcodebuildmcp"
            fi
            INSTALLED_ITEMS+=("Skill: xcodebuildmcp")
            success "xcodebuildmcp skill installed"
        fi

    fi

    # --- Commands ---
    if [[ $INSTALL_CMD_PR -eq 1 ]]; then
        ((current_step++))
        step $current_step $total_steps "Installing Commands"

        local commands_dir="$HOME/.claude/commands"
        mkdir -p "$commands_dir"

        if [[ $INSTALL_CMD_PR -eq 1 ]]; then
            info "Installing /pr command..."
            cp "$SCRIPT_DIR/commands/pr.md" "$commands_dir/pr.md"
            # Replace user name placeholder if provided
            if [[ -n "$USER_NAME" ]]; then
                sed -i '' "s/__USER_NAME__/${USER_NAME}/g" "$commands_dir/pr.md"
            fi
            INSTALLED_ITEMS+=("Command: /pr")
            success "/pr command installed"
        fi
    fi

    # --- Hooks ---
    if [[ $INSTALL_HOOKS -eq 1 ]]; then
        ((current_step++))
        step $current_step $total_steps "Installing Hooks"

        mkdir -p "$CLAUDE_HOOKS_DIR"

        cp "$SCRIPT_DIR/hooks/session_start.sh" "$CLAUDE_HOOKS_DIR/session_start.sh"
        chmod +x "$CLAUDE_HOOKS_DIR/session_start.sh"

        cp "$SCRIPT_DIR/hooks/continuous-learning-activator.sh" "$CLAUDE_HOOKS_DIR/continuous-learning-activator.sh"
        chmod +x "$CLAUDE_HOOKS_DIR/continuous-learning-activator.sh"

        INSTALLED_ITEMS+=("Hooks: session_start + continuous-learning-activator")
        success "Hooks installed"
    fi

    # --- Settings ---
    if [[ $INSTALL_SETTINGS -eq 1 ]]; then
        ((current_step++))
        step $current_step $total_steps "Applying Settings"

        if [[ -f "$CLAUDE_SETTINGS" ]]; then
            backup_file "$CLAUDE_SETTINGS"
            # Merge settings: our config on top of existing
            if check_command jq; then
                local merged
                merged=$(jq -s '.[0] * .[1]' "$CLAUDE_SETTINGS" "$SCRIPT_DIR/config/settings.json" 2>/dev/null) || {
                    warn "Failed to merge settings. Overwriting with new settings."
                    merged=$(cat "$SCRIPT_DIR/config/settings.json")
                }
                echo "$merged" > "$CLAUDE_SETTINGS"
            else
                cp "$SCRIPT_DIR/config/settings.json" "$CLAUDE_SETTINGS"
            fi
        else
            cp "$SCRIPT_DIR/config/settings.json" "$CLAUDE_SETTINGS"
        fi

        INSTALLED_ITEMS+=("Settings: env vars, plan mode, hooks config, plugins")
        success "Settings applied"
    fi

}

# ---------------------------------------------------------------------------
# Phase 5: Post-install Summary
# ---------------------------------------------------------------------------
phase_summary_post() {
    header "✅ Setup Complete!"

    if [[ ${#INSTALLED_ITEMS[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Installed:${NC}"
        for item in "${INSTALLED_ITEMS[@]}"; do
            echo -e "    ${GREEN}✓${NC} $item"
        done
    fi

    if [[ ${#SKIPPED_ITEMS[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Skipped (already present):${NC}"
        for item in "${SKIPPED_ITEMS[@]}"; do
            echo -e "    ${DIM}○ $item${NC}"
        done
    fi

    echo ""
    echo -e "  ${BOLD}Next Steps:${NC}"
    echo ""

    local step_num=1

    echo -e "    ${step_num}. ${BOLD}Restart your terminal${NC} to pick up PATH changes"
    echo ""
    ((step_num++))

    if [[ "$CLAUDE_FRESH_INSTALL" == "true" ]]; then
        echo -e "    ${step_num}. Run ${BOLD}claude${NC} and authenticate with your Anthropic account"
        echo ""
        ((step_num++))
    fi

    echo -e "    ${step_num}. Configure ${BOLD}CLAUDE.local.md${NC} for your iOS project(s)"
    echo -e "       ${DIM}Detects your Xcode project, sets branch naming, and applies the template.${NC}"
    if [[ $INSTALL_MCP_SERENA -eq 1 ]]; then
        echo -e "       ${DIM}ℹ  Serena config is auto-generated on first run in each project.${NC}"
    fi
    echo ""

    if ask_yn "Configure a project now?"; then
        configure_project
        # Offer to configure additional projects
        while ask_yn "Configure another project?" "N"; do
            configure_project
        done
    else
        echo ""
        echo -e "       ${DIM}You can configure projects later by re-running:${NC}"
        echo -e "       ${SCRIPT_DIR}/setup.sh --configure-project"
    fi
    echo ""

    ((step_num++))

    if [[ "$PERPLEXITY_API_KEY" == "__ADD_YOUR_PERPLEXITY_API_KEY__" ]]; then
        echo -e "    ${step_num}. Add your Perplexity API key to mcp-omnisearch:"
        echo -e "       Edit ${BOLD}~/.claude.json${NC} → mcpServers → mcp-omnisearch → env → PERPLEXITY_API_KEY"
        echo ""
        ((step_num++))
    fi

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Happy coding! 🚀"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Support --configure-project flag for standalone project setup
if [[ "${1:-}" == "--configure-project" ]]; then
    header "📱 Configure Project"
    configure_project
    while ask_yn "Configure another project?" "N"; do
        configure_project
    done
    echo ""
    exit 0
fi

main() {
    phase_welcome
    phase_selection
    phase_summary
    phase_install
    phase_summary_post
}

main
