# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Swift CLI tool (`mcs`) that configures Claude Code with MCP servers, plugins, skills, hooks, and settings. Technology-agnostic core with a "tech pack" extension model. Currently ships with an iOS tech pack. Distributed via Homebrew.

## Commands

```bash
# Development
swift build                      # Build the CLI
swift test                       # Run tests
swift build -c release --arch arm64 --arch x86_64  # Universal binary

# CLI usage (after install)
mcs install                      # Interactive setup (pick components)
mcs install --all                # Install everything
mcs install --dry-run            # Preview what would be installed
mcs install --pack ios           # Install iOS pack components
mcs doctor                       # Diagnose installation health (core + installed packs)
mcs doctor --fix                 # Diagnose and auto-fix issues
mcs doctor --pack ios            # Only check a specific pack
mcs configure [path]             # Generate CLAUDE.local.md (core + installed packs)
mcs configure --pack ios         # Explicitly apply a pack's templates
mcs cleanup                      # Find and delete backup files
mcs cleanup --force              # Delete backups without confirmation
```

## Architecture

### Swift Package Structure
- **Package.swift** — swift-tools-version: 6.0, macOS 13+, deps: swift-argument-parser, Yams
- **Sources/mcs/** — main executable target
- **Tests/MCSTests/** — test target

### Entry Point
- `CLI.swift` — `@main` struct, `MCSVersion.current`, subcommand registration

### Core (`Sources/mcs/Core/`)
- `Constants.swift` — centralized string constants (file names, CLI paths, Ollama config, hooks, Serena, JSON keys, plugins)
- `Environment.swift` — paths, arch detection, brew path, shell RC
- `CLIOutput.swift` — ANSI colors, logging, prompts, multi-select, doctor summary
- `ShellRunner.swift` — Process execution wrapper
- `Settings.swift` — Codable model for `settings.json`, deep-merge (replaces jq)
- `SettingsOwnership.swift` — sidecar file tracking which settings keys mcs manages, stale key detection
- `Manifest.swift` — SHA-256 tracking via CryptoKit, per-file directory hashing, installed component/pack tracking
- `Backup.swift` — timestamped backups before file writes, backup discovery and deletion
- `GitignoreManager.swift` — global gitignore management, core entry list
- `ClaudeIntegration.swift` — `claude mcp add/remove`, `claude plugin install/remove`
- `Homebrew.swift` — brew detection, package install
- `HookInjector.swift` — section-marker-based fragment injection into hook files
- `OllamaService.swift` — Ollama daemon management, model pull, health check
- `ProjectDetector.swift` — walk-up project root detection (`.git/` or `CLAUDE.local.md`)
- `ProjectState.swift` — per-project `.claude/.mcs-project` state (configured packs, version)
- `MCSError.swift` — error types for the CLI

### TechPack System (`Sources/mcs/TechPack/`)
- `TechPack.swift` — protocol for tech packs (components, templates, hooks, doctor checks, migrations)
- `Component.swift` — ComponentDefinition with install actions, ComponentType enum
- `TechPackRegistry.swift` — registry of available packs, filtering by installed state
- `DependencyResolver.swift` — topological sort of component dependencies with cycle detection

### Doctor (`Sources/mcs/Doctor/`)
- `DoctorRunner.swift` — 7-layer check orchestration with project-aware pack resolution
- `CoreDoctorChecks.swift` — check structs (CommandCheck, MCPServerCheck, PluginCheck, HookCheck, SettingsCheck, GitignoreCheck, DeprecatedMCPServerCheck, DeprecatedPluginCheck, HookContributionCheck, PackMigrationCheck, etc.)
- `DerivedDoctorChecks.swift` — `deriveDoctorCheck()` extension on ComponentDefinition + SkillFreshnessCheck + ManifestFreshnessCheck
- `ProjectDoctorChecks.swift` — project-scoped checks (CLAUDE.local.md version, Serena memory migration, state file)
- `SectionValidator.swift` — validation of CLAUDE.local.md section markers
- `MigrationDetector.swift` — detection of legacy bash installer artifacts

### Commands (`Sources/mcs/Commands/`)
- `InstallCommand.swift` — 5-phase install flow with interactive selection
- `DoctorCommand.swift` — health checks with optional --fix and --pack filter
- `ConfigureCommand.swift` — project configuration with --pack option and interactive flow
- `CleanupCommand.swift` — backup file management with --force flag

### Install (`Sources/mcs/Install/`)
- `Installer.swift` — 5-phase orchestrator (welcome, selection, summary, install, post-summary)
- `CoreComponents.swift` — all core component definitions, feature bundles, hook fragments
- `ComponentExecutor.swift` — dispatches individual install actions (brew packages, MCP servers, plugins, gitignore, hooks)
- `SelectionState.swift` — tracks selected component IDs and branch prefix during install
- `PackInstaller.swift` — auto-installs missing pack components during configure
- `ProjectConfigurator.swift` — template composition, CLAUDE.local.md writing, Serena memory symlink, gitignore

### Templates (`Sources/mcs/Templates/`)
- `TemplateEngine.swift` — `__PLACEHOLDER__` substitution
- `TemplateComposer.swift` — section markers for composed files (`<!-- mcs:begin core v2.0.0 -->`), section parsing, user content preservation

### Core Pack (`Sources/mcs/Packs/Core/`)
- `CoreTechPack.swift` — universal tech pack for any project, conditional template contributions (continuous learning, Serena)
- `CoreTemplates.swift` — CLAUDE.local.md section templates for core features

### iOS Pack (`Sources/mcs/Packs/iOS/`)
- `IOSTechPack.swift` — TechPack conformance, Xcode project auto-detection
- `IOSComponents.swift` — XcodeBuildMCP, Sosumi, xcodebuildmcp skill, gitignore entries
- `IOSDoctorChecks.swift` — Xcode CLT check, XcodeBuildMCP config check, CLAUDE.local.md iOS section check
- `IOSConstants.swift` — iOS-specific string constants
- `IOSTemplates.swift` — iOS CLAUDE.local.md section template, XcodeBuildMCP config template
- `IOSHookFragments.swift` — simulator status check fragment for session_start hook

### Resources (`Sources/mcs/Resources/`)
Bundled with the binary via SwiftPM `.copy()`:
- `config/settings.json` — Claude settings template
- `hooks/` — session_start.sh, continuous-learning-activator.sh
- `skills/continuous-learning/` — knowledge extraction skill (SKILL.md + references)
- `commands/pr.md, commit.md` — /pr and /commit slash commands

Note: CLAUDE.local.md templates are compiled-in as Swift string literals (`CoreTemplates.swift`, `IOSTemplates.swift`), not bundled resources.

## Testing

- Test files mirror source: `FooTests.swift` tests `Foo.swift`
- Run a single test class: `swift test --filter MCSTests.FooTests`
- Tests construct all state inline; no external fixtures or shared setup

## Key Design Decisions

- **Tech pack protocol**: all platform-specific components (MCP servers, templates, doctor checks) live in tech packs; core is technology-agnostic
- **Explicit pack selection**: packs are installed and tracked explicitly (no auto-detection); doctor and configure only run pack logic for installed packs
- **Compiled-in packs**: packs are Swift targets in the same package, shipped as a single binary
- **Section markers**: composed files use `<!-- mcs:begin/end -->` HTML comments to separate tool-managed content from user content
- **File-based memory**: memories stored in `<project>/.claude/memories/*.md`, indexed by docs-mcp-server for semantic search
- **Settings deep-merge**: native Swift Codable replaces jq; hooks deduplicate by command, plugins merge additively
- **Settings ownership tracking**: sidecar file (`~/.claude/.mcs-settings-keys`) records which keys mcs manages, enabling stale key cleanup when the template changes
- **Backup on every write**: timestamped backup created before any file modification
- **Manifest tracking**: SHA-256 hashes + installed component IDs + installed pack IDs in `~/.claude/.mcs-manifest` for doctor scoping and freshness checks
- **Component-derived doctor checks**: `ComponentDefinition` is the single source of truth — `deriveDoctorCheck()` auto-generates verification from `installAction`, supplementary checks handle extras; both install and doctor share the same detection logic
- **Project awareness**: doctor detects project root (walk-up for `.git/`), resolves packs from `.claude/.mcs-project` before falling back to section marker inference, then to global manifest
- **Hook fragment injection**: pack hook contributions and core features (continuous learning) use versioned section markers (`# --- mcs:begin <id> v<version> ---`) for idempotent updates
- **fix() responsibility boundary**: `doctor --fix` handles cleanup, migration, and trivial repairs only; additive operations (install/register/copy) are deferred to `mcs install` to keep the manifest as single source of truth
