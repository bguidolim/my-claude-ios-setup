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
mcs doctor                       # Diagnose installation health
mcs doctor --fix                 # Diagnose and auto-fix issues
mcs configure-project [path]     # Generate CLAUDE.local.md for a project
mcs cleanup                      # Find and delete backup files
mcs update                       # Update via Homebrew
```

## Architecture

### Swift Package Structure
- **Package.swift** — swift-tools-version: 6.0, macOS 13+, deps: swift-argument-parser, Yams
- **Sources/mcs/** — main executable target

### Core (`Sources/mcs/Core/`)
- `Environment.swift` — paths, arch detection, brew path, shell RC
- `CLIOutput.swift` — ANSI colors, logging, prompts
- `ShellRunner.swift` — Process execution wrapper
- `Settings.swift` — Codable model, deep-merge (replaces jq)
- `Manifest.swift` — SHA-256 tracking via CryptoKit
- `Backup.swift` — timestamped backups before file writes
- `GitignoreManager.swift` — global gitignore management
- `ClaudeIntegration.swift` — `claude mcp add`, `claude plugin install`
- `Homebrew.swift` — brew detection, package install

### TechPack System (`Sources/mcs/TechPack/`)
- `TechPack.swift` — protocol for tech packs (components, templates, hooks, doctor checks)
- `Component.swift` — ComponentDefinition with install actions
- `TechPackRegistry.swift` — registry of available packs
- `DependencyResolver.swift` — topological sort of component dependencies

### Commands (`Sources/mcs/Commands/`)
- `InstallCommand.swift` — 5-phase install flow with interactive selection
- `DoctorCommand.swift` — health checks with optional --fix
- `ConfigureCommand.swift` — project configuration with memory migration
- `CleanupCommand.swift` — backup file management
- `UpdateCommand.swift` — Homebrew upgrade wrapper

### Templates (`Sources/mcs/Templates/`)
- `TemplateEngine.swift` — `__PLACEHOLDER__` substitution
- `TemplateComposer.swift` — section markers for composed files (`<!-- mcs:begin core v2.0.0 -->`)

### iOS Pack (`Sources/mcs/Packs/iOS/`)
- `IOSTechPack.swift` — TechPack conformance
- `IOSComponents.swift` — XcodeBuildMCP, Sosumi, xcodebuildmcp skill
- `IOSProjectDetector.swift` — .xcodeproj/.xcworkspace detection
- `IOSDoctorChecks.swift` — Xcode CLT, MCP server checks

### Resources (`Sources/mcs/Resources/`)
Bundled with the binary via SwiftPM `.copy()`:
- `config/settings.json` — Claude settings template
- `hooks/` — session_start.sh, continuous-learning-activator.sh
- `skills/continuous-learning/` — knowledge extraction skill
- `commands/pr.md` — /pr slash command
- `templates/core/` — core CLAUDE.local.md template
- `templates/packs/ios/` — iOS CLAUDE.local.md section, xcodebuildmcp.yaml

## Key Design Decisions

- **Tech pack protocol**: all platform-specific components (MCP servers, templates, doctor checks) live in tech packs; core is technology-agnostic
- **Compiled-in packs**: packs are Swift targets in the same package, shipped as a single binary
- **Section markers**: composed files use `<!-- mcs:begin/end -->` HTML comments to separate tool-managed content from user content
- **File-based memory**: memories stored in `<project>/.claude/memories/*.md`, indexed by docs-mcp-server for semantic search
- **Settings deep-merge**: native Swift Codable replaces jq; hooks deduplicate by command, plugins merge additively
- **Backup on every write**: timestamped backup created before any file modification
- **Manifest tracking**: SHA-256 hashes in `~/.claude/.setup-manifest` for doctor freshness checks
