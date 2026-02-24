import Foundation

/// Per-project configuration engine.
///
/// Handles multi-pack selection, convergence (add/remove/update packs),
/// template composition, settings.local.json writing, and artifact tracking.
/// Used by `mcs sync`.
struct ProjectConfigurator {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    var registry: TechPackRegistry = .shared

    // MARK: - Interactive Flow

    /// Full interactive configure flow — multi-select of registered packs.
    ///
    /// - Parameter customize: When `true`, present per-pack component multi-select after pack selection.
    func interactiveConfigure(at projectPath: URL, dryRun: Bool = false, customize: Bool = false) throws {
        output.header("Sync Project")
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

        if selectedPacks.isEmpty && previousPacks.isEmpty {
            output.plain("")
            output.info("No packs selected. Nothing to configure.")
            return
        }

        // Component-level customization
        var excludedComponents: [String: Set<String>] = [:]
        if customize && !selectedPacks.isEmpty {
            excludedComponents = selectComponentExclusions(
                packs: selectedPacks,
                previousState: previousState
            )
        }

        if dryRun {
            self.dryRun(at: projectPath, packs: selectedPacks)
        } else {
            try configure(at: projectPath, packs: selectedPacks, excludedComponents: excludedComponents)

            output.header("Done")
            output.info("Run 'mcs doctor' to verify configuration")
        }
    }

    /// Present per-pack component multi-select and return excluded component IDs.
    private func selectComponentExclusions(
        packs: [any TechPack],
        previousState: ProjectState
    ) -> [String: Set<String>] {
        var exclusions: [String: Set<String>] = [:]

        for pack in packs {
            let components = pack.components
            guard components.count > 1 else { continue } // No point customizing a single component

            output.plain("")
            output.info("Components for \(pack.displayName):")

            let previousExcluded = previousState.excludedComponents(for: pack.identifier)

            var number = 1
            var items: [SelectableItem] = []
            for component in components {
                items.append(SelectableItem(
                    number: number,
                    name: component.displayName,
                    description: component.description,
                    isSelected: !previousExcluded.contains(component.id)
                ))
                number += 1
            }

            let requiredItems = components
                .filter(\.isRequired)
                .map { RequiredItem(name: $0.displayName) }

            var groups = [SelectableGroup(
                title: pack.displayName,
                items: items,
                requiredItems: requiredItems
            )]

            let selectedNumbers = output.multiSelect(groups: &groups)

            // Compute excluded = all component IDs NOT in selectedNumbers
            var excluded = Set<String>()
            for (index, component) in components.enumerated() {
                if !selectedNumbers.contains(index + 1) && !component.isRequired {
                    excluded.insert(component.id)
                }
            }

            if !excluded.isEmpty {
                exclusions[pack.identifier] = excluded
            }
        }

        return exclusions
    }

    // MARK: - Dry Run

    /// Compute and display what `configure` would do, without making any changes.
    func dryRun(at projectPath: URL, packs: [any TechPack]) {
        let selectedIDs = Set(packs.map(\.identifier))

        let projectState = ProjectState(projectRoot: projectPath)
        let previousIDs = projectState.configuredPacks

        let removals = previousIDs.subtracting(selectedIDs)
        let additions = selectedIDs.subtracting(previousIDs)
        let updates = selectedIDs.intersection(previousIDs)

        output.header("Plan")

        if removals.isEmpty && additions.isEmpty && updates.isEmpty && packs.isEmpty {
            output.plain("")
            output.info("No packs selected. Nothing would change.")
            output.plain("")
            output.dimmed("No changes made (dry run).")
            return
        }

        // Show additions
        for pack in packs where additions.contains(pack.identifier) {
            output.plain("")
            output.success("+ \(pack.displayName) (new)")
            printPackArtifactSummary(pack)
        }

        // Show removals
        for packID in removals.sorted() {
            output.plain("")
            output.warn("- \(packID) (remove)")
            if let artifacts = projectState.artifacts(for: packID) {
                printRemovalSummary(artifacts)
            } else {
                output.dimmed("  No artifact record available")
            }
        }

        // Show updates (unchanged packs that would be refreshed)
        for pack in packs where updates.contains(pack.identifier) {
            output.plain("")
            output.info("~ \(pack.displayName) (update)")
            printPackArtifactSummary(pack)
        }

        output.plain("")
        let totalChanges = additions.count + removals.count
        if totalChanges == 0 {
            output.info("\(updates.count) pack(s) would be refreshed, no additions or removals.")
        } else {
            var parts: [String] = []
            if !additions.isEmpty { parts.append("+\(additions.count) added") }
            if !removals.isEmpty { parts.append("-\(removals.count) removed") }
            if !updates.isEmpty { parts.append("~\(updates.count) updated") }
            output.info(parts.joined(separator: ", "))
        }
        output.plain("")
        output.dimmed("No changes made (dry run).")
    }

