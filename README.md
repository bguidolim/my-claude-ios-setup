<div align="center">

# ⚡ My Claude Setup (`mcs`)

**Your Claude Code environment — packaged, portable, and reproducible.**

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138.svg?logo=swift&logoColor=white)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-13+-000000.svg?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Homebrew](https://img.shields.io/badge/Homebrew-tap-FBB040.svg?logo=homebrew&logoColor=white)](https://github.com/bguidolim/homebrew-tap)
[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-❤️-ea4aaa.svg?logo=github)](https://github.com/sponsors/bguidolim)

<br/>

```bash
brew install bguidolim/tap/my-claude-setup
mcs pack add https://github.com/you/your-pack
mcs sync
```

</div>

> [!WARNING]
> **This project is under active development.** Expect breaking changes, bugs, and incomplete features. Migrations between versions are not guaranteed. Use at your own risk.

---

## The Problem

You've spent hours getting Claude Code just right — MCP servers, plugins, hooks, skills, custom commands, fine-tuned settings. Then:

- 🖥️ **New machine?** Start over from scratch.
- 👥 **Onboarding a teammate?** "Just follow this 47-step wiki page."
- 📂 **Different projects?** Copy-paste configs, hope nothing drifts.
- 🔄 **Something broke?** Good luck figuring out what changed.

## The Solution

`mcs` is a **configuration engine for Claude Code**. It lets you package everything — MCP servers, plugins, hooks, skills, commands, settings, and templates — into shareable **tech packs** (Git repos with a `techpack.yaml` manifest). Then sync them across any project, any machine, in seconds.

> Think of it as **Ansible for your Claude Code environment**: declare what you want in a pack, point `mcs` at it, and the engine converges your setup to the desired state — idempotent, composable, and safe to re-run.

| Without `mcs` | With `mcs` |
|---|---|
| Install MCP servers one by one | `mcs pack add` + `mcs sync` |
| Hand-edit `settings.json` per project | Managed settings composition |
| Copy hooks between projects manually | Auto-installed per-project from packs |
| Configuration drifts silently | `mcs doctor --fix` detects and repairs |
| Rebuild from memory on new machines | Fully reproducible in minutes |
| No way to share your setup | Push a pack, anyone can `mcs pack add` it |

---

## ✨ Key Features

| | Feature | Description |
|---|---------|-------------|
| 📦 | **Tech Packs** | Package your entire Claude setup as a Git repo anyone can install |
| 🔄 | **Convergent Sync** | Re-run safely — adds what's missing, removes what's deselected, updates what changed |
| 🩺 | **Self-Healing** | `mcs doctor --fix` detects configuration drift and repairs it automatically |
| 🎯 | **Per-Project** | Each project gets its own hooks, skills, commands, and settings |
| 🌍 | **Portable** | Recreate your entire environment on a new machine in minutes |
| 🔒 | **Safe** | Backups, dry-run previews, section markers, trust verification, lockfiles |
| 🧩 | **Composable** | Mix and match multiple packs — `mcs` merges them cleanly |
| 🚀 | **Zero Bundled Content** | Pure engine — all features come from the packs you choose |

---

## 🚀 Quick Start

### 1. Install

```bash
brew install bguidolim/tap/my-claude-setup
```

### 2. Add a tech pack

```bash
mcs pack add https://github.com/bguidolim/mcs-personal-setup
```

### 3. Sync a project

```bash
cd ~/Developer/my-project
mcs sync
```

### 4. Verify everything

```bash
mcs doctor
```

That's it. Your MCP servers, plugins, hooks, skills, commands, settings, and templates are all in place.

<details>
<summary><strong>📋 Prerequisites</strong></summary>

- macOS 13+ (Apple Silicon or Intel)
- Xcode Command Line Tools
  ```bash
  xcode-select --install
  ```
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview) (`claude`)
- [Homebrew](https://brew.sh)

</details>

---

## 🎯 Use Cases

### 🧑‍💻 Solo Developer — Portable Setup

Got a new Mac? One `mcs pack add` + `mcs sync` and your entire Claude Code environment is back — every MCP server, every hook, every setting. No wiki, no notes, no memory required.

### 👥 Teams — Consistent Environments

Create a team pack with your org's MCP servers, approved plugins, commit hooks, and coding standards. Every developer gets the same setup:

```bash
# New team member onboarding
brew install bguidolim/tap/my-claude-setup
mcs pack add https://github.com/your-org/team-claude-pack
mcs sync --all
# Done. Everything configured.
```

### 🌐 Open Source — Instant Contributor Setup

Ship a tech pack with your repo. Contributors run `mcs sync` and get the right MCP servers, project-specific skills, and coding conventions automatically. No setup documentation to maintain.

### 🧪 Experimentation — Try, Swap, Roll Back

Want to try a different set of MCP servers? Add a new pack, sync. Don't like it? Remove and re-sync. `mcs` converges cleanly — deselected packs are fully removed, no leftovers.

---

## 🔍 Real-World Example

A single tech pack can configure your entire Claude Code environment — brew dependencies, MCP servers, plugins, hooks, skills, slash commands, settings, and templates. For a working example, see [**mcs-personal-setup**](https://github.com/bguidolim/mcs-personal-setup): an iOS development pack with 24 components that sets up everything from XcodeBuildMCP to git conventions in one `mcs sync`.

> 💡 Fork it as a starting point for your own pack, or use it as a reference when building from scratch.

---

## ⚙️ How It Works

```
 Tech Packs          mcs sync          Your Project
 (Git repos)  -----> (engine)  -----> (configured)
                        |
                   .---------.
                   |         |
                   v         v
              Per-Project  Global
              artifacts    artifacts
```

When you run `mcs sync` in a project directory:

1. **Select** which packs to apply (interactive multi-select or `--all`)
2. **Resolve** prompts (auto-detect project files, ask for config values)
3. **Install** artifacts to the right locations:

| Artifact | Location | Scope |
|----------|----------|-------|
| MCP servers | `~/.claude.json` | Per-project (keyed by path) |
| Skills | `<project>/.claude/skills/` | Per-project |
| Hooks | `<project>/.claude/hooks/` | Per-project |
| Commands | `<project>/.claude/commands/` | Per-project |
| Settings | `<project>/.claude/settings.local.json` | Per-project |
| Templates | `<project>/CLAUDE.local.md` | Per-project |

4. **Track** everything in `<project>/.claude/.mcs-project` for convergence

Re-running `mcs sync` converges to the desired state — new packs added, deselected packs fully cleaned up, unchanged packs updated idempotently. It's safe to run as many times as you want.

Use `mcs sync --global` for global-scope components (Homebrew packages, plugins, global MCP servers).

---

## 📦 What's in a Tech Pack?

A tech pack is a Git repository with a `techpack.yaml` manifest. It can include any combination of:

| Type | Description | Example |
|------|-------------|---------|
| 🍺 `brew` | CLI dependencies | `brew: node` |
| 🔌 `mcp` | MCP servers (stdio or HTTP) | `mcp: { command: npx, args: [...] }` |
| 🧩 `plugin` | Claude Code plugins | `plugin: "my-plugin@publisher"` |
| ⚡ `hook` | Session lifecycle scripts | `hook: { source: hooks/start.sh }` |
| 🎓 `skill` | Domain knowledge & workflows | `skill: { source: skills/my-skill }` |
| 💬 `command` | Custom `/slash` commands | `command: { source: commands/deploy.md }` |
| ⚙️ `settingsFile` | Settings for `settings.local.json` | `settingsFile: config/settings.json` |
| 📝 `templates` | CLAUDE.local.md instructions | Placeholder substitution with `__VAR__` |
| 🔍 `doctorChecks` | Health verification & auto-repair | Command existence, settings validation |

### Creating Your Own Pack

```bash
mkdir my-pack && cd my-pack && git init

# Create your techpack.yaml (see docs for full schema)
cat > techpack.yaml << 'EOF'
schemaVersion: 1
identifier: my-pack
displayName: My Pack
version: "1.0.0"

components:
  - id: my-server
    description: My MCP server
    mcp:
      command: npx
      args: ["-y", "my-server@latest"]
EOF

git add -A && git commit -m "Initial pack"
# Push to GitHub, then:
# mcs pack add https://github.com/you/my-pack
```

📖 **Full guide:** [Creating Tech Packs](docs/creating-tech-packs.md) · **Schema reference:** [techpack-schema.md](docs/techpack-schema.md)

---

## 🛡️ Safety & Trust

| Guarantee | What it means |
|-----------|---------------|
| 💾 **Backups** | Timestamped backup before modifying files with user content |
| 👀 **Dry Run** | `mcs sync --dry-run` previews all changes without applying |
| 🎛️ **Selective Install** | Choose components with `--customize` or apply all with `--all` |
| 🔁 **Idempotent** | Safe to re-run any number of times |
| 📌 **Non-Destructive** | Your content in `CLAUDE.local.md` is preserved via section markers |
| 🔄 **Convergent** | Deselected packs are fully cleaned up — no orphaned artifacts |
| 🔐 **Trust Verification** | Pack scripts SHA-256 hashed at add-time, verified at load-time |
| 📎 **Lockfile** | `mcs.lock.yaml` pins pack versions for reproducible environments |

---

## 📖 Commands Reference

### Sync (primary command)

```bash
mcs sync [path]                  # Interactive project sync (default command)
mcs sync --pack <name>           # Non-interactive: apply specific pack(s) (repeatable)
mcs sync --all                   # Apply all registered packs without prompts
mcs sync --dry-run               # Preview what would change
mcs sync --customize             # Per-pack component selection
mcs sync --global                # Install to global scope (~/.claude/)
mcs sync --lock                  # Checkout locked versions from mcs.lock.yaml
mcs sync --update                # Fetch latest and update mcs.lock.yaml
```

### Pack Management

```bash
mcs pack add <url>               # Add a tech pack from a Git URL
mcs pack add <url> --ref <tag>   # Pin to a specific tag, branch, or commit
mcs pack add <url> --preview     # Preview pack contents without installing
mcs pack remove <name>           # Remove a registered pack
mcs pack remove <name> --force   # Remove without confirmation
mcs pack list                    # List registered packs
mcs pack update [name]           # Update pack(s) to latest version
```

### Health Checks

```bash
mcs doctor                       # Diagnose installation health
mcs doctor --fix                 # Diagnose and auto-fix issues
mcs doctor --pack <name>         # Check a specific pack only
```

### Maintenance

```bash
mcs cleanup                      # Find and delete backup files
mcs cleanup --force              # Delete backups without confirmation
```

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| 📖 [Creating Tech Packs](docs/creating-tech-packs.md) | Step-by-step guide to building your first pack |
| 📋 [Tech Pack Schema](docs/techpack-schema.md) | Complete `techpack.yaml` field reference |
| 🏗️ [Architecture](docs/architecture.md) | Internal design, sync flow, and extension points |
| 🔧 [Troubleshooting](docs/troubleshooting.md) | Common issues and fixes |

---

## 🛠️ Development

```bash
swift build                                            # Build
swift test                                             # Run tests
swift build -c release --arch arm64 --arch x86_64      # Universal binary
```

See [Architecture](docs/architecture.md) for project structure and design decisions.

## 🤝 Contributing

Tech pack ideas and engine improvements are welcome!

1. Fork the repo
2. Create a feature branch
3. Run `swift test`
4. Open a PR

For building new packs, start with [Creating Tech Packs](docs/creating-tech-packs.md).

---

<div align="center">

## 💛 Support

If `mcs` saves you time, consider [sponsoring the project](https://github.com/sponsors/bguidolim).

**MIT License** · Made with ❤️ by [Bruno Guidolim](https://github.com/bguidolim)

</div>
