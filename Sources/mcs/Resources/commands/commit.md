# Commit and Push

Stage, commit, and push changes. No PR creation. This is a **git-only workflow** — never build or test.

## Branch naming convention

Branches follow the pattern: `__BRANCH_PREFIX__/{ticket}-short-description` (e.g. `__BRANCH_PREFIX__/ABC-123-fix-login`).

## Steps

1. **Analyze changes**:
   - Run `git status` (never use `-uall`) and `git diff` (staged + unstaged) in parallel.
   - Extract the **ticket number** from the branch name (pattern: `__BRANCH_PREFIX__/{ticket}-*` or `{ticket}-*`). If not found, ask the user.

2. **Stage and commit**:
   - Stage relevant files (prefer specific files over `git add -A`; never stage `.env` or credentials).
   - Describe **what** changed based on the **actual code diff** — the conversation may contain reverted attempts, bugs, or dead ends that don't reflect the final result. Use the conversation for **context and rationale** (the *why*), but never describe changes that aren't in the diff.
   - Commit message format: one-line summary + max 3 bullet points describing actual changes. Use HEREDOC for the message.
   - If there are no changes to commit, say so and stop.

3. **Push** the current branch with `-u` flag if needed.

<!-- mcs:managed -->