    /// Print what a pack would install (for dry-run display).
    private func printPackArtifactSummary(_ pack: any TechPack) {
        // MCP servers
        let mcpServers = pack.components.compactMap { component -> String? in
            if case .mcpServer(let config) = component.installAction {
                return "+\(config.name) (\(config.resolvedScope))"
            }
            return nil
        }
        if !mcpServers.isEmpty {
            output.dimmed("  MCP servers:  \(mcpServers.joined(separator: ", "))")
        }

        // Files (skills, hooks, commands)
        let files = pack.components.compactMap { component -> String? in
            if case .copyPackFile(_, let destination, let fileType) = component.installAction {
                let prefix: String
                switch fileType {
                case .skill: prefix = ".claude/skills/"
                case .hook: prefix = ".claude/hooks/"
                case .command: prefix = ".claude/commands/"
                case .generic: prefix = ".claude/"
                }
                return "+\(prefix)\(destination)"
            }
            return nil
        }
        if !files.isEmpty {
            output.dimmed("  Files:        \(files.joined(separator: ", "))")
        }

        // Templates
        let templateSections = pack.templates.map { "+\($0.sectionIdentifier) section" }
        if !templateSections.isEmpty {
            output.dimmed("  Templates:    \(templateSections.joined(separator: ", ")) in CLAUDE.local.md")
        }

        // Hook entries (settings.local.json)
        let hookEntries = pack.hookContributions.map { "+\(hookEventName(for: $0.hookName)) hook entry" }
        if !hookEntries.isEmpty {
            output.dimmed("  Hooks:        \(hookEntries.joined(separator: ", "))")
        }

        // Settings files
        let settingsFiles = pack.components.compactMap { component -> String? in
            if case .settingsMerge(let source) = component.installAction, source != nil {
                return "+settings merge from \(component.displayName)"
            }
            return nil
        }
        if !settingsFiles.isEmpty {
            output.dimmed("  Settings:     \(settingsFiles.joined(separator: ", "))")
        }

        // Brew packages
        let brewPackages = pack.components.compactMap { component -> String? in
            if case .brewInstall(let package) = component.installAction {
                return package
            }
            return nil
        }
        if !brewPackages.isEmpty {
            output.dimmed("  Brew:         \(brewPackages.joined(separator: ", ")) (global)")
        }

        // Plugins
        let plugins = pack.components.compactMap { component -> String? in
            if case .plugin(let name) = component.installAction {
                return PluginRef(name).bareName
            }
            return nil
        }
        if !plugins.isEmpty {
            output.dimmed("  Plugins:      \(plugins.joined(separator: ", ")) (global)")
        }
    }

    /// Print what a removal would clean up.
    private func printRemovalSummary(_ artifacts: PackArtifactRecord) {
        for server in artifacts.mcpServers {
            output.dimmed("      MCP server: \(server.name)")
        }
        for path in artifacts.files {
            output.dimmed("      File: \(path)")
        }
        for section in artifacts.templateSections {
            output.dimmed("      CLAUDE.local.md section: \(section)")
        }
        for cmd in artifacts.hookCommands {
            output.dimmed("      Hook: \(cmd)")
        }
    }

    // MARK: - Configure (Multi-Pack)

