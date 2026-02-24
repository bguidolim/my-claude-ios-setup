/// Centralized string constants used across multiple files.
/// Only strings that appear in 2+ files belong here; single-use
/// constants may be included when they form a logical group with
/// multi-use siblings. Single-file constants should remain local
/// to their type.
enum Constants {

    // MARK: - File Names

    enum FileNames {
        /// The per-project instructions file managed by `mcs sync`.
        static let claudeLocalMD = "CLAUDE.local.md"

        /// The per-project state file tracking configured packs.
        static let mcsProject = ".mcs-project"

        /// The Claude Code configuration directory name.
        static let claudeDirectory = ".claude"

        /// The session start hook script.
        static let sessionStartHook = "session_start.sh"

        /// The continuous learning activator hook script.
        static let continuousLearningHook = "continuous-learning-activator.sh"

        /// The process lock file preventing concurrent mcs execution.
        static let mcsLock = ".mcs-lock"
    }

    // MARK: - CLI

    enum CLI {
        /// The `/usr/bin/env` path used to resolve commands from PATH.
        static let env = "/usr/bin/env"

        /// The Claude Code CLI binary name.
        static let claudeCommand = "claude"
    }

    // MARK: - Hooks

    enum Hooks {
        /// The marker where hook fragments are injected.
        /// Callers add their own indentation as needed.
        static let extensionMarker = "# --- mcs:hook-extensions ---"

        /// The fragment identifier for the continuous learning hook injection.
        static let continuousLearningFragmentID = "learning"

        /// Claude Code hook event name for session start.
        static let eventSessionStart = "SessionStart"

        /// Claude Code hook event name for user prompt submission.
        static let eventUserPromptSubmit = "UserPromptSubmit"
    }

    // MARK: - Serena

    enum Serena {
        /// The Serena configuration directory name.
        static let directory = ".serena"

        /// The memories subdirectory name.
        static let memoriesDirectory = "memories"

        /// The MCP server identifier in claude.json.
        static let mcpServerName = "serena"
    }

    // MARK: - JSON Keys

    enum JSONKeys {
        /// The top-level key in `~/.claude.json` for MCP server registrations.
        static let mcpServers = "mcpServers"
    }

    // MARK: - External Packs

    enum ExternalPacks {
        /// The manifest filename for external tech packs.
        static let manifestFilename = "techpack.yaml"

        /// The registry filename tracking installed packs.
        static let registryFilename = ".mcs-packs.yaml"

        /// The directory name for pack checkouts.
        static let packsDirectory = "packs"
    }

    // MARK: - Plugins

    enum Plugins {
        /// The official Anthropic plugin marketplace identifier.
        static let officialMarketplace = "claude-plugins-official"

        /// The GitHub repo path for the official plugin marketplace.
        static let officialMarketplaceRepo = "anthropics/claude-plugins-official"
    }
}
