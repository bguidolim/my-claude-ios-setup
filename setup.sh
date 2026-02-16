#!/bin/bash
# =============================================================================
# Claude Code iOS Development Setup
# =============================================================================
# Portable, interactive setup script for Claude Code with iOS development tools.
# Installs MCP servers, plugins, skills, hooks, and configuration.
#
# Usage: ./setup.sh                      # Interactive setup (pick components)
#        ./setup.sh --all                 # Install everything (minimal prompts)
#        ./setup.sh doctor [--fix]        # Diagnose installation health
#        ./setup.sh configure-project     # Configure CLAUDE.local.md for a project
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

# User identity (used in commands and project config)
USER_NAME=""

# Full install mode (--all flag)
INSTALL_ALL=0

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
        local answer
        read -r answer
        answer=${answer:-$default}
        case "$answer" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO])     return 1 ;;
            *)                  echo "  Please answer y or n." ;;
        esac
    done
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Run a command, capturing stderr. On failure, warn instead of crashing.
# Usage: try_install "Label" command args...
try_install() {
    local label=$1
    shift
    local err_output
    if err_output=$("$@" 2>&1); then
        INSTALLED_ITEMS+=("$label")
        return 0
    else
        warn "Failed to install $label"
        [[ -n "$err_output" ]] && echo -e "  ${DIM}${err_output}${NC}" | head -3
        SKIPPED_ITEMS+=("$label (failed)")
        return 1
    fi
}

# Escape a string for use in sed replacement (handles /, &, \)
sed_escape() {
    printf '%s' "$1" | sed 's/[&/\]/\\&/g'
}

backup_file() {
    local file=$1
    if [[ -f "$file" ]]; then
        local backup="${file}.${BACKUP_SUFFIX}"
        cp "$file" "$backup"
        info "Backed up $(basename "$file") → $(basename "$backup")"
    fi
}

# Hash a file for manifest tracking (sha256, macOS compatible)
file_hash() {
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
}

# Record a source→installed mapping in the manifest
# Usage: manifest_record "relative/source/path"
manifest_record() {
    local rel_path=$1
    local hash
    hash=$(file_hash "$SCRIPT_DIR/$rel_path")
    # Remove old entry if present, then append
    if [[ -f "$SETUP_MANIFEST" ]]; then
        grep -v "^${rel_path}=" "$SETUP_MANIFEST" > "${SETUP_MANIFEST}.tmp" 2>/dev/null || true
        mv "${SETUP_MANIFEST}.tmp" "$SETUP_MANIFEST"
    fi
    echo "${rel_path}=${hash}" >> "$SETUP_MANIFEST"
}