    /// Configure a project with the given set of packs.
    /// Handles convergence: adds new packs, updates existing, removes deselected.
    ///
    /// - Parameter confirmRemovals: When `true`, prompt the user before removing packs.
    ///   Pass `false` for non-interactive paths (`--pack`, `--all`).
    /// - Parameter excludedComponents: Component IDs excluded per pack (packID -> Set<componentID>).
    ///   Excluded components are skipped during installation, settings composition, and artifact tracking.
    func configure(
        at projectPath: URL,
        packs: [any TechPack],
        confirmRemovals: Bool = true,
        excludedComponents: [String: Set<String>] = [:]
    ) throws {
        let selectedIDs = Set(packs.map(\.identifier))

        // Load previous state
        var projectState = ProjectState(projectRoot: projectPath)
        let previousIDs = projectState.configuredPacks

        let removals = previousIDs.subtracting(selectedIDs)
        let additions = selectedIDs.subtracting(previousIDs)

        // 0. Validate peer dependencies before making any changes
        let peerIssues = validatePeerDependencies(packs: packs)
        if !peerIssues.isEmpty {
            for issue in peerIssues {
                switch issue.status {
                case .missing:
                    output.error("Pack '\(issue.packIdentifier)' requires peer pack '\(issue.peerPack)' (>= \(issue.minVersion)) which is not selected.")
                    output.dimmed("  Either select '\(issue.peerPack)' or deselect '\(issue.packIdentifier)'.")
                case .versionTooLow(let actual):
                    output.error("Pack '\(issue.packIdentifier)' requires peer pack '\(issue.peerPack)' >= \(issue.minVersion), but v\(actual) is registered.")
                    output.dimmed("  Update it with: mcs pack update \(issue.peerPack)")
                case .satisfied:
                    break
                }
            }
            throw MCSError.configurationFailed(
                reason: "Unresolved peer dependencies. Fix the issues above and re-run mcs sync."
            )
        }

        // 1. Confirm and unconfigure removed packs
        if confirmRemovals && !removals.isEmpty {
            output.plain("")
            output.warn("The following packs will be removed:")
            for packID in removals.sorted() {
                output.plain("  - \(packID)")
                if let artifacts = projectState.artifacts(for: packID) {
                    printRemovalSummary(artifacts)
                }
            }
            output.plain("")
            guard output.askYesNo("Proceed with removal?", default: true) else {
                output.info("Sync cancelled.")
                return
            }
        }

        for packID in removals.sorted() {
            unconfigurePack(packID, at: projectPath, state: &projectState)
        }

        // 2. Auto-install global dependencies for all selected packs
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            autoInstallGlobalDependencies(pack, excludedIDs: excluded)
        }

        // 3. Resolve all template/placeholder values upfront (single pass)
        let repoName = resolveRepoName(at: projectPath)
        var allValues = resolveAllTemplateValues(packs: packs, projectPath: projectPath, repoName: repoName)

        // 4. Auto-prompt for undeclared placeholders in pack files
        let undeclared = scanForUndeclaredPlaceholders(packs: packs, resolvedValues: allValues)
        for key in undeclared {
            let value = output.promptInline("Set value for \(key)", default: nil)
            allValues[key] = value
        }

