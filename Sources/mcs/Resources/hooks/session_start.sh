#!/bin/bash

set -euo pipefail

# Graceful exit on any error
trap 'exit 0' ERR

# Check if jq is available
command -v jq >/dev/null 2>&1 || exit 0

main() {
    # Read and validate JSON input
    local input_data
    input_data=$(cat) || exit 0
    echo "$input_data" | jq '.' >/dev/null 2>&1 || exit 0

    # Build context
    local context=""

    # === TIMESTAMP ===
    context+="Session: $(date '+%Y-%m-%d %H:%M:%S')"

    # === GIT STATUS ===
    if branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); then
        context+="\nBranch: $branch"

        # Branch protection warning
        if [[ "$branch" == "main" || "$branch" == "develop" || "$branch" == "master" || "$branch" == release/* || "$branch" == hotfix/* ]]; then
            context+="\n⚠️ WARNING: On protected branch '$branch' - create a feature branch before making changes"
        fi

        # Uncommitted changes
        if changes=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' '); then
            [[ "$changes" -gt 0 ]] && context+="\nUncommitted: $changes files"
        fi

        # Stash status
        if stash_count=$(git stash list 2>/dev/null | wc -l | tr -d ' '); then
            [[ "$stash_count" -gt 0 ]] && context+="\n📦 Stashed changes: $stash_count"
        fi

        # Merge conflict detection
        if git ls-files -u 2>/dev/null | grep -q .; then
            context+="\n🔴 MERGE CONFLICTS DETECTED - resolve before proceeding"
        fi
    fi

    # === GIT REMOTE TRACKING ===
    if [[ -n "${branch:-}" ]] && git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
        if counts=$(git rev-list --count --left-right '@{upstream}...HEAD' 2>/dev/null); then
            behind=$(echo "$counts" | cut -f1)
            ahead=$(echo "$counts" | cut -f2)
            if [[ "$behind" -gt 0 && "$ahead" -gt 0 ]]; then
                context+="\n↕️ Branch diverged: $ahead ahead, $behind behind remote"
            elif [[ "$ahead" -gt 0 ]]; then
                context+="\n⬆️ $ahead commit(s) ahead of remote (unpushed)"
            elif [[ "$behind" -gt 0 ]]; then
                context+="\n⬇️ $behind commit(s) behind remote (pull needed)"
            fi
        fi
    elif [[ -n "${branch:-}" && "$branch" != "main" && "$branch" != "develop" && "$branch" != "master" && "$branch" != release/* && "$branch" != hotfix/* ]]; then
        context+="\n🔗 No remote tracking branch (push with -u to set upstream)"
    fi

    # === OPEN PR FOR BRANCH ===
    if [[ -n "${branch:-}" ]] && command -v gh >/dev/null 2>&1; then
        if pr_info=$(gh pr view --json number,title,url,state 2>/dev/null); then
            pr_number=$(echo "$pr_info" | jq -r '.number' 2>/dev/null)
            pr_title=$(echo "$pr_info" | jq -r '.title' 2>/dev/null)
            pr_state=$(echo "$pr_info" | jq -r '.state' 2>/dev/null)
            if [[ -n "$pr_number" && "$pr_state" == "OPEN" ]]; then
                context+="\n🔀 Open PR #$pr_number: $pr_title"
            fi
        fi
    fi

    # --- mcs:hook-extensions ---

    # Create JSON output
    jq -n --arg ctx "$context" '{
        hookSpecificOutput: {
            hookEventName: "SessionStart",
            additionalContext: $ctx
        }
    }'
}

main