# Initialize manifest with SCRIPT_DIR header
manifest_init() {
    mkdir -p "$(dirname "$SETUP_MANIFEST")"
    echo "SCRIPT_DIR=${SCRIPT_DIR}" > "$SETUP_MANIFEST"
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

# Read an env var from an existing MCP server in ~/.claude.json
# Usage: get_mcp_env "server-name" "ENV_VAR_NAME"
# Returns the value on stdout, or empty string if not found
get_mcp_env() {
    local server=$1
    local var_name=$2
    if [[ -f "$CLAUDE_JSON" ]]; then
        if check_command jq; then
            jq -r ".mcpServers.\"${server}\".env.\"${var_name}\" // empty" "$CLAUDE_JSON" 2>/dev/null || true
        else
            # Fallback: rough grep extraction (works for simple string values)
            grep -o "\"${var_name}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CLAUDE_JSON" 2>/dev/null \
                | head -1 | sed 's/.*:.*"\(.*\)"/\1/' || true
        fi
    fi
}

# Run claude CLI without nesting check
claude_cli() {
    CLAUDECODE="" claude "$@"
}

# Add (or replace) an MCP server. Removes existing entry first to avoid
# "already exists" errors, and places the server name before -e flags
# so the variadic --env doesn't consume the name.
# Usage: mcp_add <name> [options...] [-- command args...]
mcp_add() {
    local name=$1
    shift
    claude_cli mcp remove -s user "$name" 2>/dev/null || true
    claude_cli mcp add -s user "$name" "$@"
}

# Check if Ollama service is running and the embedding model is available
ollama_fully_ready() {
    check_command ollama || return 1
    local tags
    tags=$(curl -s --max-time 3 http://localhost:11434/api/tags 2>/dev/null) || return 1
    echo "$tags" | grep -q "nomic-embed-text"
}

# ---------------------------------------------------------------------------
# Configure CLAUDE.local.md for a project
# ---------------------------------------------------------------------------
configure_project() {
    local current_dir
    current_dir=$(pwd)
    echo ""
    echo -e "  ${BOLD}Enter the path to your iOS project${NC} [${DIM}${current_dir}${NC}]${BOLD}:${NC}"
    echo -ne "  > "
    read -e -r project_path
    # Default to current directory if empty
    project_path="${project_path:-$current_dir}"
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
    local xcode_escaped
    xcode_escaped=$(sed_escape "$xcode_project")
    sed -i '' "s/__PROJECT__\.xcodeproj/${xcode_escaped}/g" "$dest"

    # 2. Branch naming: remove EDIT comment, replace placeholder
    sed -i '' '/<!-- EDIT: Set your branch naming convention below -->/d' "$dest"
    local safe_name
    safe_name=$(sed_escape "$user_name")
    sed -i '' "s/<your-name>/${safe_name}/g" "$dest"

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

    # --- Generate XcodeBuildMCP config ---
    local xbm_dir="$project_path/.xcodebuildmcp"
    local xbm_config="$xbm_dir/config.yaml"
    local xbm_template="$SCRIPT_DIR/templates/xcodebuildmcp.yaml"

    # Build expected config from template
    local xcode_escaped_xbm
    xcode_escaped_xbm=$(sed_escape "$xcode_project")
    local expected_config
    expected_config=$(sed "s/__PROJECT__/${xcode_escaped_xbm}/g" "$xbm_template")

    if [[ -f "$xbm_config" ]]; then
        local current_config
        current_config=$(<"$xbm_config")
        if [[ "$current_config" == "$expected_config" ]]; then
            info "XcodeBuildMCP config is up to date — skipping"
        else
            warn "XcodeBuildMCP config differs from template"
            if ask_yn "Overwrite .xcodebuildmcp/config.yaml with updated template?" "Y"; then
                backup_file "$xbm_config"
                echo "$expected_config" > "$xbm_config"
                success "Updated ${xbm_config}"
            else
                info "Kept existing XcodeBuildMCP config"
            fi
        fi
    else
        mkdir -p "$xbm_dir"
        echo "$expected_config" > "$xbm_config"
        success "Created ${xbm_config}"
    fi

    echo ""
    success "Project configured: ${project_path}"
    echo -e "    Xcode project:      ${BOLD}${xcode_project}${NC}"
    echo -e "    Branch prefix:      ${BOLD}${user_name}/{ticket-and-small-title}${NC}"
    echo -e "    XcodeBuildMCP:      ${BOLD}.xcodebuildmcp/config.yaml${NC}"
    if [[ "$has_symlink" == true ]]; then
        echo -e "    Symlink note:       ${GREEN}enabled${NC} (CLAUDE.md → AGENTS.md)"
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
    info "This script will ask what to install. You can also choose to install everything at once."
    info "Required dependencies are auto-resolved based on your choices."
}

# ---------------------------------------------------------------------------
# Phase 2: Interactive Selection
# ---------------------------------------------------------------------------
phase_selection() {

    # === Full install shortcut ===
    echo ""
    if [[ $INSTALL_ALL -eq 1 ]] || ask_yn "Install everything? (skip individual prompts)" "N"; then
        INSTALL_MCP_XCODEBUILD=1
        INSTALL_MCP_SOSUMI=1
        INSTALL_MCP_SERENA=1
        INSTALL_MCP_DOCS=1
        INSTALL_MCP_OMNISEARCH=1
        INSTALL_PLUGIN_EXPLANATORY=1
        INSTALL_PLUGIN_PR_REVIEW=1
        INSTALL_PLUGIN_SIMPLIFIER=1
        INSTALL_PLUGIN_RALPH=1
        INSTALL_PLUGIN_HUD=1
        INSTALL_PLUGIN_CLAUDE_MD=1
        INSTALL_SKILL_LEARNING=1
        INSTALL_SKILL_XCODEBUILD=1
        INSTALL_CMD_PR=1
        INSTALL_HOOKS=1
        INSTALL_SETTINGS=1

        # Still need the API key and user name
        echo ""
        echo -e "  ${BOLD}Your name${NC} (used for branch naming, e.g. ${DIM}bruno${NC}):"
        echo -ne "  > "
        read -r USER_NAME

        echo ""
        local existing_pplx_key
        existing_pplx_key=$(get_mcp_env "mcp-omnisearch" "PERPLEXITY_API_KEY")
        if [[ -n "$existing_pplx_key" && "$existing_pplx_key" != "__ADD_YOUR_PERPLEXITY_API_KEY__" ]]; then
            local masked_key="${existing_pplx_key:0:8}...${existing_pplx_key: -4}"
            echo -ne "  Perplexity API key for mcp-omnisearch [current: ${masked_key}] (Enter to keep): "
        else
            echo -ne "  Perplexity API key for mcp-omnisearch (Enter to skip): "
        fi
        read -r PERPLEXITY_API_KEY
        if [[ -z "$PERPLEXITY_API_KEY" ]]; then
            if [[ -n "$existing_pplx_key" && "$existing_pplx_key" != "__ADD_YOUR_PERPLEXITY_API_KEY__" ]]; then
                PERPLEXITY_API_KEY="$existing_pplx_key"
            else
                PERPLEXITY_API_KEY="__ADD_YOUR_PERPLEXITY_API_KEY__"
            fi
        fi

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
            fi
        fi
        return
    fi

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
        local existing_pplx_key
        existing_pplx_key=$(get_mcp_env "mcp-omnisearch" "PERPLEXITY_API_KEY")
        if [[ -n "$existing_pplx_key" && "$existing_pplx_key" != "__ADD_YOUR_PERPLEXITY_API_KEY__" ]]; then
            local masked_key="${existing_pplx_key:0:8}...${existing_pplx_key: -4}"
            echo -ne "     Perplexity API key [current: ${masked_key}] (Enter to keep): "
        else
            echo -ne "     Enter your Perplexity API key (or press Enter to add later): "
        fi
        read -r PERPLEXITY_API_KEY
        if [[ -z "$PERPLEXITY_API_KEY" ]]; then
            if [[ -n "$existing_pplx_key" && "$existing_pplx_key" != "__ADD_YOUR_PERPLEXITY_API_KEY__" ]]; then
                PERPLEXITY_API_KEY="$existing_pplx_key"
            else
                warn "No API key provided. You can add it later in ~/.claude.json"
                PERPLEXITY_API_KEY="__ADD_YOUR_PERPLEXITY_API_KEY__"
            fi
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
    echo -e "     Plan mode by default, always-thinking enabled, env vars, hooks config, plugins."
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

    # Install gh if /pr command is selected and not present
    if [[ $INSTALL_CMD_PR -eq 1 ]] && ! check_command gh; then
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
        [[ $INSTALL_OLLAMA -eq 1 ]]      && echo -e "    ✅ Ollama + nomic-embed-text model"
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

    # Initialize manifest for tracking installed file versions
    manifest_init

    # Pre-check: does Ollama actually need any setup work?
    # Skip the entire Ollama step when service is already running with the model.
    local ollama_setup_needed=false
    if [[ $INSTALL_OLLAMA -eq 1 ]]; then
        ollama_setup_needed=true
    elif [[ $INSTALL_MCP_DOCS -eq 1 ]] && ! ollama_fully_ready; then
        ollama_setup_needed=true
    fi

    # Count total steps (using $((x + 1)) instead of ((x++)) for bash 3.2 / set -e safety)
    [[ $INSTALL_HOMEBREW -eq 1 ]] && total_steps=$((total_steps + 1))
    [[ $INSTALL_NODE -eq 1 || $INSTALL_JQ -eq 1 || $INSTALL_GH -eq 1 || $INSTALL_UV -eq 1 ]] && total_steps=$((total_steps + 1))
    [[ "$ollama_setup_needed" == true ]] && total_steps=$((total_steps + 1))
    [[ $INSTALL_CLAUDE_CODE -eq 1 ]] && total_steps=$((total_steps + 1))
    [[ $INSTALL_MCP_XCODEBUILD -eq 1 || $INSTALL_MCP_SOSUMI -eq 1 || $INSTALL_MCP_SERENA -eq 1 || \
       $INSTALL_MCP_DOCS -eq 1 || $INSTALL_MCP_OMNISEARCH -eq 1 ]] && total_steps=$((total_steps + 1))
    [[ $INSTALL_PLUGIN_EXPLANATORY -eq 1 || $INSTALL_PLUGIN_PR_REVIEW -eq 1 || \
       $INSTALL_PLUGIN_SIMPLIFIER -eq 1 || $INSTALL_PLUGIN_RALPH -eq 1 || \
       $INSTALL_PLUGIN_HUD -eq 1 || $INSTALL_PLUGIN_CLAUDE_MD -eq 1 ]] && total_steps=$((total_steps + 1))
    [[ $INSTALL_SKILL_LEARNING -eq 1 || $INSTALL_SKILL_XCODEBUILD -eq 1 ]] && total_steps=$((total_steps + 1))
    [[ $INSTALL_CMD_PR -eq 1 ]] && total_steps=$((total_steps + 1))
    [[ $INSTALL_HOOKS -eq 1 ]] && total_steps=$((total_steps + 1))
    [[ $INSTALL_SETTINGS -eq 1 ]] && total_steps=$((total_steps + 1))
    [[ $INSTALL_MCP_XCODEBUILD -eq 1 || $INSTALL_MCP_DOCS -eq 1 || \
       $INSTALL_MCP_OMNISEARCH -eq 1 ]] && total_steps=$((total_steps + 1))

    header "🚀 Installing..."

    # --- Homebrew ---
    if [[ $INSTALL_HOMEBREW -eq 1 ]]; then
        current_step=$((current_step + 1))
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
        current_step=$((current_step + 1))
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
        current_step=$((current_step + 1))
        step $current_step $total_steps "Setting up Ollama"

        if ! check_command ollama; then
            info "Installing Ollama..."
            brew install ollama
            INSTALLED_ITEMS+=("Ollama")
            success "Ollama installed"
        fi
    fi

    # Ensure Ollama is running with the embedding model whenever docs-mcp-server is selected.
    # Skipped entirely when Ollama is already running with nomic-embed-text (ollama_fully_ready).
    if [[ "$ollama_setup_needed" == true ]] && check_command ollama; then
        if [[ $INSTALL_OLLAMA -ne 1 ]]; then
            current_step=$((current_step + 1))
            step $current_step $total_steps "Setting up Ollama"
        fi

        # Start Ollama if not already responding
        local ollama_ready=true
        if ! curl -s --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
            # Try brew services only if Ollama was installed via Homebrew
            if brew list ollama &>/dev/null; then
                if ! brew services list 2>/dev/null | grep -q "ollama.*started"; then
                    info "Starting Ollama as a brew service..."
                    brew services start ollama
                fi
            else
                warn "Ollama is installed but not running."
                warn "Start it manually (e.g. 'ollama serve') and re-run setup."
            fi

            # Wait for Ollama to be ready
            local attempts=0
            while ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; do
                attempts=$((attempts + 1))
                if [[ $attempts -ge 30 ]]; then
                    warn "Ollama did not start in time."
                    ollama_ready=false
                    break
                fi
                sleep 1
            done
        fi

        # Pull embedding model (skip if Ollama didn't start)
        if [[ "$ollama_ready" == true ]]; then
            if ! ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
                info "Pulling nomic-embed-text model..."
                if ollama pull nomic-embed-text; then
                    INSTALLED_ITEMS+=("nomic-embed-text model")
                    success "Ollama ready with nomic-embed-text"
                else
                    warn "Failed to pull nomic-embed-text. Run manually: ollama pull nomic-embed-text"
                fi
            else
                success "Ollama running with nomic-embed-text"
            fi
        else
            warn "Skipping model pull. Run manually: ollama pull nomic-embed-text"
        fi
    fi

    # --- Claude Code ---
    if [[ $INSTALL_CLAUDE_CODE -eq 1 ]]; then
        current_step=$((current_step + 1))
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
        current_step=$((current_step + 1))
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
                if try_install "MCP: XcodeBuildMCP" mcp_add XcodeBuildMCP \
                    -e XCODEBUILDMCP_SENTRY_DISABLED=1 \
                    -- npx -y xcodebuildmcp@latest mcp; then
                    success "XcodeBuildMCP configured"
                fi
            fi

            if [[ $INSTALL_MCP_SOSUMI -eq 1 ]]; then
                info "Adding Sosumi..."
                if try_install "MCP: Sosumi" mcp_add sosumi \
                    --transport http \
                    https://sosumi.ai/mcp; then
                    success "Sosumi configured"
                fi
            fi

            if [[ $INSTALL_MCP_SERENA -eq 1 ]]; then
                info "Adding Serena..."
                if try_install "MCP: Serena" mcp_add serena \
                    -- uvx --from "git+https://github.com/oraios/serena" \
                    serena start-mcp-server --context=claude-code --project-from-cwd; then
                    success "Serena configured"
                fi
            fi

            if [[ $INSTALL_MCP_DOCS -eq 1 ]]; then
                info "Adding docs-mcp-server..."
                if try_install "MCP: docs-mcp-server" mcp_add docs-mcp-server \
                    -e OPENAI_API_KEY=ollama \
                    -e OPENAI_API_BASE=http://localhost:11434/v1 \
                    -e DOCS_MCP_EMBEDDING_MODEL=openai:nomic-embed-text \
                    -- npx -y @arabold/docs-mcp-server@latest --read-only --telemetry=false; then
                    success "docs-mcp-server configured"
                fi
            fi

            if [[ $INSTALL_MCP_OMNISEARCH -eq 1 ]]; then
                info "Adding mcp-omnisearch..."
                if try_install "MCP: mcp-omnisearch" mcp_add mcp-omnisearch \
                    -e "PERPLEXITY_API_KEY=${PERPLEXITY_API_KEY}" \
                    -- npx -y mcp-omnisearch; then
                    success "mcp-omnisearch configured"
                fi
            fi
        fi
    fi

    # --- Plugins ---
    if [[ $INSTALL_PLUGIN_EXPLANATORY -eq 1 || $INSTALL_PLUGIN_PR_REVIEW -eq 1 || \
          $INSTALL_PLUGIN_SIMPLIFIER -eq 1 || $INSTALL_PLUGIN_RALPH -eq 1 || \
          $INSTALL_PLUGIN_HUD -eq 1 || $INSTALL_PLUGIN_CLAUDE_MD -eq 1 ]]; then
        current_step=$((current_step + 1))
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
                if try_install "Plugin: explanatory-output-style" \
                    claude_cli plugin install explanatory-output-style@claude-plugins-official; then
                    success "explanatory-output-style installed"
                fi
            fi

            if [[ $INSTALL_PLUGIN_PR_REVIEW -eq 1 ]]; then
                info "Installing pr-review-toolkit..."
                if try_install "Plugin: pr-review-toolkit" \
                    claude_cli plugin install pr-review-toolkit@claude-plugins-official; then
                    success "pr-review-toolkit installed"
                fi
            fi

            if [[ $INSTALL_PLUGIN_SIMPLIFIER -eq 1 ]]; then
                info "Installing code-simplifier..."
                if try_install "Plugin: code-simplifier" \
                    claude_cli plugin install code-simplifier@claude-plugins-official; then
                    success "code-simplifier installed"
                fi
            fi

            if [[ $INSTALL_PLUGIN_RALPH -eq 1 ]]; then
                info "Installing ralph-loop..."
                if try_install "Plugin: ralph-loop" \
                    claude_cli plugin install ralph-loop@claude-plugins-official; then
                    success "ralph-loop installed"
                fi
            fi

            if [[ $INSTALL_PLUGIN_HUD -eq 1 ]]; then
                info "Installing claude-hud..."
                if try_install "Plugin: claude-hud" \
                    claude_cli plugin install claude-hud@claude-hud; then
                    success "claude-hud installed"
                fi
            fi

            if [[ $INSTALL_PLUGIN_CLAUDE_MD -eq 1 ]]; then
                info "Installing claude-md-management..."
                if try_install "Plugin: claude-md-management" \
                    claude_cli plugin install claude-md-management@claude-plugins-official; then
                    success "claude-md-management installed"
                fi
            fi
        fi
    fi

    # --- Skills ---
    if [[ $INSTALL_SKILL_LEARNING -eq 1 || $INSTALL_SKILL_XCODEBUILD -eq 1 ]]; then
        current_step=$((current_step + 1))
        step $current_step $total_steps "Installing Skills"

        if [[ $INSTALL_SKILL_LEARNING -eq 1 ]]; then
            info "Installing continuous-learning skill..."
            mkdir -p "$CLAUDE_SKILLS_DIR/continuous-learning/references"
            cp "$SCRIPT_DIR/skills/continuous-learning/SKILL.md" \
               "$CLAUDE_SKILLS_DIR/continuous-learning/SKILL.md"
            manifest_record "skills/continuous-learning/SKILL.md"
            cp "$SCRIPT_DIR/skills/continuous-learning/references/templates.md" \
               "$CLAUDE_SKILLS_DIR/continuous-learning/references/templates.md"
            manifest_record "skills/continuous-learning/references/templates.md"
            INSTALLED_ITEMS+=("Skill: continuous-learning")
            success "continuous-learning skill installed"
        fi

        if [[ $INSTALL_SKILL_XCODEBUILD -eq 1 ]]; then
            info "Installing xcodebuildmcp skill..."
            if try_install "Skill: xcodebuildmcp" \
                npx -y skills add cameroncooke/xcodebuildmcp -g -a claude-code -y; then
                success "xcodebuildmcp skill installed"
            else
                info "You can try manually: npx -y skills add cameroncooke/xcodebuildmcp -g -a claude-code -y"
            fi
        fi

    fi

    # --- Commands ---
    if [[ $INSTALL_CMD_PR -eq 1 ]]; then
        current_step=$((current_step + 1))
        step $current_step $total_steps "Installing Commands"

        local commands_dir="$HOME/.claude/commands"
        mkdir -p "$commands_dir"

        if [[ $INSTALL_CMD_PR -eq 1 ]]; then
            info "Installing /pr command..."
            cp "$SCRIPT_DIR/commands/pr.md" "$commands_dir/pr.md"
            # Replace user name placeholder if provided
            if [[ -n "$USER_NAME" ]]; then
                local safe_user
                safe_user=$(sed_escape "$USER_NAME")
                sed -i '' "s/__USER_NAME__/${safe_user}/g" "$commands_dir/pr.md"
            fi
            manifest_record "commands/pr.md"
            INSTALLED_ITEMS+=("Command: /pr")
            success "/pr command installed"
        fi
    fi

    # --- Hooks ---
    if [[ $INSTALL_HOOKS -eq 1 ]]; then
        current_step=$((current_step + 1))
        step $current_step $total_steps "Installing Hooks"

        mkdir -p "$CLAUDE_HOOKS_DIR"

        cp "$SCRIPT_DIR/hooks/session_start.sh" "$CLAUDE_HOOKS_DIR/session_start.sh"
        chmod +x "$CLAUDE_HOOKS_DIR/session_start.sh"
        manifest_record "hooks/session_start.sh"

        cp "$SCRIPT_DIR/hooks/continuous-learning-activator.sh" "$CLAUDE_HOOKS_DIR/continuous-learning-activator.sh"
        chmod +x "$CLAUDE_HOOKS_DIR/continuous-learning-activator.sh"
        manifest_record "hooks/continuous-learning-activator.sh"

        INSTALLED_ITEMS+=("Hooks: session_start + continuous-learning-activator")
        success "Hooks installed"
    fi

    # --- Settings ---
    if [[ $INSTALL_SETTINGS -eq 1 ]]; then
        current_step=$((current_step + 1))
        step $current_step $total_steps "Applying Settings"

        if [[ -f "$CLAUDE_SETTINGS" ]]; then
            backup_file "$CLAUDE_SETTINGS"
            # Merge settings: our config on top of existing
            if check_command jq; then
                local merged
                local merge_err
                if merge_err=$(jq -s '.[0] * .[1]' "$CLAUDE_SETTINGS" "$SCRIPT_DIR/config/settings.json" 2>&1); then
                    merged="$merge_err"
                else
                    warn "Failed to merge settings: $merge_err"
                    warn "Previous settings backed up. Overwriting with new settings."
                    merged=$(cat "$SCRIPT_DIR/config/settings.json")
                fi
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

    # --- Global gitignore ---
    local git_ignore_dir="$HOME/.config/git"
    local git_ignore="$git_ignore_dir/ignore"
    local gitignore_entries=(".claude" "*.local.*" ".serena" ".xcodebuildmcp")
    local added_entries=()

    mkdir -p "$git_ignore_dir"
    touch "$git_ignore"

    for entry in "${gitignore_entries[@]}"; do
        if ! grep -qxF "$entry" "$git_ignore" 2>/dev/null; then
            added_entries+=("$entry")
        fi
    done

    if [[ ${#added_entries[@]} -gt 0 ]]; then
        {
            echo ""
            echo "# Added by Claude Code iOS Setup"
            for entry in "${added_entries[@]}"; do
                echo "$entry"
            done
        } >> "$git_ignore"
        INSTALLED_ITEMS+=("Global gitignore: ${added_entries[*]}")
        success "Global gitignore updated (${#added_entries[@]} entries added)"
    fi

    # --- Warm up npx cache ---
    # Pre-download npx packages so the first Claude Code launch is fast.
    # MCP servers use @latest (checks registry every time), but cached
    # packages make the download check near-instant.
    local npx_packages=()
    [[ $INSTALL_MCP_XCODEBUILD -eq 1 ]] && npx_packages+=("xcodebuildmcp@latest")
    [[ $INSTALL_MCP_DOCS -eq 1 ]]       && npx_packages+=("@arabold/docs-mcp-server@latest")
    [[ $INSTALL_MCP_OMNISEARCH -eq 1 ]]  && npx_packages+=("mcp-omnisearch")

    if [[ ${#npx_packages[@]} -gt 0 ]] && check_command npx; then
        current_step=$((current_step + 1))
        step $current_step $total_steps "Warming up npx cache"
        info "Pre-downloading MCP packages for faster first launch..."
        local pids=()
        for pkg in "${npx_packages[@]}"; do
            npx -y "$pkg" --help >/dev/null 2>&1 &
            pids+=($!)
        done
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        success "npx cache ready"
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
    step_num=$((step_num + 1))

    if [[ "$CLAUDE_FRESH_INSTALL" == "true" ]]; then
        echo -e "    ${step_num}. Run ${BOLD}claude${NC} and authenticate with your Anthropic account"
        echo ""
        step_num=$((step_num + 1))
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
        echo -e "       ${SCRIPT_DIR}/setup.sh configure-project"
    fi
    echo ""

    step_num=$((step_num + 1))

    if [[ "$PERPLEXITY_API_KEY" == "__ADD_YOUR_PERPLEXITY_API_KEY__" ]]; then
        echo -e "    ${step_num}. Add your Perplexity API key to mcp-omnisearch:"
        echo -e "       Edit ${BOLD}~/.claude.json${NC} → mcpServers → mcp-omnisearch → env → PERPLEXITY_API_KEY"
        echo ""
        step_num=$((step_num + 1))
    fi

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Happy coding! 🚀"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Doctor — Diagnose installation health
# ---------------------------------------------------------------------------
phase_doctor() {
    local doctor_fix="${1:-false}"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   🩺 Claude Code iOS Setup — Doctor                     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    if [[ "$doctor_fix" == "true" ]]; then
        echo -e "  ${DIM}Running in fix mode — will auto-fix issues where possible${NC}"
    fi
    echo ""

    local pass=0
    local fail=0
    local warn_count=0
    local fixed=0

    doc_pass()  { echo -e "  ${GREEN}✓${NC} $1"; pass=$((pass + 1)); }
    doc_fail()  { echo -e "  ${RED}✗${NC} $1"; fail=$((fail + 1)); }
    doc_warn()  { echo -e "  ${YELLOW}!${NC} $1"; warn_count=$((warn_count + 1)); }
    doc_skip()  { echo -e "  ${DIM}○ $1${NC}"; }
    doc_fixed() { echo -e "  ${GREEN}✓${NC} $1 ${CYAN}(fixed)${NC}"; fixed=$((fixed + 1)); pass=$((pass + 1)); }

    # ===== Dependencies =====
    echo -e "${BOLD}  Dependencies${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    check_command brew   && doc_pass "Homebrew"        || doc_fail "Homebrew — not found"
    check_command node   && doc_pass "Node.js ($(node -v 2>/dev/null))" || doc_fail "Node.js — not found"
    check_command jq     && doc_pass "jq"              || doc_fail "jq — not found"
    check_command gh     && doc_pass "gh (GitHub CLI)"  || doc_fail "gh — not found"
    check_command uvx    && doc_pass "uv"              || doc_fail "uv — not found (needed for Serena)"
    check_command claude && doc_pass "Claude Code"     || doc_fail "Claude Code — not found"

    # Ollama: check command + service running + model
    if check_command ollama; then
        doc_pass "Ollama"
        if curl -s --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
            doc_pass "Ollama service running"
            if curl -s --max-time 3 http://localhost:11434/api/tags 2>/dev/null | grep -q "nomic-embed-text"; then
                doc_pass "nomic-embed-text model"
            else
                doc_fail "nomic-embed-text model not found — run: ollama pull nomic-embed-text"
            fi
        else
            doc_fail "Ollama not responding — start it with 'brew services start ollama' or 'ollama serve'"
        fi
    else
        doc_fail "Ollama — not found"
    fi
    echo ""

    # ===== MCP Servers =====
    echo -e "${BOLD}  MCP Servers${NC} ${DIM}(in ~/.claude.json)${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    if [[ ! -f "$CLAUDE_JSON" ]]; then
        doc_fail "~/.claude.json not found — Claude Code may not be configured"
    elif ! check_command jq; then
        doc_warn "jq not installed — cannot inspect ~/.claude.json"
    else
        local mcp_servers=("XcodeBuildMCP" "sosumi" "serena" "docs-mcp-server" "mcp-omnisearch")
        for server in "${mcp_servers[@]}"; do
            if jq -e ".mcpServers.\"$server\"" "$CLAUDE_JSON" >/dev/null 2>&1; then
                doc_pass "$server"
            else
                doc_skip "$server — not configured"
            fi
        done

        # Check Perplexity API key
        local perp_key
        perp_key=$(jq -r '.mcpServers."mcp-omnisearch".env.PERPLEXITY_API_KEY // ""' "$CLAUDE_JSON" 2>/dev/null) || perp_key=""
        if [[ "$perp_key" == "__ADD_YOUR_PERPLEXITY_API_KEY__" ]]; then
            doc_warn "mcp-omnisearch: Perplexity API key is still a placeholder"
        elif [[ -z "$perp_key" ]] && jq -e '.mcpServers."mcp-omnisearch"' "$CLAUDE_JSON" >/dev/null 2>&1; then
            doc_warn "mcp-omnisearch: Perplexity API key is empty"
        fi
    fi
    echo ""

    # ===== Plugins =====
    echo -e "${BOLD}  Plugins${NC} ${DIM}(in ~/.claude/settings.json)${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
        doc_fail "~/.claude/settings.json not found"
    elif ! check_command jq; then
        doc_warn "jq not installed — cannot inspect settings"
    else
        local plugins=(
            "explanatory-output-style@claude-plugins-official"
            "pr-review-toolkit@claude-plugins-official"
            "code-simplifier@claude-plugins-official"
            "ralph-loop@claude-plugins-official"
            "claude-hud@claude-hud"
            "claude-md-management@claude-plugins-official"
        )
        for plugin in "${plugins[@]}"; do
            local short_name="${plugin%%@*}"
            if jq -e ".enabledPlugins.\"$plugin\"" "$CLAUDE_SETTINGS" 2>/dev/null | grep -q "true"; then
                doc_pass "$short_name"
            else
                doc_skip "$short_name — not enabled"
            fi
        done
    fi
    echo ""

    # ===== Skills =====
    echo -e "${BOLD}  Skills${NC} ${DIM}(in ~/.claude/skills/)${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    if [[ -f "$CLAUDE_SKILLS_DIR/continuous-learning/SKILL.md" ]]; then
        doc_pass "continuous-learning"
    else
        doc_skip "continuous-learning — not installed"
    fi

    if [[ -e "$CLAUDE_SKILLS_DIR/xcodebuildmcp" ]]; then
        doc_pass "xcodebuildmcp"
    else
        doc_skip "xcodebuildmcp — not installed"
    fi
    echo ""

    # ===== Commands =====
    echo -e "${BOLD}  Commands${NC} ${DIM}(in ~/.claude/commands/)${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    if [[ -f "$HOME/.claude/commands/pr.md" ]]; then
        if grep -q "__USER_NAME__" "$HOME/.claude/commands/pr.md" 2>/dev/null; then
            doc_warn "/pr — installed but user name placeholder not replaced"
        else
            doc_pass "/pr"
        fi
    else
        doc_skip "/pr — not installed"
    fi
    echo ""

    # ===== Hooks =====
    echo -e "${BOLD}  Hooks${NC} ${DIM}(in ~/.claude/hooks/)${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    local hook_files=("session_start.sh" "continuous-learning-activator.sh")
    for hook in "${hook_files[@]}"; do
        local hook_path="$CLAUDE_HOOKS_DIR/$hook"
        if [[ -f "$hook_path" ]]; then
            if [[ -x "$hook_path" ]]; then
                doc_pass "$hook"
            else
                doc_warn "$hook — exists but not executable"
            fi
        else
            doc_skip "$hook — not installed"
        fi
    done

    # Check settings.json has hook entries
    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        if jq -e '.hooks.SessionStart' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
            doc_pass "SessionStart hook registered in settings"
        else
            doc_warn "SessionStart hook not registered in settings.json"
        fi
        if jq -e '.hooks.UserPromptSubmit' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
            doc_pass "UserPromptSubmit hook registered in settings"
        else
            doc_warn "UserPromptSubmit hook not registered in settings.json"
        fi
    fi
    echo ""

    # ===== Settings =====
    echo -e "${BOLD}  Settings${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        if jq -e '.permissions.defaultMode == "plan"' "$CLAUDE_SETTINGS" 2>/dev/null | grep -q "true"; then
            doc_pass "Default mode: plan"
        else
            doc_skip "Default mode: not set to plan"
        fi
        if jq -e '.alwaysThinkingEnabled == true' "$CLAUDE_SETTINGS" 2>/dev/null | grep -q "true"; then
            doc_pass "Always-thinking: enabled"
        else
            doc_skip "Always-thinking: not enabled"
        fi
    fi
    echo ""

    # ===== Global Gitignore =====
    echo -e "${BOLD}  Global Gitignore${NC} ${DIM}(~/.config/git/ignore)${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    local git_ignore="$HOME/.config/git/ignore"
    if [[ -f "$git_ignore" ]]; then
        local required_entries=(".claude" "*.local.*" ".serena" ".xcodebuildmcp")
        for entry in "${required_entries[@]}"; do
            if grep -qxF "$entry" "$git_ignore" 2>/dev/null; then
                doc_pass "$entry"
            else
                doc_fail "$entry — missing from global gitignore"
            fi
        done
    else
        doc_fail "~/.config/git/ignore not found"
    fi
    echo ""

    # ===== Installed File Freshness =====
    echo -e "${BOLD}  Installed Files${NC} ${DIM}(vs source repo)${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    # Determine source repo location
    local src_dir=""
    if [[ -f "$SETUP_MANIFEST" ]]; then
        src_dir=$(grep "^SCRIPT_DIR=" "$SETUP_MANIFEST" 2>/dev/null | cut -d'=' -f2-)
    fi
    # Fall back to current SCRIPT_DIR (we're running from the repo)
    if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
        src_dir="$SCRIPT_DIR"
    fi

    if [[ ! -d "$src_dir" ]]; then
        doc_warn "Source repo not found"
    else
        # Plain-copy files: can compare source vs installed directly
        local -a direct_files=(
            "hooks/session_start.sh|$CLAUDE_HOOKS_DIR/session_start.sh"
            "hooks/continuous-learning-activator.sh|$CLAUDE_HOOKS_DIR/continuous-learning-activator.sh"
            "skills/continuous-learning/SKILL.md|$CLAUDE_SKILLS_DIR/continuous-learning/SKILL.md"
            "skills/continuous-learning/references/templates.md|$CLAUDE_SKILLS_DIR/continuous-learning/references/templates.md"
        )
        # sed-modified files: need manifest hash (can't compare directly)
        local -a manifest_files=(
            "commands/pr.md|$HOME/.claude/commands/pr.md"
        )
        local outdated_count=0

        # Check plain-copy files via direct diff
        for entry in "${direct_files[@]}"; do
            local rel_path="${entry%%|*}"
            local installed_path="${entry##*|}"
            local short_name
            short_name=$(basename "$rel_path")
            local src_file="$src_dir/$rel_path"

            if [[ ! -f "$installed_path" ]]; then
                continue  # Not installed — already reported in its own section
            fi
            if [[ ! -f "$src_file" ]]; then
                doc_warn "$short_name — source missing from repo"
                continue
            fi

            if diff -q "$src_file" "$installed_path" >/dev/null 2>&1; then
                doc_pass "$short_name"
            else
                doc_fail "$short_name — outdated (source differs from installed)"
                outdated_count=$((outdated_count + 1))
            fi
        done

        # Check sed-modified files via manifest hash
        for entry in "${manifest_files[@]}"; do
            local rel_path="${entry%%|*}"
            local installed_path="${entry##*|}"
            local short_name
            short_name=$(basename "$rel_path")
            local src_file="$src_dir/$rel_path"

            if [[ ! -f "$installed_path" ]]; then
                continue
            fi
            if [[ ! -f "$src_file" ]]; then
                doc_warn "$short_name — source missing from repo"
                continue
            fi

            if [[ -f "$SETUP_MANIFEST" ]]; then
                local stored_hash
                stored_hash=$(grep "^${rel_path}=" "$SETUP_MANIFEST" 2>/dev/null | cut -d'=' -f2-) || stored_hash=""
                local current_src_hash
                current_src_hash=$(file_hash "$src_file")

                if [[ -z "$stored_hash" ]]; then
                    doc_warn "$short_name — not tracked (re-run setup to track)"
                elif [[ "$stored_hash" != "$current_src_hash" ]]; then
                    doc_fail "$short_name — outdated (source updated since install)"
                    outdated_count=$((outdated_count + 1))
                else
                    doc_pass "$short_name"
                fi
            else
                doc_warn "$short_name — no manifest (re-run setup to track)"
            fi
        done

        if [[ $outdated_count -gt 0 ]]; then
            echo ""
            echo -e "  ${YELLOW}Run ${BOLD}${src_dir}/setup.sh${NC}${YELLOW} to update outdated files.${NC}"
        fi
    fi
    echo ""

    # ===== Project (current directory) =====
    local has_project=false
    local project_dir="$PWD"

    # Detect if cwd is an iOS project
    if ls "$project_dir"/*.xcodeproj >/dev/null 2>&1 || ls "$project_dir"/*.xcworkspace >/dev/null 2>&1; then
        has_project=true
    fi

    if $has_project; then
        echo -e "${BOLD}  Project${NC} ${DIM}($(basename "$project_dir"))${NC}"
        echo -e "  ${DIM}──────────────────────────────────────────${NC}"

        # CLAUDE.local.md
        if [[ -f "$project_dir/CLAUDE.local.md" ]]; then
            doc_pass "CLAUDE.local.md"
        else
            doc_fail "CLAUDE.local.md — not found. Run: ${SCRIPT_DIR}/setup.sh configure-project"
        fi

        # .xcodebuildmcp/config.yaml
        local xbm_project_config="$project_dir/.xcodebuildmcp/config.yaml"
        local xbm_template="$SCRIPT_DIR/templates/xcodebuildmcp.yaml"
        if [[ -f "$xbm_project_config" ]]; then
            doc_pass ".xcodebuildmcp/config.yaml"
            # Check if xcode-ide workflow is enabled
            if grep -q "xcode-ide" "$xbm_project_config" 2>/dev/null; then
                doc_pass "xcode-ide workflow enabled"
            else
                doc_warn "xcode-ide workflow not enabled — xcode_tools_* unavailable"
            fi

            # Compare workflows against template
            if [[ -f "$xbm_template" ]]; then
                local template_workflows config_workflows
                template_workflows=$(grep "^  - " "$xbm_template" | sed 's/^  - //' | sort)
                config_workflows=$(grep "^  - " "$xbm_project_config" | sed 's/^  - //' | sort)

                local missing_wf extra_wf xbm_diffs=""
                missing_wf=$(comm -23 <(echo "$template_workflows") <(echo "$config_workflows"))
                extra_wf=$(comm -13 <(echo "$template_workflows") <(echo "$config_workflows"))

                if [[ -n "$missing_wf" ]]; then
                    xbm_diffs="missing: $(echo "$missing_wf" | tr '\n' ', ' | sed 's/,$//')"
                fi
                if [[ -n "$extra_wf" ]]; then
                    local extra_list="extra: $(echo "$extra_wf" | tr '\n' ', ' | sed 's/,$//')"
                    xbm_diffs="${xbm_diffs:+$xbm_diffs; }$extra_list"
                fi

                if [[ -n "$xbm_diffs" ]]; then
                    if [[ "$doctor_fix" == "true" ]]; then
                        # Detect the Xcode project to fill in the template placeholder
                        local xcode_proj=""
                        xcode_proj=$(ls -1 "$project_dir"/*.xcodeproj 2>/dev/null | head -1)
                        if [[ -z "$xcode_proj" ]]; then
                            xcode_proj=$(ls -1 "$project_dir"/*.xcworkspace 2>/dev/null | head -1)
                        fi
                        if [[ -n "$xcode_proj" ]]; then
                            xcode_proj=$(basename "$xcode_proj")
                            local xbm_escaped
                            xbm_escaped=$(sed_escape "$xcode_proj")
                            local expected
                            expected=$(sed "s/__PROJECT__/${xbm_escaped}/g" "$xbm_template")
                            backup_file "$xbm_project_config"
                            echo "$expected" > "$xbm_project_config"
                            doc_fixed ".xcodebuildmcp/config.yaml — $xbm_diffs"
                        else
                            doc_fail ".xcodebuildmcp/config.yaml — $xbm_diffs (could not detect Xcode project to auto-fix)"
                        fi
                    else
                        doc_fail ".xcodebuildmcp/config.yaml — $xbm_diffs"
                    fi
                fi
            fi
        else
            doc_fail ".xcodebuildmcp/config.yaml — not found. Run: ${SCRIPT_DIR}/setup.sh configure-project"
        fi

        # Serena config (auto-generated on first run)
        if [[ -d "$project_dir/.serena" ]]; then
            doc_pass ".serena/ config (auto-generated)"
        else
            doc_skip ".serena/ — will be auto-generated on first Serena run"
        fi
        echo ""
    else
        echo -e "  ${DIM}  Tip: run from a project root to also check per-project config${NC}"
        echo ""
    fi

    # ===== Summary =====
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "  "
    echo -ne "${GREEN}${pass} passed${NC}"
    if [[ $fixed -gt 0 ]]; then
        echo -ne "  ${CYAN}${fixed} fixed${NC}"
    fi
    if [[ $warn_count -gt 0 ]]; then
        echo -ne "  ${YELLOW}${warn_count} warnings${NC}"
    fi
    if [[ $fail -gt 0 ]]; then
        echo -ne "  ${RED}${fail} issues${NC}"
    fi
    echo ""

    if [[ $fail -eq 0 && $warn_count -eq 0 ]]; then
        echo -e "  ${GREEN}Everything looks good!${NC}"
    elif [[ $fail -eq 0 ]]; then
        echo -e "  ${YELLOW}No critical issues, but some warnings to review.${NC}"
    else
        if [[ "$doctor_fix" != "true" ]]; then
            echo -e "  ${RED}Some issues found. Run ${BOLD}./setup.sh doctor --fix${NC}${RED} to auto-fix.${NC}"
        else
            echo -e "  ${RED}Some issues could not be auto-fixed. Run ${BOLD}./setup.sh${NC}${RED} to resolve.${NC}"
        fi
    fi
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Handle subcommands and flags
case "${1:-}" in
    doctor|--doctor)
        local_fix="false"
        if [[ "${2:-}" == "--fix" ]]; then
            local_fix="true"
        fi
        phase_doctor "$local_fix"
        exit 0
        ;;
    --all)
        # Set all install flags — phase_selection will detect this and skip prompts
        INSTALL_ALL=1
        ;;
    configure-project|--configure-project)
        header "📱 Configure Project"
        configure_project
        while ask_yn "Configure another project?" "N"; do
            configure_project
        done
        echo ""
        exit 0
        ;;
    --help|-h)
        echo "Usage: ./setup.sh                      # Interactive setup (pick components)"
        echo "       ./setup.sh --all                 # Install everything (minimal prompts)"
        echo "       ./setup.sh doctor [--fix]        # Diagnose installation health"
        echo "       ./setup.sh configure-project     # Configure CLAUDE.local.md for a project"
        exit 0
        ;;
    "")
        ;; # No flag — interactive mode
    *)
        error "Unknown option: $1"
        echo "Run ./setup.sh --help for usage."
        exit 1
        ;;
esac

main() {
    phase_welcome
    phase_selection
    phase_summary
    phase_install
    phase_summary_post
}

main
