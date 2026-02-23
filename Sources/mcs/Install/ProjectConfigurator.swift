import Foundation

/// Per-project configuration engine.
///
/// Handles multi-pack selection, convergence (add/remove/update packs),
/// template composition, settings.local.json writing, and artifact tracking.
/// Used by `mcs configure`.
struct ProjectConfigurator {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    var registry: TechPackRegistry = .shared

    // MARK: - Interactive Flow

    /// Full interactive configure flow — multi-select of registered packs.
    func interactiveConfigure(at projectPath: URL) throws {
        output.header("Configure Project")
        output.plain("")
        output.info("Project: \(projectPath.path)")

        let packs = registry.availablePacks
        guard !packs.isEmpty else {
            output.error("No packs registered. Run 'mcs pack add <url>' first.")
            return
        }

        // Load previous state to pre-select previously configured packs
        let previousState = ProjectState(projectRoot: projectPath)
        let previousPacks = previousState.configuredPacks

        // Build selection groups — one group with all packs
        var number = 1
        var items: [SelectableItem] = []
        for pack in packs {
            items.append(SelectableItem(
                number: number,
                name: pack.displayName,
                description: pack.description,
                isSelected: previousPacks.contains(pack.identifier)
            ))
            number += 1
        }

        var groups = [SelectableGroup(
            title: "Tech Packs",
            items: items,
            requiredItems: []
        )]

        let selectedNumbers = output.multiSelect(groups: &groups)

        // Map numbers back to packs
        let selectedPacks = packs.enumerated().compactMap { index, pack in
            selectedNumbers.contains(index + 1) ? pack : nil
        }

        if selectedPacks.isEmpty {
            output.plain("")
            output.info("No packs selected. Nothing to configure.")
            return
        }

        try configure(at: projectPath, packs: selectedPacks)

        output.header("Done")
        output.info("Run 'mcs doctor' to verify configuration")
    }

    // MARK: - Configure (Multi-Pack)

    /// Configure a project with the given set of packs.
    /// Handles convergence: adds new packs, updates existing, removes deselected.
    func configure(
        at projectPath: URL,
        packs: [any TechPack]
    ) throws {
        let selectedIDs = Set(packs.map(\.identifier))

        // Load previous state
        var projectState = ProjectState(projectRoot: projectPath)
        let previousIDs = projectState.configuredPacks

        let removals = previousIDs.subtracting(selectedIDs)
        let additions = selectedIDs.subtracting(previousIDs)

        // 1. Unconfigure removed packs
        for packID in removals.sorted() {
            unconfigurePack(packID, at: projectPath, state: &projectState)
        }

        // 2. Auto-install global dependencies for all selected packs
        for pack in packs {
            autoInstallGlobalDependencies(pack)
        }

        // 3. Install per-project files for additions and updates
        for pack in packs {
            let isNew = additions.contains(pack.identifier)
            let label = isNew ? "Configuring" : "Updating"
            output.info("\(label) \(pack.displayName)...")
            let artifacts = installProjectArtifacts(pack, at: projectPath)
            projectState.setArtifacts(artifacts, for: pack.identifier)
            projectState.recordPack(pack.identifier)
        }

        // 4. Compose settings.local.json from ALL selected packs
        composeProjectSettings(at: projectPath, packs: packs)

        // 5. Compose CLAUDE.local.md from ALL selected packs
        let repoName = resolveRepoName(at: projectPath)
        try composeClaudeLocal(at: projectPath, packs: packs, repoName: repoName)

        // 6. Run pack-specific configureProject hooks
        for pack in packs {
            var context = ProjectConfigContext(
                projectPath: projectPath,
                repoName: repoName,
                output: output
            )
            let packValues = pack.templateValues(context: context)
            context = ProjectConfigContext(
                projectPath: projectPath,
                repoName: repoName,
                output: output,
                resolvedValues: packValues
            )
            try pack.configureProject(at: projectPath, context: context)
        }

        // 7. Ensure gitignore entries
        try ensureGitignoreEntries()
        for pack in packs {
            let exec = makeExecutor()
            exec.addPackGitignoreEntries(from: pack)
        }

        // 8. Save project state
        do {
            try projectState.save()
            output.success("Updated .claude/.mcs-project")
        } catch {
            output.warn("Could not write .mcs-project: \(error.localizedDescription)")
        }
    }

    // MARK: - Pack Unconfiguration

