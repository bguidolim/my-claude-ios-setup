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

    # === OLLAMA STATUS & DOCS-MCP LIBRARY ===
    local ollama_running=false
    if curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
        ollama_running=true
        context+="\n🦙 Ollama: running"
    fi

    # If project has a memories directory, ensure docs-mcp-server library is synced
    if [ -d ".claude/memories" ]; then
        if [ "$ollama_running" = true ]; then
            local repo_name
            repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "")
            if [ -n "$repo_name" ]; then
                local memories_path
                memories_path="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/memories"

                # Background: ensure library exists and is up to date.
                # Redirect subshell stdout/stderr to /dev/null so the hook's
                # output pipe closes immediately (Claude Code waits for the
                # pipe to close, not just the parent process).
                # A watchdog kills the subshell after 120s to prevent hangs.
                (
                    trap 'kill 0 2>/dev/null' TERM
                    export OPENAI_API_KEY=ollama
                    export OPENAI_API_BASE=http://localhost:11434/v1

                    embedding_model="openai:nomic-embed-text"

                    if npx -y @arabold/docs-mcp-server list --silent 2>/dev/null | grep -q "$repo_name"; then
                        npx -y @arabold/docs-mcp-server refresh "$repo_name" \
                            --embedding-model "$embedding_model" \
                            --silent >/dev/null 2>&1
                    else
                        npx -y @arabold/docs-mcp-server scrape "$repo_name" \
                            "file://$memories_path" \
                            --embedding-model "$embedding_model" \
                            --silent >/dev/null 2>&1
                    fi
                ) >/dev/null 2>&1 &
                local sync_pid=$!
                ( sleep 120 && kill "$sync_pid" 2>/dev/null ) >/dev/null 2>&1 &
            fi
        else
            context+="\n⚠️ Ollama not running — docs-mcp semantic search will fail"
        fi
    fi

    # Create JSON output
    jq -n --arg ctx "$context" '{
        hookSpecificOutput: {
            hookEventName: "SessionStart",
            additionalContext: $ctx
        }
    }'
}

main
