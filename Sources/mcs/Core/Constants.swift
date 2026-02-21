/// Centralized string constants used across multiple files.
/// Only strings that appear in 2+ files belong here; single-use
/// constants may be included when they form a logical group with
/// multi-use siblings. Single-file constants should remain local
/// to their type.
enum Constants {

    // MARK: - File Names

    enum FileNames {
        /// The per-project instructions file managed by `mcs configure`.
        static let claudeLocalMD = "CLAUDE.local.md"

        /// The per-project state file tracking configured packs.
        static let mcsProject = ".mcs-project"

        /// The Claude Code configuration directory name.
        static let claudeDirectory = ".claude"

        /// The session start hook script.
        static let sessionStartHook = "session_start.sh"

        /// The continuous learning activator hook script.
        static let continuousLearningHook = "continuous-learning-activator.sh"
    }

    // MARK: - CLI

    enum CLI {
        /// The `/usr/bin/env` path used to resolve commands from PATH.
        static let env = "/usr/bin/env"

        /// The Claude Code CLI binary name.
        static let claudeCommand = "claude"
    }

    // MARK: - Ollama

    enum Ollama {
        /// The embedding model name used by docs-mcp-server.
        static let embeddingModel = "nomic-embed-text"

        /// The embedding model ID in OpenAI-compatible format.
        static var embeddingModelID: String { "openai:\(embeddingModel)" }

        /// The local Ollama API base URL (OpenAI-compatible endpoint).
        static let apiBase = "http://localhost:11434/v1"

        /// The local Ollama API tags endpoint (for health checks).
        static let apiTagsURL = "http://localhost:11434/api/tags"
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

    // MARK: - JSON Keys

    enum JSONKeys {
        /// The top-level key in `~/.claude.json` for MCP server registrations.
        static let mcpServers = "mcpServers"
    }

    // MARK: - Plugins

    enum Plugins {
        /// The official Anthropic plugin marketplace identifier.
        static let officialMarketplace = "claude-plugins-official"

        /// The GitHub repo path for the official plugin marketplace.
        static let officialMarketplaceRepo = "anthropics/claude-plugins-official"
    }
}