    /// Remove all per-project artifacts installed by a pack.
    private func unconfigurePack(
        _ packID: String,
        at projectPath: URL,
        state: inout ProjectState
    ) {
        output.info("Removing \(packID)...")
        let exec = makeExecutor()

        guard let artifacts = state.artifacts(for: packID) else {
            output.dimmed("No artifact record for \(packID) — skipping")
            state.removePack(packID)
            return
        }

        // Remove MCP servers
        for server in artifacts.mcpServers {
            exec.removeMCPServer(name: server.name, scope: server.scope)
            output.dimmed("  Removed MCP server: \(server.name)")
        }

        // Remove project files
        for path in artifacts.files {
            exec.removeProjectFile(relativePath: path, projectPath: projectPath)
            output.dimmed("  Removed: \(path)")
        }

        state.removePack(packID)
    }

    // MARK: - Global Dependencies

    /// Auto-install brew packages and plugins (global-scope only).
    private func autoInstallGlobalDependencies(_ pack: any TechPack) {
        let exec = makeExecutor()
        for component in pack.components {
            switch component.installAction {
            case .brewInstall(let package):
                if !shell.commandExists(package) {
                    output.dimmed("  Installing \(component.displayName)...")
                    _ = exec.installBrewPackage(package)
                }
            case .plugin(let name):
                output.dimmed("  Installing plugin \(component.displayName)...")
                _ = exec.installPlugin(name)
            default:
                break
            }
        }
    }

    // MARK: - Per-Project Artifact Installation

    /// Install per-project files and MCP servers for a pack.
    /// Returns a `PackArtifactRecord` tracking what was installed.
    private func installProjectArtifacts(
        _ pack: any TechPack,
        at projectPath: URL
    ) -> PackArtifactRecord {
        var artifacts = PackArtifactRecord()
        var exec = makeExecutor()

        for component in pack.components {
            switch component.installAction {
            case .mcpServer(let config):
                if exec.installMCPServer(config) {
                    artifacts.mcpServers.append(MCPServerRef(
                        name: config.name,
                        scope: config.resolvedScope
                    ))
                    output.success("  \(component.displayName) registered")
                }

            case .copyPackFile(let source, let destination, let fileType):
                let paths = exec.installProjectFile(
                    source: source,
                    destination: destination,
                    fileType: fileType,
                    projectPath: projectPath
                )
                artifacts.files.append(contentsOf: paths)
                if !paths.isEmpty {
                    output.success("  \(component.displayName) installed")
                }

            case .gitignoreEntries(let entries):
                _ = exec.addGitignoreEntries(entries)

            case .brewInstall, .plugin:
                // Handled by autoInstallGlobalDependencies
                break

            case .shellCommand(let command):
                let result = shell.shell(command)
                if !result.succeeded {
                    output.warn("  \(component.displayName) failed: \(String(result.stderr.prefix(200)))")
                }

            case .settingsMerge:
                // Settings merge is handled at the project level.
                break
            }
        }

        // Track template sections
        for contribution in pack.templates {
            artifacts.templateSections.append(contribution.sectionIdentifier)
        }

        return artifacts
    }

    // MARK: - Settings Composition

    /// Build `settings.local.json` from all selected packs' hook entries.
    private func composeProjectSettings(at projectPath: URL, packs: [any TechPack]) {
        let settingsPath = projectPath
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent("settings.local.json")

        var settings = Settings()

        // Gather hook entries from all packs
        for pack in packs {
            for contribution in pack.hookContributions {
                let command = "bash .claude/hooks/\(contribution.hookName).sh"
                let entry = Settings.HookEntry(type: "command", command: command)
                let group = Settings.HookGroup(matcher: nil, hooks: [entry])

                let event = hookEventName(for: contribution.hookName)
                var existing = settings.hooks ?? [:]
                var groups = existing[event] ?? []
                // Deduplicate by command
                if !groups.contains(where: { $0.hooks?.first?.command == command }) {
                    groups.append(group)
                }
                existing[event] = groups
                settings.hooks = existing
            }
        }

        // Only write if there's content
        guard settings.hooks != nil else { return }

        do {
            try settings.save(to: settingsPath)
            output.success("Composed settings.local.json")
        } catch {
            output.warn("Could not write settings.local.json: \(error.localizedDescription)")
        }
    }

    /// Map hook contribution names to Claude Code hook event names.
    private func hookEventName(for hookName: String) -> String {
        switch hookName {
        case "session_start": return "SessionStart"
        case "pre_tool_use": return "PreToolUse"
        case "post_tool_use": return "PostToolUse"
        case "notification": return "Notification"
        case "stop": return "Stop"
        default: return hookName
        }
    }

    // MARK: - CLAUDE.local.md Composition

