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
        echo -e "  ${BOLD}Your name for branch naming${NC} (e.g. ${DIM}bruno${NC} → ${DIM}bruno/ABC-123-fix-login${NC})"
        echo -e "  Leave empty for ${DIM}feature/ABC-123-fix-login${NC}"
        echo -ne "  > "
        read -r user_name
        if [[ -z "$user_name" ]]; then
            user_name='feature'
            info "Defaulting branch prefix to: ${BOLD}${user_name}${NC}"
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
        if ask_yn "CLAUDE.local.md already exists. Overwrite? (a backup will be created)" "N"; then
            backup_file "$dest"
        else
            warn "Skipped project configuration."
            return 0
        fi
    fi

    cp "$SCRIPT_DIR/templates/CLAUDE.local.md" "$dest"

    # Stamp the template hash so doctor can detect drift
    local template_hash
    template_hash=$(file_hash "$SCRIPT_DIR/templates/CLAUDE.local.md")
    echo "" >> "$dest"
    echo "<!-- template-hash:${template_hash} -->" >> "$dest"

    # --- Apply edits ---

    # 1. Repo name for docs-mcp-server library (matches session_start.sh convention)
    local repo_name
    repo_name=$(basename "$(git -C "$project_path" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || basename "$project_path")
    local repo_escaped
    repo_escaped=$(sed_escape "$repo_name")
    sed -i '' "s/__REPO_NAME__/${repo_escaped}/g" "$dest"

    # 2. Xcode project: remove EDIT comment, replace placeholder
    sed -i '' '/<!-- EDIT: Set your .xcodeproj and default scheme below -->/d' "$dest"
    local xcode_escaped
    xcode_escaped=$(sed_escape "$xcode_project")
    sed -i '' "s/__PROJECT__\.xcodeproj/${xcode_escaped}/g" "$dest"

    # 2. Branch naming: remove EDIT comment, replace placeholder
    sed -i '' '/<!-- EDIT: Set your branch naming convention below -->/d' "$dest"
    local safe_name
    safe_name=$(sed_escape "$user_name")
    sed -i '' "s/__USER_NAME__/${safe_name}/g" "$dest"

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
            if ask_yn "Overwrite .xcodebuildmcp/config.yaml with updated template? (a backup will be created)" "Y"; then
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
    echo -e "    Docs library:       ${BOLD}${repo_name}${NC}"
    echo -e "    Branch prefix:      ${BOLD}${user_name}/{ticket-and-small-title}${NC}"
    echo -e "    XcodeBuildMCP:      ${BOLD}.xcodebuildmcp/config.yaml${NC}"
    if [[ "$has_symlink" == true ]]; then
        echo -e "    Symlink note:       ${GREEN}enabled${NC} (CLAUDE.md → AGENTS.md)"
    fi
}
