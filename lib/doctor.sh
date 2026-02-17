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

    doc_pass()       { echo -e "  ${GREEN}✓${NC} $1"; pass=$((pass + 1)); }
    doc_fail()       { echo -e "  ${RED}✗${NC} $1"; fail=$((fail + 1)); }
    doc_warn()       { echo -e "  ${YELLOW}!${NC} $1"; warn_count=$((warn_count + 1)); }
    doc_skip()       { echo -e "  ${DIM}○ $1${NC}"; }
    doc_fixed()      { echo -e "  ${GREEN}✓${NC} $1 ${CYAN}(fixed)${NC}"; fixed=$((fixed + 1)); pass=$((pass + 1)); }
    doc_fix_failed() { echo -e "  ${RED}✗${NC} $1 ${YELLOW}(fix failed)${NC}"; fail=$((fail + 1)); }

    # Ensure brew is on PATH before dependency checks
    ensure_brew_in_path

    # ===== Dependencies =====
    echo -e "${BOLD}  Dependencies${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    # Homebrew — cannot auto-fix (interactive installer)
    check_command brew && doc_pass "Homebrew" || doc_fail "Homebrew — not found (install from https://brew.sh)"

    # Brew packages — auto-fix only if brew exists AND dep is needed
    local brew_deps=("node:node" "jq:jq" "gh:gh" "uvx:uv")
    for dep_entry in "${brew_deps[@]}"; do
        local cmd="${dep_entry%%:*}"
        local pkg="${dep_entry##*:}"
        if check_command "$cmd"; then
            if [[ "$cmd" == "node" ]]; then
                doc_pass "Node.js ($(node -v 2>/dev/null))"
            elif [[ "$cmd" == "gh" ]]; then
                doc_pass "gh (GitHub CLI)"
            elif [[ "$cmd" == "uvx" ]]; then
                doc_pass "uv"
            else
                doc_pass "$pkg"
            fi
        else
            local label="$pkg"
            [[ "$cmd" == "node" ]] && label="Node.js"
            [[ "$cmd" == "gh" ]] && label="gh (GitHub CLI)"
            [[ "$cmd" == "uvx" ]] && label="uv"

            if [[ "$doctor_fix" == "true" ]] && check_command brew && dep_needed "$cmd"; then
                if fix_brew_package "$pkg" >/dev/null 2>&1; then
                    doc_fixed "$label"
                else
                    doc_fix_failed "$label — brew install $pkg failed"
                fi
            elif dep_needed "$cmd"; then
                doc_fail "$label — not found"
            else
                doc_skip "$label — not needed by installed components"
            fi
        fi
    done

    # Claude Code — cannot auto-fix (needs cask + auth)
    check_command claude && doc_pass "Claude Code" || doc_fail "Claude Code — not found"

    # Ollama: command + service + model
    if check_command ollama; then
        doc_pass "Ollama"
        if curl -s --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
            doc_pass "Ollama service running"
            if curl -s --max-time 3 http://localhost:11434/api/tags 2>/dev/null | grep -q "nomic-embed-text"; then
                doc_pass "nomic-embed-text model"
            else
                if [[ "$doctor_fix" == "true" ]]; then
                    if fix_ollama_model "nomic-embed-text" >/dev/null 2>&1; then
                        doc_fixed "nomic-embed-text model"
                    else
                        doc_fix_failed "nomic-embed-text model — ollama pull failed"
                    fi
                else
                    doc_fail "nomic-embed-text model not found — run: ollama pull nomic-embed-text"
                fi
            fi
        else
            if [[ "$doctor_fix" == "true" ]]; then
                if fix_ollama_start >/dev/null 2>&1; then
                    doc_fixed "Ollama service started"
                    # Now check/pull model
                    if curl -s --max-time 3 http://localhost:11434/api/tags 2>/dev/null | grep -q "nomic-embed-text"; then
                        doc_pass "nomic-embed-text model"
                    else
                        if fix_ollama_model "nomic-embed-text" >/dev/null 2>&1; then
                            doc_fixed "nomic-embed-text model"
                        else
                            doc_fix_failed "nomic-embed-text model — ollama pull failed"
                        fi
                    fi
                else
                    doc_fix_failed "Ollama service — could not start (try 'ollama serve' manually)"
                fi
            else
                doc_fail "Ollama not responding — start it with 'brew services start ollama' or 'ollama serve'"
            fi
        fi
    else
        if [[ "$doctor_fix" == "true" ]] && check_command brew && dep_needed "ollama"; then
            if fix_brew_package "ollama" >/dev/null 2>&1; then
                doc_fixed "Ollama installed"
                if fix_ollama_start >/dev/null 2>&1; then
                    doc_fixed "Ollama service started"
                    if fix_ollama_model "nomic-embed-text" >/dev/null 2>&1; then
                        doc_fixed "nomic-embed-text model"
                    else
                        doc_fix_failed "nomic-embed-text model — ollama pull failed"
                    fi
                else
                    doc_fix_failed "Ollama service — could not start"
                fi
            else
                doc_fix_failed "Ollama — brew install failed"
            fi
        elif dep_needed "ollama"; then
            doc_fail "Ollama — not found"
        else
            doc_skip "Ollama — not needed by installed components"
        fi
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
        if [[ "$doctor_fix" == "true" ]]; then
            if fix_settings_merge 2>/dev/null; then
                doc_fixed "~/.claude/settings.json created"
            else
                doc_fix_failed "~/.claude/settings.json — could not create"
            fi
        else
            doc_fail "~/.claude/settings.json not found"
        fi
    elif ! check_command jq; then
        doc_warn "jq not installed — cannot inspect settings"
    fi

    # Only check plugins if settings file exists now
    if [[ -f "$CLAUDE_SETTINGS" ]] && check_command jq; then
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
        # Check manifest to see if it was previously installed
        if [[ -f "$SETUP_MANIFEST" ]] && grep -q "^skills/continuous-learning/SKILL.md=" "$SETUP_MANIFEST" 2>/dev/null; then
            if [[ "$doctor_fix" == "true" ]]; then
                if fix_skill_learning 2>/dev/null; then
                    doc_fixed "continuous-learning"
                else
                    doc_fix_failed "continuous-learning — could not copy files"
                fi
            else
                doc_fail "continuous-learning — was installed but files are missing"
            fi
        else
            doc_skip "continuous-learning — not installed"
        fi
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
        if grep -q "__BRANCH_PREFIX__" "$HOME/.claude/commands/pr.md" 2>/dev/null; then
            doc_warn "/pr — installed but branch prefix placeholder not replaced"
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
                if [[ "$doctor_fix" == "true" ]]; then
                    if fix_hook_executable "$hook_path"; then
                        doc_fixed "$hook (made executable)"
                    else
                        doc_fix_failed "$hook — chmod +x failed"
                    fi
                else
                    doc_warn "$hook — exists but not executable"
                fi
            fi
        else
            # Check manifest to see if it was previously installed
            if [[ -f "$SETUP_MANIFEST" ]] && grep -q "^hooks/${hook}=" "$SETUP_MANIFEST" 2>/dev/null; then
                if [[ "$doctor_fix" == "true" ]]; then
                    if fix_hook_copy "$hook" 2>/dev/null; then
                        doc_fixed "$hook"
                    else
                        doc_fix_failed "$hook — could not copy from source"
                    fi
                else
                    doc_fail "$hook — was installed but file is missing"
                fi
            else
                doc_skip "$hook — not installed"
            fi
        fi
    done

    # Check settings.json has hook entries
    if [[ -f "$CLAUDE_SETTINGS" ]] && check_command jq; then
        local hook_events=("SessionStart" "UserPromptSubmit")
        for event in "${hook_events[@]}"; do
            if jq -e ".hooks.$event" "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
                doc_pass "$event hook registered in settings"
            else
                if [[ "$doctor_fix" == "true" ]]; then
                    if fix_settings_merge 2>/dev/null; then
                        doc_fixed "$event hook registered in settings"
                    else
                        doc_fix_failed "$event hook — settings merge failed"
                    fi
                else
                    doc_warn "$event hook not registered in settings.json"
                fi
            fi
        done
    fi
    echo ""

    # ===== Settings =====
    echo -e "${BOLD}  Settings${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    if [[ -f "$CLAUDE_SETTINGS" ]] && check_command jq; then
        if jq -e '.permissions.defaultMode == "plan"' "$CLAUDE_SETTINGS" 2>/dev/null | grep -q "true"; then
            doc_pass "Default mode: plan"
        else
            if [[ "$doctor_fix" == "true" ]]; then
                if fix_settings_merge 2>/dev/null; then
                    doc_fixed "Default mode: plan"
                else
                    doc_fix_failed "Default mode — settings merge failed"
                fi
            else
                doc_skip "Default mode: not set to plan"
            fi
        fi
        if jq -e '.alwaysThinkingEnabled == true' "$CLAUDE_SETTINGS" 2>/dev/null | grep -q "true"; then
            doc_pass "Always-thinking: enabled"
        else
            if [[ "$doctor_fix" == "true" ]]; then
                if fix_settings_merge 2>/dev/null; then
                    doc_fixed "Always-thinking: enabled"
                else
                    doc_fix_failed "Always-thinking — settings merge failed"
                fi
            else
                doc_skip "Always-thinking: not enabled"
            fi
        fi
    fi
    echo ""

    # ===== Global Gitignore =====
    echo -e "${BOLD}  Global Gitignore${NC} ${DIM}(~/.config/git/ignore)${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────${NC}"

    local git_ignore="$HOME/.config/git/ignore"
    if [[ ! -f "$git_ignore" ]]; then
        if [[ "$doctor_fix" == "true" ]]; then
            if fix_gitignore_file; then
                doc_fixed "~/.config/git/ignore created"
            else
                doc_fix_failed "~/.config/git/ignore — could not create"
            fi
        else
            doc_fail "~/.config/git/ignore not found"
        fi
    fi

    # Check entries (file may have just been created by fix above)
    if [[ -f "$git_ignore" ]]; then
        local required_entries=(".claude" "*.local.*" ".serena" ".xcodebuildmcp")
        for entry in "${required_entries[@]}"; do
            if grep -qxF "$entry" "$git_ignore" 2>/dev/null; then
                doc_pass "$entry"
            else
                if [[ "$doctor_fix" == "true" ]]; then
                    if fix_gitignore_entry "$entry"; then
                        doc_fixed "$entry"
                    else
                        doc_fix_failed "$entry — could not append to gitignore"
                    fi
                else
                    doc_fail "$entry — missing from global gitignore"
                fi
            fi
        done
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
                if [[ "$doctor_fix" == "true" ]]; then
                    if fix_outdated_direct "$rel_path" "$installed_path" 2>/dev/null; then
                        doc_fixed "$short_name"
                    else
                        doc_fix_failed "$short_name — could not update from source"
                    fi
                else
                    doc_fail "$short_name — outdated (source differs from installed)"
                fi
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
                    # sed-modified files can't be auto-fixed (need user input for substitution)
                    doc_fail "$short_name — outdated (source updated since install). Re-run setup to update."
                else
                    doc_pass "$short_name"
                fi
            else
                doc_warn "$short_name — no manifest (re-run setup to track)"
            fi
        done
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
            local claude_local_ok=true

            # Check for unsubstituted placeholders
            if grep -qE '__REPO_NAME__|__PROJECT__|__BRANCH_PREFIX__' "$project_dir/CLAUDE.local.md" 2>/dev/null; then
                doc_warn "CLAUDE.local.md — has unsubstituted placeholders"
                claude_local_ok=false
            fi

            # Check template freshness via embedded hash
            local stored_tmpl_hash current_tmpl_hash
            stored_tmpl_hash=$(sed -n 's/.*<!-- template-hash:\([a-f0-9]*\) -->.*/\1/p' "$project_dir/CLAUDE.local.md" 2>/dev/null) || stored_tmpl_hash=""
            current_tmpl_hash=$(file_hash "$SCRIPT_DIR/templates/CLAUDE.local.md" 2>/dev/null) || current_tmpl_hash=""

            if [[ -n "$current_tmpl_hash" && -n "$stored_tmpl_hash" && "$stored_tmpl_hash" != "$current_tmpl_hash" ]]; then
                doc_fail "CLAUDE.local.md — outdated (template updated since generation). Re-run: ${SCRIPT_DIR}/setup.sh configure-project"
                claude_local_ok=false
            elif [[ -n "$current_tmpl_hash" && -z "$stored_tmpl_hash" ]]; then
                doc_warn "CLAUDE.local.md — no template hash (re-generate to enable freshness tracking)"
                claude_local_ok=false
            fi

            if $claude_local_ok; then
                doc_pass "CLAUDE.local.md"
            fi
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
