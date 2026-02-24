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
        var exclusions: [String: Set<String>] = [:]

        for pack in packs {
            let components = globalComponents(from: pack)
            guard components.count > 1 else { continue }

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

        // 2. Install global artifacts for each pack
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            let isNew = additions.contains(pack.identifier)
            let label = isNew ? "Configuring" : "Updating"
            output.info("\(label) \(pack.displayName) (global)...")
            let artifacts = installGlobalArtifacts(pack, excludedIDs: excluded)
            state.setArtifacts(artifacts, for: pack.identifier)
            state.setExcludedComponents(excluded, for: pack.identifier)
            state.recordPack(pack.identifier)
        }

        // 3. Ensure gitignore entries
        try ensureGitignoreEntries()
        for pack in packs {
            let exec = makeExecutor()
            exec.addPackGitignoreEntries(from: pack)
        }

        // 4. Save global state
        do {
            try state.save()
            output.success("Updated \(environment.globalStateFile.lastPathComponent)")
        } catch {
            output.warn("Could not write global state: \(error.localizedDescription)")
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

        // Remove MCP servers
        for server in artifacts.mcpServers {
            exec.removeMCPServer(name: server.name, scope: server.scope)
            output.dimmed("  Removed MCP server: \(server.name)")
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
        excludedIDs: Set<String> = []
    ) -> PackArtifactRecord {
        var artifacts = PackArtifactRecord()
        let exec = makeExecutor()

        for component in pack.components {
            if excludedIDs.contains(component.id) {
                output.dimmed("  \(component.displayName) excluded, skipping")
                continue
            }

            switch component.installAction {
            case .brewInstall(let package):
                if !ComponentExecutor.isAlreadyInstalled(component) {
                    output.dimmed("  Installing \(component.displayName)...")
                    _ = exec.installBrewPackage(package)
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
                if !ComponentExecutor.isAlreadyInstalled(component) {
                    output.dimmed("  Installing plugin \(component.displayName)...")
                    _ = exec.installPlugin(name)
                }

            case .copyPackFile(let source, let destination, let fileType):
                if exec.installCopyPackFile(
                    source: source,
                    destination: destination,
                    fileType: fileType
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
                let result = shell.shell(command)
                if !result.succeeded {
                    output.warn("  \(component.displayName) failed: \(String(result.stderr.prefix(200)))")
                }

            case .settingsMerge:
                // Settings merge is project-scoped; not applicable to global.
                break
            }
        }

        return artifacts
    }

    // MARK: - Helpers

    /// Filter a pack's components to those relevant for global installation.
    /// Excludes settings merge (project-scoped only).
    private func globalComponents(from pack: any TechPack) -> [ComponentDefinition] {
        pack.components.filter { component in
            if case .settingsMerge = component.installAction { return false }
            return true
        }
    }

    /// Return a path relative to `~/.claude/` for artifact tracking.
    private func claudeRelativePath(_ url: URL) -> String {
        let full = url.path
        let base = environment.claudeDirectory.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count))
        }
        return full
    }

    private func makeExecutor() -> ComponentExecutor {
        ComponentExecutor(
            environment: environment,
            output: output,
            shell: shell
        )
    }

    private func validatePeerDependencies(packs: [any TechPack]) -> [PeerDependencyResult] {
        let packRegistryFile = PackRegistryFile(path: environment.packsRegistry)
        let registeredPacks = (try? packRegistryFile.load())?.packs ?? []

        return PeerDependencyValidator.validateSelection(
            packs: packs,
            registeredPacks: registeredPacks
        )
    }

    private func ensureGitignoreEntries() throws {
        let manager = GitignoreManager(shell: shell)
        try manager.addCoreEntries()
    }
}
