# Tech Pack Schema Reference

Complete field-by-field reference for `techpack.yaml`. For a tutorial-style introduction, see [Creating Tech Packs](creating-tech-packs.md).

## Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schemaVersion` | `Integer` | Yes | Must be `1` |
| `identifier` | `String` | Yes | Unique pack ID. Lowercase alphanumeric + hyphens, e.g. `my-pack` |
| `displayName` | `String` | Yes | Human-readable name shown in CLI output |
| `description` | `String` | Yes | One-line description of what the pack provides |
| `version` | `String` | Yes | Semantic version, e.g. `"1.0.0"` |
| `minMCSVersion` | `String` | No | Minimum `mcs` version required, e.g. `"2.1.0"` |
| `peerDependencies` | `[PeerDependency]` | No | Other packs this pack requires |
| `components` | `[Component]` | No | Installable components (see below) |
| `templates` | `[Template]` | No | CLAUDE.local.md section contributions |
| `prompts` | `[Prompt]` | No | Interactive prompts for `mcs sync` |
| `configureProject` | `ConfigureProject` | No | Script to run after project configuration |
| `supplementaryDoctorChecks` | `[DoctorCheck]` | No | Pack-level health checks |
| `hookContributions` | `[HookContribution]` | No | Legacy hook fragments (prefer `hook:` components) |
| `gitignoreEntries` | `[String]` | No | Legacy gitignore entries (prefer `gitignore:` component) |

### PeerDependency

```yaml
peerDependencies:
  - pack: other-pack
    minVersion: "1.0.0"
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `pack` | `String` | Yes | Pack identifier |
| `minVersion` | `String` | Yes | Minimum version required |

---

## Components

Components are defined in the `components` array. Each component represents something `mcs` can install, verify, and uninstall.

### Common Fields

These fields are available on every component, regardless of which shorthand key is used:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | `String` | Yes | Short identifier (no dots). Auto-prefixed with `<pack>.` |
| `description` | `String` | Yes | One-line description |
| `displayName` | `String` | No | Display name (defaults to `id`) |
| `dependencies` | `[String]` | No | Component IDs this depends on. Short form auto-prefixed |
| `isRequired` | `Boolean` | No | If `true`, cannot be deselected in `--customize` mode |
| `hookEvent` | `String` | No | Claude Code event for hook components |
| `doctorChecks` | `[DoctorCheck]` | No | Custom health checks (see [Doctor Checks](#doctor-checks)) |

### Shorthand Keys

Use one of these keys to define a component's install action. Each key infers the component `type` automatically (except `shell:`).

#### `brew:` — Homebrew Package

```yaml
- id: node
  description: JavaScript runtime
  brew: node
```

| Field | Type | Description |
|-------|------|-------------|
| `brew` | `String` | Homebrew package name |

Infers: `type: brewPackage`, `installAction: brewInstall`

---

#### `mcp:` — MCP Server

```yaml
# Stdio transport
- id: my-server
  description: Code analysis
  mcp:
    command: npx
    args: ["-y", "my-server@latest"]
    env:
      API_KEY: "value"
    scope: local

# HTTP transport
- id: remote-server
  description: Cloud server
  mcp:
    url: https://example.com/mcp
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | `String` | No | Server name (defaults to component id) |
| `command` | `String` | Stdio only | Command to run (e.g. `npx`, `uvx`) |
| `args` | `[String]` | No | Command arguments |
| `env` | `{String: String}` | No | Environment variables |
| `url` | `String` | HTTP only | Server URL |
| `scope` | `String` | No | `local` (default), `project`, or `user` |

Transport is inferred: if `url` is present, HTTP; otherwise stdio.

Infers: `type: mcpServer`, `installAction: mcpServer`

---

#### `plugin:` — Claude Code Plugin

```yaml
- id: my-plugin
  description: Helpful plugin
  plugin: "my-plugin@my-org"
```

| Field | Type | Description |
|-------|------|-------------|
| `plugin` | `String` | Plugin full name (`name@org` or `name@user/repo`) |

Infers: `type: plugin`, `installAction: plugin`

---

#### `hook:` — Hook Script

```yaml
- id: session-hook
  description: Session start hook
  hookEvent: SessionStart
  hook:
    source: hooks/session_start.sh
    destination: session_start.sh
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | `String` | Yes | Path to script in the pack repo |
| `destination` | `String` | Yes | Filename in `<project>/.claude/hooks/` |

Use with `hookEvent` to register the hook in `settings.local.json`.

Infers: `type: hookFile`, `installAction: copyPackFile(fileType: hook)`

---

#### `command:` — Slash Command

```yaml
- id: pr-command
  description: Create pull requests
  command:
    source: commands/pr.md
    destination: pr.md
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | `String` | Yes | Path to command file in the pack repo |
| `destination` | `String` | Yes | Filename in `<project>/.claude/commands/` |

Infers: `type: command`, `installAction: copyPackFile(fileType: command)`

---

#### `skill:` — Skill

