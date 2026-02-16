# ---------------------------------------------------------------------------
# Shared Fix Functions — used by doctor --fix and phase_install
# ---------------------------------------------------------------------------
# Each function performs the fix, returns 0 on success / 1 on failure.
# No user-facing output — the caller handles UI (info/success/warn or
# doc_fixed/doc_fix_failed).
# All functions assume globals from setup.sh are available (SCRIPT_DIR,
# CLAUDE_DIR, CLAUDE_HOOKS_DIR, CLAUDE_SKILLS_DIR, CLAUDE_SETTINGS, etc.)

# === Tier 1: File operations only (always safe) ===

# Create global gitignore file if missing
fix_gitignore_file() {
    local git_ignore_dir="$HOME/.config/git"
    mkdir -p "$git_ignore_dir"
    touch "$git_ignore_dir/ignore"
}

# Append an entry to global gitignore (idempotent)
fix_gitignore_entry() {
    local entry=$1
    local git_ignore="$HOME/.config/git/ignore"
    fix_gitignore_file
    if ! grep -qxF "$entry" "$git_ignore" 2>/dev/null; then
        echo "$entry" >> "$git_ignore"
    fi
}

# Copy a hook file from source and make executable
fix_hook_copy() {
    local name=$1
    mkdir -p "$CLAUDE_HOOKS_DIR"
    cp "$SCRIPT_DIR/hooks/$name" "$CLAUDE_HOOKS_DIR/$name"
    chmod +x "$CLAUDE_HOOKS_DIR/$name"
    manifest_record "hooks/$name"
}

# Make an existing hook file executable
fix_hook_executable() {
    local path=$1
    chmod +x "$path"
}