    /// Compose CLAUDE.local.md from all selected packs' template contributions.
    private func composeClaudeLocal(
        at projectPath: URL,
        packs: [any TechPack],
        repoName: String
    ) throws {
        var allContributions: [TemplateContribution] = []
        var allValues: [String: String] = ["REPO_NAME": repoName]

        for pack in packs {
            allContributions.append(contentsOf: pack.templates)
            let context = ProjectConfigContext(
                projectPath: projectPath,
                repoName: repoName,
                output: output
            )
            let packValues = pack.templateValues(context: context)
            allValues.merge(packValues) { _, new in new }
        }

        guard !allContributions.isEmpty else {
            output.info("No template sections to add — skipping CLAUDE.local.md")
            return
        }

        try writeClaudeLocal(
            at: projectPath,
            contributions: allContributions,
            values: allValues
        )
    }

    // MARK: - CLAUDE.local.md Writing

    /// Compose and write CLAUDE.local.md from template contributions.
    func writeClaudeLocal(
        at projectPath: URL,
        contributions: [TemplateContribution],
        values: [String: String]
    ) throws {
        let version = MCSVersion.current
        let claudeLocalPath = projectPath.appendingPathComponent(Constants.FileNames.claudeLocalMD)
        let fm = FileManager.default

        let coreContribution = contributions.first { $0.sectionIdentifier == "core" }
        let otherContributions = contributions.filter { $0.sectionIdentifier != "core" }
        let coreContent = coreContribution?.templateContent ?? ""

        let composed: String
        let existingContent: String? = fm.fileExists(atPath: claudeLocalPath.path)
            ? try String(contentsOf: claudeLocalPath, encoding: .utf8)
            : nil

        let hasMarkers = existingContent.map {
            !TemplateComposer.parseSections(from: $0).isEmpty
        } ?? false

        if let existingContent, hasMarkers {
            let unpaired = TemplateComposer.unpairedSections(in: existingContent)
            if !unpaired.isEmpty {
                output.warn("Unpaired section markers in CLAUDE.local.md: \(unpaired.joined(separator: ", "))")
                output.warn("Sections with missing end markers will not be updated to prevent data loss.")
                output.warn("Add the missing end markers manually, then re-run mcs configure.")
            }

            let userContent = TemplateComposer.extractUserContent(from: existingContent)

            let processedCore = TemplateEngine.substitute(template: coreContent, values: values)
            var updated = TemplateComposer.replaceSection(
                in: existingContent,
                sectionIdentifier: "core",
                newContent: processedCore,
                newVersion: version
            )

            for contribution in otherContributions {
                let processedContent = TemplateEngine.substitute(
                    template: contribution.templateContent,
                    values: values
                )
                updated = TemplateComposer.replaceSection(
                    in: updated,
                    sectionIdentifier: contribution.sectionIdentifier,
                    newContent: processedContent,
                    newVersion: version
                )
            }

            let trimmedUser = userContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedUser.isEmpty {
                let currentUser = TemplateComposer.extractUserContent(from: updated)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if currentUser.isEmpty {
                    updated += "\n\n" + trimmedUser + "\n"
                }
            }

            composed = updated
        } else {
            if existingContent != nil {
                output.info("Migrating CLAUDE.local.md from v1 to v2 format")
            }

            composed = TemplateComposer.compose(
                coreContent: coreContent,
                packContributions: otherContributions,
                values: values
            )
        }

        var backup = Backup()
        if fm.fileExists(atPath: claudeLocalPath.path) {
            do {
                try backup.backupFile(at: claudeLocalPath)
            } catch {
                output.warn("Could not create backup: \(error.localizedDescription)")
            }
        }
        try composed.write(to: claudeLocalPath, atomically: true, encoding: .utf8)
        output.success("Generated CLAUDE.local.md")
    }

    // MARK: - Gitignore

    private func ensureGitignoreEntries() throws {
        let manager = GitignoreManager(shell: shell)
        try manager.addCoreEntries()
    }

    // MARK: - Helpers

    private func makeExecutor() -> ComponentExecutor {
        ComponentExecutor(
            environment: environment,
            output: output,
            shell: shell,
            backup: Backup()
        )
    }

    private func resolveRepoName(at projectPath: URL) -> String {
        let gitResult = shell.run(
            "/usr/bin/git",
            arguments: ["-C", projectPath.path, "rev-parse", "--show-toplevel"]
        )
        if gitResult.succeeded, !gitResult.stdout.isEmpty {
            return URL(fileURLWithPath: gitResult.stdout).lastPathComponent
        }
        return projectPath.lastPathComponent
    }
}
