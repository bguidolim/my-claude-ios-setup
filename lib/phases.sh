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
        echo -e "  ${BOLD}Your name for branch naming${NC} (e.g. ${DIM}bruno${NC} → ${DIM}bruno/ABC-123-fix-login${NC})"
        echo -e "  Leave empty for ${DIM}feature/ABC-123-fix-login${NC}"
        echo -ne "  > "
        read -r USER_NAME
        if [[ -z "$USER_NAME" ]]; then
            USER_NAME='feature'
            info "Defaulting branch prefix to: ${BOLD}${USER_NAME}${NC}"
        fi

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
        echo -e "  ${BOLD}Your name for branch naming${NC} (e.g. ${DIM}bruno${NC} → ${DIM}bruno/ABC-123-fix-login${NC})"
        echo -e "  Leave empty for ${DIM}feature/ABC-123-fix-login${NC}"
        echo -ne "  > "
        read -r USER_NAME
        if [[ -z "$USER_NAME" ]]; then
            USER_NAME='feature'
            info "Defaulting branch prefix to: ${BOLD}${USER_NAME}${NC}"
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
            fix_brew_package node
            INSTALLED_ITEMS+=("Node.js")
            success "Node.js installed"
        fi

        if [[ $INSTALL_JQ -eq 1 ]]; then
            info "Installing jq..."
            fix_brew_package jq
            INSTALLED_ITEMS+=("jq")
            success "jq installed"
        fi

        if [[ $INSTALL_GH -eq 1 ]]; then
            info "Installing GitHub CLI..."
            fix_brew_package gh
            INSTALLED_ITEMS+=("gh")
            success "GitHub CLI installed"
        fi

        if [[ $INSTALL_UV -eq 1 ]]; then
            info "Installing uv..."
            fix_brew_package uv
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
            info "Starting Ollama..."
            if ! fix_ollama_start; then
                warn "Ollama did not start. Start it manually (e.g. 'ollama serve') and re-run setup."
                ollama_ready=false
            fi
        fi

        # Pull embedding model (skip if Ollama didn't start)
        if [[ "$ollama_ready" == true ]]; then
            if ! ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
                info "Pulling nomic-embed-text model..."
                if fix_ollama_model "nomic-embed-text"; then
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
            if [[ $INSTALL_PLUGIN_EXPLANATORY -eq 1 ]]; then
                info "Installing explanatory-output-style..."
                if try_install "Plugin: explanatory-output-style" \
                    fix_plugin explanatory-output-style@claude-plugins-official; then
                    success "explanatory-output-style installed"
                fi
            fi

            if [[ $INSTALL_PLUGIN_PR_REVIEW -eq 1 ]]; then
                info "Installing pr-review-toolkit..."
                if try_install "Plugin: pr-review-toolkit" \
                    fix_plugin pr-review-toolkit@claude-plugins-official; then
                    success "pr-review-toolkit installed"
                fi
            fi

            if [[ $INSTALL_PLUGIN_SIMPLIFIER -eq 1 ]]; then
                info "Installing code-simplifier..."
                if try_install "Plugin: code-simplifier" \
                    fix_plugin code-simplifier@claude-plugins-official; then
                    success "code-simplifier installed"
                fi
            fi

            if [[ $INSTALL_PLUGIN_RALPH -eq 1 ]]; then
                info "Installing ralph-loop..."
                if try_install "Plugin: ralph-loop" \
                    fix_plugin ralph-loop@claude-plugins-official; then
                    success "ralph-loop installed"
                fi
            fi

            if [[ $INSTALL_PLUGIN_HUD -eq 1 ]]; then
                info "Installing claude-hud..."
                if try_install "Plugin: claude-hud" \
                    fix_plugin claude-hud@claude-hud; then
                    success "claude-hud installed"
                fi
            fi

            if [[ $INSTALL_PLUGIN_CLAUDE_MD -eq 1 ]]; then
                info "Installing claude-md-management..."
                if try_install "Plugin: claude-md-management" \
                    fix_plugin claude-md-management@claude-plugins-official; then
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
            fix_skill_learning
            INSTALLED_ITEMS+=("Skill: continuous-learning")
            success "continuous-learning skill installed"
        fi

        if [[ $INSTALL_SKILL_XCODEBUILD -eq 1 ]]; then
            info "Installing xcodebuildmcp skill..."
            if try_install "Skill: xcodebuildmcp" fix_skill_xcodebuild; then
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

        info "Installing /pr command..."
        fix_cmd_pr "$USER_NAME"
        INSTALLED_ITEMS+=("Command: /pr")
        success "/pr command installed"
    fi

    # --- Hooks ---
    if [[ $INSTALL_HOOKS -eq 1 ]]; then
        current_step=$((current_step + 1))
        step $current_step $total_steps "Installing Hooks"

        fix_hook_copy "session_start.sh"
        fix_hook_copy "continuous-learning-activator.sh"

        INSTALLED_ITEMS+=("Hooks: session_start + continuous-learning-activator")
        success "Hooks installed"
    fi

    # --- Settings ---
    if [[ $INSTALL_SETTINGS -eq 1 ]]; then
        current_step=$((current_step + 1))
        step $current_step $total_steps "Applying Settings"

        if ! fix_settings_merge; then
            warn "Failed to merge settings. Previous settings backed up. Overwriting with new settings."
            cp "$SCRIPT_DIR/config/settings.json" "$CLAUDE_SETTINGS"
        fi

        # Disable built-in auto-memory when Serena continuous-learning replaces it
        if [[ $INSTALL_MCP_SERENA -eq 1 || $INSTALL_SKILL_LEARNING -eq 1 ]]; then
            fix_settings_auto_memory || true
        fi

        INSTALLED_ITEMS+=("Settings: env vars, plan mode, hooks config, plugins")
        success "Settings applied"
    fi

    # --- Global gitignore ---
    fix_gitignore_file
    local git_ignore="$HOME/.config/git/ignore"
    local gitignore_entries=(".claude" "*.local.*" ".serena" ".xcodebuildmcp")
    local added_entries=()

    for entry in "${gitignore_entries[@]}"; do
        if ! grep -qxF "$entry" "$git_ignore" 2>/dev/null; then
            added_entries+=("$entry")
        fi
    done

    if [[ ${#added_entries[@]} -gt 0 ]]; then
        # Add a comment header before the first entry
        echo "" >> "$git_ignore"
        echo "# Added by Claude Code iOS Setup" >> "$git_ignore"
        for entry in "${added_entries[@]}"; do
            fix_gitignore_entry "$entry"
        done
        INSTALLED_ITEMS+=("Global gitignore: ${added_entries[*]}")
        success "Global gitignore updated (${#added_entries[@]} entries added)"
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
