import Foundation

/// Global-scope configuration engine.
///
/// Installs brew packages, MCP servers (scope "user"), plugins, and files
/// into `~/.claude/` directories. Composes `~/.claude/settings.json` from
/// pack hook entries, plugins, and settings files. Composes `~/.claude/CLAUDE.md`
/// from pack template contributions. State is tracked at `~/.mcs/global-state.json`.
struct GlobalConfigurator {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    var registry: TechPackRegistry = .shared

    // MARK: - Interactive Flow

    /// Full interactive global configure flow — multi-select of registered packs.
    func interactiveConfigure(dryRun: Bool = false, customize: Bool = false) throws {
        output.header("Sync Global")
        output.plain("")
        output.info("Target: \(environment.claudeDirectory.path)")

        let packs = registry.availablePacks
        guard !packs.isEmpty else {
            output.error("No packs registered. Run 'mcs pack add <url>' first.")
            return
        }

        let previousState = try ProjectState(stateFile: environment.globalStateFile)
        let previousPacks = previousState.configuredPacks

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
            title: "Tech Packs (Global)",
            items: items,
            requiredItems: []
        )]

        let selectedNumbers = output.multiSelect(groups: &groups)

        let selectedPacks = packs.enumerated().compactMap { index, pack in
            selectedNumbers.contains(index + 1) ? pack : nil
        }

        if selectedPacks.isEmpty && previousPacks.isEmpty {
            output.plain("")
            output.info("No packs selected. Nothing to configure.")
            return
        }

        var excludedComponents: [String: Set<String>] = [:]
        if customize && !selectedPacks.isEmpty {
            excludedComponents = selectComponentExclusions(
                packs: selectedPacks,
                previousState: previousState
            )
        }

        if dryRun {
            try self.dryRun(packs: selectedPacks)
        } else {
            try configure(packs: selectedPacks, excludedComponents: excludedComponents)

            output.header("Done")
            output.info("Run 'mcs doctor' to verify configuration")
        }
    }

    /// Present per-pack component multi-select and return excluded component IDs.
    private func selectComponentExclusions(
        packs: [any TechPack],
        previousState: ProjectState
    ) -> [String: Set<String>] {
        ConfiguratorSupport.selectComponentExclusions(
            packs: packs,
            previousState: previousState,
            output: output
        )
    }

    // MARK: - Dry Run

    /// Compute and display what `configure` would do, without making any changes.
    func dryRun(packs: [any TechPack]) throws {
        let state = try ProjectState(stateFile: environment.globalStateFile)
        ConfiguratorSupport.dryRunSummary(
            packs: packs,
            state: state,
            header: "Plan (Global)",
            output: output,
            artifactSummary: printGlobalArtifactSummary,
            removalSummary: printRemovalSummary
        )
    }

    private func printGlobalArtifactSummary(_ pack: any TechPack) {
        let mcpServers = pack.components.compactMap { component -> String? in
            if case .mcpServer(let config) = component.installAction {
                return "+\(config.name) (user)"
            }
            return nil
        }
        if !mcpServers.isEmpty {
            output.dimmed("  MCP servers:  \(mcpServers.joined(separator: ", "))")
        }

        let files = pack.components.compactMap { component -> String? in
            if case .copyPackFile(_, let destination, let fileType) = component.installAction {
                let prefix: String
                switch fileType {
                case .skill: prefix = "~/.claude/skills/"
                case .hook: prefix = "~/.claude/hooks/"
                case .command: prefix = "~/.claude/commands/"
                case .generic: prefix = "~/.claude/"
                }
                return "+\(prefix)\(destination)"
            }
            return nil
        }
        if !files.isEmpty {
            output.dimmed("  Files:        \(files.joined(separator: ", "))")
        }

        let brewPackages = pack.components.compactMap { component -> String? in
            if case .brewInstall(let package) = component.installAction {
                return package
            }
            return nil
        }
        if !brewPackages.isEmpty {
            output.dimmed("  Brew:         \(brewPackages.joined(separator: ", "))")
        }

        let plugins = pack.components.compactMap { component -> String? in
            if case .plugin(let name) = component.installAction {
                return PluginRef(name).bareName
            }
            return nil
        }
        if !plugins.isEmpty {
            output.dimmed("  Plugins:      \(plugins.joined(separator: ", "))")
        }

        let templateSections = pack.templateSectionIdentifiers.map { "+\($0) section" }
        if !templateSections.isEmpty {
            output.dimmed("  Templates:    \(templateSections.joined(separator: ", ")) in CLAUDE.md")
        }
    }

    private func printRemovalSummary(_ artifacts: PackArtifactRecord) {
        for server in artifacts.mcpServers {
            output.dimmed("      MCP server: \(server.name)")
        }
        for path in artifacts.files {
            output.dimmed("      File: \(path)")
        }
        for pkg in artifacts.brewPackages {
            output.dimmed("      Brew package: \(pkg)")
        }
        for plugin in artifacts.plugins {
            output.dimmed("      Plugin: \(PluginRef(plugin).bareName)")
        }
        for section in artifacts.templateSections {
            output.dimmed("      CLAUDE.md section: \(section)")
        }
    }

    // MARK: - Configure (Multi-Pack)

    /// Configure global scope with the given set of packs.
    /// Handles convergence: adds new packs, updates existing, removes deselected.
    func configure(
        packs: [any TechPack],
        confirmRemovals: Bool = true,
        excludedComponents: [String: Set<String>] = [:]
    ) throws {
        let selectedIDs = Set(packs.map(\.identifier))

        var state = try ProjectState(stateFile: environment.globalStateFile)
        let previousIDs = state.configuredPacks

        let removals = previousIDs.subtracting(selectedIDs)
        let additions = selectedIDs.subtracting(previousIDs)

        // 0. Validate peer dependencies
        let peerIssues = validatePeerDependencies(packs: packs)
        if ConfiguratorSupport.reportPeerDependencyIssues(
            peerIssues,
            output: output,
            severity: .error,
            missingSuggestion: { packID, peerPack in
                "Either select '\(peerPack)' or deselect '\(packID)'."
            }
        ) {
            throw MCSError.configurationFailed(
                reason: "Unresolved peer dependencies. Fix the issues above and re-run mcs sync --global."
            )
        }

        // 1. Confirm and unconfigure removed packs
        if confirmRemovals && !removals.isEmpty {
            output.plain("")
            output.warn("The following packs will be removed (global):")
            for packID in removals.sorted() {
                output.plain("  - \(packID)")
                if let artifacts = state.artifacts(for: packID) {
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
            unconfigurePack(packID, state: &state)
        }

        // 2. Resolve all template/placeholder values upfront (single pass)
        var allValues = try resolveGlobalTemplateValues(packs: packs)

        // 2b. Auto-prompt for undeclared placeholders in pack files
        let undeclared = ConfiguratorSupport.scanForUndeclaredPlaceholders(packs: packs, resolvedValues: allValues)
        for key in undeclared {
            let value = output.promptInline("Set value for \(key)", default: nil)
            allValues[key] = value
        }

        // 2c. Pre-load templates (single disk read per pack)
        var preloadedTemplates: [String: [TemplateContribution]] = [:]
        for pack in packs {
            do {
                preloadedTemplates[pack.identifier] = try pack.templates
            } catch {
                output.warn("Could not load templates for \(pack.displayName): \(error.localizedDescription)")
            }
        }

        // 2d. Persist resolved values for doctor freshness checks
        state.setResolvedValues(allValues)

        // 3. Install global artifacts for each pack
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            let isNew = additions.contains(pack.identifier)
            let label = isNew ? "Configuring" : "Updating"
            output.info("\(label) \(pack.displayName) (global)...")
            let previousArtifacts = state.artifacts(for: pack.identifier)
            let artifacts = installGlobalArtifacts(
                pack,
                previousArtifacts: previousArtifacts,
                excludedIDs: excluded,
                resolvedValues: allValues,
                preloadedTemplates: preloadedTemplates[pack.identifier]
            )
            state.setArtifacts(artifacts, for: pack.identifier)
            state.setExcludedComponents(excluded, for: pack.identifier)
            state.recordPack(pack.identifier)
        }

        // 4. Compose global settings.json from ALL selected packs
        let contributedKeys = try composeGlobalSettings(packs: packs, excludedComponents: excludedComponents)

        // 4b. Record contributed settings keys in artifact records
        for (packID, keys) in contributedKeys {
            if var artifacts = state.artifacts(for: packID) {
                artifacts.settingsKeys = keys
                state.setArtifacts(artifacts, for: packID)
            }
        }

        // 4c. Compose ~/.claude/CLAUDE.md from ALL selected packs' templates
        let writtenSections = try composeGlobalClaudeMD(packs: packs, preloadedTemplates: preloadedTemplates, values: allValues)

        // 4d. Reconcile artifact records — remove template sections skipped by placeholder prompt
        if let writtenSections {
            for pack in packs {
                if var artifacts = state.artifacts(for: pack.identifier) {
                    let before = artifacts.templateSections.count
                    artifacts.templateSections = artifacts.templateSections.filter { writtenSections.contains($0) }
                    if artifacts.templateSections.count != before {
                        state.setArtifacts(artifacts, for: pack.identifier)
                    }
                }
            }
        }

        // 5. Ensure gitignore entries
        try ensureGitignoreEntries()
        for pack in packs {
            let exec = makeExecutor()
            exec.addPackGitignoreEntries(from: pack)
        }

        // 6. Save global state — failure here means artifacts become untracked
        do {
            try state.save()
            output.success("Updated \(environment.globalStateFile.lastPathComponent)")
        } catch {
            output.error("Could not write global state: \(error.localizedDescription)")
            output.error("Global state may be inconsistent. Re-run 'mcs sync --global' to recover.")
            throw MCSError.fileOperationFailed(
                path: environment.globalStateFile.path,
                reason: error.localizedDescription
            )
        }

        // 7. Update project index for cross-project tracking
        do {
            let indexFile = ProjectIndex(path: environment.projectsIndexFile)
            var indexData = try indexFile.load()
            indexFile.upsert(
                projectPath: ProjectIndex.globalSentinel,
                packIDs: packs.map(\.identifier),
                in: &indexData
            )
            try indexFile.save(indexData)
        } catch {
            output.error("Could not update project index: \(error.localizedDescription)")
            output.error("Cross-project resource tracking may be inaccurate. Re-run 'mcs sync --global' to retry.")
        }

    }

    // MARK: - Pack Unconfiguration

    /// Remove all global artifacts installed by a pack.
    private func unconfigurePack(
        _ packID: String,
        state: inout ProjectState
    ) {
        output.info("Removing \(packID) (global)...")
        let exec = makeExecutor()

        guard let artifacts = state.artifacts(for: packID) else {
            output.dimmed("No artifact record for \(packID) — skipping")
            state.removePack(packID)
            return
        }

        var remaining = artifacts
        var removedServers: Set<MCPServerRef> = []
        var removedFiles: Set<String> = []

        // Remove MCS-owned brew packages (with reference counting)
        let refCounter = ResourceRefCounter(
            environment: environment,
            output: output,
            registry: registry
        )
        for package in artifacts.brewPackages {
            if refCounter.isStillNeeded(
                .brewPackage(package),
                excludingScope: ProjectIndex.globalSentinel,
                excludingPack: packID
            ) {
                output.dimmed("  Keeping brew package '\(package)' — still needed by another scope")
            } else {
                if exec.uninstallBrewPackage(package) {
                    output.dimmed("  Removed brew package: \(package)")
                }
            }
        }
        remaining.brewPackages = []

        // Remove MCS-owned plugins (with reference counting)
        for pluginName in artifacts.plugins {
            if refCounter.isStillNeeded(
                .plugin(pluginName),
                excludingScope: ProjectIndex.globalSentinel,
                excludingPack: packID
            ) {
                output.dimmed("  Keeping plugin '\(PluginRef(pluginName).bareName)' — still needed by another scope")
            } else {
                if exec.removePlugin(pluginName) {
                    output.dimmed("  Removed plugin: \(PluginRef(pluginName).bareName)")
                }
            }
        }
        remaining.plugins = []

        // Remove MCP servers (project-independent, no ref counting needed)
        for server in artifacts.mcpServers {
            if exec.removeMCPServer(name: server.name, scope: server.scope) {
                removedServers.insert(server)
                output.dimmed("  Removed MCP server: \(server.name)")
            }
        }
        remaining.mcpServers.removeAll { removedServers.contains($0) }

        // Remove files from ~/.claude/ tree
        let fm = FileManager.default
        for relativePath in artifacts.files {
            guard let fullPath = PathContainment.safePath(
                relativePath: relativePath,
                within: environment.claudeDirectory
            ) else {
                output.warn("Path '\(relativePath)' escapes claude directory — clearing from tracking")
                removedFiles.insert(relativePath)
                continue
            }

            if !fm.fileExists(atPath: fullPath.path) {
                removedFiles.insert(relativePath)
                continue
            }

            do {
                try fm.removeItem(at: fullPath)
                removedFiles.insert(relativePath)
                output.dimmed("  Removed: \(relativePath)")
            } catch {
                output.warn("  Could not remove \(relativePath): \(error.localizedDescription)")
            }
        }
        remaining.files.removeAll { removedFiles.contains($0) }

        // Remove auto-derived hook commands and contributed settings keys
        let hasHooksToRemove = !artifacts.hookCommands.isEmpty
        let hasSettingsToRemove = !artifacts.settingsKeys.isEmpty
        if hasHooksToRemove || hasSettingsToRemove {
            let settingsPath = environment.claudeSettings
            var settings: Settings
            do {
                settings = try Settings.load(from: settingsPath)
            } catch {
                output.warn("  Could not parse settings.json: \(error.localizedDescription)")
                output.warn("  Settings for \(packID) were not cleaned up. Fix settings.json and re-run.")
                // Keep pack in state — settings cleanup was not attempted
                state.setArtifacts(remaining, for: packID)
                output.warn("Some artifacts for \(packID) could not be removed. Re-run 'mcs sync --global' to retry.")
                return
            }
            if hasHooksToRemove {
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
            }
            if hasSettingsToRemove {
                settings.removeKeys(artifacts.settingsKeys)
            }
            do {
                // dropKeys prevents save(to:) Layer 3 from re-adding removed
                // top-level keys that still exist in the destination file.
                let dropKeys = Set(artifacts.settingsKeys.filter { !$0.contains(".") })
                try settings.save(to: settingsPath, dropKeys: dropKeys)
                remaining.hookCommands = []
                remaining.settingsKeys = []
                for cmd in artifacts.hookCommands {
                    output.dimmed("  Removed hook: \(cmd)")
                }
                for key in artifacts.settingsKeys {
                    output.dimmed("  Removed setting: \(key)")
                }
            } catch {
                output.warn("  Could not write settings.json: \(error.localizedDescription)")
            }
        }

        // Remove template sections from ~/.claude/CLAUDE.md
        if !artifacts.templateSections.isEmpty {
            let claudeMDPath = environment.globalClaudeMD
            if !FileManager.default.fileExists(atPath: claudeMDPath.path) {
                remaining.templateSections = []
                output.dimmed("  CLAUDE.md not found — clearing template section records")
            } else {
                do {
                    let content = try String(contentsOf: claudeMDPath, encoding: .utf8)
                    var updated = content
                    for sectionID in artifacts.templateSections {
                        updated = TemplateComposer.removeSection(in: updated, sectionIdentifier: sectionID)
                    }
                    if updated != content {
                        try updated.write(to: claudeMDPath, atomically: true, encoding: .utf8)
                        for sectionID in artifacts.templateSections {
                            output.dimmed("  Removed template section: \(sectionID)")
                        }
                    } else {
                        output.dimmed("  Template sections already absent from CLAUDE.md")
                    }
                    remaining.templateSections = []
                } catch {
                    output.warn("Could not update CLAUDE.md: \(error.localizedDescription)")
                }
            }
        }

        if remaining.isEmpty {
            state.removePack(packID)
        } else {
            state.setArtifacts(remaining, for: packID)
            output.warn("Some artifacts for \(packID) could not be removed. Re-run 'mcs sync --global' to retry.")
        }
    }

    // MARK: - Global Artifact Installation

    /// Install global-scope artifacts for a pack (brew, MCP with scope "user",
    /// plugins, and files to `~/.claude/`).
    /// Returns a `PackArtifactRecord` tracking what was installed.
    ///
    /// Starts from the previous artifact record to preserve brew/plugin ownership
    /// from earlier syncs. Convergent fields (mcpServers, files, hookCommands) are
    /// rebuilt fresh; ownership fields (brewPackages, plugins) carry forward.
    private func installGlobalArtifacts(
        _ pack: any TechPack,
        previousArtifacts: PackArtifactRecord? = nil,
        excludedIDs: Set<String> = [],
        resolvedValues: [String: String] = [:],
        preloadedTemplates: [TemplateContribution]? = nil
    ) -> PackArtifactRecord {
        var artifacts = PackArtifactRecord()
        // Carry forward ownership records from previous sync
        artifacts.brewPackages = previousArtifacts?.brewPackages ?? []
        artifacts.plugins = previousArtifacts?.plugins ?? []
        let exec = makeExecutor()

        for component in pack.components {
            if excludedIDs.contains(component.id) {
                output.dimmed("  \(component.displayName) excluded, skipping")
                continue
            }

            // Skip if already installed. Convergent actions (see
            // ComponentExecutor.isAlreadyInstalled) always return false
            // so they re-run to pick up configuration changes.
            if ComponentExecutor.isAlreadyInstalled(component) {
                output.dimmed("  \(component.displayName) already installed, skipping")
                continue
            }

            switch component.installAction {
            case .brewInstall(let package):
                output.dimmed("  Installing \(component.displayName)...")
                if exec.installBrewPackage(package) {
                    artifacts.recordBrewPackage(package)
                    output.success("  \(component.displayName) installed")
                } else {
                    output.warn("  \(component.displayName) failed to install")
                }

            case .mcpServer(let config):
                // Override scope to "user" for global installation
                let globalConfig = MCPServerConfig(
                    name: config.name,
                    command: config.command,
                    args: config.args,
                    env: config.env,
                    scope: "user"
                )
                if exec.installMCPServer(globalConfig) {
                    artifacts.mcpServers.append(MCPServerRef(
                        name: config.name,
                        scope: "user"
                    ))
                    output.success("  \(component.displayName) registered (scope: user)")
                }

            case .plugin(let name):
                output.dimmed("  Installing plugin \(component.displayName)...")
                if exec.installPlugin(name) {
                    artifacts.recordPlugin(name)
                    output.success("  \(component.displayName) installed")
                } else {
                    output.warn("  \(component.displayName) failed to install")
                }

            case .copyPackFile(let source, let destination, let fileType):
                if exec.installCopyPackFile(
                    source: source,
                    destination: destination,
                    fileType: fileType,
                    resolvedValues: resolvedValues
                ) {
                    // Track path relative to ~/.claude/
                    let baseDir = fileType.baseDirectory(in: environment)
                    let destURL = baseDir.appendingPathComponent(destination)
                    let relativePath = claudeRelativePath(destURL)
                    artifacts.files.append(relativePath)
                    // Track auto-derived hook commands for settings cleanup
                    if component.type == .hookFile,
                       component.hookEvent != nil,
                       fileType == .hook {
                        artifacts.hookCommands.append("bash ~/.claude/hooks/\(destination)")
                    }
                    output.success("  \(component.displayName) installed")
                }

            case .gitignoreEntries(let entries):
                _ = exec.addGitignoreEntries(entries)

            case .shellCommand(let command):
                // Attempt to run the command. ShellRunner sets stdin to /dev/null,
                // so non-interactive commands (npx -y, etc.) work fine.
                // Only commands needing interactive input (sudo, prompts) will fail.
                output.dimmed("  Running \(component.displayName)...")
                let result = shell.shell(command)
                if result.succeeded {
                    output.success("  \(component.displayName) installed")
                } else {
                    output.warn("  \(component.displayName) requires manual installation:")
                    output.plain("    \(command)")
                    if !result.stderr.isEmpty {
                        output.dimmed("  Error: \(String(result.stderr.prefix(200)))")
                    }
                    output.dimmed("  Run the command above in your terminal, then re-run 'mcs sync --global'.")
                }

            case .settingsMerge:
                // Handled by composeGlobalSettings at the configure level.
                break
            }
        }

        // Track template sections from pre-loaded cache only — if loading failed
        // earlier, we must not record sections that were never written.
        if let templates = preloadedTemplates {
            artifacts.templateSections = templates.map(\.sectionIdentifier)
        }

        return artifacts
    }

    // MARK: - Global Settings Composition

    /// Build `settings.json` from all selected packs' hook entries, plugins, and settings files,
    /// respecting per-pack component exclusions.
    ///
    /// Unlike the project-scoped `settings.local.json` which is entirely mcs-managed,
    /// the global `settings.json` may contain user-written content. We load the existing
    /// file first and merge pack contributions into it — `Settings.merge(with:)` preserves
    /// existing user values, and `Settings.save(to:)` preserves unknown top-level keys.
    /// Returns a mapping of pack identifier to contributed extraJSON key paths,
    /// so the caller can store them in artifact records for later cleanup.
    private func composeGlobalSettings(
        packs: [any TechPack],
        excludedComponents: [String: Set<String>] = [:]
    ) throws -> [String: [String]] {
        let settingsPath = environment.claudeSettings

        var settings: Settings
        do {
            settings = try Settings.load(from: settingsPath)
        } catch {
            output.error("Could not parse \(settingsPath.path): \(error.localizedDescription)")
            output.error("Fix the JSON syntax or rename the file, then re-run 'mcs sync --global'.")
            throw MCSError.fileOperationFailed(
                path: settingsPath.path,
                reason: "Invalid JSON: \(error.localizedDescription)"
            )
        }

        // Strip mcs-managed hook entries before re-composing so hooks from
        // removed packs are cleaned up. User-written hooks are preserved.
        if var hooks = settings.hooks {
            for (event, groups) in hooks {
                hooks[event] = groups.filter { group in
                    guard let cmd = group.hooks?.first?.command else { return true }
                    return !cmd.hasPrefix("bash ~/.claude/hooks/")
                }
            }
            hooks = hooks.filter { !$0.value.isEmpty }
            settings.hooks = hooks.isEmpty ? nil : hooks
        }

        var hasContent = false
        var contributedKeys: [String: [String]] = [:]

        // Single pass: derive hook entries, plugins, and merge settings files
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            for component in pack.components {
                guard !excluded.contains(component.id) else { continue }

                // Auto-derive hook entries from hookFile components with hookEvent
                if component.type == .hookFile,
                   let hookEvent = component.hookEvent,
                   case .copyPackFile(_, let destination, .hook) = component.installAction {
                    // Global hooks reference ~/.claude/hooks/ (home-relative, not project-relative)
                    let command = "bash ~/.claude/hooks/\(destination)"
                    if settings.addHookEntry(event: hookEvent, command: command) {
                        hasContent = true
                    }
                }

                // Auto-derive enabledPlugins from plugin components
                if case .plugin(let name) = component.installAction {
                    let ref = PluginRef(name)
                    var plugins = settings.enabledPlugins ?? [:]
                    if plugins[ref.bareName] == nil {
                        plugins[ref.bareName] = true
                    }
                    settings.enabledPlugins = plugins
                    hasContent = true
                    // Track for cleanup on pack removal (dotted path handled by removeKeys)
                    contributedKeys[pack.identifier, default: []].append("enabledPlugins.\(ref.bareName)")
                }

                // Merge settings files from packs
                if case .settingsMerge(let source) = component.installAction, let source {
                    do {
                        let packSettings = try Settings.load(from: source)
                        // Track extraJSON keys this pack contributes for artifact cleanup
                        if !packSettings.extraJSON.isEmpty {
                            contributedKeys[pack.identifier, default: []].append(contentsOf: packSettings.extraJSON.keys)
                        }
                        settings.merge(with: packSettings)
                        hasContent = true
                    } catch {
                        output.warn("Could not load settings from \(pack.displayName)/\(source.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Write composed settings (do NOT remove the file when empty — user may own it)
        if hasContent {
            do {
                try settings.save(to: settingsPath)
                output.success("Composed settings.json (global)")
            } catch {
                output.error("Could not write settings.json: \(error.localizedDescription)")
                throw MCSError.fileOperationFailed(
                    path: settingsPath.path,
                    reason: error.localizedDescription
                )
            }
        }

        return contributedKeys
    }

    // MARK: - Value Resolution

    /// Resolve template/placeholder values from pack prompts for global scope.
    ///
    /// Project-scoped prompts (`fileDetect`) are skipped via `isGlobalScope: true`.
    private func resolveGlobalTemplateValues(
        packs: [any TechPack]
    ) throws -> [String: String] {
        var allValues: [String: String] = [:]
        let context = ProjectConfigContext(
            projectPath: environment.homeDirectory,
            repoName: "",
            output: output,
            isGlobalScope: true
        )
        for pack in packs {
            let packValues = try pack.templateValues(context: context)
            allValues.merge(packValues) { _, new in new }
        }
        return allValues
    }

    // MARK: - CLAUDE.md Composition

    /// Compose `~/.claude/CLAUDE.md` from all selected packs' pre-loaded template contributions.
    ///
    /// Before writing, checks for unreplaced placeholders (e.g. `__REPO_NAME__`) that
    /// cannot be resolved in global scope. If found, presents a three-way prompt:
    /// proceed (keep literal placeholders), skip (omit affected sections), or stop.
    ///
    /// - Returns: The set of section identifiers actually written, or `nil` if no
    ///   contributions existed (nothing to reconcile).
    @discardableResult
    private func composeGlobalClaudeMD(
        packs: [any TechPack],
        preloadedTemplates: [String: [TemplateContribution]],
        values: [String: String]
    ) throws -> Set<String>? {
        var allContributions: [TemplateContribution] = []
        for pack in packs {
            if let templates = preloadedTemplates[pack.identifier] {
                allContributions.append(contentsOf: templates)
            } else if !pack.templateSectionIdentifiers.isEmpty {
                output.warn("Skipping templates for \(pack.displayName) (failed to load earlier)")
            }
        }

        guard !allContributions.isEmpty else { return nil }

        // Check for unreplaced placeholders before writing
        var placeholdersBySectionID: [String: [String]] = [:]
        for contribution in allContributions {
            let rendered = TemplateEngine.substitute(
                template: contribution.templateContent,
                values: values,
                emitWarnings: false
            )
            let unreplaced = TemplateEngine.findUnreplacedPlaceholders(in: rendered)
            if !unreplaced.isEmpty {
                placeholdersBySectionID[contribution.sectionIdentifier] = unreplaced
            }
        }

        if !placeholdersBySectionID.isEmpty {
            output.warn("Global templates contain placeholders that cannot be resolved:")
            for (sectionID, placeholders) in placeholdersBySectionID.sorted(by: { $0.key < $1.key }) {
                output.warn("  \(placeholders.joined(separator: ", ")) in: \(sectionID)")
            }
            output.plain("")

            let choice = promptPlaceholderAction()
            switch choice {
            case .proceed:
                break
            case .skip:
                allContributions.removeAll { placeholdersBySectionID.keys.contains($0.sectionIdentifier) }
                if allContributions.isEmpty {
                    output.info("All template sections contained unresolved placeholders — skipping CLAUDE.md composition.")
                    return Set()
                }
            case .stop:
                throw MCSError.configurationFailed(
                    reason: "Aborted: templates contain unresolved placeholders. "
                        + "Remove project-scoped placeholders from global templates or provide values via pack prompts."
                )
            }
        }

        try writeGlobalClaudeMD(contributions: allContributions, values: values)
        return Set(allContributions.map(\.sectionIdentifier))
    }

    /// Three-way prompt for handling unreplaced template placeholders.
    private enum PlaceholderAction {
        case proceed, skip, stop
    }

    private func promptPlaceholderAction() -> PlaceholderAction {
        output.plain("  [p]roceed — include sections with unresolved placeholders")
        output.plain("  [s]kip    — omit sections containing unresolved placeholders")
        output.plain("  s[t]op    — abort global sync")
        while true {
            let answer = output.promptInline("Choose", default: "p").lowercased()
            switch answer.first {
            case "p": return .proceed
            case "s": return .skip
            case "t": return .stop
            default:
                output.plain("  Please enter p, s, or t.")
            }
        }
    }

    /// Compose and write `~/.claude/CLAUDE.md` from template contributions.
    private func writeGlobalClaudeMD(
        contributions: [TemplateContribution],
        values: [String: String]
    ) throws {
        let claudeMDPath = environment.globalClaudeMD
        let existingContent = try? String(contentsOf: claudeMDPath, encoding: .utf8)

        let result = TemplateComposer.composeOrUpdate(
            existingContent: existingContent,
            contributions: contributions,
            values: values,
            emitWarnings: false
        )

        for warning in result.warnings {
            output.warn(warning)
        }

        if existingContent != nil {
            var backup = Backup()
            try backup.backupFile(at: claudeMDPath)
        }
        try result.content.write(to: claudeMDPath, atomically: true, encoding: .utf8)
        output.success("Generated CLAUDE.md (global)")
    }

    // MARK: - Helpers

    /// Return a path relative to `~/.claude/` for artifact tracking.
    private func claudeRelativePath(_ url: URL) -> String {
        PathContainment.relativePath(of: url.path, within: environment.claudeDirectory.path)
    }

    private func makeExecutor() -> ComponentExecutor {
        ConfiguratorSupport.makeExecutor(environment: environment, output: output, shell: shell)
    }

    private func validatePeerDependencies(packs: [any TechPack]) -> [PeerDependencyResult] {
        ConfiguratorSupport.validatePeerDependencies(packs: packs, environment: environment, output: output)
    }

    private func ensureGitignoreEntries() throws {
        try ConfiguratorSupport.ensureGitignoreEntries(shell: shell)
    }

}
