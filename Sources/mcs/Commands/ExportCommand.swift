import ArgumentParser
import Foundation

/// Export current Claude Code configuration to a techpack.yaml pack directory.
///
/// This wizard reads live configuration files (settings, MCP servers, hooks,
/// skills, CLAUDE.md) and generates a reusable, shareable tech pack.
struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export current configuration as a tech pack"
    )

    @Argument(help: "Output directory for the generated pack")
    var outputDir: String

    @Flag(name: .long, help: "Export global scope (~/.claude/) instead of project scope")
    var global = false

    @Option(name: .long, help: "Pack identifier (prompted if omitted)")
    var identifier: String?

    @Flag(name: .long, help: "Include everything without prompts")
    var nonInteractive = false

    @Flag(name: .long, help: "Preview what would be exported without writing")
    var dryRun = false

    func run() throws {
        let env = Environment()
        let output = CLIOutput()

        output.header("Export Configuration")

        // 1. Determine scope
        let scope: ConfigurationDiscovery.Scope
        if global {
            scope = .global
            output.info("  Scope: global (~/.claude/)")
        } else {
            guard let projectRoot = ProjectDetector.findProjectRoot() else {
                throw ExportError.noProjectFound
            }
            scope = .project(projectRoot)
            output.info("  Scope: project (\(projectRoot.lastPathComponent))")
        }

        // 2. Discover configuration
        let discovery = ConfigurationDiscovery(environment: env, output: output)
        let config = discovery.discover(scope: scope)

        guard !config.isEmpty else {
            throw ExportError.noConfigurationFound
        }

        output.plain("")
        printDiscoverySummary(config, output: output)

        // 3. Select artifacts
        let selection: Selection
        if nonInteractive {
            selection = selectAll(from: config)
        } else {
            selection = interactiveSelect(config: config, output: output)
        }

        // 4. Gather metadata
        let metadata: ManifestBuilder.Metadata
        if nonInteractive {
            metadata = ManifestBuilder.Metadata(
                identifier: identifier ?? "exported-pack",
                displayName: identifier?.replacingOccurrences(of: "-", with: " ").capitalized ?? "Exported Pack",
                description: "Exported Claude Code configuration",
                author: gitAuthorName()
            )
        } else {
            metadata = gatherMetadata(output: output)
        }

        // 5. Build manifest
        let builder = ManifestBuilder()
        let result = builder.build(
            from: config,
            metadata: metadata,
            selectedMCPServers: selection.mcpServers,
            selectedHookFiles: selection.hookFiles,
            selectedSkillFiles: selection.skillFiles,
            selectedCommandFiles: selection.commandFiles,
            selectedPlugins: selection.plugins,
            selectedSections: selection.sections,
            includeUserContent: selection.includeUserContent,
            includeGitignore: selection.includeGitignore,
            includeSettings: selection.includeSettings
        )

        let outputURL = URL(fileURLWithPath: outputDir).standardizedFileURL

        // 6. Write or preview
        let writer = PackWriter(output: output)
        if dryRun {
            output.plain("")
            writer.preview(result: result, outputDir: outputURL)
        } else {
            output.plain("")
            output.sectionHeader("Writing pack to \(outputURL.path)")
            try writer.write(result: result, to: outputURL)

            output.plain("")
            output.success("Pack exported successfully!")
            printPostExportHints(config: config, output: output)
        }
    }

    // MARK: - Discovery Summary

    private func printDiscoverySummary(_ config: ConfigurationDiscovery.DiscoveredConfiguration, output: CLIOutput) {
        output.sectionHeader("Discovered configuration:")
        if !config.mcpServers.isEmpty {
            output.plain("  MCP servers:   \(config.mcpServers.map(\.name).joined(separator: ", "))")
        }
        if !config.hookFiles.isEmpty {
            output.plain("  Hook files:    \(config.hookFiles.map(\.filename).joined(separator: ", "))")
        }
        if !config.skillFiles.isEmpty {
            output.plain("  Skills:        \(config.skillFiles.map(\.filename).joined(separator: ", "))")
        }
        if !config.commandFiles.isEmpty {
            output.plain("  Commands:      \(config.commandFiles.map(\.filename).joined(separator: ", "))")
        }
        if !config.plugins.isEmpty {
            output.plain("  Plugins:       \(config.plugins.joined(separator: ", "))")
        }
        if !config.claudeSections.isEmpty {
            output.plain("  CLAUDE.md:     \(config.claudeSections.count) managed section(s)")
        }
        if config.claudeUserContent != nil {
            output.plain("  CLAUDE.md:     user content present")
        }
        if !config.gitignoreEntries.isEmpty {
            output.plain("  Gitignore:     \(config.gitignoreEntries.count) entries")
        }
        if config.remainingSettingsData != nil {
            output.plain("  Settings:      additional keys present")
        }
        output.plain("")
    }

    // MARK: - Selection

    struct Selection {
        var mcpServers: Set<String>
        var hookFiles: Set<String>
        var skillFiles: Set<String>
        var commandFiles: Set<String>
        var plugins: Set<String>
        var sections: Set<String>
        var includeUserContent: Bool
        var includeGitignore: Bool
        var includeSettings: Bool
    }

    private func selectAll(from config: ConfigurationDiscovery.DiscoveredConfiguration) -> Selection {
        Selection(
            mcpServers: Set(config.mcpServers.map(\.name)),
            hookFiles: Set(config.hookFiles.map(\.filename)),
            skillFiles: Set(config.skillFiles.map(\.filename)),
            commandFiles: Set(config.commandFiles.map(\.filename)),
            plugins: Set(config.plugins),
            sections: Set(config.claudeSections.map(\.sectionIdentifier)),
            includeUserContent: config.claudeUserContent != nil,
            includeGitignore: !config.gitignoreEntries.isEmpty,
            includeSettings: config.remainingSettingsData != nil
        )
    }

    private func interactiveSelect(
        config: ConfigurationDiscovery.DiscoveredConfiguration,
        output: CLIOutput
    ) -> Selection {
        var groups: [SelectableGroup] = []
        var itemCounter = 0

        // Track which items map to which artifact names
        var mcpMapping: [Int: String] = [:]
        var hookMapping: [Int: String] = [:]
        var skillMapping: [Int: String] = [:]
        var commandMapping: [Int: String] = [:]
        var pluginMapping: [Int: String] = [:]
        var sectionMapping: [Int: String] = [:]
        var userContentItem: Int?
        var gitignoreItem: Int?
        var settingsItem: Int?

        // MCP Servers
        if !config.mcpServers.isEmpty {
            var items: [SelectableItem] = []
            for server in config.mcpServers {
                itemCounter += 1
                let sensitiveWarning = server.sensitiveEnvVarNames.isEmpty
                    ? "" : " (contains sensitive env vars)"
                items.append(SelectableItem(
                    number: itemCounter,
                    name: server.name,
                    description: server.isHTTP ? "HTTP MCP server\(sensitiveWarning)" : (server.command ?? "MCP server") + sensitiveWarning,
                    isSelected: true
                ))
                mcpMapping[itemCounter] = server.name
            }
            groups.append(SelectableGroup(title: "MCP Servers", items: items, requiredItems: []))
        }

        // Hook files
        if !config.hookFiles.isEmpty {
            var items: [SelectableItem] = []
            for hook in config.hookFiles {
                itemCounter += 1
                let eventInfo = hook.hookEvent.map { " → \($0)" } ?? " (unknown event)"
                items.append(SelectableItem(
                    number: itemCounter,
                    name: hook.filename,
                    description: "Hook script\(eventInfo)",
                    isSelected: true
                ))
                hookMapping[itemCounter] = hook.filename
            }
            groups.append(SelectableGroup(title: "Hooks", items: items, requiredItems: []))
        }

        // Skills
        if !config.skillFiles.isEmpty {
            var items: [SelectableItem] = []
            for skill in config.skillFiles {
                itemCounter += 1
                items.append(SelectableItem(
                    number: itemCounter,
                    name: skill.filename,
                    description: "Skill file",
                    isSelected: true
                ))
                skillMapping[itemCounter] = skill.filename
            }
            groups.append(SelectableGroup(title: "Skills", items: items, requiredItems: []))
        }

        // Commands
        if !config.commandFiles.isEmpty {
            var items: [SelectableItem] = []
            for cmd in config.commandFiles {
                itemCounter += 1
                items.append(SelectableItem(
                    number: itemCounter,
                    name: cmd.filename,
                    description: "Slash command",
                    isSelected: true
                ))
                commandMapping[itemCounter] = cmd.filename
            }
            groups.append(SelectableGroup(title: "Commands", items: items, requiredItems: []))
        }

        // Plugins
        if !config.plugins.isEmpty {
            var items: [SelectableItem] = []
            for plugin in config.plugins {
                itemCounter += 1
                items.append(SelectableItem(
                    number: itemCounter,
                    name: plugin,
                    description: "Plugin",
                    isSelected: true
                ))
                pluginMapping[itemCounter] = plugin
            }
            groups.append(SelectableGroup(title: "Plugins", items: items, requiredItems: []))
        }

        // CLAUDE.md sections + extras
        var claudeItems: [SelectableItem] = []
        for section in config.claudeSections {
            itemCounter += 1
            claudeItems.append(SelectableItem(
                number: itemCounter,
                name: section.sectionIdentifier,
                description: "Managed section",
                isSelected: true
            ))
            sectionMapping[itemCounter] = section.sectionIdentifier
        }
        if config.claudeUserContent != nil {
            itemCounter += 1
            claudeItems.append(SelectableItem(
                number: itemCounter,
                name: "User content",
                description: "Content outside managed sections",
                isSelected: true
            ))
            userContentItem = itemCounter
        }
        if !claudeItems.isEmpty {
            groups.append(SelectableGroup(title: "CLAUDE.md Content", items: claudeItems, requiredItems: []))
        }

        // Gitignore + Settings
        var extraItems: [SelectableItem] = []
        if !config.gitignoreEntries.isEmpty {
            itemCounter += 1
            extraItems.append(SelectableItem(
                number: itemCounter,
                name: "Gitignore entries",
                description: "\(config.gitignoreEntries.count) entries",
                isSelected: true
            ))
            gitignoreItem = itemCounter
        }
        if config.remainingSettingsData != nil {
            itemCounter += 1
            extraItems.append(SelectableItem(
                number: itemCounter,
                name: "Additional settings",
                description: "env vars, permissions, etc.",
                isSelected: true
            ))
            settingsItem = itemCounter
        }
        if !extraItems.isEmpty {
            groups.append(SelectableGroup(title: "Other", items: extraItems, requiredItems: []))
        }

        // Run multi-select
        let selected = output.multiSelect(groups: &groups)

        return Selection(
            mcpServers: Set(mcpMapping.filter { selected.contains($0.key) }.values),
            hookFiles: Set(hookMapping.filter { selected.contains($0.key) }.values),
            skillFiles: Set(skillMapping.filter { selected.contains($0.key) }.values),
            commandFiles: Set(commandMapping.filter { selected.contains($0.key) }.values),
            plugins: Set(pluginMapping.filter { selected.contains($0.key) }.values),
            sections: Set(sectionMapping.filter { selected.contains($0.key) }.values),
            includeUserContent: userContentItem.map { selected.contains($0) } ?? false,
            includeGitignore: gitignoreItem.map { selected.contains($0) } ?? false,
            includeSettings: settingsItem.map { selected.contains($0) } ?? false
        )
    }

    // MARK: - Metadata

    private func gatherMetadata(output: CLIOutput) -> ManifestBuilder.Metadata {
        output.sectionHeader("Pack metadata:")

        let defaultID = identifier ?? "my-pack"
        let id = output.promptInline("Pack identifier", default: defaultID)
        let name = output.promptInline("Display name", default: id.replacingOccurrences(of: "-", with: " ").capitalized)
        let desc = output.promptInline("Description", default: "Exported Claude Code configuration")
        let defaultAuthor = gitAuthorName()
        let author = output.promptInline("Author", default: defaultAuthor)

        output.plain("")

        return ManifestBuilder.Metadata(
            identifier: id,
            displayName: name,
            description: desc,
            author: author.isEmpty ? nil : author
        )
    }

    // MARK: - Post-export Hints

    private func printPostExportHints(
        config: ConfigurationDiscovery.DiscoveredConfiguration,
        output: CLIOutput
    ) {
        var hints: [String] = []

        // Check for MCP servers that might need brew
        let mcpCommands = config.mcpServers.compactMap(\.command)
        let brewHints = Set(mcpCommands.compactMap { cmd -> String? in
            let basename = URL(fileURLWithPath: cmd).lastPathComponent
            let brewPackages: [String: String] = [
                "node": "node", "npx": "node", "npm": "node",
                "python3": "python3", "uvx": "uv", "uv": "uv",
            ]
            return brewPackages[basename]
        })
        if !brewHints.isEmpty {
            hints.append("Some MCP servers may need brew packages: \(brewHints.sorted().joined(separator: ", "))")
            hints.append("Add `brew: <package>` components to your techpack.yaml if needed")
        }

        // Check for hooks without matched events
        let unmatchedHooks = config.hookFiles.filter { $0.hookEvent == nil }
        if !unmatchedHooks.isEmpty {
            hints.append("Hook files without matched events: \(unmatchedHooks.map(\.filename).joined(separator: ", "))")
            hints.append("Add `hookEvent:` to these components in techpack.yaml")
        }

        // Check for sensitive env vars
        let sensitiveServers = config.mcpServers.filter { !$0.sensitiveEnvVarNames.isEmpty }
        if !sensitiveServers.isEmpty {
            hints.append("Sensitive env vars were replaced with __PLACEHOLDER__ tokens")
            hints.append("Users will be prompted for values during `mcs sync`")
        }

        if !hints.isEmpty {
            output.plain("")
            output.warn("Review notes:")
            for hint in hints {
                output.plain("  - \(hint)")
            }
        }

        output.plain("")
        output.info("Next steps:")
        output.plain("  1. Review the generated techpack.yaml")
        output.plain("  2. Test with: mcs pack add \(outputDir)")
        output.plain("  3. Share via git: push to a repository and use mcs pack add <url>")
    }

    // MARK: - Helpers

    private func gitAuthorName() -> String? {
        let result = ShellRunner(environment: Environment()).run("/usr/bin/git", arguments: ["config", "user.name"])
        return result.succeeded ? result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) : nil
    }
}
