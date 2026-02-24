# Creating Tech Packs

This guide walks through creating an external tech pack for `mcs`. Tech packs add platform-specific MCP servers, templates, hooks, doctor checks, and project configuration.

## Overview

A tech pack is a Git repository containing a `techpack.yaml` manifest file. Packs are installed via `mcs pack add <url>` and configured per-project via `mcs configure`. There are no compiled-in packs — all packs are external.

## Quick Start

```bash
# Create a new pack repo
mkdir my-pack && cd my-pack && git init

# Create the manifest
cat > techpack.yaml << 'EOF'
schemaVersion: 1
identifier: my-pack
displayName: My Pack
description: What this pack provides
version: "1.0.0"
EOF

# Push to GitHub, then install
mcs pack add https://github.com/you/my-pack
```

## Pack Structure

```
my-pack/
    techpack.yaml                # Required: pack manifest
    templates/
        claude-local.md          # CLAUDE.local.md section content
    hooks/
        session-start.sh         # Hook script(s)
    skills/
        my-skill/SKILL.md        # Skill files
    commands/
        my-command.md            # Slash commands
    config/
        settings.json            # Settings template
    scripts/
        configure.sh             # Optional: configure hook script
```

## Manifest Reference (`techpack.yaml`)

### Minimal Manifest

```yaml
schemaVersion: 1
identifier: my-pack
displayName: My Pack
description: Adds tools for my workflow
version: "1.0.0"
```

### Full Example (Shorthand)

Components support a **shorthand syntax** where a single key replaces both `type` and `installAction`. This is the recommended style — it's more concise and less error-prone.

```yaml
schemaVersion: 1
identifier: my-pack
displayName: My Pack
description: Adds tools for my workflow
version: "1.0.0"

components:
  # Brew package — `brew:` infers type: brewPackage
  - id: node
    description: JavaScript runtime
    dependencies: [homebrew]
    brew: node

  # MCP server (stdio) — `mcp:` infers type: mcpServer, name from id
  - id: my-server
    description: Code search server
    dependencies: [node]
    mcp:
      command: npx
      args: ["-y", "my-server@latest"]
      env:
        API_KEY: "value"
      scope: local          # local (default), project, or user

  # MCP server (HTTP) — url presence infers HTTP transport
  - id: my-http-server
    description: Remote MCP server
    mcp:
      url: https://example.com/mcp

  # Plugin — `plugin:` infers type: plugin
  - id: my-plugin
    description: A useful plugin
    plugin: "my-plugin@my-org"

  # Hook — `hook:` infers type: hookFile, fileType: hook
  - id: session-hook
    description: Session start hook
    hookEvent: SessionStart
    hook:
      source: hooks/session_start.sh
      destination: session_start.sh

  # Command — `command:` infers type: command, fileType: command
  - id: pr-command
    description: PR creation command
    command:
      source: commands/pr.md
      destination: pr.md

  # Skill — `skill:` infers type: skill, fileType: skill
  - id: my-skill
    description: A pack-provided skill
    skill:
      source: skills/my-skill
      destination: my-skill

  # Settings — `settingsFile:` infers type: configuration
  - id: settings
    description: Claude Code settings
    isRequired: true
    settingsFile: config/settings.json

  # Gitignore — `gitignore:` infers type: configuration
  - id: gitignore
    description: Global gitignore entries
    isRequired: true
    gitignore:
      - .my-pack
      - .my-pack-cache

  # Shell command — `shell:` requires explicit `type:`
  - id: homebrew
    displayName: Homebrew
    description: macOS package manager
    type: brewPackage
    shell: '/bin/bash -c "$(curl -fsSL https://brew.sh)"'
    doctorChecks:
      - type: commandExists
        name: Homebrew
        section: Dependencies
        command: brew

templates:
  - sectionIdentifier: my-pack
    contentFile: templates/claude-local.md
    placeholders: ["__PROJECT__"]

prompts:
  - key: PROJECT
    type: fileDetect
    label: "Project file"
    detectPattern: "*.xcodeproj"

configureProject:
  script: scripts/configure.sh

supplementaryDoctorChecks:
  - name: My Tool Config
    section: My Pack
    type: fileExists
    path: ".my-pack/config.yaml"
```

### Verbose Form (Still Supported)

The shorthand is syntactic sugar — the **verbose form** with explicit `type` + `installAction` is always supported and required for edge cases like `shell:` commands.

```yaml
# Verbose equivalent of `brew: node`
- id: node
  displayName: Node.js
  description: JavaScript runtime
  type: brewPackage
  installAction:
    type: brewInstall
    package: node
```

## Shorthand Reference

