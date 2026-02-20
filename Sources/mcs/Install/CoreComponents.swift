import Foundation

/// Defines the core components that are not pack-specific.
enum CoreComponents {
    /// All core component definitions.
    static let all: [ComponentDefinition] = [
        // Dependencies
        homebrew, node, gh, ollama, claudeCode,
        // MCP Servers
        docsMCPServer,
        // Plugins
        pluginExplanatoryOutput, pluginPRReview, pluginRalphLoop, pluginClaudeMD,
        // Skills
        skillContinuousLearning,
        // Hooks
        hookSessionStart, hookContinuousLearning,
        // Commands
        commandPR,
        // Configuration
        settingsMerge, gitignoreCore,
    ]

    // MARK: - Dependencies

    static let homebrew = ComponentDefinition(
        id: "core.homebrew",
        displayName: "Homebrew",
        description: "macOS package manager",
        type: .brewPackage,
        packIdentifier: nil,
        dependencies: [],
        isRequired: false,
        installAction: .shellCommand(
            command: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        )
    )

    static let node = ComponentDefinition(
        id: "core.node",
        displayName: "Node.js",
        description: "JavaScript runtime (for npx-based MCP servers)",
        type: .brewPackage,
        packIdentifier: nil,
        dependencies: ["core.homebrew"],
        isRequired: false,
        installAction: .brewInstall(package: "node")
    )

    static let gh = ComponentDefinition(
        id: "core.gh",
        displayName: "GitHub CLI",
        description: "GitHub CLI for PR operations",
        type: .brewPackage,
        packIdentifier: nil,
        dependencies: ["core.homebrew"],
        isRequired: false,
        installAction: .brewInstall(package: "gh")
    )

    static let ollama = ComponentDefinition(
        id: "core.ollama",
        displayName: "Ollama",
        description: "Local LLM runtime with nomic-embed-text model",
        type: .brewPackage,
        packIdentifier: nil,
        dependencies: ["core.homebrew"],
        isRequired: false,
        installAction: .brewInstall(package: "ollama")
    )

    static let claudeCode = ComponentDefinition(
        id: "core.claude-code",
        displayName: "Claude Code",
        description: "Claude Code CLI",
        type: .brewPackage,
        packIdentifier: nil,
        dependencies: ["core.homebrew"],
        isRequired: false,
        installAction: .shellCommand(command: "brew install --cask claude-code")
    )

    // MARK: - MCP Servers

    static let docsMCPServer = ComponentDefinition(
        id: "core.docs-mcp-server",
        displayName: "docs-mcp-server",
        description: "Semantic search over documentation using local Ollama embeddings",
        type: .mcpServer,
        packIdentifier: nil,
        dependencies: ["core.node", "core.ollama"],
        isRequired: false,
        installAction: .mcpServer(MCPServerConfig(
            name: "docs-mcp-server",
            command: "npx",
            args: ["-y", "@arabold/docs-mcp-server@latest", "--read-only", "--telemetry=false"],
            env: [
                "OPENAI_API_KEY": "ollama",
                "OPENAI_API_BASE": "http://localhost:11434/v1",
                "DOCS_MCP_EMBEDDING_MODEL": "openai:nomic-embed-text",
            ]
        ))
    )

    // MARK: - Plugins

    static let pluginExplanatoryOutput = ComponentDefinition(
        id: "core.plugin.explanatory-output-style",
        displayName: "explanatory-output-style",
        description: "Enhanced output with educational insights and structured formatting",
        type: .plugin,
        packIdentifier: nil,
        dependencies: [],
        isRequired: false,
        installAction: .plugin(name: "explanatory-output-style@claude-plugins-official")
    )

    static let pluginPRReview = ComponentDefinition(
        id: "core.plugin.pr-review-toolkit",
        displayName: "pr-review-toolkit",
        description: "Specialized PR review agents",
        type: .plugin,
        packIdentifier: nil,
        dependencies: [],
        isRequired: false,
        installAction: .plugin(name: "pr-review-toolkit@claude-plugins-official")
    )

