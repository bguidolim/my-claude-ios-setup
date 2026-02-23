# Architecture

This document describes the internal architecture of `mcs` for contributors and anyone extending the codebase.

## Package Structure

```
Package.swift                    # swift-tools-version: 6.0, macOS 13+
Sources/mcs/
    CLI.swift                    # @main entry, version, subcommand registration
    Core/                        # Shared infrastructure
    Commands/                    # CLI subcommands (install, doctor, configure, cleanup)
    Install/                     # Installation logic, component definitions, project configuration
    TechPack/                    # Tech pack protocol, component model, dependency resolver
    Templates/                   # Template engine and section-based file composition
    Doctor/                      # Diagnostic checks and fix logic
    Packs/
        Core/                    # Universal tech pack (works with any project)
        iOS/                     # iOS/macOS development tech pack
    Resources/                   # Bundled config, hooks, skills, commands, templates
Tests/MCSTests/                  # Test target
```

## Core Infrastructure

### Environment (`Core/Environment.swift`)

Central path resolution for all file locations. Detects architecture (arm64/x86_64), resolves Homebrew path, and locates the user's shell RC file. Key paths:

- `~/.claude/` -- Claude Code configuration directory
- `~/.claude/settings.json` -- user settings
- `~/.claude.json` -- MCP server registrations
- `~/.claude/hooks/` -- session hooks
- `~/.claude/skills/` -- installed skills
- `~/.claude/commands/` -- slash commands
- `~/.claude/.mcs-manifest` -- manifest tracking installed files
- `~/.claude/.mcs-settings-keys` -- settings ownership sidecar

### Settings (`Core/Settings.swift`, `Core/SettingsOwnership.swift`)

`Settings` is a Codable model that mirrors the structure of `~/.claude/settings.json`. It supports deep-merge: when merging a template into existing settings, hooks are deduplicated by command string, plugins are merged additively, and scalar values from the template take precedence.

`SettingsOwnership` tracks which top-level keys in `settings.json` were written by mcs. This enables stale key cleanup: when a key is removed from the template in a new version, `mcs install` detects and removes it from the user's settings without disturbing user-added keys.

### Manifest (`Core/Manifest.swift`)

Tracks what mcs has installed using three data structures:

1. **File hashes**: SHA-256 hashes of bundled resources at install time, enabling freshness checks
2. **Installed component IDs**: set of component identifiers (e.g., `core.docs-mcp-server`, `ios.xcodebuildmcp`)
3. **Installed pack IDs**: set of pack identifiers (e.g., `ios`)

The manifest is the system's source of truth for "what is installed." Doctor checks read it to determine scope; the installer writes to it after each successful component installation.

### Project State (`Core/ProjectState.swift`)

Per-project state stored at `<project>/.claude/.mcs-project`. Tracks:

- **Configured packs**: which packs have had their templates applied to this project's `CLAUDE.local.md`
- **mcs version**: the version that last wrote the file
- **Timestamp**: when the file was last updated

Written by `mcs configure` after templates are composed and the project is set up.

### Global vs. Project State

The manifest and project state files serve different scopes:

| | `~/.claude/.mcs-manifest` | `<project>/.claude/.mcs-project` |
|---|---|---|
| **Scope** | Machine-wide | Single project |
| **Written by** | `mcs install` | `mcs configure` |
| **Tracks** | Globally installed components, pack IDs, file integrity hashes | Which packs are configured for this project |

Pack identifiers appear in both files because installation and configuration are independent operations:

- **Installed but not configured**: `mcs install --pack ios` registers MCP servers and installs brew packages globally, but no project has iOS templates yet. Doctor should still verify these global tools are healthy.
- **Configured but not installed**: a teammate clones a repo that already has `.mcs-project` listing `ios`, but hasn't run `mcs install`. Doctor inside the project should flag missing components.

