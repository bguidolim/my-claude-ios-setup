# My Claude Setup

One command to configure [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with MCP servers, plugins, skills, and hooks — technology-agnostic core with extensible tech packs.

### What you get

- 🧠 **Persistent memory** — learnings and decisions saved across sessions, searchable via semantic search
- 🔍 **Automated PR reviews** — specialized agents for code quality, silent failures, and test coverage
- ⚡ **Context-aware sessions** — every session starts with git state, branch protection, open PRs
- 📋 **Per-project templates** — auto-generate `CLAUDE.local.md` tuned to your project
- 🩺 **Self-healing setup** — built-in diagnostics that detect and auto-fix configuration drift
- 📦 **Tech packs** — platform-specific tools loaded on demand (iOS pack included)

> **Safe to try**: preview with `--dry-run`, pick only the components you need, automatic backups before any file changes. Fully idempotent — re-run anytime.

## Quick Start

### Via Homebrew (recommended)

```bash
brew install bguidolim/tap/my-claude-setup
mcs install --all
```

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/bguidolim/my-claude-setup/main/install.sh | bash
```

### Prerequisites

- **macOS** (Apple Silicon or Intel)
- **Anthropic account** with Claude Code access
- **Xcode CLT** (for iOS pack): `xcode-select --install`

## Usage

```bash
mcs install                    # Interactive setup (pick components)
mcs install --all              # Install everything
mcs install --dry-run          # Preview what would be installed
mcs install --pack ios         # Install iOS pack components
mcs doctor                     # Diagnose installation health
mcs doctor --fix               # Diagnose and auto-fix issues
mcs configure-project [path]   # Generate CLAUDE.local.md for a project
mcs cleanup                    # Find and delete backup files
mcs update                     # Update via Homebrew
mcs --help                     # Show usage
```

## Components

### Core (always available)

| Category | Component | Description |
|----------|-----------|-------------|
| MCP Server | **docs-mcp-server** | Semantic search over documentation and memories using local Ollama embeddings |
| Plugin | **explanatory-output-style** | Enhanced output with educational insights |
| Plugin | **pr-review-toolkit** | PR review agents (code quality, silent failures, test coverage) |
| Plugin | **ralph-loop** | Iterative refinement loop for complex tasks |
| Plugin | **claude-md-management** | Audit and improve CLAUDE.md files |
| Skill | **continuous-learning** | Extracts learnings and decisions into memory files |
| Command | **/pr** | Automates stage, commit, push, and PR creation with ticket extraction |
| Hook | **session_start** | Git context, branch protection, open PRs, Ollama status, memory sync |
| Hook | **continuous-learning-activator** | Reminds to evaluate learnings after each prompt |
| Config | **settings.json** | Plan mode, always-thinking, env vars, hooks, plugins |

### iOS Tech Pack (`--pack ios`)

| Category | Component | Description |
|----------|-----------|-------------|
| MCP Server | **XcodeBuildMCP** | Build, test, and run iOS/macOS apps via Xcode integration |
| MCP Server | **Sosumi** | Search and fetch Apple Developer documentation |
| Skill | **xcodebuildmcp** | Tool catalog and workflow guidance for 190+ iOS dev tools |
| Template | **CLAUDE.local.md** | iOS-specific instructions (simulator, build & test rules) |
| Config | **xcodebuildmcp.yaml** | Per-project XcodeBuildMCP workflow configuration |

### Dependencies (auto-resolved)

Based on your selections, `mcs` automatically installs:

- **Homebrew** — if any packages need installing
- **Node.js** — for npx-based MCP servers and skills
- **gh** — GitHub CLI (when /pr command is selected)
- **Ollama** + `nomic-embed-text` — for docs-mcp-server local embeddings

## Memory Architecture

Memories are plain markdown files stored in `<project>/.claude/memories/`:

```
continuous-learning skill → Write tool → .claude/memories/*.md
                                              ↓
session_start hook → docs-mcp-server scrape → Ollama embeddings
                                              ↓
docs-mcp-server MCP → search_docs queries → semantic results
```

- **Learnings**: `learning_<topic>_<specific>.md` — non-obvious debugging, workarounds
- **Decisions**: `decision_<domain>_<topic>.md` — architecture choices, conventions

Memory files are gitignored and local to your machine.

## Per-Project Configuration

After running `mcs install`, configure each project:

```bash
cd your-project
mcs configure-project
```

This generates:
- `CLAUDE.local.md` with section markers for core + detected tech pack instructions
- `.xcodebuildmcp/config.yaml` (for iOS projects)
- Migrates memories from `.serena/memories/` if present

## Tech Pack System

Components are organized into tech packs. The core is technology-agnostic; platform-specific tools live in packs.

Currently shipped:
- **Core** — memory, PR workflows, session hooks, plugins
- **iOS** — XcodeBuildMCP, Sosumi, simulator management

Future packs (contributions welcome):
- Android, Web, Backend, etc.

Tech packs are compiled into a single binary — no separate installation needed.

## Troubleshooting

### Ollama not starting
```bash
curl http://localhost:11434/api/tags   # Check status
brew services start ollama             # Start via Homebrew
```

### MCP servers not appearing
```bash
claude mcp list                        # List configured servers
mcs doctor --fix                       # Auto-fix registration
```

### Migration from Bash version
```bash
brew install bguidolim/tap/my-claude-setup
mcs install --all
mcs configure-project                  # In each project
mcs doctor                             # Verify everything
rm -rf ~/.claude-ios-setup ~/.claude/bin/claude-ios-setup  # Cleanup old install
```

## Backups

All file writes create timestamped backups:
- `~/.claude/settings.json.backup.YYYYMMDD_HHMMSS`
- `<project>/CLAUDE.local.md.backup.YYYYMMDD_HHMMSS`

Use `mcs cleanup` to find and delete old backups.

## Development

```bash
swift build                            # Build
swift test                             # Run tests (50 tests)
swift build -c release --arch arm64 --arch x86_64  # Universal binary
```

## License

MIT
