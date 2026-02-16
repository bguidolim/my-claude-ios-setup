# ---------------------------------------------------------------------------
# Backup cleanup
# ---------------------------------------------------------------------------

# Offer to delete backups created during this run
prompt_cleanup_backups() {
    if [[ ${#CREATED_BACKUPS[@]} -eq 0 ]]; then
        return
    fi

    echo ""
    header "🗑️  Backup Cleanup"
    echo -e "  ${DIM}The following backup files were created during this run:${NC}"
    echo ""
    for f in "${CREATED_BACKUPS[@]}"; do
        echo -e "    ${DIM}${f}${NC}"
    done
    echo ""
    if ask_yn "Delete these backups?" "N"; then
        for f in "${CREATED_BACKUPS[@]}"; do
            rm -f "$f"
        done
        success "Deleted ${#CREATED_BACKUPS[@]} backup file(s)"
    else
        info "Backups kept. Run ./setup.sh cleanup to manage them later."
    fi
}

# Find and manage all backup files from any previous run
phase_cleanup() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   🗑️  Backup Cleanup                                    ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Known backup locations
    local -a search_dirs=(
        "$HOME"                # ~/.claude.json.backup.*
        "$CLAUDE_DIR"          # settings.json.backup.*
    )

    local -a found_backups=()

    # Search known global locations
    for dir in "${search_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            while IFS= read -r -d '' f; do
                found_backups+=("$f")
            done < <(find "$dir" -maxdepth 1 -name "*.backup.*" -type f -print0 2>/dev/null)
        fi
    done

    # Search project directory (if in a project)
    local project_dir="$PWD"
    if ls "$project_dir"/*.xcodeproj >/dev/null 2>&1 || ls "$project_dir"/*.xcworkspace >/dev/null 2>&1; then
        while IFS= read -r -d '' f; do
            found_backups+=("$f")
        done < <(find "$project_dir" -maxdepth 2 -name "*.backup.*" -type f -print0 2>/dev/null)
    fi

    if [[ ${#found_backups[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}No backup files found.${NC}"
        echo ""
        return
    fi

    # Group by timestamp
    echo -e "  Found ${BOLD}${#found_backups[@]}${NC} backup file(s):"
    echo ""
    for f in "${found_backups[@]}"; do
        local size
        size=$(du -h "$f" 2>/dev/null | cut -f1 | tr -d ' ')
        echo -e "    ${DIM}${f}${NC}  ${DIM}(${size})${NC}"
    done
    echo ""

    if ask_yn "Delete all ${#found_backups[@]} backup file(s)?" "N"; then
        for f in "${found_backups[@]}"; do
            rm -f "$f"
        done
        success "Deleted ${#found_backups[@]} backup file(s)"
    else
        info "Backups kept."
    fi
    echo ""
}
