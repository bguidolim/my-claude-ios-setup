# Architecture

This document describes the internal architecture of `mcs` for contributors and anyone extending the codebase.

## Package Structure

```
Package.swift                    # swift-tools-version: 6.0, macOS 13+
Sources/mcs/
    CLI.swift                    # @main entry, version, subcommand registration
    Core/                        # Shared infrastructure
    Commands/                    # CLI subcommands (install, doctor, configure, cleanup, pack)
    Install/                     # Installation logic, project configuration, convergence engine
    TechPack/                    # Tech pack protocol, component model, dependency resolver
    Templates/                   # Template engine and section-based file composition
    Doctor/                      # Diagnostic checks and fix logic
    ExternalPack/                # YAML manifest parsing, Git fetching, adapter, script runner
Tests/MCSTests/                  # Test target
```

## Design Philosophy

`mcs` is a **pure pack management engine** with zero bundled content. It ships no templates, hooks, settings, skills, or slash commands. Everything comes from external tech packs that users add via `mcs pack add <url>`.

The two primary commands:
- **`mcs install`** — global component installation (brew packages, MCP servers, plugins)
- **`mcs configure`** — per-project setup with multi-pack selection and convergent artifact management

## Core Infrastructure

### Environment (`Core/Environment.swift`)

Central path resolution for all file locations. Detects architecture (arm64/x86_64), resolves Homebrew path, and locates the user's shell RC file. Key paths:

- `~/.claude/` — Claude Code configuration directory
- `~/.claude/settings.json` — user settings (global)
- `~/.claude.json` — MCP server registrations (global + per-project via `local` scope)
- `~/.claude/packs/` — external tech pack checkouts
- `~/.claude/packs.yaml` — registry of installed external packs
- `~/.claude/.mcs-manifest` — manifest tracking globally installed files

Per-project paths (created by `mcs configure`):
- `<project>/.claude/settings.local.json` — per-project settings with hook entries
- `<project>/.claude/skills/` — per-project skills
- `<project>/.claude/hooks/` — per-project hook scripts
- `<project>/.claude/commands/` — per-project slash commands
- `<project>/.claude/.mcs-project` — per-project state (JSON)
- `<project>/CLAUDE.local.md` — per-project instructions with section markers

### Settings (`Core/Settings.swift`)

`Settings` is a Codable model that mirrors the structure of Claude Code settings files. It supports deep-merge: when merging, hooks are deduplicated by command string, plugins are merged additively, and scalar values from the template take precedence.

