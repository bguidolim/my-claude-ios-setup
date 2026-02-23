# Troubleshooting

This guide covers common issues and how to resolve them. Start by running `mcs doctor` to get a diagnostic report -- most problems will show up there.

```bash
mcs doctor           # Diagnose
mcs doctor --fix     # Diagnose and auto-fix what's possible
```

## Dependencies

### Homebrew not installed

**Symptom**: `mcs install` fails at the welcome phase with "Homebrew is required but not installed."

**Fix**: Install Homebrew first:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then re-run `mcs install`.

### Xcode Command Line Tools missing

**Symptom**: `mcs install` fails with "Xcode Command Line Tools not found."

**Fix**:
```bash
xcode-select --install
```

Follow the system dialog to complete installation, then re-run `mcs install`.

### Node.js not found

**Symptom**: MCP servers that use `npx` fail to start or install.

**Fix**: Node.js is auto-resolved as a dependency. Re-run:
```bash
mcs install
```

If you manage Node.js through nvm or similar, make sure it's available in your PATH during installation.

### Ollama not running

**Symptom**: `mcs doctor` shows "Ollama: not running" or semantic search fails.

**Fix**: Start Ollama:
```bash
ollama serve                      # Foreground (for debugging)
brew services start ollama        # Background service
```

If the embedding model is missing:
```bash
ollama pull nomic-embed-text
```

Verify it's working:
```bash
curl http://localhost:11434/api/tags
```

### Claude Code CLI not found

**Symptom**: MCP servers and plugins can't be registered.

**Fix**: Install Claude Code:
```bash
brew install --cask claude-code
```

Verify:
```bash
claude --version
```

## MCP Servers

### MCP server not registered

**Symptom**: `mcs doctor` shows a server as "not registered" or `claude mcp list` doesn't show it.

**Fix**: Re-run the installer:
```bash
mcs install
```

The installer checks for existing registrations and only adds what's missing.

### docs-mcp-server semantic search not working

**Symptom**: `search_docs` returns no results or errors.

**Causes**:
1. Ollama is not running
2. The `nomic-embed-text` model is not pulled
3. The project library has not been indexed

**Fix**:
```bash
# 1. Start Ollama
ollama serve

# 2. Pull the embedding model
ollama pull nomic-embed-text

# 3. Verify the library exists
OPENAI_API_KEY=ollama OPENAI_API_BASE=http://localhost:11434/v1 \
  npx -y @arabold/docs-mcp-server list

# 4. If missing, manually scrape
OPENAI_API_KEY=ollama OPENAI_API_BASE=http://localhost:11434/v1 \
  npx -y @arabold/docs-mcp-server scrape "your-repo-name" \
  "file://$(pwd)/.claude/memories" \
  --embedding-model "openai:nomic-embed-text"
```

The session_start hook normally handles indexing automatically when Ollama is running.

### Sosumi not responding

**Symptom**: Apple documentation search via Sosumi returns errors.

Sosumi uses HTTP transport (external service at `https://sosumi.ai/mcp`). Check your internet connection and verify the server is registered:
```bash
claude mcp list
```

If not registered, re-run `mcs install --pack ios`.

## Plugins

### Plugin not enabled

**Symptom**: `mcs doctor` shows a plugin as "not enabled."

**Fix**: Re-run installation:
```bash
mcs install
```

You can also manually install a plugin:
```bash
claude plugin install <plugin-name>@claude-plugins-official
```

## Hooks

### Hook not executable

**Symptom**: `mcs doctor` shows "not executable" for a hook file.

**Fix**: `mcs doctor --fix` can repair this automatically. Or manually:
```bash
chmod +x ~/.claude/hooks/session_start.sh
chmod +x ~/.claude/hooks/continuous-learning-activator.sh
```

### Legacy hook missing extension marker

**Symptom**: `mcs doctor` shows "legacy hook -- missing extension marker, needs update."

This means the hook file was installed by an older version that didn't support fragment injection.

**Fix**: Re-run installation to replace the hook:
```bash
mcs install
```

### Hook fragment version mismatch

**Symptom**: `mcs doctor` shows something like "v1.0.0 installed, v2.0.0 available."

**Fix**: Re-run installation to update:
```bash
mcs install
```

## Settings

### defaultMode not set to 'plan'