The manifest tracks packs globally because the resources it manages (MCP servers via `claude mcp add`, hook files in `~/.claude/hooks/`, settings in `~/.claude/settings.json`, brew packages) are machine-level artifacts, not project-local files.

Doctor resolves which packs to check using a priority chain:

1. `--pack` CLI flag (explicit override)
2. `.mcs-project` configured packs (authoritative per-project source)
3. `CLAUDE.local.md` section markers (legacy inference for projects predating `.mcs-project`)
4. Manifest installed packs (global fallback when outside any project)

### Backup (`Core/Backup.swift`)

Every file write goes through the backup system. Before overwriting a file, a timestamped copy is created (e.g., `settings.json.backup.20260222_143000`). The `mcs cleanup` command discovers and deletes these backups.

### HookInjector (`Core/HookInjector.swift`)

Injects script fragments into hook files using versioned section markers:

```bash
# --- mcs:begin ios v2.0.0 ---
# ... injected fragment ...
# --- mcs:end ios ---
```

This pattern enables idempotent updates: running install again replaces the fragment between markers without affecting the rest of the hook file. Both tech pack hook contributions and core features (continuous learning) use this mechanism.

## Install Flow

The installer (`Install/Installer.swift`) runs five phases:

### Phase 1: Welcome
System checks (macOS, not root, Xcode CLT, Homebrew). Manifest migration from legacy formats.

### Phase 2: Selection
Three modes:
- `--all`: selects every component from core and all packs
- `--pack <name>`: selects all components from the named pack
- Interactive: presents grouped multi-select menu with feature bundles

Feature bundles (`CoreComponents.bundles`) group related components into a single selectable item. For example, "Continuous Learning" bundles `docs-mcp-server` + `continuous-learning` skill + `continuous-learning-activator` hook.

### Phase 3: Summary
Shows the dependency-resolved installation plan grouped by type. Auto-resolved dependencies are annotated. In `--dry-run` mode, stops here.

### Phase 4: Install
Iterates through the resolved plan in topological order. For each component:
1. Checks if already installed using the same doctor check logic (shared detection)
2. Executes the component's install action
3. Records the component in the manifest
4. Runs post-install steps (e.g., starting Ollama, pulling models)

After all components: injects hook contributions, adds gitignore entries, registers continuous learning hooks.

### Phase 5: Post-Summary
Shows installed/skipped items. Offers inline project configuration for interactive installs.

## Dependency Resolution

`DependencyResolver` performs a topological sort of selected components plus their transitive dependencies. It detects cycles and auto-adds dependencies that weren't explicitly selected (marking them as "(auto-resolved)" in the summary).

Components declare dependencies by ID:

```swift
static let docsMCPServer = ComponentDefinition(
    id: "core.docs-mcp-server",
    dependencies: ["core.node", "core.ollama"],
    // ...
)
```

## Component Model

Each installable unit is a `ComponentDefinition` with:

- **id**: unique identifier (e.g., `ios.xcodebuildmcp`)
- **type**: `mcpServer`, `plugin`, `skill`, `hookFile`, `command`, `brewPackage`, `configuration`
- **packIdentifier**: `nil` for core, pack ID for pack components
- **dependencies**: IDs of components this depends on
- **isRequired**: if true, always installed with its pack
- **installAction**: how to install (see below)
- **supplementaryChecks**: doctor checks that can't be auto-derived

### Install Actions

```swift
enum ComponentInstallAction {
    case mcpServer(MCPServerConfig)     // Register via `claude mcp add`
    case plugin(name: String)            // Install via `claude plugin install`
    case copySkill(source, destination)  // Copy bundled skill directory
    case copyHook(source, destination)   // Copy bundled hook script
    case copyCommand(source, dest, placeholders)  // Copy with placeholder substitution
    case brewInstall(package: String)    // Install via Homebrew
    case shellCommand(command: String)   // Run arbitrary shell command
    case settingsMerge                   // Deep-merge settings template
    case gitignoreEntries(entries)       // Add to global gitignore
}
```

