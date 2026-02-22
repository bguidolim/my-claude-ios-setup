# mcs -- My Claude Setup

> One command to turn Claude Code into a fully equipped development environment.

```bash
brew install bguidolim/tap/my-claude-setup && mcs install --all
```

| | Feature | What it does |
|---|---------|-------------|
| 🧠 | **Persistent Memory** | Learnings and decisions saved across sessions, searchable via semantic search |
| 🔍 | **Automated PR Reviews** | Specialized agents for code quality, silent failures, and test coverage |
| ⚡ | **Context-Aware Sessions** | Every session starts with git state, branch info, open PRs, and system health |
| 🛠️ | **Per-Project Config** | Auto-generated `CLAUDE.local.md` tuned to your stack |
| 🩺 | **Self-Healing Setup** | `mcs doctor --fix` detects and repairs configuration drift |
| 📦 | **Tech Packs** | Platform-specific tooling on demand (iOS pack ships today) |

> **Safe by design** -- preview with `--dry-run`, pick only the components you want, automatic backups before every file change. Fully idempotent.

## Quick Start

```bash
brew install bguidolim/tap/my-claude-setup   # 1. Install
mcs install --all                            # 2. Configure Claude Code
cd your-project && mcs configure             # 3. Set up your project
mcs doctor                                   # 4. Verify everything
```

<details>
<summary><strong>Prerequisites</strong></summary>

- macOS (Apple Silicon or Intel)
- Xcode Command Line Tools: `xcode-select --install`
- [Homebrew](https://brew.sh)

</details>

## How It Works

`mcs` automates what you'd otherwise do manually: installing MCP servers, plugins, hooks, skills, and settings for Claude Code. It tracks everything it installs, detects drift, and fixes issues.

```
mcs install          →  installs components, resolves dependencies, records state
mcs configure        →  generates per-project CLAUDE.local.md + pack configs
mcs doctor [--fix]   →  7-layer diagnostic across your entire setup
mcs cleanup          →  finds and removes old backup files
```

## Components

### Core

| | Component | What it does |
|---|-----------|-------------|
| 🔌 | **docs-mcp-server** | Semantic search over project memories via local Ollama embeddings |
| 🔌 | **Serena** | Semantic code navigation, symbol editing, and project context via LSP |
| 🧩 | **pr-review-toolkit** | PR review agents for code quality, silent failures, test coverage |
| 🧩 | **ralph-loop** | Iterative refinement loop for complex multi-step tasks |
| 🧩 | **explanatory-output-style** | Enhanced output with educational insights |
| 🧩 | **claude-md-management** | Audit and improve CLAUDE.md files |
| 📋 | **continuous-learning** | Extracts learnings and decisions into memory files |
| 📋 | **/pr** and **/commit** | Stage, commit, push (and optionally open a PR) in one step |
| ⚙️ | **session_start hook** | Git status, branch protection, open PRs, Ollama health on every session |
| ⚙️ | **settings.json** | Plan mode, always-thinking, env vars, hooks, plugins |

### iOS Tech Pack

Installed with `mcs install --pack ios` or included in `--all`.

| | Component | What it does |
|---|-----------|-------------|
| 🔌 | **XcodeBuildMCP** | Build, test, and run iOS/macOS apps via Xcode |
| 🔌 | **Sosumi** | Search Apple Developer documentation |
| 📋 | **xcodebuildmcp skill** | Workflow guidance for 190+ iOS dev tools |
| ⚙️ | **CLAUDE.local.md section** | iOS-specific instructions for simulator and build workflows |
| ⚙️ | **xcodebuildmcp.yaml** | Per-project XcodeBuildMCP configuration |

<details>
<summary><strong>Auto-resolved dependencies</strong></summary>

Based on your selections, `mcs` automatically installs these if not already present:

- **Node.js** -- npx-based MCP servers and skills
- **GitHub CLI (gh)** -- /pr command
- **jq** -- JSON processing in session hooks
- **Ollama** + nomic-embed-text -- local embeddings for docs-mcp-server
- **uv** -- Python package runner for Serena
- **Claude Code** -- the CLI itself

</details>

## Memory System

Claude Code discovers and retains knowledge automatically across sessions:

```
Session work → continuous-learning skill → .claude/memories/*.md
                                                    ↓
            session_start hook → docs-mcp-server scrape → Ollama embeddings
                                                    ↓
                        docs-mcp-server → search_docs → semantic results
```

Memories are plain markdown files (`learning_*.md`, `decision_*.md`), gitignored and local to your machine. If Serena is installed, memories are shared via symlink.

## Safety

| Guarantee | Detail |
|-----------|--------|
| 🔒 Backups | Timestamped backup before every file write |
| 👁️ Dry run | `--dry-run` previews changes without touching the filesystem |
| 🎯 Selective | Pick only the components you want, or `--all` for everything |
| 🔄 Idempotent | Re-run anytime -- installed components are detected and skipped |
| 🧩 Non-destructive | Existing settings preserved; only new keys added |
| 📐 Section markers | Managed content separated from yours in `CLAUDE.local.md` |
| 🔎 Manifest tracking | SHA-256 hashes detect configuration drift |

## Tech Packs

Platform-specific tools organized as installable packs, compiled into the single `mcs` binary.

| Pack | What's included |
|------|----------------|
| **Core** | Memory, PR workflows, session hooks, plugins, Serena |
| **iOS** | XcodeBuildMCP, Sosumi, simulator management, Xcode integration |

Want to create a pack? See [docs/creating-tech-packs.md](docs/creating-tech-packs.md).

## Troubleshooting

Run `mcs doctor` first -- most problems show up there. Add `--fix` for auto-repair.

<details>
<summary><strong>Common fixes</strong></summary>

**Ollama not running**
```bash
ollama serve                       # Start in foreground
brew services start ollama         # Or start as background service
ollama pull nomic-embed-text       # Ensure embedding model is installed
```

**MCP servers not appearing in Claude Code**
```bash
claude mcp list                    # List registered servers
mcs doctor --fix                   # Auto-fix what can be fixed
mcs install                        # Re-run install for additive repairs
```

**CLAUDE.local.md out of date**
```bash
mcs configure                      # Regenerate with current templates
```

</details>

See [docs/troubleshooting.md](docs/troubleshooting.md) for the complete guide.

## Development

```bash
swift build                                              # Build debug
swift test                                               # Run tests
swift build -c release --arch arm64 --arch x86_64        # Universal release binary
```

See [docs/architecture.md](docs/architecture.md) for project structure and design decisions.

## Contributing

Contributions welcome, especially new tech packs. See [docs/creating-tech-packs.md](docs/creating-tech-packs.md).

1. Fork the repository
2. Create a feature branch
3. Run `swift test` to verify
4. Open a pull request

## License

MIT
