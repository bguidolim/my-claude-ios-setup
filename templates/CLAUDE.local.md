# Claude Code Instructions

<!-- EDIT: If your project has CLAUDE.md as a symlink to AGENTS.md, uncomment the note below -->
<!-- > **Note:** `CLAUDE.md` is a symlink to `AGENTS.md` — its content is already loaded at session start. Do not re-read `AGENTS.md` or `CLAUDE.md` via tool calls. -->

## MANDATORY — Before Starting Any Task

Before writing code, planning, or exploring — **always do these two steps first**:

1. **Search the KB** — call `search_docs` with library `__REPO_NAME__` and keywords relevant to the task (module, feature, concept). It indexes both documentation and Serena memories in a single semantic search. Try multiple keyword variations if needed.
2. **Read matching memories** — use Serena `read_memory` on any relevant results to get full context (architecture decisions, gotchas, patterns from past sessions).

Only after these steps, proceed with Serena tools, Glob, or other discovery.

## MANDATORY — Swift Code Operations via Serena

**NEVER** use Read, Edit, Grep, or Glob for Swift files. Always use Serena equivalents:
- **Discovery**: `get_symbols_overview`, `find_symbol`, `find_referencing_symbols`, `search_for_pattern`
- **Editing**: `replace_symbol_body`, `insert_before_symbol`, `insert_after_symbol`
- **Before removing or renaming** any symbol, verify it is unused via `find_referencing_symbols`
- **Memory**: save architectural decisions, gotchas, and patterns via `write_memory`; update existing memories rather than creating duplicates

## iOS Simulator
- Always use the **booted simulator first**, referenced by **UUID** (not name)
- If no simulator is booted, **ask the user** which one to use

## Build & Test (XcodeBuildMCP)

All build, test, and run operations go through **XcodeBuildMCP** (see the `xcodebuildmcp` skill for the full tool catalog).

The `xcode-ide` workflow is enabled via `.xcodebuildmcp/config.yaml`, providing `xcode_tools_*` (incremental builds — fast). Default to these. Use CLI tools (`build_sim`, `test_sim`, etc.) only when you need scheme switching, `-only-testing`, or UI interaction. Set `preferXcodebuild: true` in `session_set_defaults` to force full `xcodebuild` builds.

### Rules
- Before the first build/test in a session, call `session_show_defaults` to verify the active project, scheme, and simulator
- **Never** run `xcrun` or `xcodebuild` directly via Bash — always use XcodeBuildMCP tools
- **Never** build or test unless explicitly asked
<!-- EDIT: Set your .xcodeproj and default scheme below -->
- Always use `__PROJECT__.xcodeproj` with the appropriate scheme
- **Never** suppress warnings — if any are related to the session, fix them
- Prefer `snapshot_ui` over `screenshot` (screenshot only as fallback)

## Code Reviews
- When asked to **review a PR** or **answer a question about code**, do NOT make code edits or run commands unless explicitly asked
- Review tasks are **read-only by default** — provide findings in conversation only
- Do not post GitHub comments unless explicitly asked

## Git & GitHub
<!-- EDIT: Set your branch naming convention below -->
- Branch naming: `__BRANCH_PREFIX__/{ticket-and-small-title}`
- **Never commit without being asked**
- Use `gh` command for GitHub queries (auth already configured)

### Commit Message
- One-line short description
- Max 3 bullet points
- Consider only the actual changes being committed