## Tech Pack Protocol

```swift
protocol TechPack: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var description: String { get }
    var components: [ComponentDefinition] { get }
    var templates: [TemplateContribution] { get }
    var hookContributions: [HookContribution] { get }
    var gitignoreEntries: [String] { get }
    var supplementaryDoctorChecks: [any DoctorCheck] { get }
    var migrations: [any PackMigration] { get }
    func configureProject(at path: URL, context: ProjectConfigContext) throws
}
```

Packs provide:
- **Components**: installable units (MCP servers, skills, etc.)
- **Templates**: sections to inject into `CLAUDE.local.md`
- **Hook contributions**: script fragments to inject into existing hooks
- **Gitignore entries**: patterns to add to the global gitignore
- **Supplementary doctor checks**: pack-level diagnostics not derivable from components
- **Migrations**: versioned data migrations run by `doctor --fix`
- **Project configuration**: pack-specific setup (e.g., iOS generates `.xcodebuildmcp/config.yaml`)

The registry (`TechPackRegistry`) holds all compiled-in packs and provides filtering by installed state.

## Doctor System

`DoctorRunner` orchestrates checks across seven layers:

1. **Derived checks**: auto-generated from each component's `installAction` via `deriveDoctorCheck()`
2. **Supplementary component checks**: additional checks declared on components
3. **Supplementary pack checks**: pack-level concerns not tied to a specific component
4. **Standalone checks**: cross-component concerns (hook event registration, settings validation, gitignore, manifest freshness)
5. **Deprecation checks**: detect and optionally remove legacy components
6. **Hook contribution checks**: verify pack hook fragments are injected and up to date
7. **Project checks**: CLAUDE.local.md version, Serena memory migration, project state file

### fix() Responsibility Boundary

`doctor --fix` only handles:
- **Cleanup**: removing deprecated components
- **Migration**: one-time data moves (memories, state files)
- **Trivial repairs**: permission fixes, gitignore additions

`doctor --fix` does NOT handle additive operations (installing packages, registering servers, copying files). These are `mcs install`'s responsibility because only install manages the manifest. This prevents inconsistent state where a file exists but the manifest doesn't track it.

### Pack Resolution

When determining which packs to check, doctor uses a priority chain:
1. Explicit `--pack` flag
2. Project `.mcs-project` state file
3. Inferred from `CLAUDE.local.md` section markers
4. Global manifest

## Template System

### TemplateEngine

Simple `__PLACEHOLDER__` substitution. Values are passed as `[String: String]` dictionaries.

### TemplateComposer

Manages section markers in `CLAUDE.local.md`:

```html
<!-- mcs:begin core v2.0.0 -->
... managed content ...
<!-- mcs:end core -->

<!-- mcs:begin ios v2.0.0 -->
... managed content ...
<!-- mcs:end ios -->

(user content preserved outside markers)
```

Key operations:
- `compose()`: create a new file from contributions
- `replaceSection()`: update a section in an existing file
- `extractUserContent()`: preserve content outside markers during updates
- `parseSections()`: extract section identifiers and versions

## Project Configuration

`ProjectConfigurator` handles per-project setup:

1. Auto-installs missing pack components via `PackInstaller`
2. Resolves the repository name from git
3. Gathers template contributions from CoreTechPack and the selected pack
4. Writes/updates `CLAUDE.local.md` preserving user content
5. Creates `.serena/memories` symlink to `.claude/memories` (if Serena is installed)
6. Ensures global gitignore entries
7. Runs pack-specific configuration (e.g., iOS creates `.xcodebuildmcp/config.yaml`)
8. Writes `.claude/.mcs-project` state file

## Concurrency Model

The codebase uses Swift 6's strict concurrency. All core types conform to `Sendable`. `TechPack` is a `Sendable` protocol. The registry is a static `let` singleton. No mutable global state exists outside the installer's in-progress mutation context.