In the per-project model, `ProjectConfigurator` composes `settings.local.json` from all selected packs' hook entries. Each pack gets its own `HookGroup` entry pointing to a script in `<project>/.claude/hooks/`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash .claude/hooks/core-session-start.sh" }] },
      { "hooks": [{ "type": "command", "command": "bash .claude/hooks/ios-session-start.sh" }] }
    ]
  }
}
```

### Manifest (`Core/Manifest.swift`)

Tracks what mcs has installed globally using three data structures:

1. **File hashes**: SHA-256 hashes of copied resources at install time
2. **Installed component IDs**: set of component identifiers (e.g., `ios.xcodebuildmcp`)
3. **Installed pack IDs**: set of pack identifiers (e.g., `ios`)

The manifest covers global-scope installations. Per-project state is tracked separately by `ProjectState`.

### Project State (`Core/ProjectState.swift`)

Per-project state stored as JSON at `<project>/.claude/.mcs-project`. Tracks:

- **Configured packs**: which packs are configured for this project
- **Per-pack artifact records** (`PackArtifactRecord`): for each pack, what was installed
  - `mcpServers`: name + scope (for `claude mcp remove`)
  - `files`: project-relative paths (for deletion)
  - `templateSections`: section identifiers (for CLAUDE.local.md removal)
  - `hookCommands`: hook commands (for settings.local.json cleanup)
  - `settingsKeys`: settings keys contributed by this pack
- **mcs version**: the version that last wrote the file
- **Timestamp**: when the file was last updated

Written by `mcs configure` after convergence. Supports legacy key=value format migration.

### Global vs. Project State

| | `~/.claude/.mcs-manifest` | `<project>/.claude/.mcs-project` |
|---|---|---|
| **Scope** | Machine-wide | Single project |
| **Written by** | `mcs install` | `mcs configure` |
| **Format** | Key=value | JSON |
| **Tracks** | Globally installed components, pack IDs, file hashes | Per-pack artifact records, configured pack IDs |

### Backup (`Core/Backup.swift`)

Every file write goes through the backup system. Before overwriting a file, a timestamped copy is created (e.g., `settings.json.backup.20260222_143000`). The `mcs cleanup` command discovers and deletes these backups.

### ClaudeIntegration (`Core/ClaudeIntegration.swift`)

Wraps `claude mcp add/remove` and `claude plugin install/remove` CLI commands. MCP server registration supports three scopes:

- **`local`** (default): per-user, per-project — stored in `~/.claude.json` keyed by project path
- **`project`**: team-shared — stored in `.mcp.json` in the project directory
- **`user`**: cross-project — stored in `~/.claude.json` globally

## External Pack System

External packs are Git repositories containing a `techpack.yaml` manifest. The system has these layers:

1. **PackFetcher** — clones/pulls pack repos into `~/.claude/packs/<name>/`
2. **ExternalPackManifest** — Codable model for `techpack.yaml` (components, templates, hooks, doctor checks, prompts, configure scripts)
3. **ExternalPackAdapter** — bridges `ExternalPackManifest` to the `TechPack` protocol so external packs participate in all install/doctor/configure flows
4. **PackRegistryFile** — YAML registry (`~/.claude/packs.yaml`) tracking which packs are installed
5. **TechPackRegistry** — unified registry that loads external packs and exposes them alongside the (now empty) compiled-in pack list

### Pack Manifest (`techpack.yaml`)

```yaml
identifier: my-pack
displayName: My Pack
description: What this pack provides
components:
  - id: my-pack.server
    displayName: My Server
    type: mcpServer
    installAction:
      mcpServer:
        name: my-server
        command: npx
        args: ["-y", "my-server@latest"]
        scope: local  # local (default), project, or user
templates:
  - sectionIdentifier: my-pack
    contentFile: templates/claude-local.md
hookContributions:
  - hookName: session_start
    fragmentFile: hooks/session-start-fragment.sh