        // 5. Install per-project files with resolved values
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            let isNew = additions.contains(pack.identifier)
            let label = isNew ? "Configuring" : "Updating"
            output.info("\(label) \(pack.displayName)...")
            let artifacts = installProjectArtifacts(pack, at: projectPath, resolvedValues: allValues, excludedIDs: excluded)
            projectState.setArtifacts(artifacts, for: pack.identifier)
            projectState.setExcludedComponents(excluded, for: pack.identifier)
            projectState.recordPack(pack.identifier)
        }

        // 6. Compose settings.local.json from ALL selected packs
        composeProjectSettings(at: projectPath, packs: packs, excludedComponents: excludedComponents)

        // 7. Compose CLAUDE.local.md with pre-resolved values
        try composeClaudeLocal(at: projectPath, packs: packs, values: allValues)

        // 8. Run pack-specific configureProject hooks with resolved values
        for pack in packs {
            let context = ProjectConfigContext(
                projectPath: projectPath,
                repoName: repoName,
                output: output,
                resolvedValues: allValues
            )
            try pack.configureProject(at: projectPath, context: context)
        }

        // 9. Ensure gitignore entries
        try ensureGitignoreEntries()
        for pack in packs {
            let exec = makeExecutor()
            exec.addPackGitignoreEntries(from: pack)
        }

        // 10. Save project state
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

        // Remove auto-derived hook commands from settings.local.json
        if !artifacts.hookCommands.isEmpty {
            let settingsPath = projectPath
                .appendingPathComponent(Constants.FileNames.claudeDirectory)
                .appendingPathComponent("settings.local.json")
            do {
                var settings = try Settings.load(from: settingsPath)
                let commandsToRemove = Set(artifacts.hookCommands)
                if var hooks = settings.hooks {
                    for (event, groups) in hooks {
                        hooks[event] = groups.filter { group in
                            guard let cmd = group.hooks?.first?.command else { return true }
                            return !commandsToRemove.contains(cmd)
                        }
                    }
                    hooks = hooks.filter { !$0.value.isEmpty }
                    settings.hooks = hooks.isEmpty ? nil : hooks
                }
                try settings.save(to: settingsPath)
                for cmd in artifacts.hookCommands {
                    output.dimmed("  Removed hook: \(cmd)")
                }
            } catch {
                output.warn("Could not clean up hooks from settings.local.json: \(error.localizedDescription)")
            }
        }

        // Remove template sections from CLAUDE.local.md
        if !artifacts.templateSections.isEmpty {
            let claudeLocalPath = projectPath.appendingPathComponent(Constants.FileNames.claudeLocalMD)
            do {
                let content = try String(contentsOf: claudeLocalPath, encoding: .utf8)
                var updated = content
                for sectionID in artifacts.templateSections {
                    updated = TemplateComposer.removeSection(in: updated, sectionIdentifier: sectionID)
                }
                if updated != content {
                    try updated.write(to: claudeLocalPath, atomically: true, encoding: .utf8)
                    for sectionID in artifacts.templateSections {
                        output.dimmed("  Removed template section: \(sectionID)")
                    }
                }
            } catch {
                output.warn("Could not update CLAUDE.local.md: \(error.localizedDescription)")
            }
        }

        state.removePack(packID)
    }

    // MARK: - Global Dependencies

    /// Auto-install brew packages and plugins (global-scope only).
    private func autoInstallGlobalDependencies(_ pack: any TechPack, excludedIDs: Set<String> = []) {
        let exec = makeExecutor()
        for component in pack.components {
            guard !excludedIDs.contains(component.id) else { continue }
            guard !ComponentExecutor.isAlreadyInstalled(component) else { continue }

            switch component.installAction {
            case .brewInstall(let package):
                output.dimmed("  Installing \(component.displayName)...")
                _ = exec.installBrewPackage(package)
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
        at projectPath: URL,
        resolvedValues: [String: String] = [:],
        excludedIDs: Set<String> = []
    ) -> PackArtifactRecord {
        var artifacts = PackArtifactRecord()
        var exec = makeExecutor()

        for component in pack.components {
            if excludedIDs.contains(component.id) {
                output.dimmed("  \(component.displayName) excluded, skipping")
                continue
            }

            // Check doctor checks before running install — skip if already installed.
            // Convergent actions (copyPackFile, settingsMerge, mcpServer, gitignore)
            // always report not-installed so they re-run to pick up changes.
            if ComponentExecutor.isAlreadyInstalled(component) {
                output.dimmed("  \(component.displayName) already installed, skipping")
                continue
            }

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
                    projectPath: projectPath,
                    resolvedValues: resolvedValues
                )
                artifacts.files.append(contentsOf: paths)
                // Track auto-derived hook commands for convergence cleanup
                if component.type == .hookFile,
                   component.hookEvent != nil,
                   fileType == .hook {
                    artifacts.hookCommands.append("bash .claude/hooks/\(destination)")
                }
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

    /// Build `settings.local.json` from all selected packs' hook entries and settings files.
    private func composeProjectSettings(
        at projectPath: URL,
        packs: [any TechPack],
        excludedComponents: [String: Set<String>] = [:]
    ) {
        let settingsPath = projectPath
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent("settings.local.json")

        var settings = Settings()
        var hasContent = false

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
                hasContent = true
            }
        }

        // Auto-derive hook entries from hookFile components with hookEvent
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            for component in pack.components {
                guard !excluded.contains(component.id) else { continue }
                if component.type == .hookFile,
                   let hookEvent = component.hookEvent,
                   case .copyPackFile(_, let destination, .hook) = component.installAction {
                    let command = "bash .claude/hooks/\(destination)"
                    let entry = Settings.HookEntry(type: "command", command: command)
                    let group = Settings.HookGroup(matcher: nil, hooks: [entry])
                    var existing = settings.hooks ?? [:]
                    var groups = existing[hookEvent] ?? []
                    if !groups.contains(where: { $0.hooks?.first?.command == command }) {
                        groups.append(group)
                    }
                    existing[hookEvent] = groups
                    settings.hooks = existing
                    hasContent = true
                }
            }
        }

        // Auto-derive enabledPlugins from plugin components
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            for component in pack.components {
                guard !excluded.contains(component.id) else { continue }
                if case .plugin(let name) = component.installAction {
                    let ref = PluginRef(name)
                    var plugins = settings.enabledPlugins ?? [:]
                    if plugins[ref.bareName] == nil {
                        plugins[ref.bareName] = true
                    }
                    settings.enabledPlugins = plugins
                    hasContent = true
                }
            }
        }

        // Merge settings files from packs
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            for component in pack.components {
                guard !excluded.contains(component.id) else { continue }
                if case .settingsMerge(let source) = component.installAction, let source {
                    do {
                        let packSettings = try Settings.load(from: source)
                        settings.merge(with: packSettings)
                        hasContent = true
                    } catch {
                        output.warn("Could not load settings from \(source.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Write composed settings or clean up stale file
        if hasContent {
            do {
                try settings.save(to: settingsPath)
                output.success("Composed settings.local.json")
            } catch {
                output.warn("Could not write settings.local.json: \(error.localizedDescription)")
            }
        } else if FileManager.default.fileExists(atPath: settingsPath.path) {
            // No packs contribute settings — remove stale file
            do {
                try FileManager.default.removeItem(at: settingsPath)
                output.dimmed("Removed empty settings.local.json")
            } catch {
                output.warn("Could not remove stale settings.local.json: \(error.localizedDescription)")
            }
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
        values: [String: String]
    ) throws {
        var allContributions: [TemplateContribution] = []

        for pack in packs {
            allContributions.append(contentsOf: pack.templates)
        }

        guard !allContributions.isEmpty else {
            output.info("No template sections to add — skipping CLAUDE.local.md")
            return
        }

        try writeClaudeLocal(
            at: projectPath,
            contributions: allContributions,
            values: values
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
                output.warn("Add the missing end markers manually, then re-run mcs sync.")
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

        if fm.fileExists(atPath: claudeLocalPath.path) {
            var backup = Backup()
            try backup.backupFile(at: claudeLocalPath)
        }
        try composed.write(to: claudeLocalPath, atomically: true, encoding: .utf8)
        output.success("Generated CLAUDE.local.md")
    }

    // MARK: - Gitignore

    private func ensureGitignoreEntries() throws {
        let manager = GitignoreManager(shell: shell)
        try manager.addCoreEntries()
    }

    // MARK: - Value Resolution

    /// Resolve all template/placeholder values from pack prompts in a single pass.
    /// Returns a merged dictionary with `REPO_NAME` and all pack-declared prompt values.
    private func resolveAllTemplateValues(
        packs: [any TechPack],
        projectPath: URL,
        repoName: String
    ) -> [String: String] {
        var allValues: [String: String] = ["REPO_NAME": repoName]
        let context = ProjectConfigContext(
            projectPath: projectPath,
            repoName: repoName,
            output: output
        )
        for pack in packs {
            let packValues = pack.templateValues(context: context)
            allValues.merge(packValues) { _, new in new }
        }
        return allValues
    }

    /// Scan all `copyPackFile` sources and template content for `__PLACEHOLDER__` tokens
    /// that are not covered by resolved values. Returns the undeclared keys sorted alphabetically.
    private func scanForUndeclaredPlaceholders(
        packs: [any TechPack],
        resolvedValues: [String: String]
    ) -> [String] {
        var undeclared = Set<String>()
        let resolvedKeys = Set(resolvedValues.keys)

        for pack in packs {
            // Scan copyPackFile sources
            for component in pack.components {
                if case .copyPackFile(let source, _, _) = component.installAction {
                    for placeholder in Self.findPlaceholdersInSource(source) {
                        let key = Self.stripPlaceholderDelimiters(placeholder)
                        if !resolvedKeys.contains(key) {
                            undeclared.insert(key)
                        }
                    }
                }
            }

            // Scan template content
            for template in pack.templates {
                for placeholder in TemplateEngine.findUnreplacedPlaceholders(in: template.templateContent) {
                    let key = Self.stripPlaceholderDelimiters(placeholder)
                    if !resolvedKeys.contains(key) {
                        undeclared.insert(key)
                    }
                }
            }
        }

        return undeclared.sorted()
    }

    /// Find all `__PLACEHOLDER__` tokens in a file or directory of files.
    private static func findPlaceholdersInSource(_ source: URL) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return [] }

        let files: [URL]
        if isDir.boolValue {
            files = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        } else {
            files = [source]
        }

        var results: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            results.append(contentsOf: TemplateEngine.findUnreplacedPlaceholders(in: text))
        }
        return results
    }

    /// Strip `__` delimiters from a placeholder token: `__FOO__` → `FOO`.
    private static func stripPlaceholderDelimiters(_ placeholder: String) -> String {
        String(placeholder.dropFirst(2).dropLast(2))
    }

    // MARK: - Helpers

    private func makeExecutor() -> ComponentExecutor {
        ComponentExecutor(
            environment: environment,
            output: output,
            shell: shell
        )
    }

    /// Validate peer dependencies for all selected packs.
    /// Returns only unsatisfied results (missing or version too low).
    private func validatePeerDependencies(packs: [any TechPack]) -> [PeerDependencyResult] {
        let packRegistryFile = PackRegistryFile(path: environment.packsRegistry)
        let registeredPacks = (try? packRegistryFile.load())?.packs ?? []

        return PeerDependencyValidator.validateSelection(
            packs: packs,
            registeredPacks: registeredPacks
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