```yaml
- id: my-skill
  description: Domain knowledge
  skill:
    source: skills/my-skill
    destination: my-skill
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | `String` | Yes | Path to skill directory in the pack repo |
| `destination` | `String` | Yes | Directory name in `<project>/.claude/skills/` |

Infers: `type: skill`, `installAction: copyPackFile(fileType: skill)`

---

#### `settingsFile:` — Settings

```yaml
- id: settings
  description: Claude Code configuration
  isRequired: true
  settingsFile: config/settings.json
```

| Field | Type | Description |
|-------|------|-------------|
| `settingsFile` | `String` | Path to settings JSON file in the pack repo |

The settings file is deep-merged into `<project>/.claude/settings.local.json`.

Infers: `type: configuration`, `installAction: settingsFile`

---

#### `gitignore:` — Gitignore Entries

```yaml
- id: gitignore
  description: Global gitignore
  isRequired: true
  gitignore:
    - .claude/memories
    - .claude/settings.local.json
```

| Field | Type | Description |
|-------|------|-------------|
| `gitignore` | `[String]` | Patterns to add to the global gitignore |

Infers: `type: configuration`, `installAction: gitignoreEntries`

---

#### `shell:` — Shell Command

```yaml
- id: homebrew
  description: macOS package manager
  type: brewPackage           # Required — shell: doesn't infer type
  shell: '/bin/bash -c "$(curl -fsSL https://brew.sh)"'
```

| Field | Type | Description |
|-------|------|-------------|
| `shell` | `String` | Shell command to execute |

**Does not infer `type`** — you must provide `type:` explicitly. This is because a shell command could install anything (a brew package, a skill, a tool).

No auto-derived doctor check — add `doctorChecks` if verification is needed.

---

### Verbose Form

The explicit form with `type` + `installAction` is always supported:

```yaml
- id: my-pack.node
  displayName: Node.js
  description: JavaScript runtime
  type: brewPackage
  installAction:
    type: brewInstall
    package: node
```

#### Install Action Types

| `type` | Fields | Description |
|--------|--------|-------------|
| `mcpServer` | `name`, `command`, `args`, `env`, `transport`, `url`, `scope` | Register MCP server |
| `plugin` | `name` | Install Claude Code plugin |
| `brewInstall` | `package` | Install Homebrew package |
| `shellCommand` | `command` | Run shell command |
| `gitignoreEntries` | `entries` | Add to global gitignore |
| `settingsMerge` | *(none)* | Merge settings (internal) |
| `settingsFile` | `source` | Merge settings from file |
| `copyPackFile` | `source`, `destination`, `fileType` | Copy file from pack |

`fileType` values: `skill`, `hook`, `command`, `generic`

---

## Templates

Templates contribute sections to `CLAUDE.local.md` during `mcs sync`.

```yaml
templates:
  - sectionIdentifier: my-pack.instructions
    contentFile: templates/instructions.md
    placeholders:
      - __PROJECT__
      - __BRANCH_PREFIX__
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sectionIdentifier` | `String` | Yes | Short section ID (no dots). Auto-prefixed with `<pack>.` |
| `contentFile` | `String` | Yes | Path to markdown file in the pack repo |
| `placeholders` | `[String]` | No | `__PLACEHOLDER__` tokens used in the template |

### Built-in Placeholder

`__REPO_NAME__` is always available — it resolves to the git repository name of the project being configured.

### Section Markers

Templates are wrapped in HTML comment markers in `CLAUDE.local.md`:

```markdown
<!-- mcs:begin my-pack.instructions v1.0.0 -->
(template content here)
<!-- mcs:end my-pack.instructions -->
```

Content outside markers is preserved. Re-running `mcs sync` updates only the managed sections.

---

## Prompts

Prompts gather values from the user during `mcs sync`.

```yaml
prompts:
  - key: PROJECT
    type: fileDetect
    label: "Xcode project"
    detectPattern:
      - "*.xcodeproj"
      - "*.xcworkspace"
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `key` | `String` | Yes | Unique key. Becomes `__KEY__` placeholder and `MCS_RESOLVED_KEY` env var |
| `type` | `String` | Yes | One of: `fileDetect`, `input`, `select`, `script` |
| `label` | `String` | No | Human-readable prompt label |
| `default` | `String` | No | Default value for `input` type |
| `detectPattern` | `String` or `[String]` | `fileDetect` | Glob pattern(s) to match files |
| `options` | `[{value, label}]` | `select` | Choices for select prompts |
| `scriptCommand` | `String` | `script` | Shell command whose stdout becomes the value |

### Prompt Types

| Type | Behavior |
|------|----------|
| `fileDetect` | Scans the project directory for files matching the glob pattern(s). If one match is found, it's used automatically. If multiple, the user picks one. |
| `input` | Free-text input with optional default value. |
| `select` | Choose from a predefined list of options. |
| `script` | Runs a shell command and uses its stdout as the value. |

---

## Doctor Checks

Doctor checks verify pack health. They can be defined at two levels:

1. **Per-component** — `doctorChecks` field on a component
2. **Pack-level** — `supplementaryDoctorChecks` at the top level