# Deep-merge config/settings.json into ~/.claude/settings.json
# Deep-merges objects and deduplicates hook arrays by command string
fix_settings_merge() {
    check_command jq || return 1
    mkdir -p "$CLAUDE_DIR"
    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        backup_file "$CLAUDE_SETTINGS"
        local merged
        if merged=$(jq -s '
          (.[0] | del(.hooks)) * (.[1] | del(.hooks)) +
          { hooks: (
            (.[0].hooks // {}) as $a | (.[1].hooks // {}) as $b |
            (($a | keys) + ($b | keys) | unique) | reduce .[] as $k ({};
              . + {($k): (
                ($a[$k] // []) as $existing |
                ($b[$k] // []) |
                reduce .[] as $entry ($existing;
                  if (map(.hooks[0].command) | index($entry.hooks[0].command)) then .
                  else . + [$entry] end
                )
              )}
            )
          )}
        ' "$CLAUDE_SETTINGS" "$SCRIPT_DIR/config/settings.json" 2>&1); then
            echo "$merged" > "$CLAUDE_SETTINGS"
        else
            return 1
        fi
    else
        cp "$SCRIPT_DIR/config/settings.json" "$CLAUDE_SETTINGS"
    fi
}

# Copy continuous-learning skill files from source
fix_skill_learning() {
    mkdir -p "$CLAUDE_SKILLS_DIR/continuous-learning/references"
    cp "$SCRIPT_DIR/skills/continuous-learning/SKILL.md" \
       "$CLAUDE_SKILLS_DIR/continuous-learning/SKILL.md"
    manifest_record "skills/continuous-learning/SKILL.md"
    cp "$SCRIPT_DIR/skills/continuous-learning/references/templates.md" \
       "$CLAUDE_SKILLS_DIR/continuous-learning/references/templates.md"
    manifest_record "skills/continuous-learning/references/templates.md"
}

# Copy /pr command and substitute user name placeholder
fix_cmd_pr() {
    local user_name=${1:-}
    local commands_dir="$HOME/.claude/commands"
    mkdir -p "$commands_dir"
    cp "$SCRIPT_DIR/commands/pr.md" "$commands_dir/pr.md"
    if [[ -n "$user_name" ]]; then
        local safe_user
        safe_user=$(sed_escape "$user_name")
        sed -i '' "s/__USER_NAME__/${safe_user}/g" "$commands_dir/pr.md"
    fi
    manifest_record "commands/pr.md"
}

# Set CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 in settings.json
fix_settings_auto_memory() {
    check_command jq || return 1
    [[ -f "$CLAUDE_SETTINGS" ]] || return 1
    local tmp_settings
    tmp_settings=$(jq '.env.CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1"' "$CLAUDE_SETTINGS")
    echo "$tmp_settings" > "$CLAUDE_SETTINGS"
}

# Re-copy a plain-copy file from source to its installed location
fix_outdated_direct() {
    local rel_path=$1
    local installed_path=$2
    local src_file="$SCRIPT_DIR/$rel_path"
    [[ -f "$src_file" ]] || return 1
    backup_file "$installed_path"
    cp "$src_file" "$installed_path"
    # Restore executable bit for hook files
    if [[ "$rel_path" == hooks/* ]]; then
        chmod +x "$installed_path"
    fi
    manifest_record "$rel_path"
}

# === Tier 2: Needs brew/network ===

# Install a Homebrew package
fix_brew_package() {
    local name=$1
    check_command brew || return 1
    brew install "$name" 2>&1
}

# Start Ollama service and wait for it to respond
fix_ollama_start() {
    check_command ollama || return 1
    # Already running?
    if curl -s --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
        return 0
    fi
    # Try brew services if brew-installed
    if brew list ollama &>/dev/null; then
        if ! brew services list 2>/dev/null | grep -q "ollama.*started"; then
            brew services start ollama 2>&1
        fi
    else
        return 1  # Not brew-installed, can't auto-start
    fi
    # Wait for ready
    local attempts=0
    while ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 30 ]]; then
            return 1
        fi
        sleep 1
    done
}

# Pull an Ollama model
fix_ollama_model() {
    local model=$1
    check_command ollama || return 1
    ollama pull "$model" 2>&1
}

# Install a Claude Code plugin (ensures marketplace is registered first)
fix_plugin() {
    local full_name=$1  # e.g. "explanatory-output-style@claude-plugins-official"
    local marketplace="${full_name##*@}"
    check_command claude || return 1
    # Map marketplace short names to repos
    case "$marketplace" in
        claude-plugins-official) claude_cli plugin marketplace add anthropics/claude-plugins-official 2>/dev/null || true ;;
        claude-hud) claude_cli plugin marketplace add jarrodwatts/claude-hud 2>/dev/null || true ;;
    esac
    claude_cli plugin install "$full_name" 2>&1
}

# Install xcodebuildmcp skill via npx
fix_skill_xcodebuild() {
    check_command npx || return 1
    npx -y skills add cameroncooke/xcodebuildmcp -g -a claude-code -y 2>&1
}

# === Dependency-awareness helpers ===

# Check if a dependency is needed by any installed component
# Returns 0 if needed, 1 if not
dep_needed() {
    local dep=$1
    case "$dep" in
        node)
            # Needed if any MCP server, skill (xcodebuild), or commands are installed
            [[ -f "$CLAUDE_JSON" ]] && check_command jq && \
                jq -e '.mcpServers | length > 0' "$CLAUDE_JSON" >/dev/null 2>&1 && return 0
            [[ -e "$CLAUDE_SKILLS_DIR/xcodebuildmcp" ]] && return 0
            return 1
            ;;
        jq)
            # Needed if settings.json exists (we need jq to merge settings)
            [[ -f "$CLAUDE_SETTINGS" ]] && return 0
            return 1
            ;;
        gh)
            # Needed if /pr command is installed
            [[ -f "$HOME/.claude/commands/pr.md" ]] && return 0
            return 1
            ;;
        uvx)
            # Needed if Serena MCP is configured
            [[ -f "$CLAUDE_JSON" ]] && check_command jq && \
                jq -e '.mcpServers.serena' "$CLAUDE_JSON" >/dev/null 2>&1 && return 0
            return 1
            ;;
        ollama)
            # Needed if docs-mcp-server is configured
            [[ -f "$CLAUDE_JSON" ]] && check_command jq && \
                jq -e '.mcpServers."docs-mcp-server"' "$CLAUDE_JSON" >/dev/null 2>&1 && return 0
            return 1
            ;;
    esac
    return 1
}
