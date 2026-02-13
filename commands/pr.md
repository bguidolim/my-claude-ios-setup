# Create Pull Request

Automate the full commit-push-PR pipeline. This is a **git-only workflow** — never build or test.

Arguments: $ARGUMENTS (optional — GitHub usernames to add as reviewers, e.g. `@user1 @user2`)

## Steps

1. **Check KB/memory** for any relevant PR conventions or context related to the current branch/feature.

2. **Analyze changes**:
   - Run `git status` (never use `-uall`) and `git diff` (staged + unstaged) in parallel.
   - Run `git log main..HEAD --oneline` to see existing commits on this branch.
   - Extract the **ticket number** from the branch name (pattern: `__USER_NAME__/{ticket}-*` or `{ticket}-*`) or from commit messages. If not found, ask the user.

3. **Stage and commit**:
   - Stage relevant files (prefer specific files over `git add -A`; never stage `.env` or credentials).
   - Describe **what** changed based on the **actual code diff** — the conversation may contain reverted attempts, bugs, or dead ends that don't reflect the final result. Use the conversation for **context and rationale** (the *why*), but never describe changes that aren't in the diff.
   - Commit message format: one-line summary + max 3 bullet points describing actual changes. Use HEREDOC for the message.
   - If there are no changes to commit, skip to step 4.

4. **Push** the current branch with `-u` flag if needed.

5. **Create the PR**:
   - If `.github/pull_request_template.md` exists, read it first and follow its format.
   - **Title**: `[TICKET_NUMBER] Brief description` — must be under 72 characters.
   - **Body**: Fill in Context/Acceptance Criteria from the commit history and branch purpose. Fill in Testing Steps. Do NOT include unrelated PR references or auto-linked issue numbers.
   - Use `gh pr create` with HEREDOC for the body.
   - If reviewers were provided in `$ARGUMENTS`, add them with `--reviewer`.

6. **Report** the PR URL.