### Check Definition

```yaml
- type: shellScript
  name: Xcode CLI Tools
  section: Prerequisites
  command: "xcode-select -p >/dev/null 2>&1"
  fixCommand: "xcode-select --install"
  isOptional: false
```

### Common Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | `String` | Yes | Check type (see table below) |
| `name` | `String` | Yes | Display name in doctor output |
| `section` | `String` | No | Grouping label in output |
| `fixCommand` | `String` | No | Shell command for `mcs doctor --fix` |
| `fixScript` | `String` | No | Path to fix script (for complex fixes) |
| `scope` | `String` | No | `global` or `project` |
| `isOptional` | `Boolean` | No | If `true`, failure is a warning, not an error |

### Check Types

| Type | Required Fields | Description |
|------|----------------|-------------|
| `commandExists` | `command` | Without `args`: checks PATH presence. With `args`: runs the command and checks exit code |
| `fileExists` | `path` | Does a file exist? |
| `directoryExists` | `path` | Does a directory exist? |
| `fileContains` | `path`, `pattern` | Does a file match a regex pattern? |
| `fileNotContains` | `path`, `pattern` | Does a file NOT match a regex pattern? |
| `shellScript` | `command` | Run a command. Exit codes: `0`=pass, `1`=fail, `2`=warn, `3`=skip |
| `hookEventExists` | `event` | Is a hook event registered in settings? |
| `settingsKeyEquals` | `keyPath`, `expectedValue` | Does a settings JSON key equal a specific value? |

### Auto-Derived Checks

Most components get free doctor checks from their install action — no need to define them manually:

| Shorthand | Auto-derived check |
|-----------|-------------------|
| `brew: node` | `commandExists` for `node` |
| `mcp: {command: npx, ...}` | MCP server registered in `~/.claude.json` |
| `plugin: "name@org"` | Plugin enabled in settings |
| `hook: {source, dest}` | File exists at destination |
| `skill: {source, dest}` | Directory exists at destination |
| `command: {source, dest}` | File exists at destination |
| `settingsFile: path` | Always re-applied (convergent) |
| `gitignore: [...]` | Always re-applied (convergent) |
| `shell: "..."` | **None** — add `doctorChecks` manually |

---

## Configure Project

```yaml
configureProject:
  script: scripts/configure.sh
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `script` | `String` | Yes | Path to shell script in the pack repo |

### Environment Variables

The script receives:

| Variable | Description |
|----------|-------------|
| `MCS_PROJECT_PATH` | Absolute path to the project root |
| `MCS_RESOLVED_<KEY>` | Resolved prompt values (uppercased key) |

---

## Hook Contributions (Legacy)

```yaml
hookContributions:
  - hookName: session_start
    fragmentFile: hooks/fragment.sh
    position: after
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `hookName` | `String` | Yes | Hook name (e.g. `session_start`, `pre_tool_use`) |
| `fragmentFile` | `String` | Yes | Path to script file in the pack repo |
| `position` | `String` | No | `before` or `after` |

> **Prefer `hook:` components** over `hookContributions`. Hook components are tracked per-project and support convergence (add/remove on re-configure). Hook contributions are a legacy mechanism.

---

## Validation Rules

The engine validates manifests on load. These rules are enforced:

- `schemaVersion` must be `1`
- `identifier` must be non-empty, lowercase alphanumeric with hyphens, not starting with a hyphen
- Component IDs must be short names without dots (auto-prefixed with `<pack>.`) and unique within the pack
- Intra-pack dependency references must resolve to existing component IDs in the same pack
- Template `sectionIdentifier` must be a short name without dots (auto-prefixed with `<pack>.`)
- Prompt `key` values must be unique
- Doctor check required fields must be present and non-empty

---

## Complete Example

A minimal but realistic pack:

```yaml
schemaVersion: 1
identifier: web-dev
displayName: Web Development
description: Node.js development environment for Claude Code
version: "1.0.0"

prompts:
  - key: FRAMEWORK
    type: select
    label: "Framework"
    options:
      - value: next
        label: Next.js
      - value: remix
        label: Remix

components:
  - id: node
    description: JavaScript runtime
    brew: node

  - id: prettier-server
    description: Code formatting MCP server
    dependencies: [node]
    mcp:
      command: npx
      args: ["-y", "prettier-mcp-server@latest"]

  - id: pr-review
    description: PR review toolkit
    plugin: "pr-review-toolkit@claude-plugins-official"

  - id: session-hook
    description: Shows npm outdated on session start
    hookEvent: SessionStart
    hook:
      source: hooks/session_start.sh
      destination: session_start.sh

  - id: settings
    description: Plan mode and thinking
    isRequired: true
    settingsFile: config/settings.json

  - id: gitignore
    description: Gitignore entries
    isRequired: true
    gitignore:
      - .claude/memories
      - .claude/settings.local.json

templates:
  - sectionIdentifier: web-dev.instructions
    placeholders: [__FRAMEWORK__]
    contentFile: templates/instructions.md
```
