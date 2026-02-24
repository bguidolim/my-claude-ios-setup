import Foundation

/// Global-scope configuration engine.
///
/// Installs brew packages, MCP servers (scope "user"), plugins, and files
/// into `~/.claude/` directories. Does not compose CLAUDE.local.md or
/// settings.local.json — those are project-scoped.
/// State is tracked at `~/.mcs/global-state.json`.
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

        let previousState = ProjectState(stateFile: environment.globalStateFile)
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
            self.dryRun(packs: selectedPacks)
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
            output: output,
            componentsProvider: globalComponents(from:)
        )
    }

    // MARK: - Dry Run

    /// Compute and display what `configure` would do, without making any changes.
    func dryRun(packs: [any TechPack]) {
        let selectedIDs = Set(packs.map(\.identifier))

        let state = ProjectState(stateFile: environment.globalStateFile)
        let previousIDs = state.configuredPacks

        let removals = previousIDs.subtracting(selectedIDs)
        let additions = selectedIDs.subtracting(previousIDs)
        let updates = selectedIDs.intersection(previousIDs)

        output.header("Plan (Global)")

        if removals.isEmpty && additions.isEmpty && updates.isEmpty && packs.isEmpty {
            output.plain("")
            output.info("No packs selected. Nothing would change.")
            output.plain("")
            output.dimmed("No changes made (dry run).")
            return
        }

        for pack in packs where additions.contains(pack.identifier) {
            output.plain("")
            output.success("+ \(pack.displayName) (new)")
            printGlobalArtifactSummary(pack)
        }

        for packID in removals.sorted() {
            output.plain("")
            output.warn("- \(packID) (remove)")
            if let artifacts = state.artifacts(for: packID) {
                printRemovalSummary(artifacts)
            } else {
                output.dimmed("  No artifact record available")
            }
        }

        for pack in packs where updates.contains(pack.identifier) {
            output.plain("")
            output.info("~ \(pack.displayName) (update)")
            printGlobalArtifactSummary(pack)
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
    }

    private func printRemovalSummary(_ artifacts: PackArtifactRecord) {
        for server in artifacts.mcpServers {
            output.dimmed("      MCP server: \(server.name)")
        }
        for path in artifacts.files {
            output.dimmed("      File: \(path)")
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

        var state = ProjectState(stateFile: environment.globalStateFile)
        let previousIDs = state.configuredPacks

        let removals = previousIDs.subtracting(selectedIDs)
        let additions = selectedIDs.subtracting(previousIDs)

        // 0. Validate peer dependencies
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
        let undeclared = scanForUndeclaredPlaceholders(packs: packs, resolvedValues: allValues)
        for key in undeclared {
            let value = output.promptInline("Set value for \(key)", default: nil)
            allValues[key] = value
        }

        // 3. Install global artifacts for each pack
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            let isNew = additions.contains(pack.identifier)
            let label = isNew ? "Configuring" : "Updating"
            output.info("\(label) \(pack.displayName) (global)...")
            let artifacts = installGlobalArtifacts(pack, excludedIDs: excluded, resolvedValues: allValues)
            state.setArtifacts(artifacts, for: pack.identifier)
            state.setExcludedComponents(excluded, for: pack.identifier)
            state.recordPack(pack.identifier)
        }

        // 4. Compose global settings.json from ALL selected packs
        try composeGlobalSettings(packs: packs, excludedComponents: excludedComponents)

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

        // 7. Inform user about project-scoped features that were skipped
        printProjectScopedSkips(packs: packs)
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

        // Remove MCP servers
        for server in artifacts.mcpServers {
            if exec.removeMCPServer(name: server.name, scope: server.scope) {
                output.dimmed("  Removed MCP server: \(server.name)")
            }
        }

        // Remove files from ~/.claude/ tree
        let fm = FileManager.default
        for relativePath in artifacts.files {
            let fullPath = environment.claudeDirectory.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: fullPath.path) {
                do {
                    try fm.removeItem(at: fullPath)
                    output.dimmed("  Removed: \(relativePath)")
                } catch {
                    output.warn("  Could not remove \(relativePath): \(error.localizedDescription)")
                }
            }
        }

        state.removePack(packID)
    }

    // MARK: - Global Artifact Installation

    /// Install global-scope artifacts for a pack (brew, MCP with scope "user",
    /// plugins, and files to `~/.claude/`).
    /// Returns a `PackArtifactRecord` tracking what was installed.
    private func installGlobalArtifacts(
        _ pack: any TechPack,
        excludedIDs: Set<String> = [],
        resolvedValues: [String: String] = [:]
    ) -> PackArtifactRecord {
        var artifacts = PackArtifactRecord()
        let exec = makeExecutor()

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
            case .brewInstall(let package):
                output.dimmed("  Installing \(component.displayName)...")
                _ = exec.installBrewPackage(package)

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
                _ = exec.installPlugin(name)

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
                    output.success("  \(component.displayName) installed")
                }

            case .gitignoreEntries(let entries):
                _ = exec.addGitignoreEntries(entries)

            case .shellCommand(let command):
                // Interactive shell commands cannot run through mcs (stdin is /dev/null).
                // Warn the user with manual install instructions.
                output.warn("  \(component.displayName) requires manual installation:")
                output.plain("    \(command)")
                output.dimmed("  Run the command above in your terminal, then re-run 'mcs sync --global'.")

            case .settingsMerge:
                // Handled by composeGlobalSettings at the configure level.
                break
            }
        }

        return artifacts
    }

    // MARK: - Global Settings Composition

    /// Build `settings.json` from all selected packs' hook entries, plugins, and settings files.
    ///
    /// Unlike the project-scoped `settings.local.json` which is entirely mcs-managed,
    /// the global `settings.json` may contain user-written content. We load the existing
    /// file first and merge pack contributions into it — `Settings.merge(with:)` preserves
    /// existing user values, and `Settings.save(to:)` preserves unknown top-level keys.
    private func composeGlobalSettings(
        packs: [any TechPack],
        excludedComponents: [String: Set<String>] = [:]
    ) throws {
        let settingsPath = environment.claudeSettings

        var settings = try Settings.load(from: settingsPath)
        var hasContent = false

        // 1. Auto-derive hook entries from hookFile components with hookEvent
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            for component in pack.components {
                guard !excluded.contains(component.id) else { continue }
                if component.type == .hookFile,
                   let hookEvent = component.hookEvent,
                   case .copyPackFile(_, let destination, .hook) = component.installAction {
                    // Global hooks use absolute path to ~/.claude/hooks/
                    let command = "bash ~/.claude/hooks/\(destination)"
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

        // 2. Auto-derive enabledPlugins from plugin components
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

        // 3. Merge settings files from packs
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

        // 4. Write composed settings (do NOT remove the file when empty — user may own it)
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

    /// Scan all `copyPackFile` sources for `__PLACEHOLDER__` tokens not covered by
    /// resolved values. Returns undeclared keys sorted alphabetically.
    private func scanForUndeclaredPlaceholders(
        packs: [any TechPack],
        resolvedValues: [String: String]
    ) -> [String] {
        var undeclared = Set<String>()
        let resolvedKeys = Set(resolvedValues.keys)

        for pack in packs {
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

    /// Strip `__` delimiters from a placeholder token (e.g. `__FOO__` → `FOO`).
    private static func stripPlaceholderDelimiters(_ token: String) -> String {
        String(token.dropFirst(2).dropLast(2))
    }

    // MARK: - Helpers

    /// Filter a pack's components to those relevant for global installation.
    private func globalComponents(from pack: any TechPack) -> [ComponentDefinition] {
        pack.components
    }

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

    /// Print a summary of project-scoped features that were skipped during global sync.
    private func printProjectScopedSkips(packs: [any TechPack]) {
        var skipped: [String] = []

        let templateCount = packs.reduce(0) { $0 + ((try? $1.templates) ?? []).count }
        if templateCount > 0 {
            skipped.append("CLAUDE.local.md templates (\(templateCount))")
        }

        if !skipped.isEmpty {
            output.plain("")
            output.dimmed("Skipped (project-scoped): \(skipped.joined(separator: ", "))")
            output.dimmed("Run 'mcs sync' inside a project to apply these.")
        }
    }
}
