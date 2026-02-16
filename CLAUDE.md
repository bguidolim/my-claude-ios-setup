# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Portable, interactive Bash setup script that configures Claude Code with MCP servers, plugins, skills, hooks, and settings optimized for iOS development on macOS. Installs to `~/.claude/` and configures per-project files via templates.

## Commands

```bash
./setup.sh                      # Interactive setup (pick components)
./setup.sh --all                # Install everything (minimal prompts)
./setup.sh --dry-run            # Preview what would be installed
./setup.sh --all --dry-run      # Preview full install
./setup.sh doctor               # Diagnose installation health
./setup.sh doctor --fix         # Diagnose and auto-fix issues
./setup.sh configure-project    # Generate CLAUDE.local.md for a project
./setup.sh cleanup              # Find and delete backup files
```

There are no tests, linting, or build steps — this is a pure Bash project.

## Architecture

### Entry points
- `setup.sh` — main orchestrator; parses args, sources lib modules, dispatches to subcommands or runs the 5-phase install flow (welcome → selection → summary → install → post-summary)
- `install.sh` — one-line web installer that clones to a temp dir and runs `setup.sh` with stdin from `/dev/tty`

### Library modules (`lib/`)
All sourced by `setup.sh` to share global state (flags, paths, color constants) without subshell overhead:
- `utils.sh` — logging (`info`, `success`, `warn`, `error`, `header`, `step`), `ask_yn` prompts, `backup_file`, manifest tracking (SHA-256), `try_install`, brew path detection, `claude_cli` wrapper, `sed_escape`
- `fixes.sh` — shared `fix_*` functions (brew packages, Ollama, hooks, skills, plugins, settings, gitignore) used by both `phase_install()` and `doctor --fix`; no UI output, returns 0/1
- `phases.sh` — the 5 installation phases; `phase_install()` delegates to `fix_*` functions for actual work, adds UI (progress steps, info/success/warn) and tracking (`INSTALLED_ITEMS`, `SKIPPED_ITEMS`)
- `configure.sh` — `configure_project()`: auto-detects Xcode projects, fills `__PLACEHOLDER__` tokens in templates, writes `CLAUDE.local.md` and `.xcodebuildmcp/config.yaml`
- `doctor.sh` — `phase_doctor()`: health checks (deps, MCP servers, plugins, skills, hooks, file freshness via manifest); `--fix` mode calls `fix_*` functions from `fixes.sh`
- `cleanup.sh` — backup file management (end-of-run prompt + `cleanup` subcommand)

### Templates (`templates/`)
- `CLAUDE.local.md` — per-project Claude instructions; placeholders: `__PROJECT__`, `__REPO_NAME__`, `__USER_NAME__`
- `xcodebuildmcp.yaml` — XcodeBuildMCP workflow config

### Installed artifacts
- `config/settings.json` → `~/.claude/settings.json` (merged via jq)
- `hooks/` → `~/.claude/hooks/` (session_start, continuous-learning-activator)
- `skills/continuous-learning/` → `~/.claude/skills/continuous-learning/`
- `commands/pr.md` → `~/.claude/commands/pr.md`

## Bash Conventions

- All scripts use `set -euo pipefail`; hooks use `trap 'exit 0' ERR` so failures don't crash Claude Code
- Idempotent design: `*_needed` flags and `check_command` skip already-completed steps on re-runs
- Global state via variables (`INSTALL_*`, `DRY_RUN`, `INSTALL_ALL`, tracking arrays `INSTALLED_ITEMS`, `SKIPPED_ITEMS`, `CREATED_BACKUPS`)
- Template substitution uses `sed` with `sed_escape()` for safe path handling
- JSON merging uses `jq` (array merge replaces rather than appends — see Serena memory `learning_jq_array_merge_silent_replacement`)
- Dependencies are auto-resolved: selecting a component adds its required deps (e.g., Serena → uv, docs-mcp → Ollama)
- `try_install` wraps installations: captures stderr, warns on failure, records in `SKIPPED_ITEMS`
- Backups are always created before overwriting existing files

## Key Design Decisions

- **Sourced modules over subshells**: `lib/*.sh` are sourced (not executed) so they share the parent's global variables
- **Subcommands over flags**: `doctor`, `configure-project`, `cleanup` are positional subcommands, not `--flags`
- **Template-driven config**: templates use `__PLACEHOLDER__` tokens filled at runtime; `<!-- EDIT: ... -->` comments are stripped after substitution
- **Two-tier backup cleanup**: prompt at end of run for fresh backups + dedicated `cleanup` subcommand for old ones
- **Manifest tracking**: `~/.claude/.setup-manifest` stores SHA-256 hashes of source files for freshness checks in `doctor`