| Shorthand Key | Value Type | Infers `type` | Infers `installAction` |
|--------------|-----------|---------------|----------------------|
| `brew:` | `String` | `brewPackage` | `brewInstall(package:)` |
| `mcp:` | Map | `mcpServer` | `mcpServer(config)` — name defaults to component id |
| `plugin:` | `String` | `plugin` | `plugin(name:)` |
| `shell:` | `String` | *none — requires explicit `type:`* | `shellCommand(command:)` |
| `hook:` | `{source, destination}` | `hookFile` | `copyPackFile(fileType: hook)` |
| `command:` | `{source, destination}` | `command` | `copyPackFile(fileType: command)` |
| `skill:` | `{source, destination}` | `skill` | `copyPackFile(fileType: skill)` |
| `settingsFile:` | `String` | `configuration` | `settingsFile(source:)` |
| `gitignore:` | `[String]` | `configuration` | `gitignoreEntries(entries:)` |

**Additional notes:**
- `displayName` is optional — defaults to the component `id` if omitted
- `mcp:` derives the server name from the component id. Use `name:` inside the map to override (e.g. when the server name uses mixed case)
- `shell:` is the only shorthand that doesn't infer `type` — you must provide `type:` explicitly since shell commands can install anything (brew packages, skills, etc.)

## Component Types

| Type | Description |
|------|-------------|
| `mcpServer` | MCP server registered via `claude mcp add` |
| `plugin` | Claude Code plugin |
| `brewPackage` | Homebrew package |
| `skill` | Skill directory copied to `<project>/.claude/skills/` |
| `hookFile` | Hook script copied to `<project>/.claude/hooks/` |
| `command` | Slash command copied to `<project>/.claude/commands/` |
| `configuration` | Gitignore entries, settings merge, etc. |

## Component Features

### Dependencies

Components can depend on other components. Use short IDs (auto-prefixed with the pack identifier):

```yaml
- id: my-server
  dependencies: [node, homebrew]   # → my-pack.node, my-pack.homebrew
  mcp:
    command: npx
    args: ["-y", "my-server@latest"]
```

Cross-pack dependencies use the full `pack.component` form:

```yaml
- id: my-tool
  dependencies: [other-pack.node]
  brew: my-tool
```

### Short IDs

Component IDs can use short form — the engine auto-prefixes with `<pack-identifier>.`:

```yaml
identifier: my-pack
components:
  - id: node          # → my-pack.node
  - id: my-server     # → my-pack.my-server
```

### MCP Server Scopes

The `scope` field on MCP server components controls where the server is registered:

- **`local`** (default): per-user, per-project — stored in `~/.claude.json` keyed by project path. This is the recommended scope for project-specific tools.
- **`project`**: team-shared — stored in `.mcp.json` in the project directory. Use when the entire team should have the same server.
- **`user`**: cross-project — stored in `~/.claude.json` globally. Use sparingly for truly global tools.

## Templates

Templates contribute sections to `CLAUDE.local.md`. Create a markdown file referenced by `contentFile`:

```markdown
## My Pack Instructions

When working on this project, follow these guidelines:

- Guideline 1
- Guideline 2

Project: __REPO_NAME__
```

Placeholders use the `__NAME__` format and are substituted during `mcs configure`. Built-in placeholder:
- `__REPO_NAME__` — git repository name (always available)

Custom placeholders are resolved via `prompts` in the manifest.

## Prompts

Prompts gather values during `mcs configure`. Four types are available:

```yaml
prompts:
  # Detect files matching a glob pattern
  - key: PROJECT
    type: fileDetect
    label: "Xcode project"
    detectPattern:
      - "*.xcodeproj"
      - "*.xcworkspace"

  # Free-text input
  - key: BRANCH_PREFIX
    type: input
    label: "Branch prefix"
    default: "feature"

  # Select from predefined options
  - key: PLATFORM
    type: select
    label: "Target platform"
    options:
      - value: ios
        label: iOS
      - value: macos
        label: macOS

  # Run a script to get the value
  - key: SDK_VERSION
    type: script
    label: "SDK version"
    scriptCommand: "xcrun --show-sdk-version"
```

Resolved values are available as `__KEY__` placeholders in templates and as `MCS_RESOLVED_KEY` env vars in scripts.

## Hook Contributions

Hook contributions are installed as individual script files in `<project>/.claude/hooks/` and registered as separate `HookGroup` entries in `settings.local.json`.

Create a shell script fragment referenced by `fragmentFile`:

```bash
#!/bin/bash
# My pack session start hook
if command -v my-tool &>/dev/null; then
    echo "my-tool: $(my-tool --version)"
fi
```

Hook names map to Claude Code events:
- `session_start` → `SessionStart`
- `pre_tool_use` → `PreToolUse`
- `post_tool_use` → `PostToolUse`
- `notification` → `Notification`
- `stop` → `Stop`

## Doctor Checks

### Auto-Derived Checks