```

## Install Flow

The installer (`Install/Installer.swift`) handles global-scope component installation:

### Phase 1: Welcome
System checks (macOS, not root, Xcode CLT, Homebrew).

### Phase 2: Selection
Three modes:
- `--all`: selects every component from all registered packs
- `--pack <name>`: selects all components from the named pack
- Interactive: presents grouped multi-select menu

### Phase 3: Summary
Shows the dependency-resolved installation plan grouped by type. Auto-resolved dependencies are annotated. In `--dry-run` mode, stops here.

### Phase 4: Install
Iterates through the resolved plan in topological order. For each component:
1. Checks if already installed using the same doctor check logic (shared detection)
2. Executes the component's install action
3. Records the component in the manifest

After all components: adds gitignore entries, records pack IDs in manifest.

### Phase 5: Post-Summary
Shows installed/skipped items. Offers inline project configuration.

## Project Configuration (Convergence Engine)

`ProjectConfigurator` is the per-project convergence engine, invoked by `mcs configure`:

1. **Multi-select**: shows all registered packs, pre-selects previously configured packs
2. **Compute diff**: `removals = previous - selected`, `additions = selected - previous`
3. **Unconfigure removed packs**: remove MCP servers (via CLI), delete project files, using stored `PackArtifactRecord`
4. **Auto-install global deps**: brew packages and plugins for all selected packs
5. **Install per-project artifacts**: copy skills/hooks/commands to `<project>/.claude/`, register MCP servers with `local` scope
6. **Compose `settings.local.json`**: build from all selected packs' hook entries
7. **Compose `CLAUDE.local.md`**: gather template sections from all selected packs
8. **Run pack configure hooks**: pack-specific setup (e.g., generate config files)
9. **Ensure gitignore entries**: add `.claude/` entries to global gitignore
10. **Save project state**: write `.mcs-project` with artifact records for each pack

The `--pack` flag bypasses multi-select for CI use: `mcs configure --pack ios --pack web`.

## Dependency Resolution

`DependencyResolver` performs a topological sort of selected components plus their transitive dependencies. It detects cycles and auto-adds dependencies that weren't explicitly selected (marking them as "(auto-resolved)" in the summary).

## Component Model

Each installable unit is a `ComponentDefinition` with:

- **id**: unique identifier (e.g., `ios.xcodebuildmcp`)
- **type**: `mcpServer`, `plugin`, `skill`, `hookFile`, `command`, `brewPackage`, `configuration`
- **packIdentifier**: pack ID for the owning pack
- **dependencies**: IDs of components this depends on
- **isRequired**: if true, always installed with its pack
- **installAction**: how to install (see below)
- **supplementaryChecks**: doctor checks that can't be auto-derived

### Install Actions

```swift
enum ComponentInstallAction {
    case mcpServer(MCPServerConfig)     // Register via `claude mcp add -s <scope>`
    case plugin(name: String)            // Install via `claude plugin install`
    case brewInstall(package: String)    // Install via Homebrew
    case shellCommand(command: String)   // Run arbitrary shell command
    case settingsMerge                   // Deep-merge settings (project-level)
    case gitignoreEntries(entries)       // Add to global gitignore
    case copyPackFile(source, dest, type) // Copy from pack checkout to project .claude/
}
```

### MCP Server Scopes

`MCPServerConfig` includes a `scope` field:
- `nil` / `"local"` (default) — per-user, per-project isolation
- `"project"` — team-shared (`.mcp.json`)
- `"user"` — cross-project global

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
    func templateValues(context: ProjectConfigContext) -> [String: String]
    func configureProject(at path: URL, context: ProjectConfigContext) throws
}
```

Packs provide:
- **Components**: installable units (MCP servers, skills, etc.)
- **Templates**: sections to inject into `CLAUDE.local.md`
- **Hook contributions**: script files to install in `<project>/.claude/hooks/` with entries in `settings.local.json`
- **Gitignore entries**: patterns to add to the global gitignore
- **Supplementary doctor checks**: pack-level diagnostics not derivable from components
- **Template values**: resolved via prompts or scripts during configure
- **Project configuration**: pack-specific setup (e.g., generate config files)

## Doctor System

`DoctorRunner` orchestrates checks across five layers:

1. **Derived checks**: auto-generated from each component's `installAction` via `deriveDoctorCheck()`
2. **Supplementary component checks**: additional checks declared on components
3. **Supplementary pack checks**: pack-level concerns not tied to a specific component
4. **Standalone checks**: cross-component concerns (hook event registration, settings validation, gitignore)
5. **Project checks**: CLAUDE.local.md version, Serena memory migration, project state file

### fix() Responsibility Boundary

`doctor --fix` only handles:
- **Cleanup**: removing deprecated components
- **Trivial repairs**: permission fixes, gitignore additions, symlink creation
- **Project state**: creating missing `.mcs-project` by inferring from section markers

`doctor --fix` does NOT handle additive operations (installing packages, registering servers, copying files). These are handled by `mcs install` and `mcs configure`.

### Pack Resolution

When determining which packs to check, doctor uses a priority chain:
1. Explicit `--pack` flag
2. Project `.mcs-project` state file
3. Inferred from `CLAUDE.local.md` section markers
4. Global manifest

## Template System

### TemplateEngine

Simple `__PLACEHOLDER__` substitution. Values are passed as `[String: String]` dictionaries. Packs can resolve values via prompts (interactive) or scripts (automated) during configure.

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

## Concurrency Model

The codebase uses Swift 6's strict concurrency. All core types conform to `Sendable`. `TechPack` is a `Sendable` protocol. No mutable global state exists outside the installer's in-progress mutation context.
