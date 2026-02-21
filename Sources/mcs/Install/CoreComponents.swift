import Foundation

/// Defines the core components that are not pack-specific.
enum CoreComponents {
    /// All core component definitions.
    static let all: [ComponentDefinition] = [
        // Dependencies
        homebrew, node, gh, jq, ollama, claudeCode,
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
        ),
        supplementaryChecks: [
            CommandCheck(name: "Homebrew", section: "Dependencies", command: "brew"),
        ]
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

    static let jq = ComponentDefinition(
        id: "core.jq",
        displayName: "jq",
        description: "JSON processor (used by session hooks)",
        type: .brewPackage,
        packIdentifier: nil,
        dependencies: ["core.homebrew"],
        isRequired: false,
        installAction: .brewInstall(package: "jq")
    )

    static let ollama = ComponentDefinition(
        id: "core.ollama",
        displayName: "Ollama",
        description: "Local LLM runtime with \(Constants.Ollama.embeddingModel) model",
        type: .brewPackage,
        packIdentifier: nil,
        dependencies: ["core.homebrew"],
        isRequired: false,
        installAction: .brewInstall(package: "ollama"),
        supplementaryChecks: [OllamaRuntimeCheck()]
    )

    static let claudeCode = ComponentDefinition(
        id: "core.claude-code",
        displayName: "Claude Code",
        description: "Claude Code CLI",
        type: .brewPackage,
        packIdentifier: nil,
        dependencies: ["core.homebrew"],
        isRequired: false,
        installAction: .shellCommand(command: "brew install --cask claude-code"),
        supplementaryChecks: [
            CommandCheck(name: "Claude Code", section: "Dependencies", command: Constants.CLI.claudeCommand),
        ]
    )

    // MARK: - MCP Servers

    static let docsMCPServer = ComponentDefinition(
        id: "core.docs-mcp-server",
        displayName: "docs-mcp-server",
        description: "Semantic search over memories using local Ollama embeddings",
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
                "OPENAI_API_BASE": Constants.Ollama.apiBase,
                "DOCS_MCP_EMBEDDING_MODEL": Constants.Ollama.embeddingModelID,
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
        dependencies: ["core.jq"],
        isRequired: true,
        installAction: .copyHook(
            source: "hooks/\(Constants.FileNames.sessionStartHook)",
            destination: Constants.FileNames.sessionStartHook
        )
    )

    static let hookContinuousLearning = ComponentDefinition(
        id: "core.hook.continuous-learning-activator",
        displayName: "Continuous learning activator",
        description: "Reminds to evaluate learnings on each prompt",
        type: .hookFile,
        packIdentifier: nil,
        dependencies: [],
        isRequired: false,
        installAction: .copyHook(
            source: "hooks/\(Constants.FileNames.continuousLearningHook)",
            destination: Constants.FileNames.continuousLearningHook
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
        installAction: .gitignoreEntries(entries: [Constants.FileNames.claudeDirectory, "*.local.*", "\(Constants.FileNames.claudeDirectory)/memories/"])
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

    /// Components split into selectable (optional) and required for multi-select display.
    /// Excludes components that are part of bundles.
    static var groupedForSelection: (
        selectable: [(type: ComponentType, components: [ComponentDefinition])],
        required: [ComponentDefinition]
    ) {
        let bundledIDs = Set(bundles.flatMap(\.componentIDs))
        let displayOrder: [ComponentType] = [
            .mcpServer, .plugin, .skill, .command,
        ]
        let selectable = displayOrder.compactMap { type in
            let matching = userFacing.filter {
                $0.type == type && !$0.isRequired && !bundledIDs.contains($0.id)
            }
            return matching.isEmpty ? nil : (type, matching)
        }
        let required = userFacing.filter { $0.isRequired }
        return (selectable, required)
    }

    // MARK: - Feature Bundles

    /// Bundles group related components into a single selectable item.
    static let bundles: [ComponentBundle] = [
        ComponentBundle(
            name: "Continuous Learning",
            description: "Learns from sessions and provides semantic search over memories",
            componentIDs: [
                "core.docs-mcp-server",
                "core.skill.continuous-learning",
                "core.hook.continuous-learning-activator",
            ]
        ),
    ]

    // MARK: - Hook Fragments

    /// Ollama status check + docs-mcp-server memory sync.
    /// Injected into session_start.sh when Continuous Learning is selected.
    static let continuousLearningHookFragment = """
        # === OLLAMA STATUS & DOCS-MCP LIBRARY ===
        local ollama_running=false
        if curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
            ollama_running=true
            context+="\\n🦙 Ollama: running"
        fi

        # If project has a memories directory, ensure docs-mcp-server library is synced
        if [ -d ".claude/memories" ]; then
            if [ "$ollama_running" = true ]; then
                local repo_name
                repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "")
                if [ -n "$repo_name" ]; then
                    local memories_path
                    memories_path="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/memories"

                    # Background: ensure library exists and is up to date.
                    # Redirect subshell stdout/stderr to /dev/null so the hook's
                    # output pipe closes immediately (Claude Code waits for the
                    # pipe to close, not just the parent process).
                    # A watchdog kills the subshell after 120s to prevent hangs.
                    (
                        trap 'kill 0 2>/dev/null' TERM
                        export OPENAI_API_KEY=ollama
                        export OPENAI_API_BASE=http://localhost:11434/v1

                        embedding_model="openai:nomic-embed-text"

                        if npx -y @arabold/docs-mcp-server list --silent 2>/dev/null | grep -q "$repo_name"; then
                            npx -y @arabold/docs-mcp-server refresh "$repo_name" \\
                                --embedding-model "$embedding_model" \\
                                --silent >/dev/null 2>&1
                        else
                            npx -y @arabold/docs-mcp-server scrape "$repo_name" \\
                                "file://$memories_path" \\
                                --embedding-model "$embedding_model" \\
                                --silent >/dev/null 2>&1
                        fi
                    ) >/dev/null 2>&1 &
                    local sync_pid=$!
                    ( sleep 120 && kill "$sync_pid" 2>/dev/null ) >/dev/null 2>&1 &
                fi
            else
                context+="\\n⚠️ Ollama not running — docs-mcp semantic search will fail"
            fi
        fi
    """
}

/// A group of related components exposed as a single selectable item.
struct ComponentBundle: Sendable {
    let name: String
    let description: String
    let componentIDs: [String]
}