Most components automatically generate doctor checks from their install action:
- `mcpServer` → checks registration in `~/.claude.json`
- `plugin` → checks enablement in settings
- `brewInstall` → checks command availability
- `copyPackFile` → checks file existence at destination

### Per-Component Checks

For components with special verification needs, define `doctorChecks` inline:

```yaml
- id: homebrew
  description: macOS package manager
  type: brewPackage
  shell: '/bin/bash -c "$(curl -fsSL https://brew.sh)"'
  doctorChecks:
    - type: commandExists
      name: Homebrew
      section: Dependencies
      command: brew
```

### Supplementary Checks (Pack-Level)

For checks that don't belong to a specific component:

```yaml
supplementaryDoctorChecks:
  - name: My Tool Config
    section: My Pack
    type: fileExists
    path: ".my-pack/config.yaml"

  - name: My Service Running
    section: My Pack
    type: shellScript
    command: "curl -s localhost:8080/health"
    fixCommand: "my-service start"
```

### Available Check Types

| Type | Required Fields | Description |
|------|----------------|-------------|
| `commandExists` | `command` | Check if a CLI command is available |
| `fileExists` | `path` | Check if a file exists |
| `directoryExists` | `path` | Check if a directory exists |
| `fileContains` | `path`, `pattern` | Check if a file matches a regex |
| `fileNotContains` | `path`, `pattern` | Check a file does NOT match a regex |
| `shellScript` | `command` | Run a shell command (exit 0=pass, 1=fail, 2=warn, 3=skip) |
| `hookEventExists` | `event` | Check if a hook event is registered in settings |
| `settingsKeyEquals` | `keyPath`, `expectedValue` | Check a settings value at a JSON key path |

**Optional fields** (available on all check types):
- `section` — grouping label in doctor output
- `fixCommand` — shell command to auto-fix the issue (`mcs doctor --fix`)
- `fixScript` — path to a script file for complex fixes
- `scope` — `global` or `project` (project checks only run when a project is detected)
- `isOptional` — if `true`, failure shows as a warning instead of an error

## Configure Hook

The `configureProject` script runs after all per-project artifacts are installed. It receives environment variables:

- `MCS_PROJECT_PATH` — absolute path to the project
- `MCS_RESOLVED_<KEY>` — resolved prompt values (uppercased)

```bash
#!/bin/bash
# scripts/configure.sh
config_dir="$MCS_PROJECT_PATH/.my-pack"
mkdir -p "$config_dir"
echo "type: $MCS_RESOLVED_PROJECT_TYPE" > "$config_dir/config.yaml"
```

## Per-Project Artifact Placement

When `mcs configure` runs, pack artifacts are placed per-project:

| Artifact | Location | Managed by |
|----------|----------|------------|
| MCP servers | `~/.claude.json` (keyed by project) | `claude mcp add -s local` |
| Skills | `<project>/.claude/skills/` | File copy |
| Hook scripts | `<project>/.claude/hooks/` | File copy |
| Commands | `<project>/.claude/commands/` | File copy |
| Hook entries | `<project>/.claude/settings.local.json` | Composed from all packs |
| Templates | `<project>/CLAUDE.local.md` | Section markers |
| State | `<project>/.claude/.mcs-project` | JSON with artifact records |
| Brew packages | Global via `brew install` | Auto-install |
| Plugins | Global via `claude plugin install` | Auto-install |

## Convergence

`mcs configure` is idempotent. On re-run:

1. **New packs**: full install (MCP, files, templates, settings)
2. **Removed packs**: full cleanup using stored `PackArtifactRecord` (remove MCP servers, delete files, remove template sections)
3. **Unchanged packs**: update idempotently (re-copy files, re-compose settings)

The `PackArtifactRecord` in `.mcs-project` tracks exactly what each pack installed, enabling clean reversal.

## Testing Your Pack

```bash
# Add your pack
mcs pack add /path/to/local/pack   # or https://github.com/you/my-pack

# Configure a project
cd /path/to/project
mcs configure                       # Select your pack in multi-select

# Verify
mcs doctor                          # Check diagnostics
ls .claude/                         # Verify per-project artifacts

# Test convergence: re-run and deselect
mcs configure                       # Deselect your pack
ls .claude/                         # Artifacts should be removed
```

## Design Guidelines

### Component IDs
Use short IDs — the engine auto-prefixes with the pack identifier:
- `server` → `my-pack.server`
- `session-hook` → `my-pack.session-hook`

Or use the fully-qualified form:
- `my-pack.server`
- `my-pack.skill.my-skill`

### Idempotency
Install actions should be safe to re-run. The system checks if components are already installed before executing install actions.

### Scope Selection
Default to `local` scope for MCP servers. Only use `project` scope if the server should be shared with the team (checked into `.mcp.json`). Only use `user` scope for truly global tools that apply to all projects.