**Symptom**: `mcs doctor` warns about settings configuration.

**Fix**: Re-run installation to merge settings:
```bash
mcs install
```

Settings are deep-merged: existing user settings are preserved, and template values are added.

### Stale settings keys

**Symptom**: `mcs doctor` warns about stale settings keys.

This means a previous version of mcs added settings keys that the current version no longer manages.

**Fix**: Re-run installation:
```bash
mcs install
```

The installer detects and removes stale keys automatically.

## Project Configuration

### CLAUDE.local.md not found

**Symptom**: `mcs doctor` skips project checks or shows "CLAUDE.local.md not found."

**Fix**: Configure the project:
```bash
cd /path/to/your/project
mcs configure
```

### CLAUDE.local.md sections outdated

**Symptom**: `mcs doctor` shows "outdated sections" with version mismatches.

**Fix**: Re-run configure to update sections:
```bash
cd /path/to/your/project
mcs configure
```

Managed sections (inside `<!-- mcs:begin/end -->` markers) are updated. Content you added outside markers is preserved.

### .mcs-project file missing

**Symptom**: `mcs doctor` warns "CLAUDE.local.md exists but .mcs-project missing."

**Fix**: `mcs doctor --fix` can create the state file by inferring packs from CLAUDE.local.md section markers. Or re-run configure:
```bash
mcs configure
```

### XcodeBuildMCP config.yaml missing (iOS)

**Symptom**: `mcs doctor` shows ".xcodebuildmcp/config.yaml: Missing."

**Fix**:
```bash
cd /path/to/your/ios/project
mcs configure --pack ios
```

### XcodeBuildMCP config.yaml has placeholder

**Symptom**: `mcs doctor` warns "Present but __PROJECT__ placeholder not filled in."

This means `mcs configure` could not auto-detect an `.xcworkspace` or `.xcodeproj` file in the project directory.

**Fix**: Manually edit `.xcodebuildmcp/config.yaml` and replace `__PROJECT__` with your actual Xcode project or workspace file name.

## Serena Memory Migration

### .serena/memories exists as directory

**Symptom**: `mcs doctor` shows ".serena/memories/ has N file(s) -- migrate to .claude/memories/."

If you previously used Serena with a separate memories directory, it should be migrated to `.claude/memories/` and replaced with a symlink.

**Fix**: `mcs doctor --fix` handles this automatically:
```bash
cd /path/to/your/project
mcs doctor --fix
```

This copies files from `.serena/memories/` to `.claude/memories/`, removes the original directory, and creates a symlink.

## Migration from Legacy Versions

### Deprecated MCP servers or plugins

**Symptom**: `mcs doctor` warns about deprecated components like `mcp-omnisearch` or `claude-hud`.

**Fix**: `mcs doctor --fix` removes deprecated components automatically:
```bash
mcs doctor --fix
```

### Migrating from the bash installer

If you previously used the bash-based installer (`claude-ios-setup`):

```bash
# 1. Install the new version
brew install bguidolim/tap/my-claude-setup

# 2. Run full install (handles manifest migration)
mcs install --all

# 3. Configure each project
cd /path/to/project && mcs configure

# 4. Verify
mcs doctor

# 5. Clean up old installation
rm -rf ~/.claude-ios-setup ~/.claude/bin/claude-ios-setup
```

## Global Gitignore

### Missing gitignore entries

**Symptom**: `mcs doctor` shows "missing entries" in the gitignore check.

**Fix**: `mcs doctor --fix` adds missing entries automatically:
```bash
mcs doctor --fix
```

## Backup Files

### Too many backup files

Over time, `mcs install` and `mcs configure` create timestamped backups of files they modify.

**Fix**: Clean them up:
```bash
mcs cleanup          # Lists backups and asks before deleting
mcs cleanup --force  # Deletes without confirmation
```

## Getting More Help

If `mcs doctor` doesn't identify the problem:

1. Check that your PATH includes the necessary binaries (`brew`, `node`, `claude`, `ollama`)
2. Verify `~/.claude.json` is valid JSON: `python3 -m json.tool ~/.claude.json`
3. Verify `~/.claude/settings.json` is valid JSON: `python3 -m json.tool ~/.claude/settings.json`
4. Open an issue at the project repository with the output of `mcs doctor`
