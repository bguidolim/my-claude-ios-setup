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
identifier: my-pack
displayName: My Pack
description: What this pack provides
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
    scripts/
        configure.sh             # Optional: configure hook script
```

## Manifest Reference (`techpack.yaml`)

### Minimal Manifest

```yaml
identifier: my-pack
displayName: My Pack
description: Adds tools for my workflow
```

### Full Manifest

```yaml
identifier: my-pack
displayName: My Pack
description: Adds tools for my workflow

components:
  - id: my-pack.server
    displayName: My MCP Server
    description: Provides code search
    type: mcpServer
    isRequired: true
    installAction:
      mcpServer:
        name: my-server
        command: npx
        args: ["-y", "my-server@latest"]
        scope: local          # local (default), project, or user

  - id: my-pack.tool
    displayName: My CLI Tool
    description: Required dependency
    type: brewPackage
    isRequired: true
    installAction:
      brewInstall: my-tool

  - id: my-pack.gitignore
    displayName: Gitignore entries
    description: Add .my-pack to global gitignore
    type: configuration
    isRequired: true
    installAction:
      gitignoreEntries: [".my-pack"]

  - id: my-pack.skill
    displayName: My skill
    description: A pack-provided skill
    type: skill
    installAction:
      copyPackFile:
        source: skills/my-skill
        destination: my-skill
        fileType: skill       # skill, hook, command, or generic

templates:
  - sectionIdentifier: my-pack
    contentFile: templates/claude-local.md
    placeholders: ["__PROJECT__"]

hookContributions:
  - hookName: session_start
    fragmentFile: hooks/session-start.sh

gitignoreEntries:
  - ".my-pack"

prompts:
  - key: PROJECT_TYPE
    message: "What type of project is this?"
    type: select
    options: ["web", "mobile", "cli"]

configureProject:
  script: scripts/configure.sh

supplementaryDoctorChecks:
  - name: My Tool Config
    section: My Pack
    type: fileExists
    path: ".my-pack/config.yaml"
```

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

## Install Actions

| Action | YAML Key | Use Case |
|--------|----------|----------|
| MCP server | `mcpServer: {name, command, args, env, scope}` | Register via `claude mcp add` |
| HTTP MCP | `mcpServer: {name, url, scope}` | Register HTTP transport server |
| Plugin | `plugin: <name>` | Install via `claude plugin install` |
| Brew | `brewInstall: <package>` | Install via Homebrew |
| Shell | `shellCommand: <command>` | Run arbitrary shell command |
| Gitignore | `gitignoreEntries: [patterns]` | Add to global gitignore |
| Copy file | `copyPackFile: {source, destination, fileType}` | Copy from pack to project `.claude/` |
| Settings | `settingsMerge` | Merge settings (handled at project level) |

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

## Supplementary Doctor Checks

Doctor checks verify the pack's health. Auto-derived checks handle common cases:
- `mcpServer` → checks registration in `~/.claude.json`
- `plugin` → checks enablement in settings
- `brewInstall` → checks command availability

For custom checks, define them in the manifest:

```yaml
supplementaryDoctorChecks:
  - name: My Tool Config
    section: My Pack
    type: fileExists
    path: ".my-pack/config.yaml"

  - name: My Service
    section: My Pack
    type: shellScript
    script: scripts/check-service.sh
```

Shell script checks use exit codes:
- `0` = pass
- `1` = fail
- `2` = warn
- `3` = skip

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
Use the format `<pack>.<name>` or `<pack>.<type>.<name>`:
- `my-pack.server`
- `my-pack.skill.my-skill`

### Sendable Conformance
The `TechPack` protocol requires `Sendable` conformance (Swift 6 strict concurrency). External packs don't need to worry about this — the adapter handles it.

### Idempotency
Install actions should be safe to re-run. The system checks if components are already installed before executing install actions.

### Scope Selection
Default to `local` scope for MCP servers. Only use `project` scope if the server should be shared with the team (checked into `.mcp.json`). Only use `user` scope for truly global tools that apply to all projects.