    static let pluginRalphLoop = ComponentDefinition(
        id: "core.plugin.ralph-loop",
        displayName: "ralph-loop",
        description: "Iterative refinement loop for complex multi-step tasks",
        type: .plugin,
        packIdentifier: nil,
        dependencies: [],
        isRequired: false,
        installAction: .plugin(name: "ralph-loop@claude-plugins-official")
    )

    static let pluginClaudeMD = ComponentDefinition(
        id: "core.plugin.claude-md-management",
        displayName: "claude-md-management",
        description: "Audit and improve CLAUDE.md files across repositories",
        type: .plugin,
        packIdentifier: nil,
        dependencies: [],
        isRequired: false,
        installAction: .plugin(name: "claude-md-management@claude-plugins-official")
    )

    // MARK: - Skills

    static let skillContinuousLearning = ComponentDefinition(
        id: "core.skill.continuous-learning",
        displayName: "continuous-learning",
        description: "Extracts learnings and decisions from sessions into memory",
        type: .skill,
        packIdentifier: nil,
        dependencies: [],
        isRequired: false,
        installAction: .copySkill(
            source: "skills/continuous-learning",
            destination: "continuous-learning"
        )
    )

    // MARK: - Hooks

    static let hookSessionStart = ComponentDefinition(
        id: "core.hook.session-start",
        displayName: "Session start hook",
        description: "Shows git status, branch protection, and open PRs on session start",
        type: .hookFile,
        packIdentifier: nil,
        dependencies: [],
        isRequired: true,
        installAction: .copyHook(
            source: "hooks/session_start.sh",
            destination: "session_start.sh"
        )
    )

    static let hookContinuousLearning = ComponentDefinition(
        id: "core.hook.continuous-learning-activator",
        displayName: "Continuous learning activator",
        description: "Reminds to evaluate learnings on each prompt",
        type: .hookFile,
        packIdentifier: nil,
        dependencies: [],
        isRequired: true,
        installAction: .copyHook(
            source: "hooks/continuous-learning-activator.sh",
            destination: "continuous-learning-activator.sh"
        )
    )

    // MARK: - Commands

    static let commandPR = ComponentDefinition(
        id: "core.command.pr",
        displayName: "/pr command",
        description: "Automates stage, commit, push, and PR creation with ticket extraction",
        type: .command,
        packIdentifier: nil,
        dependencies: ["core.gh"],
        isRequired: false,
        installAction: .copyCommand(
            source: "commands/pr.md",
            destination: "pr.md",
            placeholders: ["BRANCH_PREFIX": "feature"]
        )
    )

    // MARK: - Configuration

    static let settingsMerge = ComponentDefinition(
        id: "core.settings",
        displayName: "Settings",
        description: "Plan mode, always-thinking, env vars, hooks config, plugins",
        type: .configuration,
        packIdentifier: nil,
        dependencies: [],
        isRequired: true,
        installAction: .settingsMerge
    )

    static let gitignoreCore = ComponentDefinition(
        id: "core.gitignore",
        displayName: "Global gitignore",
        description: "Add .claude, *.local.*, .claude/memories/ to global gitignore",
        type: .configuration,
        packIdentifier: nil,
        dependencies: [],
        isRequired: true,
        installAction: .gitignoreEntries(entries: [".claude", "*.local.*", ".claude/memories/"])
    )

    // MARK: - Helpers

    /// User-facing components (excludes auto-resolved dependencies).
    static var userFacing: [ComponentDefinition] {
        all.filter { $0.type != .brewPackage }
    }

    /// Components grouped by type for display.
    static var grouped: [(type: ComponentType, components: [ComponentDefinition])] {
        let displayOrder: [ComponentType] = [
            .mcpServer, .plugin, .skill, .command, .hookFile, .configuration,
        ]
        return displayOrder.compactMap { type in
            let matching = userFacing.filter { $0.type == type }
            return matching.isEmpty ? nil : (type, matching)
        }
    }
}
